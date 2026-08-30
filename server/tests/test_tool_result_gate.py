"""工具结果大小门控单元测试（llm.py:_maybe_redirect_result）。

覆盖：
- 短结果（≤ 阈值）原样返回、不触发写入
- 超长结果 + 写入器 → 返回重定向提示（含文件位置/原因/预览），写入器收到完整原文
- 超长结果、无写入器 → 退化为本地截断（长度有界、含截断标记）
- 写入器抛异常 → 退化为本地截断（不向上抛错）
"""

import unittest

from config.models import ModelConfig
from llm.llm import (
    RESULT_REDIRECT_THRESHOLD,
    _REDIRECT_PREVIEW_CHARS,
    AgentLLMSession,
)


def _make_session(writer=None):
    mc = ModelConfig(
        name="t", base_url="http://localhost:8000",
        api_key="k", model_id="m",
        extra={"max_seqlen": 65536},
    )
    return AgentLLMSession(
        model_config=mc,
        workspace_id="ws",
        system_prompt="",
        result_redirect_writer=writer,
    )


class TestResultGate(unittest.TestCase):
    def test_short_result_unchanged(self):
        writer_calls = []
        session = _make_session(writer=lambda *a: writer_calls.append(a))
        short = "x" * (RESULT_REDIRECT_THRESHOLD - 1)
        out = session._maybe_redirect_result("read", short)
        self.assertEqual(out, short)
        self.assertEqual(writer_calls, [])

    def test_long_result_redirected_with_writer(self):
        captured = []
        session = _make_session(
            writer=lambda rel, content: captured.append((rel, content))
        )
        long_text = "x" * (RESULT_REDIRECT_THRESHOLD + 12345)
        out = session._maybe_redirect_result("read", long_text)

        # 返回的是重定向提示而非原文
        self.assertIn("[工具结果已重定向]", out)
        self.assertIn("read", out)
        self.assertIn(str(RESULT_REDIRECT_THRESHOLD + 12345), out)
        self.assertIn(".self/results/", out)
        self.assertIn(str(RESULT_REDIRECT_THRESHOLD), out)
        self.assertIn("分多次读取", out)
        self.assertIn("terminal", out)
        # 提示很小，绝不接近阈值
        self.assertLess(len(out), RESULT_REDIRECT_THRESHOLD)
        # 预览片段出现
        self.assertIn(long_text[:_REDIRECT_PREVIEW_CHARS], out)

        # 写入器收到完整原文 + .self 相对路径，文件名含工具名
        self.assertEqual(len(captured), 1)
        rel, content = captured[0]
        self.assertEqual(content, long_text)
        self.assertTrue(rel.startswith(".self/results/"))
        self.assertTrue(rel.endswith(".read.result"))
        # 会话级序号递增
        self.assertEqual(session._redirect_seq, 1)

    def test_long_result_no_writer_truncated(self):
        session = _make_session(writer=None)
        long_text = "y" * (RESULT_REDIRECT_THRESHOLD * 3)
        out = session._maybe_redirect_result("terminal", long_text)
        # 长度有界，且带截断标记
        self.assertIn("...[结果过长", out)
        self.assertLessEqual(
            len(out), RESULT_REDIRECT_THRESHOLD + 80
        )
        # 原文前段保留
        self.assertTrue(out.startswith(long_text[:100]))

    def test_writer_raises_falls_back_to_truncation(self):
        def _boom(rel, content):
            raise RuntimeError("write failed")

        session = _make_session(writer=_boom)
        long_text = "z" * (RESULT_REDIRECT_THRESHOLD + 999)
        out = session._maybe_redirect_result("grep", long_text)
        # 不抛错，退化为截断
        self.assertIn("...[结果过长", out)
        self.assertLessEqual(len(out), RESULT_REDIRECT_THRESHOLD + 80)


if __name__ == "__main__":
    unittest.main()
