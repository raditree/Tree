r"""面板快照（二期 M1-b）单元测试：合成 / 过滤 / 骨架 / 观测字段 / 路由注册。

- 快照合成：未启用骨架（200 语义）、实例/站/看门狗/配置区块、user·team 过滤；
- 观测字段：waits_in_flight 增减平衡、wait_ms_total/max、reset 清零；
- 路由注册：``GET /api/plugin/snapshot`` 已挂载。

运行：cd server && .venv\Scripts\python -m pytest tests\test_plugin_snapshot.py -q
"""

from __future__ import annotations

import threading
import time
import unittest

from plugin.registry import PluginRegistry
from plugin.snapshot import build_snapshot
from plugin.status import StatusEmitter, get_status_emitter, set_status_emitter
from plugin.stations import STATION_READ_RESULT, StationsHub
from plugin.watchdog import ProgressWatchdog

SID = STATION_READ_RESULT


def scope_of(user="u1", team="t1", agent="a1", session="s1"):
    """构造四元组 scope（默认全字段非空）。"""
    return {
        "user_id": user,
        "team_id": team,
        "agent_id": agent,
        "session_id": session,
    }


class SnapshotTestBase(unittest.TestCase):
    """独立组件实例 + 全局发射器静默（消除清音日志）+ tearDown 清理。"""

    def setUp(self):
        self._orig_emitter = get_status_emitter()
        set_status_emitter(StatusEmitter(sender=lambda u, m: True))
        self.reg = PluginRegistry()
        self.wd = ProgressWatchdog()
        self.hub = StationsHub(self.reg, watchdog=self.wd)

    def tearDown(self):
        try:
            self.hub.reset()
        except Exception:
            pass
        for inst in self.reg.instances():
            try:
                self.reg.unregister(inst)
            except Exception:
                pass
        set_status_emitter(self._orig_emitter)


# ======================================================================
# 一、快照合成
# ======================================================================
class TestSnapshotBuild(SnapshotTestBase):

    def test_disabled_empty_skeleton(self):
        """未启用：enabled=false 空骨架（200 语义；面板显示"未启用"）。"""
        snap = build_snapshot(enabled=False)
        self.assertFalse(snap["enabled"])
        self.assertEqual(snap["instances"], [])
        self.assertEqual(snap["stations"], [])
        self.assertEqual(snap["watchdog"]["active_runs"], 0)
        self.assertEqual(snap["watchdog"]["judged_dead"], 0)
        self.assertIn("station_timeout_s", snap["config"])
        self.assertGreater(snap["generated_at"], 0)

    def test_instances_filter_and_fields(self):
        """实例区块：字段最小集 + user/team 过滤。"""
        self.reg.register(
            "demo-a", lambda e: None, granularity="agent", scope=scope_of("u1")
        )
        self.reg.register(
            "demo-b", lambda e: None, granularity="agent", scope=scope_of("u2")
        )
        snap = build_snapshot(enabled=True, user_id="u1", registry=self.reg)
        self.assertEqual(
            [i["plugin_id"] for i in snap["instances"]], ["demo-a"]
        )
        row = snap["instances"][0]
        for key in (
            "plugin_id",
            "name",
            "granularity",
            "scope",
            "status",
            "last_heartbeat",
            "queue_depth",
            "disabled_reason",
        ):
            self.assertIn(key, row)
        self.assertEqual(row["status"], "registered")
        self.assertEqual(row["disabled_reason"], "")
        self.assertEqual(row["scope"]["user_id"], "u1")
        # team 过滤（命中 / 不命中）
        snap2 = build_snapshot(
            enabled=True, user_id="u1", team_id="t1", registry=self.reg
        )
        self.assertEqual(len(snap2["instances"]), 1)
        snap3 = build_snapshot(
            enabled=True, user_id="u1", team_id="nope", registry=self.reg
        )
        self.assertEqual(snap3["instances"], [])

    def test_stations_block(self):
        """站区块：subscriptions / counts / gauges / timing 结构。"""
        self.assertTrue(
            self.hub.subscribe(
                SID, "demo", lambda req: None,
                granularity="agent", scope=scope_of(),
            )
        )
        snap = build_snapshot(enabled=True, stations=self.hub)
        self.assertEqual(len(snap["stations"]), 1)
        row = snap["stations"][0]
        self.assertEqual(row["station_id"], SID)
        self.assertEqual(len(row["subscriptions"]), 1)
        sub = row["subscriptions"][0]
        self.assertEqual(sub["plugin_id"], "demo")
        self.assertIn("subscriber", sub)
        for key in ("counts", "gauges", "timing"):
            self.assertIn(key, row)
        self.assertIn("waits_in_flight", row["gauges"])
        self.assertIn("wait_ms_total", row["timing"])
        self.assertIn("wait_ms_max", row["timing"])

    def test_facade_get_snapshot_shape(self):
        """门面 get_snapshot：键集完整（不依赖全局启用态）。"""
        from plugin import get_snapshot

        snap = get_snapshot(user_id="u1")
        for key in (
            "enabled",
            "generated_at",
            "instances",
            "stations",
            "watchdog",
            "config",
        ):
            self.assertIn(key, snap)


# ======================================================================
# 二、站观测字段（等待在飞 / 时长 / 清零）
# ======================================================================
class TestStationObservation(SnapshotTestBase):

    def test_wait_observation_balance_and_timing(self):
        """等待在飞增减平衡；wait_ms_total/max 累计；reset 清零。"""
        slow_done = threading.Event()

        def handler(req):
            slow_done.wait(timeout=1.0)
            return "OK:" + req.data

        self.assertTrue(
            self.hub.subscribe(
                SID, "demo", handler, granularity="agent", scope=scope_of()
            )
        )
        out = {}

        def run():
            out["r"] = self.hub.process(SID, "data", scope_of(), timeout_s=2.0)

        t = threading.Thread(target=run)
        t.start()
        try:
            seen = False
            deadline = time.monotonic() + 1.0
            while time.monotonic() < deadline:
                if self.hub.stats()["gauges"]["waits_in_flight"] >= 1:
                    seen = True
                    break
                time.sleep(0.005)
            self.assertTrue(seen, "等待在飞应可见（in-flight >= 1）")
        finally:
            slow_done.set()
        t.join(timeout=3.0)
        self.assertEqual(out.get("r"), "OK:data")
        st = self.hub.stats()
        self.assertEqual(st["gauges"]["waits_in_flight"], 0)
        self.assertGreater(st["timing"]["wait_ms_total"], 0)
        self.assertGreater(st["timing"]["wait_ms_max"], 0)
        # 单次等待：total ≈ max
        self.assertAlmostEqual(
            st["timing"]["wait_ms_max"],
            st["timing"]["wait_ms_total"],
            places=3,
        )
        # reset 清零
        self.hub.reset()
        st2 = self.hub.stats()
        self.assertEqual(st2["gauges"]["waits_in_flight"], 0)
        self.assertEqual(st2["timing"]["wait_ms_total"], 0.0)
        self.assertEqual(st2["timing"]["wait_ms_max"], 0.0)


# ======================================================================
# 三、路由注册
# ======================================================================
class TestSnapshotRoute(unittest.TestCase):

    def test_snapshot_route_registered(self):
        """GET /api/plugin/snapshot 已挂载（prefix=/api + 端点路径）。"""
        from agent import routes

        paths = {getattr(r, "path", "") for r in routes.router.routes}
        self.assertIn("/api/plugin/snapshot", paths)
