# -*- coding: utf-8 -*-
"""前端执行器（本地/SSH）请求定向投递回归测试。

背景：同用户可能并行开多个前端实例（每个实例一条 WS 连接），后端原先按
``user_id`` 广播工具执行请求，导致"非目标实例"也会收到请求。它既不能执行
（未注册/未启用本地模式），又不敢回传错误——回传的失败包会先于真正执行器
的成功结果到达，被 ``resolve`` 取作结果并占位（``fut.done()`` 后丢弃真正的
结果）。于是只能静默放行，后端则空等满卡死窗口（60s）。

改为按"注册该 team 执行器的那条连接"定向投递后，非目标实例收不到请求，
目标实例即可安全地对"本端不可执行"回传明确错误。本测试覆盖：

- ``WebSocketManager.send_to_connection`` 的定向语义（只投目标连接 /
  连接不存在返回 False / 死链移除并返回 False）；
- ``LocalExecutorClient.request`` 只投给注册连接，并携带 ``targeted`` 标志
  （前端据此决定可否回传错误）；
- 未记录注册连接时回落广播且 ``targeted=False``（兼容历史调用/测试替身）；
- 注册连接已消失时快速失败（不空等响应超时）；
- 注销的跨连接归属校验（其他实例接管后，先注册实例断连不清掉生效中的注册）。
"""

import asyncio
import sys
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from io_.local_executor import LocalExecutorClient  # noqa: E402
from ws.ws_manager import WebSocketManager  # noqa: E402


