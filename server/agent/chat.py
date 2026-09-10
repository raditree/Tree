"""Agent chat 编排：用户/成员消息处理、流式推送、统一消息投递。

自 main.py 迁出（P0 组件化重组），包含：
- 用户消息处理（_handle_user_message / _stream_agent_reply）
- 成员消息处理（_process_member_message，由 team broker worker 串行调用）
- 统一消息投递（_dispatch_agent_message / _find_roster_member / _parse_roster_table）
- .self 文档注入（identity/memory/rule，超限 LLM 压缩）
- 活动日志 / 取消事件 / 记忆更新阶段
"""
import asyncio
import base64
import datetime
import hashlib
import logging
import os
import queue
import threading
import time
import uuid
from typing import Any, Callable, Dict, List, Optional, Set, Tuple

from openai import RateLimitError

import state
from config.config import get_config
from config.models import ModelConfig
from prompt import versions
from prompt.registry import audit_header
from data.agent_store import get_agent
from data.conversation_store import (
    load_context,
    save_context,
    store_message,
)
from data.data_collection_store import collect_sft_turn
from data.session_cache import get_session, pop_session, set_session
from data.session_store import (
    DEFAULT_SESSION,
    create_session,
    get_session_record,
    touch_session,
    update_session_title_from_first_message,
)
from io_.mode_resolver import ensure_mode_locked, resolve_mode
from io_.workspace_io import run_io
from llm.llm import AgentLLMSession, _AskPaused
from tool import register_builtin_tools

# 模块级日志器
logger = logging.getLogger(__name__)

# 用户自身 agent_id：统一消息接口中"用户直发"的发送方标记。
# 历史实现/旧数据以空串表示，读取侧经 is_user_sender 两者等效处理。
USER_AGENT_ID = "0"


def is_user_sender(id_: Any) -> bool:
    """判断消息发送方是否为用户直发。

    兼容两种标记：空串（历史/内部旧数据）与 ``USER_AGENT_ID``（"0"，
    统一消息接口的新标记）。凡对 sender_id / source_agent_id 做真值判断
    （``if sender_id:`` / ``sender_id or ...``）的地方必须改用本函数，
    因为 "0" 在 Python 中为真值，直接归一会改变用户直发路径的行为。
    """
    return not id_ or id_ == USER_AGENT_ID


# 主事件循环引用：消息分发层（同步函数，可能运行在工具线程/线程池）推送
# WS 消息时，经 run_coroutine_threadsafe 线程安全提交到主循环。由运行在
# 主循环的入口（WS 连接建立、_stream_agent_reply）opportunistic 绑定。
_MAIN_LOOP: Optional[asyncio.AbstractEventLoop] = None


def _bind_main_loop() -> None:
    """绑定主事件循环（须在主循环线程内调用；无运行循环时静默跳过）。"""
    global _MAIN_LOOP
    try:
        _MAIN_LOOP = asyncio.get_running_loop()
    except RuntimeError:
        pass


def _push_ws(user_id: str, message: Dict[str, Any]) -> None:
    """分发层（同步上下文）向用户推送一条 WS 消息。

    - 当前线程有运行中的事件循环：直接调度；
    - 工具线程/线程池：提交到绑定的主循环（``_bind_main_loop``）；
    - 无循环 / 无 ws_manager：静默跳过（推送失败不影响投递主流程）。
    """
    wsm = getattr(state, "ws_manager", None)
    if wsm is None:
        return
    try:
        coro = wsm.send_message(user_id, message)
    except Exception:  # noqa: BLE001
        return
    try:
        asyncio.get_running_loop().create_task(coro)
        return
    except RuntimeError:
        pass
    loop = _MAIN_LOOP
    if loop is not None and loop.is_running():
        try:
            asyncio.run_coroutine_threadsafe(coro, loop)
        except Exception:  # noqa: BLE001
            pass


def _store_message(
    user_id: str,
    agent_id: str,
    role: str,
    content: str,
    usage: Optional[Dict[str, Any]] = None,
    kind: str = "text",
    tool_name: Optional[str] = None,
    tool_arguments: Optional[Dict[str, Any]] = None,
    tool_result: Optional[str] = None,
    session_id: str = DEFAULT_SESSION,
) -> Dict[str, Any]:
    """保存一条消息到 SQLite 持久化历史。"""
    return store_message(
        user_id, agent_id, role, content,
        usage=usage, kind=kind,
        tool_name=tool_name, tool_arguments=tool_arguments,
        tool_result=tool_result, session_id=session_id,
    )


async def _register_tools(
    session: AgentLLMSession, agent_id: str, user_id: str = "",
    leader_id: str = "", team_id: str = "", member_system_prompt: str = "",
    session_id: str = DEFAULT_SESSION, is_member: bool = False,
    member_system_prompt_provider: Optional[Callable[[], str]] = None,
) -> None:
    """给会话注册内置工具（team / message / mcp / spec 等）。

    封装对 register_builtin_tools 的调用，避免重复展开 mcp_config 取值逻辑。
    同时把消息投递器与用户标识传给 team/message 工具，用于异步触发成员处理。
    并给会话挂上 compact 时的 system prompt 重建回调（spec「注入时机」：
    重构 context 时重建 system prompt，注入最新 Spec 索引/已选 Spec/memory/
    成员拓扑/MCP 工具清单）。

    :param member_system_prompt_provider: 可选，重建/刷新时现读成员
        system_prompt（经 team_store；update_member 修改后无需清会话，
        下次 compact 即生效）。缺省回退 ``member_system_prompt``。
    """
    mcp_config = get_config().get("mcp")
    # 合并 DB 持久化的外部 MCP 服务（REST /api/mcp/services 注册），
    # 与 config yaml 内置服务一起注册到 MCPManager（spec「MCP services CRUD」）
    try:
        from data.mcp_service_store import load_services_as_config

        db_services = load_services_as_config()
        if db_services:
            merged = dict(mcp_config or {})
            merged.update(db_services)
            mcp_config = merged
    except Exception as exc:  # noqa: BLE001
        logger.warning("加载 DB 外部 MCP 服务失败(忽略): %s", exc)
    workspace_id = getattr(session, "workspace_id", "") or ""

    # MCP 章节正文提供者：从会话级 mcp_manager 现算（不启动 stdio 子进程）。
    # 注意：register_builtin_tools 在本函数末尾才挂载 session.mcp_manager，
    # 此闭包是惰性的（compact 重建时才读取），顺序无碍。
    def _mcp_text_provider() -> str:
        return _build_mcp_tools_text(getattr(session, "mcp_manager", None))

    session.system_prompt_rebuilder = _make_system_prompt_rebuilder(
        workspace_id,
        member_system_prompt=member_system_prompt,
        user_id=user_id,
        agent_id=agent_id,
        team_id=team_id,
        session_id=session_id,
        member_system_prompt_provider=member_system_prompt_provider,
        mcp_text_provider=_mcp_text_provider,
    )

    # workspace_extra_info 刷新回调：每次 compact 刷新时现读现算
    # （identity/memory.md 均为最新；成员 system_prompt 经 provider 现读，
    # 避免会话构造时的一次性快照长期过期——memory.md 每次记忆维护都会更新）。
    def _extra_info_refresher() -> dict:
        member_prompt = member_system_prompt
        if member_system_prompt_provider is not None:
            try:
                member_prompt = (
                    member_system_prompt_provider() or member_system_prompt
                )
            except Exception as exc:  # noqa: BLE001
                logger.warning("刷新成员 system_prompt 失败(回退捕获值): %s", exc)
        return _build_workspace_extra_info(
            workspace_id,
            member_system_prompt=member_prompt,
            user_id=user_id,
            agent_id=team_id or agent_id,
            local_executor=state.local_executor,
        )

    # terminal hook 模式完成回调：后台命令结束后向发起该命令的 agent 投递
    # 一条 user 角色消息（带 [terminal hook] 前缀），经既有 broker 通道续跑
    # 同一会话，agent 据此读取输出文件继续推进任务。与 AskUserQuestion 的
    # resume_after_answer 唤醒通道一致（顶部 agent 走 top_chat_broker、
    # 成员走 team_broker）；source_agent_id 为空可避免 _dispatch_agent_message
    # 的"自发拒绝"（目标=自己）。
    def _terminal_hook_done(
        task_id: str,
        exit_code: int,
        output_file: str,
        cancelled: bool = False,
        error: str = "",
    ) -> None:
        tag = "取消" if cancelled else "结束"
        content = (
            f"[terminal hook] 你启动的后台命令已{tag}（exit_code={exit_code}），"
            f"输出已重定向到工作空间文件 {output_file}。"
            f"{('' if not error else ' ' + str(error))}"
            " 请读取该文件，根据结果继续推进你的任务。"
        )
        sender = getattr(session, "sender_id", "") or ""
        try:
            if is_member:
                _dispatch_agent_message(
                    user_id, [agent_id], content,
                    source_agent_id=team_id or agent_id,
                    team_id=team_id,
                    extra={"session_id": session_id, "sender_id": sender},
                    # 唤醒续跑属被动注入（Task 7.1）：不触发总结反向推送
                    active=False,
                )
            else:
                _dispatch_agent_message(
                    user_id, [agent_id], content, "",
                    team_id or agent_id, "", {"session_id": session_id},
                    active=False,
                )
        except Exception as exc:  # noqa: BLE001
            logger.exception(
                "terminal hook 唤醒 agent 失败: %s agent=%s", exc, agent_id
            )

    register_builtin_tools(
        session,
        docker_manager=state.docker_manager,
        model_configs=state.model_configs,
        mcp_config=mcp_config,
        broker=state.team_broker,
        user_id=user_id,
        ws_manager=state.ws_manager,
        agent_id=agent_id,
        leader_id=leader_id,
        team_id=team_id,
        local_executor=state.local_executor,
        message_dispatcher=_dispatch_agent_message,
        extra_info_refresher=_extra_info_refresher,
        session_id=session_id,
        is_member=is_member,
        terminal_hook_callback=_terminal_hook_done,
    )


def _make_system_prompt_rebuilder(
    workspace_id: str,
    member_system_prompt: str = "",
    user_id: str = "",
    agent_id: str = "",
    team_id: str = "",
    session_id: str = "",
    member_system_prompt_provider: Optional[Callable[[], str]] = None,
    mcp_text_provider: Optional[Callable[[], str]] = None,
) -> Any:
    """构造 compact（重构 context）时重建 system prompt 的同步回调。

    现读现算：.self 文档（identity/memory）、Spec 索引、已选 Spec 全文、
    成员拓扑均为最新。回调在后台线程（自动压缩）或 to_thread（手动 compact）
    中执行，其中读取 .self 经反向 WS（阻塞）不会卡死事件循环。

    :param member_system_prompt_provider: 可选，重建时现读成员 system_prompt
        （经 team_store，update_member 修改后无需清会话即可在下次 compact 生效）；
        缺省回退 ``member_system_prompt``（会话创建时捕获值）
    :param mcp_text_provider: 可选，重建时现算 MCP 工具清单章节正文
        （经 ``session.mcp_manager``，不启动 stdio 子进程）
    """
    def _resolve_member_prompt() -> str:
        if member_system_prompt_provider is not None:
            try:
                return member_system_prompt_provider() or member_system_prompt
            except Exception as exc:  # noqa: BLE001
                logger.warning("现读成员 system_prompt 失败(回退捕获值): %s", exc)
        return member_system_prompt

    def _rebuild() -> str:
        member_prompt = _resolve_member_prompt()
        extra_info = _build_workspace_extra_info(
            workspace_id,
            member_system_prompt=member_prompt,
            user_id=user_id,
            agent_id=team_id or agent_id,
            local_executor=state.local_executor,
        )
        mcp_text = ""
        if mcp_text_provider is not None:
            try:
                mcp_text = mcp_text_provider() or ""
            except Exception as exc:  # noqa: BLE001
                logger.warning("现算 MCP 工具清单失败(跳过章节): %s", exc)
        return _build_agent_system_prompt(
            workspace_id,
            member_system_prompt=member_prompt,
            user_id=user_id,
            agent_id=agent_id,
            team_id=team_id,
            session_id=session_id,
            extra_info=extra_info,
            mcp_tools_text=mcp_text,
        )
    return _rebuild


def _upload_attachments_local(base_dir: str, paths: Any) -> List[str]:
    """本地模式：把上传的本地文件写入 ``base_dir/.input/yyyymmdd/``。

    base_dir 是用户在本地执行模式下选择的工作目录（register_local_executor
    上报），与 agent 本地 read/write 工具的根一致——附件落地后 agent 即可
    通过相对路径 ``.input/yyyymmdd/name`` 读取。

    :param base_dir: 用户选择的本地工作目录
    :param paths: 用户上传的本地文件路径列表
    :return: 工作空间语义路径列表（如 ``/workspace/.input/20260808/xxx``）
    """
    date_dir = datetime.datetime.now().strftime("%Y%m%d")
    uploaded: List[str] = []
    for p in paths:
        path = str(p)
        if not os.path.isfile(path):
            logger.debug("附件不存在，跳过上传: %s", path)
            continue
        name = os.path.basename(path.replace("\\", "/"))
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError as exc:  # noqa: BLE001
            logger.warning("读取附件失败: %s (%s)", path, exc)
            continue
        rel_path = os.path.join(".input", date_dir, name)
        target = os.path.join(base_dir, rel_path)
        try:
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "wb") as f:
                f.write(data)
        except OSError as exc:  # noqa: BLE001
            logger.warning("附件写入本地工作空间失败: %s (%s)", name, exc)
            continue
        uploaded.append(f"/workspace/.input/{date_dir}/{name}")
    return uploaded


def _upload_attachments(
    workspace_id: str,
    paths: Any,
    user_id: str = "",
    team_id: str = "",
) -> List[str]:
    """将对话框上传的本地文件写入工作空间 ``.input/yyyymmdd/`` 目录。

    返回工作空间内的路径列表（如 ``/workspace/.input/20260808/xxx``）：
    - 本地模式（用户已注册本地执行器）：写入用户选择的本地工作目录
      ``base_dir/.input/yyyymmdd/``，与 agent 本地工具同一根目录；
    - 云端模式：写入 Docker 容器。Docker 不可用或文件不存在时跳过该文件。

    SSH 模式不在此处处理：附件须落在 SSH **远端主机**上（经前端执行器
    SFTP），由异步调用方按 ``resolve_mode == "ssh"`` 走
    :func:`_upload_attachments_ssh`（本函数不感知 SSH，防止误写云端）。

    写入失败仅记录日志，不中断。

    :param workspace_id: agent 工作空间标识
    :param paths: 用户上传的本地文件路径列表
    :param user_id: 用户标识（本地模式判定用）
    :param team_id: 顶部 agent 标识（本地模式判定用）
    :return: 成功写入工作空间的路径列表
    """
    if not paths:
        return []
    # 本地模式优先：附件落到用户选择的本地目录，否则云端容器里 agent
    # 本地工具根本读不到（表现为「提示已存入工作空间，实际无法访问」）。
    if user_id and team_id and state.local_executor is not None:
        try:
            if state.local_executor.is_local(user_id, team_id):
                base_dir = state.local_executor.base_dir_of(
                    user_id, team_id
                ) or ""
                if not base_dir:
                    logger.warning(
                        "本地执行器已注册但 base_dir 为空，附件跳过上传"
                    )
                    return []
                return _upload_attachments_local(base_dir, paths)
        except Exception as exc:  # noqa: BLE001
            logger.warning("附件本地上传判定失败，回退云端路径: %s", exc)
    if state.docker_manager is None or not state.docker_manager.available:
        return []
    date_dir = datetime.datetime.now().strftime("%Y%m%d")
    uploaded: List[str] = []
    for p in paths:
        path = str(p)
        if not os.path.isfile(path):
            logger.debug("附件不存在，跳过上传: %s", path)
            continue
        name = os.path.basename(path.replace("\\", "/"))
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError as exc:  # noqa: BLE001
            logger.warning("读取附件失败: %s (%s)", path, exc)
            continue
        container_path = f".input/{date_dir}/{name}"
        result = state.docker_manager.write_file(workspace_id, container_path, data)
        if result.get("exit_code") != 0 or "error" in result:
            logger.warning(
                "附件写入工作空间失败: %s (exit=%s, error=%s, detail=%s, stderr=%s)",
                name,
                result.get("exit_code"),
                result.get("error", ""),
                result.get("detail", ""),
                str(result.get("stderr", ""))[:200],
            )
            continue
        uploaded.append(f"/workspace/{container_path}")
    return uploaded


