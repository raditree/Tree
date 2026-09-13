# -*- coding: utf-8 -*-
"""插件体系一期骨架单测：总线 / 注册表 / 看门狗 / SDK / join / 门面。

覆盖（对应 ADR D1-D9 与一期验收标准）：
- 事件信封 / scope 四元组 / fail-closed 过滤（D1/D2/D4）；
- 注册表：幂等注册、scope 匹配、实例内串行处理、TTL/Pin、级联清理（D2/D3）；
- 看门狗：进度续期、fail-closed 归属校验、滑窗判死、实例心跳（D7）；
- SDK：workspace 白名单校验、dispatch（active=False）、ws 注入、日志（D6）；
- join 原语：键值/计数齐备、超时 partial、强制 partial、复用（D5）；
- 门面：总开关关闭零副作用、启用全链路、环境变量开关。
"""

import os
import sys
import time
import unittest
from pathlib import Path
from unittest.mock import patch

# 将 server 目录加入 Python 路径（与既有测试一致）
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import plugin  # noqa: E402
from plugin.bus import (  # noqa: E402
    EventBus,
    Subscription,
    make_scope,
    normalize_scope,
    scope_matches,
)
from plugin.join import JoinBuffer  # noqa: E402
from plugin.registry import PluginRegistry  # noqa: E402
from plugin.sdk import (  # noqa: E402
    PluginSDK,
    reset_injections,
    set_dispatcher,
    set_io_provider,
    set_log_fn,
    set_ws_sender,
)
from plugin.watchdog import ProgressWatchdog  # noqa: E402


