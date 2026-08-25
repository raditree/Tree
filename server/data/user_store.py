"""用户存储 - 账号密码注册/登录、注销倒计时与彻底删除。

与 agent_store / conversation_store 共用同一个 SQLite 数据库
（``server/data/conversations.db``）。

核心设计：
- 每个用户拥有唯一 ``openid`` 作为下游所有模块的用户标识，
  账号密码用户通过 ``source='account'`` 区分，微信用户通过 ``source='wechat'``。
- 注销流程（checklist 第 3 条）：
  1. 用户请求注销 -> 进入十日倒计时（``cancel_deadline``），期间功能照常、可随时取消
  2. 超过十日倒计时 -> 账号正式注销，数据保留 31 天（``delete_at``）
  3. 超过 ``delete_at`` -> 彻底删除该用户及其全部数据
"""
import hashlib
import os
import secrets
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any, Dict, Optional

from config.levels import DEFAULT_LEVEL, is_valid_level

# 数据库目录与文件（与 agent_store/conversation_store 保持一致）
_DATA_DIR = Path(__file__).resolve().parent.parent / "data"
_DB_PATH = _DATA_DIR / "conversations.db"

# 写操作锁
_write_lock = threading.Lock()
_initialized = False

# 用户等级内存缓存（user_id(openid) -> level），用独立锁保护，与 DB 写锁分开
_level_cache: Dict[str, str] = {}
_level_cache_lock = threading.Lock()
# 是否允许从 DB 恢复用户等级：restore_level=false（默认）时重启不恢复上次会话
# 落盘的等级，全部按 DEFAULT_LEVEL=common；由 load_levels_from_db() 设置。
# 关闭后 get_user_level 缓存未命中时直接返回 common，不再回读 DB 里旧等级
# （但 DB 落盘值本身不改，供 restore_level=true 或未来重新启用时保留）。
_level_restore_enabled: bool = True

# 注销流程天数配置
CANCEL_GRACE_DAYS = 10      # 申请注销后的十日倒计时（期间可取消）
RETENTION_AFTER_CANCEL = 31  # 倒计时结束后数据保留 31 天


def _ensure_level_column(conn: sqlite3.Connection) -> None:
    """幂等迁移：老库 users 表缺少 level 列时补加（新库 CREATE TABLE 已含）。

    通过 PRAGMA table_info(users) 检查列是否存在，不存在才 ALTER，
    因此重复调用不报错、不重复修改。
    """
    cols = {row[1] for row in conn.execute("PRAGMA table_info(users)").fetchall()}
    if "level" not in cols:
        conn.execute(
            "ALTER TABLE users ADD COLUMN level TEXT NOT NULL DEFAULT 'common'"
        )


