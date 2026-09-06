"""附件上传链路测试：本地模式下附件落到用户选择的本地工作目录。

回归场景：本地模式下，附件若只写入 Docker 容器，agent 本地工具
（read/write）读不到——表现为「提示已存入工作空间，实际无法访问」。
"""
import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import state  # noqa: E402
from agent.chat import _upload_attachments  # noqa: E402


class _FakeLocalExecutor:
    def __init__(self, base_dir: str = "") -> None:
        self._base_dir = base_dir

    def is_local(self, user_id: str, team_id=None) -> bool:
        return bool(self._base_dir)

    def base_dir_of(self, user_id: str, team_id=None) -> str:
        return self._base_dir


class _FakeDocker:
    available = True

    def __init__(self) -> None:
        self.calls: list = []

    def write_file(self, workspace_id: str, container_path: str, data: bytes):
        self.calls.append((workspace_id, container_path, data))
        return {"exit_code": 0, "stdout": ""}


def test_local_mode_writes_to_base_dir(tmp_path, monkeypatch) -> None:
    """本地模式：附件字节写入 base_dir/.input/yyyymmdd/，返回语义路径。"""
    src = tmp_path / "clipboard_paste_123.png"
    src.write_bytes(b"fake-image-bytes")
    base = tmp_path / "workdir"
    base.mkdir()
    monkeypatch.setattr(state, "local_executor", _FakeLocalExecutor(str(base)))
    monkeypatch.setattr(state, "docker_manager", None)

    uploaded = _upload_attachments(
        "top", [str(src)], user_id="u1", team_id="top"
    )

    assert uploaded, "本地模式应成功上报附件路径"
    assert uploaded[0].startswith("/workspace/.input/")
    rel = uploaded[0].replace("\\", "/").split("/workspace/", 1)[-1]
    target = base / rel.replace("/", os.sep)
    assert target.exists(), f"附件未落到工作目录: {target}"
    assert target.read_bytes() == b"fake-image-bytes"


def test_local_mode_skips_non_existent(tmp_path, monkeypatch) -> None:
    """本地模式：附件不存在时跳过（不报错、不上报）。"""
    base = tmp_path / "workdir"
    base.mkdir()
    monkeypatch.setattr(state, "local_executor", _FakeLocalExecutor(str(base)))
    monkeypatch.setattr(state, "docker_manager", None)

    uploaded = _upload_attachments(
        "top", [str(tmp_path / "nope.png")], user_id="u1", team_id="top"
    )
    assert uploaded == []


def test_cloud_mode_skips_when_docker_unavailable(tmp_path, monkeypatch) -> None:
    """非本地模式且 Docker 不可用：安全跳过（原行为）。"""
    monkeypatch.setattr(state, "local_executor", _FakeLocalExecutor(""))
    monkeypatch.setattr(state, "docker_manager", None)

    uploaded = _upload_attachments(
        "top", [str(tmp_path / "x.png")], user_id="u1", team_id="top"
    )
    assert uploaded == []


def test_cloud_mode_writes_to_docker(tmp_path, monkeypatch) -> None:
    """非本地模式：保留 Docker 容器写入路径（原行为）。"""
    src = tmp_path / "a.txt"
    src.write_bytes(b"data")
    docker = _FakeDocker()
    monkeypatch.setattr(state, "local_executor", _FakeLocalExecutor(""))
    monkeypatch.setattr(state, "docker_manager", docker)

    uploaded = _upload_attachments(
        "top", [str(src)], user_id="u1", team_id="top"
    )
    assert uploaded and uploaded[0].startswith("/workspace/.input/")
    assert docker.calls, "云端模式应调用 docker write_file"
    assert docker.calls[0][1].startswith(".input/")
