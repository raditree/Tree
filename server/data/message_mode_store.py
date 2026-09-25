"""消息切入模式偏好存储。

前端「设置 - 消息切入模式」选择（``message_mode_prefs`` 表）决定 agent 在
处理消息期间收到新消息（用户插话 / 其他 agent 的派活与主动汇报等）时的切入策略：

- ``queue``（串行排队，默认）：新消息入队，仅在当前消息的 tool_call 间隙
  **逐条**切入；当前轮以最终文本结束时，剩余消息等本轮结束后作为独立一轮
  再处理（历史行为）。
- ``direct``（直接切入）：在 tool_call 间隙把队列中当前会话的待处理消息
  **一次性全部**切入；且当前轮给出最终文本时，若队列中仍有新消息则继续
  本轮（并入同一上下文），使"几乎同时到达"的消息一起处理，而非拆成多轮
  串行等待。

存储仅保存偏好；行为执行在 ``agent/chat.py``（切入 drain）与
``llm/llm.py``（轮末继续）。
"""
import logging
import sqlite3
import threading
import time
from pathlib import Path

from data.db import connect  # noqa: E402

logger = logging.getLogger(__name__)

# 数据库目录（与 conversation_store 保持一致）
_DATA_DIR = Path(__file__).resolve().parent.parent / "data"
_DB_PATH = _DATA_DIR / "conversations.db"

# 模式取值
MODE_QUEUE = "queue"
MODE_DIRECT = "direct"
VALID_MODES = (MODE_QUEUE, MODE_DIRECT)

# 写操作锁
_write_lock = threading.Lock()
_initialized = False


def _ensure_db() -> None:
    """确保偏好表已创建（线程安全的惰性初始化）。"""
    global _initialized
    if _initialized:
        return
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    with connect() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS message_mode_prefs (
                openid TEXT PRIMARY KEY,
                mode TEXT NOT NULL DEFAULT 'queue',
                updated_at INTEGER NOT NULL
            )
            """
        )
        conn.commit()
    _initialized = True


def _connect():
    _ensure_db()
    return connect()


def set_message_mode(openid: str, mode: str) -> None:
    """设置某用户的消息切入模式（upsert），非法值回退 ``queue``。"""
    if mode not in VALID_MODES:
        mode = MODE_QUEUE
    _ensure_db()
    now = int(time.time() * 1000)
    with _write_lock:
        conn = _connect()
        try:
            conn.execute(
                "INSERT INTO message_mode_prefs (openid, mode, updated_at) "
                "VALUES (?, ?, ?) "
                "ON CONFLICT(openid) DO UPDATE SET "
                "mode = excluded.mode, updated_at = excluded.updated_at",
                (openid, mode, now),
            )
            conn.commit()
        finally:
            conn.close()


def get_message_mode(openid: str) -> str:
    """查询用户的消息切入模式。

    缺省/未设置/读写异常一律回退 ``queue``（保持既有串行排队行为），
    绝不因偏好读取失败影响消息处理主链路。
    """
    if not openid:
        return MODE_QUEUE
    try:
        conn = _connect()
        try:
            row = conn.execute(
                "SELECT mode FROM message_mode_prefs WHERE openid = ?",
                (openid,),
            ).fetchone()
            mode = str(row[0]) if row and row[0] else MODE_QUEUE
            return mode if mode in VALID_MODES else MODE_QUEUE
        finally:
            conn.close()
    except sqlite3.Error as exc:  # noqa: BLE001
        logger.warning("读取消息切入模式失败(回退 queue): %s", exc)
        return MODE_QUEUE


def is_direct_cutin(openid: str) -> bool:
    """是否启用「直接切入」模式（缺省 False = 串行排队）。"""
    return get_message_mode(openid) == MODE_DIRECT


def delete_user_message_mode_pref(user_id: str) -> None:
    """删除某用户的消息切入偏好（注销彻底删除时级联调用）。"""
    _ensure_db()
    with _write_lock, connect() as conn:
        conn.execute("DELETE FROM message_mode_prefs WHERE openid = ?", (user_id,))
        conn.commit()