async def _upload_attachments_ssh(
    workspace_id: str,
    paths: Any,
    user_id: str = "",
    team_id: str = "",
) -> List[str]:
    """SSH 模式：把后端可读的附件内容转发前端 SSH 执行器，落盘**远端**。

    目标目录与本地/云端语义一致：前端 SSH 执行器把工作空间相对路径
    ``.input/yyyymmdd/name`` 映射到远端 ``remote_base_dir/.input/yyyymmdd/``
    （upload_file 经 SFTP 写入），附件落地后 agent 的 SSH 工具即可经相对路径
    ``.input/yyyymmdd/name`` 读取。

    仅在"该顶部 agent 处于 SSH 模式且执行器已注册（前端在线）"时执行：
    - 前端失联/未注册时记录 warning 并跳过，**不静默回退 Docker/云端**——
      与"锁定 SSH 模式绝不回落云端执行"的既有约定一致；
    - 后端无法按路径读到附件（如后端与用户文件不在同一台机器）时同样跳过
      并告警，交由文件面板的多字节上传通道兜底。

    :param workspace_id: agent 工作空间标识
    :param paths: 用户上传的本地文件路径列表
    :param user_id: 用户标识
    :param team_id: 顶部 agent 标识
    :return: 工作空间语义路径列表（如 ``/workspace/.input/20260906/xxx``）
    """
    if not paths:
        return []
    executor = state.local_executor
    ws_manager = getattr(state, "ws_manager", None)
    if executor is None or ws_manager is None:
        return []
    if not executor.is_ssh(user_id, team_id):
        logger.warning(
            "SSH 模式附件跳过上传：SSH 执行器未注册/前端失联"
            "（user_id=%s team_id=%s，模式锁定不变，等待重注册后重发）",
            user_id, team_id,
        )
        return []
    date_dir = datetime.datetime.now().strftime("%Y%m%d")
    uploaded: List[str] = []
    for p in paths:
        path = str(p)
        if not os.path.isfile(path):
            logger.debug("附件不存在，跳过上传: %s", path)
            continue
        name = os.path.basename(path.replace("\\", "/"))
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError as exc:  # noqa: BLE001
            logger.warning("读取附件失败: %s (%s)", path, exc)
            continue
        rel_path = f".input/{date_dir}/{name}"
        # executor.request 为阻塞式反向 WS 请求：放线程池执行，避免阻塞
        # 事件循环（否则 WS 接收无法处理 tool_exec_response 造成死锁）。
        result = await asyncio.to_thread(
            executor.request,
            ws_manager,
            user_id,
            {
                "op": "upload_file",
                "workspace_id": workspace_id,
                "rel_path": rel_path,
                "data_base64": base64.b64encode(data).decode("ascii"),
            },
            team_id=team_id,
        )
        if "error" in result:
            logger.warning(
                "附件写入 SSH 远端失败: %s (%s)", name, result.get("error"),
            )
            continue
        uploaded.append(f"/workspace/{rel_path}")
    return uploaded


def _build_attachments_prompt(paths: Any) -> str:
    """构建注入到 LLM 提示词的附件路径块。

    附件已由 ``_upload_attachments`` 写入工作空间，此处仅将路径告知 LLM，
    不再读取文件内容注入；LLM 如需内容再通过 read 工具读取。

    :param paths: 工作空间内的附件路径列表
    :return: 提示词片段；无文件时返回空字符串
    """
    if not paths:
        return ""
    lines: List[str] = ["[用户上传的文件，已存入工作空间，如需内容请用 read 工具读取]"]
    for p in paths:
        name = os.path.basename(str(p).replace("\\", "/"))
        lines.append(f"- {name}: {p}")
    return "\n".join(lines)


def _read_workspace_file(workspace_id: str, rel_path: str) -> str:
    """从工作空间读取文件内容（不存在或失败时返回空字符串）。"""
    if not workspace_id or state.docker_manager is None:
        return ""
    try:
        result = state.docker_manager.exec_in_workspace(
            workspace_id, ["cat", rel_path]
        )
        if result.get("exit_code", -1) != 0:
            return ""
        return result.get("stdout", "") or ""
    except Exception as exc:  # noqa: BLE001
        logger.warning("读取工作空间文件失败 %s/%s: %s", workspace_id, rel_path, exc)
        return ""


def _get_workspace_size(workspace_id: str) -> int:
    """获取工作空间已用字节数（查询失败返回 0）。"""
    if not workspace_id or state.docker_manager is None:
        return 0
    if state.docker_manager._use_local():
        # 本地模式：直接统计本地工作空间目录大小
        import os as _os

        local_workspace = state.docker_manager._local_workspace_path(workspace_id)
        if not local_workspace.exists():
            return 0
        total = 0
        for dirpath, _dirnames, filenames in _os.walk(str(local_workspace)):
            for fname in filenames:
                try:
                    total += _os.path.getsize(_os.path.join(dirpath, fname))
                except OSError:
                    continue
        return total
    try:
        result = state.docker_manager.exec_in_workspace(
            workspace_id, ["sh", "-c", "du -sb /workspace 2>/dev/null"]
        )
        if result.get("exit_code", -1) != 0:
            return 0
        out = result.get("stdout", "").strip()
        return int(out.split()[0]) if out else 0
    except Exception:  # noqa: BLE001
        return 0


# Spec 索引注入条数上限（超限提示用 spec search 取更多）
_SPEC_INDEX_LIMIT = 12


