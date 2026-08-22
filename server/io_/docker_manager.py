"""Docker 工作空间管理 - 容器创建/停止/删除与卷管理。"""
import base64
import io
import json
import logging
import os
import re
import shlex
import tarfile
import time
from typing import Any, Dict, List, Optional
from config.config import get_config
logger = logging.getLogger(__name__)
# 尝试导入 docker SDK；未安装时各方法优雅降级
try:
    import docker
    from docker.errors import APIError, ImageNotFound, NotFound
    _DOCKER_IMPORT_ERROR = ""
except ImportError as _exc:
    docker = None  # type: ignore[assignment]
    APIError = Exception  # type: ignore[assignment,misc]
    ImageNotFound = Exception  # type: ignore[assignment,misc]
    NotFound = Exception  # type: ignore[assignment,misc]
    _DOCKER_IMPORT_ERROR = str(_exc)
# 父 agent Git HTTP 服务默认端口（容器内 git http server 监听端口）
DEFAULT_GIT_PORT = 8000


def _make_tar_bytes(name: str, data: bytes) -> bytes:
    """将单个文件打包为 tar 字节流，供 ``container.put_archive`` 使用。

    采用流式 tar 打包，避免将大文件 base64 编码塞进 exec 命令行——
    Docker exec 单条命令消息上限 4MB，大文件会触发 ResourceExhausted。
    :param name: tar 内的文件名（相对解包目录）
    :param data: 文件字节内容
    :return: tar 字节流
    """
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        info = tarfile.TarInfo(name)
        info.size = len(data)
        info.mtime = int(time.time())
        tar.addfile(info, io.BytesIO(data))
    buf.seek(0)
    return buf.read()


