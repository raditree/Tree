# -*- coding: utf-8 -*-
"""分级 API 限流测试：令牌桶节奏 / 等级解析 / 取消 / 按 agent 独立 / 存储往返。

覆盖 spec「分级 API 限流」：
- 无论是否开启主动延迟都限流：间隔按用户等级 + 开关动态解析
  （关闭用等级 rate_per_minute；开启用等级 active_rate_per_minute）
- 缺 user_id / agent_id 直接放行（不产生等待）
- 按固定时间步限速（interval），等待令牌期间可被取消事件中止（配合「停止」级联）
- 不同 agent 独立限流（互不影响）
- set_user_level 清空该用户限流器（等级变更立即生效）
- load_enabled_users 整体替换开关缓存 / reset_user 清理
- rate_limit_prefs 表读写往返（隔离临时 DB，不污染真实库）

所有用例均快速执行：通过 patch ``_resolve_interval`` / 等级配置缩短或精确
控制间隔，不真实等待 5-10 秒。
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
import data.db as data_db  # noqa: E402
import data.rate_limit_store as rate_limit_store  # noqa: E402
from config import levels as level_config  # noqa: E402
from data import user_store  # noqa: E402


class TestRateLimitAcquire(unittest.TestCase):
    def setUp(self):
        # 清空开关缓存与限流器实例，避免跨用例干扰
        rate_limit.load_enabled_users({})
        rate_limit._limiters.clear()
        # 等级解析统一走内存 mock（返回 common），避免触碰真实 DB
        # （真实 user_store 路由不属于本测试范围，由各用例自行覆盖 get_user_level）
        self._level_patch = patch.object(
            user_store, "get_user_level", return_value="common"
        )
        self._level_patch.start()
        self.addCleanup(self._level_patch.stop)

    def test_missing_ids_pass_immediately(self):
        """缺 user_id / agent_id：acquire 直接放行。"""
        t0 = time.monotonic()
        self.assertTrue(rate_limit.acquire("", "a1"))
        self.assertLess(time.monotonic() - t0, 0.3)

        t0 = time.monotonic()
        self.assertTrue(rate_limit.acquire("u1", ""))
        self.assertLess(time.monotonic() - t0, 0.3)

    def test_disabled_still_rate_limited(self):
        """主动延迟关闭也限流：按该用户等级 rate_per_minute 的间隔生效。"""
        rate_limit.set_user_enabled("u1", False)
        with patch.object(rate_limit, "_resolve_interval", return_value=0.3):
            t0 = time.monotonic()
            self.assertTrue(rate_limit.acquire("u1", "a1"))
            self.assertLess(time.monotonic() - t0, 0.2)

            t0 = time.monotonic()
            self.assertTrue(rate_limit.acquire("u1", "a1"))
            dt = time.monotonic() - t0
            self.assertGreaterEqual(dt, 0.3 - 0.1, "关闭时同样按间隔限流")

    def test_token_bucket_interval(self):
        """开启后：首次立即放行，第二次需等 ≥ interval（固定时间步）。"""
        rate_limit.set_user_enabled("u1", True)
        with patch.object(rate_limit, "_resolve_interval", return_value=0.3):
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
        with patch.object(rate_limit, "_resolve_interval", return_value=5.0):
            t0 = time.monotonic()
            ok = rate_limit.acquire("u2", "a1", cancel)
            dt = time.monotonic() - t0
        self.assertFalse(ok)
        self.assertLess(dt, 2.0, "取消应中断长等待")

    def test_per_agent_independent(self):
        """不同 agent 使用独立限流器，互不影响。"""
        rate_limit.set_user_enabled("u3", True)
        with patch.object(rate_limit, "_resolve_interval", return_value=5.0):
            rate_limit.acquire("u3", "a1")  # 占掉 a1 的令牌
            # a2 首次调用立即放行（独立令牌）
            t0 = time.monotonic()
            self.assertTrue(rate_limit.acquire("u3", "a2"))
            self.assertLess(time.monotonic() - t0, 0.3)

    def test_set_user_level_clears_limiters(self):
        """set_user_level：清除该用户全部限流器（等级变更立即生效）。"""
        rate_limit.set_user_enabled("u6", True)
        rate_limit.acquire("u6", "a1")
        rate_limit.acquire("u6", "a2")
        rate_limit.acquire("u7", "a1")
        self.assertIn(("u6", "a1"), rate_limit._limiters)
        self.assertIn(("u6", "a2"), rate_limit._limiters)
        self.assertIn(("u7", "a1"), rate_limit._limiters)

        rate_limit.set_user_level("u6", "pro")
        self.assertNotIn(("u6", "a1"), rate_limit._limiters)
        self.assertNotIn(("u6", "a2"), rate_limit._limiters)
        # 不影响其它用户
        self.assertIn(("u7", "a1"), rate_limit._limiters)

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


class TestResolveInterval(unittest.TestCase):
    """_resolve_interval：按等级 + 开关解析 interval（直接断言返回值，不等待）。"""

    def setUp(self):
        # 等级解析统一走内存 mock（返回 common），避免触碰真实 DB
        self._level_patch = patch.object(
            user_store, "get_user_level", return_value="common"
        )
        self._level_patch.start()
        self.addCleanup(self._level_patch.stop)

    def test_by_level_disabled(self):
        """关闭主动延迟：interval = 60 / rate_per_minute
        （common 12 / pro 24 / ultra 60 / beta 300 次/分钟）。"""
        cases = [
            ("common", 12, 5.0),
            ("pro", 24, 2.5),
            ("ultra", 60, 1.0),
            ("beta", 300, 0.2),
        ]
        for level, rpm, expected in cases:
            with self.subTest(level=level):
                with patch.object(user_store, "get_user_level", return_value=level), \
                     patch.object(level_config, "get_level_config", return_value={
                         "rate_per_minute": rpm,
                         "active_rate_per_minute": 6,
                     }), \
                     patch.object(rate_limit, "is_user_enabled", return_value=False):
                    self.assertAlmostEqual(
                        rate_limit._resolve_interval("u_x"), expected
                    )

    def test_by_level_enabled(self):
        """开启主动延迟：interval = 60 / active_rate_per_minute（各等级均 6/min → 10s）。"""
        for level in ("common", "pro", "ultra", "beta"):
            with self.subTest(level=level):
                with patch.object(user_store, "get_user_level", return_value=level), \
                     patch.object(level_config, "get_level_config", return_value={
                         "rate_per_minute": 12,
                         "active_rate_per_minute": 6,
                     }), \
                     patch.object(rate_limit, "is_user_enabled", return_value=True):
                    self.assertAlmostEqual(
                        rate_limit._resolve_interval("u_x"), 10.0
                    )

    def test_fallback_min_interval(self):
        """等级配置缺失 / rate<=0：回退 MIN_INTERVAL。"""
        # 配置缺失
        with patch.object(level_config, "get_level_config", return_value={}), \
             patch.object(rate_limit, "is_user_enabled", return_value=False):
            self.assertEqual(rate_limit._resolve_interval("u_x"), rate_limit.MIN_INTERVAL)
        # rate<=0
        with patch.object(level_config, "get_level_config", return_value={
                "rate_per_minute": 0, "active_rate_per_minute": -1}), \
             patch.object(rate_limit, "is_user_enabled", return_value=False):
            self.assertEqual(rate_limit._resolve_interval("u_x"), rate_limit.MIN_INTERVAL)


class TestRateLimitStore(unittest.TestCase):
    def test_store_roundtrip(self):
        """rate_limit_prefs 表读写往返（隔离临时 DB）。"""
        tmp = Path(tempfile.mkdtemp())
        with patch.object(rate_limit_store, "_DATA_DIR", tmp), \
             patch.object(rate_limit_store, "_DB_PATH", tmp / "test.db"), \
             patch.object(rate_limit_store, "_initialized", False), \
             patch.object(data_db, "_DB_PATH", tmp / "test.db"):
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
