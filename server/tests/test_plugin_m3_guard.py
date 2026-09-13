r"""工程组（M3）专项测试：防呆（EN2）/ 链深上限（EN5）/ F5 日志前缀（EN7）/
read encoding（EN6）与计数键就绪（EN1 补）。

范围与对照：
- 反例矩阵 ``agentspace/.hard/20260913-plugin-phase2/artifacts/test-reverse-matrix-v2.md``
  §4：EN2 防呆（A+B 判据 / 对偶不误击 / 与 F1 不串计）· EN5 链深上限（边界族
  chain_max=1/2/3）· EN7 F5 统一前缀 ``[plugin:station:<site>]`` · EN6 read encoding
  （参数生效 / 非法 fail-open / 旧 provider 兼容）；
- 实现：``stations.py``（``bind_main_loop_ident`` / ``_chain_*`` / ``_flog``）、
  ``sdk.py``（``workspace_read(..., encoding=...)``）；
- 缩参注入（构造参数优先）：``StationsHub(chain_max=...)``；防呆 A 判据用
  ``bind_main_loop_ident()`` 显式绑定当前线程（模拟主 loop），B 判据用
  ``asyncio.run`` 内调用验证。

运行：cd server && .venv\Scripts\python -m pytest tests\test_plugin_m3_guard.py -q
"""

from __future__ import annotations

import asyncio
import threading
import time
import unittest

from plugin.registry import PluginRegistry
from plugin.sdk import PluginSDK, reset_injections, set_io_provider
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


def _mk_hub(**kwargs):
    """独立组件（不依赖全局门面）；registry.shutdown 由调用方 cleanup。"""
    reg = PluginRegistry()
    hub = StationsHub(reg, watchdog=ProgressWatchdog(), **kwargs)
    return reg, hub


class LoopGuardTests(unittest.TestCase):
    """EN2：防呆判据 A/B、对偶不误击、与 F1 不串计。"""

    def test_a_criterion_bypass_and_no_side_effects(self):
        """A：bind 主 loop ident（当前线程）→ loop_bypass 直通、不投递、不阻塞。"""
        reg, hub = _mk_hub()
        self.addCleanup(reg.shutdown)
        hub.bind_main_loop_ident()  # 当前线程视为主 loop 线程（模拟）
        called = []

        def _h(req):
            called.append(1)
            return "X"

        hub.subscribe(SID, "guardplug", _h, granularity="agent", scope=scope_of())
        t0 = time.perf_counter()
        out = hub.process(SID, "payload", scope_of())
        dt = time.perf_counter() - t0
        self.assertEqual(out, "payload")
        self.assertEqual(called, [])
        self.assertEqual(hub.stats()["counts"]["loop_bypass"], 1)
        self.assertLess(dt, 1.0)  # 不投递、不等待（近零耗时）

    def test_b_criterion_inside_running_loop(self):
        """B：running-loop 检测（未 bind 亦命中）→ loop_bypass。"""
        reg, hub = _mk_hub()
        self.addCleanup(reg.shutdown)
        called = []

        def _h(req):
            called.append(1)
            return "X"

        hub.subscribe(SID, "guardplug2", _h, granularity="agent", scope=scope_of())
        result = {}

        async def _in_loop():
            result["out"] = hub.process(SID, "payload2", scope_of())

        asyncio.run(_in_loop())
        self.assertEqual(result["out"], "payload2")
        self.assertEqual(called, [])
        self.assertEqual(hub.stats()["counts"]["loop_bypass"], 1)

    def test_dual_no_false_positive_from_worker_thread(self):
        """对偶：工具/worker 线程调用不误击（无 loop_bypass，正常投递）。"""
        reg, hub = _mk_hub()
        self.addCleanup(reg.shutdown)
        hub.bind_main_loop_ident()  # 绑定测试线程；新线程 ident 不同
        called = []

        def _h(req):
            called.append(1)
            return "Y"

        hub.subscribe(SID, "guardplug3", _h, granularity="agent", scope=scope_of())
        out = {}

        def _call():
            out["res"] = hub.process(SID, "z", scope_of())

        t = threading.Thread(target=_call)
        t.start()
        t.join(timeout=5)
        self.assertEqual(out.get("res"), "Y")
        self.assertEqual(called, [1])
        self.assertEqual(hub.stats()["counts"]["loop_bypass"], 0)

    def test_f1_still_reentrant_and_not_cross_counted(self):
        """组合：worker 线程内同实例触发仍走 reentrant_bypass；两键不串计。"""
        reg, hub = _mk_hub()
        self.addCleanup(reg.shutdown)
        seen = []

        def handler(req):
            if not seen:
                seen.append("first")
                inner = hub.process(SID, "inner", scope_of())  # 同实例重入
                assert inner == "inner"
            return "outer"

        hub.subscribe(SID, "replug", handler, granularity="agent", scope=scope_of())
        out = hub.process(SID, "x", scope_of())
        self.assertEqual(out, "outer")
        counts = hub.stats()["counts"]
        self.assertEqual(counts["reentrant_bypass"], 1)
        self.assertEqual(counts["loop_bypass"], 0)


