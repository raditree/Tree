"""SSH 连接配置存储 - ``ssh_connections`` 表 CRUD。

SSH 运行模式配置按 ``(user_id, agent_id)`` 维度持久化到 SQLite
（与 user_store / agent_store 共用 ``server/data/conversations.db``），
保证重启后端后 SSH 配置仍生效（spec「三模式运行」场景）。
"""
import base64
import logging
import os
import secrets
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)

# 数据库目录与文件（与 user_store 保持一致，定位到 server/data）
_DATA_DIR = Path(__file__).resolve().parent.parent / "data"
_DB_PATH = _DATA_DIR / "conversations.db"
_KEY_PATH = _DATA_DIR / "ssh_crypto.key"

# 写操作锁
_write_lock = threading.Lock()
_initialized = False

# ---------------------------------------------------------------------------
# SSH 密码加密模块（Fernet 对称加密，仅加密落库，读取时解密回明文）
# ---------------------------------------------------------------------------
_ENC_PREFIX = "enc:"
_CIPHER = None          # Fernet 实例（惰性初始化）
_CIPHER_LOADED = False  # 是否已完成初始化（避免反复尝试导入 cryptography）


def _load_or_create_key() -> Optional[bytes]:
    """获取 Fernet 密钥字节。

    优先级：环境变量 ``SSH_ENCRYPT_KEY`` > 密钥文件 > 新生成并持久化。
    密钥为 32 字节随机数经 urlsafe base64 编码（Fernet 要求的密钥格式）。
    """
    env_key = os.environ.get("SSH_ENCRYPT_KEY")
    if env_key:
        try:
            base64.urlsafe_b64decode(env_key)
            return env_key.encode("ascii")
        except Exception:  # noqa: BLE001
            logger.warning("SSH_ENCRYPT_KEY 不是合法的 Fernet 密钥，忽略并回退到密钥文件")

    if _KEY_PATH.exists():
        try:
            return _KEY_PATH.read_bytes()
        except OSError:
            logger.warning("读取 SSH 加密密钥文件失败: %s", _KEY_PATH)

    # 首次运行：生成并持久化，保证服务重启后仍能解密
    try:
        key = base64.urlsafe_b64encode(secrets.token_bytes(32))
        _KEY_PATH.write_bytes(key)
        if os.name != "nt":  # POSIX 收紧权限；Windows 忽略
            os.chmod(_KEY_PATH, 0o600)
        logger.info("已生成 SSH 加密密钥文件: %s", _KEY_PATH)
        return key
    except OSError:
        logger.warning("SSH 加密密钥持久化失败，仅本次运行有效")
        return base64.urlsafe_b64encode(secrets.token_bytes(32))


def _get_cipher() -> Optional[object]:
    """惰性构建全局 Fernet 实例；依赖缺失/初始化失败时返回 None（降级不加密）。"""
    global _CIPHER, _CIPHER_LOADED
    if _CIPHER_LOADED:
        return _CIPHER
    _CIPHER_LOADED = True
    try:
        from cryptography.fernet import Fernet
    except ImportError:
        logger.warning(
            "cryptography 未安装，SSH 密码将以明文存储；请安装 'cryptography>=41.0.0'"
        )
        return None
    key = _load_or_create_key()
    if key is None:
        return None
    _CIPHER = Fernet(key)
    return _CIPHER


def encrypt_password(plain: Optional[str]) -> Optional[str]:
    """加密 SSH 密码。plain 为空返回原值；否则返回 ``enc:`` 前缀的密文。

    密钥不可用时降级为原样返回（不加密，避免服务崩溃）。
    """
    if not plain:
        return plain
    cipher = _get_cipher()
    if cipher is None:
        return plain
    token = cipher.encrypt(plain.encode("utf-8")).decode("utf-8")
    return _ENC_PREFIX + token


def decrypt_password(stored: Optional[str]) -> str:
    """解密 SSH 密码。

    ``enc:`` 前缀视为密文并解密；无前缀视为历史明文（向后兼容，原样返回），
    便于存量数据迁移过渡。密钥不可用或解密失败时原样返回。
    """
    if not stored or not stored.startswith(_ENC_PREFIX):
        return stored or ""
    cipher = _get_cipher()
    if cipher is None:
        return stored
    try:
        return cipher.decrypt(stored[len(_ENC_PREFIX):].encode("utf-8")).decode("utf-8")
    except Exception:  # noqa: BLE001
        logger.warning("SSH 密码解密失败，返回密文原值")
        return stored


