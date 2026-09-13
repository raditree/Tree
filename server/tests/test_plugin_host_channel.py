r"""二期 M2 专项：宿主通道 CH 组（独立验证 · 矩阵 CH1–CH8）。

独立性（与实现方自测 test_plugin_host_core.py 互补、不重复）：
- CH1/CH3 全链序列 + 计数账本（start→status→stop 逐步对账）；
- CH3 边界：lost 会话再 start → 不复用、新会话替换（重连重建语义）；
- CH4 边界：reconcile 探测上限（>16 lost → 单轮 ≤16 防风暴，逐轮收敛）；
- CH6 传输异常（executor raise）→ fail-closed 且异常不外抛（stop 异常路径补标
  lost——写路径三失败分支一致，CH6 修正后口径）；
- 缩参三通道：env（PLUGIN_HOST_OP_TIMEOUT_S / STOP_WAIT_S）/ 构造 / 时钟注入
  （created_at / updated_at）；
- 观测：stats() lost/closed 汇总；并发 start 收敛（观测性，防孤儿）。

如实声明：真实反向 WS 帧往返（后端 ↔ 前端执行器）与分发层分支隔离
（ws.endpoints）由联调窗口 / 柳依前端单测覆盖；本文件以脚本化假执行器验证
通道状态机与门控语义。

运行：cd server && .venv\Scripts\python -m pytest tests\test_plugin_host_channel.py -q
"""

from __future__ import annotations

import os
import threading
import unittest

from plugin.host import (
    OP_HOST_START,
    OP_HOST_STATUS,
    OP_HOST_STOP,
    HostChannel,
)

U1 = "u1"
T1 = "t1"
T2 = "t2"


class ScriptedExecutor:
    """脚本化假执行器（记录调用；支持 list 顺序脚本与 raise 注入）。"""

    def __init__(self, script=None):
        self.calls = []
        self.script = {
            k: (list(v) if isinstance(v, list) else dict(v))
            for k, v in dict(script or {}).items()
        }
        self.raise_on = set()
        self.delay_s = 0.0

    def request(self, ws_manager, user_id, payload, timeout=None, team_id=""):
        import time as _t

        if self.delay_s:
            _t.sleep(self.delay_s)
        self.calls.append(
            {
                "user_id": user_id,
                "op": payload.get("op"),
                "payload": dict(payload),
                "timeout": timeout,
                "team_id": team_id,
            }
        )
        op = payload.get("op")
        if op in self.raise_on:
            raise RuntimeError("injected-transport-error")
        val = self.script.get(op, {})
        if isinstance(val, list):
            return dict(val.pop(0)) if val else {}
        return dict(val) if isinstance(val, dict) else {}


def _make_channel(**kw):
    kw.setdefault("enabled_fn", lambda: True)
    kw.setdefault("op_timeout_s", 0.5)
    kw.setdefault("stop_wait_s", 0.5)
    return HostChannel(**kw)


class HostChannelTestBase(unittest.TestCase):
    def setUp(self):
        self.ch = _make_channel()
        self.ex = ScriptedExecutor()
        self.ws = object()

    def tearDown(self):
        self.ch.reset()

    def _start(self, key="k1", sid="phs_1", team=T1, user=U1):
        if OP_HOST_START not in self.ex.script:
            self.ex.script[OP_HOST_START] = []
        val = self.ex.script[OP_HOST_START]
        if not isinstance(val, list):
            val = [val]
            self.ex.script[OP_HOST_START] = val
        val.append({"host_session_id": sid})
        return self.ch.start_session(self.ex, self.ws, user, key, team_id=team)


class TestFullChain(unittest.TestCase):
    """CH1/CH3：全链序列 + 计数账本。"""

    def setUp(self):
        self.ch = _make_channel()
        self.ex = ScriptedExecutor(
            {
                OP_HOST_START: {"host_session_id": "phs_1"},
                OP_HOST_STATUS: {"state": "running"},
                OP_HOST_STOP: {"ok": True},
            }
        )
        self.ws = object()

    def tearDown(self):
        self.ch.reset()

    def test_ch1_full_chain_ledger(self):
        """start→status(running)→stop 全链；op 顺序与分类计数逐步对账。"""
        r1 = self.ch.start_session(self.ex, self.ws, U1, "k1", team_id=T1)
        self.assertEqual(r1["host_session_id"], "phs_1")
        r2 = self.ch.query_status(self.ex, self.ws, U1, "phs_1", team_id=T1)
        self.assertEqual(r2["state"], "running")
        r3 = self.ch.stop_session(self.ex, self.ws, U1, "phs_1", team_id=T1)
        self.assertTrue(r3["ok"])
        sess = self.ch.get_session("phs_1")
        self.assertEqual(sess.state, "closed")
        self.assertFalse(sess.lost)
        # op 顺序
        self.assertEqual(
            [c["op"] for c in self.ex.calls],
            [OP_HOST_START, OP_HOST_STATUS, OP_HOST_STOP],
        )
        # 计数账本
        c = self.ch.stats()["counts"]
        self.assertEqual(c["started"], 1)
        self.assertEqual(c["status_ok"], 1)
        self.assertEqual(c["stopped"], 1)
        self.assertEqual(c["reused"], 0)
        self.assertEqual(c["start_failed"], 0)
        self.assertEqual(c["stop_failed"], 0)
        self.assertEqual(c["rejected_invalid"], 0)
        self.assertEqual(c["rejected_owner"], 0)

    def test_ch3_lost_then_restart_new_session(self):
        """lost 会话再 start：不复用、发新 op、旧会话被替换（重连重建）。"""
        self.ex.script[OP_HOST_START] = [
            {"host_session_id": "phs_a"},
            {"host_session_id": "phs_b"},
        ]
        r1 = self.ch.start_session(self.ex, self.ws, U1, "k1", team_id=T1)
        self.assertEqual(r1["host_session_id"], "phs_a")
        self.assertEqual(self.ch.mark_lost(U1, [T1]), 1)
        r2 = self.ch.start_session(self.ex, self.ws, U1, "k1", team_id=T1)
        self.assertEqual(r2["host_session_id"], "phs_b")
        self.assertFalse(r2.get("reused"))
        self.assertIsNone(self.ch.get_session("phs_a"))
        self.assertIsNotNone(self.ch.get_session("phs_b"))
        self.assertEqual(self.ch.stats()["counts"]["started"], 2)
        self.assertEqual(len(self.ex.calls), 2)  # 未复用 → 两个 start op


