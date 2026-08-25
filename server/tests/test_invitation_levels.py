# -*- coding: utf-8 -*-
"""邀请码分级注册与等级体系测试（Task 9）。

覆盖：
1. 邀请码生成与文件：init_invitation_codes() 后每个等级有 code、key 文件写入，
   validate_code 对有效码返回对应等级。
2. 到期/冷却/重新生成：beta（cooldown_minutes>0）到期进入冷却、冷却结束重新
   生成新码且旧码失效；common（cooldown_minutes=0）到期立即重新生成。
3. 名额：consume_code 计数、超 max_users 返回 False（beta max_users=1 验证）。
4. 注册/升级校验：单元级 validate_code/consume_code + set_user_level 组合；
   另用 FastAPI TestClient（httpx 已安装）对 POST /api/auth/register 与
   /api/auth/upgrade 做端到端（带码注册成功、错误码 400）。
5. restore_level 行为：set_user_level 写库后 load_levels_from_db(True) 恢复、
   load_levels_from_db(False) 全回 common 且不改 DB 值。
6. 分级限流：llm.rate_limit._resolve_interval 按等级/开关解析 interval。
7. 并发拒绝：chat._count_active_agents 统计不同 agent、_concurrency_limit_reached
   按等级并发上限判定。

隔离策略：用临时目录 patch 各模块 _DATA_DIR/_DB_PATH/_key_dir 等常量，避免污染
真实 conversations.db 与真实 key 文件。所有用例快速、可重复。
"""

import asyncio
import shutil
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

# 将 server 目录加入 Python 路径
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from fastapi import HTTPException  # noqa: E402

import agent.chat as chat  # noqa: E402
import data.invitation_code as invitation_code  # noqa: E402
import data.routes as data_routes  # noqa: E402
import data.user_store as user_store  # noqa: E402
import llm.rate_limit as rate_limit  # noqa: E402
from config import levels as level_config  # noqa: E402

# 测试用等级配置（数值与 app.yaml 一致，便于断言到期/冷却/名额）
LEVELS_CFG = {
    "common": {
        "max_users": 200,
        "validity_minutes": 1440,
        "cooldown_minutes": 0,
        "max_concurrent_agents": 4,
        "rate_per_minute": 12,
        "active_rate_per_minute": 6,
    },
    "pro": {
        "max_users": 50,
        "validity_minutes": 360,
        "cooldown_minutes": 0,
        "max_concurrent_agents": 12,
        "rate_per_minute": 24,
        "active_rate_per_minute": 6,
    },
    "ultra": {
        "max_users": 10,
        "validity_minutes": 30,
        "cooldown_minutes": 0,
        "max_concurrent_agents": 72,
        "rate_per_minute": 60,
        "active_rate_per_minute": 6,
    },
    "beta": {
        "max_users": 1,
        "validity_minutes": 2,
        "cooldown_minutes": 18,
        "max_concurrent_agents": 500,
        "rate_per_minute": 300,
        "active_rate_per_minute": 6,
    },
}


# ----------------------------------------------------------------------
# 隔离基类
# ----------------------------------------------------------------------
class _InvitationIsolated(unittest.TestCase):
    """临时 key 目录 + 可控等级配置 + 初始化邀请码。"""

    def setUp(self):
        self._tmp = Path(tempfile.mkdtemp(prefix="trae_inv_"))
        invitation_code._codes.clear()
        self._patchers = [
            # key 文件重定向到临时目录
            patch.object(invitation_code, "_key_dir", return_value=self._tmp),
            # 等级列表与单等级配置可控
            patch.object(
                invitation_code,
                "get_levels",
                return_value={k: dict(v) for k, v in LEVELS_CFG.items()},
            ),
            patch.object(
                invitation_code,
                "get_level_config",
                side_effect=lambda lv: dict(LEVELS_CFG.get(lv, {})),
            ),
        ]
        for p in self._patchers:
            p.start()
            self.addCleanup(p.stop)
        invitation_code.init_invitation_codes()

    def tearDown(self):
        shutil.rmtree(self._tmp, ignore_errors=True)


