# -*- coding: utf-8 -*-
"""LocalExecutorClient 请求/响应对 pending 清理语义的回归测试。

Issue1 回归：finally 块不应在成功返回路径上再次清理 pending。
- 正常结果由 resolve() 在匹配时完成清理（set_result + pop）；
- finally 仅应在请求被放弃（future 仍未完成：超时/异常路径）时兜底清理；
- 前端迟到/重复推送结果时应被安全拒绝（resolve 返回 False），不产生副作用。
"""

import sys
import threading
import time
import unittest
from pathlib import Path

# 将 server 目录添加到 Python 路径，使 core 模块可导入
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core.local_executor import LocalExecutorClient  # noqa: E402


class _SpyPending(dict):
    """记录 pop 调用（含 no-op）的 dict 子类，用于断言清理发生的次数。"""

    def __init__(self, log):
        super().__init__()
        self._log = log

    def pop(self, key, default=None):
        existed = key in self
        self._log.append((key, existed))
        return super().pop(key, default)


class _FakeWS:
    """极简 ws_manager 替身：记录推送消息，send_message 为异步方法。"""

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


class TestPendingCleanup(unittest.TestCase):
    def _make_client(self, user="u1"):
        client = LocalExecutorClient()
        client.register(user, "top", "C:/proj")
        return client

    def test_success_path_finally_does_not_cleanup_pending(self):
        """成功路径：pending 仅由 resolve() 清理一次，finally 不再触发 pop。

        若回归为无条件 `self._pending.pop(key, None)`，此处 pop 调用应为 2 次
        （resolve 一次 + finally 一次）；修复后应为 1 次。
        """
        client = self._make_client()
        ws = _FakeWS()
        pops = []
        client._pending = _SpyPending(pops)

        box = {}

        def do_request():
            box["res"] = client.request(
                ws, "u1", {"op": "read_file", "workspace_id": "top", "path": "a.txt"}, timeout=8
            )

        t = threading.Thread(target=do_request)
        t.start()
        msg = ws.wait_message()
        exec_id = msg["data"]["exec_id"]

        def do_resolve():
            box["resolved"] = client.resolve("u1", exec_id, {"exit_code": 0, "content": "hello"})

        tr = threading.Thread(target=do_resolve)
        tr.start()
        t.join(timeout=8)
        tr.join(timeout=8)

        self.assertEqual(box.get("res"), {"exit_code": 0, "content": "hello"})
        self.assertTrue(box.get("resolved"))
        self.assertEqual(len(client._pending), 0)
        # 唯一一次有效清理来自 resolve（existed=True），finally 不应再触发 pop
        self.assertEqual(len(pops), 1, "finally 不应在成功路径上清理 pending，实际 pop 调用: %s" % pops)
        self.assertTrue(pops[0][1], "resolve 清理时条目应当存在")

    def test_timeout_path_cleans_pending_and_rejects_late_response(self):
        """超时路径：pending 被清理，迟到响应无法匹配，不产生副作用。"""
        client = self._make_client(user="u2")
        ws = _FakeWS()
        box = {}

        def do_request():
            box["res"] = client.request(
                ws, "u2", {"op": "exec_shell", "workspace_id": "top", "command": "sleep"}, timeout=1
            )

        t = threading.Thread(target=do_request)
        t.start()
        msg = ws.wait_message()
        exec_id = msg["data"]["exec_id"]
        t.join(timeout=8)

        self.assertIn("error", box["res"])
        self.assertEqual(len(client._pending), 0)
        # 迟到响应：无法匹配，返回 False
        self.assertFalse(client.resolve("u2", exec_id, {"exit_code": 0, "stdout": "late"}))

    def test_duplicate_repush_after_success_is_safely_rejected(self):
        """成功后前端重复推送同一 exec_id：resolve 返回 False，无副作用。"""
        client = self._make_client(user="u3")
        ws = _FakeWS()
        box = {}

        def do_request():
            box["res"] = client.request(
                ws, "u3", {"op": "read_file", "workspace_id": "top", "path": "a.txt"}, timeout=8
            )

        t = threading.Thread(target=do_request)
        t.start()
        msg = ws.wait_message()
        exec_id = msg["data"]["exec_id"]
        self.assertTrue(client.resolve("u3", exec_id, {"exit_code": 0, "content": "hello"}))
        t.join(timeout=8)
        self.assertEqual(box["res"], {"exit_code": 0, "content": "hello"})
        self.assertFalse(client.resolve("u3", exec_id, {"exit_code": 0, "content": "hello"}))
        self.assertEqual(len(client._pending), 0)

    def test_unregister_fails_pending_requests(self):
        """注销本地执行器时，待响应请求失败且 pending 被清理。"""
        client = self._make_client(user="u4")
        ws = _FakeWS()
        box = {}

        def do_request():
            box["res"] = client.request(
                ws, "u4", {"op": "exec_shell", "workspace_id": "top", "command": "sleep"}, timeout=8
            )

        t = threading.Thread(target=do_request)
        t.start()
        msg = ws.wait_message()
        client.unregister("u4", "top")
        t.join(timeout=8)
        self.assertIn("error", box["res"])
        self.assertEqual(len(client._pending), 0)


if __name__ == "__main__":
    unittest.main()
