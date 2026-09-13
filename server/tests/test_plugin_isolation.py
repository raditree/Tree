# -*- coding: utf-8 -*-
"""插件化埋点体系一期 —— 隔离专项测试（隔离验证矩阵 P1–P4 / N1–N6 / C1–C4 / 出站）。

对应实现（栖迟 `server/plugin/`，已按实际接口对齐 v2）：
    bus.py        EventBus / PluginEvent / make_scope / Subscription
    registry.py   PluginRegistry / PluginInstance / scope_key / GRANULARITY_FIELDS
    watchdog.py   ProgressWatchdog（时间可注入：is_stalled(now=...)）
    sdk.py        PluginSDK（出站 fail-closed 校验 + 依赖注入点）

矩阵来源：
- ``artifacts/test-plan.md``《隔离验证矩阵》（知遥）
- ``artifacts/interface-contract.md`` v1（观澜）— 行为判定标准；实现差异见
  ``artifacts/test-report.md`` 差距清单（联调阶段逐项评审）。

联调对齐点（v2，已对齐）：本文件仅依赖上述公共 API；实现如再调整命名，只需修改
"接口导入区"与 ``_make_env``。

执行（server 目录下）：
    .venv\\Scripts\\python -m pytest tests/test_plugin_isolation.py -v
"""

import sys
import time
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

try:
    import plugin.sdk as sdk_mod  # noqa: E402
    from plugin.bus import EventBus, PluginEvent, make_scope  # noqa: E402
    from plugin.registry import PluginInstance, PluginRegistry  # noqa: E402
    from plugin.sdk import PluginSDK  # noqa: E402
    from plugin.watchdog import ProgressWatchdog  # noqa: E402

    PLUGIN_AVAILABLE = True
    IMPORT_ERROR = ""
except Exception as _e:  # noqa: BLE001 —— 模块未就绪时整文件 skip（联调前正常）
    EventBus = PluginEvent = PluginRegistry = PluginInstance = None  # type: ignore
    PluginSDK = ProgressWatchdog = sdk_mod = None  # type: ignore
    PLUGIN_AVAILABLE = False
    IMPORT_ERROR = f"{type(_e).__name__}: {_e}"

_SKIP_REASON = f"server/plugin 未就绪: {IMPORT_ERROR}"

_WAIT_TIMEOUT = 3.0  # 异步投递等待上限（秒）
_NEGATIVE_WINDOW = 0.35  # 反例"无投递"观察窗口（秒）


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


def _settle(seconds=_NEGATIVE_WINDOW):
    time.sleep(seconds)


def _make_env():
    """组装 bus/registry/watchdog（各用例独立，互不串扰）。"""
    bus = EventBus()
    watchdog = ProgressWatchdog()
    registry = PluginRegistry(bus=bus, watchdog=watchdog)
    bus.start()
    return bus, registry, watchdog


def _recorder(calls):
    def handler(event):
        calls.append(event)

    return handler


def _noop_handler(event):
    return None


@unittest.skipUnless(PLUGIN_AVAILABLE, _SKIP_REASON)
class _PluginCase(unittest.TestCase):
    def setUp(self):
        self.bus, self.registry, self.watchdog = _make_env()

    def tearDown(self):
        self.registry.shutdown()
        self.bus.stop()


# --------------------------------------------------------------------------
# P1–P4 正例：本 scope 投递 / 实例隔离创建与复用
# --------------------------------------------------------------------------

class TestScopePositive(_PluginCase):
    def test_p1_team_scope_delivery(self):
        """P1：team 级实例接收本团队事件（内容完整、scope 一致）。"""
        calls = []
        self.registry.register(
            "test.iso.p1", _recorder(calls),
            granularity="team", scope=_scope("u1", "t1"),
            event_types={"test.event.p1"},
        )
        self.assertTrue(
            self.bus.publish("test.event.p1", _scope("u1", "t1"), {"n": 1}, source="test")
        )
        self.assertTrue(_wait_until(lambda: len(calls) >= 1), "事件未投递到 team 实例")
        event = calls[0]
        self.assertEqual(event.type, "test.event.p1")
        self.assertEqual(event.payload.get("n"), 1)
        self.assertEqual(event.scope["user_id"], "u1")
        self.assertEqual(event.scope["team_id"], "t1")

    def test_p2_session_scope_delivery(self):
        """P2：session 级实例接收本会话事件（细粒度声明生效）。"""
        calls = []
        self.registry.register(
            "test.iso.p2", _recorder(calls),
            granularity="session", scope=_scope("u1", "t1", "a1", "s1"),
            event_types={"test.event.p2"},
        )
        self.assertTrue(
            self.bus.publish("test.event.p2", _scope("u1", "t1", "a1", "s1"), {}, source="test")
        )
        self.assertTrue(_wait_until(lambda: len(calls) >= 1), "事件未投递到 session 实例")

    def test_p4_instances_isolated_per_scope_and_reused(self):
        """P4：实例按 scope 区分（互不同一对象）；同 scope 重复注册复用同一实例。"""
        inst_t1 = self.registry.register(
            "test.iso.p4", _noop_handler, granularity="team", scope=_scope("u1", "t1")
        )
        inst_t2 = self.registry.register(
            "test.iso.p4", _noop_handler, granularity="team", scope=_scope("u1", "t2")
        )
        inst_t1b = self.registry.register(
            "test.iso.p4", _noop_handler, granularity="team", scope=_scope("u1", "t1")
        )
        self.assertIsNot(inst_t1, inst_t2, "不同 scope 的实例不应是同一对象")
        self.assertIs(inst_t1, inst_t1b, "同 scope 注册应复用同一实例")
        self.assertEqual(self.registry.count(), 2)


