"""grep 内置工具单元测试。

覆盖：
- 工具定义（name=grep、必填 pattern、参数齐全）
- 参数校验（空 pattern / 非法路径：绝对路径、盘符、.. 回溯、非法字符）
- 执行分发（pattern/path/regex/ignore_case/max_depth/exclude 正确透传
  WorkspaceIO.grep_search）
- 结果组装（命中 / 无命中 exit_code=1 / max_results 截断标注）
"""

import unittest
from unittest.mock import AsyncMock, Mock

from tool.grep_tool import (
    DEFAULT_EXCLUDE_PATTERNS,
    DEFAULT_MAX_LINE_CHARS,
    DEFAULT_MAX_RESULTS,
    DEFAULT_MAX_TOTAL_CHARS,
    GrepTool,
)


class TestToolDefinition(unittest.TestCase):
    def setUp(self):
        self.tool = GrepTool(Mock(), "ws")

    def test_name_and_required(self):
        fn = self.tool.get_tool_definition()["function"]
        self.assertEqual(fn["name"], "grep")
        self.assertEqual(fn["parameters"]["required"], ["pattern"])

    def test_has_all_params(self):
        props = self.tool.get_tool_definition()["function"]["parameters"]["properties"]
        for key in (
            "pattern", "path", "regex", "ignore_case",
            "max_depth", "exclude", "max_results",
        ):
            self.assertIn(key, props)


class TestPathValidation(unittest.TestCase):
    def test_valid_relative_paths(self):
        for p in ("lib/src", "a/b/c.dart", "lib", "dir_1.2-3"):
            self.assertTrue(GrepTool._is_valid_path(p), p)

    def test_reject_absolute_and_drive(self):
        self.assertFalse(GrepTool._is_valid_path("/etc"))
        self.assertFalse(GrepTool._is_valid_path("\\etc"))
        self.assertFalse(GrepTool._is_valid_path("C:/Users"))
        self.assertFalse(GrepTool._is_valid_path("d:\\tmp"))

    def test_reject_parent_traversal(self):
        self.assertFalse(GrepTool._is_valid_path("../secret"))
        self.assertFalse(GrepTool._is_valid_path("a/../../b"))

    def test_reject_illegal_chars(self):
        for ch in "|;&$`<>'\"*?~ ":
            self.assertFalse(GrepTool._is_valid_path(f"a{ch}b"), ch)

    def test_reject_empty(self):
        self.assertFalse(GrepTool._is_valid_path(""))


