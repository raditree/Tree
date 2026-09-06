# -*- coding: utf-8 -*-
"""WebSocketManager 连接治理回归测试（Task 3 B3）。

- 每条连接分配 connection_id，连接表为 user_id -> {connection_id: ws}；
- send_json 经 asyncio.wait_for 超时保护（超时可注入）：挂起的假 ws 在
  超时后被移除并关闭，不无限堆积发送协程；
- 发送异常同样移除连接；
- disconnect_by_id 只移除目标连接，不影响同用户其他并行连接。
"""

import asyncio
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ws.ws_manager import WebSocketManager  # noqa: E402


class _FakeWS:
    """假 WebSocket：send_json 可挂起/抛错，close/accept 记录状态。"""

    def __init__(self, delay: float = 0.0, fail: bool = False):
        self.delay = delay
        self.fail = fail
        self.closed = False
        self.accepted = False
        self.sent = []

    async def accept(self):
        self.accepted = True

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


def test_connect_assigns_unique_connection_id():
    mgr = WebSocketManager()
    ws1, ws2 = _FakeWS(), _FakeWS()
    cid1 = _run(mgr.connect("u1", ws1))
    cid2 = _run(mgr.connect("u1", ws2))
    assert cid1 and cid2 and cid1 != cid2
    assert set(mgr.connections["u1"].keys()) == {cid1, cid2}
    assert ws1.accepted and ws2.accepted


def test_normal_send_delivers_and_keeps_connection():
    mgr = WebSocketManager()
    ws = _FakeWS()
    cid = _run(mgr.connect("u1", ws))
    _run(mgr.send_message("u1", {"type": "heartbeat"}))
    assert ws.sent == [{"type": "heartbeat"}]
    assert mgr.connections["u1"][cid] is ws
    assert not ws.closed


def test_hanging_send_removed_after_injected_timeout():
    """send_json 挂起：注入小超时后连接被移除并关闭，总耗时受控。"""
    mgr = WebSocketManager(send_timeout=0.15)
    slow, good = _FakeWS(delay=5.0), _FakeWS()
    cid_slow = _run(mgr.connect("u1", slow))
    _run(mgr.connect("u1", good))

    t0 = time.time()
    _run(mgr.send_message("u1", {"type": "ping"}))
    elapsed = time.time() - t0

    # 总耗时应接近注入超时（0.15s），远小于慢连接的 5s 挂起时长
    assert elapsed < 2.0, elapsed
    # 慢连接被移除并关闭，好连接保留且收到消息
    assert cid_slow not in mgr.connections.get("u1", {})
    assert slow.closed
    assert good.sent == [{"type": "ping"}]
    assert mgr.connections["u1"] and good in mgr.connections["u1"].values()


def test_send_exception_removes_connection():
    mgr = WebSocketManager()
    bad, good = _FakeWS(fail=True), _FakeWS()
    cid_bad = _run(mgr.connect("u1", bad))
    _run(mgr.connect("u1", good))
    _run(mgr.send_message("u1", {"type": "ping"}))
    assert cid_bad not in mgr.connections.get("u1", {})
    assert bad.closed
    assert good.sent == [{"type": "ping"}]


def test_disconnect_by_id_only_removes_target():
    mgr = WebSocketManager()
    ws1, ws2 = _FakeWS(), _FakeWS()
    cid1 = _run(mgr.connect("u1", ws1))
    _run(mgr.connect("u1", ws2))
    mgr.disconnect_by_id("u1", cid1)
    conns = mgr.connections["u1"]
    assert len(conns) == 1
    assert ws2 in conns.values()


def test_send_to_user_without_connections_is_noop():
    mgr = WebSocketManager()
    _run(mgr.send_message("ghost", {"type": "heartbeat"}))


def test_broadcast_removes_dead_connections():
    mgr = WebSocketManager(send_timeout=0.15)
    good = _FakeWS()
    slow = _FakeWS(delay=5.0)
    _run(mgr.connect("u1", good))
    _run(mgr.connect("u2", slow))
    _run(mgr.broadcast({"type": "notice"}))
    assert good.sent == [{"type": "notice"}]
    assert slow.closed
    assert "u2" not in mgr.connections
    assert "u1" in mgr.connections
