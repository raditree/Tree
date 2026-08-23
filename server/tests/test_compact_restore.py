# -*- coding: utf-8 -*-
"""compact 路由测试：重启后内存会话清空时，应从 DB 恢复上下文再压缩。

回归场景（用户反馈）：前端重启后点 compact 提示"该 agent 当前没有活跃的
会话上下文"。根因是 compact 只查内存会话缓存，不尝试从 agent_context 表
恢复持久化上下文。修复后缓存未命中应 load_context 恢复、压缩并写回。
"""

import asyncio
import sys
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

# 将 server 目录加入 Python 路径
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agent import routes  # noqa: E402


def _run(coro):
    """在事件循环中执行异步路由函数。"""
    return asyncio.new_event_loop().run_until_complete(coro)


class TestCompactRestore(unittest.TestCase):
    def setUp(self):
        self.user_id = "u1"
        self.agent_id = "a1"
        self.session_id = "s1"
        # 模拟 DB 中持久化的上下文（含 system + 多轮消息）
        self.ctx = [
            {"role": "system", "content": "sys"},
            {"role": "user", "content": "hello"},
            {"role": "assistant", "content": "hi"},
            {"role": "user", "content": "请继续"},
            {"role": "assistant", "content": "done"},
        ]

    def test_compact_restores_from_db_when_cache_empty(self):
        """缓存未命中 + DB 有上下文：应恢复并压缩，不报 no_active_session。"""
        fake_session = MagicMock()
        fake_session.compress.return_value = True
        fake_session.context = list(self.ctx)

        with patch.object(routes, "get_session", return_value=None), \
             patch.object(routes, "load_context", return_value=list(self.ctx)), \
             patch.object(routes, "get_agent", return_value={
                 "id": self.agent_id,
                 "model_id": "m1",
                 "workspace_id": "ws1",
             }), \
             patch.object(routes.state, "model_configs", {"m1": MagicMock()}), \
             patch.object(routes, "AgentLLMSession", return_value=fake_session), \
             patch.object(routes, "save_context") as save_mock:
            result = _run(routes.compact_agent_context(
                self.agent_id,
                body={"session_id": self.session_id},
                current_user={"openid": self.user_id},
            ))

        self.assertTrue(result["success"])
        self.assertTrue(result["compressed"])
        # 成功路径不应出现 no_active_session 标记
        self.assertNotIn("reason", result)
        # 压缩结果应写回 DB（重启后仍是最新压缩态）
        save_mock.assert_called_once_with(
            self.user_id, self.agent_id, fake_session.context, self.session_id,
        )

    def test_compact_no_context_returns_no_active_session(self):
        """缓存未命中且 DB 无上下文：应返回 no_active_session（原语义保留）。"""
        with patch.object(routes, "get_session", return_value=None), \
             patch.object(routes, "load_context", return_value=None):
            result = _run(routes.compact_agent_context(
                self.agent_id,
                body={"session_id": self.session_id},
                current_user={"openid": self.user_id},
            ))

        self.assertTrue(result["success"])
        self.assertFalse(result["compressed"])
        self.assertEqual(result["reason"], "no_active_session")

    def test_compact_uses_cached_session_when_hit(self):
        """缓存命中：直接用内存会话压缩，不读 DB、不写回。"""
        fake_session = MagicMock()
        fake_session.compress.return_value = True
        fake_session.context = list(self.ctx)

        with patch.object(routes, "get_session", return_value=fake_session), \
             patch.object(routes, "load_context") as load_mock, \
             patch.object(routes, "save_context") as save_mock:
            result = _run(routes.compact_agent_context(
                self.agent_id,
                body={"session_id": self.session_id},
                current_user={"openid": self.user_id},
            ))

        self.assertTrue(result["compressed"])
        load_mock.assert_not_called()
        save_mock.assert_not_called()


if __name__ == "__main__":
    unittest.main()
