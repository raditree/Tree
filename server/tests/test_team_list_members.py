# -*- coding: utf-8 -*-
"""list_members / list_teams 视角可靠性专项测试（缺陷 #4，用户要求 5）。

覆盖（5.1）：
1. TOP 视角：teammates=直属 L1、team_member=L2（indirect），无 leader 组
2. L1 视角：leader=TOP(level 0)、自建 L2 在 teammates、平级在 team_member、
   自己不出现在任何组
3. L2 视角：leader 经 team_members 解析为 L1（level/名称正确，非裸 id）
4. 实时 work_status 叠加 + 两种筛选（level/work_status）+ log_path
5. legacy roster 回退：非 TOP 视角不产生伪直属
6. team 与 message 两工具 list_members/list_teams 输出完全一致（防行为漂移）
7. query_status 输出形状（缺陷 #9）：含 work_status/last_active_at/log_path，
   不含任何 git/commit/task 字段
"""

import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import data.agent_store as agent_store  # noqa: E402
import data.conversation_store as conv  # noqa: E402
import data.db as db_mod  # noqa: E402
import data.session_store as session_store  # noqa: E402
import data.spec_store as spec_store  # noqa: E402
import data.team_store as team_store  # noqa: E402
from config.models import ModelConfig  # noqa: E402
from llm.llm import AgentLLMSession  # noqa: E402
from tool.message_tool import MessageTool  # noqa: E402
from tool.team_base import TeamToolBase  # noqa: E402
from tool.team_tool import TeamTool  # noqa: E402

TOP_AGENTS = {
    "top1": {"id": "top1", "name": "顶层A", "model_id": "m1",
             "workspace_id": "top1"},
    "top2": {"id": "top2", "name": "顶层B", "model_id": "m1",
             "workspace_id": "top2"},
}

LEGACY_ROSTER = (
    "| ID | 名称 | 模型 | 层级 | 创建时间 | 工作状态 | 评价 | 角色 | 职责 | "
    "质量 | 效率 | 协作性 | 准确性 | 可带队 |\n"
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | "
    "--- | --- | --- |\n"
    "| x1 | 甲 | m | 1 | 2026-01-01 00:00:00 | - | | 后端 | 接口 | "
    "8 | 7 | 9 | 6 | 是 |\n"
)


def _redirect_db_mods(tmpdir: Path) -> None:
    for mod in (conv, session_store, spec_store, team_store, agent_store):
        mod._DB_PATH = tmpdir / "conversations.db"  # type: ignore[attr-defined]
        mod._initialized = False  # type: ignore[attr-defined]
    db_mod._DB_PATH = tmpdir / "conversations.db"  # type: ignore[attr-defined]
    db_mod._wal_configured = False  # type: ignore[attr-defined]


class ListMembersBase(unittest.TestCase):
    def setUp(self):
        self._tmp = Path(tempfile.mkdtemp(prefix="trae_test_"))
        self._orig_db = db_mod._DB_PATH  # type: ignore[attr-defined]
        _redirect_db_mods(self._tmp)
        self._patchers = [
            patch("data.agent_store.get_agents",
                  side_effect=lambda uid: list(TOP_AGENTS.values())
                  if uid == "u1" else []),
            patch("data.agent_store.get_agent",
                  side_effect=lambda uid, aid: TOP_AGENTS.get(aid)),
        ]
        for p in self._patchers:
            p.start()
        team_store.init_team("u1", "top1", "顶层A")
        team_store.add_member("u1", "top1", "l1a", "一组组长", level=1,
                              parent_agent_id="top1", model_id="m1",
                              role="后端", duty="接口")
        team_store.add_member("u1", "top1", "l1b", "二组组长", level=1,
                              parent_agent_id="top1", model_id="m1",
                              role="前端", duty="页面")
        team_store.add_member("u1", "top1", "l2a", "小兵", level=2,
                              parent_agent_id="l1a", model_id="m2")

    def tearDown(self):
        for p in self._patchers:
            p.stop()
        db_mod._DB_PATH = self._orig_db  # type: ignore[attr-defined]
        db_mod._wal_configured = False  # type: ignore[attr-defined]
        shutil.rmtree(self._tmp, ignore_errors=True)

    def _tool(self, agent_id, leader_id="", team_id="top1", cls=TeamTool):
        mc = ModelConfig(
            name="m", base_url="http://x", api_key="k", model_id="m",
            extra={"max_seqlen": 8192},
        )
        session = AgentLLMSession(
            model_config=mc, workspace_id="ws", system_prompt=""
        )
        return cls(
            session=session,
            docker_manager=MagicMock(),
            model_configs={"m": mc, "m1": mc, "m2": mc},
            broker=MagicMock(),
            user_id="u1",
            agent_id=agent_id,
            leader_id=leader_id,
            team_id=team_id,
        )

    @staticmethod
    def _ids(group):
        return [m["id"] for m in group]


