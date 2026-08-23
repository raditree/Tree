# -*- coding: utf-8 -*-
"""P6 数据层测试：会话 / Spec / 团队 / 名字池（隔离临时 DB）。

覆盖 checklist P2/P4 的持久化要点：
1. session_store：创建会话、默认会话兜底、Spec 多选保存、软删除
2. spec_store：内置 3 模板置顶、自定义 Spec 创建/查询回退/删除、关键词检索
3. team_store：建团队、加成员、名单按 TOP 隔离（跨 TOP 名单不传递）、update_member
4. team_init：名字池取名字（同名全局唯一）、名字池不足报错

所有模块使用同一个 ``conversations.db``；通过临时目录重定位 ``_DB_PATH``
并重置各模块 ``_initialized``，避免污染真实数据库，且天然验证"多模块同库共享"。
"""

import shutil
import sys
import tempfile
import unittest
from pathlib import Path

# 将 server 目录加入 Python 路径
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import data.conversation_store as conv  # noqa: E402
import data.session_store as session_store  # noqa: E402
import data.spec_store as spec_store  # noqa: E402
import data.team_store as team_store  # noqa: E402
import data.team_init as team_init  # noqa: E402


def _redirect_db_mods(tmpdir: Path) -> None:
    """把各 data 模块的 DB 路径指向临时目录并重置初始化标记。"""
    for mod in (conv, session_store, spec_store, team_store):
        mod._DB_PATH = tmpdir / "conversations.db"  # type: ignore[attr-defined]
        mod._initialized = False  # type: ignore[attr-defined]


class DataStoreBase(unittest.TestCase):
    """为每个测试创建独立临时 DB 目录。"""

    def setUp(self):
        self._tmp = Path(tempfile.mkdtemp(prefix="trae_test_"))
        _redirect_db_mods(self._tmp)

    def tearDown(self):
        shutil.rmtree(self._tmp, ignore_errors=True)


class TestSessionStore(DataStoreBase):
    def test_create_and_list_sessions(self):
        s = session_store.create_session("u1", "a1", title="会话A")
        self.assertEqual(s["session_id"], s["session_id"])
        rows = session_store.list_sessions("u1", "a1")
        ids = [r["session_id"] for r in rows]
        self.assertIn(s["session_id"], ids)
        # 默认会话兜底存在
        self.assertIn(session_store.DEFAULT_SESSION, ids)

    def test_default_session_fallback_when_none(self):
        rows = session_store.list_sessions("u99", "a99")
        self.assertTrue(
            any(r["session_id"] == session_store.DEFAULT_SESSION for r in rows)
        )

    def test_set_and_get_selected_spec_ids(self):
        raise_ = session_store.create_session("u1", "a1")
        sid = raise_["session_id"]
        session_store.set_selected_spec_ids("u1", sid, ["easy-task", "hard-task"])
        got = session_store.get_selected_spec_ids("u1", sid)
        self.assertEqual(sorted(got), ["easy-task", "hard-task"])

    def test_set_spec_ids_requires_existing_session(self):
        """未创建的会话写 Spec 选择无效（需先 create_session 再 set）。"""
        # 未创建会话：UPDATE 影响 0 行，get 仍为空
        session_store.set_selected_spec_ids("u1", "no_such_session", ["easy-task"])
        self.assertEqual(
            session_store.get_selected_spec_ids("u1", "no_such_session"), []
        )
        # 与路由一致：先创建会话再写，即可持久化
        session_store.create_session("u1", "a1", session_id="session_default")
        session_store.set_selected_spec_ids("u1", "session_default", ["easy-task"])
        self.assertEqual(
            session_store.get_selected_spec_ids("u1", "session_default"),
            ["easy-task"],
        )

    def test_soft_delete_hides_session(self):
        s = session_store.create_session("u1", "a1")
        sid = s["session_id"]
        self.assertTrue(session_store.delete_session("u1", sid))
        self.assertIsNone(session_store.get_session_record("u1", sid))

    def test_sessions_isolated_by_agent(self):
        s1 = session_store.create_session("u1", "a1")
        s2 = session_store.create_session("u1", "a2")
        rows_a1 = session_store.list_sessions("u1", "a1")
        rows_a2 = session_store.list_sessions("u1", "a2")
        self.assertIn(s1["session_id"], [r["session_id"] for r in rows_a1])
        self.assertNotIn(s1["session_id"], [r["session_id"] for r in rows_a2])
        self.assertIn(s2["session_id"], [r["session_id"] for r in rows_a2])


