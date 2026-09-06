# -*- coding: utf-8 -*-
"""LocalExecutorClient 失联执行器快速失败/自动停用回归测试。

Issue：本地执行器失联（前端未注销、WS 断开等）时，后端每个请求都空等满
120s 超时；一条消息叠加多次请求（.self 读取 + 工具调用 + 记忆更新循环）
表现为"发消息卡大半天"，且大量空等线程占满线程池导致其他请求阻塞。

修复：卡死窗口判定（距最近一次 tool_exec_progress 进度 / 请求发出超过窗口
则判疑似卡死快速失败）+ 连续超时自动停用执行器；前端在执行长任务时周期
上报 tool_exec_progress 续期，使真正在干活的任务（grep 数分钟 / terminal
360s+）不被窗口误杀。重新注册时清零计数自动恢复。
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

    def test_progress_renews_stall_window(self):
        """执行中周期上报 tool_exec_progress → 等待时间可越过请求 timeout 窗口。

        模拟"任务确实在跑（每 0.15s 上报一次进度）但完成耗时远超 timeout=0.6s"
        的场景：有进度续期则等待不中断、正常拿到结果，且执行器不被误停用；
        对应真实场景里的 grep 数分钟 / terminal 360s+ 长任务。
        """
        client = self._make_client("f5")
        ws = _FakeWS()
        box = {}

        def do_request():
            box["res"] = client.request(
                ws, "f5",
                {"op": "exec_shell", "workspace_id": "top", "command": "sleep"},
                timeout=0.6,
            )

        t = threading.Thread(target=do_request)
        t.start()
        msg = ws.wait_message()
        tool_id = msg["data"]["tool_id"]

        # 任务执行约 1.2s（远超 timeout 窗口 0.6s），期间每 0.15s 上报一次进度
        deadline = time.time() + 1.2
        while time.time() < deadline:
            self.assertTrue(client.note_progress("f5", tool_id))
            time.sleep(0.15)
        # 任务结束回传结果
        self.assertTrue(
            client.resolve("f5", tool_id, {"exit_code": 0, "stdout": "done"})
        )
        t.join(timeout=8)
        self.assertEqual(box["res"], {"exit_code": 0, "stdout": "done"})
        # 进度续期下等待未被中断，执行器未被自动停用
        self.assertTrue(client.is_local("f5"))

    def test_progress_interruption_fails_fast(self):
        """进度中断（曾上报后停止）→ 距最后进度超过卡死窗口即快速失败。

        请求 timeout=30s（远超窗口），但只凭"距最后上报进度 > 窗口"就在秒级
        判死——验证卡死检测依据的是进度续期窗口，而不是笼统的请求超时。
        单次卡死不触发自动停用（计数 1 < 阈值 2）。
        """
        import io_.local_executor as le_mod

        orig = le_mod._STALL_WITHOUT_PROGRESS_SECONDS
        le_mod._STALL_WITHOUT_PROGRESS_SECONDS = 0.4
        try:
            client = self._make_client("f6")
            ws = _FakeWS()
            box = {}

            def do_request():
                box["res"] = client.request(
                    ws, "f6",
                    {"op": "exec_shell", "workspace_id": "top", "command": "sleep"},
                    timeout=30,
                )

            t = threading.Thread(target=do_request)
            t.start()
            msg = ws.wait_message()
            tool_id = msg["data"]["tool_id"]
            # 有过一次进度，随后中断（模拟执行器冻结 / 前端卡死）
            self.assertTrue(client.note_progress("f6", tool_id))
            t0 = time.time()
            t.join(timeout=8)
            self.assertIn("error", box.get("res", {}))
            elapsed = time.time() - t0
            self.assertGreaterEqual(elapsed, 0.4, "应等到卡死窗口滑出才失败")
            self.assertLess(elapsed, 6, "不应等满 30s 请求超时")
            self.assertTrue(client.is_local("f6"), "单次卡死不触发自动停用")
        finally:
            le_mod._STALL_WITHOUT_PROGRESS_SECONDS = orig

    def test_note_progress_ownership_enforced(self):
        """tool_exec_progress 归属校验：他人不能为本用户的 pending 续期。

        只有请求归属的 user_id 本人上报进度才能刷新 _progress_at（卡死窗口
        续期）；其他用户即使猜到/拿到 tool_id 也会被拒绝（fail-closed，owner
        记录缺失同样拒绝），避免跨用户续期放大等待窗口。
        """
        client = self._make_client("own")
        ws = _FakeWS()
        box = {}

        def do_request():
            box["res"] = client.request(
                ws, "own",
                {"op": "exec_shell", "workspace_id": "top", "command": "sleep"},
                timeout=30,
            )

        t = threading.Thread(target=do_request)
        t.start()
        msg = ws.wait_message()
        tool_id = msg["data"]["tool_id"]
        self.assertIsNotNone(client._pending.get(tool_id))

        # 他人（未注册该 team 的另一用户）上报进度 → 拒绝，不刷新活动时间
        self.assertFalse(client.note_progress("evil", tool_id))
        self.assertNotIn(tool_id, client._progress_at)

        # 本人上报进度 → 允许续期
        self.assertTrue(client.note_progress("own", tool_id))
        self.assertIn(tool_id, client._progress_at)

        # 正常回传收尾，等待线程安全退出
        self.assertTrue(
            client.resolve("own", tool_id, {"exit_code": 0, "stdout": "done"})
        )
        t.join(timeout=8)
        self.assertEqual(box["res"], {"exit_code": 0, "stdout": "done"})

    def test_note_progress_owner_missing_fails_closed(self):
        """owner 记录缺失（内部状态不一致）时按 fail-closed 拒绝续期。

        手工构造"pending 存在但 _pending_owner 无记录"的异常状态，验证
        note_progress 不因 owner 缺失而放行跨用户/无主续期。
        """
        client = self._make_client("u9")
        ws = _FakeWS()
        box = {}

        def do_request():
            box["res"] = client.request(
                ws, "u9",
                {"op": "exec_shell", "workspace_id": "top", "command": "sleep"},
                timeout=30,
            )

        t = threading.Thread(target=do_request)
        t.start()
        msg = ws.wait_message()
        tool_id = msg["data"]["tool_id"]
        # 破坏不变式：删除 owner 记录，仅保留 pending
        del client._pending_owner[tool_id]
        self.assertFalse(client.note_progress("u9", tool_id))
        self.assertNotIn(tool_id, client._progress_at)
        # 还原并正常收尾，避免影响其他清理
        client._pending_owner[tool_id] = ("u9", "top")
        self.assertTrue(client.resolve("u9", tool_id, {"exit_code": 0, "stdout": "ok"}))
        t.join(timeout=8)
        self.assertEqual(box["res"], {"exit_code": 0, "stdout": "ok"})


if __name__ == "__main__":
    unittest.main()
