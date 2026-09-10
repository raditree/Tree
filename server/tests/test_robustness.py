# -*- coding: utf-8 -*-
"""鲁棒性单测：按模型超时/重试、broker 清理、会话缓存 LRU、MCP 章节。

覆盖：
- LLMClientFactory：模型级 timeout_seconds / max_retries 覆盖应用级默认
- TeamMessageBroker.remove_agent：清理队列与 worker 注册（防注册表膨胀）
- session_cache LRU：超上限逐出最旧、命中刷新
- chat._build_mcp_tools_text：进程内服务列工具名 / stdio 服务只列名
- _build_agent_system_prompt：mcp_tools_text 注入「⑩b MCP 工具与外部服务」
"""

import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from config.models import ModelConfig  # noqa: E402


class TestLLMClientFactory(unittest.TestCase):
    def test_model_level_timeout_overrides_app_default(self):
        from llm.llm import LLMClientFactory

        mc = ModelConfig(
            name="local", base_url="http://local", api_key="k",
            model_id="local-llm",
            extra={"timeout_seconds": 1800, "max_retries": 0},
        )
        with patch("llm.llm.get_config",
                   return_value={"llm": {"timeout_seconds": 300,
                                         "max_retries": 1}}), \
             patch("llm.llm.OpenAI") as mock_openai:
            LLMClientFactory.create_client(mc)
        kwargs = mock_openai.call_args.kwargs
        self.assertEqual(kwargs["timeout"], 1800)
        self.assertEqual(kwargs["max_retries"], 0)

    def test_app_level_fallback(self):
        from llm.llm import LLMClientFactory

        mc = ModelConfig(
            name="api", base_url="http://api", api_key="k",
            model_id="api-model",
            extra={"max_seqlen": 8192},
        )
        with patch("llm.llm.get_config",
                   return_value={"llm": {"timeout_seconds": 300,
                                         "max_retries": 1}}), \
             patch("llm.llm.OpenAI") as mock_openai:
            LLMClientFactory.create_client(mc)
        kwargs = mock_openai.call_args.kwargs
        self.assertEqual(kwargs["timeout"], 300)
        self.assertEqual(kwargs["max_retries"], 1)


class TestBrokerRemoveAgent(unittest.TestCase):
    def test_remove_agent_drops_queue_and_worker_entries(self):
        from agent.team_broker import TeamMessageBroker

        async def _process(payload, queue):
            pass

        broker = TeamMessageBroker(process_fn=_process)
        broker.dispatch(("u1", "m1"), {"content": "1"})
        broker.dispatch(("u1", "m1"), {"content": "2"})
        broker.dispatch(("u1", "m2"), {"content": "x"})

        cleared = broker.remove_agent("u1", "m1")
        self.assertEqual(cleared, 2)
        self.assertNotIn(("u1", "m1"), broker._queues)
        self.assertNotIn(("u1", "m1"), broker._workers)
        # 其他成员不受影响
        self.assertIn(("u1", "m2"), broker._queues)
        self.assertEqual(broker._queues[("u1", "m2")].qsize(), 1)

    def test_remove_agent_unknown_noop(self):
        from agent.team_broker import TeamMessageBroker

        broker = TeamMessageBroker(process_fn=None)
        self.assertEqual(broker.remove_agent("u1", "ghost"), 0)


class TestRateLimitRemoveAgent(unittest.TestCase):
    def test_remove_agent_drops_limiter(self):
        import llm.rate_limit as rl

        with rl._registry_lock:
            rl._limiters[("u1", "a1")] = rl.AgentRateLimiter()
            rl._limiters[("u1", "a2")] = rl.AgentRateLimiter()
        rl.remove_agent("u1", "a1")
        with rl._registry_lock:
            self.assertNotIn(("u1", "a1"), rl._limiters)
            self.assertIn(("u1", "a2"), rl._limiters)
        # 清理残留
        with rl._registry_lock:
            rl._limiters.clear()


class TestSessionCacheLRU(unittest.TestCase):
    def test_lru_eviction(self):
        import data.session_cache as sc

        with patch.object(sc, "MAX_SESSIONS", 3):
            with sc._lock:
                sc._sessions.clear()
            sc.set_session("u1", "a1", object(), "s1")
            sc.set_session("u1", "a2", object(), "s2")
            sc.set_session("u1", "a3", object(), "s3")
            # 命中 s1 刷新位置（s2 成为最旧）
            sc.get_session("u1", "a1", "s1")
            sc.set_session("u1", "a4", object(), "s4")  # 逐出 s2
            self.assertIsNone(sc.get_session("u1", "a2", "s2"))
            self.assertIsNotNone(sc.get_session("u1", "a1", "s1"))
            self.assertIsNotNone(sc.get_session("u1", "a4", "s4"))
            with sc._lock:
                sc._sessions.clear()

    def test_session_count(self):
        import data.session_cache as sc

        with patch.object(sc, "MAX_SESSIONS", 100):
            with sc._lock:
                sc._sessions.clear()
            sc.set_session("u1", "a1", object(), "s1")
            self.assertEqual(sc.session_count(), 1)
            with sc._lock:
                sc._sessions.clear()


