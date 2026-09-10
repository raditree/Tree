"""MCP 工作空间服务——把工作空间级检索能力以 MCP 形式暴露。

以「进程内 MCP server」形式提供：``build_server`` 构造标准 MCP server，
后端以内存流对接 ClientSession（见 ``mcp_tools.inproc_server``）。检索经
``WorkspaceIO`` 在执行环境内进行——cloud 走容器、local 走用户本地执行器、
ssh 走远端主机；服务端本身始终在后端进程内。

read / write / edit / terminal 是内置工具，不经 MCP 暴露；本服务仅保留
embed_search。
"""

import json
import logging
from typing import Any, Dict, List

from mcp.server.lowlevel import Server

from io_.workspace_io import WorkspaceIO
from mcp_tools.embed_search_tool import EmbedSearchTool
from mcp_tools.inproc_server import build_inproc_server

logger = logging.getLogger(__name__)

_EMPTY_SCHEMA: Dict[str, Any] = {"type": "object", "properties": {}}


def _tool_specs() -> List[Dict[str, Any]]:
    """把 EmbedSearchTool 的工具定义转成 MCP 工具规格（含参数 schema）。"""
    definition = EmbedSearchTool(None, "").get_tool_definition()
    fn = definition.get("function", definition) or definition
    return [
        {
            "name": fn.get("name", ""),
            "description": fn.get("description", ""),
            "inputSchema": fn.get("parameters")
            or fn.get("inputSchema")
            or _EMPTY_SCHEMA,
        }
    ]


def build_server(workspace_id: str, io: WorkspaceIO) -> Server:
    """构建工作空间服务的进程内 MCP server。

    :param workspace_id: 工作空间标识（进入 serverInfo）
    :param io: 工作空间 IO（cloud/local/ssh 三模式差异的唯一来源）
    """
    embed_tool = EmbedSearchTool(io, workspace_id)

    def _dispatch(tool_name: str, arguments: Dict[str, Any]) -> str:
        if tool_name == "embed_search":
            return json.dumps(embed_tool.execute(arguments), ensure_ascii=False)
        return json.dumps(
            {"success": False, "error": f"未知工具: {tool_name}"}, ensure_ascii=False
        )

    return build_inproc_server(
        name=f"workspace-{workspace_id or 'default'}",
        tool_specs=_tool_specs(),
        dispatch=_dispatch,
    )
