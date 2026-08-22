"""read 工具行数控制单元测试。

覆盖 ``_apply_line_range`` 与 ``execute`` 的 start_line / line_count 裁剪逻辑：
- 未传行参数时返回全文
- start_line 分段读取
- line_count 限制行数
- 越界/非法值安全处理
"""

import unittest
from unittest.mock import Mock, AsyncMock

from tool.read_tool import ReadTool

SAMPLE = "\n".join(f"line{i}" for i in range(1, 11))  # 10 行


class TestApplyLineRange(unittest.TestCase):
    def test_no_range_returns_full(self):
        self.assertEqual(
            ReadTool._apply_line_range(SAMPLE, {}),
            SAMPLE,
        )

    def test_start_only_reads_from_line(self):
        out = ReadTool._apply_line_range(SAMPLE, {"start_line": 3})
        self.assertEqual(out, "line3\nline4\nline5\nline6\nline7\nline8\nline9\nline10")

    def test_start_and_count(self):
        out = ReadTool._apply_line_range(
            SAMPLE, {"start_line": 2, "line_count": 3}
        )
        self.assertEqual(out, "line2\nline3\nline4")

    def test_count_only(self):
        out = ReadTool._apply_line_range(SAMPLE, {"line_count": 2})
        self.assertEqual(out, "line1\nline2")

    def test_overshoot_clamped(self):
        # 起始 8、读 10 行，超出文件末尾应裁剪
        out = ReadTool._apply_line_range(
            SAMPLE, {"start_line": 8, "line_count": 10}
        )
        self.assertEqual(out, "line8\nline9\nline10")

    def test_start_beyond_eof_empty(self):
        out = ReadTool._apply_line_range(
            SAMPLE, {"start_line": 99, "line_count": 5}
        )
        self.assertEqual(out, "")

    def test_invalid_values_fallback(self):
        # 非法字符串回退：start_line->1，line_count->不限
        out = ReadTool._apply_line_range(
            SAMPLE, {"start_line": "abc", "line_count": "xyz"}
        )
        self.assertEqual(out, SAMPLE)

    def test_zero_count_means_unlimited(self):
        out = ReadTool._apply_line_range(
            SAMPLE, {"start_line": 4, "line_count": 0}
        )
        self.assertEqual(out, "line4\nline5\nline6\nline7\nline8\nline9\nline10")


class TestExecuteLineRange(unittest.TestCase):
    def setUp(self):
        self.io = Mock()
        # read_file 是协程函数：AsyncMock 使 read_file() 返回 awaitable 协程
        self.io.read_file = AsyncMock(return_value={"content": SAMPLE})
        self.tool = ReadTool(self.io, "ws")

    def _execute(self, args):
        return self.tool.execute(args)

    def test_execute_no_range(self):
        ret = self._execute({"file_path": "a.txt"})
        self.assertEqual(ret["content"], SAMPLE)

    def test_execute_with_range(self):
        ret = self._execute(
            {"file_path": "a.txt", "start_line": 3, "line_count": 2}
        )
        self.assertEqual(ret["content"], "line3\nline4")

    def test_invalid_path(self):
        # 空格不属于允许字符集，应在路径校验阶段返回 error
        ret = self._execute({"file_path": "a b.txt"})
        self.assertIn("error", ret)


if __name__ == "__main__":
    unittest.main()
    