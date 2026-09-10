"""MCP 服务配置存储 - SQLite 持久化。

外部 MCP 服务（stdio 外接，如 npx / deno / 自定义可执行文件启动的第三方
服务）的注册信息持久化到 SQLite，供 REST 层（``/api/mcp/services``）管理，
并在会话构建时与 config yaml 中的内置服务合并注册到 MCPManager。

安全语义（「MCP 语义修正」后）：不再枚举允许的可执行文件名，改为
**底线形态过滤 + 用户授权**：

- 底线形态过滤：command 只要 basename 不是 shell 解释器、且 command/args
  不含命令串联/重定向/命令替换元字符与内联代码参数，即允许注册；绝对路径
  （含 Windows ``C:\\...``）与普通参数（``~`` / ``*`` / ``$`` / ``:`` 等）
  一律放行。命令本身的合理性交由用户在注册时判断。
- 用户授权：非可信启动器（见 ``is_trusted_launcher``）且非内置服务时，
  ``needs_user_confirmation`` 为真，留待前端首次确认后再启动
  （spec「MCP services CRUD 安全红线」的替代方案）。
"""
import json
import logging
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)

# 数据库目录：server/data
_DATA_DIR = Path(__file__).resolve().parent.parent / "data"
_DB_PATH = _DATA_DIR / "conversations.db"

_write_lock = threading.Lock()
_initialized = False

# 可信启动器（免确认快捷通道）：basename 命中即视为常见 MCP server 启动器。
# 注意：这里是「免确认」白名单，而不再是注册准入的门槛（非名单命令也可注册）。
_COMMAND_ALLOWLIST = (
    "npx", "node", "python", "python3", "uvx", "uv", "pipx", "docker",
)

# shell 解释器：禁止作为 MCP 启动命令（可借 -c/-Command/-EncodedCommand 直接执行任意代码）
_SHELL_INTERPRETERS = {
    "cmd", "powershell", "pwsh", "sh", "bash", "zsh", "dash", "csh", "ksh",
    "wscript", "cscript", "mshta", "rundll32", "regsvr32", "start", "open",
    "osascript",
}
# 命令串联 / 重定向 / 命令替换元字符：禁止出现在 command 与 args 中
_FORBIDDEN_METACHARS = set(";|&<>`\r\n")
# 内联代码/执行参数（忽略大小写精确匹配即拒绝）
_INLINE_EXEC_ARGS = {
    "-c", "/c", "/k", "-command", "--command", "-encodedcommand",
    "-e", "--eval", "--exec", "-exec", "-execute", "--execute",
}
# 内联执行片段（出现在任意参数中即拒绝）
_INLINE_EXEC_SNIPPETS = ("$(", "${", "`")

# 合法 scope 取值（"" 表示未指定）
_SCOPES = ("", "server", "local", "ssh")

