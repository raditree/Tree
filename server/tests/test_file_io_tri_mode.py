# -*- coding: utf-8 -*-
"""Task 5 文件 IO 三模式一致 + 大文件分片上传 REST 层测试。

覆盖（io_/routes.py 文件栏接口的三模式分派语义）：
- 单请求上传通道（POST /files/{ws}/upload）：local / ssh 模式经反向 WS 委托
  前端执行器（op=upload_file，team_id 透传），云端模式容器内 base64 解码写入；
  local/ssh 模式超过 ``upload.chunk_threshold`` 的文件 413 拒绝单请求通道。
- 分片协议（upload_init/upload_chunk/upload_complete 三段式）：local/ssh 模式
  逐段委托前端执行器（负载与 team_id 透传校验）；云端模式服务端暂存分片、
  complete 按序组装进容器并清理，覆盖不完整 400 / 非法 upload_id 400 /
  会话不存在 404 / 非法 base64 400 / 超过 max_file_size 413。
- list_files 三模式：SSH/local 委托前端执行器（并过滤 .git/workspaces/
  agentspace 隐藏条目），云端模式 ls 输出同样过滤。
- get_file_content SSH 模式：文本走 read_file、图片走 read_file_bytes（base64）。

隔离：workspace_id 固定 ``top``（共享演示空间，跳过归属校验）；认证经
dependency_overrides 覆盖；local_executor / ws_manager / docker_manager /
get_config / _upload_staging_dir / mode_resolver.resolve_mode 全部打桩，
分片暂存目录重定位到 pytest tmp_path，不污染 server/data。
"""
import base64
import datetime
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import state  # noqa: E402
from fastapi import FastAPI  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from io_ import mode_resolver  # noqa: E402
from io_ import routes as routes_mod  # noqa: E402
from ws.auth import get_current_user  # noqa: E402

USER = {"openid": "u-tri-mode"}

# 打桩上传配置：阈值 1MB / 分片 256KB，用小负载即可验证阈值与分片语义
UPLOAD_CFG = {
    "max_file_size": "10m",
    "chunk_threshold": "1m",
    "chunk_size": "256k",
    "sandbox_max_size": "1g",
}

CHUNK_SIZE = 256 * 1024


# ----------------------------------------------------------------------
# 打桩假件
# ----------------------------------------------------------------------
class _FakeWS:
    """极简 ws_manager 替身（request 不实际推送，仅记录）。"""


class _FakeExecutor:
    """假前端执行器：记录 request 调用（含 team_id），返回预设响应。"""

    def __init__(self, is_local=True, response=None):
        self.is_local_flag = is_local
        self.response = response if response is not None else {"success": True}
        self.calls = []  # [(payload, team_id), ...]

    def is_local(self, user_id, team_id=None):
        return self.is_local_flag

    def request(self, ws_manager, user_id, payload, team_id=""):
        self.calls.append((dict(payload), team_id))
        return dict(self.response)


class _FakeDocker:
    """假 docker_manager：记录 write_file / exec_in_workspace 调用。"""

    def __init__(self):
        self.written = []  # [(workspace_id, path, bytes), ...]
        self.execs = []  # [(workspace_id, argv), ...]

    def write_file(self, workspace_id, container_path, data):
        self.written.append((workspace_id, container_path, bytes(data)))
        return {"exit_code": 0, "stdout": ""}

    def exec_in_workspace(self, workspace_id, argv):
        self.execs.append((workspace_id, list(argv)))
        # du -sb /workspace（沙箱大小校验）→ 0 字节；其余命令按成功处理
        if any("du -sb" in str(a) for a in argv):
            return {"exit_code": 0, "stdout": "0\n"}
        return {"exit_code": 0, "stdout": ""}


def _today() -> str:
    return datetime.datetime.now().strftime("%Y%m%d")


