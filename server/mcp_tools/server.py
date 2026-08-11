"""MCP stdio server - 将工作空间基础工具以 MCP 形式暴露。

通过环境变量 ``WORKSPACE_ID`` 绑定到指定 agent 的 Docker 工作空间，
供后端 MCPManager 以 stdio 方式连接、列出并调用这些工具。
覆盖工具：read / write / edit / terminal / embed_search。
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
from mcp_tools.edit_tool import EditTool  # noqa: E402
from mcp_tools.embed_search_tool import EmbedSearchTool  # noqa: E402
from mcp_tools.read_tool import ReadTool  # noqa: E402
from mcp_tools.terminal_tool import TerminalTool  # noqa: E402
from mcp_tools.write_tool import WriteTool  # noqa: E402

logger = logging.getLogger(__name__)


def _build_server() -> MCPServer:
    """构建暴露工作空间基础工具的 MCP server。"""
    workspace_id = os.environ.get("WORKSPACE_ID", "")
    docker_manager = DockerManager()

    read_tool = ReadTool(docker_manager, workspace_id)
    write_tool = WriteTool(docker_manager, workspace_id)
    edit_tool = EditTool(docker_manager, workspace_id)
    terminal_tool = TerminalTool(docker_manager, workspace_id)
    embed_tool = EmbedSearchTool(docker_manager, workspace_id)

    server = MCPServer(
        name=f"workspace-{workspace_id or 'default'}",
        version="1.0.0",
    )

    def _dump(result: dict) -> str:
        return json.dumps(result, ensure_ascii=False)

    def _read(file_path: str, encoding: str = "utf-8") -> str:
        return _dump(read_tool.execute({"file_path": file_path, "encoding": encoding}))

    def _write(file_path: str, content: str) -> str:
        return _dump(write_tool.execute({"file_path": file_path, "content": content}))

    def _edit(file_path: str, old_text: str, new_text: str) -> str:
        return _dump(
            edit_tool.execute({
                "file_path": file_path,
                "old_text": old_text,
                "new_text": new_text,
            })
        )

    def _terminal(command: str, timeout: int = 30) -> str:
        return _dump(
            terminal_tool.execute({"command": command, "timeout": timeout})
        )

    def _embed_search(query: str, top_k: int = 5) -> str:
        return _dump(embed_tool.execute({"query": query, "top_k": top_k}))

    server.add_tool(_read, name="read", description="读取工作空间内指定文件的内容")
    server.add_tool(
        _write, name="write", description="向工作空间内写入文件，自动创建父目录"
    )
    server.add_tool(
        _edit,
        name="edit",
        description="对工作空间内文件执行精确字符串替换，old_text 必须唯一匹配",
    )
    server.add_tool(
        _terminal,
        name="terminal",
        description="在工作空间容器内执行 shell 命令，包括 git 命令",
    )
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