# -*- coding: utf-8 -*-
"""team remove_member 测试（成员移除 + 级联清理 + 权限闸）。

新增 ``team remove_member`` action 的背景：此前 ``team_tool`` 的提示词明确写
"成员不可删除，仅可 update_member 调整"，团队只能无限扩张。本测试覆盖：

- 权限闸：不可移除自身；不可移除任何上级（沿 ``parent_agent_id`` 上溯）
- cascade：目标有下级时默认连子树一并移除；``cascade=false`` 且存在下级 → 拒绝
- 名单落库：``team_members`` 行删除、``teams.member_count`` 重算
- 级联清理：工作空间 / 会话缓存 / 上下文 / broker / 限流器 / 插件 均被调用
- 内存名单剔除（否则本实例后续动作仍看到幽灵成员）
- 无副作用路径：目标不存在、缺参数

隔离：临时 DB（team_members 为名单权威源），docker/broker 用替身。
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
from tool.team_tool import TEAM_ACTIONS, TeamTool  # noqa: E402

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


class RemoveMemberBase(unittest.TestCase):
    def setUp(self):
        self._tmp = Path(tempfile.mkdtemp(prefix="trae_rm_"))
        self._orig_db = db_mod._DB_PATH  # type: ignore[attr-defined]
        _redirect_db_mods(self._tmp)
        self._patchers = [
            patch("data.agent_store.get_agents",
                  side_effect=lambda uid: list(TOP_AGENTS.values())
                  if uid == "u1" else []),
            patch("data.agent_store.get_agent",
                  side_effect=lambda uid, aid: TOP_AGENTS.get(aid)),
            # 级联清理的外部依赖打桩，避免真实触碰 DB / 事件总线
            patch("data.session_cache.clear_user_agent", return_value=None),
            patch("data.conversation_store.clear_context", return_value=None),
        ]
        for p in self._patchers:
            p.start()
        team_store.init_team("u1", "top1", "顶层A")
        # 两层结构：top1 → l1a → l2a，以及平级 l1b
        team_store.add_member("u1", "top1", "l1a", "一组组长", level=1,
                              parent_agent_id="top1", model_id="m")
        team_store.add_member("u1", "top1", "l1b", "二组组长", level=1,
                              parent_agent_id="top1", model_id="m")
        team_store.add_member("u1", "top1", "l2a", "小兵", level=2,
                              parent_agent_id="l1a", model_id="m")

    def tearDown(self):
        for p in self._patchers:
            p.stop()
        db_mod._DB_PATH = self._orig_db  # type: ignore[attr-defined]
        db_mod._wal_configured = False  # type: ignore[attr-defined]
        shutil.rmtree(self._tmp, ignore_errors=True)

    def _tool(self, agent_id, leader_id="", team_id="top1", broker=None):
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
            broker=broker if broker is not None else MagicMock(),
            user_id="u1",
            agent_id=agent_id,
            leader_id=leader_id,
            team_id=team_id,
        )
        return tool


class TestActionRegistered(RemoveMemberBase):
    def test_action_in_enum_and_dispatch(self):
        self.assertIn("remove_member", TEAM_ACTIONS)
        definition = self._tool("top1").get_tool_definition()
        enum = definition["function"]["parameters"]["properties"]["action"]["enum"]
        self.assertIn("remove_member", enum)


class TestPermissionGates(RemoveMemberBase):
    def test_cannot_remove_self(self):
        tool = self._tool("l1a", leader_id="top1")
        result = tool._action_remove_member({"target_member_id": "l1a"})
        self.assertIn("error", result)
        self.assertIn("不可移除自己", result["error"])
        # 名单不变
        self.assertIsNotNone(team_store.get_member("top1", "l1a"))

    def test_cannot_remove_direct_leader(self):
        """l2a 不能移除 l1a（直属上级）。"""
        tool = self._tool("l2a", leader_id="l1a")
        result = tool._action_remove_member({"target_member_id": "l1a"})
        self.assertIn("error", result)
        self.assertIn("上级", result["error"])

    def test_cannot_remove_top_ancestor(self):
        """l2a 不能移除顶层的 top1（团队所有者 + 祖先，而非直属 leader）。"""
        tool = self._tool("l2a", leader_id="l1a")
        result = tool._action_remove_member({"target_member_id": "top1"})
        self.assertIn("error", result)
        # top1 是团队所有者而非 team_members 成员行，命中"所有者"闸（同为祖先语义）
        self.assertTrue(
            "所有者" in result["error"] or "上级" in result["error"],
            result["error"],
        )
        self.assertIsNotNone(team_store.get_member("top1", "l2a"))

    def test_cannot_remove_sibling(self):
        """l1a 不能移除平级 l1b（不在自己的后代集合中）。"""
        tool = self._tool("l1a", leader_id="top1")
        result = tool._action_remove_member({"target_member_id": "l1b"})
        self.assertIn("error", result)
        self.assertIsNotNone(team_store.get_member("top1", "l1b"))

    def test_missing_target(self):
        tool = self._tool("top1")
        result = tool._action_remove_member({})
        self.assertIn("error", result)
        self.assertIn("target_member_id", result["error"])

    def test_unknown_target(self):
        tool = self._tool("top1")
        result = tool._action_remove_member({"target_member_id": "不存在"})
        self.assertIn("error", result)
        self.assertIn("不存在", result["error"])


class TestRemoveLeaf(RemoveMemberBase):
    def test_top_removes_direct_member(self):
        tool = self._tool("top1")
        result = tool._action_remove_member({"target_member_id": "l1b"})
        self.assertNotIn("error", result)
        self.assertTrue(result["persisted"])
        self.assertEqual(result["removed_ids"], ["l1b"])
        self.assertEqual(result["subtree_removed"], [])
        self.assertIsNone(team_store.get_member("top1", "l1b"))
        # 内存名单同步剔除
        self.assertNotIn("l1b", [str(m.get("id")) for m in tool.members])
        # 工作空间被回收
        tool.docker_manager.remove_workspace.assert_called_with("l1b")

    def test_member_count_recomputed(self):
        tool = self._tool("top1")
        before = team_store.get_team("top1")["member_count"]
        self.assertEqual(before, 3)
        tool._action_remove_member({"target_member_id": "l1b"})
        self.assertEqual(team_store.get_team("top1")["member_count"], 2)

    def test_by_name_addressing(self):
        tool = self._tool("top1")
        result = tool._action_remove_member({"target_member_id": "二组组长"})
        self.assertNotIn("error", result)
        self.assertEqual(result["member_id"], "l1b")

    def test_leader_can_remove_own_child(self):
        tool = self._tool("l1a", leader_id="top1")
        result = tool._action_remove_member({"target_member_id": "l2a"})
        self.assertNotIn("error", result)
        self.assertIsNone(team_store.get_member("top1", "l2a"))


class TestCascade(RemoveMemberBase):
    def test_cascade_true_removes_subtree(self):
        tool = self._tool("top1")
        result = tool._action_remove_member({"target_member_id": "l1a"})
        self.assertNotIn("error", result)
        self.assertIn("l2a", result["subtree_removed"])
        self.assertEqual(sorted(result["removed_ids"]), ["l1a", "l2a"])
        self.assertIsNone(team_store.get_member("top1", "l1a"))
        self.assertIsNone(team_store.get_member("top1", "l2a"))
        # 兄弟节点不受影响
        self.assertIsNotNone(team_store.get_member("top1", "l1b"))
        self.assertEqual(team_store.get_team("top1")["member_count"], 1)

    def test_cascade_false_with_descendants_rejected(self):
        tool = self._tool("top1")
        result = tool._action_remove_member(
            {"target_member_id": "l1a", "cascade": False}
        )
        self.assertIn("error", result)
        self.assertIn("cascade", result["error"])
        self.assertEqual(result["cascade_required"], ["l2a"])
        # 拒绝时不得留下部分删除
        self.assertIsNotNone(team_store.get_member("top1", "l1a"))
        self.assertIsNotNone(team_store.get_member("top1", "l2a"))

    def test_cascade_false_without_descendants_ok(self):
        tool = self._tool("top1")
        result = tool._action_remove_member(
            {"target_member_id": "l1b", "cascade": False}
        )
        self.assertNotIn("error", result)
        self.assertIsNone(team_store.get_member("top1", "l1b"))


class TestCascadeCleanupCalls(RemoveMemberBase):
    def test_runtime_purge_invoked_per_removed_id(self):
        broker = MagicMock()
        tool = self._tool("top1", broker=broker)
        with patch("llm.rate_limit.remove_agent") as remove_limiter, \
                patch("plugin.plugin_cascade") as cascade, \
                patch("data.conversation_store.clear_context") as clear_ctx, \
                patch("data.session_cache.clear_user_agent") as clear_cache:
            result = tool._action_remove_member({"target_member_id": "l1a"})
        self.assertNotIn("error", result)

        for mid in ("l1a", "l2a"):
            tool.docker_manager.remove_workspace.assert_any_call(mid)
            broker.remove_agent.assert_any_call("u1", mid)
            remove_limiter.assert_any_call("u1", mid)
            cascade.assert_any_call("u1", agent_id=mid)
            clear_ctx.assert_any_call("u1", mid)
            clear_cache.assert_any_call("u1", mid)

    def test_cleanup_failure_does_not_abort_removal(self):
        """级联清理任一步抛错都不应阻断名单删除（容错口径）。"""
        tool = self._tool("top1")
        tool.docker_manager.remove_workspace.side_effect = RuntimeError("docker down")
        with patch("llm.rate_limit.remove_agent", side_effect=RuntimeError("boom")):
            result = tool._action_remove_member({"target_member_id": "l1b"})
        self.assertNotIn("error", result)
        self.assertTrue(result["persisted"])
        self.assertIsNone(team_store.get_member("top1", "l1b"))

    def test_roster_pushed_after_removal(self):
        tool = self._tool("top1")
        with patch.object(TeamTool, "_push_roster_update",
                          return_value=2) as pushed:
            result = tool._action_remove_member({"target_member_id": "l1b"})
        self.assertEqual(result["roster_pushed"], 2)
        pushed.assert_called_once()


class TestStoreHelpers(RemoveMemberBase):
    def test_collect_subtree_orders_parent_first(self):
        ids = team_store.collect_member_subtree("top1", "l1a")
        self.assertEqual(ids[0], "l1a")
        self.assertIn("l2a", ids)

    def test_remove_member_absent_returns_false(self):
        self.assertFalse(team_store.remove_member("top1", "ghost"))

    def test_remove_subtree_absent_returns_empty(self):
        self.assertEqual(team_store.remove_member_subtree("top1", "ghost"), [])

    def test_collect_subtree_cycle_safe(self):
        """历史脏数据成环时不得无限递归。"""
        team_store.add_member("u1", "top1", "lc", "环", level=2,
                              parent_agent_id="ld", model_id="m")
        team_store.add_member("u1", "top1", "ld", "环2", level=3,
                              parent_agent_id="lc", model_id="m")
        ids = team_store.collect_member_subtree("top1", "lc")
        self.assertEqual(sorted(ids), ["lc", "ld"])


if __name__ == "__main__":
    unittest.main()