def _setup(
    monkeypatch,
    executor=None,
    ws=None,
    ssh_mode=False,
    staging_root=None,
    docker=None,
):
    """构建 TestClient 并打桩：认证 / state / 配置 / 暂存目录 / 模式解析。"""
    ws = ws if ws is not None else _FakeWS()
    monkeypatch.setattr(state, "local_executor", executor)
    monkeypatch.setattr(state, "ws_manager", ws)
    monkeypatch.setattr(state, "docker_manager", docker)

    monkeypatch.setattr(routes_mod, "get_config", lambda: {"upload": dict(UPLOAD_CFG)})
    if staging_root is not None:
        monkeypatch.setattr(
            routes_mod,
            "_upload_staging_dir",
            lambda upload_id: staging_root / upload_id,
        )
    if ssh_mode:
        monkeypatch.setattr(mode_resolver, "resolve_mode", lambda u, k: "ssh")

    app = FastAPI()
    app.include_router(routes_mod.router)
    app.dependency_overrides[get_current_user] = lambda: dict(USER)
    return TestClient(app)


# ----------------------------------------------------------------------
# 单请求上传通道：三模式分派
# ----------------------------------------------------------------------
def test_upload_local_mode_delegates(monkeypatch):
    """local 模式：multipart 上传委托前端执行器（op=upload_file，team_id 透传）。"""
    executor = _FakeExecutor(is_local=True)
    client = _setup(monkeypatch, executor=executor)

    r = client.post(
        "/api/files/top/upload?team_id=top1",
        files=[("files", ("a.txt", b"hello", "text/plain"))],
        data={"rel_paths": "docs/a.txt"},
    )
    assert r.status_code == 200
    body = r.json()
    assert body["success"] is True
    assert body["paths"] == [f"/workspace/.input/{_today()}/docs/a.txt"]

    payload, team_id = executor.calls[0]
    assert payload["op"] == "upload_file"
    assert payload["workspace_id"] == "top"
    assert payload["rel_path"] == f".input/{_today()}/docs/a.txt"
    assert base64.b64decode(payload["data_base64"]) == b"hello"
    assert team_id == "top1"


def test_upload_ssh_mode_delegates(monkeypatch):
    """ssh 模式：与 local 相同的委托路径（三模式一致）。"""
    executor = _FakeExecutor(is_local=False, response={"success": True})
    client = _setup(monkeypatch, executor=executor, ssh_mode=True)

    r = client.post(
        "/api/files/top/upload?team_id=top1",
        files=[("files", ("b.txt", b"ssh-bytes", "text/plain"))],
    )
    assert r.status_code == 200
    payload, team_id = executor.calls[0]
    assert payload["op"] == "upload_file"
    assert base64.b64decode(payload["data_base64"]) == b"ssh-bytes"
    assert team_id == "top1"


def test_upload_cloud_mode_docker_write(monkeypatch):
    """云端模式：容器内 base64 解码写入（不经前端委托）。"""
    docker = _FakeDocker()
    monkeypatch.setattr(routes_mod, "get_config", lambda: {"upload": dict(UPLOAD_CFG)})
    client = _setup(monkeypatch, docker=docker)

    r = client.post(
        "/api/files/top/upload",
        files=[
            ("files", ("a.txt", b"cloud-a", "text/plain")),
            ("files", ("b.txt", b"cloud-b", "text/plain")),
        ],
    )
    assert r.status_code == 200
    assert r.json()["paths"] == [
        f"/workspace/.input/{_today()}/a.txt",
        f"/workspace/.input/{_today()}/b.txt",
    ]
    # 写入命令：echo "$2" | base64 -d > "$3"（argv[5]=b64, argv[6]=目标路径；
    # 沙箱大小校验的 du -sb 调用不计入）
    write_execs = [argv for _, argv in docker.execs if "base64 -d >" in str(argv)]
    assert len(write_execs) == 2
    b64_0, target_0 = write_execs[0][5], write_execs[0][6]
    assert base64.b64decode(b64_0) == b"cloud-a"
    assert target_0 == f".input/{_today()}/a.txt"


