r"""plugin_status（二期 M1-a）单元测试。

- 发射器语义：消息形状 / 去重 / 限频 / 计数 / 假时钟确定性（EV4 数据面）；
- registry 触点：register→registered；unregister / cleanup / cascade / shutdown
  →destroyed（含 reason 归因）；
- 全局发射器注入隔离（set_status_emitter + tearDown 还原）。

运行：cd server && .venv\Scripts\python -m pytest tests\test_plugin_status.py -q
"""

from __future__ import annotations

import time
import unittest
from typing import Any, Dict, List, Tuple

from plugin.registry import PluginRegistry
from plugin.status import (
    StatusEmitter,
    get_status_emitter,
    set_status_emitter,
)


def scope_of(user="u1", team="t1", agent="a1", session="s1"):
    """构造四元组 scope（默认全字段非空）。"""
    return {
        "user_id": user,
        "team_id": team,
        "agent_id": agent,
        "session_id": session,
    }


class CaptureSender:
    """捕获型 sender（记录 (user_id, message)；``fail`` 可注入失败）。"""

    def __init__(self) -> None:
        self.messages: List[Tuple[str, Dict[str, Any]]] = []
        self.fail = False

    def __call__(self, user_id: str, message: Dict[str, Any]) -> bool:
        if self.fail:
            return False
        self.messages.append((user_id, message))
        return True


class StatusTestBase(unittest.TestCase):
    """全局发射器注入（假时钟 + 捕获 sender）+ tearDown 还原。"""

    def setUp(self):
        self._orig_emitter = get_status_emitter()
        self.cap = CaptureSender()
        self.clock = {"t": 1000.0}
        self.em = StatusEmitter(
            dedup_s=1.0,
            max_per_sec=3,
            rate_window_s=1.0,
            time_fn=lambda: self.clock["t"],
            sender=self.cap,
        )
        set_status_emitter(self.em)

    def tearDown(self):
        set_status_emitter(self._orig_emitter)

    def statuses(self) -> List[str]:
        return [m["data"]["status"] for _, m in self.cap.messages]


# ======================================================================
# 一、发射器语义（去重 / 限频 / 计数 / 注入）
# ======================================================================
class TestEmitterSemantics(StatusTestBase):

    def test_emit_basic_shape(self):
        """基本发射：单播目标=scope.user_id；消息形状按契约 §8。"""
        ok = self.em.emit("p1", scope_of(), "registered", inst_key="k1")
        self.assertTrue(ok)
        self.assertEqual(len(self.cap.messages), 1)
        user_id, msg = self.cap.messages[0]
        self.assertEqual(user_id, "u1")
        self.assertEqual(msg["type"], "plugin_status")
        d = msg["data"]
        self.assertEqual(d["plugin_id"], "p1")
        self.assertEqual(d["status"], "registered")
        self.assertEqual(d["reason"], "")
        self.assertEqual(d["scope"]["user_id"], "u1")
        self.assertGreater(d["ts"], 0)
        self.assertEqual(self.em.stats()["emitted"], 1)

    def test_missing_user_id_skipped(self):
        """缺 user_id：无法单播 → 跳过 + skipped_no_user 计数。"""
        ok = self.em.emit("p1", {"team_id": "t1"}, "registered", inst_key="k1")
        self.assertFalse(ok)
        self.assertEqual(self.cap.messages, [])
        self.assertEqual(self.em.stats()["skipped_no_user"], 1)

    def test_dedup_same_state_in_window(self):
        """同实例同状态：去重窗口内合并为一次。"""
        self.assertTrue(
            self.em.emit("p1", scope_of(), "registered", inst_key="k1")
        )
        self.assertFalse(
            self.em.emit("p1", scope_of(), "registered", inst_key="k1")
        )
        self.assertEqual(len(self.cap.messages), 1)
        self.assertEqual(self.em.stats()["deduped"], 1)

    def test_dedup_expires_after_window(self):
        """去重窗口过期后同状态可再发。"""
        self.em.emit("p1", scope_of(), "registered", inst_key="k1")
        self.clock["t"] += 1.5
        self.assertTrue(
            self.em.emit("p1", scope_of(), "registered", inst_key="k1")
        )
        self.assertEqual(len(self.cap.messages), 2)

    def test_different_status_not_deduped(self):
        """不同状态互不去重（registered→destroyed 序列完整可见）。"""
        self.em.emit("p1", scope_of(), "registered", inst_key="k1")
        self.assertTrue(
            self.em.emit("p1", scope_of(), "destroyed", inst_key="k1")
        )
        self.assertEqual(len(self.cap.messages), 2)

    def test_transition_requalifies_within_window(self):
        """跃迁必发：registered→destroyed→registered（窗口内）第三发不被吞。"""
        self.em.emit("p1", scope_of(), "registered", inst_key="k1")
        self.em.emit("p1", scope_of(), "destroyed", inst_key="k1")
        self.assertTrue(
            self.em.emit("p1", scope_of(), "registered", inst_key="k1")
        )
        self.assertEqual(
            self.statuses(), ["registered", "destroyed", "registered"]
        )
        self.assertEqual(self.em.stats()["deduped"], 0)

    def test_transition_symmetric_destroyed_requalifies(self):
        """跃迁必发（对称）：destroyed→registered→destroyed 第三发不被吞。"""
        self.em.emit("p1", scope_of(), "destroyed", inst_key="k1")
        self.em.emit("p1", scope_of(), "registered", inst_key="k1")
        self.assertTrue(
            self.em.emit("p1", scope_of(), "destroyed", inst_key="k1")
        )
        self.assertEqual(
            self.statuses(), ["destroyed", "registered", "destroyed"]
        )

    def test_consecutive_same_after_transition_still_deduped(self):
        """跃迁后的连续同状态重复仍去重（防风暴语义不被弱化）。"""
        self.em.emit("p1", scope_of(), "registered", inst_key="k1")
        self.em.emit("p1", scope_of(), "destroyed", inst_key="k1")
        self.em.emit("p1", scope_of(), "registered", inst_key="k1")
        self.assertFalse(
            self.em.emit("p1", scope_of(), "registered", inst_key="k1")
        )
        self.assertEqual(
            self.statuses(), ["registered", "destroyed", "registered"]
        )
        self.assertEqual(self.em.stats()["deduped"], 1)

    def test_rate_limit_throttles(self):
        """速率超限：超出丢弃 + throttled 计数（EV4 风暴语义）。"""
        for i in range(3):
            self.assertTrue(
                self.em.emit("p1", scope_of(), "registered", inst_key=f"k{i}")
            )
        self.assertFalse(
            self.em.emit("p1", scope_of(), "registered", inst_key="k9")
        )
        self.assertEqual(self.em.stats()["throttled"], 1)
        self.assertEqual(len(self.cap.messages), 3)

    def test_rate_window_recovers(self):
        """限频窗口滑过后恢复发射。"""
        for i in range(3):
            self.em.emit("p1", scope_of(), "registered", inst_key=f"k{i}")
        self.clock["t"] += 1.2
        self.assertTrue(
            self.em.emit("p1", scope_of(), "registered", inst_key="kx")
        )

    def test_sender_failure_counted(self):
        """发送失败：计数、不抛（fail-open）。"""
        self.cap.fail = True
        ok = self.em.emit("p1", scope_of(), "registered", inst_key="k1")
        self.assertFalse(ok)
        self.assertEqual(self.em.stats()["send_failed"], 1)

    def test_reset_clears_state(self):
        """reset：计数清零、去重状态清空（可立即重发）。"""
        self.em.emit("p1", scope_of(), "registered", inst_key="k1")
        self.em.reset()
        self.assertEqual(self.em.stats()["emitted"], 0)
        self.assertTrue(
            self.em.emit("p1", scope_of(), "registered", inst_key="k1")
        )


