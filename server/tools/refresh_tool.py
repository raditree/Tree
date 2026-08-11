"""内置 refresh 工具 - 刷新并返回所有可用的 MCP 工具。"""

import logging
from typing import Any, Dict, List, Optional

from tools.mcp_tool import MCPManager

logger = logging.getLogger(__name__)


class RefreshTool:
    """refresh 工具 - 刷新 MCP client 并返回所有可用的 MCP 工具。"""

    def __init__(self, mcp_manager: MCPManager) -> None:
        """初始化 refresh 工具。

        :param mcp_manager: MCP 服务管理器实例
        """
        self.mcp_manager = mcp_manager

    def get_tool_definition(self) -> Dict[str, Any]:
        """返回 OpenAI function calling 格式的工具定义。"""
        return {
            "type": "function",
            "function": {
                "name": "refresh",
                "description": "刷新 MCP client 并返回所有可用的 MCP 工具。",
                "parameters": {
                    "type": "object",
                    "properties": {},
                },
            },
        }

    def execute(
        self, arguments: Dict[str, Any], session: Optional[Any] = None
    ) -> Dict[str, Any]:
        """执行 refresh 命令，强制刷新并返回 MCP 工具列表。

        :param arguments: 工具参数（当前无参数）
        :param session: 保留参数，暂无用途
        :return: 包含 ``tools`` 列表与 ``count`` 的字典
        """
        tools = self.mcp_manager.get_tools(force=True)
        logger.info("refresh 工具刷新并返回所有 MCP 工具: %d 个", len(tools))

        # 仅保留 name, description, parameters 三个字段
        result_tools: List[Dict[str, Any]] = []
        for tool in tools:
            result_tools.append({
                "name": tool.get("name", ""),
                "description": tool.get("description", ""),
                "parameters": tool.get("parameters", {}),
            })

        return {"tools": result_tools, "count": len(result_tools)}