def test_upload_local_over_chunk_threshold_413(monkeypatch):
    """local 模式：超过分片阈值的文件拒绝单请求通道（提示走分片通道）。"""
    executor = _FakeExecutor(is_local=True)
    client = _setup(monkeypatch, executor=executor)

    r = client.post(
        "/api/files/top/upload?team_id=top1",
        files=[("files", ("big.bin", b"x" * (1024 * 1024 + 1), "application/octet-stream"))],
    )
    assert r.status_code == 413
    assert "分片" in r.json()["detail"]
    assert executor.calls == []  # 未委托执行器


def test_upload_over_max_file_size_413(monkeypatch):
    """超过 ``upload.max_file_size``：三模式统一 413（读取阶段即校验）。"""
    executor = _FakeExecutor(is_local=True)
    client = _setup(monkeypatch, executor=executor)

    r = client.post(
        "/api/files/top/upload?team_id=top1",
        files=[("files", ("huge.bin", b"x" * (10 * 1024 * 1024 + 1), "application/octet-stream"))],
    )
    assert r.status_code == 413
    assert executor.calls == []


# ----------------------------------------------------------------------
# 分片协议：local/ssh 委托前端执行器
# ----------------------------------------------------------------------
def test_chunked_upload_ssh_full_flow_delegates(monkeypatch):
    """ssh 模式分片三段式：init/chunk/complete 逐段委托 + 负载校验。"""
    executor = _FakeExecutor(
        is_local=False,
        response={"success": True, "path": ".input/x/big.bin", "size": 5},
    )
    client = _setup(monkeypatch, executor=executor, ssh_mode=True)

    # ① init
    r = client.post(
        "/api/files/top/upload_init?team_id=top1",
        json={"file_name": "big.bin", "rel_path": "", "total_size": 5},
    )
    assert r.status_code == 200
    body = r.json()
    upload_id = body["upload_id"]
    assert len(upload_id) == 32  # uuid4().hex，complete/chunk 回传同一 id
    assert body["chunk_size"] == CHUNK_SIZE  # 服务端定标（upload.chunk_size）

    init_payload, init_team = executor.calls[0]
    assert init_payload["op"] == "upload_init"
    assert init_payload["upload_id"] == upload_id
    assert init_payload["rel_path"] == f".input/{_today()}/big.bin"
    assert init_payload["total_size"] == 5
    assert init_payload["chunk_size"] == CHUNK_SIZE
    assert init_team == "top1"

    # ② chunk
    r = client.post(
        "/api/files/top/upload_chunk?team_id=top1",
        json={"upload_id": upload_id, "index": 0, "data": base64.b64encode(b"hello").decode()},
    )
    assert r.status_code == 200
    assert r.json() == {"received": True, "index": 0}
    chunk_payload, chunk_team = executor.calls[1]
    assert chunk_payload["op"] == "upload_chunk"
    assert chunk_payload["upload_id"] == upload_id
    assert chunk_payload["index"] == 0
    assert base64.b64decode(chunk_payload["data_base64"]) == b"hello"
    assert chunk_team == "top1"

    # ③ complete
    r = client.post(
        "/api/files/top/upload_complete?team_id=top1",
        json={"upload_id": upload_id, "total_chunks": 1},
    )
    assert r.status_code == 200
    done = r.json()
    assert done["success"] is True
    assert done["path"] == ".input/x/big.bin"
    assert done["size"] == 5
    complete_payload, complete_team = executor.calls[2]
    assert complete_payload["op"] == "upload_complete"
    assert complete_payload["upload_id"] == upload_id
    assert complete_payload["total_chunks"] == 1
    assert complete_team == "top1"