def _ensure_db() -> None:
    """确保 users 表已创建（线程安全的惰性初始化）。"""
    global _initialized
    if _initialized:
        return
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(_DB_PATH) as conn:
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS users (
                id TEXT PRIMARY KEY,
                username TEXT UNIQUE,
                password_hash TEXT,
                salt TEXT,
                openid TEXT UNIQUE NOT NULL,
                nickname TEXT NOT NULL DEFAULT '',
                avatar TEXT NOT NULL DEFAULT '',
                source TEXT NOT NULL DEFAULT 'account',
                level TEXT NOT NULL DEFAULT 'common',
                delete_requested_at INTEGER,
                cancel_deadline INTEGER,
                delete_at INTEGER,
                created_at INTEGER NOT NULL
            )
            """
        )
        # 老库迁移：确保 level 列存在（幂等）
        _ensure_level_column(conn)
        conn.commit()
    _initialized = True


def _connect():
    _ensure_db()
    conn = sqlite3.connect(_DB_PATH)
    conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
    return conn


# ----------------------------------------------------------------------
# 密码哈希
# ----------------------------------------------------------------------
def _hash_password(password: str, salt: Optional[str] = None) -> tuple:
    """使用 PBKDF2-HMAC-SHA256 计算密码哈希，返回 (hash_hex, salt)。"""
    if salt is None:
        salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt.encode("utf-8"), 200_000
    )
    return digest.hex(), salt


def _verify_password(password: str, password_hash: str, salt: str) -> bool:
    digest, _ = _hash_password(password, salt)
    return secrets.compare_digest(digest, password_hash)


def _generate_openid() -> str:
    """生成账号用户的唯一 openid（下游 user_id 标识）。"""
    return f"user_{secrets.token_hex(12)}"


def _row_to_user(row: sqlite3.Row) -> Dict[str, Any]:
    return {
        "id": row["id"],
        "username": row["username"],
        "password_hash": row["password_hash"],
        "salt": row["salt"],
        "openid": row["openid"],
        "nickname": row["nickname"],
        "avatar": row["avatar"],
        "source": row["source"],
        "level": row["level"],
        "delete_requested_at": row["delete_requested_at"],
        "cancel_deadline": row["cancel_deadline"],
        "delete_at": row["delete_at"],
        "created_at": row["created_at"],
    }


# ----------------------------------------------------------------------
# 账号创建 / 查询
# ----------------------------------------------------------------------
def create_account(username: str, password: str, nickname: str = "") -> Dict[str, Any]:
    """创建账号密码用户，返回用户字典（含 openid）。"""
    _ensure_db()
    username = username.strip()
    password_hash, salt = _hash_password(password)
    user_id = f"u_{int(time.time() * 1000)}"
    openid = _generate_openid()
    created_at = int(time.time() * 1000)
    with _write_lock:
        conn = _connect()
        try:
            conn.execute(
                "INSERT INTO users "
                "(id, username, password_hash, salt, openid, nickname, source, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?, 'account', ?)",
                (user_id, username, password_hash, salt, openid, nickname or username, created_at),
            )
            conn.commit()
        finally:
            conn.close()
    user = get_user_by_openid(openid)
    assert user is not None
    return user


def get_user_by_username(username: str) -> Optional[Dict[str, Any]]:
    _ensure_db()
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            "SELECT * FROM users WHERE username = ?", (username.strip(),)
        ).fetchone()
        return _row_to_user(row) if row else None
    finally:
        conn.close()


def get_user_by_openid(openid: str) -> Optional[Dict[str, Any]]:
    _ensure_db()
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            "SELECT * FROM users WHERE openid = ?", (openid,)
        ).fetchone()
        return _row_to_user(row) if row else None
    finally:
        conn.close()


def authenticate(username: str, password: str) -> Optional[Dict[str, Any]]:
    """校验账号密码，成功返回用户字典，失败返回 None。"""
    user = get_user_by_username(username)
    if user is None:
        return None
    password_hash = user["password_hash"]
    salt = user["salt"]
    # 重新读取 salt（避免字典未含 salt）
    if salt is None or password_hash is None:
        return None
    if _verify_password(password, password_hash, salt):
        return user
    return None


def get_or_create_wechat_user(openid: str, nickname: str = "", avatar: str = "") -> Dict[str, Any]:
    """微信登录：按 openid 查找，不存在则创建（source='wechat'）。"""
    _ensure_db()
    user = get_user_by_openid(openid)
    if user is not None:
        return user
    user_id = f"u_{int(time.time() * 1000)}"
    created_at = int(time.time() * 1000)
    with _write_lock:
        conn = _connect()
        try:
            conn.execute(
                "INSERT INTO users "
                "(id, username, password_hash, salt, openid, nickname, avatar, source, created_at) "
                "VALUES (?, NULL, NULL, NULL, ?, ?, ?, 'wechat', ?)",
                (user_id, openid, nickname, avatar, created_at),
            )
            conn.commit()
        finally:
            conn.close()
    return get_user_by_openid(openid)


# ----------------------------------------------------------------------
# 注销流程
# ----------------------------------------------------------------------
def request_delete(openid: str) -> Optional[Dict[str, Any]]:
    """请求注销：进入十日倒计时，期间功能照常，可随时取消。"""
    user = get_user_by_openid(openid)
    if user is None:
        return None
    now = int(time.time())
    cancel_deadline = now + CANCEL_GRACE_DAYS * 86400
    delete_at = cancel_deadline + RETENTION_AFTER_CANCEL * 86400
    with _write_lock:
        conn = _connect()
        try:
            conn.execute(
                "UPDATE users SET delete_requested_at = ?, cancel_deadline = ?, "
                "delete_at = ? WHERE openid = ?",
                (now, cancel_deadline, delete_at, openid),
            )
            conn.commit()
        finally:
            conn.close()
    return get_user_by_openid(openid)


def cancel_delete(openid: str) -> Optional[Dict[str, Any]]:
    """取消注销：清除倒计时与删除时间。"""
    user = get_user_by_openid(openid)
    if user is None:
        return None
    with _write_lock:
        conn = _connect()
        try:
            conn.execute(
                "UPDATE users SET delete_requested_at = NULL, "
                "cancel_deadline = NULL, delete_at = NULL WHERE openid = ?",
                (openid,),
            )
            conn.commit()
        finally:
            conn.close()
    return get_user_by_openid(openid)


def change_password(openid: str, old_password: str, new_password: str) -> bool:
    """修改密码：校验旧密码正确后更新为新密码。

    成功返回 True，旧密码错误或用户不存在返回 False。
    """
    user = get_user_by_openid(openid)
    if user is None:
        return False
    password_hash = user.get("password_hash")
    salt = user.get("salt")
    if password_hash is None or salt is None:
        return False
    if not _verify_password(old_password, password_hash, salt):
        return False
    new_hash, new_salt = _hash_password(new_password)
    with _write_lock:
        conn = _connect()
        try:
            conn.execute(
                "UPDATE users SET password_hash = ?, salt = ? WHERE openid = ?",
                (new_hash, new_salt, openid),
            )
            conn.commit()
        finally:
            conn.close()
    return True


def get_account_status(openid: str) -> Dict[str, Any]:
    """返回账号注销状态。

    - ``status == 'active'``：正常
    - ``status == 'pending_delete'``：三日倒计时中，可取消（含剩余天数）
    - ``status == 'deleting'``：倒计时结束，数据保留 31 天后彻底删除（含剩余天数）
    """
    user = get_user_by_openid(openid)
    if user is None:
        return {"status": "deleted", "user": None}
    now = int(time.time())
    cancel_deadline = user.get("cancel_deadline")
    delete_at = user.get("delete_at")
    if user.get("delete_requested_at") and cancel_deadline:
        if now < cancel_deadline:
            days_left = max(0, int((cancel_deadline - now) / 86400) + 1)
            return {
                "status": "pending_delete",
                "cancel_days_left": days_left,
                "delete_at": delete_at,
                "user": user,
            }
        else:
            days_until_erase = max(0, int((delete_at - now) / 86400) + 1)
            return {
                "status": "deleting",
                "erase_days_left": days_until_erase,
                "delete_at": delete_at,
                "user": user,
            }
    return {"status": "active", "user": user}


def purge_expired_users() -> int:
    """彻底删除所有超过保留期（delete_at 已过）的用户及其全部数据。

    同时级联删除该用户的 agents、messages、agent_context。
    返回删除的用户数。
    """
    _ensure_db()
    now = int(time.time())
    expired = []
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT openid FROM users WHERE delete_at IS NOT NULL AND delete_at <= ?",
            (now,),
        ).fetchall()
        expired = [r["openid"] for r in rows]
    finally:
        conn.close()

    deleted = 0
    for openid in expired:
        with _write_lock, sqlite3.connect(_DB_PATH) as conn:
            conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
            conn.execute("DELETE FROM users WHERE openid = ?", (openid,))
            conn.execute("DELETE FROM agents WHERE user_id = ?", (openid,))
            conn.execute("DELETE FROM messages WHERE user_id = ?", (openid,))
            conn.execute("DELETE FROM agent_context WHERE user_id = ?", (openid,))
            conn.execute("DELETE FROM usage_snapshots WHERE openid = ?", (openid,))
            conn.execute("DELETE FROM data_collection_prefs WHERE openid = ?", (openid,))
            conn.execute("DELETE FROM sft_sessions WHERE user_id = ?", (openid,))
            conn.commit()
        deleted += 1
    return deleted


# ----------------------------------------------------------------------
# 用户等级（level）读写：内存缓存 + 落盘
# ----------------------------------------------------------------------
def get_user_level(user_id: str) -> str:
    """返回用户等级。

    优先读内存缓存；缓存未命中则读 DB（users.level，用户不存在时按
    DEFAULT_LEVEL）并回填缓存。永远返回合法等级（非法值回 common）。
    """
    _ensure_db()
    with _level_cache_lock:
        level = _level_cache.get(user_id)
    if level is not None:
        return level if is_valid_level(level) else DEFAULT_LEVEL
    if not _level_restore_enabled:
        # restore_level=false：不恢复上次会话落盘的等级，缓存未命中统一按 common，
        # 不回读 DB（DB 值保留但本会话不生效）。
        with _level_cache_lock:
            _level_cache[user_id] = DEFAULT_LEVEL
        return DEFAULT_LEVEL
    conn = _connect()
    try:
        row = conn.execute(
            "SELECT level FROM users WHERE openid = ?", (user_id,)
        ).fetchone()
        level = str(row[0]) if row else DEFAULT_LEVEL
    finally:
        conn.close()
    if not is_valid_level(level):
        level = DEFAULT_LEVEL
    with _level_cache_lock:
        _level_cache[user_id] = level
    return level


def set_user_level(user_id: str, level: str) -> str:
    """设置用户等级：校验（非法回 DEFAULT_LEVEL），更新内存缓存并 UPDATE 落盘。

    返回实际设置的等级。用户不存在时仅更新缓存不报错（由上层接口处理）。
    """
    _ensure_db()
    if not is_valid_level(level):
        level = DEFAULT_LEVEL
    with _level_cache_lock:
        _level_cache[user_id] = level
    with _write_lock:
        conn = _connect()
        try:
            conn.execute(
                "UPDATE users SET level = ? WHERE openid = ?", (level, user_id)
            )
            conn.commit()
        finally:
            conn.close()
    return level


def get_all_users_levels() -> Dict[str, str]:
    """遍历 users 表返回 {openid: level}（供启动恢复加载用）。"""
    _ensure_db()
    conn = _connect()
    try:
        rows = conn.execute("SELECT openid, level FROM users").fetchall()
        return {
            str(openid): level if is_valid_level(level) else DEFAULT_LEVEL
            for openid, level in rows
        }
    finally:
        conn.close()


def load_levels_from_db(restore: bool) -> None:
    """启动加载等级缓存。

    restore=True 时用 DB 落盘值把各用户等级载入内存缓存；
    restore=False 时清空缓存并关闭 DB 恢复（所有用户按 DEFAULT_LEVEL=common，
    get_user_level 不再回读 DB，但 DB 落盘值本身不改）。
    """
    global _level_restore_enabled
    _ensure_db()
    if restore:
        data = get_all_users_levels()
        with _level_cache_lock:
            _level_cache.clear()
            _level_cache.update(data)
        _level_restore_enabled = True
    else:
        with _level_cache_lock:
            _level_cache.clear()
        _level_restore_enabled = False


def load_user_levels() -> None:
    """按配置 registration.restore_level 决定是否从 DB 恢复等级缓存（无参，供启动调用）。"""
    from config.levels import get_registration_config

    restore = bool(get_registration_config().get("restore_level", False))
    load_levels_from_db(restore)