def _isolate_user_store(tmp: Path):
    """把 user_store 的 DB 路径重定向到临时目录并重置初始化标记。"""
    user_store._level_cache.clear()
    user_store._level_restore_enabled = True
    return [
        patch.object(user_store, "_DATA_DIR", tmp),
        patch.object(user_store, "_DB_PATH", tmp / "conversations.db"),
        patch.object(user_store, "_initialized", False),
    ]


# ----------------------------------------------------------------------
# 1. 邀请码生成与文件
# ----------------------------------------------------------------------
class TestInvitationCodeGeneration(_InvitationIsolated):
    def test_init_generates_code_per_level_and_writes_key_files(self):
        """init 后每个等级都有 code，key 文件写入，validate 返回对应等级。"""
        for level in LEVELS_CFG:
            with self.subTest(level=level):
                code = invitation_code.get_current_code(level)
                self.assertTrue(code, f"等级 {level} 应有邀请码")

                key_file = self._tmp / f"invitation_code_{level}.key"
                self.assertTrue(key_file.exists(), f"{key_file} 应被写入")
                self.assertEqual(
                    key_file.read_text(encoding="utf-8").strip(), code
                )

                got_level, reason = invitation_code.validate_code(code)
                self.assertEqual(got_level, level)
                self.assertEqual(reason, "有效")

    def test_validate_invalid_and_empty(self):
        """无效码/空码返回 (None, 原因)，不影响有效码。"""
        self.assertEqual(
            invitation_code.validate_code(""), (None, "无效邀请码")
        )
        self.assertEqual(
            invitation_code.validate_code("bad_code"), (None, "无效邀请码")
        )

    def test_codes_distinct_per_level(self):
        """不同等级邀请码互不相同（避免串用）。"""
        codes = {
            lv: invitation_code.get_current_code(lv) for lv in LEVELS_CFG
        }
        self.assertEqual(len(set(codes.values())), len(LEVELS_CFG))


# ----------------------------------------------------------------------
# 2. 到期 / 冷却 / 重新生成
# ----------------------------------------------------------------------
class TestInvitationCodeLifecycle(_InvitationIsolated):
    def test_beta_expiry_enters_cooldown(self):
        """beta 到期进入冷却：validate 返回「邀请码冷却中」。"""
        old_code = invitation_code.get_current_code("beta")
        state = invitation_code._codes["beta"]
        state["expires_at"] = time.time() - 1
        invitation_code._maybe_refresh("beta")

        self.assertGreater(state["cooldown_until"], time.time(), "应进入冷却")
        # 冷却中：码本身未变，但 validate 报冷却
        self.assertEqual(
            invitation_code.validate_code(old_code), (None, "邀请码冷却中")
        )

    def test_beta_cooldown_end_regenerates_new_code(self):
        """冷却结束重新生成新码，旧码失效、新码写入 key 文件。"""
        old_code = invitation_code.get_current_code("beta")
        state = invitation_code._codes["beta"]
        state["expires_at"] = time.time() - 1
        state["cooldown_until"] = time.time() - 1  # 冷却已结束
        invitation_code._maybe_refresh("beta")

        new_code = invitation_code.get_current_code("beta")
        self.assertNotEqual(new_code, old_code)
        # 旧码失效
        self.assertEqual(
            invitation_code.validate_code(old_code), (None, "无效邀请码")
        )
        # 新码有效且 key 文件已更新
        self.assertEqual(
            invitation_code.validate_code(new_code), ("beta", "有效")
        )
        key_file = self._tmp / "invitation_code_beta.key"
        self.assertEqual(
            key_file.read_text(encoding="utf-8").strip(), new_code
        )
        # 重新生成后冷却清零
        self.assertEqual(state["cooldown_until"], 0)

    def test_common_expiry_regenerates_immediately(self):
        """common（cooldown_minutes=0）到期立即重新生成，不进入冷却。"""
        old_code = invitation_code.get_current_code("common")
        state = invitation_code._codes["common"]
        state["expires_at"] = time.time() - 1
        invitation_code._maybe_refresh("common")

        new_code = invitation_code.get_current_code("common")
        self.assertNotEqual(new_code, old_code)
        self.assertEqual(
            invitation_code.validate_code(new_code), ("common", "有效")
        )
        self.assertEqual(state["cooldown_until"], 0, "无冷却配置不应进入冷却")

    def test_expired_code_validate_reports_expired(self):
        """已过期且不在冷却中的码 validate 报「邀请码已过期」。"""
        old_code = invitation_code.get_current_code("beta")
        state = invitation_code._codes["beta"]
        state["expires_at"] = time.time() - 1
        state["cooldown_until"] = 0  # 未进入冷却
        self.assertEqual(
            invitation_code.validate_code(old_code), (None, "邀请码已过期")
        )