def test_chunked_upload_init_over_max_file_size_413(monkeypatch):
    """分片 init：total_size 超过 max_file_size 时 413（不建会话）。"""
    executor = _FakeExecutor(is_local=True)
    client = _setup(monkeypatch, executor=executor)

    r = client.post(
        "/api/files/top/upload_init?team_id=top1",
        json={"file_name": "huge.bin", "rel_path": "", "total_size": 10 * 1024 * 1024 + 1},
    )
    assert r.status_code == 413
    assert executor.calls == []


def test_chunked_upload_executor_error_500(monkeypatch):
    """分片委托执行失败（前端执行器回 error）：500 透出。"""
    executor = _FakeExecutor(is_local=True, response={"error": "分片会话不存在或已完成"})
    client = _setup(monkeypatch, executor=executor)

    r = client.post(
        "/api/files/top/upload_chunk?team_id=top1",
        json={"upload_id": "a" * 32, "index": 0, "data": base64.b64encode(b"x").decode()},
    )
    assert r.status_code == 500
    assert "分片会话不存在" in r.json()["detail"]["error"]


def test_chunked_upload_init_bad_rel_path_400(monkeypatch):
    """分片 init：rel_path 含 ``..`` 段（路径穿越）时 400。"""
    executor = _FakeExecutor(is_local=True)
    client = _setup(monkeypatch, executor=executor)

    r = client.post(
        "/api/files/top/upload_init?team_id=top1",
        json={"file_name": "big.bin", "rel_path": "../../etc", "total_size": 5},
    )
    assert r.status_code == 400
    assert executor.calls == []


# ----------------------------------------------------------------------
# 分片协议：云端模式暂存 + 组装
# ----------------------------------------------------------------------
def test_chunked_upload_cloud_assembles_and_cleans(monkeypatch, tmp_path):
    """云端分片：init 建暂存 → chunk 落 .part → complete 按序组装进容器并清理。"""
    docker = _FakeDocker()
    staging_root = tmp_path / "upload_chunks"
    client = _setup(
        monkeypatch, ws=None, ssh_mode=False, staging_root=staging_root, docker=docker
    )

    # ① init：建立暂存目录 + meta.json
    r = client.post(
        "/api/files/top/upload_init",
        json={"file_name": "big.bin", "rel_path": "", "total_size": 5},
    )
    assert r.status_code == 200
    upload_id = r.json()["upload_id"]
    staging = staging_root / upload_id
    meta = json.loads((staging / "meta.json").read_text(encoding="utf-8"))
    assert meta["workspace_id"] == "top"
    assert meta["rel_path"] == f".input/{_today()}/big.bin"
    assert meta["total_size"] == 5
    assert meta["received"] == 0

    # ② chunk：分片字节写入 {index:06d}.part，received 累加
    r = client.post(
        "/api/files/top/upload_chunk",
        json={"upload_id": upload_id, "index": 0, "data": base64.b64encode(b"he").decode()},
    )
    assert r.status_code == 200
    r = client.post(
        "/api/files/top/upload_chunk",
        json={"upload_id": upload_id, "index": 1, "data": base64.b64encode(b"llo").decode()},
    )
    assert r.status_code == 200
    meta = json.loads((staging / "meta.json").read_text(encoding="utf-8"))
    assert meta["received"] == 5

    # ③ complete：首片 write_file 流式落盘，后续片 base64 追加，暂存清理
    r = client.post(
        "/api/files/top/upload_complete",
        json={"upload_id": upload_id, "total_chunks": 2},
    )
    assert r.status_code == 200
    done = r.json()
    assert done["success"] is True
    assert done["path"] == f"/workspace/.input/{_today()}/big.bin"
    assert done["size"] == 5

    target = f".input/{_today()}/big.bin"
    assert docker.written == [("top", target, b"he")]
    append = [argv for _, argv in docker.execs if "base64 -d >>" in str(argv)]
    assert len(append) == 1
    # 追加命令：echo "$1" | base64 -d >> "$2"（argv[4]=b64, argv[5]=目标路径）
    assert base64.b64decode(append[0][4]) == b"llo"
    assert append[0][5] == target
    assert not staging.exists(), "组装完成后暂存目录应被清理"


