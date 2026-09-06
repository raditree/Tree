# -*- coding: utf-8 -*-
"""Task 7：消息 active 语义（总结反向推送显式化）+ 接收方会话保障。

覆盖：
1. active=true 且目标已有"最后总结" → 反向推送一条 active=false 消息给发起方
   （mock ws_manager / broker 捕获断言）；active=false / 用户直发 /
   auto_reply 被动通道 / 无总结 → 不推送。
2. 接收方无 session → 自动创建会话元数据并经 WS 推送 session_created；
   跨 team（TOP↔TOP）、用户直发、成员目标同样保障；已存在会话不重复推送。
3. sessions 表主键迁移（session_id → (session_id, user_id, agent_id)）：
   旧库数据保留，同一会话 id 可被多个 agent 各自持有元数据行。
4. REST send_teammate_message 透传 active 参数。
"""

import asyncio
import shutil
import sqlite3
import sys
import tempfile
import unittest
import uuid
from contextlib import ExitStack
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

# 将 server 目录加入 Python 路径
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import state  # noqa: E402
import data.agent_store as agent_store  # noqa: E402
import data.conversation_store as conv  # noqa: E402
import data.db as db_mod  # noqa: E402
import data.session_store as session_store  # noqa: E402
import data.spec_store as spec_store  # noqa: E402
import data.team_store as team_store  # noqa: E402
from agent import chat as chat_mod  # noqa: E402
from agent import routes  # noqa: E402
from agent.chat import USER_AGENT_ID  # noqa: E402
from data.session_cache import set_session  # noqa: E402


def _redirect_db(tmpdir: Path) -> None:
    """把 data 层各模块 DB 指向临时目录并重置初始化标记（隔离真实库）。"""
    for mod in (conv, session_store, spec_store, team_store, agent_store):
        mod._DB_PATH = tmpdir / "conversations.db"  # type: ignore[attr-defined]
        mod._initialized = False  # type: ignore[attr-defined]
    db_mod._DB_PATH = tmpdir / "conversations.db"  # type: ignore[attr-defined]
    db_mod._wal_configured = False  # type: ignore[attr-defined]


class FakeWSManager:
    """捕获 WS 推送的 ws_manager 替身。"""

    def __init__(self):
        self.sent = []

    async def send_message(self, user_id, message):
        self.sent.append(message)


class FakeBroker:
    """捕获投递负载的 broker 替身。"""

    def __init__(self):
        self.payloads = []

    def dispatch(self, key, payload):
        self.payloads.append(payload)
        return True


def _flush_async(coro_main):
    """在独立事件循环中执行 async 主体的同步辅助：绑定主循环并空转刷新，
    使分发层 _push_ws 调度的 WS 推送真正执行，供断言捕获。"""
    loop = asyncio.new_event_loop()
    try:
        loop.run_until_complete(coro_main())
        # 空转若干次，让 create_task / run_coroutine_threadsafe 调度的
        # WS 推送协程跑完
        for _ in range(6):
            loop.run_until_complete(asyncio.sleep(0))
    finally:
        loop.close()


