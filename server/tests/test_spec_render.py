# -*- coding: utf-8 -*-
"""spec 工具 front matter 渲染/解析回归测试。

覆盖：
- ``_render_spec_markdown`` 输出含 version/classification/risk/changelog 字段
  （与内置模板 front matter 结构对齐），且 pinned/builtin 为 false。
- 渲染结果可被 ``spec_store._parse_front_matter`` 往返解析回 risk/version 值
  （v2 扁平 changelog 列表不泄漏子键）。
- ``SpecTool._action_create`` 带 risk/classification 时落盘文件含对应字段。
- ``SpecTool._action_update`` 版本号自增并保留 changelog 历史条目。
"""

import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock

# 将 server 目录加入 Python 路径
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import data.db as db_mod  # noqa: E402
import data.session_store as session_store  # noqa: E402
from data.spec_store import _parse_front_matter  # noqa: E402
from tool.spec_tool import (  # noqa: E402
    SpecTool,
    _normalize_risk,
    _parse_changelog,
    _render_spec_markdown,
)


class TestRenderSpecMarkdown(unittest.TestCase):
    def _render(self, **overrides):
        args = dict(
            spec_id="demo-task",
            title="演示任务",
            task_type="custom",
            description="演示用",
            when=["场景 A", "场景 B"],
            tags=["demo"],
            workflow="1. 读上下文。",
            rules="先读后写。",
            notes="注意。",
        )
        args.update(overrides)
        return _render_spec_markdown(**args)

    def test_default_render_contains_new_fields(self):
        md = self._render()
        self.assertIn("version: 1\n", md)
        self.assertIn("classification: 内部规范\n", md)
        self.assertIn("risk: low\n", md)
        self.assertIn("changelog:\n", md)
        self.assertIn("pinned: false\n", md)
        self.assertIn("builtin: false\n", md)
        # 默认 changelog 为初始创建条目
        self.assertIn("v1(", md)
        self.assertIn("初始创建", md)

    def test_custom_risk_and_classification(self):
        md = self._render(risk="high", classification="团队约定")
        self.assertIn("risk: high\n", md)
        self.assertIn("classification: 团队约定\n", md)

    def test_changelog_list_render(self):
        md = self._render(
            version=2,
            changelog=[
                "v2(2026-08-30): 二次更新",
                "v1(2026-08-23): 初始创建",
            ],
        )
        self.assertIn("- \"v2(2026-08-30): 二次更新\"\n", md)
        self.assertIn("- \"v1(2026-08-23): 初始创建\"\n", md)

    def test_render_roundtrip_parse_front_matter(self):
        """渲染结果可被 _parse_front_matter 解析回 risk/version，无子键泄漏。"""
        md = self._render(
            risk="medium",
            classification="内部规范",
            version=3,
            changelog=[
                "v3(2026-08-30): 第三次更新",
                "v2(2026-08-25): 第二次更新",
                "v1(2026-08-23): 初始创建",
            ],
        )
        meta = _parse_front_matter(md)
        self.assertIsNotNone(meta)
        self.assertEqual(meta["risk"], "medium")
        self.assertEqual(meta["classification"], "内部规范")
        self.assertEqual(meta["version"], 3)
        self.assertEqual(meta["pinned"], False)
        self.assertEqual(meta["builtin"], False)
        self.assertEqual(meta["title"], "演示任务")
        self.assertEqual(meta["when"], ["场景 A", "场景 B"])
        # 扁平 changelog 条目不再泄漏为顶层键
        self.assertNotIn("v3(2026-08-30): 第三次更新", meta)
        self.assertNotIn("date", meta)

    def test_normalize_risk(self):
        self.assertEqual(_normalize_risk("high"), "high")
        self.assertEqual(_normalize_risk("review"), "review")
        self.assertEqual(_normalize_risk("High"), "high")
        self.assertEqual(_normalize_risk("unknown"), "low")
        self.assertEqual(_normalize_risk(None), "low")
        self.assertEqual(_normalize_risk(""), "low")

    def test_parse_changelog_flat(self):
        md = self._render(
            version=2,
            changelog=[
                "v2(2026-08-30): 修正工具名",
                "v1(2026-08-23): 初版",
            ],
        )
        items = _parse_changelog(md)
        self.assertEqual(len(items), 2)
        self.assertEqual(items[0], "v2(2026-08-30): 修正工具名")
        self.assertEqual(items[1], "v1(2026-08-23): 初版")

    def test_parse_changelog_nested_not_required(self):
        """旧式嵌套 changelog 解析不佳但不应报错；空内容返回空列表。"""
        self.assertEqual(_parse_changelog("no front matter"), [])


