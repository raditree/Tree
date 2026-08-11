"""Docker 工作空间管理 - 容器创建/停止/删除与卷管理。"""
import base64
import logging
import shlex
from typing import Any, Dict, List, Optional
from core.config import get_config
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
class DockerManager:
    """管理 agent 工作空间容器与持久化卷的生命周期。"""
    def __init__(self) -> None:
        """初始化 docker client，读取配置中的镜像与资源限制。
        若 Docker 未安装或 daemon 未运行，标记为不可用而非抛出异常，
        后续调用各方法时优雅降级。
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
    @property
    def available(self) -> bool:
        """Docker daemon 是否可用。"""
        return self._available
    # ------------------------------------------------------------------
    # 内部工具方法
    # ------------------------------------------------------------------
    @staticmethod
    def _volume_name(workspace_id: str) -> str:
        """工作空间对应的 volume 名称。"""
        return f"workspace_{workspace_id}"
    @staticmethod
    def _container_name(workspace_id: str) -> str:
        """工作空间对应的容器名称。"""
        return f"workspace_{workspace_id}"
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
    ) -> Dict[str, Any]:
        """创建工作空间容器并完成 Git 初始化。
        :param workspace_id: 工作空间唯一标识
        :param parent_workspace_id: 父工作空间标识，存在时配置父 agent git remote
        :param agent_name: agent 名称，用于 git user 配置；缺省时从 workspace_id 派生
        :return: 包含 workspace_id / container_id / volume_name 的字典；
                 Docker 不可用时返回 error 字段
        """
        if not self._available:
            return {
                "error": "Docker 不可用",
                "detail": self._unavailable_reason,
            }
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
        """获取工作空间容器；Docker 不可用或容器不存在时返回 (None, error_dict)。"""
        if not self._available:
            return None, {"error": "Docker 不可用", "detail": self._unavailable_reason}
        try:
            container = self.client.containers.get(self._container_name(workspace_id))
            return container, None
        except NotFound:
            return None, {"error": f"工作空间容器不存在: {workspace_id}"}
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
        """
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
        }
    def git_fetch(self, workspace_id: str, remote: str = "parent") -> Dict[str, Any]:
        """在指定工作空间执行 ``git fetch {remote}``，拉取远程分支。"""
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
        """查看提交历史：``git log --oneline --all -n {limit}``。"""
        container, err = self._get_container(workspace_id)
        if err:
            return err
        # 限制 limit 范围，防止异常输入
        safe_limit = max(1, min(int(limit), 1000))
        result = self._exec(
            container,
            f"cd /workspace && git log --oneline --all -n {safe_limit}",
        )
        commits = [
            line.strip()
            for line in result["stdout"].splitlines()
            if line.strip()
        ]
        return {
            "commits": commits,
            "exit_code": result["exit_code"],
        }
    def git_branches(self, workspace_id: str) -> Dict[str, Any]:
        """查看所有分支：``git branch -a``。"""
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
        """停止工作空间容器但保留卷。"""
        if not self._available:
            return {"error": "Docker 不可用", "detail": self._unavailable_reason}
        try:
            container = self.client.containers.get(self._container_name(workspace_id))
            container.stop()
            return {"workspace_id": workspace_id, "status": "stopped"}
        except NotFound:
            return {"workspace_id": workspace_id, "status": "removed"}
        except (APIError, Exception) as exc:  # noqa: BLE001
            return {"error": "停止工作空间失败", "detail": str(exc)}
    def remove_workspace(self, workspace_id: str) -> Dict[str, Any]:
        """删除工作空间容器但保留卷（可手动清理）。"""
        if not self._available:
            return {"error": "Docker 不可用", "detail": self._unavailable_reason}
        try:
            container = self.client.containers.get(self._container_name(workspace_id))
            # 容器可能仍在运行，先停止再删除
            try:
                container.stop()
            except Exception:  # noqa: BLE001
                pass
            container.remove()
            return {"workspace_id": workspace_id, "status": "removed"}
        except NotFound:
            return {"workspace_id": workspace_id, "status": "removed"}
        except (APIError, Exception) as exc:  # noqa: BLE001
            return {"error": "删除工作空间失败", "detail": str(exc)}
    def get_workspace_status(self, workspace_id: str) -> Dict[str, Any]:
        """返回工作空间容器状态（running / stopped / removed）。"""
        if not self._available:
            return {"error": "Docker 不可用", "detail": self._unavailable_reason}
        try:
            container = self.client.containers.get(self._container_name(workspace_id))
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
                "volume_name": self._volume_name(workspace_id),
            }
        except NotFound:
            return {
                "workspace_id": workspace_id,
                "status": "removed",
            }
        except (APIError, Exception) as exc:  # noqa: BLE001
            return {"error": "查询工作空间状态失败", "detail": str(exc)}
    def ensure_workspace(self, workspace_id: str) -> Dict[str, Any]:
        """确保工作空间容器存在，不存在时自动创建。
        用于兼容历史 agent 数据（数据库中记录了 workspace_id 但容器从未创建），
        首次访问时补建容器。
        :param workspace_id: 工作空间唯一标识
        :return: 容器已存在返回 {"created": False}；创建成功返回
                 {"created": True, ...}；失败返回含 "error" 字段的字典
        """
        if not self._available:
            return {
                "created": False,
                "error": "Docker 不可用",
                "detail": self._unavailable_reason,
            }
        try:
            self.client.containers.get(self._container_name(workspace_id))
            return {"created": False}
        except NotFound:
            result = self.create_workspace(workspace_id)
            result["created"] = "error" not in result
            return result
    def exec_in_workspace(
        self, workspace_id: str, command: List[str]
    ) -> Dict[str, Any]:
        """在工作空间容器内执行命令，返回 stdout / exit_code。
        :param command: 命令及其参数列表，如 ``["git", "status"]``
        """
        if not self._available:
            return {"error": "Docker 不可用", "detail": self._unavailable_reason}
        try:
            container = self.client.containers.get(self._container_name(workspace_id))
        except NotFound:
            # 容器不存在：自动补建（兼容历史 agent 数据，首次访问时创建）
            created = self.ensure_workspace(workspace_id)
            if "error" in created:
                return {
                    "error": created["error"],
                    "detail": created.get("detail", ""),
                    "exit_code": -1,
                }
            try:
                container = self.client.containers.get(
                    self._container_name(workspace_id)
                )
            except NotFound:
                return {
                    "error": f"工作空间无法创建: {workspace_id}",
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
        支持任意二进制内容：将内容 base64 编码后，在容器内通过 ``base64 -d``
        解码写入，避免 shell 转义与编码问题。
        :param workspace_id: 工作空间标识
        :param container_path: 容器内绝对路径（相对 /workspace 的路径亦可）
        :param data: 待写入的文件字节内容
        :return: ``{"exit_code": 0, "stdout": ...}`` 或在失败时带 ``error``
        """
        if not self._available:
            return {"error": "Docker 不可用", "detail": self._unavailable_reason}
        try:
            container = self.client.containers.get(self._container_name(workspace_id))
        except NotFound:
            # 容器不存在：自动补建（兼容历史 agent 数据）
            created = self.ensure_workspace(workspace_id)
            if "error" in created:
                return {
                    "error": created["error"],
                    "detail": created.get("detail", ""),
                    "exit_code": -1,
                }
            try:
                container = self.client.containers.get(
                    self._container_name(workspace_id)
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
        # base64 字符集（A-Za-z0-9+/=）不含 shell 特殊字符，单引号包裹安全
        b64 = base64.b64encode(data).decode("ascii")
        cmd = (
            f"mkdir -p '{dirname}' && "
            f"echo '{b64}' | base64 -d > '{abs_path}'"
        )
        try:
            result = container.exec_run(["sh", "-c", cmd])
            exit_code = int(result.exit_code)
            output = result.output
            if isinstance(output, bytes):
                output = output.decode("utf-8", errors="replace")
            return {"exit_code": exit_code, "stdout": output, "stderr": ""}
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