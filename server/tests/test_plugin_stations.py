r"""处理站（半二期）单元测试：隔离 / 竞态 / 超时 / 降级语义（fail-open 全分支）。

范围与对照：
- 反例矩阵 ``artifacts/test-reverse-matrix.md``（S1–S16）逐条映射见
  ``artifacts/test-report.md`` 的「矩阵 ↔ 用例」表；
- 实现：``server/plugin/stations.py``（接口冻结版，计数键名以最终实现为准）；
- 本文件使用**独立组件实例**（PluginRegistry + StationsHub + ProgressWatchdog），
  不依赖全局门面状态；timing 类用例统一缩参（等待切片/节拍 env，tearDown 恢复）。

运行：cd server && .venv\Scripts\python -m pytest tests\test_plugin_stations.py -q

用例速览（场景 → 预期）：
- 替换/直通：str 替换 / None 不改动 / 空串合法替换 / 无订阅快速路径 /
  未命中 no_subscriber / 非 str 直通 / 缺 user_id 直通
- 超时与竞态：超时放行+迟到计数 / 自动回填被忽略 / 重复回填首胜 /
  非法类型立即终结 / handler 异常隔离 / 取消快速放行
- 背压与销毁：队列满立即 fail-open / 在途实例销毁快速失败 / 残留订阅惰性清理
- 订阅语义：冲突先到先得 / replace 替换 / 显式退订 / 最细粒度优先 / 级联清理
- 隔离与反例：跨会话隔离 / 同站重入有界 / 自增殖销毁终止 / 跨实例环有界
- 观测：进度通道 runs 登记/完成/活跃
"""

from __future__ import annotations

import os
import threading
import time
import unittest

from plugin.registry import PluginRegistry
from plugin.stations import STATION_READ_RESULT, StationsHub
from plugin.watchdog import ProgressWatchdog

# 真实接入站位（read 结果站）；ALT 为反例用第二站
SID = STATION_READ_RESULT
ALT = "test.station.alt"


def scope_of(user="u1", team="t1", agent="a1", session="s1"):
    """构造四元组 scope（默认全字段非空）。"""
    return {
        "user_id": user,
        "team_id": team,
        "agent_id": agent,
        "session_id": session,
    }


class StationTestBase(unittest.TestCase):
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
    def counts(self):
        """分类计数快照（每次返回拷贝，可安全前后对比）。"""
        return dict(self.hub.stats()["counts"])

    def diff(self, before, after):
        """计数差量（只保留变化键）。"""
        return {
            key: after[key] - before.get(key, 0)
            for key in after
            if after[key] != before.get(key, 0)
        }

    def assertNoCountChange(self, before, after, msg=""):
        self.assertEqual(self.diff(before, after), {}, msg or "计数应保持不变")

    def wait_until(self, predicate, timeout=2.0, interval=0.01):
        """轮询直到条件为真（测试时限内）。"""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            time.sleep(interval)
        return predicate()

    def subscribe(self, handler, *, plugin="p1", granularity="agent",
                  scope=None, **kw):
        return self.hub.subscribe(
            SID, plugin, handler,
            granularity=granularity, scope=scope or scope_of(), **kw
        )

    def _instance(self, plugin_id):
        for inst in self.reg.instances():
            if inst.plugin_id == plugin_id:
                return inst
        return None


