r"""宿主通道（二期 M2）模块单测：HostChannel + 门面接线 + 注册入口修复。

覆盖：
- fail-closed：总开关关闭全链 no-op（零副作用）；
- start 幂等（同 host_key 复用）/ 参数与归属校验 / 失败分类计数；
- stop 幂等（未知/已 closed 不发 op）/ 停止确认与未确认分支；
- status 缓存更新（state / exit_code / stderr_tail 截尾）；
- 上行 ``plugin_host_event``（exit 命中 / 未知 / 归属不符 / 非法 event）；
- 断连回收 ``mark_lost`` + 重连对账 ``reconcile``（closed/running/失败三分支）；
- 级联清理 ``cascade_cleanup``（scope 匹配 + best-effort 停止）；
- 门面接线：``plugin_host_event / plugin_host_mark_lost / plugin_host_reconcile``
  关闭零副作用、开启可走通；``plugin_cascade`` 挂接宿主会话回收；
- 注册入口修复（D-P2-6）：env 自动注册示范插件（默认关 / 缺 scope 跳过 / 命中注册）。

覆盖边界（如实声明）：真实反向 WS 帧往返（后端 ↔ 前端执行器）由联调窗口覆盖；
本文件以假执行器（FakeExecutor）验证通道状态机与门控语义。

运行：cd server && .venv\Scripts\python -m pytest tests\test_plugin_host_core.py -q
"""

from __future__ import annotations

import os
import unittest

import plugin
from plugin.host import (
    OP_HOST_START,
    OP_HOST_STATUS,
    OP_HOST_STOP,
    HostChannel,
    make_host_key,
)
from plugin.plugins.read_station_demo import ReadStationDemoPlugin
from plugin.stations import STATION_READ_RESULT

U1 = "u1"
T1 = "t1"
T2 = "t2"

FRAME_EXIT = {
    "event": "exit",
    "host_session_id": "phs_1",
    "team_id": T1,
    "exit_code": 0,
}


class FakeExecutor:
    """假执行器：记录请求并按脚本回结果（v2：支持 list 顺序脚本）。"""

    def __init__(self, script=None):
        self.calls = []
        self.script = {
            key: (list(val) if isinstance(val, list) else val)
            for key, val in dict(script or {}).items()
        }

    def _next_for(self, op):
        val = self.script.get(op)
        if isinstance(val, list):
            return dict(val.pop(0)) if val else {}
        if callable(val):
            return val()
        return dict(val) if isinstance(val, dict) else {}

    def request(self, ws_manager, user_id, payload, timeout=None, team_id=""):
        self.calls.append(
            {
                "user_id": user_id,
                "payload": dict(payload),
                "timeout": timeout,
                "team_id": team_id,
            }
        )
        return self._next_for(payload.get("op"))


def _make_channel(**kw):
    """构造直测通道（绕过全局开关；缩参 0.5s）。"""
    kw.setdefault("enabled_fn", lambda: True)
    kw.setdefault("op_timeout_s", 0.5)
    kw.setdefault("stop_wait_s", 0.5)
    return HostChannel(**kw)


class HostChannelBase(unittest.TestCase):
    def setUp(self):
        self.ch = _make_channel()
        self.ex = FakeExecutor()
        self.ws = object()

    def tearDown(self):
        self.ch.reset()


class TestDisabledZeroSideEffect(HostChannelBase):
    """总开关关闭（enabled_fn=False）：全链 no-op + 计数，零副作用。"""

    def test_disabled_all_ops_noop(self):
        ch = _make_channel(enabled_fn=lambda: False)
        ex, ws = FakeExecutor(), object()
        self.assertIn("error", ch.start_session(ex, ws, U1, "k1", team_id=T1))
        self.assertIn("error", ch.stop_session(ex, ws, U1, "phs_x"))
        self.assertIn("error", ch.query_status(ex, ws, U1, "phs_x"))
        self.assertFalse(ch.on_event(U1, dict(FRAME_EXIT)))
        self.assertEqual(ch.mark_lost(U1, [T1]), 0)
        self.assertEqual(ch.cascade_cleanup(U1, team_id=T1), 0)
        self.assertEqual(ch.reconcile_async(U1, T1), 0)
        self.assertEqual(ex.calls, [])
        self.assertEqual(ch.list_sessions(), [])
        self.assertGreaterEqual(ch.stats()["counts"]["skipped_disabled"], 3)


