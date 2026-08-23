"""read 工具行数控制单元测试。

覆盖 ``_apply_line_range`` 与 ``execute`` 的 start_line / line_count 裁剪逻辑：
- 未传行参数时返回全文
- start_line 分段读取
- line_count 限制行数
- 越界/非法值安全处理

同时覆盖 plan 第 7 项已落地实现的图像输入分支：
- ``_is_valid_image_path`` 图像路径校验（允许空格/中文，拒绝绝对路径/回溯/shell 元字符）
- ``execute`` 显式 ``image`` 参数 / 扩展名自动识别
- ``_read_image`` base64 读取成功与失败回退
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


class TestImagePathValidation(unittest.TestCase):
    """图像路径校验：允许空格/中文，拒绝绝对路径/回溯/shell 元字符。"""

    def test_allow_spaces_and_chinese(self):
        self.assertTrue(
            ReadTool._is_valid_image_path("屏幕截图 2026-08-12 183834.png")
        )

    def test_allow_relative_subdir(self):
        self.assertTrue(ReadTool._is_valid_image_path("a/b/c.webp"))

    def test_reject_absolute_path(self):
        self.assertFalse(ReadTool._is_valid_image_path("/etc/passwd.png"))
        self.assertFalse(ReadTool._is_valid_image_path("\\server\\share.png"))
        # Windows 盘符绝对路径
        self.assertFalse(ReadTool._is_valid_image_path("C:\\file.png"))
        self.assertFalse(ReadTool._is_valid_image_path("C:/file.png"))
        self.assertFalse(ReadTool._is_valid_image_path("d:\\tmp\\a.png"))

    def test_reject_parent_traversal(self):
        self.assertFalse(ReadTool._is_valid_image_path("../secret.png"))
        self.assertFalse(ReadTool._is_valid_image_path("a/../../b.png"))

    def test_reject_shell_metachars(self):
        for ch in "|;&$`<>'\"*?~":
            self.assertFalse(
                ReadTool._is_valid_image_path(f"a{ch}b.png"),
                f"应拒绝含 {ch!r} 的路径",
            )

    def test_reject_empty(self):
        self.assertFalse(ReadTool._is_valid_image_path(""))


class TestExecuteImage(unittest.TestCase):
    """read 工具图像分支：显式 image 参数 / 扩展名自动识别 / base64 读取。"""

    def setUp(self):
        self.io = Mock()
        self.tool = ReadTool(self.io, "ws")

    def test_image_flag_forces_image(self):
        # 文本扩展名 + image=true → 强制走图像读取
        self.io.exec_argv = AsyncMock(
            return_value={"exit_code": 0, "stdout": "aGVsbG8="}
        )
        ret = self.tool.execute({"file_path": "a.txt", "image": True})
        self.assertIn("image_base64", ret)
        self.assertEqual(ret["image_base64"], "aGVsbG8=")
        self.assertEqual(ret["mime"], "image/png")

    def test_extension_auto_detect(self):
        self.io.exec_argv = AsyncMock(
            return_value={"exit_code": 0, "stdout": "aGVsbG8="}
        )
        ret = self.tool.execute({"file_path": "屏幕截图 2026-08-12.png"})
        self.assertIn("image_base64", ret)
        self.assertEqual(ret["mime"], "image/png")

    def test_jpg_mime(self):
        self.io.exec_argv = AsyncMock(
            return_value={"exit_code": 0, "stdout": "aGVsbG8="}
        )
        ret = self.tool.execute({"file_path": "photo.jpg"})
        self.assertEqual(ret["mime"], "image/jpeg")

    def test_invalid_image_path_rejected(self):
        ret = self.tool.execute({"file_path": "/etc/passwd.png"})
        self.assertIn("error", ret)
        ret2 = self.tool.execute({"file_path": "../secret.png"})
        self.assertIn("error", ret2)

    def test_read_image_all_candidates_fail(self):
        # 三个编码器候选全部失败 → 返回错误
        self.io.exec_argv = AsyncMock(
            side_effect=[
                {"exit_code": 1, "stdout": "", "stderr": "python3 not found"},
                {"error": "python not found"},
                {"exit_code": 1, "stdout": "", "stderr": "base64 not found"},
            ]
        )
        ret = self.tool.execute({"file_path": "a.png"})
        self.assertIn("error", ret)
        self.assertEqual(ret["file_path"], "a.png")

    def test_read_image_invalid_base64_falls_next(self):
        # 第一个候选输出非法 base64，回退到第二个候选成功
        self.io.exec_argv = AsyncMock(
            side_effect=[
                {"exit_code": 0, "stdout": "!!!not-base64!!!"},
                {"exit_code": 0, "stdout": "aGVsbG8="},
            ]
        )
        ret = self.tool.execute({"file_path": "a.png"})
        self.assertEqual(ret["image_base64"], "aGVsbG8=")


if __name__ == "__main__":
    unittest.main()