# ======================================================================
# 一、替换 / 直通语义
# ======================================================================
class TestStationPassthrough(StationTestBase):

    def test_replace_result(self):
        """str 替换生效：process 返回替换值；requests/responded 计数。"""
        calls = []

        def handler(req):
            calls.append(req.data)
            return "REPLACED:" + req.data

        self.assertTrue(self.subscribe(handler))
        r = self.hub.process(SID, "hello", scope_of(), timeout_s=1.0)
        self.assertEqual(r, "REPLACED:hello")
        self.assertEqual(calls, ["hello"])
        c = self.counts()
        self.assertEqual(c["requests"], 1)
        self.assertEqual(c["responded"], 1)

    def test_respond_none_passthrough(self):
        """None 不改动：返回原数据（仍是合法回填）。"""
        self.assertTrue(self.subscribe(lambda req: None))
        r = self.hub.process(SID, "orig", scope_of(), timeout_s=1.0)
        self.assertEqual(r, "orig")
        self.assertEqual(self.counts()["responded"], 1)

    def test_replace_with_empty_string(self):
        """空串是合法替换（与 None 语义区分）。"""
        self.assertTrue(self.subscribe(lambda req: ""))
        r = self.hub.process(SID, "orig", scope_of(), timeout_s=1.0)
        self.assertEqual(r, "")
        self.assertEqual(self.counts()["responded"], 1)

    def test_no_subscription_fast_path(self):
        """无任何订阅：快速路径原值放行、零计数（近零开销）。"""
        before = self.counts()
        r = self.hub.process(SID, "x", scope_of())
        self.assertEqual(r, "x")
        self.assertNoCountChange(before, self.counts())

    def test_active_but_not_matched(self):
        """有订阅但未命中：原值 + no_subscriber+1。"""
        self.assertTrue(self.subscribe(lambda req: "HIT", scope=scope_of(agent="a1")))
        before = self.counts()
        r = self.hub.process(SID, "x", scope_of(agent="a9"))
        self.assertEqual(r, "x")
        self.assertEqual(self.diff(before, self.counts()), {"no_subscriber": 1})

    def test_non_str_passthrough(self):
        """非 str 输入直通：不处理、不计数（契约外输入）。"""
        self.assertTrue(self.subscribe(lambda req: "HIT"))
        data = {"k": 1}
        before = self.counts()
        r = self.hub.process(SID, data, scope_of())
        self.assertIs(r, data)
        self.assertNoCountChange(before, self.counts())

    def test_missing_user_id_passthrough(self):
        """缺 user_id：fail-closed 直通（不投递、不计数）。"""
        self.assertTrue(self.subscribe(lambda req: "HIT"))
        before = self.counts()
        r = self.hub.process(SID, "x", {})
        self.assertEqual(r, "x")
        self.assertNoCountChange(before, self.counts())


