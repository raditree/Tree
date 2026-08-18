"""MCP stdio server - 将工作空间搜索工具以 MCP 形式暴露。

通过环境变量 ``WORKSPACE_ID`` 绑定到指定 agent 的 Docker 工作空间，
供后端 MCPManager 以 stdio 方式连接、列出并调用。
read / write / edit / terminal 已改为内置工具（不经 MCP），
本服务仅保留 embed_search。
"""

import asyncio
import json
import logging
import os
import sys

from mcp.server.mcpserver import MCPServer

# 确保 server 目录在 sys.path 中，便于导入 core / mcp_tools
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from core.docker_manager import DockerManager  # noqa: E402
from core.workspace_io import CloudWorkspaceIO  # noqa: E402
from mcp_tools.embed_search_tool import EmbedSearchTool  # noqa: E402

logger = logging.getLogger(__name__)


def _build_server() -> MCPServer:
    """构建暴露工作空间基础工具的 MCP server。"""
    workspace_id = os.environ.get("WORKSPACE_ID", "")
    docker_manager = DockerManager()
    io = CloudWorkspaceIO(docker_manager)

    embed_tool = EmbedSearchTool(io, workspace_id)

    server = MCPServer(
        name=f"workspace-{workspace_id or 'default'}",
        version="1.0.0",
    )

    def _dump(result: dict) -> str:
        return json.dumps(result, ensure_ascii=False)

    def _embed_search(query: str, top_k: int = 5) -> str:
        return _dump(embed_tool.execute({"query": query, "top_k": top_k}))

    server.add_tool(
        _embed_search,
        name="embed_search",
        description="在工作空间内搜索文本（当前为 grep 实现）",
    )
    return server


def main() -> None:
    """启动 MCP stdio server。"""
    logging.basicConfig(level=logging.INFO)
    server = _build_server()
    logger.info("启动 MCP server: %s", server.name)
    asyncio.run(server.run_stdio_async())


if __name__ == "__main__":
    main()