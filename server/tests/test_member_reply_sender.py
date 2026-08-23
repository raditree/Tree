# -*- coding: utf-8 -*-
"""成员最终总结回发目标：按"谁发给它的就回发给谁"。

回归场景（用户反馈）：在某会话里向成员 agent 发消息，结果成员的最终总结
被自动回发给 top agent，把 top 卷了进来。根因：回发目标用的是
``leader_id = source_agent_id or top_agent_id``，用户直发时 ``source_agent_id``
为空，兜底成了 top。

修复后：成员负载新增 ``sender_id`` 记录真实发送方（上游/平级/下级 agent，
或用户直发的空串），成员的最终总结回发给这个真实发送方。
feature：中途切入新消息时，自动回复仅回给**最后**发给它的那位发送方。
"""

import asyncio
import queue as _queue
import sys
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agent import chat as chat_mod  # noqa: E402


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


def _run_with_mocks(dispatched, stream, q, payload):
    """进入全部 mock 上下文后运行 _process_member_message。"""
    with ExitStack() as stack:
        for p in _make_context(dispatched, stream, q):
            stack.enter_context(p)
        _run(chat_mod._process_member_message(payload, q))


def _fake_dispatch(dispatched):
    def _wrap(user_id, target_ids, content,
              source_agent_id="", top_agent_id="",
              system_prompt="", extra=None):
        dispatched.append(target_ids)
        return {"status": "sent", "sent": list(target_ids), "rejected": []}
    return _wrap


def _make_fake_stream(insert_cb=None):
    """返回 _stream_agent_reply 的替身；可选在 tool_call 间隙调用插入回调。"""
    async def _fake_stream(user_id, agent_id, workspace_id, session,
                           content, on_tool_turn=None, cancel_event=None,
                           session_id=None):
        if insert_cb is not None:
            insert_cb(on_tool_turn)
        return ("成员最终总结内容", "ok", None)
    return _fake_stream


def _make_context(dispatched, fake_stream, q=None):
    """构造 _process_member_message 运行所需的全部 mock 上下文。"""
    return [
        patch.object(chat_mod, "_stream_agent_reply", new=fake_stream),
        patch.object(chat_mod, "_dispatch_agent_message",
                     side_effect=_fake_dispatch(dispatched)),
        patch.object(chat_mod, "_store_message", return_value=None),
        patch.object(chat_mod, "_register_active_task",
                     return_value=MagicMock()),
        patch.object(chat_mod, "_clear_active_task", return_value=None),
        patch.object(chat_mod, "_send_status_idle", new=AsyncMock()),
        patch.object(chat_mod, "save_context", return_value=None),
        patch.object(chat_mod, "_append_activity_log", return_value=None),
        patch.object(chat_mod, "_register_tools", new=AsyncMock()),
        patch.object(chat_mod, "get_session", return_value=MagicMock()),
        patch.object(chat_mod, "load_context", return_value=None),
        patch.object(chat_mod, "set_session", return_value=None),
        patch.object(chat_mod, "_build_workspace_extra_info",
                     return_value={}),
        patch.object(chat_mod, "_build_agent_system_prompt", return_value="sys"),
        patch("agent.chat.state.model_configs", {
            "m1": MagicMock(api_key="k", name="M1", if_vision=False),
        }),
        patch("agent.chat.state.ws_manager",
              MagicMock(send_message=AsyncMock())),
    ]


class TestMemberReplyToSender(unittest.TestCase):
    def setUp(self):
        self.base = {
            "user_id": "u1", "agent_id": "mem-1", "workspace_id": "w1",
            "model_id": "m1", "top_agent_id": "top-1",
            "system_prompt": "", "content": "开工", "session_id": "s1",
        }
        self.q = _queue.Queue()

    def _run_payload(self, payload):
        dispatched = []
        stream = _make_fake_stream()
        _run_with_mocks(dispatched, stream, self.q, payload)
        return dispatched

    def test_user_direct_no_auto_forward(self):
        """用户直发（sender_id=""）→ 成员总结不转发给任何 agent。"""
        payload = dict(self.base, leader_id="top-1", sender_id="")
        dispatched = self._run_payload(payload)
        self.assertEqual(dispatched, [], "用户直发不应回发给任何 agent")

    def test_top_sent_forwards_to_top(self):
        """顶部 agent 直发（sender_id="top-1"）→ 总结回发给 top-1。"""
        payload = dict(self.base, leader_id="top-1", sender_id="top-1")
        dispatched = self._run_payload(payload)
        self.assertEqual(dispatched, [["top-1"]])

    def test_peer_sent_forwards_to_peer(self):
        """平级成员发送（sender_id="peerA"）→ 总结回发给 peerA，而非 top。"""
        payload = dict(self.base, leader_id="top-1", sender_id="peerA")
        dispatched = self._run_payload(payload)
        self.assertEqual(dispatched, [["peerA"]])

    def test_no_sender_falls_back_to_leader(self):
        """老负载（无 sender_id）→ 回退 leader_id，保持旧行为。"""
        payload = dict(self.base, leader_id="leader-1")
        dispatched = self._run_payload(payload)
        self.assertEqual(dispatched, [["leader-1"]])

    def test_inserted_msg_last_sender_wins(self):
        """feature：中途插入新消息时，最终总结只回给最后发送方 peerC。"""
        # 初始发送方 top-1，中途切入 peerC 发来的消息 → 回发给 peerC
        def _insert(on_tool_turn):
            self.q.put_nowait(dict(self.base, agent_id="mem-1",
                                   leader_id="top-1", sender_id="peerC",
                                   content="插一句", session_id="s1"))
            pulled = on_tool_turn() if on_tool_turn else None
            self.assertTrue(pulled, "插入消息应被切入上下文")

        dispatched = []
        stream = _make_fake_stream(insert_cb=_insert)
        payload = dict(self.base, leader_id="top-1", sender_id="top-1")
        _run_with_mocks(dispatched, stream, self.q, payload)
        self.assertEqual(dispatched, [["peerC"]],
                         "插入消息后应把总结回发给最后发送方 peerC")

    def test_inserted_user_msg_suppresses_forward(self):
        """feature：中途插入用户直发消息（sender_id=""）→ 不回发任何 agent。"""
        def _insert(on_tool_turn):
            self.q.put_nowait(dict(self.base, agent_id="mem-1",
                                   leader_id="top-1", sender_id="",
                                   content="用户插话", session_id="s1"))
            on_tool_turn()

        dispatched = []
        stream = _make_fake_stream(insert_cb=_insert)
        payload = dict(self.base, leader_id="top-1", sender_id="top-1")
        _run_with_mocks(dispatched, stream, self.q, payload)
        self.assertEqual(dispatched, [],
                         "最后发送方为用户时，总结只留在成员会话")


if __name__ == "__main__":
    unittest.main()