class Task7TestBase(unittest.TestCase):
    """每个测试独立临时 DB 与唯一用户/会话 id。"""

    def setUp(self):
        self._tmp = Path(tempfile.mkdtemp(prefix="trae_task7_"))
        self._orig_db = db_mod._DB_PATH  # type: ignore[attr-defined]
        _redirect_db(self._tmp)
        self.user_id = "u7_" + uuid.uuid4().hex[:8]
        self.session_id = "s7_" + uuid.uuid4().hex[:8]
        self.top_a = "topA_" + uuid.uuid4().hex[:6]
        self.top_b = "topB_" + uuid.uuid4().hex[:6]
        self.member_id = "mem_" + uuid.uuid4().hex[:6]

    def tearDown(self):
        db_mod._DB_PATH = self._orig_db  # type: ignore[attr-defined]
        db_mod._wal_configured = False  # type: ignore[attr-defined]
        shutil.rmtree(self._tmp, ignore_errors=True)

    @staticmethod
    def _agent_record():
        return {"workspace_id": None, "model_id": "m1"}

    def _dispatch(self, target, content, source_agent_id, team_id,
                  active=True, extra=None, agents=None, find_member=None):
        """执行统一消息投递，返回 (ws, top_broker, team_broker) 捕获替身。

        事件循环内先 _bind_main_loop，使分发层 _push_ws 经 create_task
        调度到该循环并真实执行。
        """
        ws = FakeWSManager()
        top = FakeBroker()
        team_b = FakeBroker()
        agents = agents if agents is not None else {}
        with ExitStack() as stack:
            stack.enter_context(patch.object(state, "ws_manager", ws))
            stack.enter_context(patch.object(state, "top_chat_broker", top))
            stack.enter_context(patch.object(state, "team_broker", team_b))
            stack.enter_context(patch.object(
                chat_mod, "get_agent", lambda uid, aid: agents.get(aid)))
            if find_member is not None:
                stack.enter_context(patch.object(
                    chat_mod, "_find_roster_member", find_member))

            async def main():
                chat_mod._bind_main_loop()
                chat_mod._dispatch_agent_message(
                    self.user_id, [target], content,
                    source_agent_id=source_agent_id,
                    team_id=team_id,
                    extra={"session_id": self.session_id, **(extra or {})},
                    active=active,
                )

            _flush_async(main)
        return ws, top, team_b

    def _seed_summary(self, agent_id, content="上一轮总结SUMMARY"):
        """给 agent 指定会话预置内存上下文（含最后总结）。"""
        set_session(
            self.user_id, agent_id,
            SimpleNamespace(
                context=[
                    {"role": "system", "content": "sys"},
                    {"role": "assistant", "content": content},
                ]
            ),
            self.session_id,
        )
        return content


class TestActiveSummaryPush(Task7TestBase):
    """7.1 active 语义：总结反向推送（显式化）。"""

    def test_active_message_pushes_summary_back_with_active_false(self):
        """active=true 且目标有总结 → 反向推送一条 active=false 消息给发起方。"""
        self._seed_summary(self.top_b)
        agents = {
            self.top_a: self._agent_record(),
            self.top_b: self._agent_record(),
        }
        ws, top, team = self._dispatch(
            self.top_b, "新任务", self.top_a, self.top_a,
            active=True, agents=agents,
        )
        # 原消息投递给 topB，负载标记 active=True
        originals = [p for p in top.payloads if p["agent_id"] == self.top_b]
        self.assertEqual(len(originals), 1)
        self.assertIs(originals[0]["active"], True)
        # 反向推送：回发给发起方 topA，内容含目标总结，标记 active=False
        pushed = [p for p in top.payloads if p["agent_id"] == self.top_a]
        self.assertEqual(len(pushed), 1)
        self.assertIn("SUMMARY", pushed[0]["content"])
        self.assertIs(pushed[0]["active"], False)
        self.assertEqual(team.payloads, [])

    def test_active_false_does_not_push(self):
        """active=false（被动推送）→ 不触发反向推送。"""
        self._seed_summary(self.top_b)
        agents = {
            self.top_a: self._agent_record(),
            self.top_b: self._agent_record(),
        }
        ws, top, team = self._dispatch(
            self.top_b, "新任务", self.top_a, self.top_a,
            active=False, agents=agents,
        )
        self.assertEqual([p["agent_id"] for p in top.payloads], [self.top_b])

    def test_auto_reply_channel_does_not_push(self):
        """auto_reply 被动通道（active 缺省 true）→ 不触发反向推送。"""
        self._seed_summary(self.top_b)
        agents = {
            self.top_a: self._agent_record(),
            self.top_b: self._agent_record(),
        }
        ws, top, team = self._dispatch(
            self.top_b, "新任务", self.top_a, self.top_a,
            active=True, extra={"auto_reply": True}, agents=agents,
        )
        self.assertEqual([p["agent_id"] for p in top.payloads], [self.top_b])

    def test_user_sender_does_not_push(self):
        """用户直发不触发反向推送（用户已可见目标会话历史）。"""
        self._seed_summary(self.top_b)
        agents = {self.top_b: self._agent_record()}
        ws, top, team = self._dispatch(
            self.top_b, "用户直发", USER_AGENT_ID, self.top_b,
            active=True, agents=agents,
        )
        self.assertEqual([p["agent_id"] for p in top.payloads], [self.top_b])

    def test_no_summary_does_not_push(self):
        """目标无"最后总结" → 不推送。"""
        agents = {
            self.top_a: self._agent_record(),
            self.top_b: self._agent_record(),
        }
        ws, top, team = self._dispatch(
            self.top_b, "新任务", self.top_a, self.top_a,
            active=True, agents=agents,
        )
        self.assertEqual([p["agent_id"] for p in top.payloads], [self.top_b])

    def test_member_summary_pushed_to_leader(self):
        """TOP → 成员（active）：成员已有总结时反向回发给发起 TOP。"""
        self._seed_summary(self.member_id)
        member = {
            "id": self.member_id, "name": "m", "model_id": "m1",
            "workspace_id": self.member_id, "system_prompt": "",
        }
        agents = {self.top_a: self._agent_record()}
        ws, top, team = self._dispatch(
            self.member_id, "去做事", self.top_a, self.top_a,
            active=True, agents=agents,
            find_member=lambda uid, owner, mid: (
                member if mid == self.member_id else None
            ),
        )
        # 成员总结回发给发起 TOP（经 top broker 解析 TOP 目标）
        pushed = [p for p in top.payloads if p["agent_id"] == self.top_a]
        self.assertEqual(len(pushed), 1)
        self.assertIn("SUMMARY", pushed[0]["content"])
        self.assertIs(pushed[0]["active"], False)


