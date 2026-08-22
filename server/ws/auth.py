"""JWT 认证模块 - token 生成、验证与依赖注入。"""
import time
from typing import Any, Dict, Set

import jwt
from fastapi import HTTPException, Request, status

from config.config import get_config


# 已撤销的 token 集合（内存暂存，进程重启后失效）
_REVOKED_TOKENS: Set[str] = set()


def create_token(user_data: dict) -> str:
    """生成 JWT token。

    从 ``get_config()["jwt"]`` 读取 secret、algorithm、expire_hours，
    payload 包含 ``user_data``、``exp``（过期时间）、``iat``（签发时间）。
    """
    jwt_cfg = get_config().get("jwt", {})
    secret = jwt_cfg.get("secret", "change-me-in-production")
    algorithm = jwt_cfg.get("algorithm", "HS256")
    expire_hours = int(jwt_cfg.get("expire_hours", 72))

    now = int(time.time())
    payload: Dict[str, Any] = {
        "user": user_data,
        "iat": now,
        "exp": now + expire_hours * 3600,
    }
    return jwt.encode(payload, secret, algorithm=algorithm)


def verify_token(token: str) -> dict:
    """验证 JWT token，返回 payload。

    验证失败抛出 :class:`jwt.InvalidTokenError`。
    若 token 已被撤销，同样抛出 :class:`jwt.InvalidTokenError`。
    """
    if token in _REVOKED_TOKENS:
        raise jwt.InvalidTokenError("Token has been revoked")

    jwt_cfg = get_config().get("jwt", {})
    secret = jwt_cfg.get("secret", "change-me-in-production")
    algorithm = jwt_cfg.get("algorithm", "HS256")

    return jwt.decode(token, secret, algorithms=[algorithm])


def get_current_user(request: Request) -> dict:
    """FastAPI 依赖注入：从 Authorization header 提取 Bearer token 并验证。

    无效 token 抛出 HTTP 401。返回 payload 中的用户信息。
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
    except jwt.InvalidTokenError as e:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"无效的 token: {e}",
            headers={"WWW-Authenticate": "Bearer"},
        )

    return payload.get("user", {})


def refresh_token(token: str) -> str:
    """刷新 token：验证旧 token 有效性，生成新 token。"""
    payload = verify_token(token)
    user_data = payload.get("user", {})
    return create_token(user_data)


def revoke_token(token: str) -> None:
    """撤销 token：加入已撤销集合（内存暂存）。"""
    _REVOKED_TOKENS.add(token)
