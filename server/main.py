"""Agent Team 后端应用入口。

启动服务：``python server/main.py``
"""
import asyncio
import datetime
import hashlib
import json
import logging
import os
import queue
import threading
import time
import uuid
from contextlib import asynccontextmanager
from typing import Any, Dict, List, Optional, Set, Tuple

import jwt
import uvicorn
from fastapi import Depends, FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from openai import RateLimitError
from pydantic import BaseModel

from api.routes import router as api_router
from core.agent_store import get_agent
from core.auth import get_current_user, verify_token
from core.budget import (
    PriceCalculator,
    get_budget_tracker,
    get_budget_status,
    reset_budget_tracker,
    set_budget,
)
from core.config import get_config
from core.conversation_store import (
    clear_history,
    get_history,
    load_context,
    save_context,
    store_message,
    get_tool_count,
    increment_tool_count,
    reset_tool_count,
)
from core.data_collection_store import (
    is_data_collection_enabled,
    save_snapshot,
)
from core.docker_manager import DockerManager
from core.llm import AgentLLMSession, LimitlessContextSession
from core.models import ModelConfig, get_model_configs
from core.session_cache import get_session, set_session, clear_user_agent
from core.team_broker import TeamMessageBroker
from core.ws_manager import WebSocketManager
from tools import register_builtin_tools

# WebSocket 连接管理器（全局单例）
ws_manager = WebSocketManager()

# 本地执行器客户端（全局单例）：本地模式下把工具调用转发给前端本地执行
_local_executor: "Optional[Any]" = None

# 模块级日志器
logger = logging.getLogger(__name__)

# 模型配置全局缓存（ lifespan 中填充）
_model_configs: Dict[str, ModelConfig] = {}
# Docker 管理器与应用的全局句柄（lifespan 中填充，供聊天处理等场景使用）
_docker_manager: Optional[DockerManager] = None
# 团队成员消息投递器（lifespan 中填充，供 team 工具触发成员异步处理）
_team_broker: Optional[TeamMessageBroker] = None
# 顶部 agent 用户消息投递器（lifespan 中填充，checklist 7）：
# 串行消费用户消息，agent working 时在 tool_call 间隙切入新消息，
# idle 时立即处理（等价于直接发送）。
_top_chat_broker: Optional[TeamMessageBroker] = None

# Agent 系统提示词：仅保留基本介绍，详细说明全部转移到 help 工具。
_SYSTEM_PROMPT = (
    "你是一个 helpful AI agent，帮助用户完成各种任务。\n"
    "先调用 help 工具查看使用帮助，磨刀不负砍柴功。"
)


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
) -> Dict[str, Any]:
    """保存一条消息到 SQLite 持久化历史。"""
    return store_message(
        user_id, agent_id, role, content,
        usage=usage, kind=kind,
        tool_name=tool_name, tool_arguments=tool_arguments,
        tool_result=tool_result,
    )


async def _register_tools(
    session: AgentLLMSession, agent_id: str, user_id: str = "",
    leader_id: str = "", top_agent_id: str = "", member_system_prompt: str = "",
) -> None:
    """给会话注册内置工具（help / team / set / mcp / refresh）。

    封装对 register_builtin_tools 的调用，避免重复展开 mcp_config 取值逻辑。
    同时把消息投递器与用户标识传给 team 工具，用于异步触发成员处理。
    """
    mcp_config = (
        app.state.config.get("mcp") if hasattr(app.state, "config") else None
    )
    workspace_id = getattr(session, "workspace_id", "") or ""

    # help 的 workspace_extra_info 刷新回调：每次 help 执行 / compact 刷新时
    # 现读现算（identity/rule/memory.md 均为最新），避免会话构造时的一次性
    # 快照长期过期（memory.md 每次记忆维护都会更新）。
    def _extra_info_refresher() -> dict:
        return _build_workspace_extra_info(
            workspace_id,
            member_system_prompt=member_system_prompt,
            user_id=user_id,
            agent_id=top_agent_id or agent_id,
            local_executor=_local_executor,
        )

    register_builtin_tools(
        session,
        docker_manager=_docker_manager,
        model_configs=_model_configs,
        mcp_config=mcp_config,
        broker=_team_broker,
        user_id=user_id,
        ws_manager=ws_manager,
        agent_id=agent_id,
        leader_id=leader_id,
        top_agent_id=top_agent_id,
        local_executor=_local_executor,
        message_dispatcher=_dispatch_agent_message,
        extra_info_refresher=_extra_info_refresher,
    )


