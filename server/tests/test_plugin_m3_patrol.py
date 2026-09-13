r"""工程组（M3）专项测试：巡检联动 / 判死停用 / F3（纯计数）——对照矩阵 §4（EN3/EN4/EN8）。

范围与对照：
- 反例矩阵 ``agentspace/.hard/20260913-plugin-phase2/artifacts/test-reverse-matrix-v2.md``
  §4 工程组：EN3 巡检（判死双阈值 / 续期不误杀 / 幂等）· EN4 F3（纯计数 / 重置 /
  独立性）· EN8 max_run_seconds（执行 + 不泄漏）；EN1 观测补与 EN2/EN5/EN6/EN7 见
  ``test_plugin_m3_guard.py``；
- 实现：``watchdog.py``（巡检 check/start/stop + 判死双阈值）、``registry.py``
  （连续判死 → disable 联动 / status(disabled) / 恢复）、``stations.py``（F3 计数）；
- 缩参注入（构造参数优先，全部可注入；不依赖 env）：
  ``ProgressWatchdog(stall_seconds=..., dead_strikes=..., max_consecutive_dead=...)``、
  ``StationsHub(..., error_threshold=...)``；判死计数器以显式 ``check(now=...)``
  或真实短窗驱动。

运行：cd server && .venv\Scripts\python -m pytest tests\test_plugin_m3_patrol.py -q
"""

from __future__ import annotations

import time
import unittest

from plugin.registry import PluginRegistry
from plugin.stations import STATION_READ_RESULT, StationsHub
from plugin.watchdog import ProgressWatchdog

SID = STATION_READ_RESULT
INST_KEY = "m3plug|agent|u1|t1|a1"


def scope_of(user="u1", team="t1", agent="a1", session="s1"):
    """构造四元组 scope（默认全字段非空）。"""
    return {
        "user_id": user,
        "team_id": team,
        "agent_id": agent,
        "session_id": session,
    }


