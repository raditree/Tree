# -*- coding: utf-8 -*-
"""插件化埋点体系一期 —— 异步专项测试（异步反例集 J1–J5 / W1–W4 / B1–B2 / E1）。

对应实现（栖迟 `server/plugin/`，已按实际接口对齐 v2）：
    join.py       JoinBuffer / JoinResult（齐备条件 / 超时 partial / 重复键去重；
                  超时由调用方 check_timeout 驱动 —— 一期"插件自协调"形态）
    watchdog.py   ProgressWatchdog（start_task/beat/finish_task/is_stalled/stalled_tasks
                  + 实例级 touch_instance/is_instance_stale/collect_stale_instances；
                  时间可注入）
    bus.py        EventBus（有界队列 dropped_full 计数）
    registry.py   PluginInstance（实例内 inbox_max 背压 / errors 计数 / 注销释放）

矩阵来源：``artifacts/test-plan.md``《异步反例集》（知遥）＋
``artifacts/interface-contract.md`` v1（行为判定标准）。

已知实现差异（记录于 ``artifacts/test-report.md`` 差距清单，联调逐项评审）：
- 活跃组数"双上限"未实现（J5 用例标注 skip）；
- "连续判死 → 自动停用实例"未实现（W4 改测实例级心跳/TTL 语义）；
- 无 auto_tick 自动续期（续期节拍由调用方 beat 驱动）。

执行（server 目录下）：
    .venv\\Scripts\\python -m pytest tests/test_plugin_async.py -v
"""

import sys
import time
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

try:
    from plugin.bus import EventBus, PluginEvent, Subscription, make_scope  # noqa: E402
    from plugin.join import JoinBuffer  # noqa: E402
    from plugin.registry import PluginInstance, PluginRegistry  # noqa: E402
    from plugin.watchdog import ProgressWatchdog  # noqa: E402

    PLUGIN_AVAILABLE = True
    IMPORT_ERROR = ""
except Exception as _e:  # noqa: BLE001 —— 模块未就绪时整文件 skip（联调前正常）
    EventBus = PluginEvent = Subscription = PluginRegistry = None  # type: ignore
    PluginInstance = JoinBuffer = ProgressWatchdog = None  # type: ignore
    PLUGIN_AVAILABLE = False
    IMPORT_ERROR = f"{type(_e).__name__}: {_e}"

_SKIP_REASON = f"server/plugin 未就绪: {IMPORT_ERROR}"

_WAIT_TIMEOUT = 3.0
_SETTLE_SHORT = 0.3
_LONG_GROUP_TIMEOUT = 10.0  # 测试内不希望误超时的组


# --------------------------------------------------------------------------
# 通用辅助
# --------------------------------------------------------------------------

def _scope(user_id="u1", team_id="t1", agent_id="", session_id=""):
    return make_scope(user_id=user_id, team_id=team_id, agent_id=agent_id, session_id=session_id)


def _wait_until(predicate, timeout=_WAIT_TIMEOUT):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.005)
    return False


def _settle(seconds=_SETTLE_SHORT):
    time.sleep(seconds)


def _event(type_="test.event", scope=None, payload=None):
    return PluginEvent(
        event_id=uuid.uuid4().hex,
        seq=1,
        type=type_,
        ts=time.time(),
        scope=scope or _scope(),
        source="test",
        payload=payload or {},
    )


def _make_env():
    bus = EventBus()
    watchdog = ProgressWatchdog()
    registry = PluginRegistry(bus=bus, watchdog=watchdog)
    bus.start()
    return bus, registry, watchdog


@unittest.skipUnless(PLUGIN_AVAILABLE, _SKIP_REASON)
class _AsyncCase(unittest.TestCase):
    def setUp(self):
        self.bus, self.registry, self.watchdog = _make_env()

    def tearDown(self):
        self.registry.shutdown()
        self.bus.stop()


# --------------------------------------------------------------------------
# J1–J5 join 边界（JoinBuffer 原语层）
# --------------------------------------------------------------------------

