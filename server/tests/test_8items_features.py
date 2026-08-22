"""8 大项改造新增功能单元测试。

覆盖：
- read_tool 图像读取（_read_image base64、路径校验放宽）
- ModelConfig.if_vision 显式字段与 reserved 不透传
- llm.py vision 消息格式转换（_convert_vision_messages）
- llm.py 图像工具结果进上下文（_tool_context_content / _append_image_user_msg）
- MCP 服务存储（mcp_service_store 注册/校验/删除）
"""

import base64
import json
import unittest
from unittest.mock import AsyncMock, Mock

from config.models import ModelConfig
from tool.read_tool import ReadTool


class TestModelConfigIfVision(unittest.TestCase):
    def test_if_vision_parsed_from_yaml_top_level(self):
        cfg = ModelConfig.from_dict({
            "name": "vision-model",
            "base_url": "http://x",
            "api_key": "k",
            "model_id": "vm",
            "if_vision": True,
        })
        self.assertTrue(cfg.if_vision)
        # if_vision 不应进入 extra（否则会被透传为 OpenAI 顶层参数）
        self.assertNotIn("if_vision", cfg.extra)

    def test_if_vision_default_false(self):
        cfg = ModelConfig.from_dict({
            "name": "plain-model",
            "base_url": "http://x",
            "api_key": "k",
            "model_id": "pm",
        })
        self.assertFalse(cfg.if_vision)

    def test_to_dict_keeps_if_vision(self):
        cfg = ModelConfig(
            name="m", base_url="u", api_key="k", model_id="id", if_vision=True
        )
        d = cfg.to_dict()
        self.assertTrue(d["if_vision"])


class TestReadToolImage(unittest.TestCase):
    def setUp(self):
        self.io = Mock()
        self.tool = ReadTool(self.io, "ws")

    def test_image_path_validation_allows_chinese_and_space(self):
        # 图像路径放宽：允许空格/中文（文本路径校验会拒绝）
        self.assertTrue(
            ReadTool._is_valid_image_path("截图 2026-08-12 183834.png")
        )
        # 仍拒绝 shell 元字符与 .. 回溯
        self.assertFalse(ReadTool._is_valid_image_path("a;rm -rf.png"))
        self.assertFalse(ReadTool._is_valid_image_path("../etc/passwd.png"))

    def test_read_image_returns_base64(self):
        payload = base64.b64encode(b"\x89PNG\r\n\x1a\nfake").decode()
        self.io.exec_argv = AsyncMock(return_value={
            "exit_code": 0, "stdout": payload, "stderr": "",
        })
        ret = self.tool.execute({"file_path": "shot.png"})
        self.assertEqual(ret["image_base64"], payload)
        self.assertEqual(ret["mime"], "image/png")

    def test_read_image_falls_back_commands(self):
        # python3 失败 → python 成功
        self.io.exec_argv = AsyncMock(side_effect=[
            {"exit_code": 1, "stderr": "no python3", "stdout": ""},
            {"exit_code": 0, "stdout": "YmFzZTY0", "stderr": ""},
        ])
        ret = self.tool.execute({"file_path": "a.jpg"})
        self.assertEqual(ret["image_base64"], "YmFzZTY0")
        self.assertEqual(ret["mime"], "image/jpeg")
        self.assertEqual(self.io.exec_argv.call_count, 2)

    def test_read_image_all_fail_returns_error(self):
        self.io.exec_argv = AsyncMock(return_value={
            "exit_code": 1, "stderr": "fail", "stdout": "",
        })
        ret = self.tool.execute({"file_path": "a.png"})
        self.assertIn("error", ret)

    def test_text_file_still_works(self):
        self.io.read_file = AsyncMock(return_value={"content": "hello"})
        ret = self.tool.execute({"file_path": "a.txt"})
        self.assertEqual(ret["content"], "hello")


