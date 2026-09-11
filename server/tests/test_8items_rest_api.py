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
import data.conversation_store as conv_store  # noqa: E402
import data.db as db_mod  # noqa: E402
import data.mcp_service_store as mcp_store  # noqa: E402
import data.session_store as session_store  # noqa: E402
import data.team_store as team_store  # noqa: E402
from agent.routes import router as agent_router  # noqa: E402
from config.models import ModelConfig  # noqa: E402

USER = {"openid": "u-rest-test"}


def _redirect_db(tmpdir: Path) -> None:
    """将各 data 模块 DB 路径指向临时目录并重置初始化标记。"""
    for mod in (
        agent_store,
        mcp_store,
        team_store,
        conv_store,
        session_store,
        db_mod,
    ):
        mod._DB_PATH = tmpdir / "conversations.db"  # type: ignore[attr-defined]
        mod._initialized = False  # type: ignore[attr-defined]


class RestApiBase(unittest.TestCase):
    """为每个测试创建独立临时 DB + 独立 TestClient（override 认证）。"""

    _REDIRECT_MODS = (agent_store, mcp_store, team_store, conv_store,
                      session_store, db_mod)

    def setUp(self):
        self._tmp = Path(tempfile.mkdtemp(prefix="trae_rest_"))
        # 记录原始全局状态，恢复动作注册为 addCleanup：setUp 中途抛错（例如
        # TestClient 依赖不兼容）时 tearDown 不会执行，只靠 tearDown 会把 DB
        # 重定向泄漏给后续用例（表现为 no such table: auth_tokens），
        # addCleanup 在 setUp 失败时仍会执行。
        self._orig_db = {m: m._DB_PATH for m in self._REDIRECT_MODS}
        self._orig_model_configs = state.model_configs
        self.addCleanup(self._restore_globals)
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

    def _restore_globals(self):
        """恢复 DB 重定向与 state.model_configs（addCleanup，幂等）。"""
        for m in self._REDIRECT_MODS:
            m._DB_PATH = self._orig_db[m]
            m._initialized = False
        state.model_configs = self._orig_model_configs
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

    def test_includes_nested_subteam_level2(self):
        """子团队（成员自建，行挂在成员自身 id 下）也应出现在顶部 teammates 页。"""
        agent = agent_store.create_agent(USER["openid"], "TOP", "flash")
        team_store.init_team(USER["openid"], agent["id"], "TOP")
        team_store.add_member(
            USER["openid"], agent["id"], "member_l1",
            name="一层成员", model_id="flash",
            level=1, parent_agent_id=agent["id"],
        )
        # 一层成员作为子团队 leader 创建的 Level 2 成员：行挂在 member_l1 名下
        team_store.add_member(
            USER["openid"], "member_l1", "member_l2",
            name="二层成员", model_id="flash",
            level=2, parent_agent_id="member_l1",
        )
        r = self.client.get(f"/api/agents/{agent['id']}/teammates")
        self.assertEqual(r.status_code, 200)
        members = r.json()["members"]
        self.assertEqual(
            [m["id"] for m in members], ["member_l1", "member_l2"],
        )
        self.assertEqual(members[1]["level"], 2)
        self.assertEqual(members[1]["name"], "二层成员")


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
        """_dispatch_user_message 经 extra 透传 data（含 session_id）给 dispatch。"""
        from agent import chat

        captured = {}

        def _fake_dispatch(user_id, target_ids, content, source_agent_id="",
                           team_id="", system_prompt="", extra=None,
                           active=True):
            captured["session_id"] = (extra or {}).get("session_id")
            return {"status": "sent", "sent": list(target_ids), "rejected": []}

        with patch.object(chat, "_dispatch_agent_message", new=_fake_dispatch):
            self._run(chat._dispatch_user_message(
                "u1", {"agent_id": "a1", "content": "x", "session_id": "sess-abc"}
            ))
        self.assertEqual(captured.get("session_id"), "sess-abc")

    def test_dispatch_user_message_rejects_missing_agent_id(self):
        """_dispatch_user_message 缺 agent_id 时拒绝投递（不降级、不静默）。"""
        from agent import chat

        with patch.object(chat, "_dispatch_agent_message") as fake_dispatch, \
                patch.object(chat, "_handle_user_message") as fake_handle:
            self._run(chat._dispatch_user_message(
                "u1", {"agent_id": "", "content": "x", "session_id": "sess-abc"}
            ))
        fake_dispatch.assert_not_called()
        fake_handle.assert_not_called()


