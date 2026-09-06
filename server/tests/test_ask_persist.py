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
from unittest.mock import MagicMock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tool.ask_question_tool import ASK_PAUSED_KEY, AskUserQuestionTool
import data.conversation_store as store
import data.db as db_mod


class PendingQuestionStoreTest(unittest.TestCase):
    def setUp(self) -> None:
        # 指向临时 DB，避免污染正式 conversations.db
        self.tmpdir = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        store._DB_PATH = Path(self.tmpdir.name) / "conv_test_ask.db"
        store._initialized = False
        # 共享 connect()（data.db）一并重定向，避免打开真实库
        self._old_shared_db = db_mod._DB_PATH
        db_mod._DB_PATH = Path(self.tmpdir.name) / "conv_test_ask.db"
        db_mod._wal_configured = False

    def tearDown(self) -> None:
        store._initialized = False
        db_mod._DB_PATH = self._old_shared_db
        db_mod._wal_configured = False
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
        self.assertEqual(row["team_id"], top)
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

    def test_sender_id_roundtrip(self) -> None:
        """sender_id 应随待答提问落库并回读（续跑后总结精确回发用）。"""
        store.save_pending_question(
            "u4", "a4", "top-4", "s4", "q_test4", "问题",
            is_member=1, sender_id="peerA",
        )
        row = store.get_pending_question("q_test4")
        self.assertEqual(row["sender_id"], "peerA")
        # 缺省 sender_id 落库为空串（兼容旧调用/主 agent）
        store.save_pending_question("u5", "a5", "a5", "s5", "q_test5", "问题")
        self.assertEqual(store.get_pending_question("q_test5")["sender_id"], "")

    def test_list_questions_filter_and_order(self) -> None:
        """list_questions 支持按会话过滤、is_member 转 bool、按时间倒序。"""
        store.save_pending_question(
            "u9", "a9", "top-9", "s9", "q_list1", "问题1", ["A", "B"], is_member=0
        )
        store.save_pending_question(
            "u9", "a9m", "top-9", "s9", "q_list2", "问题2",
            is_member=1, sender_id="peerB",
        )
        # 另一会话的提问不应混入 s9 的结果
        store.save_pending_question("u9", "a9", "top-9", "s10", "q_list3", "问题3")

        # 按会话过滤：仅 s9 两条，且最新的在前（q_list2 后插入）
        rows = store.list_questions("u9", "s9")
        self.assertEqual([r["qid"] for r in rows], ["q_list2", "q_list1"])
        self.assertTrue(rows[0]["is_member"])
        self.assertFalse(rows[1]["is_member"])
        self.assertEqual(rows[1]["options"], ["A", "B"])
        self.assertEqual(rows[0]["sender_id"], "peerB")

        # 不过滤会话：三条全返回
        self.assertEqual(len(store.list_questions("u9")), 3)
        # 其他用户不可见
        self.assertEqual(store.list_questions("u-other"), [])


class AskToolSentinelTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmpdir = tempfile.TemporaryDirectory(ignore_cleanup_errors=True)
        store._DB_PATH = Path(self.tmpdir.name) / "conv_test_ask2.db"
        store._initialized = False
        # 共享 connect()（data.db）一并重定向，避免打开真实库
        self._old_shared_db = db_mod._DB_PATH
        db_mod._DB_PATH = Path(self.tmpdir.name) / "conv_test_ask2.db"
        db_mod._wal_configured = False

    def tearDown(self) -> None:
        store._initialized = False
        db_mod._DB_PATH = self._old_shared_db
        db_mod._wal_configured = False
        self.tmpdir.cleanup()

    def test_execute_returns_sentinel_and_persists(self) -> None:
        # ws_manager=None 时跳过推送，仅验证持久化与哨兵
        tool = AskUserQuestionTool(
            ws_manager=None, user_id="u1", agent_id="a1",
            team_id="a1", session_id="s1", is_member=False,
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

    def test_execute_persists_sender_from_session(self) -> None:
        """提问时从 session.sender_id 读取发送方并持久化（成员边缘路径）。"""
        session = MagicMock()
        session.sender_id = "peerA"
        tool = AskUserQuestionTool(
            ws_manager=None, user_id="u6", agent_id="a6",
            team_id="top-6", session_id="s6", is_member=True,
            session=session,
        )
        result = tool.execute({"question": "确认？"})
        qid = result.get("qid")
        self.assertEqual(store.get_pending_question(qid)["sender_id"], "peerA")


if __name__ == "__main__":
    unittest.main()