# ----------------------------------------------------------------------
# 3. 名额
# ----------------------------------------------------------------------
class TestInvitationQuota(_InvitationIsolated):
    def test_consume_counts(self):
        """consume_code 逐次计数，未超限返回 True。"""
        self.assertTrue(invitation_code.consume_code("common"))
        self.assertTrue(invitation_code.consume_code("common"))
        self.assertEqual(invitation_code._codes["common"]["used_count"], 2)

    def test_exceed_max_users_returns_false(self):
        """beta max_users=1：第二个名额返回 False 且计数回滚。"""
        self.assertTrue(invitation_code.consume_code("beta"))
        self.assertFalse(invitation_code.consume_code("beta"))
        self.assertEqual(
            invitation_code._codes["beta"]["used_count"], 1, "超限应回滚"
        )

    def test_consume_unknown_level_false(self):
        """未初始化/不存在的等级 consume 返回 False。"""
        self.assertFalse(invitation_code.consume_code("no_such_level"))


# ----------------------------------------------------------------------
# 4. 注册 / 升级校验（单元级 + E2E）
# ----------------------------------------------------------------------
class TestRegistrationUpgradeUnit(_InvitationIsolated):
    """不依赖 HTTP 的注册/升级流程：validate + consume + set_user_level。"""

    def setUp(self):
        super().setUp()
        self._db_patchers = _isolate_user_store(self._tmp / "db")
        for p in self._db_patchers:
            p.start()
            self.addCleanup(p.stop)

    def test_register_flow_unit(self):
        """带码注册：validate 通过 + consume 扣名额 + set_user_level 生效。"""
        code = invitation_code.get_current_code("common")
        level, reason = invitation_code.validate_code(code)
        self.assertEqual((level, reason), ("common", "有效"))
        self.assertTrue(invitation_code.consume_code(level))

        user = user_store.create_account("alice_unit", "secret123", "Alice")
        user_store.set_user_level(user["openid"], level)
        self.assertEqual(user_store.get_user_level(user["openid"]), "common")
        self.assertEqual(
            invitation_code._codes["common"]["used_count"], 1, "注册应扣减一个名额"
        )

    def test_upgrade_flow_unit(self):
        """升级：common 用户用 pro 码升到 pro。"""
        user = user_store.create_account("bob_unit", "secret123", "Bob")
        self.assertEqual(user_store.get_user_level(user["openid"]), "common")

        pro_code = invitation_code.get_current_code("pro")
        level, reason = invitation_code.validate_code(pro_code)
        self.assertEqual(level, "pro")
        self.assertTrue(invitation_code.consume_code(level))
        user_store.set_user_level(user["openid"], level)
        self.assertEqual(user_store.get_user_level(user["openid"]), "pro")

    def test_invalid_code_rejected(self):
        """无效码：validate 返回 (None, 原因)，流程应拒绝。"""
        level, reason = invitation_code.validate_code("not-a-code")
        self.assertIsNone(level)
        self.assertEqual(reason, "无效邀请码")

    def test_expired_code_rejected(self):
        """过期码：validate 返回 (None, 原因)，流程应拒绝。"""
        code = invitation_code.get_current_code("beta")
        state = invitation_code._codes["beta"]
        state["expires_at"] = time.time() - 1
        state["cooldown_until"] = 0
        level, reason = invitation_code.validate_code(code)
        self.assertIsNone(level)
        self.assertEqual(reason, "邀请码已过期")

    def test_quota_exhausted_blocked(self):
        """名额耗尽：consume 返回 False，不能注册。"""
        self.assertTrue(invitation_code.consume_code("beta"))
        self.assertFalse(invitation_code.consume_code("beta"))


