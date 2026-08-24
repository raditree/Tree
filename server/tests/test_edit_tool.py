# -*- coding: utf-8 -*-
"""edit 工具换行容错单元测试。

覆盖 LF / CRLF 文件的精确字符串替换：
- LF 文件：old_text（LF）正常匹配替换（回归）
- CRLF 文件：old_text 传 LF 也能匹配（自动按 CRLF 归一），写回保持 CRLF
- CRLF 文件：跨行 old_text 匹配
- old_text 自带 CRLF（如从 read 复制）：归一后仍可匹配，不产生 \r\r\n
- 未找到 / 多处匹配：报错且不写回
"""

import unittest
from unittest.mock import AsyncMock, Mock

from tool.edit_tool import EditTool


class TestEditTool(unittest.TestCase):
    def setUp(self):
        self.io = Mock()
        self.io.read_file = AsyncMock()
        self.io.write_file = AsyncMock(return_value={"success": True})
        self.tool = EditTool(self.io, "ws")

    def _edit(self, content, old_text, new_text, file_path="a.txt"):
        self.io.read_file.return_value = {"content": content}
        return self.tool.execute({
            "file_path": file_path,
            "old_text": old_text,
            "new_text": new_text,
        })

    def _written(self):
        """WriteTool 以 (workspace_id, file_path, content) 调用 write_file。"""
        return self.io.write_file.call_args[0][2]

    def test_lf_file_basic_replace(self):
        ret = self._edit("line1\nline2\nline3\n", "line2", "LINE2")
        self.assertEqual(ret["success"], True)
        self.assertEqual(self._written(), "line1\nLINE2\nline3\n")

    def test_crlf_file_with_lf_old_text(self):
        # CRLF 文件 + LLM 传 LF old_text → 应匹配成功，写回保持 CRLF
        ret = self._edit("line1\r\nline2\r\nline3\r\n", "line2", "LINE2")
        self.assertEqual(ret["success"], True)
        self.assertEqual(self._written(), "line1\r\nLINE2\r\nline3\r\n")

    def test_crlf_file_multiline_lf_old_text(self):
        ret = self._edit("a\r\nb\r\nc\r\n", "a\nb", "A\nB")
        self.assertEqual(ret["success"], True)
        self.assertEqual(self._written(), "A\r\nB\r\nc\r\n")

    def test_crlf_file_old_text_with_crlf(self):
        # LLM 从 read 复制带回 \r\n 的 old_text：归一后不产生 \r\r\n
        ret = self._edit("a\r\nb\r\nc\r\n", "a\r\nb", "A\r\nB")
        self.assertEqual(ret["success"], True)
        self.assertEqual(self._written(), "A\r\nB\r\nc\r\n")

    def test_no_match(self):
        ret = self._edit("line1\nline2\n", "nope", "x")
        self.assertIn("error", ret)
        self.io.write_file.assert_not_called()

    def test_multiple_match_rejected(self):
        ret = self._edit("x\nx\n", "x", "y")
        self.assertIn("error", ret)
        self.assertEqual(ret["match_count"], 2)
        self.io.write_file.assert_not_called()


if __name__ == "__main__":
    unittest.main()
