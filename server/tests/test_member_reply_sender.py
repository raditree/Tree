# -*- coding: utf-8 -*-
"""成员与发送方之间**不做任何自动回传**：最终回复只留在成员自己的会话。

历史背景：成员处理完消息后，会把最终回复自动回发给"最后发给它的那位发送方"
（``[成员 X 完成回复] ...``），把 leader / 平级 / 顶部 agent 卷进对话。

现口径（用户要求）：message 工具完全移除回传，需要对方知道结果时由 agent
自己主动 ``send_message`` 回发（见 ``tool/message_tool.py`` 的"回复机制"提示
与 prompt 的 message 条目）。因此无论发送方是谁（用户直发 / 顶部 agent /
平级成员）、负载是否携带 ``sender_id``，成员处理完都不回传任何 agent；最终
回复仅落库到成员自己的会话（teammates 进度页可读）。
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


def _run_with_mocks(dispatched, stream, q, payload, stored=None):
    """进入全部 mock 上下文后运行 _process_member_message。"""
    with ExitStack() as stack:
        for p in _make_context(dispatched, stream, q, stored):
            stack.enter_context(p)
        _run(chat_mod._process_member_message(payload, q))


def _fake_dispatch(dispatched):
    def _wrap(user_id, target_ids, content,
              source_agent_id="", team_id="",
              system_prompt="", extra=None):
        dispatched.append(target_ids)
        return {"status": "sent", "sent": list(target_ids), "rejected": []}
    return _wrap


def _make_fake_stream(insert_cb=None):
    """返回 _stream_agent_reply 的替身；可选在 tool_call 间隙调用插入回调。"""
    async def _fake_stream(user_id, agent_id, workspace_id, session,
                           content, on_tool_turn=None, cancel_event=None,
                           session_id=None, team_id=None):
        if insert_cb is not None:
            insert_cb(on_tool_turn)
        return ("成员最终总结内容", "ok", None, "成员最终总结内容")
    return _fake_stream


def _make_context(dispatched, fake_stream, q=None, stored=None):
    """构造 _process_member_message 运行所需的全部 mock 上下文。

    [stored] 传入 list 时记录 ``_store_message`` 的调用（落库断言用）。
    """
    def _fake_store(user_id, agent_id, role, content, session_id=None):
        if stored is not None:
            stored.append((agent_id, role, content, session_id))
        return None

    return [
        patch.object(chat_mod, "_stream_agent_reply", new=fake_stream),
        patch.object(chat_mod, "_dispatch_agent_message",
                     side_effect=_fake_dispatch(dispatched)),
        patch.object(chat_mod, "_store_message", side_effect=_fake_store),
        patch.object(chat_mod, "_register_active_task",
                     return_value=MagicMock()),
        patch.object(chat_mod, "_clear_active_task", return_value=None),
        patch.object(chat_mod, "_send_status_idle", new=AsyncMock()),
        patch.object(chat_mod, "save_context", return_value=None),
        patch.object(chat_mod, "collect_sft_turn", return_value=None),
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


class TestMemberNoAutoForward(unittest.TestCase):
    def setUp(self):
        self.base = {
            "user_id": "u1", "agent_id": "mem-1", "workspace_id": "w1",
            "model_id": "m1", "team_id": "top-1",
            "system_prompt": "", "content": "开工", "session_id": "s1",
        }
        self.q = _queue.Queue()

    def _run_payload(self, payload):
        dispatched = []
        stream = _make_fake_stream()
        _run_with_mocks(dispatched, stream, self.q, payload)
        return dispatched

    def test_user_direct_no_auto_forward(self):
        """用户直发（sender_id=""）→ 不回传任何 agent。"""
        payload = dict(self.base, leader_id="top-1", sender_id="")
        self.assertEqual(self._run_payload(payload), [])

    def test_top_sent_no_auto_forward(self):
        """顶部 agent 直发（sender_id="top-1"）→ 不回传给 top-1。"""
        payload = dict(self.base, leader_id="top-1", sender_id="top-1")
        self.assertEqual(self._run_payload(payload), [])

    def test_peer_sent_no_auto_forward(self):
        """平级成员发送（sender_id="peerA"）→ 不回传给 peerA。"""
        payload = dict(self.base, leader_id="top-1", sender_id="peerA")
        self.assertEqual(self._run_payload(payload), [])

    def test_missing_sender_no_auto_forward(self):
        """老负载（无 sender_id，回退 leader_id）→ 同样不回传。"""
        payload = dict(self.base, leader_id="leader-1")
        self.assertEqual(self._run_payload(payload), [])

    def test_inserted_msg_no_auto_forward(self):
        """中途切入新消息（peerC）→ 处理完仍不回传给最后发送方。"""
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
        self.assertEqual(dispatched, [])

    def test_auto_reply_incoming_no_forward(self):
        """被动 auto_reply 消息（错误回传等）→ 不回传任何 agent。"""
        payload = dict(self.base, leader_id="top-1", sender_id="peerA",
                       auto_reply=True)
        self.assertEqual(self._run_payload(payload), [])

    def test_final_text_kept_in_own_session(self):
        """回传移除后，最终回复仍须落库到成员自己的会话（进度页可读）。"""
        stored = []
        payload = dict(self.base, leader_id="top-1", sender_id="top-1")
        _run_with_mocks([], _make_fake_stream(), self.q, payload, stored)
        replies = [s for s in stored if s[1] == "agent"]
        self.assertEqual(
            [(s[0], s[2], s[3]) for s in replies],
            [("mem-1", "成员最终总结内容", "s1")],
        )


if __name__ == "__main__":
    unittest.main()