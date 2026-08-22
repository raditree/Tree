# -*- coding: utf-8 -*-
"""usage 解析兼容性单元测试。

覆盖三种缓存字段口径：
1. OpenAI 协议: usage.prompt_tokens_details.cached_tokens
2. DeepSeek 官方: 顶层 usage.prompt_cache_hit_tokens / prompt_cache_miss_tokens
3. 兼容网关: 顶层 usage.cached_tokens

同时验证：
- 无缓存字段时正确回退（cached_tokens=0）
- 防御性钳制（缓存 > 输入时截断）
- 重复 usage chunk 只记账一次
"""

import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# 将 server 目录添加到 Python 路径，使 core 模块可导入
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from llm.llm import AgentLLMSession, extract_usage_counts  # noqa: E402
from config.models import ModelConfig  # noqa: E402


class _Usage:
    """简单用法对象，模拟 OpenAI SDK 的 usage 结构。"""

    def __init__(self, **kwargs):
        self.prompt_tokens = kwargs.get("prompt_tokens", 0)
        self.completion_tokens = kwargs.get("completion_tokens", 0)
        self.total_tokens = kwargs.get("total_tokens", 0)
        self.prompt_tokens_details = kwargs.get("prompt_tokens_details")
        self.prompt_cache_hit_tokens = kwargs.get("prompt_cache_hit_tokens")
        self.prompt_cache_miss_tokens = kwargs.get("prompt_cache_miss_tokens")
        self.cached_tokens = kwargs.get("cached_tokens")


class TestExtractUsageCounts(unittest.TestCase):
    """extract_usage_counts 覆盖多格式缓存字段的解析。"""

    def test_openai_protocol_cached_tokens(self):
        """OpenAI 协议：prompt_tokens_details.cached_tokens。"""
        details = MagicMock()
        details.cached_tokens = 100
        usage = _Usage(
            prompt_tokens=300,
            completion_tokens=50,
            prompt_tokens_details=details,
        )
        counts = extract_usage_counts(usage)
        self.assertEqual(counts["prompt_tokens"], 300)
        self.assertEqual(counts["completion_tokens"], 50)
        self.assertEqual(counts["cached_tokens"], 100)

    def test_deepseek_prompt_cache_hit_tokens(self):
        """DeepSeek 官方：顶层 prompt_cache_hit_tokens。"""
        usage = _Usage(
            prompt_tokens=400,
            completion_tokens=20,
            prompt_cache_hit_tokens=350,
            prompt_cache_miss_tokens=50,
        )
        counts = extract_usage_counts(usage)
        self.assertEqual(counts["cached_tokens"], 350)

    def test_deepseek_prompt_cache_miss_tokens_fallback(self):
        """DeepSeek 官方：仅提供 miss tokens 时由输入差额推导。"""
        usage = _Usage(
            prompt_tokens=400,
            completion_tokens=20,
            prompt_cache_hit_tokens=0,
            prompt_cache_miss_tokens=50,
        )
        counts = extract_usage_counts(usage)
        self.assertEqual(counts["cached_tokens"], 350)

    def test_gateway_top_level_cached_tokens(self):
        """兼容网关：顶层 cached_tokens 字段。"""
        usage = _Usage(
            prompt_tokens=500,
            completion_tokens=10,
            cached_tokens=480,
        )
        counts = extract_usage_counts(usage)
        self.assertEqual(counts["cached_tokens"], 480)

    def test_no_cache_fields_returns_zero(self):
        """无任何缓存字段时回退为 0（不做假命中）。"""
        usage = _Usage(prompt_tokens=200, completion_tokens=30)
        counts = extract_usage_counts(usage)
        self.assertEqual(counts["cached_tokens"], 0)

    def test_cache_clamped_to_prompt(self):
        """防御：缓存命中不超过输入 token。"""
        usage = _Usage(
            prompt_tokens=100,
            completion_tokens=10,
            prompt_cache_hit_tokens=150,
        )
        counts = extract_usage_counts(usage)
        self.assertEqual(counts["cached_tokens"], 100)

    def test_openai_takes_priority(self):
        """OpenAI 协议字段优先于 DeepSeek 顶层字段。"""
        details = _Usage()
        details.cached_tokens = 80
        usage = _Usage(
            prompt_tokens=200,
            completion_tokens=10,
            prompt_tokens_details=details,
            prompt_cache_hit_tokens=120,
        )
        counts = extract_usage_counts(usage)
        self.assertEqual(counts["cached_tokens"], 80)


class TestUsageRecordOnce(unittest.TestCase):
    """验证流式响应中重复 usage chunk 只记账一次（写入 last_usage）。"""

    def setUp(self):
        self.model_config = ModelConfig(
            name="test-model",
            base_url="http://localhost:8000",
            api_key="test-api-key",
            model_id="test-model-id",
            extra={"max_seqlen": 204800},
        )
        self.session = AgentLLMSession(
            model_config=self.model_config,
            workspace_id="test-ws",
            system_prompt="",
        )

    def test_duplicate_usage_chunks_recorded_once(self):
        """同一响应中重复的 usage chunk 只记录一次。"""
        # 模拟流式响应：文本 chunk + 两个重复 usage chunk
        def make_usage_chunk(prompt, completion, cached=0):
            chunk = MagicMock()
            u = _Usage(
                prompt_tokens=prompt,
                completion_tokens=completion,
                total_tokens=prompt + completion,
                cached_tokens=cached,
            )
            chunk.usage = u
            chunk.choices = []
            return chunk

        def make_text_chunk(content):
            chunk = MagicMock()
            chunk.usage = None
            choice = MagicMock()
            choice.delta.content = content
            choice.delta.tool_calls = None
            choice.finish_reason = "stop"
            chunk.choices = [choice]
            return chunk

        mock_client = MagicMock()
        mock_client.chat.completions.create.return_value = [
            make_text_chunk("hello"),
            make_usage_chunk(100, 20, cached=80),
            make_usage_chunk(100, 20, cached=80),  # 重复的 usage chunk
            make_text_chunk(" world"),
        ]

        with patch(
            "llm.llm.LLMClientFactory.create_client",
            return_value=mock_client,
        ):
            list(self.session.chat("hi"))

        # last_usage 只记录一次：输入 100，输出 20，缓存 80
        snap = self.session.last_usage
        self.assertIsNotNone(snap)
        self.assertEqual(snap["prompt_tokens"], 100)
        self.assertEqual(snap["completion_tokens"], 20)
        self.assertEqual(snap["cached_tokens"], 80)


if __name__ == "__main__":
    unittest.main()
