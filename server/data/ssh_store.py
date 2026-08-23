"""SSH 连接配置存储 - ``ssh_connections`` 表 CRUD。

SSH 运行模式配置按 ``(user_id, agent_id)`` 维度持久化到 SQLite
（与 user_store / agent_store 共用 ``server/data/conversations.db``），
保证重启后端后 SSH 配置仍生效（spec「三模式运行」场景）。

**不存储 SSH 密码**：连接由前端发起，后端仅保留 host/port/username 等
定位信息；历史遗留的密码字段会在初始化时清空（数据最小化）。
"""
import logging
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)

# 数据库目录与文件（与 user_store 保持一致，定位到 server/data）
_DATA_DIR = Path(__file__).resolve().parent.parent / "data"
_DB_PATH = _DATA_DIR / "conversations.db"

# 写操作锁
_write_lock = threading.Lock()
_initialized = False


def _ensure_db() -> None:
    """确保 ssh_connections 表已创建（线程安全的惰性初始化）。"""
    global _initialized
    if _initialized:
        return
    with sqlite3.connect(_DB_PATH) as conn:
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS ssh_connections (
                user_id TEXT NOT NULL,
                agent_id TEXT NOT NULL,
                host TEXT NOT NULL,
                port INTEGER NOT NULL DEFAULT 22,
                username TEXT NOT NULL,
                auth_type TEXT NOT NULL DEFAULT 'password',
                password TEXT NOT NULL DEFAULT '',
                private_key_path TEXT NOT NULL DEFAULT '',
                remote_base_dir TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (user_id, agent_id)
            )
            """
        )
        # 数据最小化：清理历史遗留的 SSH 密码（含既有加密密文）。
        # 连接已由前端发起，后端不再存储/消费任何 SSH 密码。
        conn.execute(
            "UPDATE ssh_connections SET password = '' WHERE password != ''"
        )
        conn.commit()
    _initialized = True


def _connect():
    _ensure_db()
    conn = sqlite3.connect(_DB_PATH)
    conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
    return conn


def _row_to_dict(row: sqlite3.Row) -> Dict[str, Any]:
    return {
        "user_id": row["user_id"],
        "agent_id": row["agent_id"],
        "host": row["host"],
        "port": row["port"],
        "username": row["username"],
        "auth_type": row["auth_type"],
        # 后端不再存储/消费 SSH 密码（连接由前端发起），统一返回空串
        "password": "",
        "private_key_path": row["private_key_path"],
        "remote_base_dir": row["remote_base_dir"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


def save_connection(
    user_id: str,
    agent_id: str,
    host: str,
    port: int = 22,
    username: str = "",
    auth_type: str = "password",
    private_key_path: str = "",
    remote_base_dir: str = "",
) -> Dict[str, Any]:
    """保存（或覆盖）一个 SSH 连接配置。

    以 ``(user_id, agent_id)`` 为键。**不存储 SSH 密码**：连接由前端发起，
    后端仅保留 host/port/username 等定位信息与模式标记。
    """
    now = int(time.time())
    with _write_lock:
        conn = _connect()
        try:
            conn.execute(
                """
                INSERT INTO ssh_connections (
                    user_id, agent_id, host, port, username, auth_type,
                    private_key_path, remote_base_dir, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(user_id, agent_id) DO UPDATE SET
                    host = excluded.host,
                    port = excluded.port,
                    username = excluded.username,
                    auth_type = excluded.auth_type,
                    private_key_path = excluded.private_key_path,
                    remote_base_dir = excluded.remote_base_dir,
                    updated_at = excluded.updated_at
                """,
                (
                    user_id, agent_id, host, int(port), username, auth_type,
                    private_key_path, remote_base_dir, now, now,
                ),
            )
            conn.commit()
        finally:
            conn.close()
    return get_connection(user_id, agent_id) or {}


def get_connection(user_id: str, agent_id: str) -> Optional[Dict[str, Any]]:
    """按 ``(user_id, agent_id)`` 读取 SSH 连接配置；不存在返回 None。"""
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        cur = conn.execute(
            "SELECT * FROM ssh_connections WHERE user_id = ? AND agent_id = ?",
            (user_id, agent_id),
        )
        row = cur.fetchone()
        return _row_to_dict(row) if row else None
    finally:
        conn.close()


def delete_connection(user_id: str, agent_id: str) -> bool:
    """删除指定 SSH 连接配置，返回是否实际删除。"""
    with _write_lock:
        conn = _connect()
        try:
            cur = conn.execute(
                "DELETE FROM ssh_connections WHERE user_id = ? AND agent_id = ?",
                (user_id, agent_id),
            )
            conn.commit()
            return cur.rowcount > 0
        finally:
            conn.close()


def get_all_connections(user_id: str) -> List[Dict[str, Any]]:
    """列出某用户全部 SSH 连接配置。"""
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        cur = conn.execute(
            "SELECT * FROM ssh_connections WHERE user_id = ? ORDER BY updated_at DESC",
            (user_id,),
        )
        return [_row_to_dict(r) for r in cur.fetchall()]
    finally:
        conn.close()
