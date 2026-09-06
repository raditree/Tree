# -*- coding: utf-8 -*-
"""auth_token 多设备生命周期管理测试（隔离临时 DB）。

覆盖 Task 8 验收点：
1. 签发 → 校验通过；同一用户第二个 token 并存有效（多设备互不影响）
2. 撤销 token A 后 A 拒绝（TokenRevokedError）、B 仍有效
3. 过期拒绝：篡改 DB expires_at / 注入短 TTL（expire_hours=-1）
4. 旧数据无 jti 行为：payload 无 jti 或表中无该 jti 行 → 拒绝（安全默认）
5. 启动/惰性清理函数行为：purge_expired 返回删除行数；verify 惰性触发

所有模块通过临时目录重定位 ``data.db._DB_PATH`` 并重置初始化标记，
避免污染真实数据库。
"""

import shutil
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

# 将 server 目录加入 Python 路径
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import jwt as pyjwt  # noqa: E402

import data.auth_token_store as auth_token_store  # noqa: E402
import data.db as db_mod  # noqa: E402
from ws import auth  # noqa: E402

_FIXED_SECRET = "fixed-secret-abc-0123456789abcdefghij"


def _jwt_cfg(expire_hours: int = 72) -> dict:
    return {
        "jwt": {
            "secret": _FIXED_SECRET,
            "algorithm": "HS256",
            "expire_hours": expire_hours,
        }
    }


class AuthTokenBase(unittest.TestCase):
    """每个用例独立临时 DB + 固定 JWT 配置。"""

    def setUp(self):
        self._tmp = Path(tempfile.mkdtemp(prefix="trae_test_auth_tokens_"))
        self._orig_db_path = db_mod._DB_PATH  # type: ignore[attr-defined]
        self._orig_wal = db_mod._wal_configured  # type: ignore[attr-defined]
        self._orig_store_db = auth_token_store._DB_PATH
        self._orig_store_init = auth_token_store._initialized
        self._orig_secret = auth._JWT_SECRET
        self._orig_random = auth.random
        db_mod._DB_PATH = self._tmp / "conversations.db"  # type: ignore[attr-defined]
        db_mod._wal_configured = False  # type: ignore[attr-defined]
        auth_token_store._DB_PATH = self._tmp / "conversations.db"
        auth_token_store._initialized = False
        auth._JWT_SECRET = None
        # 默认惰性清理不触发（随机数恒 1.0 ≥ 0.02）；需要触发时用 _force_lazy_purge
        auth.random = SimpleNamespace(random=lambda: 1.0)
        self._cfg_patch = patch.object(auth, "get_config", return_value=_jwt_cfg())
        self._cfg_patch.start()

    def tearDown(self):
        self._cfg_patch.stop()
        auth.random = self._orig_random
        auth._JWT_SECRET = self._orig_secret
        auth_token_store._initialized = self._orig_store_init
        auth_token_store._DB_PATH = self._orig_store_db
        db_mod._DB_PATH = self._orig_db_path  # type: ignore[attr-defined]
        db_mod._wal_configured = self._orig_wal  # type: ignore[attr-defined]
        shutil.rmtree(self._tmp, ignore_errors=True)

    def _force_lazy_purge(self) -> None:
        """令下一次 verify_token 必然触发惰性清理（random() < 0.02）。"""
        auth.random = SimpleNamespace(random=lambda: 0.0)

    @staticmethod
    def _insert_row(token_id: str, expires_at: float, user_id: str = "u1") -> None:
        """直接注入一条 token 行（模拟过期/历史数据）。"""
        conn = db_mod.connect()
        try:
            conn.execute(
                "INSERT INTO auth_tokens "
                "(token_id, user_id, device, created_at, expires_at, revoked) "
                "VALUES (?, ?, '', ?, ?, 0)",
                (token_id, user_id, time.time() - 3600, expires_at),
            )
            conn.commit()
        finally:
            conn.close()

    @staticmethod
    def _row_ids() -> set:
        conn = db_mod.connect()
        try:
            return {r[0] for r in conn.execute("SELECT token_id FROM auth_tokens")}
        finally:
            conn.close()


class TestIssueAndVerify(AuthTokenBase):
    def test_issue_then_verify_passes(self):
        token = auth.create_token({"openid": "u1", "name": "tester"})
        payload = auth.verify_token(token)
        self.assertEqual(payload["user"]["openid"], "u1")
        self.assertTrue(payload["jti"], "签发必须包含 jti claim")
        row = auth_token_store.get_token(payload["jti"])
        self.assertIsNotNone(row)
        self.assertEqual(row["user_id"], "u1")
        self.assertEqual(row["device"], "", "device 缺省空串")
        self.assertFalse(row["revoked"])

    def test_second_token_same_user_coexists(self):
        t_phone = auth.create_token({"openid": "u1"}, device="手机")
        t_pc = auth.create_token({"openid": "u1"}, device="电脑")
        p1 = auth.verify_token(t_phone)
        p2 = auth.verify_token(t_pc)
        self.assertNotEqual(p1["jti"], p2["jti"], "每个 token 应有独立 jti")
        self.assertEqual(
            auth_token_store.get_token(p1["jti"])["device"], "手机"
        )
        self.assertEqual(
            auth_token_store.get_token(p2["jti"])["device"], "电脑"
        )
        self.assertEqual(len(self._row_ids()), 2, "多设备 token 并存落库")