class DockerManager:
    """管理 agent 工作空间容器与持久化卷的生命周期。"""
    def __init__(self) -> None:
        """初始化 docker client，读取配置中的镜像与资源限制。
        若 Docker 未安装或 daemon 未运行，标记为不可用而非抛出异常，
        后续调用各方法时优雅降级。

        说明：本地运行模式不再由本后端进程决定（前端不再启动本地后端），
        而是由用户在 WebSocket 连接中发送 ``register_local_executor`` 注册，
        后端通过 :class:`core.local_executor.LocalExecutorClient` 把工具调用
        经反向 WS 转发到用户本机执行。因此此处不再读取 ``LOCAL_MODE`` 环境变量。
        """
        self._available = False
        self._unavailable_reason = ""
        # docker SDK 未安装
        if docker is None:
            self._unavailable_reason = f"docker SDK 未安装: {_DOCKER_IMPORT_ERROR}"
            self.client = None  # type: ignore[assignment]
        else:
            try:
                self.client = docker.from_env()
                # 触发一次 ping 确认 daemon 可达
                self.client.ping()
                self._available = True
            except Exception as exc:  # noqa: BLE001
                self._unavailable_reason = str(exc)
                self.client = None  # type: ignore[assignment]
        docker_cfg = get_config().get("docker", {})
        self.image: str = docker_cfg.get("image", "agent-workspace:latest")
        self.max_members_per_level: int = int(docker_cfg.get("max_members_per_level", 10))
        resource_limits = docker_cfg.get("resource_limits", {})
        self.cpu_limit: str = str(resource_limits.get("cpu", "2.0"))
        self.memory_limit: str = str(resource_limits.get("memory", "2g"))
        # 父 agent git http 服务端口（暂用默认值，后续可从配置扩展）
        self.git_port: int = DEFAULT_GIT_PORT
        # 沙箱网络与下载限制（checklist 13/14）
        sandbox_cfg = get_config().get("sandbox", {})
        net_cfg = sandbox_cfg.get("network", {})
        self.network_enabled: bool = bool(net_cfg.get("enabled", False))
        self.network_whitelist: List[str] = list(net_cfg.get("whitelist", []))
        # 单次网络下载数据量上限（pip / curl / git 等单次拉取，需 < 1G）
        self.max_download_size: str = str(
            net_cfg.get("max_download_size", "900m")
        )
        # 云端共享主工作区：member_workspace_id -> 顶层 agent workspace_id。
        # 团队成员共享顶层 agent 的容器/卷（/workspace 主工作区），
        # 各 agent 的 .self 私人路径路由到共享容器内 workspaces/{agent_id}/.self。
        self._shared_owner: Dict[str, str] = {}
        self._load_shared_map()
    @property
    def available(self) -> bool:
        """Docker daemon 是否可用。"""
        return self._available
    # ------------------------------------------------------------------
    # 内部工具方法
    # ------------------------------------------------------------------
    @staticmethod
    def _local_workspace_path(workspace_id: str) -> "os.PathLike":
        """返回 Docker 不可用时的工作空间目录路径。

        - 顶级 agent（workspace_id == "top"）：直接映射到后端当前工作目录
          ``<cwd>`` 本身。
        - 其他 agent：位于 ``<cwd>/workspaces/{workspace_id}`` 子目录，
          彼此隔离且不污染用户项目目录。

        注意：新架构下本地运行模式（工具执行经反向 WS 到用户本机）不由
        本方法决定——Frontend 端的 :class:`LocalExecutorService` 拥有独立的
        路径映射逻辑（与后端一致保持同步即可）。
        """
        from pathlib import Path
        return Path(__file__).resolve().parent.parent / "workspaces" / workspace_id
    def _use_local(self) -> bool:
        """是否应使用本地目录执行（Docker 不可用时降级）。"""
        return not self._available
    @staticmethod
    def _resolve_sh() -> Optional[str]:
        """定位可用的 POSIX shell（本地模式执行 shell 命令用）。

        优先使用 PATH 中的 ``sh``；Windows 上 Git for Windows 自带
        ``sh.exe``，位于常见安装目录。找不到时返回 None，
        调用方将使用 Python 原生的命令解析（mkdir/heredoc/base64 等）。
        """
        import shutil

        found = shutil.which("sh")
        if found:
            return found
        if os.name == "nt":
            candidates = [
                r"C:\Program Files\Git\bin\sh.exe",
                r"C:\Program Files (x86)\Git\bin\sh.exe",
                r"C:\Program Files\Git\usr\bin\sh.exe",
                os.path.expandvars(r"%LOCALAPPDATA%\Programs\Git\bin\sh.exe"),
            ]
            for cand in candidates:
                if cand and os.path.exists(cand):
                    return cand
        return None
    @staticmethod
    def _volume_name(workspace_id: str) -> str:
        """工作空间对应的 volume 名称。"""
        return f"workspace_{workspace_id}"
    @staticmethod
    def _container_name(workspace_id: str) -> str:
        """工作空间对应的容器名称。"""
        return f"workspace_{workspace_id}"
    # ------------------------------------------------------------------
    # 云端共享主工作区：团队成员共享顶层 agent 的容器/卷
    # ------------------------------------------------------------------
    def _shared_map_path(self) -> "os.PathLike":
        """共享映射持久化文件路径（server/data/shared_workspaces.json）。"""
        from pathlib import Path
        return Path(__file__).resolve().parent.parent / "data" / "shared_workspaces.json"

    def _load_shared_map(self) -> None:
        """从磁盘加载共享映射：{member_workspace_id: top_agent_workspace_id}。"""
        try:
            path = self._shared_map_path()
            if path.exists():
                with open(path, "r", encoding="utf-8") as f:
                    data = json.load(f)
                if isinstance(data, dict):
                    self._shared_owner = {
                        str(k): str(v) for k, v in data.items() if k and v
                    }
        except Exception as exc:  # noqa: BLE001
            logger.warning("加载共享工作空间映射失败: %s", exc)

    def _save_shared_map(self) -> None:
        """持久化共享映射，保证服务重启后成员仍共享顶层容器。"""
        try:
            path = self._shared_map_path()
            path.parent.mkdir(parents=True, exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                json.dump(self._shared_owner, f, ensure_ascii=False, indent=2)
        except Exception as exc:  # noqa: BLE001
            logger.warning("保存共享工作空间映射失败: %s", exc)

    def register_shared_workspace(
        self, workspace_id: str, owner_id: str
    ) -> None:
        """将成员工作空间注册为共享顶层 agent 的主工作区。

        :param workspace_id: 成员工作空间标识
        :param owner_id: 所属顶层 agent 的工作空间标识（容器所有者）
        """
        if not workspace_id or not owner_id or workspace_id == owner_id:
            return
        self._shared_owner[workspace_id] = owner_id
        self._save_shared_map()

    def unregister_shared_workspace(self, workspace_id: str) -> None:
        """取消成员工作空间的共享注册（不删除共享容器）。"""
        if self._shared_owner.pop(workspace_id, None) is not None:
            self._save_shared_map()

    def is_shared(self, workspace_id: str) -> bool:
        """是否为共享成员：云端模式下共享顶层 agent 的容器。"""
        return workspace_id in self._shared_owner

    def get_container_owner(self, workspace_id: str) -> str:
        """返回实际持有容器的工作空间标识（共享成员→顶层 agent，否则为自身）。"""
        return self._shared_owner.get(workspace_id, workspace_id)

    def _container_name_for(self, workspace_id: str) -> str:
        """返回应使用的容器名称（共享成员解析到顶层 agent 容器）。"""
        return self._container_name(self.get_container_owner(workspace_id))

    @staticmethod
    def _is_private_path(path: str) -> bool:
        """判断路径是否属于 agent 的私人记忆空间（``.self`` 开头的路径）。

        与前端 LocalExecutorService 保持一致：仅 ``.self`` 视为私人路径，
        ``.input``（用户上传附件）等其余路径共享主工作区。
        兼容 ``/workspace/.self/...`` 绝对路径形式。
        """
        p = (path or "").replace("\\", "/").strip()
        if p == "/workspace":
            return False
        if p.startswith("/workspace/"):
            p = p[len("/workspace/"):]
        while p.startswith("./"):
            p = p[2:]
        return p == ".self" or p.startswith(".self/")

    def resolve_private_path(self, workspace_id: str, path: str) -> str:
        """解析工作空间内相对路径（相对于 /workspace）。

        共享成员（云端模式下共享顶层 agent 容器）的 ``.self`` 私人路径
        路由到共享容器内 ``workspaces/{workspace_id}`` 子目录；其余路径
        保持不变（即顶层 agent 的主工作区，团队共享）。
        """
        if not self.is_shared(workspace_id):
            return path
        p = (path or "").replace("\\", "/").strip()
        if p.startswith("/workspace/"):
            p = p[len("/workspace/"):]
        elif p == "/workspace":
            p = ""
        while p.startswith("./"):
            p = p[2:]
        if not (p == ".self" or p.startswith(".self/")):
            return path
        rest = p[len(".self"):].lstrip("/")
        prefix = f"workspaces/{workspace_id}/.self"
        return prefix if not rest else f"{prefix}/{rest}"

    def _rewrite_private_tokens(self, workspace_id: str, text: str) -> str:
        """重写命令中的 ``.self`` 路径令牌（共享成员→私人子目录）。

        仅当目标工作空间为共享成员时生效；顶层 agent 的命令原样返回。
        使用词边界正则，避免误伤 ``myself`` / ``.selfish`` 等含 .self 的串。
        """
        if not self.is_shared(workspace_id) or not text:
            return text
        pattern = re.compile(r"(?<![A-Za-z0-9_.-])\.self(?![A-Za-z0-9_.-])")
        return pattern.sub(f"workspaces/{workspace_id}/.self", text)
    def _exec(self, container, command: str) -> Dict[str, Any]:
        """在容器内通过 sh -c 执行复合命令，返回执行结果。"""
        result = container.exec_run(["sh", "-c", command])
        exit_code = int(result.exit_code)
        output = result.output
        if isinstance(output, bytes):
            output = output.decode("utf-8", errors="replace")
        return {
            "exit_code": exit_code,
            "stdout": output,
            "stderr": "",
        }
    @staticmethod
    def _parse_size(value: str, default: int) -> int:
        """将形如 ``900m`` / ``1g`` 的大小字符串解析为字节数。"""
        if not value:
            return default
        s = str(value).strip().lower()
        try:
            if s.endswith("g"):
                return int(float(s[:-1]) * 1024 * 1024 * 1024)
            if s.endswith("m"):
                return int(float(s[:-1]) * 1024 * 1024)
            if s.endswith("k"):
                return int(float(s[:-1]) * 1024)
            return int(float(s))
        except (TypeError, ValueError):
            return default
    # ------------------------------------------------------------------
    # 沙箱网络与下载限制（checklist 13/14）
    # ------------------------------------------------------------------
    def _apply_sandbox_policy(self, container, workspace_id: str) -> None:
        """在新建容器上应用沙箱网络白名单与单次下载数据量限制。"""
        if self.network_enabled:
            self._apply_egress_whitelist(container, workspace_id)
            self._apply_download_proxy(container, workspace_id)
    def _apply_egress_whitelist(self, container, workspace_id: str) -> None:
        """通过 iptables 配置白名单式出站网络（仅允许白名单主机 80/443）。
        默认放行回环、DNS（tcp/udp 53）与已建立连接；其余出站一律 DROP。
        白名单主机解析为 IP 后放行其 80/443 端口。需容器具备 NET_ADMIN 能力。
        """
        hosts = list(self.network_whitelist)
        if not hosts:
            logger.warning("网络白名单为空，跳过白名单限制, workspace=%s", workspace_id)
            return
        hosts_expr = " ".join(shlex.quote(h) for h in hosts)
        script = (
            "set -e\n"
            "iptables -P OUTPUT DROP\n"
            "iptables -A OUTPUT -o lo -j ACCEPT\n"
            "iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT\n"
            "iptables -A OUTPUT -p udp --dport 53 -j ACCEPT\n"
            "iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT\n"
            "for host in {hosts}; do\n"
            "  for ip in $(getent ahostsv4 \"$host\" 2>/dev/null | awk '{{print $1}}' | sort -u); do\n"
            "    iptables -A OUTPUT -d \"$ip\" -p tcp --dport 80 -j ACCEPT\n"
            "    iptables -A OUTPUT -d \"$ip\" -p tcp --dport 443 -j ACCEPT\n"
            "  done\n"
            "done\n"
        ).format(hosts=hosts_expr)
        b64 = base64.b64encode(script.encode("utf-8")).decode("ascii")
        result = self._exec(container, f"echo {b64} | base64 -d | sh")
        if result.get("exit_code", -1) != 0:
            logger.warning(
                "白名单网络策略应用失败: %s, workspace=%s",
                result.get("stdout", "").strip(),
                workspace_id,
            )
        else:
            logger.info("沙箱白名单网络已应用: workspace=%s", workspace_id)
    def _apply_download_proxy(self, container, workspace_id: str) -> None:
        """部署出站代理并对单次网络下载施加数据量上限（checklist 14）。
        代理监听 ``127.0.0.1:3128``，容器通过 ``http_proxy`` / ``https_proxy``
        环境变量投递所有 HTTP/HTTPS 出站流量。代理按目标主机执行白名单校验，
        并对每次下载（服务器→客户端方向）统计字节数，超过
        ``max_download_size`` 即截断连接，从而限制 pip / curl / git 等
        任意工具的单次拉取数据量 < 上限。
        """
        max_bytes = self._parse_size(self.max_download_size, 900 * 1024 * 1024)
        whitelist = list(self.network_whitelist)
        proxy_src = _build_egress_proxy_src(max_bytes, whitelist)
        script = (
            "cat <<'PROXY_EOF' > /usr/local/bin/egress_proxy.py\n"
            f"{proxy_src}"
            "PROXY_EOF\n"
            "chmod 755 /usr/local/bin/egress_proxy.py\n"
            "nohup python3 /usr/local/bin/egress_proxy.py "
            ">/tmp/egress_proxy.log 2>&1 &\n"
        )
        result = self._exec(container, script)
        if result.get("exit_code", -1) != 0:
            logger.warning(
                "下载代理部署失败: %s, workspace=%s",
                result.get("stdout", "").strip(),
                workspace_id,
            )
        else:
            logger.info(
                "下载代理已部署（单次下载上限 %d 字节）: workspace=%s",
                max_bytes,
                workspace_id,
            )
    # ------------------------------------------------------------------
    # 核心生命周期方法
    # ------------------------------------------------------------------
    def create_workspace(
        self,
        workspace_id: str,
        parent_workspace_id: Optional[str] = None,
        agent_name: Optional[str] = None,
        shared_with: Optional[str] = None,
    ) -> Dict[str, Any]:
        """创建工作空间容器并完成 Git 初始化。
        :param workspace_id: 工作空间唯一标识
        :param parent_workspace_id: 父工作空间标识，存在时配置父 agent git remote
        :param agent_name: agent 名称，用于 git user 配置；缺省时从 workspace_id 派生
        :param shared_with: 所属顶层 agent 的工作空间标识。提供时表示该工作空间为
            团队成员，云端模式下不创建独立容器/卷，而是共享顶层 agent 的容器与
            /workspace 主工作区，仅在其内初始化私人空间 workspaces/{id}/.self。
        :return: 包含 workspace_id / container_id / volume_name 的字典；
                 Docker 不可用时返回 error 字段
        """
        if shared_with:
            # 云端共享主工作区：成员不创建独立容器/卷，共享顶层 agent 容器
            self.register_shared_workspace(workspace_id, shared_with)
            if self._use_local():
                # Docker 不可用：降级为本地目录创建工作空间（保留原行为）
                return self._create_local_workspace(
                    workspace_id, parent_workspace_id, agent_name
                )
            name = agent_name or f"agent-{workspace_id[:8]}"
            try:
                # 确保顶层 agent 容器存在（首次创建成员时可能尚未就绪）
                owner = self.ensure_workspace(shared_with)
                if "error" in owner:
                    return {
                        "error": owner["error"],
                        "detail": owner.get("detail", ""),
                    }
                container = self.client.containers.get(
                    self._container_name_for(workspace_id)
                )
                # 在共享容器内初始化成员私人空间 workspaces/{member_id}/.self
                private_dir = f"workspaces/{workspace_id}/.self"
                init_cmd = " && ".join([
                    f"mkdir -p {private_dir}",
                    f"echo '# Agent 活动日志' > {private_dir}/activity.log",
                    f"echo '# 工作准则 (rule.md)' > {private_dir}/rule.md",
                ])
                self._exec(container, init_cmd)
                return {
                    "workspace_id": workspace_id,
                    "container_id": container.id,
                    "volume_name": self._volume_name(shared_with),
                    "parent_workspace_id": parent_workspace_id,
                    "agent_name": name,
                    "shared_with": shared_with,
                    "is_shared": True,
                }
            except (APIError, Exception) as exc:  # noqa: BLE001
                return {
                    "error": "创建共享成员工作空间失败",
                    "detail": str(exc),
                }
        if self._use_local():
            # Docker 不可用：降级为本地目录创建工作空间
            logger.info("Docker 不可用，改用本地目录创建工作空间")
            return self._create_local_workspace(
                workspace_id, parent_workspace_id, agent_name
            )
        name = agent_name or f"agent-{workspace_id[:8]}"
        volume_name = self._volume_name(workspace_id)
        container_name = self._container_name(workspace_id)
        try:
            # 1. 创建持久化卷（若已存在则复用）
            try:
                volume = self.client.volumes.get(volume_name)
            except NotFound:
                volume = self.client.volumes.create(name=volume_name)
            # 2. 启动容器，挂载卷并设置资源配额
            cpu_quota = int(float(self.cpu_limit) * 100000)
            container = self.client.containers.run(
                image=self.image,
                name=container_name,
                volumes={volume_name: {"bind": "/workspace", "mode": "rw"}},
                working_dir="/workspace",
                cpu_quota=cpu_quota,
                mem_limit=self.memory_limit,
                detach=True,
                tty=True,
                # 白名单网络限制需 NET_ADMIN 能力配置 iptables（checklist 13）
                cap_add=["NET_ADMIN"] if self.network_enabled else None,
                # 经本地出站代理路由 HTTP/HTTPS，以限制单次下载数据量（checklist 14）
                environment=(
                    _egress_proxy_env() if self.network_enabled else None
                ),
            )
            container_id = container.id
            # 3. 容器内执行 Git 仓库初始化
            git_init_cmd = " && ".join([
                "cd /workspace",
                "git init",
                f'git config user.name "{name}"',
                f'git config user.email "{name}@agent.local"',
                "mkdir -p .self",
                # 预创建活动日志，避免前端读取 activity.log 时 404
                "echo '# Agent 活动日志' > .self/activity.log",
            ])
            self._exec(container, git_init_cmd)
            # 3.1 初始化 .self/rule.md 模板（checklist 9：每个 agent 的工作准则文件）
            self._init_rule_md(container, name)
            # 3.2 应用沙箱网络白名单与 pip 下载限制（checklist 13/14）
            self._apply_sandbox_policy(container, workspace_id)
            # 4. 若存在父工作空间，配置父 agent git remote 并切换分支
            if parent_workspace_id:
                self._setup_parent_remote(
                    container, workspace_id, parent_workspace_id
                )
            # 5. 启动 Git HTTP daemon，供子 agent 通过 git remote push
            self.start_git_http_server(workspace_id)
            return {
                "workspace_id": workspace_id,
                "container_id": container_id,
                "volume_name": volume_name,
                "parent_workspace_id": parent_workspace_id,
                "agent_name": name,
            }
        except ImageNotFound:
            return {
                "error": f"镜像不存在: {self.image}",
                "detail": "请先构建 agent 工作空间镜像（参考 server/docker/Dockerfile）",
            }
        except (APIError, Exception) as exc:  # noqa: BLE001
            return {
                "error": "创建工作空间失败",
                "detail": str(exc),
            }
    def _create_local_workspace(
        self,
        workspace_id: str,
        parent_workspace_id: Optional[str] = None,
        agent_name: Optional[str] = None,
    ) -> Dict[str, Any]:
        """本地模式：在用户选择目录下创建本地工作空间并完成 Git 初始化。

        工作空间目录为 ``<cwd>/workspaces/{workspace_id}``，其中 cwd 即前端
        启动本地后端时选择的工作目录。
        :return: 包含 workspace_id / is_local 的字典
        """
        import subprocess

        name = agent_name or f"agent-{workspace_id[:8]}"
        local_workspace = self._local_workspace_path(workspace_id)
        try:
            existed = local_workspace.exists()
            if not existed:
                local_workspace.mkdir(parents=True, exist_ok=True)
                # Git 初始化
                subprocess.run(
                    ["git", "init"],
                    cwd=str(local_workspace),
                    capture_output=True,
                    text=True,
                )
                subprocess.run(
                    ["git", "config", "user.name", name],
                    cwd=str(local_workspace),
                    capture_output=True,
                    text=True,
                )
                subprocess.run(
                    ["git", "config", "user.email", f"{name}@agent.local"],
                    cwd=str(local_workspace),
                    capture_output=True,
                    text=True,
                )
                # .self 目录与活动日志
                self_dir = local_workspace / ".self"
                self_dir.mkdir(exist_ok=True)
                (self_dir / "activity.log").write_text(
                    "# Agent 活动日志\n", encoding="utf-8"
                )
                # .self/rule.md 模板
                rule_file = self_dir / "rule.md"
                if not rule_file.exists():
                    rule_template = (
                        "# 工作准则 (rule.md)\n\n"
                        "# 你（agent:{name}）的职责与工作准则\n"
                        "# 请根据你的角色与偏好维护此文件，供系统在初始化或上下文压缩时注入。\n"
                        "# 建议记录：\n"
                        "# - 你的角色定位与擅长领域\n"
                        "# - 协作方式与沟通偏好\n"
                        "# - 需要遵守的团队约定与禁忌\n".format(name=name)
                    )
                    rule_file.write_text(rule_template, encoding="utf-8")
                # 父工作空间 remote（本地模式下指向父工作空间目录）
                if parent_workspace_id:
                    parent_path = self._local_workspace_path(parent_workspace_id)
                    if parent_path.exists():
                        subprocess.run(
                            ["git", "remote", "add", "parent", str(parent_path)],
                            cwd=str(local_workspace),
                            capture_output=True,
                            text=True,
                        )
                logger.info("本地模式：创建本地工作空间: %s", local_workspace)
            return {
                "workspace_id": workspace_id,
                "is_local": True,
                "local_path": str(local_workspace),
                "parent_workspace_id": parent_workspace_id,
                "agent_name": name,
                "created": not existed,
            }
        except Exception as exc:  # noqa: BLE001
            logger.error("本地模式创建工作空间失败: %s", exc)
            return {
                "error": "本地模式创建工作空间失败",
                "detail": str(exc),
            }
    def _init_rule_md(self, container, agent_name: str) -> None:
        """在工作空间中初始化 ``.self/rule.md`` 模板（若不存在）。
        每个 agent 通过维护 rule.md 记录自己的工作准则、偏好与协作方式，
        内容会在初始化或 compact 时注入 normal LLM 系统提示词（checklist 9/10）。
        team leader 有职责提醒 teammates 维护各自的 rule.md。
        """
        rule_template = (
            "# 工作准则 (rule.md)\n\n"
            "# 你（agent:{name}）的职责与工作准则\n"
            "# 请根据你的角色与偏好维护此文件，供系统在初始化或上下文压缩时注入。\n"
            "# 建议记录：\n"
            "# - 你的角色定位与擅长领域\n"
            "# - 协作方式与沟通偏好\n"
            "# - 需要遵守的团队约定与禁忌\n".format(name=agent_name)
        )
        cmd = (
            "cd /workspace && if [ ! -f .self/rule.md ]; then "
            "cat > .self/rule.md << 'RULE_EOF'\n"
            f"{rule_template}RULE_EOF\n"
            "fi"
        )
        # 注意：_exec 内部会包一层 `sh -c <command>`，这里必须传字符串而非列表
        self._exec(container, cmd)
    def _setup_parent_remote(
        self,
        container,
        workspace_id: str,
        parent_workspace_id: str,
    ) -> Dict[str, Any]:
        """配置父 agent 的 git remote 并创建独立分支。
        通过 Docker 默认 bridge 网络获取父容器 IP，在子容器中添加 remote。
        """
        try:
            parent_container = self.client.containers.get(
                self._container_name(parent_workspace_id)
            )
            parent_container.reload()
            networks = parent_container.attrs.get("NetworkSettings", {}).get("Networks", {})
            bridge_info = networks.get("bridge", {})
            parent_ip = bridge_info.get("IPAddress", "")
        except NotFound:
            return {"error": f"父工作空间容器不存在: {parent_workspace_id}"}
        if not parent_ip:
            return {"error": "无法获取父容器 IP 地址"}
        member_id = workspace_id
        remote_url = f"http://{parent_ip}:{self.git_port}/workspace"
        cmd = " && ".join([
            "cd /workspace",
            # 若 remote 已存在则先移除，保证幂等
            "git remote remove parent 2>/dev/null || true",
            f"git remote add parent {remote_url}",
            f"git checkout -b member_{member_id}",
        ])
        return self._exec(container, cmd)
    # ------------------------------------------------------------------
    # Git HTTP 服务与父 agent Git 操作
    # ------------------------------------------------------------------
    def _get_container(self, workspace_id: str):
        """获取工作空间容器；Docker 不可用或容器不存在时返回 (None, error_dict)。
        容器存在但未运行时自动启动（可能因系统重启等原因已停止）。
        在本地模式下始终返回 (None, error)，调用者需要单独处理本地模式。
        """
        if not self._available:
            return None, {"error": "Docker 不可用", "detail": self._unavailable_reason}
        try:
            container = self.client.containers.get(self._container_name_for(workspace_id))
        except NotFound:
            return None, {"error": f"工作空间容器不存在: {workspace_id}"}
        if container.status != "running":
            try:
                container.start()
            except APIError as exc:
                return None, {"error": "启动工作空间容器失败", "detail": str(exc)}
        return container, None
    def _local_git_exec(self, workspace_id: str, command: str) -> Dict[str, Any]:
        """本地模式：在本地工作空间目录下执行 git 命令。
        :param workspace_id: 工作空间标识
        :param command: shell 命令字符串（如 git log --oneline）
        :return: 同 _exec 的格式
        """
        import subprocess
        import sys as _sys

        local_workspace = self._local_workspace_path(workspace_id)
        if not local_workspace.exists():
            return {"error": f"本地工作空间目录不存在: {local_workspace}", "exit_code": -1, "stdout": ""}
        # 确保在 /workspace 目录下执行（等价于 Docker 中的 cd /workspace）
        # 将命令中的 cd /workspace && 替换为无操作
        clean_cmd = command.replace("cd /workspace && ", "")
        try:
            sh_path = self._resolve_sh()
            if _sys.platform == "win32" and sh_path:
                # Windows 上优先使用 Git for Windows 的 sh 执行复合 git 命令
                result = subprocess.run(
                    [sh_path, "-c", clean_cmd],
                    cwd=str(local_workspace),
                    capture_output=True,
                    text=True,
                )
            elif _sys.platform == "win32":
                # Windows 上通过 shell=True 执行
                result = subprocess.run(
                    clean_cmd,
                    cwd=str(local_workspace),
                    capture_output=True,
                    text=True,
                    shell=True,
                )
            else:
                result = subprocess.run(
                    ["sh", "-c", clean_cmd],
                    cwd=str(local_workspace),
                    capture_output=True,
                    text=True,
                )
            return {
                "exit_code": result.returncode,
                "stdout": result.stdout,
                "stderr": result.stderr,
            }
        except Exception as exc:
            return {"error": f"本地模式 git 命令执行失败: {exc}", "exit_code": -1, "stdout": ""}

    def _local_run_sh(
        self, cwd: "os.PathLike", shell_cmd: str, args: List[str]
    ) -> Dict[str, Any]:
        """本地模式：执行 ``sh -c <shell_cmd> [args]``。

        优先使用 PATH 中的 ``sh``（Windows 上 Git for Windows 的 sh.exe）；
        找不到时使用 Python 原生实现常见 POSIX shell 命令。
        """
        import subprocess
        import sys as _sys

        # 检查是否有 sh 可用
        sh_path = self._resolve_sh()
        if sh_path:
            return self._local_run_sh_via_sh(sh_path, cwd, shell_cmd, args)

        # 无 sh 可用：Python 原生 fallback 实现常见命令
        return self._local_run_sh_native(cwd, shell_cmd, args)

    def _local_run_sh_via_sh(
        self, sh_path: str, cwd: "os.PathLike", shell_cmd: str, args: List[str]
    ) -> Dict[str, Any]:
        """通过 sh 执行 shell 命令。"""
        import subprocess
        import sys as _sys

        try:
            # 构建完整的 sh 命令，包含位置参数
            if args:
                result = subprocess.run(
                    [sh_path, "-c", shell_cmd, *args],
                    cwd=str(cwd),
                    capture_output=True,
                    text=True,
                )
            else:
                result = subprocess.run(
                    [sh_path, "-c", shell_cmd],
                    cwd=str(cwd),
                    capture_output=True,
                    text=True,
                )
            return {
                "exit_code": result.returncode,
                "stdout": result.stdout,
                "stderr": result.stderr,
            }
        except Exception as exc:
            return {"error": f"本地模式 shell 执行失败: {exc}", "exit_code": -1, "stdout": ""}

    def _local_run_sh_native(
        self, cwd: "os.PathLike", shell_cmd: str, args: List[str]
    ) -> Dict[str, Any]:
        """无 sh 可用时的 Python 原生 fallback 实现。

        仅支持常见 POSIX shell 命令模式：
        - mkdir -p <dir>
        - cat > file <<'DELIMITER'\ncontent\nDELIMITER  (heredoc 写入)
        - echo <content> > file
        - echo <content> >> file
        - git <subcommand>
        - timeout <seconds> sh -c <cmd>
        """
        import subprocess
        from pathlib import Path

        # 解析位置参数：$1, $2, ...
        # args 形如 ["sh", a, b, c]，其中 args[0] 对应 shell 的 $0（脚本名占位），
        # $1=args[1], $2=args[2], ...
        def _arg(n: int) -> str:
            if n >= 1 and n < len(args):
                return args[n]
            return ""

        # mkdir -p
        if shell_cmd == "mkdir -p $1" and _arg(1):
            (Path(cwd) / _arg(1)).mkdir(parents=True, exist_ok=True)
            return {"exit_code": 0, "stdout": "", "stderr": ""}

        # touch
        if shell_cmd == "touch $1" and _arg(1):
            (Path(cwd) / _arg(1)).touch(exist_ok=True)
            return {"exit_code": 0, "stdout": "", "stderr": ""}

        # mkdir -p && touch
        if shell_cmd.startswith("mkdir -p ") and "&&" in shell_cmd and "touch" in shell_cmd:
            # 解析 mkdir -p DIR && touch FILE
            parts = shell_cmd.split("&&")
            dir_part = parts[0].replace("mkdir -p", "").strip()
            file_part = parts[1].replace("touch", "").strip()
            if dir_part:
                (Path(cwd) / dir_part).mkdir(parents=True, exist_ok=True)
            if file_part:
                (Path(cwd) / file_part).touch(exist_ok=True)
            return {"exit_code": 0, "stdout": "", "stderr": ""}

        # heredoc 写入：cat > FILE <<'DELIM'\nCONTENT\nDELIM
        # 或 echo CONTENT | base64 -d > FILE
        if "cat >" in shell_cmd and "<<'" in shell_cmd:
            return self._local_native_heredoc_write(cwd, shell_cmd)

        # echo CONTENT | base64 -d > FILE
        if "echo " in shell_cmd and "| base64 -d > " in shell_cmd:
            return self._local_native_base64_write(cwd, shell_cmd, _arg)

        # echo CONTENT > FILE
        if "echo " in shell_cmd and " > " in shell_cmd and "|" not in shell_cmd:
            return self._local_native_echo_write(cwd, shell_cmd, ">")

        # echo CONTENT >> FILE
        if "echo " in shell_cmd and " >> " in shell_cmd and "|" not in shell_cmd:
            return self._local_native_echo_write(cwd, shell_cmd, ">>")

        # echo CONTENT | base64 -d >> FILE
        if "echo " in shell_cmd and "| base64 -d >> " in shell_cmd:
            return self._local_native_base64_append(cwd, shell_cmd, _arg)

        # ls -la --time-style=long-iso（文件面板列表）
        if shell_cmd.startswith("ls -la"):
            return self._local_native_ls(cwd, shell_cmd, _arg)

        # git 命令
        if shell_cmd.startswith("git "):
            import shlex
            git_cmd = shlex.split(shell_cmd)
            try:
                result = subprocess.run(
                    git_cmd,
                    cwd=str(cwd),
                    capture_output=True,
                    text=True,
                )
                return {
                    "exit_code": result.returncode,
                    "stdout": result.stdout,
                    "stderr": result.stderr,
                }
            except Exception as exc:
                return {"error": f"git 命令执行失败: {exc}", "exit_code": -1, "stdout": ""}

        # timeout 命令（去除 timeout 前缀，直接执行）
        if shell_cmd.startswith("timeout "):
            import shlex
            # timeout <seconds> sh -c <cmd> 或 timeout <seconds> <cmd>
            parts = shell_cmd.split(" ", 2)
            if len(parts) >= 3:
                inner_cmd = parts[2]
                # 去掉 sh -c 包装
                if inner_cmd.startswith("sh -c "):
                    inner_cmd = inner_cmd[6:]
                try:
                    result = subprocess.run(
                        inner_cmd,
                        cwd=str(cwd),
                        capture_output=True,
                        text=True,
                        shell=True,
                    )
                    return {
                        "exit_code": result.returncode,
                        "stdout": result.stdout,
                        "stderr": result.stderr,
                    }
                except Exception as exc:
                    return {"error": f"timeout 命令执行失败: {exc}", "exit_code": -1, "stdout": ""}

        # 无法原生解析，回退到 cmd.exe / powershell
        try:
            result = subprocess.run(
                shell_cmd,
                cwd=str(cwd),
                capture_output=True,
                text=True,
                shell=True,
            )
            return {
                "exit_code": result.returncode,
                "stdout": result.stdout,
                "stderr": result.stderr,
            }
        except Exception as exc:
            return {"error": f"本地模式命令执行失败: {exc}", "exit_code": -1, "stdout": ""}

    def _local_native_heredoc_write(
        self, cwd: "os.PathLike", shell_cmd: str
    ) -> Dict[str, Any]:
        """Python 原生实现 heredoc 写入：cat > FILE <<'DELIM'\nCONTENT\nDELIM"""
        import re
        from pathlib import Path

        # 解析 cat > FILE <<'DELIM' 或 cat > FILE << 'DELIM'
        m = re.search(r"cat > (.*?) <<\s*'([^']+)'", shell_cmd)
        if not m:
            return {"error": "无法解析 heredoc 命令", "exit_code": 1, "stdout": ""}
        file_path = m.group(1).strip()
        delimiter = m.group(2).strip()
        # 提取内容（在 delimiter 之后、换行后的内容）
        # 兼容 <<'DELIM' 与 << 'DELIM' 两种写法
        content = shell_cmd.split(f"<<'{delimiter}'", 1)
        if len(content) < 2:
            content = shell_cmd.split(f"<< '{delimiter}'", 1)
        if len(content) < 2:
            return {"error": "heredoc 内容格式错误", "exit_code": 1, "stdout": ""}
        content = content[1]
        # 去掉末尾的换行 + delimiter
        if content.endswith(f"\n{delimiter}"):
            content = content[:-(len(delimiter) + 1)]
        elif content.endswith(f"\n{delimiter}\n"):
            content = content[:-(len(delimiter) + 2)]
        # 去掉前导换行
        if content.startswith("\n"):
            content = content[1:]

        full_path = Path(cwd) / file_path
        full_path.parent.mkdir(parents=True, exist_ok=True)
        full_path.write_text(content, encoding="utf-8")
        return {"exit_code": 0, "stdout": "", "stderr": ""}

    def _local_native_base64_write(
        self, cwd: "os.PathLike", shell_cmd: str, _arg
    ) -> Dict[str, Any]:
        """Python 原生实现 echo B64 | base64 -d > FILE"""
        import base64 as _b64, re
        from pathlib import Path

        # echo 'B64' | base64 -d > FILE  或 echo "$1" | base64 -d > "$2"
        m = re.search(r"echo (.+?) \| base64 -d > (.+)", shell_cmd)
        if not m:
            return {"error": "无法解析 base64 写入命令", "exit_code": 1, "stdout": ""}
        b64_src = m.group(1).strip().strip("'\"")
        file_path = m.group(2).strip().strip("'\"")
        # 展开 $1, $2 等位置参数
        if b64_src.startswith("$") and len(b64_src) > 1:
            idx = int(b64_src[1:])
            b64_data = _arg(idx)
        else:
            b64_data = b64_src
        if file_path.startswith("$") and len(file_path) > 1:
            idx = int(file_path[1:])
            file_path = _arg(idx)
        try:
            raw = _b64.b64decode(b64_data)
            full_path = Path(cwd) / file_path
            full_path.parent.mkdir(parents=True, exist_ok=True)
            full_path.write_bytes(raw)
            return {"exit_code": 0, "stdout": "", "stderr": ""}
        except Exception as exc:
            return {"error": f"base64 解码写入失败: {exc}", "exit_code": 1, "stdout": ""}

    def _local_native_base64_append(
        self, cwd: "os.PathLike", shell_cmd: str, _arg
    ) -> Dict[str, Any]:
        """Python 原生实现 echo B64 | base64 -d >> FILE"""
        import base64 as _b64, re
        from pathlib import Path

        m = re.search(r"echo (.+?) \| base64 -d >> (.+)", shell_cmd)
        if not m:
            return {"error": "无法解析 base64 追加命令", "exit_code": 1, "stdout": ""}
        b64_src = m.group(1).strip().strip("'\"")
        file_path = m.group(2).strip().strip("'\"")
        if b64_src.startswith("$") and len(b64_src) > 1:
            idx = int(b64_src[1:])
            b64_data = _arg(idx)
        else:
            b64_data = b64_src
        if file_path.startswith("$") and len(file_path) > 1:
            idx = int(file_path[1:])
            file_path = _arg(idx)
        try:
            raw = _b64.b64decode(b64_data)
            full_path = Path(cwd) / file_path
            full_path.parent.mkdir(parents=True, exist_ok=True)
            with full_path.open("ab") as f:
                f.write(raw)
            return {"exit_code": 0, "stdout": "", "stderr": ""}
        except Exception as exc:
            return {"error": f"base64 解码追加失败: {exc}", "exit_code": 1, "stdout": ""}

    def _local_native_ls(
        self, cwd: "os.PathLike", shell_cmd: str, _arg
    ) -> Dict[str, Any]:
        """Python 原生实现 ``ls -la --time-style=long-iso``。

        输出格式与容器内一致：``perms links owner group size date time name``，
        以便前端 ``_parse_ls_output`` 解析。
        """
        import os as _os
        import time as _time
        from pathlib import Path

        # 解析目标目录：ls -la --time-style=long-iso . 或 ls -la --time-style=long-iso "$1"
        target = "."
        if '"$1"' in shell_cmd:
            target = _arg(1) or "."
        elif shell_cmd.strip().endswith(" ."):
            target = "."
        else:
            # 尝试提取末尾路径（去掉 2>&1 重定向）
            tail = shell_cmd.split("--time-style=long-iso", 1)[-1].strip()
            tail = tail.replace("2>&1", "").strip()
            # 去掉 "$1" 形式的占位（由上方处理）
            if tail and not tail.startswith("$"):
                target = tail.strip("'\"")
        base = Path(cwd) / target
        if not base.exists():
            return {"exit_code": 2, "stdout": "", "stderr": f"ls: cannot access '{target}': No such file or directory"}
        if not base.is_dir():
            # 列出单个文件
            entry = base
            lines = [self._ls_entry(entry)]
        else:
            entries = sorted(base.iterdir(), key=lambda p: p.name.lower())
            # 包含 . 和 .. 两行（与 ls -la 一致）
            lines = [self._ls_entry(base, ".", is_dir=True, mtime=base.stat().st_mtime),
                     self._ls_entry(base.parent, "..", is_dir=True)]
            for entry in entries:
                lines.append(self._ls_entry(entry))
        return {"exit_code": 0, "stdout": "\n".join(lines), "stderr": ""}

    @staticmethod
    def _ls_entry(
        path: "os.PathLike", name: str = "", is_dir: bool = False, mtime: float = 0.0
    ) -> str:
        """构造单行 ls -la --time-style=long-iso 格式输出。"""
        import os as _os
        import time as _time

        p = path
        if not name:
            name = _os.path.basename(str(p)) or "."
        try:
            st = p.stat()
            is_dir = is_dir or _os.path.isdir(str(p))
        except OSError:
            st = None
            is_dir = False
        perms = "drwxr-xr-x" if is_dir else "-rw-r--r--"
        links = "1"
        owner = "user"
        group = "group"
        size = st.st_size if st else 0
        if mtime == 0.0:
            mtime = st.st_mtime if st else 0.0
        tstr = _time.strftime("%Y-%m-%d %H:%M", _time.localtime(mtime))
        return f"{perms} {links} {owner} {group} {size} {tstr} {name}"

    def _local_native_echo_write(
        self, cwd: "os.PathLike", shell_cmd: str, op: str
    ) -> Dict[str, Any]:
        """Python 原生实现 echo CONTENT > FILE 或 echo CONTENT >> FILE"""
        import re
        from pathlib import Path

        pattern = f"echo (.+?) {op} (.+)"
        m = re.search(pattern, shell_cmd)
        if not m:
            return {"error": f"无法解析 echo 命令", "exit_code": 1, "stdout": ""}
        content = m.group(1).strip().strip("'\"")
        file_path = m.group(2).strip().strip("'\"")
        full_path = Path(cwd) / file_path
        full_path.parent.mkdir(parents=True, exist_ok=True)
        mode = "a" if op == ">>" else "w"
        full_path.write_text(content, encoding="utf-8")
        return {"exit_code": 0, "stdout": "", "stderr": ""}

    @staticmethod
    def _is_valid_ref_name(name: str) -> bool:
        """校验 git 引用名，仅允许字母数字、/_-.，防止命令注入。"""
        if not name or len(name) > 200:
            return False
        allowed = set(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/_.-"
        )
        return all(ch in allowed for ch in name)
    def start_git_http_server(self, workspace_id: str) -> Dict[str, Any]:
        """在指定工作空间容器内启动 Git HTTP daemon，使其可被子 agent push。
        使用 ``git daemon`` 启动 HTTP 服务，监听 ``self.git_port``，
        并通过 ``--enable=receive-pack`` 允许 push 操作。后台运行并重定向输出，
        避免 ``exec_run`` 阻塞。
        本地模式：不需要 Git HTTP daemon，返回成功（子 agent 直接使用本地 git）。
        """
        if self._use_local():
            # 本地模式：不需要 daemon，返回成功
            return {
                "workspace_id": workspace_id,
                "git_port": self.git_port,
                "exit_code": 0,
                "started": True,
                "is_local": True,
            }
        container, err = self._get_container(workspace_id)
        if err:
            return err
        # 后台启动 git daemon，重定向输出避免 exec_run 阻塞
        cmd = (
            "cd /workspace && "
            f"git daemon --reuseaddr --base-path=/workspace --export-all "
            f"--enable=receive-pack --listen=0.0.0.0 --port={self.git_port} "
            ">/tmp/git-daemon.log 2>&1 &"
        )
        result = self._exec(container, cmd)
        exit_code = result["exit_code"]
        return {
            "workspace_id": workspace_id,
            "git_port": self.git_port,
            "exit_code": exit_code,
            "started": exit_code == 0,
            "is_local": False,
        }
    def git_fetch(self, workspace_id: str, remote: str = "parent") -> Dict[str, Any]:
        """在指定工作空间执行 ``git fetch {remote}``，拉取远程分支。"""
        if self._use_local():
            # 本地模式：直接在本地目录执行
            if not self._is_valid_ref_name(remote):
                return {"error": "非法 remote 名称", "remote": remote}
            result = self._local_git_exec(
                workspace_id,
                f"cd /workspace && git fetch {remote}",
            )
            if "error" in result:
                return result
            return {
                "exit_code": result["exit_code"],
                "output": result["stdout"],
                "remote": remote,
            }
        container, err = self._get_container(workspace_id)
        if err:
            return err
        if not self._is_valid_ref_name(remote):
            return {"error": "非法 remote 名称", "remote": remote}
        result = self._exec(
            container,
            f"cd /workspace && git fetch {remote}",
        )
        return {
            "exit_code": result["exit_code"],
            "output": result["stdout"],
            "remote": remote,
        }
    def git_diff(self, workspace_id: str, branch: str) -> Dict[str, Any]:
        """查看子 agent 分支与主分支的差异：``git diff main...{branch}``。"""
        if self._use_local():
            # 本地模式：直接在本地目录执行
            if not self._is_valid_ref_name(branch):
                return {"error": "非法分支名", "branch": branch}
            result = self._local_git_exec(
                workspace_id,
                f"cd /workspace && git diff main...{branch}",
            )
            if "error" in result:
                return result
            return {
                "diff": result["stdout"],
                "exit_code": result["exit_code"],
            }
        container, err = self._get_container(workspace_id)
        if err:
            return err
        if not self._is_valid_ref_name(branch):
            return {"error": "非法分支名", "branch": branch}
        result = self._exec(
            container,
            f"cd /workspace && git diff main...{branch}",
        )
        return {
            "diff": result["stdout"],
            "exit_code": result["exit_code"],
        }
    def git_merge(self, workspace_id: str, branch: str) -> Dict[str, Any]:
        """合并子 agent 分支到当前分支：``git merge {branch}``。
        返回合并结果（成功/冲突），非零退出码视为冲突。
        """
        if self._use_local():
            # 本地模式：直接在本地目录执行
            if not self._is_valid_ref_name(branch):
                return {"error": "非法分支名", "branch": branch}
            result = self._local_git_exec(
                workspace_id,
                f"cd /workspace && git merge {branch}",
            )
            if "error" in result:
                return result
            exit_code = result["exit_code"]
            output = result["stdout"].strip()
            success = exit_code == 0
            message = output or ("合并成功" if success else "合并失败，可能存在冲突")
            return {
                "success": success,
                "message": message,
                "exit_code": exit_code,
                "conflict": not success,
            }
        container, err = self._get_container(workspace_id)
        if err:
            return err
        if not self._is_valid_ref_name(branch):
            return {"error": "非法分支名", "branch": branch}
        result = self._exec(
            container,
            f"cd /workspace && git merge {branch}",
        )
        exit_code = result["exit_code"]
        output = result["stdout"].strip()
        success = exit_code == 0
        message = output or ("合并成功" if success else "合并失败，可能存在冲突")
        return {
            "success": success,
            "message": message,
            "exit_code": exit_code,
            "conflict": not success,
        }
    def git_log(self, workspace_id: str, limit: int = 50) -> Dict[str, Any]:
        """查看提交历史：``git log --all -n {limit}``，返回结构化提交列表。

        每条提交 ``{"hash", "author", "date", "message"}``，与前端 Git 历史面板
        的解析字段保持一致（前端按 hash/author/date/message 候选键取值）。
        """
        # 限制 limit 范围，防止异常输入
        safe_limit = max(1, min(int(limit), 1000))
        pretty = "--pretty=format:%H%x1f%an%x1f%aI%x1f%s"
        if self._use_local():
            # 本地模式：直接在本地目录执行
            result = self._local_git_exec(
                workspace_id,
                f"cd /workspace && git log --all -n {safe_limit} {pretty}",
            )
            if "error" in result:
                return result
            return {
                "commits": self._parse_git_log_commits(result["stdout"]),
                "exit_code": result["exit_code"],
            }
        container, err = self._get_container(workspace_id)
        if err:
            return err
        result = self._exec(
            container,
            f"cd /workspace && git log --all -n {safe_limit} {pretty}",
        )
        return {
            "commits": self._parse_git_log_commits(result["stdout"]),
            "exit_code": result["exit_code"],
        }

    @staticmethod
    def _parse_git_log_commits(stdout: str) -> List[Dict[str, str]]:
        """解析 ``git log --pretty=format:%H%x1f%an%x1f%aI%x1f%s`` 输出。

        字段以单位分隔符（``0x1f``）分隔，避免提交信息中出现空格/管道符干扰解析。
        """
        commits: List[Dict[str, str]] = []
        for line in (stdout or "").splitlines():
            parts = line.split("\x1f")
            commits.append(
                {
                    "hash": parts[0].strip() if len(parts) > 0 else "",
                    "author": parts[1].strip() if len(parts) > 1 else "",
                    "date": parts[2].strip() if len(parts) > 2 else "",
                    "message": parts[3].strip() if len(parts) > 3 else "",
                }
            )
        return commits
    def git_branches(self, workspace_id: str) -> Dict[str, Any]:
        """查看所有分支：``git branch -a``。"""
        if self._use_local():
            # 本地模式：直接在本地目录执行
            result = self._local_git_exec(workspace_id, "cd /workspace && git branch -a")
            if "error" in result:
                return result
            branches: List[str] = []
            current = ""
            for line in result["stdout"].splitlines():
                stripped = line.strip()
                if not stripped:
                    continue
                if stripped.startswith("* "):
                    current = stripped[2:].strip()
                    branches.append(current)
                else:
                    branches.append(stripped)
            return {
                "branches": branches,
                "current": current,
                "exit_code": result["exit_code"],
            }
        container, err = self._get_container(workspace_id)
        if err:
            return err
        result = self._exec(container, "cd /workspace && git branch -a")
        branches: List[str] = []
        current = ""
        for line in result["stdout"].splitlines():
            stripped = line.strip()
            if not stripped:
                continue
            if stripped.startswith("* "):
                current = stripped[2:].strip()
                branches.append(current)
            else:
                branches.append(stripped)
        return {
            "branches": branches,
            "current": current,
            "exit_code": result["exit_code"],
        }
    def stop_workspace(self, workspace_id: str) -> Dict[str, Any]:
        """停止工作空间容器但保留卷。
        本地模式下无需操作，直接返回成功；共享成员不得停止顶层 agent 容器。
        """
        if self._use_local():
            # 本地模式：无需停止
            return {"workspace_id": workspace_id, "status": "stopped", "is_local": True}
        if self.is_shared(workspace_id):
            # 共享成员：容器归顶层 agent 所有，不可单独停止
            return {
                "workspace_id": workspace_id,
                "status": "running",
                "is_shared": True,
            }
        try:
            container = self.client.containers.get(self._container_name(workspace_id))
            container.stop()
            return {"workspace_id": workspace_id, "status": "stopped", "is_local": False}
        except NotFound:
            return {"workspace_id": workspace_id, "status": "removed", "is_local": False}
        except (APIError, Exception) as exc:  # noqa: BLE001
            return {"error": "停止工作空间失败", "detail": str(exc)}
    def remove_workspace(self, workspace_id: str) -> Dict[str, Any]:
        """删除工作空间容器但保留卷（可手动清理）。
        本地模式下删除整个本地目录；共享成员仅取消共享注册，不删除顶层容器。
        """
        if self._use_local():
            # 本地模式：删除本地目录
            import shutil

            local_workspace = self._local_workspace_path(workspace_id)
            if local_workspace.exists():
                try:
                    shutil.rmtree(local_workspace)
                    logger.info("本地模式：删除工作空间目录: %s", local_workspace)
                except Exception as exc:
                    return {"error": "本地模式删除工作空间失败", "detail": str(exc)}
            return {"workspace_id": workspace_id, "status": "removed", "is_local": True}
        if self.is_shared(workspace_id):
            # 共享成员：仅取消共享注册，共享容器与主工作区保留
            self.unregister_shared_workspace(workspace_id)
            return {
                "workspace_id": workspace_id,
                "status": "removed",
                "is_shared": True,
            }
        try:
            container = self.client.containers.get(self._container_name(workspace_id))
            # 容器可能仍在运行，先停止再删除
            try:
                container.stop()
            except Exception:  # noqa: BLE001
                pass
            container.remove()
            return {"workspace_id": workspace_id, "status": "removed", "is_local": False}
        except NotFound:
            return {"workspace_id": workspace_id, "status": "removed", "is_local": False}
        except (APIError, Exception) as exc:  # noqa: BLE001
            return {"error": "删除工作空间失败", "detail": str(exc)}
    def get_workspace_status(self, workspace_id: str) -> Dict[str, Any]:
        """返回工作空间容器状态（running / stopped / removed）。
        本地模式下返回本地目录的状态。
        """
        if self._use_local():
            # 本地模式：检查本地工作空间目录是否存在
            local_workspace = self._local_workspace_path(workspace_id)
            if local_workspace.exists():
                return {
                    "workspace_id": workspace_id,
                    "status": "running",  # 本地模式一直视为运行中
                    "is_local": True,
                }
            else:
                return {
                    "workspace_id": workspace_id,
                    "status": "removed",
                    "is_local": True,
                }
        try:
            container = self.client.containers.get(self._container_name_for(workspace_id))
            container.reload()
            # container.status: "created" / "running" / "exited" / "paused" 等
            raw_status = container.status or "unknown"
            if raw_status == "running":
                status = "running"
            elif raw_status in ("exited", "created", "paused"):
                status = "stopped"
            else:
                status = raw_status
            return {
                "workspace_id": workspace_id,
                "container_id": container.id,
                "status": status,
                "volume_name": self._volume_name(self.get_container_owner(workspace_id)),
                "is_local": False,
                "is_shared": self.is_shared(workspace_id),
                "shared_with": self._shared_owner.get(workspace_id, ""),
            }
        except NotFound:
            return {
                "workspace_id": workspace_id,
                "status": "removed",
                "is_local": False,
            }
        except (APIError, Exception) as exc:  # noqa: BLE001
            return {"error": "查询工作空间状态失败", "detail": str(exc)}
    def ensure_workspace(self, workspace_id: str) -> Dict[str, Any]:
        """确保工作空间容器存在，不存在时自动创建。
        用于兼容历史 agent 数据（数据库中记录了 workspace_id 但容器从未创建），
        首次访问时补建容器。
        本地模式下确保本地目录存在。
        :param workspace_id: 工作空间唯一标识
        :return: 容器已存在返回 {"created": False}；创建成功返回
                 {"created": True, ...}；失败返回含 "error" 字段的字典
        """
        if self._use_local():
            # 本地模式：确保本地目录存在
            import subprocess

            local_workspace = self._local_workspace_path(workspace_id)
            if local_workspace.exists():
                return {"created": False, "is_local": True}
            # 不存在则创建目录并初始化 git
            local_workspace.mkdir(parents=True, exist_ok=True)
            init_cmd = ["git", "init"]
            result = subprocess.run(
                init_cmd,
                cwd=str(local_workspace),
                capture_output=True,
                text=True,
            )
            subprocess.run(
                ["git", "config", "user.name", "local-agent"],
                cwd=str(local_workspace),
                capture_output=True,
                text=True,
            )
            subprocess.run(
                ["git", "config", "user.email", "local-agent@agent.local"],
                cwd=str(local_workspace),
                capture_output=True,
                text=True,
            )
            (local_workspace / ".self").mkdir(exist_ok=True)
            (local_workspace / ".self" / "activity.log").write_text(
                "# Agent 活动日志\n", encoding="utf-8"
            )
            logger.info("本地模式：自动确保工作空间目录存在: %s", local_workspace)
            return {"created": True, "is_local": True, "workspace_id": workspace_id}
        try:
            self.client.containers.get(self._container_name_for(workspace_id))
            return {"created": False, "is_local": False, "is_shared": self.is_shared(workspace_id)}
        except NotFound:
            # 共享成员：补建其所属顶层 agent 的容器（成员自身不持有容器）
            create_target = self.get_container_owner(workspace_id)
            result = self.create_workspace(create_target)
            result["created"] = "error" not in result
            result["is_local"] = False
            return result
    def exec_in_workspace(
        self, workspace_id: str, command: List[str]
    ) -> Dict[str, Any]:
        """在工作空间容器内执行命令，返回 stdout / exit_code。
        :param command: 命令及其参数列表，如 ``["git", "status"]``
        Docker 不可用时，降级为直接在本地工作空间目录执行。
        """
        if self._use_local():
            # 本地模式（或 Docker 不可用）：直接在用户选择目录下执行命令
            import subprocess
            import os

            # 本地工作空间目录位于用户选择的工作目录下
            local_workspace = self._local_workspace_path(workspace_id)
            if not local_workspace.exists():
                # 自动创建工作空间目录
                local_workspace.mkdir(parents=True, exist_ok=True)
                # 初始化 git
                subprocess.run(
                    ["git", "init"],
                    cwd=str(local_workspace),
                    capture_output=True,
                    text=True,
                )
                subprocess.run(
                    ["git", "config", "user.name", "local-agent"],
                    cwd=str(local_workspace),
                    capture_output=True,
                    text=True,
                )
                subprocess.run(
                    ["git", "config", "user.email", "local-agent@agent.local"],
                    cwd=str(local_workspace),
                    capture_output=True,
                    text=True,
                )
                (local_workspace / ".self").mkdir(exist_ok=True)
                (local_workspace / ".self" / "activity.log").write_text(
                    "# Agent 活动日志\n", encoding="utf-8"
                )
                logger.info("本地模式：自动创建工作空间目录: %s", local_workspace)

            # 执行命令 — 处理 "cat" 读取文件的场景
            try:
                if len(command) == 1 and command[0] == "cat":
                    # 纯 "cat" 无参数，返回空
                    return {"exit_code": 0, "stdout": "", "stderr": ""}
                if len(command) >= 2 and command[0] == "cat":
                    # cat 文件：直接从本地文件读取
                    file_path = command[1]
                    # 确保路径在工作空间内，防止路径穿越
                    safe_path = file_path.lstrip("/")
                    if safe_path.startswith("workspace/"):
                        safe_path = safe_path[len("workspace/"):]
                    abs_path = local_workspace / safe_path
                    try:
                        content = abs_path.read_text(encoding="utf-8", errors="replace")
                        return {"exit_code": 0, "stdout": content, "stderr": ""}
                    except FileNotFoundError:
                        return {"exit_code": 1, "stdout": "", "stderr": f"文件不存在: {file_path}"}
                    except Exception as exc:
                        return {"exit_code": 1, "stdout": "", "stderr": str(exc)}

                if len(command) >= 3 and command[0] == "sh" and command[1] == "-c":
                    shell_cmd = command[2]
                    # 位置参数（如 "sh" 脚本名 + 各参数）
                    args = list(command[3:])
                    # base64 编码命令模式：base64 "$1" 2>/dev/null
                    if shell_cmd.startswith("base64 ") or (
                        "base64" in shell_cmd and "tar" not in shell_cmd
                        and ">" not in shell_cmd and ">>" not in shell_cmd
                    ):
                        # 提取文件路径参数（command[3] 是 "sh"，command[4] 是路径）
                        file_arg = command[4] if len(command) >= 5 else ""
                        if file_arg:
                            safe_path = file_arg.lstrip("/")
                            if safe_path.startswith("workspace/"):
                                safe_path = safe_path[len("workspace/"):]
                            abs_path = local_workspace / safe_path
                            if abs_path.exists():
                                import base64 as _b64
                                data = abs_path.read_bytes()
                                b64_str = _b64.b64encode(data).decode("ascii")
                                return {"exit_code": 0, "stdout": b64_str, "stderr": ""}
                            else:
                                return {"exit_code": 1, "stdout": "", "stderr": f"文件不存在: {file_arg}"}
                        return {"exit_code": 1, "stdout": "", "stderr": "base64 命令缺少文件路径"}
                    if "tar" in shell_cmd and "echo" not in shell_cmd and ">" not in shell_cmd:
                        # tar 打包命令：使用 Python 的 tarfile 实现
                        import tarfile, io, base64 as _b642
                        # 排除 .git 目录
                        buf = io.BytesIO()
                        with tarfile.open(fileobj=buf, mode="w") as tar:
                            for item in local_workspace.rglob("*"):
                                if ".git" in item.parts:
                                    continue
                                rel = item.relative_to(local_workspace)
                                try:
                                    tar.add(str(item), arcname=str(rel))
                                except Exception:
                                    pass
                        buf.seek(0)
                        b64_str = _b642.b64encode(buf.read()).decode("ascii")
                        return {"exit_code": 0, "stdout": b64_str, "stderr": ""}
                    # 其他 sh -c 命令：交由本地 shell 解析器处理
                    return self._local_run_sh(
                        local_workspace, shell_cmd, args
                    )

                # 其他命令列表
                result = subprocess.run(
                    command,
                    cwd=str(local_workspace),
                    capture_output=True,
                    text=True,
                )
                return {
                    "exit_code": result.returncode,
                    "stdout": result.stdout,
                    "stderr": result.stderr,
                }
            except Exception as exc:
                return {
                    "error": "本地模式执行命令失败",
                    "detail": str(exc),
                    "exit_code": -1,
                }
        # 共享成员：将命令中的 .self 路径令牌重写为私人子目录 workspaces/{id}/.self，
        # 并把容器解析到所属顶层 agent 的共享容器（主工作区 /workspace）
        if self.is_shared(workspace_id):
            command = [
                self._rewrite_private_tokens(workspace_id, c) for c in command
            ]
        try:
            container = self.client.containers.get(self._container_name_for(workspace_id))
        except NotFound:
            # 容器不存在：自动补建（共享成员补建其所属顶层 agent 容器）
            created = self.ensure_workspace(workspace_id)
            if "error" in created:
                return {
                    "error": created["error"],
                    "detail": created.get("detail", ""),
                    "exit_code": -1,
                }
            try:
                container = self.client.containers.get(
                    self._container_name_for(workspace_id)
                )
            except NotFound:
                return {
                    "error": f"工作空间无法创建: {workspace_id}",
                    "exit_code": -1,
                }
        # 确保容器处于运行状态（可能因系统重启等原因已停止）
        if container.status != "running":
            try:
                container.start()
            except APIError as exc:
                return {
                    "error": "启动工作空间容器失败",
                    "detail": str(exc),
                    "exit_code": -1,
                }
        try:
            result = container.exec_run(command, workdir="/workspace")
            exit_code = int(result.exit_code)
            output = result.output
            if isinstance(output, bytes):
                output = output.decode("utf-8", errors="replace")
            return {
                "exit_code": exit_code,
                "stdout": output,
                "stderr": "",
            }
        except (APIError, Exception) as exc:  # noqa: BLE001
            return {
                "error": "执行命令失败",
                "detail": str(exc),
                "exit_code": -1,
            }
    def write_file(
        self, workspace_id: str, container_path: str, data: bytes
    ) -> Dict[str, Any]:
        """将文件内容写入工作空间容器内指定路径（自动创建父目录）。
        支持任意二进制内容与任意大小：通过 ``put_archive`` 流式写入，
        避免把内容 base64 塞进 exec 命令行（超过 4MB 会触发 ResourceExhausted）。
        :param workspace_id: 工作空间标识
        :param container_path: 容器内绝对路径（相对 /workspace 的路径亦可）
        :param data: 待写入的文件字节内容
        :return: ``{"exit_code": 0, "stdout": ...}`` 或在失败时带 ``error``
        """
        if self._use_local():
            # 本地模式（或 Docker 不可用）：直接在用户选择目录下写入文件
            local_workspace = self._local_workspace_path(workspace_id)
            local_workspace.mkdir(parents=True, exist_ok=True)
            # 统一为相对路径
            rel = container_path.lstrip("/")
            if rel.startswith("workspace/"):
                rel = rel[len("workspace/"):]
            local_path = local_workspace / rel
            # 自动创建父目录
            local_path.parent.mkdir(parents=True, exist_ok=True)
            try:
                local_path.write_bytes(data)
                return {"exit_code": 0, "stdout": "", "stderr": ""}
            except Exception as exc:
                return {
                    "error": "本地模式写入文件失败",
                    "detail": str(exc),
                    "exit_code": -1,
                }
        # 共享成员：将 .self 私人路径路由到共享容器内 workspaces/{id}/.self
        if self.is_shared(workspace_id):
            container_path = self.resolve_private_path(workspace_id, container_path)
        try:
            container = self.client.containers.get(self._container_name_for(workspace_id))
        except NotFound:
            # 容器不存在：自动补建（共享成员补建其所属顶层 agent 容器）
            created = self.ensure_workspace(workspace_id)
            if "error" in created:
                return {
                    "error": created["error"],
                    "detail": created.get("detail", ""),
                    "exit_code": -1,
                }
            try:
                container = self.client.containers.get(
                    self._container_name_for(workspace_id)
                )
            except NotFound:
                return {
                    "error": f"工作空间无法创建: {workspace_id}",
                    "exit_code": -1,
                }
        # 统一为容器内绝对路径（相对路径以 /workspace 为根）
        rel = container_path.lstrip("/")
        if not rel.startswith("workspace/"):
            rel = f"workspace/{rel}"
        abs_path = f"/{rel}"
        dirname = abs_path.rsplit("/", 1)[0]
        basename = rel.rsplit("/", 1)[-1]
        try:
            # 先确保父目录存在（put_archive 不会自动创建目标目录）
            mkdir = container.exec_run(["sh", "-c", f"mkdir -p '{dirname}'"])
            if int(mkdir.exit_code) != 0:
                return {
                    "error": "创建父目录失败",
                    "exit_code": int(mkdir.exit_code),
                    "stdout": "",
                }
            # 流式写入 tar，避免命令行长度限制
            ok = container.put_archive(
                dirname, _make_tar_bytes(basename, data)
            )
            return {"exit_code": 0 if ok else 1, "stdout": "", "stderr": ""}
        except (APIError, Exception) as exc:  # noqa: BLE001
            return {
                "error": "写入文件失败",
                "detail": str(exc),
                "exit_code": -1,
            }

def _egress_proxy_env() -> Dict[str, str]:
    """返回容器 http/https 代理环境变量（指向本地下载代理，checklist 14）。

    回环地址（git 父仓库 http 服务等）经 ``no_proxy`` 排除，不走代理。
    """
    proxy = "http://127.0.0.1:3128"
    no_proxy = "127.0.0.1,localhost"
    return {
        "http_proxy": proxy,
        "https_proxy": proxy,
        "HTTP_PROXY": proxy,
        "HTTPS_PROXY": proxy,
        "no_proxy": no_proxy,
        "NO_PROXY": no_proxy,
    }


def _build_egress_proxy_src(max_bytes: int, whitelist: List[str]) -> str:
    """生成出站代理脚本源码（限制单次下载数据量 + 白名单主机校验）。

    代理同时承担 checklist 13 的白名单校验与 checklist 14 的单次下载上限，
    返回供写入容器的完整 Python 源码。
    """
    whitelist_literal = repr(whitelist)
    return (
        "import socket, threading\n"
        f"LIMIT = {max_bytes}\n"
        f"LISTEN_HOST = '127.0.0.1'\n"
        f"LISTEN_PORT = 3128\n"
        f"WHITELIST = {whitelist_literal}\n"
        "\n"
        "def _allowed(host):\n"
        "    host = host.strip().lower()\n"
        "    if host.startswith('['):\n"
        "        host = host.split(']')[-1]\n"
        "    host = host.split(':')[0]\n"
        "    for w in WHITELIST:\n"
        "        w = w.strip().lower()\n"
        "        if w == host:\n"
        "            return True\n"
        "        if w.startswith('*.') and host.endswith(w[1:]):\n"
        "            return True\n"
        "    return False\n"
        "\n"
        "def _copy(src, dst, counter, cap):\n"
        "    try:\n"
        "        while True:\n"
        "            data = src.recv(65536)\n"
        "            if not data:\n"
        "                break\n"
        "            counter[0] += len(data)\n"
        "            if counter[0] > cap:\n"
        "                # 单次下载超过上限：截断并断开\n"
        "                space = cap - (counter[0] - len(data))\n"
        "                if space > 0:\n"
        "                    dst.sendall(data[:space])\n"
        "                break\n"
        "            dst.sendall(data)\n"
        "    except Exception:\n"
        "        pass\n"
        "    finally:\n"
        "        try:\n"
        "            dst.shutdown(socket.SHUT_WR)\n"
        "        except Exception:\n"
        "            pass\n"
        "\n"
        "def _handle(client):\n"
        "    try:\n"
        "        client.settimeout(60)\n"
        "        buf = b''\n"
        "        while b'\\r\\n\\r\\n' not in buf:\n"
        "            chunk = client.recv(4096)\n"
        "            if not chunk:\n"
        "                break\n"
        "            buf += chunk\n"
        "            if len(buf) > 65536:\n"
        "                break\n"
        "        if not buf:\n"
        "            client.close(); return\n"
        "        head = buf.split(b'\\r\\n\\r\\n', 1)[0]\n"
        "        lines = head.split(b'\\r\\n')\n"
        "        parts = lines[0].decode('latin-1', 'replace').split(' ')\n"
        "        if not parts:\n"
        "            client.close(); return\n"
        "        method = parts[0].upper()\n"
        "        target = parts[1] if len(parts) > 1 else ''\n"
        "        headers = {}\n"
        "        for ln in lines[1:]:\n"
        "            if b':' in ln:\n"
        "                k, v = ln.split(b':', 1)\n"
        "                headers[k.decode('latin-1').strip().lower()] = v.decode('latin-1').strip()\n"
        "        if method == 'CONNECT':\n"
        "            hp, _, port = target.partition(':')\n"
        "            port = int(port or 443)\n"
        "            if not _allowed(hp):\n"
        "                client.sendall(b'HTTP/1.1 403 Forbidden\\r\\n\\r\\n')\n"
        "                client.close(); return\n"
        "            try:\n"
        "                up = socket.create_connection((hp, port), timeout=30)\n"
        "            except Exception:\n"
        "                client.sendall(b'HTTP/1.1 502 Bad Gateway\\r\\n\\r\\n')\n"
        "                client.close(); return\n"
        "            client.sendall(b'HTTP/1.1 200 Connection established\\r\\n\\r\\n')\n"
        "        else:\n"
        "            if target.startswith('http://'):\n"
        "                rest = target[len('http://'):]\n"
        "                hp, _, path = rest.partition('/')\n"
        "                path = '/' + path\n"
        "                host, _, port = hp.partition(':')\n"
        "                port = int(port or 80)\n"
        "            else:\n"
        "                host, _, port = headers.get('host', '').partition(':')\n"
        "                port = int(port or 80)\n"
        "                path = target\n"
        "            if not _allowed(headers.get('host', host).split(':')[0]):\n"
        "                client.sendall(b'HTTP/1.1 403 Forbidden\\r\\n\\r\\n')\n"
        "                client.close(); return\n"
        "            try:\n"
        "                up = socket.create_connection((host, port), timeout=30)\n"
        "            except Exception:\n"
        "                client.sendall(b'HTTP/1.1 502 Bad Gateway\\r\\n\\r\\n')\n"
        "                client.close(); return\n"
        "            req = (method + ' ' + path + ' HTTP/1.1\\r\\n').encode('latin-1')\n"
        "            for k, v in headers.items():\n"
        "                if k in ('proxy-connection', 'proxy-authorization'):\n"
        "                    continue\n"
        "                req += (k + ': ' + v + '\\r\\n').encode('latin-1')\n"
        "            req += b'\\r\\n'\n"
        "            body = buf.split(b'\\r\\n\\r\\n', 1)[1] if b'\\r\\n\\r\\n' in buf else b''\n"
        "            up.sendall(req + body)\n"
        "        # 上行（客户端→服务器）不设下载上限；下行（下载方向）单独计数\n"
        "        up_ct = [0]\n"
        "        down_ct = [0]\n"
        "        t1 = threading.Thread(target=_copy, args=(client, up, up_ct, 10**18), daemon=True)\n"
        "        t2 = threading.Thread(target=_copy, args=(up, client, down_ct, LIMIT), daemon=True)\n"
        "        t1.start(); t2.start(); t1.join(); t2.join()\n"
        "    except Exception:\n"
        "        pass\n"
        "    finally:\n"
        "        try:\n"
        "            client.close()\n"
        "        except Exception:\n"
        "            pass\n"
        "\n"
        "def _main():\n"
        "    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)\n"
        "    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\n"
        "    srv.bind((LISTEN_HOST, LISTEN_PORT))\n"
        "    srv.listen(128)\n"
        "    while True:\n"
        "        c, _ = srv.accept()\n"
        "        threading.Thread(target=_handle, args=(c,), daemon=True).start()\n"
        "\n"
        "if __name__ == '__main__':\n"
        "    _main()\n"
    )