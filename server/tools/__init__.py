"""内置工具装配：将内置工具注册到 LLM 会话，并把工作空间基础工具注册为 MCP 服务。"""

import logging
import os
import sys
from typing import Any, Dict, Optional

from core.docker_manager import DockerManager
from core.llm import AgentLLMSession
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


def register_builtin_tools(
    session: AgentLLMSession,
    docker_manager: DockerManager,
    model_configs: Dict[str, Any],
    mcp_config: Optional[Dict[str, Any]] = None,
    broker: Optional[Any] = None,
    user_id: str = "",
) -> None:
    """将内置工具注册到会话，并把工作空间基础工具注册为 MCP 服务。

    :param session: LLM 会话实例（工具将通过 register_tool 挂载）
    :param docker_manager: Docker 工作空间管理器（team 工具使用）
    :param model_configs: 可用模型配置字典（team 工具创建成员时使用）
    :param mcp_config: 可选外部 MCP 服务配置字典（name -> {command, args, env}）
    :param broker: 团队成员消息投递器（TeamMessageBroker），team 工具用于
                   触发成员异步处理
    :param user_id: 当前用户标识，team 工具投递成员消息时使用
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

    # 各内置工具实例
    help_tool = HelpTool(session.registered_tools, mcp_manager=mcp_manager)
    set_tool = SetTool(session)
    refresh_tool = RefreshTool(mcp_manager)
    mcp_tool = MCPTool(mcp_manager)
    team_tool = TeamTool(
        session, docker_manager, model_configs, broker=broker, user_id=user_id
    )

    # 统一注册内置工具：handler 收集关键字参数后调用各工具的 execute(dict)
    for tool in (help_tool, set_tool, refresh_tool, mcp_tool, team_tool):
        definition = tool.get_tool_definition()
        session.register_tool(
            name=definition["function"]["name"],
            description=definition["function"]["description"],
            parameters=definition["function"]["parameters"],
            handler=_make_handler(tool),
        )
    logger.info(
        "已注册内置工具: %s",
        ", ".join(
            t["definition"]["function"]["name"] for t in session.registered_tools
        ),
    )


def _make_handler(tool) -> Any:
    """构造工具 handler：将 tool_call 的关键字参数打包为 dict 传给 execute。"""

    def handler(**kwargs: Any) -> Any:
        return tool.execute(kwargs)

    return handler