# ======================================================================
# 二、超时与回填竞态
# ======================================================================
class TestStationTimeoutRaces(StationTestBase):

    def test_timeout_release_with_late_respond(self):
        """超时放行 + 迟到回传分类计数（late_response，不干扰返回值）。"""
        late = []

        def handler(req):
            time.sleep(0.25)
            late.append(req.respond("late-value"))  # 请求已超时 → False + late

        self.assertTrue(self.subscribe(handler))
        t0 = time.monotonic()
        r = self.hub.process(SID, "orig", scope_of(), timeout_s=0.08)
        dt = time.monotonic() - t0
        self.assertEqual(r, "orig")
        self.assertLess(dt, 0.6, "超时应按语义时限放行")
        self.assertEqual(self.counts()["timeout"], 1)
        self.assertTrue(self.wait_until(lambda: late), "迟到回传未发生")
        self.assertEqual(late, [False])
        c = self.counts()
        self.assertEqual(c["late_response"], 1)
        self.assertEqual(c["responded"], 0)

    def test_auto_refill_after_timeout_is_ignored(self):
        """超时后框架自动回填（handler 返回值）被忽略：不重复计数。"""
        def handler(req):
            time.sleep(0.15)
            return "too-late"

        self.assertTrue(self.subscribe(handler))
        r = self.hub.process(SID, "orig", scope_of(), timeout_s=0.05)
        self.assertEqual(r, "orig")
        self.assertEqual(self.counts()["timeout"], 1)
        time.sleep(0.25)  # 等 handler 完成其回填尝试
        c = self.counts()
        self.assertEqual(c["late_response"], 0)
        self.assertEqual(c["responded"], 0)

    def test_duplicate_respond_first_wins(self):
        """重复回填：先到先赢；第二次 False + duplicate_response。"""
        rets = []

        def handler(req):
            rets.append(req.respond("first"))
            rets.append(req.respond("second"))

        self.assertTrue(self.subscribe(handler))
        r = self.hub.process(SID, "orig", scope_of(), timeout_s=1.0)
        self.assertEqual(r, "first")
        self.assertTrue(self.wait_until(lambda: len(rets) == 2))
        self.assertEqual(rets, [True, False])
        c = self.counts()
        self.assertEqual(c["responded"], 1)
        self.assertEqual(c["duplicate_response"], 1)

    def test_invalid_respond_type(self):
        """非法回填类型：立即终结（invalid）→ invalid_response + 迟到计数。"""
        rets = []

        def handler(req):
            rets.append(req.respond(123))          # int 非法 → 立即终结
            rets.append(req.respond("after"))      # 终结后 → 迟到

        self.assertTrue(self.subscribe(handler))
        t0 = time.monotonic()
        r = self.hub.process(SID, "orig", scope_of(), timeout_s=1.0)
        dt = time.monotonic() - t0
        self.assertEqual(r, "orig")
        self.assertLess(dt, 0.6, "非法回填应即时终结等待（无需等超时）")
        self.assertTrue(self.wait_until(lambda: len(rets) == 2))
        self.assertEqual(rets, [False, False])
        c = self.counts()
        self.assertEqual(c["invalid_response"], 1)
        self.assertEqual(c["late_response"], 1)
        self.assertEqual(c["responded"], 0)

    def test_invalid_response_type_matrix(self):
        """S6 类型矩阵：int / dict / bytes / float / object → 均 invalid_response。"""
        payloads = (123, {"a": 1}, b"bytes", 3.14, object())
        for idx, payload in enumerate(payloads):
            with self.subTest(payload=type(payload).__name__):
                scope = scope_of(agent="a_inv%d" % idx)
                seen = []

                def handler(req, _payload=payload):
                    seen.append(req.respond(_payload))

                self.assertTrue(
                    self.hub.subscribe(
                        SID, "p_inv_%d" % idx, handler,
                        granularity="agent", scope=scope,
                    )
                )
                r = self.hub.process(SID, "orig", scope, timeout_s=0.5)
                self.assertEqual(r, "orig", "非法回填不应放行半成品")
                self.assertTrue(self.wait_until(lambda: seen))
                self.assertEqual(seen, [False])
        c = self.counts()
        self.assertEqual(c["invalid_response"], len(payloads))
        self.assertEqual(c["responded"], 0)

    def test_handler_exception_isolated(self):
        """插件异常隔离：handler_error 计数 + 原值放行（不抛出）。"""
        def handler(req):
            raise RuntimeError("boom")

        self.assertTrue(self.subscribe(handler))
        t0 = time.monotonic()
        r = self.hub.process(SID, "orig", scope_of(), timeout_s=1.0)
        dt = time.monotonic() - t0
        self.assertEqual(r, "orig")
        self.assertLess(dt, 0.6, "异常路径应立即终结等待")
        c = self.counts()
        self.assertEqual(c["handler_error"], 1)
        self.assertEqual(c["responded"], 0)

    def test_cancel_fast_release(self):
        """取消：≤亚秒级放行（远小于超时设置）+ cancelled + 期间回传迟到。"""
        late = []

        def handler(req):
            time.sleep(0.3)
            late.append(req.respond("too-late"))

        self.assertTrue(self.subscribe(handler))
        cancel = threading.Event()
        timer = threading.Timer(0.05, cancel.set)
        timer.start()
        try:
            t0 = time.monotonic()
            r = self.hub.process(
                SID, "orig", scope_of(), timeout_s=5.0, cancel_event=cancel
            )
            dt = time.monotonic() - t0
        finally:
            timer.cancel()
        self.assertEqual(r, "orig")
        self.assertLess(dt, 1.5, "取消应在分段粒度内放行（远小于 5s 超时）")
        self.assertEqual(self.counts()["cancelled"], 1)
        self.assertTrue(self.wait_until(lambda: late))
        self.assertEqual(self.counts()["late_response"], 1)


