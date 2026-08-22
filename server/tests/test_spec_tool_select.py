# -*- coding: utf-8 -*-
"""spec 工具 select 取消逻辑测试（空数组清空 / 整体替换 / 去重）。"""

import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock

# 将 server 目录加入 Python 路径
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import data.session_store as session_store  # noqa: E402
from tool.spec_tool import SpecTool  # noqa: E402


class SpecSelectBase(unittest.TestCase):
    def setUp(self):
        self._tmp = Path(tempfile.mkdtemp(prefix="trae_spec_"))
        self._old_db = session_store._DB_PATH
        session_store._DB_PATH = self._tmp / "conversations.db"  # type: ignore[attr-defined]
        session_store._initialized = False  # type: ignore[attr-defined]
        # 构造会话，模拟 云舟 已建会话（route 里先 create_session 再由 tool 写）
        self.user_id = "u1"
        self.agent_id = "a1"
        self.sid = session_store.create_session(self.user_id, self.agent_id)[
            "session_id"
        ]

    def tearDown(self):
        session_store._DB_PATH = self._old_db  # type: ignore[attr-defined]
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


class TestSelectToggle(SpecSelectBase):
    def test_select_with_no_ids_cancels_all(self):
        tool = self._make_tool()
        # 先选两个
        r = tool.execute({"action": "select", "spec_ids": ["easy-task", "hard-task"]})
        self.assertNotIn("error", r)
        self.assertEqual(
            session_store.get_selected_spec_ids(self.user_id, self.sid),
            ["easy-task", "hard-task"],
        )
        # 传空数组取消全部
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
        tool.execute({"action": "select", "spec_ids": ["easy-task", "hard-task"]})
        tool.execute({"action": "select", "spec_ids": ["complex-task"]})
        self.assertEqual(
            session_store.get_selected_spec_ids(self.user_id, self.sid),
            ["complex-task"],
        )

    def test_select_dedup(self):
        tool = self._make_tool()
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
        # 校验失败不影响原选择
        self.assertEqual(
            session_store.get_selected_spec_ids(self.user_id, self.sid), []
        )


if __name__ == "__main__":
    unittest.main()