# 内置服务名（config yaml / 会话内注册，不可经 REST 删除）
_BUILTIN_SERVICES = {"workspace", "document"}


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
                scope TEXT NOT NULL DEFAULT '',
                env_json TEXT NOT NULL DEFAULT '{}',
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )
            """
        )
        _migrate_mcp_services(conn)
        conn.commit()
    _initialized = True


def _migrate_mcp_services(conn: sqlite3.Connection) -> None:
    """为旧库补列（幂等）：scope / env_json。

    异常吞掉仅记 warning，避免历史库缺列导致启动失败。
    """
    try:
        cols = {row[1] for row in conn.execute("PRAGMA table_info(mcp_services)")}
        if "scope" not in cols:
            conn.execute(
                "ALTER TABLE mcp_services ADD COLUMN scope TEXT NOT NULL DEFAULT ''"
            )
        if "env_json" not in cols:
            conn.execute(
                "ALTER TABLE mcp_services ADD COLUMN env_json TEXT NOT NULL DEFAULT '{}'"
            )
    except Exception as exc:  # noqa: BLE001
        logger.warning("mcp_services 表结构迁移失败（已忽略）: %s", exc)


def _connect():
    """创建 UTF-8 编码的 SQLite 连接（确保表已建）。"""
    _ensure_db()
    conn = sqlite3.connect(_DB_PATH)
    conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
    return conn


def _basename(command: str) -> str:
    """取命令的 basename：去目录、去 .exe 后缀、转小写。"""
    base = (command or "").replace("\\", "/").split("/")[-1].strip().lower()
    if base.endswith(".exe"):
        base = base[:-4]
    return base


def is_trusted_launcher(command: str) -> bool:
    """命令是否可信启动器（免确认快捷通道，basename 命中白名单）。"""
    return _basename(command) in _COMMAND_ALLOWLIST


def needs_user_confirmation(command: str) -> bool:
    """是否需要用户首次确认（非可信启动器；无命令的内置服务免确认）。"""
    if not (command or "").strip():
        return False
    return not is_trusted_launcher(command)


def validate_service_config(
    name: str, command: str, args: List[str], scope: str = ""
) -> Optional[str]:
    """校验 MCP 服务注册配置，非法返回错误信息（None 表示合法）。

    底线形态过滤（不枚举可执行名）：
    - 名称非空、不含路径分隔符与空白；
    - scope 必须是 ""/server/local/ssh 之一；
    - command 非空，且 basename 不得是 shell 解释器；
    - command/args 不得含命令串联、重定向、命令替换元字符；
    - args 不得含内联代码/执行参数（``-c`` / ``--eval`` / ``$(`` 等）。
    """
    if not name or not name.strip():
        return "服务名称不能为空"
    name = name.strip()
    if any(ch in name for ch in "/\\ \t"):
        return "服务名称不能包含路径分隔符或空格"
    scope = (scope or "").strip()
    if scope not in _SCOPES:
        return f"scope 取值非法（允许：''、server、local、ssh）：{scope}"
    if not command or not command.strip():
        return "启动命令不能为空"
    command = command.strip()
    base = _basename(command)
    if base in _SHELL_INTERPRETERS:
        return (
            f"禁止用 shell 解释器作为 MCP 启动命令（{base}）："
            "可执行文件本身不得为 shell，以免借 -c/-Command 执行任意代码"
        )
    for token in [command, *args]:
        token = str(token)
        hit = next((ch for ch in token if ch in _FORBIDDEN_METACHARS), None)
        if hit is not None:
            return f"命令/参数禁止包含 shell 元字符（{hit!r}）：{token}"
    for arg in args:
        low = str(arg).strip().lower()
        if low in _INLINE_EXEC_ARGS:
            return f"禁止使用内联代码/执行参数: {arg}"
        if any(s in str(arg) for s in _INLINE_EXEC_SNIPPETS):
            return f"禁止在参数中使用命令替换/内联执行: {arg}"
    return None


def register_service(
    name: str,
    command: str,
    args: List[str],
    enabled: bool = True,
    scope: str = "",
    env: Optional[Dict[str, str]] = None,
) -> Dict[str, Any]:
    """注册/更新一个 MCP 服务配置（持久化）。返回注册后的记录。

    校验失败抛出 ValueError（错误信息面向用户可读）。
    """
    name = name.strip()
    scope = (scope or "").strip()
    env = dict(env or {})
    err = validate_service_config(name, command, args, scope)
    if err:
        raise ValueError(err)
    _ensure_db()
    now = int(time.time() * 1000)
    with _write_lock, sqlite3.connect(_DB_PATH) as conn:
        conn.text_factory = lambda b: b.decode("utf-8", errors="replace")
        conn.execute(
            "INSERT INTO mcp_services (name, command, args_json, enabled, scope, "
            "env_json, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(name) DO UPDATE SET "
            "command = excluded.command, args_json = excluded.args_json, "
            "enabled = excluded.enabled, scope = excluded.scope, "
            "env_json = excluded.env_json, updated_at = excluded.updated_at",
            (name, command, json.dumps(list(args), ensure_ascii=False),
             int(bool(enabled)), scope,
             json.dumps(env, ensure_ascii=False), now, now),
        )
        conn.commit()
    return {
        "name": name,
        "command": command,
        "args": list(args),
        "enabled": bool(enabled),
        "scope": scope,
        "env": env,
    }


def _row_to_dict(row: sqlite3.Row) -> Dict[str, Any]:
    """把 DB 行转为对外字典（解析 args/env_json，补 computed 字段）。"""
    d = dict(row)
    try:
        d["args"] = json.loads(d.pop("args_json") or "[]")
    except (ValueError, TypeError):
        d["args"] = []
    try:
        d["env"] = json.loads(d.pop("env_json") or "{}")
    except (ValueError, TypeError):
        d["env"] = {}
    if not isinstance(d.get("env"), dict):
        d["env"] = {}
    d["enabled"] = bool(d["enabled"])
    d["scope"] = d.get("scope") or ""
    d["needs_confirmation"] = needs_user_confirmation(d.get("command", ""))
    return d


def list_services() -> List[Dict[str, Any]]:
    """列出全部已注册的外部 MCP 服务配置。"""
    _ensure_db()
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT name, command, args_json, enabled, scope, env_json, "
            "created_at, updated_at FROM mcp_services ORDER BY created_at ASC"
        ).fetchall()
        return [_row_to_dict(row) for row in rows]
    finally:
        conn.close()


def get_service(name: str) -> Optional[Dict[str, Any]]:
    """按名称获取单个服务配置。"""
    _ensure_db()
    conn = _connect()
    try:
        conn.row_factory = sqlite3.Row
        row = conn.execute(
            "SELECT name, command, args_json, enabled, scope, env_json, "
            "created_at, updated_at FROM mcp_services WHERE name = ?",
            (name,),
        ).fetchone()
        if row is None:
            return None
        return _row_to_dict(row)
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
            "scope": svc.get("scope", "") or "",
            "env": svc.get("env") or {},
        }
    return config
