# -*- coding: utf-8 -*-
"""P6 create_member 测试：dispatch 注册、初始化消息、直属上限、动态层级错误。

覆盖：
- team 工具 dispatch 表含 create_member（LLM 可调用）
- 创建成员后自动向新成员投递含 system_prompt 的初始化消息
- 直属成员数量上限（按 parent_agent_id 计数，非 TOP 总人数）
- 层级校验错误信息动态（不再硬编码 Level 3）
- list_members 分组：teammates=直属 / team_member=同 TOP 非直属
"""

import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from config.models import ModelConfig  # noqa: E402
from llm.llm import AgentLLMSession  # noqa: E402
from tool.team_tool import TeamTool  # noqa: E402


def _make_tool(max_level=3, max_members=7, agent_id="top1",
               top_agent_id="top1", user_id="u1", leader_id=""):
    """构造 TeamTool（get_team/get_members 打桩，避免真实 DB）。"""
    mc = ModelConfig(
        name="m", base_url="http://x", api_key="k", model_id="m",
        extra={"max_seqlen": 8192},
    )
    session = AgentLLMSession(
        model_config=mc, workspace_id="ws1", system_prompt=""
    )
    with patch("data.team_store.get_team", return_value={
        "top_agent_id": top_agent_id,
        "max_level": max_level,
        "max_members_per_level": max_members,
    }), patch("data.team_store.get_members", return_value=[]):
        tool = TeamTool(
            session=session,
            docker_manager=MagicMock(),
            model_configs={"m": mc},
            broker=MagicMock(),
            user_id=user_id,
            agent_id=agent_id,
            leader_id=leader_id,
            top_agent_id=top_agent_id,
        )
    return tool


class TestCreateMemberDispatch(unittest.TestCase):
    def test_dispatch_contains_create_member(self):
        """create_member 已注册到 team 工具 dispatch 表（LLM 可调用）。"""
        tool = _make_tool()
        # 未指定 model_id 时返回模型池（而非「未知 action」错误 → 证明已注册）
        result = tool.execute({"action": "create_member"})
        self.assertIn("models", result)
        self.assertNotIn("error", result)


class TestCreateMemberFlow(unittest.TestCase):
    def test_create_member_persists_and_dispatches_init(self):
        """创建后：落 team_members 表（含 system_prompt/parent）+ 投递初始化消息。"""
        tool = _make_tool(agent_id="top1", top_agent_id="top1")
        tool.can_lead_team = True
        tool.docker_manager.create_workspace.return_value = {
            "workspace_id": "member_x",
        }
        tool._dispatch_to_member = MagicMock(return_value=True)  # type: ignore[method-assign]
        with patch("data.team_store.add_member") as add_member:
            result = tool.execute({
                "action": "create_member",
                "member_name": "测试成员",
                "model_id": "m",
                "system_prompt": "你是测试工程师，负责后端验证。",
            })
        self.assertTrue(result["member_id"].startswith("member_"))
        self.assertEqual(result["workspace_id"], "member_x")
        self.assertTrue(result["initialized"])
        # 权威名单持久化：system_prompt / parent_agent_id（直属 leader）
        add_member.assert_called_once()
        kwargs = add_member.call_args.kwargs
        self.assertEqual(kwargs["system_prompt"], "你是测试工程师，负责后端验证。")
        self.assertEqual(kwargs["parent_agent_id"], "top1")
        self.assertEqual(kwargs["top_agent_id"], "top1")
        # 初始化消息携带 system prompt
        tool._dispatch_to_member.assert_called_once()
        init_content = tool._dispatch_to_member.call_args.args[1]
        self.assertIn("你是测试工程师，负责后端验证。", init_content)
        self.assertIn("团队初始化", init_content)

    def test_create_member_count_checks_direct_only(self):
        """直属成员上限按 parent_agent_id 计数：同 TOP 非直属成员不占用名额。"""
        tool = _make_tool(max_members=2, agent_id="top1", top_agent_id="top1")
        tool.can_lead_team = True
        # 1 名直属 + 2 名同 TOP 非直属（如平级/上层创建的成员）
        tool.members = [
            {"id": "d1", "parent_agent_id": "top1"},
            {"id": "o1", "parent_agent_id": "top2"},
            {"id": "o2", "parent_agent_id": "top2"},
        ]
        result = tool.execute({
            "action": "create_member", "model_id": "m",
        })
        # 未达上限：继续走创建流程（model 存在则创建，无需校验错误）
        self.assertNotIn("已达上限", str(result))

        tool2 = _make_tool(max_members=2, agent_id="top1", top_agent_id="top1")
        tool2.can_lead_team = True
        tool2.members = [
            {"id": "d1", "parent_agent_id": "top1"},
            {"id": "d2", "parent_agent_id": "top1"},
            {"id": "o1", "parent_agent_id": "top2"},
        ]
        result2 = tool2.execute({
            "action": "create_member", "model_id": "m",
        })
        self.assertIn("已达上限", str(result2))
        self.assertIn("2", str(result2))

    def test_level_error_message_dynamic(self):
        """层级超限错误信息使用实际配置（非硬编码 Level 3）。"""
        tool = _make_tool(max_level=2, agent_id="top1", top_agent_id="top1")
        tool.level = 2  # Level 2 且 max_team_level=2 → 拒绝
        tool.can_lead_team = True
        result = tool.execute({
            "action": "create_member", "model_id": "m",
        })
        self.assertIn("Level 2", str(result))
        self.assertNotIn("Level 3", str(result))

    def test_cannot_create_when_can_lead_team_false(self):
        tool = _make_tool(agent_id="top1", top_agent_id="top1")
        tool.can_lead_team = False
        result = tool.execute({
            "action": "create_member", "model_id": "m",
        })
        self.assertIn("can_lead_team=False", str(result))


class TestListMembersGrouping(unittest.TestCase):
    def test_grouping_by_parent_agent_id(self):
        """list_members：teammates=直属，team_member=同 TOP 非直属。"""
        tool = _make_tool(agent_id="top1", top_agent_id="top1")
        tool.members = [
            {"id": "d1", "name": "直属1", "parent_agent_id": "top1",
             "role": "后端", "duty": "接口", "model_id": "m", "level": 1},
            {"id": "o1", "name": "平级1", "parent_agent_id": "top2",
             "role": "前端", "duty": "页面", "model_id": "m", "level": 1},
        ]
        result = tool._action_list_members({})
        groups = result["groups"]
        teammates = groups["teammates"]
        team_member = groups["team_member"]
        self.assertEqual([m["id"] for m in teammates], ["d1"])
        self.assertEqual([m["id"] for m in team_member], ["o1"])


if __name__ == "__main__":
    unittest.main()
