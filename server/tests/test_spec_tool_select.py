# -*- coding: utf-8 -*-
"""spec 工具 select 逻辑测试（空数组清空 / 整体替换 / 去重 / 先 read 后 select）。"""

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
from tool.spec_tool import SpecTool  # noqa: E402


class SpecSelectBase(unittest.TestCase):
    def setUp(self):
        self._tmp = Path(tempfile.mkdtemp(prefix="trae_spec_"))
        self._old_db = session_store._DB_PATH
        self._old_shared_db = db_mod._DB_PATH
        session_store._DB_PATH = self._tmp / "conversations.db"  # type: ignore[attr-defined]
        session_store._initialized = False  # type: ignore[attr-defined]
        # 共享 connect() 的路径来源（data.db）一并重定向，避免打开真实库
        db_mod._DB_PATH = self._tmp / "conversations.db"  # type: ignore[attr-defined]
        db_mod._wal_configured = False  # type: ignore[attr-defined]
        # 构造会话，模拟 云舟 已建会话（route 里先 create_session 再由 tool 写）
        self.user_id = "u1"
        self.agent_id = "a1"
        self.sid = session_store.create_session(self.user_id, self.agent_id)[
            "session_id"
        ]

    def tearDown(self):
        session_store._DB_PATH = self._old_db  # type: ignore[attr-defined]
        db_mod._DB_PATH = self._old_shared_db  # type: ignore[attr-defined]
        db_mod._wal_configured = False  # type: ignore[attr-defined]
        shutil.rmtree(self._tmp, ignore_errors=True)

    def _make_tool(self):
        tool = SpecTool(
            io=MagicMock(),
            workspace_id="ws1",
            user_id=self.user_id,
            agent_id=self.agent_id,
            session_id=self.sid,
        )
        # mock 覆盖读取：让内置/自定义 spec 均"存在"
        tool._read_spec_content = MagicMock(return_value="# spec")
        return tool

    def _read(self, tool, spec_id):
        """先 read 对应 spec（select 前置要求），成功返回。"""
        r = tool.execute({"action": "read", "spec_id": spec_id})
        self.assertNotIn("error", r)
        return r


class TestSelectToggle(SpecSelectBase):
    def test_select_with_no_ids_cancels_all(self):
        tool = self._make_tool()
        # 先 read 再选两个
        self._read(tool, "easy-task")
        self._read(tool, "hard-task")
        r = tool.execute({"action": "select", "spec_ids": ["easy-task", "hard-task"]})
        self.assertNotIn("error", r)
        self.assertEqual(
            session_store.get_selected_spec_ids(self.user_id, self.sid),
            ["easy-task", "hard-task"],
        )
        # 传空数组取消全部（取消不受 read 前置限制）
        r = tool.execute({"action": "select", "spec_ids": []})
        self.assertNotIn("error", r)
        self.assertEqual(r["spec_ids"], [])
        self.assertIn("取消", r["note"])
        self.assertEqual(
            session_store.get_selected_spec_ids(self.user_id, self.sid), []
        )

    def test_select_omitted_spec_ids_cancels_all(self):
        """不传 spec_ids（缺省空）等同取消全部。"""
        tool = self._make_tool()
        self._read(tool, "easy-task")
        tool.execute({"action": "select", "spec_ids": ["easy-task"]})
        self.assertEqual(
            session_store.get_selected_spec_ids(self.user_id, self.sid),
            ["easy-task"],
        )
        tool.execute({"action": "select"})
        self.assertEqual(
            session_store.get_selected_spec_ids(self.user_id, self.sid), []
        )

    def test_select_replaces_previous_set(self):
        """select 是整体替换：传新集合时旧集合被覆盖。"""
        tool = self._make_tool()
        self._read(tool, "easy-task")
        self._read(tool, "hard-task")
        self._read(tool, "complex-task")
        tool.execute({"action": "select", "spec_ids": ["easy-task", "hard-task"]})
        tool.execute({"action": "select", "spec_ids": ["complex-task"]})
        self.assertEqual(
            session_store.get_selected_spec_ids(self.user_id, self.sid),
            ["complex-task"],
        )

    def test_select_dedup(self):
        tool = self._make_tool()
        self._read(tool, "easy-task")
        tool.execute({"action": "select", "spec_ids": ["easy-task", "easy-task"]})
        self.assertEqual(
            session_store.get_selected_spec_ids(self.user_id, self.sid),
            ["easy-task"],
        )

    def test_select_missing_spec_rejected(self):
        tool = self._make_tool()
        tool._read_spec_content = MagicMock(return_value=None)
        r = tool.execute({"action": "select", "spec_ids": ["nope"]})
        self.assertIn("error", r)
        self.assertIn("Spec 不存在", r["error"])
        # 校验失败不影响原选择
        self.assertEqual(
            session_store.get_selected_spec_ids(self.user_id, self.sid), []
        )


class TestSelectRequiresRead(SpecSelectBase):
    """select 前置校验：必须先 read 对应 Spec，未 read 直接 select 被拒绝。"""

    def test_select_without_read_rejected(self):
        tool = self._make_tool()
        # 未 read 直接 select
        r = tool.execute({"action": "select", "spec_ids": ["easy-task"]})
        self.assertIn("error", r)
        self.assertIn("先 read", r["error"])
        # 校验失败不影响原选择
        self.assertEqual(
            session_store.get_selected_spec_ids(self.user_id, self.sid), []
        )

    def test_select_mixed_read_and_unread_rejected(self):
        tool = self._make_tool()
        self._read(tool, "easy-task")
        # easy-task 已 read，hard-task 未 read -> 整体拒绝
        r = tool.execute(
            {"action": "select", "spec_ids": ["easy-task", "hard-task"]}
        )
        self.assertIn("error", r)
        self.assertIn("hard-task", r["error"])
        self.assertIn("先 read", r["error"])
        self.assertEqual(
            session_store.get_selected_spec_ids(self.user_id, self.sid), []
        )

    def test_select_after_read_allowed(self):
        tool = self._make_tool()
        self._read(tool, "easy-task")
        r = tool.execute({"action": "select", "spec_ids": ["easy-task"]})
        self.assertNotIn("error", r)
        self.assertEqual(
            session_store.get_selected_spec_ids(self.user_id, self.sid),
            ["easy-task"],
        )

    def test_read_failure_not_recorded(self):
        tool = self._make_tool()
        # read 不存在的 spec：读取失败，不应被记为"已 read"
        tool._read_spec_content = MagicMock(return_value=None)
        r = tool.execute({"action": "read", "spec_id": "nope"})
        self.assertIn("error", r)
        self.assertNotIn("nope", tool._read_spec_ids)
        # 随后 select 仍被拒（未 read）
        r2 = tool.execute({"action": "select", "spec_ids": ["nope"]})
        self.assertIn("error", r2)


if __name__ == "__main__":
    unittest.main()
