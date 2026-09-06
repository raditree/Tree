# -*- coding: utf-8 -*-
"""SSH 模式相关单测：SSHWorkspaceIO 前端委托 / SSHConnectionManager 配置管理 / ModeResolver 三模式。

SSH 运行模式改造后（SSH 连接由**前端 dartssh2** 发起，IP 相对前端），后端
不再建立任何 SSH 连接：

- ``SSHWorkspaceIO`` 是 ``LocalWorkspaceIO`` 的委托子类：七个方法（含 hook）
  把请求转发给 ``local_executor.request()`` / ``send_request()`` 并透传结果。
- ``SSHConnectionManager`` 仅做配置持久化与模式判定（register 不再测试连接）。
- ``ModeResolver`` 三模式优先级 local > ssh > cloud 与互斥校验保持不变。

使用 mock 替换 local_executor / ssh_store，无需真实 SSH 主机或前端。
"""
import asyncio
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))


# ----------------------------------------------------------------------
# 前端委托假件
# ----------------------------------------------------------------------
class _FakeWS:
    """极简 ws_manager 替身（request 不实际推送，仅记录）。"""

    def __init__(self):
        self.sent = []

    async def send_message(self, user_id, message):
        self.sent.append(message)


class _FakeExecutor:
    """假前端执行器客户端：记录请求负载，按预设响应返回。"""

    def __init__(self, response=None):
        self.response = response if response is not None else {}
        self.request_calls = []
        self.send_calls = []
        self.cancel_calls = []
        self.cancel_pidfiles = []
        self.hook_on_done = None

    def request(self, ws_manager, user_id, payload, team_id=""):
        self.request_calls.append(payload)
        return dict(self.response)

    def send_request(self, ws_manager, user_id, payload):
        self.send_calls.append(payload)
        return {"success": True}

    def register_hook(self, user_id, tool_id, on_done, team_id=""):
        self.hook_on_done = on_done

    def resolve(self, user_id, tool_id, result, team_id=""):
        # 模拟真实 LocalExecutorClient.resolve：唤醒已登记的 hook 完成回调
        if self.hook_on_done is not None:
            self.hook_on_done(result)
        return True

    def cancel_hook(self, ws_manager, user_id, tool_id, pidfile=""):
        self.cancel_calls.append(tool_id)
        self.cancel_pidfiles.append(pidfile)
        return {"success": True}


def make_io(executor, team_id="top1"):
    from io_.ssh_workspace_io import SSHWorkspaceIO

    return SSHWorkspaceIO(executor, _FakeWS(), "u1")


def run(coro):
    return asyncio.run(coro)


# ----------------------------------------------------------------------
# SSHWorkspaceIO：委托前端执行器 + 结果透传
# ----------------------------------------------------------------------
def test_read_file_delegates_and_passthrough():
    io = make_io(_FakeExecutor({
        "exit_code": 0, "content": "hello", "stdout": "hello", "stderr": "",
    }))
    result = run(io.read_file("top1", "a.txt", "utf-8"))
    assert result["content"] == "hello"
    assert result["exit_code"] == 0
    call = io._executor.request_calls[0]
    assert call["op"] == "read_file"
    assert call["workspace_id"] == "top1"
    assert call["path"] == "a.txt"
    assert call["encoding"] == "utf-8"


def test_read_file_error_passthrough():
    io = make_io(_FakeExecutor({"error": "文件不存在"}))
    result = run(io.read_file("top1", "nope.txt"))
    assert result["error"] == "文件不存在"


def test_write_file_delegates():
    io = make_io(_FakeExecutor({"success": True, "file_path": "f.txt"}))
    result = run(io.write_file("top1", "f.txt", "content"))
    assert result["success"] is True
    call = io._executor.request_calls[0]
    assert call["op"] == "write_file"
    assert call["content"] == "content"


def test_write_file_error_passthrough():
    io = make_io(_FakeExecutor({"error": "写入失败"}))
    result = run(io.write_file("top1", "f.txt", "content"))
    assert result["error"] == "写入失败"
    assert result["file_path"] == "f.txt"


