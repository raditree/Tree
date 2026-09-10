# -*- coding: utf-8 -*-
"""工具结果"返回时间"注入回归测试（缺陷：工具结果无时间，模型无法判断产出时效）。

覆盖 ``AgentLLMSession.chat`` 工具循环：
- yield 的 tool_call 事件带 ``timestamp``（YYYY-MM-DD HH:MM:SS）
- 写入上下文的 tool 消息末尾追加「结果返回时间：…（服务器本地时间）」
- 未找到工具 / handler 抛错等异常路径同样带时间脚注
- AskUserQuestion 暂停占位结果同样带时间脚注

stub LLM 流式响应，不发起真实网络请求。
"""

import re
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from config.models import ModelConfig  # noqa: E402
from llm.llm import AgentLLMSession  # noqa: E402

DT_RE = re.compile(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}")


def _make_chunk(delta, finish_reason="stop"):
    choice = MagicMock()
    choice.delta = delta
    choice.finish_reason = finish_reason
    chunk = MagicMock()
    chunk.usage = None
    chunk.choices = [choice]
    return chunk


def _make_delta(content=None, tool_calls=None):
    delta = MagicMock()
    delta.content = content
    delta.reasoning_content = None
    delta.reasoning = None
    delta.tool_calls = tool_calls
    return delta


def _make_tool_call(call_id, name, arguments):
    tc = MagicMock()
    tc.index = 0
    tc.id = call_id
    tc.function = MagicMock()
    tc.function.name = name
    tc.function.arguments = arguments
    return tc


def _session():
    mc = ModelConfig(
        name="t", base_url="http://localhost:8000", api_key="k",
        model_id="m", extra={"max_seqlen": 65536},
    )
    return AgentLLMSession(model_config=mc, workspace_id="ws", system_prompt="")


def _run_tool_turn(tool_name, handler=None, arguments='{"x": 1}'):
    """跑一轮 tool_call + 一轮收尾文本，返回 (items, context)。"""
    session = _session()
    if handler is not None:
        session.register_tool(tool_name, "d", {"type": "object"}, handler)
    client = MagicMock()
    client.chat.completions.create.side_effect = [
        [_make_chunk(
            _make_delta(tool_calls=[
                _make_tool_call("call_1", tool_name, arguments)
            ]),
            finish_reason="tool_calls",
        )],
        [_make_chunk(_make_delta(content="完成"))],
    ]
    with patch("llm.llm.LLMClientFactory.create_client", return_value=client):
        items = list(session.chat("执行"))
    return items, session.context


class TestToolResultTimestamp(unittest.TestCase):
    def test_yield_event_has_timestamp(self):
        items, _ = _run_tool_turn("terminal", handler=lambda **kw: "已执行")
        tool_items = [i for i in items if i.get("type") == "tool_call"]
        self.assertEqual(len(tool_items), 1)
        self.assertRegex(
            tool_items[0]["timestamp"],
            r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$",
        )

    def test_context_tool_message_has_time_footer(self):
        _, context = _run_tool_turn("terminal", handler=lambda **kw: "已执行")
        tool_msgs = [m for m in context if m.get("role") == "tool"]
        self.assertEqual(len(tool_msgs), 1)
        content = tool_msgs[0]["content"]
        self.assertIn("结果返回时间：", content)
        self.assertIn("（服务器本地时间）", content)
        self.assertTrue(DT_RE.search(content))

    def test_unknown_tool_still_gets_time(self):
        """未找到工具（handler 缺失）同样注入时间。"""
        _, context = _run_tool_turn("不存在的工具", handler=None)
        tool_msgs = [m for m in context if m.get("role") == "tool"]
        self.assertIn("未找到工具", tool_msgs[0]["content"])
        self.assertIn("结果返回时间：", tool_msgs[0]["content"])

    def test_handler_error_still_gets_time(self):
        """handler 抛错路径同样注入时间。"""
        def _boom(**kw):
            raise RuntimeError("boom")

        _, context = _run_tool_turn("terminal", handler=_boom)
        tool_msgs = [m for m in context if m.get("role") == "tool"]
        self.assertIn("工具执行出错", tool_msgs[0]["content"])
        self.assertIn("结果返回时间：", tool_msgs[0]["content"])


class TestAskPausedFooter(unittest.TestCase):
    def test_ask_paused_placeholder_has_time(self):
        from llm.llm import _ASK_PAUSED_KEY, _AskPaused

        session = _session()
        session.register_tool(
            "ask", "d", {"type": "object"},
            lambda **kw: {_ASK_PAUSED_KEY: True, "qid": "q1"},
        )
        client = MagicMock()
        client.chat.completions.create.side_effect = [
            [_make_chunk(
                _make_delta(tool_calls=[
                    _make_tool_call("call_1", "ask", "{}")
                ]),
                finish_reason="tool_calls",
            )],
        ]
        with patch("llm.llm.LLMClientFactory.create_client", return_value=client):
            with self.assertRaises(_AskPaused):
                list(session.chat("问用户"))
        tool_msgs = [m for m in session.context if m.get("role") == "tool"]
        self.assertIn("等待用户回答", tool_msgs[0]["content"])
        self.assertIn("结果返回时间：", tool_msgs[0]["content"])
        self.assertTrue(DT_RE.search(tool_msgs[0]["content"]))


if __name__ == "__main__":
    unittest.main()
