# -*- coding: utf-8 -*-
"""8 大项改造 REST API 层冒烟测试（plan 3 新增 REST 对应 R6/R4 风险）。

覆盖（对应 docs/test_report.md §4 风险 R4/R6/R2）：
- R6：PATCH /api/agents/{id}（改 model_id/system_prompt）、
      GET /api/agents/{id}/models-info（模型池 info + base_url 脱敏）、
      GET/POST/DELETE /api/mcp/services（列表含内置 / 注册回环 / 非法 400 / 内置删除 404）
- R4：GET /api/agents/{id}/teammates 优先 team_store 表；表空回退解析
      .self/team_roster.md 文件。
- R2：session_id 从用户消息透传到 _store_message（含默认会话回退与
      _dispatch_user_message 透传）。

隔离：临时目录重定位 data 模块 DB（不污染真实 conversations.db）。
"""
import asyncio
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import state  # noqa: E402
from fastapi import FastAPI  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

import data.agent_store as agent_store  # noqa: E402
import data.mcp_service_store as mcp_store  # noqa: E402
import data.team_store as team_store  # noqa: E402
from agent.routes import router as agent_router  # noqa: E402
from config.models import ModelConfig  # noqa: E402

USER = {"openid": "u-rest-test"}


def _redirect_db(tmpdir: Path) -> None:
    """将各 data 模块 DB 路径指向临时目录并重置初始化标记。"""
    for mod in (agent_store, mcp_store, team_store):
        mod._DB_PATH = tmpdir / "conversations.db"  # type: ignore[attr-defined]
        mod._initialized = False  # type: ignore[attr-defined]


class RestApiBase(unittest.TestCase):
    """为每个测试创建独立临时 DB + 独立 TestClient（override 认证）。"""

    _REDIRECT_MODS = (agent_store, mcp_store, team_store)

    def setUp(self):
        self._tmp = Path(tempfile.mkdtemp(prefix="trae_rest_"))
        # 记录原始 DB 路径，tearDown 恢复，避免污染其他测试文件
        self._orig_db = {m: m._DB_PATH for m in self._REDIRECT_MODS}
        _redirect_db(self._tmp)
        state.model_configs = {
            "flash": ModelConfig(
                name="Flash", base_url="http://x/secret", api_key="k",
                model_id="flash", if_vision=True, thinking=True,
                extra={"max_seqlen": 8192},
            ),
        }
        app = FastAPI()
        app.include_router(agent_router)
        from ws.auth import get_current_user

        app.dependency_overrides[get_current_user] = lambda: dict(USER)
        self.client = TestClient(app)

    def tearDown(self):
        for m in self._REDIRECT_MODS:
            m._DB_PATH = self._orig_db[m]
            m._initialized = False
        shutil.rmtree(self._tmp, ignore_errors=True)


class TestPatchAgent(RestApiBase):
    def test_patch_model_and_prompt(self):
        agent = agent_store.create_agent(USER["openid"], "测试", "flash")
        r = self.client.patch(
            f"/api/agents/{agent['id']}",
            json={"model_id": "flash", "system_prompt": "新提示词"},
        )
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["success"])
        updated = agent_store.get_agent(USER["openid"], agent["id"])
        self.assertEqual(updated["model_id"], "flash")
        self.assertEqual(updated["system_prompt"], "新提示词")

    def test_patch_invalid_model_400(self):
        agent = agent_store.create_agent(USER["openid"], "测试", "flash")
        r = self.client.patch(
            f"/api/agents/{agent['id']}", json={"model_id": "nope"}
        )
        self.assertEqual(r.status_code, 400)

    def test_patch_empty_body_400(self):
        agent = agent_store.create_agent(USER["openid"], "测试", "flash")
        r = self.client.patch(f"/api/agents/{agent['id']}", json={})
        self.assertEqual(r.status_code, 400)


class TestModelsInfo(RestApiBase):
    def test_models_info_shape_and_mask(self):
        agent = agent_store.create_agent(USER["openid"], "测试", "flash")
        mock_cfgs = {
            "flash": ModelConfig(
                name="Flash", base_url="http://x/secret/path", api_key="k",
                model_id="flash", if_vision=True, thinking=True,
                extra={"max_seqlen": 8192},
            ),
        }
        with patch("agent.routes.get_model_configs", return_value=mock_cfgs):
            r = self.client.get(f"/api/agents/{agent['id']}/models-info")
        self.assertEqual(r.status_code, 200)
        data = r.json()
        self.assertEqual(data["agent"]["id"], agent["id"])
        self.assertEqual(data["agent"]["model_id"], "flash")
        model = data["models"][0]
        self.assertEqual(model["model_id"], "flash")
        self.assertTrue(model["if_vision"])
        self.assertTrue(model["thinking"])
        self.assertEqual(model["max_seqlen"], 8192)
        # base_url 脱敏：仅协议+主机，不含路径/密钥
        self.assertNotIn("secret", model["base_url"])
        self.assertNotIn("/path", model["base_url"])


