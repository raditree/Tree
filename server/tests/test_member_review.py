# -*- coding: utf-8 -*-
"""团队成员审核状态与"不继承 TOP 模型"治理测试（要求 1 / 3）。

背景（两个真实缺口）：
1. 建队成员此前**继承 TOP 的模型**，于是"用户还没看过成员，它就已经能自主执行
   任务"。要求 3 改为：成员创建时 ``model_id`` 留空、``review_status`` =
   ``pending_model``，必须由用户在「团队成员 → 模型配置」页赋模型 + 审核通过
   才会接收消息；TOP agent（LLM）无权设置成员模型。
2. 建队预建人数此前 = ``max_members_per_level``（默认 7）。要求 1 改为只预建 3
   名，而"每层成员上限"仍是独立口径（leader 可继续扩编到上限）。

覆盖：
- ``team_store`` 审核状态机：新建 / 赋模型 / 审核 / 驳回 / 清空模型 / 编辑
  其它字段不冲掉审核结论
- 旧库迁移：已存在的表补 ``review_status`` 列并按有无模型回填
- ``team_init``：建队预建 3 名、受每层上限钳制、成员无模型 + pending
- ``team_tool.create_member``：省略 model_id 仍可创建；不投递初始化消息
- ``team_tool.review_member``：放行 / 驳回 / 非法状态 / 成员不存在
- ``chat._member_review_block``：审核闸口径（未就绪拒绝、已通过放行、
  TOP 自身与未建队不拦）
- ``chat._resolve_member_model``：空模型**不再**回退 TOP 模型
- REST：``PATCH /api/agents/{id}/teammate/{member_id}`` 赋模型 + 审核，
  ``GET .../teammates`` 带 pending 计数，``GET /api/agents`` 带
  ``pending_member_count``（红点徽章数据源）

隔离：临时 DB；TestClient override 认证。
"""
import shutil
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import state  # noqa: E402
from fastapi import FastAPI  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

import data.agent_store as agent_store  # noqa: E402
import data.conversation_store as conv_store  # noqa: E402
import data.db as db_mod  # noqa: E402
import data.mcp_service_store as mcp_store  # noqa: E402
import data.session_store as session_store  # noqa: E402
import data.team_init as team_init  # noqa: E402
import data.team_store as team_store  # noqa: E402
from config.models import ModelConfig  # noqa: E402

USER = {"openid": "u-review-test"}

_REDIRECT_MODS = (
    agent_store, mcp_store, team_store, conv_store, session_store, db_mod,
)


def _redirect_db(tmpdir: Path) -> None:
    for mod in _REDIRECT_MODS:
        mod._DB_PATH = tmpdir / "conversations.db"  # type: ignore[attr-defined]
        mod._initialized = False  # type: ignore[attr-defined]


class TeamStoreBase(unittest.TestCase):
    def setUp(self):
        self._tmp = Path(tempfile.mkdtemp(prefix="trae_review_"))
        self._orig_db = {m: m._DB_PATH for m in _REDIRECT_MODS}
        self.addCleanup(self._restore)
        _redirect_db(self._tmp)

    def _restore(self):
        for m in _REDIRECT_MODS:
            m._DB_PATH = self._orig_db[m]
            m._initialized = False
        shutil.rmtree(self._tmp, ignore_errors=True)


