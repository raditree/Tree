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

# ---------------------------------------------------------------------------
# 成员审核状态（review_status）
# ---------------------------------------------------------------------------
# 成员**不再**在创建时自动继承 TOP 的模型：新建成员的 model_id 为空、审核状态为
# ``pending_model``，必须由用户在「团队成员 → 模型配置」页显式赋值并审核通过
# 之后才会接收消息。TOP agent（LLM）无权设置成员模型。
#
# 状态机（由本模块的 _derive_review_status 收敛，避免多处手工推导漂移）：
#   pending_model  --用户赋模型-->  pending_review  --用户审核通过-->  approved
#   approved      --用户撤销审核-->  rejected
#   approved/rejected 下清空模型  -->  pending_model
REVIEW_STATUS_PENDING_MODEL = "pending_model"
REVIEW_STATUS_PENDING_REVIEW = "pending_review"
REVIEW_STATUS_APPROVED = "approved"
REVIEW_STATUS_REJECTED = "rejected"

REVIEW_STATUSES = (
    REVIEW_STATUS_PENDING_MODEL,
    REVIEW_STATUS_PENDING_REVIEW,
    REVIEW_STATUS_APPROVED,
    REVIEW_STATUS_REJECTED,
)

# 需要用户处理的状态（前端红点徽章口径：未赋模型 / 待审核）。
# rejected 不计入：那是用户已处理的否定结论，不需要再提醒。
REVIEW_STATUS_NEEDS_USER = (
    REVIEW_STATUS_PENDING_MODEL,
    REVIEW_STATUS_PENDING_REVIEW,
)


def _derive_review_status(model_id: Any, current: Any) -> str:
    """由模型与当前状态推导合法审核状态（缺列/脏值时按旧数据兜底）。

    - 模型为空 → 必为 ``pending_model``（未赋模型的成员无法工作）
    - 模型非空且**尚未审核**（当前为空/``pending_model``/``pending_review``）
      → ``pending_review``（赋了模型但用户还没过审）
    - 模型非空且已审核结论（``approved``/``rejected``）→ 保留该结论，
      避免"每次改成员字段都把审核结论冲掉"

    旧库迁移而来的行（无 review_status、且有模型）会被视为 ``approved``：
    它们在建队时自动继承了 TOP 模型且此前一直可用，不应因本次治理被突然停用。
    """
    has_model = bool(str(model_id or "").strip())
    if not has_model:
        return REVIEW_STATUS_PENDING_MODEL
    if current in (REVIEW_STATUS_APPROVED, REVIEW_STATUS_REJECTED):
        return str(current)
    return REVIEW_STATUS_PENDING_REVIEW


def derive_review_status_for(model_id: Any) -> str:
    """按模型推导新建成员的审核状态（无模型 → ``pending_model``）。

    供 ``team_tool.create_member`` 等"新建成员"路径使用，保证内存视图与落库
    状态同一口径（不要各自硬编码字符串字面量）。
    """
    return _derive_review_status(model_id, None)


def normalize_review_status(value: Any, model_id: Any = "") -> Optional[str]:
    """把审核状态归一化为**与模型自洽**的合法值，供入库使用。

    - 值非法（不在 :data:`REVIEW_STATUSES`）→ 返回 None（调用方决定回退策略）；
    - 空模型 → 强制 ``pending_model``（未赋模型的成员不可能处于审核态）；
    - ``approved``/``rejected`` 为终态，模型非空时原样保留。

    :param value: 期望状态（如 ``approved``）
    :param model_id: 该成员生效的模型，用于自洽性收敛
    """
    text = str(value or "").strip().lower()
    if text not in REVIEW_STATUSES:
        return None
    return _derive_review_status(model_id, text)


