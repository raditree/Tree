"""Agent 存储 - 基于 SQLite 的持久化实现。

将每个用户创建的 agent 保存到 SQLite 数据库（与对话历史同库），
重启后数据不丢失。数据库文件位于 ``server/data/conversations.db``。
"""
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

from data.db import connect  # noqa: E402

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
    with connect() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS agents (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                name TEXT NOT NULL,
                model_id TEXT NOT NULL,
                system_prompt TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL,
                mode TEXT,
                reasoning_effort TEXT,
                max_seqlen_override INTEGER,
                max_output_tokens INTEGER,
                compress_threshold REAL
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
        # 迁移：补充 mode 列（运行模式锁定值，NULL 表示未锁定；旧库补列）
        _migrate_add_mode(conn)
        # 迁移：补充模型参数覆盖列（思考强度/输入长度/输出长度/压缩阈值）
        _migrate_add_model_overrides(conn)
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


def _migrate_add_mode(conn: sqlite3.Connection) -> None:
    """为 agents 表增加 mode 列（若缺失）。

    运行模式锁定值：NULL/空串 = 未锁定（首条消息时经 resolve_mode 确定并写回，
    此后按持久化模式工作）；"cloud" / "local" / "ssh" = 已锁定。
    旧库（Task 1 自动重建前遗留）经本迁移惰性补列，无迁移框架。
    """
    cols = {row[1] for row in conn.execute("PRAGMA table_info(agents)")}
    if "mode" not in cols:
        conn.execute("ALTER TABLE agents ADD COLUMN mode TEXT")


# 模型参数覆盖列：列名 -> SQL 类型。
# 全部 NULL = 不覆盖（回退模型 YAML 配置 / AgentLLMSession 的类常量默认值）。
_MODEL_OVERRIDE_COLUMNS = {
    "reasoning_effort": "TEXT",
    "max_seqlen_override": "INTEGER",
    "max_output_tokens": "INTEGER",
    "compress_threshold": "REAL",
}


def _migrate_add_model_overrides(conn: sqlite3.Connection) -> None:
    """为 agents 表补充每 agent 的模型参数覆盖列（若缺失）。

    - ``reasoning_effort``：思考强度（透传 OpenAI 顶层参数，仅推理模型支持）
    - ``max_seqlen_override``：最大输入（上下文预算）覆盖
    - ``max_output_tokens``：最大输出 token（下发 ``max_tokens``）
    - ``compress_threshold``：上下文压缩触发阈值（占 max_seqlen 的比例）

    幂等：按 ``PRAGMA table_info`` 判定缺列后逐个 ``ALTER TABLE``（对齐
    ``_migrate_add_mode`` 的既有写法）。
    """
    cols = {row[1] for row in conn.execute("PRAGMA table_info(agents)")}
    for column, sql_type in _MODEL_OVERRIDE_COLUMNS.items():
        if column not in cols:
            conn.execute(f"ALTER TABLE agents ADD COLUMN {column} {sql_type}")


def _connect():
    """创建 UTF-8 编码的 SQLite 连接（全局复用）。"""
    _ensure_db()
    conn = connect()
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
            "SELECT id, name, model_id, system_prompt, created_at, workspace_id, "
            "reasoning_effort, max_seqlen_override, max_output_tokens, "
            "compress_threshold "
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
    reasoning_effort: Optional[str] = None,
    max_seqlen_override: Optional[int] = None,
    max_output_tokens: Optional[int] = None,
    compress_threshold: Optional[float] = None,
    clear_model_overrides: bool = False,
) -> Optional[Dict[str, Any]]:
    """更新 agent 字段，仅更新非 None 字段。

    用于 ``PATCH /api/agents/{id}``（右侧面板"模型信息"页修改模型、提示词与
    模型参数覆盖）。

    模型参数覆盖语义：``None`` = **不修改**（保留库中原值）；``clear_model_overrides``
    为 True 时把四个覆盖列一次性置 NULL（前端「清除自定义参数」）。
    由此避免"传 None 到底是清空还是不改"的歧义。

    :param user_id: 用户标识
    :param agent_id: agent 标识
    :param model_id: 新模型 ID（可选）
    :param system_prompt: 新系统提示词（可选）
    :param reasoning_effort: 思考强度覆盖（可选）
    :param max_seqlen_override: 最大输入（上下文预算）覆盖（可选）
    :param max_output_tokens: 最大输出 token 覆盖（可选）
    :param compress_threshold: 上下文压缩阈值覆盖（可选，0.1~0.95）
    :param clear_model_overrides: 是否一次性清除全部模型参数覆盖
    :return: 更新后的 agent 字典；agent 不存在返回 None
    """
    _ensure_db()
    updates: Dict[str, Any] = {}
    if model_id is not None:
        updates["model_id"] = model_id
    if system_prompt is not None:
        updates["system_prompt"] = system_prompt
    if reasoning_effort is not None:
        updates["reasoning_effort"] = reasoning_effort
    if max_seqlen_override is not None:
        updates["max_seqlen_override"] = max_seqlen_override
    if max_output_tokens is not None:
        updates["max_output_tokens"] = max_output_tokens
    if compress_threshold is not None:
        updates["compress_threshold"] = compress_threshold
    if clear_model_overrides:
        for column in _MODEL_OVERRIDE_COLUMNS:
            updates[column] = None
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
    with _write_lock, connect() as conn:
        cursor = conn.execute(
            "UPDATE agents SET deleted_at = ? "
            "WHERE user_id = ? AND id = ? AND deleted_at IS NULL",
            (now, user_id, agent_id),
        )
        conn.commit()
        return cursor.rowcount > 0


