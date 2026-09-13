r"""处理站（半二期）链路测试：门面 safe_process 与结果门控衔接。

覆盖：
- 门面语义：总开关关闭零副作用（原值 + 组件未初始化）；开启后全链替换生效；
  站内部异常 fail-open（不抛出、原值放行）；
- 结果门控衔接：站处理后结果仍受工具结果大小门控（llm.py 单点替换语义）——
  处理后超长结果触发重定向（与 ``_maybe_redirect_result`` 同路径）；
- 示范插件 E2E：read 结果处理站（前缀替换 + 空串 passthrough）。

覆盖边界（如实声明）：llm.py 接入点内部两个"直通"条件（错误结果 /
AskUserQuestion 占位分支）无法在无 mock LLM 会话下单测直触，由代码核读与
独立复核覆盖（见 artifacts/test-report.md「覆盖边界」）。

运行：cd server && .venv\Scripts\python -m pytest tests\test_plugin_stations_link.py -q
"""

from __future__ import annotations

import unittest

import plugin
from config.models import ModelConfig
from llm.llm import RESULT_REDIRECT_THRESHOLD, AgentLLMSession
from plugin.plugins.read_station_demo import register_demo_plugin
from plugin.stations import STATION_READ_RESULT

SID = STATION_READ_RESULT


def _scope(**kw):
    base = {
        "user_id": "u1",
        "team_id": "t1",
        "agent_id": "a1",
        "session_id": "s1",
    }
    base.update(kw)
    return base


def _make_session(writer=None):
    """构造最小 AgentLLMSession（参照 test_tool_result_gate 的注入方式）。"""
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
        result_redirect_writer=writer,
    )


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
        plugin.set_enabled(self._saved_enabled)


class TestSafeProcessFacade(PluginFacadeBase):

    def test_disabled_zero_side_effect(self):
        """总开关关闭：原值返回 + 站组件未初始化（零副作用）。"""
        r = plugin.safe_process(SID, "x", _scope())
        self.assertEqual(r, "x")
        self.assertIsNone(plugin._stations, "关闭态不应初始化站组件")

    def test_enabled_replace_end_to_end(self):
        """开启 + 订阅：safe_process 全链替换生效。"""
        plugin.set_enabled(True)
        hub = plugin.get_stations()
        self.assertIsNotNone(hub)
        ok = hub.subscribe(
            SID, "p_link", lambda req: "P:" + req.data,
            granularity="agent", scope=_scope(),
        )
        self.assertTrue(ok)
        r = plugin.safe_process(SID, "hello", _scope(), timeout_s=1.0)
        self.assertEqual(r, "P:hello")

    def test_internal_error_fail_open(self):
        """站内部异常：门面兜底 fail-open（不抛出、返回原值）。"""
        plugin.set_enabled(True)
        hub = plugin.get_stations()
        self.assertTrue(
            hub.subscribe(SID, "p_boom", lambda req: "x",
                          granularity="agent", scope=_scope())
        )
        original = hub.process

        def _boom(*args, **kwargs):
            raise RuntimeError("station exploded")

        hub.process = _boom
        try:
            r = plugin.safe_process(SID, "orig", _scope())
        finally:
            hub.process = original
        self.assertEqual(r, "orig")

    def test_demo_plugin_end_to_end(self):
        """示范插件 E2E：非空加前缀（替换）/ 空串 passthrough（None 语义）。"""
        plugin.set_enabled(True)
        demo = register_demo_plugin(granularity="agent", scope=_scope(), pin=True)
        self.assertIsNotNone(demo, "示范插件订阅应成功")
        out = plugin.safe_process(SID, "hello", _scope(), timeout_s=1.0)
        self.assertIn("[处理站示范]", out)
        self.assertIn("hello", out)
        out_empty = plugin.safe_process(SID, "", _scope(), timeout_s=1.0)
        self.assertEqual(out_empty, "")
        self.assertEqual(demo.processed, 1)
        self.assertEqual(demo.passthrough, 1)


class TestProcessedResultGate(PluginFacadeBase):
    """站处理后结果仍受工具结果大小门控（单点替换语义的衔接验证）。"""

    def test_processed_long_result_hits_redirect_gate(self):
        """放大处理后超长 → 重定向门控命中（替换值不豁免门控）。"""
        plugin.set_enabled(True)
        hub = plugin.get_stations()
        amplified = "X" * (RESULT_REDIRECT_THRESHOLD + 100)
        self.assertTrue(
            hub.subscribe(
                SID, "p_amp", lambda req: amplified,
                granularity="agent", scope=_scope(),
            )
        )
        processed = plugin.safe_process(SID, "seed", _scope(), timeout_s=1.0)
        self.assertEqual(processed, amplified)

        captured = []
        session = _make_session(
            writer=lambda rel, content: captured.append((rel, content))
        )
        out = session._maybe_redirect_result("read", processed)
        self.assertIn("[工具结果已重定向]", out)
        self.assertNotEqual(out, processed)
        self.assertEqual(len(captured), 1)
        self.assertEqual(captured[0][1], amplified)
        self.assertTrue(captured[0][0].startswith(".self/results/"))


if __name__ == "__main__":
    unittest.main()
