# -*- coding: utf-8 -*-
"""团队成员 OpenAI 调用上下文的 session 分隔回归测试。

审计结论（用户要求核查）：成员会话/上下文/历史均按
``(user_id, member_id, session_id)`` 键隔离，session_id 由 leader 工具调用
所在会话经 broker payload 透传（投递层用例见
test_8items_rest_api.TestTeamMemberSessionIsolation）。本文件锁定处理层契约：

1. 会话缓存：同一成员不同会话是两个独立会话对象，互不串扰；
2. 处理函数：``_process_member_message`` 以 payload 的 session_id 建会话
   （set_session）、存上下文（save_context）、存历史（_store_message）——
   两条不同 session 的消息落在各自的键上；缺 session_id 时回退默认会话
   （防御性兜底，固化既有行为）；
3. 队列切入：跨会话的排队消息不会切入当前轮次（``_pick_incoming`` 隔离），
   处理完后仍留在队列，由 worker 作为独立消息继续处理；
4. ``agent_context`` 表按 (user, member, session) 独立存取（真实 DB 断言）。
"""

import asyncio
import queue as _queue
import shutil
import sys
import tempfile
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agent import chat as chat_mod  # noqa: E402
from data import session_cache  # noqa: E402


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


def _make_context(captured, fake_stream, q=None):
    """构造 _process_member_message 运行所需的全部 mock 上下文。

    ``captured`` 为 dict，用于捕获 set_session / save_context / _store_message
    的调用（key: "set_session" / "save_context" / "store"，值：kwargs 列表）。
    """
    captured.setdefault("set_session", [])
    captured.setdefault("save_context", [])
    captured.setdefault("store", [])
    captured.setdefault("sft", [])

    def _fake_set_session(user_id, agent_id, session, session_id):
        captured["set_session"].append(
            {"user_id": user_id, "agent_id": agent_id, "session_id": session_id}
        )

    def _fake_save_context(user_id, agent_id, context, session_id=None):
        captured["save_context"].append(
            {"user_id": user_id, "agent_id": agent_id, "session_id": session_id}
        )

    def _fake_store_message(user_id, agent_id, role, content,
                            session_id=None, **kwargs):
        captured["store"].append(
            {"user_id": user_id, "agent_id": agent_id,
             "role": role, "session_id": session_id}
        )

    def _fake_collect_sft(user_id, agent_id, session_id,
                          context_before, context_after, agent_type="top"):
        captured["sft"].append({
            "user_id": user_id, "agent_id": agent_id,
            "session_id": session_id, "agent_type": agent_type,
            "before_len": len(context_before),
            "after_len": len(context_after),
        })

    return [
        patch.object(chat_mod, "_stream_agent_reply", new=fake_stream),
        patch.object(chat_mod, "_dispatch_agent_message",
                     return_value={"status": "sent"}),
        patch.object(chat_mod, "_store_message", side_effect=_fake_store_message),
        patch.object(chat_mod, "_register_active_task", return_value=MagicMock()),
        patch.object(chat_mod, "_clear_active_task", return_value=None),
        patch.object(chat_mod, "_send_status_idle", new=AsyncMock()),
        patch.object(chat_mod, "save_context", side_effect=_fake_save_context),
        patch.object(chat_mod, "collect_sft_turn", side_effect=_fake_collect_sft),
        patch.object(chat_mod, "_append_activity_log", return_value=None),
        patch.object(chat_mod, "_register_tools", new=AsyncMock()),
        patch.object(chat_mod, "get_session", return_value=None),
        patch.object(chat_mod, "load_context", return_value=None),
        patch.object(chat_mod, "set_session", side_effect=_fake_set_session),
        patch.object(chat_mod, "_build_workspace_extra_info", return_value={}),
        patch.object(chat_mod, "_build_agent_system_prompt", return_value="sys"),
        patch("agent.chat.state.model_configs", {
            "m1": MagicMock(api_key="k", name="M1", if_vision=False),
        }),
        patch("agent.chat.state.ws_manager",
              MagicMock(send_message=AsyncMock())),
    ]


def _fake_stream_ok():
    """_stream_agent_reply 替身：直接返回固定回复，不触发切入回调。"""

    async def _fake(user_id, agent_id, workspace_id, session,
                    content, on_tool_turn=None, cancel_event=None,
                    session_id=None, team_id=None):
        return ("成员回复", "ok", None, "成员回复")

    return _fake


def _run_payload(payload, q=None):
    captured = {}
    stream = _fake_stream_ok()
    with ExitStack() as stack:
        for p in _make_context(captured, stream, q):
            stack.enter_context(p)
        _run(chat_mod._process_member_message(payload, q))
    return captured