class TestReviewStatusStateMachine(TeamStoreBase):
    """team_store 层：状态机自洽（模型与审核状态不允许互相矛盾）。"""

    def setUp(self):
        super().setUp()
        team_store.init_team("u1", "top1", "T")

    def test_add_member_without_model_is_pending_model(self):
        m = team_store.add_member("u1", "top1", "m1", "A")
        self.assertEqual(m["model_id"], "")
        self.assertEqual(m["review_status"], "pending_model")

    def test_add_member_with_model_is_pending_review(self):
        """指定了模型也算"未过审"：赋模型不等于放行。"""
        m = team_store.add_member("u1", "top1", "m2", "B", model_id="flash")
        self.assertEqual(m["review_status"], "pending_review")

    def test_explicit_pending_status_respected(self):
        m = team_store.add_member(
            "u1", "top1", "m3", "C",
            review_status=team_store.REVIEW_STATUS_PENDING_MODEL,
        )
        self.assertEqual(m["review_status"], "pending_model")

    def test_empty_model_forces_pending_model(self):
        """空模型不可能处于审核态（即便调用方硬传 approved）。"""
        m = team_store.add_member(
            "u1", "top1", "m4", "D",
            review_status=team_store.REVIEW_STATUS_APPROVED,
        )
        self.assertEqual(m["review_status"], "pending_model")

    def test_assign_model_then_approve(self):
        team_store.add_member("u1", "top1", "m1", "A")
        row = team_store.update_member_review_status(
            "top1", "m1", model_id="flash"
        )
        self.assertEqual(row["review_status"], "pending_review")
        row = team_store.update_member_review_status(
            "top1", "m1", value="approved"
        )
        self.assertEqual(row["review_status"], "approved")
        self.assertEqual(row["model_id"], "flash")

    def test_reject_then_reapprove(self):
        team_store.add_member("u1", "top1", "m1", "A", model_id="flash")
        row = team_store.update_member_review_status(
            "top1", "m1", value="rejected"
        )
        self.assertEqual(row["review_status"], "rejected")
        row = team_store.update_member_review_status(
            "top1", "m1", value="approved"
        )
        self.assertEqual(row["review_status"], "approved")

    def test_clearing_model_resets_to_pending_model(self):
        team_store.add_member("u1", "top1", "m1", "A", model_id="flash")
        team_store.update_member_review_status("top1", "m1", value="approved")
        row = team_store.update_member_review_status("top1", "m1", model_id="")
        self.assertEqual(row["model_id"], "")
        self.assertEqual(row["review_status"], "pending_model")

    def test_editing_other_fields_keeps_verdict(self):
        """编辑职责/名称不得把审核结论打回待审核。"""
        team_store.add_member("u1", "top1", "m1", "A", model_id="flash")
        team_store.update_member_review_status("top1", "m1", value="approved")
        row = team_store.update_member("top1", "m1", duty="后端验证")
        self.assertEqual(row["review_status"], "approved")

    def test_rejected_survives_model_change(self):
        """已被驳回的成员改模型仍保持驳回（改模型不等于放行）。"""
        team_store.add_member("u1", "top1", "m1", "A", model_id="flash")
        team_store.update_member_review_status("top1", "m1", value="rejected")
        row = team_store.update_member("top1", "m1", model_id="other")
        self.assertEqual(row["review_status"], "rejected")

    def test_illegal_status_raises(self):
        team_store.add_member("u1", "top1", "m1", "A", model_id="flash")
        with self.assertRaises(ValueError):
            team_store.update_member_review_status("top1", "m1", value="bogus")

    def test_missing_member_returns_none(self):
        self.assertIsNone(
            team_store.update_member_review_status(
                "top1", "nope", value="approved"
            )
        )

    def test_needs_user_review_and_count(self):
        team_store.add_member("u1", "top1", "m1", "A")                # 待赋模型
        team_store.add_member("u1", "top1", "m2", "B", model_id="f")   # 待审核
        team_store.add_member("u1", "top1", "m3", "C", model_id="f")
        team_store.update_member_review_status("top1", "m3", value="approved")
        team_store.add_member("u1", "top1", "m4", "D", model_id="f")
        team_store.update_member_review_status("top1", "m4", value="rejected")
        # approved / rejected 都不需要用户再处理
        self.assertEqual(team_store.count_pending_members("top1"), 2)
        by_id = {m["id"]: m for m in team_store.get_members("top1")}
        self.assertTrue(team_store.needs_user_review(by_id["m1"]))
        self.assertTrue(team_store.needs_user_review(by_id["m2"]))
        self.assertFalse(team_store.needs_user_review(by_id["m3"]))
        self.assertFalse(team_store.needs_user_review(by_id["m4"]))

    def test_roster_md_contains_review_column(self):
        team_store.add_member("u1", "top1", "m1", "A")
        md = team_store.render_roster_md(team_store.get_members("top1"))
        header = md.splitlines()[0]
        self.assertIn("审核", header)
        self.assertIn("pending_model", md)


