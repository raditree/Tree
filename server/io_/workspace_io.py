"""工作空间 IO 抽象层（async 接口）。

MCP 文件工具（read / write / edit / terminal / embed_search）与文档工具
只依赖 :class:`WorkspaceIO` 接口，由后端根据运行模式注入具体实现：

- :class:`CloudWorkspaceIO`：云端模式，基于 DockerManager 在容器内执行命令
  （docker exec 为阻塞 subprocess，内部经 ``asyncio.to_thread`` 切线程）。
- :class:`LocalWorkspaceIO`：本地模式，通过反向 WebSocket 将请求转发给
  Flutter 前端本地执行器（Future 配对保持，接口 async）。

这样上层工具无需感知"本地还是云端"，新增传输（如 SSH）只需再实现一个
``WorkspaceIO`` 适配器即可无缝接入。

同步上下文（工具消费线程 / stdio 子进程）经 :func:`run_io` 桥驱动协程；
事件循环内的调用方直接 ``await``。
"""

from __future__ import annotations

import asyncio
import logging
from abc import ABC, abstractmethod
from concurrent import futures
from typing import Any, Awaitable, Dict, List, Optional

logger = logging.getLogger(__name__)


def run_io(coro: Awaitable[Dict[str, Any]]) -> Dict[str, Any]:
    """同步桥：在同步上下文中执行 async WorkspaceIO 协程。

    - 当前线程无运行中事件循环（工具消费线程 / stdio 子进程主线程）：
      直接 ``asyncio.run`` 驱动。
    - 当前线程已有事件循环：不可再 ``asyncio.run``，改在独立线程中驱动，
      避免阻塞（或死锁）当前循环。

    事件循环内的异步调用方应直接 ``await`` 协程，无需经过本桥。
    """
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        return asyncio.run(coro)
    with futures.ThreadPoolExecutor(max_workers=1) as pool:
        return pool.submit(asyncio.run, coro).result()


class WorkspaceIO(ABC):
    """工作空间 IO 统一接口（云端/本地/SSH 实现共享的 async 契约）。

    所有方法的返回值统一使用与 ``docker_manager.exec_in_workspace`` 兼容的
    字典形态：``{"exit_code": int, "stdout": str, "stderr": str,
    "error": Optional[str]}``，失败时 ``error`` 非空。
    """

    @abstractmethod
    async def read_file(
        self, workspace_id: str, path: str, encoding: str = "utf-8"
    ) -> Dict[str, Any]:
        """读取工作空间内文件内容。

        :param workspace_id: 工作空间标识
        :param path: 工作空间内相对路径
        :param encoding: 文件编码，默认 utf-8
        :return: 成功 ``{"exit_code": 0, "stdout": "<内容>", "content": "<内容>"}``；
                 失败 ``{"error": "...", "exit_code": N}``
        """

    @abstractmethod
    async def write_file(
        self, workspace_id: str, path: str, content: str
    ) -> Dict[str, Any]:
        """向工作空间内写入文件，自动创建父目录。

        :param workspace_id: 工作空间标识
        :param path: 工作空间内相对路径
        :param content: 文件内容（字符串）
        :return: 成功 ``{"success": True, "file_path": path}``；
                 失败 ``{"error": "...", "file_path": path}``
        """

    @abstractmethod
    async def exec_shell(
        self, workspace_id: str, command: str, timeout: int = 30
    ) -> Dict[str, Any]:
        """在工作空间内执行 shell 命令（含 git 等任意命令）。

        :param workspace_id: 工作空间标识
        :param command: shell 命令字符串
        :param timeout: 超时秒数，默认 30（超时退出码 124）
        :return: ``{"exit_code": int, "stdout": str, "stderr": str}`` 或 ``{"error": ...}``
        """

    @abstractmethod
    async def exec_argv(
        self, workspace_id: str, argv: List[str], timeout: Optional[int] = None
    ) -> Dict[str, Any]:
        """在工作空间内执行 argv 形式的命令（不经 shell 包装）。

        :param workspace_id: 工作空间标识
        :param argv: 命令参数列表，如 ``["python3", "-c", "..."]``
        :param timeout: 可选超时秒数
        :return: 同 :meth:`exec_shell`
        """

    @abstractmethod
    async def grep_search(self, workspace_id: str, pattern: str) -> Dict[str, Any]:
        """在工作空间内按文本模式搜索候选行（供 embed_search 使用）。

        :param workspace_id: 工作空间标识
        :param pattern: 搜索模式（作为字面量传给 grep）
        :return: ``{"exit_code": 0|1, "stdout": "<grep 输出>"}``；grep 无命中时
                 exit_code 为 1；失败 ``{"error": ...}``
        """

    @abstractmethod
    async def git_log(
        self, workspace_id: str, limit: int = 50
    ) -> Dict[str, Any]:
        """查看工作空间 Git 提交历史（供 team 工具使用，统一双轨制）。

        :param workspace_id: 工作空间标识
        :param limit: 返回提交条数上限
        :return: ``{"commits": [{"hash", "author", "date", "message"}, ...]}``
                 或含 ``error`` 的字典
        """

    @abstractmethod
    async def list_files(
        self, workspace_id: str, path: str = ""
    ) -> Dict[str, Any]:
        """列出工作空间内指定目录的文件（供 team 工具 view_member_output 使用）。

        :param workspace_id: 工作空间标识
        :param path: 相对工作空间根的目录路径，空串表示根目录
        :return: ``{"files": [{"name", "size", "type", "modified"}, ...]}``
                 或含 ``error`` 的字典
        """

    async def read_file_base64(
        self, workspace_id: str, path: str
    ) -> Dict[str, Any]:
        """读取工作空间内文件并以 base64 返回（供 read 工具图像输入）。

        默认实现基于 :meth:`exec_argv` 执行 ``base64 -w0``（容器/远端主机
        通常自带 coreutils）；子类可按需覆盖（如前端本地执行器自定义 op）。

        :param workspace_id: 工作空间标识
        :param path: 工作空间内相对路径
        :return: 成功 ``{"base64": "<...>", "file_path": path}``；
                 失败 ``{"error": "...", "file_path": path}``
        """
        result = await self.exec_argv(
            workspace_id, ["base64", "-w0", path], timeout=30
        )
        if result.get("error") or result.get("exit_code", -1) != 0:
            return {
                "error": result.get("error")
                or f"读取二进制文件失败: {path}",
                "file_path": path,
            }
        return {"base64": result.get("stdout", ""), "file_path": path}


