"""内置工具装配：将内置工具注册到 LLM 会话，并把工作空间能力注册为 MCP 服务。"""

import asyncio
import copy
import logging
from typing import Any, Callable, Dict, Optional

import state

from io_.docker_manager import DockerManager
from data.conversation_store import archive_context
from data.mcp_service_store import needs_user_confirmation
from llm.llm import AgentLLMSession
from io_.workspace_io import LocalWorkspaceIO
from ws.ws_manager import WebSocketManager
from mcp_tools import document_server
from mcp_tools import server as workspace_server
from mcp_tools.frontend_tunnel import FrontendTunnel
from tool.edit_tool import EditTool
from tool.read_tool import ReadTool
from tool.grep_tool import GrepTool
from tool.terminal_tool import TerminalTool
from tool.write_tool import WriteTool
from tool.ask_question_tool import AskUserQuestionTool
from tool.mcp_tool import MCPManager, MCPTool
from tool.team_tool import TeamTool
from tool.message_tool import MessageTool
from tool.todo_tool import SetTodoListTool
from tool.spec_tool import SpecTool

logger = logging.getLogger(__name__)


def _resolve_service_host(scope: str, mode: str) -> Optional[str]:
    """判定一个第三方 MCP 服务的执行落点。

    - ``scope="server"``：后端进程直接拉起 stdio 子进程（与当前模式无关）；
    - ``scope=""``（未指定）：按当前会话模式自动落到"文件所在处"——local /
      ssh 模式的宿主进程（用户本机 / 远端主机），cloud 模式的后端进程；
    - ``scope="local"`` / ``"ssh"``：仅当与当前会话模式一致时经该宿主隧道驱动。

    :return: ``"server"`` / ``"tunnel"``；scope 与当前模式冲突时返回 None
    """
    if scope == "server":
        return "server"
    if not scope:
        return "tunnel" if mode in ("local", "ssh") else "server"
    if scope == mode:
        return "tunnel"
    return None


def _build_mcp_tunnel(
    mode: str,
    user_id: str,
    team_id: str,
    local_executor: Optional[Any],
    ws_manager: Optional[WebSocketManager],
) -> Optional[FrontendTunnel]:
    """按会话模式构造第三方 MCP 的宿主隧道；cloud 模式 / 缺依赖时返回 None。

    隧道只搬运字节：拉起子进程、写 stdin、读 stdout 均在宿主进程完成，
    请求配对与超时/卡死检测复用 LocalExecutorClient 的既有机制。
    """
    if mode not in ("local", "ssh"):
        return None
    if mode == "ssh":
        executor = getattr(state, "local_executor", None)
        ws = getattr(state, "ws_manager", None)
    else:
        executor = local_executor or getattr(state, "local_executor", None)
        ws = ws_manager or getattr(state, "ws_manager", None)
    if executor is None or ws is None:
        logger.warning(
            "%s 模式缺少前端执行器/WS 管理器，第三方 MCP 服务在本会话不可用", mode
        )
        return None
    return FrontendTunnel(executor, ws, user_id, team_id, mode=mode)