class TestMcpServiceScope(unittest.TestCase):
    """第三方 MCP 服务的执行落点判定（local / ssh 隧道 vs 后端直连）。"""

    def test_scope_server_always_backend(self):
        from tool import _resolve_service_host

        for mode in ("cloud", "local", "ssh"):
            self.assertEqual(_resolve_service_host("server", mode), "server")

    def test_scope_unspecified_follows_mode(self):
        from tool import _resolve_service_host

        self.assertEqual(_resolve_service_host("", "cloud"), "server")
        self.assertEqual(_resolve_service_host("", "local"), "tunnel")
        self.assertEqual(_resolve_service_host("", "ssh"), "tunnel")

    def test_scope_must_match_current_mode(self):
        from tool import _resolve_service_host

        self.assertEqual(_resolve_service_host("local", "local"), "tunnel")
        self.assertEqual(_resolve_service_host("ssh", "ssh"), "tunnel")
        self.assertIsNone(_resolve_service_host("ssh", "local"))
        self.assertIsNone(_resolve_service_host("local", "cloud"))

    def test_build_tunnel_requires_local_or_ssh_with_deps(self):
        from tool import _build_mcp_tunnel

        self.assertIsNone(_build_mcp_tunnel("cloud", "u1", "t1", None, None))
        self.assertIsNone(_build_mcp_tunnel("local", "u1", "t1", None, None))
        tunnel = _build_mcp_tunnel("ssh", "u1", "t1", None, None)
        # state 在单测环境未装配执行器 → 无隧道可用
        self.assertIsNone(tunnel)


class TestMcpPromptChapter(unittest.TestCase):
    def _fake_manager(self):
        mgr = MagicMock()
        mgr.list_services.return_value = ["workspace", "external"]
        mgr.services = {
            "workspace": {
                "server_factory": lambda: None,
                "tools": [
                    {"name": "embed_search",
                     "mcp_name": "mcp__workspace__embed_search",
                     "description": "检索"},
                ],
            },
            "external": {
                "server_factory": None,
                "command": "npx",
                "args": [],
                "env": {},
                "tools": [{"name": "t1"}],
            },
        }
        return mgr

    def test_build_mcp_tools_text_in_process_lists_names(self):
        from agent.chat import _build_mcp_tools_text

        text = _build_mcp_tools_text(self._fake_manager())
        self.assertIn("workspace", text)
        self.assertIn("mcp__workspace__embed_search", text)
        # stdio 服务：只列服务名 + mcp help 提示，不展开
        self.assertIn("external", text)
        self.assertIn("mcp", text)

    def test_build_mcp_tools_text_none_or_empty(self):
        from agent.chat import _build_mcp_tools_text

        self.assertEqual(_build_mcp_tools_text(None), "")
        mgr = MagicMock()
        mgr.list_services.return_value = []
        self.assertEqual(_build_mcp_tools_text(mgr), "")

    def test_build_mcp_tools_text_annotates_tunnel_host(self):
        from agent.chat import _build_mcp_tools_text

        mgr = self._fake_manager()
        mgr.services["external"]["tunnel"] = MagicMock(mode="ssh")
        text = _build_mcp_tools_text(mgr)
        self.assertIn("远端主机执行", text)

        mgr.services["external"]["tunnel"] = MagicMock(mode="local")
        self.assertIn("本机执行", _build_mcp_tools_text(mgr))

    def test_system_prompt_injects_chapter(self):
        from agent.chat import _build_agent_system_prompt

        prompt = _build_agent_system_prompt(
            "ws1", user_id="u1", agent_id="a1", team_id="a1",
            session_id="s1",
            extra_info={"identity": "顶层 Agent", "memory": "",
                        "exec_mode": "local"},
            mcp_tools_text="可用 MCP 服务与工具：\n- 服务 `workspace`",
        )
        self.assertIn("⑩b MCP 工具与外部服务", prompt)
        self.assertIn("服务 `workspace`", prompt)

        prompt2 = _build_agent_system_prompt(
            "ws1", user_id="u1", agent_id="a1", team_id="a1",
            session_id="s1",
            extra_info={"identity": "顶层 Agent", "memory": "",
                        "exec_mode": "local"},
        )
        self.assertNotIn("⑩b MCP 工具与外部服务", prompt2)


if __name__ == "__main__":
    unittest.main()