def _build_mcp_tools_text(mcp_manager: Any) -> str:
    """生成「⑩b MCP 工具与外部服务」章节文本（不启动 stdio 子进程）。

    进程内服务（workspace/document，server_factory + SDK 内存流）的工具已在
    会话注册期经 ``tools/list`` 发现并按 ``mcp__<服务名>__<工具名>`` 注入模型
    工具列表，这里直接从缓存列名；外部 stdio 服务只列服务名与工具数，完整
    清单由模型按需 ``mcp help`` 查询——prompt 构建/重建发生在会话创建与
    compact 时机，逐服务拉起子进程在 300+ agent 规模下不可接受。

    :param mcp_manager: 会话级 MCPManager（``session.mcp_manager``）
    :return: 章节正文；无可用服务/异常时返回空串（调用方跳过章节）
    """
    try:
        if mcp_manager is None:
            return ""
        services = mcp_manager.list_services()
        if not services:
            return ""
        lines: List[str] = []
        for name in services:
            service = getattr(mcp_manager, "services", {}).get(name) or {}
            in_process = service.get("server_factory") is not None
            if in_process:
                names = [
                    str(t.get("mcp_name") or t.get("name") or "")
                    for t in (service.get("tools", []) or [])
                ]
                names = [n for n in names if n]
                if names:
                    lines.append(f"- 服务 `{name}`（进程内）: {', '.join(names)}")
                else:
                    lines.append(f"- 服务 `{name}`（进程内）")
            else:
                tool_count = len(service.get("tools", []) or [])
                hint = f"（{tool_count} 个工具）" if tool_count else ""
                # 执行落点：隧道服务在宿主进程（本机 / 远端主机）拉起子进程，
                # 其余由后端进程直连；模型据此判断"第三方能力在谁的机器上跑"。
                tunnel = service.get("tunnel")
                if tunnel is not None:
                    host = "本机执行" if getattr(tunnel, "mode", "") == "local" else "远端主机执行"
                else:
                    host = "后端执行"
                lines.append(
                    f"- 服务 `{name}`{hint}（{host}）："
                    "工具列表用 `mcp` 工具的 help 动作查看"
                )
        if not lines:
            return ""
        return (
            "可用 MCP 服务与工具：\n" + "\n".join(lines) + "\n"
            "（进程内服务的工具已按 `mcp__<服务名>__<工具名>` 直接注入可用工具，"
            "可直接调用；其余服务的工具清单用 `mcp` 工具的 help 动作查询，"
            "再以 action=call、tool_name 为 `mcp__<服务名>__<工具名>` 调用）"
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("构建 MCP 工具清单章节失败(跳过): %s", exc)
        return ""


def _build_agent_system_prompt(
    workspace_id: str,
    member_system_prompt: str = "",
    user_id: str = "",
    agent_id: str = "",
    team_id: str = "",
    session_id: str = "",
    extra_info: Optional[Dict[str, Any]] = None,
    mcp_tools_text: str = "",
) -> str:
    """构建 agent 系统提示词：13 章节全量注入（spec「system prompt 内容」）。

    章节数据来自集中式版本化数据目录（``prompt/versions/<激活版本>/``，经
    ``prompt.versions`` 解析）：静态章节（角色权威/任务范式/安全护栏/工具路由/
    Spec 维护/todo 纪律/[Warning] 负责）随激活版本切换；动态章节（身份/memory/Spec
    索引/已选 Spec/执行模式/成员拓扑/MCP 工具清单）由本函数按会话现算注入。
    提示词顶部带审计头（版本+章节清单）。

    ① 身份与角色（.self/identity.md，默认顶层 Agent 说明；成员含 leader 设定）
    ② 角色权威与行为准则（core，注册表）
    ③ 任务执行范式（任务分型路由，注册表）
    ④ 安全与边界护栏（guardrail，注册表）
    ⑤ 需求→工具路由表（7 需求维度，注册表）
    ⑥ .self 文档注入（memory.md，超 4k 已由 _build_workspace_extra_info 压缩）
    ⑦ Spec 索引（内置 4 置顶 + 自定义，id/task_type/title/when 摘要）
    ⑧ 已选 Spec 全文（本会话挂 hook 的 Spec，注入 workflow/规范/注意事项全文）
    ⑨ 工作空间与执行模式（三模式 + shell 类型 + 存储软上限告警）
    ⑩ 成员拓扑与寻址规则（TOP + 全体成员；top 内按 name 寻址、跨 Top 顶层寻址、
       回复路径）
    ⑩b MCP 工具与外部服务（已注册服务/进程内工具名；stdio 服务提示 mcp help）
    ⑪ Spec 维护指引（何时应 search/select/create spec，注册表）
    ⑫ 任务进度管理纪律（todo 须增量更新，注册表）
    ⑬ 工具反馈 [Warning] 负责规则（[Warning] 必须严格关注并回应，注册表）

    :param workspace_id: 工作空间标识
    :param member_system_prompt: 成员专属系统提示词（leader 通过 update_member 设置）
    :param user_id: 用户标识
    :param agent_id: 当前 agent 的 ID
    :param team_id: 所属顶层 agent ID（顶层 agent 自身即 agent_id）
    :param session_id: 当前会话 ID（读取已选 Spec）
    :param extra_info: ``_build_workspace_extra_info`` 的输出（identity/memory/
                       exec_mode/storage_warning 等现算信息）
    :param mcp_tools_text: ``_build_mcp_tools_text`` 的输出（MCP 章节正文；
                           空串时不注入该章节）
    :return: 13 章节系统提示词
    """
    extra_info = extra_info or {}
    mode_key = team_id or agent_id
    chapters: List[str] = []

    # 审计头：版本 + 章节清单（可审计、可追溯）
    chapters.append(audit_header())

    # ① 身份与角色（动态）
    identity = str(extra_info.get("identity") or "").strip()
    if not identity:
        identity = "顶层 Agent（Level 0），直属用户，可创建并带领子团队。"
    identity_chapter = ["## ① 身份与角色", identity]
    if member_system_prompt:
        identity_chapter.append(f"\n角色分工（leader 设定）:\n{member_system_prompt}")
    chapters.append("\n".join(identity_chapter))

    # ②-⑤ 静态核心与护栏章节（角色权威/任务范式/安全护栏/工具路由）：来自注册表
    for chap in versions.active_system_head():
        chapters.append(f"## {chap.title}\n{chap.content}")

    # ⑥ .self 私人文档（memory.md；rule.md 已移除）
    memory = str(extra_info.get("memory") or "").strip()
    if memory:
        chapters.append("## ⑥ .self 私人文档（memory.md）\n" + memory)
    else:
        chapters.append(
            "## ⑥ .self 私人文档\n暂无 memory.md；任务完成/关键结论请维护到 "
            ".self/memory.md 供跨会话记忆。"
        )

    # ⑦ Spec 索引（内置 4 置顶 + 自定义）
    chapters.append(
        "## ⑦ Spec 索引（内置 4 置顶 + 自定义）\n" + _build_spec_index_text(agent_id)
    )

    # ⑧ 已选 Spec 全文（本会话挂 hook）
    selected_text = _build_selected_specs_text(
        workspace_id, user_id, mode_key, session_id
    )
    if selected_text:
        chapters.append("## ⑧ 已选 Spec 全文（本会话挂 hook）\n" + selected_text)

    # ⑨ 工作空间与执行模式
    exec_mode = str(extra_info.get("exec_mode") or "").strip()
    if exec_mode:
        chapter9 = "## ⑨ 工作空间与执行模式\n" + exec_mode
        storage_warning = str(extra_info.get("storage_warning") or "").strip()
        if storage_warning:
            chapter9 += "\n" + storage_warning
        chapters.append(chapter9)

    # ⑩ 成员拓扑与寻址规则（动态）
    chapters.append(
        _build_member_topology_text(workspace_id, user_id, mode_key)
    )

    # ⑩b MCP 工具与外部服务（动态，仅当有可用服务时注入；
    # 文本由调用方经 session.mcp_manager 现算，避免在此启动 stdio 子进程）
    if mcp_tools_text:
        chapters.append("## ⑩b MCP 工具与外部服务\n" + mcp_tools_text)

    # ⑪-⑬ 静态尾部章节（Spec 维护/todo 纪律/[Warning] 负责）：来自注册表
    for chap in versions.active_system_tail():
        chapters.append(f"## {chap.title}\n{chap.content}")

    return "\n\n".join(chapters)


def _build_spec_index_text(agent_id: str) -> str:
    """⑦ Spec 索引：内置 4 置顶 + 自定义 Spec（id/task_type/title/when 摘要），超限截断。"""
    try:
        from data.spec_store import list_specs

        specs = list_specs(agent_id=agent_id or None)
    except Exception as exc:  # noqa: BLE001
        logger.warning("构建 Spec 索引失败: %s", exc)
        return "（Spec 索引读取失败，可稍后用 spec list 查看）"
    if not specs:
        return "（暂无 Spec，任务完成前可用 spec create 沉淀）"
    lines: List[str] = []
    for s in specs[:_SPEC_INDEX_LIMIT]:
        when = "；".join(s.get("when") or [])
        if len(when) > 80:
            when = when[:80] + "…"
        line = f"- `{s['id']}` [{s.get('task_type', '')}] {s.get('title', '')}"
        # 标注内置模板（easy/complex/hard/team-meeting），与自定义 Spec 区分
        if s.get("builtin"):
            line += "（内置）"
        if when:
            line += f"（适用: {when}）"
        lines.append(line)
    if len(specs) > _SPEC_INDEX_LIMIT:
        lines.append(f"- …共 {len(specs)} 条，更多请用 spec search 检索")
    return "\n".join(lines)


def _read_spec_full_text(workspace_id: str, user_id: str, mode_key: str,
                         spec_id: str) -> str:
    """读取 Spec 全文：内置模板优先，其次工作空间 ``spec/<id>.md``（三模式通用）。"""
    from tool.spec_tool import _BUILTIN_DIR

    builtin_file = _BUILTIN_DIR / f"{spec_id}.md"
    if builtin_file.exists():
        return builtin_file.read_text(encoding="utf-8")
    io = _get_workspace_io(user_id, mode_key)
    if io is None:
        return _read_workspace_file(workspace_id, f"spec/{spec_id}.md")
    try:
        r = run_io(io.read_file(workspace_id, f"spec/{spec_id}.md"))
        if r.get("error"):
            return ""
        return str(r.get("content") or "")
    except Exception as exc:  # noqa: BLE001
        logger.warning("读取 Spec 全文失败 %s/%s: %s", workspace_id, spec_id, exc)
        return ""


def _build_selected_specs_text(
    workspace_id: str, user_id: str, mode_key: str, session_id: str
) -> str:
    """⑥ 已选 Spec 全文：本会话挂 hook 的 Spec 注入 workflow/规范/注意事项全文。"""
    if not (user_id and session_id):
        return ""
    try:
        from data.session_store import get_selected_spec_ids

        spec_ids = get_selected_spec_ids(user_id, session_id)
    except Exception as exc:  # noqa: BLE001
        logger.warning("读取已选 Spec 失败: %s", exc)
        return ""
    if not spec_ids:
        return ""
    blocks: List[str] = []
    for sid in spec_ids:
        content = _read_spec_full_text(workspace_id, user_id, mode_key, sid)
        if content.strip():
            blocks.append(f"### Spec: {sid}\n{content.strip()}")
    return "\n\n".join(blocks)


def _build_member_topology_text(
    workspace_id: str, user_id: str, mode_key: str
) -> str:
    """⑧ 成员拓扑与寻址规则：注入所属 TOP 的成员名单 + 寻址/回复路径规则。

    成员名单的权威来源是 ``team_members`` 表（P4 TOP 创建即全量建队），
    注入 name/role/duty/model_id/status（spec「成员拓扑常驻」）；
    未建队/旧数据时回退读取顶部 agent 工作空间的 ``.self/team_roster.md``。
    """
    members = _load_members_from_team_store(mode_key)
    roster = ""
    if not members:
        io = _get_workspace_io(user_id, mode_key)
        if io is not None:
            try:
                r = run_io(io.read_file(workspace_id, ".self/team_roster.md"))
                roster = "" if r.get("error") else (str(r.get("content") or ""))
            except Exception as exc:  # noqa: BLE001
                logger.warning("读取成员拓扑失败: %s", exc)
        if not roster.strip():
            roster = _read_workspace_file(workspace_id, ".self/team_roster.md")
        members = _parse_roster_table(roster) if roster.strip() else []

    lines = ["## ⑩ 成员拓扑与寻址规则"]
    if members:
        lines.append("当前团队成员（ID | 名称 | 角色 | 职责 | 模型 | 状态 | 层级 | 直属上级 | 可带队）:")
        for m in members:
            # 状态列注入**实际执行态**（基于 _active_tasks），
            # 不读表/roster 快照（避免假 working）
            mid = m.get("id", "")
            live_status = (
                "working"
                if (user_id and mid and _is_agent_working(user_id, mid))
                else "idle"
            )
            can_lead = m.get("can_lead_team", "")
            if can_lead is True or can_lead == 1:
                can_lead_text = "是"
            elif can_lead is False or can_lead == 0:
                can_lead_text = "否"
            else:
                can_lead_text = ""
            lines.append(
                f"- {mid} | {m.get('name', '')} | "
                f"{m.get('role', '')} | {m.get('duty', '')} | "
                f"{m.get('model_id', '')} | {live_status} | "
                f"L{m.get('level', 1)} | {m.get('parent_agent_id', '')} | "
                f"{can_lead_text}"
            )
    else:
        lines.append("当前为顶层 Agent，尚无成员（需要分工时：应用户要求经 "
                     "team create_member 建队，再用 message send_message 派活）。")
    lines.append("寻址规则:")
    lines.append("- 管理与通信已拆为两个工具：team 负责 list_models/list_teams/"
                 "list_members/create_member/query_member/update_member/query_status；"
                 "message 负责 send_message/broadcast/wait_for（list_members/list_teams "
                 "两个工具都可调用）。")
    lines.append("- 本团队内按成员名称（name）或成员 ID 寻址：先 team list_members "
                 "确认名单，用 message send_message 派活/沟通、wait_for 等待交付；"
                 "broadcast 只发给你的**直属成员**（不跨层级）。")
    lines.append("- 验收产出：直接 read 成员活动日志 "
                 "agentspace/{member_id}/.self/activity.log（每行带 "
                 "YYYY-MM-DD HH:MM:SS 时间戳，可 grep '[done]'/'[tool]' 定位产出）"
                 "及其工作目录内文件；team query_status 仅提供实时工作状态、"
                 "最后活动时间与日志路径。")
    lines.append("- 跨团队顶层沟通：先 team list_teams 熟悉本用户名下 TOP，向其他 "
                 "TOP agent 按 TOP 名称寻址，经 message send_message 投递（仅 TOP "
                 "本人可发起；成员需跨团队时请直属 leader 转达）。")
    lines.append("- 回复路径：成员→上级（TOP）；TOP→用户。成员不直接面向用户。")
    lines.append("- 派活前先 team list_members/query_member 核对：role/duty 为空时 "
                "用 team update_member 补充完善；model_id 为空会自动回退所属 "
                "TOP 模型（无需强制 update_member）。")
    return "\n".join(lines)


def _load_members_from_team_store(mode_key: str) -> List[Dict[str, Any]]:
    """从 ``team_members`` 表读取所属 TOP 的权威成员名单（含 role/duty）。

    ``mode_key`` 即顶部 agent ID（system prompt 构建时传 ``team_id or
    agent_id``）。名单为空或读取失败时返回空列表（调用方回退 roster 文件）。
    """
    try:
        from data.team_store import get_members

        return get_members(mode_key) or []
    except Exception as exc:  # noqa: BLE001
        logger.warning("从 team_store 读取成员拓扑失败: %s", exc)
        return []


def _build_exec_mode_text(
    workspace_id: str,
    user_id: str = "",
    agent_id: str = "",
    local_executor: Any = None,
) -> str:
    """构建执行模式说明文本（三模式 + shell 类型 + 工作空间位置），供 system prompt 注入。

    复用 ``io_.mode_resolver.describe_mode`` 透出三模式与 shell 类型（spec「shell
    类型透出」：cloud=Linux sh / local Windows=cmd.exe / local mac·linux=bash /
    ssh=远端 shell）。三种模式都给出成员与顶层共享的工作根（本地=用户 base_dir、
    云端=/workspace、ssh=远端 base）及本 agent 私人空间 .self 的**完整物理路径**
    ``{工作根}/agentspace/{workspace_id}/.self``：成员与顶层共享同一工作目录，
    agent 间 .self 相互可见，可直接用完整路径访问（Task 6 统一布局）。
    """
    from io_.mode_resolver import describe_mode, resolve_mode

    mode_key = agent_id or user_id or ""
    mode_text = ""
    if mode_key:
        try:
            mode_text = describe_mode(user_id, mode_key)
        except Exception:  # noqa: BLE001
            mode_text = ""
    if not mode_text:
        mode_text = "执行模式: 云端 Linux 容器。shell = sh (POSIX)，遵循 POSIX 命令语法。"

    mode = "cloud"
    try:
        mode = resolve_mode(user_id, mode_key)
    except Exception:  # noqa: BLE001
        mode = "cloud"

    if mode == "local":
        base_dir = ""
        if local_executor is not None:
            try:
                base_dir = local_executor.base_dir_of(user_id, mode_key) or ""
            except Exception:  # noqa: BLE001
                base_dir = ""
        root = base_dir or "<用户选择目录>"
    elif mode == "ssh":
        remote_base = ""
        try:
            if state.ssh_manager is not None:
                cfg = state.ssh_manager.get_config(user_id, mode_key) or {}
                remote_base = cfg.get("remote_base_dir") or ""
        except Exception:  # noqa: BLE001
            remote_base = ""
        root = remote_base or "<远端工作目录>"
    else:
        root = "/workspace"
    ws_self = f"{root}/agentspace/{workspace_id}/.self"
    return (
        f"{mode_text}；成员与顶层共享工作目录 {root}，各 agent 的私人空间 .self "
        f"位于 {ws_self}（agent 间 .self 相互可见，可用该完整路径直接读写）；"
        "工作文件也在该工作目录下，直接在此读写协作。"
    )


# .self 文档（memory.md / rule.md）注入大小上限（字符数）：未超限时全量注入
# help 的 workspace_extra_info，超限时经 LLM 压缩为摘要再注入，控制 help 输出
# 体积与 token 成本。
_SELF_DOC_INJECT_LIMIT = 4096
# .self 文档压缩结果缓存：doc_key -> (内容指纹, 压缩文本)。
# 文档未变化时直接复用缓存，避免重复触发 LLM 压缩。
_self_doc_compress_cache: Dict[str, Tuple[str, str]] = {}


def _compress_self_doc(workspace_id: str, doc_key: str, text: str,
                       kind: str = "记忆档案") -> str:
    """.self 文档（memory.md / rule.md）超过注入上限时压缩为中文摘要。

    优先调用 LLM 压缩（复用默认模型配置，失败回退）；回退方案为保头保尾截断。
    带指纹缓存：文档内容未变化时直接返回缓存结果。

    :param workspace_id: 工作空间标识
    :param doc_key: 文档标识（如 "memory.md" / "rule.md"），用于缓存区分
    :param text: 文档全文
    :param kind: 文档种类名（用于压缩提示词，如 记忆档案 / 工作准则）
    """
    cache_key = f"{workspace_id}:{doc_key}"
    digest = hashlib.md5(text.encode("utf-8")).hexdigest()
    cached = _self_doc_compress_cache.get(cache_key)
    if cached and cached[0] == digest:
        return cached[1]

    compressed = ""
    try:
        from llm.llm import LLMClientFactory

        model_id = next(iter(state.model_configs), "")
        cfg = state.model_configs.get(model_id) if model_id else None
        if cfg is not None:
            client = LLMClientFactory.create_client(cfg)
            resp = client.chat.completions.create(
                model=cfg.api_model_id or cfg.model_id,
                messages=[{
                    "role": "user",
                    "content": (
                        f"你是文档压缩器。以下是一份 agent 的{kind}文档（{doc_key}），"
                        f"共 {len(text)} 字，超过单次注入上限。"
                        "请压缩成 4000 字以内的中文摘要，保留：任务目标与最新要求、"
                        "关键决策、遇到的问题及解决方案、重要结论、待办事项。"
                        "不要逐条复述原文，保留必要事实（文件名、路径、数字、结论）。\n\n"
                        f"文档内容：\n{text[:12000]}"
                    ),
                }],
                temperature=0.2,
                max_tokens=1024,
            )
            if resp.choices:
                compressed = (resp.choices[0].message.content or "").strip()
    except Exception as exc:  # noqa: BLE001
        logger.warning("%s 压缩失败(%s)，回退截断: %s", doc_key, workspace_id, exc)
        compressed = ""

    if not compressed:
        # 回退方案：保留头部与尾部，中间省略（保留最新轮次与最早基线）
        compressed = (
            text[:1800].rstrip()
            + "\n\n...[文档超长已截断，省略中间内容]...\n\n"
            + text[-1600:].lstrip()
        )
    _self_doc_compress_cache[cache_key] = (digest, compressed)
    return compressed


def _get_workspace_io(user_id: str, agent_id: str) -> Any:
    """构建与内置工具一致的 WorkspaceIO 通道（经 ModeResolver 三模式统一判定）。

    本地模式经反向 WS 到前端本地执行器，由前端把 workspace 相对路径映射到
    用户选择的 base_dir（顶层与成员共享，.self → base_dir/agentspace/{workspace_id}/.self）；
    SSH 模式由前端发起 SSH 连接、经反向 WS 委托前端执行；云端模式走 Docker 容器。
    用于读 .self 文档时与内置工具（read/write/edit/terminal）保持同一路径语义，
    避免双轨制（记忆维护写本地 base_dir，help 注入却读 Docker 容器）导致
    memory/rule 注入读到旧内容或缺失。
    """
    from io_.mode_resolver import build_workspace_io

    try:
        return build_workspace_io(user_id, agent_id)
    except Exception as exc:  # noqa: BLE001
        logger.warning("构建模式 WorkspaceIO 失败，回退云端: %s", exc)
    from io_.workspace_io import CloudWorkspaceIO

    return CloudWorkspaceIO(state.docker_manager)


def _make_result_redirect_writer(
    workspace_id: str, user_id: str, agent_id: str,
) -> Callable[[str, str], None]:
    """构造工具结果重定向写入器：把超长工具结果写入 .self 私有目录。

    与内置工具共用同一 WorkspaceIO 通道（三模式统一），保证 .self
    路径语义一致（本地 baseDir / 云端容器 / SSH）。由 LLM 会话在
    工具结果超过门控阈值时调用，写入失败由 llm.py 侧退化截断兜底。
    """
    io = _get_workspace_io(user_id, agent_id)

    def _writer(rel_path: str, content: str) -> None:
        run_io(io.write_file(workspace_id, rel_path, content))

    return _writer


def _build_workspace_extra_info(
    workspace_id: str,
    member_system_prompt: str = "",
    user_id: str = "",
    agent_id: str = "",
    local_executor: Any = None,
) -> dict:
    """构建工作空间额外信息，供 system prompt 章节注入（身份/memory/执行模式/存储告警）。

    覆盖原 checklist 6 / 9 / 10 / 15：
    - 6(c) 身份：从 ``.self/identity.md`` 读取 team / level / team leader / 是否开团队
    - 10   memory.md：注入 ``.self/memory.md`` 内容（超 4k 压缩为摘要）
    - 15    存储软上限：工作空间接近 ``upload.sandbox_max_size`` 时提示清理

    :param workspace_id: 工作空间标识
    :param member_system_prompt: 成员专属系统提示词
    :return: 包含身份、memory、exec_mode、存储告警等信息的字典
    """
    info: Dict[str, Any] = {}

    # 统一 IO 通道读 .self 文档：与内置工具同路径语义（本地 baseDir/云端容器），
    # 保证 memory/rule/identity 注入读到的是 agent 实际写入的私人空间文件。
    _io = _get_workspace_io(user_id, agent_id)

    def _read_self_doc(rel_path: str) -> str:
        if _io is not None:
            try:
                r = run_io(_io.read_file(workspace_id, rel_path))
                content = r.get("content")
                if content is not None and not r.get("error"):
                    return str(content) or ""
            except Exception as exc:  # noqa: BLE001
                logger.warning("io 读取 %s 失败，回退 docker: %s", rel_path, exc)
        return _read_workspace_file(workspace_id, rel_path)

    # 执行模式（本地 vs 云端沙箱）：让 agent 无需猜测自己的工作环境。
    # 本地执行器按顶部 agent 注册（mode_key=team_id；顶部 agent 自身即 agent_id）。
    exec_mode = _build_exec_mode_text(
        workspace_id, user_id=user_id, agent_id=agent_id,
        local_executor=local_executor,
    )
    if exec_mode:
        info["exec_mode"] = exec_mode

    # 身份信息（checklist 6(c)）
    identity = _read_self_doc(".self/identity.md").strip()
    if identity:
        info["identity"] = identity
    else:
        info["identity"] = "顶层 Agent（Level 0），直属用户，可创建并带领子团队。"

    # 成员专属系统提示词（如有）
    if member_system_prompt:
        info["member_system_prompt"] = member_system_prompt

    # memory.md 注入：全量优先，超过大小上限时压缩为摘要后再注入。
    # compact 触发上下文重构时现读现算，避免依赖会话构造时的一次性快照。
    # （rule.md 已按 spec 从设计移除，不再注入。）
    memory = _read_self_doc(".self/memory.md").strip()
    if memory:
        if len(memory) <= _SELF_DOC_INJECT_LIMIT:
            info["memory"] = memory
        else:
            info["memory"] = _compress_self_doc(
                workspace_id, "memory.md", memory, "记忆档案"
            )

    # 存储软上限告警（checklist 15）
    try:
        upload_cfg = get_config().get("upload", {})
        sandbox_max = _parse_size(upload_cfg.get("sandbox_max_size"), 1024 ** 3)
    except Exception:  # noqa: BLE001
        sandbox_max = 1024 ** 3
    if sandbox_max > 0:
        used = _get_workspace_size(workspace_id)
        if used > 0:
            ratio = used / sandbox_max
            if ratio >= 0.85:
                info["storage_warning"] = (
                    f"工作空间已使用 {used/1024/1024:.0f}MB "
                    f"（上限 {sandbox_max/1024/1024:.0f}MB，约 {ratio*100:.0f}%）。"
                    "请清理不再需要的文件，避免达到上限影响后续工作。"
                )

    return info


async def _send_status_idle(
    user_id: str, agent_id: str, session_id: str = DEFAULT_SESSION
) -> None:
    """发送 agent 恢复 idle 状态。"""
    await state.ws_manager.send_message(
        user_id,
        {
            "type": "agent_status",
            "data": {
                "agent_id": agent_id,
                "status": "idle",
                "session_id": session_id,
            },
        },
    )


def _reset_member_work_status(
    user_id: str, leader_id: str, member_id: str, session_id: str = DEFAULT_SESSION
) -> None:
    """成员 tool loop 结束后复位其持久化 work_status 为 idle。

    【状态治理】工作状态不再由 leader/roster/表写入——成员是否在工作的
    唯一权威是 ``_active_tasks``（实际 tool loop 登记）：``_process_member_
    message`` 真正开始 chat 前登记、结束时清除，前端经 WS ``agent_status``
    事件感知，teammates API 的 ``live_status`` 亦基于 ``_active_tasks`` 实时
    计算。故本函数保留为兼容占位（不再写任何持久化状态）。
    """
    return


async def _send_status_working(
    user_id: str, agent_id: str, session_id: str = DEFAULT_SESSION
) -> None:
    """发送 agent 进入 working 状态。"""
    await state.ws_manager.send_message(
        user_id,
        {
            "type": "agent_status",
            "data": {
                "agent_id": agent_id,
                "status": "working",
                "session_id": session_id,
            },
        },
    )


async def _send_text_as_agent(
    user_id: str, agent_id: str, text: str, session_id: str = DEFAULT_SESSION
) -> None:
    """将一段文本作为普通 agent 消息发送（用于错误提示等）。

    同时将这条 agent 回复写入对话历史，避免切换窗口后丢失。
    """
    _store_message(user_id, agent_id, "agent", text, session_id=session_id)
    await state.ws_manager.send_message(
        user_id,
        {
            "type": "message",
            "id": agent_id,
            "role": "agent",
            "content": text,
            "timestamp": int(asyncio.get_event_loop().time() * 1000),
            "session_id": session_id,
        },
    )


# 活动日志写入阈值：流式文本累积达到该长度后 flush 一次到工作空间日志
_ACTIVITY_FLUSH_CHARS = 300


# 进行中的 agent 任务取消事件表：(user_id, agent_id, session_id) -> Event。
# 前端点击"停止"时，WS 端点 set 对应事件，chat 消费线程在每条产出后检查并退出。
_active_tasks: Dict[Tuple[str, str, str], threading.Event] = {}


def _register_active_task(
    user_id: str, agent_id: str, session_id: str = DEFAULT_SESSION
) -> threading.Event:
    """登记一个进行中的任务，返回取消事件。"""
    event = threading.Event()
    _active_tasks[(user_id, agent_id, session_id)] = event
    return event


def _cancel_active_task(
    user_id: str, agent_id: str, session_id: Optional[str] = None
) -> bool:
    """请求取消指定 agent/会话的进行中任务。

    :param session_id: 指定会话；None 时取消该 agent 第一个进行中任务
                       （兼容旧前端 stop 不携带 session_id）
    """
    if session_id is not None:
        event = _active_tasks.get((user_id, agent_id, session_id))
    else:
        event = next(
            (
                ev
                for (uid, aid, _sid), ev in _active_tasks.items()
                if uid == user_id and aid == agent_id
            ),
            None,
        )
    if event is None:
        return False
    event.set()
    return True


def _clear_active_task(
    user_id: str, agent_id: str, session_id: str = DEFAULT_SESSION
) -> None:
    """任务结束时清除取消事件登记。"""
    _active_tasks.pop((user_id, agent_id, session_id), None)


# 进行中的上下文压缩登记表：(user_id, agent_id, session_id)。
# compact 是长时间操作（LLM 总结，本地模型可能数分钟），期间：
# - 前端经 WS agent_status=compacting 显示「压缩中」状态；
# - 同会话禁止并发 compact（防双击）与消息处理（防与 compress 并发改写
#   session.context）。镜像 _active_tasks 的登记/清理/查询模式。
_compacting_tasks: "Set[Tuple[str, str, str]]" = set()


def _register_compacting_task(
    user_id: str, agent_id: str, session_id: str = DEFAULT_SESSION
) -> None:
    """登记一个进行中的上下文压缩。"""
    _compacting_tasks.add((user_id, agent_id, session_id))


def _clear_compacting_task(
    user_id: str, agent_id: str, session_id: str = DEFAULT_SESSION
) -> None:
    """压缩结束（含失败）时注销登记。"""
    _compacting_tasks.discard((user_id, agent_id, session_id))


def _is_agent_compacting(
    user_id: str, agent_id: str, session_id: Optional[str] = None
) -> bool:
    """该 agent 是否正在压缩上下文。

    :param session_id: 指定会话；None 时检查该 agent 是否有任意会话在压缩
    """
    if session_id is not None:
        return (user_id, agent_id, session_id) in _compacting_tasks
    return any(
        uid == user_id and aid == agent_id
        for (uid, aid, _sid) in _compacting_tasks
    )


def _is_agent_working(user_id: str, agent_id: str) -> bool:
    """该 agent 是否有任意会话处于进行中（teammates 状态展示用）。"""
    return any(
        uid == user_id and aid == agent_id
        for (uid, aid, _sid) in _active_tasks
    )


def _count_active_agents(user_id: str) -> int:
    """统计该用户当前"正在工作"的不同 agent 数量（并发执行数）。

    _active_tasks 以 (user_id, agent_id, session_id) 为键，同一 agent 的
    多个会话只算一个并发名额，故按 agent_id 去重计数。
    """
    return len({aid for (uid, aid, _sid) in _active_tasks if uid == user_id})


def _concurrency_limit_reached(user_id: str) -> Tuple[bool, int]:
    """判断该用户是否已达并发执行 agent 数上限。

    按等级配置 ``max_concurrent_agents`` 限制：common 4 / pro 12 /
    ultra 72 / beta 500；<=0 或缺失 = 不限。

    :return: (是否已达上限, 当前并发数)；不限时返回 (False, 0)。
    """
    active = _count_active_agents(user_id)
    # 惰性 import：chat.py 较大，避免顶层新增依赖引起循环导入
    #（user_store / config.levels 均不反向 import chat，可安全在函数内 import）
    from data.user_store import get_user_level
    from config.levels import get_level_config

    try:
        level = get_user_level(user_id)
        cfg = get_level_config(level)
        limit = int(cfg.get("max_concurrent_agents", 0) or 0)
    except Exception as exc:  # noqa: BLE001
        # 等级读取失败（如 DB 异常）时按"不限"放行，避免并发门禁阻断正常投递
        logger.warning("读取用户并发上限失败，按不限处理 user=%s: %s", user_id, exc)
        return False, 0
    if limit <= 0:
        return False, 0
    return active >= limit, active


def _cancel_all_agent_tasks(
    user_id: str, agent_id: str
) -> List[Tuple[str, str, str]]:
    """取消指定 agent 的全部进行中任务（所有会话），返回已取消的键列表。

    与 ``_cancel_active_task``（单会话）不同，停止级联需要把 TOP agent 与
    其下全部成员**所有会话**的进行中任务一次性取消，避免只停当前窗口会话
    而其他会话的任务仍在跑。
    """
    cancelled: List[Tuple[str, str, str]] = []
    for (uid, aid, sid), event in list(_active_tasks.items()):
        if uid == user_id and aid == agent_id:
            event.set()
            cancelled.append((uid, aid, sid))
    return cancelled


def _reset_member_status_to_idle(
    user_id: str, top_id: str, member_id: str
) -> None:
    """（已废弃）成员工作状态复位占位。

    【状态治理】工作状态唯一权威是 ``_active_tasks``（实际 tool loop 登记），
    不再写入 team_members 表 / roster 持久态。停止 = 取消
    ``_active_tasks`` 中的任务 + 清空 broker 队列；成员 tool loop 的 finally
    会 ``_clear_active_task`` 并推送 ``agent_status=idle``，前端/API 状态
    自然回到 idle。保留本函数仅为兼容调用方，不再写任何持久化状态。
    """
    return


async def _stop_agent_tree(
    user_id: str,
    agent_id: str,
    session_id: Optional[str] = None,
) -> Dict[str, Any]:
    """停止按钮级联：停止指定 agent（TOP 或成员）及其全部相关任务。

    若 ``agent_id`` 为 TOP agent（agent_store 可查）：
    - 取消 TOP 自身全部进行中任务（所有会话，不止当前会话）
    - 查出其全部成员（``team_members`` 表），逐一取消成员全部进行中任务
    - 清空 ``top_chat_broker`` 中该 TOP 的排队用户消息、``team_broker`` 中
      各成员的排队消息（防止队列里残留的消息在停止后把成员又拉起来工作）
    - 向前端推送 TOP 与全部成员的 ``agent_status=idle``，UI 立即停止标识
      （工作状态唯一权威是 ``_active_tasks``，不写入表/roster）

    若 ``agent_id`` 为成员（不在 agent_store）：
    - 仅取消该成员任务、清空其 broker 队列、复位 idle

    关于「立即中止」的边界（如实说明）：
    - API 调用：取消事件在流式分块间隙、下一轮调用发起前、429 重试等待期、
      限流等待期均被检查，因此**不会再发起新的 API 调用**；正在进行的流式
      响应在下一个 chunk 到达即中止。
    - 工具调用：每次 tool_call 执行前检查取消，**不再启动新工具**；但正在
      阻塞执行的同步工具（如长 terminal 命令）无法从外部强杀 Python 线程，
      需等其返回后循环在检查点退出（属正常边界，已写入活动日志提示）。

    :return: ``{"stopped": bool, "cancelled": [...], "members": [...]}``
    """
    cancelled: List[Tuple[str, str, str]] = []
    member_ids: List[str] = []

    # 判断是否为 TOP agent（agent_store 可查即 TOP）
    from data.agent_store import get_agent

    is_top = get_agent(user_id, agent_id) is not None

    # 1) 取消 agent 自身全部任务
    cancelled += _cancel_all_agent_tasks(user_id, agent_id)

    if is_top:
        # 2) 查出成员并取消其全部任务
        try:
            from data.team_store import get_members

            members = get_members(agent_id) or []
        except Exception as exc:  # noqa: BLE001
            logger.warning("停止级联读取成员失败: %s", exc)
            members = []
        member_ids = [m.get("id", "") for m in members if m.get("id")]
        for mid in member_ids:
            cancelled += _cancel_all_agent_tasks(user_id, mid)

        # 3) 清空排队消息：TOP 的用户消息 + 各成员的 leader 消息
        try:
            if state.top_chat_broker is not None:
                state.top_chat_broker.cancel_agent(user_id, agent_id)
        except Exception as exc:  # noqa: BLE001
            logger.warning("停止级联清空 TOP 队列失败: %s", exc)
        if state.team_broker is not None:
            for mid in member_ids:
                try:
                    state.team_broker.cancel_agent(user_id, mid)
                except Exception as exc:  # noqa: BLE001
                    logger.warning("停止级联清空成员队列失败 %s: %s", mid, exc)

        # 4) 推送 idle：TOP + 全部成员。成员工作状态无需写表——tool loop 的
        #    finally 会 _clear_active_task（_active_tasks 为唯一权威），
        #    此处推送 idle 让前端 UI 立即停止标识。
        for mid in [agent_id] + member_ids:
            await state.ws_manager.send_message(
                user_id,
                {
                    "type": "agent_status",
                    "data": {
                        "agent_id": mid,
                        "status": "idle",
                        "session_id": session_id,
                    },
                },
            )
    else:
        # 成员：清空其 broker 队列 + 推送 idle
        if state.team_broker is not None:
            try:
                state.team_broker.cancel_agent(user_id, agent_id)
            except Exception as exc:  # noqa: BLE001
                logger.warning("停止级联清空成员队列失败 %s: %s", agent_id, exc)
        await state.ws_manager.send_message(
            user_id,
            {
                "type": "agent_status",
                "data": {
                    "agent_id": agent_id,
                    "status": "idle",
                    "session_id": session_id,
                },
            },
        )

    return {
        "stopped": bool(cancelled) or bool(member_ids),
        "cancelled": cancelled,
        "members": member_ids,
    }


def _clock_now() -> str:
    """返回 ``YYYY-MM-DD HH:MM:SS`` 时间戳（服务器本地时间），用于活动日志。

    带日期以便跨天判断成员产出时间；旧日志行可能只有 HH:MM:SS（legacy）。
    """
    return time.strftime("%Y-%m-%d %H:%M:%S")


# 活动日志单文件字符上限（超出后只保留尾部，read-modify-write 通道用）
_ACTIVITY_LOG_MAX_CHARS = 200_000


def _append_activity_log(
    workspace_id: str, message: str,
    user_id: str = "", mode_key: str = "",
) -> None:
    """将一行活动日志追加写入 agent 工作空间的 ``.self/activity.log``。

    统一工作目录后，leader 直接 read 成员日志文件
    （``agentspace/{member_id}/.self/activity.log``）查看成员活动与产出。
    - 记录带日期时间戳（YYYY-MM-DD HH:MM:SS），便于判断最后活动/产出时间
    - **本地反向 WS / SSH 模式**：经与内置工具一致的统一 IO 通道
      read-modify-write 追加（前端执行器映射 ``.self`` →
      baseDir/agentspace/{workspace_id}/.self），避免 docker 可用时日志
      错落到云端容器；mode 按 (user_id, 所属 TOP mode_key) 判定
    - **云端模式/兜底**：容器内 base64 安全 ``>>`` 追加（exec_in_workspace
      兼容层把 ``.self`` 令牌改写为 agentspace/{workspace_id}/.self）

    :param mode_key: 运行模式归属键（所属 TOP agent id）；成员传 team_id，
                     顶层传自身 id。为空时按云端兜底路径处理
    """
    if not workspace_id:
        return
    line = message if message.endswith("\n") else message + "\n"

    # 非云端模式：统一 IO 通道（三模式与内置工具同路径语义）
    if user_id and mode_key:
        try:
            if resolve_mode(user_id, mode_key) in ("local", "ssh"):
                io = _get_workspace_io(user_id, mode_key)
                r = run_io(io.read_file(workspace_id, ".self/activity.log"))
                existing = "" if r.get("error") else str(r.get("content") or "")
                content = existing + line
                if len(content) > _ACTIVITY_LOG_MAX_CHARS:
                    # 超上限只保留尾部（按字符截断，可能切断首行，可接受）
                    content = content[-_ACTIVITY_LOG_MAX_CHARS:]
                w = run_io(io.write_file(
                    workspace_id, ".self/activity.log", content
                ))
                if not w.get("error"):
                    return
                logger.warning("统一 IO 写活动日志失败，回退 docker 通道")
        except Exception as exc:  # noqa: BLE001
            logger.warning("统一 IO 写活动日志异常，回退 docker 通道: %s", exc)

    # 云端/兜底：base64 安全追加，避免特殊字符导致命令注入或转义问题
    try:
        import base64 as _b64

        b64 = _b64.b64encode(line.encode("utf-8")).decode("ascii")
        cmd = [
            "sh",
            "-c",
            "mkdir -p .self && echo '{}' | base64 -d >> .self/activity.log".format(
                b64
            ),
        ]
        state.docker_manager.exec_in_workspace(workspace_id, cmd)
    except Exception as exc:  # noqa: BLE001
        logger.warning("写入活动日志失败: %s", exc)


def _new_seg_id(agent_id: str) -> str:
    """生成一条段（文本消息/工具卡片）的唯一 id。"""
    return f"{agent_id}_{int(time.time() * 1000)}_{uuid.uuid4().hex[:6]}"


async def _stream_agent_reply(
    user_id: str,
    agent_id: str,
    workspace_id: str,
    session: Any,
    llm_content: str,
    on_tool_turn: Optional[Any] = None,
    cancel_event: Optional[threading.Event] = None,
    silent: bool = False,
    session_id: str = DEFAULT_SESSION,
    team_id: str = "",
) -> Tuple[str, str]:
    """在后台线程中运行 chat 循环，并向前端实时推送进度事件。

    解决"工作期间其他 API 卡住"的问题：LLM 流式调用与工具执行为同步阻塞，
    若直接在主线程遍历会独占事件循环。这里把生成器消费放到独立线程
    （``asyncio.to_thread``），通过线程安全的 ``asyncio.Queue`` 把产出
    传递回事件循环，逐条推送以下 WS 事件：

    - ``agent_status``：由调用方负责发送 working/idle（本函数不发）。
    - ``text`` 产出：以"段"为单位，先发 ``msg_start`` 再逐块 ``msg_chunk``，
      段结束时发 ``msg_end``（每一次中间输出独立成一条消息）。
    - ``tool_call`` 产出：先发 ``tool_start``（含参数），工具执行完成后在
      同一产出内发 ``tool_end``（含结果），前端据此渲染可折叠卡片。
    - 取消：检测到 ``cancel_event`` 置位时提前退出，返回 cancelled。

    :param silent: 静默模式。为 True 时不向前端推送任何 WS 事件（文本段、
                   工具卡片、历史持久化均跳过），仅执行工具与写活动日志，
                   用于后台记忆更新阶段。
    :return: ``(full_text, status, last_text_id)``，status 为 ``"ok"`` /
             ``"cancelled"`` / ``"error"``；``last_text_id`` 为结束时仍打开的
             文本段 id（可能为 None），供调用方在确定 usage 后补发 ``msg_usage``。
    """
    loop = asyncio.get_running_loop()
    # 顺带绑定主事件循环：分发层从工具线程推送 WS（session_created /
    # 总结反向推送）时经 run_coroutine_threadsafe 线程安全提交
    _bind_main_loop()
    out_q: "asyncio.Queue[Dict[str, Any]]" = asyncio.Queue()

    def _consume() -> None:
        """线程内消费 chat 生成器，产出经线程安全方式回传事件循环。"""
        try:
            for item in session.chat(llm_content, on_tool_turn=on_tool_turn, cancel_event=cancel_event):
                if cancel_event is not None and cancel_event.is_set():
                    loop.call_soon_threadsafe(out_q.put_nowait, {"type": "cancelled"})
                    return
                loop.call_soon_threadsafe(out_q.put_nowait, item)
        except asyncio.CancelledError:
            loop.call_soon_threadsafe(out_q.put_nowait, {"type": "cancelled"})
        except _AskPaused:
            # AskUserQuestion 暂停：不视为错误，通知主循环置"已提问待答"
            loop.call_soon_threadsafe(
                out_q.put_nowait, {"type": "ask_paused"}
            )
        except Exception as exc:  # noqa: BLE001
            logger.exception("chat 消费线程异常")
            # 将 OpenAI 限流错误格式化为可读提示，避免前端展示原始异常串
            if isinstance(exc, RateLimitError):
                content = "请求被限流（429），请稍后重试。"
            else:
                content = str(exc)
            loop.call_soon_threadsafe(
                out_q.put_nowait, {"type": "error", "content": content}
            )
        finally:
            loop.call_soon_threadsafe(out_q.put_nowait, {"type": "done"})

    thread_task = asyncio.create_task(asyncio.to_thread(_consume))

    full_parts: List[str] = []
    text_parts: List[str] = []  # 当前文本段的累积内容
    text_id: Optional[str] = None
    # 最后一次工具调用摘要（纯 tool loop 无文字输出时，兜底为回复内容推送
    # 给上一级 leader，避免成员完成工作后 leader 收不到任何结果）
    last_tool_text = ""
    # thinking（推理）段累积：每段独立 id，收到非 thinking 产出时关闭并持久化
    thinking_parts: List[str] = []
    thinking_id: Optional[str] = None
    flush_buf = ""
    status = "ok"

    def _close_thinking() -> None:
        """结束当前 thinking 段（msg_end + 持久化 kind='thinking'）。"""
        nonlocal thinking_id, thinking_parts
        if thinking_id is None:
            return
        thinking_text = "".join(thinking_parts)
        if not silent:
            asyncio.ensure_future(
                state.ws_manager.send_message(
                    user_id,
                    {
                        "type": "msg_end",
                        "id": thinking_id,
                        "agent_id": agent_id,
                        "session_id": session_id,
                    },
                )
            )
        # 持久化 thinking 段（messages 表 kind='thinking'），历史重载后可见
        if (not silent) and thinking_text.strip():
            try:
                _store_message(
                    user_id, agent_id, "agent", thinking_text,
                    kind="thinking", session_id=session_id,
                )
            except Exception:  # noqa: BLE001
                pass
        thinking_id = None
        thinking_parts = []

    def _close_text() -> None:
        """结束当前文本段（中间输出独立成一条消息，结束时不带 usage）。

        中间文本段持久化到历史表，重启后可通过 get_history 恢复。
        """
        nonlocal text_id, text_parts
        if text_id is not None:
            if not silent:
                asyncio.ensure_future(
                    state.ws_manager.send_message(
                        user_id,
                        {
                            "type": "msg_end",
                            "id": text_id,
                            "agent_id": agent_id,
                            "session_id": session_id,
                        },
                    )
                )
            # 持久化中间文本段（非最终回复）；静默阶段不写入历史
            intermediate_text = "".join(text_parts)
            if (not silent) and intermediate_text.strip():
                try:
                    _store_message(
                        user_id, agent_id, "agent", intermediate_text,
                        session_id=session_id,
                    )
                except Exception:  # noqa: BLE001
                    pass
            text_id = None
            text_parts = []

    try:
        while True:
            item = await out_q.get()
            itype = item.get("type")
            if itype == "done":
                break
            if itype == "cancelled":
                status = "cancelled"
                break
            if itype == "error":
                status = "error"
                full_parts.append(item.get("content", ""))
                break
            if itype == "ask_paused":
                # AskUserQuestion 已提问，本轮暂停（agent 归闲，等用户作答后唤醒）
                _close_thinking()
                _close_text()
                status = "paused"
                if flush_buf and workspace_id:
                    _append_activity_log(
                        workspace_id, f"[{_clock_now()}] {flush_buf}",
                        user_id=user_id, mode_key=team_id or agent_id,
                    )
                    flush_buf = ""
                break
            if itype == "thinking":
                content = item.get("content", "")
                thinking_parts.append(content)
                if not silent:
                    if thinking_id is None:
                        thinking_id = _new_seg_id(agent_id)
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "msg_start",
                                "id": thinking_id,
                                "role": "agent",
                                "kind": "thinking",
                                "agent_id": agent_id,
                                "session_id": session_id,
                            },
                        )
                    await state.ws_manager.send_message(
                        user_id,
                        {
                            "type": "msg_chunk",
                            "id": thinking_id,
                            "agent_id": agent_id,
                            "session_id": session_id,
                            "chunk": content,
                        },
                    )
                continue
            if itype == "text":
                # 文本段开始前关闭未完成的 thinking 段
                _close_thinking()
                content = item.get("content", "")
                full_parts.append(content)
                text_parts.append(content)
                if not silent:
                    if text_id is None:
                        text_id = _new_seg_id(agent_id)
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "msg_start",
                                "id": text_id,
                                "role": "agent",
                                "agent_id": agent_id,
                                "session_id": session_id,
                            },
                        )
                    await state.ws_manager.send_message(
                        user_id,
                        {
                            "type": "msg_chunk",
                            "id": text_id,
                            "agent_id": agent_id,
                            "session_id": session_id,
                            "chunk": content,
                        },
                    )
                if workspace_id:
                    flush_buf += content
                    if len(flush_buf) >= _ACTIVITY_FLUSH_CHARS:
                        _append_activity_log(
                            workspace_id, f"[{_clock_now()}] {flush_buf}",
                            user_id=user_id, mode_key=team_id or agent_id,
                        )
                        flush_buf = ""
            elif itype == "tool_call":
                # 结束上一段文本与 thinking（中间输出独立成消息）
                _close_thinking()
                _close_text()
                name = item.get("name", "")
                args = item.get("arguments") or {}
                result = item.get("result", "")
                # 记录最后一次工具调用摘要（结果截断，避免超长）
                last_tool_text = f"[工具 {name}] {str(result)[:500]}"
                if workspace_id:
                    _append_activity_log(
                        workspace_id,
                        f"[{_clock_now()}] [tool] {name} args="
                        f"{str(args)[:200]} -> {str(result)[:150]}",
                        user_id=user_id, mode_key=team_id or agent_id,
                    )
                flush_buf = ""
                if not silent:
                    tool_id = _new_seg_id(agent_id)
                    await state.ws_manager.send_message(
                        user_id,
                        {
                            "type": "tool_start",
                            "id": tool_id,
                            "agent_id": agent_id,
                            "session_id": session_id,
                            "name": name,
                            "arguments": args,
                        },
                    )
                    await state.ws_manager.send_message(
                        user_id,
                        {
                            "type": "tool_end",
                            "id": tool_id,
                            "agent_id": agent_id,
                            "session_id": session_id,
                            "name": name,
                            "result": str(result),
                        },
                    )
                    # 持久化工具调用到历史表；静默阶段不写入历史
                    try:
                        _store_message(
                            user_id, agent_id, "agent", "",
                            kind="tool",
                            tool_name=name,
                            tool_arguments=args if isinstance(args, dict) else {},
                            tool_result=str(result),
                            session_id=session_id,
                        )
                    except Exception:  # noqa: BLE001
                        pass

                    # 工具循环中持续推送 token 用量：本轮 LLM 调用已产生新的
                    # last_usage，立即同步给前端，让「上下文长度」统计在 tool 循环
                    # 中持续跟进，而非等最终回复结束才一次性更新。
                    if getattr(session, "last_usage", None):
                        _mc = getattr(session, "model_config", None)
                        mid_max = (
                            int(_mc.extra.get("max_seqlen", 8192))
                            if _mc is not None else 8192
                        )
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "msg_usage",
                                "id": tool_id,
                                "agent_id": agent_id,
                                "session_id": session_id,
                                "usage": {**session.last_usage, "max_tokens": mid_max},
                            },
                        )
            else:
                # 未知产出类型，忽略
                continue
    finally:
        await thread_task
        # 结束未关闭的 thinking 段（msg_end + 持久化）
        _close_thinking()
        if flush_buf and workspace_id:
            _append_activity_log(
                workspace_id, f"[{_clock_now()}] {flush_buf}",
                user_id=user_id, mode_key=team_id or agent_id,
            )

    # 结束时仍打开的文本段即最终回复，交由调用方补发 msg_usage
    last_text_id = text_id
    # 纯 tool loop 无文字输出兜底：status=ok 且无任何文本时，用最后一次
    # 工具调用摘要作为回复内容（_process_member_message 据此推送给 leader）。
    if (
        status == "ok"
        and not full_parts
        and last_tool_text
    ):
        full_parts.append(f"（本轮无文字输出，最后执行：{last_tool_text}）")
    return "".join(full_parts), status, last_text_id