class TestRegistrationUpgradeRoutes(_InvitationIsolated):
    """注册/升级路由逻辑直调（TestClient 因 fastapi/httpx 版本不兼容不可用，
    改直调路由函数做单元级端到端：带码注册成功、错误码 400、升级生效）。"""

    def setUp(self):
        super().setUp()
        self._db_patchers = _isolate_user_store(self._tmp / "db")
        for p in self._db_patchers:
            p.start()
            self.addCleanup(p.stop)

    @staticmethod
    def _run(coro):
        return asyncio.run(coro)

    @staticmethod
    def _fake_request():
        # 仅 auth_register 用到 request.client.host（登录/注册限流 key）
        return SimpleNamespace(client=SimpleNamespace(host="testclient"))

    def test_register_with_valid_code_success(self):
        """带码注册成功：返回 user.level=common + token。"""
        code = invitation_code.get_current_code("common")
        result = self._run(
            data_routes.auth_register(
                self._fake_request(),
                data_routes.RegisterRequest(
                    username="e2e_reg_ok",
                    password="secret123",
                    invitation_code=code,
                ),
            )
        )
        self.assertEqual(result["user"]["level"], "common")
        self.assertIn("token", result)
        self.assertEqual(invitation_code._codes["common"]["used_count"], 1)

    def test_register_with_bad_code_400(self):
        """错误邀请码注册返回 400「无效邀请码」。"""
        with self.assertRaises(HTTPException) as ctx:
            self._run(
                data_routes.auth_register(
                    self._fake_request(),
                    data_routes.RegisterRequest(
                        username="e2e_reg_bad",
                        password="secret123",
                        invitation_code="bad-code-xyz",
                    ),
                )
            )
        self.assertEqual(ctx.exception.status_code, 400)
        self.assertEqual(ctx.exception.detail, "无效邀请码")

    def test_register_without_code_400(self):
        """enabled=true 时缺邀请码返回 400「请输入邀请码」。"""
        with self.assertRaises(HTTPException) as ctx:
            self._run(
                data_routes.auth_register(
                    self._fake_request(),
                    data_routes.RegisterRequest(
                        username="e2e_reg_none", password="secret123"
                    ),
                )
            )
        self.assertEqual(ctx.exception.status_code, 400)
        self.assertEqual(ctx.exception.detail, "请输入邀请码")

    def test_upgrade_with_code(self):
        """带码升级：返回新 level 且 user_store 落库生效。"""
        user = user_store.create_account("e2e_up", "secret123", "Up")
        public = {
            k: v for k, v in user.items() if k not in ("password_hash", "salt")
        }
        pro_code = invitation_code.get_current_code("pro")
        result = self._run(
            data_routes.auth_upgrade(
                data_routes.UpgradeRequest(invitation_code=pro_code),
                current_user=public,
            )
        )
        self.assertEqual(result["level"], "pro")
        self.assertEqual(user_store.get_user_level(user["openid"]), "pro")

    def test_upgrade_bad_code_400(self):
        """升级错误码返回 400。"""
        user = user_store.create_account("e2e_up_bad", "secret123", "Up")
        public = {
            k: v for k, v in user.items() if k not in ("password_hash", "salt")
        }
        with self.assertRaises(HTTPException) as ctx:
            self._run(
                data_routes.auth_upgrade(
                    data_routes.UpgradeRequest(invitation_code="nope"),
                    current_user=public,
                )
            )
        self.assertEqual(ctx.exception.status_code, 400)
        self.assertEqual(ctx.exception.detail, "无效邀请码")