class TestStartStopStatus(HostChannelBase):
    def test_start_roundtrip_and_reuse(self):
        self.ex.script[OP_HOST_START] = {"host_session_id": "phs_1"}
        r1 = self.ch.start_session(self.ex, self.ws, U1, "k1", team_id=T1)
        self.assertEqual(r1["host_session_id"], "phs_1")
        call = self.ex.calls[0]
        self.assertEqual(call["payload"]["op"], OP_HOST_START)
        self.assertEqual(call["payload"]["host_key"], "k1")
        self.assertEqual(call["team_id"], T1)
        self.assertEqual(call["timeout"], 0.5)
        # 幂等：同 key 再启动 → 复用缓存，不再发 op
        r2 = self.ch.start_session(self.ex, self.ws, U1, "k1", team_id=T1)
        self.assertEqual(r2["host_session_id"], "phs_1")
        self.assertTrue(r2.get("reused"))
        self.assertEqual(len(self.ex.calls), 1)
        stats = self.ch.stats()
        self.assertEqual(stats["counts"]["started"], 1)
        self.assertEqual(stats["counts"]["reused"], 1)
        self.assertEqual(stats["in_flight"], 1)

    def test_start_fail_closed_variants(self):
        # 缺参
        self.assertIn("error", self.ch.start_session(self.ex, self.ws, U1, ""))
        # 无执行器
        self.assertIn(
            "error", self.ch.start_session(None, None, U1, "k1", team_id=T1)
        )
        # 宿主返回 error
        self.ex.script[OP_HOST_START] = {"error": "boom"}
        self.assertIn("error", self.ch.start_session(self.ex, self.ws, U1, "k1"))
        # 宿主未返回 id
        self.ex.script[OP_HOST_START] = {}
        self.assertIn("error", self.ch.start_session(self.ex, self.ws, U1, "k2"))
        counts = self.ch.stats()["counts"]
        self.assertEqual(counts["rejected_invalid"], 1)
        self.assertEqual(counts["rejected_no_executor"], 1)
        self.assertEqual(counts["start_failed"], 2)
        self.assertEqual(self.ch.list_sessions(), [])

    def test_stop_idempotent_and_ownership(self):
        self.ex.script[OP_HOST_START] = {"host_session_id": "phs_1"}
        self.ex.script[OP_HOST_STOP] = {"ok": True}
        self.ch.start_session(self.ex, self.ws, U1, "k1", team_id=T1)
        # 未知会话 → 幂等 ok，不发 op
        before = len(self.ex.calls)
        r = self.ch.stop_session(self.ex, self.ws, U1, "phs_missing")
        self.assertTrue(r["ok"])
        self.assertEqual(len(self.ex.calls), before)
        # 正常停止
        r = self.ch.stop_session(self.ex, self.ws, U1, "phs_1", team_id=T1)
        self.assertTrue(r["ok"])
        call = self.ex.calls[-1]
        self.assertEqual(call["payload"]["op"], OP_HOST_STOP)
        self.assertEqual(call["timeout"], 0.5)
        sess = self.ch.get_session("phs_1")
        self.assertEqual(sess.state, "closed")
        # 已 closed → 再停幂等，不发 op
        before = len(self.ex.calls)
        r = self.ch.stop_session(self.ex, self.ws, U1, "phs_1")
        self.assertTrue(r["ok"])
        self.assertEqual(r.get("note"), "already_closed")
        self.assertEqual(len(self.ex.calls), before)
        # 归属不符拒绝
        self.ex.script[OP_HOST_START] = {"host_session_id": "phs_2"}
        self.ch.start_session(self.ex, self.ws, U1, "k2", team_id=T1)
        r = self.ch.stop_session(self.ex, self.ws, "u2", "phs_2")
        self.assertIn("error", r)
        self.assertGreaterEqual(self.ch.stats()["counts"]["rejected_owner"], 1)

    def test_stop_unconfirmed_marks_lost(self):
        self.ex.script[OP_HOST_START] = [
            {"host_session_id": "phs_1"},
            {"host_session_id": "phs_2"},
        ]
        self.ex.script[OP_HOST_STOP] = {"error": "timeout"}
        self.ch.start_session(self.ex, self.ws, U1, "k1", team_id=T1)
        # 宿主返回 error → 标记失联（尽力而为）
        r = self.ch.stop_session(self.ex, self.ws, U1, "phs_1", team_id=T1)
        self.assertFalse(r["ok"])
        sess = self.ch.get_session("phs_1")
        self.assertEqual(sess.state, "running")
        self.assertTrue(sess.lost)

        # 传输异常（executor raise）→ 同样标记失联（与另两条路径一致；CH6 观察项修正）
        self.ch.start_session(self.ex, self.ws, U1, "k2", team_id=T1)

        class _BoomExecutor:
            def request(self, *args, **kwargs):
                raise RuntimeError("injected-transport-error")

        r3 = self.ch.stop_session(
            _BoomExecutor(), self.ws, U1, "phs_2", team_id=T1
        )
        self.assertFalse(r3["ok"])
        sess2 = self.ch.get_session("phs_2")
        self.assertEqual(sess2.state, "running")
        self.assertTrue(sess2.lost)

        # 无执行器停止 → 同样标记失联（不抛）
        r2 = self.ch.stop_session(None, None, U1, "phs_1", team_id=T1)
        self.assertFalse(r2["ok"])
        self.assertGreaterEqual(self.ch.stats()["counts"]["stop_failed"], 3)

    def test_status_cache_update(self):
        self.ex.script[OP_HOST_START] = {"host_session_id": "phs_1"}
        self.ex.script[OP_HOST_STATUS] = [
            {"state": "running"},
            {"state": "closed", "exit_code": 3, "stderr_tail": "x" * 3000},
        ]
        self.ch.start_session(self.ex, self.ws, U1, "k1", team_id=T1)
        r1 = self.ch.query_status(self.ex, self.ws, U1, "phs_1", team_id=T1)
        self.assertEqual(r1["state"], "running")
        r2 = self.ch.query_status(self.ex, self.ws, U1, "phs_1", team_id=T1)
        self.assertEqual(r2["state"], "closed")
        sess = self.ch.get_session("phs_1")
        self.assertEqual(sess.state, "closed")
        self.assertEqual(sess.exit_code, 3)
        self.assertEqual(len(sess.stderr_tail), 2000)
        # 未知 / 归属
        self.assertIn("error", self.ch.query_status(self.ex, self.ws, U1, "phs_x"))
        self.assertIn("error", self.ch.query_status(self.ex, self.ws, "u2", "phs_1"))
        counts = self.ch.stats()["counts"]
        self.assertEqual(counts["status_ok"], 2)
        self.assertGreaterEqual(counts["rejected_invalid"], 1)
        self.assertGreaterEqual(counts["rejected_owner"], 1)