# ======================================================================
# 三、背压与销毁
# ======================================================================
class TestStationBackpressureDestroy(StationTestBase):

    def test_queue_full_immediate_fail_open(self):
        """队列满：投递失败立即 fail-open（快速失败，绝不静默等超时）。"""
        def handler(req):
            time.sleep(0.35)
            return None

        self.assertTrue(self.subscribe(handler, inbox_max=1))
        # 第 1 次：worker 取走执行（占用）；调用方短超时返回
        r1 = self.hub.process(SID, "a", scope_of(), timeout_s=0.05)
        self.assertEqual(r1, "a")
        time.sleep(0.05)  # 确保 worker 已取走任务 1（执行中）
        # 第 2 次：队列空 → 投递成功（占满容量 1）
        r2 = self.hub.process(SID, "b", scope_of(), timeout_s=0.05)
        self.assertEqual(r2, "b")
        # 第 3 次：队列满 → 立即返回（dt 仅毫秒级）
        t0 = time.monotonic()
        r3 = self.hub.process(SID, "c", scope_of(), timeout_s=0.05)
        dt3 = time.monotonic() - t0
        self.assertEqual(r3, "c")
        self.assertLess(dt3, 0.04, "队列满应立即快速失败（不作等待）")
        c = self.counts()
        self.assertEqual(c["overflow"], 1)
        self.assertEqual(c["requests"], 2)
        self.assertEqual(c["timeout"], 2)

    def test_inflight_destroy_fast_fail(self):
        """在途销毁：等待方检测实例失效 → 立即 fail-open（cancelled）。"""
        def handler(req):
            time.sleep(0.8)
            return "x"

        self.assertTrue(self.subscribe(handler))
        holder = {}

        def waiter():
            t0 = time.monotonic()
            holder["r"] = self.hub.process(SID, "orig", scope_of(), timeout_s=8.0)
            holder["dt"] = time.monotonic() - t0

        th = threading.Thread(target=waiter, daemon=True)
        th.start()
        time.sleep(0.08)  # 确保 handler 已在执行、请求在途
        removed = self.reg.cleanup_scope(user_id="u1", agent_id="a1")
        self.assertEqual(removed, 1)
        th.join(timeout=3.0)
        self.assertFalse(th.is_alive(), "等待线程未及时返回（在途失效未生效）")
        self.assertEqual(holder.get("r"), "orig")
        self.assertLess(holder.get("dt", 99), 1.5, "销毁应快速失败（远小于 8s）")
        self.assertEqual(self.counts()["cancelled"], 1)

    def test_inflight_team_cascade_fast_fail(self):
        """在途销毁（第二路：team 级联）：等待方立即 fail-open。"""
        def handler(req):
            time.sleep(0.8)
            return "x"

        self.assertTrue(self.subscribe(handler))
        holder = {}

        def waiter():
            t0 = time.monotonic()
            holder["r"] = self.hub.process(SID, "orig", scope_of(), timeout_s=8.0)
            holder["dt"] = time.monotonic() - t0

        th = threading.Thread(target=waiter, daemon=True)
        th.start()
        time.sleep(0.08)
        removed = self.reg.cleanup_scope(user_id="u1", team_id="t1")
        self.assertEqual(removed, 1)
        th.join(timeout=3.0)
        self.assertFalse(th.is_alive(), "等待线程未及时返回（级联失效未生效）")
        self.assertEqual(holder.get("r"), "orig")
        self.assertLess(holder.get("dt", 99), 1.5)
        self.assertEqual(self.counts()["cancelled"], 1)

    def test_stale_subscription_cleanup_on_resubscribe(self):
        """残留订阅（实例已销毁）→ 同键重订自动惰性清理后接受。"""
        self.assertTrue(self.subscribe(lambda req: "OLD", plugin="p_old"))
        inst = self._instance("p_old")
        self.assertIsNotNone(inst)
        self.assertTrue(self.reg.unregister(inst))  # 模拟实例销毁（订阅残留）
        # 同键位重订：应获接受（惰性清理残留），而非冲突拒绝
        ok = self.subscribe(lambda req: "NEW", plugin="p_new")
        self.assertTrue(ok)
        self.assertEqual(self.counts()["rejected_conflict"], 0)
        r = self.hub.process(SID, "x", scope_of(), timeout_s=1.0)
        self.assertEqual(r, "NEW")