class TestLegacyMigration(TeamStoreBase):
    """旧库（无 review_status 列）迁移：补列并回填，不能留下"第三种状态"。"""

    def _create_legacy_table(self) -> None:
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
            "parent_agent_id TEXT NOT NULL DEFAULT '',"
            "can_lead_team INTEGER NOT NULL DEFAULT 1,"
            "created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)"
        )
        conn.commit()
        conn.close()

    def test_migration_backfills_by_model_presence(self):
        self._create_legacy_table()
        conn = sqlite3.connect(str(self._tmp / "conversations.db"))
        conn.execute(
            "INSERT INTO team_members (id, team_id, user_id, name, model_id,"
            " created_at, updated_at) VALUES ('old1','top1','u1','A','',1,1)"
        )
        conn.execute(
            "INSERT INTO team_members (id, team_id, user_id, name, model_id,"
            " created_at, updated_at) VALUES ('old2','top1','u1','B','f',1,1)"
        )
        conn.commit()
        conn.close()

        team_store._initialized = False  # type: ignore[attr-defined]
        by_id = {m["id"]: m for m in team_store.get_members("top1")}
        # 有模型 -> 视为已审核（此前一直可用，不因治理被突然停用）
        self.assertEqual(by_id["old2"]["review_status"], "approved")
        # 无模型 -> 待用户赋模型（确实不可用，需要提醒）
        self.assertEqual(by_id["old1"]["review_status"], "pending_model")

    def test_row_without_status_reads_as_approved_when_model_present(self):
        """兜底：列存在但值为空的历史行，读取时按有无模型归一。"""
        team_store.init_team("u1", "top1", "T")
        team_store.add_member("u1", "top1", "m1", "A", model_id="f")
        conn = sqlite3.connect(str(self._tmp / "conversations.db"))
        conn.execute(
            "UPDATE team_members SET review_status = '' WHERE id = 'm1'"
        )
        conn.commit()
        conn.close()
        self.assertEqual(
            team_store.get_member("top1", "m1")["review_status"], "approved"
        )


class TestTeamInitDefaults(TeamStoreBase):
    """建队默认 3 名、成员无模型 pending（要求 1 + 3）。"""

    def _top(self):
        return {"id": "top1", "name": "TOP", "workspace_id": "ws_top",
                "model_id": "topmodel"}

    def _build(self, **kwargs):
        with patch("data.team_init._pick_names",
                   return_value=[f"name{i}" for i in range(20)]), \
             patch("data.team_init._generate_member_ids",
                   return_value=[f"member_{i}" for i in range(20)]):
            return team_init.init_team_for_top(
                "u1", self._top(), MagicMock(), **kwargs
            )

    def test_builds_three_members_by_default(self):
        result = self._build()
        self.assertEqual(result["created_count"], 3)

    def test_members_have_no_model_and_wait_for_user(self):
        self._build()
        members = team_store.get_members("top1")
        self.assertEqual(len(members), 3)
        for m in members:
            self.assertEqual(m["model_id"], "")
            self.assertEqual(m["review_status"], "pending_model")

    def test_per_level_cap_still_independent(self):
        """3 是建队预建数，不是团队上限：上限仍持久化为传入值。"""
        result = self._build(max_members_per_level=5)
        self.assertEqual(result["created_count"], 3)
        self.assertEqual(
            team_store.get_team("top1")["max_members_per_level"], 5
        )

    def test_cap_below_three_clamps_build(self):
        result = self._build(max_members_per_level=2)
        self.assertEqual(result["created_count"], 2)

    def test_explicit_member_count_overrides_default(self):
        result = self._build(member_count=5, max_members_per_level=7)
        self.assertEqual(result["created_count"], 5)


