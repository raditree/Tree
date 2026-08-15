"""内置工具装配：将内置工具注册到 LLM 会话，并把工作空间基础工具注册为 MCP 服务。"""

import asyncio
import logging
import os
import sys
from typing import Any, Dict, Optional

from core.docker_manager import DockerManager
from core.llm import AgentLLMSession
from core.ws_manager import WebSocketManager
from tools.ask_question_tool import AskUserQuestionTool
from tools.help_tool import HelpTool
from tools.mcp_tool import MCPManager, MCPTool
from tools.refresh_tool import RefreshTool
from tools.set_tool import SetTool
from tools.team_tool import TeamTool

logger = logging.getLogger(__name__)

# 工作空间基础工具暴露为 MCP 服务的 stdio server 入口
_WORKSPACE_MCP_SERVER = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "mcp_tools", "server.py"
)

# 文档处理（PDF/PPTX/DOCX/XLSX）MCP 服务入口
_DOCUMENT_MCP_SERVER = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "mcp_tools", "document_server.py"
)


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
    """
    # MCP 管理器：先注册外部 MCP 服务（来自配置文件）
    mcp_manager = MCPManager()
    for name, cfg in (mcp_config or {}).items():
        if isinstance(cfg, dict):
            mcp_manager.register_service(name, cfg)
    # 再注册工作空间基础工具服务：以 stdio server 方式暴露 read/write/edit/
    # terminal/embed_search，通过 WORKSPACE_ID 环境变量绑定到当前 agent 沙箱。
    # 工具经 refresh 列出、set 选择、mcp call 调用，而非直接作为 tool 注入。
    workspace_id = getattr(session, "workspace_id", "") or ""
    mcp_manager.register_service(
        "workspace",
        {
            "command": sys.executable,
            "args": [os.path.abspath(_WORKSPACE_MCP_SERVER)],
            "env": {"WORKSPACE_ID": workspace_id},
        },
    )
    # 再注册文档处理服务（PDF/PPTX/DOCX/XLSX）：以 stdio server 方式暴露
    # read_pdf / read_docx / read_pptx / read_xlsx / create_docx / create_pptx /
    # create_xlsx，通过 WORKSPACE_ID 环境变量绑定到当前 agent 沙箱。
    mcp_manager.register_service(
        "document",
        {
            "command": sys.executable,
            "args": [os.path.abspath(_DOCUMENT_MCP_SERVER)],
            "env": {"WORKSPACE_ID": workspace_id},
        },
    )

    # 各内置工具实例（help 需在 team_tool 之后构造，以读取身份/层级信息）
    set_tool = SetTool(session)
    refresh_tool = RefreshTool(mcp_manager)
    mcp_tool = MCPTool(mcp_manager)
    team_tool = TeamTool(
        session, docker_manager, model_configs, broker=broker, user_id=user_id,
        agent_id=agent_id, leader_id=leader_id,
    )
    ask_tool = AskUserQuestionTool(ws_manager=ws_manager, user_id=user_id)
    help_tool = HelpTool(
        session.registered_tools,
        mcp_manager=mcp_manager,
        session=session,
        team_tool=team_tool,
        workspace_extra_info=getattr(session, "workspace_extra_info", None),
    )
    # 绑定主事件循环，供 AskUserQuestion 在消费线程内安全推送 WS 消息
    try:
        ask_tool.bind_loop(asyncio.get_running_loop())
    except RuntimeError:
        pass

    # 统一注册内置工具：handler 收集关键字参数后调用各工具的 execute(dict)。
    # redirect_output 由 _make_handler 统一拦截处理，不传入 execute。
    for tool in (help_tool, set_tool, refresh_tool, mcp_tool, team_tool, ask_tool):
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