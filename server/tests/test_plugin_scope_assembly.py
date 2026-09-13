# -*- coding: utf-8 -*-
"""插件埋点 scope 装配链测试（选项A补线）：四元组装配 → 埋点事件 → 实例命中。

覆盖：
- ``AgentLLMSession`` 携带 team_id/session_id（缺省空串，向后兼容）；
- 装配四元组 → ``safe_publish("tool.call.completed", ...)`` → team 级 / session 级实例命中；
- 跨 team / 跨 session 与"未装配空字段"两条拒投路径（fail-closed 语义不回归）。

覆盖边界（诚实声明）：``llm.py::_run_completion_loop`` 内联埋点代码无法在单测中
直接触发——本测试以"**与埋点逐字同式的 scope 提取**（四字段 getattr）+ 同一
``safe_publish`` 入口"覆盖"装配 → 事件 → 命中"链路；内联段与该表达式的同源性
由代码审查保证（埋点处即刻可核对）。三个生产构造点的实参传递不在本测试范围
（由改动 diff + .output 交付说明列证）。

执行（server 目录下）：
    .venv\\Scripts\\python -m pytest tests/test_plugin_scope_assembly.py -v
"""

import sys
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

try:
    import plugin  # noqa: E402
    from config.models import ModelConfig  # noqa: E402
    from llm.llm import AgentLLMSession  # noqa: E402

    PLUGIN_AVAILABLE = True
    IMPORT_ERROR = ""
except Exception as _e:  # noqa: BLE001 —— 依赖未就绪时整文件 skip
    plugin = None  # type: ignore
    ModelConfig = None  # type: ignore
    AgentLLMSession = None  # type: ignore
    PLUGIN_AVAILABLE = False
    IMPORT_ERROR = f"{type(_e).__name__}: {_e}"

_SKIP_REASON = f"依赖未就绪: {IMPORT_ERROR}"
_WAIT_TIMEOUT = 3.0
_NEGATIVE_WINDOW = 0.35


def _wait_until(predicate, timeout=_WAIT_TIMEOUT):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.005)
    return False


def _make_session(user_id="u1", agent_id="a1", team_id="", session_id=""):
    """构造真实 AgentLLMSession（不注册工具、不联网）。"""
    mc = ModelConfig(
        name="t",
        base_url="http://localhost:8000",
        api_key="k",
        model_id="m",
        extra={"max_seqlen": 65536},
    )
    return AgentLLMSession(
        model_config=mc,
        workspace_id="ws",
        system_prompt="",
        user_id=user_id,
        agent_id=agent_id,
        team_id=team_id,
        session_id=session_id,
    )


def _scope_of(session):
    """与 llm.py 埋点逐字同式的 scope 提取（四字段 getattr）。"""
    return {
        "user_id": str(getattr(session, "user_id", "") or ""),
        "team_id": str(getattr(session, "team_id", "") or ""),
        "agent_id": str(getattr(session, "agent_id", "") or ""),
        "session_id": str(getattr(session, "session_id", "") or ""),
    }


@unittest.skipUnless(PLUGIN_AVAILABLE, _SKIP_REASON)
class TestScopeAssembly(unittest.TestCase):
    def setUp(self):
        plugin.set_enabled(True)
        self.bus = plugin.get_bus()
        self.registry = plugin.get_registry()

    def tearDown(self):
        plugin.shutdown()

    def _register(self, pid, granularity, scope, got):
        return self.registry.register(
            pid,
            lambda e: got.append(e),
            granularity=granularity,
            scope=scope,
            event_types={"tool.call.completed"},
        )

    # ------------------------------------------------------------------
    # 1) 装配：AgentLLMSession 携带四元组
    # ------------------------------------------------------------------
    def test_session_carries_scope_fields(self):
        """AgentLLMSession 携带 team_id/session_id；缺省为空串（向后兼容）。"""
        s = _make_session(team_id="t1", session_id="s1")
        self.assertEqual(s.user_id, "u1")
        self.assertEqual(s.team_id, "t1")
        self.assertEqual(s.agent_id, "a1")
        self.assertEqual(s.session_id, "s1")
        self.assertEqual(_scope_of(s)["team_id"], "t1")

        s2 = _make_session()  # 未装配：缺省空串
        self.assertEqual(s2.team_id, "")
        self.assertEqual(s2.session_id, "")

    # ------------------------------------------------------------------
    # 2) 装配 → 埋点事件 → team 级 / session 级实例命中
    # ------------------------------------------------------------------
    def test_assembled_scope_hits_team_and_session_instances(self):
        """装配后的真实四元组事件，team 级与 session 级实例均应命中。"""
        team_got, sess_got = [], []
        self._register(
            "t.assembly.team", "team",
            {"user_id": "u1", "team_id": "t1"}, team_got,
        )
        self._register(
            "t.assembly.sess", "session",
            {"user_id": "u1", "team_id": "t1", "agent_id": "a1", "session_id": "s1"},
            sess_got,
        )

        s = _make_session(team_id="t1", session_id="s1")
        ok = plugin.safe_publish(
            "tool.call.completed",
            _scope_of(s),
            {"tool_name": "read", "ok": True},
            source="test.assembly",
        )
        self.assertTrue(ok, "safe_publish 应成功入队")
        self.assertTrue(_wait_until(lambda: len(team_got) >= 1), "team 级实例未命中")
        self.assertTrue(_wait_until(lambda: len(sess_got) >= 1), "session 级实例未命中")
        self.assertEqual(team_got[0].scope["team_id"], "t1")
        self.assertEqual(sess_got[0].scope["session_id"], "s1")
        self.assertEqual(sess_got[0].payload.get("tool_name"), "read")

    # ------------------------------------------------------------------
    # 3) 拒投语义不回归：跨 team / 跨 session
    # ------------------------------------------------------------------
    def test_cross_team_and_session_not_delivered(self):
        """同 user/agent、跨 team + 跨 session 的事件不得投递（fail-closed）。"""
        got = []
        self._register(
            "t.assembly.guard", "session",
            {"user_id": "u1", "team_id": "t1", "agent_id": "a1", "session_id": "s1"},
            got,
        )
        ok = plugin.safe_publish(
            "tool.call.completed",
            {"user_id": "u1", "team_id": "t2", "agent_id": "a1", "session_id": "s2"},
            {"tool_name": "read", "ok": True},
            source="test.assembly",
        )
        self.assertTrue(ok)  # 事件本身合法（user_id 非空）；只是无匹配实例
        time.sleep(_NEGATIVE_WINDOW)
        self.assertEqual(len(got), 0, "跨 team/session 事件不应被投递")

    # ------------------------------------------------------------------
    # 4) 拒投语义不回归：未装配（空字段）不命中声明该级的实例
    # ------------------------------------------------------------------
    def test_unassembled_empty_scope_fail_closed(self):
        """未装配（team/session 为空串）的事件不命中要求该字段的实例。

        这正是本补线要消除的场景：装配前恒空 → 恒不命中；装配后命中（用例 2）。
        """
        got = []
        self._register(
            "t.assembly.miss", "team",
            {"user_id": "u1", "team_id": "t1"}, got,
        )
        s = _make_session()  # team_id/session_id 均未装配
        ok = plugin.safe_publish(
            "tool.call.completed",
            _scope_of(s),
            {"tool_name": "read", "ok": True},
            source="test.assembly",
        )
        self.assertTrue(ok)
        time.sleep(_NEGATIVE_WINDOW)
        self.assertEqual(len(got), 0, "字段缺失应按 fail-closed 不投递")


if __name__ == "__main__":
    unittest.main()
