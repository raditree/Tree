# -*- coding: utf-8 -*-
"""LocalExecutorClient 失联执行器快速失败/自动停用回归测试。

Issue：本地执行器失联（前端未注销、WS 断开等）时，后端每个请求都空等满
120s 超时；一条消息叠加多次请求（.self 读取 + 工具调用 + 记忆更新循环）
表现为"发消息卡大半天"，且大量空等线程占满线程池导致其他请求阻塞。

修复：冷启动短超时探测 + 连续超时自动停用执行器（回退云端），
重新注册时清零计数自动恢复。
"""

import sys
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from io_.local_executor import LocalExecutorClient  # noqa: E402


class _FakeWS:
    def __init__(self):
        self.sent = []
        self._lock = threading.Lock()

    async def send_message(self, user_id, message):
        with self._lock:
            self.sent.append(message)

    def wait_message(self, timeout=5.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self._lock:
                if self.sent:
                    return self.sent[0]
            time.sleep(0.005)
        raise AssertionError("未收到 tool_exec_request 推送")


class TestLocalExecutorFailFast(unittest.TestCase):
    def _make_client(self, user):
        client = LocalExecutorClient()
        client.register(user, "top", "C:/proj")
        return client

    def _request_no_response(self, client, user, timeout=0.2):
        """发起一次无人响应的请求（前端失联场景），返回结果字典。"""
        return client.request(
            _FakeWS(), user, {"op": "exec_shell", "workspace_id": "top", "command": "x"},
            timeout=timeout,
        )

    def test_auto_disable_after_consecutive_timeouts(self):
        """连续超时达到阈值后自动停用执行器，后续请求立即失败（不再空等）。"""
        client = self._make_client("f1")
        self.assertTrue(client.is_local("f1"))

        for _ in range(2):
            res = self._request_no_response(client, "f1")
            self.assertIn("error", res)

        # 连续 2 次超时后自动停用
        self.assertFalse(client.is_local("f1"))

        # 停用后请求立即返回（fail fast，而非继续空等超时）
        t0 = time.time()
        res = client.request(
            _FakeWS(), "f1", {"op": "exec_shell", "workspace_id": "top", "command": "x"},
            timeout=5,
        )
        self.assertIn("error", res)
        self.assertLess(time.time() - t0, 0.5, "停用后不应再空等响应超时")

    def test_success_resets_timeout_counter(self):
        """成功往返清零连续超时计数：之后单次超时不会触发停用。"""
        client = self._make_client("f2")
        # 1 次超时
        res = self._request_no_response(client, "f2")
        self.assertIn("error", res)

        # 1 次成功往返（模拟前端恢复响应）
        ws = _FakeWS()
        box = {}

        def do_request():
            box["res"] = client.request(
                ws, "f2", {"op": "read_file", "workspace_id": "top", "path": "a.txt"}, timeout=5
            )

        t = threading.Thread(target=do_request)
        t.start()
        msg = ws.wait_message()
        tool_id = msg["data"]["tool_id"]
        self.assertTrue(client.resolve("f2", tool_id, {"exit_code": 0, "content": "hi"}))
        t.join(timeout=8)
        self.assertEqual(box["res"], {"exit_code": 0, "content": "hi"})
        # 成功已清零计数
        self.assertEqual(client._consecutive_timeouts.get("f2", 0), 0)
        self.assertFalse(client._is_cold("f2"))

        # 再发生 1 次超时：计数 1 < 阈值 2，不应停用
        res = self._request_no_response(client, "f2")
        self.assertIn("error", res)
        self.assertTrue(client.is_local("f2"))

    def test_register_resets_timeout_counter(self):
        """重新注册清零连续超时计数，执行器自动恢复。"""
        client = self._make_client("f3")
        for _ in range(2):
            self._request_no_response(client, "f3")
        self.assertFalse(client.is_local("f3"))

        # 前端重新注册 → 恢复，且计数已清零
        client.register("f3", "top", "C:/proj")
        self.assertTrue(client.is_local("f3"))
        self.assertEqual(client._consecutive_timeouts.get("f3", 0), 0)

        # 恢复后单次超时不触发停用
        res = self._request_no_response(client, "f3")
        self.assertIn("error", res)
        self.assertTrue(client.is_local("f3"))

    def test_cold_probe_state(self):
        """冷/热状态判定：新执行器为冷，成功往返后转热。"""
        client = self._make_client("f4")
        self.assertTrue(client._is_cold("f4"))

        ws = _FakeWS()
        box = {}

        def do_request():
            box["res"] = client.request(
                ws, "f4", {"op": "read_file", "workspace_id": "top", "path": "a.txt"}, timeout=5
            )

        t = threading.Thread(target=do_request)
        t.start()
        msg = ws.wait_message()
        tool_id = msg["data"]["tool_id"]
        self.assertTrue(client.resolve("f4", tool_id, {"exit_code": 0, "content": "hi"}))
        t.join(timeout=8)
        self.assertEqual(box["res"], {"exit_code": 0, "content": "hi"})
        self.assertFalse(client._is_cold("f4"))


if __name__ == "__main__":
    unittest.main()