class TestEventAndCleanup(HostChannelBase):
    def _start(self, key="k1", sid="phs_1", team=T1, scope=None):
        self.ex.script.setdefault(OP_HOST_START, [])
        existing = self.ex.script[OP_HOST_START]
        if isinstance(existing, list):
            existing.append({"host_session_id": sid})
        else:
            self.ex.script[OP_HOST_START] = [{"host_session_id": sid}]
        return self.ch.start_session(
            self.ex, self.ws, U1, key, team_id=team, scope=scope
        )

    def test_exit_event_hit_and_ignore(self):
        self._start()
        ok = self.ch.on_event(U1, dict(FRAME_EXIT))
        self.assertTrue(ok)
        sess = self.ch.get_session("phs_1")
        self.assertEqual(sess.state, "closed")
        self.assertEqual(sess.exit_code, 0)
        # 未知会话 / 归属不符 / 非法 event → 忽略 + 计数
        self.assertFalse(
            self.ch.on_event(U1, {"event": "exit", "host_session_id": "nope"})
        )
        self._start(key="k2", sid="phs_2", team=T1)
        self.assertFalse(
            self.ch.on_event(
                "u2",
                {"event": "exit", "host_session_id": "phs_2", "team_id": T1},
            )
        )
        self.assertFalse(
            self.ch.on_event(U1, {"event": "other", "host_session_id": "phs_2"})
        )
        self.assertGreaterEqual(self.ch.stats()["counts"]["event_ignored"], 3)

    def test_mark_lost_and_reconcile_branches(self):
        self._start(key="k1", sid="phs_a", team=T1)
        self._start(key="k2", sid="phs_b", team=T2)
        # 仅 T1 命中
        self.assertEqual(self.ch.mark_lost(U1, [T1]), 1)
        self.assertTrue(self.ch.get_session("phs_a").lost)
        self.assertFalse(self.ch.get_session("phs_b").lost)
        # 对账：closed → 回收
        self.ex.script[OP_HOST_STATUS] = [{"state": "closed"}]
        out = self.ch.reconcile(self.ex, self.ws, U1, T1)
        self.assertEqual(out["closed"], 1)
        self.assertEqual(self.ch.get_session("phs_a").state, "closed")
        # 对账：running → 清 lost
        self.assertEqual(self.ch.mark_lost(U1, [T2]), 1)
        self.ex.script[OP_HOST_STATUS] = [{"state": "running"}]
        out = self.ch.reconcile(self.ex, self.ws, U1, T2)
        self.assertEqual(out["running"], 1)
        self.assertFalse(self.ch.get_session("phs_b").lost)
        # 对账：失败 → 保持 lost
        self.ch.mark_lost(U1, [T2])
        self.ex.script[OP_HOST_STATUS] = [{"error": "offline"}]
        out = self.ch.reconcile(self.ex, self.ws, U1, T2)
        self.assertEqual(out["failed"], 1)
        self.assertTrue(self.ch.get_session("phs_b").lost)
        # 异步对账：有失联会话才排期（注入假执行器，drain 收尾）
        n = self.ch.reconcile_async(U1, T2, executor=self.ex, ws_manager=self.ws)
        self.assertEqual(n, 1)
        self.ch.drain(1.0)
        # 无失联会话 → 不排期
        self.ex.script[OP_HOST_STATUS] = [{"state": "running"}]
        self.ch.reconcile(self.ex, self.ws, U1, T2)
        self.assertEqual(self.ch.reconcile_async(U1, T2), 0)

    def test_cascade_cleanup_scope_and_best_effort_stop(self):
        self._start(
            key="k1",
            sid="phs_1",
            team=T1,
            scope={"user_id": U1, "team_id": T1, "agent_id": "a1"},
        )
        self._start(
            key="k2",
            sid="phs_2",
            team=T1,
            scope={"user_id": U1, "team_id": T1, "agent_id": "a2"},
        )
        self.ex.script[OP_HOST_STOP] = {"ok": True}
        # 命中 a1：移除 + 同步 best-effort 停止
        removed = self.ch.cascade_cleanup(
            U1,
            team_id=T1,
            agent_id="a1",
            executor=self.ex,
            ws_manager=self.ws,
            async_stop=False,
        )
        self.assertEqual(removed, 1)
        self.assertIsNone(self.ch.get_session("phs_1"))
        self.assertIsNotNone(self.ch.get_session("phs_2"))
        stop_ops = [
            c for c in self.ex.calls if c["payload"].get("op") == OP_HOST_STOP
        ]
        self.assertEqual(len(stop_ops), 1)
        self.assertEqual(stop_ops[0]["payload"]["host_session_id"], "phs_1")
        # 无命中 → 0
        self.assertEqual(
            self.ch.cascade_cleanup(U1, team_id="t_none", async_stop=False), 0
        )
        # 默认异步：派工 + drain 后停止被尝试
        before = len(self.ex.calls)
        removed = self.ch.cascade_cleanup(
            U1, team_id=T1, executor=self.ex, ws_manager=self.ws
        )
        self.assertEqual(removed, 1)
        self.ch.drain(1.0)
        self.assertGreater(len(self.ex.calls), before)

    def test_make_host_key(self):
        key = make_host_key(
            "p", "agent", {"user_id": "u", "team_id": "t", "agent_id": "a"}
        )
        self.assertEqual(key, "p|agent|u|t|a")
        with self.assertRaises(ValueError):
            make_host_key("p", "bad-granularity", {})


