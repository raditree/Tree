r"""二期 M1 专项：plugin_status 事件 × 快照对账（独立验证 · 矩阵 EV1–EV7/CP5）。

独立性：与实现方自测（test_plugin_status.py / test_plugin_snapshot.py）互补——
本文件从 **序列 / 隔离 / 风暴 / 双源对账 / 默认通道降级 / schema** 角度独立验证：
- EV1 多用户单播隔离 + 事件字段 schema；
- EV2 destroyed 事件 scope 抓拍完整性（销毁后仍可解析归属）；
- EV3 生命周期全序列单调（含窗口内快速重注册边界，记录性）；
- EV4 风暴有界（批量逐出 → emitted/throttled 有界、窗口恢复）；
- EV6 双源对账（快照=基准 ↔ 事件=增量，最终一致）；
- EV5/EV7 默认发送通道不可用 → 静默降级（send_failed）且主流程无感；
- CP5 快照字段最小集（类型级 schema）。

运行：cd server && .venv\Scripts\python -m pytest tests\test_plugin_status_events.py -q
"""

from __future__ import annotations

import time
import unittest
from typing import Any, Dict, List, Tuple

from plugin import sdk as sdk_mod
from plugin.registry import PluginRegistry
from plugin.snapshot import build_snapshot
from plugin.status import (
    StatusEmitter,
    emit_status,
    get_status_emitter,
    set_status_emitter,
)


def scope_of(user="u1", team="t1", agent="a1", session="s1"):
    """构造四元组 scope。"""
    return {
        "user_id": user,
        "team_id": team,
        "agent_id": agent,
        "session_id": session,
    }


class CaptureSender:
    """捕获型 sender：记录 (user_id, message)。"""

    def __init__(self) -> None:
        self.messages: List[Tuple[str, Dict[str, Any]]] = []

    def __call__(self, user_id: str, message: Dict[str, Any]) -> bool:
        self.messages.append((user_id, message))
        return True


class EventsTestBase(unittest.TestCase):
    """独立 registry + 假时钟 + 捕获 sender + 全局替换/还原。"""

    def setUp(self):
        self._orig_emitter = get_status_emitter()
        self._orig_ws_sender = getattr(sdk_mod, "_ws_sender", None)
        self._orig_bound_loop = getattr(sdk_mod, "_bound_loop", None)
        self.cap = CaptureSender()
        self.clock = {"t": 10_000.0}
        self.em = StatusEmitter(
            dedup_s=1.0,
            max_per_sec=100,
            rate_window_s=1.0,
            time_fn=lambda: self.clock["t"],
            sender=self.cap,
        )
        set_status_emitter(self.em)
        self.reg = PluginRegistry()

    def tearDown(self):
        for inst in self.reg.instances():
            try:
                self.reg.unregister(inst)
            except Exception:  # noqa: BLE001
                pass
        set_status_emitter(self._orig_emitter)
        sdk_mod._ws_sender = self._orig_ws_sender
        sdk_mod._bound_loop = self._orig_bound_loop

    def _register(
        self,
        plugin_id="demo",
        user="u1",
        team="t1",
        agent="a1",
        session="s1",
    ):
        return self.reg.register(
            plugin_id,
            lambda e: None,
            granularity="agent",
            scope=scope_of(user, team, agent, session),
        )

    def _statuses(self) -> List[str]:
        return [m["data"]["status"] for _, m in self.cap.messages]


class TestLifecycleEvents(EventsTestBase):
    def test_full_sequence_monotonicity(self):
        """EV3：registered → destroyed →（窗口外重注册）registered，序列完整无回退。"""
        inst = self._register("demo.a")
        self.reg.unregister(inst)
        self.clock["t"] += 2.0  # 等间隔推进假钟（跃迁语义明细见 rapid 用例）
        inst2 = self._register("demo.a")
        self.assertEqual(self._statuses(), ["registered", "destroyed", "registered"])
        self.assertIsNot(inst, inst2)

    def test_rapid_reregister_transition_emits(self):
        """EV3 边界（跃迁必发 · 栖迟裁定①，2026-09-13）：窗口内
        registered→destroyed→registered 三发齐全（跃迁重置窗口）；
        连续同状态（同实例键）仍受去重约束。"""
        inst = self._register("demo.f")
        self.reg.unregister(inst)
        inst2 = self._register("demo.f")
        self.assertEqual(
            self._statuses(), ["registered", "destroyed", "registered"]
        )
        self.assertEqual(self.em.stats()["deduped"], 0)
        self.assertIsNot(inst, inst2)
        # 连续同状态仍去重（同实例键直接经门面补发 registered）：
        emit_status(
            "demo.f", scope_of(), "registered", inst_key=inst2.instance_key()
        )
        self.assertEqual(self.em.stats()["deduped"], 1)

    def test_destroyed_scope_snapshot_integrity(self):
        """EV2：销毁事件 scope 与注册时逐字段一致（销毁后可解析归属）。"""
        inst = self._register(
            "demo.b", user="u9", team="t9", agent="a9", session="s9"
        )
        self.cap.messages.clear()
        self.reg.unregister(inst)
        self.assertEqual(len(self.cap.messages), 1)
        _, msg = self.cap.messages[0]
        d = msg["data"]
        self.assertEqual(d["status"], "destroyed")
        self.assertEqual(d["plugin_id"], "demo.b")
        self.assertEqual(d["scope"], scope_of("u9", "t9", "a9", "s9"))

    def test_multi_user_unicast_isolation(self):
        """EV1：多用户实例 → 事件按 scope.user_id 单播（各发各，不串）。"""
        self._register("pa", user="u1")
        self._register("pb", user="u2")
        pairs = [(u, m["data"]["plugin_id"]) for u, m in self.cap.messages]
        self.assertEqual(pairs, [("u1", "pa"), ("u2", "pb")])

    def test_event_field_schema(self):
        """EV1：消息形状与字段 schema（type/data、ts 墙钟合理、reason 缺省空）。"""
        self._register("demo.c")
        self.assertEqual(len(self.cap.messages), 1)
        _, msg = self.cap.messages[0]
        self.assertEqual(msg["type"], "plugin_status")
        d = msg["data"]
        for key in ("plugin_id", "scope", "status", "reason", "ts"):
            self.assertIn(key, d)
        self.assertEqual(d["status"], "registered")
        self.assertEqual(d["reason"], "")
        self.assertLess(abs(float(d["ts"]) - time.time()), 30.0)


