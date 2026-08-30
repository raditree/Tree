"""主动延迟（API 调用频率限制）偏好存储。

前端「设置 - 主动延迟」开关（``rate_limit_prefs`` 表）开启后，限制单个
agent 的 LLM API 调用频率（平均 6 次/分钟），适合交互式开发。

存储仅保存开关偏好；限流执行逻辑在 ``llm/rate_limit.py``（内存缓存 +
令牌桶）。REST 设置接口写库后同步更新内存缓存；服务启动时
``load_all_rate_limit_prefs`` 预载到内存，避免每次 API 调用查库。
"""
import sqlite3
import threading
import time
from pathlib import Path
from typing import Dict

# 日志器
import logging

logger = logging.getLogger(__name__)

from data.db import connect  # noqa: E402

# 数据库目录（与 conversation_store 保持一致）
_DATA_DIR = Path(__file__).resolve().parent.parent / "data"
_DB_PATH = _DATA_DIR / "conversations.db"

# 写操作锁
_write_lock = threading.Lock()
_initialized = False


def _ensure_db() -> None:
    """确保偏好表已创建（线程安全的惰性初始化）。"""
    global _initialized
    if _initialized:
        return
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    with connect() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS rate_limit_prefs (
                openid TEXT PRIMARY KEY,
                enabled INTEGER NOT NULL DEFAULT 0,
                updated_at INTEGER NOT NULL
            )
            """
        )
        conn.commit()
    _initialized = True


def _connect():
    _ensure_db()
    conn = connect()
    return conn


# ----------------------------------------------------------------------
# 主动延迟开关
# ----------------------------------------------------------------------
def set_rate_limit_enabled(openid: str, enabled: bool) -> None:
    """设置某用户的「主动延迟」开关（upsert）。"""
    _ensure_db()
    now = int(time.time() * 1000)
    with _write_lock:
        conn = _connect()
        try:
            conn.execute(
                "INSERT INTO rate_limit_prefs (openid, enabled, updated_at) "
                "VALUES (?, ?, ?) "
                "ON CONFLICT(openid) DO UPDATE SET "
                "enabled = excluded.enabled, updated_at = excluded.updated_at",
                (openid, 1 if enabled else 0, now),
            )
            conn.commit()
        finally:
            conn.close()


def is_rate_limit_enabled(openid: str) -> bool:
    """查询用户是否开启主动延迟（缺省 False）。"""
    _ensure_db()
    conn = _connect()
    try:
        row = conn.execute(
            "SELECT enabled FROM rate_limit_prefs WHERE openid = ?",
            (openid,),
        ).fetchone()
        return bool(row and row[0])
    finally:
        conn.close()


def load_all_rate_limit_prefs() -> Dict[str, bool]:
    """读取全部用户的主动延迟开关（服务启动时预载到内存）。"""
    _ensure_db()
    conn = _connect()
    try:
        rows = conn.execute(
            "SELECT openid, enabled FROM rate_limit_prefs"
        ).fetchall()
        return {str(openid): bool(enabled) for openid, enabled in rows}
    finally:
        conn.close()


def delete_user_rate_limit_pref(user_id: str) -> None:
    """删除某用户的主动延迟偏好（注销彻底删除时级联调用）。"""
    _ensure_db()
    with _write_lock, connect() as conn:
        conn.execute("DELETE FROM rate_limit_prefs WHERE openid = ?", (user_id,))
        conn.commit()