def test_exec_shell_delegates():
    io = make_io(_FakeExecutor({"exit_code": 0, "stdout": "out", "stderr": ""}))
    result = run(io.exec_shell("top1", "echo hi", timeout=15))
    assert result["stdout"] == "out"
    call = io._executor.request_calls[0]
    assert call["op"] == "exec_shell"
    assert call["command"] == "echo hi"
    assert call["timeout"] == 15


def test_exec_argv_delegates():
    io = make_io(_FakeExecutor({"exit_code": 0, "stdout": "py", "stderr": ""}))
    result = run(io.exec_argv("top1", ["python3", "-c", "print(1)"]))
    assert result["exit_code"] == 0
    call = io._executor.request_calls[0]
    assert call["op"] == "exec_argv"
    assert call["argv"] == ["python3", "-c", "print(1)"]


def test_grep_search_delegates():
    io = make_io(_FakeExecutor({"exit_code": 0, "stdout": "f.py:1:match"}))
    result = run(io.grep_search("top1", "pattern"))
    assert "f.py:1:match" in result["stdout"]
    call = io._executor.request_calls[0]
    assert call["op"] == "grep_search"
    assert call["pattern"] == "pattern"


def test_git_log_delegates():
    io = make_io(_FakeExecutor({
        "commits": [{"hash": "abc123", "author": "Alice",
                     "date": "2026-01-01", "message": "fix"}],
        "exit_code": 0,
    }))
    result = run(io.git_log("top1", limit=10))
    assert len(result["commits"]) == 1
    assert result["commits"][0]["hash"] == "abc123"
    call = io._executor.request_calls[0]
    assert call["op"] == "git_log"
    assert call["limit"] == 10


def test_list_files_delegates():
    io = make_io(_FakeExecutor({"files": [{"name": "a.txt", "type": "file"}],
                                "exit_code": 0}))
    result = run(io.list_files("top1", ""))
    assert len(result["files"]) == 1
    assert result["files"][0]["name"] == "a.txt"
    call = io._executor.request_calls[0]
    assert call["op"] == "list_files"


def test_exec_shell_hook_delegates():
    """hook 模式：先登记完成回调，再非阻塞发送 exec_shell_hook。"""
    io = make_io(_FakeExecutor())
    done = []

    def on_done(r):
        done.append(r)

    result = run(io.exec_shell_hook(
        "top1", "exec1", "sleep 1 > .o 2>&1", ".o", 120, on_done,
    ))
    assert result["success"] is True
    assert io._executor.hook_on_done is on_done
    call = io._executor.send_calls[0]
    assert call["op"] == "exec_shell_hook"
    assert call["tool_id"] == "exec1"
    assert call["output_file"] == ".o"


def test_exec_shell_hook_send_failure_resolves_error():
    """发送失败时立即触发 on_done 以错误收尾，避免 hook 悬挂。"""
    class _FailExecutor(_FakeExecutor):
        def send_request(self, ws_manager, user_id, payload):
            self.send_calls.append(payload)
            return {"error": "推送失败"}

    io = make_io(_FailExecutor())
    done = []

    def on_done(r):
        done.append(r)

    result = run(io.exec_shell_hook(
        "top1", "exec2", "cmd", ".o", None, on_done,
    ))
    assert result["error"] == "推送失败"
    assert len(done) == 1
    assert "error" in done[0]


def test_cancel_exec_hook_delegates():
    io = make_io(_FakeExecutor())
    result = run(io.cancel_exec_hook("exec3"))
    assert result["success"] is True
    assert io._executor.cancel_calls == ["exec3"]
    assert io._executor.cancel_pidfiles == [""]


def test_cancel_exec_hook_passes_pidfile():
    """SSH hook 取消：pidfile 随 tool_exec_cancel 透传给前端执行器。"""
    io = make_io(_FakeExecutor())
    result = run(io.cancel_exec_hook("exec4", pidfile=".output/a.log.pid"))
    assert result["success"] is True
    assert io._executor.cancel_calls == ["exec4"]
    assert io._executor.cancel_pidfiles == [".output/a.log.pid"]


