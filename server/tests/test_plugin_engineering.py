r"""工程组（EN，M3）专项测试：EN1 观测增强（先行部分；M3 落盘后补 EN2–EN8）。

范围与对照：
- 反例矩阵 ``agentspace/.hard/20260913-plugin-phase2/artifacts/test-reverse-matrix-v2.md`` §4（EN1–EN8）；
- EN1 四验收点（思齐 §1.5）：``waits_in_flight`` 增减平衡（finally 兜底）/
  ``wait_ms_max`` 单调 / ``reset()`` 全清零 / 无订阅零开销不变；
- 实现：``server/plugin/stations.py``（观测面：``stats()`` 的
  ``gauges`` / ``timing`` / ``progress`` 区块）。

状态：EN1 先行部分（基于 M2 末实现现状；M3 落盘后统一复跑 + 补 EN2–EN8）。
运行：cd server && .venv\Scripts\python -m pytest tests\test_plugin_engineering.py -q
"""

from __future__ import annotations

import os
import threading
import time
import unittest

from plugin.registry import PluginRegistry
from plugin.stations import STATION_READ_RESULT, StationsHub
from plugin.watchdog import ProgressWatchdog

# 真实接入站位（read 结果站）
SID = STATION_READ_RESULT


def scope_of(user="u1", team="t1", agent="a1", session="s1"):
    """构造四元组 scope（默认全字段非空）。"""
    return {
        "user_id": user,
        "team_id": team,
        "agent_id": agent,
        "session_id": session,
    }


class EngineeringTestBase(unittest.TestCase):
    """独立组件 + 缩参环境；tearDown 恢复 env 并清理订阅/实例。"""

    _ENV = {
        "PLUGIN_STATION_WAIT_SLICE_S": "0.02",
        "PLUGIN_STATION_BEAT_INTERVAL_S": "0.05",
    }

    def setUp(self):
        self._saved_env = {}
        for key, value in self._ENV.items():
            self._saved_env[key] = os.environ.get(key)
            os.environ[key] = value
        self.reg = PluginRegistry()
        self.hub = StationsHub(self.reg, watchdog=ProgressWatchdog())

    def tearDown(self):
        for key, old in self._saved_env.items():
            if old is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = old
        try:
            self.hub.reset()
        except Exception:
            pass
        for inst in self.reg.instances():
            try:
                self.reg.unregister(inst)
            except Exception:
                pass

    # ------------------------------------------------------------------
    # 辅助
    # ------------------------------------------------------------------
    def subscribe(self, handler, *, plugin="p1", granularity="agent",
                  scope=None, **kw):
        return self.hub.subscribe(
            SID, plugin, handler,
            granularity=granularity, scope=scope or scope_of(), **kw
        )

    def obs(self):
        """观测面快照（gauges / timing / progress）。"""
        s = self.hub.stats()
        return {
            "gauges": dict(s["gauges"]),
            "timing": dict(s["timing"]),
            "progress": dict(s["progress"]),
        }

    def wait_until(self, predicate, timeout=2.0, interval=0.01):
        """轮询直到条件为真（测试时限内）。"""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            time.sleep(interval)
        return predicate()


