# -*- coding: utf-8 -*-
"""成员生命周期回归测试（缺陷 #1/#2/#3/#8）。

- #1 自身 level 恒 0：L1 实例引导后 level==1，其 create_member 落库 level=2；
     层级超限时错误信息用实际配置（动态）
- #2 can_lead_team 不闭环：update_member 写 False 后落库为 0；新建实例重新
     引导读到 False；roster 渲染「否」；旧库缺列迁移后默认 1（幂等）
- #3 role/duty 不支持：create_member 带 role/duty 落库并可 query_member 读回；
     update_member 仅传 role/duty 也算有效更新
- #8 计数快照/重名歧义：team_store 已有直属（非本实例创建）时上限实时生效；
     同团队重名 create 被拒

所有用例使用临时 DB（team_members 为名单权威源）。
"""

import shutil
import sqlite3
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
from tool.team_tool import TeamTool  # noqa: E402

TOP_AGENTS = {
    "top1": {"id": "top1", "name": "顶层A", "model_id": "m",
             "workspace_id": "top1"},
}


def _redirect_db_mods(tmpdir: Path) -> None:
    for mod in (conv, session_store, spec_store, team_store, agent_store):
        mod._DB_PATH = tmpdir / "conversations.db"  # type: ignore[attr-defined]
        mod._initialized = False  # type: ignore[attr-defined]
    db_mod._DB_PATH = tmpdir / "conversations.db"  # type: ignore[attr-defined]
    db_mod._wal_configured = False  # type: ignore[attr-defined]


class MemberLifecycleBase(unittest.TestCase):
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
                              parent_agent_id="top1", model_id="m")
        team_store.add_member("u1", "top1", "l1b", "二组组长", level=1,
                              parent_agent_id="top1", model_id="m")

    def tearDown(self):
        for p in self._patchers:
            p.stop()
        db_mod._DB_PATH = self._orig_db  # type: ignore[attr-defined]
        db_mod._wal_configured = False  # type: ignore[attr-defined]
        shutil.rmtree(self._tmp, ignore_errors=True)

    def _tool(self, agent_id, leader_id="", team_id="top1"):
        mc = ModelConfig(
            name="m", base_url="http://x", api_key="k", model_id="m",
            extra={"max_seqlen": 8192},
        )
        session = AgentLLMSession(
            model_config=mc, workspace_id="ws", system_prompt=""
        )
        tool = TeamTool(
            session=session,
            docker_manager=MagicMock(),
            model_configs={"m": mc},
            broker=MagicMock(),
            user_id="u1",
            agent_id=agent_id,
            leader_id=leader_id,
            team_id=team_id,
        )
        tool.docker_manager.create_workspace.return_value = {
            "workspace_id": "member_ws",
        }
        return tool


class TestBootstrapLevel(MemberLifecycleBase):
    def test_l1_level_from_team_members(self):
        tool = self._tool("l1a", leader_id="top1")
        self.assertEqual(tool.level, 1)
        self.assertTrue(tool.can_lead_team)

    def test_top_level_zero(self):
        tool = self._tool("top1", leader_id="")
        self.assertEqual(tool.level, 0)

    def test_l1_create_member_persists_level2(self):
        tool = self._tool("l1a", leader_id="top1")
        result = tool._action_create_member(
            {"member_name": "小兵", "model_id": "m"}
        )
        self.assertNotIn("error", result)
        self.assertEqual(result["level"], 2)
        row = team_store.get_member("top1", result["member_id"])
        self.assertIsNotNone(row)
        self.assertEqual(row["level"], 2)
        self.assertEqual(row["parent_agent_id"], "l1a")

    def test_top_create_member_persists_level1(self):
        tool = self._tool("top1", leader_id="")
        result = tool._action_create_member(
            {"member_name": "直属一", "model_id": "m"}
        )
        self.assertNotIn("error", result)
        self.assertEqual(result["level"], 1)

    def test_max_level_rejects_with_dynamic_message(self):
        team_store.init_team("u1", "top1", "顶层A", max_level=1,
                             max_members_per_level=7)
        tool = self._tool("l1a", leader_id="top1")
        self.assertEqual(tool.max_team_level, 1)
        result = tool._action_create_member(
            {"member_name": "越级", "model_id": "m"}
        )
        self.assertIn("已达最大层级", result["error"])
        self.assertIn("Level 1", result["error"])
        self.assertNotIn("Level 3", result["error"])


class TestCanLeadTeamClosure(MemberLifecycleBase):
    def test_update_false_persisted_and_rebootstrapped(self):
        top_tool = self._tool("top1", leader_id="")
        result = top_tool._action_update_member(
            {"target_member_id": "l1a", "can_lead_team": False}
        )
        self.assertNotIn("error", result)
        self.assertIn("can_lead_team", result["updated"])
        row = team_store.get_member("top1", "l1a")
        self.assertEqual(row["can_lead_team"], 0)

        # 新建实例重新引导 → 读到 False（不再恒 True）
        l1_tool = self._tool("l1a", leader_id="top1")
        self.assertFalse(l1_tool.can_lead_team)
        refused = l1_tool._action_create_member(
            {"member_name": "子成员", "model_id": "m"}
        )
        self.assertIn("can_lead_team=False", refused["error"])

    def test_roster_renders_can_lead_flag(self):
        top_tool = self._tool("top1", leader_id="")
        top_tool._action_update_member(
            {"target_member_id": "l1a", "can_lead_team": False}
        )
        roster = team_store.render_roster_md(team_store.get_members("top1"))
        self.assertIn("| 否 |", roster)
        self.assertIn("| 是 |", roster)

    def test_default_true_for_new_member(self):
        row = team_store.get_member("top1", "l1b")
        self.assertEqual(row["can_lead_team"], 1)