# ======================================================================
# 四、订阅语义（唯一性 / 替换 / 粒度 / 级联）
# ======================================================================
class TestStationSubscriptionSemantics(StationTestBase):

    def test_subscription_conflict_replace_and_unsubscribe(self):
        """站×scope 键位唯一：冲突拒绝 → replace 替换 → 显式退订。"""
        self.assertTrue(self.subscribe(lambda req: "A", plugin="p1"))
        # 同键位第二个订阅（不同 plugin 亦按站×scope 唯一）→ 拒绝
        self.assertFalse(self.subscribe(lambda req: "B", plugin="p2"))
        self.assertEqual(self.counts()["rejected_conflict"], 1)
        # 显式替换
        self.assertTrue(
            self.subscribe(lambda req: "B", plugin="p2", replace=True)
        )
        self.assertEqual(self.counts()["unsubscribed"], 1)
        snap = self.hub.stats()
        self.assertEqual(
            [s["plugin_id"] for s in snap["subscriptions"]], ["p2"]
        )
        self.assertEqual(
            self.hub.process(SID, "x", scope_of(), timeout_s=1.0), "B"
        )
        # 显式退订（仅按站匹配）
        removed = self.hub.unsubscribe(SID)
        self.assertEqual(removed, 1)
        self.assertEqual(self.counts()["unsubscribed"], 2)
        self.assertEqual(self.hub.stats()["subscription_count"], 0)

    def test_granularity_priority_and_prefix_match(self):
        """最细粒度优先（session > team）；前缀 fail-closed 匹配。"""
        self.assertTrue(
            self.subscribe(
                lambda req: "TEAM", plugin="p_t", granularity="team",
                scope={"user_id": "u1", "team_id": "t1"},
            )
        )
        self.assertTrue(
            self.subscribe(
                lambda req: "SESSION", plugin="p_s", granularity="session",
                scope=scope_of(),
            )
        )
        # 全 scope：最细（session）优先
        self.assertEqual(
            self.hub.process(SID, "x", scope_of(), timeout_s=1.0), "SESSION"
        )
        # 仅 team 前缀（缺 agent/session）：session 订阅 fail-closed 不匹配 → team
        r = self.hub.process(
            SID, "x", {"user_id": "u1", "team_id": "t1"}, timeout_s=1.0
        )
        self.assertEqual(r, "TEAM")
        # 不匹配：no_subscriber
        before = self.counts()
        r = self.hub.process(
            SID, "x", {"user_id": "u2", "team_id": "t1"}, timeout_s=1.0
        )
        self.assertEqual(r, "x")
        self.assertEqual(self.diff(before, self.counts()), {"no_subscriber": 1})

    def test_concurrent_subscribe_same_key(self):
        """并发订阅（多线程 barrier 同键）：订阅表唯一、可解析、至少 1 成功。

        观察项：实现中"检查+插入"同临界区，但订阅实例创建在锁外——
        理论上存在窄窗口使多个并发调用均返回成功（表内仍唯一；先到者
        被后到者顶替）。本用例记录成功分布（多成功属观察现象，不影响
        唯一性与路由）；结论见 test-report.md 差异清单。
        """
        for rnd in range(3):
            scope = scope_of(agent="a_r%d" % rnd)
            results = []
            barrier = threading.Barrier(6)

            def worker(i, _scope=scope, _rnd=rnd):
                try:
                    barrier.wait(timeout=5.0)
                except Exception:
                    pass
                ok = self.hub.subscribe(
                    SID, "p_race_%d_%d" % (_rnd, i), lambda req: "x",
                    granularity="agent", scope=_scope,
                )
                results.append((i, ok))

            threads = [
                threading.Thread(target=worker, args=(i,), daemon=True)
                for i in range(6)
            ]
            for t in threads:
                t.start()
            for t in threads:
                t.join(timeout=10.0)
            self.assertEqual(len(results), 6, "轮次 %d：线程未全部返回" % rnd)
            self.assertIsNotNone(
                self.hub.resolve(SID, scope),
                "轮次 %d：订阅表内应可解析出唯一订阅" % rnd,
            )
            oks = [1 for _, ok in results if ok]
            print(
                "[concurrent-subscribe] round=%d ok_count=%d" % (rnd, len(oks))
            )
        self.assertEqual(self.hub.stats()["subscription_count"], 3)

    def test_cascade_cleanup_subscriptions(self):
        """级联清理：条件非空字段匹配才移除；未匹配 scope 不受影响。"""
        self.assertTrue(
            self.subscribe(
                lambda req: "S1", plugin="p1", granularity="session",
                scope=scope_of(),
            )
        )
        self.assertTrue(
            self.subscribe(
                lambda req: "S2", plugin="p2", granularity="session",
                scope=scope_of(session="s2"),
            )
        )
        removed = self.hub.cascade_cleanup("u1", agent_id="a1", session_id="s1")
        self.assertEqual(removed, 1)
        self.assertEqual(self.counts()["subscriptions_cascaded"], 1)
        self.assertEqual(self.hub.stats()["subscription_count"], 1)
        # 被清 scope（s1）：无订阅放行
        before = self.counts()
        r = self.hub.process(SID, "x", scope_of(), timeout_s=1.0)
        self.assertEqual(r, "x")
        self.assertEqual(self.diff(before, self.counts()), {"no_subscriber": 1})
        # 保留 scope（s2）：仍命中
        self.assertEqual(
            self.hub.process(SID, "x", scope_of(session="s2"), timeout_s=1.0),
            "S2",
        )


