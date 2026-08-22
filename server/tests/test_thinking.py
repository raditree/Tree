# -*- coding: utf-8 -*-
"""thinking 解析测试（P5 Thinking 解析与展示）。

覆盖 spec「Thinking 解析与展示」：
1. ModelConfig.from_dict 解析顶层 ``thinking`` 布尔字段（默认 false）
2. 启用 thinking 时流式 chunk 携带 ``reasoning_content`` 产 ``thinking`` 段
3. 兼容 ``reasoning`` 字段
4. thinking 内容回写进 assistant 消息的 ``reasoning_content`` 字段（供下一轮
   回传网关，避免 400）
5. 未启用 thinking 时不产出 thinking 段
6. thinking 模式在 API kwargs 顶层透传 ``thinking=True``
"""

import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# 将 server 目录添加到 Python 路径，使模块可导入
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from config.models import ModelConfig  # noqa: E402
from llm.llm import AgentLLMSession  # noqa: E402


def make_choice(delta, finish_reason="stop"):
    choice = MagicMock()
    choice.delta = delta
    choice.finish_reason = finish_reason
    return choice


def make_chunk(delta=None, finish_reason="stop"):
    chunk = MagicMock()
    chunk.usage = None
    chunk.choices = [make_choice(delta, finish_reason)]
    return chunk


def make_delta(content=None, reasoning_content=None, reasoning=None,
               tool_calls=None):
    delta = MagicMock()
    delta.content = content
    delta.reasoning_content = reasoning_content
    delta.reasoning = reasoning
    delta.tool_calls = tool_calls
    return delta


class TestModelConfigThinking(unittest.TestCase):
    """ModelConfig 解析顶层 thinking 字段。"""

    def test_thinking_true(self):
        cfg = ModelConfig.from_dict(
            {"name": "t", "base_url": "u", "api_key": "k",
             "model_id": "m", "thinking": True}
        )
        self.assertTrue(cfg.thinking)

    def test_thinking_false_default(self):
        cfg = ModelConfig.from_dict(
            {"name": "t", "base_url": "u", "api_key": "k", "model_id": "m"}
        )
        self.assertFalse(cfg.thinking)

    def test_to_dict_includes_thinking(self):
        cfg = ModelConfig.from_dict(
            {"name": "t", "base_url": "u", "api_key": "k",
             "model_id": "m", "thinking": True}
        )
        self.assertTrue(cfg.to_dict()["thinking"])