def register_builtin_tools(
    session: AgentLLMSession,
    docker_manager: DockerManager,
    model_configs: Dict[str, Any],
    mcp_config: Optional[Dict[str, Any]] = None,
    broker: Optional[Any] = None,
    user_id: str = "",
    ws_manager: Optional[WebSocketManager] = None,
    agent_id: str = "",
    leader_id: str = "",
    team_id: str = "",
    local_executor: Optional[Any] = None,
    message_dispatcher: Optional[Callable] = None,
    extra_info_refresher: Optional[Callable[[], dict]] = None,
    session_id: str = "",
    is_member: bool = False,
    terminal_hook_callback: Optional[Callable] = None,
) -> None:
    """将内置工具注册到会话，并把工作空间基础工具注册为 MCP 服务。

    :param session: LLM 会话实例（工具将通过 register_tool 挂载）
    :param docker_manager: Docker 工作空间管理器（team 工具使用）
    :param model_configs: 可用模型配置字典（team 工具创建成员时使用）
    :param mcp_config: 可选外部 MCP 服务配置字典（name -> {command, args, env}）
    :param broker: 团队成员消息投递器（TeamMessageBroker），team 工具用于
                   触发成员异步处理
    :param user_id: 当前用户标识，team 工具投递成员消息时使用
    :param ws_manager: WebSocketManager 实例，AskUserQuestion 工具用于
                       向用户推送问题卡片
    :param agent_id: 当前 agent 的 ID
    :param leader_id: 当前 agent 的上级 leader ID
    :param team_id: 顶层 agent 的 ID（团队成员共享顶层工作空间）
    :param local_executor: 可选，本地执行器客户端（本地模式下提供，否则使用云端容器）
    :param message_dispatcher: 消息投递回调
    :param extra_info_refresher: 额外信息刷新回调
    :param session_id: 当前会话 ID（spec 工具挂 hook 使用）
    :param terminal_hook_callback: terminal hook 模式完成回调（由 chat.py 注入，
                                   后台命令结束后唤醒发起该命令的 agent 续跑）
    """
    # MCP 管理器：先注册外部（第三方）MCP 服务（mcp_config 已由调用方合并
    # config yaml + DB 持久化服务，见 agent/chat.py _register_session_tools），
    # 随后注册本会话的 workspace/document 内置服务。
    workspace_id = getattr(session, "workspace_id", "") or ""

    # 本地模式按顶部 agent 单独控制：以 team_id 为判定键（顶部 agent 自身
    # 会话 team_id == agent_id；成员会话 team_id 为其所属顶部 agent）。
    # 经 ModeResolver 统一判定三模式（local > ssh > cloud）。
    mode_key = team_id or agent_id or user_id
    from io_.mode_resolver import resolve_mode

    mode = resolve_mode(user_id, mode_key)
    # tool_exec_request 归属标识：注册/执行均以顶部 agent ID（team_id）为键，
    # 顶层会话 team_id == agent_id；两者都缺时回退 mode_key（含 user_id 的
    # 历史兜底），但正常链路经入口校验 team_id 必非空。
    request_team_id = team_id or agent_id or mode_key

    # 第三方 MCP 服务的执行落点由 scope 决定：显式 server 由后端直连子进程；
    # 显式 local/ssh 或未指定（自动）时，按当前会话模式落到宿主进程——local
    # 走用户本机的反向 WS，ssh 走远端主机，stdio 帧经隧道透传到 MCP 客户端。
    mcp_manager = MCPManager()
    tunnel = _build_mcp_tunnel(
        mode, user_id, request_team_id, local_executor, ws_manager
    )
    for name, cfg in (mcp_config or {}).items():
        if not isinstance(cfg, dict):
            continue
        scope = str(cfg.get("scope") or "").strip()
        host = _resolve_service_host(scope, mode)
        if host is None:
            logger.warning(
                "MCP 服务 %s 的 scope=%r 与当前会话模式 %s 不匹配，本会话跳过",
                name, scope, mode,
            )
            continue
        service_cfg = dict(cfg)
        service_cfg["scope"] = scope
        if host == "tunnel":
            if tunnel is None:
                logger.warning(
                    "MCP 服务 %s 需在宿主进程执行，但当前会话无可用隧道，跳过",
                    name,
                )
                continue
            service_cfg["tunnel"] = tunnel
        service_cfg["needs_confirmation"] = needs_user_confirmation(
            str(cfg.get("command") or "")
        )
        mcp_manager.register_service(name, service_cfg)

    # 工作空间 IO 是三模式唯一的差异来源：cloud 在容器内执行，local / ssh
    # 把语义请求经反向 WS 交给前端本地执行器 / SSH 通道执行。
    if mode == "local":
        io = LocalWorkspaceIO(
            local_executor, ws_manager, user_id, team_id=request_team_id
        )
    elif mode == "ssh":
        from io_.ssh_workspace_io import SSHWorkspaceIO
        io = SSHWorkspaceIO(
            state.local_executor, state.ws_manager, user_id,
            team_id=request_team_id,
        )
    else:
        from io_.workspace_io import CloudWorkspaceIO
        io = CloudWorkspaceIO(docker_manager)

    # 内置服务（workspace / document）：三模式统一注册为**进程内 MCP server**
    # （server_factory + SDK 内存流），服务端逻辑始终在后端，经标准 MCP 协议
    # （initialize / tools/list / tools/call）调用，差异只体现在背后的 io。
    mcp_manager.register_service(
        "workspace",
        {"server_factory": lambda: workspace_server.build_server(workspace_id, io)},
    )
    mcp_manager.register_service(
        "document",
        {"server_factory": lambda: document_server.build_server(workspace_id, io)},
    )

    # 各内置工具实例
    mcp_tool = MCPTool(mcp_manager)
    read_tool = ReadTool(io, workspace_id)
    grep_tool = GrepTool(io, workspace_id)
    write_tool = WriteTool(io, workspace_id)
    edit_tool = EditTool(io, workspace_id)
    terminal_tool = TerminalTool(
        io, workspace_id, hook_callback=terminal_hook_callback
    )
    team_tool = TeamTool(
        session, docker_manager, model_configs, broker=broker, user_id=user_id,
        agent_id=agent_id, leader_id=leader_id, team_id=team_id,
        message_dispatcher=message_dispatcher, io=io,
        # 透传当前会话：成员上下文按 session 隔离
        session_id=session_id,
    )
    # message 工具：与 team 工具同参实例化（成员/团队名单逻辑共用基类，
    # 仅 action 域不同——team 管档案，message 管通信）
    message_tool = MessageTool(
        session, docker_manager, model_configs, broker=broker, user_id=user_id,
        agent_id=agent_id, leader_id=leader_id, team_id=team_id,
        message_dispatcher=message_dispatcher, io=io,
        session_id=session_id,
    )
    ask_tool = AskUserQuestionTool(
        ws_manager=ws_manager, user_id=user_id,
        agent_id=agent_id, team_id=team_id or agent_id,
        session_id=session_id, is_member=is_member,
        # 透传会话：提问时读取 session.sender_id 持久化原发送方，
        # 供成员续跑后总结精确回发（"谁发给它的就回发给谁"）
        session=session,
    )
    # 绑定主事件循环，供 AskUserQuestion 在消费线程内安全推送 WS 消息
    try:
        ask_tool.bind_loop(asyncio.get_running_loop())
    except RuntimeError:
        pass
    # Spec 工具：检索/选择/读取/创建/更新任务型规范（挂 hook 到当前会话）
    spec_tool = SpecTool(
        io, workspace_id, user_id=user_id, agent_id=agent_id, session_id=session_id,
    )
    # SetTodoList 工具：任务分解与进度跟踪（.self/todos.md + todo_update WS 推送）
    # 按会话隔离存储：默认会话用 .self/todos.md，其余会话用会话独立文件。
    todo_tool = SetTodoListTool(
        io, workspace_id, user_id=user_id, ws_manager=ws_manager,
        session_id=session_id,
    )
    # 挂载会话级 todos 状态提供者：每个工具调用返回时注入 "current_todo_id"
    # 状态文案，供模型及时更新 todo（见 llm.py 工具结果装配）。
    try:
        session.current_todo_status = todo_tool.current_status_text
    except Exception:  # noqa: BLE001
        pass
    # 挂载会话级 selected spec 状态提供者：每个工具调用返回时注入
    # "selected spec" 状态文案，督促模型始终挂接至少一个内置 Spec
    # （见 llm.py 工具结果装配）。
    try:
        session.current_spec_status = spec_tool.current_status_text
    except Exception:  # noqa: BLE001
        pass
    # 绑定主事件循环，供 SetTodoList 在消费线程内安全推送 todo_update WS
    try:
        todo_tool.bind_loop(asyncio.get_running_loop())
    except RuntimeError:
        pass

    # 绑定 compact 时的上下文归档回调：llm.compress 替换 self.context 前，
    # 把完整 pre-compact 上下文快照写入 agent_context_archive 表，用于后期
    # 审计（含 LLM CoT / 工具调用轨迹原文）。未注入时压缩静默跳过归档。
    # 用默认参数按值捕获 user_id/agent_id，避免闭包延迟绑定的潜在歧义。
    if user_id and agent_id:
        def _archive_ctx(
            ctx: list,
            reason: str = "compact",
            _u: str = user_id,
            _a: str = agent_id,
        ) -> None:
            archive_context(_u, _a, ctx, reason)
        session.archive_context_callback = _archive_ctx

    # 统一注册内置工具（11 个）：handler 收集关键字参数后调用各工具的 execute(dict)。
    # redirect_output 由 _make_handler 统一拦截处理，不传入 execute。
    for tool in (mcp_tool, read_tool, grep_tool, write_tool, edit_tool,
                terminal_tool, team_tool, message_tool, todo_tool, ask_tool,
                spec_tool):
        definition = tool.get_tool_definition()
        # 给每个内置工具注入 redirect_output 可选参数
        params = definition["function"]["parameters"]
        if "properties" not in params:
            params["properties"] = {}
        params["properties"]["redirect_output"] = {
            "type": "string",
            "description": (
                "将工具输出重定向保存到工作空间内的指定文件路径"
                "（如 .output/result.txt）。设置后工具返回保存提示而非原始输出，"
                "便于通过 tail 查看大输出。"
            ),
        }
        session.register_tool(
            name=definition["function"]["name"],
            description=definition["function"]["description"],
            parameters=params,
            handler=_make_handler(tool, session, docker_manager),
        )
    # 挂载 MCP 管理器到会话：供 system prompt 重建（compact）与初始快照
    # 注入 MCP 工具清单章节（chat.py _build_mcp_tools_text）
    session.mcp_manager = mcp_manager
    _inject_mcp_tools(session, mcp_manager)

    logger.info(
        "已注册内置工具: %s",
        ", ".join(
            t["definition"]["function"]["name"] for t in session.registered_tools
        ),
    )