@unittest.skipUnless(PLUGIN_AVAILABLE, _SKIP_REASON)
class TestJoinBuffer(unittest.TestCase):
    """JoinBuffer 为纯内存组件（无需 env），独立于总线/注册表测试。"""

    def test_j1_partial_delivery_on_timeout(self):
        """J1：部分到达 + 组超时 → partial 交付（缺项清单、timed_out 标记）。"""
        jb = JoinBuffer(expect_keys={"a", "b"}, timeout=0.3)
        self.assertIsNone(jb.add("item-a", key="a"))
        self.assertIsNone(
            jb.check_timeout(now=time.time() + 0.1), "未超时不应交付"
        )
        res = jb.check_timeout(now=time.time() + 0.31)
        self.assertIsNotNone(res, "超时后应按 partial 交付")
        self.assertTrue(res.partial)
        self.assertTrue(res.timed_out)
        self.assertEqual(res.missing_keys, ["b"])
        self.assertEqual(len(res.items), 1)
        self.assertEqual(jb.pending_keys(), ["b"])

    def test_j1b_not_delivered_before_timeout(self):
        """J1b：未齐备且未超时 → 不交付（等待窗口未滑出）。"""
        jb = JoinBuffer(expect_keys={"a", "b"}, timeout=_LONG_GROUP_TIMEOUT)
        jb.add("x", key="a")
        self.assertIsNone(jb.check_timeout(now=time.time() + 0.5))
        self.assertFalse(jb.done())
        # 未提供 key 的 add 在 expect_keys 模式 fail-closed 拒绝
        with self.assertRaises(ValueError):
            jb.add("bad")

    def test_j2_duplicate_key_ignored_and_overflow_after_done(self):
        """J2：重复来源键去重忽略；组完成后超发事件不再交付。"""
        jb = JoinBuffer(expect_keys={"a", "b"}, timeout=_LONG_GROUP_TIMEOUT)
        jb.add("first", key="a")
        self.assertIsNone(jb.add("dup", key="a"), "重复来源键应忽略（去重）")
        self.assertEqual(jb.count(), 1)
        res = jb.add("second", key="b")
        self.assertIsNotNone(res, "键齐备应交付")
        self.assertFalse(res.partial)
        self.assertEqual(len(res.items), 2)

        jb2 = JoinBuffer(expect_count=2, timeout=_LONG_GROUP_TIMEOUT)
        self.assertIsNone(jb2.add(1))
        self.assertIsNotNone(jb2.add(2))
        self.assertIsNone(jb2.add(3), "组完成后超发事件应忽略（不重复交付）")

    def test_j3_late_arrival_and_reset(self):
        """J3：晚到（超时后才到）不得命中已结束组；reset 后新组正常。"""
        jb = JoinBuffer(expect_count=2, timeout=0.2)
        jb.add(1)
        res = jb.check_timeout(now=time.time() + 0.21)
        self.assertIsNotNone(res)
        self.assertTrue(res.timed_out)
        self.assertIsNone(jb.add(2), "已结束组不接受晚到事件")
        self.assertTrue(jb.done())

        jb.reset()
        self.assertIsNone(jb.add(3), "reset 后为新组第 1 条")
        res2 = jb.add(4)
        self.assertIsNotNone(res2, "新组应能正常齐备")
        self.assertFalse(res2.partial)
        self.assertEqual(len(res2.items), 2)

    def test_j4_groups_isolated(self):
        """J4：多组并行开窗互不污染（各自独立齐备、items 正确）。"""
        jb_a = JoinBuffer(expect_count=2, timeout=_LONG_GROUP_TIMEOUT)
        jb_b = JoinBuffer(expect_count=2, timeout=_LONG_GROUP_TIMEOUT)

        jb_a.add({"k": "A", "i": 1})
        jb_b.add({"k": "B", "i": 1})
        res_a = jb_a.add({"k": "A", "i": 2})
        self.assertIsNotNone(res_a, "组 A 应齐备")
        self.assertFalse(jb_b.done(), "组 B 不应受组 A 影响")
        res_b = jb_b.add({"k": "B", "i": 2})
        self.assertIsNotNone(res_b, "组 B 应齐备")

        self.assertEqual({it["k"] for it in res_a.items}, {"A"})
        self.assertEqual({it["k"] for it in res_b.items}, {"B"})

    @unittest.skip(
        "实现未提供活跃组数上限（契约 D5 双上限之一）——待评审：补实现或修订契约"
        "（见 test-report 差距清单）"
    )
    def test_j5_active_group_limit(self):
        """J5：活跃组数超上限 → 新组拒绝（待实现/评审）。"""
        pass


