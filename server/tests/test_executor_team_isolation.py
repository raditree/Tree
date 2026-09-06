# -*- coding: utf-8 -*-
"""LocalExecutorClient 按 (user_id, team_id) 隔离与自动停用回归测试。

Task 3（B1/B2）回归：
- 请求 id 形如 ``{user_id}:{team_id}:{uuid}``，pending/计数按 (user_id, team_id)
  粒度隔离：同用户两个 team 并行请求互不串扰；
- 注销 team A 不影响 team B 的在途请求（B 的 pending 正常完成）；
- local 与 SSH 执行器连续超时达到阈值后自动停用该 (user_id, team_id) 的注册，
  SSH 同时注销持久化配置，使后续 resolve_mode 回落 cloud。
"""

import asyncio
import sys
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from io_.local_executor import LocalExecutorClient  # noqa: E402


class _FakeWS:
    """极简 ws_manager 替身：记录推送消息，send_message 为异步方法。"""

    def __init__(self):
        self.sent = []
        self._lock = threading.Lock()

    async def send_message(self, user_id, message):
        with self._lock:
            self.sent.append(message)

    def messages(self):
        with self._lock:
            return list(self.sent)

    def wait_message(self, timeout=5.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            msgs = self.messages()
            if msgs:
                return msgs[0]
            time.sleep(0.005)
        raise AssertionError("未收到 tool_exec_request 推送")


class TestTeamIsolation(unittest.TestCase):
    """同用户两个 team 并行请求互不串扰。"""

    def test_request_id_contains_user_and_team(self):
        """请求 id 必须携带 user_id 与 team_id 前缀（隔离粒度自描述）。"""
        client = LocalExecutorClient()
        client.register("u1", "topA", "C:/a")
        ws = _FakeWS()
        box = {}

        def do_request():
            box["res"] = client.request(
                ws, "u1", {"op": "read_file", "workspace_id": "topA",
                           "path": "a.txt", "team_id": "topA"},
                timeout=8,
            )

        t = threading.Thread(target=do_request)
        t.start()
        msg = ws.wait_message()
        tool_id = msg["data"]["tool_id"]
        self.assertTrue(tool_id.startswith("u1:topA:"), tool_id)
        self.assertTrue(client.resolve("u1", tool_id, {"exit_code": 0}))
        t.join(timeout=8)
        self.assertEqual(box["res"], {"exit_code": 0})

    def test_two_teams_parallel_requests_no_crosstalk(self):
        """同用户 teamA/teamB 并行请求：fake 前端应答不同 tool_id，各自拿到正确结果。"""
        client = LocalExecutorClient()
        client.register("u1", "topA", "C:/a")
        client.register("u1", "topB", "C:/b")
        ws = _FakeWS()
        boxes = {"topA": {}, "topB": {}}

        def do_request(team):
            boxes[team]["res"] = client.request(
                ws, "u1",
                {"op": "exec_shell", "workspace_id": team,
                 "command": f"echo {team}", "team_id": team},
                timeout=8,
            )

        t_a = threading.Thread(target=do_request, args=("topA",))
        t_b = threading.Thread(target=do_request, args=("topB",))
        t_a.start()
        t_b.start()

        # 等两个请求都推送出去
        deadline = time.time() + 5
        while time.time() < deadline and len(ws.messages()) < 2:
            time.sleep(0.005)
        msgs = ws.messages()
        self.assertEqual(len(msgs), 2)
        tool_id_a = next(
            m["data"]["tool_id"] for m in msgs
            if m["data"]["team_id"] == "topA"
        )
        tool_id_b = next(
            m["data"]["tool_id"] for m in msgs
            if m["data"]["team_id"] == "topB"
        )
        self.assertNotEqual(tool_id_a, tool_id_b)

        # 各自应答：teamA → 结果 A，teamB → 结果 B
        self.assertTrue(client.resolve("u1", tool_id_a, {"stdout": "A"}))
        self.assertTrue(client.resolve("u1", tool_id_b, {"stdout": "B"}))
        t_a.join(timeout=8)
        t_b.join(timeout=8)
        self.assertEqual(boxes["topA"]["res"], {"stdout": "A"})
        self.assertEqual(boxes["topB"]["res"], {"stdout": "B"})
        self.assertEqual(len(client._pending), 0)

    def test_unregister_team_a_does_not_kill_team_b_pending(self):
        """注销 team A 只失效 A 的 pending；team B 的在途请求正常完成。"""
        client = LocalExecutorClient()
        client.register("u1", "topA", "C:/a")
        client.register("u1", "topB", "C:/b")
        ws = _FakeWS()
        boxes = {"topA": {}, "topB": {}}

        def do_request(team):
            boxes[team]["res"] = client.request(
                ws, "u1",
                {"op": "exec_shell", "workspace_id": team,
                 "command": "x", "team_id": team},
                timeout=8,
            )

        t_a = threading.Thread(target=do_request, args=("topA",))
        t_b = threading.Thread(target=do_request, args=("topB",))
        t_a.start()
        t_b.start()
        deadline = time.time() + 5
        while time.time() < deadline and len(ws.messages()) < 2:
            time.sleep(0.005)
        msgs = ws.messages()
        tool_id_a = next(
            m["data"]["tool_id"] for m in msgs
            if m["data"]["team_id"] == "topA"
        )
        tool_id_b = next(
            m["data"]["tool_id"] for m in msgs
            if m["data"]["team_id"] == "topB"
        )

        # 注销 team A：A 的 pending 立即失败，B 不受影响
        client.unregister("u1", "topA")
        t_a.join(timeout=8)
        self.assertIn("error", boxes["topA"]["res"])
        self.assertFalse(client.is_local("u1", "topA"))
        self.assertTrue(client.is_local("u1", "topB"))

        # team B 正常应答完成
        self.assertTrue(client.resolve("u1", tool_id_b, {"stdout": "B-ok"}))
        t_b.join(timeout=8)
        self.assertEqual(boxes["topB"]["res"], {"stdout": "B-ok"})

    def test_resolve_rejects_cross_user_response(self):
        """其他用户的 tool_exec_response 不能唤醒本用户 pending。"""
        client = LocalExecutorClient()
        client.register("u1", "topA", "C:/a")
        ws = _FakeWS()
        box = {}

        def do_request():
            box["res"] = client.request(
                ws, "u1",
                {"op": "read_file", "workspace_id": "topA",
                 "path": "a.txt", "team_id": "topA"},
                timeout=8,
            )

        t = threading.Thread(target=do_request)
        t.start()
        msg = ws.wait_message()
        tool_id = msg["data"]["tool_id"]
        self.assertFalse(client.resolve("u2", tool_id, {"stdout": "evil"}))
        self.assertTrue(client.resolve("u1", tool_id, {"stdout": "ok"}))
        t.join(timeout=8)
        self.assertEqual(box["res"], {"stdout": "ok"})

    def test_resolve_rejects_mismatched_team(self):
        """tool_exec_response 携带错误 team_id 时拒绝配对。"""
        client = LocalExecutorClient()
        client.register("u1", "topA", "C:/a")
        ws = _FakeWS()
        box = {}

        def do_request():
            box["res"] = client.request(
                ws, "u1",
                {"op": "read_file", "workspace_id": "topA",
                 "path": "a.txt", "team_id": "topA"},
                timeout=8,
            )

        t = threading.Thread(target=do_request)
        t.start()
        msg = ws.wait_message()
        tool_id = msg["data"]["tool_id"]
        self.assertFalse(
            client.resolve("u1", tool_id, {"stdout": "x"}, team_id="topB")
        )
        self.assertTrue(
            client.resolve("u1", tool_id, {"stdout": "ok"}, team_id="topA")
        )
        t.join(timeout=8)
        self.assertEqual(box["res"], {"stdout": "ok"})


class TestTimeoutAutoDisable(unittest.TestCase):
    """连续超时自动停用：local 与 SSH 规则一致，且只影响该 team。"""

    def _request_no_response(self, client, user, team, timeout=0.2):
        """发起一次无人响应的请求（执行器失联场景），返回结果字典。"""
        return client.request(
            _FakeWS(), user,
            {"op": "exec_shell", "workspace_id": team, "command": "x",
             "team_id": team},
            timeout=timeout,
        )

    def test_local_timeout_only_disables_target_team(self):
        """local 连续超时停用该 team；同用户其他 team 的注册保留。"""
        client = LocalExecutorClient()
        client.register("u1", "topA", "C:/a")
        client.register("u1", "topB", "C:/b")
        for _ in range(2):
            self._request_no_response(client, "u1", "topA")
        self.assertFalse(client.is_local("u1", "topA"))
        self.assertTrue(client.is_local("u1", "topB"))

        # 停用后该 team 请求立即失败（fail fast）
        t0 = time.time()
        res = self._request_no_response(client, "u1", "topA", timeout=5)
        self.assertIn("error", res)
        self.assertLess(time.time() - t0, 0.5)

    def test_ssh_timeout_disables_executor_and_falls_back_cloud(self):
        """SSH 连续超时后：SSH 注册注销 + 持久化配置注销 → resolve_mode 回落 cloud。"""
        import state
        from io_ import mode_resolver

        client = LocalExecutorClient()
        client.register_ssh("u1", "topA")
        client.register_ssh("u1", "topB")

        unregistered = []

        class _FakeSSHManager:
            def is_ssh(self, user_id, team_id):
                return team_id not in unregistered

            def unregister(self, user_id, team_id):
                unregistered.append(team_id)
                return True

        old_ssh_manager = state.ssh_manager
        old_local_executor = state.local_executor
        state.ssh_manager = _FakeSSHManager()
        state.local_executor = client
        try:
            for _ in range(2):
                self._request_no_response(client, "u1", "topA")
            # SSH 注册被注销，且持久化配置一并注销
            self.assertFalse(client.is_ssh("u1", "topA"))
            self.assertIn("topA", unregistered)
            # 同用户其他 team 不受影响
            self.assertTrue(client.is_ssh("u1", "topB"))
            self.assertNotIn("topB", unregistered)
            # 停用后请求立即失败（不再空等）
            t0 = time.time()
            res = self._request_no_response(client, "u1", "topA", timeout=5)
            self.assertIn("error", res)
            self.assertLess(time.time() - t0, 0.5)
            # 模式判定回落 cloud（该 team 的 SSH 配置已删）
            self.assertEqual(mode_resolver.resolve_mode("u1", "topA"), "cloud")
            self.assertEqual(mode_resolver.resolve_mode("u1", "topB"), "ssh")
        finally:
            state.ssh_manager = old_ssh_manager
            state.local_executor = old_local_executor

    def test_ssh_unregister_team_isolation(self):
        """注销 SSH team A 不影响 team B 的在途请求。"""
        client = LocalExecutorClient()
        client.register_ssh("u1", "topA")
        client.register_ssh("u1", "topB")
        ws = _FakeWS()
        boxes = {"topA": {}, "topB": {}}

        def do_request(team):
            boxes[team]["res"] = client.request(
                ws, "u1",
                {"op": "exec_shell", "workspace_id": team,
                 "command": "x", "team_id": team},
                timeout=8,
            )

        t_a = threading.Thread(target=do_request, args=("topA",))
        t_b = threading.Thread(target=do_request, args=("topB",))
        t_a.start()
        t_b.start()
        deadline = time.time() + 5
        while time.time() < deadline and len(ws.messages()) < 2:
            time.sleep(0.005)
        msgs = ws.messages()
        tool_id_b = next(
            m["data"]["tool_id"] for m in msgs
            if m["data"]["team_id"] == "topB"
        )

        client.unregister_ssh("u1", "topA")
        t_a.join(timeout=8)
        self.assertIn("error", boxes["topA"]["res"])

        self.assertTrue(client.resolve("u1", tool_id_b, {"stdout": "B-ok"}))
        t_b.join(timeout=8)
        self.assertEqual(boxes["topB"]["res"], {"stdout": "B-ok"})
        self.assertTrue(client.is_ssh("u1", "topB"))

    def test_timeout_counters_isolated_per_team(self):
        """超时计数按 (user_id, team_id) 记录：A 超时不累计到 B。"""
        client = LocalExecutorClient()
        client.register("u1", "topA", "C:/a")
        client.register("u1", "topB", "C:/b")
        self._request_no_response(client, "u1", "topA")
        self.assertEqual(
            client._consecutive_timeouts.get(("u1", "topA"), 0), 1
        )
        self.assertEqual(
            client._consecutive_timeouts.get(("u1", "topB"), 0), 0
        )
        # B 成功往返后转热，不影响 A 的计数
        ws = _FakeWS()
        box = {}

        def do_request():
            box["res"] = client.request(
                ws, "u1",
                {"op": "read_file", "workspace_id": "topB",
                 "path": "a.txt", "team_id": "topB"},
                timeout=8,
            )

        t = threading.Thread(target=do_request)
        t.start()
        msg = ws.wait_message()
        self.assertTrue(
            client.resolve("u1", msg["data"]["tool_id"], {"exit_code": 0})
        )
        t.join(timeout=8)
        self.assertEqual(box["res"], {"exit_code": 0})
        self.assertEqual(
            client._consecutive_timeouts.get(("u1", "topA"), 0), 1
        )
        self.assertEqual(
            client._consecutive_timeouts.get(("u1", "topB"), 0), 0
        )


if __name__ == "__main__":
    unittest.main()
