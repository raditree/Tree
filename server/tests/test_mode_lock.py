# -*- coding: utf-8 -*-
"""SubTask 6.5 运行模式锁定（mode 持久化）测试。

覆盖：
1. team 首条消息（ensure_mode_locked）后 agents.mode 非空且 = resolve_mode 结果；
2. 已锁定后再 resolve 走持久化值：cloud 锁定后 mock local/ssh 注册态变化不改变判定；
   未锁定的其他 team 仍按运行时注册态判定（行为=现状）；
3. local/ssh 持久化后执行器注销（断连/超时停用）**不回落 cloud**：resolve_mode
   仍返回持久化模式（保持本地/SSH 绑定，由执行器快速失败 + 前端重注册自愈）；
4. 锁定幂等：重复锁定不覆盖、不报错（云 ensure/锁定的幂等语义）。

隔离：临时目录重定位 data.db._DB_PATH（agent_store 经共享 connect 打开）
并重置 agent_store._initialized，避免污染真实 conversations.db。
"""

import shutil
import sys
import tempfile
import unittest
from pathlib import Path

# 将 server 目录加入 Python 路径
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import data.agent_store as agent_store  # noqa: E402
import data.db as db_mod  # noqa: E402


class _FakeSSH:
    """极简 ssh_manager 替身：is_ssh 按 team 名单判定。"""

    def __init__(self, teams=()):
        self._teams = set(teams)

    def is_ssh(self, user_id, agent_id):
        return agent_id in self._teams

    def get_config(self, user_id, agent_id):
        return {"host": "remote.example.com"} if agent_id in self._teams else None


class ModeLockBase(unittest.TestCase):
    """为每个测试创建独立临时 DB，并接管 state 执行器注册态。"""

    def setUp(self):
        import state

        self._state = state
        self._tmp = Path(tempfile.mkdtemp(prefix="trae_mode_lock_"))
        self._orig_db_path = db_mod._DB_PATH  # type: ignore[attr-defined]
        db_mod._DB_PATH = self._tmp / "conversations.db"  # type: ignore[attr-defined]
        db_mod._wal_configured = False  # type: ignore[attr-defined]
        agent_store._DB_PATH = self._tmp / "conversations.db"  # type: ignore[attr-defined]
        agent_store._initialized = False  # type: ignore[attr-defined]
        # 保存并复位执行器运行时态（保证首条消息判定干净）
        self._orig_executor = state.local_executor
        self._orig_ssh = state.ssh_manager
        state.local_executor = None
        state.ssh_manager = _FakeSSH()

    def tearDown(self):
        self._state.local_executor = self._orig_executor
        self._state.ssh_manager = self._orig_ssh
        db_mod._DB_PATH = self._orig_db_path  # type: ignore[attr-defined]
        db_mod._wal_configured = False  # type: ignore[attr-defined]
        shutil.rmtree(self._tmp, ignore_errors=True)

    def _make_agent(self, user="u1"):
        rec = agent_store.create_agent(user, "TOP", "flash")
        return rec["id"]


