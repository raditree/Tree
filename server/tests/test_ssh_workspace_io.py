"""P0 Task3 单测：SSHWorkspaceIO 七方法 / 连接探活重连 / ModeResolver 三模式。

使用 mock 替换 paramiko client / sftp，无需真实 SSH 主机即可验证
路径映射、exec 结果解析与连接管理逻辑。
"""
import asyncio

import pytest


# ----------------------------------------------------------------------
# Fake paramiko 组件
# ----------------------------------------------------------------------
class FakeSFTPFile:
    def __init__(self, data: bytes = b""):
        self._data = data
        self._pos = 0

    def read(self, size=-1):
        if size < 0:
            data = self._data[self._pos:]
            self._pos = len(self._data)
            return data
        data = self._data[self._pos:self._pos + size]
        self._pos += len(data)
        return data

    def write(self, data):
        self._data += data
        return len(data)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class FakeSFTP:
    def __init__(self):
        self.files = {}  # path -> FakeSFTPFile
        self.dirs = set()

    def open(self, path, mode="rb"):
        if "w" in mode:
            f = FakeSFTPFile()
            self.files[path] = f
            return f
        f = self.files.get(path)
        if f is None:
            raise FileNotFoundError(path)
        return f

    def stat(self, path):
        if path in self.dirs or path in self.files:
            return object()
        raise OSError(f"no such: {path}")

    def mkdir(self, path):
        self.dirs.add(path)

    def close(self):
        pass


class FakeTransport:
    def __init__(self, active=True):
        self._active = active

    def is_active(self):
        return self._active


class FakeChannel:
    def __init__(self, code=0):
        self._code = code

    def recv_exit_status(self):
        return self._code


class FakeStdout:
    def __init__(self, data: str, code=0):
        self._data = data.encode("utf-8")
        self._pos = 0
        self.channel = FakeChannel(code)

    def read(self, size=-1):
        if size < 0:
            data = self._data[self._pos:]
            self._pos = len(self._data)
            return data
        data = self._data[self._pos:self._pos + size]
        self._pos += len(data)
        return data


class FakeStderr:
    def __init__(self, data: str = ""):
        self._data = data.encode("utf-8")
        self._pos = 0

    def read(self, size=-1):
        if size < 0:
            data = self._data[self._pos:]
            self._pos = len(self._data)
            return data
        data = self._data[self._pos:self._pos + size]
        self._pos += len(data)
        return data


class FakeClient:
    def __init__(self, transport_active=True, exec_code=0, exec_stdout=""):
        self._transport = FakeTransport(transport_active)
        self.exec_code = exec_code
        self.exec_stdout = exec_stdout
        self.sftp = FakeSFTP()
        self.connect_calls = 0
        self.close_calls = 0

    def open_sftp(self):
        return self.sftp

    def exec_command(self, command, timeout=None):
        return None, FakeStdout(self.exec_stdout, self.exec_code), FakeStderr()

    def get_transport(self):
        return self._transport

    def connect(self, **kwargs):
        self.connect_calls += 1

    def close(self):
        self.close_calls += 1


class FakeSSHManager:
    """提供 get_config / get_connection 的假管理器（持有单一 client）。"""

    def __init__(self, cfg, client):
        self.cfg = cfg
        self.client = client

    def get_config(self, user_id, agent_id):
        return self.cfg

    def get_connection(self, user_id, agent_id):
        return self.client


@pytest.fixture
def ssh_cfg():
    return {
        "host": "example.com",
        "port": 22,
        "username": "user",
        "remote_base_dir": "/home/user/agent",
    }


def make_io(manager, top_agent_id="top1"):
    from io_.ssh_workspace_io import SSHWorkspaceIO

    return SSHWorkspaceIO(manager, "u1", top_agent_id)


def run(coro):
    return asyncio.run(coro)


# ----------------------------------------------------------------------
# 路径映射
# ----------------------------------------------------------------------
def test_remote_path_top_maps_to_base(ssh_cfg):
    client = FakeClient()
    manager = FakeSSHManager(ssh_cfg, client)
    io = make_io(manager, top_agent_id="top1")
    assert io._remote_path("top1", "a.txt") == "/home/user/agent/a.txt"
    assert io._remote_path("top1", "") == "/home/user/agent"


def test_remote_path_member_maps_to_workspaces(ssh_cfg):
    client = FakeClient()
    manager = FakeSSHManager(ssh_cfg, client)
    io = make_io(manager, top_agent_id="top1")
    assert (
        io._remote_path("memberA", ".self/memory.md")
        == "/home/user/agent/workspaces/memberA/.self/memory.md"
    )


# ----------------------------------------------------------------------
# 七个 async 方法
# ----------------------------------------------------------------------
def test_read_file(ssh_cfg):
    client = FakeClient()
    client.sftp.files["/home/user/agent/a.txt"] = FakeSFTPFile("hello".encode())
    io = make_io(FakeSSHManager(ssh_cfg, client))
    result = run(io.read_file("top1", "a.txt"))
    assert result["exit_code"] == 0
    assert result["content"] == "hello"


def test_read_file_missing(ssh_cfg):
    client = FakeClient()
    io = make_io(FakeSSHManager(ssh_cfg, client))
    result = run(io.read_file("top1", "nope.txt"))
    assert "error" in result


def test_write_file_creates_dirs(ssh_cfg):
    client = FakeClient()
    io = make_io(FakeSSHManager(ssh_cfg, client))
    result = run(io.write_file("top1", "sub/dir/f.txt", "content"))
    assert result["success"] is True
    sftp = client.sftp
    assert "/home/user/agent/sub" in sftp.dirs
    assert "/home/user/agent/sub/dir" in sftp.dirs
    assert sftp.files["/home/user/agent/sub/dir/f.txt"]._data == b"content"


