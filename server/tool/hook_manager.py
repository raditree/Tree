"""后台任务管理器 - 支撑 terminal 工具 hook 模式的长任务。

hook 模式把一条长命令放到独立进程后台执行（本地=前端托管分离进程，
云端/SSH=后端独立线程执行），输出实时重定向到工作空间内文件，工具立即
返回不阻塞 tool loop；命令结束后经 :mod:`agent.chat` 注入的 ``on_complete``
回调唤醒发起该命令的 agent 续跑。

任务状态统一由模块级单例 :class:`HookTaskManager` 管理，支持
``start`` / ``status`` / ``cancel``，local / ssh / cloud 三种模式共用。
"""

from __future__ import annotations

import logging
import threading
import time
import uuid
from typing import Any, Callable, Dict, Optional

from io_.workspace_io import LocalWorkspaceIO, WorkspaceIO, run_io

logger = logging.getLogger(__name__)


class _HookTask:
    """单个后台 hook 任务的状态记录。"""

    def __init__(
        self, task_id: str, command: str, output_file: str,
        io: WorkspaceIO, workspace_id: str,
    ) -> None:
        self.task_id = task_id
        self.command = command
        self.output_file = output_file
        self.io = io
        self.workspace_id = workspace_id
        self.state = "running"  # running | completed | failed | cancelled
        self.exit_code: Optional[int] = None
        self.error = ""
        self.cancelled = False
        self.started_at = time.time()
        self.finished_at: Optional[float] = None
        self._lock = threading.Lock()