def update_member_review_status(
    team_id: str,
    member_id: str,
    value: Any = None,
    model_id: Any = None,
) -> Optional[Dict[str, Any]]:
    """设置成员的审核状态与/或模型，并保证两者自洽。

    **这是"赋模型 / 审核 / 撤销审核"的唯一入口**，前端 teammates 面板与 team
    工具的 review_member 都走它，避免各处重复推导状态机。

    :param value: 期望状态（``approved``/``rejected``/``pending_review``…）；
                  None 表示不改状态（仅赋模型时按新模型推导）
    :param model_id: 新模型；None 表示不改模型
    :return: 更新后的成员；成员不存在返回 None
    :raises ValueError: 提供了 ``value`` 但不是合法状态
    """
    current = get_member(team_id, member_id)
    if current is None:
        return None
    effective_model = (
        model_id if model_id is not None else current.get("model_id", "")
    )
    if value is None:
        status = _derive_review_status(
            effective_model, current.get("review_status")
        )
    else:
        status = normalize_review_status(value, effective_model)
        if status is None:
            raise ValueError(f"审核状态非法: {value!r}")
    payload: Dict[str, Any] = {"review_status": status}
    if model_id is not None:
        payload["model_id"] = str(model_id)
    return update_member(team_id, member_id, **payload)


def needs_user_review(row: Dict[str, Any]) -> bool:
    """该成员是否处于"等待用户处理"状态（未赋模型 / 待审核）。"""
    return (row.get("review_status") or "") in REVIEW_STATUS_NEEDS_USER