def get_agent_mode(user_id: str, agent_id: str) -> Optional[str]:
    """读取 agent 持久化运行模式（agents.mode 列）。

    :return: 已锁定模式（"cloud" / "local" / "ssh"）；未锁定（NULL/空串）、
             agent 不存在或已软删除返回 None
    """
    _ensure_db()
    conn = _connect()
    try:
        row = conn.execute(
            "SELECT mode FROM agents "
            "WHERE user_id = ? AND id = ? AND deleted_at IS NULL",
            (user_id, agent_id),
        ).fetchone()
        if row is None:
            return None
        mode = row[0]
        return mode or None
    finally:
        conn.close()


def lock_agent_mode(user_id: str, agent_id: str, mode: str) -> bool:
    """首消息运行模式锁定：仅当 mode 尚未写入时设置（先到先得，幂等）。

    :param mode: 待持久化的运行模式（"cloud" / "local" / "ssh"）
    :return: 本次是否真正写入；False = 已锁定（不覆盖）或 agent 不存在/已删除
    """
    _ensure_db()
    with _write_lock:
        conn = _connect()
        try:
            cursor = conn.execute(
                "UPDATE agents SET mode = ? "
                "WHERE user_id = ? AND id = ? AND deleted_at IS NULL "
                "AND (mode IS NULL OR mode = '')",
                (mode, user_id, agent_id),
            )
            conn.commit()
            return cursor.rowcount > 0
        finally:
            conn.close()


def set_agent_mode(user_id: str, agent_id: str, mode: str) -> bool:
    """显式写入 agent 的运行模式（agents.mode，无条件覆盖）。

    供执行器注册/注销消息使用：注册 local/ssh 即表达用户对该 top agent 的
    执行模式意图，写回 ``mode`` 使模式在断连/超时等瞬时失联后仍保持锁定；
    显式注销（切回 cloud）时写回 ``"cloud"``。

    :param mode: 运行模式（"cloud" / "local" / "ssh"）
    :return: 是否成功写入；False = agent 不存在或已软删除
    """
    _ensure_db()
    with _write_lock:
        conn = _connect()
        try:
            cursor = conn.execute(
                "UPDATE agents SET mode = ? "
                "WHERE user_id = ? AND id = ? AND deleted_at IS NULL",
                (mode, user_id, agent_id),
            )
            conn.commit()
            return cursor.rowcount > 0
        finally:
            conn.close()
