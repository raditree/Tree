"""内置 mcp 工具 - MCP 服务管理与工具调用框架。"""

import asyncio
import logging
import threading
from typing import Any

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

logger = logging.getLogger(__name__)


def _run_async(coro) -> Any:
    """在安全的事件循环上下文中运行协程。

    ``asyncio.run`` 不允许在已运行的 event loop 中调用。后端聊天处理运行在
    FastAPI 的 event loop 中（async 函数），而 LLM 工具 handler 是同步调用，
    此时若直接 ``asyncio.run`` 会触发
    "asyncio.run() cannot be called from a running event loop"。

    - 无 running loop（纯同步场景）：直接 ``asyncio.run``。
    - 有 running loop（FastAPI async 场景）：把协程提交到独立线程执行，
      线程内 ``asyncio.run`` 会创建新的 loop，安全。
    """
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        # 当前没有运行中的事件循环
        return asyncio.run(coro)

    # 有运行中的事件循环：在独立线程中执行
    result: "list[object]" = []

    def _runner() -> None:
        result.append(asyncio.run(coro))

    thread = threading.Thread(target=_runner, daemon=True)
    thread.start()
    thread.join()
    return result[0]


class MCPManager:
    """MCP 服务管理器。

    管理已注册的 MCP 服务，提供工具列表查询与工具调用分发能力。
    通过 mcp 2.0.0 SDK 以 stdio 方式连接各 MCP 服务。
    """

    def __init__(self) -> None:
        """初始化 MCP 服务注册表与会话缓存。"""
        # 服务注册表: name -> {"command":..., "args":[...], "env":{...}, "tools":[...]}
        self.services: dict[str, dict] = {}
        # 会话缓存（预留，当前采用每次新建连接的简单方案，后续可优化为长连接）
        self._sessions: dict[str, ClientSession] = {}

    def register_service(self, name: str, config: dict) -> None:
        """注册一个 MCP 服务。

        :param name: 服务名称
        :param config: 服务配置，包含：
            - command: 启动命令（如 ``npx``、``python``）
            - args: 参数列表
            - env: 环境变量
        """
        self.services[name] = {
            "command": config.get("command", ""),
            "args": list(config.get("args", [])),
            "env": dict(config.get("env", {})),
            # 已发现的工具列表缓存（由 MCP SDK 连接后填充）
            "tools": [],
        }
        logger.info(
            "已注册 MCP 服务: %s (command=%s, args=%s)",
            name,
            self.services[name]["command"],
            self.services[name]["args"],
        )

    def list_services(self) -> list[str]:
        """返回所有已注册的 MCP 服务名称。"""
        return list(self.services.keys())

    def get_tools(self, service_name: str = None, force: bool = False) -> list[dict]:
        """获取 MCP 工具列表。

        :param service_name: 指定服务名称。为 None 时返回所有服务的工具。
        :param force: 是否强制重新连接服务拉取。False 时复用已缓存的服务工具列表，
            避免每次调用都重新启动 stdio 子进程。
        :return: 工具列表，每项包含 name、description、parameters
        """
        return _run_async(self._get_tools_async(service_name, force=force))

    async def _get_tools_async(
        self, service_name: str = None, force: bool = False
    ) -> list[dict]:
        """获取 MCP 工具列表的异步实现。"""
        tools: list[dict] = []

        if service_name is not None:
            service = self.services.get(service_name)
            if service is None:
                logger.warning("未找到 MCP 服务: %s", service_name)
                return []
            service_tools = await self._fetch_tools_from_service(
                service_name, service, force=force
            )
            service["tools"] = service_tools
            return service_tools

        # 返回所有服务的工具
        for name, service in self.services.items():
            service_tools = await self._fetch_tools_from_service(
                name, service, force=force
            )
            service["tools"] = service_tools
            tools.extend(service_tools)
        return tools

    async def _fetch_tools_from_service(
        self, service_name: str, service: dict, force: bool = False
    ) -> list[dict]:
        """连接指定 MCP 服务并获取其工具列表。

        连接失败时记录错误日志并返回空列表，不影响其他服务。
        将 MCP 工具格式转换为 OpenAI function calling 格式。
        已缓存工具列表且非强制刷新时直接复用缓存，避免重复启动子进程。
        """
        cached = service.get("tools")
        if cached and not force:
            logger.debug("MCP 服务 %s 命中工具缓存: %d 个", service_name, len(cached))
            return list(cached)

        command = service.get("command", "")
        if not command:
            logger.error("MCP 服务 %s 未配置 command，跳过", service_name)
            return []

        # env 为空字典时传 None，使子进程继承父进程环境变量
        params = StdioServerParameters(
            command=command,
            args=service.get("args", []),
            env=service.get("env") or None,
        )

        try:
            async with stdio_client(params) as (read, write):
                async with ClientSession(read, write) as session:
                    await session.initialize()
                    result = await session.list_tools()
        except Exception as e:  # 连接或通信异常，优雅降级
            logger.error("连接 MCP 服务 %s 获取工具失败: %s", service_name, e)
            return []

        tools: list[dict] = []
        for tool in result.tools:
            tools.append({
                "name": tool.name,
                "description": tool.description,
                # mcp 2.0 的 Tool 对象使用 input_schema（snake_case）
                "parameters": getattr(tool, "input_schema", None)
                or getattr(tool, "inputSchema", None),
            })
        logger.info("MCP 服务 %s 返回 %d 个工具", service_name, len(tools))
        return tools

    def call_tool(self, tool_name: str, arguments: dict) -> dict:
        """调用指定的 MCP 工具。

        查找 tool_name 所属的 MCP 服务，通过 MCP SDK 执行工具调用。

        :param tool_name: 工具名称
        :param arguments: 工具参数
        :return: 执行结果字典；找不到工具时返回错误信息
        """
        return _run_async(self._call_tool_async(tool_name, arguments))

    async def _call_tool_async(self, tool_name: str, arguments: dict) -> dict:
        """调用指定 MCP 工具的异步实现。"""
        # 查找工具所属的服务
        target_service_name: str | None = None
        for name, service in self.services.items():
            for tool in service.get("tools", []):
                if tool.get("name") == tool_name:
                    target_service_name = name
                    break
            if target_service_name is not None:
                break

        # 缓存中未找到时，刷新一次工具列表后重试
        if target_service_name is None:
            logger.info("缓存中未找到工具 %s，刷新工具列表后重试", tool_name)
            await self._get_tools_async()
            for name, service in self.services.items():
                for tool in service.get("tools", []):
                    if tool.get("name") == tool_name:
                        target_service_name = name
                        break
                if target_service_name is not None:
                    break

        if target_service_name is None:
            logger.warning("未找到 MCP 工具: %s", tool_name)
            return {"error": f"未找到 MCP 工具: {tool_name}"}

        service = self.services[target_service_name]
        command = service.get("command", "")
        if not command:
            logger.error(
                "MCP 服务 %s 未配置 command，无法调用工具 %s",
                target_service_name,
                tool_name,
            )
            return {"error": f"MCP 服务 {target_service_name} 未配置 command"}

        params = StdioServerParameters(
            command=command,
            args=service.get("args", []),
            env=service.get("env") or None,
        )

        logger.info(
            "调用 MCP 工具: %s (service=%s, arguments=%s)",
            tool_name,
            target_service_name,
            arguments,
        )

        try:
            async with stdio_client(params) as (read, write):
                async with ClientSession(read, write) as session:
                    await session.initialize()
                    result = await session.call_tool(tool_name, arguments)
        except Exception as e:  # 连接或调用异常，优雅降级
            logger.error(
                "调用 MCP 工具 %s 失败 (service=%s): %s",
                tool_name,
                target_service_name,
                e,
            )
            return {"error": f"调用 MCP 工具 {tool_name} 失败: {e}"}

        # 从结果中提取文本内容
        text = self._extract_text_content(result)
        return {
            "tool_name": tool_name,
            "service": target_service_name,
            "content": text,
            "isError": getattr(result, "isError", False),
        }

    @staticmethod
    def _extract_text_content(result) -> str:
        """从 MCP 调用结果中提取文本内容。

        MCP 结果的 content 为内容项列表，提取其中 type=text 的文本并拼接。
        """
        texts: list[str] = []
        content = getattr(result, "content", None) or []
        for item in content:
            if getattr(item, "type", None) == "text":
                text = getattr(item, "text", None)
                if text:
                    texts.append(text)
        return "\n".join(texts)