def test_exec_shell(ssh_cfg):
    client = FakeClient(exec_stdout="cmd-out\n", exec_code=0)
    io = make_io(FakeSSHManager(ssh_cfg, client))
    result = run(io.exec_shell("top1", "echo hi", timeout=5))
    assert result["exit_code"] == 0
    assert "cmd-out" in result["stdout"]


def test_exec_argv(ssh_cfg):
    client = FakeClient(exec_stdout="py\n", exec_code=0)
    io = make_io(FakeSSHManager(ssh_cfg, client))
    result = run(io.exec_argv("top1", ["python3", "-c", "print(1)"]))
    assert result["exit_code"] == 0
    assert "py" in result["stdout"]


def test_grep_search(ssh_cfg):
    client = FakeClient(exec_stdout="f.py:1:match", exec_code=0)
    io = make_io(FakeSSHManager(ssh_cfg, client))
    result = run(io.grep_search("top1", "pattern"))
    assert result["exit_code"] == 0
    assert "f.py:1:match" in result["stdout"]


def test_git_log(ssh_cfg):
    out = "abc123\tAlice\t2026-01-01 10:00:00 +0800\tfix bug"
    client = FakeClient(exec_stdout=out, exec_code=0)
    io = make_io(FakeSSHManager(ssh_cfg, client))
    result = run(io.git_log("top1", limit=10))
    assert len(result["commits"]) == 1
    assert result["commits"][0]["hash"] == "abc123"
    assert result["commits"][0]["message"] == "fix bug"


def test_git_branches(ssh_cfg):
    out = "* main\n  feature/x\n  remotes/origin/main\n"
    client = FakeClient(exec_stdout=out, exec_code=0)
    io = make_io(FakeSSHManager(ssh_cfg, client))
    result = run(io.git_branches("top1"))
    assert result["current"] == "main"
    assert "main" in result["branches"]
    assert "feature/x" in result["branches"]
    assert result["branches"].count("main") == 1


def test_git_branches_empty(ssh_cfg):
    client = FakeClient(exec_stdout="", exec_code=0)
    io = make_io(FakeSSHManager(ssh_cfg, client))
    result = run(io.git_branches("top1"))
    assert result["branches"] == []
    assert result["current"] == ""


def test_list_files(ssh_cfg):
    out = (
        "total 8\n"
        "drwxr-xr-x 2 user user 4096 Jan 1 10:00 .\n"
        "drwxr-xr-x 3 user user 4096 Jan 1 10:00 ..\n"
        "-rw-r--r-- 1 user user  123 Jan 1 10:00 a.txt\n"
        "drwxr-xr-x 2 user user 4096 Jan 1 10:00 dir\n"
    )
    client = FakeClient(exec_stdout=out, exec_code=0)
    io = make_io(FakeSSHManager(ssh_cfg, client))
    result = run(io.list_files("top1", ""))
    names = {(f["name"], f["type"]) for f in result["files"]}
    assert ("a.txt", "file") in names
    assert ("dir", "dir") in names
    assert len(result["files"]) == 2


# ----------------------------------------------------------------------
# 连接管理：懒连接 + 探活重连
# ----------------------------------------------------------------------
def test_connection_lazy_and_reconnect(monkeypatch, ssh_cfg):
    import io_.ssh_connection_manager as mod
    from io_.ssh_connection_manager import SSHConnectionManager

    client1 = FakeClient(transport_active=True)
    client2 = FakeClient(transport_active=True)

    monkeypatch.setattr(
        mod.ssh_store, "get_connection", lambda u, a: dict(ssh_cfg)
    )
    manager = SSHConnectionManager()
    manager._clients["u1:top1"] = client1

    # 活动连接直接复用
    got = manager.get_connection("u1", "top1")
    assert got is client1

    # transport 失活 -> 关闭并重建（新 connect）
    client1._transport._active = False

    def _connect(**kwargs):
        pass

    monkeypatch.setattr(
        "paramiko.SSHClient.connect", lambda self, **kw: setattr(self, "connected", True)
    )
    client2.close_calls = 0
    got = manager.get_connection("u1", "top1")
    assert client1.close_calls == 1  # 旧连接被关闭
    assert got is not client1
    assert got is not None


def test_connection_not_configured(monkeypatch, ssh_cfg):
    import io_.ssh_connection_manager as mod
    from io_.ssh_connection_manager import SSHConnectionManager

    monkeypatch.setattr(mod.ssh_store, "get_connection", lambda u, a: None)
    manager = SSHConnectionManager()
    with pytest.raises(RuntimeError):
        manager.get_connection("u1", "top1")


def test_is_ssh(monkeypatch, ssh_cfg):
    import io_.ssh_connection_manager as mod
    from io_.ssh_connection_manager import SSHConnectionManager

    monkeypatch.setattr(mod.ssh_store, "get_connection", lambda u, a: dict(ssh_cfg))
    assert SSHConnectionManager().is_ssh("u1", "top1") is True
    monkeypatch.setattr(mod.ssh_store, "get_connection", lambda u, a: None)
    assert SSHConnectionManager().is_ssh("u1", "top1") is False


# ----------------------------------------------------------------------
# ModeResolver：优先级 + 互斥
# ----------------------------------------------------------------------
class FakeLocalExecutor:
    def __init__(self, local=False):
        self.local = local

    def is_local(self, user_id, top_agent_id=None):
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
