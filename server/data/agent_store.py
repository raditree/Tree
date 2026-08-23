"""Agent 存储 - 基于 SQLite 的持久化实现。

将每个用户创建的 agent 保存到 SQLite 数据库（与对话历史同库），
重启后数据不丢失。数据库文件位于 ``server/data/conversations.db``。
"""
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
            CREATE TABLE IF NOT EXISTS agents (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                name TEXT NOT NULL,
                model_id TEXT NOT NULL,
                system_prompt TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL
            )
            """
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_agents_user "
            "ON agents (user_id, created_at)"
        )
        # 迁移：为已存在的 agents 表补充 workspace_id 列并回填
        _migrate_add_workspace_id(conn)
        # 迁移：补充 deleted_at 列（软删除标记，NULL 表示未删除）
        _migrate_add_deleted_at(conn)
        conn.commit()
    _initialized = True


def _migrate_add_workspace_id(conn: sqlite3.Connection) -> None:
    """为 agents 表增加 workspace_id 列（若缺失），并回填已有数据。

    workspace_id 是每个 agent 独立的 Docker 工作空间标识，
    新列默认回填为 agent 自身的 id，保证旧数据也能映射到独立工作空间。
    """
    cols = {row[1] for row in conn.execute("PRAGMA table_info(agents)")}
    if "workspace_id" not in cols:
        conn.execute(
            "ALTER TABLE agents ADD COLUMN workspace_id TEXT NOT NULL DEFAULT ''"
        )
        conn.execute(
            "UPDATE agents SET workspace_id = id WHERE workspace_id = ''"
        )


def _migrate_add_deleted_at(conn: sqlite3.Connection) -> None:
    """为 agents 表增加 deleted_at 列（若缺失）。

    软删除标记：NULL 表示未删除，非 NULL 表示已从前端删除的时间戳。
    底层数据（messages / agent_context）始终保留，方便后期审计。
    """
    cols = {row[1] for row in conn.execute("PRAGMA table_info(agents)")}
    if "deleted_at" not in cols:
        conn.execute("ALTER TABLE agents ADD COLUMN deleted_at INTEGER")


def _connect():
    """创建 UTF-8 编码的 SQLite 连接（全局复用）。"""
    _ensure_db()
    conn = sqlite3.connect(_DB_PATH)
    conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
    return conn


def create_agent(
    user_id: str,
    name: str,
    model_id: str,
    system_prompt: str = "",
) -> Dict[str, Any]:
    """创建一个 agent 并持久化，返回 agent 字典。

    每个 agent 拥有独立的工作空间（workspace_id 取 agent 自身 id）。
    """
    _ensure_db()
    agent_id = f"agent_{int(time.time() * 1000)}"
    workspace_id = agent_id
    created_at = int(time.time() * 1000)
    with _write_lock:
        conn = _connect()
        try:
            conn.execute(
                "INSERT INTO agents "
                "(id, user_id, name, model_id, system_prompt, created_at, workspace_id) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (
                    agent_id,
                    user_id,
                    name,
                    model_id,
                    system_prompt,
                    created_at,
                    workspace_id,
                ),
            )
            conn.commit()
        finally:
            conn.close()
    result = get_agent(user_id, agent_id)
    assert result is not None
    return result


def get_agents(user_id: str) -> List[Dict[str, Any]]:
    """拉取指定用户的全部 agent（不含已软删除），按创建时间升序。"""
    _ensure_db()
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT id, name, model_id, system_prompt, created_at, workspace_id "
            "FROM agents WHERE user_id = ? AND deleted_at IS NULL "
            "ORDER BY created_at ASC",
            (user_id,),
        ).fetchall()
        return [dict(row) for row in rows]
    finally:
        conn.close()


def get_agent(user_id: str, agent_id: str) -> Optional[Dict[str, Any]]:
    """按 id 获取指定用户的单个 agent（已软删除返回 None）。"""
    _ensure_db()
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            "SELECT id, name, model_id, system_prompt, created_at, workspace_id "
            "FROM agents WHERE user_id = ? AND id = ? AND deleted_at IS NULL",
            (user_id, agent_id),
        ).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


def update_agent(
    user_id: str,
    agent_id: str,
    model_id: Optional[str] = None,
    system_prompt: Optional[str] = None,
) -> Optional[Dict[str, Any]]:
    """更新 agent 字段（model_id / system_prompt），仅更新非 None 字段。

    用于 ``PATCH /api/agents/{id}``（右侧面板"模型信息"页修改模型与提示词）。

    :param user_id: 用户标识
    :param agent_id: agent 标识
    :param model_id: 新模型 ID（可选）
    :param system_prompt: 新系统提示词（可选）
    :return: 更新后的 agent 字典；agent 不存在返回 None
    """
    _ensure_db()
    updates: Dict[str, Any] = {}
    if model_id is not None:
        updates["model_id"] = model_id
    if system_prompt is not None:
        updates["system_prompt"] = system_prompt
    if not updates:
        return get_agent(user_id, agent_id)

    set_clause = ", ".join(f"{k} = ?" for k in updates)
    values = list(updates.values()) + [user_id, agent_id]
    with _write_lock:
        conn = _connect()
        try:
            cursor = conn.execute(
                f"UPDATE agents SET {set_clause} "
                "WHERE user_id = ? AND id = ? AND deleted_at IS NULL",
                values,
            )
            conn.commit()
            updated = cursor.rowcount > 0
        finally:
            conn.close()
    return get_agent(user_id, agent_id) if updated else None


def delete_agent(user_id: str, agent_id: str) -> bool:
    """软删除指定 agent（标记 deleted_at），保留其对话历史与 LLM 上下文。

    前端列表/查询自动过滤已删除 agent，但底层 messages / agent_context
    行一律保留（含 LLM CoT），方便后期审计。彻底清理只能由
    ``user_store.purge_expired_users`` 在用户注销保留期满后触发。

    :return: 是否存在被软删除的 agent
    """
    _ensure_db()
    now = int(time.time() * 1000)
    with _write_lock, sqlite3.connect(_DB_PATH) as conn:
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        cursor = conn.execute(
            "UPDATE agents SET deleted_at = ? "
            "WHERE user_id = ? AND id = ? AND deleted_at IS NULL",
            (now, user_id, agent_id),
        )
        conn.commit()
        return cursor.rowcount > 0