class TestSessionMessageCount(RestApiBase):
    """会话列表附带 message_count：运行模式 agent 级锁定的数据基础。

    验证 GET /api/agents/{id}/sessions 返回每个会话的 message_count，
    供前端判断「该 agent 是否已有任一历史会话」来锁定运行模式
    （切换会话/新建空会话不解除锁定）。
    """

    def test_message_count_attached(self):
        agent = agent_store.create_agent(USER["openid"], "测试", "flash")
        session_store.create_session(
            USER["openid"], agent["id"], title="会话A", session_id="sa"
        )
        session_store.create_session(
            USER["openid"], agent["id"], title="会话B", session_id="sb"
        )
        # 会话 A 有 2 条消息，会话 B 为空
        conv_store.store_message(
            USER["openid"], agent["id"], "user", "hi", session_id="sa"
        )
        conv_store.store_message(
            USER["openid"], agent["id"], "agent", "hello", session_id="sa"
        )
        r = self.client.get(f"/api/agents/{agent['id']}/sessions")
        self.assertEqual(r.status_code, 200)
        sessions = r.json()["sessions"]
        by_id = {s["session_id"]: s["message_count"] for s in sessions}
        self.assertEqual(by_id["sa"], 2)
        self.assertEqual(by_id["sb"], 0)

    def test_any_session_with_history_means_agent_started(self):
        """仅会话 A 有历史即可认定该 agent 已开始过对话（供前端锁定模式）。"""
        agent = agent_store.create_agent(USER["openid"], "测试", "flash")
        session_store.create_session(
            USER["openid"], agent["id"], title="会话A", session_id="sa"
        )
        session_store.create_session(
            USER["openid"], agent["id"], title="会话B", session_id="sb"
        )
        conv_store.store_message(
            USER["openid"], agent["id"], "user", "hi", session_id="sa"
        )
        r = self.client.get(f"/api/agents/{agent['id']}/sessions")
        sessions = r.json()["sessions"]
        self.assertTrue(any(s["message_count"] > 0 for s in sessions))
        # 前端据此：agent 级锁定 = 任一会话 message_count > 0
        self.assertTrue(
            all(
                (s["message_count"] > 0) == (s["session_id"] == "sa")
                for s in sessions
            )
        )