def _ensure_db() -> None:
    """确保 ssh_connections 表已创建（线程安全的惰性初始化）。"""
    global _initialized
    if _initialized:
        return
    with sqlite3.connect(_DB_PATH) as conn:
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS ssh_connections (
                user_id TEXT NOT NULL,
                agent_id TEXT NOT NULL,
                host TEXT NOT NULL,
                port INTEGER NOT NULL DEFAULT 22,
                username TEXT NOT NULL,
                auth_type TEXT NOT NULL DEFAULT 'password',
                password TEXT NOT NULL DEFAULT '',
                private_key_path TEXT NOT NULL DEFAULT '',
                remote_base_dir TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (user_id, agent_id)
            )
            """
        )
        conn.commit()
    _initialized = True


def _connect():
    _ensure_db()
    conn = sqlite3.connect(_DB_PATH)
    conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
    return conn


def _row_to_dict(row: sqlite3.Row) -> Dict[str, Any]:
    return {
        "user_id": row["user_id"],
        "agent_id": row["agent_id"],
        "host": row["host"],
        "port": row["port"],
        "username": row["username"],
        "auth_type": row["auth_type"],
        "password": decrypt_password(row["password"]),
        "private_key_path": row["private_key_path"],
        "remote_base_dir": row["remote_base_dir"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


def save_connection(
    user_id: str,
    agent_id: str,
    host: str,
    port: int = 22,
    username: str = "",
    auth_type: str = "password",
    password: str = "",
    private_key_path: str = "",
    remote_base_dir: str = "",
) -> Dict[str, Any]:
    """保存（或覆盖）一个 SSH 连接配置。

    以 ``(user_id, agent_id)`` 为键，密码与私钥路径只保留其一
    （auth_type 决定使用哪种认证方式）。
    """
    now = int(time.time())
    with _write_lock:
        conn = _connect()
        try:
            conn.execute(
                """
                INSERT INTO ssh_connections (
                    user_id, agent_id, host, port, username, auth_type,
                    password, private_key_path, remote_base_dir, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(user_id, agent_id) DO UPDATE SET
                    host = excluded.host,
                    port = excluded.port,
                    username = excluded.username,
                    auth_type = excluded.auth_type,
                    password = excluded.password,
                    private_key_path = excluded.private_key_path,
                    remote_base_dir = excluded.remote_base_dir,
                    updated_at = excluded.updated_at
                """,
                (
                    user_id, agent_id, host, int(port), username, auth_type,
                    encrypt_password(password), private_key_path, remote_base_dir, now, now,
                ),
            )
            conn.commit()
        finally:
            conn.close()
    return get_connection(user_id, agent_id) or {}


def get_connection(user_id: str, agent_id: str) -> Optional[Dict[str, Any]]:
    """按 ``(user_id, agent_id)`` 读取 SSH 连接配置；不存在返回 None。"""
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        cur = conn.execute(
            "SELECT * FROM ssh_connections WHERE user_id = ? AND agent_id = ?",
            (user_id, agent_id),
        )
        row = cur.fetchone()
        return _row_to_dict(row) if row else None
    finally:
        conn.close()


def delete_connection(user_id: str, agent_id: str) -> bool:
    """删除指定 SSH 连接配置，返回是否实际删除。"""
    with _write_lock:
        conn = _connect()
        try:
            cur = conn.execute(
                "DELETE FROM ssh_connections WHERE user_id = ? AND agent_id = ?",
                (user_id, agent_id),
            )
            conn.commit()
            return cur.rowcount > 0
        finally:
            conn.close()


def get_all_connections(user_id: str) -> List[Dict[str, Any]]:
    """列出某用户全部 SSH 连接配置。"""
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        cur = conn.execute(
            "SELECT * FROM ssh_connections WHERE user_id = ? ORDER BY updated_at DESC",
            (user_id,),
        )
        return [_row_to_dict(r) for r in cur.fetchall()]
    finally:
        conn.close()