# --------------------------------------------------------------------------
# 出站 SDK（fail-closed 第二防线）：本 scope 通过 / 越权拒绝
# --------------------------------------------------------------------------

class TestOutboundSDK(_PluginCase):
    def setUp(self):
        super().setUp()
        self.sent_ws = []
        self.dispatched = []
        self.logs = []

        def _fake_ws(user_id, message):
            self.sent_ws.append((user_id, message))
            return True

        def _fake_dispatch(**kwargs):
            self.dispatched.append(kwargs)
            return {"sent": ["ok"]}

        def _fake_log(**kwargs):
            self.logs.append(kwargs)

        sdk_mod.set_ws_sender(_fake_ws)
        sdk_mod.set_dispatcher(_fake_dispatch)
        sdk_mod.set_log_fn(_fake_log)
        self.addCleanup(sdk_mod.reset_injections)

    def test_p3_outbound_self_scope_passes(self):
        """P3：本 scope 出站通过校验，且 user_id 一律取自实例 scope。"""
        sdk = PluginSDK(_scope("u1", "t1", "a1"))
        self.assertTrue(sdk.ws_push({"type": "plugin_event", "data": {"k": 1}}))
        self.assertEqual(self.sent_ws[0][0], "u1")
        self.assertTrue(sdk.activity_log("hello"))
        self.assertEqual(self.logs[0]["user_id"], "u1")
        res = sdk.dispatch_agent_message(["a1"], "hi")
        self.assertNotIn("error", res, res)

    def test_outbound_workspace_whitelist_enforced(self):
        """出站反例：workspace_id 不在实例 scope 白名单（agent_id/team_id）→ 拒绝。"""
        sdk = PluginSDK(_scope("u1", "t1", "a1"))
        res = sdk.workspace_read("x.txt", workspace_id="other-ws")
        self.assertIn("error", res, res)
        res2 = sdk.workspace_write("x.txt", "c", workspace_id="other-ws")
        self.assertIn("error", res2, res2)
        # 白名单内（agent_id）不因归属校验被拒（底层可达性不在本断言范围）
        res3 = sdk.activity_log("x", workspace_id="a1")
        self.assertTrue(res3)
        self.assertEqual(self.logs[-1]["workspace_id"], "a1")

    def test_outbound_missing_user_rejected(self):
        """出站反例：实例 scope 缺 user_id → 一律拒绝（不能证明归属）。"""
        sdk = PluginSDK({"team_id": "t1"})
        self.assertFalse(sdk.ws_push({"type": "plugin_event"}))
        res = sdk.dispatch_agent_message(["a1"], "hi")
        self.assertIn("error", res, res)


# --------------------------------------------------------------------------
# N1–N4 反例：四类越权（跨 user / team / agent / session 必须不投递）
# --------------------------------------------------------------------------