# --------------------------------------------------------------------------
# W1–W4 看门狗（续期 / 判死 / 实例心跳）
# --------------------------------------------------------------------------

@unittest.skipUnless(PLUGIN_AVAILABLE, _SKIP_REASON)
class TestWatchdog(unittest.TestCase):
    def test_w1_renewal_prevents_death(self):
        """W1：处理中周期续期 → 不判死；滑出窗口才判死（时间注入模拟）。"""
        wd = ProgressWatchdog(stall_seconds=1.0)
        wd.start_task("k1", owner=("u1", "t1"))
        self.assertFalse(wd.is_stalled("k1", now=time.time() + 0.5), "窗口内不应判死")
        self.assertTrue(wd.beat("k1", owner=("u1", "t1")))
        self.assertFalse(wd.is_stalled("k1", now=time.time() + 0.5), "续期后不应判死")
        self.assertTrue(
            wd.is_stalled("k1", now=time.time() + 1.5), "距最近进度滑出窗口应判死"
        )

    def test_w2_progress_interruption_judged_dead(self):
        """W2：进度中断（曾上报后停止）→ 滑出窗口判死。"""
        wd = ProgressWatchdog(stall_seconds=0.5)
        wd.start_task("k2", owner=("u1", "t1"))
        self.assertTrue(wd.beat("k2", owner=("u1", "t1")))
        self.assertFalse(wd.is_stalled("k2", now=time.time() + 0.1))
        self.assertTrue(
            wd.is_stalled("k2", now=time.time() + 0.6), "进度中断应被判死"
        )
        self.assertIn("k2", wd.stalled_tasks(now=time.time() + 0.6))

    def test_w3_waiting_or_finished_not_judged(self):
        """W3：未开始（等待期未注册）与已结束的任务不参与判死（防误杀）。"""
        wd = ProgressWatchdog(stall_seconds=0.2)
        self.assertFalse(
            wd.is_stalled("not-started", now=time.time() + 100),
            "未登记任务不应被判死",
        )
        wd.start_task("finished")
        self.assertTrue(wd.finish_task("finished"))
        self.assertFalse(
            wd.is_stalled("finished", now=time.time() + 100),
            "已结束任务不应被判死",
        )
        self.assertEqual(wd.task_count(), 0)

    def test_w4_instance_heartbeat_and_stale(self):
        """W4：实例级心跳——超 TTL 判 stale；未登记保守判 stale；可回收。"""
        wd = ProgressWatchdog()
        wd.touch_instance("inst-1")
        self.assertFalse(
            wd.is_instance_stale("inst-1", ttl=100, now=time.time() + 99)
        )
        self.assertTrue(
            wd.is_instance_stale("inst-1", ttl=100, now=time.time() + 101)
        )
        self.assertTrue(
            wd.is_instance_stale("unknown-inst", ttl=100), "未登记实例应保守判 stale"
        )
        stale = wd.collect_stale_instances(ttl=100, now=time.time() + 101)
        self.assertIn("inst-1", stale)
        wd.drop_instance("inst-1")
        self.assertEqual(wd.instance_count(), 0)


# --------------------------------------------------------------------------
# B1–B2 背压（总线队列 / 实例 inbox）
# --------------------------------------------------------------------------

