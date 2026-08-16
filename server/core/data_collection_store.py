"""数据收集存储 - 使用数据快照管理。

提供数据收集开关和快照存储功能：
- 用户可开关数据收集
- 仅开启期间记录使用数据快照
- 关闭后不再收集，已有快照保留
"""
import json
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

_DATA_DIR = Path(__file__).resolve().parent.parent / "data"
_DB_PATH = _DATA_DIR / "conversations.db"

_write_lock = threading.Lock()
_initialized = False


def _ensure_db() -> None:
    """确保数据收集相关表已创建。"""
    global _initialized
    if _initialized:
        return
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(_DB_PATH) as conn:
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS data_collection_prefs (
                openid TEXT PRIMARY KEY,
                enabled INTEGER NOT NULL DEFAULT 0,
                updated_at INTEGER NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS usage_snapshots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                openid TEXT NOT NULL,
                snapshot_type TEXT NOT NULL,
                snapshot_data TEXT NOT NULL,
                created_at INTEGER NOT NULL
            )
            """
        )
        conn.commit()
    _initialized = True


def _connect():
    _ensure_db()
    conn = sqlite3.connect(_DB_PATH)
    conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
    return conn


def set_data_collection(openid: str, enabled: bool) -> None:
    """设置用户数据收集开关。"""
    _ensure_db()
    now = int(time.time() * 1000)
    with _write_lock:
        conn = _connect()
        try:
            conn.execute(
                """INSERT INTO data_collection_prefs (openid, enabled, updated_at)
                   VALUES (?, ?, ?)
                   ON CONFLICT(openid) DO UPDATE SET enabled = ?, updated_at = ?""",
                (openid, 1 if enabled else 0, now, 1 if enabled else 0, now),
            )
            conn.commit()
        finally:
            conn.close()


def is_data_collection_enabled(openid: str) -> bool:
    """查询用户数据收集是否开启。"""
    _ensure_db()
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            "SELECT enabled FROM data_collection_prefs WHERE openid = ?",
            (openid,),
        ).fetchone()
        return bool(row["enabled"]) if row else False
    finally:
        conn.close()


def save_snapshot(
    openid: str,
    snapshot_type: str,
    snapshot_data: Dict[str, Any],
) -> None:
    """保存一条使用数据快照（仅在数据收集开启时有效）。

    :param openid: 用户标识
    :param snapshot_type: 快照类型，如 'api_usage', 'agent_activity', 'system_stats'
    :param snapshot_data: 快照数据字典
    """
    if not is_data_collection_enabled(openid):
        return
    _ensure_db()
    now = int(time.time() * 1000)
    data_json = json.dumps(snapshot_data, ensure_ascii=False)
    with _write_lock:
        conn = _connect()
        try:
            conn.execute(
                "INSERT INTO usage_snapshots (openid, snapshot_type, snapshot_data, created_at) "
                "VALUES (?, ?, ?, ?)",
                (openid, snapshot_type, data_json, now),
            )
            conn.commit()
        finally:
            conn.close()


def get_snapshots(
    openid: str,
    snapshot_type: Optional[str] = None,
    limit: int = 100,
    offset: int = 0,
) -> List[Dict[str, Any]]:
    """查询用户的使用数据快照列表。

    :param openid: 用户标识
    :param snapshot_type: 可选，按快照类型过滤
    :param limit: 返回条数上限
    :param offset: 偏移量
    :return: 快照字典列表
    """
    _ensure_db()
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        if snapshot_type:
            rows = conn.execute(
                "SELECT * FROM usage_snapshots WHERE openid = ? AND snapshot_type = ? "
                "ORDER BY created_at DESC LIMIT ? OFFSET ?",
                (openid, snapshot_type, limit, offset),
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM usage_snapshots WHERE openid = ? "
                "ORDER BY created_at DESC LIMIT ? OFFSET ?",
                (openid, limit, offset),
            ).fetchall()
        result = []
        for row in rows:
            result.append({
                "id": row["id"],
                "openid": row["openid"],
                "snapshot_type": row["snapshot_type"],
                "snapshot_data": json.loads(row["snapshot_data"]),
                "created_at": row["created_at"],
            })
        return result
    finally:
        conn.close()


def delete_user_snapshots(openid: str) -> int:
    """删除用户的所有快照（用于账号注销时清理）。"""
    _ensure_db()
    with _write_lock:
        conn = _connect()
        try:
            conn.execute("DELETE FROM usage_snapshots WHERE openid = ?", (openid,))
            conn.execute("DELETE FROM data_collection_prefs WHERE openid = ?", (openid,))
            conn.commit()
            deleted = conn.total_changes
        finally:
            conn.close()
    return deleted