class HookTaskManager:
    """管理 terminal hook 后台任务的启动 / 查询 / 取消（模块级单例）。

    线程安全：``on_complete`` 回调可能在后端后台线程（cloud/ssh）或前端
    ``tool_exec_response`` 触发的消费线程（local）中执行，任务落定使用锁。
    """

    def __init__(self) -> None:
        self._tasks: Dict[str, _HookTask] = {}
        self._lock = threading.Lock()

    def start(
        self,
        io: WorkspaceIO,
        workspace_id: str,
        command: str,
        output_file: str = "",
        timeout: Optional[int] = None,
        on_complete: Optional[Callable[..., Any]] = None,
    ) -> Dict[str, Any]:
        """后台启动一条 hook 命令并立即返回。

        - local：前端托管分离进程（``exec_shell_hook``），退出时回传真实退出码。
        - cloud/ssh：后端独立后台线程执行 ``exec_shell_no_timeout``（无时长上限）。

        :param io: 工作空间 IO 实现
        :param workspace_id: 工作空间标识
        :param command: 要执行的 shell 命令
        :param output_file: 输出重定向文件（工作空间相对路径）；缺省自动派生
        :param timeout: 超时秒数（hook 任务不限制时长，仅透传，前端不强制）
        :param on_complete: 完成回调 ``on_complete(task_id, exit_code,
                            output_file, cancelled, error)``
        :return: ``{"task_id": ..., "output_file": ...}`` 或 ``{"error": ...}``
        """
        task_id = uuid.uuid4().hex
        if not output_file:
            output_file = f".output/hook_{task_id}.log"
        task = _HookTask(task_id, command, output_file, io, workspace_id)
        with self._lock:
            self._tasks[task_id] = task

        # 先建占位文件（自动建父目录，三模式通用），保证重定向目标存在
        try:
            run_io(io.write_file(workspace_id, output_file, ""))
        except Exception as exc:  # noqa: BLE001
            logger.warning("创建 hook 输出占位文件失败: %s (%s)", output_file, exc)
            self._complete(
                task, {"error": f"创建输出文件失败: {exc}"}, on_complete
            )
            return {"error": task.error, "task_id": task_id}

        if isinstance(io, LocalWorkspaceIO):
            # 本地模式：前端托管分离进程，输出重定向在前端 cmd/bash 中完成
            wrapped = f"{command} > {output_file} 2>&1"
            try:
                result = run_io(io.exec_shell_hook(
                    workspace_id, task_id, wrapped, output_file,
                    timeout, lambda r: self._complete(task, r, on_complete),
                ))
            except Exception as exc:  # noqa: BLE001
                logger.warning("启动本地 hook 失败: %s (%s)", task_id, exc)
                self._complete(
                    task, {"error": f"启动本地 hook 失败: {exc}"}, on_complete
                )
                return {"error": task.error, "task_id": task_id}
            if result.get("error"):
                # 发送失败已由 exec_shell_hook 内部触发 on_done 收尾
                return {"error": result["error"], "task_id": task_id}
        else:
            # 云端 / SSH：sh 语法后台 + pidfile + wait，后端线程执行（无上限）
            wrapped = (
                f"{command} > {output_file} 2>&1 "
                f"& echo $! > {output_file}.pid; wait"
            )
            threading.Thread(
                target=self._run_remote,
                args=(io, workspace_id, task, wrapped, on_complete),
                daemon=True,
            ).start()

        return {"task_id": task_id, "output_file": output_file}

    def _run_remote(
        self,
        io: WorkspaceIO,
        workspace_id: str,
        task: _HookTask,
        wrapped: str,
        on_complete: Optional[Callable[..., Any]],
    ) -> None:
        """云端 / SSH 后台线程入口：执行无超时命令并落定任务。"""
        try:
            result = run_io(io.exec_shell_no_timeout(workspace_id, wrapped))
        except Exception as exc:  # noqa: BLE001
            logger.warning("远端 hook 执行异常: task_id=%s (%s)", task.task_id, exc)
            result = {"error": f"远端 hook 执行异常: {exc}"}
        self._complete(task, result, on_complete)

    def _complete(
        self,
        task: _HookTask,
        result: Dict[str, Any],
        on_complete: Optional[Callable[..., Any]],
    ) -> None:
        """根据回传结果落定任务状态并触发完成回调（幂等）。

        :param result: ``{"exit_code": int, ...}`` 或 ``{"error": ...}``
        """
        with task._lock:
            if task.finished_at is not None:
                return  # 已结束（重复回传 / 取消后进程退出）
            if task.cancelled:
                task.state = "cancelled"
                task.exit_code = (
                    task.exit_code if task.exit_code is not None else -1
                )
            elif result.get("error"):
                task.state = "failed"
                task.error = str(result["error"])
                task.exit_code = -1
            else:
                task.state = "completed"
                task.exit_code = result.get("exit_code", 0)
            task.finished_at = time.time()
        logger.info(
            "hook 任务结束: task_id=%s state=%s exit_code=%s output=%s",
            task.task_id, task.state, task.exit_code, task.output_file,
        )
        try:
            if on_complete:
                on_complete(
                    task.task_id, task.exit_code, task.output_file,
                    task.cancelled, task.error,
                )
        except Exception:  # noqa: BLE001
            logger.exception(
                "hook on_complete 回调失败: task_id=%s", task.task_id
            )

    def status(self, task_id: str) -> Dict[str, Any]:
        """查询任务状态。

        :return: ``{"state", "exit_code", "output_file", "command",
                  "started_at", "finished_at", "error", "task_id"}``；
                 未知 task_id 返回 ``{"error": ...}``
        """
        task = self._tasks.get(task_id)
        if task is None:
            return {"error": f"未知任务: {task_id}"}
        return {
            "task_id": task.task_id,
            "state": task.state,
            "exit_code": task.exit_code,
            "output_file": task.output_file,
            "command": task.command,
            "started_at": task.started_at,
            "finished_at": task.finished_at,
            "error": task.error,
        }

    def cancel(self, task_id: str) -> Dict[str, Any]:
        """取消一个后台 hook 任务（尽力终止，进程退出后仍走完成回调）。

        - local：向后端 WS 发 ``tool_exec_cancel`` → 前端 ``process.kill()``；
        - cloud/ssh：经 pidfile ``kill -TERM``（尽力终止，不保证杀掉全部孙进程）。
        """
        task = self._tasks.get(task_id)
        if task is None:
            return {"error": f"未知任务: {task_id}"}
        with task._lock:
            task.cancelled = True
            if task.finished_at is not None:
                return self.status(task_id)
        try:
            if isinstance(task.io, LocalWorkspaceIO):
                run_io(task.io.cancel_exec_hook(task_id))
            else:
                kill_cmd = (
                    f"kill -TERM $(cat {task.output_file}.pid) 2>/dev/null || true"
                )
                run_io(task.io.exec_shell(task.workspace_id, kill_cmd, 10))
        except Exception as exc:  # noqa: BLE001
            logger.warning("取消 hook 任务失败: task_id=%s (%s)", task_id, exc)
        return self.status(task_id)


# 模块级单例
_hook_manager: Optional[HookTaskManager] = None
_hook_manager_lock = threading.Lock()


def get_hook_manager() -> HookTaskManager:
    """返回全局 HookTaskManager 单例。"""
    global _hook_manager
    if _hook_manager is None:
        with _hook_manager_lock:
            if _hook_manager is None:
                _hook_manager = HookTaskManager()
    return _hook_manager
