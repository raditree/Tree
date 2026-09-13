"""消息切入模式（串行排队 / 直接切入）回归测试。

覆盖：
1. 偏好存储读写往返、非法值/缺失回退 ``queue``（隔离临时 DB，不污染真实库）；
2. ``_drain_session_payloads``：串行排队逐条取、跨会话阻塞、直接切入批量 drain
   且其他会话消息原样放回（不串入本会话上下文）。
"""
import queue as _queue
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import data.message_mode_store as mode_store  # noqa: E402
from agent import chat as chat_mod  # noqa: E402


class TestMessageModeStore(unittest.TestCase):
    """偏好存储：读写往返 + 缺省/非法回退 queue。"""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        db_path = Path(self._tmp.name) / "t.db"
        # 记录测试期间打开的全部连接，收尾时统一关闭——否则 Windows 下
        # 临时库文件被占用导致清理报 PermissionError（_ensure_db 的
        # ``with connect()`` 只提交不关闭，与 rate_limit_store 一致）。
        self._conns = []

        def _connect():
            conn = sqlite3.connect(db_path)
            conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
            self._conns.append(conn)
            return conn

        mode_store._initialized = False
        self._patch_connect = patch.object(
            mode_store, "connect", side_effect=_connect
        )
        self._patch_connect.start()
        self.addCleanup(self._patch_connect.stop)
        self.addCleanup(self._cleanup)

    def _cleanup(self):
        mode_store._initialized = False
        for conn in self._conns:
            try:
                conn.close()
            except Exception:  # noqa: BLE001
                pass
        self._conns.clear()
        self._tmp.cleanup()

    def test_default_is_queue(self):
        """未设置过的用户默认串行排队。"""
        self.assertEqual(mode_store.get_message_mode("u1"), mode_store.MODE_QUEUE)
        self.assertFalse(mode_store.is_direct_cutin("u1"))

    def test_direct_roundtrip(self):
        """设置直接切入后可读回，并持久化到库（重建初始化标记仍可读）。"""
        mode_store.set_message_mode("u1", mode_store.MODE_DIRECT)
        self.assertEqual(mode_store.get_message_mode("u1"), mode_store.MODE_DIRECT)
        self.assertTrue(mode_store.is_direct_cutin("u1"))
        mode_store._initialized = False
        self.assertEqual(mode_store.get_message_mode("u1"), mode_store.MODE_DIRECT)

    def test_invalid_value_falls_back_to_queue(self):
        """非法模式值回退 queue（不抛错）。"""
        mode_store.set_message_mode("u2", "bogus")
        self.assertEqual(mode_store.get_message_mode("u2"), mode_store.MODE_QUEUE)

    def test_empty_openid_defaults_queue(self):
        self.assertEqual(mode_store.get_message_mode(""), mode_store.MODE_QUEUE)


class TestDrainSessionPayloads(unittest.TestCase):
    """队列 drain：串行排队逐条；直接切入批量且跨会话隔离。"""

    @staticmethod
    def _q(items):
        q = _queue.Queue()
        for it in items:
            q.put(it)
        return q

    def test_queue_mode_takes_only_one(self):
        """串行排队：一次仅取队首一条，剩余留在队列由 worker 后续处理。"""
        q = self._q([
            {"session_id": "s1", "content": "a"},
            {"session_id": "s1", "content": "b"},
        ])
        picked = chat_mod._drain_session_payloads(q, "s1", False)
        self.assertEqual([p["content"] for p in picked], ["a"])
        self.assertEqual(q.qsize(), 1)

    def test_queue_mode_other_session_blocks(self):
        """串行排队：队首是其他会话时返回空并放回（不向后扫描）。"""
        q = self._q([
            {"session_id": "s2", "content": "other"},
            {"session_id": "s1", "content": "mine"},
        ])
        picked = chat_mod._drain_session_payloads(q, "s1", False)
        self.assertEqual(picked, [])
        self.assertEqual(q.qsize(), 2)

    def test_direct_mode_drains_all_same_session(self):
        """直接切入：一次性取走全部当前会话消息，其他会话消息放回。"""
        q = self._q([
            {"session_id": "s1", "content": "a"},
            {"session_id": "s2", "content": "other"},
            {"session_id": "s1", "content": "b"},
        ])
        picked = chat_mod._drain_session_payloads(q, "s1", True)
        self.assertEqual([p["content"] for p in picked], ["a", "b"])
        self.assertEqual(q.qsize(), 1)
        self.assertEqual(q.get_nowait()["content"], "other")

    def test_none_queue_returns_empty(self):
        self.assertEqual(chat_mod._drain_session_payloads(None, "s1", True), [])


if __name__ == "__main__":
    unittest.main()
