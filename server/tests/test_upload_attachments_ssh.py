# -*- coding: utf-8 -*-
"""SSH 模式聊天附件上传回归测试。

回归场景：SSH 模式下聊天附件只写云端容器/后端本地 workspaces，agent 的
SSH 工具（跑在远端主机）读不到——表现为「提示已上传、实际找不到」。

修复：resolve_mode == "ssh" 时走 _upload_attachments_ssh，把附件内容经前端
SSH 执行器（upload_file op）SFTP 落到远端 remote_base_dir/.input/yyyymmdd/，
与文件面板 FileSync 上传语义一致。执行器未注册/前端失联时不静默回退云端。
"""
import asyncio
import base64
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import state  # noqa: E402
from agent.chat import _upload_attachments_ssh  # noqa: E402


class _RecordingExecutor:
    """模拟 LocalExecutorClient：is_ssh 可配置，request 记录调用并返回成功。"""

    def __init__(self, ssh_registered=True, base_dir="", request_result=None):
        self.ssh_registered = ssh_registered
        self.base_dir = base_dir
        self.request_result = request_result or {"success": True, "file_path": "x"}
        self.requests = []

    def is_local(self, user_id, team_id=None):
        return bool(self.base_dir)

    def is_ssh(self, user_id, team_id=None):
        return self.ssh_registered

    def request(self, ws_manager, user_id, payload, timeout=120, team_id=""):
        self.requests.append((team_id, payload))
        return self.request_result


class _FakeWS:
    pass


class TestUploadAttachmentsSsh(unittest.TestCase):
    def setUp(self):
        self._orig_executor = getattr(state, "local_executor", None)
        self._orig_ws = getattr(state, "ws_manager", None)
        self._orig_docker = getattr(state, "docker_manager", None)

    def tearDown(self):
        state.local_executor = self._orig_executor
        state.ws_manager = self._orig_ws
        state.docker_manager = self._orig_docker

    def _make_src(self, tmpdir, name="a.txt", content=b"data"):
        src = Path(tmpdir) / name
        src.write_bytes(content)
        return src

    def test_ssh_mode_forwards_to_remote_input(self):
        """SSH 模式：经执行器 upload_file 转发，落远端 .input/yyyymmdd/。"""
        executor = _RecordingExecutor(ssh_registered=True)
        state.local_executor = executor
        state.ws_manager = _FakeWS()
        state.docker_manager = None  # 证明不依赖云端

        with tempfile.TemporaryDirectory() as td:
            src = self._make_src(td, content=b"ssh-bytes")
            uploaded = asyncio.run(
                _upload_attachments_ssh("top", [str(src)], user_id="u1", team_id="top")
            )

        self.assertTrue(uploaded, "SSH 模式应上报附件路径")
        self.assertTrue(uploaded[0].startswith("/workspace/.input/"))
        self.assertEqual(len(executor.requests), 1)
        team_id, payload = executor.requests[0]
        self.assertEqual(team_id, "top")
        self.assertEqual(payload["op"], "upload_file")
        self.assertEqual(payload["workspace_id"], "top")
        self.assertTrue(
            payload["rel_path"].startswith(".input/"),
            f"rel_path 应为工作空间相对路径: {payload['rel_path']}",
        )
        self.assertTrue(payload["rel_path"].endswith("a.txt"))
        self.assertEqual(
            base64.b64decode(payload["data_base64"]), b"ssh-bytes"
        )

    def test_ssh_mode_unregistered_skips_no_cloud_fallback(self):
        """SSH 模式但执行器未注册：跳过上传，不静默回退云端。"""
        executor = _RecordingExecutor(ssh_registered=False)
        state.local_executor = executor
        state.ws_manager = _FakeWS()
        state.docker_manager = None

        with tempfile.TemporaryDirectory() as td:
            src = self._make_src(td)
            uploaded = asyncio.run(
                _upload_attachments_ssh("top", [str(src)], user_id="u1", team_id="top")
            )

        self.assertEqual(uploaded, [])
        self.assertEqual(executor.requests, [], "未注册时不应发起请求")

    def test_missing_file_skipped(self):
        """附件不存在：跳过（不报错、不上报）。"""
        state.local_executor = _RecordingExecutor(ssh_registered=True)
        state.ws_manager = _FakeWS()
        state.docker_manager = None

        with tempfile.TemporaryDirectory() as td:
            uploaded = asyncio.run(
                _upload_attachments_ssh(
                    "top", [str(Path(td) / "nope.png")], user_id="u1", team_id="top"
                )
            )
        self.assertEqual(uploaded, [])

    def test_ssh_upload_error_logged_and_skipped(self):
        """前端返回 error：记录 warning 并跳过该文件，不影响整体。"""
        executor = _RecordingExecutor(
            ssh_registered=True,
            request_result={"error": "SSH 上传失败: x"},
        )
        state.local_executor = executor
        state.ws_manager = _FakeWS()
        state.docker_manager = None

        with tempfile.TemporaryDirectory() as td:
            src = self._make_src(td)
            uploaded = asyncio.run(
                _upload_attachments_ssh("top", [str(src)], user_id="u1", team_id="top")
            )
        self.assertEqual(uploaded, [])


if __name__ == "__main__":
    unittest.main()