class TestReceiverSessionGuarantee(Task7TestBase):
    """7.2 接收方会话保障：无 session 自动创建 + session_created 推送。"""

    def _agents(self):
        return {
            self.top_a: self._agent_record(),
            self.top_b: self._agent_record(),
        }

    def test_cross_team_creates_receiver_session_and_pushes(self):
        """跨 team（TOP↔TOP）：接收 TOP 无会话 → 创建并推送 session_created。"""
        content = "帮我看看跨 team 的会话保障"
        ws, top, team = self._dispatch(
            self.top_b, content, self.top_a, self.top_a,
            active=True, agents=self._agents(),
        )
        # 接收方会话元数据落库（sessions 主键含 agent_id），标题取首条消息摘要
        rec = session_store.get_session_record(
            self.user_id, self.session_id, agent_id=self.top_b
        )
        self.assertIsNotNone(rec)
        self.assertIn("跨 team", rec["title"])
        # WS 推送 session_created 元数据
        created = [m for m in ws.sent if m.get("type") == "session_created"]
        self.assertEqual(len(created), 1)
        data = created[0]["data"]
        self.assertEqual(data["agent_id"], self.top_b)
        self.assertEqual(data["session_id"], self.session_id)
        self.assertIn("跨 team", data["title"])

    def test_second_dispatch_no_duplicate_push(self):
        """同一会话再次投递：不重复推送 session_created。"""
        agents = self._agents()
        self._dispatch(self.top_b, "第一条", self.top_a, self.top_a,
                       active=True, agents=agents)
        ws2, top2, team2 = self._dispatch(
            self.top_b, "第二条", self.top_a, self.top_a,
            active=True, agents=agents,
        )
        created = [m for m in ws2.sent if m.get("type") == "session_created"]
        self.assertEqual(created, [])

    def test_user_direct_creates_receiver_session(self):
        """用户直发（WS user_message 同路径）：同样保障接收方会话。"""
        agents = {self.top_b: self._agent_record()}
        ws, top, team = self._dispatch(
            self.top_b, "用户直发内容", USER_AGENT_ID, self.top_b,
            active=True, agents=agents,
        )
        rec = session_store.get_session_record(
            self.user_id, self.session_id, agent_id=self.top_b
        )
        self.assertIsNotNone(rec)
        created = [m for m in ws.sent if m.get("type") == "session_created"]
        self.assertEqual(len(created), 1)
        self.assertEqual(created[0]["data"]["agent_id"], self.top_b)

    def test_member_target_session_guarantee(self):
        """成员目标：投递前同样创建会话元数据并推送。"""
        member = {
            "id": self.member_id, "name": "m", "model_id": "m1",
            "workspace_id": self.member_id, "system_prompt": "",
        }
        agents = {self.top_a: self._agent_record()}
        ws, top, team = self._dispatch(
            self.member_id, "给成员的任务", self.top_a, self.top_a,
            active=True, agents=agents,
            find_member=lambda uid, owner, mid: (
                member if mid == self.member_id else None
            ),
        )
        rec = session_store.get_session_record(
            self.user_id, self.session_id, agent_id=self.member_id
        )
        self.assertIsNotNone(rec)
        created = [m for m in ws.sent if m.get("type") == "session_created"]
        self.assertEqual(len(created), 1)
        self.assertEqual(created[0]["data"]["agent_id"], self.member_id)
        # 成员负载携带 active
        member_payloads = [p for p in team.payloads
                           if p["agent_id"] == self.member_id]
        self.assertEqual(len(member_payloads), 1)
        self.assertIs(member_payloads[0]["active"], True)

    def test_existing_session_not_repushed(self):
        """接收方会话已存在 → 不推送 session_created（避免刷屏）。"""
        session_store.create_session(
            self.user_id, self.top_b,
            title="已有会话", session_id=self.session_id,
        )
        ws, top, team = self._dispatch(
            self.top_b, "新消息", self.top_a, self.top_a,
            active=True, agents=self._agents(),
        )
        created = [m for m in ws.sent if m.get("type") == "session_created"]
        self.assertEqual(created, [])