class TestMemberSessionCacheIsolation(unittest.TestCase):
    """会话缓存按 (user, member, session) 键隔离。"""

    def setUp(self):
        session_cache._sessions.clear()

    def tearDown(self):
        session_cache._sessions.clear()

    def test_same_member_different_sessions_isolated(self):
        """同一成员两个会话是独立对象，清理一个不影响另一个。"""
        s1 = MagicMock()
        s2 = MagicMock()
        session_cache.set_session("u1", "m1", s1, "s1")
        session_cache.set_session("u1", "m1", s2, "s2")
        self.assertIs(session_cache.get_session("u1", "m1", "s1"), s1)
        self.assertIs(session_cache.get_session("u1", "m1", "s2"), s2)

        # 精确清理 s1：s2 与默认会话均不受影响
        session_cache.clear_user_agent("u1", "m1", session_id="s1")
        self.assertIsNone(session_cache.get_session("u1", "m1", "s1"))
        self.assertIs(session_cache.get_session("u1", "m1", "s2"), s2)

    def test_clear_member_keeps_other_members(self):
        """按 agent 清理只影响该成员，其他成员/其他用户不受影响。"""
        session_cache.set_session("u1", "m1", MagicMock(), "s1")
        session_cache.set_session("u1", "m2", MagicMock(), "s1")
        session_cache.set_session("u2", "m1", MagicMock(), "s1")
        cleared = session_cache.clear_user_agent("u1", "m1")
        self.assertEqual(cleared, 1)
        self.assertIsNone(session_cache.get_session("u1", "m1", "s1"))
        self.assertIsNotNone(session_cache.get_session("u1", "m2", "s1"))
        self.assertIsNotNone(session_cache.get_session("u2", "m1", "s1"))


class TestProcessMemberMessageSessionKeys(unittest.TestCase):
    """处理函数以 payload 的 session_id 落键（会话/上下文/历史）。"""

    BASE = {
        "user_id": "u1", "agent_id": "mem-1", "workspace_id": "w1",
        "model_id": "m1", "team_id": "top-1",
        "system_prompt": "", "content": "开工",
    }

    def test_two_sessions_use_distinct_keys(self):
        """同一成员两条不同 session 的消息落在各自键上。"""
        q = _queue.Queue()
        captured1 = _run_payload(dict(self.BASE, session_id="s1"), q)
        captured2 = _run_payload(dict(self.BASE, session_id="s2"), q)

        # 建会话：两次各以自己 session 落键
        self.assertEqual(captured1["set_session"][0]["session_id"], "s1")
        self.assertEqual(captured2["set_session"][0]["session_id"], "s2")
        # 存上下文：同样按各自 session
        self.assertEqual(captured1["save_context"][0]["session_id"], "s1")
        self.assertEqual(captured2["save_context"][0]["session_id"], "s2")
        # 历史（user 消息 + agent 回复）全部落在各自 session
        self.assertEqual(
            {m["session_id"] for m in captured1["store"]}, {"s1"},
        )
        self.assertEqual(
            {m["session_id"] for m in captured2["store"]}, {"s2"},
        )
        # 键归属正确（user 消息来自成员，agent 消息也属于成员本人）
        self.assertEqual(captured1["store"][0]["agent_id"], "mem-1")

    def test_missing_session_id_falls_back_to_default(self):
        """负载缺 session_id 时回退默认会话（防御性兜底）。"""
        q = _queue.Queue()
        captured = _run_payload(dict(self.BASE), q)
        self.assertEqual(
            captured["set_session"][0]["session_id"], "session_default",
        )
        self.assertEqual(
            captured["save_context"][0]["session_id"], "session_default",
        )
        self.assertEqual(
            {m["session_id"] for m in captured["store"]},
            {"session_default"},
        )


class TestCrossSessionQueueIsolation(unittest.TestCase):
    """跨会话排队消息不切入当前轮次（_pick_incoming 隔离）。"""

    BASE = {
        "user_id": "u1", "agent_id": "mem-1", "workspace_id": "w1",
        "model_id": "m1", "team_id": "top-1",
        "system_prompt": "", "content": "当前会话任务",
    }

    def test_other_session_msg_stays_queued(self):
        """处理 s1 时队列中的 s2 消息不被切入，处理完仍在队列。"""
        q = _queue.Queue()
        q.put_nowait(dict(self.BASE, content="另一会话消息", session_id="s2"))
        picked = {}

        async def _fake_stream(user_id, agent_id, workspace_id, session,
                               content, on_tool_turn=None, cancel_event=None,
                               session_id=None, team_id=None):
            # 模拟 tool_call 间隙的切入检查
            picked["value"] = on_tool_turn() if on_tool_turn else None
            return ("成员回复", "ok", None, "成员回复")

        captured = {}
        with ExitStack() as stack:
            for p in _make_context(captured, _fake_stream, q):
                stack.enter_context(p)
            _run(chat_mod._process_member_message(
                dict(self.BASE, session_id="s1"), q,
            ))

        # 跨会话消息未切入当前轮次
        self.assertIsNone(picked["value"])
        # 消息被放回队列，作为独立消息后续处理（不串入 s1 上下文）
        self.assertEqual(q.qsize(), 1)
        remaining = q.get_nowait()
        self.assertEqual(remaining["session_id"], "s2")

    def test_same_session_msg_cuts_in(self):
        """同会话排队消息正常切入当前轮次。"""
        q = _queue.Queue()
        q.put_nowait(dict(self.BASE, content="同会话插话", session_id="s1"))
        picked = {}

        async def _fake_stream(user_id, agent_id, workspace_id, session,
                               content, on_tool_turn=None, cancel_event=None,
                               session_id=None, team_id=None):
            picked["value"] = on_tool_turn() if on_tool_turn else None
            return ("成员回复", "ok", None, "成员回复")

        captured = {}
        with ExitStack() as stack:
            for p in _make_context(captured, _fake_stream, q):
                stack.enter_context(p)
            _run(chat_mod._process_member_message(
                dict(self.BASE, session_id="s1"), q,
            ))

        self.assertEqual(picked["value"], "同会话插话")
        self.assertEqual(q.qsize(), 0)


