"""MCP 服务配置存储 - SQLite 持久化。

外部 MCP 服务（stdio 外接，如 npx / python 启动的第三方服务）的注册信息
持久化到 SQLite，供 REST 层（``/api/mcp/services``）管理，并在会话构建时
与 config yaml 中的内置服务合并注册到 MCPManager。

安全红线：命令必须通过白名单校验（绝对路径/可执行文件 + 参数禁止 shell
元字符），防止注册任意命令导致 RCE（spec「MCP services CRUD 安全红线」）。
"""
import json
import re
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

# 数据库目录：server/data
_DATA_DIR = Path(__file__).resolve().parent.parent / "data"
_DB_PATH = _DATA_DIR / "conversations.db"

_write_lock = threading.Lock()
_initialized = False

# 命令白名单：允许的可执行文件名/绝对路径片段
# （覆盖常见 MCP server 启动器；自定义需为绝对路径且文件存在由调用方校验）
_COMMAND_ALLOWLIST = (
    "npx", "node", "python", "python3", "uvx", "uv", "pipx", "docker",
)
# 禁止出现在命令/参数中的 shell 元字符（防注入）
_FORBIDDEN_CHARS = set("|;&$`<>(){}[]!\\*?~")

# 内置服务名（config yaml / 会话内注册，不可经 REST 删除）
_BUILTIN_SERVICES = {"workspace", "document", "embed_search"}


def _ensure_db() -> None:
    """确保数据库目录与表结构已创建（线程安全的惰性初始化）。"""
    global _initialized
    if _initialized:
        return
    _DATA_DIR.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(_DB_PATH) as conn:
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS mcp_services (
                name TEXT PRIMARY KEY,
                command TEXT NOT NULL,
                args_json TEXT NOT NULL DEFAULT '[]',
                enabled INTEGER NOT NULL DEFAULT 1,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )
            """
        )
        conn.commit()
    _initialized = True


def _connect():
    """创建 UTF-8 编码的 SQLite 连接（确保表已建）。"""
    _ensure_db()
    conn = sqlite3.connect(_DB_PATH)
    conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
    return conn


def validate_service_config(name: str, command: str, args: List[str]) -> Optional[str]:
    """校验 MCP 服务注册配置，非法返回错误信息（None 表示合法）。

    安全规则：
    - 名称非空、不含路径分隔符与空格；
    - 命令必须是白名单内的可执行名，或绝对路径（/ 或 \\ 开头）；
    - 命令与全部参数不得含 shell 元字符。
    """
    if not name or not name.strip():
        return "服务名称不能为空"
    name = name.strip()
    if any(ch in name for ch in "/\\ \t"):
        return "服务名称不能包含路径分隔符或空格"
    if not command or not command.strip():
        return "启动命令不能为空"
    command = command.strip()
    base = command.split("\\")[-1].split("/")[-1]
    is_allowlisted = base in _COMMAND_ALLOWLIST
    is_abs = command.startswith("/") or (
        len(command) > 2 and command[1] == ":" and command[2] in "/\\"
    )
    if not (is_allowlisted or is_abs):
        return (
            f"启动命令不在白名单内（允许: {', '.join(_COMMAND_ALLOWLIST)} 或绝对路径）"
        )
    for token in [command, *args]:
        if any(ch in _FORBIDDEN_CHARS for ch in token):
            return "命令/参数包含禁止的 shell 元字符"
    # 参数不得包含 --shell / -c 等注入危险参数（宽松校验常见危险形式）
    for arg in args:
        low = arg.lower()
        if low in ("-c", "--shell", "--command") or arg.startswith("$("):
            return f"禁止使用危险参数: {arg}"
    return None


def register_service(
    name: str, command: str, args: List[str], enabled: bool = True
) -> Dict[str, Any]:
    """注册/更新一个 MCP 服务配置（持久化）。返回注册后的记录。

    校验失败抛出 ValueError（错误信息面向用户可读）。
    """
    name = name.strip()
    err = validate_service_config(name, command, args)
    if err:
        raise ValueError(err)
    _ensure_db()
    now = int(time.time() * 1000)
    with _write_lock, sqlite3.connect(_DB_PATH) as conn:
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        conn.execute(
            "INSERT INTO mcp_services (name, command, args_json, enabled, "
            "created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(name) DO UPDATE SET "
            "command = excluded.command, args_json = excluded.args_json, "
            "enabled = excluded.enabled, updated_at = excluded.updated_at",
            (name, command, json.dumps(list(args), ensure_ascii=False),
             int(bool(enabled)), now, now),
        )
        conn.commit()
    return {
        "name": name,
        "command": command,
        "args": list(args),
        "enabled": bool(enabled),
    }


def list_services() -> List[Dict[str, Any]]:
    """列出全部已注册的外部 MCP 服务配置。"""
    _ensure_db()
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT name, command, args_json, enabled, created_at, updated_at "
            "FROM mcp_services ORDER BY created_at ASC"
        ).fetchall()
        result = []
        for row in rows:
            d = dict(row)
            try:
                d["args"] = json.loads(d.pop("args_json") or "[]")
            except (ValueError, TypeError):
                d["args"] = []
            d["enabled"] = bool(d["enabled"])
            result.append(d)
        return result
    finally:
        conn.close()


def get_service(name: str) -> Optional[Dict[str, Any]]:
    """按名称获取单个服务配置。"""
    _ensure_db()
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            "SELECT name, command, args_json, enabled, created_at, updated_at "
            "FROM mcp_services WHERE name = ?",
            (name,),
        ).fetchone()
        if row is None:
            return None
        d = dict(row)
        try:
            d["args"] = json.loads(d.pop("args_json") or "[]")
        except (ValueError, TypeError):
            d["args"] = []
        d["enabled"] = bool(d["enabled"])
        return d
    finally:
        conn.close()


def delete_service(name: str) -> bool:
    """删除一个 MCP 服务配置。内置服务不可删除，返回 False。"""
    if name in _BUILTIN_SERVICES:
        return False
    _ensure_db()
    with _write_lock, sqlite3.connect(_DB_PATH) as conn:
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        cursor = conn.execute(
            "DELETE FROM mcp_services WHERE name = ?", (name,)
        )
        conn.commit()
        return cursor.rowcount > 0


def load_services_as_config() -> Dict[str, Dict[str, Any]]:
    """把 DB 中的外部服务配置转为 MCPManager.register_service 的 config 字典。

    供会话构建（``register_builtin_tools``）合并使用：config yaml 内置服务 +
    DB 持久化服务。
    """
    config: Dict[str, Dict[str, Any]] = {}
    for svc in list_services():
        if not svc.get("enabled"):
            continue
        config[svc["name"]] = {
            "command": svc["command"],
            "args": svc.get("args", []),
        }
    return config