def _upload_attachments(
    workspace_id: str, paths: Any
) -> List[str]:
    """将对话框上传的本地文件写入工作空间 ``.input/yyyymmdd/`` 目录。

    返回工作空间内的路径列表（如 ``/workspace/.input/20260808/xxx``）。
    Docker 不可用或文件不存在时跳过该文件。写入失败仅记录日志，不中断。

    :param workspace_id: agent 工作空间标识
    :param paths: 用户上传的本地文件路径列表
    :return: 成功写入工作空间的路径列表
    """
    if not paths or _docker_manager is None or not _docker_manager.available:
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
        result = _docker_manager.write_file(workspace_id, container_path, data)
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
    if not workspace_id or _docker_manager is None:
        return ""
    try:
        result = _docker_manager.exec_in_workspace(
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
    if not workspace_id or _docker_manager is None:
        return 0
    if _docker_manager._use_local():
        # 本地模式：直接统计本地工作空间目录大小
        import os as _os

        local_workspace = _docker_manager._local_workspace_path(workspace_id)
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
        result = _docker_manager.exec_in_workspace(
            workspace_id, ["sh", "-c", "du -sb /workspace 2>/dev/null"]
        )
        if result.get("exit_code", -1) != 0:
            return 0
        out = result.get("stdout", "").strip()
        return int(out.split()[0]) if out else 0
    except Exception:  # noqa: BLE001
        return 0


def _build_agent_system_prompt(
    workspace_id: str,
    member_system_prompt: str = "",
) -> str:
    """构建 agent 的系统提示词：仅保留基础指令，详细说明转移到 help 工具。

    checklist 6 / 9 / 10 / 15 的身份、rule.md、存储告警等全部聚集到 help 工具的
    ``workspace_extra_info`` 中，由 help 工具统一透露。

    :param workspace_id: 工作空间标识
    :param member_system_prompt: 成员专属系统提示词（leader 通过 update_member 设置）
    :return: 精简后的系统提示词
    """
    return _SYSTEM_PROMPT


def _setup_session_budget(
    session: Any, model_config: ModelConfig,
    user_id: str, top_agent_id: str,
) -> None:
    """为会话设置预算追踪器与价格计算器。

    如果模型配置包含价格信息，创建 BudgetTracker 并绑定到会话。
    teammates 共享顶层 agent 的预算（通过 top_agent_id 关联）。
    """
    price_calc = PriceCalculator(model_config)
    if price_calc.has_pricing:
        tracker = get_budget_tracker(user_id, top_agent_id)
        session.set_budget_tracker(tracker, price_calc)


def _check_budget_threshold(
    session: Any, user_id: str, agent_id: str,
) -> Optional[str]:
    """检查预算阈值，若达到新阈值返回系统提示注入文本。

    返回的文本可注入到 LLM 上下文作为预算告警。
    """
    if session.budget_tracker is None or session.price_calculator is None:
        return None
    threshold = session.budget_tracker.check_and_mark_threshold(
        session.price_calculator
    )
    if threshold is None:
        return None
    pct = session.budget_tracker.get_percentage(session.price_calculator)
    remaining = session.budget_tracker.get_remaining(session.price_calculator)
    summary = session.budget_tracker.get_budget_summary(session.price_calculator)
    if threshold >= 100:
        msg = (
            f"[预算告警] 预算已耗尽！{summary}\n"
            "请立即停止所有非关键 API 调用，仅完成最核心的任务。"
            "后续 API 调用可能因预算耗尽而受限。"
        )
    else:
        msg = (
            f"[预算告警] 预算已消耗 {pct}%（{threshold}%），剩余 ${remaining:.4f}。\n"
            "请合理规划工作流，在预算消耗 50% 前完成核心任务。"
            f"当前用量：{summary}"
        )
    return msg


async def _send_budget_update_ws(
    user_id: str, agent_id: str, session: Any,
) -> None:
    """发送预算更新 WebSocket 事件。"""
    if session.budget_tracker is None or session.price_calculator is None:
        return
    data = session.budget_tracker.get_budget_ws_data(session.price_calculator)
    await ws_manager.send_message(
        user_id,
        {
            "type": "budget_update",
            "agent_id": agent_id,
            "data": data,
        },
    )


def _build_exec_mode_text(
    workspace_id: str,
    user_id: str = "",
    agent_id: str = "",
    local_executor: Any = None,
) -> str:
    """构建执行模式说明文本（本地 vs 云端沙箱），供 help 工具透出。

    本地模式：工作目录 = base_dir，私人空间 .self 在 base_dir/workspaces/{id}/.self，
    团队共享 base_dir（成员与 leader 直接读写文件协作）。
    云端模式：工作空间在 Docker 容器，工具读写经容器路径。
    """
    mode_key = agent_id or user_id or ""
    is_local = False
    base_dir = ""
    if local_executor is not None and mode_key:
        try:
            is_local = bool(local_executor.is_local(user_id, mode_key))
        except Exception:  # noqa: BLE001
            is_local = False
        if is_local:
            try:
                reg = getattr(local_executor, "_users", {}) or {}
                base_dir = ((reg.get(user_id) or {}).get(mode_key) or "") or ""
            except Exception:  # noqa: BLE001
                base_dir = ""
    if is_local:
        ws_self = f"{base_dir}/workspaces/{workspace_id}/.self"
        return (
            f"执行模式：本地（工作目录 {base_dir or '<用户选择目录>'}"
            f"；你的私人空间 .self 位于 {ws_self}；"
            f"团队共享工作目录 {base_dir or '<用户选择目录>'}"
            "，成员与 leader 直接在此读写文件协作，无需跨沙箱）"
        )
    return (
        f"执行模式：云端沙箱（工作空间 {workspace_id} 位于 Docker 容器，"
        "工具读写经容器路径，工作文件与私人空间 .self 都在容器内）"
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
        from core.llm import LLMClientFactory

        model_id = next(iter(_model_configs), "")
        cfg = _model_configs.get(model_id) if model_id else None
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


def _build_workspace_extra_info(
    workspace_id: str,
    member_system_prompt: str = "",
    user_id: str = "",
    agent_id: str = "",
    local_executor: Any = None,
) -> dict:
    """构建工作空间额外信息，供 help 工具使用。

    覆盖 checklist 6 / 9 / 10 / 15：
    - 6(c) 身份：从 ``.self/identity.md`` 读取 team / level / team leader / 是否开团队
    - 9/10  rule.md：注入 ``.self/rule.md`` 内容
    - 15    存储软上限：工作空间接近 ``upload.sandbox_max_size`` 时提示清理

    :param workspace_id: 工作空间标识
    :param member_system_prompt: 成员专属系统提示词
    :return: 包含身份、rule.md、存储告警等信息的字典
    """
    info: Dict[str, Any] = {}

    # 执行模式（本地 vs 云端沙箱）：让 agent 无需猜测自己的工作环境。
    # 本地执行器按顶部 agent 注册（mode_key=top_agent_id；顶部 agent 自身即 agent_id）。
    exec_mode = _build_exec_mode_text(
        workspace_id, user_id=user_id, agent_id=agent_id,
        local_executor=local_executor,
    )
    if exec_mode:
        info["exec_mode"] = exec_mode

    # 身份信息（checklist 6(c)）
    identity = _read_workspace_file(workspace_id, ".self/identity.md").strip()
    if identity:
        info["identity"] = identity
    else:
        info["identity"] = "顶层 Agent（Level 0），直属用户，可创建并带领子团队。"

    # 成员专属系统提示词（如有）
    if member_system_prompt:
        info["member_system_prompt"] = member_system_prompt

    # rule.md 注入（checklist 9/10）：同样设 4k 大小上限，超限压缩
    rule = _read_workspace_file(workspace_id, ".self/rule.md").strip()
    if rule:
        if len(rule) <= _SELF_DOC_INJECT_LIMIT:
            info["rule"] = rule
        else:
            info["rule"] = _compress_self_doc(
                workspace_id, "rule.md", rule, "工作准则"
            )
    else:
        info["rule"] = "请维护 .self/rule.md 记录你的工作准则。如果你是 team leader，请提醒每一位 teammate 维护各自的 rule.md。"

    # memory.md 注入：全量优先，超过大小上限时压缩为摘要后再注入。
    # memory.md 每次记忆维护都会更新（_run_memory_update），所以不能依赖
    # 会话构造时的一次性快照——compact 触发上下文重构时通过 help 刷新回调
    # 现读现算（见 tools/__init__.py 的 help_refresh_callback）。
    memory = _read_workspace_file(workspace_id, ".self/memory.md").strip()
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


@asynccontextmanager
async def lifespan(app: FastAPI):
    """应用生命周期：启动时加载配置与模型配置，关闭时清理资源。"""
    global _model_configs, _docker_manager, _team_broker, _top_chat_broker
    global _local_executor
    config = get_config()
    app.state.config = config
    _model_configs = get_model_configs()
    app.state.model_configs = _model_configs
    # 本地执行器客户端：本地模式下工具调用经反向 WS 转发给前端本地执行
    from core.local_executor import LocalExecutorClient
    _local_executor = LocalExecutorClient()
    # 绑定主事件循环，供后台线程通过 run_coroutine_threadsafe 安全推送 WS 消息
    _local_executor.bind_loop(asyncio.get_running_loop())
    app.state.local_executor = _local_executor
    # 团队成员消息投递器：leader 发消息给成员时异步触发成员串行处理
    _team_broker = TeamMessageBroker(process_fn=_process_member_message)
    app.state.team_broker = _team_broker
    # 顶部 agent 用户消息投递器（checklist 7）：串行消费用户消息，
    # agent working 时在 tool_call 间隙切入新消息，idle 时立即处理。
    _top_chat_broker = TeamMessageBroker(process_fn=_broker_process_user_message)
    app.state.top_chat_broker = _top_chat_broker
    # 初始化 Docker 工作空间管理器（Docker 未安装时优雅降级）
    docker_manager = DockerManager()
    _docker_manager = docker_manager
    app.state.docker_manager = docker_manager
    app.state.ws_manager = ws_manager
    print(f"[启动] 服务配置: {config.get('server', {})}")
    print(f"[启动] 已加载模型: {list(_model_configs.keys())}")
    if docker_manager.available:
        print(f"[启动] Docker 工作空间管理器就绪，镜像: {docker_manager.image}")
        # 自动创建顶部 agent 工作空间（若不存在），供前端文件管理使用
        top_status = docker_manager.get_workspace_status("top")
        if top_status.get("status") == "removed":
            init_result = docker_manager.create_workspace(
                "top", agent_name="首席 Agent"
            )
            if "error" in init_result:
                print(
                    f"[启动] 创建顶部工作空间失败: {init_result['error']} "
                    f"- {init_result.get('detail', '')}"
                )
            else:
                print(f"[启动] 顶部工作空间已创建: {init_result['workspace_id']}")
        else:
            print(
                f"[启动] 顶部工作空间已存在: top ({top_status.get('status')})"
            )
    else:
        print(f"[启动] Docker 不可用，工作空间功能将降级: {docker_manager._unavailable_reason}")

    # 启动后台任务：定期彻底删除超过保留期的注销账号（checklist 3(b)）
    from core import user_store

    async def _purge_loop() -> None:
        while True:
            try:
                deleted = user_store.purge_expired_users()
                if deleted:
                    print(f"[注销] 已彻底删除 {deleted} 个过期账号")
            except Exception as exc:  # noqa: BLE001
                print(f"[注销] 清理任务异常: {exc}")
            await asyncio.sleep(3600)  # 每小时检查一次

    purge_task = asyncio.create_task(_purge_loop())

    yield
    print("[关闭] 服务退出")
    purge_task.cancel()
    try:
        await purge_task
    except asyncio.CancelledError:
        pass


app = FastAPI(
    title="Agent Team Backend",
    description="LLM 驱动的 agent 团队效率工具后端",
    version="0.1.0",
    lifespan=lifespan,
)

# CORS 中间件配置
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# 注册 REST API 路由
app.include_router(api_router)


def _extract_token(ws: WebSocket) -> str:
    """从 WebSocket 中提取 JWT token。

    优先从查询参数 ``token`` 获取，其次从 ``Authorization`` header 获取。
    """
    token = ws.query_params.get("token", "")
    if token:
        return token
    auth_header = ws.headers.get("authorization", "")
    if auth_header.startswith("Bearer "):
        return auth_header[len("Bearer "):].strip()
    return ""


async def _send_status_idle(user_id: str, agent_id: str) -> None:
    """发送 agent 恢复 idle 状态。"""
    await ws_manager.send_message(
        user_id,
        {"type": "agent_status", "data": {"agent_id": agent_id, "status": "idle"}},
    )


async def _send_status_working(user_id: str, agent_id: str) -> None:
    """发送 agent 进入 working 状态。"""
    await ws_manager.send_message(
        user_id,
        {"type": "agent_status", "data": {"agent_id": agent_id, "status": "working"}},
    )


async def _send_status_updating_memory(user_id: str, agent_id: str) -> None:
    """发送 agent 进入记忆更新状态。"""
    await ws_manager.send_message(
        user_id,
        {
            "type": "agent_status",
            "data": {"agent_id": agent_id, "status": "updating_memory"},
        },
    )


async def _send_text_as_agent(
    user_id: str, agent_id: str, text: str
) -> None:
    """将一段文本作为普通 agent 消息发送（用于错误提示等）。

    同时将这条 agent 回复写入对话历史，避免切换窗口后丢失。
    """
    _store_message(user_id, agent_id, "agent", text)
    await ws_manager.send_message(
        user_id,
        {
            "type": "message",
            "id": agent_id,
            "role": "agent",
            "content": text,
            "timestamp": int(asyncio.get_event_loop().time() * 1000),
        },
    )


# 活动日志写入阈值：流式文本累积达到该长度后 flush 一次到工作空间日志
_ACTIVITY_FLUSH_CHARS = 300

# 记忆更新阶段注入的系统提示词：让 agent 用 write/edit 工具更新 .self/ 文档
_MEMORY_UPDATE_PROMPT = (
    "【记忆维护】本次任务已完成。请更新 .self/ 目录下的记忆文档，"
    "记录本次任务的关键信息：\n"
    "- .self/memory.md：任务目标、关键决策、遇到的问题及解决方案、重要结论\n"
    "- .self/rule.md：从本次任务中总结出的工作准则或经验（如有）\n"
    "- .self/identity.md：如角色或团队结构发生变化（可选）\n"
    "请优先使用 read 工具读取现有内容，再用 write/edit 工具增量更新，"
    "保留已有记忆，不要删除历史记录。\n"
    "更新完成后，仅输出一句话确认：'记忆已更新。'\n"
    "如果本次任务没有值得记录的信息，输出：'无需更新记忆。'"
)


async def _run_memory_update(
    user_id: str,
    agent_id: str,
    workspace_id: str,
    session: Any,
    cancel_event: Optional[threading.Event] = None,
) -> None:
    """任务主循环完成后运行记忆更新阶段。

    状态机：working -> updating_memory -> idle（记忆维护结束后由调用方直接发送 idle）。

    流程：
    1. 发送 ``agent_status: updating_memory``。
    2. 向会话上下文注入记忆更新系统提示，静默运行一次完整 LLM 循环
       （工具调用正常执行并写入 .self/ 文档，但不向前端推送文本/工具卡片）。
    3. 结束后回滚记忆更新阶段的上下文注入与产出，保持主对话上下文干净；
       恢复 ``last_usage`` 等字段，保证最终 token 用量仍为主回复的。

    仅在普通 LLM（非无限上下文）且主回复成功时由调用方触发。
    """
    if session is None:
        return
    if cancel_event is not None and cancel_event.is_set():
        return

    # update memory 门控：工具调用计数达到阈值才触发（各 agent 独立，落盘）。
    # 只有调用了 7 次以上工具时才进入记忆维护，完成后计数清零重新累积。
    tool_count = get_tool_count(user_id, agent_id)
    if tool_count < 7:
        _append_activity_log(
            workspace_id,
            f"[{_clock_now()}] [memory] 工具调用数 {tool_count} < 7，跳过记忆维护",
        )
        return

    # update memory 加锁：期间 User/Teammates/Team Leader 均无法向其发送消息
    if not _lock_memory_update(user_id, agent_id):
        _append_activity_log(
            workspace_id,
            f"[{_clock_now()}] [memory] 已有记忆更新进行中，跳过本次触发",
        )
        return

    await _send_status_updating_memory(user_id, agent_id)

    # 上下文接近模型上限时跳过记忆维护：记忆阶段会继续执行多轮工具调用、
    # 每轮把完整上下文重发给 LLM，容易使输入超长导致响应极慢（表现为前端
    # 长时间"卡死"）。此时跳过记忆更新，保持 updating_memory，随后由调用方直接发送 idle。
    # 跳过阈值比例来自 app.yaml 的 llm.memory_update_skip_ratio，默认 0.9。
    limit = getattr(session, "max_seqlen", 0) or 0
    if limit and getattr(session, "context", None):
        llm_cfg = get_config().get("llm", {}) or {}
        try:
            skip_ratio = float(llm_cfg.get("memory_update_skip_ratio", 0.9))
        except Exception:  # noqa: BLE001
            skip_ratio = 0.9
        try:
            est = session._estimate_context_tokens()
        except Exception:  # noqa: BLE001
            est = 0
        if est >= int(limit * skip_ratio):
            _append_activity_log(
                workspace_id,
                f"[{_clock_now()}] [memory] 上下文接近上限（{est} ≥ {limit} tokens），"
                "跳过记忆维护以避免超长输入",
            )
            # 释放本次加的 update memory 锁，否则该 agent 将永远无法再次进行记忆更新
            _unlock_memory_update(user_id, agent_id)
            # 不发送 working：保持 updating_memory，由调用方随后发送 idle
            return

    # 记忆更新阶段在上下文中的起始标记，结束后回滚
    marker_index = len(session.context)
    # 保存主回复的用量字段，记忆阶段结束后恢复
    saved_usage = getattr(session, "last_usage", None)
    saved_last_prompt = getattr(session, "_last_prompt_tokens", None)
    saved_anchor = getattr(session, "_context_len_at_last_call", 0)

    # 注入记忆更新提示
    session.context.append({"role": "system", "content": _MEMORY_UPDATE_PROMPT})

    try:
        _, mem_status, _ = await _stream_agent_reply(
            user_id,
            agent_id,
            workspace_id,
            session,
            "[系统] 请进入记忆维护阶段，按上述要求更新 .self/ 文档。",
            on_tool_turn=None,
            cancel_event=cancel_event,
            silent=True,
        )
        if mem_status == "cancelled":
            _append_activity_log(
                workspace_id, f"[{_clock_now()}] [memory] 记忆更新被取消"
            )
        elif mem_status == "error":
            _append_activity_log(
                workspace_id, f"[{_clock_now()}] [memory] 记忆更新失败"
            )
        else:
            _append_activity_log(
                workspace_id, f"[{_clock_now()}] [memory] 记忆更新完成"
            )
    except Exception as exc:  # noqa: BLE001
        logger.warning("记忆更新阶段异常: %s", exc)
        _append_activity_log(
            workspace_id, f"[{_clock_now()}] [error] 记忆更新异常: {exc}"
        )
    finally:
        # 回滚记忆更新阶段的上下文注入与产出，保持主对话上下文干净
        del session.context[marker_index:]
        # 恢复主回复的用量字段，避免最终显示的 token 用量被记忆阶段覆盖
        session.last_usage = saved_usage
        session._last_prompt_tokens = saved_last_prompt
        session._context_len_at_last_call = saved_anchor
        # 释放 update memory 锁，并清零工具调用计数（门控重新累积）
        _unlock_memory_update(user_id, agent_id)
        reset_tool_count(user_id, agent_id)
        # 不发送 working：保持 updating_memory，由调用方随后发送 idle


# 进行中的 agent 任务取消事件表：(user_id, agent_id) -> threading.Event。
# 前端点击"停止"时，WS 端点 set 对应事件，chat 消费线程在每条产出后检查并退出。
_active_tasks: Dict[Tuple[str, str], threading.Event] = {}

# update memory 进行中的 agent 集合：期间 User/Teammates/Team Leader 均无法
# 向其发送消息（入口统一拦截）。键为 (user_id, agent_id)。
_memory_updating: Set[Tuple[str, str]] = set()


def _is_memory_updating(user_id: str, agent_id: str) -> bool:
    """判断指定 agent 是否正处于 update memory 阶段。"""
    return (user_id, agent_id) in _memory_updating


def _lock_memory_update(user_id: str, agent_id: str) -> bool:
    """为指定 agent 加 update memory 锁；已加锁时返回 False。"""
    key = (user_id, agent_id)
    if key in _memory_updating:
        return False
    _memory_updating.add(key)
    return True


def _unlock_memory_update(user_id: str, agent_id: str) -> None:
    """释放 update memory 锁。"""
    _memory_updating.discard((user_id, agent_id))


def _register_active_task(user_id: str, agent_id: str) -> threading.Event:
    """登记一个进行中的任务，返回取消事件。"""
    event = threading.Event()
    _active_tasks[(user_id, agent_id)] = event
    return event


def _cancel_active_task(user_id: str, agent_id: str) -> bool:
    """请求取消指定 agent 的进行中任务。"""
    event = _active_tasks.get((user_id, agent_id))
    if event is None:
        return False
    event.set()
    return True


def _clear_active_task(user_id: str, agent_id: str) -> None:
    """任务结束时清除取消事件登记。"""
    _active_tasks.pop((user_id, agent_id), None)


def _clock_now() -> str:
    """返回 HH:MM:SS 时间戳，用于活动日志。"""
    return time.strftime("%H:%M:%S")


def _append_activity_log(workspace_id: str, message: str) -> None:
    """将一行活动日志追加写入 agent 工作空间的 ``.self/activity.log``。

    供 team leader 通过 ``view_member_log`` 查看成员文字输出，判断工作是否卡死。
    - 记录带时间戳，便于判断最后活动时间
    - 使用 base64 写入，避免特殊字符导致命令注入或转义问题
    """
    if not workspace_id:
        return
    try:
        import base64 as _b64

        b64 = _b64.b64encode(message.encode("utf-8")).decode("ascii")
        cmd = [
            "sh",
            "-c",
            "mkdir -p .self && echo '{}' | base64 -d >> .self/activity.log".format(
                b64
            ),
        ]
        _docker_manager.exec_in_workspace(workspace_id, cmd)
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
    out_q: "asyncio.Queue[Dict[str, Any]]" = asyncio.Queue()

    def _consume() -> None:
        """线程内消费 chat 生成器，产出经线程安全方式回传事件循环。"""
        try:
            for item in session.chat(llm_content, on_tool_turn=on_tool_turn):
                if cancel_event is not None and cancel_event.is_set():
                    loop.call_soon_threadsafe(out_q.put_nowait, {"type": "cancelled"})
                    return
                loop.call_soon_threadsafe(out_q.put_nowait, item)
        except asyncio.CancelledError:
            loop.call_soon_threadsafe(out_q.put_nowait, {"type": "cancelled"})
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
    flush_buf = ""
    status = "ok"

    def _close_text() -> None:
        """结束当前文本段（中间输出独立成一条消息，结束时不带 usage）。

        中间文本段持久化到历史表，重启后可通过 get_history 恢复。
        """
        nonlocal text_id, text_parts
        if text_id is not None:
            if not silent:
                asyncio.ensure_future(
                    ws_manager.send_message(
                        user_id, {"type": "msg_end", "id": text_id, "agent_id": agent_id}
                    )
                )
            # 持久化中间文本段（非最终回复）；静默阶段不写入历史
            intermediate_text = "".join(text_parts)
            if (not silent) and intermediate_text.strip():
                try:
                    _store_message(user_id, agent_id, "agent", intermediate_text)
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
            if itype == "text":
                content = item.get("content", "")
                full_parts.append(content)
                text_parts.append(content)
                if not silent:
                    if text_id is None:
                        text_id = _new_seg_id(agent_id)
                        await ws_manager.send_message(
                            user_id,
                            {
                                "type": "msg_start",
                                "id": text_id,
                                "role": "agent",
                                "agent_id": agent_id,
                            },
                        )
                    await ws_manager.send_message(
                        user_id,
                        {
                            "type": "msg_chunk",
                            "id": text_id,
                            "agent_id": agent_id,
                            "chunk": content,
                        },
                    )
                if workspace_id:
                    flush_buf += content
                    if len(flush_buf) >= _ACTIVITY_FLUSH_CHARS:
                        _append_activity_log(workspace_id, f"[{_clock_now()}] {flush_buf}")
                        flush_buf = ""
            elif itype == "tool_call":
                # 结束上一段文本（中间输出独立成消息）
                _close_text()
                name = item.get("name", "")
                args = item.get("arguments") or {}
                result = item.get("result", "")
                # 工具调用计数 +1（update memory 门控累加器，落盘、按 agent 隔离）；
                # 静默模式（update memory 内部工具调用）不计入。
                if not silent:
                    try:
                        increment_tool_count(user_id, agent_id)
                    except Exception:  # noqa: BLE001
                        pass
                if workspace_id:
                    _append_activity_log(
                        workspace_id,
                        f"[{_clock_now()}] [tool] {name} args="
                        f"{str(args)[:200]} -> {str(result)[:150]}",
                    )
                flush_buf = ""
                if not silent:
                    tool_id = _new_seg_id(agent_id)
                    await ws_manager.send_message(
                        user_id,
                        {
                            "type": "tool_start",
                            "id": tool_id,
                            "agent_id": agent_id,
                            "name": name,
                            "arguments": args,
                        },
                    )
                    await ws_manager.send_message(
                        user_id,
                        {
                            "type": "tool_end",
                            "id": tool_id,
                            "agent_id": agent_id,
                            "name": name,
                            "result": str(result),
                        },
                    )
                    # 工具调用完成后发送预算更新
                    if session is not None:
                        await _send_budget_update_ws(user_id, agent_id, session)
                    # 持久化工具调用到历史表；静默阶段不写入历史
                    try:
                        _store_message(
                            user_id, agent_id, "agent", "",
                            kind="tool",
                            tool_name=name,
                            tool_arguments=args if isinstance(args, dict) else {},
                            tool_result=str(result),
                        )
                    except Exception:  # noqa: BLE001
                        pass
            else:
                # 未知产出类型，忽略
                continue
    finally:
        await thread_task
        if flush_buf and workspace_id:
            _append_activity_log(workspace_id, f"[{_clock_now()}] {flush_buf}")

    # 结束时仍打开的文本段即最终回复，交由调用方补发 msg_usage
    last_text_id = text_id
    return "".join(full_parts), status, last_text_id


async def _process_member_message(
    payload: Dict[str, Any], queue: Optional[asyncio.Queue] = None
) -> None:
    """处理投递给成员的消息（leader 通过 team send_message/assign_task 触发）。

    每个成员由 broker 的独立 worker 串行调用本函数。消息不在双方的
    tool_call / token 生成执行中途打断，而是在当前消息的 tool_call 间隙
    通过 ``on_tool_turn`` 回调切入处理新消息（append 到上下文供下一轮处理）。
    成员处理过程中的文字输出写入其工作空间活动日志，leader 可通过
    ``team view_member_log`` 查看判断进度。

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
    top_agent_id = payload.get("top_agent_id", "")
    if not agent_id or not content:
        return

    # update memory 锁：成员正在记忆更新时拒绝新消息（用户/leader 消息均被拦截）
    if _is_memory_updating(user_id, agent_id):
        _append_activity_log(
            workspace_id,
            f"[{_clock_now()}] [error] 成员 {agent_id} 正在记忆更新，消息被拒绝",
        )
        return

    model_config = _model_configs.get(model_id)
    if model_config is None:
        _append_activity_log(
            workspace_id,
            f"[{_clock_now()}] [error] 成员模型不存在: {model_id}",
        )
        return

    # 保存成员收到的消息到历史（teammates 进度页可加载显示）
    _store_message(user_id, agent_id, "user", content)

    # 构建成员会话（normal 复用缓存累积上下文；limitless 每次新建并从 DB 恢复）
    # 系统提示词仅保留基础指令，详细说明转移到 help 工具的 workspace_extra_info
    member_system_prompt = payload.get("system_prompt", "")
    enhanced_prompt = _build_agent_system_prompt(
        workspace_id, member_system_prompt=member_system_prompt
    )
    extra_info = _build_workspace_extra_info(
        workspace_id, member_system_prompt=member_system_prompt,
        user_id=user_id, agent_id=top_agent_id or agent_id,
        local_executor=_local_executor,
    )
    session = get_session(user_id, agent_id)
    if session is None:
        if model_config.is_limitless_context:
            session = LimitlessContextSession(
                model_config=model_config,
                workspace_id=workspace_id,
                system_prompt=enhanced_prompt,
                docker_manager=_docker_manager,
            )
            session.workspace_extra_info = extra_info
            restored = load_context(user_id, agent_id)
            if restored:
                session.restore_context(restored)
        else:
            session = AgentLLMSession(
                model_config=model_config,
                workspace_id=workspace_id,
                system_prompt=enhanced_prompt,
            )
            session.workspace_extra_info = extra_info
            set_session(user_id, agent_id, session)
            await _register_tools(session, agent_id, user_id,
                                  leader_id=leader_id,
                                  top_agent_id=top_agent_id,
                                  member_system_prompt=member_system_prompt)
            restored = load_context(user_id, agent_id)
            if restored:
                session.context = restored
    # 为成员设置预算追踪器（共享顶层 agent 的预算）
    if top_agent_id:
        _setup_session_budget(session, model_config, user_id, top_agent_id)
    if model_config.is_limitless_context:
        await _register_tools(session, agent_id, user_id,
                              leader_id=leader_id,
                              top_agent_id=top_agent_id,
                              member_system_prompt=member_system_prompt)

    _append_activity_log(
        workspace_id,
        f"[{_clock_now()}] [start(成员)] 收到 leader 消息: {content[:120]}",
    )

    def _pick_incoming() -> Optional[str]:
        """在 tool_call 间隙从队列切入 leader 发来的新消息。"""
        if queue is None:
            return None
        try:
            incoming = queue.get_nowait()
        except queue.Empty:
            return None
        incoming_content = incoming.get("content", "")
        if not incoming_content:
            return None
        _append_activity_log(
            workspace_id,
            f"[{_clock_now()}] [切入] 收到 leader 新消息: "
            f"{incoming_content[:120]}",
        )
        return incoming_content

    # 登记任务并通知用户该成员进入 working 状态（teammates 窗口可见）
    cancel_event = _register_active_task(user_id, agent_id)
    await ws_manager.send_message(
        user_id,
        {"type": "agent_status", "data": {"agent_id": agent_id, "status": "working"}},
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
        )
        # 关闭最终文本段（无 usage）
        if _last:
            await ws_manager.send_message(
                user_id,
                {"type": "msg_end", "id": _last, "agent_id": agent_id, "usage": None},
            )
        # 保存成员回复到历史（teammates 进度页可加载显示）
        if full_reply:
            _store_message(user_id, agent_id, "agent", full_reply)
        _append_activity_log(workspace_id, f"[{_clock_now()}] [done(成员)] 回复完成")
        # 成员工具循环最后一次回复的 content 自动回发对应 leader
        if full_reply and leader_id:
            try:
                _dispatch_agent_message(
                    user_id,
                    [leader_id],
                    f"[成员 {agent_id} 完成回复] {full_reply}",
                    source_agent_id=agent_id,
                    top_agent_id=top_agent_id or leader_id,
                    extra={"auto_reply": True},
                )
            except Exception as exc:  # noqa: BLE001
                logger.warning("成员回复回传 leader 失败: %s", exc)
        # 成员主回复成功后触发记忆更新阶段（普通 LLM，且未被取消时）
        if _status == "ok" and not model_config.is_limitless_context:
            await _run_memory_update(
                user_id,
                agent_id,
                workspace_id,
                session,
                cancel_event=cancel_event,
            )
    except Exception as exc:  # noqa: BLE001
        logger.exception("成员消息处理失败: %s", exc)
        _append_activity_log(
            workspace_id, f"[{_clock_now()}] [error] 成员处理失败: {exc}"
        )
    finally:
        _clear_active_task(user_id, agent_id)
        await _send_status_idle(user_id, agent_id)

    # 持久化上下文（成员回复已实时写入工作空间活动日志，供 leader 查看）
    try:
        save_context(user_id, agent_id, session.context)
    except Exception as exc:  # noqa: BLE001
        logger.warning("成员上下文持久化失败: %s", exc)


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
    """从指定 agent 的 roster（成员管理表）中查找成员。"""
    if not roster_owner_id or not member_id:
        return None
    owner = get_agent(user_id, roster_owner_id) or {}
    owner_ws = owner.get("workspace_id") or roster_owner_id
    roster_content = _read_workspace_file(owner_ws, ".self/team_roster.md")
    members = _parse_roster_table(roster_content)
    for m in members:
        if m.get("id") == member_id:
            return m
    return None


def _dispatch_agent_message(
    user_id: str,
    target_ids: Any,
    content: str,
    source_agent_id: str = "",
    top_agent_id: str = "",
    system_prompt: str = "",
    extra: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """统一消息发送 API：对本顶部 agent 旗下任意 agent_id 发送消息（一对多）。

    User-Agent 与 Agent-Agent 消息都收敛到本入口（顶部 agent 走
    ``_top_chat_broker``，团队成员走 ``_team_broker``），统一做：
    - 团队隔离：仅允许发送给与本 agent 有关系的对象（上级 leader / 直属成员），
      不同顶部 agent 旗下互不可见、不可达；
    - update memory 锁：目标正处于记忆维护时拒绝投递；
    - 目标解析：顶部 agent 经 agent_store 查询；成员经发送方 roster 解析。
    """
    if isinstance(target_ids, str):
        target_ids = [target_ids]
    if not target_ids or not content:
        return {"error": "目标 ID 或消息内容不能为空"}

    owner_top = top_agent_id or source_agent_id or ""
    sent: List[str] = []
    rejected: List[str] = []
    for target_id in target_ids:
        if not target_id or target_id == source_agent_id:
            rejected.append(target_id)
            continue
        # update memory 锁：目标正在记忆更新时拒绝投递
        if _is_memory_updating(user_id, target_id):
            logger.warning("目标 %s 正在记忆更新，拒绝消息投递", target_id)
            rejected.append(target_id)
            continue

        # 1) 目标为顶部 agent（agent_store 中可查）
        target_agent = get_agent(user_id, target_id)
        if target_agent is not None:
            # 团队隔离：成员只能向自己的顶部 leader 发送（不允许跨顶部互发）
            if source_agent_id and owner_top and target_id != owner_top:
                rejected.append(target_id)
                continue
            payload = {
                "user_id": user_id,
                "agent_id": target_id,
                "workspace_id": target_agent.get("workspace_id") or target_id,
                "model_id": target_agent.get("model_id") or "",
                "system_prompt": system_prompt,
                "leader_id": "",
                "top_agent_id": target_id,
                "content": content,
            }
            if extra:
                payload.update(extra)
            dispatched = False
            if _top_chat_broker is not None:
                dispatched = _top_chat_broker.dispatch(
                    (user_id, target_id), payload
                )
            if dispatched:
                sent.append(target_id)
            else:
                rejected.append(target_id)
            continue

        # 2) 目标为成员：从发送方（或所属顶部 agent）roster 查找直属成员
        member = _find_roster_member(
            user_id, top_agent_id or source_agent_id, target_id
        )
        if member is None:
            rejected.append(target_id)
            continue
        payload = {
            "user_id": user_id,
            "agent_id": target_id,
            "workspace_id": member.get("workspace_id") or target_id,
            "model_id": member.get("model_id") or "",
            "system_prompt": member.get("system_prompt", "") or system_prompt,
            "leader_id": source_agent_id or top_agent_id,
            "top_agent_id": owner_top,
            "content": content,
        }
        if extra:
            payload.update(extra)
        dispatched = False
        if _team_broker is not None:
            dispatched = _team_broker.dispatch((user_id, target_id), payload)
        if dispatched:
            sent.append(target_id)
        else:
            rejected.append(target_id)

    if not sent:
        return {"status": "error", "sent": sent, "rejected": rejected}
    return {
        "status": "sent" if not rejected else "partial",
        "sent": sent,
        "rejected": rejected,
    }


def _dispatch_user_message(user_id: str, data: Dict[str, Any]) -> None:
    """投递顶部 agent 用户消息（收敛到统一消息 API）。

    - agent idle：broker 立即新建 worker 消费消息，等价于直接发送。
    - agent working：消息进入该 agent 的队列，在当前 tool_call 间隙切入。
    - update memory 期间拒绝投递（记忆维护锁）。
    """
    agent_id = data.get("agent_id", "")
    if not agent_id:
        asyncio.create_task(_handle_user_message(user_id, data))
        return
    if _is_memory_updating(user_id, agent_id):
        logger.warning("agent %s 正在记忆更新，拒绝用户消息投递", agent_id)
        asyncio.create_task(_send_text_as_agent(
            user_id, agent_id, "该 agent 正在执行记忆维护，请稍后再发送消息。"
        ))
        return
    content = data.get("content", "") or ""
    if not content and data.get("attachments"):
        content = "[附件消息]"
    result = _dispatch_agent_message(
        user_id, [agent_id], content,
        source_agent_id="",
        top_agent_id=agent_id,
        extra=dict(data),
    )
    if result.get("status") == "error":
        asyncio.create_task(_handle_user_message(user_id, data))


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

    # update memory 锁兜底：直连调用时同样拒绝（正常由 _dispatch_user_message 拦截）
    if agent_id and _is_memory_updating(user_id, agent_id):
        await _send_text_as_agent(
            user_id, agent_id, "该 agent 正在执行记忆维护，请稍后再发送消息。"
        )
        await _send_status_idle(user_id, agent_id)
        return

    if not agent_id or (not content and not data.get("attachments")):
        await _send_text_as_agent(user_id, agent_id or "unknown", "消息内容或 agent_id 不能为空")
        return

    # 读取用户上传的附件路径（写入工作空间在获取 agent/workspace 后进行）
    attachments = data.get("attachments") or []
    llm_content = content

    # 保存用户消息到历史
    _store_message(user_id, agent_id, "user", content)

    # 获取模型配置
    if not _model_configs:
        await _send_text_as_agent(user_id, agent_id, "后端未配置任何 LLM 模型")
        await _send_status_idle(user_id, agent_id)
        return

    # 根据 agent 绑定的模型选择模型配置
    agent = get_agent(user_id, agent_id)
    model_id = agent.get("model_id") if agent else None
    model_config = _model_configs.get(model_id) if model_id else None
    # agent 的独立工作空间（旧数据回填为 agent 自身 id）
    workspace_id = agent.get("workspace_id") if agent else None
    if not workspace_id:
        workspace_id = agent_id if agent else "top"

    # 上传附件到工作空间 .input/yyyymmdd/，仅将路径告知 LLM
    uploaded_paths = _upload_attachments(workspace_id, attachments)
    attachments_prompt = _build_attachments_prompt(uploaded_paths)
    if attachments_prompt:
        llm_content = f"{llm_content}\n\n{attachments_prompt}" if llm_content else attachments_prompt

    # 兜底：agent 不存在或模型已删除时，回退到第一个配置
    if model_config is None:
        model_config = next(iter(_model_configs.values()))

    if not model_config.api_key:
        await _send_text_as_agent(
            user_id,
            agent_id,
            f"模型 {model_config.name} 未配置 API Key，请在 server/configs/models/*.yaml 中配置",
        )
        await _send_status_idle(user_id, agent_id)
        return

    # 登记进行中的任务（供"停止"按钮取消）
    cancel_event = _register_active_task(user_id, agent_id)

    # 用户发送消息到顶层 agent 时重置预算（teammates 共享顶层预算）
    reset_budget_tracker(user_id, agent_id)

    # 通知前端 agent 进入 working 状态
    await ws_manager.send_message(
        user_id,
        {"type": "agent_status", "data": {"agent_id": agent_id, "status": "working"}},
    )

    # 初始化变量，确保 finally 块中可访问
    session = None
    full_reply = ""
    last_text_id = None
    try:
        # 系统提示词仅保留基础指令，详细说明转移到 help 工具的 workspace_extra_info
        enhanced_prompt = _build_agent_system_prompt(workspace_id)
        extra_info = _build_workspace_extra_info(
            workspace_id, user_id=user_id, agent_id=agent_id,
            local_executor=_local_executor,
        )
        if model_config.is_limitless_context:
            session = LimitlessContextSession(
                model_config=model_config,
                workspace_id=workspace_id,
                system_prompt=enhanced_prompt,
                docker_manager=_docker_manager,
            )
            session.workspace_extra_info = extra_info
            # 设置预算追踪器
            _setup_session_budget(session, model_config, user_id, agent_id)
            # 无限上下文 LLM 每次新建，从数据库恢复上下文（重启不丢失）
            restored = load_context(user_id, agent_id)
            if restored:
                session.restore_context(restored)
        else:
            # normal LLM：按 (user_id, agent_id) 复用会话，使上下文跨消息累积
            session = get_session(user_id, agent_id)
            if session is None:
                session = AgentLLMSession(
                    model_config=model_config,
                    workspace_id=workspace_id,
                    system_prompt=enhanced_prompt,
                )
                session.workspace_extra_info = extra_info
                # 设置预算追踪器
                _setup_session_budget(session, model_config, user_id, agent_id)
                set_session(user_id, agent_id, session)
                await _register_tools(session, agent_id, user_id,
                                      top_agent_id=agent_id)
                # 首次创建时从数据库恢复上下文（重启后重建会话）
                restored = load_context(user_id, agent_id)
                if restored:
                    session.context = restored
            else:
                # 已有会话，确保预算追踪器已设置
                _setup_session_budget(session, model_config, user_id, agent_id)

        # 无限上下文 LLM 每次新建，需注册工具；normal LLM 仅在首次创建时注册
        if model_config.is_limitless_context:
            await _register_tools(session, agent_id, user_id,
                                  top_agent_id=agent_id)

        # 活动日志：记录本次对话开始，供 leader 判断是否卡死
        if workspace_id:
            _append_activity_log(
                workspace_id,
                f"[{_clock_now()}] [start] 收到输入: {llm_content[:120]}",
            )

        def _pick_incoming() -> Optional[str]:
            """在 tool_call 间隙从队列切入用户新发的消息（checklist 7）。

            仅在 agent 处于 working 状态时调用：当前消息处理到 tool_call 间隙，
            从队列取出用户新消息，插到工具结果之后供下一轮 LLM 处理。
            """
            if queue is None:
                return None
            try:
                incoming = queue.get_nowait()
            except queue.Empty:
                return None
            incoming_content = incoming.get("content", "")
            if not incoming_content:
                return None
            if workspace_id:
                _append_activity_log(
                    workspace_id,
                    f"[{_clock_now()}] [切入] 收到用户新消息: "
                    f"{incoming_content[:120]}",
                )
            return incoming_content

        # 在后台线程运行 chat 循环，实时推送中间输出与工具调用
        full_reply, stream_status, last_text_id = await _stream_agent_reply(
            user_id,
            agent_id,
            workspace_id,
            session,
            llm_content,
            on_tool_turn=_pick_incoming,
            cancel_event=cancel_event,
        )

        if stream_status == "cancelled":
            if workspace_id:
                _append_activity_log(
                    workspace_id, f"[{_clock_now()}] [stopped] 已停止"
                )
        elif stream_status == "error":
            if workspace_id:
                _append_activity_log(
                    workspace_id, f"[{_clock_now()}] [error] LLM 请求失败: {full_reply}"
                )
        else:
            if workspace_id:
                _append_activity_log(
                    workspace_id, f"[{_clock_now()}] [done] 回复完成"
                )
            # 主回复成功后触发记忆更新阶段（普通 LLM，且未被取消时）
            if not model_config.is_limitless_context:
                await _run_memory_update(
                    user_id,
                    agent_id,
                    workspace_id,
                    session,
                    cancel_event=cancel_event,
                )
        # 对话结束后将上下文持久化到数据库（重启后恢复）
        if session is not None:
            save_context(user_id, agent_id, session.context)
    except Exception as exc:  # noqa: BLE001
        await _send_text_as_agent(user_id, agent_id, f"LLM 请求失败: {exc}")
        full_reply = f"LLM 请求失败: {exc}"
        stream_status = "error"
        last_text_id = None
        if workspace_id:
            _append_activity_log(
                workspace_id, f"[{_clock_now()}] [error] LLM 请求失败: {exc}"
            )
    finally:
        # 计算 token 用量（normal LLM 附带）
        usage_payload = None
        if (
            session is not None
            and not model_config.is_limitless_context
            and getattr(session, "last_usage", None)
        ):
            max_tokens = int(model_config.extra.get("max_seqlen", 8192))
            usage_payload = {**session.last_usage, "max_tokens": max_tokens}
            # 追加预算信息到 usage payload
            if (
                getattr(session, "budget_tracker", None) is not None
                and getattr(session, "price_calculator", None) is not None
            ):
                budget_data = session.budget_tracker.get_budget_ws_data(
                    session.price_calculator
                )
                usage_payload["budget"] = budget_data

        # 若最终文本段仍打开，补发 msg_end（附带 usage 与预算信息）
        if last_text_id:
            await ws_manager.send_message(
                user_id,
                {
                    "type": "msg_end",
                    "id": last_text_id,
                    "agent_id": agent_id,
                    "usage": usage_payload,
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
            )

        # 数据收集：记录使用快照（仅在开启时有效）
        try:
            if is_data_collection_enabled(user_id):
                snapshot_data = {
                    "agent_id": agent_id,
                    "model_id": getattr(model_config, "model_id", ""),
                    "reply_length": len(full_reply) if full_reply else 0,
                    "usage": usage_payload,
                }
                save_snapshot(user_id, "agent_reply", snapshot_data)
        except Exception:  # noqa: BLE001
            pass

        # 任务结束时发送预算更新
        if session is not None:
            await _send_budget_update_ws(user_id, agent_id, session)

        # 恢复 idle 状态并清除任务登记
        _clear_active_task(user_id, agent_id)
        await _send_status_idle(user_id, agent_id)


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    """WebSocket 端点，承载实时消息（agent 对话、状态变更、同步进度等）。

    消息格式：``{"type": "message_type", "data": {...}}``

    支持的消息类型：
    - ``user_message``：用户发送消息
    - ``heartbeat``：心跳检测

    推送的消息类型：
    - ``stream_start``：流式回复开始
    - ``stream_chunk``：流式回复内容块
    - ``stream_end``：流式回复结束
    - ``tool_call``：工具调用通知
    - ``agent_status``：agent 状态变更
    - ``file_sync_progress``：文件同步进度
    - ``error``：错误消息
    - ``heartbeat``：心跳响应
    """
    # 1. 验证 JWT token
    token = _extract_token(ws)
    if not token:
        await ws.close(code=1008, reason="缺少 token")
        return
    try:
        payload = verify_token(token)
    except jwt.InvalidTokenError:
        await ws.close(code=1008, reason="无效的 token")
        return

    user = payload.get("user", {})
    user_id = user.get("openid", "")
    if not user_id:
        await ws.close(code=1008, reason="无效的用户信息")
        return

    # 2. 接受连接并存储
    await ws_manager.connect(user_id, ws)
    # 2.1 重连状态同步：将当前仍有进行中任务的 agent 状态补推给前端，
    #     保证前端重启（WebSocket 重连）后"工作中"标识与"停止"按钮能恢复显示。
    for (active_uid, active_agent_id) in list(_active_tasks.keys()):
        if active_uid == user_id:
            await ws_manager.send_message(
                user_id,
                {
                    "type": "agent_status",
                    "data": {"agent_id": active_agent_id, "status": "working"},
                },
            )
    try:
        # 3. 循环接收消息并处理
        while True:
            message_text = await ws.receive_text()
            try:
                message = json.loads(message_text)
            except json.JSONDecodeError:
                await ws_manager.send_message(
                    user_id,
                    {"type": "error", "data": {"message": "消息格式错误，需为 JSON"}},
                )
                continue

            if not isinstance(message, dict):
                await ws_manager.send_message(
                    user_id,
                    {"type": "error", "data": {"message": "消息需为 JSON 对象"}},
                )
                continue

            msg_type = message.get("type")
            data = message.get("data", {})
            if not isinstance(data, dict):
                data = {}
            # 兼容两种字段位置：优先 data 子对象，回退到顶层字段
            if not data:
                data = {
                    k: message.get(k)
                    for k in ("agent_id", "content", "attachments")
                    if message.get(k) is not None
                }

            # 4. 根据消息类型分发处理
            if msg_type == "heartbeat":
                await ws_manager.handle_heartbeat(user_id)
            elif msg_type == "user_message":
                # checklist 7：通过 broker 投递，working 时在 tool_call 间隙切入，
                # idle 时立即处理（不等同于阻塞 WebSocket 循环，便于后续消息切入）。
                _dispatch_user_message(user_id, data)
            elif msg_type == "stop":
                # 停止按钮：请求取消指定 agent 的进行中任务
                agent_id = data.get("agent_id", "")
                if agent_id and _cancel_active_task(user_id, agent_id):
                    await ws_manager.send_message(
                        user_id,
                        {
                            "type": "agent_status",
                            "data": {"agent_id": agent_id, "status": "stopping"},
                        },
                    )
                else:
                    await ws_manager.send_message(
                        user_id,
                        {
                            "type": "error",
                            "data": {"message": "没有进行中的任务可停止"},
                        },
                    )
            elif msg_type == "user_answer":
                # 用户回答 AskUserQuestion 工具的问题
                qid = data.get("question_id", "")
                answer = data.get("answer")
                from tools.ask_question_tool import get_ask_tool

                ask_tool = get_ask_tool(user_id)
                if ask_tool is not None and qid:
                    ask_tool.resolve(qid, answer)
                else:
                    await ws_manager.send_message(
                        user_id,
                        {
                            "type": "error",
                            "data": {"message": "没有等待回答的问题"},
                        },
                    )
            elif msg_type == "cancel_question":
                # 用户取消 AskUserQuestion 工具的问题
                qid = data.get("question_id", "")
                from tools.ask_question_tool import get_ask_tool

                ask_tool = get_ask_tool(user_id)
                if ask_tool is not None and qid:
                    ask_tool.cancel(qid)
                else:
                    await ws_manager.send_message(
                        user_id,
                        {
                            "type": "error",
                            "data": {"message": "没有等待回答的问题"},
                        },
                    )
            elif msg_type == "register_local_executor":
                # 前端注册本地执行器：该顶部 agent 的工具调用转发到前端本地执行
                from core.local_executor import LocalExecutorClient
                base_dir = data.get("base_dir")
                top_agent_id = data.get("top_agent_id") or data.get("agent_id") or user_id
                _local_executor.register(user_id, top_agent_id, base_dir)
                # 清除该 agent 的会话缓存：即使此前会话已绑定云端工具，
                # 下次发消息会重建会话并按本地模式重新绑定工具
                clear_user_agent(user_id, top_agent_id)
                # 注册成功回应
                await ws_manager.send_message(
                    user_id,
                    {
                        "type": "register_local_executor_ack",
                        "data": {"success": True},
                    },
                )
            elif msg_type == "unregister_local_executor":
                # 前端注销某个顶部 agent 的本地执行器：该 agent 恢复云端执行
                from core.local_executor import LocalExecutorClient
                top_agent_id = data.get("top_agent_id") or data.get("agent_id") or user_id
                _local_executor.unregister(user_id, top_agent_id)
                await ws_manager.send_message(
                    user_id,
                    {
                        "type": "unregister_local_executor_ack",
                        "data": {"success": True},
                    },
                )
            elif msg_type == "tool_exec_response":
                # 前端返回工具执行结果：唤醒等待的后端请求
                from core.local_executor import LocalExecutorClient
                exec_id = data.get("exec_id", "")
                result = data.get("result", {})
                if not exec_id:
                    await ws_manager.send_message(
                        user_id,
                        {
                            "type": "error",
                            "data": {"message": "tool_exec_response 缺少 exec_id"},
                        },
                    )
                    continue
                resolved = _local_executor.resolve(user_id, exec_id, result)
                if not resolved:
                    logger.warning(
                        "tool_exec_response 未匹配到待处理请求: user_id=%s exec_id=%s",
                        user_id,
                        exec_id,
                    )
            else:
                await ws_manager.send_message(
                    user_id,
                    {"type": "error", "data": {"message": f"未知消息类型: {msg_type}"}},
                )
    except WebSocketDisconnect:
        # 客户端主动断开连接
        pass
    finally:
        ws_manager.disconnect(user_id, ws)


@app.get("/api/conversations/{agent_id}")
async def get_conversation_history(
    agent_id: str,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """拉取指定 agent 的对话历史（SQLite 持久化）。"""
    user_id = current_user.get("openid", "")
    return {"agent_id": agent_id, "messages": get_history(user_id, agent_id)}


@app.delete("/api/conversations/{agent_id}")
async def delete_conversation(
    agent_id: str,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """清空指定 agent 的对话历史。

    ``agent_id`` 为 ``all`` 时清空该用户所有 agent 的历史。
    """
    user_id = current_user.get("openid", "")
    target = None if agent_id == "all" else agent_id
    deleted = clear_history(user_id, target)
    return {"success": True, "deleted": deleted}


@app.post("/api/agents/{agent_id}/compact")
async def compact_agent_context(
    agent_id: str,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """手动压缩 normal LLM 的上下文（compact 按钮触发）。

    从会话缓存中取出该 agent 的会话并强制压缩：
    - 中间消息总结为一条 summary，保留最近 N 条。
    - 无限上下文 LLM 无操作（返回 compressed=False）。
    """
    user_id = current_user.get("openid", "")
    session = get_session(user_id, agent_id)
    if session is None:
        return {
            "success": True,
            "compressed": False,
            "reason": "no_active_session",
            "message": "该 agent 当前没有活跃的会话上下文",
        }
    compressed = session.compress(force=True)
    return {
        "success": True,
        "compressed": compressed,
        "context_size": len(session.context),
    }


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


@app.get("/api/agents/{agent_id}/teammates")
async def get_agent_teammates(
    agent_id: str,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """拉取某 agent 的团队成员拓扑（teammates 工作进度窗口）。

    从该 agent 工作空间解析 ``.self/team_roster.md``，并叠加实时工作状态
    （是否有进行中的任务，来自 ``_active_tasks``）。
    """
    user_id = current_user.get("openid", "")
    agent = get_agent(user_id, agent_id)
    workspace_id = (agent.get("workspace_id") if agent else None) or agent_id
    content = _read_workspace_file(workspace_id, ".self/team_roster.md")
    members = _parse_roster_table(content)
    for m in members:
        mid = m["id"]
        m["live_status"] = (
            "working" if (user_id, mid) in _active_tasks else m.get("work_status") or "idle"
        )
    return {"agent_id": agent_id, "members": members}


@app.get("/api/agents/{agent_id}/teammate/{member_id}/log")
async def get_teammate_log(
    agent_id: str,
    member_id: str,
    lines: int = 60,
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """读取成员工作空间的活动日志（teammates 窗口展示工作进度）。"""
    user_id = current_user.get("openid", "")
    if not _docker_manager or not _docker_manager.available:
        return {"success": True, "log": ""}
    try:
        result = _docker_manager.exec_in_workspace(
            member_id,
            ["sh", "-c", f"tail -n {int(lines)} .self/activity.log 2>/dev/null"],
        )
        return {"success": True, "log": result.get("stdout", "")}
    except Exception as exc:  # noqa: BLE001
        logger.warning("读取成员日志失败 %s: %s", member_id, exc)
        return {"success": False, "error": str(exc)}


@app.post("/api/agents/{agent_id}/teammate/{member_id}/message")
async def send_teammate_message(
    agent_id: str,
    member_id: str,
    body: Dict[str, Any],
    current_user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """用户直接向团队成员发送消息（teammates 窗口）。

    读取 leader 工作空间的成员管理表找到成员，经 broker 异步投递，
    成员会像收到 leader 消息一样开始处理。
    """
    user_id = current_user.get("openid", "")
    content = (body or {}).get("content", "")
    if not content:
        return {"success": False, "error": "缺少 content"}

    # 收敛出口：统一消息 API（用户 -> 成员，走顶部 agent 的 roster 校验与投递）
    result = _dispatch_agent_message(
        user_id,
        [member_id],
        content,
        source_agent_id="",
        top_agent_id=agent_id,
    )
    if result.get("status") == "error":
        return {"success": False, "error": "消息投递失败", "detail": result}
    return {"success": True}


# ===== 预算控制 API =====


class BudgetSetRequest(BaseModel):
    """设置预算请求体。"""
    budget: float


@app.post("/api/budget/{agent_id}")
async def set_agent_budget(
    agent_id: str,
    req: BudgetSetRequest,
    user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """设置顶层 agent 的预算金额（美元）。

    预算金额需大于 0。如果 agent 当前有活跃会话，向上下文中注入预算变更
    系统提示词，让 agent 感知到预算变化并调整工作策略。
    """
    user_id = user.get("openid", "")
    if req.budget <= 0:
        raise HTTPException(status_code=400, detail="预算金额必须大于 0")
    set_budget(user_id, agent_id, req.budget)

    # 若有活跃会话，注入预算变更提示词
    session = get_session(user_id, agent_id)
    if session is not None and hasattr(session, "context"):
        budget = req.budget
        # 获取当前预算状态以生成摘要
        model_config = session.model_config if hasattr(session, "model_config") else None
        if model_config is not None:
            try:
                from core.budget import PriceCalculator, get_budget_tracker
                pc = PriceCalculator(model_config)
                tracker = get_budget_tracker(user_id, agent_id)
                summary = tracker.get_budget_summary(pc)
                session.context.append({
                    "role": "system",
                    "content": (
                        f"[预算变更] 用户已将预算修改为 ${budget:.2f}。"
                        f"当前用量：{summary}\n"
                        "请根据新的预算配额合理规划后续工作流，"
                        "在预算消耗 50% 前完成核心任务。"
                    ),
                })
            except Exception:
                # 兜底：简版提示
                session.context.append({
                    "role": "system",
                    "content": (
                        f"[预算变更] 用户已将预算修改为 ${budget:.2f}。"
                        "请根据新的预算配额合理规划后续工作流。"
                    ),
                })

    return {"success": True, "agent_id": agent_id, "budget": req.budget}


@app.get("/api/budget/{agent_id}")
async def get_agent_budget(
    agent_id: str,
    user: dict = Depends(get_current_user),
) -> Dict[str, Any]:
    """获取顶层 agent 的预算状态。

    返回预算总额、已使用、剩余、消耗百分比、各 token 分类用量。
    """
    user_id = user.get("openid", "")
    # 获取该 agent 的模型配置以计算价格
    agent = get_agent(user_id, agent_id)
    model_id = agent.get("model_id") if agent else None
    model_config = _model_configs.get(model_id) if model_id else None
    if model_config is None:
        model_config = next(iter(_model_configs.values()))
    status = get_budget_status(user_id, agent_id, model_config)
    return {"agent_id": agent_id, **status}


class _LifespanCancelFilter(logging.Filter):
    """屏蔽 uvicorn 强制退出时 lifespan 任务被取消产生的噪音堆栈。

    uvicorn 0.29+ 在 Windows 上 Ctrl+C 退出时会重抛捕获到的信号，导致
    asyncio 清理阶段取消仍存活的 lifespan 任务；starlette 随后将这段
    CancelledError 堆栈作为 lifespan.shutdown.failed 消息以 ERROR 级别打印。
    这里仅抑制这类“任务被取消”的堆栈，其它真实异常不受影响。
    """

    def filter(self, record: logging.LogRecord) -> bool:
        if record.levelno < logging.ERROR:
            return True
        msg = record.getMessage()
        # 形式 1：starlette 把格式化后的取消堆栈作为消息（on.py send 分支）
        if msg.startswith("Traceback (most recent call last):") and msg.strip().endswith("CancelledError"):
            return False
        # 形式 2：uvicorn 直接以 exc_info 记录 lifespan 协议异常（on.py main 分支）
        if msg.startswith("Exception in 'lifespan' protocol") and record.exc_info:
            if record.exc_info[0] is asyncio.CancelledError:
                return False
        return True


if __name__ == "__main__":
    server_cfg = get_config().get("server", {})
    host = server_cfg.get("host", "0.0.0.0")
    port = int(server_cfg.get("port", 8000))
    # Windows 上 uvicorn 退出路径会触发上述 lifespan 取消噪音，预先挂上过滤器
    logging.getLogger("uvicorn.error").addFilter(_LifespanCancelFilter())
    try:
        uvicorn.run(app, host=host, port=port)
    except KeyboardInterrupt:
        pass
    except asyncio.CancelledError:
        pass
