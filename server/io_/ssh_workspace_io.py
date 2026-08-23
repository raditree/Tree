"""SSH 工作空间 IO - 七个 async 方法，转发到远端主机执行。

SSH 模式下，工作空间工具调用经 paramiko 在用户配置的远端主机上执行：
- 文件读写走 SFTP；命令执行走 exec_command。
- 路径映射：顶部 agent（workspace_id == top_agent_id）→ ``remote_base_dir``；
  团队成员 → ``remote_base_dir/workspaces/{workspace_id}``。

paramiko 均为阻塞式调用，所有方法内部经 ``asyncio.to_thread`` 切线程，
对外保持与 :class:`io_.workspace_io.WorkspaceIO` 一致的 async 契约。
"""
from __future__ import annotations

import asyncio
import logging
import posixpath
import shlex
from typing import Any, Dict, List, Optional

from io_.workspace_io import WorkspaceIO

logger = logging.getLogger(__name__)


class SSHWorkspaceIO(WorkspaceIO):
    """SSH 模式实现：基于 SSHConnectionManager 在远端主机执行。"""

    def __init__(
        self,
        manager: Any,
        user_id: str,
        top_agent_id: str,
    ) -> None:
        """初始化 SSH IO。

        :param manager: SSHConnectionManager 实例
        :param user_id: 用户标识
        :param top_agent_id: 顶部 agent ID（SSH 模式键 + 顶层路径判定）
        """
        self._manager = manager
        self._user_id = user_id
        self._top_agent_id = top_agent_id

    # ------------------------------------------------------------------
    # 路径映射
    # ------------------------------------------------------------------
    def _resolve_base(self) -> str:
        """返回该 top agent 的 SSH 远端基础目录。"""
        cfg = self._manager.get_config(self._user_id, self._top_agent_id)
        base = (cfg or {}).get("remote_base_dir", "").strip() or "/"
        return base.rstrip("/")

    def _remote_path(self, workspace_id: str, path: str) -> str:
        """将工作空间内相对路径映射为远端绝对路径。

        顶部 agent 直接落在 remote_base_dir；成员落在
        ``remote_base_dir/workspaces/{workspace_id}``。
        """
        base = self._resolve_base()
        rel = path.lstrip("/")
        if workspace_id == self._top_agent_id:
            root = base
        else:
            root = f"{base}/workspaces/{workspace_id}"
        return posixpath.join(root, rel) if rel else root

    # ------------------------------------------------------------------
    # 同步底层（阻塞，经 to_thread 调用）
    # ------------------------------------------------------------------
    def _client(self) -> Any:
        return self._manager.get_connection(self._user_id, self._top_agent_id)

    def _exec(self, argv: List[str], timeout: Optional[int] = None) -> Dict[str, Any]:
        """执行 argv 命令（shell 转义后拼成 command 串），返回统一结果字典。"""
        client = self._client()
        command = " ".join(shlex.quote(str(a)) for a in argv)
        try:
            stdin, stdout, stderr = client.exec_command(command, timeout=timeout)
            out = stdout.read().decode("utf-8", errors="replace")
            err = stderr.read().decode("utf-8", errors="replace")
            code = stdout.channel.recv_exit_status()
            return {"exit_code": code, "stdout": out, "stderr": err}
        except Exception as exc:  # noqa: BLE001
            logger.warning("SSH exec 失败: %s (%s)", command, exc)
            return {"error": f"SSH 执行失败: {exc}"}

    def _sftp_mkdir_p(self, sftp: Any, remote_dir: str) -> None:
        """递归创建远端目录（幂等）。"""
        parts = remote_dir.split("/")
        cur = ""
        for part in parts:
            if not part:
                continue
            cur = f"{cur}/{part}" if cur else f"/{part}"
            try:
                sftp.stat(cur)
            except OSError:
                try:
                    sftp.mkdir(cur)
                except OSError:
                    pass

    # ------------------------------------------------------------------
    # async 接口（七个方法）
    # ------------------------------------------------------------------
    async def read_file(
        self, workspace_id: str, path: str, encoding: str = "utf-8"
    ) -> Dict[str, Any]:
        def _do() -> Dict[str, Any]:
            try:
                sftp = self._client().open_sftp()
                try:
                    remote = self._remote_path(workspace_id, path)
                    with sftp.open(remote, "rb") as f:
                        data = f.read()
                finally:
                    sftp.close()
                content = data.decode(encoding or "utf-8", errors="replace")
                return {
                    "exit_code": 0,
                    "stdout": content,
                    "stderr": "",
                    "content": content,
                }
            except FileNotFoundError:
                return {"error": f"文件不存在: {path}", "exit_code": 1}
            except Exception as exc:  # noqa: BLE001
                return {"error": f"SSH 读取失败: {exc}", "exit_code": 1}

        return await asyncio.to_thread(_do)

    async def write_file(
        self, workspace_id: str, path: str, content: str
    ) -> Dict[str, Any]:
        def _do() -> Dict[str, Any]:
            try:
                client = self._client()
                sftp = client.open_sftp()
                try:
                    remote = self._remote_path(workspace_id, path)
                    self._sftp_mkdir_p(sftp, posixpath.dirname(remote))
                    with sftp.open(remote, "wb") as f:
                        f.write(content.encode("utf-8"))
                finally:
                    sftp.close()
                return {"success": True, "file_path": path}
            except Exception as exc:  # noqa: BLE001
                logger.warning("SSH 写入失败: %s (%s)", path, exc)
                return {"error": f"SSH 写入失败: {exc}", "file_path": path}

        return await asyncio.to_thread(_do)

    async def exec_shell(
        self, workspace_id: str, command: str, timeout: int = 30
    ) -> Dict[str, Any]:
        timeout = max(1, min(int(timeout or 30), 3600))
        cwd = self._remote_path(workspace_id, "")
        # 在目标目录下执行命令（POSIX 远端主机）
        full = f"cd {shlex.quote(cwd)} && timeout {timeout} sh -c {shlex.quote(command)}"
        return await asyncio.to_thread(
            self._exec, ["sh", "-c", full], timeout=timeout + 5
        )

    async def exec_argv(
        self, workspace_id: str, argv: List[str], timeout: Optional[int] = None
    ) -> Dict[str, Any]:
        cwd = self._remote_path(workspace_id, "")
        full = f"cd {shlex.quote(cwd)} && " + " ".join(shlex.quote(str(a)) for a in argv)
        return await asyncio.to_thread(self._exec, ["sh", "-c", full], timeout=timeout)

    async def grep_search(self, workspace_id: str, pattern: str) -> Dict[str, Any]:
        cwd = self._remote_path(workspace_id, "")
        full = (
            f"cd {shlex.quote(cwd)} && "
            f"grep -rnI --exclude-dir=.git -- {shlex.quote(pattern)} ."
        )
        return await asyncio.to_thread(self._exec, ["sh", "-c", full])

    async def git_log(
        self, workspace_id: str, limit: int = 50
    ) -> Dict[str, Any]:
        cwd = self._remote_path(workspace_id, "")
        full = (
            f"cd {shlex.quote(cwd)} && git log "
            "--pretty=format:%H%x09%an%x09%ad%x09%s --date=iso "
            f"-n {int(limit)}"
        )
        result = await asyncio.to_thread(self._exec, ["sh", "-c", full])
        commits = []
        if not result.get("error") and result.get("exit_code") == 0:
            for line in (result.get("stdout", "") or "").splitlines():
                parts = line.split("\t", 3)
                if len(parts) == 4:
                    commits.append({
                        "hash": parts[0],
                        "author": parts[1],
                        "date": parts[2],
                        "message": parts[3],
                    })
        return {"commits": commits, "exit_code": result.get("exit_code", 0)}

    async def git_branches(self, workspace_id: str) -> Dict[str, Any]:
        """查看远端所有分支：``git branch -a``，返回 ``{"branches", "current"}``。

        与 :meth:`git_log` 一致，在远端工作空间目录执行；解析 ``*`` 标记当前分支。
        """
        cwd = self._remote_path(workspace_id, "")
        full = f"cd {shlex.quote(cwd)} && git branch -a"
        result = await asyncio.to_thread(self._exec, ["sh", "-c", full])
        branches: List[str] = []
        current = ""
        if not result.get("error") and result.get("exit_code") == 0:
            for line in (result.get("stdout", "") or "").splitlines():
                s = line.strip()
                if not s:
                    continue
                if s.startswith("* "):
                    current = s[2:].strip()
                    branches.append(current)
                else:
                    branches.append(s)
        return {
            "branches": branches,
            "current": current,
            "exit_code": result.get("exit_code", 0),
        }

    async def list_files(
        self, workspace_id: str, path: str = ""
    ) -> Dict[str, Any]:
        target = self._remote_path(workspace_id, path.strip("/"))
        result = await asyncio.to_thread(
            self._exec, ["ls", "-la", target]
        )
        files = []
        if not result.get("error") and result.get("exit_code") == 0:
            for line in (result.get("stdout", "") or "").splitlines():
                line = line.strip()
                if not line or line.startswith("total"):
                    continue
                parts = line.split(None, 8)
                if len(parts) >= 9:
                    name = parts[8]
                    if name in (".", ".."):
                        continue
                    is_dir = parts[0].startswith("d")
                    try:
                        size = int(parts[4])
                    except ValueError:
                        size = 0
                    files.append({
                        "name": name,
                        "size": size,
                        "type": "dir" if is_dir else "file",
                        "modified": " ".join(parts[5:8]),
                    })
        return {"files": files, "exit_code": result.get("exit_code", 0)}
