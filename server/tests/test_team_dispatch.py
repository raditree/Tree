# -*- coding: utf-8 -*-
"""broker 回退投递的 leader_id 归属回归测试（缺陷 #5）。

背景：历史上 ``_dispatch_to_member`` 的 payload ``leader_id`` 恒写成 TOP，
导致 L1 给自己创建的 L2 投递消息时，L2 认为自己的 leader 是 TOP，
汇报/寻址链路错位。

修复后：payload 的 ``leader_id`` 取**接收成员**的 ``parent_agent_id``
（缺失时回退调用方 ``self.leader_id``）。名单已迁至 team_members 表，
故用 MessageTool（公共基类 TeamToolBase 提供投递能力）。
"""

import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from config.models import ModelConfig  # noqa: E402
from llm.llm import AgentLLMSession  # noqa: E402
from tool.message_tool import MessageTool  # noqa: E402


def _make_tool(agent_id, leader_id="", team_id="top1", user_id="u1"):
    mc = ModelConfig(
        name="m", base_url="http://x", api_key="k", model_id="m",
        extra={"max_seqlen": 8192},
    )
    session = AgentLLMSession(
        model_config=mc, workspace_id="ws", system_prompt=""
    )
    with patch("data.team_store.get_team", return_value=None), \
            patch("data.team_store.get_members", return_value=[]), \
            patch("data.team_store.get_member", return_value=None):
        tool = MessageTool(
            session=session,
            docker_manager=MagicMock(),
            model_configs={"m": mc},
            broker=MagicMock(),
            user_id=user_id,
            agent_id=agent_id,
            leader_id=leader_id,
            team_id=team_id,
        )
    return tool


class TestDispatchLeaderId(unittest.TestCase):
    def _payload(self, tool, member):
        tool.broker.dispatch.return_value = True
        tool._dispatch_to_member(member, "干活")
        key, payload = tool.broker.dispatch.call_args[0]
        return key, payload

    def test_l1_dispatch_to_own_child_uses_l1_as_leader(self):
        """L1 投递给自建 L2：L2 眼中的 leader 是该 L1，而非 TOP。"""
        tool = _make_tool(agent_id="l1a", leader_id="top1", team_id="top1")
        member = {
            "id": "l2a", "workspace_id": "l2a",
            "model_id": "m", "parent_agent_id": "l1a",
        }
        key, payload = self._payload(tool, member)
        self.assertEqual(key, ("u1", "l2a"))
        self.assertEqual(payload["agent_id"], "l2a")
        self.assertEqual(payload["leader_id"], "l1a")
        self.assertEqual(payload["team_id"], "top1")

    def test_top_dispatch_uses_top_as_leader(self):
        """TOP 投递直属 L1：leader 仍为 TOP。"""
        tool = _make_tool(agent_id="top1", leader_id="", team_id="top1")
        member = {
            "id": "l1a", "workspace_id": "l1a",
            "model_id": "m", "parent_agent_id": "top1",
        }
        _, payload = self._payload(tool, member)
        self.assertEqual(payload["leader_id"], "top1")

    def test_member_without_parent_falls_back_to_own_leader(self):
        """成员行缺 parent_agent_id 时回退调用方自己的 leader。"""
        tool = _make_tool(agent_id="l1b", leader_id="top1", team_id="top1")
        member = {"id": "l2b", "workspace_id": "l2b", "model_id": "m"}
        _, payload = self._payload(tool, member)
        self.assertEqual(payload["leader_id"], "top1")

    def test_dispatch_carries_session_id(self):
        tool = _make_tool(agent_id="top1", leader_id="", team_id="top1")
        tool.session_id = "sess-9"
        member = {
            "id": "l1a", "workspace_id": "l1a",
            "model_id": "m", "parent_agent_id": "top1",
        }
        _, payload = self._payload(tool, member)
        self.assertEqual(payload["session_id"], "sess-9")

    def test_no_broker_returns_false(self):
        tool = _make_tool(agent_id="top1", leader_id="", team_id="top1")
        tool.broker = None
        self.assertFalse(
            tool._dispatch_to_member({"id": "l1a", "model_id": "m"}, "hi")
        )


class TestDispatchOneFallbackUpward(unittest.TestCase):
    def test_leader_target_dispatches_to_leader_agent(self):
        """向上汇报：解析为 leader 的目标经同一 broker 通道投递给该 agent。"""
        tool = _make_tool(agent_id="l1a", leader_id="top1", team_id="top1")
        resolved = {
            "type": "leader", "id": "top1", "name": "顶层A",
            "agent": {"id": "top1", "workspace_id": "top1", "model_id": "m"},
        }
        tool.broker.dispatch.return_value = True
        self.assertTrue(tool._dispatch_one_fallback(resolved, "汇报"))
        key, payload = tool.broker.dispatch.call_args[0]
        self.assertEqual(key, ("u1", "top1"))
        self.assertEqual(payload["agent_id"], "top1")


if __name__ == "__main__":
    unittest.main()
