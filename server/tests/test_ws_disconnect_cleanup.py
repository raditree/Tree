# -*- coding: utf-8 -*-
"""WS 断连清理执行器注册的 SSH 归属回归测试。

Issue：``ws/endpoints.py`` 断连 cleanup（finally）中，SSH 分支在归属校验
（``unregister_ssh`` 返回 ``cleared``）之前就无条件执行
``ssh_manager.unregister``——当该 team 的注册已被同用户其他连接接管
（cleared=False）时，仍会删除持久化 SSH 配置，误清接管连接的 SSH 模式
（前端再执行时模式失联，须重新注册）。修复：仅在本连接确实注销成功
（cleared=True）后清 SSH 配置，与 ``unregister_ssh_executor`` 显式注销
分支同一归属原则。

测试直接驱动 ``register_ws`` 挂载的 websocket 端点（假 WS / 假连接管理器 /
假 SSH 配置管理器 + 真实 LocalExecutorClient）：
- 连接 1 注册 team → 连接 2 注册同一 team（接管）；
- 连接 1 断连：注册与 SSH 配置必须保持（不得调用 ssh_manager.unregister）；
- 连接 2 断连（归属者）：注册与 SSH 配置正常清理。
"""

import asyncio
import json
import sys
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import state  # noqa: E402
import ws.endpoints as endpoints_mod  # noqa: E402
from fastapi import WebSocketDisconnect  # noqa: E402
from io_ import mode_resolver as mode_resolver_mod  # noqa: E402
from io_.local_executor import LocalExecutorClient  # noqa: E402

USER = "ws-disconnect-u1"
TEAM = "top-ssh-1"


class _AppDouble:
    """FastAPI app 替身：捕获 @app.websocket(path) 注册的端点函数。"""

    def __init__(self):
        self.routes = {}

    def websocket(self, path):
        def _deco(fn):
            self.routes[path] = fn
            return fn

        return _deco


class _FakeWSManager:
    """连接管理器替身：记录连接与出站消息，不真正发送。"""

    def __init__(self):
        # user_id -> {connection_id: ws}（形状对齐真实 WebSocketManager）
        self.connections = {}
        self.sent = []
        self._seq = 0

    async def connect(self, user_id, ws):
        self._seq += 1
        cid = f"conn-{self._seq}"
        self.connections.setdefault(user_id, {})[cid] = ws
        return cid

    def disconnect_by_id(self, user_id, connection_id):
        self.connections.get(user_id, {}).pop(connection_id, None)

    async def send_message(self, user_id, message):
        self.sent.append(message)

    def ack_count(self, msg_type):
        return sum(
            1
            for m in self.sent
            if m.get("type") == msg_type
            and isinstance(m.get("data"), dict)
            and m["data"].get("success")
        )


class _FakeSSHManager:
    """SSH 配置管理器替身：内存记录注册/注销（不落盘）。"""

    def __init__(self):
        self.configs = {}
        self.unregister_calls = []

    def is_ssh(self, user_id, agent_id):
        return (user_id, agent_id) in self.configs

    def get_config(self, user_id, agent_id):
        return self.configs.get((user_id, agent_id))

    def register(self, user_id, agent_id, cfg):
        self.configs[(user_id, agent_id)] = dict(cfg)
        return True, ""

    def unregister(self, user_id, agent_id):
        self.unregister_calls.append((user_id, agent_id))
        return self.configs.pop((user_id, agent_id), None) is not None


class _ScriptedWS:
    """脚本化 WebSocket：回放脚本消息；脚本耗尽后等断连事件并抛 WebSocketDisconnect。"""

    def __init__(self, script):
        self._script = list(script)
        self.query_params = {"token": "itest-token"}
        self.headers = {}
        self.disconnect_event = asyncio.Event()

    async def receive_text(self):
        if self._script:
            return json.dumps(self._script.pop(0))
        await self.disconnect_event.wait()
        raise WebSocketDisconnect()

    async def close(self, code=1000, reason=""):
        pass


def _register_ssh_msg(team_id):
    return {
        "type": "register_ssh_executor",
        "data": {
            "team_id": team_id,
            "config": {
                "host": "192.0.2.10",
                "port": 22,
                "username": "ops",
                "auth_type": "password",
                "password": "must-be-stripped",
            },
        },
    }


