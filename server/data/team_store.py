"""团队存储 - SQLite 持久化（teams / team_members 表）。

团队由顶层 agent（TOP）在初始化时全量预创建（P4 团队初始化，spec「TOP 创建全量建队」），
本模块作为成员数据的持久化权威（source of truth）：restart 后成员拓扑、
角色职责、模型、评分等不丢失。工作空间可见的 ``.self/team_roster.md`` 是
给 LLM 看的可读镜像，由 team_init / team_tool 同步维护。

表结构：
- ``teams``：一个 TOP agent 对应一行（team_id 主键）。
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

from data.db import connect  # noqa: E402

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
    """确保数据库目录与表结构已创建（线程安全的惰性初始化）。

    含旧库迁移：``teams.max_level / max_members_per_level`` 与
    ``team_members.parent_agent_id`` 为后加列，对已存在的表做幂等 ALTER。
    """
    global _initialized
    if _initialized:
        return
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    with _write_lock, connect() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS teams (
                team_id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                name TEXT NOT NULL,
                member_count INTEGER NOT NULL DEFAULT 0,
                max_level INTEGER NOT NULL DEFAULT 3,
                max_members_per_level INTEGER NOT NULL DEFAULT 7,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS team_members (
                id TEXT PRIMARY KEY,
                team_id TEXT NOT NULL,
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
                parent_agent_id TEXT NOT NULL DEFAULT '',
                can_lead_team INTEGER NOT NULL DEFAULT 1,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )
            """
        )
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_team_members_top "
            "ON team_members (team_id, created_at)"
        )
        # 旧库迁移（幂等）：检查列是否存在，缺失则 ALTER 补充
        _migrate_column(conn, "teams", "max_level",
                        "ALTER TABLE teams ADD COLUMN max_level "
                        "INTEGER NOT NULL DEFAULT 3")
        _migrate_column(conn, "teams", "max_members_per_level",
                        "ALTER TABLE teams ADD COLUMN max_members_per_level "
                        "INTEGER NOT NULL DEFAULT 7")
        _migrate_column(conn, "team_members", "parent_agent_id",
                        "ALTER TABLE team_members ADD COLUMN parent_agent_id "
                        "TEXT NOT NULL DEFAULT ''")
        _migrate_column(conn, "team_members", "can_lead_team",
                        "ALTER TABLE team_members ADD COLUMN can_lead_team "
                        "INTEGER NOT NULL DEFAULT 1")
        conn.commit()
    _initialized = True


def _migrate_column(conn: sqlite3.Connection, table: str, column: str,
                    ddl: str) -> None:
    """列不存在时执行 ALTER TABLE（幂等迁移）。"""
    try:
        cols = {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}
    except sqlite3.Error:
        return
    if column not in cols:
        conn.execute(ddl)