class TestCreateMemberWithoutModel(TeamStoreBase):
    """team_tool.create_member：模型可选，且不投递注定失败的消息。"""

    def _tool(self):
        from tool.team_tool import TeamTool

        session = MagicMock()
        session.workspace_id = "ws_top"
        session.agent_name = "TOP"
        tool = TeamTool(
            session=session,
            docker_manager=MagicMock(),
            model_configs={"m": MagicMock()},
            broker=MagicMock(),
            user_id="u1",
            agent_id="top1",
            leader_id="",
            team_id="top1",
        )
        tool.can_lead_team = True
        tool.max_members_per_level = 7
        tool.max_team_level = 3
        tool.level = 0
        tool.docker_manager.create_workspace.return_value = {
            "workspace_id": "member_ws",
        }
        tool._dispatch_to_member = MagicMock(return_value=True)  # type: ignore[method-assign]
        return tool

    def _patch_members(self, tool):
        return patch.object(
            type(tool), "_live_members",
            side_effect=lambda *a, **k: [dict(m) for m in tool.members],
        )

    def test_create_without_model_succeeds(self):
        tool = self._tool()
        with patch("data.team_store.add_member") as add_member, \
                self._patch_members(tool):
            result = tool.execute({
                "action": "create_member", "member_name": "新成员",
            })
        self.assertNotIn("error", result)
        self.assertEqual(result["model_id"], "")
        self.assertEqual(result["review_status"], "pending_model")
        # 未就绪成员不投递初始化消息（否则必被审核闸拒绝）
        self.assertFalse(result["initialized"])
        tool._dispatch_to_member.assert_not_called()
        self.assertEqual(
            add_member.call_args.kwargs["review_status"], "pending_model"
        )

    def test_create_with_model_enters_pending_review(self):
        tool = self._tool()
        with patch("data.team_store.add_member"), self._patch_members(tool):
            result = tool.execute({
                "action": "create_member", "member_name": "带模型成员",
                "model_id": "m",
            })
        self.assertEqual(result["review_status"], "pending_review")
        self.assertFalse(result["initialized"])

    def test_unknown_model_still_rejected(self):
        tool = self._tool()
        with self._patch_members(tool):
            result = tool.execute({
                "action": "create_member", "member_name": "错模型",
                "model_id": "nope",
            })
        self.assertIn("模型不存在", result["error"])


class TestReviewMemberAction(TeamStoreBase):
    """team_tool.review_member：放行 / 驳回 / 非法状态。"""

    def setUp(self):
        super().setUp()
        team_store.init_team("u1", "top1", "T")
        team_store.add_member("u1", "top1", "m1", "A", model_id="m")

    def _tool(self):
        from tool.team_tool import TeamTool

        session = MagicMock()
        session.workspace_id = "ws_top"
        session.agent_name = "TOP"
        return TeamTool(
            session=session,
            docker_manager=MagicMock(),
            model_configs={"m": MagicMock(), "m2": MagicMock()},
            broker=MagicMock(),
            user_id="u1",
            agent_id="top1",
            leader_id="",
            team_id="top1",
        )

    def test_approve(self):
        result = self._tool().execute({
            "action": "review_member", "target_member_id": "m1",
        })
        self.assertEqual(result["review_status"], "approved")
        self.assertEqual(
            team_store.get_member("top1", "m1")["review_status"], "approved"
        )

    def test_reject_via_approve_false(self):
        result = self._tool().execute({
            "action": "review_member", "target_member_id": "m1",
            "approve": False,
        })
        self.assertEqual(result["review_status"], "rejected")

    def test_assign_model_and_approve_together(self):
        result = self._tool().execute({
            "action": "review_member", "target_member_id": "m1",
            "model_id": "m2", "review_status": "approved",
        })
        self.assertEqual(result["model_id"], "m2")
        self.assertEqual(result["review_status"], "approved")

    def test_pending_model_hint(self):
        team_store.add_member("u1", "top1", "m2", "B")
        result = self._tool().execute({
            "action": "review_member", "target_member_id": "m2",
            "review_status": "pending_review",
        })
        # 无模型时状态被收敛为 pending_model，并给出可执行提示
        self.assertEqual(result["review_status"], "pending_model")
        self.assertIn("尚未分配模型", result["hint"])

    def test_illegal_status_rejected(self):
        result = self._tool().execute({
            "action": "review_member", "target_member_id": "m1",
            "review_status": "bogus",
        })
        self.assertIn("error", result)

    def test_missing_target_rejected(self):
        result = self._tool().execute({"action": "review_member"})
        self.assertIn("target_member_id", result["error"])

    def test_unknown_member_rejected(self):
        result = self._tool().execute({
            "action": "review_member", "target_member_id": "nope",
        })
        self.assertIn("成员不存在", result["error"])