class TestModeLock(ModeLockBase):
    """模式锁定：首消息后持久化 mode，此后 resolve 优先持久化值。"""

    def test_first_message_locks_cloud_and_persists(self):
        """首消息（无执行器注册）→ 锁定 cloud，agents.mode 非空且=resolve 结果。"""
        from io_ import mode_resolver as mr

        aid = self._make_agent()
        self.assertIsNone(agent_store.get_agent_mode("u1", aid))
        # 首消息锁定点
        self.assertEqual(mr.ensure_mode_locked("u1", aid), "cloud")
        self.assertEqual(agent_store.get_agent_mode("u1", aid), "cloud")
        self.assertEqual(mr.resolve_mode("u1", aid), "cloud")

    def test_first_message_locks_registered_local(self):
        """已注册本地执行器时首消息 → 锁定 local。"""
        from io_.local_executor import LocalExecutorClient
        from io_ import mode_resolver as mr

        aid = self._make_agent()
        client = LocalExecutorClient()
        client.register("u1", aid, "C:/base")
        self._state.local_executor = client
        self.assertEqual(mr.ensure_mode_locked("u1", aid), "local")
        self.assertEqual(agent_store.get_agent_mode("u1", aid), "local")
        self.assertEqual(mr.resolve_mode("u1", aid), "local")

    def test_locked_cloud_ignores_later_local_registration(self):
        """已锁定 cloud：mock local/ssh 注册态变化不改变判定（持久化值优先）。"""
        from io_.local_executor import LocalExecutorClient
        from io_ import mode_resolver as mr

        aid_a = self._make_agent()
        aid_b = self._make_agent()
        # aid_a 首消息在无执行器时锁定为 cloud
        self.assertEqual(mr.ensure_mode_locked("u1", aid_a), "cloud")
        # 之后前端为 aid_a/aid_b 都注册本地执行器：已锁 cloud 判定不变
        client = LocalExecutorClient()
        client.register("u1", aid_a, "C:/a")
        client.register("u1", aid_b, "C:/b")
        self._state.local_executor = client
        self._state.ssh_manager = _FakeSSH()
        self.assertEqual(mr.resolve_mode("u1", aid_a), "cloud")
        # 未锁定的其他 team 仍按运行时注册态判定（行为=现状）
        self.assertEqual(mr.resolve_mode("u1", aid_b), "local")
        # aid_a 再注册 ssh（并置 ssh_manager）：已锁 cloud 仍不变
        client.register_ssh("u1", aid_a)
        self._state.ssh_manager = _FakeSSH(teams=[aid_a])
        self.assertEqual(mr.resolve_mode("u1", aid_a), "cloud")
        # aid_b（未锁定）切换执行器注册态 → 按运行时判定迁移
        client.unregister("u1", aid_b)
        client.register_ssh("u1", aid_b)
        self._state.ssh_manager = _FakeSSH(teams=[aid_b])
        self.assertEqual(mr.resolve_mode("u1", aid_b), "ssh")

    def test_locked_local_keeps_local_when_executor_unregistered(self):
        """已锁定 local/ssh 但执行器注销（断连/超时停用）→ resolve_mode 仍锁定。

        保持"本地/SSH 绑定等待前端重注册自愈"的语义，绝不静默回退云端执行。
        """
        from io_.local_executor import LocalExecutorClient
        from io_ import mode_resolver as mr

        # --- local：锁定后注销执行器，模式不回落 cloud ---
        aid = self._make_agent()
        client = LocalExecutorClient()
        client.register("u1", aid, "C:/base")
        self._state.local_executor = client
        self.assertEqual(mr.ensure_mode_locked("u1", aid), "local")
        # 执行器注销（模拟 WS 断连/超时停用）：已锁定的 local 仍保持 local
        client.unregister("u1", aid)
        self.assertEqual(mr.resolve_mode("u1", aid), "local")
        # 前端重注册 → 恢复（mode 不变）
        client.register("u1", aid, "C:/base")
        self.assertEqual(mr.resolve_mode("u1", aid), "local")

        # --- ssh：锁定后注销执行器与持久化配置，模式不回落 cloud ---
        aid2 = self._make_agent()
        client.register_ssh("u1", aid2)
        self._state.ssh_manager = _FakeSSH(teams=[aid2])
        self.assertEqual(mr.ensure_mode_locked("u1", aid2), "ssh")
        # 注销 SSH 注册且移除 ssh_manager 配置（模拟超时停用 _disable_ssh_mode）
        client.unregister_ssh("u1", aid2)
        self._state.ssh_manager = _FakeSSH()
        self.assertEqual(mr.resolve_mode("u1", aid2), "ssh")

    def test_set_agent_mode_overwrites_and_missing_noop(self):
        """set_agent_mode：显式覆盖运行模式（注册/注销意图）；agent 不存在返回 False。"""
        aid = self._make_agent()
        # 注册 local 后首次锁定可先由首消息写入 cloud，注册事件再显式改 local
        self.assertEqual(agent_store.get_agent_mode("u1", aid), None)
        self.assertTrue(agent_store.set_agent_mode("u1", aid, "local"))
        self.assertEqual(agent_store.get_agent_mode("u1", aid), "local")
        # 显式注销（切回云端）无条件覆盖已锁定模式
        self.assertTrue(agent_store.set_agent_mode("u1", aid, "cloud"))
        self.assertEqual(agent_store.get_agent_mode("u1", aid), "cloud")
        self.assertTrue(agent_store.set_agent_mode("u1", aid, "ssh"))
        self.assertEqual(agent_store.get_agent_mode("u1", aid), "ssh")
        # agent 不存在/已删除：返回 False 且不抛错
        self.assertFalse(agent_store.set_agent_mode("u1", "ghost_top", "local"))

    def test_lock_is_idempotent_and_never_overwrites(self):
        """重复锁定幂等：第二次不覆盖、不报错，mode 保持不变。"""
        from io_ import mode_resolver as mr

        aid = self._make_agent()
        self.assertEqual(mr.ensure_mode_locked("u1", aid), "cloud")
        # store 级：再次锁定返回 False（未写入）
        self.assertFalse(agent_store.lock_agent_mode("u1", aid, "local"))
        self.assertEqual(agent_store.get_agent_mode("u1", aid), "cloud")
        # helper 级：重复调用返回既有持久化值，不因运行时态漂移而改写
        self.assertEqual(mr.ensure_mode_locked("u1", aid), "cloud")
        self.assertEqual(mr.resolve_mode("u1", aid), "cloud")

    def test_lock_noop_for_missing_agent(self):
        """agent 不存在/无记录：锁定不落库也不抛错（消息按运行时判定继续）。"""
        from io_ import mode_resolver as mr

        self.assertIsNone(agent_store.get_agent_mode("u1", "ghost_top"))
        # 无异常即可；返回值为运行时判定结果，但不写入任何行
        mr.ensure_mode_locked("u1", "ghost_top")
        self.assertIsNone(agent_store.get_agent_mode("u1", "ghost_top"))


if __name__ == "__main__":
    unittest.main()
