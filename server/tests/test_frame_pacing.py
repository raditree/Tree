# -*- coding: utf-8 -*-
"""主动延迟叠加的生成器帧率控制测试（计划项 4）。

两把旋钮分工（本测试锁定该契约）：
- 等级 ``rate_per_minute`` / ``active_rate_per_minute`` 管 **API 调用频率**
  （原有机制，未改动）；
- 主动延迟开关 + 用户设置的 **帧率（20~1000 帧/秒）** 管 **生成器帧率**，
  把同一轮回复内的 text/thinking 产出按固定时间步投递。

落点在**生产者线程**（``_stream_agent_reply._consume`` 内的 `_FramePacer`）：
`asyncio.Queue` 无界且 `call_soon_threadsafe` 零背压，只有阻塞生成器才能形成
真正的背压；在事件循环里 sleep 只会让队列膨胀。

覆盖：
- 关闭主动延迟 → 间隔 0（不节流，保持原生流式速度）
- 开启 → 间隔 = 1/fps，且可**中途切换**（每帧现查内存缓存）
- 帧率换算与范围夹取（20~1000）
- 控制类事件（tool_call / done / error / ask_paused）**不被节流**
- ``silent`` 模式完全跳过
- 取消事件在等待期间可响应
- `_consume` 集成：取消时投递 cancelled 并中止
"""
import sys
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import llm.rate_limit as rate_limit  # noqa: E402
from agent.chat import _FramePacer  # noqa: E402
from data.frame_rate_store import (  # noqa: E402
    DEFAULT_FRAME_RATE,
    MAX_FRAME_RATE,
    MIN_FRAME_RATE,
    clamp_frame_rate,
    frame_rate_to_interval,
)

USER = "u-pacing"


class TestClampAndInterval(unittest.TestCase):
    def test_clamp_bounds(self):
        self.assertEqual(clamp_frame_rate(0), MIN_FRAME_RATE)
        self.assertEqual(clamp_frame_rate(1), MIN_FRAME_RATE)
        self.assertEqual(clamp_frame_rate(20), 20)
        self.assertEqual(clamp_frame_rate(1000), 1000)
        self.assertEqual(clamp_frame_rate(99999), MAX_FRAME_RATE)

    def test_clamp_illegal_falls_back_to_default(self):
        for bad in (None, "", "abc", object()):
            self.assertEqual(clamp_frame_rate(bad), DEFAULT_FRAME_RATE)

    def test_clamp_accepts_numeric_strings_and_floats(self):
        self.assertEqual(clamp_frame_rate("240"), 240)
        self.assertEqual(clamp_frame_rate(240.7), 240)

    def test_interval_math(self):
        self.assertAlmostEqual(frame_rate_to_interval(20), 0.05)
        self.assertAlmostEqual(frame_rate_to_interval(1000), 0.001)
        self.assertEqual(frame_rate_to_interval(0), 0.0)
        self.assertEqual(frame_rate_to_interval(None), 0.0)


class TestFrameIntervalResolution(unittest.TestCase):
    """``rate_limit.frame_interval``：开关关闭 → 0；开启 → 1/fps。"""

    def setUp(self):
        rate_limit.load_enabled_users({})
        rate_limit.load_frame_rates({})

    def tearDown(self):
        rate_limit.load_enabled_users({})
        rate_limit.load_frame_rates({})

    def test_disabled_returns_zero(self):
        rate_limit.set_user_frame_rate(USER, 20)
        self.assertEqual(rate_limit.frame_interval(USER), 0.0)

    def test_enabled_returns_reciprocal(self):
        rate_limit.set_user_enabled(USER, True)
        rate_limit.set_user_frame_rate(USER, 20)
        self.assertAlmostEqual(rate_limit.frame_interval(USER), 0.05)

    def test_rate_change_takes_effect_immediately(self):
        rate_limit.set_user_enabled(USER, True)
        rate_limit.set_user_frame_rate(USER, 20)
        self.assertAlmostEqual(rate_limit.frame_interval(USER), 0.05)
        # 中途改帧率：无需重建会话，下一次查询即生效
        rate_limit.set_user_frame_rate(USER, 100)
        self.assertAlmostEqual(rate_limit.frame_interval(USER), 0.01)

    def test_toggle_midstream(self):
        rate_limit.set_user_frame_rate(USER, 50)
        self.assertEqual(rate_limit.frame_interval(USER), 0.0)  # 未开启
        rate_limit.set_user_enabled(USER, True)
        self.assertAlmostEqual(rate_limit.frame_interval(USER), 0.02)
        rate_limit.set_user_enabled(USER, False)
        self.assertEqual(rate_limit.frame_interval(USER), 0.0)

    def test_no_user_or_no_fps_returns_zero(self):
        rate_limit.set_user_enabled(USER, True)
        self.assertEqual(rate_limit.frame_interval(""), 0.0)
        self.assertEqual(rate_limit.frame_interval("nobody"), 0.0)

    def test_reset_user_clears_frame_rate(self):
        rate_limit.set_user_frame_rate(USER, 200)
        rate_limit.reset_user(USER)
        self.assertEqual(rate_limit.get_user_frame_rate(USER), DEFAULT_FRAME_RATE)