class TestMemberReviewGate(TeamStoreBase):
    """chat 审核闸 + 空模型不回退 TOP 模型。"""

    def setUp(self):
        super().setUp()
        team_store.init_team("u1", "top1", "T")
        agent_store.create_agent("u1", "TOP", "topmodel")

    def test_pending_model_blocked(self):
        from agent.chat import _member_review_block

        team_store.add_member("u1", "top1", "m1", "A")
        reason = _member_review_block("u1", "m1", "top1")
        self.assertIsNotNone(reason)
        self.assertIn("尚未分配模型", reason)

    def test_pending_review_blocked(self):
        from agent.chat import _member_review_block

        team_store.add_member("u1", "top1", "m1", "A", model_id="m")
        reason = _member_review_block("u1", "m1", "top1")
        self.assertIsNotNone(reason)
        self.assertIn("审核", reason)

    def test_rejected_blocked(self):
        from agent.chat import _member_review_block

        team_store.add_member("u1", "top1", "m1", "A", model_id="m")
        team_store.update_member_review_status("top1", "m1", value="rejected")
        reason = _member_review_block("u1", "m1", "top1")
        self.assertIn("驳回", reason)

    def test_approved_passes(self):
        from agent.chat import _member_review_block

        team_store.add_member("u1", "top1", "m1", "A", model_id="m")
        team_store.update_member_review_status("top1", "m1", value="approved")
        self.assertIsNone(_member_review_block("u1", "m1", "top1"))

    def test_top_itself_not_blocked(self):
        """TOP 自身不在 team_members 表内，不该被审核闸拦住。"""
        from agent.chat import _member_review_block

        self.assertIsNone(_member_review_block("u1", "top1", "top1"))

    def test_unknown_member_not_blocked(self):
        """未建队/旧数据查不到成员行：保持原行为（不拦）。"""
        from agent.chat import _member_review_block

        self.assertIsNone(_member_review_block("u1", "ghost", "top1"))

    def test_no_team_id_not_blocked(self):
        from agent.chat import _member_review_block

        self.assertIsNone(_member_review_block("u1", "m1", ""))

    def test_empty_model_does_not_fall_back_to_top(self):
        """空 model_id 不再回退 TOP 模型（治理核心：不得未经确认即可执行）。"""
        from agent.chat import _resolve_member_model

        original = state.model_configs
        self.addCleanup(setattr, state, "model_configs", original)
        state.model_configs = {
            "topmodel": ModelConfig(
                name="top", base_url="http://x", api_key="k",
                model_id="topmodel", extra={"max_seqlen": 100},
            )
        }
        config, model_id = _resolve_member_model("u1", "m1", "top1", "")
        self.assertIsNone(config)
        self.assertEqual(model_id, "")

    def test_member_own_model_resolved(self):
        from agent.chat import _resolve_member_model

        original = state.model_configs
        self.addCleanup(setattr, state, "model_configs", original)
        state.model_configs = {
            "flash": ModelConfig(
                name="f", base_url="http://x", api_key="k",
                model_id="flash", extra={"max_seqlen": 100},
            )
        }
        config, model_id = _resolve_member_model("u1", "m1", "top1", "flash")
        self.assertIsNotNone(config)
        self.assertEqual(model_id, "flash")


