"""团队存储 - SQLite 持久化（teams / team_members 表）。

团队由顶层 agent（TOP）在初始化时全量预创建（P4 团队初始化，spec「TOP 创建全量建队」），
本模块作为成员数据的持久化权威（source of truth）：restart 后成员拓扑、
角色职责、模型、评分等不丢失。工作空间可见的 ``.self/team_roster.md`` 是
给 LLM 看的可读镜像，由 team_init / team_tool 同步维护。

表结构：
- ``teams``：一个 TOP agent 对应一行（top_agent_id 主键）。
- ``team_members``：每个成员一行（member_id 主键），归属某 TOP agent；
  记录 name/role/duty/model_id/level/work_status/comment/scores/system_prompt。
  评分维度（quality/efficiency/collaboration/accuracy，0-10）序列化为 scores_json。
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

# 评分维度（与 team_tool 保持一致）
SCORE_FIELDS = ("quality", "efficiency", "collaboration", "accuracy")

# 写操作锁
_write_lock = threading.Lock()
# 初始化标记
_initialized = False


def _ensure_db() -> None:
    """确保数据库目录与表结构已创建（线程安全的惰性初始化）。"""
    global _initialized
    if _initialized:
        return
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    with _write_lock, sqlite3.connect(_DB_PATH) as conn:
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS teams (
                top_agent_id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                name TEXT NOT NULL,
                member_count INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS team_members (
                id TEXT PRIMARY KEY,
                top_agent_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                name TEXT NOT NULL,
                role TEXT NOT NULL DEFAULT '',
                duty TEXT NOT NULL DEFAULT '',
                model_id TEXT NOT NULL DEFAULT '',
                level INTEGER NOT NULL DEFAULT 1,
                work_status TEXT NOT NULL DEFAULT 'idle',
                comment TEXT NOT NULL DEFAULT '',
                scores_json TEXT NOT NULL DEFAULT '{}',
                system_prompt TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )
            """
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_team_members_top "
            "ON team_members (top_agent_id, created_at)"
        )
        conn.commit()
    _initialized = True


def _connect():
    """创建 UTF-8 编码的 SQLite 连接（确保表已建）。"""
    _ensure_db()
    conn = sqlite3.connect(_DB_PATH)
    conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
    return conn


def _to_score(value: Any) -> float:
    """将任意值解析为 0-10 的评分，非法值归 0。"""
    try:
        return max(0.0, min(10.0, float(value)))
    except (TypeError, ValueError):
        return 0.0


def render_roster_md(members: List[Dict[str, Any]]) -> str:
    """生成成员管理表视图（``.self/team_roster.md`` 内容）。

    ``team_members`` 表为成员名单结构化存储，roster 文件是其可读视图
    （spec「DB 变更」：team_roster.md 为生成视图）。

    列顺序与既有 ``_parse_roster_table`` / team_tool 保持一致
    （前 7 列 ID|名称|模型|层级|创建时间|工作状态|评价 保持不变），
    角色/职责列追加在评价之后、评分之前，避免破坏已有解析索引。
    完整列：ID | 名称 | 模型 | 层级 | 创建时间 | 工作状态 | 评价 |
    角色 | 职责 | 质量 | 效率 | 协作性 | 准确性
    """
    header = (
        "| ID | 名称 | 模型 | 层级 | 创建时间 | 工作状态 | 评价 | "
        "角色 | 职责 | 质量 | 效率 | 协作性 | 准确性 |"
    )
    separator = (
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- | "
        "--- | --- | --- | --- |"
    )
    lines = [header, separator]
    for m in members:
        s = m.get("scores") or {}
        lines.append(
            f"| {m.get('id', '')} | {m.get('name', '')} | "
            f"{m.get('model_id', '')} | {m.get('level', 1)} | "
            f"{m.get('created_at', '')} | {m.get('work_status', '')} | "
            f"{m.get('comment', '')} | "
            f"{m.get('role', '')} | {m.get('duty', '')} | "
            f"{_to_score(s.get('quality', 0))} | "
            f"{_to_score(s.get('efficiency', 0))} | "
            f"{_to_score(s.get('collaboration', 0))} | "
            f"{_to_score(s.get('accuracy', 0))} |"
        )
    return "\n".join(lines) + "\n"


# ----------------------------------------------------------------------
# teams 表
# ----------------------------------------------------------------------
def init_team(user_id: str, top_agent_id: str, name: str) -> Dict[str, Any]:
    """初始化一个 TOP agent 的团队（幂等：已存在则更新名称）。

    :return: 团队信息字典
    """
    _ensure_db()
    now = int(time.time() * 1000)
    with _write_lock, sqlite3.connect(_DB_PATH) as conn:
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        conn.execute(
            "INSERT INTO teams (top_agent_id, user_id, name, member_count, "
            "created_at, updated_at) VALUES (?, ?, ?, 0, ?, ?) "
            "ON CONFLICT(top_agent_id) DO UPDATE SET "
            "name = excluded.name, user_id = excluded.user_id, "
            "updated_at = excluded.updated_at",
            (top_agent_id, user_id, name, now, now),
        )
        conn.commit()
    team = get_team(top_agent_id)
    assert team is not None
    return team