class TestExecute(unittest.TestCase):
    def setUp(self):
        self.io = Mock()
        self.io.grep_search = AsyncMock(
            return_value={"exit_code": 0, "stdout": "lib/a.dart:hello\nlib/b.dart:hello2"}
        )
        self.tool = GrepTool(self.io, "ws")

    def test_empty_pattern_rejected(self):
        ret = self.tool.execute({})
        self.assertIn("error", ret)
        ret2 = self.tool.execute({"pattern": "  "})
        self.assertIn("error", ret2)

    def test_invalid_path_rejected(self):
        ret = self.tool.execute({"pattern": "x", "path": "../secret"})
        self.assertIn("error", ret)
        ret2 = self.tool.execute({"pattern": "x", "path": "E:/foo"})
        self.assertIn("error", ret2)
        self.io.grep_search.assert_not_awaited()

    def test_non_string_path_rejected(self):
        ret = self.tool.execute({"pattern": "x", "path": 123})
        self.assertIn("error", ret)

    def test_hits_returned(self):
        ret = self.tool.execute({"pattern": "hello"})
        self.assertEqual(ret["exit_code"], 0)
        self.assertEqual(ret["count"], 2)
        self.assertEqual(ret["total"], 2)
        self.assertFalse(ret["truncated"])
        self.assertEqual(ret["matches"][0], "lib/a.dart:hello")
        self.io.grep_search.assert_awaited_once_with(
            "ws", "hello", path="", regex=False, ignore_case=False,
            max_depth=0, exclude=DEFAULT_EXCLUDE_PATTERNS,
        )

    def test_sender_truncation_flags_merged(self):
        """本地模式前端在发送端截断的标记并入结果，避免部分命中被当全量。"""
        self.io.grep_search = AsyncMock(return_value={
            "exit_code": 0,
            "stdout": "lib/a.dart:hello\nlib/b.dart:hello2",
            "truncated": True,
            "line_truncated": True,
        })
        ret = self.tool.execute({"pattern": "hello"})
        self.assertTrue(ret["truncated"])
        self.assertTrue(ret["line_truncated"])

    def test_sender_flags_absent_for_cloud_and_ssh(self):
        """云端/SSH 不返回发送端标记时，行为与旧版一致。"""
        ret = self.tool.execute({"pattern": "hello"})
        self.assertFalse(ret["truncated"])
        self.assertFalse(ret["line_truncated"])

    def test_params_forwarded(self):
        self.tool.execute(
            {"pattern": r"\d+", "path": "lib/src", "regex": True, "ignore_case": True}
        )
        self.io.grep_search.assert_awaited_once_with(
            "ws", r"\d+", path="lib/src", regex=True, ignore_case=True,
            max_depth=0, exclude=DEFAULT_EXCLUDE_PATTERNS,
        )

    def test_max_depth_and_exclude_forwarded(self):
        ret = self.tool.execute(
            {"pattern": "x", "max_depth": 2,
             "exclude": "node_modules, *.min.js,"}
        )
        expected = ["node_modules", "*.min.js"] + [
            p for p in DEFAULT_EXCLUDE_PATTERNS if p != "node_modules"
        ]
        self.io.grep_search.assert_awaited_once_with(
            "ws", "x", path="", regex=False, ignore_case=False,
            max_depth=2, exclude=expected,
        )
        self.assertEqual(ret["max_depth"], 2)
        self.assertEqual(ret["exclude"], expected)

    def test_default_excludes_merged(self):
        """未传 exclude 时也会并入默认排除目录（依赖/缓存/构建产物）。"""
        ret = self.tool.execute({"pattern": "x"})
        self.assertEqual(ret["exclude"], DEFAULT_EXCLUDE_PATTERNS)
        self.assertIn(".venv", ret["exclude"])
        self.assertIn("node_modules", ret["exclude"])

    def test_explicit_path_overrides_default_exclude(self):
        """path 明确指向某个默认排除目录（或其子目录）时，该目录不再被排除。"""
        for path, freed in (
            (".venv", ".venv"),
            (".venv/lib", ".venv"),
            ("node_modules/foo", "node_modules"),
            ("build", "build"),
        ):
            self.io.grep_search.reset_mock()
            ret = self.tool.execute({"pattern": "x", "path": path})
            self.assertEqual(
                self.io.grep_search.await_args.kwargs["exclude"], ret["exclude"]
            )
            self.assertNotIn(freed, ret["exclude"])
            # 其余默认排除项仍然生效
            others = [p for p in DEFAULT_EXCLUDE_PATTERNS if p != freed]
            self.assertEqual(ret["exclude"], others)

    def test_max_depth_clamped(self):
        self.tool.execute({"pattern": "x", "max_depth": 999})
        self.assertEqual(
            self.io.grep_search.await_args.kwargs["max_depth"], 100
        )
        self.io.grep_search.reset_mock()
        self.tool.execute({"pattern": "x", "max_depth": -5})
        self.assertEqual(
            self.io.grep_search.await_args.kwargs["max_depth"], 0
        )

    def test_invalid_max_depth_rejected(self):
        ret = self.tool.execute({"pattern": "x", "max_depth": "abc"})
        self.assertIn("error", ret)
        self.io.grep_search.assert_not_awaited()

    def test_invalid_exclude_rejected(self):
        ret = self.tool.execute({"pattern": "x", "exclude": ["node_modules"]})
        self.assertIn("error", ret)
        ret2 = self.tool.execute({"pattern": "x", "exclude": "a" * 300})
        self.assertIn("error", ret2)
        self.io.grep_search.assert_not_awaited()

    def test_huge_exclude_rejected(self):
        ret = self.tool.execute(
            {"pattern": "x", "exclude": ",".join(f"p{i}" for i in range(51))}
        )
        self.assertIn("error", ret)
        self.io.grep_search.assert_not_awaited()

    def test_exclude_with_path_separator_rejected(self):
        """带路径的模式在 grep 命令行文件下会变成路径后缀匹配，三模式不一致，
        故直接拒绝（详见 GrepTool._parse_exclude）。"""
        for bad in ("lib/*.dart", "lib\\*.dart", "node_modules,lib/*.dart"):
            ret = self.tool.execute({"pattern": "x", "exclude": bad})
            self.assertIn("error", ret)
            self.assertIn("basename", ret["error"])
        self.io.grep_search.assert_not_awaited()

    def test_exclude_basename_glob_accepted(self):
        self.tool.execute(
            {"pattern": "x", "exclude": "*.g.dart,build,node_modules"}
        )
        self.assertEqual(
            self.io.grep_search.await_args.kwargs["exclude"],
            ["*.g.dart", "build", "node_modules"]
            + [
                p for p in DEFAULT_EXCLUDE_PATTERNS
                if p not in ("build", "node_modules")
            ],
        )

    def test_no_hits(self):
        self.io.grep_search = AsyncMock(return_value={"exit_code": 1, "stdout": ""})
        ret = self.tool.execute({"pattern": "nope"})
        self.assertEqual(ret["exit_code"], 1)
        self.assertEqual(ret["matches"], [])
        self.assertEqual(ret["count"], 0)

    def test_error_propagated(self):
        self.io.grep_search = AsyncMock(return_value={"error": "搜索失败"})
        ret = self.tool.execute({"pattern": "x"})
        self.assertIn("error", ret)

    def test_max_results_truncates(self):
        self.io.grep_search = AsyncMock(
            return_value={
                "exit_code": 0,
                "stdout": "\n".join(f"f{i}.txt:line{i}" for i in range(1, 11)),
            }
        )
        ret = self.tool.execute({"pattern": "line", "max_results": 3})
        self.assertEqual(ret["count"], 3)
        self.assertEqual(ret["total"], 10)
        self.assertTrue(ret["truncated"])
        self.assertEqual(len(ret["matches"]), 3)

    def test_max_results_clamped_and_defaulted(self):
        self.io.grep_search = AsyncMock(return_value={"exit_code": 0, "stdout": ""})
        ret = self.tool.execute({"pattern": "x", "max_results": 999999})
        self.assertLessEqual(ret["total"], 2000)
        self.io.grep_search = AsyncMock(return_value={"exit_code": 0, "stdout": ""})
        ret2 = self.tool.execute({"pattern": "x", "max_results": "abc"})
        self.assertEqual(ret2["count"], 0)
        self.assertEqual(DEFAULT_MAX_RESULTS, 200)

    def test_blank_stdout_is_clean(self):
        self.io.grep_search = AsyncMock(
            return_value={"exit_code": 0, "stdout": "\n  \nline\n"}
        )
        ret = self.tool.execute({"pattern": "line"})
        self.assertEqual(ret["matches"], ["line"])

    def test_short_lines_untouched(self):
        ret = self.tool.execute({"pattern": "hello"})
        self.assertFalse(ret["line_truncated"])
        self.assertEqual(ret["matches"][0], "lib/a.dart:hello")

    def test_long_line_truncated_to_match_window(self):
        # 模拟 jsonl 超长记录行：命中点在行中部，整行返回会撑爆上下文
        pad = "x" * 5000
        line = f"{pad}list_members{pad}"
        self.io.grep_search = AsyncMock(
            return_value={
                "exit_code": 0,
                "stdout": f"sft_20260825.jsonl:1:{line}",
            }
        )
        ret = self.tool.execute({"pattern": "list_members"})
        self.assertTrue(ret["line_truncated"])
        self.assertEqual(ret["count"], 1)
        out = ret["matches"][0]
        self.assertIn("list_members", out)
        # 截断为「命中点 ± 上下文」窗口：行本身 10000+ 字符，返回仅 2000 上下
        self.assertLessEqual(len(out), DEFAULT_MAX_LINE_CHARS + 2)
        self.assertTrue(out.startswith("…") and out.endswith("…"))
        self.assertGreater(out.index("list_members"), 0)

    def test_long_line_regex_match_position(self):
        pad = "y" * 5000
        line = f"{pad}ERROR: disk full{pad}"
        self.io.grep_search = AsyncMock(
            return_value={"exit_code": 0, "stdout": f"log.txt:3:{line}"}
        )
        ret = self.tool.execute({"pattern": r"ERROR:\s+\w+", "regex": True})
        self.assertTrue(ret["line_truncated"])
        self.assertIn("disk full", ret["matches"][0])

    def test_total_chars_cap(self):
        # 多行超长行叠加，触发总字符上限并停止收集
        pad = "z" * 3000
        lines = "\n".join(f"f{i}.jsonl:{pad}needle{pad}" for i in range(50))
        self.io.grep_search = AsyncMock(return_value={"exit_code": 0, "stdout": lines})
        ret = self.tool.execute({"pattern": "needle"})
        self.assertTrue(ret["truncated"])
        self.assertLess(ret["count"], 50)
        self.assertLessEqual(
            sum(len(m) + 1 for m in ret["matches"]), DEFAULT_MAX_TOTAL_CHARS
        )


if __name__ == "__main__":
    unittest.main()