class TestTeammateReviewApi(TeamStoreBase):
    """REST：赋模型 / 审核 + 待处理计数（红点徽标数据源）。"""

    def setUp(self):
        super().setUp()
        self._orig_state_configs = state.model_configs
        state.model_configs = {
            "flash": ModelConfig(
                name="Flash", base_url="http://x", api_key="sk-1",
                model_id="flash", extra={"max_seqlen": 8192},
            ),
        }
        self.addCleanup(setattr, state, "model_configs", self._orig_state_configs)
        # team_id 必须等于 agent 主键：/api/agents 的待处理计数按 agent id 收集
        self._agent = agent_store.create_agent(USER["openid"], "TOP", "flash")
        self.top_id = self._agent["id"]
        team_store.init_team(USER["openid"], self.top_id, "TOP")
        team_store.add_member(USER["openid"], self.top_id, "m1", "成员A")
        team_store.add_member(USER["openid"], self.top_id, "m2", "成员B",
                              model_id="flash")

        app = FastAPI()
        from agent.routes import router as agent_router
        from ws.auth import get_current_user

        app.include_router(agent_router)
        app.dependency_overrides[get_current_user] = lambda: dict(USER)
        self.client = TestClient(app)

    def _member_url(self, member_id: str) -> str:
        return f"/api/agents/{self.top_id}/teammate/{member_id}"

    def test_assign_model_moves_to_pending_review(self):
        r = self.client.patch(
            self._member_url("m1"), json={"model_id": "flash"}
        )
        self.assertEqual(r.status_code, 200, r.text)
        body = r.json()["member"]
        self.assertEqual(body["model_id"], "flash")
        self.assertEqual(body["review_status"], "pending_review")

    def test_approve(self):
        r = self.client.patch(
            self._member_url("m1"),
            json={"model_id": "flash", "review_status": "approved"},
        )
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(r.json()["member"]["review_status"], "approved")

    def test_unknown_model_400(self):
        r = self.client.patch(
            self._member_url("m1"), json={"model_id": "nope"}
        )
        self.assertEqual(r.status_code, 400, r.text)
        self.assertIn("模型不存在", r.json()["detail"])

    def test_illegal_status_400(self):
        r = self.client.patch(
            self._member_url("m1"), json={"review_status": "bogus"}
        )
        self.assertEqual(r.status_code, 400, r.text)

    def test_empty_body_400(self):
        r = self.client.patch(self._member_url("m1"), json={})
        self.assertEqual(r.status_code, 400, r.text)

    def test_unknown_member_404(self):
        r = self.client.patch(
            self._member_url("nope"), json={"model_id": "flash"}
        )
        self.assertEqual(r.status_code, 404)

    def test_clearing_model_forces_pending_model(self):
        r = self.client.patch(
            self._member_url("m2"), json={"model_id": ""}
        )
        self.assertEqual(r.status_code, 200, r.text)
        self.assertEqual(r.json()["member"]["review_status"], "pending_model")

    def test_teammates_endpoint_exposes_status_and_pending_count(self):
        r = self.client.get(f"/api/agents/{self.top_id}/teammates")
        self.assertEqual(r.status_code, 200, r.text)
        data = r.json()
        self.assertEqual(data["pending_member_count"], 2)
        by_id = {m["id"]: m for m in data["members"]}
        self.assertEqual(by_id["m1"]["review_status"], "pending_model")
        self.assertEqual(by_id["m2"]["review_status"], "pending_review")

    def test_pending_count_drops_after_approval(self):
        self.client.patch(
            self._member_url("m1"),
            json={"model_id": "flash", "review_status": "approved"},
        )
        r = self.client.get(f"/api/agents/{self.top_id}/teammates")
        self.assertEqual(r.json()["pending_member_count"], 1)

    def test_agent_list_exposes_pending_member_count(self):
        """Agent 列表红点徽章的计数来自 /api/agents。"""
        r = self.client.get("/api/agents")
        self.assertEqual(r.status_code, 200, r.text)
        agents = r.json()["agents"]
        self.assertEqual(len(agents), 1)
        self.assertEqual(agents[0]["pending_member_count"], 2)

    def test_agent_list_count_zero_when_all_approved(self):
        for mid in ("m1", "m2"):
            self.client.patch(
                self._member_url(mid),
                json={"model_id": "flash", "review_status": "approved"},
            )
        r = self.client.get("/api/agents")
        self.assertEqual(r.json()["agents"][0]["pending_member_count"], 0)


if __name__ == "__main__":
    unittest.main()