class TestRevoke(AuthTokenBase):
    def test_revoke_a_rejects_b_still_valid(self):
        t_a = auth.create_token({"openid": "u1"})
        t_b = auth.create_token({"openid": "u1"})
        auth.revoke_token(t_a)
        with self.assertRaises(auth.TokenRevokedError):
            auth.verify_token(t_a)
        # 同一用户 token B 不受影响（多设备互不影响）
        payload = auth.verify_token(t_b)
        self.assertTrue(payload["jti"])
        # 撤销 B 后同样拒绝；TokenRevokedError 属于 InvalidTokenError 家族
        auth.revoke_token(t_b)
        with self.assertRaises(pyjwt.InvalidTokenError):
            auth.verify_token(t_b)

    def test_revoke_persists_in_store(self):
        token = auth.create_token({"openid": "u1"})
        jti = pyjwt.decode(
            token, options={"verify_signature": False}
        )["jti"]
        auth.revoke_token(token)
        self.assertTrue(auth_token_store.get_token(jti)["revoked"])


class TestExpired(AuthTokenBase):
    def test_db_expires_at_tampered_rejected(self):
        token = auth.create_token({"openid": "u1"})
        # JWT exp 仍有效，但表中 expires_at 被改到过去 → 拒绝
        conn = db_mod.connect()
        try:
            conn.execute("UPDATE auth_tokens SET expires_at = ?", (time.time() - 10,))
            conn.commit()
        finally:
            conn.close()
        with self.assertRaises(pyjwt.ExpiredSignatureError):
            auth.verify_token(token)

    def test_short_ttl_token_rejected(self):
        # 注入短 TTL：expire_hours=-1 → 签发即过期（JWT 库 exp 校验先拒）
        with patch.object(auth, "get_config", return_value=_jwt_cfg(-1)):
            token = auth.create_token({"openid": "u1"})
        with self.assertRaises(pyjwt.ExpiredSignatureError):
            auth.verify_token(token)


class TestLegacyTokenWithoutJti(AuthTokenBase):
    def test_payload_without_jti_rejected(self):
        now = int(time.time())
        legacy = pyjwt.encode(
            {"user": {"id": "u1"}, "iat": now, "exp": now + 3600},
            _FIXED_SECRET,
            algorithm="HS256",
        )
        with self.assertRaises(pyjwt.InvalidTokenError):
            auth.verify_token(legacy)

    def test_jti_missing_in_table_rejected(self):
        # jti 在 payload 中但表中无对应行（旧数据 / 记录已被清理）→ 安全默认拒绝
        now = int(time.time())
        orphan = pyjwt.encode(
            {
                "user": {"id": "u1"},
                "iat": now,
                "exp": now + 3600,
                "jti": "orphan-jti-not-in-db",
            },
            _FIXED_SECRET,
            algorithm="HS256",
        )
        with self.assertRaises(pyjwt.InvalidTokenError):
            auth.verify_token(orphan)
        self.assertIsNone(auth_token_store.get_token("orphan-jti-not-in-db"))


class TestPurge(AuthTokenBase):
    def test_purge_expired_returns_deleted_count(self):
        active = auth.create_token({"openid": "u1"})
        active_jti = pyjwt.decode(active, options={"verify_signature": False})["jti"]
        self._insert_row("expired-1", time.time() - 100)
        self._insert_row("expired-2", time.time() - 1)
        self.assertEqual(len(self._row_ids()), 3)

        deleted = auth_token_store.purge_expired()
        self.assertEqual(deleted, 2, "应删除 2 条过期行并返回行数")
        self.assertEqual(self._row_ids(), {active_jti}, "未过期行保留")
        # 幂等：再清一次返回 0
        self.assertEqual(auth_token_store.purge_expired(), 0)

    def test_lazy_purge_triggered_on_verify(self):
        token = auth.create_token({"openid": "u1"})
        self._insert_row("expired-lazy", time.time() - 100)
        self._force_lazy_purge()  # random() 恒 0.0 < 0.02 → 必触发
        auth.verify_token(token)
        self.assertIsNone(auth_token_store.get_token("expired-lazy"))

    def test_lazy_purge_not_triggered_normally(self):
        token = auth.create_token({"openid": "u1"})
        self._insert_row("expired-still", time.time() - 100)
        auth.verify_token(token)  # setUp 已固定 random()=1.0 → 不触发
        self.assertIsNotNone(auth_token_store.get_token("expired-still"))

    def test_revoked_error_is_invalid_token_subclass(self):
        self.assertTrue(issubclass(auth.TokenRevokedError, pyjwt.InvalidTokenError))


if __name__ == "__main__":
    unittest.main()