def get_team(top_agent_id: str) -> Optional[Dict[str, Any]]:
    """按 TOP agent ID 获取团队信息。"""
    _ensure_db()
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            "SELECT * FROM teams WHERE top_agent_id = ?", (top_agent_id,)
        ).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


def delete_team(top_agent_id: str) -> bool:
    """删除团队及全部成员（TOP agent 被删除时调用）。"""
    _ensure_db()
    with _write_lock, sqlite3.connect(_DB_PATH) as conn:
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        conn.execute("DELETE FROM team_members WHERE top_agent_id = ?", (top_agent_id,))
        cursor = conn.execute(
            "DELETE FROM teams WHERE top_agent_id = ?", (top_agent_id,)
        )
        conn.commit()
        return cursor.rowcount > 0


# ----------------------------------------------------------------------
# team_members 表
# ----------------------------------------------------------------------
def add_member(
    user_id: str,
    top_agent_id: str,
    member_id: str,
    name: str,
    role: str = "",
    duty: str = "",
    model_id: str = "",
    level: int = 1,
    system_prompt: str = "",
) -> Dict[str, Any]:
    """新增一名团队成员并更新团队 member_count。"""
    _ensure_db()
    now = int(time.time() * 1000)
    with _write_lock, sqlite3.connect(_DB_PATH) as conn:
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        conn.execute(
            "INSERT OR REPLACE INTO team_members "
            "(id, top_agent_id, user_id, name, role, duty, model_id, level, "
            "work_status, comment, scores_json, system_prompt, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'idle', '', '{}', ?, ?, ?)",
            (
                member_id, top_agent_id, user_id, name, role, duty,
                model_id, level, system_prompt, now, now,
            ),
        )
        conn.execute(
            "UPDATE teams SET member_count = "
            "(SELECT COUNT(*) FROM team_members WHERE top_agent_id = ?), "
            "updated_at = ? WHERE top_agent_id = ?",
            (top_agent_id, now, top_agent_id),
        )
        conn.commit()
    member = get_member(top_agent_id, member_id)
    assert member is not None
    return member


def get_members(top_agent_id: str) -> List[Dict[str, Any]]:
    """列出某 TOP agent 旗下全部成员，按创建时间升序。"""
    _ensure_db()
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT * FROM team_members WHERE top_agent_id = ? "
            "ORDER BY created_at ASC, id ASC",
            (top_agent_id,),
        ).fetchall()
        result = []
        for row in rows:
            d = dict(row)
            try:
                d["scores"] = json.loads(d.pop("scores_json") or "{}")
            except (ValueError, TypeError):
                d["scores"] = {}
            result.append(d)
        return result
    finally:
        conn.close()


def get_member(top_agent_id: str, member_id: str) -> Optional[Dict[str, Any]]:
    """按 ID 获取某个成员。"""
    _ensure_db()
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            "SELECT * FROM team_members WHERE top_agent_id = ? AND id = ?",
            (top_agent_id, member_id),
        ).fetchone()
        if row is None:
            return None
        d = dict(row)
        try:
            d["scores"] = json.loads(d.pop("scores_json") or "{}")
        except (ValueError, TypeError):
            d["scores"] = {}
        return d
    finally:
        conn.close()


def update_member(
    top_agent_id: str, member_id: str, **fields: Any
) -> Optional[Dict[str, Any]]:
    """更新成员字段（name/role/duty/model_id/level/work_status/comment/
    system_prompt/scores），返回更新后的成员；成员不存在返回 None。"""
    allowed = {
        "name", "role", "duty", "model_id", "level", "work_status",
        "comment", "system_prompt", "scores",
    }
    updates: Dict[str, Any] = {k: v for k, v in fields.items() if k in allowed}
    if not updates:
        return get_member(top_agent_id, member_id)

    if "scores" in updates:
        scores = updates.pop("scores")
        if not isinstance(scores, dict):
            scores = {}
        scores_json = json.dumps(
            {k: v for k, v in scores.items() if k in SCORE_FIELDS},
            ensure_ascii=False,
        )
        updates["scores_json"] = scores_json

    now = int(time.time() * 1000)
    set_clause = ", ".join(f"{k} = ?" for k in updates)
    values = list(updates.values()) + [now, top_agent_id, member_id]
    _ensure_db()
    with _write_lock, sqlite3.connect(_DB_PATH) as conn:
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        cursor = conn.execute(
            f"UPDATE team_members SET {set_clause}, updated_at = ? "
            "WHERE top_agent_id = ? AND id = ?",
            values,
        )
        conn.execute(
            "UPDATE teams SET updated_at = ? WHERE top_agent_id = ?",
            (now, top_agent_id),
        )
        conn.commit()
    return get_member(top_agent_id, member_id) if cursor.rowcount else None