class TestTeamMemberSessionIsolation(unittest.TestCase):
    """R2 成员链路层：leader 投递消息给成员时 session_id 必须透传。

    此前 TeamTool._dispatch_to_member / message_dispatcher 构造的 payload
    不带 session_id，成员在 _process_member_message 中恒回退默认会话，
    导致成员上下文跨会话串扰。修复后要求：
    1. _dispatch_to_member payload 含当前会话 session_id；
    2. message_dispatcher 调用（send_message/broadcast）经 extra 透传 session_id；
    3. _dispatch_roster_event 广播 payload 同样带 session_id。
    """

    def _make_tool(self, session_id: str = "sess-m", tool_cls=None):
        """构造带指定 session_id 的工具实例（依赖为占位，仅测投递 payload）。

        ``tool_cls`` 默认 TeamTool（管理域）；通信域用例传 MessageTool。
        """
        from tool.message_tool import MessageTool

        if tool_cls is None:
            tool_cls = MessageTool

        session = MagicMock()
        session.workspace_id = "ws-m"
        tool = tool_cls(
            session=session,
            docker_manager=None,
            model_configs={},
            broker=MagicMock(),
            user_id="u1",
            agent_id="leader-1",
            leader_id="top-1",
            team_id="top-1",
            session_id=session_id,
        )
        tool.members = [{
            "id": "mem-1", "workspace_id": "ws-m", "model_id": "m1",
            "system_prompt": "", "name": "成员一", "role": "执行",
            "duty": "落地实现", "parent_agent_id": "leader-1", "level": 1,
        }]
        return tool

    def test_dispatch_to_member_carries_session_id(self):
        """_dispatch_to_member 的 broker payload 必须含当前 session_id。"""
        tool = self._make_tool(session_id="sess-xyz")
        broker = tool.broker
        broker.dispatch.return_value = True
        tool._dispatch_to_member(tool.members[0], "请完成任务")
        _, payload = broker.dispatch.call_args[0]
        self.assertEqual(payload["session_id"], "sess-xyz")
        self.assertEqual(payload["agent_id"], "mem-1")

    def test_default_session_when_empty(self):
        """session_id 未设置时 payload 为空串，由成员处理侧回退默认会话。"""
        tool = self._make_tool(session_id="")
        broker = tool.broker
        broker.dispatch.return_value = True
        tool._dispatch_to_member(tool.members[0], "hi")
        _, payload = broker.dispatch.call_args[0]
        self.assertEqual(payload["session_id"], "")

    def test_send_message_passes_session_via_extra(self):
        """send_message 走 message_dispatcher 时经 extra 透传 session_id。"""
        tool = self._make_tool(session_id="sess-abc")

        def _fake_dispatcher(user_id, target_ids, content, source_agent_id="",
                             team_id="", system_prompt="", extra=None):
            self.assertEqual(extra, {"session_id": "sess-abc"})
            return {"status": "sent", "sent": target_ids, "rejected": []}

        tool.message_dispatcher = _fake_dispatcher
        result = tool.execute({
            "action": "send_message",
            "target_member_id": "mem-1",
            "message": "开工",
        })
        self.assertEqual(result["status"], "sent")

    def test_broadcast_passes_session_via_extra(self):
        """broadcast 走 message_dispatcher 时经 extra 透传 session_id。"""
        tool = self._make_tool(session_id="sess-bc")

        def _fake_dispatcher(user_id, target_ids, content, source_agent_id="",
                             team_id="", system_prompt="", extra=None):
            self.assertEqual(extra, {"session_id": "sess-bc"})
            return {"status": "sent", "sent": target_ids, "rejected": []}

        tool.message_dispatcher = _fake_dispatcher
        result = tool.execute({
            "action": "broadcast",
            "message": "全体注意",
        })
        self.assertEqual(result["status"], "broadcast")


