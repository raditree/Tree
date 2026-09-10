"""进程内 MCP server 适配器。

把「显式工具规格 + 分发函数」包装成一个标准 MCP server（mcp SDK 的
lowlevel ``Server``），由后端以内存流方式与 ``ClientSession`` 对接
（``mcp.shared.memory.create_client_server_memory_streams``）。

这样 workspace / document 等内置能力在 cloud / local / ssh 三种模式下都
走真实 MCP 协议（initialize / tools/list / tools/call），差异只体现在背后
的 WorkspaceIO；不再绕过协议直接调用 Python 函数。

采用 lowlevel ``Server`` 而非高层 ``MCPServer`` 的原因：内置工具的参数
schema 是版本化的显式 JSON Schema（含 enum / required / 中文描述），
不能由函数签名自动推导。
"""

import json
import logging
from typing import Any, Callable, Dict, List

from mcp import types
from mcp.server.lowlevel import Server

logger = logging.getLogger(__name__)

# 工具分发签名：(tool_name, arguments) -> 结果字符串
Dispatch = Callable[[str, Dict[str, Any]], str]

_EMPTY_SCHEMA: Dict[str, Any] = {"type": "object", "properties": {}}


def to_call_tool_result(raw: Any) -> types.CallToolResult:
    """把工具返回结果规范化为 ``CallToolResult``。

    内置工具存在两种返回形态：完整的 ``CallToolResult`` JSON（含 content
    列表），以及业务结果 JSON（如 ``{"success": false, "error": ...}``）。
    前者直接解析，后者包装为文本内容，并把 ``success=false`` 映射为
    ``isError``（MCP 客户端依赖该字段判断调用是否失败）。
    """
    text = raw if isinstance(raw, str) else json.dumps(raw, ensure_ascii=False)
    try:
        parsed = json.loads(text)
    except (TypeError, ValueError):
        parsed = None
    if isinstance(parsed, dict) and isinstance(parsed.get("content"), list):
        try:
            return types.CallToolResult.model_validate(parsed)
        except Exception as exc:  # noqa: BLE001 - 结构异常时退化为文本结果
            logger.warning("CallToolResult 解析失败，退化为文本结果: %s", exc)
    return types.CallToolResult(
        content=[types.TextContent(type="text", text=text)],
        isError=isinstance(parsed, dict) and parsed.get("success") is False,
    )


def build_inproc_server(
    name: str,
    tool_specs: List[Dict[str, Any]],
    dispatch: Dispatch,
    version: str = "1.0.0",
) -> Server:
    """构建一个在进程内运行的标准 MCP server。

    :param name: 服务名（出现在 ``initialize`` 的 serverInfo 中）
    :param tool_specs: 工具规格列表，每项含 ``name`` / ``description`` /
        ``inputSchema``（显式 JSON Schema，原样透传给客户端）
    :param dispatch: 工具分发函数 ``(tool_name, arguments) -> 结果字符串``
    :param version: 服务版本
    """

    async def _on_list_tools(ctx: Any, params: Any) -> types.ListToolsResult:
        return types.ListToolsResult(
            tools=[
                types.Tool(
                    name=spec["name"],
                    description=spec.get("description", ""),
                    inputSchema=spec.get("inputSchema") or _EMPTY_SCHEMA,
                )
                for spec in tool_specs
            ]
        )

    async def _on_call_tool(ctx: Any, params: Any) -> types.CallToolResult:
        arguments = getattr(params, "arguments", None) or {}
        return to_call_tool_result(dispatch(params.name, arguments))

    return Server(
        name,
        version=version,
        on_list_tools=_on_list_tools,
        on_call_tool=_on_call_tool,
    )