# ----------------------------------------------------------------------
# 5. restore_level 行为
# ----------------------------------------------------------------------
class TestRestoreLevelBehavior(unittest.TestCase):
    def setUp(self):
        self._tmp = Path(tempfile.mkdtemp(prefix="trae_restore_"))
        self._db_patchers = _isolate_user_store(self._tmp)
        for p in self._db_patchers:
            p.start()
            self.addCleanup(p.stop)

    def tearDown(self):
        shutil.rmtree(self._tmp, ignore_errors=True)

    def test_restore_true_recovers_db_value(self):
        """restore=True：清缓存后从 DB 恢复升级后的等级。"""
        u = user_store.create_account("restore_a", "secret123", "A")
        user_store.set_user_level(u["openid"], "ultra")
        self.assertEqual(user_store.get_user_level(u["openid"]), "ultra")

        # 模拟重启：清缓存 + restore=True
        user_store.load_levels_from_db(True)
        self.assertEqual(user_store.get_user_level(u["openid"]), "ultra")

    def test_restore_false_all_common_db_unchanged(self):
        """restore=False：全回 common，且不改 DB 落盘值。"""
        u = user_store.create_account("restore_b", "secret123", "B")
        user_store.set_user_level(u["openid"], "pro")
        user_store.load_levels_from_db(False)

        self.assertEqual(user_store.get_user_level(u["openid"]), "common")
        # DB 值保持不变（供未来恢复保留）
        self.assertEqual(user_store.get_user_by_openid(u["openid"])["level"], "pro")

        # restore=False 下重新 set_user_level 仍生效
        user_store.set_user_level(u["openid"], "beta")
        self.assertEqual(user_store.get_user_level(u["openid"]), "beta")


# ----------------------------------------------------------------------
# 6. 分级限流
# ----------------------------------------------------------------------
class TestLevelRateLimitResolution(unittest.TestCase):
    def setUp(self):
        # 等级解析走内存 mock，避免触碰真实 DB
        self._level_patch = patch.object(
            user_store, "get_user_level", return_value="common"
        )
        self._level_patch.start()
        self.addCleanup(self._level_patch.stop)

    def test_resolve_interval_by_level_and_toggle(self):
        """按等级 + 开关解析 interval（关闭用 rate_per_minute，开启用 active）。"""
        cases = [
            # (level, rate_per_minute, active_rate_per_minute, enabled, expected)
            ("common", 12, 6, False, 5.0),
            ("pro", 24, 6, False, 2.5),
            ("ultra", 60, 6, False, 1.0),
            ("beta", 300, 6, False, 0.2),
            ("common", 12, 6, True, 10.0),
            ("beta", 300, 6, True, 10.0),
        ]
        for level, rpm, arpm, enabled, expected in cases:
            with self.subTest(level=level, enabled=enabled):
                with patch.object(user_store, "get_user_level", return_value=level), \
                     patch.object(level_config, "get_level_config", return_value={
                         "rate_per_minute": rpm,
                         "active_rate_per_minute": arpm,
                     }), \
                     patch.object(rate_limit, "is_user_enabled", return_value=enabled):
                    self.assertAlmostEqual(
                        rate_limit._resolve_interval("u_x"), expected
                    )

    def test_fallback_min_interval(self):
        """等级配置缺失 / rate<=0：回退 MIN_INTERVAL。"""
        with patch.object(level_config, "get_level_config", return_value={}), \
             patch.object(rate_limit, "is_user_enabled", return_value=False):
            self.assertEqual(
                rate_limit._resolve_interval("u_x"), rate_limit.MIN_INTERVAL
            )
        with patch.object(level_config, "get_level_config", return_value={
                "rate_per_minute": 0, "active_rate_per_minute": -1}), \
             patch.object(rate_limit, "is_user_enabled", return_value=False):
            self.assertEqual(
                rate_limit._resolve_interval("u_x"), rate_limit.MIN_INTERVAL
            )