def test_chunked_upload_cloud_incomplete_400(monkeypatch, tmp_path):
    """云端 complete：分片不完整（少于 total_chunks）时 400。"""
    staging_root = tmp_path / "upload_chunks"
    client = _setup(
        monkeypatch, ws=None, staging_root=staging_root, docker=_FakeDocker()
    )

    r = client.post(
        "/api/files/top/upload_init",
        json={"file_name": "big.bin", "rel_path": "", "total_size": 5},
    )
    upload_id = r.json()["upload_id"]
    client.post(
        "/api/files/top/upload_chunk",
        json={"upload_id": upload_id, "index": 0, "data": base64.b64encode(b"he").decode()},
    )
    r = client.post(
        "/api/files/top/upload_complete",
        json={"upload_id": upload_id, "total_chunks": 2},
    )
    assert r.status_code == 400
    assert "分片不完整" in r.json()["detail"]


def test_chunked_upload_cloud_bad_upload_id_400(monkeypatch, tmp_path):
    """云端 chunk：upload_id 非 32 位 hex（路径穿越风险）时 400。"""
    client = _setup(monkeypatch, ws=None, staging_root=tmp_path / "s")
    r = client.post(
        "/api/files/top/upload_chunk",
        json={"upload_id": "../evil", "index": 0, "data": base64.b64encode(b"x").decode()},
    )
    assert r.status_code == 400


def test_chunked_upload_cloud_unknown_session_404(monkeypatch, tmp_path):
    """云端 chunk：会话不存在（未 init）时 404。"""
    client = _setup(monkeypatch, ws=None, staging_root=tmp_path / "s")
    r = client.post(
        "/api/files/top/upload_chunk",
        json={"upload_id": "a" * 32, "index": 0, "data": base64.b64encode(b"x").decode()},
    )
    assert r.status_code == 404


def test_chunked_upload_cloud_bad_base64_400(monkeypatch, tmp_path):
    """云端 chunk：data 不是合法 base64 时 400。"""
    staging_root = tmp_path / "upload_chunks"
    client = _setup(
        monkeypatch, ws=None, staging_root=staging_root, docker=_FakeDocker()
    )

    r = client.post(
        "/api/files/top/upload_init",
        json={"file_name": "big.bin", "rel_path": "", "total_size": 5},
    )
    upload_id = r.json()["upload_id"]
    r = client.post(
        "/api/files/top/upload_chunk",
        json={"upload_id": upload_id, "index": 0, "data": "!!!not-base64!!!"},
    )
    assert r.status_code == 400


# ----------------------------------------------------------------------
# list_files：三模式委托 + 隐藏条目过滤
# ----------------------------------------------------------------------
def test_list_files_ssh_delegates_and_filters_hidden(monkeypatch):
    """ssh 模式 list_files：委托前端执行器 + 过滤 .git/workspaces/agentspace。"""
    executor = _FakeExecutor(
        is_local=False,
        response={
            "files": [
                {"name": ".git", "type": "dir"},
                {"name": "workspaces", "type": "dir"},
                {"name": "agentspace", "type": "dir"},
                {"name": "src", "type": "dir", "path": "src"},
                {"name": "main.py", "type": "file", "path": "main.py"},
            ]
        },
    )
    client = _setup(monkeypatch, executor=executor, ssh_mode=True)

    r = client.get("/api/files/top?team_id=top1")
    assert r.status_code == 200
    names = [f["name"] for f in r.json()["files"]]
    assert names == ["src", "main.py"]  # 隐藏条目被过滤

    payload, team_id = executor.calls[0]
    assert payload["op"] == "list_files"
    assert payload["workspace_id"] == "top"
    assert payload["path"] == ""
    assert team_id == "top1"


