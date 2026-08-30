# -*- coding: utf-8 -*-
"""compact 状态机测试：compacting 状态推送与压缩互斥。

覆盖 compact 端点（POST /api/agents/{id}/compact）的状态行为：
- 进入压缩：注册 ``_compacting_tasks`` + 推送 ``agent_status=compacting``；
- 结束：注销登记 + 按实际工作状态推送 working/idle（不误清并行会话的工作标识）；
- 互斥：同会话正在 chat（agent_working）或正在压缩（already_compacting）时拒绝；
- 其他会话 working 不拦截（各自独立 AgentLLMSession）；
- ws_manager 缺失时静默跳过（不使压缩请求失败）；
- 压缩异常时 finally 仍注销登记（状态不卡死）。
"""

import asyncio
import sys
import threading
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agent import chat as chat_mod  # noqa: E402
from agent import routes  # noqa: E402


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


def _make_session():
    """构造可压缩的会话替身（compress 直接返回 True）。"""
    session = MagicMock()
    session.compress.return_value = True
    session.context = [
        {"role": "system", "content": "sys"},
        {"role": "user", "content": "a"},
        {"role": "assistant", "content": "b"},
        {"role": "user", "content": "c"},
        {"role": "assistant", "content": "d"},
    ]
    return session


class TestCompactStatus(unittest.TestCase):
    USER = {"openid": "u1"}
    AGENT = "a1"
    SESSION = "s1"

    def setUp(self):
        chat_mod._compacting_tasks.clear()
        chat_mod._active_tasks.clear()

    def tearDown(self):
        chat_mod._compacting_tasks.clear()
        chat_mod._active_tasks.clear()

    def _run_compact(self, session=None, body=None):
        session = session or _make_session()
        with patch.object(routes, "get_session", return_value=session):
            result = _run(routes.compact_agent_context(
                self.AGENT,
                body=body or {"session_id": self.SESSION},
                current_user=dict(self.USER),
            ))
        return result, session

    def _ws_statuses(self, ws_mock):
        """提取 ws_manager.send_message 推送的全部 agent_status 序列。"""
        statuses = []
        for call in ws_mock.send_message.call_args_list:
            payload = call.args[1]
            if payload.get("type") == "agent_status":
                statuses.append(payload["data"]["status"])
        return statuses

    def test_compacting_events_sequence(self):
        """压缩期间推送 compacting，结束后推送 idle（状态不卡死）。"""
        ws_mock = MagicMock(send_message=AsyncMock())
        with patch.object(routes.state, "ws_manager", ws_mock):
            result, _ = self._run_compact()

        self.assertTrue(result["success"])
        self.assertTrue(result["compressed"])
        statuses = self._ws_statuses(ws_mock)
        self.assertEqual(statuses, ["compacting", "idle"])
        # 会话/状态登记已注销，重连补推不会残留
        self.assertNotIn(("u1", "a1", "s1"), chat_mod._compacting_tasks)
        # 事件带正确会话标识
        first = ws_mock.send_message.call_args_list[0].args[1]
        self.assertEqual(first["data"]["agent_id"], "a1")
        self.assertEqual(first["data"]["session_id"], "s1")

    def test_end_status_working_when_parallel_session_busy(self):
        """其他会话正在工作时，压缩结束推 working 而非 idle（不误清标识）。"""
        chat_mod._active_tasks[("u1", "a1", "s2")] = threading.Event()
        ws_mock = MagicMock(send_message=AsyncMock())
        with patch.object(routes.state, "ws_manager", ws_mock):
            result, _ = self._run_compact()

        self.assertTrue(result["compressed"])
        self.assertEqual(self._ws_statuses(ws_mock), ["compacting", "working"])

    def test_reject_when_same_session_working(self):
        """同会话正在 chat：拒绝压缩，避免与 compress 并发改写上下文。"""
        chat_mod._active_tasks[("u1", "a1", "s1")] = threading.Event()
        session = _make_session()
        result, _ = self._run_compact(session=session)

        self.assertEqual(result["reason"], "agent_working")
        session.compress.assert_not_called()

    def test_allow_when_other_session_working(self):
        """其他会话 working 不拦截本会话压缩（各自独立上下文）。"""
        chat_mod._active_tasks[("u1", "a1", "s2")] = threading.Event()
        chat_mod._active_tasks[("u1", "a2", "s1")] = threading.Event()
        result, _ = self._run_compact()
        self.assertTrue(result["compressed"])

    def test_reject_when_already_compacting(self):
        """同会话已在压缩（双击）：拒绝重复压缩。"""
        chat_mod._compacting_tasks.add(("u1", "a1", "s1"))
        session = _make_session()
        result, _ = self._run_compact(session=session)

        self.assertEqual(result["reason"], "already_compacting")
        session.compress.assert_not_called()

    def test_compacting_cleared_on_error(self):
        """compress 抛异常：请求失败但 finally 仍注销登记（状态不卡死）。"""
        session = _make_session()
        session.compress.side_effect = RuntimeError("boom")

        with patch.object(routes, "get_session", return_value=session):
            with self.assertRaises(RuntimeError):
                _run(routes.compact_agent_context(
                    self.AGENT,
                    body={"session_id": self.SESSION},
                    current_user=dict(self.USER),
                ))

        self.assertNotIn(("u1", "a1", "s1"), chat_mod._compacting_tasks)

    def test_no_ws_manager_silent_skip(self):
        """ws_manager 缺失（如单测/后端初始化前）：推送静默跳过，压缩照常。"""
        result, _ = self._run_compact()
        self.assertTrue(result["compressed"])


if __name__ == "__main__":
    unittest.main()
