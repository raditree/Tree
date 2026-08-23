"""内置工具装配：将内置工具注册到 LLM 会话，并把工作空间基础工具注册为 MCP 服务。"""

import asyncio
import json
import logging
import os
import sys
from typing import Any, Callable, Dict, List, Optional

import state

from io_.docker_manager import DockerManager
from data.conversation_store import archive_context
from llm.llm import AgentLLMSession
from io_.workspace_io import LocalWorkspaceIO
from ws.ws_manager import WebSocketManager
from mcp_tools import document_server
from mcp_tools.embed_search_tool import EmbedSearchTool
from tool.edit_tool import EditTool
from tool.read_tool import ReadTool
from tool.terminal_tool import TerminalTool
from tool.write_tool import WriteTool
from tool.ask_question_tool import AskUserQuestionTool
from tool.mcp_tool import MCPManager, MCPTool
from tool.team_tool import TeamTool
from tool.todo_tool import SetTodoListTool
from tool.spec_tool import SpecTool

logger = logging.getLogger(__name__)

# 工作空间基础工具暴露为 MCP 服务的 stdio server 入口
_WORKSPACE_MCP_SERVER = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "mcp_tools", "server.py"
)

# 文档处理（PDF/PPTX/DOCX/XLSX）MCP 服务入口
_DOCUMENT_MCP_SERVER = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "mcp_tools", "document_server.py"
)