class TestQueueInjectionSessionIsolation(unittest.TestCase):
    """R2 队列切入链路：tool_call 间隙切入时只接收当前会话的消息。

    背景：broker 队列按 (user_id, agent_id) 维度共享，跨会话的消息
    会进入同一队列。若 _pick_incoming 不校验 session_id，用户在会话 B
    发消息而 agent 正在处理会话 A 时，B 的消息会被切入 A 的上下文，
    造成"其他会话消息串入当前会话/默认会话"。

    修复：_pick_incoming 校验 incoming.session_id == 当前会话，不匹配
    则放回队列（由 worker 后续作为独立消息处理），不串入本会话上下文。
    """

    def _run(self, coro):
        loop = asyncio.new_event_loop()
        try:
            return loop.run_until_complete(coro)
        finally:
            loop.close()

    def test_pick_incoming_skips_other_session(self):
        """切入时跳过其他会话消息并放回队列，仅切入当前会话消息。"""
        from agent import chat

        injected: list = []

        async def _fake_stream(user_id, agent_id, workspace_id, session,
                               content, on_tool_turn=None, cancel_event=None,
                               session_id=None, team_id=None):
            # 模拟 tool_call 间隙：先尝试切入（此刻队列头是其他会话消息，
            # 应被跳过放回），再尝试切入（当前会话消息可被取出）
            first = on_tool_turn()
            second = on_tool_turn()
            injected.append((first, second))
            return ("ok", "ok", None, "ok")

        # 队列先放其他会话消息，再放当前会话消息
        import queue as _queue

        q = _queue.Queue()
        q.put({"user_id": "u1", "agent_id": "mem-1", "workspace_id": "w1",
               "model_id": "m1", "leader_id": "leader-1",
               "team_id": "top-1", "content": "other-session-msg",
               "session_id": "sess-other"})
        q.put({"user_id": "u1", "agent_id": "mem-1", "workspace_id": "w1",
               "model_id": "m1", "leader_id": "leader-1",
               "team_id": "top-1", "content": "current-session-msg",
               "session_id": "sess-current"})

        with patch.object(chat, "_stream_agent_reply", new=_fake_stream), \
                patch.object(chat, "_store_message", return_value=None), \
                patch.object(chat, "_register_active_task",
                             return_value=MagicMock()), \
                patch.object(chat, "_clear_active_task", return_value=None), \
                patch.object(chat, "_send_status_idle", new=AsyncMock()), \
                patch.object(chat, "save_context", return_value=None), \
                patch.object(chat, "collect_sft_turn", return_value=None), \
                patch.object(chat, "_reset_member_work_status", return_value=None), \
                patch.object(chat, "_append_activity_log", return_value=None), \
                patch.object(chat, "_register_tools", new=AsyncMock()), \
                patch.object(chat, "get_session", return_value=None), \
                patch.object(chat, "load_context", return_value=None), \
                patch.object(chat, "set_session", return_value=None), \
                patch("agent.chat.state.model_configs", {
                    "m1": MagicMock(api_key="k", name="M1", if_vision=False),
                }), \
                patch("agent.chat.state.ws_manager",
                      MagicMock(send_message=AsyncMock())):
            payload = {
                "user_id": "u1", "agent_id": "mem-1", "workspace_id": "w1",
                "model_id": "m1", "leader_id": "leader-1",
                "team_id": "top-1",
                "system_prompt": "", "content": "start",
                "session_id": "sess-current",
            }
            self._run(chat._process_member_message(payload, q))

        # 第一次切入应跳过其他会话（None），第二次切入到当前会话消息
        self.assertEqual(injected[0][0], None)
        self.assertEqual(injected[0][1], "current-session-msg")
        # 其他会话消息被放回队列，未被消费
        self.assertFalse(q.empty())

    def test_pick_incoming_same_session_passthrough(self):
        """队列头即当前会话消息时正常切入（不误伤）。"""
        from agent import chat

        injected: list = []

        async def _fake_stream(user_id, agent_id, workspace_id, session,
                               content, on_tool_turn=None, cancel_event=None,
                               session_id=None, team_id=None):
            injected.append(on_tool_turn())
            return ("ok", "ok", None, "ok")

        import queue as _queue

        q = _queue.Queue()
        q.put({"user_id": "u1", "agent_id": "mem-1", "workspace_id": "w1",
               "model_id": "m1", "leader_id": "leader-1",
               "team_id": "top-1", "content": "same-session-msg",
               "session_id": "sess-current"})

        with patch.object(chat, "_stream_agent_reply", new=_fake_stream), \
                patch.object(chat, "_store_message", return_value=None), \
                patch.object(chat, "_register_active_task",
                             return_value=MagicMock()), \
                patch.object(chat, "_clear_active_task", return_value=None), \
                patch.object(chat, "_send_status_idle", new=AsyncMock()), \
                patch.object(chat, "save_context", return_value=None), \
                patch.object(chat, "collect_sft_turn", return_value=None), \
                patch.object(chat, "_reset_member_work_status", return_value=None), \
                patch.object(chat, "_append_activity_log", return_value=None), \
                patch.object(chat, "_register_tools", new=AsyncMock()), \
                patch.object(chat, "get_session", return_value=None), \
                patch.object(chat, "load_context", return_value=None), \
                patch.object(chat, "set_session", return_value=None), \
                patch("agent.chat.state.model_configs", {
                    "m1": MagicMock(api_key="k", name="M1", if_vision=False),
                }), \
                patch("agent.chat.state.ws_manager",
                      MagicMock(send_message=AsyncMock())):
            payload = {
                "user_id": "u1", "agent_id": "mem-1", "workspace_id": "w1",
                "model_id": "m1", "leader_id": "leader-1",
                "team_id": "top-1",
                "system_prompt": "", "content": "start",
                "session_id": "sess-current",
            }
            self._run(chat._process_member_message(payload, q))

        self.assertEqual(injected[0], "same-session-msg")
        # 当前会话消息已被消费
        self.assertTrue(q.empty())


if __name__ == "__main__":
    unittest.main()