class TestMemberSftCollection(unittest.TestCase):
    """成员轮次同样进入 SFT 数据收集（agent_type=member，按成员分键）。"""

    BASE = {
        "user_id": "u1", "agent_id": "mem-1", "workspace_id": "w1",
        "model_id": "m1", "team_id": "top-1",
        "system_prompt": "", "content": "开工",
    }

    def test_member_turn_collected_with_member_type(self):
        """成员处理一轮后 collect_sft_turn 以成员键 + member 类型调用。"""
        q = _queue.Queue()
        captured = _run_payload(dict(self.BASE, session_id="s1"), q)

        self.assertEqual(len(captured["sft"]), 1)
        call = captured["sft"][0]
        self.assertEqual(call["user_id"], "u1")
        self.assertEqual(call["agent_id"], "mem-1")
        self.assertEqual(call["session_id"], "s1")
        self.assertEqual(call["agent_type"], "member")
        # 基线 = 处理前上下文，after 应覆盖完整工具循环产出
        self.assertGreaterEqual(call["after_len"], call["before_len"])

    def test_member_turns_separated_by_session(self):
        """同一成员不同会话的 SFT 行按各自 session 分键。"""
        q = _queue.Queue()
        c1 = _run_payload(dict(self.BASE, session_id="s1"), q)
        c2 = _run_payload(dict(self.BASE, session_id="s2"), q)
        self.assertEqual(c1["sft"][0]["session_id"], "s1")
        self.assertEqual(c2["sft"][0]["session_id"], "s2")


class TestAgentContextDbIsolation(unittest.TestCase):
    """agent_context 表按 (user, member, session) 独立存取。"""

    def setUp(self):
        self._tmp = Path(tempfile.mkdtemp(prefix="member_iso_"))
        import data.conversation_store as conv_store
        import data.db as db_mod

        self._conv_store = conv_store
        self._db_mod = db_mod
        self._orig = (conv_store._DB_PATH, conv_store._initialized,
                      db_mod._DB_PATH, db_mod._wal_configured)
        conv_store._DB_PATH = self._tmp / "conversations.db"
        conv_store._initialized = False
        db_mod._DB_PATH = self._tmp / "conversations.db"
        db_mod._wal_configured = False

    def tearDown(self):
        (self._conv_store._DB_PATH, self._conv_store._initialized,
         self._db_mod._DB_PATH, self._db_mod._wal_configured) = self._orig
        shutil.rmtree(self._tmp, ignore_errors=True)

    def test_context_roundtrip_per_session(self):
        """同成员两个会话的上下文独立存取，互不覆盖。"""
        from data.conversation_store import (
            clear_context,
            load_context,
            save_context,
        )

        ctx1 = [{"role": "system", "content": "sys"}, {"role": "user", "content": "a"}]
        ctx2 = [{"role": "system", "content": "sys"}, {"role": "user", "content": "b"}]
        save_context("u1", "m1", ctx1, session_id="s1")
        save_context("u1", "m1", ctx2, session_id="s2")
        # 另一成员同会话也不覆盖
        save_context("u1", "m2", [{"role": "user", "content": "other"}], session_id="s1")

        self.assertEqual(load_context("u1", "m1", "s1"), ctx1)
        self.assertEqual(load_context("u1", "m1", "s2"), ctx2)
        self.assertEqual(load_context("u1", "m2", "s1"),
                         [{"role": "user", "content": "other"}])

        # 软删除只影响指定会话
        clear_context("u1", "m1", session_id="s1")
        self.assertIsNone(load_context("u1", "m1", "s1"))
        self.assertEqual(load_context("u1", "m1", "s2"), ctx2)


if __name__ == "__main__":
    unittest.main()