def _connect():
    """创建 UTF-8 编码的 SQLite 连接（确保表已建）。"""
    _ensure_db()
    conn = connect()
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
    角色/职责列追加在评价之后、评分之前，避免破坏已有解析索引；
    「可带队」列追加在最末（旧 roster 缺该列时解析按缺省处理）。
    完整列：ID | 名称 | 模型 | 层级 | 创建时间 | 工作状态 | 评价 |
    角色 | 职责 | 质量 | 效率 | 协作性 | 准确性 | 可带队

    【状态治理】工作状态列输出占位 ``-``（不写任何状态值）：成员是否在
    工作的唯一权威是 ``chat._active_tasks``（实际 tool loop 登记），由
    ``team query_status`` / teammates API 实时计算；roster 不再承载状态，
    避免名册中的状态与实际情况脱节。
    """
    header = (
        "| ID | 名称 | 模型 | 层级 | 创建时间 | 工作状态 | 评价 | "
        "角色 | 职责 | 质量 | 效率 | 协作性 | 准确性 | 可带队 |"
    )
    separator = (
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- | "
        "--- | --- | --- | --- | --- |"
    )
    lines = [header, separator]
    for m in members:
        s = m.get("scores") or {}
        can_lead = "是" if m.get("can_lead_team", 1) else "否"
        lines.append(
            f"| {m.get('id', '')} | {m.get('name', '')} | "
            f"{m.get('model_id', '')} | {m.get('level', 1)} | "
            f"{m.get('created_at', '')} | - | "
            f"{m.get('comment', '')} | "
            f"{m.get('role', '')} | {m.get('duty', '')} | "
            f"{_to_score(s.get('quality', 0))} | "
            f"{_to_score(s.get('efficiency', 0))} | "
            f"{_to_score(s.get('collaboration', 0))} | "
            f"{_to_score(s.get('accuracy', 0))} | {can_lead} |"
        )
    return "\n".join(lines) + "\n"


# ----------------------------------------------------------------------
# teams 表
# ----------------------------------------------------------------------
def init_team(
    user_id: str,
    team_id: str,
    name: str,
    max_level: int = 3,
    max_members_per_level: int = 7,
) -> Dict[str, Any]:
    """初始化一个 TOP agent 的团队（幂等：已存在则更新名称与团队配置）。

    团队配置（max_level / max_members_per_level）在创建 TOP 时设定并持久化，
    之后不可修改（成员只增不减）。已存在团队时同步更新配置列（兼容旧数据）。

    :return: 团队信息字典
    """
    _ensure_db()
    now = int(time.time() * 1000)
    with _write_lock, connect() as conn:
        conn.execute(
            "INSERT INTO teams (team_id, user_id, name, member_count, "
            "max_level, max_members_per_level, created_at, updated_at) "
            "VALUES (?, ?, ?, 0, ?, ?, ?, ?) "
            "ON CONFLICT(team_id) DO UPDATE SET "
            "name = excluded.name, user_id = excluded.user_id, "
            "max_level = excluded.max_level, "
            "max_members_per_level = excluded.max_members_per_level, "
            "updated_at = excluded.updated_at",
            (team_id, user_id, name, max_level, max_members_per_level,
             now, now),
        )
        conn.commit()
    team = get_team(team_id)
    assert team is not None
    return team


def get_team(team_id: str) -> Optional[Dict[str, Any]]:
    """按 TOP agent ID 获取团队信息。"""
    _ensure_db()
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            "SELECT * FROM teams WHERE team_id = ?", (team_id,)
        ).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


def delete_team(team_id: str) -> bool:
    """删除团队及全部成员（TOP agent 被删除时调用）。"""
    _ensure_db()
    with _write_lock, connect() as conn:
        conn.execute("DELETE FROM team_members WHERE team_id = ?", (team_id,))
        cursor = conn.execute(
            "DELETE FROM teams WHERE team_id = ?", (team_id,)
        )
        conn.commit()
        return cursor.rowcount > 0


# ----------------------------------------------------------------------
# team_members 表
# ----------------------------------------------------------------------
def add_member(
    user_id: str,
    team_id: str,
    member_id: str,
    name: str,
    role: str = "",
    duty: str = "",
    model_id: str = "",
    level: int = 1,
    system_prompt: str = "",
    parent_agent_id: str = "",
    can_lead_team: bool = True,
) -> Dict[str, Any]:
    """新增一名团队成员并更新团队 member_count。

    :param parent_agent_id: 直属 leader（创建者的 agent_id）；P4 全量建队时
                            为 team_id，leader 经 create_member 创建时为
                            创建者的 agent_id（用于「每层成员上限」与
                            teammates/team_member 分组）。
    :param can_lead_team: 是否允许该成员再建下级团队，默认允许。
    """
    _ensure_db()
    now = int(time.time() * 1000)
    with _write_lock, connect() as conn:
        conn.execute(
            "INSERT OR REPLACE INTO team_members "
            "(id, team_id, user_id, name, role, duty, model_id, level, "
            "work_status, comment, scores_json, system_prompt, parent_agent_id, "
            "can_lead_team, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'idle', '', '{}', ?, ?, ?, ?, ?)",
            (
                member_id, team_id, user_id, name, role, duty,
                model_id, level, system_prompt, parent_agent_id,
                1 if can_lead_team else 0, now, now,
            ),
        )
        conn.execute(
            "UPDATE teams SET member_count = "
            "(SELECT COUNT(*) FROM team_members WHERE team_id = ?), "
            "updated_at = ? WHERE team_id = ?",
            (team_id, now, team_id),
        )
        conn.commit()
    member = get_member(team_id, member_id)
    assert member is not None
    return member


def get_members(team_id: str) -> List[Dict[str, Any]]:
    """列出某 TOP agent 旗下全部成员，按创建时间升序。"""
    _ensure_db()
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT * FROM team_members WHERE team_id = ? "
            "ORDER BY created_at ASC, id ASC",
            (team_id,),
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


def get_member(team_id: str, member_id: str) -> Optional[Dict[str, Any]]:
    """按 ID 获取某个成员。"""
    _ensure_db()
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            "SELECT * FROM team_members WHERE team_id = ? AND id = ?",
            (team_id, member_id),
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
    team_id: str, member_id: str, **fields: Any
) -> Optional[Dict[str, Any]]:
    """更新成员字段（name/role/duty/model_id/level/work_status/comment/
    system_prompt/scores/can_lead_team/parent_agent_id），返回更新后的成员；
    成员不存在返回 None。"""
    allowed = {
        "name", "role", "duty", "model_id", "level", "work_status",
        "comment", "system_prompt", "scores", "can_lead_team",
        "parent_agent_id",
    }
    updates: Dict[str, Any] = {k: v for k, v in fields.items() if k in allowed}
    if not updates:
        return get_member(team_id, member_id)

    if "can_lead_team" in updates:
        updates["can_lead_team"] = 1 if updates["can_lead_team"] else 0

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
    values = list(updates.values()) + [now, team_id, member_id]
    _ensure_db()
    with _write_lock, connect() as conn:
        cursor = conn.execute(
            f"UPDATE team_members SET {set_clause}, updated_at = ? "
            "WHERE team_id = ? AND id = ?",
            values,
        )
        conn.execute(
            "UPDATE teams SET updated_at = ? WHERE team_id = ?",
            (now, team_id),
        )
        conn.commit()
    return get_member(team_id, member_id) if cursor.rowcount else None


def _row_to_member(row: sqlite3.Row) -> Dict[str, Any]:
    d = dict(row)
    try:
        d["scores"] = json.loads(d.pop("scores_json") or "{}")
    except (ValueError, TypeError):
        d["scores"] = {}
    return d


def get_member_by_name(
    team_id: str, name: str
) -> Optional[Dict[str, Any]]:
    """按名称在团队内精确查找成员（无重名约束时返回创建最早的一条）。"""
    _ensure_db()
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            "SELECT * FROM team_members WHERE team_id = ? AND name = ? "
            "ORDER BY created_at ASC, id ASC LIMIT 1",
            (team_id, name),
        ).fetchone()
        return _row_to_member(row) if row else None
    finally:
        conn.close()


def count_members_by_name(team_id: str, name: str) -> int:
    """统计团队内同名成员数量（重名校验用）。"""
    _ensure_db()
    conn = _connect()
    try:
        row = conn.execute(
            "SELECT COUNT(*) FROM team_members WHERE team_id = ? AND name = ?",
            (team_id, name),
        ).fetchone()
        return int(row[0]) if row else 0
    finally:
        conn.close()


def count_direct_members(team_id: str, parent_agent_id: str) -> int:
    """实时统计某 leader 的直属成员数（每层人数上限校验用）。"""
    _ensure_db()
    conn = _connect()
    try:
        row = conn.execute(
            "SELECT COUNT(*) FROM team_members "
            "WHERE team_id = ? AND parent_agent_id = ?",
            (team_id, parent_agent_id),
        ).fetchone()
        return int(row[0]) if row else 0
    finally:
        conn.close()
