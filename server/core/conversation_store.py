"""对话历史存储 - 基于 SQLite 的持久化实现。

将每个用户/agent 的对话消息存储到 SQLite 数据库，重启后数据不丢失。
数据库文件位于 ``server/data/conversations.db``。
"""
import json
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any, Dict, List, Optional


# 数据库目录：server/data
_DATA_DIR = Path(__file__).resolve().parent.parent / "data"
_DB_PATH = _DATA_DIR / "conversations.db"

# 写操作锁（SQLite 单文件写并发有限，串行化保证安全）
_write_lock = threading.Lock()
# 初始化标记
_initialized = False


def _ensure_db() -> None:
    """确保数据库目录与表结构已创建（线程安全的惰性初始化）。"""
    global _initialized
    if _initialized:
        return
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(_DB_PATH) as conn:
        # 显式声明 UTF-8 解码，防止 Windows 默认行为导致中文乱码
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id TEXT NOT NULL,
                agent_id TEXT NOT NULL,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                timestamp INTEGER NOT NULL,
                msg_id TEXT NOT NULL,
                usage TEXT
            )
            """
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_user_agent "
            "ON messages (user_id, agent_id, id)"
        )
        # LLM 会话上下文持久化表（normal 与 limitless 通用，重启后恢复）
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS agent_context (
                user_id TEXT NOT NULL,
                agent_id TEXT NOT NULL,
                context TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (user_id, agent_id)
            )
            """
        )
        # 兼容旧库：缺 usage 列时补充（ALTER TABLE ADD COLUMN）
        cols = {
            row[1]
            for row in conn.execute("PRAGMA table_info(messages)").fetchall()
        }
        if "usage" not in cols:
            conn.execute("ALTER TABLE messages ADD COLUMN usage TEXT")
        conn.commit()
    _initialized = True


def _connect():
    """创建 UTF-8 编码的 SQLite 连接（全局复用）。"""
    _ensure_db()
    conn = sqlite3.connect(_DB_PATH)
    conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
    return conn


def store_message(
    user_id: str,
    agent_id: str,
    role: str,
    content: str,
    usage: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """保存一条消息到 SQLite，返回消息对象（含 id/timestamp）。

    :param usage: 可选 token 用量统计（agent 消息），JSON 序列化存储
    """
    _ensure_db()
    timestamp = int(time.time() * 1000)
    msg_id = f"msg_{timestamp}"
    usage_json = json.dumps(usage, ensure_ascii=False) if usage else None
    with _write_lock:
        conn = _connect()
        try:
            conn.execute(
                "INSERT INTO messages "
                "(user_id, agent_id, role, content, timestamp, msg_id, usage) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (user_id, agent_id, role, content, timestamp, msg_id, usage_json),
            )
            conn.commit()
        finally:
            conn.close()
    return {
        "id": msg_id,
        "role": role,
        "content": content,
        "timestamp": timestamp,
        "is_streaming": False,
        "usage": usage,
    }


def get_history(user_id: str, agent_id: str) -> List[Dict[str, Any]]:
    """拉取指定用户/agent 的对话历史，按 id 升序。"""
    _ensure_db()
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT msg_id, role, content, timestamp, usage FROM messages "
            "WHERE user_id = ? AND agent_id = ? ORDER BY id ASC",
            (user_id, agent_id),
        ).fetchall()
        result: List[Dict[str, Any]] = []
        for row in rows:
            usage = None
            raw_usage = row["usage"]
            if raw_usage:
                try:
                    usage = json.loads(raw_usage)
                except (ValueError, TypeError):
                    usage = None
            result.append(
                {
                    "id": row["msg_id"],
                    "role": row["role"],
                    "content": row["content"],
                    "timestamp": row["timestamp"],
                    "is_streaming": False,
                    "usage": usage,
                }
            )
        return result
    finally:
        conn.close()


def clear_history(user_id: str, agent_id: Optional[str] = None) -> int:
    """清空指定用户/agent 的对话历史。

    :param user_id: 用户标识
    :param agent_id: agent 标识，None 表示清空该用户所有 agent 的历史
    :return: 被删除的消息条数
    """
    _ensure_db()
    with _write_lock, sqlite3.connect(_DB_PATH) as conn:
        if agent_id is None:
            cursor = conn.execute(
                "DELETE FROM messages WHERE user_id = ?", (user_id,)
            )
        else:
            cursor = conn.execute(
                "DELETE FROM messages WHERE user_id = ? AND agent_id = ?",
                (user_id, agent_id),
            )
        deleted = cursor.rowcount
        conn.commit()
    return deleted


def save_context(
    user_id: str, agent_id: str, context: List[Dict[str, Any]]
) -> None:
    """保存 LLM 会话上下文到 SQLite（upsert）。

    :param context: LLM 上下文列表（OpenAI messages 格式），JSON 序列化存储
    """
    _ensure_db()
    context_json = json.dumps(context, ensure_ascii=False)
    ts = int(time.time() * 1000)
    with _write_lock, sqlite3.connect(_DB_PATH) as conn:
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        conn.execute(
            "INSERT INTO agent_context (user_id, agent_id, context, updated_at) "
            "VALUES (?, ?, ?, ?) "
            "ON CONFLICT(user_id, agent_id) DO UPDATE SET "
            "context = excluded.context, updated_at = excluded.updated_at",
            (user_id, agent_id, context_json, ts),
        )
        conn.commit()


def load_context(
    user_id: str, agent_id: str
) -> Optional[List[Dict[str, Any]]]:
    """从 SQLite 加载 LLM 会话上下文；不存在或解析失败时返回 None。"""
    _ensure_db()
    conn = _connect()
    try:
        row = conn.execute(
            "SELECT context FROM agent_context "
            "WHERE user_id = ? AND agent_id = ?",
            (user_id, agent_id),
        ).fetchone()
        if not row or not row[0]:
            return None
        try:
            data = json.loads(row[0])
            return data if isinstance(data, list) else None
        except (ValueError, TypeError):
            return None
    finally:
        conn.close()


def clear_context(user_id: str, agent_id: Optional[str] = None) -> None:
    """清空指定用户/agent 的会话上下文；agent_id 为 None 时清空该用户全部。"""
    _ensure_db()
    with _write_lock, sqlite3.connect(_DB_PATH) as conn:
        if agent_id is None:
            conn.execute(
                "DELETE FROM agent_context WHERE user_id = ?", (user_id,)
            )
        else:
            conn.execute(
                "DELETE FROM agent_context WHERE user_id = ? AND agent_id = ?",
                (user_id, agent_id),
            )
        conn.commit()
