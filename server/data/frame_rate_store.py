"""流式输出帧率偏好存储。

前端「设置 - 主动延迟」开启后，除既有的「等级 API 调用频率」限制外，**再叠加**
一层生成器帧率控制：把同一次回复内流式产出的 token 按固定帧率合并投递给前端，
避免一整轮回复以 token 速度刷屏（每 chunk 一次 WS 帧 + 每次前端全量 markdown
重解析）。两把旋钮互不干扰：等级管 API 调用频率，本模块管生成器帧率。

单位是 **帧/秒（fps）**，取值范围 ``[20, 1000]``：20 是"人眼可跟上的慢放"，
1000 是近似不限速（间隔 1ms，实际受调度粒度约束，等价于关闭节流）。

执行逻辑在 ``llm/rate_limit.py``（内存缓存），本模块只负责持久化；REST 写接口
写库后同步内存缓存，服务启动时 ``load_all_frame_rates`` 预载。
"""
import logging
import sqlite3
import threading
import time
from pathlib import Path
from typing import Dict, Optional

logger = logging.getLogger(__name__)

from data.db import connect  # noqa: E402

# 数据库目录（与 rate_limit_store 保持一致）
_DATA_DIR = Path(__file__).resolve().parent.parent / "data"
_DB_PATH = _DATA_DIR / "conversations.db"

# 帧率取值范围（fps）与缺省值
MIN_FRAME_RATE = 20
MAX_FRAME_RATE = 1000
DEFAULT_FRAME_RATE = 20

# 写操作锁
_write_lock = threading.Lock()
_initialized = False


def clamp_frame_rate(value: object) -> int:
    """把任意输入规范为 ``[MIN_FRAME_RATE, MAX_FRAME_RATE]`` 内的整数 fps。

    非法值（None / 非数字 / 越界）一律回落到 [DEFAULT_FRAME_RATE]，而不是抛错——
    该值来自用户设置与启动预载，任何异常都不应阻断会话创建。
    """
    try:
        rate = int(float(value))  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return DEFAULT_FRAME_RATE
    if rate < MIN_FRAME_RATE:
        return MIN_FRAME_RATE
    if rate > MAX_FRAME_RATE:
        return MAX_FRAME_RATE
    return rate


def _ensure_db() -> None:
    """确保偏好表已创建（线程安全的惰性初始化）。"""
    global _initialized
    if _initialized:
        return
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    with connect() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS frame_rate_prefs (
                openid TEXT PRIMARY KEY,
                frame_rate INTEGER NOT NULL DEFAULT 20,
                updated_at INTEGER NOT NULL
            )
            """
        )
        conn.commit()
    _initialized = True


def _connect():
    _ensure_db()
    conn = connect()
    return conn


def set_frame_rate(openid: str, frame_rate: int) -> int:
    """设置某用户的流式帧率（upsert），返回规范化后的实际写入值。"""
    _ensure_db()
    rate = clamp_frame_rate(frame_rate)
    now = int(time.time() * 1000)
    with _write_lock:
        conn = _connect()
        try:
            conn.execute(
                "INSERT INTO frame_rate_prefs (openid, frame_rate, updated_at) "
                "VALUES (?, ?, ?) "
                "ON CONFLICT(openid) DO UPDATE SET "
                "frame_rate = excluded.frame_rate, updated_at = excluded.updated_at",
                (openid, rate, now),
            )
            conn.commit()
        finally:
            conn.close()
    return rate


def get_frame_rate(openid: str) -> int:
    """查询某用户的流式帧率（缺省 [DEFAULT_FRAME_RATE]）。"""
    _ensure_db()
    conn = _connect()
    try:
        row = conn.execute(
            "SELECT frame_rate FROM frame_rate_prefs WHERE openid = ?",
            (openid,),
        ).fetchone()
        return clamp_frame_rate(row[0]) if row else DEFAULT_FRAME_RATE
    finally:
        conn.close()


def load_all_frame_rates() -> Dict[str, int]:
    """读取全部用户的流式帧率（服务启动时预载到内存）。"""
    _ensure_db()
    conn = _connect()
    try:
        rows = conn.execute(
            "SELECT openid, frame_rate FROM frame_rate_prefs"
        ).fetchall()
        return {
            str(openid): clamp_frame_rate(rate) for openid, rate in rows
        }
    finally:
        conn.close()


def delete_user_frame_rate(openid: str) -> None:
    """删除某用户的流式帧率偏好（注销彻底删除时级联调用）。"""
    _ensure_db()
    with _write_lock, connect() as conn:
        conn.execute("DELETE FROM frame_rate_prefs WHERE openid = ?", (openid,))
        conn.commit()


def frame_rate_to_interval(frame_rate: Optional[int]) -> float:
    """把帧率（fps）换算为帧间隔（秒）；<=0 或非法时返回 0（表示不节流）。"""
    if not frame_rate or frame_rate <= 0:
        return 0.0
    return 1.0 / float(frame_rate)
