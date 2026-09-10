# -*- coding: utf-8 -*-
"""P6 团队寻址测试：top 内成员按 name + 跨 Top 顶层寻址 + 跨用户拒绝。

覆盖 checklist P4：
- top 内成员寻址按 name（基于成员拓扑）
- 跨 Top 顶层寻址按 TOP agent name（同用户名下可解析为 top，仅 TOP 自己可用）
- 跨用户 TOP 名称不可解析（unknown）——顶层寻址限同用户
- 非 TOP（团队成员）尝试跨 TOP：unknown + reason=cross_top_denied
- _resolve_target 对空目标返回 unknown

通信动作（send_message）已迁至 ``message`` 工具，故本文件用 MessageTool
构造被测实例（寻址逻辑在公共基类 TeamToolBase）。
"""

import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from llm.llm import AgentLLMSession  # noqa: E402
from config.models import ModelConfig  # noqa: E402
from tool.message_tool import MessageTool  # noqa: E402


def _tool(user_id="u1", agent_id="top1", top="top1", members=None):
    """构造 MessageTool；``members`` 为实时名单（patch team_store.get_members）。"""
    mc = ModelConfig(
        name="m", base_url="http://x", api_key="k", model_id="m",
        extra={"max_seqlen": 8192},
    )
    session = AgentLLMSession(
        model_config=mc, workspace_id="ws1", system_prompt=""
    )
    with patch("data.team_store.get_members", return_value=list(members or [])):
        tool = MessageTool(
            session=session,
            docker_manager=MagicMock(),
            model_configs={"m": mc},
            broker=MagicMock(),
            user_id=user_id,
            agent_id=agent_id,
            leader_id=agent_id,
            team_id=top,
        )
    return tool


def _patch_members(members):
    return patch("data.team_store.get_members", return_value=list(members or []))


class TestResolveTarget(unittest.TestCase):
    def test_top_member_by_name(self):
        tool = _tool(members=[{"id": "m1", "name": "晏清"}])
        with _patch_members([{"id": "m1", "name": "晏清"}]):
            r = tool._resolve_target("晏清")
        self.assertEqual(r["type"], "member")
        self.assertEqual(r["id"], "m1")

    def test_top_member_by_id(self):
        tool = _tool(members=[{"id": "m1", "name": "晏清"}])
        with _patch_members([{"id": "m1", "name": "晏清"}]):
            r = tool._resolve_target("m1")
        self.assertEqual(r["type"], "member")

    def test_cross_top_by_name_same_user(self):
        """同用户名下其他 TOP：按 name 解析为 top（当前 agent 即 TOP）。"""
        tool = _tool(user_id="u1", agent_id="top1", top="top1")
        other = {"id": "top2", "name": "另一个Agent"}
        with patch("data.agent_store.get_agents", return_value=[other]), \
                _patch_members([]):
            r = tool._resolve_target("另一个Agent")
            self.assertEqual(r["type"], "top")
            self.assertEqual(r["id"], "top2")

    def test_cross_top_by_member_denied(self):
        """非 TOP 成员尝试跨 TOP：拒绝并给出 cross_top_denied。"""
        tool = _tool(user_id="u1", agent_id="mem-1", top="top1")
        other = {"id": "top2", "name": "另一个Agent"}
        with patch("data.agent_store.get_agents", return_value=[other]), \
                _patch_members([]):
            r = tool._resolve_target("另一个Agent")
            self.assertEqual(r["type"], "unknown")
            self.assertEqual(r["reason"], "cross_top_denied")

    def test_cross_user_top_not_resolvable(self):
        """跨用户：其他用户 TOP 名称不可解析为 top（限同用户）。"""
        tool = _tool(user_id="u1", agent_id="top1", top="top1")
        # get_agents("u1") 只返回 u1 名下 agent；其他用户的 TOP 名不在其中
        mine = {"id": "top2", "name": "我的TOP"}
        with patch("data.agent_store.get_agents", return_value=[mine]), \
                _patch_members([]):
            r = tool._resolve_target("别人的TOP")  # 非本用户名下的 TOP
            self.assertEqual(r["type"], "unknown")

    def test_unknown_empty_target(self):
        tool = _tool()
        r = tool._resolve_target("")
        self.assertEqual(r["type"], "unknown")


class TestSendMessageCrossTop(unittest.TestCase):
    def test_send_to_cross_top_dispatch(self):
        """send_message 跨 Top 顶层：解析为 top 后经 message_dispatcher 投递。"""
        tool = _tool(user_id="u1", agent_id="top1", top="top1")
        dispatcher = MagicMock(
            return_value={"status": "sent", "sent": ["top2"], "rejected": []}
        )
        tool.message_dispatcher = dispatcher
        with patch(
            "data.agent_store.get_agents",
            return_value=[{"id": "top2", "name": "跨TopAgent"}],
        ), _patch_members([]):
            result = tool._action_send_message(
                {"target_member_id": "跨TopAgent", "message": "协作请求"}
            )
        self.assertEqual(result["status"], "sent")
        dispatcher.assert_called_once()
        # 投递目标包含 top2
        self.assertEqual(dispatcher.call_args.args[1], ["top2"])

    def test_send_to_unknown_target_rejected(self):
        """不可达目标：返回 error，逐目标明细标记 unknown。"""
        tool = _tool(user_id="u1", agent_id="top1", top="top1")
        with patch("data.agent_store.get_agents", return_value=[]), \
                _patch_members([]):
            result = tool._action_send_message(
                {"target_member_id": "不存在的成员", "message": "hi"}
            )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["unknown"][0]["target"], "不存在的成员")
        self.assertEqual(result["unknown"][0]["reason"], "not_found")
        self.assertIn("目标不存在或不可达", result["hint"])


if __name__ == "__main__":
    unittest.main()