@unittest.skipUnless(PLUGIN_AVAILABLE, _SKIP_REASON)
class TestBackpressure(unittest.TestCase):
    def test_b1_bus_queue_overflow_dropped_full(self):
        """B1：总线有界队列溢出 → 丢弃 + dropped_full 计数递增。"""
        bus = EventBus(max_queue=2)
        delivered = []

        def _slow(event):
            time.sleep(0.2)
            delivered.append(event)

        bus.add_subscription(
            Subscription(name="slow", match_fn=lambda e: True, deliver_fn=_slow)
        )
        bus.start()
        self.addCleanup(bus.stop)

        for i in range(6):
            bus.publish("test.event.b1", _scope("u1", "t1"), {"i": i}, source="test")
        stats = bus.stats()
        self.assertGreaterEqual(
            stats.get("dropped_full", 0), 1, f"队列溢出未按策略丢弃: {stats}"
        )

    def test_b1b_instance_inbox_overflow_dropped(self):
        """B1b：实例内队列（inbox_max）溢出 → 丢弃 + dropped 计数。"""
        seen = []
        inst = PluginInstance(
            "test.async.b1b", "team", _scope("u1", "t1"),
            lambda e: seen.append(e), inbox_max=2,
        )
        # 不启动 worker：队列不消费，直接观察溢出
        self.assertTrue(inst.offer(_event()))
        self.assertTrue(inst.offer(_event()))
        self.assertFalse(inst.offer(_event()))
        self.assertFalse(inst.offer(_event()))
        self.assertEqual(inst.dropped, 2)
        _settle(_SETTLE_SHORT)
        self.assertEqual(len(seen), 0, "未启动 worker 时不应有处理")

    def test_b2_system_usable_after_drops(self):
        """B2：丢弃后系统仍可用（恢复消费、后续事件正常处理、计数保留）。"""
        seen = []
        inst = PluginInstance(
            "test.async.b2", "team", _scope("u1", "t1"),
            lambda e: seen.append(e), inbox_max=2,
        )
        for _ in range(5):
            inst.offer(_event())
        self.assertGreaterEqual(inst.dropped, 3)
        inst.start_worker()  # 恢复消费
        self.assertTrue(
            _wait_until(lambda: len(seen) >= 2), "排空后已入队事件未被消费"
        )
        self.assertTrue(inst.offer(_event()), "丢弃后新事件应正常入队")
        self.assertTrue(_wait_until(lambda: len(seen) >= 3), "新事件未被处理")
        inst.stop()


# --------------------------------------------------------------------------
# E1 崩溃/解除
# --------------------------------------------------------------------------

@unittest.skipUnless(PLUGIN_AVAILABLE, _SKIP_REASON)
class TestCrashAndRelease(_AsyncCase):
    def test_e1a_handler_exception_does_not_break_subsequent(self):
        """E1a：handler 异常被捕获计数，不影响后续事件（异常不波及主线）。"""
        seen = []
        state = {"n": 0}

        def flaky(event):
            state["n"] += 1
            if state["n"] == 1:
                raise RuntimeError("boom（测试注入）")
            seen.append(event)

        inst = self.registry.register(
            "test.async.e1a", flaky,
            granularity="team", scope=_scope("u1", "t1"),
            event_types={"test.event.e1a"},
        )
        self.bus.publish("test.event.e1a", _scope("u1", "t1"), {}, source="test")
        self.assertTrue(
            _wait_until(lambda: inst.errors >= 1), "首次处理异常应被计数"
        )
        self.bus.publish("test.event.e1a", _scope("u1", "t1"), {}, source="test")
        self.assertTrue(
            _wait_until(lambda: len(seen) >= 1), "异常后后续事件未被处理"
        )
        self.assertEqual(inst.errors, 1, "异常计数应恰好为 1")

    def test_e1b_unregister_releases_instance(self):
        """E1b：实例注销后资源释放：查询为空、订阅移除、事件不再投递。"""
        calls = []
        inst = self.registry.register(
            "test.async.e1b", lambda e: calls.append(e),
            granularity="team", scope=_scope("u1", "t1"),
            event_types={"test.event.e1b"},
        )
        self.assertTrue(self.registry.unregister(inst))
        self.assertIsNone(self.registry.get(inst.instance_key()))
        self.bus.publish("test.event.e1b", _scope("u1", "t1"), {}, source="test")
        _settle(_SETTLE_SHORT)
        self.assertEqual(len(calls), 0, "销毁后仍收到投递（订阅未释放）")


if __name__ == "__main__":
    unittest.main()