def test_list_files_local_mode_delegates(monkeypatch):
    """local 模式 list_files：team_id 缺省时回落 workspace_id 作为隔离键。"""
    executor = _FakeExecutor(is_local=True, response={"files": [{"name": "a.txt", "type": "file"}]})
    client = _setup(monkeypatch, executor=executor)

    r = client.get("/api/files/top")
    assert r.status_code == 200
    assert r.json()["files"] == [{"name": "a.txt", "type": "file"}]
    _, team_id = executor.calls[0]
    assert team_id == "top"  # team_id 缺省 → workspace_id


def test_list_files_executor_error_404(monkeypatch):
    """local/ssh 模式 list_files：执行器回 error 时 404。"""
    executor = _FakeExecutor(is_local=True, response={"error": "目录不存在"})
    client = _setup(monkeypatch, executor=executor)
    r = client.get("/api/files/top?team_id=top1")
    assert r.status_code == 404


def test_list_files_cloud_filters_hidden(monkeypatch):
    """云端 list_files：ls 输出同样过滤隐藏条目（三模式一致）。"""
    docker = _FakeDocker()
    monkeypatch.setattr(state, "local_executor", None)
    monkeypatch.setattr(state, "ws_manager", None)
    monkeypatch.setattr(state, "docker_manager", docker)
    monkeypatch.setattr(routes_mod, "get_config", lambda: {"upload": dict(UPLOAD_CFG)})

    ls_output = (
        "total 16\n"
        "drwxr-xr-x 2 root root 4096 2026-09-06 10:00 .git\n"
        "drwxr-xr-x 2 root root 4096 2026-09-06 10:00 workspaces\n"
        "drwxr-xr-x 2 root root 4096 2026-09-06 10:00 agentspace\n"
        "-rw-r--r-- 1 root root 12 2026-09-06 10:00 main.py\n"
    )
    monkeypatch.setattr(
        docker, "exec_in_workspace", lambda ws_id, argv: {"exit_code": 0, "stdout": ls_output}
    )

    app = FastAPI()
    app.include_router(routes_mod.router)
    app.dependency_overrides[get_current_user] = lambda: dict(USER)
    client = TestClient(app)

    r = client.get("/api/files/top")
    assert r.status_code == 200
    names = [f["name"] for f in r.json()["files"]]
    assert names == ["main.py"]


# ----------------------------------------------------------------------
# get_file_content：SSH 模式文本 / 图片分派
# ----------------------------------------------------------------------
def test_get_file_content_ssh_text_delegates(monkeypatch):
    """ssh 模式读取文本文件：op=read_file（utf-8）。"""
    executor = _FakeExecutor(
        is_local=False, response={"content": "hello ssh", "exit_code": 0}
    )
    client = _setup(monkeypatch, executor=executor, ssh_mode=True)

    r = client.get("/api/files/top/content?team_id=top1&path=main.py")
    assert r.status_code == 200
    body = r.json()
    assert body["content"] == "hello ssh"
    assert body["path"] == "main.py"
    assert body.get("is_base64", False) is False

    payload, team_id = executor.calls[0]
    assert payload["op"] == "read_file"
    assert payload["path"] == "main.py"
    assert payload["encoding"] == "utf-8"
    assert team_id == "top1"


def test_get_file_content_ssh_image_base64(monkeypatch):
    """ssh 模式读取图片：op=read_file_bytes，返回 is_base64=true。"""
    raw = b"\x89PNG fake"
    executor = _FakeExecutor(
        is_local=False,
        response={"content_base64": base64.b64encode(raw).decode(), "exit_code": 0},
    )
    client = _setup(monkeypatch, executor=executor, ssh_mode=True)

    r = client.get("/api/files/top/content?team_id=top1&path=img.png")
    assert r.status_code == 200
    body = r.json()
    assert body["is_base64"] is True
    assert base64.b64decode(body["content"]) == raw

    payload, _ = executor.calls[0]
    assert payload["op"] == "read_file_bytes"
    assert payload["path"] == "img.png"