def _inject_mcp_tools(session: AgentLLMSession, mcp_manager: MCPManager) -> None:
    """把 MCP 工具按 ``mcp__<服务名>__<工具名>`` 注入模型工具列表。

    仅注入进程内服务（内置 workspace / document）：它们的 server 就在本进程，
    发现成本可忽略。外部 stdio 服务若在注册期逐个握手会拉起子进程，在数百
    agent 规模下不可接受，故不在注册期发现——模型改用 ``mcp`` 工具的 ``help``
    动作按需查询工具清单，再经其 ``call`` 动作（或命名空间名）调用。
    """
    for service_name in mcp_manager.list_services():
        service = mcp_manager.services.get(service_name) or {}
        if service.get("server_factory") is None:
            continue
        for tool in mcp_manager.get_tools(service_name):
            name = tool.get("mcp_name") or ""
            if not name:
                continue
            session.register_tool(
                name=name,
                description=tool.get("description") or "",
                # 深拷贝：工具规格缓存在 MCPManager 中跨会话共享，避免被下游改写
                parameters=copy.deepcopy(tool.get("parameters") or {}),
                handler=_make_mcp_handler(mcp_manager, service_name, tool.get("name", "")),
            )


def _make_mcp_handler(
    mcp_manager: MCPManager, service_name: str, tool_name: str
) -> Any:
    """构造 MCP 工具 handler：经标准 MCP 协议调用并返回文本结果。

    参数直接作为工具入参传给 ``tools/call``；结果优先返回文本内容（模型直接
    消费业务 JSON），无文本内容时回退为结果字典。
    """

    def handler(**kwargs: Any) -> Any:
        result = mcp_manager.call_tool(tool_name, kwargs, service_name)
        if isinstance(result, dict):
            content = result.get("content")
            if content:
                return content
        return result

    return handler