def count_pending_members(team_id: str) -> int:
    """统计某 TOP 旗下**等待用户处理**的成员数（红点徽章计数口径）。

    与 :func:`needs_user_review` 同一口径，供 ``/api/agents`` 列表徽章使用。
    """
    _ensure_db()
    conn = _connect()
    try:
        placeholders = ",".join("?" for _ in REVIEW_STATUS_NEEDS_USER)
        row = conn.execute(
            f"SELECT COUNT(*) FROM team_members "
            f"WHERE team_id = ? AND review_status IN ({placeholders})",
            (team_id, *REVIEW_STATUS_NEEDS_USER),
        ).fetchone()
        return int(row[0]) if row else 0
    finally:
        conn.close()

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
                review_status TEXT NOT NULL DEFAULT '',
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
        _migrate_column(conn, "team_members", "review_status",
                        "ALTER TABLE team_members ADD COLUMN review_status "
                        "TEXT NOT NULL DEFAULT ''")
        # 回填旧行的审核状态（幂等）：有模型视为已审核，无模型视为待赋模型。
        # 不回填的话，旧行 review_status='' 既不属于"待用户处理"也不属于
        # "已审核"，会在前端显示为第三种状态且列表徽章统计不到它们。
        conn.execute(
            "UPDATE team_members SET review_status = ? "
            "WHERE review_status IS NULL OR review_status = ''",
            (REVIEW_STATUS_APPROVED,),
        )
        conn.execute(
            "UPDATE team_members SET review_status = ? "
            "WHERE review_status = ? AND (model_id IS NULL OR model_id = '')",
            (REVIEW_STATUS_PENDING_MODEL, REVIEW_STATUS_APPROVED),
        )
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
    「可带队」列追加在其后，最后追加「审核」列（旧 roster 缺该列时解析按
    缺省处理）。完整列：ID | 名称 | 模型 | 层级 | 创建时间 | 工作状态 | 评价 |
    角色 | 职责 | 质量 | 效率 | 协作性 | 准确性 | 可带队 | 审核

    【状态治理】工作状态列输出占位 ``-``（不写任何状态值）：成员是否在
    工作的唯一权威是 ``chat._active_tasks``（实际 tool loop 登记），由
    ``team query_status`` / teammates API 实时计算；roster 不再承载状态，
    避免名册中的状态与实际情况脱节。

    【审核治理】「审核」列是成员能否工作的**前置条件**（用户审核通过才放行），
    必须在 roster 中可见，否则 leader 会反复向未就绪成员派活并收到拒绝。
    """
    header = (
        "| ID | 名称 | 模型 | 层级 | 创建时间 | 工作状态 | 评价 | "
        "角色 | 职责 | 质量 | 效率 | 协作性 | 准确性 | 可带队 | 审核 |"
    )
    separator = (
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- | "
        "--- | --- | --- | --- | --- | --- |"
    )
    lines = [header, separator]
    for m in members:
        s = m.get("scores") or {}
        can_lead = "是" if m.get("can_lead_team", 1) else "否"
        review = str(m.get("review_status") or "")
        if not review:
            review = (
                REVIEW_STATUS_APPROVED
                if str(m.get("model_id") or "").strip()
                else REVIEW_STATUS_PENDING_MODEL
            )
        lines.append(
            f"| {m.get('id', '')} | {m.get('name', '')} | "
            f"{m.get('model_id', '')} | {m.get('level', 1)} | "
            f"{m.get('created_at', '')} | - | "
            f"{m.get('comment', '')} | "
            f"{m.get('role', '')} | {m.get('duty', '')} | "
            f"{_to_score(s.get('quality', 0))} | "
            f"{_to_score(s.get('efficiency', 0))} | "
            f"{_to_score(s.get('collaboration', 0))} | "
            f"{_to_score(s.get('accuracy', 0))} | {can_lead} | {review} |"
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
    review_status: Optional[str] = None,
) -> Dict[str, Any]:
    """新增一名团队成员并更新团队 member_count。

    :param parent_agent_id: 直属 leader（创建者的 agent_id）；P4 全量建队时
                            为 team_id，leader 经 create_member 创建时为
                            创建者的 agent_id（用于「每层成员上限」与
                            teammates/team_member 分组）。
    :param can_lead_team: 是否允许该成员再建下级团队，默认允许。
    :param review_status: 审核状态；缺省由 :func:`_derive_review_status` 按
                          ``model_id`` 推导（空模型 → ``pending_model``）。
                          成员创建后**不继承** TOP 模型，必须由用户赋模型并
                          审核通过才会接收消息。
    """
    _ensure_db()
    now = int(time.time() * 1000)
    status = normalize_review_status(review_status, model_id)
    if status is None:
        status = _derive_review_status(model_id, None)
    with _write_lock, connect() as conn:
        conn.execute(
            "INSERT OR REPLACE INTO team_members "
            "(id, team_id, user_id, name, role, duty, model_id, level, "
            "work_status, comment, scores_json, system_prompt, parent_agent_id, "
            "can_lead_team, review_status, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'idle', '', '{}', ?, ?, ?, ?, ?, ?)",
            (
                member_id, team_id, user_id, name, role, duty,
                model_id, level, system_prompt, parent_agent_id,
                1 if can_lead_team else 0, status, now, now,
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


def remove_member(team_id: str, member_id: str) -> bool:
    """从团队名单中移除单个成员，并重算 ``teams.member_count``。

    仅删除 ``team_members`` 行的名单记录（工作空间/会话/上下文/运行时的清理由
    调用方负责，见 ``tool/team_tool.py`` 的 ``remove_member`` action）。删除
    子树请用 :func:`remove_member_subtree`。

    :return: 是否实际删除了记录
    """
    _ensure_db()
    now = int(time.time() * 1000)
    with _write_lock, connect() as conn:
        cursor = conn.execute(
            "DELETE FROM team_members WHERE team_id = ? AND id = ?",
            (team_id, member_id),
        )
        if cursor.rowcount <= 0:
            return False
        # 与 add_member 的计数口径一致：以实际行数回填，避免累加漂移
        conn.execute(
            "UPDATE teams SET member_count = "
            "(SELECT COUNT(*) FROM team_members WHERE team_id = ?), "
            "updated_at = ? WHERE team_id = ?",
            (team_id, now, team_id),
        )
        conn.commit()
        return True


def collect_member_subtree(team_id: str, root_id: str) -> List[str]:
    """收集 ``root_id`` 及其全部后代成员 id（含自身），按层级自浅到深。

    成员树通过 ``parent_agent_id`` 表达。返回顺序保证父先于子，便于调用方按序
    清理（先删父不会影响后续按 id 删除子行）。

    防御：以 ``team_id`` 限定范围（不跨团队），并用 ``visited`` 集合兜底——
    历史脏数据若形成环，也不会无限递归。
    """
    rows = get_members(team_id) or []
    children: Dict[str, List[str]] = {}
    for row in rows:
        parent = str(row.get("parent_agent_id") or "")
        mid = str(row.get("id") or "")
        if mid:
            children.setdefault(parent, []).append(mid)

    ordered: List[str] = []
    visited: set = set()
    stack: List[str] = [root_id]
    while stack:
        current = stack.pop(0)
        if not current or current in visited:
            continue
        visited.add(current)
        ordered.append(current)
        stack.extend(children.get(current, []))
    return ordered


def remove_member_subtree(team_id: str, root_id: str) -> List[str]:
    """移除 ``root_id`` 及其全部后代，返回被删除的成员 id 列表。

    :return: 实际删除的 id（按父先子后顺序）；``root_id`` 不在名单中时为空列表
    """
    _ensure_db()
    ids = collect_member_subtree(team_id, root_id)
    if not ids:
        return []
    now = int(time.time() * 1000)
    placeholders = ",".join("?" for _ in ids)
    with _write_lock, connect() as conn:
        cursor = conn.execute(
            f"DELETE FROM team_members WHERE team_id = ? AND id IN ({placeholders})",
            [team_id, *ids],
        )
        if cursor.rowcount <= 0:
            return []
        conn.execute(
            "UPDATE teams SET member_count = "
            "(SELECT COUNT(*) FROM team_members WHERE team_id = ?), "
            "updated_at = ? WHERE team_id = ?",
            (team_id, now, team_id),
        )
        conn.commit()
    return ids


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
        return [_row_to_member(row) for row in rows]
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
        return _row_to_member(row) if row else None
    finally:
        conn.close()


def update_member(
    team_id: str, member_id: str, **fields: Any
) -> Optional[Dict[str, Any]]:
    """更新成员字段（name/role/duty/model_id/level/work_status/comment/
    system_prompt/scores/can_lead_team/parent_agent_id/review_status），
    返回更新后的成员；成员不存在返回 None。

    审核状态一致性：改了 ``model_id`` 会重新推导 ``review_status``（赋模型 →
    ``pending_review``，清空模型 → ``pending_model``），**已审核结论**
    （approved/rejected）在模型非空时保持不变——否则编辑一次职责就会把成员的
    审核状态打回待审核。
    """
    allowed = {
        "name", "role", "duty", "model_id", "level", "work_status",
        "comment", "system_prompt", "scores", "can_lead_team",
        "parent_agent_id", "review_status",
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

    # 审核状态：读当前行补全"模型与状态必须自洽"的约束（见本模块状态机注释）
    if "review_status" in updates or "model_id" in updates:
        current = get_member(team_id, member_id)
        if current is None:
            return None
        effective_model = (
            updates["model_id"] if "model_id" in updates
            else current.get("model_id", "")
        )
        # 调用方给的状态只是"期望值"（可能是已归一化的合法值，也可能是脏数据，
        # 甚至同一拍里传了 model_id 却没传状态=让本函数按新模型推导），
        # 最终一律经 _derive_review_status 收敛：空模型不可能处于审核态；
        # 非空模型 + 已审核结论则保留结论。非法值自然回退为"按模型推导"。
        incoming = updates.get("review_status")
        if incoming is not None:
            incoming = normalize_review_status(incoming, effective_model)
        status = _derive_review_status(
            effective_model, incoming or current.get("review_status")
        )
        updates["review_status"] = status

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
    """DB 行 → 成员字典：解析 scores_json，并补齐审核状态。

    ``review_status`` 为空的旧行按 ``approved`` 兜底（与迁移口径一致：它们
    此前一直可用，不应因本次治理被突然停用）。
    """
    d = dict(row)
    try:
        d["scores"] = json.loads(d.pop("scores_json") or "{}")
    except (ValueError, TypeError):
        d["scores"] = {}
    if not d.get("review_status"):
        d["review_status"] = (
            REVIEW_STATUS_APPROVED
            if str(d.get("model_id") or "").strip()
            else REVIEW_STATUS_PENDING_MODEL
        )
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