class TestTopView(ListMembersBase):
    def test_top_groups(self):
        tool = self._tool("top1", leader_id="")
        result = tool._action_list_members({})
        groups = result["groups"]
        self.assertEqual(groups["team_leader"], [])
        self.assertEqual(self._ids(groups["teammates"]), ["l1a", "l1b"])
        self.assertEqual(self._ids(groups["team_member"]), ["l2a"])
        self.assertEqual(result["total"], 3)
        self.assertEqual(
            groups["team_member"][0]["relation"], "indirect"
        )
        # log_path 指向统一工作目录下的成员活动日志
        self.assertEqual(
            groups["teammates"][0]["log_path"],
            "agentspace/l1a/.self/activity.log",
        )
        self.assertRegex(
            result["generated_at"], r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"
        )


class TestL1View(ListMembersBase):
    def test_l1_groups_and_self_excluded(self):
        tool = self._tool("l1a", leader_id="top1")
        self.assertEqual(tool.level, 1)
        result = tool._action_list_members({})
        groups = result["groups"]
        self.assertEqual(self._ids(groups["teammates"]), ["l2a"])
        self.assertEqual(self._ids(groups["team_member"]), ["l1b"])
        self.assertEqual(groups["team_member"][0]["relation"], "peer")
        self.assertEqual(self._ids(groups["team_leader"]), ["top1"])
        leader = groups["team_leader"][0]
        self.assertEqual(leader["name"], "顶层A")
        self.assertEqual(leader["level"], 0)
        self.assertEqual(leader["relation"], "team_leader")
        # 自己不出现在任何组
        all_ids = self._ids(result["members"])
        self.assertNotIn("l1a", all_ids)


class TestL2View(ListMembersBase):
    def test_l2_leader_resolved_from_team_members(self):
        tool = self._tool("l2a", leader_id="l1a")
        self.assertEqual(tool.level, 2)
        result = tool._action_list_members({})
        groups = result["groups"]
        self.assertEqual(self._ids(groups["team_leader"]), ["l1a"])
        leader = groups["team_leader"][0]
        self.assertEqual(leader["name"], "一组组长")
        self.assertEqual(leader["level"], 1)
        self.assertNotEqual(leader["name"], "l1a")
        self.assertEqual(groups["teammates"], [])
        self.assertEqual(self._ids(groups["team_member"]), ["l1a", "l1b"])


class TestFiltersAndLiveStatus(ListMembersBase):
    def test_work_status_overlay_and_filter(self):
        tool = self._tool("top1", leader_id="")

        def _status(member_id):
            return "working" if member_id == "l1a" else "idle"

        with patch.object(TeamTool, "_live_work_status", side_effect=_status):
            result = tool._action_list_members({"work_status": "working"})
        groups = result["groups"]
        self.assertEqual(self._ids(groups["teammates"]), ["l1a"])
        self.assertEqual(groups["team_member"], [])

    def test_model_filter_no_longer_supported(self):
        """team 工具不涉及模型：model_id 不再是筛选参数（传了也不生效）。"""
        tool = self._tool("top1", leader_id="")
        result = tool._action_list_members({"model_id": "m2"})
        groups = result["groups"]
        self.assertEqual(self._ids(groups["teammates"]), ["l1a", "l1b"])
        self.assertEqual(self._ids(groups["team_member"]), ["l2a"])

    def test_level_filter(self):
        tool = self._tool("top1", leader_id="")
        result = tool._action_list_members({"level": 1})
        groups = result["groups"]
        self.assertEqual(self._ids(groups["teammates"]), ["l1a", "l1b"])
        self.assertEqual(groups["team_member"], [])

    def test_hint_when_role_duty_missing(self):
        team_store.update_member("top1", "l2a", parent_agent_id="top1")
        tool = self._tool("top1", leader_id="")
        result = tool._action_list_members({})
        self.assertIn("role/duty 为空", result["hint"])
        self.assertIn("小兵", result["hint"])