# ----------------------------------------------------------------------
# hook_manager SSH 路由：SSH 分支显式化（输出重定向落盘 + pidfile 取消）
# ----------------------------------------------------------------------
def test_hook_manager_ssh_start_wraps_redirect_and_pidfile():
    """SSH hook 启动：经 exec_shell_hook 下发，wrapped 含重定向 + pidfile + wait。"""
    from tool.hook_manager import get_hook_manager

    executor = _FakeExecutor()
    io = make_io(executor)
    mgr = get_hook_manager()
    result = mgr.start(io, "top1", "python server.py",
                       output_file=".output/s.log")
    assert result["task_id"]
    assert result["output_file"] == ".output/s.log"
    # 占位输出文件先经前端 write_file 建立（SSH 走 SFTP 写入）
    assert executor.request_calls[0]["op"] == "write_file"
    assert executor.request_calls[0]["path"] == ".output/s.log"
    # hook 命令非阻塞下发（exec_shell_hook），tool_id 与任务 id 同源
    assert len(executor.send_calls) == 1
    send = executor.send_calls[0]
    assert send["op"] == "exec_shell_hook"
    assert send["tool_id"] == result["task_id"]
    assert send["output_file"] == ".output/s.log"
    # wrapped：重定向落盘 + pidfile + wait（完成回执语义与 local 一致）
    wrapped = send["command"]
    assert "python server.py" in wrapped
    assert "python server.py > .output/s.log 2>&1" in wrapped
    assert "echo $! > .output/s.log.pid" in wrapped
    assert wrapped.rstrip().endswith("wait")
    # 任务运行中（等前端 tool_exec_response 回执，而非后端线程直接落定）
    assert mgr.status(result["task_id"])["state"] == "running"
    assert mgr.status(result["task_id"])["task_id"] == result["task_id"]

    # 模拟前端回传退出码 → 任务落定 completed
    executor.resolve("u1", result["task_id"], {"exit_code": 0})
    status = mgr.status(result["task_id"])
    assert status["state"] == "completed"
    assert status["exit_code"] == 0


def test_hook_manager_ssh_cancel_sends_pidfile():
    """SSH hook 取消：tool_exec_cancel 携带 pidfile，回执后任务落定 cancelled。"""
    from tool.hook_manager import get_hook_manager

    executor = _FakeExecutor()
    io = make_io(executor)
    mgr = get_hook_manager()
    result = mgr.start(io, "top1", "sleep 100",
                       output_file=".output/c2.log")
    task_id = result["task_id"]

    st = mgr.cancel(task_id)
    assert st["task_id"] == task_id
    assert st["state"] == "running"  # 远端进程退出回执后才落定
    # 取消经 tool_exec_cancel（cancel_exec_hook）携带 pidfile
    assert executor.cancel_calls == [task_id]
    assert executor.cancel_pidfiles == [".output/c2.log.pid"]
    assert mgr.status(task_id)["state"] == "running"

    # 模拟远端进程被 kill 后 wrapped wait 返回，前端回传退出码
    executor.resolve("u1", task_id, {"exit_code": 143})
    status = mgr.status(task_id)
    assert status["state"] == "cancelled"


def test_hook_manager_ssh_send_failure_completes_with_error():
    """SSH hook 发送失败：立即以错误收尾回调，避免 hook 悬挂。"""
    from tool.hook_manager import get_hook_manager

    class _FailExecutor(_FakeExecutor):
        def send_request(self, ws_manager, user_id, payload):
            self.send_calls.append(payload)
            return {"error": "推送失败"}

    executor = _FailExecutor()
    io = make_io(executor)
    mgr = get_hook_manager()
    completed = []
    result = mgr.start(
        io, "top1", "sleep 100", output_file=".output/f.log",
        on_complete=lambda *a, **kw: completed.append(a),
    )
    assert "error" in result
    assert executor.cancel_calls == []
    # exec_shell_hook 内部已触发 on_done 收尾
    assert mgr.status(result["task_id"])["state"] == "failed"
    assert len(completed) == 1


# ----------------------------------------------------------------------
# SSHConnectionManager：配置持久化 + 模式判定（不再建连）
# ----------------------------------------------------------------------
def _make_manager():
    import io_.ssh_connection_manager as mod

    return mod.SSHConnectionManager(), mod


