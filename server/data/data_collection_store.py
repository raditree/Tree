"""SFT 数据收集存储 - 开关偏好 + 会话级对话快照，用于导出 LLM 训练数据集。

用户在前端"设置 - 数据收集"开关（`data_collection_prefs` 表）开启时，
后台才允许收集该用户后续产生的对话数据；关闭开关即停止写入（**仅在开启
数据收集期间收集对话数据**）。

收集粒度：按 `(user_id, agent_id, session_id)` 存一个会话行，记录
**含 CoT（thinking）的完整 OpenAI messages 上下文**：
- ``base_messages``：会话首次进入收集时（用户开启开关后的第一次对话）的完整
  context 快照（含 system prompt、历史、推理）。此后只追加增量，不重复存历史。
- ``diffs``：后续每个用户轮次新增的消息 diff（``context[len(before):]``），
  一段一段顺序追加。导出时按 ``base + 依次合并 diffs`` 还原完整会话。

导出：每日固定时刻由后台定时任务（main.py）调用 :func:`export_daily_sft`，
把每个会话还原成完整 messages 写一行 JSON 写进 ``server/data/sft/sft_YYYYMMDD.jsonl``；
同时提供导出 API :func:`list_sft_files`（仅管理员可调用，防普通用户拉取全量数据越权）。
"""
import json
import sqlite3
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

# 数据库目录（与 conversation_store 保持一致）
_DATA_DIR = Path(__file__).resolve().parent.parent / "data"
_DB_PATH = _DATA_DIR / "conversations.db"
# SFT 导出文件目录
_SFT_DIR = _DATA_DIR / "sft"

# 日志器
import logging

logger = logging.getLogger(__name__)

# 写操作锁
_write_lock = threading.Lock()
_initialized = False


