"""对话历史存储 - 基于 SQLite 的持久化实现。

将每个用户/agent/会话的对话消息存储到 SQLite 数据库，重启后数据不丢失。
数据库文件位于 ``server/data/conversations.db``。

多会话并行（P2）：消息与 LLM 上下文均按 ``session_id`` 隔离（旧数据回填
默认会话 ``session_default``）；会话元数据（标题/状态/Spec 选择）见
``session_store.SessionManager``。
"""
import json
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

from data.session_store import DEFAULT_SESSION


# 数据库目录：server/data
_DATA_DIR = Path(__file__).resolve().parent.parent / "data"
_DB_PATH = _DATA_DIR / "conversations.db"

# 写操作锁（SQLite 单文件写并发有限，串行化保证安全）
_write_lock = threading.Lock()
# 初始化标记
_initialized = False


def _ensure_db() -> None:
    """确保数据库目录与表结构已创建（线程安全的惰性初始化）。

    含旧库迁移（重构 v2 首次启动执行一次）：
    - ``messages`` 增加 ``session_id`` 列并回填默认会话 ``session_default``
    - ``agent_context`` 主键扩为 ``(user_id, agent_id, session_id)``，旧行归入
      默认会话（重建表迁移，保留审计所需的完整历史）
    """
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
                usage TEXT,
                session_id TEXT NOT NULL DEFAULT 'session_default'
            )
            """
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_user_agent "
            "ON messages (user_id, agent_id, session_id, id)"
        )
        # LLM 会话上下文持久化表（多会话后主键含 session_id，重启后恢复）
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS agent_context (
                user_id TEXT NOT NULL,
                agent_id TEXT NOT NULL,
                session_id TEXT NOT NULL DEFAULT 'session_default',
                context TEXT NOT NULL,
                updated_at INTEGER NOT NULL,
                deleted_at INTEGER,
                PRIMARY KEY (user_id, agent_id, session_id)
            )
            """
        )
        # 兼容旧库：缺列时补充
        cols = {
            row[1]
            for row in conn.execute("PRAGMA table_info(messages)").fetchall()
        }
        if "usage" not in cols:
            conn.execute("ALTER TABLE messages ADD COLUMN usage TEXT")
        if "kind" not in cols:
            conn.execute("ALTER TABLE messages ADD COLUMN kind TEXT DEFAULT 'text'")
        if "tool_name" not in cols:
            conn.execute("ALTER TABLE messages ADD COLUMN tool_name TEXT")
        if "tool_arguments" not in cols:
            conn.execute("ALTER TABLE messages ADD COLUMN tool_arguments TEXT")
        if "tool_result" not in cols:
            conn.execute("ALTER TABLE messages ADD COLUMN tool_result TEXT")
        # 软删除标记列：NULL 表示未删除，非 NULL 表示已从前端清空的时间戳。
        # 底层消息行始终保留（含 LLM CoT），方便后期审计。
        if "deleted_at" not in cols:
            conn.execute("ALTER TABLE messages ADD COLUMN deleted_at INTEGER")
        # 多会话：messages 增加 session_id 列并回填默认会话（旧数据迁移）
        if "session_id" not in cols:
            conn.execute(
                "ALTER TABLE messages ADD COLUMN session_id TEXT "
                "DEFAULT 'session_default'"
            )
            conn.execute(
                "UPDATE messages SET session_id = 'session_default' "
                "WHERE session_id IS NULL"
            )
        # agent_context 主键扩为 (user_id, agent_id, session_id)：重建表迁移。
        # 旧结构无 session_id 列时，把既有行归入默认会话后替换表结构。
        ctx_cols = {
            row[1]
            for row in conn.execute("PRAGMA table_info(agent_context)").fetchall()
        }
        if "session_id" not in ctx_cols:
            conn.execute("ALTER TABLE agent_context RENAME TO agent_context_old")
            conn.execute(
                """
                CREATE TABLE agent_context (
                    user_id TEXT NOT NULL,
                    agent_id TEXT NOT NULL,
                    session_id TEXT NOT NULL DEFAULT 'session_default',
                    context TEXT NOT NULL,
                    updated_at INTEGER NOT NULL,
                    deleted_at INTEGER,
                    PRIMARY KEY (user_id, agent_id, session_id)
                )
                """
            )
            conn.execute(
                "INSERT INTO agent_context "
                "(user_id, agent_id, session_id, context, updated_at, deleted_at) "
                "SELECT user_id, agent_id, 'session_default', context, updated_at, "
                "deleted_at FROM agent_context_old"
            )
            conn.execute("DROP TABLE agent_context_old")
        # 重建表后重新读取列，避免重复添加 deleted_at（新表已含该列）
        ctx_cols = {
            row[1]
            for row in conn.execute("PRAGMA table_info(agent_context)").fetchall()
        }
        if "deleted_at" not in ctx_cols:
            conn.execute("ALTER TABLE agent_context ADD COLUMN deleted_at INTEGER")
        # agent_context 归档表：compact / clear 等覆盖性操作发生前，
        # 把当时的完整 LLM 上下文快照写入此表，用于后期审计（含 CoT）。
        # 与 agent_context 的软删除不同：compact 不软删当前行，而是用
        # summary 覆盖 self.context 后由 save_context UPSERT 写回，旧值
        # 会丢失——故专门在此表留一份只增不改的历史快照。
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS agent_context_archive (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id TEXT NOT NULL,
                agent_id TEXT NOT NULL,
                session_id TEXT NOT NULL DEFAULT 'session_default',
                context TEXT NOT NULL,
                archived_at INTEGER NOT NULL,
                reason TEXT NOT NULL DEFAULT 'compact'
            )
            """
        )
        # 兼容旧归档表：缺 session_id 列时补充并回填默认会话
        arch_cols = {
            row[1]
            for row in conn.execute(
                "PRAGMA table_info(agent_context_archive)"
            ).fetchall()
        }
        if "session_id" not in arch_cols:
            conn.execute(
                "ALTER TABLE agent_context_archive ADD COLUMN "
                "session_id TEXT NOT NULL DEFAULT 'session_default'"
            )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_ctx_archive_user_agent "
            "ON agent_context_archive (user_id, agent_id, session_id, id)"
        )
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
    kind: str = "text",
    tool_name: Optional[str] = None,
    tool_arguments: Optional[Dict[str, Any]] = None,
    tool_result: Optional[str] = None,
    session_id: str = DEFAULT_SESSION,
) -> Dict[str, Any]:
    """保存一条消息到 SQLite，返回消息对象（含 id/timestamp）。

    :param usage: 可选 token 用量统计（agent 消息），JSON 序列化存储
    :param kind: 消息种类，``"text"``（普通文本）或 ``"tool"``（工具调用卡片）
    :param tool_name: 工具名称（kind == "tool" 时有效）
    :param tool_arguments: 工具调用参数（kind == "tool" 时有效，JSON 序列化存储）
    :param tool_result: 工具执行结果文本（kind == "tool" 时有效）
    :param session_id: 所属会话 id（多会话隔离，缺省为默认会话）
    """
    _ensure_db()
    timestamp = int(time.time() * 1000)
    msg_id = f"msg_{timestamp}"
    usage_json = json.dumps(usage, ensure_ascii=False) if usage else None
    args_json = (
        json.dumps(tool_arguments, ensure_ascii=False) if tool_arguments else None
    )
    with _write_lock:
        conn = _connect()
        try:
            conn.execute(
                "INSERT INTO messages "
                "(user_id, agent_id, role, content, timestamp, msg_id, usage, "
                "kind, tool_name, tool_arguments, tool_result, session_id) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    user_id, agent_id, role, content, timestamp, msg_id,
                    usage_json, kind, tool_name, args_json, tool_result,
                    session_id,
                ),
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
        "kind": kind,
        "tool_name": tool_name,
        "tool_arguments": tool_arguments,
        "tool_result": tool_result,
    }


def get_history(
    user_id: str, agent_id: str, session_id: Optional[str] = DEFAULT_SESSION
) -> List[Dict[str, Any]]:
    """拉取指定用户/agent/会话的对话历史（不含已软删除），按 id 升序。

    ``session_id`` 为 None 时返回该用户/agent 全部会话的消息（按会话分组，
    供前端"全部会话"视图使用）。
    """
    _ensure_db()
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        if session_id is None:
            rows = conn.execute(
                "SELECT session_id, msg_id, role, content, timestamp, usage, "
                "kind, tool_name, tool_arguments, tool_result "
                "FROM messages "
                "WHERE user_id = ? AND agent_id = ? AND deleted_at IS NULL "
                "ORDER BY id ASC",
                (user_id, agent_id),
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT session_id, msg_id, role, content, timestamp, usage, "
                "kind, tool_name, tool_arguments, tool_result "
                "FROM messages "
                "WHERE user_id = ? AND agent_id = ? AND session_id = ? "
                "AND deleted_at IS NULL "
                "ORDER BY id ASC",
                (user_id, agent_id, session_id),
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
            tool_args = None
            raw_args = row["tool_arguments"] if "tool_arguments" in row.keys() else None
            if raw_args:
                try:
                    tool_args = json.loads(raw_args)
                except (ValueError, TypeError):
                    tool_args = None
            kind = row["kind"] if "kind" in row.keys() else "text"
            tool_name = row["tool_name"] if "tool_name" in row.keys() else None
            tool_result = row["tool_result"] if "tool_result" in row.keys() else None
            result.append(
                {
                    "id": row["msg_id"],
                    "role": row["role"],
                    "content": row["content"],
                    "timestamp": row["timestamp"],
                    "is_streaming": False,
                    "usage": usage,
                    "kind": kind or "text",
                    "tool_name": tool_name,
                    "tool_arguments": tool_args,
                    "tool_result": tool_result or "",
                    "session_id": row["session_id"],
                }
            )
        return result
    finally:
        conn.close()


def clear_history(
    user_id: str,
    agent_id: Optional[str] = None,
    session_id: Optional[str] = None,
) -> int:
    """软删除（标记 deleted_at）指定用户/agent/会话的对话历史。

    底层消息行一律保留（含 LLM CoT），方便后期审计；前端
    ``get_history`` 自动过滤已软删除的行。

    :param user_id: 用户标识
    :param agent_id: agent 标识，None 表示清空该用户所有 agent 的历史
    :param session_id: 会话 id；None 表示清空指定范围内全部会话
    :return: 被软删除的消息条数
    """
    _ensure_db()
    now = int(time.time() * 1000)
    with _write_lock, sqlite3.connect(_DB_PATH) as conn:
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        if agent_id is None and session_id is None:
            cursor = conn.execute(
                "UPDATE messages SET deleted_at = ? "
                "WHERE user_id = ? AND deleted_at IS NULL",
                (now, user_id),
            )
        elif agent_id is None and session_id is not None:
            cursor = conn.execute(
                "UPDATE messages SET deleted_at = ? "
                "WHERE user_id = ? AND session_id = ? AND deleted_at IS NULL",
                (now, user_id, session_id),
            )
        elif agent_id is not None and session_id is None:
            cursor = conn.execute(
                "UPDATE messages SET deleted_at = ? "
                "WHERE user_id = ? AND agent_id = ? AND deleted_at IS NULL",
                (now, user_id, agent_id),
            )
        else:
            cursor = conn.execute(
                "UPDATE messages SET deleted_at = ? "
                "WHERE user_id = ? AND agent_id = ? AND session_id = ? "
                "AND deleted_at IS NULL",
                (now, user_id, agent_id, session_id),
            )
        deleted = cursor.rowcount
        conn.commit()
    return deleted


def save_context(
    user_id: str,
    agent_id: str,
    context: List[Dict[str, Any]],
    session_id: str = DEFAULT_SESSION,
) -> None:
    """保存 LLM 会话上下文到 SQLite（upsert）。

    新对话开始时调用：UPSERT 同时把 ``deleted_at`` 重置为 NULL，
    使之前被 ``clear_context`` 软删除的行重新可见（live 状态）。

    :param context: LLM 上下文列表（OpenAI messages 格式），JSON 序列化存储
    :param session_id: 所属会话 id（多会话隔离，缺省为默认会话）
    """
    _ensure_db()
    context_json = json.dumps(context, ensure_ascii=False)
    ts = int(time.time() * 1000)
    with _write_lock, sqlite3.connect(_DB_PATH) as conn:
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        conn.execute(
            "INSERT INTO agent_context "
            "(user_id, agent_id, session_id, context, updated_at, deleted_at) "
            "VALUES (?, ?, ?, ?, ?, NULL) "
            "ON CONFLICT(user_id, agent_id, session_id) DO UPDATE SET "
            "context = excluded.context, updated_at = excluded.updated_at, "
            "deleted_at = NULL",
            (user_id, agent_id, session_id, context_json, ts),
        )
        conn.commit()


def load_context(
    user_id: str, agent_id: str, session_id: str = DEFAULT_SESSION
) -> Optional[List[Dict[str, Any]]]:
    """从 SQLite 加载 LLM 会话上下文；不存在/已软删除/解析失败时返回 None。"""
    _ensure_db()
    conn = _connect()
    try:
        row = conn.execute(
            "SELECT context FROM agent_context "
            "WHERE user_id = ? AND agent_id = ? AND session_id = ? "
            "AND deleted_at IS NULL",
            (user_id, agent_id, session_id),
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


def clear_context(
    user_id: str,
    agent_id: Optional[str] = None,
    session_id: Optional[str] = None,
) -> None:
    """软删除（标记 deleted_at）指定用户/agent/会话的会话上下文。

    底层 ``agent_context`` 行一律保留（含完整 LLM 上下文 / CoT），
    方便后期审计；``load_context`` 自动过滤已软删除的行。

    :param session_id: 会话 id；None 表示清空指定范围内全部会话
    """
    _ensure_db()
    now = int(time.time() * 1000)
    with _write_lock, sqlite3.connect(_DB_PATH) as conn:
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        if agent_id is None and session_id is None:
            conn.execute(
                "UPDATE agent_context SET deleted_at = ? "
                "WHERE user_id = ? AND deleted_at IS NULL",
                (now, user_id),
            )
        elif agent_id is None and session_id is not None:
            conn.execute(
                "UPDATE agent_context SET deleted_at = ? "
                "WHERE user_id = ? AND session_id = ? AND deleted_at IS NULL",
                (now, user_id, session_id),
            )
        elif agent_id is not None and session_id is None:
            conn.execute(
                "UPDATE agent_context SET deleted_at = ? "
                "WHERE user_id = ? AND agent_id = ? AND deleted_at IS NULL",
                (now, user_id, agent_id),
            )
        else:
            conn.execute(
                "UPDATE agent_context SET deleted_at = ? "
                "WHERE user_id = ? AND agent_id = ? AND session_id = ? "
                "AND deleted_at IS NULL",
                (now, user_id, agent_id, session_id),
            )
        conn.commit()


def archive_context(
    user_id: str,
    agent_id: str,
    context: List[Dict[str, Any]],
    reason: str = "compact",
    session_id: str = DEFAULT_SESSION,
) -> None:
    """归档一份完整的 LLM 上下文快照（只增不改），用于后期审计。

    在 compact 等覆盖性操作替换 ``session.context`` 前调用：把当时的
    完整上下文（含 system / user / assistant / tool 消息与 CoT）写入
    ``agent_context_archive`` 表。该表与 ``agent_context`` 不同——后者
    是 live 状态（被 UPSERT 覆盖、被软删除标记），前者是只增的历史快照。

    :param context: LLM 上下文列表（OpenAI messages 格式）
    :param reason: 归档原因，如 ``"compact"`` / ``"auto_compress"``
    :param session_id: 所属会话 id（多会话隔离，缺省为默认会话）
    """
    _ensure_db()
    context_json = json.dumps(context, ensure_ascii=False)
    ts = int(time.time() * 1000)
    with _write_lock, sqlite3.connect(_DB_PATH) as conn:
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        conn.execute(
            "INSERT INTO agent_context_archive "
            "(user_id, agent_id, session_id, context, archived_at, reason) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (user_id, agent_id, session_id, context_json, ts, reason),
        )
        conn.commit()


def list_archived_contexts(
    user_id: str, agent_id: str
) -> List[Dict[str, Any]]:
    """拉取指定 agent 的全部归档上下文快照，按时间升序（审计查询用）。"""
    _ensure_db()
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT id, context, archived_at, reason "
            "FROM agent_context_archive "
            "WHERE user_id = ? AND agent_id = ? ORDER BY id ASC",
            (user_id, agent_id),
        ).fetchall()
        result: List[Dict[str, Any]] = []
        for row in rows:
            try:
                data = json.loads(row["context"])
            except (ValueError, TypeError):
                data = None
            result.append(
                {
                    "id": row["id"],
                    "context": data,
                    "archived_at": row["archived_at"],
                    "reason": row["reason"],
                }
            )
        return result
    finally:
        conn.close()

