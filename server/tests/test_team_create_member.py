# -*- coding: utf-8 -*-
"""P6 create_member 测试：dispatch 注册、待用户配置、直属上限、动态层级错误。

覆盖：
- team 工具 dispatch 表含 create_member（LLM 可调用）
- 创建成员后**不投递**初始化消息：模型由用户配置，未就绪前不接收消息
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
               team_id="top1", user_id="u1", leader_id=""):
    """构造 TeamTool（get_team/get_members 打桩，避免真实 DB）。"""
    mc = ModelConfig(
        name="m", base_url="http://x", api_key="k", model_id="m",
        extra={"max_seqlen": 8192},
    )
    session = AgentLLMSession(
        model_config=mc, workspace_id="ws1", system_prompt=""
    )
    with patch("data.team_store.get_team", return_value={
        "team_id": team_id,
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
            team_id=team_id,
        )
    return tool


def _patch_members(tool):
    """把实时名单锁定为该工具的内存名单，隔离真实 DB 同名团队数据。"""
    return patch("data.team_store.get_members",
                 side_effect=lambda *a, **k: [dict(m) for m in tool.members])


class TestCreateMemberDispatch(unittest.TestCase):
    def test_dispatch_contains_create_member(self):
        """create_member 已注册到 team 工具 dispatch 表（LLM 可调用）。

        成员创建后不继承 TOP 模型：``model_id`` 一律留空 + pending_model
        （等用户赋模型 + 审核）。工具**不接受** model_id 参数。
        """
        tool = _make_tool()
        tool.docker_manager.create_workspace.return_value = {
            "workspace_id": "member_probe",
        }
        # 落库与重名查询一并 mock：本用例只验证 dispatch 注册，
        # 真实写库会让后续重复运行撞上"成员名称已存在"
        with patch("data.team_store.add_member"), \
                patch("data.team_store.count_members_by_name", return_value=0), \
                patch("data.team_store.get_members", return_value=[]), \
                _patch_members(tool):
            result = tool.execute({"action": "create_member",
                                   "member_name": "调度探针"})
        self.assertNotIn("未知 action", str(result))
        self.assertNotIn("error", result)
        self.assertEqual(result["review_status"], "pending_model")
        self.assertEqual(result["model_id"], "")


class TestCreateMemberFlow(unittest.TestCase):
    def test_create_member_persists_and_awaits_user_config(self):
        """创建后：落 team_members 表（含 system_prompt/parent）+ 不进初始化投递。

        成员在用户赋模型并审核通过前不接收任何消息，故 create_member **不投递**
        初始化消息（避免制造注定失败的死信），返回等待用户处理提示。
        """
        tool = _make_tool(agent_id="top1", team_id="top1")
        tool.can_lead_team = True
        tool.docker_manager.create_workspace.return_value = {
            "workspace_id": "member_x",
        }
        tool._dispatch_to_member = MagicMock(return_value=True)  # type: ignore[method-assign]
        with patch("data.team_store.add_member") as add_member, \
                _patch_members(tool):
            result = tool.execute({
                "action": "create_member",
                "member_name": "测试成员",
                "system_prompt": "你是测试工程师，负责后端验证。",
            })
        self.assertTrue(result["member_id"].startswith("member_"))
        self.assertEqual(result["workspace_id"], "member_x")
        # 模型由用户配置 → 创建即 pending_model，等用户赋模型 + 审核
        self.assertEqual(result["model_id"], "")
        self.assertEqual(result["review_status"], "pending_model")
        self.assertFalse(result["initialized"])
        self.assertIn("等待用户处理", result["hint"])
        tool._dispatch_to_member.assert_not_called()
        # 权威名单持久化：system_prompt / parent_agent_id（直属 leader）
        add_member.assert_called_once()
        kwargs = add_member.call_args.kwargs
        self.assertEqual(kwargs["system_prompt"], "你是测试工程师，负责后端验证。")
        self.assertEqual(kwargs["parent_agent_id"], "top1")
        self.assertEqual(kwargs["team_id"], "top1")
        self.assertEqual(kwargs["review_status"], "pending_model")

    def test_create_member_rejects_model_id(self):
        """工具无权指定模型：传 model_id 直接拒绝（而非静默忽略）。"""
        tool = _make_tool(agent_id="top1", team_id="top1")
        tool.can_lead_team = True
        with _patch_members(tool):
            result = tool.execute({
                "action": "create_member", "member_name": "带模型成员",
                "model_id": "m",
            })
        self.assertIn("无权为成员分配模型", result["error"])
        self.assertEqual(tool.members, [])

    def test_create_member_without_model_is_pending_model(self):
        """成员模型留空 + pending_model（由用户赋模型）。"""
        tool = _make_tool(agent_id="top1", team_id="top1")
        tool.can_lead_team = True
        tool.docker_manager.create_workspace.return_value = {
            "workspace_id": "member_x",
        }
        tool._dispatch_to_member = MagicMock(return_value=True)  # type: ignore[method-assign]
        with patch("data.team_store.add_member") as add_member, \
                _patch_members(tool):
            result = tool.execute({
                "action": "create_member", "member_name": "待赋模型成员",
            })
        self.assertEqual(result["model_id"], "")
        self.assertEqual(result["review_status"], "pending_model")
        self.assertFalse(result["initialized"])
        tool._dispatch_to_member.assert_not_called()
        self.assertEqual(
            add_member.call_args.kwargs["review_status"], "pending_model"
        )

    def test_create_member_count_checks_direct_only(self):
        """直属成员上限按 parent_agent_id 计数：同 TOP 非直属成员不占用名额。"""
        tool = _make_tool(max_members=2, agent_id="top1", team_id="top1")
        tool.can_lead_team = True
        # 1 名直属 + 2 名同 TOP 非直属（如平级/上层创建的成员）
        tool.members = [
            {"id": "d1", "parent_agent_id": "top1"},
            {"id": "o1", "parent_agent_id": "top2"},
            {"id": "o2", "parent_agent_id": "top2"},
        ]
        with _patch_members(tool):
            result = tool.execute({
                "action": "create_member",
            })
        # 未达上限：继续走创建流程（无模型 → 建为待用户配置成员，非校验错误）
        self.assertNotIn("已达上限", str(result))

        tool2 = _make_tool(max_members=2, agent_id="top1", team_id="top1")
        tool2.can_lead_team = True
        tool2.members = [
            {"id": "d1", "parent_agent_id": "top1"},
            {"id": "d2", "parent_agent_id": "top1"},
            {"id": "o1", "parent_agent_id": "top2"},
        ]
        with _patch_members(tool2):
            result2 = tool2.execute({
                "action": "create_member",
            })
        self.assertIn("已达上限", str(result2))
        self.assertIn("2", str(result2))

    def test_level_error_message_dynamic(self):
        """层级超限错误信息使用实际配置（非硬编码 Level 3）。"""
        tool = _make_tool(max_level=2, agent_id="top1", team_id="top1")
        tool.level = 2  # Level 2 且 max_team_level=2 → 拒绝
        tool.can_lead_team = True
        result = tool.execute({
            "action": "create_member",
        })
        self.assertIn("Level 2", str(result))
        self.assertNotIn("Level 3", str(result))

    def test_cannot_create_when_can_lead_team_false(self):
        tool = _make_tool(agent_id="top1", team_id="top1")
        tool.can_lead_team = False
        result = tool.execute({
            "action": "create_member",
        })
        self.assertIn("can_lead_team=False", str(result))


class TestListMembersGrouping(unittest.TestCase):
    def test_grouping_by_parent_agent_id(self):
        """list_members：teammates=直属，team_member=同 TOP 非直属。"""
        tool = _make_tool(agent_id="top1", team_id="top1")
        tool.members = [
            {"id": "d1", "name": "直属1", "parent_agent_id": "top1",
             "role": "后端", "duty": "接口", "model_id": "m", "level": 1},
            {"id": "o1", "name": "平级1", "parent_agent_id": "top2",
             "role": "前端", "duty": "页面", "model_id": "m", "level": 1},
        ]
        with _patch_members(tool):
            result = tool._action_list_members({})
        groups = result["groups"]
        teammates = groups["teammates"]
        team_member = groups["team_member"]
        self.assertEqual([m["id"] for m in teammates], ["d1"])
        self.assertEqual([m["id"] for m in team_member], ["o1"])


if __name__ == "__main__":
    unittest.main()