class TestScopeViolationsNotDelivered(_PluginCase):
    def _make_instance(self, plugin_id, granularity, scope):
        calls = []
        self.registry.register(
            plugin_id, _recorder(calls),
            granularity=granularity, scope=scope,
            event_types={f"test.event.{plugin_id}"},
        )
        return calls

    def test_n1_cross_user(self):
        """N1：userB 的事件不得投递给 userA 的实例。"""
        calls = self._make_instance("test.iso.n1", "team", _scope("uA", "t1"))
        before = self.bus.stats().get("dispatched", 0)
        self.assertTrue(self.bus.publish("test.event.test.iso.n1", _scope("uB", "t1"), {}, source="test"))
        _settle()
        self.assertEqual(len(calls), 0, "跨 user 事件被错误投递")
        self.assertEqual(self.bus.stats().get("dispatched", 0), before)

    def test_n2_cross_team(self):
        """N2：同 user 异团队的事件不得投递给 T1 实例。"""
        calls = self._make_instance("test.iso.n2", "team", _scope("u1", "t1"))
        before = self.bus.stats().get("dispatched", 0)
        self.assertTrue(self.bus.publish("test.event.test.iso.n2", _scope("u1", "t2"), {}, source="test"))
        _settle()
        self.assertEqual(len(calls), 0, "跨 team 事件被错误投递")
        self.assertEqual(self.bus.stats().get("dispatched", 0), before)

    def test_n3_cross_agent(self):
        """N3：同团队异成员的事件不得投递给 agent 级实例（非空层级须全等）。"""
        calls = self._make_instance("test.iso.n3", "agent", _scope("u1", "t1", "a1"))
        before = self.bus.stats().get("dispatched", 0)
        self.assertTrue(self.bus.publish("test.event.test.iso.n3", _scope("u1", "t1", "a2"), {}, source="test"))
        _settle()
        self.assertEqual(len(calls), 0, "跨 agent 事件被错误投递")
        self.assertEqual(self.bus.stats().get("dispatched", 0), before)

    def test_n4_cross_session(self):
        """N4：同 agent 不同会话的事件不得投递给 session 级实例。"""
        calls = self._make_instance("test.iso.n4", "session", _scope("u1", "t1", "a1", "s1"))
        before = self.bus.stats().get("dispatched", 0)
        self.assertTrue(self.bus.publish("test.event.test.iso.n4", _scope("u1", "t1", "a1", "s2"), {}, source="test"))
        _settle()
        self.assertEqual(len(calls), 0, "跨 session 事件被错误投递")
        self.assertEqual(self.bus.stats().get("dispatched", 0), before)


# --------------------------------------------------------------------------
# N5–N6 fail-closed 强化：越权续期 / scope 缺失
# --------------------------------------------------------------------------

class TestFailClosed(_PluginCase):
    def test_n5_cross_scope_progress_rejected(self):
        """N5：看门狗续期 fail-closed——跨归属 / 无归属 / 结束后一律拒绝。"""
        task_key = "plugin:test.iso.n5:u1:t1"
        owner_a = ("u1", "t1")
        owner_b = ("u1", "t2")
        self.watchdog.start_task(task_key, owner=owner_a)

        self.assertFalse(self.watchdog.beat(task_key, owner=owner_b), "跨归属续期必须拒绝")
        self.assertFalse(self.watchdog.beat(task_key, owner=None), "无归属证明必须拒绝")
        self.assertFalse(self.watchdog.beat("plugin:unknown:task", owner=owner_a), "未知任务必须拒绝")
        self.assertTrue(self.watchdog.beat(task_key, owner=owner_a), "本归属续期应被接受")
        self.assertFalse(self.watchdog.finish_task(task_key, owner=owner_b), "跨归属完成必须拒绝")
        self.assertTrue(self.watchdog.finish_task(task_key, owner=owner_a))
        self.assertFalse(self.watchdog.beat(task_key, owner=owner_a), "结束后续期必须拒绝")

    def test_n6_missing_required_fields_rejected(self):
        """N6：type 或 scope.user_id 缺失 → 拒绝发布（dropped_invalid 计数）。"""
        stats = self.bus.stats()
        before = stats.get("dropped_invalid", 0)
        self.assertFalse(self.bus.publish("", _scope("u1", "t1"), {}, source="test"), "缺 type 应拒绝")
        self.assertFalse(self.bus.publish("test.event.n6", {"team_id": "t1"}, {}, source="test"), "缺 user_id 应拒绝")
        self.assertFalse(self.bus.publish("test.event.n6", None, {}, source="test"), "scope 缺失应拒绝")
        after = self.bus.stats().get("dropped_invalid", 0)
        self.assertGreaterEqual(after - before, 3, f"dropped_invalid 计数未增加: {before}->{after}")

    def test_n6b_missing_team_id_not_delivered(self):
        """N6b：缺 team_id 的发布当前不被入口拒绝（记录：契约要求必填），
        但事件不会被带 team 归属的实例接收（匹配层 fail-closed）。

        差异项 N6b（见 test-report 差距清单）：实现入口仅校验 user_id。
        """
        calls = self._make_team_instance("test.iso.n6b")
        # 当前实现：入队成功（不拒绝）——若评审后收紧入口校验，此处应改为 assertFalse
        res = self.bus.publish("test.event.test.iso.n6b", {"user_id": "u1"}, {}, source="test")
        self.assertTrue(res, "当前实现接受缺 team_id 的发布（差异 N6b）")
        _settle()
        self.assertEqual(len(calls), 0, "缺 team_id 事件不应被团队实例接收（匹配层）")

    def _make_team_instance(self, plugin_id):
        calls = []
        self.registry.register(
            plugin_id, _recorder(calls),
            granularity="team", scope=_scope("u1", "t1"),
            event_types={f"test.event.{plugin_id}"},
        )
        return calls


