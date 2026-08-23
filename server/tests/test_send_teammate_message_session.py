# -*- coding: utf-8 -*-
"""send_teammate_message 会话隔离回归测试。

回归场景（用户反馈）：在某创建的会话里向成员 agent 发消息，结果消息发到
默认会话。根因：REST 接口 /agents/{id}/teammate/{member}/message 不读取、
不透传 body 里的 session_id，导致成员方 payload 缺 session_id 而回退
DEFAULT_SESSION。修复后在投递负载中携带 session_id。
"""

import asyncio
import sys
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

# 将 server 目录加入 Python 路径
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agent import routes  # noqa: E402


def _run(coro):
    """在事件循环中执行异步路由函数。"""
    return asyncio.new_event_loop().run_until_complete(coro)


class FakeResult:
    def __init__(self, status="sent"):
        self.status = status
        self.sent = []
        self.rejected = []

    def get(self, key, default=None):
        return {"status": self.status, "sent": self.sent,
                "rejected": self.rejected}.get(key, default)


class TestSendTeammateMessageSession(unittest.TestCase):
    def setUp(self):
        self.user_id = "u1"
        self.agent_id = "a1"
        self.member_id = "m1"
        self.session_id = "s_" + uuid.uuid4().hex[:8]

    def _call(self, body=None, dispatch_result=None):
        with patch.object(routes, "_dispatch_agent_message",
                          return_value=dispatch_result) as m:
            result = _run(routes.send_teammate_message(
                self.agent_id,
                self.member_id,
                body=body or {},
                current_user={"openid": self.user_id},
            ))
        return result, m

    def test_passes_explicit_session_id(self):
        """请求体带 session_id：应原样透传进投递负载的 extra。"""
        result, dispatch = self._call(
            body={"content": "开工", "session_id": self.session_id},
            dispatch_result=FakeResult("sent"),
        )
        self.assertTrue(result["success"])
        kwargs = dispatch.call_args.kwargs
        # 三个位置参：user_id / target_ids / content
        self.assertEqual(tuple(dispatch.call_args.args)[:2],
                         (self.user_id, [self.member_id]))
        self.assertEqual(kwargs["extra"]["session_id"], self.session_id)
        # 用户直发：sender_id 为显式空串（成员总结不回发给任何 agent）
        self.assertEqual(kwargs["extra"]["sender_id"], "")

    def test_user_direct_never_auto_replies_to_top(self):
        """用户直发：extra 必须显式带 sender_id=""，绝不允许兜底成 top。"""
        result, dispatch = self._call(
            body={"content": "开工", "session_id": self.session_id},
            dispatch_result=FakeResult("sent"),
        )
        self.assertTrue(result["success"])
        kwargs = dispatch.call_args.kwargs
        # source_agent_id 为空、top_agent_id 为顶部 agent；
        # sender_id 必须被显式覆盖为空，而非 source or top 兜底成 top。
        self.assertEqual(kwargs.get("source_agent_id"), "")
        self.assertEqual(kwargs.get("top_agent_id"), self.agent_id)
        self.assertEqual(kwargs["extra"]["sender_id"], "")
        self.assertNotEqual(kwargs["extra"]["sender_id"], self.agent_id)

    def test_defaults_to_default_session_when_absent(self):
        """请求体缺 session_id：投递 load 应带上 DEFAULT_SESSION 兜底。"""
        result, dispatch = self._call(
            body={"content": "开工"},
            dispatch_result=FakeResult("sent"),
        )
        self.assertTrue(result["success"])
        self.assertEqual(dispatch.call_args.kwargs["extra"]["session_id"],
                         routes.DEFAULT_SESSION)

    def test_empty_session_id_falls_back_to_default(self):
        """请求体显式传空 session_id：应回退默认会话。"""
        result, dispatch = self._call(
            body={"content": "开工", "session_id": ""},
            dispatch_result=FakeResult("sent"),
        )
        self.assertTrue(result["success"])
        self.assertEqual(dispatch.call_args.kwargs["extra"]["session_id"],
                         routes.DEFAULT_SESSION)

    def test_error_status_returns_failure(self):
        """投递被拒（status=error）：接口应返回 success=False。"""
        result, _ = self._call(
            body={"content": "开工", "session_id": self.session_id},
            dispatch_result=FakeResult("error"),
        )
        self.assertFalse(result["success"])

    def test_missing_content_rejected(self):
        """缺 content：直接返回错误，不应触发投递。"""
        with patch.object(routes, "_dispatch_agent_message") as dispatch:
            result = _run(routes.send_teammate_message(
                self.agent_id, self.member_id,
                body={}, current_user={"openid": self.user_id},
            ))
        self.assertFalse(result["success"])
        dispatch.assert_not_called()


if __name__ == "__main__":
    unittest.main()