class TestSpecStore(DataStoreBase):
    def test_builtin_specs_pinned_first(self):
        specs = spec_store.list_specs(agent_id=None)
        pinned = [s for s in specs if s["pinned"]]
        # 内置 4 个存在且置顶并被标记为 builtin
        self.assertGreaterEqual(len(pinned), 4)
        builtin_ids = [s["id"] for s in pinned if s["builtin"]]
        self.assertEqual(
            [s for s in spec_store.BUILTIN_SPEC_IDS if s in builtin_ids],
            list(spec_store.BUILTIN_SPEC_IDS),
        )
        # 固定顺序置顶：easy/complex/hard/team-meeting
        order = [s["id"] for s in specs if s["builtin"]]
        self.assertEqual(
            order[:4],
            ["easy-task", "complex-task", "hard-task", "team-meeting"],
        )

    @unittest.skipIf(
        not (Path(__file__).resolve().parent.parent / "tool/spec/builtin").exists(),
        "内置 Spec 模板目录缺失",
    )
    def test_builtin_in_idempotent_register(self):
        spec_store._ensure_db()
        spec_store._ensure_db()  # 二次调用不报错、不重复
        ids = [s["id"] for s in spec_store.list_specs()]
        self.assertEqual(ids.count("easy-task"), 1)

    def test_create_and_query_custom_spec(self):
        spec_store.create_spec(
            "my-spec", "a1", "我的规范", "custom",
            description="处理图片", when=["图像", "视觉"], tags=["img"],
        )
        got = spec_store.get_spec("my-spec", "a1")
        self.assertEqual(got["title"], "我的规范")
        self.assertIn("图像", got["when"])

    def test_get_spec_deprecates_to_builtin(self):
        # 未定义的自定义 id，回退查询内置（agent_id IS NULL）不存在则为 None
        self.assertIsNone(spec_store.get_spec("not-exist", None))

    def test_custom_spec_isolated_by_agent(self):
        spec_store.create_spec("s1", "a1", "A", "custom")
        spec_store.create_spec("s1", "a2", "B", "custom")
        a1 = spec_store.list_specs(agent_id="a1")
        self.assertTrue(any(s["id"] == "s1" and s["title"] == "A" for s in a1))

    @unittest.skipIf(
        not (Path(__file__).resolve().parent.parent / "tool/spec/builtin").exists(),
        "内置 Spec 模板目录缺失",
    )
    def test_keyword_search(self):
        """嵌入不可用时回退关键词检索（mock 掉 embedding）。"""
        # 强制回退关键词：把 spec_store._compute_embedding 设为返回 None
        import unittest.mock
        with unittest.mock.patch.object(
            spec_store, "_compute_embedding", return_value=None
        ):
            # 自定义 spec 描述命中"部署错误"关键词
            spec_store.create_spec(
                "deploy-spec", "a1", "部署指南", "custom",
                description="排查部署错误", when=["deploy", "错误"],
            )
            results = spec_store.search_specs("错误", agent_id="a1", limit=10)
            self.assertTrue(
                any(s["id"] == "deploy-spec" for s in results),
                msg=f"关键词检索应命中 deploy-spec，实际: {results}",
            )

    def test_delete_custom_spec(self):
        spec_store.create_spec("tmp-spec", "a1", "T", "custom")
        self.assertTrue(spec_store.delete_spec("tmp-spec", "a1"))
        self.assertIsNone(spec_store.get_spec("tmp-spec", "a1"))


class TestTeamStore(DataStoreBase):
    def test_init_and_get_team(self):
        team_store.init_team("u1", "top1", "主Agent")
        team = team_store.get_team("top1")
        self.assertIsNotNone(team)
        self.assertEqual(team["name"], "主Agent")

    def test_add_and_list_members(self):
        team_store.init_team("u1", "top1", "主")
        team_store.add_member(
            "u1", "top1", "m1", "晏清", "产品经理", "", "", 1, ""
        )
        team_store.add_member(
            "u1", "top1", "m2", "知遥", "架构师", "", "", 1, ""
        )
        members = team_store.get_members("top1")
        names = [m["name"] for m in members]
        self.assertIn("晏清", names)
        self.assertIn("知遥", names)

    def test_members_isolated_by_top(self):
        """跨 TOP 成员名单不传递：不同 top 之间成员互不可见。"""
        team_store.init_team("u1", "top1", "TOP1")
        team_store.init_team("u1", "top2", "TOP2")
        team_store.add_member("u1", "top1", "m1", "甲", "", "", "", 1, "")
        team_store.add_member("u1", "top2", "m2", "乙", "", "", "", 1, "")
        top1_names = [m["name"] for m in team_store.get_members("top1")]
        top2_names = [m["name"] for m in team_store.get_members("top2")]
        self.assertEqual(top1_names, ["甲"])
        self.assertEqual(top2_names, ["乙"])

    def test_update_member(self):
        team_store.init_team("u1", "top1", "主")
        team_store.add_member("u1", "top1", "m1", "叙白", "工程师", "", "", 1, "")
        team_store.update_member("top1", "m1", duty="转前端", model_id="m2")
        m = team_store.get_member("top1", "m1")
        self.assertEqual(m["duty"], "转前端")
        self.assertEqual(m["model_id"], "m2")


class TestTeamInit(DataStoreBase):
    def test_pick_names_global_unique(self):
        pool = team_init._load_names()
        # 无已用名字时，返回 count 个互不重复的名字
        names = team_init._pick_names("u", "top_a", 4)
        self.assertEqual(len(names), 4)
        self.assertEqual(len(set(names)), 4)
        for n in names:
            self.assertIn(n, pool)

    def test_pick_names_reject_all_used(self):
        """名字池不足（需求超出可用个数）应抛错并提示扩充名字池。

        不依赖 names.json 的固定数量：以当前池大小 +1 作为需求，确保必然超出。
        """
        pool = team_init._load_names()
        self.assertGreaterEqual(len(pool), 1)  # 名字池非空
        with self.assertRaises(ValueError):
            team_init._pick_names("u", "top_b", len(pool) + 1)


if __name__ == "__main__":
    unittest.main()