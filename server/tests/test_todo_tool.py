# -*- coding: utf-8 -*-
"""SetTodoList 工具测试：agent 自定义 id / 缺省生成 / 去重回退。"""

import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# 将 server 目录加入 Python 路径
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tool import todo_tool  # noqa: E402
from tool.todo_tool import SetTodoListTool  # noqa: E402


class TodoToolBase(unittest.TestCase):
    def setUp(self):
        self._tmp = Path(tempfile.mkdtemp(prefix="trae_todo_"))
        self.user_id = "u1"
        self.workspace_id = "ws1"

    def tearDown(self):
        shutil.rmtree(self._tmp, ignore_errors=True)

    def _make_tool(self):
        io = MagicMock()
        tool = SetTodoListTool(
            io=io,
            workspace_id=self.workspace_id,
            user_id=self.user_id,
        )
        return tool

    def _write_success(self):
        """让 run_io 返回成功（无 error）。"""
        patcher = patch.object(todo_tool, "run_io", return_value={"error": None})
        patcher.start()
        self.addCleanup(patcher.stop)

    def _load_saved(self, tool):
        """从 mock io 拿回写入的 todos。"""
        call = tool.io.write_file.call_args
        content = call[0][2]
        import json as _json
        import re as _re

        match = _re.search(r"```json\s*(.*?)\s*```", content, _re.DOTALL)
        return _json.loads(match.group(1))


class TestSetWithCustomId(TodoToolBase):
    def test_custom_id_preserved(self):
        tool = self._make_tool()
        self._write_success()
        r = tool.execute({
            "action": "set",
            "todos": [{"id": "task_export", "content": "导出数据"}],
        })
        self.assertNotIn("error", r)
        self.assertEqual(r["todos"][0]["id"], "task_export")

    def test_missing_id_generates(self):
        tool = self._make_tool()
        self._write_success()
        r = tool.execute({
            "action": "set",
            "todos": [{"content": "无 id 任务"}],
        })
        self.assertNotIn("error", r)
        self.assertTrue(str(r["todos"][0]["id"]).startswith("todo_"))

    def test_non_string_id_falls_back(self):
        tool = self._make_tool()
        self._write_success()
        r = tool.execute({
            "action": "set",
            "todos": [{"id": 12345, "content": "数字 id"}],
        })
        self.assertNotIn("error", r)
        self.assertTrue(str(r["todos"][0]["id"]).startswith("todo_"))

    def test_duplicate_custom_id_dedups(self):
        tool = self._make_tool()
        self._write_success()
        r = tool.execute({
            "action": "set",
            "todos": [
                {"id": "dup", "content": "任务A"},
                {"id": "dup", "content": "任务B"},
            ],
        })
        self.assertNotIn("error", r)
        ids = [t["id"] for t in r["todos"]]
        self.assertEqual(len(ids), len(set(ids)), "同批 id 必须唯一")

    def test_persisted_with_custom_id(self):
        tool = self._make_tool()
        self._write_success()
        tool.execute({
            "action": "set",
            "todos": [{"id": "task_x", "content": "持久化验证"}],
        })
        saved = self._load_saved(tool)
        self.assertEqual(saved[0]["id"], "task_x")


if __name__ == "__main__":
    unittest.main()