def _ensure_db() -> None:
    """确保偏好表与会话快照表已创建（线程安全的惰性初始化）。"""
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
            CREATE TABLE IF NOT EXISTS sft_sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id TEXT NOT NULL,
                agent_id TEXT NOT NULL,
                session_id TEXT NOT NULL DEFAULT 'session_default',
                base_messages TEXT NOT NULL,
                diffs TEXT NOT NULL DEFAULT '[]',
                sealed TEXT NOT NULL DEFAULT '[]',
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                UNIQUE (user_id, agent_id, session_id)
            )
            """
        )
        # 兼容旧库：若表在 UNIQUE 约束前已建且积累重复行，先按 key 去重
        #（保留最新 id 行），再建唯一索引，保证 reset_base 的 ON CONFLICT 生效
        conn.execute(
            "DELETE FROM sft_sessions WHERE id NOT IN ("
            "SELECT MAX(id) FROM sft_sessions "
            "GROUP BY user_id, agent_id, session_id)"
        )
        conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS uq_sft_user_agent_session "
            "ON sft_sessions (user_id, agent_id, session_id)"
        )
        # 兼容旧库：早期表无 sealed 列，补充迁移（重复执行被 OperationalError 忽略）
        try:
            conn.execute(
                "ALTER TABLE sft_sessions ADD COLUMN sealed TEXT NOT NULL DEFAULT '[]'"
            )
        except sqlite3.OperationalError:
            # 列已存在（表已含 sealed）
            pass
        conn.commit()
    _initialized = True


def _connect():
    _ensure_db()
    conn = sqlite3.connect(_DB_PATH)
    conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
    return conn


# ----------------------------------------------------------------------
# 数据收集开关
# ----------------------------------------------------------------------
def set_collection_enabled(openid: str, enabled: bool) -> None:
    """设置某用户的"允许收集使用数据"开关（upsert）。"""
    _ensure_db()
    now = int(time.time() * 1000)
    with _write_lock:
        conn = _connect()
        try:
            conn.execute(
                "INSERT INTO data_collection_prefs (openid, enabled, updated_at) "
                "VALUES (?, ?, ?) "
                "ON CONFLICT(openid) DO UPDATE SET "
                "enabled = excluded.enabled, updated_at = excluded.updated_at",
                (openid, 1 if enabled else 0, now),
            )
            conn.commit()
        finally:
            conn.close()


def is_collection_enabled(openid: str) -> bool:
    """查询用户是否开启数据收集（缺省 False）。"""
    _ensure_db()
    conn = _connect()
    try:
        row = conn.execute(
            "SELECT enabled FROM data_collection_prefs WHERE openid = ?",
            (openid,),
        ).fetchone()
        return bool(row and row[0])
    finally:
        conn.close()


# ----------------------------------------------------------------------
# 会话级对话快照（base + diffs）
# ----------------------------------------------------------------------
def _common_prefix_len(
    a: List[Dict[str, Any]],
    b: List[Dict[str, Any]],
) -> int:
    """计算两个消息列表开头连续相等的条数（逐条 dict ==）。

    compact 会把中间历史压缩替换成 summary 或删掉多余消息，导致
    ``context_after`` 开头与 ``context_before`` 不再逐条一致。用公共前缀
    而非长度切片定位新增段，才能得到准确的 diff。
    """
    n = 0
    for x, y in zip(a, b):
        if x == y:
            n += 1
        else:
            break
    return n


def _restore_full_history(
    base_messages_str: str,
    diffs_str: str,
) -> List[Dict[str, Any]]:
    """把 base + diffs 还原成完整 messages 列表。"""
    try:
        base = json.loads(base_messages_str) or []
    except (ValueError, TypeError):
        base = []
    try:
        diffs = json.loads(diffs_str) or []
    except (ValueError, TypeError):
        diffs = []
    messages: List[Dict[str, Any]] = list(base)
    for diff in diffs:
        if isinstance(diff, list):
            messages.extend(diff)
    return messages


def collect_sft_turn(
    user_id: str,
    agent_id: str,
    session_id: str,
    context_before: List[Dict[str, Any]],
    context_after: List[Dict[str, Any]],
) -> None:
    """收集一个用户轮次新增的对话消息 diff。

    若开关未开启则静默忽略（不收集）。

    数据组织为「已封存段 + 活动段」：
    - 活动段由 ``base_messages`` + ``diffs`` 构成，随每个轮次追加 diff。
    - 发生 compact 时，LLM 会把中间历史压缩成 summary / 删除多余消息，
      破坏前缀一致性（``LCP < len(before)``），导致活动段的 base+diffs 无法
      再与新的 context 连续对齐。此时**不丢弃旧数据**，而是把活动段当前已
      还原的完整历史封存进 ``sealed``（独立完整段），再以 ``context_after``
      全量开启新的活动段继续收集。这样 compact 前后的对话历史都保留。
    """
    if not is_collection_enabled(user_id):
        return

    now = int(time.time() * 1000)
    with _write_lock:
        conn = _connect()
        try:
            row = conn.execute(
                "SELECT id, base_messages, diffs, sealed FROM sft_sessions "
                "WHERE user_id = ? AND agent_id = ? AND session_id = ?",
                (user_id, agent_id, session_id),
            ).fetchone()

            if row is None:
                # 首次收集：以当前 context 为 base，该轮新增为第一段 diff
                common = _common_prefix_len(context_before, context_after)
                diff = context_after[common:]
                conn.execute(
                    "INSERT INTO sft_sessions "
                    "(user_id, agent_id, session_id, base_messages, diffs, "
                    "created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    (
                        user_id, agent_id, session_id,
                        json.dumps(context_before, ensure_ascii=False),
                        json.dumps([diff], ensure_ascii=False),
                        now, now,
                    ),
                )
                conn.commit()
                return

            # 已有活动段：判断是否发生 compact
            try:
                sealed: List[Any] = json.loads(row[3]) or []
            except (ValueError, TypeError):
                sealed = []
            common = _common_prefix_len(context_before, context_after)
            compacted = common < len(context_before)

            if compacted:
                # 封存当前活动段（含已还原历史），开启以 context_after 为
                # base 的新活动段。sealed 保留历史，不覆盖不丢失。
                old_full = _restore_full_history(row[1], row[2])
                if old_full:
                    sealed.append(old_full)
                conn.execute(
                    "UPDATE sft_sessions SET "
                    "base_messages = ?, diffs = ?, sealed = ?, updated_at = ? "
                    "WHERE id = ?",
                    (
                        json.dumps(context_after, ensure_ascii=False),
                        "[]",  # 新活动段初始无 diff
                        json.dumps(sealed, ensure_ascii=False),
                        now,
                        row[0],
                    ),
                )
            else:
                # 纯追加：新增段 = after 越过公共前缀之后的全部消息
                diff = context_after[common:]
                try:
                    existing_diffs = json.loads(row[2]) or []
                except (ValueError, TypeError):
                    existing_diffs = []
                existing_diffs.append(diff)
                conn.execute(
                    "UPDATE sft_sessions SET diffs = ?, updated_at = ? "
                    "WHERE id = ?",
                    (json.dumps(existing_diffs, ensure_ascii=False), now, row[0]),
                )
            conn.commit()
        finally:
            conn.close()


def delete_user_sft(user_id: str) -> None:
    """删除某用户的全部 SFT 会话快照（注销彻底删除时级联调用）。"""
    _ensure_db()
    with _write_lock, sqlite3.connect(_DB_PATH) as conn:
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        conn.execute("DELETE FROM sft_sessions WHERE user_id = ?", (user_id,))
        conn.execute("DELETE FROM data_collection_prefs WHERE openid = ?", (user_id,))
        conn.commit()


# ----------------------------------------------------------------------
# 导出
# ----------------------------------------------------------------------
def _reconstruct_messages(row: sqlite3.Row) -> List[Dict[str, Any]]:
    """把活动段 base + diffs 还原成完整 messages 列表。"""
    return _restore_full_history(row["base_messages"], row["diffs"])


def _split_segments(row: sqlite3.Row) -> List[List[Dict[str, Any]]]:
    """把一个会话拆成多个独立完整对话段。

    返回顺序：各 sealed 段（compact 封存的旧历史，按序）+ 最后的活动段。
    每段都是一条自洽、完整的对话，可独立作为 SFT 样本。
    """
    segments: List[List[Dict[str, Any]]] = []
    try:
        sealed = json.loads(row["sealed"]) or []
    except (ValueError, TypeError):
        sealed = []
    for seg in sealed:
        if isinstance(seg, list) and seg:
            segments.append(seg)
    active = _reconstruct_messages(row)
    if active:
        segments.append(active)
    return segments


def export_daily_sft() -> Path:
    """把所有已收集会话还原为完整消息，写 SFT jsonl 文件并返回路径。

    文件名 ``sft_YYYYMMDD.jsonl``，每行一条完整对话样本：
    ``{"messages": [...完整含CoT的OpenAI消息...]}``，附带会话元数据。

    一个会话若经历 compact，其旧历史被封存为 sealed 段，仍会被完整导出；
    该会话输出多行（每 sealed 段一行 + 活动段一行），不丢任何历史。
    """
    _ensure_db()
    _SFT_DIR.mkdir(parents=True, exist_ok=True)
    fname = f"sft_{datetime.now().strftime('%Y%m%d')}.jsonl"
    target = _SFT_DIR / fname

    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT agent_id, session_id, base_messages, diffs, sealed, "
            "updated_at FROM sft_sessions ORDER BY updated_at ASC"
        ).fetchall()
    finally:
        conn.close()

    count = 0
    with open(target, "w", encoding="utf-8") as f:
        for row in rows:
            for messages in _split_segments(row):
                record = {
                    "messages": messages,
                    "agent_id": row["agent_id"],
                    "session_id": row["session_id"],
                    "collected_until": row["updated_at"],
                }
                f.write(json.dumps(record, ensure_ascii=False) + "\n")
                count += 1
    logger.info("SFT 每日导出完成: %s（%d 个对话样本）", target, count)
    return target


def list_sft_files() -> List[Dict[str, Any]]:
    """列出已导出的 SFT jsonl 文件（仅管理员调用）。"""
    _ensure_db()
    if not _SFT_DIR.exists():
        return []
    files: List[Dict[str, Any]] = []
    for p in sorted(_SFT_DIR.glob("sft_*.jsonl")):
        files.append(
            {
                "filename": p.name,
                "size": p.stat().st_size,
                "mtime": int(p.stat().st_mtime * 1000),
            }
        )
    return files


def read_sft_file(filename: str) -> Optional[bytes]:
    """读取指定 SFT jsonl 文件的原始字节（防路径穿越）。"""
    _ensure_db()
    # 仅允许 sft_*.jsonl 命名，禁止路径穿越
    name = Path(filename).name
    if not name.startswith("sft_") or not name.endswith(".jsonl"):
        return None
    fp = _SFT_DIR / name
    if not fp.exists():
        return None
    return fp.read_bytes()