class WatchdogPatrolTests(unittest.TestCase):
    """EN3 巡检：判死双阈值 / 续期不误杀 / 幂等 / 计数 / 循环缩参。"""

    def test_continuously_stalled_run_judged_dead_after_strikes(self):
        """连续 dead_strikes 轮停滞 → 判死（移除 run + 计数；不泄漏）。"""
        wd = ProgressWatchdog(stall_seconds=1.0, dead_strikes=2)
        wd.register_run(INST_KEY, "req-1", auto_tick=False, max_run_seconds=None)
        t0 = time.time()
        self.assertEqual(wd.check(now=t0 + 0.5)["judged_runs"], [])
        self.assertEqual(wd.check(now=t0 + 1.1)["judged_runs"], [])  # 第 1 击未达阈
        r3 = wd.check(now=t0 + 1.2)
        self.assertEqual(r3["judged_runs"], ["req-1"])
        self.assertEqual(wd.judged_dead_count(), 1)
        self.assertEqual(wd.task_count(), 0)  # 判死后不泄漏

    def test_renewal_resets_strikes_no_false_kill(self):
        """续期（显式 beat）打断连续计数——「续期不误杀」重点矩阵。"""
        wd = ProgressWatchdog(stall_seconds=0.12, dead_strikes=2)
        wd.register_run(INST_KEY, "req-r", auto_tick=False, max_run_seconds=None)
        # 第一击：停滞窗口外
        time.sleep(0.15)
        self.assertEqual(wd.check()["judged_runs"], [])
        # 续期（真实时钟）→ 进度刷新，下一轮不再累积
        self.assertTrue(wd.note_progress(INST_KEY, "req-r"))
        self.assertEqual(wd.check()["judged_runs"], [])
        # 再来一轮循环：持续续期则永不判死
        time.sleep(0.15)
        self.assertEqual(wd.check()["judged_runs"], [])
        self.assertTrue(wd.note_progress(INST_KEY, "req-r"))
        self.assertEqual(wd.check()["judged_runs"], [])
        self.assertEqual(wd.judged_dead_count(), 0)
        self.assertEqual(wd.task_count(), 1)
        wd.finish_run(INST_KEY, "req-r")
        self.assertEqual(wd.task_count(), 0)

    def test_auto_tick_run_auto_renewed_no_kill(self):
        """auto_tick=True：框架代续期（慢处理不误杀）；仅硬上限约束。"""
        wd = ProgressWatchdog(stall_seconds=0.05, dead_strikes=1)
        wd.register_run(INST_KEY, "req-a", auto_tick=True, max_run_seconds=None)
        time.sleep(0.12)
        self.assertEqual(wd.check()["judged_runs"], [])
        self.assertEqual(wd.judged_dead_count(), 0)
        self.assertEqual(wd.task_count(), 1)

    def test_max_run_seconds_executed(self):
        """EN8：max_run_seconds 执行——超限经判死 + 释放（防僵尸 run 占用）。"""
        wd = ProgressWatchdog(stall_seconds=60.0, dead_strikes=2)
        t0 = time.time()
        wd.register_run(INST_KEY, "req-m", auto_tick=True, max_run_seconds=1.0)
        # 自动续期仅刷新进度——超限判定以 started_at 为准
        self.assertEqual(wd.check(now=t0 + 1.2)["judged_runs"], [])
        r = wd.check(now=t0 + 1.3)
        self.assertEqual(r["judged_runs"], ["req-m"])
        self.assertEqual(wd.judged_dead_count(), 1)
        self.assertEqual(wd.task_count(), 0)

    def test_consecutive_dead_disables_via_handler(self):
        """连续判死达阈 → 停用回调（watchdog 侧）；回调异常安全（不中断巡检）。"""
        wd = ProgressWatchdog(
            stall_seconds=0.04, dead_strikes=1, max_consecutive_dead=2
        )
        calls = []
        wd.set_disable_handler(lambda k, r: calls.append((k, r)))
        t0 = time.time()
        wd.register_run(INST_KEY, "d1", auto_tick=False, max_run_seconds=None)
        wd.check(now=t0 + 0.08)  # 判死 1
        self.assertEqual(calls, [])  # 未达阈
        wd.register_run(INST_KEY, "d2", auto_tick=False, max_run_seconds=None)
        wd.check(now=t0 + 0.16)  # 判死 2 → 达阈
        self.assertEqual(calls, [(INST_KEY, "watchdog_dead")])
        self.assertEqual(wd.judged_dead_count(), 2)

        def _boom(_k, _r):
            raise RuntimeError("boom")

        wd.set_disable_handler(_boom)
        wd.register_run(INST_KEY, "d3", auto_tick=False, max_run_seconds=None)
        wd.register_run(INST_KEY, "d4", auto_tick=False, max_run_seconds=None)
        wd.check(now=t0 + 0.24)  # d3 判死
        wd.check(now=t0 + 0.32)  # d4 判死 → 达阈 → 回调抛异常被吞
        self.assertEqual(wd.judged_dead_count(), 4)

    def test_patrol_loop_start_stop_with_interval(self):
        """循环缩参：start(interval) 后台巡检；start/stop 幂等、可停可起。"""
        wd = ProgressWatchdog(stall_seconds=0.05, dead_strikes=1)
        wd.register_run(INST_KEY, "loop-1", auto_tick=False, max_run_seconds=None)
        self.assertTrue(wd.start(interval=0.02))
        self.assertFalse(wd.start(interval=0.02))  # 幂等
        deadline = time.time() + 3.0
        while wd.judged_dead_count() < 1 and time.time() < deadline:
            time.sleep(0.02)
        self.assertGreaterEqual(wd.judged_dead_count(), 1)
        wd.stop()
        wd.stop()  # 幂等
        self.assertEqual(wd.task_count(), 0)

    def test_disable_end_to_end_with_registry_status_and_station(self):
        """端到端：连续判死 → 停用 + status(disabled) → 站请求 fail-open 直通；
        重复停用幂等；快照字段就绪；重新注册恢复。"""
        import plugin.status as status_mod
        from plugin.snapshot import build_snapshot

        orig = status_mod.get_status_emitter()
        events = []
        emitter = status_mod.StatusEmitter(
            dedup_s=0.0,
            max_per_sec=1000,
            sender=lambda uid, msg: (events.append(msg), True)[1],
        )
        status_mod.set_status_emitter(emitter)
        try:
            wd = ProgressWatchdog(
                stall_seconds=0.04, dead_strikes=1, max_consecutive_dead=2
            )
            reg = PluginRegistry(watchdog=wd)
            hub = StationsHub(reg, watchdog=wd)
            try:
                inst = reg.register(
                    "m3plug", lambda e: None, granularity="agent", scope=scope_of()
                )
                key = inst.instance_key()
                self.assertEqual(key, INST_KEY)
                wd.register_run(key, "e1", auto_tick=False, max_run_seconds=None)
                time.sleep(0.06)
                wd.check()
                self.assertFalse(inst.disabled)  # 1 次判死未达阈
                wd.register_run(key, "e2", auto_tick=False, max_run_seconds=None)
                time.sleep(0.06)
                wd.check()
                self.assertTrue(inst.disabled)
                self.assertEqual(inst.disabled_reason, "watchdog_dead")
                disabled_events = [
                    m
                    for m in events
                    if m.get("data", {}).get("status") == "disabled"
                ]
                self.assertEqual(len(disabled_events), 1)
                self.assertEqual(
                    disabled_events[0]["data"]["reason"], "watchdog_dead"
                )
                # 重复停用幂等：不产生第二次 disabled 事件
                self.assertFalse(reg.disable(inst, reason="again"))
                self.assertEqual(
                    len(
                        [
                            m
                            for m in events
                            if m.get("data", {}).get("status") == "disabled"
                        ]
                    ),
                    1,
                )
                # 站请求 fail-open 直通（不再投递 handler；归因 no_subscriber）
                called = []

                def _h(req):
                    called.append(1)
                    return "X"

                hub.subscribe(SID, "m3plug", _h, granularity="agent", scope=scope_of())
                out = hub.process(SID, "hello", scope_of())
                self.assertEqual(out, "hello")
                self.assertEqual(called, [])
                self.assertGreaterEqual(hub.stats()["counts"]["no_subscriber"], 1)
                # 快照字段：status=disabled + reason
                snap = build_snapshot(
                    enabled=True,
                    user_id="u1",
                    registry=reg,
                    stations=hub,
                    watchdog=wd,
                )
                row = [i for i in snap["instances"] if i["plugin_id"] == "m3plug"][0]
                self.assertEqual(row["status"], "disabled")
                self.assertEqual(row["disabled_reason"], "watchdog_dead")
                # 重新注册 = 恢复信号
                again = reg.register(
                    "m3plug", lambda e: None, granularity="agent", scope=scope_of()
                )
                self.assertIs(again, inst)
                self.assertFalse(inst.disabled)
                self.assertEqual(inst.disabled_reason, "")
            finally:
                reg.shutdown()
        finally:
            status_mod.set_status_emitter(orig)