# ----------------------------------------------------------------------
# 7. 并发拒绝
# ----------------------------------------------------------------------
class TestConcurrencyLimit(unittest.TestCase):
    def setUp(self):
        chat._active_tasks.clear()

    def tearDown(self):
        chat._active_tasks.clear()

    @staticmethod
    def _add(user_id, agent_id, n_sessions=1):
        for i in range(n_sessions):
            chat._active_tasks[(user_id, agent_id, f"s{i}")] = threading.Event()

    def test_count_active_agents_dedup(self):
        """同一 agent 多会话去重计数；不同用户隔离。"""
        self._add("u1", "a1", n_sessions=2)
        self._add("u1", "a2", n_sessions=1)
        self._add("u2", "a9", n_sessions=1)
        self.assertEqual(chat._count_active_agents("u1"), 2)
        self.assertEqual(chat._count_active_agents("u2"), 1)
        self.assertEqual(chat._count_active_agents("u3"), 0)

    def test_concurrency_limit_reached_common(self):
        """common max_concurrent_agents=4：4 个并发判定已达上限。"""
        self._add("u1", "a1")
        self._add("u1", "a2")
        self._add("u1", "a3")
        self._add("u1", "a4")
        with patch("data.user_store.get_user_level", return_value="common"), \
             patch("config.levels.get_level_config", return_value={
                 "max_concurrent_agents": 4,
             }):
            reached, active = chat._concurrency_limit_reached("u1")
        self.assertTrue(reached)
        self.assertEqual(active, 4)

    def test_concurrency_limit_not_reached(self):
        """未达上限：返回 (False, 当前并发数)。"""
        self._add("u1", "a1")
        self._add("u1", "a2")
        with patch("data.user_store.get_user_level", return_value="common"), \
             patch("config.levels.get_level_config", return_value={
                 "max_concurrent_agents": 4,
             }):
            reached, active = chat._concurrency_limit_reached("u1")
        self.assertFalse(reached)
        self.assertEqual(active, 2)

    def test_unlimited_level_not_reached(self):
        """上限 >0 但远超当前并发（如 ultra 72 / beta 500）不拒绝。"""
        self._add("u1", "a1")
        with patch("data.user_store.get_user_level", return_value="ultra"), \
             patch("config.levels.get_level_config", return_value={
                 "max_concurrent_agents": 72,
             }):
            reached, _ = chat._concurrency_limit_reached("u1")
        self.assertFalse(reached)


class TestDispatchUserMessageNoFallback(unittest.TestCase):
    """_dispatch_user_message：concurrency_limited 结果不回落到 _handle_user_message。"""

    def test_concurrency_limited_sends_hint_not_fallback(self):
        chat._active_tasks.clear()
        self.addCleanup(chat._active_tasks.clear)

        with patch.object(
            chat,
            "_dispatch_agent_message",
            return_value={"status": "concurrency_limited"},
        ), patch.object(chat, "_send_text_as_agent", new=AsyncMock()) as send:
            asyncio.run(
                chat._dispatch_user_message(
                    "u1",
                    {
                        "agent_id": "a1",
                        "content": "hi",
                        "session_id": "s1",
                    },
                )
            )
            send.assert_awaited_once()
            args = send.await_args.args
            self.assertEqual(args[0], "u1")
            self.assertEqual(args[1], "a1")
            self.assertIn("并发任务已达上限", args[2])


if __name__ == "__main__":
    unittest.main()
