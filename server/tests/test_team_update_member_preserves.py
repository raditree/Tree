# -*- coding: utf-8 -*-
"""update_member 信息保留测试：改名/改提示词不再清空工作区与上下文。

覆盖：
- update_member 修改 name / system_prompt 后：
  - 不调用 docker remove_workspace / create_workspace（不重建工作区）
  - 不调用 clear_user_agent / clear_context（不清空上下文）
  - roster 视图与 team_members 表照常同步
  - 其他字段（scores/comment/model_id）保留
- 返回值不再包含 rebirth 字段
"""

import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from config.models import ModelConfig  # noqa: E402
from llm.llm import AgentLLMSession  # noqa: E402
from tool.team_tool import TeamTool  # noqa: E402


def _make_tool():
    mc = ModelConfig(
        name="m", base_url="http://x", api_key="k", model_id="m",
        extra={"max_seqlen": 8192},
    )
    session = AgentLLMSession(
        model_config=mc, workspace_id="ws1", system_prompt=""
    )
    with patch("data.team_store.get_team", return_value={
        "max_level": 3, "max_members_per_level": 7,
    }), patch("data.team_store.get_members", return_value=[]):
        tool = TeamTool(
            session=session,
            docker_manager=MagicMock(),
            model_configs={"m": mc},
            broker=MagicMock(),
            user_id="u1",
            agent_id="top1",
            leader_id="",
            top_agent_id="top1",
        )
    tool.members = [{
        "id": "m1",
        "name": "旧名",
        "role": "",
        "duty": "",
        "model_id": "m",
        "level": 1,
        "workspace_id": "m1",
        "parent_agent_id": "top1",
        "created_at": "2026-01-01 00:00:00",
        "work_status": "idle",
        "current_task": "",
        "can_lead_team": True,
        "system_prompt": "",
        "scores": {"quality": 8.0, "efficiency": 7.0,
                   "collaboration": 9.0, "accuracy": 6.0},
        "comment": "表现良好",
        "task_ids": [],
        "message_history": [],
    }]
    return tool


class TestUpdateMemberPreservesInfo(unittest.TestCase):
    def test_rename_and_prompt_do_not_clear_context(self):
        """改 name/system_prompt：不重建工作区、不清空上下文、不重生。"""
        tool = _make_tool()
        with patch("data.team_store.update_member") as upd, \
             patch("data.team_store.get_members",
                   return_value=[dict(tool.members[0])]), \
             patch.object(tool, "_save_roster") as save_roster, \
             patch.object(tool, "_push_roster_update", return_value=0):
            result = tool._action_update_member({
                "target_member_id": "m1",
                "name": "新角色名",
                "system_prompt": "新的职责说明",
            })
        self.assertNotIn("error", result)
        self.assertIn("name", result["updated"])
        self.assertIn("system_prompt", result["updated"])
        # 关键：不触发工作区重建 / 上下文清空
        tool.docker_manager.remove_workspace.assert_not_called()
        tool.docker_manager.create_workspace.assert_not_called()
        # 信息保留：其他字段不变
        m = tool.members[0]
        self.assertEqual(m["name"], "新角色名")
        self.assertEqual(m["system_prompt"], "新的职责说明")
        self.assertEqual(m["scores"]["quality"], 8.0)
        self.assertEqual(m["comment"], "表现良好")
        self.assertEqual(m["model_id"], "m")
        # roster 与 team_store 照常同步
        save_roster.assert_called_once()
        upd.assert_called_once()
        # 返回结构不再含 rebirth
        self.assertNotIn("rebirth", result)

    def test_scores_and_comment_preserved_on_update(self):
        """只改评分/评价：与既有行为一致，信息保留。"""
        tool = _make_tool()
        with patch("data.team_store.update_member") as upd, \
             patch("data.team_store.get_members",
                   return_value=[dict(tool.members[0])]), \
             patch.object(tool, "_save_roster"), \
             patch.object(tool, "_push_roster_update", return_value=0):
            result = tool._action_update_member({
                "target_member_id": "m1",
                "scores": {"quality": 9.5},
                "comment": "更好了",
            })
        self.assertEqual(result["member"]["scores"]["quality"], 9.5)
        self.assertEqual(result["member"]["comment"], "更好了")
        tool.docker_manager.remove_workspace.assert_not_called()
        upd.assert_called_once()

    def test_update_member_rejects_work_status(self):
        """work_status 仍为只读（状态治理不变）。"""
        tool = _make_tool()
        result = tool._action_update_member({
            "target_member_id": "m1", "work_status": "working",
        })
        self.assertIn("error", result)
        self.assertIn("只读", str(result))


if __name__ == "__main__":
    unittest.main()