class TestStormBounded(EventsTestBase):
    def test_storm_bounded_then_recovers(self):
        """EV4：批量逐出风暴 → 发射有界（emitted 受限 / throttled 计数）；窗口滚过恢复。"""
        self.em = StatusEmitter(
            dedup_s=0.1,
            max_per_sec=5,
            rate_window_s=1.0,
            time_fn=lambda: self.clock["t"],
            sender=self.cap,
        )
        set_status_emitter(self.em)
        n = 20
        for i in range(n):
            self._register(f"p{i:02d}", agent=f"a{i}")
        emitted = self.em.stats()["emitted"]
        self.assertLessEqual(emitted, 5)
        self.assertEqual(len(self.cap.messages), emitted)
        self.assertGreaterEqual(self.em.stats()["throttled"], n - 5)
        # 批量逐出（同窗口内）：全部被限频（不风暴）
        self.cap.messages.clear()
        removed = self.reg.cleanup_stale(now=time.time() + 10**7)
        self.assertEqual(removed, n)
        self.assertEqual(self.cap.messages, [])
        self.assertGreaterEqual(self.em.stats()["throttled"], (n - 5) + n)
        self.assertEqual(self.reg.instances(), [])
        # 窗口滚过 → 恢复正常发射
        self.clock["t"] += 1.2
        self._register("p-new", agent="an")
        self.assertEqual(len(self.cap.messages), 1)
        self.assertEqual(self._statuses(), ["registered"])


class TestDoubleSourceReconciliation(EventsTestBase):
    def test_snapshot_event_consistency(self):
        """EV6：快照=基准 ↔ 事件=增量，最终一致（注册×2 → 注销×1 三步对账）。"""
        s0 = build_snapshot(enabled=True, user_id="u1", registry=self.reg)
        self.assertEqual(s0["instances"], [])
        i1 = self._register("r1", agent="a1")
        self._register("r2", agent="a2")
        self.assertEqual(self._statuses(), ["registered", "registered"])
        s1 = build_snapshot(enabled=True, user_id="u1", registry=self.reg)
        self.assertEqual(
            sorted(i["plugin_id"] for i in s1["instances"]), ["r1", "r2"]
        )
        self.reg.unregister(i1)
        s2 = build_snapshot(enabled=True, user_id="u1", registry=self.reg)
        self.assertEqual([i["plugin_id"] for i in s2["instances"]], ["r2"])
        # 事件增量与快照变化不矛盾（无丢失路径下逐条一致）
        self.assertEqual(len(self.cap.messages), 3)
        self.assertEqual(
            self._statuses(), ["registered", "registered", "destroyed"]
        )


class TestDefaultChannelDegraded(EventsTestBase):
    def test_default_sender_unavailable_fails_open(self):
        """EV5/EV7：默认通道不可用（无注入/无 loop）→ send_failed、不抛；主流程无感。"""
        sdk_mod._ws_sender = None
        sdk_mod._bound_loop = None
        self.em = StatusEmitter(
            dedup_s=1.0,
            max_per_sec=10,
            sender=None,  # 走默认 sdk 通道
            time_fn=lambda: self.clock["t"],
        )
        set_status_emitter(self.em)
        inst = self._register("demo.d")
        self.assertEqual(self.em.stats()["send_failed"], 1)
        self.assertEqual(self.em.stats()["emitted"], 0)
        self.assertEqual(len(self.reg.instances()), 1)
        self.assertIsNotNone(inst)


class TestSnapshotSchema(EventsTestBase):
    def test_field_schema_and_types(self):
        """CP5：快照字段最小集类型级 schema + status 枚举 + config 键集。"""
        self._register("demo.e")
        snap = build_snapshot(
            enabled=True, user_id="u1", team_id="t1", registry=self.reg
        )
        self.assertIsInstance(snap["enabled"], bool)
        self.assertGreater(float(snap["generated_at"]), 0.0)
        row = snap["instances"][0]
        self.assertIsInstance(row["plugin_id"], str)
        self.assertIsInstance(row["name"], str)
        self.assertIn(row["status"], {"registered", "destroyed"})
        self.assertIsInstance(row["scope"], dict)
        self.assertIsInstance(row["queue_depth"], int)
        self.assertIsInstance(row["disabled_reason"], str)
        self.assertIsInstance(snap["watchdog"], dict)
        self.assertIn("active_runs", snap["watchdog"])
        self.assertIn("judged_dead", snap["watchdog"])
        for key in (
            "instance_ttl_s",
            "ttl_sweep_interval_s",
            "station_timeout_s",
            "status_max_per_sec",
        ):
            self.assertIn(key, snap["config"])


if __name__ == "__main__":
    unittest.main()