# ======================================================================
# 五、隔离与反例（重入 / 环 / 跨会话）
# ======================================================================
class TestStationIsolationAndCycles(StationTestBase):

    def test_cross_session_isolation(self):
        """跨会话隔离：s1 慢等待不阻塞 s2 正常处理（实例间并行）。"""
        def slow(req):
            time.sleep(0.3)
            return "slow-done"

        def fast(req):
            return "fast-done"

        self.assertTrue(
            self.subscribe(
                slow, plugin="p_slow", granularity="session",
                scope=scope_of(session="s1"),
            )
        )
        self.assertTrue(
            self.subscribe(
                fast, plugin="p_fast", granularity="session",
                scope=scope_of(session="s2"),
            )
        )
        holder = {}

        def waiter():
            holder["r"] = self.hub.process(
                SID, "x", scope_of(session="s1"), timeout_s=3.0
            )

        th = threading.Thread(target=waiter, daemon=True)
        th.start()
        time.sleep(0.05)
        t0 = time.monotonic()
        r_fast = self.hub.process(
            SID, "x", scope_of(session="s2"), timeout_s=3.0
        )
        dt_fast = time.monotonic() - t0
        th.join(timeout=3.0)
        self.assertEqual(r_fast, "fast-done")
        self.assertLess(dt_fast, 0.25, "s1 等待不应阻塞 s2")
        self.assertEqual(holder.get("r"), "slow-done")

    def test_reentrant_self_call_bounded(self):
        """同站重入（handler 内触发同站）：F1 防重入 bypass 立即放行（不投递/不等待）+ 计数。"""
        inner = []

        def handler(req):
            if req.data.startswith("outer"):
                inner.append(
                    self.hub.process(SID, "inner-data", scope_of(), timeout_s=0.15)
                )
                return "outer-done"
            return None

        self.assertTrue(self.subscribe(handler))
        t0 = time.monotonic()
        r = self.hub.process(SID, "outer-1", scope_of(), timeout_s=1.5)
        dt = time.monotonic() - t0
        self.assertEqual(r, "outer-done")
        self.assertLess(dt, 0.12, "bypass 应立即放行（不再等待超时）")
        self.assertEqual(inner, ["inner-data"], "内层应 bypass 原值放行")
        c = self.counts()
        self.assertEqual(c["reentrant_bypass"], 1, "同站重入应立即 bypass 计数")
        self.assertEqual(
            c["requests"], 1, "内层 bypass 不投递（仅外层计入 requests）"
        )
        self.assertEqual(c["timeout"], 0, "bypass 不产生等待超时")

    def test_reentrant_bypass_prevents_self_perpetuation(self):
        """无条件重入：F1 防重入 bypass 立即放行 → 无自增殖任务循环。"""
        def handler(req):
            self.hub.process(SID, "loop", scope_of(), timeout_s=0.05)
            return None

        self.assertTrue(self.subscribe(handler))
        for _ in range(2):
            t0 = time.monotonic()
            self.hub.process(SID, "seed", scope_of(), timeout_s=0.5)
            self.assertLess(
                time.monotonic() - t0, 0.2, "种子应立即完成（内层 bypass）"
            )
        time.sleep(0.3)  # 观察窗：若仍自增殖，timeout/requests 会增长
        c = self.counts()
        self.assertEqual(c["timeout"], 0, "bypass 下不应有等待超时（无自增殖）")
        self.assertEqual(c["requests"], 2, "仅两次种子投递")
        self.assertEqual(c["reentrant_bypass"], 2, "每次种子处理内层均 bypass")

    def test_cross_instance_cycle_bounded(self):
        """跨实例环（A→B→A 同步等待）：超时兜底解除、有界收敛。"""
        def handler_a(req):
            if req.data == "seed-x":
                # 外层预算须宽于 B 端总耗时（B 自身内层 0.1s + 开销）；否则
                # 外层先超时（亦为合法 fail-open 路径：每层独立 deadline，
                # 先到先得，无死锁），断言将不确定。
                inner = self.hub.process(ALT, "from-a", scope_of(), timeout_s=0.5)
                return "a<{}>".format(inner)
            return None

        def handler_b(req):
            if req.data == "from-a":
                inner = self.hub.process(SID, "from-b", scope_of(), timeout_s=0.1)
                return "b<{}>".format(inner)
            return "b-pass"

        self.assertTrue(
            self.hub.subscribe(SID, "p_a", handler_a, granularity="agent",
                               scope=scope_of())
        )
        self.assertTrue(
            self.hub.subscribe(ALT, "p_b", handler_b, granularity="agent",
                               scope=scope_of())
        )
        t0 = time.monotonic()
        r = self.hub.process(SID, "seed-x", scope_of(), timeout_s=2.0)
        dt = time.monotonic() - t0
        self.assertEqual(r, "a<b<from-b>>")
        self.assertLess(dt, 1.0, "环应以超时兜底有界收敛")
        self.assertGreaterEqual(self.counts()["timeout"], 1)

    def test_same_instance_cross_station_reentrancy_bounded(self):
        """同实例跨站重入（两站同 plugin+同 scope 共实例）：F1 防重入 bypass 立即放行 + 计数。"""
        inner = []

        def handler_x(req):
            if req.data.startswith("outer"):
                inner.append(
                    self.hub.process(ALT, "inner-y", scope_of(), timeout_s=0.15)
                )
                return "x-done"
            return None

        def handler_y(req):
            return "y-done"

        # 同 plugin_id + 同粒度 + 同 scope → 两站订阅共用同一实例
        self.assertTrue(
            self.hub.subscribe(SID, "p_same", handler_x, granularity="agent",
                               scope=scope_of())
        )
        self.assertTrue(
            self.hub.subscribe(ALT, "p_same", handler_y, granularity="agent",
                               scope=scope_of())
        )
        same = [i for i in self.reg.instances() if i.plugin_id == "p_same"]
        self.assertEqual(len(same), 1, "两站订阅应共用同一实例")
        self.assertEqual(
            self.hub.resolve(SID, scope_of()).inst_key,
            self.hub.resolve(ALT, scope_of()).inst_key,
        )

        t0 = time.monotonic()
        r = self.hub.process(SID, "outer-1", scope_of(), timeout_s=1.5)
        dt = time.monotonic() - t0
        self.assertEqual(r, "x-done")
        self.assertLess(dt, 0.12, "同实例重入应立即 bypass（不等待）")
        self.assertEqual(inner, ["inner-y"])
        c = self.counts()
        self.assertEqual(c["reentrant_bypass"], 1)
        self.assertEqual(c["requests"], 1)
        self.assertEqual(c["timeout"], 0)


# ======================================================================
# 六、观测：进度通道
# ======================================================================
class TestStationProgressChannel(StationTestBase):

    def test_progress_channel(self):
        """等待期进度通道登记/活跃/完成（runs_registered/finished/active）。"""
        def handler(req):
            time.sleep(0.25)
            return "done"

        self.assertTrue(self.subscribe(handler))
        holder = {}

        def waiter():
            holder["r"] = self.hub.process(SID, "x", scope_of(), timeout_s=3.0)

        th = threading.Thread(target=waiter, daemon=True)
        th.start()
        time.sleep(0.08)
        snap = self.hub.stats()
        self.assertGreaterEqual(snap["progress"]["runs_registered"], 1)
        self.assertEqual(snap["progress"]["runs_active"], 1,
                         "等待中应有 1 个活跃 run（进度通道观测）")
        th.join(timeout=3.0)
        self.assertEqual(holder.get("r"), "done")
        after = self.hub.stats()["progress"]
        self.assertGreaterEqual(after["runs_finished"], 1)
        self.assertEqual(after["runs_active"], 0, "完成后应无活跃 run")


if __name__ == "__main__":
    unittest.main()
