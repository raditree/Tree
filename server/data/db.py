"""SQLite 共享连接（conversations.db 单库多存储模块）。

300+ agent 7×24 长跑下，各存储模块（会话/消息/团队/限流等）频繁读写同一
SQLite 文件。统一连接参数：

- ``timeout=30``：写锁竞争时最多等待 30 秒（sqlite3 默认 5 秒在高峰期易抛
  ``database is locked``，表现为个别请求偶发失败）；
- ``PRAGMA busy_timeout = 30000``：与 timeout 呼应，等待而非立即报错；
- ``journal_mode = WAL``：读写不互斥，长事务期间读请求不被阻塞（幂等设置
  一次并持久化到库文件，未迁移的存储模块同样受益）。

用法：存储模块用 ``from data.db import connect`` 替换
``sqlite3.connect(_DB_PATH)``（text_factory 约定在 connect 内统一处理）。
"""
import logging
import sqlite3
import threading
from pathlib import Path

logger = logging.getLogger(__name__)

# 数据库目录：server/data
_DATA_DIR = Path(__file__).resolve().parent.parent / "data"
_DB_PATH = _DATA_DIR / "conversations.db"

# 连接超时（秒）：写锁竞争等待上限
CONNECT_TIMEOUT: float = 30.0

_init_lock = threading.Lock()
_wal_configured = False


def connect() -> sqlite3.Connection:
    """打开带超时与 WAL 的共享连接（UTF-8 text_factory 与既有约定一致）。"""
    _ensure_wal()
    conn = sqlite3.connect(_DB_PATH, timeout=CONNECT_TIMEOUT)
    conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
    try:
        conn.execute("PRAGMA busy_timeout = 30000")
    except sqlite3.Error:
        pass
    return conn


def _ensure_wal() -> None:
    """幂等启用 WAL（失败时回退默认 journal 模式，不阻塞使用）。"""
    global _wal_configured
    if _wal_configured:
        return
    with _init_lock:
        if _wal_configured:
            return
        try:
            _DATA_DIR.mkdir(parents=True, exist_ok=True)
            conn = sqlite3.connect(_DB_PATH, timeout=CONNECT_TIMEOUT)
            try:
                conn.execute("PRAGMA journal_mode = WAL")
            finally:
                conn.close()
        except sqlite3.Error as exc:  # noqa: BLE001
            logger.warning("启用 WAL 失败(回退默认 journal 模式): %s", exc)
        _wal_configured = True