class TestSessionsPkMigration(unittest.TestCase):
    """sessions 表主键迁移：旧库保留数据，同一会话 id 可多 agent 持有。"""

    def setUp(self):
        self._tmp = Path(tempfile.mkdtemp(prefix="trae_task7_pk_"))
        self._orig_db = db_mod._DB_PATH  # type: ignore[attr-defined]
        _redirect_db(self._tmp)

    def tearDown(self):
        db_mod._DB_PATH = self._orig_db  # type: ignore[attr-defined]
        db_mod._wal_configured = False  # type: ignore[attr-defined]
        shutil.rmtree(self._tmp, ignore_errors=True)

    def test_old_pk_migrated_and_per_agent_rows(self):
        db_path = self._tmp / "conversations.db"
        conn = sqlite3.connect(str(db_path))
        conn.execute(
            """
            CREATE TABLE sessions (
                session_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                agent_id TEXT NOT NULL,
                title TEXT NOT NULL DEFAULT '新会话',
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                status TEXT NOT NULL DEFAULT 'active',
                deleted_at INTEGER,
                selected_spec_ids TEXT,
                PRIMARY KEY (session_id)
            )
            """
        )
        conn.execute(
            "INSERT INTO sessions (session_id, user_id, agent_id, title, "
            "created_at, updated_at, status) "
            "VALUES ('s_old', 'u1', 'a1', '旧会话', 1, 1, 'active')"
        )
        conn.commit()
        conn.close()
        # 触发迁移：重置初始化标记后再次进入 _ensure_db
        session_store._initialized = False
        rec = session_store.create_session("u1", "a2", session_id="s_old")
        self.assertEqual(rec["agent_id"], "a2")
        # 旧数据保留：a1 的行仍在
        old = session_store.get_session_record("u1", "s_old", agent_id="a1")
        self.assertIsNotNone(old)
        self.assertEqual(old["title"], "旧会话")
        # 各自会话列表可见
        self.assertIn("s_old", [r["session_id"] for r in
                                session_store.list_sessions("u1", "a1")])
        self.assertIn("s_old", [r["session_id"] for r in
                                session_store.list_sessions("u1", "a2")])
        # 复合主键：同一会话 id 可被多个 agent 各自持有
        session_store.create_session("u1", "a1", session_id="s_shared")
        session_store.create_session("u1", "a3", session_id="s_shared")
        self.assertIsNotNone(
            session_store.get_session_record("u1", "s_shared", agent_id="a3")
        )


class TestRestActiveParam(unittest.TestCase):
    """REST send_teammate_message 透传 active 参数。"""

    def setUp(self):
        self.user_id = "u7_" + uuid.uuid4().hex[:8]

    def _run(self, body):
        return asyncio.new_event_loop().run_until_complete(
            routes.send_teammate_message(
                "a1", "m1", body=body,
                current_user={"openid": self.user_id},
            )
        )

    def test_active_default_true(self):
        with patch.object(routes, "_dispatch_agent_message") as m:
            m.return_value = SimpleNamespace(get=lambda k, d=None: "sent")
            self._run({"content": "开工", "session_id": "s1"})
            self.assertIs(m.call_args.kwargs["active"], True)

    def test_active_false_passthrough(self):
        with patch.object(routes, "_dispatch_agent_message") as m:
            m.return_value = SimpleNamespace(get=lambda k, d=None: "sent")
            self._run({"content": "开工", "session_id": "s1",
                       "active": False})
            self.assertIs(m.call_args.kwargs["active"], False)


if __name__ == "__main__":
    unittest.main()
