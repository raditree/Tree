# -*- coding: utf-8 -*-
"""提示词多版本选择层单元测试。

覆盖：
- ``prompt.versions`` 激活版本解析（默认 v1.0.0，与 app.yaml 一致）。
- 章节头/尾数量与 id；压缩器；工具描述。
- 未登记版本 fail-fast（raise），不做静默回退。
"""

import unittest

from prompt import versions
from prompt.loader import VersionMissingError


class TestActiveVersion(unittest.TestCase):
    """激活版本应来自 app.yaml 的 prompt.version（默认 v1.0.0）。"""

    def test_active_version_is_default(self):
        self.assertEqual(versions.active_version(), "1.0.0")

    def test_active_chapters_counts(self):
        head = versions.active_system_head()
        tail = versions.active_system_tail()
        self.assertEqual(len(head), 4)
        self.assertEqual(len(tail), 3)
        # 头尾 id 与 meta.yaml 声明一致
        self.assertEqual([c.id for c in head], [
            "authority", "task-paradigm", "security-boundary", "tool-routing",
        ])
        self.assertEqual([c.id for c in tail], [
            "spec-maintenance", "todo-discipline", "warning-accountability",
        ])


class TestActiveReturnedContent(unittest.TestCase):
    """激活解析器返回的内容应来自数据目录（非空、含关键字段）。"""

    def test_system_head_content_present(self):
        text = "".join(c.content for c in versions.active_system_head())
        self.assertIn("权威边界", text)        # authority
        self.assertIn("easy-task", text)        # task-paradigm
        self.assertIn("命令护栏", text)         # security-boundary
        self.assertIn("上下文获取", text)       # tool-routing

    def test_compressor_injects_raw(self):
        out = versions.active_compressor("历史片段XYZ")
        self.assertIn("上下文压缩器", out)
        self.assertIn("历史对话", out)
        self.assertIn("历史片段XYZ", out)

    def test_tool_description_struct(self):
        desc = versions.active_tool_description("read")
        self.assertIn("何时使用", desc)
        self.assertIn("贡献维度", desc)

    def test_mcp_tool_description(self):
        desc = versions.active_tool_description("read_pdf")
        self.assertIn("何时使用", desc)

    def test_unknown_tool_raises(self):
        with self.assertRaises(KeyError):
            versions.active_tool_description("no_such_tool")


class TestMissingVersion(unittest.TestCase):
    """未登记版本应 fail-fast（raise），不做静默回退。"""

    def test_unregistered_version_raises(self):
        with self.assertRaises(VersionMissingError):
            versions.get_version("9.9.9")


if __name__ == "__main__":
    unittest.main()