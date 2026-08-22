# -*- coding: utf-8 -*-
"""LLM 视觉消息与停止中止（cancel）单元测试。

覆盖 plan 第 2b 项（停止按钮中止 tool loop）与第 7 项（read_tool 图像输入，
LLM 层 vision 消息转换）已落地实现：
1. ``AgentLLMSession._is_cancelled``：取消事件检查（会话级 / 显式参数）
2. ``_convert_vision_messages``：含图 user 消息转 OpenAI vision content 数组
3. ``_tool_context_content``：图像工具结果文本化（非视觉模型降级提示）
4. ``_append_image_user_msg``：图像结果追加携带图像的 user 消息（仅视觉模型）
"""

import sys
import threading
import unittest
from pathlib import Path

# 将 server 目录添加到 Python 路径，使模块可导入
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from config.models import ModelConfig  # noqa: E402
from llm.llm import AgentLLMSession  # noqa: E402


def make_session(if_vision: bool = False, cancel_event=None):
    cfg = ModelConfig(
        name="test-model",
        base_url="http://localhost",
        api_key="k",
        model_id="m",
        if_vision=if_vision,
    )
    return AgentLLMSession(
        model_config=cfg,
        workspace_id="ws",
        system_prompt="",
        cancel_event=cancel_event,
    )


class TestIsCancelled(unittest.TestCase):
    """停止中止：取消事件检查。"""

    def test_no_event_false(self):
        s = make_session()
        self.assertFalse(s._is_cancelled())

    def test_event_not_set_false(self):
        evt = threading.Event()
        s = make_session(cancel_event=evt)
        self.assertFalse(s._is_cancelled())

    def test_event_set_true(self):
        evt = threading.Event()
        s = make_session(cancel_event=evt)
        evt.set()
        self.assertTrue(s._is_cancelled())

    def test_explicit_param_preferred(self):
        """显式传入的 cancel_event 优先于会话级。"""
        session_evt = threading.Event()
        explicit_evt = threading.Event()
        s = make_session(cancel_event=session_evt)
        explicit_evt.set()
        # 显式事件已置位 → 判定已取消（即使会话级未置位）
        self.assertTrue(s._is_cancelled(explicit_evt))
        # 显式事件未置位 → 判定未取消（即使会话级已置位）
        session_evt.set()
        self.assertFalse(s._is_cancelled(threading.Event()))

    def test_none_param_falls_back_to_session(self):
        session_evt = threading.Event()
        s = make_session(cancel_event=session_evt)
        self.assertFalse(s._is_cancelled(None))
        session_evt.set()
        self.assertTrue(s._is_cancelled(None))


class TestConvertVisionMessages(unittest.TestCase):
    """视觉消息格式转换（OpenAI vision content 数组）。"""

    def setUp(self):
        self.s = make_session(if_vision=True)

    def test_image_user_msg_converted(self):
        ctx = [{
            "role": "user",
            "content": {
                "text": "[图像读取结果] a.png",
                "image_base64": "aGVsbG8=",
                "mime": "image/png",
            },
        }]
        out = self.s._convert_vision_messages(ctx)
        content = out[0]["content"]
        self.assertIsInstance(content, list)
        self.assertEqual(content[0], {"type": "text", "text": "[图像读取结果] a.png"})
        self.assertEqual(
            content[1],
            {"type": "image_url",
             "image_url": {"url": "data:image/png;base64,aGVsbG8="}},
        )

    def test_no_text_only_image(self):
        ctx = [{
            "role": "user",
            "content": {"image_base64": "QQ==", "mime": "image/jpeg"},
        }]
        out = self.s._convert_vision_messages(ctx)
        content = out[0]["content"]
        # 无 text 时不生成 text 片段
        self.assertEqual(
            content,
            [{"type": "image_url",
              "image_url": {"url": "data:image/jpeg;base64,QQ=="}}],
        )

    def test_image_url_preferred(self):
        """content 显式提供 image_url 时优先使用（不拼接 data URL）。"""
        ctx = [{
            "role": "user",
            "content": {
                "text": "t",
                "image_base64": "aGVsbG8=",
                "image_url": "http://x/img.png",
            },
        }]
        out = self.s._convert_vision_messages(ctx)
        parts = out[0]["content"]
        self.assertEqual(
            parts[1],
            {"type": "image_url", "image_url": {"url": "http://x/img.png"}},
        )

    def test_plain_message_passthrough(self):
        ctx = [
            {"role": "system", "content": "sys"},
            {"role": "user", "content": "普通文本"},
            {"role": "assistant", "content": "回复"},
        ]
        out = self.s._convert_vision_messages(ctx)
        self.assertEqual(out, ctx)

    def test_non_user_dict_content_passthrough(self):
        """role 非 user 的 dict content 不做转换。"""
        ctx = [{"role": "assistant", "content": {"text": "x"}}]
        out = self.s._convert_vision_messages(ctx)
        self.assertEqual(out, ctx)

    def test_empty_context(self):
        self.assertEqual(self.s._convert_vision_messages([]), [])


class TestToolContextContent(unittest.TestCase):
    """图像工具结果文本化（上下文写入用）。"""

    def test_non_vision_degraded(self):
        s = make_session(if_vision=False)
        result = {"image_base64": "aGVsbG8=", "mime": "image/png",
                  "file_path": "a.png"}
        out = s._tool_context_content(result, "已读取图像: a.png")
        self.assertIn("不支持图像输入", out)
        self.assertIn("a.png", out)

    def test_vision_keeps_summary(self):
        s = make_session(if_vision=True)
        result = {"image_base64": "aGVsbG8=", "mime": "image/png",
                  "file_path": "a.png"}
        out = s._tool_context_content(result, "已读取图像: a.png (image/png)")
        self.assertEqual(out, "已读取图像: a.png (image/png)")

    def test_normal_result_passthrough(self):
        s = make_session(if_vision=True)
        out = s._tool_context_content({"content": "hello"}, "hello")
        self.assertEqual(out, "hello")


class TestAppendImageUserMsg(unittest.TestCase):
    """图像结果追加携带图像的 user 消息（仅视觉模型）。"""

    def test_vision_appends_user_msg(self):
        s = make_session(if_vision=True)
        result = {"image_base64": "aGVsbG8=", "mime": "image/png",
                  "file_path": "a.png"}
        s._append_image_user_msg(result)
        added = s.context[-1]
        self.assertEqual(added["role"], "user")
        self.assertEqual(added["content"]["text"], "[图像读取结果] a.png")
        self.assertEqual(added["content"]["image_base64"], "aGVsbG8=")
        self.assertEqual(added["content"]["mime"], "image/png")

    def test_non_vision_no_append(self):
        s = make_session(if_vision=False)
        s._append_image_user_msg(
            {"image_base64": "aGVsbG8=", "mime": "image/png", "file_path": "a.png"}
        )
        self.assertEqual(s.context, [])

    def test_non_image_no_append(self):
        s = make_session(if_vision=True)
        s._append_image_user_msg({"content": "普通结果"})
        self.assertEqual(s.context, [])


if __name__ == "__main__":
    unittest.main()
