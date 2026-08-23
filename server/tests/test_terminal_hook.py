"""terminal hook 模式单测：HookTaskManager 后台任务 + TerminalTool hook 分支。

用假 WorkspaceIO（非 LocalWorkspaceIO，走云端/SSH 后端线程路径）验证：
- start → 后台线程执行 exec_shell_no_timeout → 完成 → on_complete 触发；
- status 状态流转（running → completed / cancelled）；
- cancel 对远端任务发出 pidfile kill 命令；
- TerminalTool.execute 的 hook_action=status/cancel、hook=True 启动分支与
  普通阻塞分支互不影响。
"""
import asyncio
import threading
import time

from tool.hook_manager import get_hook_manager
from tool.terminal_tool import TerminalTool


class FakeRemoteIO:
    """模拟云端/SSH 工作空间 IO（非 LocalWorkspaceIO）。"""

    def __init__(self) -> None:
        self.write_calls = []
        self.no_timeout_calls = []
        self.exec_calls = []

    async def write_file(self, workspace_id, path, content):
        self.write_calls.append((workspace_id, path, content))
        return {"success": True, "file_path": path}

    async def exec_shell_no_timeout(self, workspace_id, command):
        self.no_timeout_calls.append((workspace_id, command))
        await asyncio.sleep(0.05)
        return {"exit_code": 0, "stdout": "done"}

    async def exec_shell(self, workspace_id, command, timeout=30):
        self.exec_calls.append((workspace_id, command, timeout))
        return {"exit_code": 0, "stdout": "blocking-out"}


def _fresh_io() -> FakeRemoteIO:
    return FakeRemoteIO()


def test_hook_manager_remote_start_complete():
    io = _fresh_io()
    mgr = get_hook_manager()
    completed = []
    event = threading.Event()

    def on_complete(task_id, exit_code, output_file, cancelled=False, error=""):
        completed.append((task_id, exit_code, output_file, cancelled, error))
        event.set()

    result = mgr.start(
        io, "ws1", "sleep 1", output_file=".output/a.log",
        on_complete=on_complete,
    )
    assert result["task_id"]
    assert result["output_file"] == ".output/a.log"
    # 先建占位文件（自动建父目录）
    assert io.write_calls and io.write_calls[0][1] == ".output/a.log"

    # 后台线程异步完成，等待回调
    assert event.wait(timeout=5), "on_complete 未在超时内触发"
    assert len(completed) == 1
    tid, code, of, cancelled, err = completed[0]
    assert tid == result["task_id"]
    assert code == 0
    assert of == ".output/a.log"
    assert cancelled is False
    assert err == ""

    # 无超时执行通道被调用，命令带重定向 + pidfile 后台包装
    assert len(io.no_timeout_calls) == 1
    cmd = io.no_timeout_calls[0][1]
    assert ".output/a.log" in cmd and ".pid" in cmd

    status = mgr.status(result["task_id"])
    assert status["state"] == "completed"
    assert status["exit_code"] == 0
    assert status["output_file"] == ".output/a.log"
    assert status["task_id"] == result["task_id"]


def test_hook_manager_cancel_remote():
    io = _fresh_io()
    mgr = get_hook_manager()
    result = mgr.start(io, "ws1", "sleep 100", output_file=".output/c.log")
    task_id = result["task_id"]
    # 等后台线程进入执行后取消（fake sleep 0.05s）
    deadline = time.time() + 2
    while not io.no_timeout_calls and time.time() < deadline:
        time.sleep(0.01)
    assert io.no_timeout_calls, "后台线程未启动"

    st = mgr.cancel(task_id)
    assert st["task_id"] == task_id
    # 远端取消经 exec_shell 发 pidfile kill 命令
    assert any(".output/c.log.pid" in c[1] for c in io.exec_calls)

    # 后台线程结束后任务落定为 cancelled
    deadline = time.time() + 5
    while mgr.status(task_id)["state"] != "cancelled" and time.time() < deadline:
        time.sleep(0.01)
    assert mgr.status(task_id)["state"] == "cancelled"


def test_terminal_tool_hook_start():
    io = _fresh_io()
    tool = TerminalTool(io, "ws1")
    res = tool.execute({"command": "make build", "hook": True})
    assert res["task_id"]
    assert res["output_file"].endswith(".log")
    assert res["exit_code"] == 0
    assert "hook" in res["stdout"]
    # 后台线程默认无 on_complete，等待其收尾避免泄漏线程
    time.sleep(0.2)


def test_terminal_tool_hook_status_cancel_unknown():
    io = _fresh_io()
    tool = TerminalTool(io, "ws1")
    res = tool.execute(
        {"command": "", "hook_action": "status", "task_id": "nonexistent"}
    )
    assert "error" in res
    res2 = tool.execute(
        {"command": "", "hook_action": "cancel", "task_id": "nonexistent"}
    )
    assert "error" in res2


def test_terminal_tool_normal_blocking():
    io = _fresh_io()
    tool = TerminalTool(io, "ws1")
    res = tool.execute({"command": "echo hi"})
    assert res["exit_code"] == 0
    assert res["stdout"] == "blocking-out"
    # 普通分支不走无超时通道
    assert not io.no_timeout_calls
