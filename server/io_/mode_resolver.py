"""运行模式解析器 - cloud / local / ssh 三分支 + 互斥校验。

三模式按 ``(user_id, top_agent_id)`` 维度判定，优先级 **local > ssh > cloud**
（local 与 ssh 互斥，同 top 同时只能启用一种非 cloud 模式）：

- :func:`resolve_mode`：返回 ``"local"`` / ``"ssh"`` / ``"cloud"``
- :func:`build_workspace_io`：构建与当前模式一致的 WorkspaceIO（供 chat
  编排、roster/日志读取、工具装配共用，避免双轨制）
- :func:`check_exclusive`：注册新模式前的互斥校验（spec 场景：已启用 local
  再注册 ssh 必须拒绝并提示先注销 local）

依赖全局 ``state``（lifespan 填充 local_executor / ssh_manager / docker_manager）。
"""
from __future__ import annotations

import logging
from typing import Any, Tuple

import state

logger = logging.getLogger(__name__)


def resolve_mode(user_id: str, top_agent_id: str) -> str:
    """判定某 top agent 当前运行模式（local > ssh > cloud）。"""
    if _is_local(user_id, top_agent_id):
        return "local"
    if _is_ssh(user_id, top_agent_id):
        return "ssh"
    return "cloud"


def _is_local(user_id: str, top_agent_id: str) -> bool:
    try:
        local_executor = state.local_executor
        if local_executor is not None:
            return local_executor.is_local(user_id, top_agent_id)
    except Exception as exc:  # noqa: BLE001
        logger.warning("local 模式判定异常（按未启用处理）: %s", exc)
    return False


def _is_ssh(user_id: str, top_agent_id: str) -> bool:
    try:
        ssh_manager = state.ssh_manager
        if ssh_manager is not None:
            return ssh_manager.is_ssh(user_id, top_agent_id)
    except Exception as exc:  # noqa: BLE001
        logger.warning("ssh 模式判定异常（按未启用处理）: %s", exc)
    return False


def build_workspace_io(user_id: str, agent_id: str) -> Any:
    """构建与当前运行模式一致的 WorkspaceIO。

    :param user_id: 用户标识
    :param agent_id: 顶部 agent ID（mode key；顶层会话传入其自身 id）
    :return: WorkspaceIO 实例（local -> LocalWorkspaceIO / ssh -> SSHWorkspaceIO /
             cloud -> CloudWorkspaceIO）
    """
    mode = resolve_mode(user_id, agent_id)
    if mode == "local":
        from io_.workspace_io import LocalWorkspaceIO

        return LocalWorkspaceIO(
            state.local_executor, state.ws_manager, user_id, agent_id
        )
    if mode == "ssh":
        from io_.ssh_workspace_io import SSHWorkspaceIO

        # SSH 连接由前端发起；后端经反向 WS 委托前端执行，构造与 local 一致
        return SSHWorkspaceIO(
            state.local_executor, state.ws_manager, user_id, agent_id
        )
    from io_.workspace_io import CloudWorkspaceIO

    return CloudWorkspaceIO(state.docker_manager)


def check_exclusive(
    user_id: str, top_agent_id: str, target: str
) -> Tuple[bool, str]:
    """注册前互斥校验：local 与 ssh 不可共存于同一 top agent。

    :param target: 待注册的模式（"local" / "ssh"）
    :return: ``(ok, message_or_empty)``；ok=False 时 message 为拒绝原因
    """
    other = "ssh" if target == "local" else "local"
    if other == "ssh" and _is_ssh(user_id, top_agent_id):
        return False, "该 agent 已启用 SSH 模式，请先注销 SSH 再启用本地模式"
    if other == "local" and _is_local(user_id, top_agent_id):
        return False, "该 agent 已启用本地模式，请先注销本地执行器再启用 SSH 模式"
    return True, ""


def describe_mode(user_id: str, top_agent_id: str) -> str:
    """生成执行模式说明文本（含 shell 类型），供 system prompt 注入。

    spec「shell 类型透出」：cloud 注明 ``Linux 容器, shell = sh (POSIX)``；
    local Windows 注明 ``shell = cmd.exe`` 及语法注意事项；
    ssh 注明远端 shell 类型与"远端主机、操作不可逆"提示。
    """
    mode = resolve_mode(user_id, top_agent_id)
    if mode == "local":
        import platform

        if platform.system() == "Windows":
            return (
                "执行模式: 本地(用户本机 Windows)。shell = cmd.exe，"
                "请使用 Windows 命令语法（dir 而非 ls、type 而非 cat），"
                "路径用反斜杠或正斜杠，注意环境变量 %VAR% 语法。"
            )
        return "执行模式: 本地(用户本机)。shell = bash，遵循 POSIX 命令语法。"
    if mode == "ssh":
        cfg = None
        if state.ssh_manager is not None:
            cfg = state.ssh_manager.get_config(user_id, top_agent_id)
        host = (cfg or {}).get("host", "未知主机")
        return (
            f"执行模式: SSH 远端主机({host})。操作作用于远端主机、不可逆，"
            "执行命令前请确认影响范围；shell 类型以远端环境为准。"
        )
    return "执行模式: 云端 Linux 容器。shell = sh (POSIX)，遵循 POSIX 命令语法。"
