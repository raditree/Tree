"""运行模式解析器 - cloud / local / ssh 三分支 + 互斥校验。

三模式按 ``(user_id, team_id)`` 维度判定，优先级 **local > ssh > cloud**
（local 与 ssh 互斥，同 top 同时只能启用一种非 cloud 模式）：

- :func:`resolve_mode`：返回 ``"local"`` / ``"ssh"`` / ``"cloud"``；team 首次
  收到消息后按 ``agents.mode`` 持久化值优先判定（模式锁定，见
  :func:`ensure_mode_locked`）
- :func:`ensure_mode_locked`：首消息锁定辅助——mode 为空时按运行时判定结果
  写回 agents 表，此后不再变更（除非用户显式变更）
- :func:`build_workspace_io`：构建与当前模式一致的 WorkspaceIO（供 chat
  编排、roster/日志读取、工具装配共用，避免双轨制）
- :func:`check_exclusive`：注册新模式前的互斥校验（spec 场景：已启用 local
  再注册 ssh 必须拒绝并提示先注销 local）

依赖全局 ``state``（lifespan 填充 local_executor / ssh_manager / docker_manager）。
"""
from __future__ import annotations

import logging
from typing import Any, Optional, Tuple

import state

logger = logging.getLogger(__name__)


def _persisted_mode(user_id: str, team_id: str) -> Optional[str]:
    """读取已持久化的运行模式（agents.mode 列，模式锁定值）。

    仅在 agents 表可读且存在非空 mode 时返回；未锁定 / agent 不存在 /
    读取异常（如表结构未初始化）一律返回 None，保证"未持久化时行为=现状"
    （调用方回落运行时注册态判定，不影响既有测试与运行路径）。
    """
    try:
        from data.agent_store import get_agent_mode

        return get_agent_mode(user_id, team_id)
    except Exception as exc:  # noqa: BLE001
        logger.debug("读取持久化运行模式失败（按未锁定处理）: %s", exc)
        return None


def resolve_mode(user_id: str, team_id: str) -> str:
    """判定某 top agent 当前运行模式（local > ssh > cloud）。

    已锁定的 agent（agents.mode 持久化）优先返回持久化值：
    - ``mode == cloud``：不依赖执行器运行时注册态（此后注册/注销 local/ssh
      不改变判定）；
    - ``mode == local/ssh``：以对应执行器当前仍注册为前提；执行器已注销
      （WS 断连/连续超时自动停用）时回落运行时判定（通常为 cloud），保持
      既有"执行器未注册 → 云端"的回退行为，不空等挂死；
    - 未锁定：按运行时注册态判定（local > ssh > cloud），与历史行为一致。
    """
    mode = _persisted_mode(user_id, team_id)
    if mode == "cloud":
        return "cloud"
    if mode == "local" and _is_local(user_id, team_id):
        return "local"
    if mode == "ssh" and _is_ssh(user_id, team_id):
        return "ssh"
    # 未锁定 / 已锁定 local·ssh 但执行器未注册 → 按运行时注册态判定（回落 cloud）
    if _is_local(user_id, team_id):
        return "local"
    if _is_ssh(user_id, team_id):
        return "ssh"
    return "cloud"


def ensure_mode_locked(user_id: str, team_id: str) -> str:
    """team（顶层 agent）首条消息到达时的运行模式锁定（幂等，轻量）。

    若 ``agents.mode`` 为空：以当前 :func:`resolve_mode`（运行时判定）结果为
    准写回 agents 表（先到先得）；已锁定则直接返回持久化值，不覆盖。
    任何 DB/判定异常不阻断消息处理（返回空串，消息按运行时判定继续）。
    local/ssh 模式的目录初始化由前端执行器负责，云端沙箱在 agent 创建时
    已创建（POST /agents → docker_manager.create_workspace），故本处只负责
    持久化 mode 字段，不重复创建任何沙箱/目录。

    :return: 生效的持久化模式（"cloud" / "local" / "ssh"）；锁定失败返回 ""
    """
    try:
        from data.agent_store import get_agent_mode, lock_agent_mode

        current = get_agent_mode(user_id, team_id)
        if current:
            return current
        mode = resolve_mode(user_id, team_id)
        if mode:
            lock_agent_mode(user_id, team_id, mode)
            return mode
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "运行模式锁定失败（按未锁定继续，消息仍按运行时判定处理）: "
            "user=%s team=%s err=%s",
            user_id, team_id, exc,
        )
    return ""


def _is_local(user_id: str, team_id: str) -> bool:
    try:
        local_executor = state.local_executor
        if local_executor is not None:
            return local_executor.is_local(user_id, team_id)
    except Exception as exc:  # noqa: BLE001
        logger.warning("local 模式判定异常（按未启用处理）: %s", exc)
    return False


def _is_ssh(user_id: str, team_id: str) -> bool:
    try:
        ssh_manager = state.ssh_manager
        if ssh_manager is not None:
            return ssh_manager.is_ssh(user_id, team_id)
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
    user_id: str, team_id: str, target: str
) -> Tuple[bool, str]:
    """注册前互斥校验：local 与 ssh 不可共存于同一 top agent。

    :param target: 待注册的模式（"local" / "ssh"）
    :return: ``(ok, message_or_empty)``；ok=False 时 message 为拒绝原因
    """
    other = "ssh" if target == "local" else "local"
    if other == "ssh" and _is_ssh(user_id, team_id):
        return False, "该 agent 已启用 SSH 模式，请先注销 SSH 再启用本地模式"
    if other == "local" and _is_local(user_id, team_id):
        return False, "该 agent 已启用本地模式，请先注销本地执行器再启用 SSH 模式"
    return True, ""


def describe_mode(user_id: str, team_id: str) -> str:
    """生成执行模式说明文本（含 shell 类型），供 system prompt 注入。

    spec「shell 类型透出」：cloud 注明 ``Linux 容器, shell = sh (POSIX)``；
    local Windows 注明 ``shell = cmd.exe`` 及语法注意事项；
    ssh 注明远端 shell 类型与"远端主机、操作不可逆"提示。
    """
    mode = resolve_mode(user_id, team_id)
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
            cfg = state.ssh_manager.get_config(user_id, team_id)
        host = (cfg or {}).get("host", "未知主机")
        return (
            f"执行模式: SSH 远端主机({host})。操作作用于远端主机、不可逆，"
            "执行命令前请确认影响范围；shell 类型以远端环境为准。"
        )
    return "执行模式: 云端 Linux 容器。shell = sh (POSIX)，遵循 POSIX 命令语法。"