class CloudWorkspaceIO(WorkspaceIO):
    """云端模式实现：基于 DockerManager 在容器内执行。

    docker exec 为阻塞 subprocess 调用，每个方法内部经
    ``asyncio.to_thread`` 切换线程，避免阻塞事件循环。
    """

    def __init__(self, docker_manager: Any) -> None:
        """初始化云端 IO。

        :param docker_manager: DockerManager 实例
        """
        self.docker_manager = docker_manager

    async def read_file(
        self, workspace_id: str, path: str, encoding: str = "utf-8"
    ) -> Dict[str, Any]:
        result = await asyncio.to_thread(
            self.docker_manager.exec_in_workspace, workspace_id, ["cat", path]
        )
        if result.get("error"):
            return result
        exit_code = result.get("exit_code", -1)
        if exit_code != 0:
            return {
                "error": f"文件不存在或无法读取: {path}",
                "exit_code": exit_code,
                "stdout": result.get("stdout", ""),
            }
        content = result.get("stdout", "")
        return {
            "exit_code": 0,
            "stdout": content,
            "stderr": result.get("stderr", ""),
            "content": content,
        }

    async def write_file(
        self, workspace_id: str, path: str, content: str
    ) -> Dict[str, Any]:
        # 通过 docker_manager.write_file 走 put_archive 流式写入：
        # - 避免 heredoc 转义问题与内容中含 .self 导致的误重写
        # - 共享成员（云端共享顶层主工作区）的 .self 私人路径自动路由到
        #   workspaces/{workspace_id} 子目录
        result = await asyncio.to_thread(
            self.docker_manager.write_file,
            workspace_id, path, content.encode("utf-8"),
        )
        if "error" in result or result.get("exit_code", -1) != 0:
            return {
                "error": result.get("error")
                or result.get("detail")
                or "写入文件失败",
                "file_path": path,
            }
        return {"success": True, "file_path": path}

    async def exec_shell(
        self, workspace_id: str, command: str, timeout: int = 30
    ) -> Dict[str, Any]:
        import shlex

        timeout = max(1, min(int(timeout or 30), 3600))
        # 通过 timeout 命令限制执行时间，超时后 coreutils 发送 SIGTERM
        wrapped_command = f"timeout {timeout} sh -c {shlex.quote(command)}"
        return await asyncio.to_thread(
            self.docker_manager.exec_in_workspace,
            workspace_id, ["sh", "-c", wrapped_command],
        )

    async def exec_argv(
        self, workspace_id: str, argv: List[str], timeout: Optional[int] = None
    ) -> Dict[str, Any]:
        return await asyncio.to_thread(
            self.docker_manager.exec_in_workspace, workspace_id, list(argv)
        )

    async def grep_search(self, workspace_id: str, pattern: str) -> Dict[str, Any]:
        import shlex

        grep_cmd = f"grep -rnI --exclude-dir=.git -- {shlex.quote(pattern)} ."
        return await asyncio.to_thread(
            self.docker_manager.exec_in_workspace,
            workspace_id, ["sh", "-c", grep_cmd],
        )

    async def git_log(
        self, workspace_id: str, limit: int = 50
    ) -> Dict[str, Any]:
        cmd = (
            "git log --pretty=format:%H%x09%an%x09%ad%x09%s --date=iso "
            f"-n {int(limit)}"
        )
        result = await asyncio.to_thread(
            self.docker_manager.exec_in_workspace,
            workspace_id, ["sh", "-c", cmd],
        )
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

    async def list_files(
        self, workspace_id: str, path: str = ""
    ) -> Dict[str, Any]:
        import shlex

        target = path.strip("/") if path else "."
        cmd = f"ls -la {shlex.quote(target)}"
        result = await asyncio.to_thread(
            self.docker_manager.exec_in_workspace,
            workspace_id, ["sh", "-c", cmd],
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


class LocalWorkspaceIO(WorkspaceIO):
    """本地模式实现：通过反向 WebSocket 把请求转发给前端本地执行器。

    前端执行器负责把工作空间内相对路径映射到用户选择的本地目录（并处理
    ``.self`` / ``.input`` 私有区），因此本实现只透传语义请求，不感知本地路径。
    反向 WS 的 Future 配对本身是阻塞等待，接口 async 化后统一经
    ``asyncio.to_thread`` 切线程执行。
    """

    def __init__(self, local_executor: Any, ws_manager: Any, user_id: str) -> None:
        """初始化本地 IO。

        :param local_executor: LocalExecutorClient 实例
        :param ws_manager: WebSocketManager 实例
        :param user_id: 用户标识（用于反向 WS 通道）
        """
        self._executor = local_executor
        self._ws_manager = ws_manager
        self._user_id = user_id

    async def _request(self, workspace_id: str, op: str, **kwargs: Any) -> Dict[str, Any]:
        payload: Dict[str, Any] = {
            "op": op,
            "workspace_id": workspace_id,
            **kwargs,
        }
        return await asyncio.to_thread(
            self._executor.request, self._ws_manager, self._user_id, payload
        )

    async def read_file(
        self, workspace_id: str, path: str, encoding: str = "utf-8"
    ) -> Dict[str, Any]:
        result = await self._request(
            workspace_id, "read_file", path=path, encoding=encoding or "utf-8"
        )
        if result.get("error"):
            return result
        content = result.get("content", "")
        return {
            "exit_code": 0,
            "stdout": content,
            "stderr": "",
            "content": content,
        }

    async def write_file(
        self, workspace_id: str, path: str, content: str
    ) -> Dict[str, Any]:
        result = await self._request(
            workspace_id, "write_file", path=path, content=content
        )
        if result.get("error"):
            return {"error": result["error"], "file_path": path}
        return {"success": True, "file_path": path}

    async def exec_shell(
        self, workspace_id: str, command: str, timeout: int = 30
    ) -> Dict[str, Any]:
        return await self._request(
            workspace_id, "exec_shell", command=command, timeout=int(timeout or 30)
        )

    async def exec_argv(
        self, workspace_id: str, argv: List[str], timeout: Optional[int] = None
    ) -> Dict[str, Any]:
        return await self._request(
            workspace_id, "exec_argv", argv=list(argv), timeout=timeout
        )

    async def grep_search(self, workspace_id: str, pattern: str) -> Dict[str, Any]:
        return await self._request(workspace_id, "grep_search", pattern=pattern)

    async def git_log(
        self, workspace_id: str, limit: int = 50
    ) -> Dict[str, Any]:
        result = await self._request(workspace_id, "git_log", limit=int(limit or 50))
        return {
            "commits": result.get("commits", []),
            "exit_code": result.get("exit_code", 0),
        }

    async def list_files(
        self, workspace_id: str, path: str = ""
    ) -> Dict[str, Any]:
        result = await self._request(workspace_id, "list_files", path=path or "")
        return {
            "files": result.get("files", []),
            "exit_code": result.get("exit_code", 0),
        }
