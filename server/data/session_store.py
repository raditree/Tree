"""会话存储 - 基于 SQLite 的 SessionManager。

多会话并行（P2）：一个 agent 拥有多个并行会话，每个会话拥有独立上下文、
对话历史与运行状态（stop / compact / Spec 选择）。会话元数据存
``sessions`` 表；对话消息与 LLM 上下文仍由 conversation_store 负责
（按其 ``session_id`` 列隔离）。

约定：
- 默认会话 id 为 ``session_default``（旧数据迁移目标 / 前端未选择时的兜底）
- 删除会话为软删除（deleted_at 置位），底层消息与上下文保留用于审计
"""

import json
import sqlite3
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional

from data.db import connect  # noqa: E402

# 默认会话 id：旧数据迁移目标，前端未选择会话时的兜底
DEFAULT_SESSION = "session_default"

# 数据库目录：server/data（与 conversation_store 同库同目录）
_DATA_DIR = Path(__file__).resolve().parent.parent / "data"
_DB_PATH = _DATA_DIR / "conversations.db"

# 写操作锁（SQLite 单文件写并发有限，串行化保证安全）
_write_lock = threading.Lock()
# 初始化标记
_initialized = False


def _ensure_db() -> None:
    """确保 sessions 表已创建（线程安全的惰性初始化）。"""
    global _initialized
    if _initialized:
        return
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    with connect() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS sessions (
                session_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                agent_id TEXT NOT NULL,
                title TEXT NOT NULL DEFAULT '新会话',
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                status TEXT NOT NULL DEFAULT 'active',
                deleted_at INTEGER,
                selected_spec_ids TEXT,
                PRIMARY KEY (session_id)
            )
            """
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_sessions_user_agent "
            "ON sessions (user_id, agent_id, updated_at)"
        )
        conn.commit()
    _initialized = True


def _connect():
    """创建 UTF-8 编码的 SQLite 连接（全局复用）。"""
    _ensure_db()
    conn = connect()
    return conn


def _gen_session_id() -> str:
    """生成全局唯一的会话 id。"""
    return f"session_{int(time.time() * 1000)}_{uuid.uuid4().hex[:8]}"


def create_session(
    user_id: str, agent_id: str, title: str = "", session_id: str = ""
) -> Dict[str, Any]:
    """创建新会话并持久化，返回会话记录。

    :param title: 会话标题，为空时取默认标题 ``"新会话"``
    :param session_id: 可选。显式指定会话 id（如默认会话 ``session_default``）
    """
    _ensure_db()
    sid = session_id or _gen_session_id()
    final_title = (title or "").strip() or "新会话"
    ts = int(time.time() * 1000)
    with _write_lock, connect() as conn:
        conn.execute(
            "INSERT OR IGNORE INTO sessions "
            "(session_id, user_id, agent_id, title, created_at, updated_at, status) "
            "VALUES (?, ?, ?, ?, ?, ?, 'active')",
            (sid, user_id, agent_id, final_title, ts, ts),
        )
        conn.commit()
    return get_session_record(user_id, sid) or {
        "session_id": sid,
        "user_id": user_id,
        "agent_id": agent_id,
        "title": final_title,
        "created_at": ts,
        "updated_at": ts,
        "status": "active",
        "selected_spec_ids": [],
    }


def get_session_record(user_id: str, session_id: str) -> Optional[Dict[str, Any]]:
    """按 session_id 查询会话记录；不存在或已软删除时返回 None。"""
    _ensure_db()
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            "SELECT * FROM sessions "
            "WHERE session_id = ? AND user_id = ? AND deleted_at IS NULL",
            (session_id, user_id),
        ).fetchone()
        if row is None:
            return None
        return _row_to_dict(row)
    finally:
        conn.close()


def list_sessions(user_id: str, agent_id: str) -> List[Dict[str, Any]]:
    """列出指定 agent 的全部有效会话（含默认会话兜底条目），按更新时间倒序。"""
    _ensure_db()
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT * FROM sessions "
            "WHERE user_id = ? AND agent_id = ? AND deleted_at IS NULL "
            "ORDER BY updated_at DESC, created_at DESC",
            (user_id, agent_id),
        ).fetchall()
        result: List[Dict[str, Any]] = [_row_to_dict(r) for r in rows]
        # 默认会话兜底：无论 DB 是否有行，始终向调用方呈现"默认会话"，
        # 保证前端未选择会话时总能落到 session_default。
        if not any(r["session_id"] == DEFAULT_SESSION for r in result):
            result.append(
                {
                    "session_id": DEFAULT_SESSION,
                    "user_id": user_id,
                    "agent_id": agent_id,
                    "title": "默认会话",
                    "created_at": 0,
                    "updated_at": 0,
                    "status": "active",
                    "selected_spec_ids": [],
                }
            )
        return result
    finally:
        conn.close()


def rename_session(user_id: str, session_id: str, title: str) -> bool:
    """重命名会话，返回是否成功。"""
    _ensure_db()
    final_title = (title or "").strip()
    if not final_title:
        return False
    ts = int(time.time() * 1000)
    with _write_lock, connect() as conn:
        cursor = conn.execute(
            "UPDATE sessions SET title = ?, updated_at = ? "
            "WHERE session_id = ? AND user_id = ? AND deleted_at IS NULL",
            (final_title, ts, session_id, user_id),
        )
        conn.commit()
        return cursor.rowcount > 0


def touch_session(user_id: str, session_id: str) -> None:
    """更新会话的最后活跃时间（消息收发 / compact 时调用）。"""
    _ensure_db()
    ts = int(time.time() * 1000)
    with _write_lock, connect() as conn:
        conn.execute(
            "UPDATE sessions SET updated_at = ? "
            "WHERE session_id = ? AND user_id = ? AND deleted_at IS NULL",
            (ts, session_id, user_id),
        )
        conn.commit()


def update_session_title_from_first_message(
    user_id: str, agent_id: str, session_id: str, content: str
) -> None:
    """会话标题为默认值时，用首条用户消息内容自动生成标题。

    标题取首行/前 30 字符，避免过长的用户输入淹没会话列表。
    """
    _ensure_db()
    text = (content or "").strip().replace("\n", " ").strip()
    if not text:
        return
    brief = text[:30] + ("…" if len(text) > 30 else "")
    with _write_lock, connect() as conn:
        conn.execute(
            "UPDATE sessions SET title = ?, updated_at = ? "
            "WHERE session_id = ? AND user_id = ? AND deleted_at IS NULL "
            "AND (title = '新会话' OR title = '')",
            (brief, int(time.time() * 1000), session_id, user_id),
        )
        conn.commit()


def delete_session(user_id: str, session_id: str) -> bool:
    """软删除会话（deleted_at 置位，底层消息/上下文保留用于审计）。

    同时软删除该会话的对话消息与 LLM 上下文（经 conversation_store）。
    """
    _ensure_db()
    now = int(time.time() * 1000)
    with _write_lock, connect() as conn:
        cursor = conn.execute(
            "UPDATE sessions SET deleted_at = ? "
            "WHERE session_id = ? AND user_id = ? AND deleted_at IS NULL",
            (now, session_id, user_id),
        )
        conn.commit()
        deleted = cursor.rowcount > 0
    if deleted:
        from data.conversation_store import clear_context, clear_history

        clear_history(user_id, None, session_id=session_id)
        clear_context(user_id, None, session_id=session_id)
    return deleted


def set_selected_spec_ids(
    user_id: str, session_id: str, spec_ids: List[str]
) -> bool:
    """保存会话的 Spec 选择（selected_spec_ids，多选挂 hook）。"""
    _ensure_db()
    raw = json.dumps(list(spec_ids or []), ensure_ascii=False)
    ts = int(time.time() * 1000)
    with _write_lock, connect() as conn:
        cursor = conn.execute(
            "UPDATE sessions SET selected_spec_ids = ?, updated_at = ? "
            "WHERE session_id = ? AND user_id = ? AND deleted_at IS NULL",
            (raw, ts, session_id, user_id),
        )
        conn.commit()
        return cursor.rowcount > 0


def get_selected_spec_ids(user_id: str, session_id: str) -> List[str]:
    """读取会话已选 Spec id 列表。"""
    _ensure_db()
    conn = _connect()
    try:
        row = conn.execute(
            "SELECT selected_spec_ids FROM sessions "
            "WHERE session_id = ? AND user_id = ? AND deleted_at IS NULL",
            (session_id, user_id),
        ).fetchone()
        if not row or not row[0]:
            return []
        try:
            data = json.loads(row[0])
            return data if isinstance(data, list) else []
        except (ValueError, TypeError):
            return []
    finally:
        conn.close()


def _row_to_dict(row: sqlite3.Row) -> Dict[str, Any]:
    """将 sqlite3.Row 转为前端友好的会话记录。"""
    selected: List[str] = []
    raw = row["selected_spec_ids"]
    if raw:
        try:
            data = json.loads(raw)
            if isinstance(data, list):
                selected = [str(x) for x in data]
        except (ValueError, TypeError):
            selected = []
    return {
        "session_id": row["session_id"],
        "user_id": row["user_id"],
        "agent_id": row["agent_id"],
        "title": row["title"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
        "status": row["status"],
        "selected_spec_ids": selected,
    }
