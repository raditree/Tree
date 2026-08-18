"""无限上下文 LLM 上下文持久化与原子操作测试。

验证 LimitlessContextSession 的：
- 前缀一致性验证（正常追加与不一致抛出异常）
- 上下文跨任务保留
- 上下文持久化到 JSON 文件
- 崩溃恢复（从 JSON 文件恢复上下文）
- docker_manager 为 None 时的优雅降级

使用 unittest.mock 模拟 docker_manager 和 OpenAI client。
"""

import json
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# 将 server 目录添加到 Python 路径，使 core 模块可导入
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core.llm import LimitlessContextSession  # noqa: E402
from core.models import ModelConfig  # noqa: E402


def _make_mock_chunk(content=None, finish_reason=None):
    """构建模拟的 OpenAI 流式响应 chunk。

    :param content: 文本内容（None 表示无文本）
    :param finish_reason: 结束原因（"stop" / "tool_calls" / None）
    :return: MagicMock chunk 对象
    """
    chunk = MagicMock()
    choice = MagicMock()
    choice.delta.content = content
    choice.delta.tool_calls = None
    choice.finish_reason = finish_reason
    chunk.choices = [choice]
    return chunk


class TestLimitlessContextSession(unittest.TestCase):
    """LimitlessContextSession 原子上下文操作测试。"""

    def setUp(self):
        """每个测试前准备模型配置和默认 mock docker_manager。"""
        self.model_config = ModelConfig(
            name="test-model",
            base_url="http://localhost:8000",
            api_key="test-api-key",
            model_id="test-model-id",
            is_limitless_context=True,
            extra={"temperature": 0.7, "top_k": 40},
        )
        self.workspace_id = "test-workspace"

        # 默认 mock：文件不存在（exit_code=1）或空内容
        # 用于 __init__ 中的 _load_context_snapshot 调用
        self.docker_manager = MagicMock()
        self.docker_manager.exec_in_workspace.return_value = {
            "exit_code": 0,
            "stdout": "",
            "stderr": "",
        }

    def _create_session(self, docker_manager=None):
        """创建 LimitlessContextSession 实例。

        :param docker_manager: docker_manager 实例，None 时使用 setUp 中的默认 mock
        :return: LimitlessContextSession 实例
        """
        if docker_manager is None:
            docker_manager = self.docker_manager
        return LimitlessContextSession(
            model_config=self.model_config,
            workspace_id=self.workspace_id,
            system_prompt="",
            docker_manager=docker_manager,
        )

    # ------------------------------------------------------------------
    # 前缀一致性测试
    # ------------------------------------------------------------------
    def test_prefix_consistency_normal_append(self):
        """测试前缀一致性：新输入前缀与上次输入一致时正常追加。"""
        session = self._create_session()

        # 首次调用：_last_context_json 为 None，应直接通过
        session._validate_prefix("first message")
        self.assertEqual(len(session.context), 0)  # validate 不追加消息

        # 模拟一次完成的对话后的上下文状态
        session.context = [
            {"role": "user", "content": "hello"},
            {"role": "assistant", "content": "hi there"},
        ]
        session._last_context_json = json.dumps(
            session.context, ensure_ascii=False, sort_keys=True
        )

        # 上下文未变，前缀一致，应正常通过不抛异常
        session._validate_prefix("second message")
        # 验证仍未追加（_validate_prefix 不修改上下文）
        self.assertEqual(len(session.context), 2)

    def test_prefix_inconsistency_raises_value_error(self):
        """测试前缀不一致：上下文被篡改时抛出 ValueError。"""
        session = self._create_session()

        # 模拟上次对话结束后的上下文快照
        session.context = [
            {"role": "user", "content": "hello"},
            {"role": "assistant", "content": "hi there"},
        ]
        session._last_context_json = json.dumps(
            session.context, ensure_ascii=False, sort_keys=True
        )

        # 模拟上下文被外部篡改（删除了一条消息）
        session.context = [
            {"role": "user", "content": "hello"},
        ]

        # 前缀不一致，应抛出 ValueError
        with self.assertRaises(ValueError) as ctx:
            session._validate_prefix("new message")
        self.assertIn("前缀一致性验证失败", str(ctx.exception))

    # ------------------------------------------------------------------
    # 上下文跨任务保留测试
    # ------------------------------------------------------------------
    def test_context_preserved_across_tasks(self):
        """测试上下文跨任务保留：完成一个任务后上下文不清空。"""
        session = self._create_session()

        # 模拟第一个任务完成后的上下文
        session.context = [
            {"role": "user", "content": "task 1"},
            {"role": "assistant", "content": "task 1 done"},
        ]
        session._last_context_json = json.dumps(
            session.context, ensure_ascii=False, sort_keys=True
        )

        # 模拟 LLM 对第二个任务的响应
        mock_client = MagicMock()
        mock_chunk = _make_mock_chunk(
            content="task 2 done", finish_reason="stop"
        )
        mock_client.chat.completions.create.return_value = [mock_chunk]

        with patch(
            "core.llm.LLMClientFactory.create_client",
            return_value=mock_client,
        ):
            # 消费生成器以执行完整对话流程
            results = list(session.chat("task 2"))

        # 验证上下文保留了第一个任务的消息，并追加了第二个任务的消息
        self.assertEqual(len(session.context), 4)
        self.assertEqual(session.context[0]["content"], "task 1")
        self.assertEqual(session.context[1]["content"], "task 1 done")
        self.assertEqual(session.context[2]["content"], "task 2")
        self.assertEqual(session.context[3]["content"], "task 2 done")

        # 验证流式输出包含了 LLM 的回复文本
        text_results = [r for r in results if r["type"] == "text"]
        self.assertEqual(len(text_results), 1)
        self.assertEqual(text_results[0]["content"], "task 2 done")

        # 验证持久化被调用（回复完成后，write_file 写入上下文快照）
        self.assertGreaterEqual(self.docker_manager.write_file.call_count, 1)

    # ------------------------------------------------------------------
    # 持久化测试
    # ------------------------------------------------------------------
    def test_persistence_writes_json_file(self):
        """测试持久化：上下文正确写入 JSON 文件。"""
        session = self._create_session()

        # 设置上下文内容
        session.context = [
            {"role": "user", "content": "test message"},
            {"role": "assistant", "content": "test reply"},
        ]

        # 重置 mock 以仅捕获持久化调用
        self.docker_manager.write_file.reset_mock()

        # 执行持久化
        session._persist_context()

        # 验证 write_file 被调用
        self.docker_manager.write_file.assert_called_once()

        call_args = self.docker_manager.write_file.call_args
        # 第一个位置参数是 workspace_id
        workspace_id_arg = call_args[0][0]
        self.assertEqual(workspace_id_arg, self.workspace_id)

        # 第二个位置参数是写入路径
        path_arg = call_args[0][1]
        self.assertEqual(path_arg, "/workspace/.self/context_snapshot.json")

        # 第三个位置参数是内容 bytes，验证包含上下文消息
        content_arg = call_args[0][2]
        self.assertIsInstance(content_arg, bytes)
        content = content_arg.decode("utf-8")
        self.assertIn("test message", content)
        self.assertIn("test reply", content)

    # ------------------------------------------------------------------
    # 崩溃恢复测试
    # ------------------------------------------------------------------
    def test_crash_recovery_from_json_file(self):
        """测试崩溃恢复：从 JSON 文件恢复上下文。"""
        # 模拟工作空间中已存在的上下文快照
        saved_context = [
            {"role": "user", "content": "previous task"},
            {"role": "assistant", "content": "previous reply"},
            {"role": "user", "content": "another message"},
        ]

        docker_manager = MagicMock()

        def mock_exec(workspace_id, command):
            """根据命令类型返回不同的 mock 响应。"""
            # cat 命令：返回保存的上下文 JSON
            if isinstance(command, list) and len(command) > 0 and command[0] == "cat":
                return {
                    "exit_code": 0,
                    "stdout": json.dumps(saved_context, ensure_ascii=False),
                    "stderr": "",
                }
            # 其他命令（如 sh -c 持久化）：返回成功
            return {"exit_code": 0, "stdout": "", "stderr": ""}

        docker_manager.exec_in_workspace.side_effect = mock_exec

        # 创建会话，__init__ 会调用 _load_context_snapshot
        session = LimitlessContextSession(
            model_config=self.model_config,
            workspace_id=self.workspace_id,
            system_prompt="",
            docker_manager=docker_manager,
        )

        # 验证上下文从快照恢复
        self.assertEqual(len(session.context), 3)
        self.assertEqual(session.context[0]["content"], "previous task")
        self.assertEqual(session.context[1]["content"], "previous reply")
        self.assertEqual(session.context[2]["content"], "another message")

        # 验证 _last_context_json 已设置（用于后续前缀验证）
        self.assertIsNotNone(session._last_context_json)
        expected_json = json.dumps(
            saved_context, ensure_ascii=False, sort_keys=True
        )
        self.assertEqual(session._last_context_json, expected_json)

        # 验证恢复后可以正常通过前缀验证（上下文未被篡改）
        session._validate_prefix("new message after recovery")

    # ------------------------------------------------------------------
    # docker_manager 为 None 的优雅降级测试
    # ------------------------------------------------------------------
    def test_no_docker_manager_graceful_degradation(self):
        """测试 docker_manager 为 None 时不崩溃。"""
        session = LimitlessContextSession(
            model_config=self.model_config,
            workspace_id=self.workspace_id,
            system_prompt="",
            docker_manager=None,
        )

        # 上下文应为空（无快照可加载）
        self.assertEqual(session.context, [])
        # _last_context_json 应为 None（无快照）
        self.assertIsNone(session._last_context_json)

        # _persist_context 不应抛出异常
        session.context = [{"role": "user", "content": "test"}]
        session._persist_context()

        # _validate_prefix 应正常工作（首次调用，_last_context_json 为 None）
        session._validate_prefix("new message")

        # _load_context_snapshot 应返回 False
        self.assertFalse(session._load_context_snapshot())

    # ------------------------------------------------------------------
    # 持久化 + 崩溃恢复集成测试
    # ------------------------------------------------------------------
    def test_persist_then_recover_round_trip(self):
        """测试持久化后恢复的完整流程：写入 → 读取 → 验证一致。"""
        # 第一次创建会话，设置上下文并持久化
        docker_manager = MagicMock()
        # 第一次：无快照（文件不存在）
        docker_manager.exec_in_workspace.return_value = {
            "exit_code": 1,
            "stdout": "",
            "stderr": "No such file",
        }

        session1 = LimitlessContextSession(
            model_config=self.model_config,
            workspace_id=self.workspace_id,
            system_prompt="",
            docker_manager=docker_manager,
        )
        # session1 上下文为空（无快照）
        self.assertEqual(session1.context, [])

        # 模拟对话后的上下文
        session1.context = [
            {"role": "user", "content": "round trip message"},
            {"role": "assistant", "content": "round trip reply"},
        ]

        # 捕获持久化写入的内容（write_file 的第三个位置参数）
        persisted_json = None

        def mock_write_file(workspace_id, path, content):
            nonlocal persisted_json
            persisted_json = content.decode("utf-8")
            return {"exit_code": 0, "stdout": "", "stderr": ""}

        docker_manager.write_file.side_effect = mock_write_file

        def mock_exec_capture(workspace_id, command):
            nonlocal persisted_json
            if isinstance(command, list) and len(command) > 0 and command[0] == "cat":
                if persisted_json is not None:
                    return {
                        "exit_code": 0,
                        "stdout": persisted_json,
                        "stderr": "",
                    }
                return {"exit_code": 1, "stdout": "", "stderr": ""}
            return {"exit_code": 0, "stdout": "", "stderr": ""}

        docker_manager.exec_in_workspace.side_effect = mock_exec_capture

        # 持久化上下文
        session1._persist_context()
        self.assertIsNotNone(persisted_json)

        # 第二次创建会话，模拟崩溃后恢复
        session2 = LimitlessContextSession(
            model_config=self.model_config,
            workspace_id=self.workspace_id,
            system_prompt="",
            docker_manager=docker_manager,
        )

        # 验证恢复的上下文与持久化的内容一致
        self.assertEqual(len(session2.context), 2)
        self.assertEqual(session2.context[0]["content"], "round trip message")
        self.assertEqual(session2.context[1]["content"], "round trip reply")


if __name__ == "__main__":
    unittest.main()