# ======================================================================
# EN1：观测增强（键齐备 / 平衡 / 单调 / 清零 / 零开销）
# ======================================================================
class TestEN1Observability(EngineeringTestBase):

    def test_en1_stats_keys_schema(self):
        """EN1-a：观测键齐备、类型正确、初始为零。"""
        s = self.hub.stats()
        g, t, p = s["gauges"], s["timing"], s["progress"]
        self.assertIn("waits_in_flight", g)
        self.assertIsInstance(g["waits_in_flight"], int)
        self.assertEqual(g["waits_in_flight"], 0)
        for key in ("wait_ms_total", "wait_ms_max"):
            self.assertIn(key, t)
            self.assertIsInstance(t[key], (int, float))
        self.assertEqual(t["wait_ms_total"], 0.0)
        self.assertEqual(t["wait_ms_max"], 0.0)
        for key in ("runs_registered", "runs_finished"):
            self.assertIn(key, p)
        self.assertEqual(p["runs_registered"], 0)
        self.assertEqual(p["runs_finished"], 0)

    def test_en1_waits_in_flight_balanced(self):
        """EN1-b：等待在飞 ±平衡（等待期 1 → 完成后 0；finally 兜底）。"""
        entered = threading.Event()
        release = threading.Event()

        def handler(req):
            entered.set()
            release.wait(2.0)
            return "R"

        self.assertTrue(self.subscribe(handler))
        out = {}

        def run():
            out["r"] = self.hub.process(SID, "x", scope_of(), timeout_s=3.0)

        th = threading.Thread(target=run)
        th.start()
        try:
            self.assertTrue(entered.wait(2.0), "handler 未进入")
            self.assertTrue(
                self.wait_until(
                    lambda: self.hub.stats()["gauges"]["waits_in_flight"] == 1
                ),
                "等待期 gauges.waits_in_flight 应为 1",
            )
            release.set()
            th.join(3.0)
            self.assertEqual(out.get("r"), "R")
            self.assertTrue(
                self.wait_until(
                    lambda: self.hub.stats()["gauges"]["waits_in_flight"] == 0
                ),
                "完成后 waits_in_flight 应回 0（finally）",
            )
        finally:
            release.set()
            th.join(3.0)

    def test_en1_waits_balanced_on_timeout(self):
        """EN1-b2：超时分支 finally 兜底——超时放行后 waits 回 0（迟到回填不影响）。"""
        release = threading.Event()

        def handler(req):
            release.wait(2.0)
            return "LATE"

        self.assertTrue(self.subscribe(handler))
        try:
            r = self.hub.process(SID, "x", scope_of(), timeout_s=0.1)
            self.assertEqual(r, "x", "超时应放行原值")
            self.assertTrue(
                self.wait_until(
                    lambda: self.hub.stats()["gauges"]["waits_in_flight"] == 0
                ),
                "超时后 waits_in_flight 应回 0",
            )
            self.assertGreaterEqual(self.hub.stats()["counts"]["timeout"], 1)
        finally:
            release.set()

    def test_en1_wait_ms_max_monotonic_and_total(self):
        """EN1-c：wait_ms_max 单调不减、wait_ms_total 累计。"""

        def slow(req):
            time.sleep(0.06)
            return "S"

        self.assertTrue(self.subscribe(slow))
        self.hub.process(SID, "a", scope_of(), timeout_s=2.0)
        t1 = self.hub.stats()["timing"]
        self.assertGreater(t1["wait_ms_max"], 0.0)
        self.assertGreaterEqual(t1["wait_ms_total"], t1["wait_ms_max"] - 1e-6)
        # 峰值应接近慢等待（≥50ms；宽松下界防抖动）
        self.assertGreaterEqual(t1["wait_ms_max"], 50.0)

        # 第二次再次等待：max 不减、total 不降
        self.hub.process(SID, "b", scope_of(), timeout_s=2.0)
        t2 = self.hub.stats()["timing"]
        self.assertGreaterEqual(t2["wait_ms_max"], t1["wait_ms_max"])
        self.assertGreaterEqual(t2["wait_ms_total"], t1["wait_ms_total"])

    def test_en1_reset_clears_all(self):
        """EN1-d：reset() 全清零（订阅 / 计数 / 观测）。"""
        self.assertTrue(self.subscribe(lambda req: "R"))
        self.hub.process(SID, "x", scope_of(), timeout_s=1.0)
        self.assertGreater(self.hub.stats()["counts"]["requests"], 0)
        self.hub.reset()
        s = self.hub.stats()
        self.assertEqual(s["subscription_count"], 0)
        self.assertEqual(s["subscriptions"], [])
        self.assertTrue(all(v == 0 for v in s["counts"].values()))
        self.assertEqual(s["gauges"]["waits_in_flight"], 0)
        self.assertEqual(s["timing"]["wait_ms_total"], 0.0)
        self.assertEqual(s["timing"]["wait_ms_max"], 0.0)
        self.assertEqual(s["progress"]["runs_registered"], 0)
        self.assertEqual(s["progress"]["runs_finished"], 0)

    def test_en1_no_subscription_zero_overhead(self):
        """EN1-e：无订阅零开销——连续调用后观测面 / 计数均不变。"""
        before_c = dict(self.hub.stats()["counts"])
        before_o = self.obs()
        for _ in range(50):
            self.assertEqual(self.hub.process(SID, "x", scope_of()), "x")
        self.assertEqual(dict(self.hub.stats()["counts"]), before_c)
        self.assertEqual(self.obs(), before_o)


if __name__ == "__main__":
    unittest.main()
