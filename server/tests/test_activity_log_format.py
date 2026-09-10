# -*- coding: utf-8 -*-
"""活动日志格式回归测试（缺陷：日志行首仅有 HH:MM:SS，无日期）。

覆盖：
- ``chat._clock_now()`` 返回带日期的 ``YYYY-MM-DD HH:MM:SS``
- 云端兜底通道：base64 解码后行首为 ``[YYYY-MM-DD HH:MM:SS]``
- 本地/SSH 模式：改走统一 IO read-modify-write（不再落 docker），
  且保序追加（旧内容在前、新行在后）
- ``TeamToolBase._last_activity_at`` 能解析带日期行；旧格式行回退标注
"""

import base64
import re
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agent import chat as chat_mod  # noqa: E402
from tool.team_base import TeamToolBase  # noqa: E402

TS_RE = re.compile(r"^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]")


class TestClockNowHasDate(unittest.TestCase):
    def test_clock_now_has_date(self):
        self.assertRegex(
            chat_mod._clock_now(), r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"
        )


class _FakeIO:
    """最小 WorkspaceIO 替身（异步接口）。"""

    def __init__(self, existing: str = "") -> None:
        self.existing = existing
        self.reads = []
        self.writes = []

    async def read_file(self, workspace_id, path, encoding="utf-8"):
        self.reads.append((workspace_id, path))
        return {
            "exit_code": 0, "stdout": self.existing, "stderr": "",
            "error": None, "content": self.existing,
        }

    async def write_file(self, workspace_id, path, content, encoding="utf-8"):
        self.writes.append((workspace_id, path, content))
        return {"exit_code": 0, "stdout": "", "stderr": "", "error": None}


class TestAppendActivityLog(unittest.TestCase):
    def test_cloud_fallback_line_starts_with_datetime(self):
        """云端/兜底通道：base64 解码后行首为完整日期时间。"""
        captured = {}
        dm = MagicMock()

        def _exec(workspace_id, cmd):
            captured["cmd"] = cmd
            return {"exit_code": 0, "stdout": "", "stderr": ""}

        dm.exec_in_workspace.side_effect = _exec
        line = f"[{chat_mod._clock_now()}] [tool] terminal args=ls -> ok"
        with patch.object(chat_mod.state, "docker_manager", dm):
            chat_mod._append_activity_log("ws1", line)

        b64 = captured["cmd"][2].split("'")[1]
        decoded = base64.b64decode(b64).decode("utf-8")
        self.assertTrue(TS_RE.match(decoded.splitlines()[0]))
        self.assertIn("[tool] terminal", decoded)

    def test_local_mode_appends_via_unified_io(self):
        """本地模式：统一 IO read-modify-write 追加，不触达 docker。"""
        fake = _FakeIO(existing="[2026-01-01 08:00:00] 旧行\n")
        dm = MagicMock()
        line = f"[{chat_mod._clock_now()}] [done(成员)] 回复完成"
        with patch.object(chat_mod, "resolve_mode", return_value="local"), \
                patch.object(chat_mod, "_get_workspace_io", return_value=fake), \
                patch.object(chat_mod.state, "docker_manager", dm):
            chat_mod._append_activity_log(
                "ws1", line, user_id="u1", mode_key="top1"
            )

        self.assertEqual(len(fake.writes), 1)
        ws_id, path, content = fake.writes[0]
        self.assertEqual((ws_id, path), ("ws1", ".self/activity.log"))
        lines = content.splitlines()
        self.assertEqual(lines[0], "[2026-01-01 08:00:00] 旧行")
        self.assertTrue(TS_RE.match(lines[-1]))
        dm.exec_in_workspace.assert_not_called()

    def test_ssh_mode_appends_via_unified_io(self):
        """SSH 模式同样走统一 IO（与本地一致）。"""
        fake = _FakeIO()
        with patch.object(chat_mod, "resolve_mode", return_value="ssh"), \
                patch.object(chat_mod, "_get_workspace_io", return_value=fake), \
                patch.object(chat_mod.state, "docker_manager", MagicMock()):
            chat_mod._append_activity_log(
                "ws1", f"[{chat_mod._clock_now()}] [start(成员)] hi",
                user_id="u1", mode_key="top1",
            )
        self.assertEqual(len(fake.writes), 1)
        self.assertTrue(TS_RE.match(fake.writes[0][2].splitlines()[-1]))


class TestLastActivityAt(unittest.TestCase):
    def _tool(self, existing: str):
        tool = TeamToolBase.__new__(TeamToolBase)
        tool.io = _FakeIO(existing=existing)
        tool.docker_manager = MagicMock()
        return tool

    def test_parses_dated_line(self):
        tool = self._tool("[2026-03-04 10:20:30] [tool] read a.md\n")
        self.assertEqual(tool._last_activity_at("ws1"), "2026-03-04 10:20:30")

    def test_legacy_line_marked_without_date(self):
        tool = self._tool("[10:20:30] [tool] read a.md\n")
        self.assertEqual(tool._last_activity_at("ws1"), "旧格式无日期 10:20:30")


if __name__ == "__main__":
    unittest.main()