class _FakeWSManager:
    """ws_manager 替身：区分"定向投递"与"广播"，并模拟连接存活表。"""

    def __init__(self, alive=()):
        # 现存连接 id 集合：定向投递的目标不在其中时返回 False
        self.alive = set(alive)
        self.broadcast = []          # 广播收到的消息
        self.targeted = []           # (connection_id, message)

    async def send_message(self, user_id, message):
        self.broadcast.append(message)

    async def send_to_connection(self, user_id, connection_id, message):
        if connection_id not in self.alive:
            return False
        self.targeted.append((connection_id, message))
        return True

    def targeted_messages(self):
        return [m for _, m in self.targeted]

    def wait_targeted(self, timeout=5.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.targeted:
                return self.targeted[0][1]
            time.sleep(0.005)
        raise AssertionError("未收到定向投递的 tool_exec_request")


class _FakeWebSocket:
    """假 WebSocket：send_json 可挂起/抛错。"""

    def __init__(self, delay=0.0, fail=False):
        self.delay = delay
        self.fail = fail
        self.closed = False
        self.sent = []

    async def accept(self):
        pass

    async def send_json(self, message):
        if self.fail:
            raise RuntimeError("send failed")
        if self.delay:
            await asyncio.sleep(self.delay)
        self.sent.append(message)

    async def close(self):
        self.closed = True


def _run(coro):
    return asyncio.run(coro)


class TestWsManagerSendToConnection(unittest.TestCase):
    """WebSocketManager.send_to_connection 定向投递语义。"""

    def test_only_target_connection_receives(self):
        """同用户两条连接：只投目标连接，另一条收不到。"""
        mgr = WebSocketManager()
        target, other = _FakeWebSocket(), _FakeWebSocket()
        cid_target = _run(mgr.connect("u1", target))
        _run(mgr.connect("u1", other))

        delivered = _run(
            mgr.send_to_connection("u1", cid_target, {"type": "tool_exec_request"})
        )

        self.assertTrue(delivered)
        self.assertEqual(target.sent, [{"type": "tool_exec_request"}])
        self.assertEqual(other.sent, [])

    def test_unknown_connection_returns_false(self):
        """目标连接不存在（或用户无连接）时返回 False，供调用方快速失败。"""
        mgr = WebSocketManager()
        _run(mgr.connect("u1", _FakeWebSocket()))
        self.assertFalse(_run(mgr.send_to_connection("u1", "no-such", {"a": 1})))
        self.assertFalse(_run(mgr.send_to_connection("ghost", "no-such", {"a": 1})))

    def test_failed_target_removed_and_returns_false(self):
        """目标连接发送异常：移除并关闭，返回 False。"""
        mgr = WebSocketManager()
        bad = _FakeWebSocket(fail=True)
        cid = _run(mgr.connect("u1", bad))

        delivered = _run(mgr.send_to_connection("u1", cid, {"type": "ping"}))

        self.assertFalse(delivered)
        self.assertTrue(bad.closed)
        self.assertNotIn(cid, mgr.connections.get("u1", {}))


class TestRequestTargetedDelivery(unittest.TestCase):
    """request 按注册连接定向投递，并随请求下发 targeted 标志。"""

    def test_request_delivered_only_to_registered_connection(self):
        client = LocalExecutorClient()
        client.register("u1", "topA", "C:/a", "conn-a")
        ws = _FakeWSManager(alive={"conn-a", "conn-b"})
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
        msg = ws.wait_targeted()
        # 只投给注册连接 conn-a；未广播给同用户其他连接
        self.assertEqual([cid for cid, _ in ws.targeted], ["conn-a"])
        self.assertEqual(ws.broadcast, [])
        # 前端据此判断"请求确实发给了本端"，可安全回传明确错误
        self.assertIs(msg["data"]["targeted"], True)

        self.assertTrue(client.resolve("u1", msg["data"]["tool_id"], {"content": "ok"}))
        t.join(timeout=8)
        self.assertEqual(box["res"], {"content": "ok"})

    def test_request_falls_back_to_broadcast_without_connection(self):
        """未记录注册连接（历史调用/测试替身）：回落广播且 targeted=False。"""
        client = LocalExecutorClient()
        client.register("u1", "topA", "C:/a")
        ws = _FakeWSManager()
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
        deadline = time.time() + 5
        while time.time() < deadline and not ws.broadcast:
            time.sleep(0.005)
        self.assertEqual(len(ws.broadcast), 1)
        self.assertEqual(ws.targeted, [])
        # 广播下前端不得回错（会与真正执行器的结果竞争），故标志为 False
        self.assertIs(ws.broadcast[0]["data"]["targeted"], False)

        tool_id = ws.broadcast[0]["data"]["tool_id"]
        self.assertTrue(client.resolve("u1", tool_id, {"content": "ok"}))
        t.join(timeout=8)
        self.assertEqual(box["res"], {"content": "ok"})

    def test_request_fails_fast_when_registered_connection_gone(self):
        """注册连接已消失：立即返回明确错误，不空等响应超时、不残留 pending。"""
        client = LocalExecutorClient()
        client.register("u1", "topA", "C:/a", "conn-gone")
        ws = _FakeWSManager(alive={"conn-other"})

        t0 = time.time()
        res = client.request(
            ws, "u1",
            {"op": "read_file", "workspace_id": "topA",
             "path": "a.txt", "team_id": "topA"},
            timeout=120,
        )
        elapsed = time.time() - t0

        self.assertIn("连接已断开", res.get("error", ""))
        self.assertLess(elapsed, 5.0)
        self.assertEqual(len(client._pending), 0)
        self.assertEqual(ws.broadcast, [])


class TestUnregisterOwnership(unittest.TestCase):
    """注销的连接归属校验：其他实例接管后不受先注册实例影响。"""

    def test_other_connection_unregister_is_rejected(self):
        client = LocalExecutorClient()
        client.register("u1", "topA", "C:/a", "conn-a")
        # 同用户另一实例（conn-b）后注册：接管该 team 的执行器
        client.register("u1", "topA", "C:/b", "conn-b")
        self.assertEqual(client.executor_connection("u1", "topA"), "conn-b")

        # 先注册实例（conn-a）断连清理：不得清掉 conn-b 生效中的注册
        self.assertFalse(client.unregister("u1", "topA", "conn-a"))
        self.assertTrue(client.is_local("u1", "topA"))
        self.assertEqual(client.base_dir_of("u1", "topA"), "C:/b")
        self.assertEqual(client.executor_connection("u1", "topA"), "conn-b")

        # 归属连接自己注销：正常生效
        self.assertTrue(client.unregister("u1", "topA", "conn-b"))
        self.assertFalse(client.is_local("u1", "topA"))
        self.assertEqual(client.executor_connection("u1", "topA"), "")

    def test_ssh_unregister_respects_ownership(self):
        client = LocalExecutorClient()
        client.register_ssh("u1", "topA", "conn-a")
        client.register_ssh("u1", "topA", "conn-b")

        self.assertFalse(client.unregister_ssh("u1", "topA", "conn-a"))
        self.assertTrue(client.is_ssh("u1", "topA"))
        self.assertTrue(client.unregister_ssh("u1", "topA", "conn-b"))
        self.assertFalse(client.is_ssh("u1", "topA"))

    def test_unregister_without_connection_is_unconditional(self):
        """内部自动停用等未带连接 id 的调用保持原有语义（无条件注销）。"""
        client = LocalExecutorClient()
        client.register("u1", "topA", "C:/a", "conn-a")

        self.assertTrue(client.unregister("u1", "topA"))
        self.assertFalse(client.is_local("u1", "topA"))


if __name__ == "__main__":
    unittest.main()