class SpecCreateUpdateBase(unittest.TestCase):
    """仿 test_data_stores.py / test_spec_tool_select.py：临时 DB + mock io 捕获落盘内容。

    注意：``_action_create`` 会经 spec_store 写索引，必须把 spec_store 的
    ``_DB_PATH`` 一并重定向到临时目录，避免污染真实数据库。
    """

    def setUp(self):
        self._tmp = Path(tempfile.mkdtemp(prefix="trae_spec_render_"))
        self._old_db = session_store._DB_PATH
        self._old_shared_db = db_mod._DB_PATH
        import data.spec_store as spec_store  # noqa: PLC0415

        self._old_spec_db = spec_store._DB_PATH
        self._old_spec_init = spec_store._initialized
        session_store._DB_PATH = self._tmp / "conversations.db"  # type: ignore[attr-defined]
        session_store._initialized = False  # type: ignore[attr-defined]
        spec_store._DB_PATH = self._tmp / "conversations.db"  # type: ignore[attr-defined]
        spec_store._initialized = False  # type: ignore[attr-defined]
        db_mod._DB_PATH = self._tmp / "conversations.db"  # type: ignore[attr-defined]
        db_mod._wal_configured = False  # type: ignore[attr-defined]
        self.user_id = "u1"
        self.agent_id = "a1"
        self.sid = session_store.create_session(self.user_id, self.agent_id)[
            "session_id"
        ]

    def tearDown(self):
        import data.spec_store as spec_store  # noqa: PLC0415

        session_store._DB_PATH = self._old_db  # type: ignore[attr-defined]
        spec_store._DB_PATH = self._old_spec_db  # type: ignore[attr-defined]
        spec_store._initialized = self._old_spec_init  # type: ignore[attr-defined]
        db_mod._DB_PATH = self._old_shared_db  # type: ignore[attr-defined]
        db_mod._wal_configured = False  # type: ignore[attr-defined]
        shutil.rmtree(self._tmp, ignore_errors=True)

    def _make_tool(self, written_files):
        """构造 SpecTool：io.write_file 为 async 协程（run_io 需 awaitable），
        捕获写入内容到 written_files dict。
        """
        io = MagicMock()

        async def fake_write(ws, path, content):
            written_files[path] = content
            return {"success": True}

        io.write_file.side_effect = fake_write
        tool = SpecTool(
            io=io,
            workspace_id="ws1",
            user_id=self.user_id,
            agent_id=self.agent_id,
            session_id=self.sid,
        )
        # 绕过 run_io 桥：直接 mock 读取，让"已存在"判断可控
        tool._read_spec_content = MagicMock(return_value=None)
        return tool


class TestActionCreate(SpecCreateUpdateBase):
    def test_create_with_risk_and_classification(self):
        written = {}
        tool = self._make_tool(written)
        r = tool.execute({
            "action": "create",
            "title": "高危迁移规范",
            "task_type": "hard",
            "description": "数据迁移规范",
            "risk": "high",
            "classification": "团队约定",
            "workflow": "1. 先开会。",
        })
        self.assertNotIn("error", r)
        path = "spec/" + r["spec_id"] + ".md"
        self.assertIn(path, written)
        md = written[path]
        self.assertIn("risk: high\n", md)
        self.assertIn("classification: 团队约定\n", md)
        self.assertIn("version: 1\n", md)
        # 索引元数据含 risk/classification 的 front matter 写入
        meta = _parse_front_matter(md)
        self.assertEqual(meta["risk"], "high")
        self.assertEqual(meta["task_type"], "hard")

    def test_create_invalid_risk_falls_back_low(self):
        written = {}
        tool = self._make_tool(written)
        r = tool.execute({
            "action": "create",
            "title": "默认风险",
            "task_type": "custom",
            "risk": "super-dangerous",
            "workflow": "1. 执行。",
        })
        self.assertNotIn("error", r)
        path = "spec/" + r["spec_id"] + ".md"
        self.assertIn("risk: low\n", written[path])


class TestActionUpdate(SpecCreateUpdateBase):
    def test_update_bumps_version_and_keeps_changelog(self):
        written = {}
        tool = self._make_tool(written)
        # 先 create 一个 v1
        r1 = tool.execute({
            "action": "create",
            "title": "演进规范",
            "task_type": "custom",
            "risk": "low",
            "workflow": "1. 第一步。",
        })
        self.assertNotIn("error", r1)
        sid = r1["spec_id"]

        # 模拟后续 update：重新构造 tool，_read_spec_content 返回已落盘内容
        tool2 = self._make_tool(written)
        tool2._read_spec_content = MagicMock(
            return_value=written["spec/%s.md" % sid]
        )
        r2 = tool2.execute({
            "action": "update",
            "spec_id": sid,
            "workflow": "1. 第一步。\n2. 第二步。",
        })
        self.assertNotIn("error", r2)
        md = written["spec/%s.md" % sid]
        meta = _parse_front_matter(md)
        # 版本 +1 且保留 v1 历史条目
        self.assertEqual(meta["version"], 2)
        items = _parse_changelog(md)
        self.assertEqual(len(items), 2)
        self.assertTrue(items[0].startswith("v2("))
        self.assertIn("初始创建", items[1])
        # 未传 risk/classification 时保留原值
        self.assertEqual(meta["risk"], "low")
        self.assertIn("第二步", md)

    def test_update_override_risk(self):
        written = {}
        tool = self._make_tool(written)
        r1 = tool.execute({
            "action": "create",
            "title": "风险演进",
            "task_type": "custom",
            "risk": "low",
            "workflow": "1. 第一步。",
        })
        sid = r1["spec_id"]
        tool2 = self._make_tool(written)
        tool2._read_spec_content = MagicMock(
            return_value=written["spec/%s.md" % sid]
        )
        r2 = tool2.execute({
            "action": "update",
            "spec_id": sid,
            "risk": "high",
        })
        self.assertNotIn("error", r2)
        meta = _parse_front_matter(written["spec/%s.md" % sid])
        self.assertEqual(meta["risk"], "high")
        self.assertEqual(meta["version"], 2)


if __name__ == "__main__":
    unittest.main()