class TestFramePacerUnit(unittest.TestCase):
    def setUp(self):
        rate_limit.load_enabled_users({})
        rate_limit.load_frame_rates({})

    def tearDown(self):
        rate_limit.load_enabled_users({})
        rate_limit.load_frame_rates({})

    def test_paced_types_are_text_and_thinking_only(self):
        self.assertEqual(_FramePacer.PACED_TYPES, frozenset({"text", "thinking"}))

    def test_disabled_is_passthrough(self):
        pacer = _FramePacer(USER)
        start = time.monotonic()
        for _ in range(50):
            self.assertTrue(pacer.wait_turn({"type": "text", "content": "x"}))
        self.assertLess(time.monotonic() - start, 0.1)

    def test_control_events_not_paced(self):
        """tool_call / done / error / ask_paused 必须立即放行。"""
        rate_limit.set_user_enabled(USER, True)
        rate_limit.set_user_frame_rate(USER, 20)  # 50ms/帧
        pacer = _FramePacer(USER)
        start = time.monotonic()
        for _ in range(20):
            for kind in ("tool_call", "done", "error", "ask_paused", "cancelled"):
                self.assertTrue(pacer.wait_turn({"type": kind}))
        self.assertLess(time.monotonic() - start, 0.1)

    def test_text_is_paced_at_configured_rate(self):
        rate_limit.set_user_enabled(USER, True)
        rate_limit.set_user_frame_rate(USER, 20)  # 50ms
        pacer = _FramePacer(USER)
        start = time.monotonic()
        for _ in range(5):
            self.assertTrue(pacer.wait_turn({"type": "text", "content": "x"}))
        elapsed = time.monotonic() - start
        # 首帧立即，其后 4 帧各间隔 50ms → 至少 ~200ms
        self.assertGreaterEqual(elapsed, 0.15)
        self.assertLess(elapsed, 1.5)

    def test_higher_rate_is_faster(self):
        rate_limit.set_user_enabled(USER, True)
        slow = _FramePacer(USER)
        rate_limit.set_user_frame_rate(USER, 20)
        t0 = time.monotonic()
        for _ in range(5):
            slow.wait_turn({"type": "text"})
        slow_elapsed = time.monotonic() - t0

        fast = _FramePacer(USER)
        rate_limit.set_user_frame_rate(USER, 1000)
        t1 = time.monotonic()
        for _ in range(5):
            fast.wait_turn({"type": "text"})
        fast_elapsed = time.monotonic() - t1
        self.assertLess(fast_elapsed, slow_elapsed)

    def test_silent_skips_pacing(self):
        rate_limit.set_user_enabled(USER, True)
        rate_limit.set_user_frame_rate(USER, 20)
        pacer = _FramePacer(USER, silent=True)
        start = time.monotonic()
        for _ in range(20):
            self.assertTrue(pacer.wait_turn({"type": "text"}))
        self.assertLess(time.monotonic() - start, 0.1)

    def test_cancel_event_aborts_wait(self):
        rate_limit.set_user_enabled(USER, True)
        # 用允许的最低帧率 20fps（间隔 50ms）→ 帧间隔远大于取消延迟，
        # 避免"帧已到期"与"取消已置位"竞态导致偶发失败
        rate_limit.set_user_frame_rate(USER, MIN_FRAME_RATE)
        pacer = _FramePacer(USER)
        self.assertTrue(pacer.wait_turn({"type": "text"}))  # 首帧立即

        cancel = threading.Event()
        # 取消延迟必须显著小于帧间隔：这里 10ms vs 50ms
        timer = threading.Timer(0.01, cancel.set)
        timer.start()
        try:
            start = time.monotonic()
            result = pacer.wait_turn({"type": "text"}, cancel)
            elapsed = time.monotonic() - start
        finally:
            timer.cancel()
            cancel.set()
        self.assertFalse(result)
        # 被取消即在 10ms 量级返回，不等满 50ms 帧间隔
        self.assertLess(elapsed, 0.04)

    def test_cancel_before_wait_returns_false(self):
        """已置位的取消事件应立即中止（不消耗首帧）。"""
        rate_limit.set_user_enabled(USER, True)
        rate_limit.set_user_frame_rate(USER, 20)
        pacer = _FramePacer(USER)
        cancel = threading.Event()
        cancel.set()
        self.assertFalse(pacer.wait_turn({"type": "text"}, cancel))

    def test_already_set_cancel_returns_false_immediately(self):
        rate_limit.set_user_enabled(USER, True)
        rate_limit.set_user_frame_rate(USER, 20)
        pacer = _FramePacer(USER)
        cancel = threading.Event()
        cancel.set()
        self.assertFalse(pacer.wait_turn({"type": "text"}, cancel))

    def test_toggle_midstream_resets_timing(self):
        """流中途开关主动延迟不得抛错，且关闭后立即不再等待。"""
        pacer = _FramePacer(USER)
        self.assertTrue(pacer.wait_turn({"type": "text"}))
        rate_limit.set_user_enabled(USER, True)
        rate_limit.set_user_frame_rate(USER, 1000)
        self.assertTrue(pacer.wait_turn({"type": "text"}))
        rate_limit.set_user_enabled(USER, False)
        start = time.monotonic()
        for _ in range(10):
            self.assertTrue(pacer.wait_turn({"type": "text"}))
        self.assertLess(time.monotonic() - start, 0.1)

    def test_resolution_failure_is_fail_open(self):
        """帧率解析异常一律视为不节流：体验优化不得阻断回复。"""
        pacer = _FramePacer(USER)
        with patch("llm.rate_limit.frame_interval", side_effect=RuntimeError("boom")):
            start = time.monotonic()
            self.assertTrue(pacer.wait_turn({"type": "text"}))
        self.assertLess(time.monotonic() - start, 0.1)


if __name__ == "__main__":
    unittest.main()