def _make_handler(tool, session=None, docker_manager=None) -> Any:
    """构造工具 handler：将 tool_call 的关键字参数打包为 dict 传给 execute。

    若参数中包含 ``redirect_output``，则工具执行后把结果写入工作空间内
    指定文件，并返回保存提示（而非原始输出），便于 tail 查看大输出。
    """

    def handler(**kwargs: Any) -> Any:
        redirect_path = kwargs.pop("redirect_output", None)
        result = tool.execute(kwargs)

        if redirect_path and session and docker_manager:
            workspace_id = getattr(session, "workspace_id", "") or ""
            if workspace_id:
                try:
                    import base64 as _b64
                    # 将结果写入工作空间内文件
                    content = str(result) if result is not None else ""
                    b64 = _b64.b64encode(content.encode("utf-8")).decode("ascii")
                    # 确保目录存在
                    dir_path = "/".join(redirect_path.rsplit("/", 1)[:-1])
                    mkdir_cmd = ""
                    if dir_path:
                        mkdir_cmd = f"mkdir -p '{dir_path}' && "
                    cmd = [
                        "sh", "-c",
                        f"{mkdir_cmd}echo '{b64}' | base64 -d > '{redirect_path}'",
                    ]
                    docker_manager.exec_in_workspace(workspace_id, cmd)
                    return f"工具调用结果已保存到 {redirect_path}"
                except Exception as exc:  # noqa: BLE001
                    logger.warning("redirect_output 写入失败: %s", exc)
                    return result
        return result

    return handler