# --------------------------------------------------------------------------
# C1–C4 级联清理 / 生命周期
# --------------------------------------------------------------------------

class TestCascadeCleanup(_PluginCase):
    def _register(self, plugin_id, granularity, scope, **kwargs):
        return self.registry.register(
            plugin_id, _noop_handler, granularity=granularity, scope=scope, **kwargs
        )

    def test_c1_session_delete_only_own_scope(self):
        """C1：session 级联——仅销毁该会话的 session 级实例；兄弟会话与 team 级不受影响。"""
        inst_t = self._register("test.iso.c1t", "team", _scope("u1", "t1"))
        inst_s1 = self._register("test.iso.c1s", "session", _scope("u1", "t1", "a1", "s1"))
        inst_s2 = self._register("test.iso.c1s", "session", _scope("u1", "t1", "a1", "s2"))

        removed = self.registry.cleanup_scope(user_id="u1", agent_id="a1", session_id="s1")
        self.assertEqual(removed, 1, "session 级联应恰好销毁 1 个实例")
        self.assertIsNone(self.registry.get(inst_s1.instance_key()))
        self.assertIsNotNone(self.registry.get(inst_s2.instance_key()))
        self.assertIsNotNone(self.registry.get(inst_t.instance_key()))

    def test_c2_agent_removal_cascades_its_sessions(self):
        """C2：agent 级联——该 agent 的 agent 级 + 其全部 session 级实例销毁；其他 agent 不受影响。"""
        inst_a1 = self._register("test.iso.c2a", "agent", _scope("u1", "t1", "a1"))
        inst_a1s1 = self._register("test.iso.c2s", "session", _scope("u1", "t1", "a1", "s1"))
        inst_a1s2 = self._register("test.iso.c2s", "session", _scope("u1", "t1", "a1", "s2"))
        inst_a2s3 = self._register("test.iso.c2s", "session", _scope("u1", "t1", "a2", "s3"))

        removed = self.registry.cleanup_scope(user_id="u1", agent_id="a1")
        self.assertGreaterEqual(removed, 3, "a1 的 agent 级+两个 session 级实例均应销毁")
        self.assertIsNone(self.registry.get(inst_a1.instance_key()))
        self.assertIsNone(self.registry.get(inst_a1s1.instance_key()))
        self.assertIsNone(self.registry.get(inst_a1s2.instance_key()))
        self.assertIsNotNone(
            self.registry.get(inst_a2s3.instance_key()), "其他 agent 的实例被误伤"
        )

    def test_c3_team_dissolve_removes_all(self):
        """C3：团队级联——该团队全部实例销毁；其他团队不受影响（无残留）。"""
        inst_t1 = self._register("test.iso.c3", "team", _scope("u1", "t1"))
        inst_t1s = self._register("test.iso.c3s", "session", _scope("u1", "t1", "a1", "s1"))
        inst_t2 = self._register("test.iso.c3", "team", _scope("u1", "t2"))

        removed = self.registry.cleanup_scope(user_id="u1", team_id="t1")
        self.assertGreaterEqual(removed, 2, "t1 的实例均应销毁")
        self.assertIsNone(self.registry.get(inst_t1.instance_key()))
        self.assertIsNone(self.registry.get(inst_t1s.instance_key()))
        self.assertIsNotNone(
            self.registry.get(inst_t2.instance_key()), "其他团队实例被误伤"
        )

    def test_c4_ttl_and_pin(self):
        """C4：空闲 TTL 逐出（时间注入）；Pin 实例不参与逐出。"""
        inst = self._register("test.iso.c4", "team", _scope("u1", "t1"), idle_ttl=100.0)
        inst_pin = self._register(
            "test.iso.c4pin", "team", _scope("u1", "t5"), pin=True, idle_ttl=100.0
        )
        future = time.time() + 101.0

        stale = self.registry.collect_stale(now=future)
        self.assertIn(inst, stale, "空闲超时的非 Pin 实例应被收集")
        self.assertNotIn(inst_pin, stale, "Pin 实例不应被收集")

        removed = self.registry.cleanup_stale(now=future)
        self.assertEqual(removed, 1, "恰应清理 1 个（非 Pin）实例")
        self.assertIsNone(self.registry.get(inst.instance_key()))
        self.assertIsNotNone(self.registry.get(inst_pin.instance_key()), "Pin 实例被误清理")

        # 未到期不清理（within TTL）
        inst2 = self._register("test.iso.c4b", "team", _scope("u1", "t6"), idle_ttl=100.0)
        self.assertEqual(self.registry.cleanup_stale(now=time.time() + 1.0), 0)
        self.assertIsNotNone(self.registry.get(inst2.instance_key()))


if __name__ == "__main__":
    unittest.main()