async def _process_member_message(
    payload: Dict[str, Any], queue: Optional[asyncio.Queue] = None
) -> None:
    """处理投递给成员的消息（leader 通过 message send_message/broadcast 触发）。

    每个成员由 broker 的独立 worker 串行调用本函数。消息不在双方的
    tool_call / token 生成执行中途打断，而是在当前消息的 tool_call 间隙
    通过 ``on_tool_turn`` 回调切入处理新消息（append 到上下文供下一轮处理）。
    成员处理过程中的文字输出写入其工作空间活动日志
    （agentspace/{member_id}/.self/activity.log），leader 直接 read 判断进度。

    :param payload: 投递负载，含 user_id / agent_id / workspace_id /
                    model_id / content
    :param queue: 该成员的消息队列（broker worker 传入），用于在 tool_call
                  间隙切入新消息
    """
    user_id = payload.get("user_id", "")
    agent_id = payload.get("agent_id", "")
    workspace_id = payload.get("workspace_id", "")
    model_id = payload.get("model_id", "")
    content = payload.get("content", "")
    leader_id = payload.get("leader_id", "")
    team_id = payload.get("team_id", "")
    session_id = payload.get("session_id", DEFAULT_SESSION)
    # 真正触发本条处理的发送方：agent 发送 = 该 agent（上级/平级/下级均可）；
    # 用户直发 = 空串（成员总结不转发给任何 agent）。key 存在（含空串）即用之，
    # key 缺失才回退 leader_id（兼容无 sender_id 的老负载）。
    sender_id = payload.get("sender_id")
    if sender_id is None:
        sender_id = payload.get("leader_id", "")
    if not agent_id or not content:
        return

    model_config = state.model_configs.get(model_id)
    if model_config is None and not model_id and team_id:
        # 空 model_id 自动回退所属 TOP 的模型：建队默认继承 TOP 模型，
        # 此处兼容历史空 model_id 成员（无论从哪条投递路径进入，都不因
        # 模型缺失丢消息）。
        try:
            top_rec = get_agent(user_id, team_id) or {}
            top_model = top_rec.get("model_id") or ""
            if top_model and top_model in state.model_configs:
                model_config = state.model_configs[top_model]
                model_id = top_model
        except Exception as exc:  # noqa: BLE001
            logger.warning("成员空 model_id 回退 TOP 模型失败: %s", exc)
    if model_config is None:
        _append_activity_log(
            workspace_id,
            f"[{_clock_now()}] [error] 成员模型不存在: {model_id!r}，"
            "消息未处理（leader 需先用 team update_member 为该成员设置 model_id）",
            user_id=user_id, mode_key=team_id or agent_id,
        )
        # 明确回传错误给发送方（仅当发送方是 agent；用户直发不转发任何 agent），
        # 避免消息被静默丢弃（表现为"成员没收到"）
        if not is_user_sender(sender_id):
            try:
                _dispatch_agent_message(
                    user_id,
                    [sender_id],
                    f"[成员 {agent_id} 无法处理消息] 未配置 LLM 模型"
                    f"（model_id={model_id!r}），消息已丢弃：{content[:120]}。"
                    "请用 team update_member 为该成员设置 model_id 后重试。",
                    source_agent_id=agent_id,
                    team_id=team_id or sender_id,
                    extra={"auto_reply": True, "session_id": session_id},
                )
            except Exception as exc:  # noqa: BLE001
                logger.warning("回传成员模型缺失错误失败: %s", exc)
        return

    # 保存成员收到的消息到历史（teammates 进度页可加载显示）
    _store_message(user_id, agent_id, "user", content, session_id=session_id)

    # 构建成员会话（normal 复用缓存累积上下文）
    # 系统提示词 9 章节全量注入（Spec 索引/已选 Spec/.self 文档/成员拓扑）
    # + MCP 工具清单章节（⑩b）
    member_system_prompt = payload.get("system_prompt", "")
    session = get_session(user_id, agent_id, session_id)

    def _member_prompt_provider() -> str:
        """现读成员 system_prompt（经 team_store）。

        update_member 修改提示词后**不清空成员上下文**，本 provider 使成员
        下次 compact 重建（system_prompt_rebuilder）即用新提示词；读取失败
        回退本条消息投递时捕获的 member_system_prompt。
        """
        try:
            from data.team_store import get_member

            rec = get_member(team_id or agent_id, agent_id)
            if rec:
                return str(rec.get("system_prompt") or "")
        except Exception as exc:  # noqa: BLE001
            logger.warning("现读成员 system_prompt 失败(回退捕获值): %s", exc)
        return member_system_prompt

    if session is None:
        # 先建空会话并注册工具（register_builtin_tools 挂载 session.mcp_manager），
        # 再构建含 MCP 工具清单章节的系统提示词快照
        session = AgentLLMSession(
            model_config=model_config,
            workspace_id=workspace_id,
            user_id=user_id,
            agent_id=agent_id,
            result_redirect_writer=_make_result_redirect_writer(
                workspace_id, user_id, team_id or agent_id
            ),
        )
        set_session(user_id, agent_id, session, session_id)
        try:
            await _register_tools(
                session, agent_id, user_id,
                leader_id=leader_id,
                team_id=team_id,
                member_system_prompt=member_system_prompt,
                session_id=session_id,
                is_member=True,
                member_system_prompt_provider=_member_prompt_provider,
            )
        except Exception:
            # 工具注册失败：清掉半成品会话，避免下次消息拿到无工具会话
            pop_session(user_id, agent_id, session_id)
            raise
        # 本地模式下读 .self 文件经反向 WS（阻塞），必须放入线程池避免死锁事件循环
        extra_info = await asyncio.to_thread(
            _build_workspace_extra_info,
            workspace_id, member_system_prompt=member_system_prompt,
            user_id=user_id, agent_id=team_id or agent_id,
            local_executor=state.local_executor,
        )
        mcp_text = _build_mcp_tools_text(
            getattr(session, "mcp_manager", None)
        )
        enhanced_prompt = await asyncio.to_thread(
            _build_agent_system_prompt,
            workspace_id,
            member_system_prompt=member_system_prompt,
            user_id=user_id,
            agent_id=agent_id,
            team_id=team_id,
            session_id=session_id,
            extra_info=extra_info,
            mcp_tools_text=mcp_text,
        )
        session.system_prompt = enhanced_prompt
        session.context = [{"role": "system", "content": enhanced_prompt}]
        session.workspace_extra_info = extra_info
        restored = load_context(user_id, agent_id, session_id)
        if restored:
            session.context = restored

    # 记录本条消息的发送方：供 AskUserQuestion 在提问时持久化溯源，
    # 并由中途插入的消息实时更新为"最后发送方"（见 _pick_incoming）。
    session.sender_id = sender_id

    _append_activity_log(
        workspace_id,
        f"[{_clock_now()}] [start(成员)] 收到 leader 消息: {content[:120]}",
        user_id=user_id, mode_key=team_id or agent_id,
    )

    # 成员最终总结的回发目标：默认 = 本条消息的发送方；中途切入新消息时
    # 更新为最后一位发送方（feature：自动回复仅回给最后发给它的那位）。
    reply_sender = sender_id

    def _pick_incoming() -> Optional[str]:
        """在 tool_call 间隙从队列切入 leader 发来的新消息。"""
        nonlocal reply_sender
        if queue is None:
            return None
        try:
            incoming = queue.get_nowait()
        except queue.Empty:
            return None
        # 跨会话隔离：只切入当前会话的消息；其他会话的消息放回队列，
        # 待当前消息处理完后由 worker 作为独立消息继续处理（不串入本会话上下文）
        incoming_session = incoming.get("session_id", DEFAULT_SESSION)
        if incoming_session != session_id:
            queue.put_nowait(incoming)
            return None
        incoming_content = incoming.get("content", "")
        if not incoming_content:
            return None
        # 更新"最后发送方"：插入的新消息到来时，把最终总结的回发目标切换为
        # 这条新消息的发送方（feature：自动回复仅回给最后发给它的那位）。
        inc_sender = incoming.get("sender_id")
        if inc_sender is None:
            inc_sender = incoming.get("leader_id", "")
        reply_sender = inc_sender
        session.sender_id = inc_sender
        _append_activity_log(
            workspace_id,
            f"[{_clock_now()}] [切入] 收到 leader 新消息: "
            f"{incoming_content[:120]}",
            user_id=user_id, mode_key=team_id or agent_id,
        )
        return incoming_content

    # SFT 数据收集：记录该轮处理前的上下文基线（与 TOP 路径一致，含 CoT 的
    # 完整 context 在成员处理结束后与基线求 diff）。收集开关按用户生效，
    # 成员数据以 (user_id, member_id, session_id) 分键存储，与 TOP 互不覆盖。
    context_before = list(session.context)

    # 登记任务并通知用户该成员进入 working 状态（teammates 窗口可见）
    cancel_event = _register_active_task(user_id, agent_id, session_id)
    await state.ws_manager.send_message(
        user_id,
        {"type": "agent_status", "data": {"agent_id": agent_id, "status": "working",
                                           "session_id": session_id}},
    )
    try:
        full_reply, _status, _last = await _stream_agent_reply(
            user_id,
            agent_id,
            workspace_id,
            session,
            content,
            on_tool_turn=_pick_incoming,
            cancel_event=cancel_event,
            session_id=session_id,
            team_id=team_id,
        )
        # 关闭最终文本段（无 usage）
        if _last:
            await state.ws_manager.send_message(
                user_id,
                {"type": "msg_end", "id": _last, "agent_id": agent_id,
                 "usage": None, "session_id": session_id},
            )
        # 保存成员回复到历史（teammates 进度页可加载显示）
        if full_reply:
            _store_message(user_id, agent_id, "agent", full_reply,
                           session_id=session_id)
        _append_activity_log(
            workspace_id, f"[{_clock_now()}] [done(成员)] 回复完成",
            user_id=user_id, mode_key=team_id or agent_id,
        )
        # 成员工具循环最后一次回复的 content 自动回发"最后将消息发给它的那位"
        # （用户直发时为 USER_AGENT_ID/空串 → 不转发任何 agent，仅留在成员
        # 会话/teammates 窗口）
        if full_reply and not is_user_sender(reply_sender):
            try:
                _dispatch_agent_message(
                    user_id,
                    [reply_sender],
                    f"[成员 {agent_id} 完成回复] {full_reply}",
                    source_agent_id=agent_id,
                    team_id=team_id or reply_sender,
                    extra={"auto_reply": True, "session_id": session_id},
                )
            except Exception as exc:  # noqa: BLE001
                logger.warning("成员回复回传 leader 失败: %s", exc)
    except Exception as exc:  # noqa: BLE001
        logger.exception("成员消息处理失败: %s", exc)
        _append_activity_log(
            workspace_id, f"[{_clock_now()}] [error] 成员处理失败: {exc}",
            user_id=user_id, mode_key=team_id or agent_id,
        )
    finally:
        # 状态治理：工作状态唯一权威是 _active_tasks——此处清除任务登记并
        # 推送 idle，前端/API 状态立即回到空闲；不再写 roster/表/内存态。
        _clear_active_task(user_id, agent_id, session_id)
        await _send_status_idle(user_id, agent_id, session_id)

    # 持久化上下文（成员回复已实时写入工作空间活动日志，供 leader 查看）
    try:
        save_context(user_id, agent_id, session.context, session_id=session_id)
    except Exception as exc:  # noqa: BLE001
        logger.warning("成员上下文持久化失败: %s", exc)
    # SFT 数据收集：仅开启期间生效；把本轮新增消息（含 CoT）作为 diff 累加
    # 到该成员会话快照（agent_type=member 标注样本来源）。带 try 避免收集
    # 异常影响主流程。
    try:
        collect_sft_turn(
            user_id, agent_id, session_id,
            context_before, session.context,
            agent_type="member",
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("成员 SFT 收集失败: %s", exc)


async def _broker_process_user_message(
    payload: Dict[str, Any], queue: Optional[asyncio.Queue] = None
) -> None:
    """顶部 agent 用户消息 broker 处理函数（checklist 7）。

    适配 TeamMessageBroker 的 ``(payload, queue)`` 签名，转发给真正的
    处理函数 ``_handle_user_message``。
    """
    user_id = payload.get("user_id", "")
    await _handle_user_message(user_id, payload, queue)


def _find_roster_member(
    user_id: str, roster_owner_id: str, member_id: str
) -> Optional[Dict[str, Any]]:
    """从指定 agent 的成员名单中查找成员（team 跨模式）。

    优先读 ``team_members`` 表（P4 建队后的权威名单，cloud/local/ssh 一致），
    表为空（未建队/旧数据）时回退解析工作空间 ``.self/team_roster.md``。
    成员记录补充 system_prompt 字段（表中有、文件视图无），供投递时使用。
    """
    if not roster_owner_id or not member_id:
        return None

    # 权威来源：team_store（teams/team_members 表）
    from data.team_store import get_member as get_team_member

    try:
        db_member = get_team_member(roster_owner_id, member_id)
    except Exception:  # noqa: BLE001
        db_member = None
    if db_member is not None:
        return {
            "id": db_member["id"],
            "name": db_member["name"],
            "model_id": db_member.get("model_id", ""),
            "level": db_member.get("level", 1),
            "created_at": db_member.get("created_at", ""),
            "work_status": db_member.get("work_status", "idle"),
            "comment": db_member.get("comment", ""),
            "role": db_member.get("role", ""),
            "duty": db_member.get("duty", ""),
            "system_prompt": db_member.get("system_prompt", ""),
            "workspace_id": db_member["id"],
        }

    # 回退：工作空间 roster 文件（未走 P4 建队的历史数据）
    owner = get_agent(user_id, roster_owner_id) or {}
    owner_ws = owner.get("workspace_id") or roster_owner_id
    # 本地模式下经反向 WS 读用户本机的 .self/team_roster.md（与 help 注入同路径）
    _io = _get_workspace_io(user_id, roster_owner_id)
    try:
        r = run_io(_io.read_file(owner_ws, ".self/team_roster.md"))
        roster_content = "" if r.get("error") else (r.get("content", "") or "")
    except Exception:  # noqa: BLE001
        roster_content = _read_workspace_file(owner_ws, ".self/team_roster.md")
    members = _parse_roster_table(roster_content)
    for m in members:
        if m.get("id") == member_id:
            return m
    return None


def _session_title_from_content(content: str) -> str:
    """用首条消息内容生成会话标题（首行/前 30 字符，空内容回退默认标题）。"""
    text = (content or "").strip().replace("\n", " ").strip()
    if not text:
        return "新会话"
    return text[:30] + ("…" if len(text) > 30 else "")


def _ensure_receiver_session(
    user_id: str, agent_id: str, session_id: str, content: str
) -> None:
    """接收方会话保障（Task 7.2）：消息送达接收 agent 前确保会话元数据存在。

    会话行缺失时以首条消息摘要为标题创建（sessions 表主键含 agent_id，
    同一会话 id 可被发起方与接收方各自持有元数据行），并通过 WS 推送
    ``session_created`` 会话元数据，使前端（无需重新拉取会话列表）即时
    纳入展示；跨 team（TOP↔TOP）与用户直发同样保障。
    """
    sid = session_id or DEFAULT_SESSION
    try:
        if get_session_record(user_id, sid, agent_id=agent_id) is not None:
            return
        title = _session_title_from_content(content)
        create_session(user_id, agent_id, title=title, session_id=sid)
        _push_ws(
            user_id,
            {
                "type": "session_created",
                "data": {
                    "agent_id": agent_id,
                    "session_id": sid,
                    "title": title,
                },
            },
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("接收方会话保障失败(不影响投递): %s agent=%s", exc, agent_id)


def _get_last_summary(user_id: str, agent_id: str, session_id: str) -> str:
    """取接收 agent 指定会话的"最后总结"：最近一条 assistant 文本消息。

    优先读内存会话上下文（session_cache），缺失时回退持久化上下文
    （conversation_store.load_context）。纯工具调用轮（assistant 消息
    content 为空）向前跳过；无总结返回空串。
    """
    context: Any = None
    session = get_session(user_id, agent_id, session_id)
    if session is not None:
        context = getattr(session, "context", None)
    if not context:
        try:
            context = load_context(user_id, agent_id, session_id) or []
        except Exception:  # noqa: BLE001
            context = []
    for msg in reversed(context):
        if not isinstance(msg, dict) or msg.get("role") != "assistant":
            continue
        content = msg.get("content")
        if isinstance(content, str) and content.strip():
            return content.strip()
    return ""


def _maybe_push_last_summary(
    user_id: str,
    target_id: str,
    source_agent_id: str,
    owner_top: str,
    session_id: str,
) -> None:
    """总结反向推送（Task 7.1，显式化）：active 消息触达已有总结的目标时，
    复用消息发送接口把目标最近一轮的 assistant 总结回发给发起方。

    - 仅 agent 主动发起（active=true 且非用户直发、非 auto_reply 被动
      通道）触发；推送消息自身标记 active=false，不会级联触发反向推送
      （防循环）；
    - 仅做"给发起方看的上下文恢复"，不改变目标 agent 的处理逻辑；
      成员完成回复的既有回发链路（reply_sender）保持不变。
    """
    if is_user_sender(source_agent_id) or source_agent_id == target_id:
        return
    summary = _get_last_summary(user_id, target_id, session_id)
    if not summary:
        return
    try:
        _dispatch_agent_message(
            user_id,
            [source_agent_id],
            f"[{target_id} 最近总结] {summary}",
            source_agent_id=target_id,
            team_id=owner_top or target_id,
            extra={"auto_reply": True, "session_id": session_id},
            # 推送消息标记 active=false：接收方不再级联反向推送
            active=False,
        )
    except Exception as exc:  # noqa: BLE001
        logger.warning("总结反向推送失败: %s target=%s", exc, target_id)


def _dispatch_agent_message(
    user_id: str,
    target_ids: Any,
    content: str,
    source_agent_id: str = "",
    team_id: str = "",
    system_prompt: str = "",
    extra: Optional[Dict[str, Any]] = None,
    active: bool = True,
) -> Dict[str, Any]:
    """统一消息发送 API：对本顶部 agent 旗下任意 agent_id 发送消息（一对多）。

    User-Agent 与 Agent-Agent 消息都收敛到本入口（顶部 agent 走
    ``state.top_chat_broker``，团队成员走 ``state.team_broker``），统一做：
    - 团队隔离：仅允许发送给与本 agent 有关系的对象（上级 leader / 直属成员），
      不同顶部 agent 旗下互不可见、不可达；
    - update memory 锁：目标正处于记忆维护时拒绝投递；
    - 目标解析：顶部 agent 经 agent_store 查询；成员经发送方 roster 解析；
    - 接收方会话保障（Task 7.2）：目标会话元数据缺失时创建并推送
      ``session_created``；
    - 总结反向推送（Task 7.1）：active=true 的 agent 主动发起消息触达
      已有"最后总结"的目标时，把总结回发给发起方（推送消息标记
      active=false，防循环；用户直发与 auto_reply 被动通道不触发）。

    :param active: 消息是否为主动发起（默认 true）。被动推送（auto_reply、
                   唤醒续跑等）传 false，不触发总结反向推送。
    """
    active = bool(active)
    if isinstance(target_ids, str):
        target_ids = [target_ids]
    # ID 存在性校验（Task 2）：user_id 与归属（team_id/发送方）必须非空，
    # 缺失记日志并拒绝，绝不静默降级继续投递。
    if not user_id or not (team_id or source_agent_id):
        logger.error(
            "_dispatch_agent_message 缺少必需 ID，拒绝投递: user_id=%r "
            "team_id=%r source_agent_id=%r targets=%r",
            user_id, team_id, source_agent_id, target_ids,
        )
        return {"error": "缺少 user_id 或 team_id，消息未投递"}
    if not target_ids or not content:
        return {"error": "目标 ID 或消息内容不能为空"}

    owner_top = team_id or source_agent_id or ""
    sent: List[str] = []
    rejected: List[str] = []
    # 因用户并发执行上限被拒绝的 target（Task 7：按用户等级限制并发 agent 数）
    concurrency_limited: List[str] = []
    # auto_reply（agent 侧自动回复）消息跳过并发检查，防止递归拒绝/误伤
    # 既有 auto_reply 通道（成员模型缺失回传、成员完成回传等）。
    is_auto_reply = bool((extra or {}).get("auto_reply"))
    # 投递负载按 session_id 归集（缺省回退默认会话）；接收方会话保障与
    # 总结反向推送均按该会话定位。
    session_id = str((extra or {}).get("session_id") or "") or DEFAULT_SESSION
    for target_id in target_ids:
        if not target_id or target_id == source_agent_id:
            rejected.append(target_id)
            continue

        # 并发执行上限检查（Task 7）：
        # - 仅当目标当前未在 working（这条消息会使其新进入 working、新增并发名额）才检查；
        #   已 working 的目标消息只是入队，不新增并发，直接放行。
        # - 用户直发（source_agent_id 为用户标记）命中上限时拒绝投递（由
        #   _dispatch_user_message 提示用户）；agent→agent 命中上限时以
        #   auto_reply 方式回发 429 给发送方。
        if not is_auto_reply and not _is_agent_working(user_id, target_id):
            # 注意：此处解包变量名为 active_count，勿用 active——active 是
            # 本函数的"主动发起"参数（Task 7.1），随负载透传。
            limit_reached, active_count = _concurrency_limit_reached(user_id)
            if limit_reached:
                concurrency_limited.append(target_id)
                if not is_user_sender(source_agent_id):
                    _reply_session = (extra or {}).get(
                        "session_id", DEFAULT_SESSION
                    )
                    try:
                        _dispatch_agent_message(
                            user_id,
                            [source_agent_id],
                            f"[成员 {target_id} 无法处理] 当前并发任务已达上限"
                            f"（{active_count} 个），请稍等片刻再试。",
                            source_agent_id=target_id,
                            team_id=team_id or source_agent_id,
                            extra={
                                "auto_reply": True,
                                "session_id": _reply_session,
                            },
                        )
                    except Exception as exc:  # noqa: BLE001
                        logger.warning("回传并发限制 429 错误失败: %s", exc)
                continue

        # 1) 目标为顶部 agent（agent_store 中可查）
        target_agent = get_agent(user_id, target_id)
        if target_agent is not None:
            # 团队隔离：
            # - 成员向其他顶部 agent 发送被拒绝（跨顶部顶层通信仅限 TOP agent 之间）；
            # - TOP agent（source == owner_top）可向任意同用户 TOP 寻址（top-to-top）。
            # 目标经 get_agent(user_id) 查询，天然限同用户（跨用户不开放）。
            # 用户直发（source 为用户标记）不做隔离检查（原空串行为保持）。
            if (
                not is_user_sender(source_agent_id)
                and owner_top
                and source_agent_id != owner_top
                and target_id != owner_top
            ):
                rejected.append(target_id)
                continue
            payload = {
                "user_id": user_id,
                "agent_id": target_id,
                "workspace_id": target_agent.get("workspace_id") or target_id,
                "model_id": target_agent.get("model_id") or "",
                "system_prompt": system_prompt,
                "leader_id": "",
                "team_id": target_id,
                "content": content,
            }
            if extra:
                payload.update(extra)
            # active 随负载透传（接收侧不消费；是否触发总结反向推送由发送层判定）
            payload["active"] = active
            # 接收方会话保障（Task 7.2）：broker 消费前确保会话元数据存在
            # 并推送 session_created（跨 team TOP↔TOP 与用户直发同样保障）
            _ensure_receiver_session(user_id, target_id, session_id, content)
            dispatched = False
            if state.top_chat_broker is not None:
                dispatched = state.top_chat_broker.dispatch(
                    (user_id, target_id), payload
                )
            if dispatched:
                sent.append(target_id)
                # 总结反向推送（Task 7.1）：active 主动发起且非被动通道时触发
                if active and not is_auto_reply:
                    _maybe_push_last_summary(
                        user_id, target_id, source_agent_id, owner_top, session_id
                    )
            else:
                rejected.append(target_id)
            continue

        # 2) 目标为成员：从发送方（或所属顶部 agent）roster 查找直属成员
        member = _find_roster_member(
            user_id, team_id or source_agent_id, target_id
        )
        if member is None:
            rejected.append(target_id)
            continue
        # 成员 model_id 为空时回退所属 TOP 的模型：建队默认继承 TOP 模型，
        # 此处兼容历史空 model_id 成员，避免消息被 _process_member_message
        # 因"模型不存在"静默丢弃（成员"收不到"消息）。
        member_model = member.get("model_id") or ""
        if not member_model and owner_top:
            try:
                top_rec = get_agent(user_id, owner_top) or {}
                member_model = top_rec.get("model_id") or ""
            except Exception:  # noqa: BLE001
                member_model = ""
        payload = {
            "user_id": user_id,
            "agent_id": target_id,
            "workspace_id": member.get("workspace_id") or target_id,
            "model_id": member_model,
            "system_prompt": member.get("system_prompt", "") or system_prompt,
            # 用户直发时直属 leader 仍为所属 TOP（保持空串时代行为）
            "leader_id": (
                team_id if is_user_sender(source_agent_id)
                else source_agent_id or team_id
            ),
            "team_id": owner_top,
            # 真正触发本条处理的发送方（可被调用方经 extra 显式覆盖：用户直发
            # =USER_AGENT_ID、续跑=原发送方、团队工具缺省=source_agent_id=
            # 发送的 agent）。
            "sender_id": (
                USER_AGENT_ID if is_user_sender(source_agent_id)
                else source_agent_id or team_id
            ),
            "content": content,
        }
        if extra:
            payload.update(extra)
        # active 随负载透传（接收侧不消费；是否触发总结反向推送由发送层判定）
        payload["active"] = active
        # 接收方会话保障（Task 7.2）：broker 消费前确保会话元数据存在
        _ensure_receiver_session(user_id, target_id, session_id, content)
        dispatched = False
        if state.team_broker is not None:
            dispatched = state.team_broker.dispatch((user_id, target_id), payload)
        if dispatched:
            sent.append(target_id)
            # 总结反向推送（Task 7.1）：active 主动发起且非被动通道时触发
            if active and not is_auto_reply:
                _maybe_push_last_summary(
                    user_id, target_id, source_agent_id, owner_top, session_id
                )
        else:
            rejected.append(target_id)

    if concurrency_limited:
        result = {
            "sent": sent,
            "rejected": rejected,
            "concurrency_limited": concurrency_limited,
        }
        # 仅当全部 target 都被并发拒绝（无成功、无其他原因拒绝）时整体标记，
        # 供 _dispatch_user_message 据此提示用户，而不回落到 _handle_user_message。
        if not sent and not rejected:
            result["status"] = "concurrency_limited"
        elif not sent:
            result["status"] = "error"
        else:
            result["status"] = "sent" if not rejected else "partial"
        return result

    if not sent:
        return {"status": "error", "sent": sent, "rejected": rejected}
    return {
        "status": "sent" if not rejected else "partial",
        "sent": sent,
        "rejected": rejected,
    }


async def _dispatch_user_message(user_id: str, data: Dict[str, Any]) -> None:
    """投递顶部 agent 用户消息（收敛到统一消息 API）。

    - agent idle：broker 立即新建 worker 消费消息，等价于直接发送。
    - agent working：消息进入该 agent 的队列，在当前 tool_call 间隙切入。
    """
    agent_id = data.get("agent_id", "")
    if not agent_id:
        # ID 存在性校验（Task 2）：缺 agent_id（team_id 由其派生）即拒绝，
        # 记日志并回错误，不以空串降级到无 agent 的历史兜底路径。
        logger.error(
            "_dispatch_user_message 缺少 agent_id，拒绝投递: user_id=%r "
            "data_keys=%s",
            user_id, sorted(data.keys()),
        )
        if state.ws_manager is not None:
            try:
                await state.ws_manager.send_message(
                    user_id,
                    {
                        "type": "error",
                        "data": {"message": "消息缺少 agent_id，已拒绝"},
                    },
                )
            except Exception:  # noqa: BLE001
                pass
        return
    content = data.get("content", "") or ""
    if not content and data.get("attachments"):
        content = "[附件消息]"

    # 本地模式下 _dispatch_agent_message 内部可能经反向 WS 读 roster（阻塞），
    # 放入线程池执行，避免在事件循环线程内空等（阻塞期间其他请求全部卡住）。
    # 用户直发：source_agent_id 统一标记为 USER_AGENT_ID（历史为空串，
    # _dispatch_agent_message 经 is_user_sender 等效识别）。
    # active（Task 7.1）：用户主动发起默认 true；前端/调用方可显式传 false。
    result = await asyncio.to_thread(
        _dispatch_agent_message,
        user_id, [agent_id], content,
        USER_AGENT_ID,
        agent_id,
        "",
        dict(data),
        bool(data.get("active", True)),
    )
    if result.get("status") == "concurrency_limited":
        # 并发执行上限命中（Task 7）：提示用户稍后再试，不回落到
        # _handle_user_message（否则会再次触发超限）。
        active = _count_active_agents(user_id)
        await _send_text_as_agent(
            user_id,
            agent_id,
            f"并发任务已达上限（当前并发 {active} 个），请稍等片刻再试",
            session_id=data.get("session_id", DEFAULT_SESSION),
        )
        return
    if result.get("status") == "error":
        asyncio.create_task(_handle_user_message(user_id, data))


async def resume_after_answer(
    user_id: str,
    agent_id: str,
    team_id: str,
    session_id: str,
    answer: str,
    is_member: bool,
    sender_id: str = "",
) -> None:
    """AskUserQuestion 作答后的唤醒：注入答案并重新触发该 agent 执行。

    agent 提问后暂停归闲、上下文已持久化（含 assistant tool_calls + 占位
    tool 结果）。这里把答案作为一条"用户回答"消息经既有 broker/消息派发
    通道重新投递给该 agent，使其续跑原任务。

    - 成员：经 ``_dispatch_agent_message``（team_broker）分发，需
      ``team_id`` 解析 roster。
    - 主 agent：经 ``_dispatch_user_message``（top_chat_broker）分发。

    ``sender_id`` 为提问时持久化的原发送方；成员续跑后最终总结仍回发给它，
    保证"谁发给它的总结就回发给谁"在提问-回答边缘路径同样成立。
    """
    content = f"[AskUserQuestion 用户回答] {answer}"
    # 作答唤醒属被动注入（Task 7.1）：以 active=false 投递，不触发总结反向推送
    try:
        if is_member:
            await asyncio.to_thread(
                _dispatch_agent_message,
                user_id, [agent_id], content,
                team_id, team_id, "",
                {"session_id": session_id, "sender_id": sender_id},
                False,
            )
        else:
            await _dispatch_user_message(user_id, {
                "agent_id": agent_id,
                "session_id": session_id,
                "content": content,
                "active": False,
            })
    except Exception as exc:  # noqa: BLE001
        logger.exception("唤醒 agent 失败: %s agent=%s", exc, agent_id)


async def _handle_user_message(
    user_id: str, data: Dict[str, Any], queue: Optional[asyncio.Queue] = None
) -> None:
    """处理用户消息：调用 LLM 并流式推送回复。

    流程：
    1. 校验参数并发送 agent_status（thinking）
    2. 选择模型配置（普通/无限上下文）
    3. 发送 stream_start（流式开始）
    4. 调用 LLM，分块发送 stream_chunk
    5. 发送 stream_end（流式结束）
    6. 恢复 agent_status（idle）

    LLM 调用失败（如未配置 API Key、网络错误）时，会向前端发送错误提示消息。

    :param queue: 该 agent 的用户消息队列（checklist 7）。当 agent 处于
                  working 状态时，新到的用户消息会进入队列，并在当前
                  tool_call 处理完、进入下一轮 LLM 调用前通过 ``on_tool_turn``
                  回调切入（插在工具结果之后）。idle 时消息立即被消费，
                  等价于直接发送。
    """
    agent_id = data.get("agent_id", "")
    content = data.get("content", "")
    session_id = data.get("session_id", DEFAULT_SESSION)

    if not agent_id or (not content and not data.get("attachments")):
        await _send_text_as_agent(user_id, agent_id or "unknown", "消息内容或 agent_id 不能为空")
        return

    # 压缩互斥：同会话正在 compact（compress 在后台线程改写 session.context）
    # 时拒绝受理新消息，避免与 compress 并发读写上下文造成数据竞争；
    # 其他会话的压缩不受影响（各自独立 AgentLLMSession）。
    if _is_agent_compacting(user_id, agent_id, session_id):
        await _send_text_as_agent(
            user_id, agent_id,
            "该 agent 正在压缩上下文，请稍候再试",
            session_id=session_id,
        )
        return

    # 运行模式锁定（SubTask 6.5）：team 首次收到消息、正式进入 agent 处理
    # 循环前，确定并持久化运行模式（agents.mode）。此后 resolve_mode 优先
    # 读取该持久化值，不再随执行器运行时注册态漂移：已锁定 local/ssh 的
    # agent 即使执行器瞬时失联（WS 断连/连续超时自动停用）也保持 local/ssh，
    # 由执行器 request 快速失败 + 前端收到 registration_lost 后自动重注册
    # 自愈（绝不静默回退云端执行，见 io_/mode_resolver.py）。本地/SSH 的
    # base 与 agentspace/ 目录由前端执行器负责初始化；云端沙箱在 agent 创建
    # 时已由 POST /agents → docker_manager.create_workspace 创建（首消息
    # ensure 仅注释级确认，幂等不重复创建）。锁定失败（DB 异常等）不阻断
    # 消息处理。
    ensure_mode_locked(user_id, agent_id)

    # 确保会话元数据存在（多会话并行），更新访问时间并用首条消息生成标题
    create_session(user_id, agent_id, session_id=session_id)
    touch_session(user_id, session_id)
    update_session_title_from_first_message(user_id, agent_id, session_id, content)

    # 读取用户上传的附件路径（写入工作空间在获取 agent/workspace 后进行）
    attachments = data.get("attachments") or []
    llm_content = content

    # 保存用户消息到历史
    _store_message(user_id, agent_id, "user", content, session_id=session_id)

    # 获取模型配置
    if not state.model_configs:
        await _send_text_as_agent(user_id, agent_id, "后端未配置任何 LLM 模型", session_id=session_id)
        await _send_status_idle(user_id, agent_id, session_id)
        return

    # 根据 agent 绑定的模型选择模型配置
    agent = get_agent(user_id, agent_id)
    model_id = agent.get("model_id") if agent else None
    model_config = state.model_configs.get(model_id) if model_id else None
    # agent 的独立工作空间（旧数据回填为 agent 自身 id）
    workspace_id = agent.get("workspace_id") if agent else None
    if not workspace_id:
        workspace_id = agent_id if agent else "top"

    # 上传附件到工作空间 .input/yyyymmdd/，仅将路径告知 LLM。
    # 三模式分派：local 直接写 base_dir/.input；cloud 写云端容器/本地降级
    # workspaces；SSH 必须经前端执行器 SFTP 落**远端** .input——走异步
    # _upload_attachments_ssh，否则附件会误写云端容器而后端 agent（SSH 工具
    # 全部跑在远端主机）读不到，表现为「提示已上传、实际找不到」。
    _le = state.local_executor
    if (
        _le is not None
        and not _le.is_local(user_id, agent_id)
        and resolve_mode(user_id, agent_id) == "ssh"
    ):
        uploaded_paths = await _upload_attachments_ssh(
            workspace_id, attachments, user_id=user_id, team_id=agent_id,
        )
    else:
        uploaded_paths = _upload_attachments(
            workspace_id,
            attachments,
            user_id=user_id,
            team_id=agent_id,
        )
    attachments_prompt = _build_attachments_prompt(uploaded_paths)
    if attachments_prompt:
        llm_content = f"{llm_content}\n\n{attachments_prompt}" if llm_content else attachments_prompt

    # 兜底：agent 不存在或模型已删除时，回退到第一个配置
    if model_config is None:
        model_config = next(iter(state.model_configs.values()))

    if not model_config.api_key:
        await _send_text_as_agent(
            user_id,
            agent_id,
            f"模型 {model_config.name} 未配置 API Key，请在 server/configs/models/*.yaml 中配置",
            session_id=session_id,
        )
        await _send_status_idle(user_id, agent_id, session_id)
        return

    # 登记进行中的任务（供"停止"按钮取消）
    cancel_event = _register_active_task(user_id, agent_id, session_id)

    # 通知前端 agent 进入 working 状态
    await _send_status_working(user_id, agent_id, session_id)

    # 初始化变量，确保 finally 块中可访问
    session = None
    full_reply = ""
    last_text_id = None
    try:
        # normal LLM：按 (user_id, agent_id, session_id) 复用会话，使上下文跨消息累积
        session = get_session(user_id, agent_id, session_id)
        if session is None:
            # 先建空会话并注册工具（register_builtin_tools 挂载 session.mcp_manager），
            # 再构建含 MCP 工具清单章节的系统提示词快照——MCP 章节正文需经
            # session.mcp_manager 现算（不启动 stdio 子进程）。
            session = AgentLLMSession(
                model_config=model_config,
                workspace_id=workspace_id,
                user_id=user_id,
                agent_id=agent_id,
                result_redirect_writer=_make_result_redirect_writer(
                    workspace_id, user_id, agent_id
                ),
            )
            set_session(user_id, agent_id, session, session_id)
            try:
                await _register_tools(session, agent_id, user_id,
                                      team_id=agent_id,
                                      session_id=session_id)
            except Exception:
                # 工具注册失败：清掉半成品会话，避免下次消息拿到无工具会话
                pop_session(user_id, agent_id, session_id)
                raise
            # 本地模式下 _build_workspace_extra_info 经反向 WS 读 .self 文件（阻塞），
            # 必须放入线程池执行：否则 local_executor.request 会在事件循环线程内
            # 调用 run_coroutine_threadsafe 发送 WS 消息，但事件循环被自身阻塞，
            # send_message 永远不会被调度执行 → 死锁 ~120s/文件。
            extra_info = await asyncio.to_thread(
                _build_workspace_extra_info,
                workspace_id, user_id=user_id, agent_id=agent_id,
                local_executor=state.local_executor,
            )
            # 系统提示词 9 章节全量注入（Spec 索引/已选 Spec/.self 文档/成员拓扑）
            # + MCP 工具清单章节（⑩b）
            mcp_text = _build_mcp_tools_text(
                getattr(session, "mcp_manager", None)
            )
            enhanced_prompt = await asyncio.to_thread(
                _build_agent_system_prompt,
                workspace_id,
                user_id=user_id,
                agent_id=agent_id,
                team_id=agent_id,
                session_id=session_id,
                extra_info=extra_info,
                mcp_tools_text=mcp_text,
            )
            session.system_prompt = enhanced_prompt
            session.context = [{"role": "system", "content": enhanced_prompt}]
            session.workspace_extra_info = extra_info
            # 首次创建时从数据库恢复上下文（重启后重建会话）
            restored = load_context(user_id, agent_id, session_id)
            if restored:
                session.context = restored

        # 活动日志：记录本次对话开始，供 leader 判断是否卡死
        if workspace_id:
            _append_activity_log(
                workspace_id,
                f"[{_clock_now()}] [start] 收到输入: {llm_content[:120]}",
                user_id=user_id, mode_key=agent_id,
            )

        def _pick_incoming() -> Optional[str]:
            """在 tool_call 间隙从队列切入用户新发的消息（checklist 7）。

            仅在 agent 处于 working 状态时调用：当前消息处理到 tool_call 间隙，
            从队列取出用户新消息，插到工具结果之后供下一轮 LLM 处理。

            跨会话隔离：只切入当前会话的消息；其他会话的消息放回队列，
            待当前消息处理完后由 worker 作为独立消息继续处理（不串入本会话上下文）。
            """
            if queue is None:
                return None
            try:
                incoming = queue.get_nowait()
            except queue.Empty:
                return None
            incoming_session = incoming.get("session_id", DEFAULT_SESSION)
            if incoming_session != session_id:
                queue.put_nowait(incoming)
                return None
            incoming_content = incoming.get("content", "")
            if not incoming_content:
                return None
            if workspace_id:
                _append_activity_log(
                    workspace_id,
                    f"[{_clock_now()}] [切入] 收到用户新消息: "
                    f"{incoming_content[:120]}",
                    user_id=user_id, mode_key=agent_id,
                )
            return incoming_content

        # SFT 数据收集：记录该轮处理前的上下文基线（仅开启数据收集期间有效，
        # 内部按开关过滤；含 CoT 的完整 context 在对话结束后与基线求 diff）
        context_before = list(session.context) if session is not None else []

        # 在后台线程运行 chat 循环，实时推送中间输出与工具调用
        full_reply, stream_status, last_text_id = await _stream_agent_reply(
            user_id,
            agent_id,
            workspace_id,
            session,
            llm_content,
            on_tool_turn=_pick_incoming,
            cancel_event=cancel_event,
            session_id=session_id,
            team_id=agent_id,
        )

        if stream_status == "cancelled":
            if workspace_id:
                _append_activity_log(
                    workspace_id, f"[{_clock_now()}] [stopped] 已停止",
                    user_id=user_id, mode_key=agent_id,
                )
        elif stream_status == "paused":
            if workspace_id:
                _append_activity_log(
                    workspace_id, f"[{_clock_now()}] [wait] 已提问，等待用户回答",
                    user_id=user_id, mode_key=agent_id,
                )
        elif stream_status == "error":
            if workspace_id:
                _append_activity_log(
                    workspace_id, f"[{_clock_now()}] [error] LLM 请求失败: {full_reply}",
                    user_id=user_id, mode_key=agent_id,
                )
        else:
            if workspace_id:
                _append_activity_log(
                    workspace_id, f"[{_clock_now()}] [done] 回复完成",
                    user_id=user_id, mode_key=agent_id,
                )
        # 对话结束后将上下文持久化到数据库（重启后恢复）
        if session is not None:
            save_context(user_id, agent_id, session.context, session_id=session_id)
            # SFT 数据收集：仅开启期间生效；把本轮新增消息（含 CoT）作为
            # diff 累加到该会话快照。带 try 避免收集异常影响主流程。
            try:
                collect_sft_turn(
                    user_id, agent_id, session_id,
                    context_before, session.context,
                )
            except Exception as exc:  # noqa: BLE001
                logger.warning("SFT 收集失败: %s", exc)
    except Exception as exc:  # noqa: BLE001
        await _send_text_as_agent(user_id, agent_id, f"LLM 请求失败: {exc}", session_id=session_id)
        full_reply = f"LLM 请求失败: {exc}"
        stream_status = "error"
        last_text_id = None
        if workspace_id:
            _append_activity_log(
                workspace_id, f"[{_clock_now()}] [error] LLM 请求失败: {exc}",
                user_id=user_id, mode_key=agent_id,
            )
    finally:
        # 计算 token 用量
        usage_payload = None
        if session is not None and getattr(session, "last_usage", None):
            max_tokens = int(model_config.extra.get("max_seqlen", 8192))
            usage_payload = {**session.last_usage, "max_tokens": max_tokens}

        # 若最终文本段仍打开，补发 msg_end（附带 usage）
        if last_text_id:
            await state.ws_manager.send_message(
                user_id,
                {
                    "type": "msg_end",
                    "id": last_text_id,
                    "agent_id": agent_id,
                    "usage": usage_payload,
                    "session_id": session_id,
                },
            )

        # 保存 agent 回复到历史（附带 token 用量，便于切换 agent 后恢复显示）
        if full_reply:
            _store_message(
                user_id,
                agent_id,
                "agent",
                full_reply,
                usage=usage_payload,
                session_id=session_id,
            )

        # 恢复 idle 状态并清除任务登记
        _clear_active_task(user_id, agent_id, session_id)
        await _send_status_idle(user_id, agent_id, session_id)


def _parse_roster_table(content: str) -> List[Dict[str, Any]]:
    """解析成员管理表 markdown 表格，返回成员字典列表。

    表格列：ID | 名称 | 模型 | 层级 | 创建时间 | 工作状态 | 评价 | ...
    """
    members: List[Dict[str, Any]] = []
    for raw_line in content.splitlines():
        line = raw_line.strip()
        if not line.startswith("|"):
            continue
        if "ID" in line and "名称" in line:
            continue
        if "---" in line.replace("|", ""):
            continue
        parts = [p.strip() for p in line.strip("|").split("|")]
        if len(parts) < 7:
            continue
        try:
            level = int(parts[3]) if parts[3].isdigit() else 0
        except (ValueError, IndexError):
            level = 0
        member_id = parts[0]
        if not member_id:
            continue
        members.append(
            {
                "id": member_id,
                "name": parts[1],
                "model_id": parts[2],
                "level": level,
                "created_at": parts[4],
                "work_status": parts[5],
                "comment": parts[6],
                # member_id 同时作为 workspace_id（create_workspace 的约定）
                "workspace_id": member_id,
            }
        )
    return members