class TestMcpServicesApi(RestApiBase):
    def test_list_includes_builtin(self):
        r = self.client.get("/api/mcp/services")
        self.assertEqual(r.status_code, 200)
        names = {s["name"] for s in r.json()["services"]}
        self.assertIn("workspace", names)
        self.assertIn("document", names)
        self.assertIn("embed_search", names)

    def test_register_list_delete_roundtrip(self):
        r = self.client.post(
            "/api/mcp/services",
            json={"name": "api-svc", "command": "npx", "args": ["-y", "pkg"]},
        )
        self.assertEqual(r.status_code, 200)
        self.assertTrue(r.json()["success"])
        lst = self.client.get("/api/mcp/services").json()["services"]
        self.assertIn("api-svc", {s["name"] for s in lst})
        d = self.client.delete("/api/mcp/services/api-svc")
        self.assertEqual(d.status_code, 200)
        self.assertTrue(d.json()["success"])

    def test_register_invalid_command_400(self):
        r = self.client.post(
            "/api/mcp/services",
            json={"name": "evil", "command": "bash", "args": [";rm -rf /"]},
        )
        self.assertEqual(r.status_code, 400)

    def test_delete_builtin_404(self):
        r = self.client.delete("/api/mcp/services/workspace")
        self.assertEqual(r.status_code, 404)


class TestTeammatesPriority(RestApiBase):
    def test_prefers_db_table(self):
        agent = agent_store.create_agent(USER["openid"], "TOP", "flash")
        team_store.init_team(USER["openid"], agent["id"], "TOP")
        team_store.add_member(
            USER["openid"], agent["id"], "member_rest_1",
            name="晏清", role="产品经理", duty="需求", model_id="flash",
        )
        r = self.client.get(f"/api/agents/{agent['id']}/teammates")
        self.assertEqual(r.status_code, 200)
        members = r.json()["members"]
        self.assertEqual(len(members), 1)
        self.assertEqual(members[0]["name"], "晏清")
        self.assertEqual(members[0]["model_id"], "flash")
        self.assertEqual(members[0]["role"], "产品经理")
        self.assertEqual(members[0]["workspace_id"], "member_rest_1")

    def test_fallback_roster_file_when_table_empty(self):
        agent = agent_store.create_agent(USER["openid"], "TOP", "flash")
        fake_io = MagicMock()
        fake_io.read_file = AsyncMock(return_value={
            "content": (
                "| 成员ID | 名称 | 模型 | 层级 | 创建时间 | 工作状态 | 评价 |\n"
                "| --- | --- | --- | --- | --- | --- | --- |\n"
                "| member_x | 知遥 | flash | 1 | 123 | idle |  |\n"
            )
        })
        with patch("agent.routes._get_workspace_io", return_value=fake_io):
            r = self.client.get(f"/api/agents/{agent['id']}/teammates")
        self.assertEqual(r.status_code, 200)
        members = r.json()["members"]
        self.assertEqual(len(members), 1)
        self.assertEqual(members[0]["name"], "知遥")
        self.assertEqual(members[0]["id"], "member_x")


class TestUserMessageSessionChain(unittest.TestCase):
    """R2 会话隔离链路层：session_id 从用户消息透传到 _store_message。"""

    def _run(self, coro):
        loop = asyncio.new_event_loop()
        try:
            return loop.run_until_complete(coro)
        finally:
            loop.close()

    def test_session_id_reaches_store_and_session(self):
        from agent import chat

        store_kwargs = []

        def _fake_store(user_id, agent_id, role, content, **kwargs):
            store_kwargs.append(kwargs)

        with patch.object(chat, "_store_message", side_effect=_fake_store), \
                patch.object(chat, "create_session", return_value=None), \
                patch.object(chat, "touch_session", return_value=None), \
                patch.object(chat, "update_session_title_from_first_message",
                             return_value=None), \
                patch.object(chat, "_send_text_as_agent", new=AsyncMock()), \
                patch.object(chat, "_send_status_idle", new=AsyncMock()), \
                patch("agent.chat.state.model_configs", {}):
            self._run(chat._handle_user_message(
                "u1", {"agent_id": "a1", "content": "hi", "session_id": "sess-xyz"}
            ))
        self.assertTrue(store_kwargs)
        self.assertEqual(store_kwargs[-1]["session_id"], "sess-xyz")

    def test_default_session_fallback(self):
        from agent import chat

        store_kwargs = []

        def _fake_store(user_id, agent_id, role, content, **kwargs):
            store_kwargs.append(kwargs)

        with patch.object(chat, "_store_message", side_effect=_fake_store), \
                patch.object(chat, "create_session", return_value=None), \
                patch.object(chat, "touch_session", return_value=None), \
                patch.object(chat, "update_session_title_from_first_message",
                             return_value=None), \
                patch.object(chat, "_send_text_as_agent", new=AsyncMock()), \
                patch.object(chat, "_send_status_idle", new=AsyncMock()), \
                patch("agent.chat.state.model_configs", {}):
            self._run(chat._handle_user_message(
                "u1", {"agent_id": "a1", "content": "hi"}
            ))
        self.assertTrue(store_kwargs)
        self.assertEqual(store_kwargs[-1]["session_id"], "session_default")

    def test_dispatch_agent_message_passes_through_session(self):
        """_dispatch_user_message 无 agent_id 时直接透传 data（含 session_id）。"""
        from agent import chat

        captured = {}

        async def _fake_handle(user_id, data):
            captured["session_id"] = data.get("session_id")

        with patch.object(chat, "_handle_user_message", new=_fake_handle):
            self._run(chat._dispatch_user_message(
                "u1", {"agent_id": "", "content": "x", "session_id": "sess-abc"}
            ))
        self.assertEqual(captured.get("session_id"), "sess-abc")


if __name__ == "__main__":
    unittest.main()