class F3StreakTests(unittest.TestCase):
    """EN4：F3 连续 handler_error（纯计数、成功重置、与判死独立）。"""

    def _mk(self, threshold=3):
        wd = ProgressWatchdog()
        reg = PluginRegistry(watchdog=wd)
        hub = StationsHub(reg, watchdog=wd, error_threshold=threshold)
        self.addCleanup(reg.shutdown)
        return reg, hub, wd

    def test_threshold_boundary_and_disable(self):
        """N-1 不触发 / N 触发停用 + disabled_reason；与判死独立计数。"""
        reg, hub, wd = self._mk(threshold=3)

        def bad(req):
            raise RuntimeError("boom")

        hub.subscribe(SID, "f3plug", bad, granularity="agent", scope=scope_of())
        for _ in range(2):  # N-1
            self.assertEqual(hub.process(SID, "d", scope_of()), "d")  # fail-open
        inst = reg.get("f3plug|agent|u1|t1|a1")
        self.assertEqual(inst.handler_error_streak, 2)
        self.assertFalse(inst.disabled)
        self.assertEqual(hub.process(SID, "d", scope_of()), "d")  # N → 达阈
        self.assertTrue(inst.disabled)
        self.assertEqual(inst.disabled_reason, "handler_error")
        self.assertEqual(hub.stats()["counts"]["handler_error"], 3)
        # 与判死独立：判死计数未动
        self.assertEqual(wd.judged_dead_count(), 0)
        # 已停用后重复触发幂等（不再重复停用）
        self.assertFalse(reg.disable(inst, reason="x"))

    def test_success_resets_streak(self):
        """任一次成功（responded）即重置连续计数。"""
        reg, hub, _wd = self._mk(threshold=2)
        state = {"n": 0}

        def flaky(req):
            state["n"] += 1
            if state["n"] == 2:
                return "ok"
            raise RuntimeError("boom")

        hub.subscribe(SID, "flaky", flaky, granularity="agent", scope=scope_of())
        hub.process(SID, "d", scope_of())  # 失败 1
        inst = reg.get("flaky|agent|u1|t1|a1")
        self.assertEqual(inst.handler_error_streak, 1)
        self.assertEqual(hub.process(SID, "d", scope_of()), "ok")  # 成功 → 重置
        self.assertEqual(inst.handler_error_streak, 0)
        hub.process(SID, "d", scope_of())  # 失败 1
        self.assertFalse(inst.disabled)
        hub.process(SID, "d", scope_of())  # 失败 2 → 达阈
        self.assertTrue(inst.disabled)
        self.assertEqual(inst.disabled_reason, "handler_error")


if __name__ == "__main__":
    unittest.main()