class MCPTool:
    """内置 mcp 工具 - 作为 tool_call 的封装。

    通过 ``action`` 参数区分 ``help``（查看可用 MCP 工具）与 ``call``（调用指定工具）。
    """

    def __init__(self, mcp_manager: MCPManager) -> None:
        """初始化 mcp 工具。

        :param mcp_manager: MCP 服务管理器实例
        """
        self.mcp_manager = mcp_manager

    def get_tool_definition(self) -> dict:
        """返回 OpenAI function calling 格式的工具定义。"""
        return {
            "type": "function",
            "function": {
                "name": "mcp",
                "description": "调用 MCP 工具。传入 'help' 查看所有可用 MCP 工具",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "action": {
                            "type": "string",
                            "enum": ["help", "call"],
                            "description": "操作类型: 'help' 查看可用 MCP 工具, 'call' 调用指定工具",
                        },
                        "tool_name": {
                            "type": "string",
                            "description": "要调用的工具名称（action=call 时必填）",
                        },
                        "arguments": {
                            "type": "object",
                            "description": "工具参数（action=call 时必填）",
                        },
                    },
                    "required": ["action"],
                },
            },
        }

    def execute(self, arguments: dict) -> dict:
        """执行 mcp 命令。

        :param arguments: 工具参数，包含：
            - action: 操作类型（``help`` 或 ``call``）
            - tool_name: 工具名称（action=call 时必填）
            - arguments: 工具参数（action=call 时必填）
        :return: 执行结果字典
        """
        action = arguments.get("action", "")

        if action == "help":
            tools = self.mcp_manager.get_tools()
            if not tools:
                return {"content": "当前没有可用的 MCP 工具"}
            lines = ["可用 MCP 工具列表:"]
            for tool in tools:
                name = tool.get("name", "")
                desc = tool.get("description", "")
                if name:
                    lines.append(f"- {name}: {desc}" if desc else f"- {name}")
            return {"content": "\n".join(lines)}

        if action == "call":
            tool_name = arguments.get("tool_name", "")
            if not tool_name:
                return {"error": "action=call 时必须提供 tool_name"}
            tool_args = arguments.get("arguments", {}) or {}
            return self.mcp_manager.call_tool(tool_name, tool_args)

        return {"error": f"未知的 action: {action}，支持 'help' 或 'call'"}
