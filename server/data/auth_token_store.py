"""JWT token 生命周期存储（多设备登录态，auth_tokens 表）。

每签发一个 token（JWT ``jti``）落一行，记录 user_id / device / 过期时间；
校验与撤销以本表为准（进程重启后撤销不丢失），同一用户多设备可无限
token 并存，互不影响。

过期清理：
- 应用启动时全量清理一次（main.py lifespan 调用 :func:`purge_expired`）；
- verify_token 以小概率惰性清理（见 ws/auth.py）。

表结构沿用 data.db 共享连接（conversations.db 单库多存储模块）。
"""
import logging
import threading
import time
from pathlib import Path
from typing import Optional

logger = logging.getLogger(__name__)

from data.db import connect  # noqa: E402

# 数据库目录（与 conversation_store 保持一致）
_DATA_DIR = Path(__file__).resolve().parent.parent / "data"
_DB_PATH = _DATA_DIR / "conversations.db"

# 写操作锁
_write_lock = threading.Lock()
_initialized = False


def _ensure_db() -> None:
    """确保 token 表已创建（线程安全的惰性初始化）。"""
    global _initialized
    if _initialized:
        return
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    with connect() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS auth_tokens (
                token_id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL DEFAULT '',
                device TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                expires_at REAL NOT NULL,
                revoked INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_auth_tokens_user_id "
            "ON auth_tokens(user_id)"
        )
        conn.commit()
    _initialized = True


def save_token(
    token_id: str,
    user_id: str,
    expires_at: float,
    device: str = "",
    created_at: Optional[float] = None,
) -> None:
    """签发时落库一行 token 记录（jti 主键，重复签发幂等覆盖）。"""
    _ensure_db()
    if created_at is None:
        created_at = time.time()
    with _write_lock:
        conn = connect()
        try:
            conn.execute(
                "INSERT OR REPLACE INTO auth_tokens "
                "(token_id, user_id, device, created_at, expires_at, revoked) "
                "VALUES (?, ?, ?, ?, ?, 0)",
                (token_id, user_id, device, float(created_at), float(expires_at)),
            )
            conn.commit()
        finally:
            conn.close()


def get_token(token_id: str) -> Optional[dict]:
    """按 jti 读取 token 记录；不存在返回 None（旧 token / 未知 jti）。"""
    _ensure_db()
    conn = connect()
    try:
        row = conn.execute(
            "SELECT token_id, user_id, device, created_at, expires_at, revoked "
            "FROM auth_tokens WHERE token_id = ?",
            (token_id,),
        ).fetchone()
    finally:
        conn.close()
    if row is None:
        return None
    return {
        "token_id": row[0],
        "user_id": row[1],
        "device": row[2],
        "created_at": row[3],
        "expires_at": row[4],
        "revoked": bool(row[5]),
    }


def revoke_token(token_id: str) -> bool:
    """按 jti 置 revoked=1（幂等）；返回是否确有记录被更新。"""
    _ensure_db()
    with _write_lock:
        conn = connect()
        try:
            cursor = conn.execute(
                "UPDATE auth_tokens SET revoked = 1 "
                "WHERE token_id = ? AND revoked = 0",
                (token_id,),
            )
            conn.commit()
            return cursor.rowcount > 0
        finally:
            conn.close()


def purge_expired(now: Optional[float] = None) -> int:
    """删除 expires_at 已过的 token 行，返回删除行数（启动全量/惰性清理共用）。"""
    _ensure_db()
    if now is None:
        now = time.time()
    with _write_lock:
        conn = connect()
        try:
            cursor = conn.execute(
                "DELETE FROM auth_tokens WHERE expires_at < ?", (float(now),)
            )
            conn.commit()
            return int(cursor.rowcount)
        finally:
            conn.close()


def delete_user_tokens(user_id: str) -> None:
    """删除某用户全部 token（注销彻底删除时级联调用）。"""
    _ensure_db()
    with _write_lock, connect() as conn:
        conn.execute("DELETE FROM auth_tokens WHERE user_id = ?", (user_id,))
        conn.commit()