class TestReconcileCapAndStats(unittest.TestCase):
    """CH4 边界与观测汇总。"""

    def setUp(self):
        self.ch = _make_channel()
        self.ex = ScriptedExecutor()
        self.ws = object()

    def tearDown(self):
        self.ch.reset()

    def test_ch4_reconcile_probe_cap(self):
        """20 个 lost → 单轮探测 ≤ 16（防风暴），第二轮收敛剩余 4。"""
        self.ex.script[OP_HOST_START] = []
        for i in range(20):
            self.ex.script[OP_HOST_START].append(
                {"host_session_id": f"phs_{i:02d}"}
            )
        for i in range(20):
            self.ch.start_session(self.ex, self.ws, U1, f"k{i:02d}", team_id=T1)
        self.assertEqual(self.ch.mark_lost(U1, [T1]), 20)
        self.ex.script[OP_HOST_STATUS] = {"state": "running"}
        out = self.ch.reconcile(self.ex, self.ws, U1, T1)
        self.assertEqual(out["probed"], 16)
        self.assertEqual(out["running"], 16)
        self.assertEqual(self.ch.stats()["counts"]["reconcile_probed"], 16)
        # 第二轮：剩余 4 个
        out2 = self.ch.reconcile(self.ex, self.ws, U1, T1)
        self.assertEqual(out2["probed"], 4)
        # 显式缩参（max_probe）可再限：重新标记全部 lost 后单轮仅探测 2
        self.assertEqual(self.ch.mark_lost(U1, [T1]), 20)  # 已恢复 running → 重标
        self.assertEqual(self.ch.mark_lost(U1, [T1]), 0)  # 幂等：已 lost 再标 0
        out3 = self.ch.reconcile(self.ex, self.ws, U1, T1, max_probe=2)
        self.assertEqual(out3["probed"], 2)

    def test_stats_lost_closed_sums(self):
        """stats()：in_flight / lost / closed 汇总随状态迁移。"""
        self.ex.script[OP_HOST_START] = [
            {"host_session_id": "phs_1"},
            {"host_session_id": "phs_2"},
        ]
        self.ch.start_session(self.ex, self.ws, U1, "k1", team_id=T1)
        self.ch.start_session(self.ex, self.ws, U1, "k2", team_id=T1)
        st = self.ch.stats()
        self.assertEqual(st["sessions"], 2)
        self.assertEqual(st["in_flight"], 2)
        self.assertEqual(st["lost"], 0)
        self.assertEqual(st["closed"], 0)
        self.ch.mark_lost(U1, [T1])
        st = self.ch.stats()
        self.assertEqual(st["in_flight"], 0)
        self.assertEqual(st["lost"], 2)
        self.ex.script[OP_HOST_STOP] = {"ok": True}
        self.ch.stop_session(self.ex, self.ws, U1, "phs_1", team_id=T1)
        st = self.ch.stats()
        self.assertEqual(st["closed"], 1)
        self.assertEqual(st["lost"], 1)