class TestWsDisconnectSshCleanup(unittest.TestCase):
    def setUp(self):
        self._orig_state = (
            state.ws_manager, state.local_executor, state.ssh_manager,
        )
        self.ws_manager = _FakeWSManager()
        self.local_executor = LocalExecutorClient()
        self.ssh_manager = _FakeSSHManager()
        state.ws_manager = self.ws_manager
        state.local_executor = self.local_executor
        state.ssh_manager = self.ssh_manager

        self._patches = []
        self._patch(
            endpoints_mod, "verify_token",
            lambda token: {"user": {"openid": USER}},
        )
        self._patch(endpoints_mod, "_bind_main_loop", lambda: None)
        self._patch(
            endpoints_mod, "clear_user_agent", lambda user_id, team_id: None
        )
        self._patch(
            endpoints_mod, "_persist_agent_mode",
            lambda user_id, team_id, mode: None,
        )
        self._patch(endpoints_mod, "get_config", lambda: {"ssh": {}})
        self._patch(
            mode_resolver_mod, "check_exclusive",
            lambda user_id, team_id, mode: (True, ""),
        )

    def tearDown(self):
        for obj, name, old in reversed(self._patches):
            setattr(obj, name, old)
        (
            state.ws_manager, state.local_executor, state.ssh_manager,
        ) = self._orig_state

    def _patch(self, obj, name, value):
        self._patches.append((obj, name, getattr(obj, name)))
        setattr(obj, name, value)

    async def _wait_until(self, predicate, timeout=5.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            await asyncio.sleep(0.005)
        self.fail("等待条件超时：后端端点未按预期推进")

    def test_ssh_takeover_disconnect_keeps_config(self):
        asyncio.run(self._scenario())

    async def _scenario(self):
        app = _AppDouble()
        endpoints_mod.register_ws(app)
        endpoint = app.routes["/ws"]
        exp = self.local_executor

        ws1 = _ScriptedWS([_register_ssh_msg(TEAM)])
        ws2 = _ScriptedWS([_register_ssh_msg(TEAM)])
        tasks = []
        try:
            # 连接 1 注册 → 成为该 team 执行器的归属连接
            t1 = asyncio.create_task(endpoint(ws1))
            tasks.append(t1)
            await self._wait_until(
                lambda: self.ws_manager.ack_count("register_ssh_executor_ack") >= 1
            )
            self.assertTrue(exp.is_ssh(USER, TEAM))
            self.assertTrue(self.ssh_manager.is_ssh(USER, TEAM))
            # 边界安全：SSH 密码不得透传到后端存储
            self.assertNotIn(
                "password", self.ssh_manager.configs[(USER, TEAM)]
            )

            # 连接 2 注册同一 team → 接管归属（后注册实例持有）
            t2 = asyncio.create_task(endpoint(ws2))
            tasks.append(t2)
            await self._wait_until(
                lambda: self.ws_manager.ack_count("register_ssh_executor_ack") >= 2
            )
            conn_ids = list(self.ws_manager.connections[USER].keys())
            self.assertEqual(len(conn_ids), 2, conn_ids)
            conn2_id = conn_ids[1]
            self.assertEqual(exp.executor_connection(USER, TEAM), conn2_id)

            # 场景 1：先注册连接断连（已失去归属）→ 注册与 SSH 配置必须保持
            ws1.disconnect_event.set()
            await asyncio.wait_for(t1, timeout=10)
            self.assertEqual(exp.executor_connection(USER, TEAM), conn2_id)
            self.assertTrue(exp.is_ssh(USER, TEAM))
            self.assertTrue(
                self.ssh_manager.is_ssh(USER, TEAM),
                "非归属连接断连误清了接管连接的 SSH 持久化配置",
            )
            self.assertEqual(
                self.ssh_manager.unregister_calls, [],
                "非归属连接断连不得调用 ssh_manager.unregister",
            )

            # 场景 2：归属连接断连 → 正常清理（注册与 SSH 配置一并注销）
            ws2.disconnect_event.set()
            await asyncio.wait_for(t2, timeout=10)
            self.assertFalse(exp.is_ssh(USER, TEAM))
            self.assertEqual(self.ssh_manager.unregister_calls, [(USER, TEAM)])
            self.assertFalse(self.ssh_manager.is_ssh(USER, TEAM))
        finally:
            for t in tasks:
                if not t.done():
                    t.cancel()
            if tasks:
                await asyncio.gather(*tasks, return_exceptions=True)


if __name__ == "__main__":
    unittest.main()
