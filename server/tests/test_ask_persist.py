"""AskUserQuestion 持久化 + 暂停哨兵的单元测试。

覆盖：
- ``pending_questions`` 表 CRUD（save/get/mark_answered/mark_cancelled）
- 提问作为 ``kind='ask_user_question'`` 历史消息写入，get_history 返回
  options/answered/answer
- AskUserQuestionTool.execute 返回暂停哨兵且持久化到 DB
"""
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tool.ask_question_tool import ASK_PAUSED_KEY, AskUserQuestionTool
import data.conversation_store as store


class PendingQuestionStoreTest(unittest.TestCase):
    def setUp(self) -> None:
        # 指向临时 DB，避免污染正式 conversations.db
        self.tmpdir = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        store._DB_PATH = Path(self.tmpdir.name) / "conv_test_ask.db"
        store._initialized = False

    def tearDown(self) -> None:
        store._initialized = False
        self.tmpdir.cleanup()

    def test_pending_crud_and_history_roundtrip(self) -> None:
        user, agent, top, session = "u1", "a1", "a1", "s1"
        qid = "q_test1"
        store.save_pending_question(
            user, agent, top, session, qid, "需要你选择？", ["A", "B"], is_member=0
        )
        row = store.get_pending_question(qid)
        self.assertIsNotNone(row)
        self.assertEqual(row["agent_id"], agent)
        self.assertEqual(row["top_agent_id"], top)
        self.assertEqual(row["session_id"], session)
        self.assertEqual(row["status"], "pending")
        self.assertEqual(row["options"], ["A", "B"])

        # 提问作为历史消息写入；get_history 返回 options/answered
        store.store_message(
            user, agent, "agent", "需要你选择？", kind="ask_user_question",
            tool_arguments={"options": ["A", "B"]}, session_id=session,
            answered=0, msg_id=qid,
        )
        hist = store.get_history(user, agent, session)
        self.assertEqual(len(hist), 1)
        self.assertEqual(hist[0]["kind"], "ask_user_question")
        self.assertEqual(hist[0]["options"], ["A", "B"])
        self.assertFalse(hist[0]["answered"])

        # mark 已作答：pending 状态与历史 answered/answer 同步
        marked = store.mark_pending_answered(qid, "A")
        self.assertIsNotNone(marked)
        self.assertEqual(store.get_pending_question(qid)["status"], "answered")
        hist = store.get_history(user, agent, session)
        self.assertTrue(hist[0]["answered"])
        self.assertEqual(hist[0]["answer"], "A")

    def test_mark_answered_idempotent_after_resolved(self) -> None:
        store.save_pending_question("u2", "a2", "a2", "s2", "q_test2", "问题")
        self.assertIsNotNone(store.mark_pending_answered("q_test2", "x"))
        # 已答后再次作答返回 None
        self.assertIsNone(store.mark_pending_answered("q_test2", "y"))

    def test_cancel(self) -> None:
        store.save_pending_question("u3", "a3", "a3", "s3", "q_test3", "问题")
        store.mark_pending_cancelled("q_test3")
        self.assertEqual(store.get_pending_question("q_test3")["status"], "cancelled")


class AskToolSentinelTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmpdir = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        store._DB_PATH = Path(self.tmpdir.name) / "conv_test_ask2.db"
        store._initialized = False

    def tearDown(self) -> None:
        store._initialized = False
        self.tmpdir.cleanup()

    def test_execute_returns_sentinel_and_persists(self) -> None:
        # ws_manager=None 时跳过推送，仅验证持久化与哨兵
        tool = AskUserQuestionTool(
            ws_manager=None, user_id="u1", agent_id="a1",
            top_agent_id="a1", session_id="s1", is_member=False,
        )
        result = tool.execute({"question": "需要你选择？", "options": ["A", "B"]})
        self.assertTrue(result.get(ASK_PAUSED_KEY))
        qid = result.get("qid")

        row = store.get_pending_question(qid)
        self.assertIsNotNone(row)
        self.assertEqual(row["question"], "需要你选择？")
        self.assertEqual(row["options"], ["A", "B"])
        self.assertEqual(row["agent_id"], "a1")
        self.assertEqual(row["session_id"], "s1")
        # 历史里也应有对应的提问消息
        hist = store.get_history("u1", "a1", "s1")
        self.assertTrue(any(m["kind"] == "ask_user_question" for m in hist))


if __name__ == "__main__":
    unittest.main()