class PluginFacadeBase(unittest.TestCase):
    """操作全局门面：setUp 清理并复位开关；tearDown 清理 + 恢复原开关。"""

    def setUp(self):
        self._saved_enabled = plugin._enabled
        try:
            plugin.shutdown()
        except Exception:
            pass
        plugin.set_enabled(False)

    def tearDown(self):
        try:
            plugin.shutdown()
        except Exception:
            pass
        plugin._enabled = self._saved_enabled
        for name in (plugin.ENV_DEMO_READ_STATION, plugin.ENV_DEMO_SCOPE):
            os.environ.pop(name, None)


class TestFacadeWiring(PluginFacadeBase):
    def test_facade_disabled_zero_side_effect(self):
        self.assertFalse(plugin.plugin_host_event(U1, dict(FRAME_EXIT)))
        self.assertEqual(plugin.plugin_host_mark_lost(U1, [T1]), 0)
        self.assertEqual(plugin.plugin_host_reconcile(U1, T1), 0)

    def test_facade_enabled_roundtrip(self):
        plugin.set_enabled(True)
        ch = plugin.get_host_channel()
        ch.reset()
        ex, ws = FakeExecutor(), object()
        ex.script[OP_HOST_START] = {"host_session_id": "phs_1"}
        r = ch.start_session(ex, ws, U1, "k1", team_id=T1)
        self.assertEqual(r["host_session_id"], "phs_1")
        # 门面上行：exit 帧命中
        self.assertTrue(plugin.plugin_host_event(U1, dict(FRAME_EXIT)))
        self.assertEqual(ch.get_session("phs_1").state, "closed")
        # 断连回收与对账门面（无失联会话 → 0）
        self.assertGreaterEqual(plugin.plugin_host_mark_lost(U1, [T1]), 0)
        self.assertEqual(plugin.plugin_host_reconcile(U1, T1), 0)
        # plugin_cascade 挂接：会话随 scope 级联移除
        ex.script[OP_HOST_START] = {"host_session_id": "phs_2"}
        ch.start_session(ex, ws, U1, "k2", team_id=T1)
        plugin.plugin_cascade(U1, team_id=T1)
        self.assertIsNone(ch.get_session("phs_2"))
        ch.drain(1.0)


