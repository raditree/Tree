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
    """thinking 模式不通过 OpenAI 顶层参数透传，而经 extra_body 下发。"""

    def test_thinking_not_passed_as_top_level(self):
        """回归：thinking 作为顶层参数会被 OpenAI SDK 抛 TypeError，
        推理由 extra_body.thinking 开启，顶层不得出现 thinking。"""
        mc = ModelConfig(
            name="t", base_url="http://localhost:8000", api_key="k",
            model_id="m", thinking=True,
            extra={
                "max_seqlen": 65536,
                "extra_body": {"thinking": {"type": "enabled"}},
            },
        )
        session = AgentLLMSession(
            model_config=mc, workspace_id="ws", system_prompt=""
        )
        kwargs = session._build_api_kwargs()
        self.assertNotIn("thinking", kwargs)
        self.assertEqual(
            {"type": "enabled"}, kwargs.get("extra_body", {}).get("thinking")
        )

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


class TestContextCompress(unittest.TestCase):
    """上下文压缩：保留用户输入、压缩 tool 轨迹，用户消息不足时不得越界。

    回归：历史上当用户消息条数 < KEEP_RECENT_USER_MSGS(3) 时，
    ``user_indices[-3]`` 触发 ``IndexError: list index out of range``，
    导致 chat 消费线程异常。
    """

    def test_compress_few_user_msgs_no_index_error(self):
        session = AgentLLMSession(
            model_config=ModelConfig(
                name="t", base_url="http://localhost:8000",
                api_key="k", model_id="m",
                extra={"max_seqlen": 4096},
            ),
            workspace_id="ws", system_prompt="sys",
        )
        # 仅 2 条用户消息（< 3），多条助手/工具消息
        session.context = [
            {"role": "system", "content": "sys"},
            {"role": "user", "content": "任务一"},
            {"role": "assistant", "content": "回复一"},
            {"role": "user", "content": "任务二"},
            {"role": "assistant", "content": "回复二"},
        ]
        # force=True 跳过阈值，直接进入压缩逻辑；不得抛 IndexError
        with patch.object(session, "_summarize_with_llm", return_value="摘要"):
            result = session.compress(force=True)
        # 新策略：保留两条用户输入 + 尾部（回复二），中间的回复一进总结 → True
        self.assertTrue(result)
        # 重组后：system + summary + 用户输入 + 尾部
        roles = [m["role"] for m in session.context]
        self.assertEqual(roles, ["system", "system", "user", "user", "assistant"])
        # 用户输入原文完整保留
        contents = [m["content"] for m in session.context if m["role"] == "user"]
        self.assertEqual(contents, ["任务一", "任务二"])

    def test_compress_single_turn_many_tool_calls(self):
        """单轮任务大量 tool 调用：应压缩中间 tool 轨迹，仅保留用户输入与尾部。"""
        session = AgentLLMSession(
            model_config=ModelConfig(
                name="t", base_url="http://localhost:8000",
                api_key="k", model_id="m",
                extra={"max_seqlen": 4096},
            ),
            workspace_id="ws", system_prompt="sys",
        )
        ctx = [{"role": "system", "content": "sys"},
               {"role": "user", "content": "任务指令"}]
        for i in range(20):
            ctx.append({"role": "assistant",
                        "tool_calls": [{"id": f"t{i}", "type": "function",
                                        "function": {"name": "f", "arguments": "{}"}}],
                        "content": ""})
            ctx.append({"role": "tool", "tool_call_id": f"t{i}",
                        "content": f"结果{i}"})
        ctx.append({"role": "assistant", "content": "完成"})
        session.context = ctx
        with patch.object(session, "_summarize_with_llm", return_value="摘要"):
            result = session.compress(force=True)
        self.assertTrue(result)
        # 用户输入原文保留
        contents = [m["content"] for m in session.context if m["role"] == "user"]
        self.assertEqual(contents, ["任务指令"])
        # 大部分 tool 轨迹被总结压缩，只保留尾部少量
        tool_cnt = len([m for m in session.context if m["role"] == "tool"])
        self.assertLess(tool_cnt, 20)
        self.assertGreater(tool_cnt, 0)
        # 重组后上下文必须以 system(system+summary) 开头，且工具序列合法
        self.assertEqual(session.context[0]["role"], "system")
        self.assertEqual(session.context[1]["role"], "system")
        # 尾部 assistant(tool_calls) 均有对应 tool 响应（无孤立的 tool 消息）
        have = {m.get("tool_call_id") for m in session.context
                if m.get("role") == "tool"}
        for msg in session.context:
            if msg.get("role") == "assistant" and msg.get("tool_calls"):
                for tc in msg["tool_calls"]:
                    self.assertIn(tc.get("id"), have)


if __name__ == "__main__":
    unittest.main()