class TestThinkingStreaming(unittest.TestCase):
    """流式 reasoning_content 解析与回写。"""

    def _session(self, thinking=False):
        mc = ModelConfig(
            name="t", base_url="http://localhost:8000",
            api_key="k", model_id="m", thinking=thinking,
            extra={"max_seqlen": 65536},
        )
        return AgentLLMSession(
            model_config=mc, workspace_id="ws", system_prompt=""
        )

    def test_thinking_enabled_yields_thinking_segments(self):
        """启用 thinking 时产出 thinking 段。"""
        session = self._session(thinking=True)
        mock_client = MagicMock()
        mock_client.chat.completions.create.return_value = [
            make_chunk(make_delta(reasoning_content="第一步")),
            make_chunk(make_delta(reasoning_content=" 思考")),
            make_chunk(make_delta(content="你好")),
        ]
        with patch("llm.llm.LLMClientFactory.create_client",
                   return_value=mock_client):
            items = list(session.chat("hi"))
        thoughts = [i for i in items if i.get("type") == "thinking"]
        self.assertEqual(
            ["第一步", " 思考"],
            [t["content"] for t in thoughts],
        )

    def test_thinking_compat_reasoning_field(self):
        """兼容部分端点使用 reasoning 字段。"""
        session = self._session(thinking=True)
        mock_client = MagicMock()
        mock_client.chat.completions.create.return_value = [
            make_chunk(make_delta(reasoning="分析…")),
            make_chunk(make_delta(content="答案")),
        ]
        with patch("llm.llm.LLMClientFactory.create_client",
                   return_value=mock_client):
            items = list(session.chat("hi"))
        thoughts = [i for i in items if i.get("type") == "thinking"]
        self.assertEqual(["分析…"], [t["content"] for t in thoughts])

    def test_thinking_disabled_no_thinking_segments(self):
        """未启用 thinking 时不产出 thinking 段。"""
        session = self._session(thinking=False)
        mock_client = MagicMock()
        mock_client.chat.completions.create.return_value = [
            make_chunk(make_delta(reasoning_content="隐藏推理")),
            make_chunk(make_delta(content="答案")),
        ]
        with patch("llm.llm.LLMClientFactory.create_client",
                   return_value=mock_client):
            items = list(session.chat("hi"))
        thoughts = [i for i in items if i.get("type") == "thinking"]
        self.assertEqual([], thoughts)

    def test_thinking_backwritten_final_message(self):
        """无 tool_call 时，最终 assistant 消息回写 reasoning_content。"""
        session = self._session(thinking=True)
        mock_client = MagicMock()
        mock_client.chat.completions.create.return_value = [
            make_chunk(make_delta(reasoning_content="推理一")),
            make_chunk(make_delta(content="答案")),
        ]
        with patch("llm.llm.LLMClientFactory.create_client",
                   return_value=mock_client):
            list(session.chat("hi"))
        assistant_msgs = [
            m for m in session.context
            if m.get("role") == "assistant" and m.get("content")
        ]
        self.assertEqual(1, len(assistant_msgs))
        self.assertEqual("推理一", assistant_msgs[0].get("reasoning_content"))

    def test_thinking_backwritten_toolcall_message(self):
        """tool_call 分支的 assistant 消息也回写 reasoning_content。"""
        session = self._session(thinking=True)

        def make_tool_choice(delta):
            choice = MagicMock()
            choice.delta = delta
            choice.finish_reason = "tool_calls"
            return choice

        tool_call_delta = make_delta(tool_calls=[MagicMock(index=0, id="call_1")])
        tool_call_delta.tool_calls[0].function = MagicMock(
            name="read", arguments='{"path": "/a"}'
        )
        tc_chunk = MagicMock()
        tc_chunk.usage = None
        tc_chunk.choices = [make_tool_choice(tool_call_delta)]

        # 第一轮：thinking + tool_call；第二轮：返回最终文本
        mock_client = MagicMock()
        mock_client.chat.completions.create.side_effect = [
            [
                make_chunk(make_delta(reasoning_content="先读取"),
                           finish_reason="tool_calls"),
                tc_chunk,
            ],
            [make_chunk(make_delta(content="已读取"))],
        ]

        # 注册一个空 read handler 避免真实 IO
        session.register_tool(
            name="read",
            description="读取文件",
            parameters={"type": "object", "properties": {}},
            handler=lambda **kwargs: {"content": "文件内容"},
        )
        with patch("llm.llm.LLMClientFactory.create_client",
                   return_value=mock_client):
            list(session.chat("hi"))

        # 找到带 tool_calls 的 assistant 消息，验证回写
        tool_assistant = [
            m for m in session.context
            if m.get("role") == "assistant" and m.get("tool_calls")
        ]
        self.assertEqual(1, len(tool_assistant))
        self.assertEqual("先读取", tool_assistant[0].get("reasoning_content"))


class TestThinkingApiKwargs(unittest.TestCase):
    """thinking 模式下 API 顶层透传 thinking=True。"""

    def test_thinking_in_api_kwargs(self):
        mc = ModelConfig(
            name="t", base_url="http://localhost:8000", api_key="k",
            model_id="m", thinking=True,
            extra={"max_seqlen": 65536},
        )
        session = AgentLLMSession(
            model_config=mc, workspace_id="ws", system_prompt=""
        )
        kwargs = session._build_api_kwargs()
        self.assertTrue(kwargs.get("thinking"))

    def test_no_thinking_when_disabled(self):
        mc = ModelConfig(
            name="t", base_url="http://localhost:8000", api_key="k",
            model_id="m", thinking=False,
            extra={"max_seqlen": 65536},
        )
        session = AgentLLMSession(
            model_config=mc, workspace_id="ws", system_prompt=""
        )
        kwargs = session._build_api_kwargs()
        self.assertNotIn("thinking", kwargs)

    def test_metadata_fields_not_passed_to_api(self):
        """配置元数据字段（is_limitless_context / 价格）不透传给 OpenAI API。

        回归：历史上 ``is_limitless_context`` 被当作 OpenAI 顶层参数透传，
        导致 ``Completions.create() got an unexpected keyword argument``，
        agent 发消息无回应。
        """
        mc = ModelConfig(
            name="t", base_url="http://localhost:8000", api_key="k",
            model_id="m", thinking=False,
            extra={
                "max_seqlen": 204800,
                "is_limitless_context": False,
                "input_price": 0.14,
                "output_price": 0.28,
                "cached_input_price": 0.028,
            },
        )
        session = AgentLLMSession(
            model_config=mc, workspace_id="ws", system_prompt=""
        )
        kwargs = session._build_api_kwargs()
        for field in (
            "is_limitless_context",
            "input_price",
            "output_price",
            "cached_input_price",
        ):
            self.assertNotIn(field, kwargs, f"{field} 不应透传给 API")
        # 保留字段仍正常透传
        self.assertEqual(kwargs["model"], "m")


if __name__ == "__main__":
    unittest.main()