class TestLlmVisionMessages(unittest.TestCase):
    def _make_session(self, if_vision):
        from llm.llm import AgentLLMSession
        cfg = ModelConfig(
            name="m", base_url="u", api_key="k",
            model_id="id", if_vision=if_vision,
        )
        return AgentLLMSession(cfg, "ws", "sys")

    def test_convert_vision_messages_vision_model(self):
        session = self._make_session(if_vision=True)
        context = [
            {"role": "user", "content": "plain"},
            {
                "role": "user",
                "content": {
                    "text": "[图像读取结果] a.png",
                    "image_base64": "QUJD",
                    "mime": "image/png",
                },
            },
        ]
        converted = session._convert_vision_messages(context)
        # 图像消息转为 content 数组
        img_msg = converted[1]
        self.assertEqual(img_msg["role"], "user")
        self.assertIsInstance(img_msg["content"], list)
        parts = img_msg["content"]
        self.assertEqual(parts[0]["type"], "text")
        self.assertEqual(parts[1]["type"], "image_url")
        self.assertTrue(
            parts[1]["image_url"]["url"].startswith("data:image/png;base64,")
        )

    def test_convert_vision_messages_plain_model(self):
        # 静态方法契约：调用方按 if_vision 决定是否调用；直接调用时
        # 图像 dict 会被转换为 vision 数组（非视觉模型由 _build_api_kwargs
        # 跳过本方法，图像已在工具结果写入处降级为文本）。
        session = self._make_session(if_vision=False)
        context = [
            {"role": "user", "content": "plain"},
            {
                "role": "user",
                "content": {
                    "text": "x",
                    "image_base64": "QUJD",
                    "mime": "image/png",
                },
            },
        ]
        converted = session._convert_vision_messages(context)
        self.assertIsInstance(converted[1]["content"], list)
        self.assertEqual(converted[0]["content"], "plain")

    def test_tool_context_content_image_plain_model_degrades(self):
        session = self._make_session(if_vision=False)
        out = session._tool_context_content(
            {"image_base64": "QUJD", "mime": "image/png", "file_path": "a.png"},
            "已读取图像",
        )
        self.assertIn("不支持图像", out)

    def test_tool_context_content_image_vision_model_keeps_summary(self):
        session = self._make_session(if_vision=True)
        out = session._tool_context_content(
            {"image_base64": "QUJD", "mime": "image/png", "file_path": "a.png"},
            "已读取图像: a.png",
        )
        self.assertEqual(out, "已读取图像: a.png")

    def test_append_image_user_msg_only_vision(self):
        session = self._make_session(if_vision=True)
        session.context = []
        session._append_image_user_msg(
            {"image_base64": "QUJD", "mime": "image/png", "file_path": "a.png"}
        )
        self.assertEqual(len(session.context), 1)
        self.assertEqual(session.context[0]["role"], "user")
        self.assertEqual(session.context[0]["content"]["image_base64"], "QUJD")

    def test_append_image_user_msg_skipped_plain_model(self):
        session = self._make_session(if_vision=False)
        session.context = []
        session._append_image_user_msg(
            {"image_base64": "QUJD", "mime": "image/png", "file_path": "a.png"}
        )
        self.assertEqual(len(session.context), 0)


class TestMcpServiceStore(unittest.TestCase):
    def test_validate_service_config_ok(self):
        from data.mcp_service_store import validate_service_config
        self.assertIsNone(
            validate_service_config("my-svc", "npx", ["-y", "@modelcontext/server"])
        )

    def test_validate_rejects_shell_metachars(self):
        from data.mcp_service_store import validate_service_config
        err = validate_service_config("evil", "npx", [";rm -rf /"])
        self.assertIsNotNone(err)

    def test_validate_rejects_unknown_command(self):
        from data.mcp_service_store import validate_service_config
        err = validate_service_config("svc", "some-random-cmd", [])
        self.assertIsNotNone(err)

    def test_validate_rejects_dangerous_arg(self):
        from data.mcp_service_store import validate_service_config
        err = validate_service_config("svc", "python", ["-c", "import os"])
        self.assertIsNotNone(err)

    def test_register_and_list_roundtrip(self):
        from data.mcp_service_store import (
            delete_service, get_service, list_services, register_service,
        )
        delete_service("roundtrip-svc")  # 清理残留
        rec = register_service("roundtrip-svc", "npx", ["-y", "pkg"])
        self.assertEqual(rec["name"], "roundtrip-svc")
        got = get_service("roundtrip-svc")
        self.assertEqual(got["command"], "npx")
        self.assertEqual(got["args"], ["-y", "pkg"])
        names = [s["name"] for s in list_services()]
        self.assertIn("roundtrip-svc", names)
        delete_service("roundtrip-svc")

    def test_delete_builtin_forbidden(self):
        from data.mcp_service_store import delete_service
        self.assertFalse(delete_service("workspace"))


if __name__ == "__main__":
    unittest.main()
