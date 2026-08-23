# -*- coding: utf-8 -*-
"""主动延迟限流测试：令牌桶节奏 / 取消 / 按 agent 独立 / 存储往返。

覆盖 spec「主动延迟」：
- 开关关闭或未设置时 acquire 立即放行（不产生等待）
- 开启后按固定时间步限速（MIN_INTERVAL），平均 6 次/分钟
- 等待令牌期间可被取消事件中止（配合「停止」级联）
- 不同 agent 独立限流（互不影响）
- load_enabled_users 整体替换开关缓存 / reset_user 清理
- rate_limit_prefs 表读写往返（隔离临时 DB，不污染真实库）
"""

import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import llm.rate_limit as rate_limit  # noqa: E402
import data.rate_limit_store as rate_limit_store  # noqa: E402


class TestRateLimitAcquire(unittest.TestCase):
    def setUp(self):
        # 清空开关缓存与限流器实例，避免跨用例干扰
        rate_limit.load_enabled_users({})
        rate_limit._limiters.clear()

    def test_disabled_passes_immediately(self):
        """未开启 / 未设置用户：acquire 立即放行。"""
        rate_limit.set_user_enabled("u1", False)
        t0 = time.monotonic()
        self.assertTrue(rate_limit.acquire("u1", "a1"))
        self.assertLess(time.monotonic() - t0, 0.3)

        # 未登记的用户也直接放行
        t0 = time.monotonic()
        self.assertTrue(rate_limit.acquire("no_such_user", "a1"))
        self.assertLess(time.monotonic() - t0, 0.3)

        # 缺 user_id / agent_id 直接放行
        self.assertTrue(rate_limit.acquire("", "a1"))
        self.assertTrue(rate_limit.acquire("u1", ""))

    def test_enabled_token_bucket_interval(self):
        """开启后：首次立即放行，第二次需等 ≥ MIN_INTERVAL（固定时间步）。"""
        rate_limit.set_user_enabled("u1", True)
        with patch.object(rate_limit, "MIN_INTERVAL", 0.3):
            t0 = time.monotonic()
            self.assertTrue(rate_limit.acquire("u1", "a1"))
            self.assertLess(time.monotonic() - t0, 0.2)

            t0 = time.monotonic()
            self.assertTrue(rate_limit.acquire("u1", "a1"))
            dt = time.monotonic() - t0
            self.assertGreaterEqual(dt, 0.3 - 0.1, "第二次调用应等待一个间隔")

    def test_cancel_event_aborts_wait(self):
        """等待令牌期间收到取消事件：提前返回 False（配合停止级联）。"""
        rate_limit.set_user_enabled("u2", True)
        # 先消耗令牌，使下一次调用必须等待
        rate_limit.acquire("u2", "a1")
        cancel = threading.Event()

        def _set():
            time.sleep(0.2)
            cancel.set()

        threading.Thread(target=_set, daemon=True).start()
        with patch.object(rate_limit, "MIN_INTERVAL", 5.0):
            t0 = time.monotonic()
            ok = rate_limit.acquire("u2", "a1", cancel)
            dt = time.monotonic() - t0
        self.assertFalse(ok)
        self.assertLess(dt, 2.0, "取消应中断长等待")

    def test_per_agent_independent(self):
        """不同 agent 使用独立限流器，互不影响。"""
        rate_limit.set_user_enabled("u3", True)
        rate_limit.acquire("u3", "a1")  # 占掉 a1 的令牌
        with patch.object(rate_limit, "MIN_INTERVAL", 5.0):
            # a2 首次调用立即放行（独立令牌）
            t0 = time.monotonic()
            self.assertTrue(rate_limit.acquire("u3", "a2"))
            self.assertLess(time.monotonic() - t0, 0.3)

    def test_load_enabled_users_replaces_cache(self):
        """load_enabled_users 整体替换开关缓存（启动预载语义）。"""
        rate_limit.set_user_enabled("u1", True)
        rate_limit.set_user_enabled("u2", True)
        rate_limit.load_enabled_users({"u3": True, "u4": False})
        self.assertFalse(rate_limit.is_user_enabled("u1"))
        self.assertFalse(rate_limit.is_user_enabled("u2"))
        self.assertTrue(rate_limit.is_user_enabled("u3"))
        self.assertFalse(rate_limit.is_user_enabled("u4"))

    def test_reset_user_cleans_registry(self):
        """reset_user：清理用户开关与限流器实例（注销级联）。"""
        rate_limit.set_user_enabled("u5", True)
        rate_limit.acquire("u5", "a1")
        self.assertIn(("u5", "a1"), rate_limit._limiters)
        rate_limit.reset_user("u5")
        self.assertFalse(rate_limit.is_user_enabled("u5"))
        self.assertNotIn(("u5", "a1"), rate_limit._limiters)


class TestRateLimitStore(unittest.TestCase):
    def test_store_roundtrip(self):
        """rate_limit_prefs 表读写往返（隔离临时 DB）。"""
        tmp = Path(tempfile.mkdtemp())
        with patch.object(rate_limit_store, "_DATA_DIR", tmp), \
             patch.object(rate_limit_store, "_DB_PATH", tmp / "test.db"), \
             patch.object(rate_limit_store, "_initialized", False):
            rate_limit_store.set_rate_limit_enabled("u9", True)
            self.assertTrue(rate_limit_store.is_rate_limit_enabled("u9"))

            prefs = rate_limit_store.load_all_rate_limit_prefs()
            self.assertEqual(prefs.get("u9"), True)

            rate_limit_store.set_rate_limit_enabled("u9", False)
            self.assertFalse(rate_limit_store.is_rate_limit_enabled("u9"))

            rate_limit_store.delete_user_rate_limit_pref("u9")
            self.assertFalse(rate_limit_store.is_rate_limit_enabled("u9"))


if __name__ == "__main__":
    unittest.main()