class TestLegacyRosterFallback(ListMembersBase):
    def _legacy_tool(self, agent_id, leader_id):
        mc = ModelConfig(
            name="m", base_url="http://x", api_key="k", model_id="m",
            extra={"max_seqlen": 8192},
        )
        session = AgentLLMSession(
            model_config=mc, workspace_id="ws", system_prompt=""
        )
        with patch("data.team_store.get_members", return_value=[]), \
                patch.object(TeamTool, "_io_read", return_value=LEGACY_ROSTER):
            return TeamTool(
                session=session,
                docker_manager=MagicMock(),
                model_configs={"m": mc},
                broker=MagicMock(),
                user_id="u1",
                agent_id=agent_id,
                leader_id=leader_id,
                team_id="top1",
            )

    def test_top_view_treats_rows_as_direct(self):
        tool = self._legacy_tool("top1", "")
        with patch("data.team_store.get_members", return_value=[]):
            result = tool._action_list_members({})
        self.assertEqual(self._ids(result["groups"]["teammates"]), ["x1"])

    def test_non_top_has_no_pseudo_direct(self):
        """非 TOP 视角不得把 legacy roster 行当作自己的直属。"""
        tool = self._legacy_tool("l1a", "top1")
        with patch("data.team_store.get_members", return_value=[]):
            result = tool._action_list_members({})
        self.assertEqual(result["groups"]["teammates"], [])
        self.assertEqual(
            self._ids(result["groups"]["team_member"]), ["x1"]
        )


class TestQueryStatusShape(ListMembersBase):
    """缺陷 #9：query_status 只给实时状态与日志入口，不含任何 git/任务字段。"""

    DATED_LOG = (
        "[2026-09-10 09:00:00] [tool] terminal ls\n"
        "[2026-09-10 12:34:56] [done] 交付 agentspace/l1a/out.py"
    )

    def test_shape_has_no_git_or_task_fields(self):
        tool = self._tool("top1", leader_id="")
        with patch.object(TeamToolBase, "_io_read", return_value=self.DATED_LOG), \
                patch("agent.chat._is_agent_working", return_value=True):
            result = tool._action_query_status({"target_member_id": "l1a"})
        self.assertEqual(result["member_id"], "l1a")
        self.assertEqual(result["name"], "一组组长")
        self.assertEqual(result["work_status"], "working")
        self.assertEqual(result["last_active_at"], "2026-09-10 12:34:56")
        self.assertEqual(
            result["log_path"], "agentspace/l1a/.self/activity.log"
        )
        self.assertIn("activity.log", result["hint"])
        self.assertRegex(
            result["generated_at"], r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"
        )
        # 共享仓库下 git 无法按成员归属：输出不得出现 commit/git/task 类字段
        lowered = [k.lower() for k in result]
        self.assertEqual(
            [k for k in lowered
             if "git" in k or "commit" in k or "task" in k],
            [],
        )

    def test_missing_and_unknown_target_shape(self):
        tool = self._tool("top1", leader_id="")
        for args in ({}, {"target_member_id": "查无此人"}):
            result = tool._action_query_status(args)
            self.assertIn("error", result)
            self.assertIn("list_members", result["hint"])
            lowered = [k.lower() for k in result]
            self.assertEqual(
                [k for k in lowered
                 if "git" in k or "commit" in k or "task" in k],
                [],
            )


class TestTeamMessageParity(ListMembersBase):
    def test_list_members_identical_between_tools(self):
        team_tool = self._tool("top1", leader_id="")
        msg_tool = self._tool("top1", leader_id="", cls=MessageTool)
        a = team_tool._action_list_members({})
        b = msg_tool._action_list_members({})
        a.pop("generated_at")
        b.pop("generated_at")
        self.assertEqual(a, b)

    def test_list_teams_identical_between_tools(self):
        team_tool = self._tool("top1", leader_id="")
        msg_tool = self._tool("top1", leader_id="", cls=MessageTool)
        a = team_tool._action_list_teams({})
        b = msg_tool._action_list_teams({})
        a.pop("generated_at")
        b.pop("generated_at")
        self.assertEqual(a, b)


if __name__ == "__main__":
    unittest.main()