class TestRoleDuty(MemberLifecycleBase):
    def test_create_with_role_duty_and_query_back(self):
        tool = self._tool("top1", leader_id="")
        result = tool._action_create_member({
            "member_name": "后端匠", "model_id": "m",
            "role": "后端工程师", "duty": "接口与数据",
        })
        self.assertNotIn("error", result)
        row = team_store.get_member("top1", result["member_id"])
        self.assertEqual(row["role"], "后端工程师")
        self.assertEqual(row["duty"], "接口与数据")

        queried = tool._action_query_member(
            {"target_member_id": "后端匠"}
        )
        self.assertEqual(queried["member"]["role"], "后端工程师")
        self.assertEqual(queried["member"]["duty"], "接口与数据")

    def test_update_role_duty_only_is_valid(self):
        tool = self._tool("top1", leader_id="")
        result = tool._action_update_member({
            "target_member_id": "l1a", "role": "新角色", "duty": "新职责",
        })
        self.assertNotIn("error", result)
        self.assertIn("role", result["updated"])
        self.assertIn("duty", result["updated"])
        row = team_store.get_member("top1", "l1a")
        self.assertEqual(row["role"], "新角色")
        self.assertEqual(row["duty"], "新职责")


class TestCreateMemberRealtimeGuards(MemberLifecycleBase):
    def test_direct_limit_counts_realtime_db_rows(self):
        """上限实时生效：名单来自 team_store（非本实例创建的内存快照）。"""
        team_store.init_team("u1", "top1", "顶层A", max_level=3,
                             max_members_per_level=2)
        tool = self._tool("top1", leader_id="")
        # top1 已有 2 名直属（l1a/l1b）→ 达上限
        result = tool._action_create_member(
            {"member_name": "第三人", "model_id": "m"}
        )
        self.assertIn("已达上限", result["error"])
        self.assertIn("2", result["error"])

    def test_duplicate_name_rejected(self):
        tool = self._tool("top1", leader_id="")
        result = tool._action_create_member(
            {"member_name": "一组组长", "model_id": "m"}
        )
        self.assertIn("成员名称已存在", result["error"])
        self.assertIn("list_members", result["hint"])

    def test_update_member_duplicate_name_rejected(self):
        tool = self._tool("top1", leader_id="")
        result = tool._action_update_member({
            "target_member_id": "l1a", "name": "二组组长",
        })
        self.assertIn("成员名称已存在", result["error"])

    def test_missing_model_id_creates_pending_member(self):
        """省略 model_id 不再返回模型池：成员留空模型并进入待用户赋模型状态。"""
        tool = self._tool("top1", leader_id="")
        result = tool._action_create_member({"member_name": "无模型"})
        self.assertEqual(result["model_id"], "")
        self.assertEqual(result["review_status"], "pending_model")
        self.assertIn("等待用户处理", result["hint"])


class TestLegacyDbMigration(unittest.TestCase):
    """缺陷 #2：旧库缺列（can_lead_team/parent_agent_id）迁移后默认值。"""

    def setUp(self):
        self._tmp = Path(tempfile.mkdtemp(prefix="trae_test_"))
        self._orig_db = db_mod._DB_PATH  # type: ignore[attr-defined]
        _redirect_db_mods(self._tmp)
        # 构造迁移前的旧表结构（不含 can_lead_team / parent_agent_id）
        conn = sqlite3.connect(str(self._tmp / "conversations.db"))
        conn.execute(
            "CREATE TABLE team_members ("
            "id TEXT PRIMARY KEY, team_id TEXT NOT NULL,"
            "user_id TEXT NOT NULL, name TEXT NOT NULL,"
            "role TEXT NOT NULL DEFAULT '', duty TEXT NOT NULL DEFAULT '',"
            "model_id TEXT NOT NULL DEFAULT '',"
            "level INTEGER NOT NULL DEFAULT 1,"
            "work_status TEXT NOT NULL DEFAULT 'idle',"
            "comment TEXT NOT NULL DEFAULT '',"
            "scores_json TEXT NOT NULL DEFAULT '{}',"
            "system_prompt TEXT NOT NULL DEFAULT '',"
            "created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)"
        )
        conn.execute(
            "INSERT INTO team_members (id, team_id, user_id, name,"
            " created_at, updated_at) VALUES ('old1', 'top1', 'u1', '旧成员', 1, 1)"
        )
        conn.commit()
        conn.close()

    def tearDown(self):
        db_mod._DB_PATH = self._orig_db  # type: ignore[attr-defined]
        db_mod._wal_configured = False  # type: ignore[attr-defined]
        shutil.rmtree(self._tmp, ignore_errors=True)

    def test_migration_adds_columns_with_defaults(self):
        # 首次访问触发 _ensure_db → 幂等 ALTER 补列
        row = team_store.get_member("top1", "old1")
        self.assertIsNotNone(row)
        self.assertEqual(row["can_lead_team"], 1)  # 旧数据默认「可带队」，语义不变
        self.assertEqual(row["parent_agent_id"], "")
        self.assertEqual(row["name"], "旧成员")

    def test_migration_is_idempotent(self):
        team_store.get_member("top1", "old1")
        team_store._initialized = False  # type: ignore[attr-defined]
        row = team_store.get_member("top1", "old1")  # 二次迁移不报错、不丢数据
        self.assertEqual(row["can_lead_team"], 1)


if __name__ == "__main__":
    unittest.main()