class TestFailClosedTransport(unittest.TestCase):
    """CH6：传输异常 fail-closed（异常不外抛；stop 异常路径补标 lost——修正后口径）。"""

    def setUp(self):
        self.ch = _make_channel()
        self.ex = ScriptedExecutor()
        self.ws = object()

    def tearDown(self):
        self.ch.reset()

    def test_ch6_executor_raise_fail_closed(self):
        """executor raise：三操作均返回 error、不外抛、计数递增、主流程无感。"""
        # start 异常
        self.ex.raise_on = {OP_HOST_START}
        r = self.ch.start_session(self.ex, self.ws, U1, "k1", team_id=T1)
        self.assertIn("error", r)
        self.assertEqual(self.ch.stats()["counts"]["start_failed"], 1)
        self.assertEqual(self.ch.list_sessions(), [])
        # status 异常（先正常建会话）
        self.ex.raise_on = set()
        self.ex.script[OP_HOST_START] = {"host_session_id": "phs_1"}
        self.ch.start_session(self.ex, self.ws, U1, "k1", team_id=T1)
        self.ex.raise_on = {OP_HOST_STATUS}
        r2 = self.ch.query_status(self.ex, self.ws, U1, "phs_1", team_id=T1)
        self.assertIn("error", r2)
        self.assertEqual(self.ch.stats()["counts"]["status_failed"], 1)
        # stop 异常（修正后口径：写路径三失败分支一致标 lost——异常路径与
        # "无执行器"/"宿主返回 error"对齐，交重连对账；下方断言核对）
        self.ex.raise_on = {OP_HOST_STOP}
        r3 = self.ch.stop_session(self.ex, self.ws, U1, "phs_1", team_id=T1)
        self.assertFalse(r3["ok"])
        self.assertEqual(self.ch.stats()["counts"]["stop_failed"], 1)
        sess = self.ch.get_session("phs_1")
        self.assertEqual(sess.state, "running")
        # CH6 修正（2026-09-13，栖迟裁定落地）：写路径三失败分支一致标 lost——
        # 异常路径与"无执行器"/"宿主返回 error"对齐（交重连对账）。
        self.assertTrue(sess.lost)


class TestInjectionChannels(unittest.TestCase):
    """缩参三通道：env / 构造 / 时钟注入。"""

    def test_env_params_readable(self):
        """env 通道：PLUGIN_HOST_OP_TIMEOUT_S / STOP_WAIT_S 生效并可从 stats 读取。"""
        old = {
            k: os.environ.get(k)
            for k in ("PLUGIN_HOST_OP_TIMEOUT_S", "PLUGIN_HOST_STOP_WAIT_S")
        }
        os.environ["PLUGIN_HOST_OP_TIMEOUT_S"] = "0.2"
        os.environ["PLUGIN_HOST_STOP_WAIT_S"] = "0.3"
        try:
            ch = HostChannel(enabled_fn=lambda: True)
            st = ch.stats()
            self.assertAlmostEqual(st["op_timeout_s"], 0.2, places=3)
            self.assertAlmostEqual(st["stop_wait_s"], 0.3, places=3)
        finally:
            for k, v in old.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v

    def test_ctor_params_override_env(self):
        """构造通道优先于 env；clamp 下限（≤0.01 → 0.01）。"""
        ch = HostChannel(
            enabled_fn=lambda: True, op_timeout_s=0.05, stop_wait_s=0.0
        )
        st = ch.stats()
        self.assertAlmostEqual(st["op_timeout_s"], 0.05, places=3)
        self.assertGreaterEqual(st["stop_wait_s"], 0.01)

    def test_now_fn_clock_injection(self):
        """时钟注入：created_at / updated_at 完全确定（假钟推进可控）。"""
        clock = {"t": 1000.0}
        ch = _make_channel(now_fn=lambda: clock["t"])
        ex = ScriptedExecutor(
            {
                OP_HOST_START: {"host_session_id": "phs_1"},
                OP_HOST_STOP: {"ok": True},
            }
        )
        ch.start_session(ex, object(), U1, "k1", team_id=T1)
        sess = ch.get_session("phs_1")
        self.assertEqual(sess.created_at, 1000.0)
        self.assertEqual(sess.updated_at, 1000.0)
        clock["t"] = 1234.5
        ch.stop_session(ex, object(), U1, "phs_1", team_id=T1)
        self.assertEqual(sess.updated_at, 1234.5)
        ch.reset()


class TestConcurrentStart(unittest.TestCase):
    """并发 start（观测性）：收敛后会话表无孤儿。"""

    def test_concurrent_start_convergence(self):
        """两线程同 key 并发 start → 表收敛（by_key/by_id 各一份、无孤儿）。"""
        ch = _make_channel()
        ex = ScriptedExecutor()
        ex.script[OP_HOST_START] = [
            {"host_session_id": "phs_A"},
            {"host_session_id": "phs_B"},
        ]
        ex.delay_s = 0.05  # 确保交叠窗口
        results = []

        def worker():
            results.append(
                ch.start_session(ex, object(), U1, "kc", team_id=T1)
            )

        threads = [threading.Thread(target=worker) for _ in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=3.0)
        # 表收敛：1 个 key、1 个 id（后者替换前者，无孤儿残留）
        sessions = ch.list_sessions()
        self.assertEqual(len(sessions), 1)
        sid = sessions[0]["host_session_id"]
        self.assertIn(sid, ("phs_A", "phs_B"))
        # 计数为观测事实（可能 2 次 op；依赖宿主侧幂等/对账兜底——记录性）
        self.assertGreaterEqual(ch.stats()["counts"]["started"], 1)
        ch.reset()


if __name__ == "__main__":
    unittest.main()