def _build_in_process_handler(
    workspace_id: str,
    io: Any,
) -> Callable[[str, Dict[str, Any]], Dict[str, Any]]:
    """为本地模式构建进程内工具处理器。

    将每个工具方法（read/write/edit/terminal/embed_search）直接分发到对应实例，
    不启动 stdio 子进程，所有 IO 通过反向 WS 到本地执行器。
    """
    tools: Dict[str, Any] = {
        # read/write/edit/terminal 已改为内置工具，不经过 MCP
        "embed_search": EmbedSearchTool(io, workspace_id),
    }

    def _handler(tool_name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        tool = tools.get(tool_name)
        if tool is None:
            return {"error": f"未知本地工作空间工具: {tool_name}"}
        return tool.execute(arguments)

    return _handler


def _get_workspace_tool_defs() -> List[Dict[str, Any]]:
    """返回所有工作空间基础工具的 OpenAI function calling 格式定义。

    用于本地模式进程内处理器的静态工具定义列表。
    """
    from mcp_tools.embed_search_tool import EmbedSearchTool
    return [
        EmbedSearchTool(None, "").get_tool_definition(),
    ]


def _build_document_in_process_handler(
    workspace_id: str,
    io: Any,
) -> Callable[[str, Dict[str, Any]], Dict[str, Any]]:
    """为本地模式构建文档工具的进程内处理器。"""
    # 文档工具的处理逻辑本身就在 Python 中，只有 exec 部分透传给 WorkspaceIO
    def _handler(tool_name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        return json.loads(document_server._handle_tool_call(
            tool_name, arguments, workspace_id, io
        ))
    return _handler


def _get_document_tool_defs() -> List[Dict[str, Any]]:
    """返回所有文档工具的 OpenAI function calling 格式定义。"""
    return document_server.TOOLS


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
    top_agent_id: str = "",
    local_executor: Optional[Any] = None,
    message_dispatcher: Optional[Callable] = None,
    extra_info_refresher: Optional[Callable[[], dict]] = None,
    session_id: str = "",
    is_member: bool = False,
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
    :param top_agent_id: 顶层 agent 的 ID（团队成员共享顶层工作空间）
    :param local_executor: 可选，本地执行器客户端（本地模式下提供，否则使用云端容器）
    :param message_dispatcher: 消息投递回调
    :param extra_info_refresher: 额外信息刷新回调
    :param session_id: 当前会话 ID（spec 工具挂 hook 使用）
    """
    # MCP 管理器：注册外部 MCP 服务（mcp_config 已由调用方合并 config yaml +
    # DB 持久化服务，见 agent/chat.py _register_session_tools），随后挂载
    # 本会话 workspace/document 服务。
    mcp_manager = MCPManager()
    for name, cfg in (mcp_config or {}).items():
        if isinstance(cfg, dict):
            mcp_manager.register_service(name, cfg)
    # 再注册工作空间基础工具服务：以 stdio server 方式暴露 read/write/edit/
    # terminal/embed_search，通过 WORKSPACE_ID 环境变量绑定到当前 agent 沙箱。
    # 工具经 refresh 列出、set 选择、mcp call 调用，而非直接作为 tool 注入。
    workspace_id = getattr(session, "workspace_id", "") or ""

    # 本地模式按顶部 agent 单独控制：以 top_agent_id 为判定键（顶部 agent 自身
    # 会话 top_agent_id == agent_id；成员会话 top_agent_id 为其所属顶部 agent）。
    # 经 ModeResolver 统一判定三模式（local > ssh > cloud），SSH 与 local 均
    # 在进程内调用（后端直接转发），仅 cloud 使用 stdio 子进程。
    mode_key = top_agent_id or agent_id or user_id
    from io_.mode_resolver import resolve_mode

    mode = resolve_mode(user_id, mode_key)
    if mode == "local":
        # 本地模式：工作空间 IO 通过反向 WS 到前端本地执行器，本进程内调用
        from io_.workspace_io import LocalWorkspaceIO
        io = LocalWorkspaceIO(local_executor, ws_manager, user_id)
        mcp_manager.register_service(
            "workspace",
            {
                "handler": _build_in_process_handler(workspace_id, io),
                "tool_defs": _get_workspace_tool_defs(),
            },
        )
        mcp_manager.register_service(
            "document",
            {
                "handler": _build_document_in_process_handler(workspace_id, io),
                "tool_defs": document_server.TOOLS,
            },
        )
    elif mode == "ssh":
        # SSH 模式：工作空间 IO 经 paramiko 转发到远端主机，本进程内调用
        from io_.ssh_workspace_io import SSHWorkspaceIO
        io = SSHWorkspaceIO(state.ssh_manager, user_id, mode_key)
        mcp_manager.register_service(
            "workspace",
            {
                "handler": _build_in_process_handler(workspace_id, io),
                "tool_defs": _get_workspace_tool_defs(),
            },
        )
        mcp_manager.register_service(
            "document",
            {
                "handler": _build_document_in_process_handler(workspace_id, io),
                "tool_defs": document_server.TOOLS,
            },
        )
    else:
        # 云端模式：原有 stdio 子进程方式（terminal 改为内置工具，直接用 IO）
        from io_.workspace_io import CloudWorkspaceIO
        io = CloudWorkspaceIO(docker_manager)
        mcp_manager.register_service(
            "workspace",
            {
                "command": sys.executable,
                "args": [os.path.abspath(_WORKSPACE_MCP_SERVER)],
                "env": {"WORKSPACE_ID": workspace_id},
            },
        )
        # 再注册文档处理服务（PDF/PPTX/DOCX/XLSX）：以 stdio server 方式暴露
        mcp_manager.register_service(
            "document",
            {
                "command": sys.executable,
                "args": [os.path.abspath(_DOCUMENT_MCP_SERVER)],
                "env": {"WORKSPACE_ID": workspace_id},
            },
        )

    # 各内置工具实例
    mcp_tool = MCPTool(mcp_manager)
    read_tool = ReadTool(io, workspace_id)
    write_tool = WriteTool(io, workspace_id)
    edit_tool = EditTool(io, workspace_id)
    terminal_tool = TerminalTool(io, workspace_id)
    team_tool = TeamTool(
        session, docker_manager, model_configs, broker=broker, user_id=user_id,
        agent_id=agent_id, leader_id=leader_id, top_agent_id=top_agent_id,
        message_dispatcher=message_dispatcher, io=io,
        # 透传当前会话：成员上下文按 session 隔离
        session_id=session_id,
    )
    ask_tool = AskUserQuestionTool(
        ws_manager=ws_manager, user_id=user_id,
        agent_id=agent_id, top_agent_id=top_agent_id or agent_id,
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
    # 挂载 team_tool 到会话：成员 tool loop 结束时 chat 侧通过 leader 会话
    # 调 mark_member_idle 复位持久化 work_status（roster 文件 + team_members 表）
    session.team_tool = team_tool
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

    # 统一注册内置工具（9 个）：handler 收集关键字参数后调用各工具的 execute(dict)。
    # redirect_output 由 _make_handler 统一拦截处理，不传入 execute。
    for tool in (mcp_tool, read_tool, write_tool, edit_tool, terminal_tool,
                team_tool, todo_tool, ask_tool, spec_tool):
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
    logger.info(
        "已注册内置工具: %s",
        ", ".join(
            t["definition"]["function"]["name"] for t in session.registered_tools
        ),
    )


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