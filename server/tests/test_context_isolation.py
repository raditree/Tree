# -*- coding: utf-8 -*-
"""Agent 上下文隔离（ContextIsolator）单元测试。

覆盖 SubTask 14.5 已落地实现：
- 子 agent 工作成果摘要（工具调用统计、Git 提交、结果截断）
- 成员状态报告（当前任务 + 最近提交，最多 3 条）
- 父 agent 上下文过滤（移除 tool 消息、剥离 tool_calls）
- 父上下文注入条目构建
"""

import sys
import unittest
from pathlib import Path

# 将 server 目录添加到 Python 路径，使模块可导入
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from agent.context_isolation import ContextIsolator  # noqa: E402


class TestCreateWorkSummary(unittest.TestCase):
    """子 agent 工作成果摘要。"""

    def setUp(self):
        self.iso = ContextIsolator()

    def test_summary_with_tools_and_commit(self):
        tool_calls = [
            {"name": "read", "id": "1"},
            {"name": "read", "id": "2"},
            {"name": "write", "id": "3"},
        ]
        git = {"hash": "abc123", "message": "feat: 完成改造"}
        summary = self.iso.create_work_summary(
            "修复会话隔离", tool_calls, git, "全部测试通过"
        )
        self.assertIn("任务描述: 修复会话隔离", summary)
        self.assertIn("使用了 3 次工具调用", summary)
        self.assertIn("read(2), write(1)", summary)
        self.assertIn("Git 提交: abc123 feat: 完成改造", summary)
        self.assertIn("工作结果摘要:", summary)
        self.assertIn("全部测试通过", summary)

    def test_no_tools(self):
        summary = self.iso.create_work_summary("t", [], {}, "r")
        self.assertIn("工具调用: 使用了 0 次工具调用: 无", summary)
        self.assertIn("Git 提交: (无提交)", summary)

    def test_truncate_long_result(self):
        result = "x" * 600
        summary = self.iso.create_work_summary("t", [], {}, result)
        # 截断到 RESULT_SUMMARY_MAX_CHARS + 省略号
        self.assertIn("..." , summary)
        # 结果段截断后长度 ≤ 500 + 省略号
        idx = summary.index("工作结果摘要:") + len("工作结果摘要:\n")
        rest = summary[idx:]
        self.assertLessEqual(len(rest), ContextIsolator.RESULT_SUMMARY_MAX_CHARS + 3)

    def test_empty_inputs(self):
        summary = self.iso.create_work_summary("", [], {}, "")
        self.assertIn("(无)", summary)


class TestCreateStatusReport(unittest.TestCase):
    """成员状态报告。"""

    def setUp(self):
        self.iso = ContextIsolator()

    def test_with_task_and_commits(self):
        task = {"description": "开发功能", "status": "in_progress"}
        git_log = [
            {"hash": "a1", "message": "c1"},
            {"hash": "a2", "message": "c2"},
            {"hash": "a3", "message": "c3"},
            {"hash": "a4", "message": "c4"},
        ]
        report = self.iso.create_status_report("m1", task, git_log)
        self.assertIn("成员 ID: m1", report)
        self.assertIn("当前任务: 开发功能 [in_progress]", report)
        # 只保留最近 3 条提交
        self.assertIn("a1 c1", report)
        self.assertIn("a3 c3", report)
        self.assertNotIn("a4", report)

    def test_no_task_no_commits(self):
        report = self.iso.create_status_report("m1", {}, [])
        self.assertIn("当前任务: (无)", report)
        self.assertIn("- (无)", report)


class TestFilterContextForParent(unittest.TestCase):
    """父 agent 上下文过滤。"""

    def setUp(self):
        self.iso = ContextIsolator()

    def test_removes_tool_messages(self):
        ctx = [
            {"role": "system", "content": "sys"},
            {"role": "assistant", "content": "plan",
             "tool_calls": [{"name": "read"}]},
            {"role": "tool", "content": "文件内容", "tool_call_id": "1"},
            {"role": "user", "content": "继续"},
        ]
        out = self.iso.filter_context_for_parent(ctx)
        roles = [m["role"] for m in out]
        self.assertNotIn("tool", roles)
        self.assertEqual(roles, ["system", "assistant", "user"])

    def test_strips_tool_calls_from_assistant(self):
        ctx = [
            {"role": "assistant", "content": "text",
             "tool_calls": [{"name": "read"}]},
        ]
        out = self.iso.filter_context_for_parent(ctx)
        self.assertNotIn("tool_calls", out[0])
        self.assertEqual(out[0]["content"], "text")

    def test_keeps_plain_text(self):
        ctx = [{"role": "user", "content": "普通文本"}]
        out = self.iso.filter_context_for_parent(ctx)
        self.assertEqual(out, ctx)

    def test_non_dict_skipped(self):
        out = self.iso.filter_context_for_parent(["not-a-dict", None, 42])
        self.assertEqual(out, [])


class TestBuildParentContextEntry(unittest.TestCase):
    def test_format(self):
        entry = ContextIsolator.build_parent_context_entry("m1", "摘要内容")
        self.assertEqual(entry["role"], "user")
        self.assertIn("[成员 m1 工作成果摘要]", entry["content"])
        self.assertIn("摘要内容", entry["content"])


class TestFormatGitCommit(unittest.TestCase):
    """Git 提交信息格式化辅助。"""

    def test_dict_hash_message(self):
        self.assertEqual(
            ContextIsolator._format_git_commit({"hash": "abc", "message": "m"}),
            "abc m",
        )

    def test_dict_alt_keys(self):
        self.assertEqual(
            ContextIsolator._format_git_commit(
                {"commit_hash": "def", "subject": "s"}
            ),
            "def s",
        )

    def test_empty_dict(self):
        self.assertEqual(ContextIsolator._format_git_commit({}), "(无提交)")

    def test_none(self):
        self.assertEqual(ContextIsolator._format_git_commit(None), "(无提交)")

    def test_string(self):
        self.assertEqual(
            ContextIsolator._format_git_commit("abc m"), "abc m"
        )


class TestCountToolTypes(unittest.TestCase):
    def test_counts_and_formats(self):
        calls = [{"name": "read"}, {"name": "read"}, {"name": "write"}]
        self.assertEqual(
            ContextIsolator._count_tool_types(calls), "read(2), write(1)"
        )

    def test_empty(self):
        self.assertEqual(ContextIsolator._count_tool_types([]), "无")


class TestFormatRecentCommits(unittest.TestCase):
    def test_strings(self):
        out = ContextIsolator._format_recent_commits(
            ["c1", "c2", "c3", "c4"], limit=3
        )
        self.assertEqual(out, ["c1", "c2", "c3"])

    def test_dicts(self):
        out = ContextIsolator._format_recent_commits(
            [{"hash": "a", "message": "m"}]
        )
        self.assertEqual(out, ["a m"])

    def test_empty(self):
        self.assertEqual(ContextIsolator._format_recent_commits([]), [])


if __name__ == "__main__":
    unittest.main()
