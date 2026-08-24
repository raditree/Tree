# -*- coding: utf-8 -*-
"""JWT 认证模块单元测试：内存随机密钥与配置固定密钥两种模式。

覆盖：
- 配置 secret 留空 → 启动后随机生成、内存缓存（同一进程内一致、有足够熵）
- 配置 secret 留空 → create_token / verify_token 自洽
- 配置 secret 非空 → 使用配置值（向后兼容，跨重启保持登录态）
- jwt 段缺失 → 回退随机
- 无效 token → 抛 InvalidTokenError
"""

import unittest
from unittest.mock import patch

import jwt as pyjwt

from ws import auth


class TestJwtSecret(unittest.TestCase):
    def setUp(self):
        # 重置模块级密钥缓存，避免跨用例污染
        auth._JWT_SECRET = None

    @staticmethod
    def _cfg(secret=""):
        return {"jwt": {"secret": secret, "algorithm": "HS256", "expire_hours": 72}}

    def test_empty_secret_generates_random_in_memory(self):
        with patch.object(auth, "get_config", return_value=self._cfg("")):
            s1 = auth._get_jwt_secret()
            s2 = auth._get_jwt_secret()
        self.assertTrue(s1, "随机密钥不应为空")
        self.assertEqual(s1, s2, "同一进程内密钥应内存缓存一致")
        self.assertNotEqual(s1, "change-me-in-production")
        # token_urlsafe(32) -> 43 字符，应有足够熵
        self.assertGreaterEqual(len(s1), 40)

    def test_empty_secret_sign_and_verify(self):
        with patch.object(auth, "get_config", return_value=self._cfg("")):
            token = auth.create_token({"id": "u1", "name": "tester"})
            payload = auth.verify_token(token)
        self.assertEqual(payload["user"]["id"], "u1")

    def test_configured_secret_used(self):
        fixed = "fixed-secret-abc-0123456789abcdefghij"  # 32+ 字节，避免 InsecureKeyLengthWarning
        with patch.object(auth, "get_config", return_value=self._cfg(fixed)):
            self.assertEqual(auth._get_jwt_secret(), fixed)
            token = auth.create_token({"id": "u1"})
            payload = auth.verify_token(token)
        self.assertEqual(payload["user"]["id"], "u1")
        # 用配置密钥可独立验证（证明用的就是配置值，而非随机）
        decoded = pyjwt.decode(token, fixed, algorithms=["HS256"])
        self.assertEqual(decoded["user"]["id"], "u1")

    def test_missing_jwt_section_falls_back_random(self):
        with patch.object(auth, "get_config", return_value={}):
            s = auth._get_jwt_secret()
        self.assertTrue(s)

    def test_verify_invalid_token_raises(self):
        with patch.object(auth, "get_config", return_value=self._cfg("")):
            with self.assertRaises(pyjwt.InvalidTokenError):
                auth.verify_token("not-a-valid-token")


if __name__ == "__main__":
    unittest.main()