# ======================================================================
# 二、registry 生命周期触点（registered / destroyed + reason）
# ======================================================================
class TestRegistryHooks(StatusTestBase):

    def setUp(self):
        super().setUp()
        self.reg = PluginRegistry()

    def tearDown(self):
        for inst in self.reg.instances():
            try:
                self.reg.unregister(inst)
            except Exception:
                pass
        super().tearDown()

    def _register(self, plugin_id="demo", **kw):
        return self.reg.register(
            plugin_id,
            lambda e: None,
            granularity="agent",
            scope=scope_of(),
            **kw,
        )

    def test_register_emits_registered(self):
        """新建实例 → registered（单条、字段正确）。"""
        self._register()
        self.assertEqual(self.statuses(), ["registered"])
        _, msg = self.cap.messages[0]
        self.assertEqual(msg["data"]["plugin_id"], "demo")
        self.assertEqual(msg["data"]["scope"]["agent_id"], "a1")

    def test_register_reuse_no_duplicate(self):
        """幂等复用注册：不重发（状态未变化）。"""
        self._register()
        self._register()
        self.assertEqual(self.statuses(), ["registered"])

    def test_unregister_emits_destroyed_with_reason(self):
        """注销 → destroyed + reason 透传。"""
        inst = self._register()
        self.cap.messages.clear()
        self.reg.unregister(inst, reason="manual-check")
        self.assertEqual(len(self.cap.messages), 1)
        _, msg = self.cap.messages[0]
        self.assertEqual(msg["data"]["status"], "destroyed")
        self.assertEqual(msg["data"]["reason"], "manual-check")

    def test_cleanup_stale_reason_ttl(self):
        """TTL 逐出 → destroyed(reason=ttl)。"""
        self._register()
        self.cap.messages.clear()
        removed = self.reg.cleanup_stale(now=time.time() + 10**6)
        self.assertEqual(removed, 1)
        self.assertEqual(
            self.cap.messages[0][1]["data"]["reason"], "ttl"
        )

    def test_cascade_reason(self):
        """级联清理 → destroyed(reason=cascade)。"""
        self._register()
        self.cap.messages.clear()
        removed = self.reg.cascade_cleanup("u1", team_id="t1")
        self.assertEqual(removed, 1)
        self.assertEqual(
            self.cap.messages[0][1]["data"]["reason"], "cascade"
        )

    def test_shutdown_reason(self):
        """shutdown → destroyed(reason=shutdown)。"""
        self._register()
        self.cap.messages.clear()
        self.reg.shutdown()
        self.assertEqual(
            self.cap.messages[0][1]["data"]["reason"], "shutdown"
        )