def test_register_persists_config(monkeypatch):
    mgr, mod = _make_manager()
    saved = {}

    def _save(**kw):
        saved.update(kw)

    monkeypatch.setattr(mod.ssh_store, "save_connection", _save)
    ok, msg = mgr.register("u1", "top1", {
        "host": "remote.example.com",
        "port": 2222,
        "username": "deploy",
        "auth_type": "password",
        "password": "secret",
        "private_key_path": "",
        "remote_base_dir": "/srv/agent",
    })
    assert ok is True
    assert msg == ""
    assert saved["user_id"] == "u1"
    assert saved["agent_id"] == "top1"
    assert saved["host"] == "remote.example.com"
    assert saved["port"] == 2222
    assert saved["username"] == "deploy"
    assert saved["remote_base_dir"] == "/srv/agent"


def test_register_does_not_test_connection(monkeypatch):
    """后端不再测试连接（连接测试由前端完成），仅持久化配置。"""
    mgr, mod = _make_manager()
    monkeypatch.setattr(mod.ssh_store, "save_connection", lambda **kw: {})
    assert mgr.register("u1", "top1", {"host": "h", "username": "u"}) == (True, "")


def test_is_ssh_and_get_config(monkeypatch):
    mgr, mod = _make_manager()
    cfg = {"host": "remote.example.com", "username": "deploy"}
    monkeypatch.setattr(mod.ssh_store, "get_connection",
                        lambda u, a: dict(cfg) if a == "top1" else None)
    assert mgr.is_ssh("u1", "top1") is True
    assert mgr.is_ssh("u1", "other") is False
    assert mgr.get_config("u1", "top1") == cfg
    assert mgr.get_config("u1", "other") is None


def test_unregister_deletes_config(monkeypatch):
    mgr, mod = _make_manager()
    monkeypatch.setattr(mod.ssh_store, "delete_connection",
                        lambda u, a: a == "top1")
    assert mgr.unregister("u1", "top1") is True
    assert mgr.unregister("u1", "other") is False


# ----------------------------------------------------------------------
# ModeResolver：优先级 + 互斥（沿用三模式判定）
# ----------------------------------------------------------------------
class FakeLocalExecutor:
    def __init__(self, local=False):
        self.local = local

    def is_local(self, user_id, team_id=None):
        return self.local


def _reset_state(monkeypatch, local=False, ssh=False):
    import state

    class _Ssh:
        def is_ssh(self, u, a):
            return ssh

        def get_config(self, u, a):
            return {"host": "remote.example.com"}

    monkeypatch.setattr(state, "local_executor", FakeLocalExecutor(local))
    monkeypatch.setattr(state, "ssh_manager", _Ssh())
    monkeypatch.setattr(state, "docker_manager", object())


def test_resolve_priority_local_gt_ssh_gt_cloud(monkeypatch):
    import io_.mode_resolver as mr

    _reset_state(monkeypatch, local=True, ssh=True)
    assert mr.resolve_mode("u1", "top1") == "local"

    _reset_state(monkeypatch, local=False, ssh=True)
    assert mr.resolve_mode("u1", "top1") == "ssh"

    _reset_state(monkeypatch, local=False, ssh=False)
    assert mr.resolve_mode("u1", "top1") == "cloud"


def test_check_exclusive(monkeypatch):
    import io_.mode_resolver as mr

    # 已启用 local，注册 ssh 应拒绝
    _reset_state(monkeypatch, local=True, ssh=False)
    ok, _ = mr.check_exclusive("u1", "top1", "ssh")
    assert ok is False
    # 已启用 ssh，注册 local 应拒绝
    _reset_state(monkeypatch, local=False, ssh=True)
    ok, _ = mr.check_exclusive("u1", "top1", "local")
    assert ok is False
    # 无模式时均可注册
    _reset_state(monkeypatch, local=False, ssh=False)
    ok, _ = mr.check_exclusive("u1", "top1", "ssh")
    assert ok is True


def test_describe_mode_shell_types(monkeypatch):
    import io_.mode_resolver as mr

    _reset_state(monkeypatch, local=False, ssh=False)
    assert "Linux 容器" in mr.describe_mode("u1", "top1")
    _reset_state(monkeypatch, local=False, ssh=True)
    text = mr.describe_mode("u1", "top1")
    assert "SSH 远端主机" in text
    assert "不可逆" in text
