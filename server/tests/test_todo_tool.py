# -*- coding: utf-8 -*-
"""SetTodoList 工具测试：agent 自定义 id / 缺省生成 / 去重回退。"""

import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

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


class TestActionUpdateClearGet(unittest.TestCase):
    """SetTodoList 工具 update/clear/get 动作。

    不 patch run_io，走真实协程桥（AsyncMock 驱动 read_file/write_file），
    覆盖：按 id 更新 status/progress、进度钳制、clear 清空、get 快照。
    """

    def setUp(self):
        self._tmp = Path(tempfile.mkdtemp(prefix="trae_todo_"))
        self.io = MagicMock()
        self.workspace_id = "ws1"
        self.user_id = "u1"
        initial = json.dumps(
            [{"id": "t1", "content": "任务1", "status": "pending", "progress": 0}],
            ensure_ascii=False,
        )
        md = "# 任务清单（Todo List）\n\n```json\n" + initial + "\n```\n"
        self.io.read_file = AsyncMock(return_value={"content": md, "error": None})
        self.io.write_file = AsyncMock(return_value={"error": None})
        self.tool = SetTodoListTool(
            io=self.io, workspace_id=self.workspace_id, user_id=self.user_id
        )

    def tearDown(self):
        shutil.rmtree(self._tmp, ignore_errors=True)

    def test_update_status(self):
        r = self.tool.execute(
            {"action": "update", "todo_id": "t1", "status": "in_progress"}
        )
        self.assertNotIn("error", r)
        self.assertEqual(r["todo"]["status"], "in_progress")
        self.assertIsInstance(r["todo"]["progress"], int)

    def test_update_completed_sets_progress(self):
        r = self.tool.execute(
            {"action": "update", "todo_id": "t1", "status": "completed"}
        )
        self.assertNotIn("error", r)
        self.assertEqual(r["todo"]["status"], "completed")
        self.assertEqual(r["todo"]["progress"], 100)

    def test_update_progress(self):
        r = self.tool.execute(
            {"action": "update", "todo_id": "t1", "progress": 80}
        )
        self.assertNotIn("error", r)
        self.assertEqual(r["todo"]["progress"], 80)

    def test_update_clamps_progress_high(self):
        r = self.tool.execute(
            {"action": "update", "todo_id": "t1", "progress": 150}
        )
        self.assertEqual(r["todo"]["progress"], 100)

    def test_update_clamps_progress_low(self):
        r = self.tool.execute(
            {"action": "update", "todo_id": "t1", "progress": -5}
        )
        self.assertEqual(r["todo"]["progress"], 0)

    def test_update_missing_todo_id(self):
        r = self.tool.execute({"action": "update", "status": "x"})
        self.assertIn("error", r)

    def test_update_unknown_todo(self):
        r = self.tool.execute(
            {"action": "update", "todo_id": "t2", "status": "x"}
        )
        self.assertIn("error", r)
        self.assertIn("t2", r["error"])

    def test_clear(self):
        r = self.tool.execute({"action": "clear"})
        self.assertNotIn("error", r)
        self.assertEqual(r["action"], "clear")

    def test_get_returns_saved(self):
        r = self.tool.execute({"action": "get"})
        self.assertNotIn("error", r)
        self.assertEqual(r["count"], 1)
        self.assertEqual(r["todos"][0]["id"], "t1")
        self.assertEqual(r["todos"][0]["status"], "pending")

    def test_unknown_action(self):
        r = self.tool.execute({"action": "nope"})
        self.assertIn("error", r)


if __name__ == "__main__":
    unittest.main()