def _wait_until(predicate, timeout=3.0, interval=0.02):
    """轮询等待条件成立（测试用，避免固定 sleep 的不稳定）。"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


class TestScope(unittest.TestCase):
    """scope 四元组与匹配语义。"""

    def test_make_and_normalize(self):
        scope = make_scope(user_id="u", team_id="t")
        self.assertEqual(
            scope,
            {"user_id": "u", "team_id": "t", "agent_id": "", "session_id": ""},
        )
        self.assertEqual(normalize_scope(None)["user_id"], "")
        self.assertEqual(normalize_scope({"agent_id": "a"})["agent_id"], "a")

    def test_scope_matches_fail_closed(self):
        # 条件为空 → 任意匹配
        self.assertTrue(scope_matches({}, {"user_id": "u"}))
        # 条件字段相等 → 匹配
        self.assertTrue(
            scope_matches({"user_id": "u"}, {"user_id": "u", "agent_id": "a"})
        )
        # 条件字段不等 → 不匹配
        self.assertFalse(scope_matches({"user_id": "u2"}, {"user_id": "u"}))
        # fail-closed：事件字段为空而条件要求该字段 → 不匹配（不能证明即拒绝）
        self.assertFalse(scope_matches({"session_id": "s1"}, {"user_id": "u"}))


class TestBus(unittest.TestCase):
    """事件总线：校验 / 信封 / 过滤分发 / 队列背压。"""

    def test_publish_requires_user_id(self):
        bus = EventBus()
        self.assertFalse(bus.publish("tool.executed", {"team_id": "t"}))
        self.assertEqual(bus.stats()["dropped_invalid"], 1)
        self.assertFalse(bus.publish("", {"user_id": "u"}))
        self.assertEqual(bus.stats()["dropped_invalid"], 2)
        bus.stop()

    def test_publish_not_started_rejected(self):
        bus = EventBus()
        # 未 start：拒绝入队（不静默悬挂）
        self.assertFalse(bus.publish("tool.executed", {"user_id": "u"}))

    def test_dispatch_filters_and_envelope(self):
        bus = EventBus()
        received = []
        bus.add_subscription(
            Subscription(
                name="s1",
                match_fn=lambda e: e.type == "tool.executed"
                and scope_matches({"user_id": "u1"}, e.scope),
                deliver_fn=lambda e: received.append(e),
            )
        )
        bus.start()
        self.addCleanup(bus.stop)

        self.assertTrue(
            bus.publish("tool.executed", {"user_id": "u1", "agent_id": "a"}, {"k": 1})
        )
        self.assertTrue(_wait_until(lambda: len(received) == 1))
        # 不匹配：不同 user / 不同 type
        self.assertTrue(bus.publish("tool.executed", {"user_id": "u2"}))
        self.assertTrue(bus.publish("other.type", {"user_id": "u1"}))
        time.sleep(0.3)
        self.assertEqual(len(received), 1)

        ev = received[0]
        self.assertEqual(ev.type, "tool.executed")
        self.assertEqual(ev.scope["user_id"], "u1")
        self.assertEqual(ev.scope["agent_id"], "a")
        self.assertEqual(ev.payload, {"k": 1})
        self.assertGreater(ev.seq, 0)
        self.assertTrue(ev.event_id)
        # 信封可序列化
        d = ev.to_dict()
        self.assertEqual(d["type"], "tool.executed")
        self.assertEqual(d["scope"]["user_id"], "u1")

    def test_queue_full_drop_counted(self):
        bus = EventBus(max_queue=1)
        # 白盒：不启动分发线程，仅验证入队与满溢策略（drop_oldest：保最新+计数）
        bus._started = True
        bus._queue.put_nowait(None)  # 占满（队内哨兵应被腾出）
        self.assertTrue(bus.publish("tool.executed", {"user_id": "u"}))
        self.assertEqual(bus.stats()["dropped_full"], 1)
        # 腾出的是最旧一条（None 哨兵），新事件成功入队
        self.assertIsNotNone(bus._queue.get_nowait())
        bus._started = False


class TestRegistry(unittest.TestCase):
    """注册表：注册匹配 / 幂等 / 实例处理 / TTL / 级联清理。"""

    def _mk_scope(self, **kw):
        base = {"user_id": "u", "team_id": "t", "agent_id": "a", "session_id": "s"}
        base.update(kw)
        return base

    def test_register_match_and_unmatch(self):
        reg = PluginRegistry()
        self.addCleanup(reg.shutdown)
        inst = reg.register(
            "p1", lambda e: None, granularity="agent",
            scope={"user_id": "u", "team_id": "t", "agent_id": "a"},
        )
        # 同 user/team/agent 的事件匹配
        self.assertTrue(inst.matches(self._mk_event({"user_id": "u", "team_id": "t", "agent_id": "a"})))
        # 不同 agent 不匹配
        self.assertFalse(inst.matches(self._mk_event({"user_id": "u", "team_id": "t", "agent_id": "a2"})))
        # 不同 user 不匹配
        self.assertFalse(inst.matches(self._mk_event({"user_id": "u2", "team_id": "t", "agent_id": "a"})))
        # 事件无 agent 字段（未知）→ fail-closed 不匹配
        self.assertFalse(inst.matches(self._mk_event({"user_id": "u", "team_id": "t"})))

    def test_duplicate_register_reuses(self):
        reg = PluginRegistry()
        self.addCleanup(reg.shutdown)
        h1 = lambda e: None  # noqa: E731
        h2 = lambda e: None  # noqa: E731
        i1 = reg.register("p", h1, granularity="team", scope={"user_id": "u", "team_id": "t"})
        i2 = reg.register("p", h2, granularity="team", scope={"user_id": "u", "team_id": "t"})
        self.assertIs(i1, i2)
        self.assertIs(i2.handler, h2)  # handler 已更新
        self.assertEqual(reg.count(), 1)
        # 非法粒度 → fail-closed 报错
        with self.assertRaises(ValueError):
            reg.register("p", h1, granularity="invalid", scope={"user_id": "u"})

    def test_concurrent_register_same_key_single_instance(self):
        """D-13/C2：并发注册同键 → 最终只有一个实例（消除孤儿窗口）。

        确定性不变式：无论线程如何交织，互斥区内"检查+插入"保证
        每个线程要么自己插入、要么复用先插入的实例——所有返回值同一对象。
        """
        import threading

        reg = PluginRegistry()
        self.addCleanup(reg.shutdown)
        workers = 6
        barrier = threading.Barrier(workers)
        results = []

        def _worker():
            barrier.wait(timeout=5.0)
            inst = reg.register(
                "p.concurrent",
                lambda e: None,
                granularity="team",
                scope={"user_id": "u", "team_id": "t"},
            )
            results.append(inst)

        threads = [threading.Thread(target=_worker) for _ in range(workers)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=5.0)

        self.assertEqual(len(results), workers)
        self.assertEqual(reg.count(), 1, "同键并发注册应只产生一个实例")
        first = results[0]
        for other in results[1:]:
            self.assertIs(other, first, "并发注册同键应复用同一实例对象")

    def test_worker_end_to_end(self):
        bus = EventBus()
        reg = PluginRegistry(bus=bus)
        bus.start()
        self.addCleanup(bus.stop)
        self.addCleanup(reg.shutdown)

        got = []
        inst = reg.register(
            "p1", lambda e: got.append(e), granularity="team",
            scope={"user_id": "u", "team_id": "t"},
        )
        self.assertTrue(
            bus.publish("tool.executed", {"user_id": "u", "team_id": "t", "agent_id": "a"})
        )
        self.assertTrue(_wait_until(lambda: len(got) == 1))
        # 不匹配的事件不会投递
        bus.publish("tool.executed", {"user_id": "u", "team_id": "t2"})
        time.sleep(0.25)
        self.assertEqual(len(got), 1)
        self.assertEqual(inst.processed, 1)

    def test_cleanup_cascade(self):
        reg = PluginRegistry()
        self.addCleanup(reg.shutdown)
        h = lambda e: None  # noqa: E731
        u, t = "u1", "t1"
        reg.register("p", h, granularity="team", scope={"user_id": u, "team_id": t})
        reg.register("p", h, granularity="agent", scope={"user_id": u, "team_id": t, "agent_id": "a1"})
        reg.register("p", h, granularity="agent", scope={"user_id": u, "team_id": t, "agent_id": "a2"})
        reg.register("p", h, granularity="session",
                     scope={"user_id": u, "team_id": t, "agent_id": "a1", "session_id": "s1"})
        reg.register("p", h, granularity="session",
                     scope={"user_id": u, "team_id": t, "agent_id": "a1", "session_id": "s2"})
        reg.register("p", h, granularity="team", scope={"user_id": "u2", "team_id": "t2"})
        self.assertEqual(reg.count(), 6)

        # 清 session s1：仅删该 session 实例
        self.assertEqual(
            reg.cleanup_scope(user_id=u, team_id=t, agent_id="a1", session_id="s1"), 1
        )
        self.assertEqual(reg.count(), 5)
        # 清 agent a1：删其 agent 实例 + 剩余 session 实例（s2）
        self.assertEqual(reg.cleanup_scope(user_id=u, team_id=t, agent_id="a1"), 2)
        self.assertEqual(reg.count(), 3)
        # 清 team (u,t)：删该团队全部（team=1, agent a2=1）
        self.assertEqual(reg.cleanup_scope(user_id=u, team_id=t), 2)
        self.assertEqual(reg.count(), 1)
        # 清 user u2
        self.assertEqual(reg.cleanup_scope(user_id="u2"), 1)
        self.assertEqual(reg.count(), 0)

    def test_ttl_and_pin(self):
        reg = PluginRegistry()
        self.addCleanup(reg.shutdown)
        h = lambda e: None  # noqa: E731
        i1 = reg.register("p", h, granularity="team", scope={"user_id": "u", "team_id": "t1"}, idle_ttl=10)
        i2 = reg.register("p", h, granularity="team", scope={"user_id": "u", "team_id": "t2"}, idle_ttl=10, pin=True)
        # 手动把活跃时间拨老
        i1.last_active = time.time() - 100
        i2.last_active = time.time() - 100
        stale = reg.collect_stale()
        self.assertIn(i1, stale)
        self.assertNotIn(i2, stale)  # Pin 不参与 TTL 清理
        self.assertEqual(reg.cleanup_stale(), 1)
        self.assertEqual(reg.count(), 1)

    @staticmethod
    def _mk_event(scope):
        from plugin.bus import PluginEvent

        return PluginEvent(
            event_id="e", seq=1, type="tool.executed", ts=time.time(),
            scope=normalize_scope(scope), payload={},
        )


class TestWatchdog(unittest.TestCase):
    """看门狗：进度续期 / fail-closed / 滑窗判死 / 实例心跳。"""

    def test_task_lifecycle_and_fail_closed(self):
        wd = ProgressWatchdog(stall_seconds=60.0)
        owner = ("u", "t")
        wd.start_task("k1", owner)
        self.assertEqual(wd.task_count(), 1)
        self.assertTrue(wd.beat("k1", owner))
        # 错误 owner → 拒绝续期（fail-closed）
        self.assertFalse(wd.beat("k1", ("u2", "t")))
        # 不存在的任务 → 拒绝
        self.assertFalse(wd.beat("k404", owner))
        # 完成（owner 匹配）→ 移除
        self.assertTrue(wd.finish_task("k1", owner))
        self.assertEqual(wd.task_count(), 0)
        # 完成后再 beat → False
        self.assertFalse(wd.beat("k1", owner))

    def test_stall_detection(self):
        wd = ProgressWatchdog(stall_seconds=60.0)
        wd.start_task("k1", ("u",))
        now = time.time()
        self.assertFalse(wd.is_stalled("k1", now=now + 30))
        self.assertTrue(wd.is_stalled("k1", now=now + 61))
        self.assertEqual(wd.stalled_tasks(now=now + 61), ["k1"])
        # 续期后重新计时
        wd.beat("k1", ("u",))
        self.assertFalse(wd.is_stalled("k1", now=time.time() + 30))

    def test_instance_heartbeat(self):
        wd = ProgressWatchdog()
        wd.touch_instance("i1")
        self.assertEqual(wd.instance_count(), 1)
        self.assertFalse(wd.is_instance_stale("i1", ttl=60))
        self.assertTrue(wd.is_instance_stale("i1", ttl=60, now=time.time() + 61))
        # 未登记实例保守判 stale
        self.assertTrue(wd.is_instance_stale("ghost", ttl=60))
        self.assertEqual(wd.collect_stale_instances(ttl=60, now=time.time() + 61), ["i1"])
        wd.drop_instance("i1")
        self.assertEqual(wd.instance_count(), 0)


class TestSDK(unittest.TestCase):
    """出站 SDK：白名单校验 / dispatch / ws / 日志（注入实现）。"""

    def setUp(self):
        reset_injections()
        self.addCleanup(reset_injections)

    def _sdk(self):
        return PluginSDK(
            {"user_id": "u", "team_id": "t", "agent_id": "a", "session_id": "s"}
        )

    def test_workspace_whitelist(self):
        calls = []

        class _IO:
            async def read_file(self, ws, path, encoding="utf-8"):
                calls.append((ws, path))
                return {"exit_code": 0, "stdout": "ok:{}:{}".format(ws, path)}

        set_io_provider(lambda user_id, mode_key: _IO())
        sdk = self._sdk()
        # 缺省 → agent_id
        r = sdk.workspace_read("README.md")
        self.assertEqual(r["stdout"], "ok:a:README.md")
        # 显式 team_id → 允许
        r2 = sdk.workspace_read("f.txt", workspace_id="t")
        self.assertEqual(r2["stdout"], "ok:t:f.txt")
        # 白名单外 → 拒绝（fail-closed，不触达底层）
        r3 = sdk.workspace_read("x", workspace_id="evil")
        self.assertIn("被拒", r3["error"])
        self.assertEqual(len(calls), 2)

    def test_workspace_rejected_without_scope(self):
        sdk = PluginSDK({"user_id": "u"})  # 无 agent/team
        r = sdk.workspace_read("README.md")
        self.assertIn("被拒", r["error"])

    def test_dispatch_injected(self):
        calls = []
        set_dispatcher(lambda **kw: (calls.append(kw), {"sent": ["m1"], "rejected": []})[1])
        sdk = self._sdk()
        r = sdk.dispatch_agent_message(["m1"], "hello")
        self.assertEqual(r["sent"], ["m1"])
        kw = calls[0]
        self.assertEqual(kw["user_id"], "u")
        self.assertEqual(kw["team_id"], "t")
        self.assertEqual(kw["source_agent_id"], "a")
        self.assertFalse(kw["active"])  # D6：默认被动通道防循环
        self.assertEqual(kw["extra"]["session_id"], "s")
        # 参数不完整 → 直接拒绝
        self.assertIn("error", sdk.dispatch_agent_message([], "x"))

    def test_ws_push_injected_and_unbound(self):
        sdk = self._sdk()
        # 未绑定循环且无注入 → False（降级丢弃，不抛异常）
        self.assertFalse(sdk.ws_push({"type": "plugin_event"}))
        # 非法消息（无 type）→ False
        sent = []
        set_ws_sender(lambda user_id, message: (sent.append((user_id, message)), True)[1])
        self.assertFalse(sdk.ws_push({"no": "type"}))
        self.assertTrue(sdk.ws_push({"type": "plugin_event", "data": {}}))
        self.assertEqual(sent[0][0], "u")

    def test_activity_log_injected(self):
        logs = []
        set_log_fn(lambda **kw: logs.append(kw))
        sdk = self._sdk()
        self.assertTrue(sdk.activity_log("hello"))
        self.assertEqual(logs[0]["workspace_id"], "a")
        self.assertEqual(logs[0]["user_id"], "u")
        self.assertEqual(logs[0]["mode_key"], "t")


class TestJoin(unittest.TestCase):
    """join 原语：键值/计数齐备、超时 partial、复用。"""

    def test_requires_config(self):
        with self.assertRaises(ValueError):
            JoinBuffer()

    def test_keys_complete_and_dedupe(self):
        jb = JoinBuffer(expect_keys={"a", "b"}, timeout=60)
        self.assertIsNone(jb.add(1, key="a"))
        self.assertIsNone(jb.add(1, key="a"))  # 重复键去重
        self.assertEqual(jb.pending_keys(), ["b"])
        r = jb.add(2, key="b")
        self.assertIsNotNone(r)
        self.assertFalse(r.partial)
        self.assertEqual(sorted(r.items), [1, 2])
        self.assertEqual(r.missing_keys, [])
        self.assertTrue(jb.done())

    def test_key_required(self):
        jb = JoinBuffer(expect_keys={"a"})
        with self.assertRaises(ValueError):
            jb.add(1)  # 缺 key → fail-closed

    def test_count_complete(self):
        jb = JoinBuffer(expect_count=2)
        self.assertIsNone(jb.add("x"))
        r = jb.add("y")
        self.assertEqual(len(r.items), 2)
        self.assertFalse(r.partial)

    def test_timeout_partial(self):
        jb = JoinBuffer(expect_keys={"a", "b"}, timeout=10)
        jb.add(1, key="a")
        now = time.time()
        self.assertIsNone(jb.check_timeout(now=now + 5))
        r = jb.check_timeout(now=now + 11)
        self.assertTrue(r.partial)
        self.assertTrue(r.timed_out)
        self.assertEqual(r.missing_keys, ["b"])
        # 已交付后不再返回
        self.assertIsNone(jb.check_timeout(now=now + 100))

    def test_force_partial_and_reset(self):
        jb = JoinBuffer(expect_keys={"a"})
        r = jb.force_partial()
        self.assertTrue(r.partial)
        jb.reset()
        self.assertFalse(jb.done())
        r2 = jb.add(1, key="a")
        self.assertIsNotNone(r2)
        self.assertFalse(r2.partial)


class TestFacade(unittest.TestCase):
    """门面：总开关 / 环境变量 / 全链路。"""

    def setUp(self):
        plugin.shutdown()  # 确保干净基线（含 _enabled=False）

    def tearDown(self):
        plugin.shutdown()

    def test_disabled_zero_side_effect(self):
        self.assertFalse(plugin.is_enabled())

        class _S:
            user_id = "u"
            team_id = "t"

        # 关闭状态：直接 False，且不创建任何组件（零副作用）
        self.assertFalse(plugin.publish_tool_event(_S(), "read", {}, "ok"))
        self.assertIsNone(plugin._bus)
        self.assertIsNone(plugin._registry)

    def test_enabled_full_flow(self):
        plugin.set_enabled(True)
        bus = plugin.get_bus()
        got = []
        bus.add_subscription(
            Subscription(
                name="t",
                match_fn=lambda e: e.type == "tool.call.completed",
                deliver_fn=lambda e: got.append(e),
            )
        )

        class _S:
            user_id = "u"
            team_id = "t"
            agent_id = "a"
            session_id = "s"

        self.assertTrue(plugin.publish_tool_event(_S(), "read", {"path": "x"}, "y" * 10))
        self.assertTrue(_wait_until(lambda: len(got) == 1))
        ev = got[0]
        self.assertEqual(ev.scope["user_id"], "u")
        self.assertEqual(ev.scope["agent_id"], "a")
        self.assertEqual(ev.payload["tool"], "read")
        self.assertEqual(ev.payload["args_keys"], ["path"])
        self.assertEqual(ev.payload["result_chars"], 10)
        self.assertTrue(ev.payload["ok"])

        # 缺少 user_id 的会话 → 拒绝发布（fail-closed 入口）

        class _S2:
            user_id = ""
            team_id = "t"

        self.assertFalse(plugin.publish_tool_event(_S2(), "read", {}, "ok"))

    def test_env_flag(self):
        with patch.dict(os.environ, {"TREE_PLUGIN_ENABLED": "1"}):
            self.assertTrue(plugin._read_env_enabled())
        with patch.dict(os.environ, {"TREE_PLUGIN_ENABLED": "yes"}):
            self.assertTrue(plugin._read_env_enabled())
        with patch.dict(os.environ, {"TREE_PLUGIN_ENABLED": "0"}):
            self.assertFalse(plugin._read_env_enabled())
        with patch.dict(os.environ, {}, clear=False):
            os.environ.pop("TREE_PLUGIN_ENABLED", None)
            self.assertFalse(plugin._read_env_enabled())


if __name__ == "__main__":
    unittest.main(verbosity=2)
