"""JWT 认证模块 - token 生成、验证与依赖注入。

多设备生命周期管理（Task 8）：每次签发生成唯一 ``jti`` 并落库
（``data.auth_token_store`` 的 ``auth_tokens`` 表）。校验 = 签名有效 ∧
jti 存在于表 ∧ 未撤销 ∧ 未过期；撤销持久化到 SQLite（进程重启不丢失）。
同一用户多设备可无限 token 并存，互不影响。
"""
import logging
import random
import secrets
import time
from typing import Any, Dict, Optional

import jwt
from fastapi import HTTPException, Request, status

from config.config import get_config
from data import auth_token_store

logger = logging.getLogger(__name__)

# 惰性清理触发概率：verify_token 每次校验时以此概率顺带删除过期 token 行
_LAZY_PURGE_PROBABILITY = 0.02

# JWT 签名密钥（内存缓存）：配置留空时启动后随机生成，不落盘。
# 副作用：进程重启后密钥变化，所有已签发 token 失效（需重新登录）。
_JWT_SECRET: Optional[str] = None


class TokenRevokedError(jwt.InvalidTokenError):
    """token 已被撤销（持久化于 auth_tokens 表）。"""
    pass


def _get_jwt_secret() -> str:
    """返回 JWT 签名密钥（进程内内存缓存，仅首次计算）。

    优先使用 ``configs/app.yaml`` 的 ``jwt.secret``（非空时，向后兼容跨重启
    保持登录态的部署）；留空/缺失时用 ``secrets.token_urlsafe`` 随机生成
    （数据无硬编码泄露风险）。
    """
    global _JWT_SECRET
    if _JWT_SECRET is None:
        jwt_cfg = get_config().get("jwt", {}) or {}
        configured = (jwt_cfg.get("secret") or "").strip()
        _JWT_SECRET = configured or secrets.token_urlsafe(32)
    return _JWT_SECRET


def _user_id_of(user_data: dict) -> str:
    """从用户字典提取 user_id（兼容 openid / id 两种主键命名）。"""
    return str(user_data.get("openid") or user_data.get("id") or "")


def create_token(user_data: dict, device: str = "") -> str:
    """生成 JWT token 并登记到 auth_tokens 表。

    从 ``get_config()["jwt"]`` 读取 algorithm、expire_hours；签名密钥经
    :func:`_get_jwt_secret` 解析（配置留空则随机内存密钥）。
    payload 包含 ``user_data``、``exp``（过期时间）、``iat``（签发时间）、
    ``jti``（token 唯一标识，落库供撤销/多设备管理）。
    ``device`` 为可选设备备注名（缺省空串，多设备并存互不影响）。
    """
    jwt_cfg = get_config().get("jwt", {})
    algorithm = jwt_cfg.get("algorithm", "HS256")
    expire_hours = int(jwt_cfg.get("expire_hours", 72))

    now = int(time.time())
    expires_at = now + expire_hours * 3600
    jti = secrets.token_urlsafe(16)
    payload: Dict[str, Any] = {
        "user": user_data,
        "iat": now,
        "exp": expires_at,
        "jti": jti,
    }
    auth_token_store.save_token(
        jti,
        _user_id_of(user_data),
        expires_at,
        device=(device or "").strip(),
        created_at=now,
    )
    return jwt.encode(payload, _get_jwt_secret(), algorithm=algorithm)


def _lazy_purge_expired() -> None:
    """verify 路径小概率惰性清理过期 token 行（失败不影响校验）。"""
    if random.random() >= _LAZY_PURGE_PROBABILITY:
        return
    try:
        auth_token_store.purge_expired()
    except Exception as exc:  # noqa: BLE001
        logger.warning("惰性清理过期 token 失败: %s", exc)


def verify_token(token: str) -> dict:
    """验证 JWT token，返回 payload。

    验证 = 签名有效 ∧ jti 存在于 auth_tokens 表 ∧ revoked=0 ∧ 未过期；
    任一不满足抛出 :class:`jwt.InvalidTokenError`，错误信息区分：
    已撤销（:class:`TokenRevokedError`）/ 已过期
    （:class:`jwt.ExpiredSignatureError`）/ 无效（其余 InvalidTokenError）。
    """
    jwt_cfg = get_config().get("jwt", {})
    algorithm = jwt_cfg.get("algorithm", "HS256")

    # 签名 + exp（jwt 库）校验：过期直接抛 ExpiredSignatureError
    payload = jwt.decode(token, _get_jwt_secret(), algorithms=[algorithm])

    _lazy_purge_expired()

    jti = payload.get("jti", "")
    if not jti:
        raise jwt.InvalidTokenError("Token has no jti")
    row = auth_token_store.get_token(jti)
    if row is None:
        # 表中无该 jti（旧版本签发的 token / 记录已清理）→ 安全默认拒绝
        raise jwt.InvalidTokenError("Token record not found")
    if row["revoked"]:
        raise TokenRevokedError("Token has been revoked")
    if row["expires_at"] < time.time():
        raise jwt.ExpiredSignatureError("Token has expired")
    return payload


def get_current_user(request: Request) -> dict:
    """FastAPI 依赖注入：从 Authorization header 提取 Bearer token 并验证。

    无效/已撤销/已过期 token 均抛 HTTP 401，detail 区分具体原因。
    返回 payload 中的用户信息。
    """
    auth_header = request.headers.get("Authorization", "")
    if not auth_header.startswith("Bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="缺少有效的 Authorization 头",
            headers={"WWW-Authenticate": "Bearer"},
        )

    token = auth_header[len("Bearer "):].strip()
    try:
        payload = verify_token(token)
    except jwt.ExpiredSignatureError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="token 已过期，请重新登录",
            headers={"WWW-Authenticate": "Bearer"},
        )
    except TokenRevokedError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="token 已撤销，请重新登录",
            headers={"WWW-Authenticate": "Bearer"},
        )
    except jwt.InvalidTokenError as e:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"无效的 token: {e}",
            headers={"WWW-Authenticate": "Bearer"},
        )

    return payload.get("user", {})


def refresh_token(token: str) -> str:
    """刷新 token：验证旧 token 有效性，生成新 token（新 jti 落库）。"""
    payload = verify_token(token)
    user_data = payload.get("user", {})
    return create_token(user_data)


def revoke_token(token: str) -> None:
    """撤销 token：按 payload 中的 jti 置 revoked=1（持久化）。

    忽略 exp 校验（已过期 token 也可标记撤销，幂等无副作用）；
    无 jti 的旧格式 token 无记录可撤销（其本身已因无记录被拒绝）。
    """
    jwt_cfg = get_config().get("jwt", {})
    algorithm = jwt_cfg.get("algorithm", "HS256")
    payload = jwt.decode(
        token,
        _get_jwt_secret(),
        algorithms=[algorithm],
        options={"verify_exp": False},
    )
    jti = payload.get("jti", "")
    if jti:
        auth_token_store.revoke_token(jti)