class TestDemoRegisterEnv(PluginFacadeBase):
    """D-P2-6：env 自动注册示范插件（默认关 / 缺 scope 跳过 / 命中注册）。"""

    def test_default_off(self):
        self.assertFalse(plugin._maybe_register_demo())
        self.assertIsNone(plugin._demo_plugin)

    def test_missing_scope_skipped(self):
        os.environ[plugin.ENV_DEMO_READ_STATION] = "1"
        os.environ[plugin.ENV_DEMO_SCOPE] = ""
        plugin.set_enabled(True)
        self.assertIsNone(plugin._demo_plugin)
        self.assertFalse(plugin._maybe_register_demo())

    def test_registered_and_idempotent(self):
        os.environ[plugin.ENV_DEMO_READ_STATION] = "1"
        os.environ[plugin.ENV_DEMO_SCOPE] = "user_id=demo_u;team_id=demo_t"
        plugin.set_enabled(True)
        self.assertIsInstance(plugin._demo_plugin, ReadStationDemoPlugin)
        sub = plugin.get_stations().resolve(
            STATION_READ_RESULT,
            {"user_id": "demo_u", "team_id": "demo_t"},
        )
        self.assertIsNotNone(sub)
        self.assertEqual(sub.granularity, "team")
        # 幂等：键位已占用 → 不重复注册（返回 False，不抛）
        self.assertFalse(plugin._maybe_register_demo())
        self.assertIsInstance(plugin._demo_plugin, ReadStationDemoPlugin)


if __name__ == "__main__":
    unittest.main()