class ChainDepthTests(unittest.TestCase):
    """EN5：链深上限（跨实例环防护）——上限通过 / 达上限拦截（fail-open）。"""

    def _mk_chain(self, chain_max):
        """三层链 S1→S2→S3（独立实例）；返回 (hub, p3 调用记录)。"""
        reg = PluginRegistry()
        hub = StationsHub(reg, watchdog=ProgressWatchdog(), chain_max=chain_max)
        self.addCleanup(reg.shutdown)
        s2 = SID + ".s2"
        s3 = SID + ".s3"
        calls = []

        def p3(req):
            calls.append("p3")
            return "L3"

        def p2(req):
            return hub.process(s3, "d3", scope_of())

        def p1(req):
            return hub.process(s2, "d2", scope_of())

        hub.subscribe(s2, "cplug2", p2, granularity="agent", scope=scope_of())
        hub.subscribe(s3, "cplug3", p3, granularity="agent", scope=scope_of())
        hub.subscribe(SID, "cplug1", p1, granularity="agent", scope=scope_of())
        return hub, calls

    def test_chain_within_limit_passes(self):
        """chain_max=3：两层嵌套（< 上限）全部通过。"""
        hub, calls = self._mk_chain(3)
        self.assertEqual(hub.process(SID, "d1", scope_of()), "L3")
        self.assertEqual(calls, ["p3"])
        self.assertEqual(hub.stats()["counts"]["chain_bypass"], 0)

    def test_chain_over_limit_bypassed(self):
        """chain_max=2：第二级嵌套（≥ 上限）→ chain_bypass 放行（保留原值）。"""
        hub, calls = self._mk_chain(2)
        out = hub.process(SID, "d1", scope_of())
        # 第三层被放行：p2 收到原值 "d3"（未投递到 cplug3）
        self.assertEqual(out, "d3")
        self.assertEqual(calls, [])
        self.assertEqual(hub.stats()["counts"]["chain_bypass"], 1)

    def test_chain_limit_one_cuts_first_nesting(self):
        """chain_max=1：首级嵌套即达上限 → 立即放行。"""
        hub, calls = self._mk_chain(1)
        out = hub.process(SID, "d1", scope_of())
        self.assertEqual(out, "d2")
        self.assertEqual(calls, [])
        self.assertEqual(hub.stats()["counts"]["chain_bypass"], 1)


class F5LogTests(unittest.TestCase):
    """EN7：站日志统一前缀 ``[plugin:station:<site>]``（抽样：订阅/退订/异常）。"""

    def test_station_logs_have_unified_prefix(self):
        reg, hub = _mk_hub()
        self.addCleanup(reg.shutdown)
        with self.assertLogs("plugin.stations", level="INFO") as cm:
            hub.subscribe(
                SID, "logplug", lambda req: "ok", granularity="agent", scope=scope_of()
            )
            hub.process(SID, "d", scope_of())
            hub.unsubscribe(SID, "logplug")
        joined = "\n".join(cm.output)
        self.assertIn(f"[plugin:station:{SID}] 站订阅成功", joined)
        self.assertIn(f"[plugin:station:{SID}] 站显式退订", joined)

    def test_handler_error_log_has_prefix(self):
        reg, hub = _mk_hub()
        self.addCleanup(reg.shutdown)

        def bad(req):
            raise RuntimeError("x")

        hub.subscribe(SID, "logplug2", bad, granularity="agent", scope=scope_of())
        with self.assertLogs("plugin.stations", level="ERROR") as cm:
            hub.process(SID, "d", scope_of())
        self.assertIn("[plugin:station:", "\n".join(cm.output))


class ReadEncodingTests(unittest.TestCase):
    """EN6：SDK ``workspace_read`` encoding 可选参——生效 / 非法 fail-open / 兼容。"""

    def setUp(self):
        reset_injections()
        self.addCleanup(reset_injections)

    def _sdk(self):
        return PluginSDK(
            {"user_id": "u", "team_id": "t", "agent_id": "a", "session_id": "s"}
        )

    def test_encoding_param_effective_and_fail_open(self):
        calls = []

        class _IO:
            async def read_file(self, ws, path, encoding="utf-8"):
                calls.append((path, encoding))
                if encoding == "nope":
                    raise LookupError("unknown encoding: nope")
                return {"content": f"{path}@{encoding}"}

        set_io_provider(lambda user_id, mode_key: _IO())
        sdk = self._sdk()
        r1 = sdk.workspace_read("a.txt")
        self.assertEqual(r1["content"], "a.txt@utf-8")  # 缺省 utf-8（兼容）
        r2 = sdk.workspace_read("b.txt", encoding="gbk")
        self.assertEqual(r2["content"], "b.txt@gbk")  # 参数生效
        self.assertIn(("b.txt", "gbk"), calls)
        r3 = sdk.workspace_read("c.txt", encoding="nope")
        self.assertIn("error", r3)  # 非法编码 → fail-open（error dict，不抛出）

    def test_legacy_provider_without_encoding_accepted(self):
        class _OldIO:
            async def read_file(self, ws, path):
                return {"content": "legacy"}

        set_io_provider(lambda user_id, mode_key: _OldIO())
        r = self._sdk().workspace_read("d.txt", encoding="gbk")
        self.assertEqual(r["content"], "legacy")  # 兼容回退路径


class CountKeysTests(unittest.TestCase):
    """EN1 补：M3 新增计数键就绪（loop_bypass / chain_bypass）。"""

    def test_m3_count_keys_present(self):
        reg, hub = _mk_hub()
        self.addCleanup(reg.shutdown)
        counts = hub.stats()["counts"]
        self.assertEqual(counts.get("loop_bypass"), 0)
        self.assertEqual(counts.get("chain_bypass"), 0)
        hub._bump("loop_bypass")
        self.assertEqual(hub.stats()["counts"]["loop_bypass"], 1)
        hub.reset()
        self.assertEqual(hub.stats()["counts"]["loop_bypass"], 0)


if __name__ == "__main__":
    unittest.main()
