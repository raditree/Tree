"""内置 mcp 工具 - MCP 服务管理与工具调用框架（标准 MCP 客户端）。

cloud / local / ssh 三种模式统一经 MCP 协议访问服务，差异只在传输方式：

- 内置服务（workspace / document）：MCP server 由 ``server_factory`` 在本
  进程内构建，经 SDK 内存流（``mcp.shared.memory``）与 ``ClientSession``
  对接。服务端逻辑始终在后端，执行落点由 WorkspaceIO 决定（cloud 容器 /
  local 用户本地执行器 / ssh 远端主机）。
- 外部服务：以 stdio 子进程方式连接。cloud 由后端直接启动子进程；local /
  ssh 由宿主进程（前端本地执行器 / 远端主机）启动，stdio 帧经 WS / SSH
  隧道透传到本客户端。

工具以 ``mcp__<service>__<tool>`` 命名空间对模型暴露（见 ``tool/__init__.py``）。
"""

import asyncio
import logging
import threading
from contextlib import asynccontextmanager
from typing import Any, AsyncIterator, Optional

import anyio
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp.server.lowlevel import Server
from mcp.shared.memory import create_client_server_memory_streams

from mcp_tools.frontend_tunnel import tunnel_client
from prompt import versions

logger = logging.getLogger(__name__)

# 工具对模型暴露的命名空间：mcp__<service>__<tool>
_NAME_PREFIX = "mcp"
_NAME_SEP = "__"


def namespaced_tool_name(service: str, tool: str) -> str:
    """返回工具对模型暴露的命名空间化名称。"""
    return f"{_NAME_PREFIX}{_NAME_SEP}{service}{_NAME_SEP}{tool}"


def parse_namespaced_tool_name(name: str) -> Optional[tuple]:
    """解析 ``mcp__<service>__<tool>``，返回 ``(service, tool)``。

    非该形态（如裸工具名）返回 None。
    """
    parts = name.split(_NAME_SEP)
    if len(parts) < 3 or parts[0] != _NAME_PREFIX:
        return None
    return parts[1], _NAME_SEP.join(parts[2:])


def _run_async(coro) -> Any:
    """在安全的事件循环上下文中运行协程（异常向调用方传播）。

    ``asyncio.run`` 不允许在已运行的 event loop 中调用。后端聊天处理运行在
    FastAPI 的 event loop 中（async 函数），而 LLM 工具 handler 是同步调用，
    此时若直接 ``asyncio.run`` 会触发
    "asyncio.run() cannot be called from a running event loop"。

    - 无 running loop（纯同步场景）：直接 ``asyncio.run``。
    - 有 running loop（FastAPI async 场景）：把协程提交到独立线程执行，
      线程内 ``asyncio.run`` 会创建新的 loop，安全。协程内部的 WS 推送等
      跨线程操作由对应组件自行绑定主循环（见 LocalExecutorClient.bind_loop）。

    协程内抛出的异常在调用方线程内原样抛出，不再静默丢失。
    """
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        # 当前没有运行中的事件循环
        return asyncio.run(coro)

    # 有运行中的事件循环：在独立线程中执行
    result: "list[Any]" = []
    failure: "list[BaseException]" = []

    def _runner() -> None:
        try:
            result.append(asyncio.run(coro))
        except BaseException as exc:  # noqa: BLE001 - 需跨线程回传给调用方
            failure.append(exc)

    thread = threading.Thread(target=_runner, daemon=True)
    thread.start()
    thread.join()
    if failure:
        raise failure[0]
    return result[0]


@asynccontextmanager
async def _open_session(service: dict) -> AsyncIterator[ClientSession]:
    """按服务配置打开一个已 ``initialize`` 的 MCP 会话（统一入口）。

    - 提供 ``server_factory`` 时走内存流：server 与 client 同进程，
      由同一个事件循环内的任务组并发驱动（内存流缓冲为 1，必须并发）。
    - 提供 ``tunnel`` 时走宿主隧道：子进程由前端执行器（用户本机）/ 远端主机
      拉起，stdio 帧经反向 WS / SSH 透传（见 ``mcp_tools.frontend_tunnel``）。
    - 否则走 stdio：子进程由后端直接启动，服务由 ``command``/``args``/``env``
      描述。
    """
    factory = service.get("server_factory")
    if factory is not None:
        server: Server = factory()
        async with create_client_server_memory_streams() as (client_streams, server_streams):
            async with anyio.create_task_group() as task_group:
                task_group.start_soon(
                    lambda: server.run(
                        server_streams[0],
                        server_streams[1],
                        server.create_initialization_options(),
                    )
                )
                async with ClientSession(*client_streams) as session:
                    await session.initialize()
                    try:
                        yield session
                    finally:
                        task_group.cancel_scope.cancel()
        return

    tunnel = service.get("tunnel")
    if tunnel is not None:
        async with tunnel_client(
            tunnel,
            command=service.get("command", ""),
            args=service.get("args", []),
            env=service.get("env") or {},
            needs_confirmation=bool(service.get("needs_confirmation")),
        ) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                yield session
        return

    params = StdioServerParameters(
        command=service.get("command", ""),
        args=service.get("args", []),
        # env 为空字典时传 None，使子进程继承父进程环境变量
        env=service.get("env") or None,
    )
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            yield session


class MCPManager:
    """MCP 服务管理器。

    管理已注册的 MCP 服务，提供工具列表查询与工具调用分发能力。
    所有服务都经 mcp SDK 的 ``ClientSession`` 调用：内置服务走进程内内存流，
    外部服务走 stdio（后端直连子进程，或 local / ssh 模式下经宿主隧道透传）。
    """

    def __init__(self) -> None:
        """初始化 MCP 服务注册表。"""
        # 服务注册表: name -> {"server_factory"|"command"/"args"/"env", "tools":[...]}
        self.services: dict[str, dict] = {}

    def register_service(self, name: str, config: dict) -> None:
        """注册一个 MCP 服务。

        :param name: 服务名称
        :param config: 服务配置，三选一：
            - server_factory: 进程内服务工厂 ``() -> Server``（内置服务用），
              经 SDK 内存流对接；
            - tunnel: 宿主隧道（``FrontendTunnel`` 实例），子进程由前端执行器
              （用户本机）/ 远端主机拉起，stdio 帧经反向 WS / SSH 透传；
            - command / args / env: 外部服务，由后端以 stdio 子进程方式连接。
        """
        self.services[name] = {
            "command": config.get("command", ""),
            "args": list(config.get("args", [])),
            "env": dict(config.get("env", {})),
            "server_factory": config.get("server_factory"),
            "tunnel": config.get("tunnel"),
            # 服务作用域（"" / server / local / ssh）与授权提示：仅供展示与
            # 隧道侧首次确认使用，不参与本管理器的连接决策。
            "scope": config.get("scope", "") or "",
            "needs_confirmation": bool(config.get("needs_confirmation")),
            # 已发现的工具列表缓存（由 MCP SDK 连接后填充）
            "tools": [],
        }
        logger.info(
            "已注册 MCP 服务: %s (in_process=%s, tunnel=%s, command=%s, args=%s)",
            name,
            self.services[name]["server_factory"] is not None,
            getattr(self.services[name]["tunnel"], "mode", None),
            self.services[name]["command"],
            self.services[name]["args"],
        )

    def list_services(self) -> list[str]:
        """返回所有已注册的 MCP 服务名称。"""
        return list(self.services.keys())

    def unregister_service(self, name: str) -> bool:
        """注销一个 MCP 服务。

        :param name: 服务名称
        :return: 是否存在并被删除
        """
        if name in self.services:
            self.services.pop(name, None)
            logger.info("已注销 MCP 服务: %s", name)
            return True
        return False

    def get_service_info(self, name: str) -> Optional[dict]:
        """返回服务详情（脱敏：env 仅列键名，不含值）。

        :param name: 服务名称
        :return: 服务信息字典；服务不存在时返回 None
        """
        service = self.services.get(name)
        if service is None:
            return None
        return {
            "name": name,
            "command": service.get("command", ""),
            "args": list(service.get("args", [])),
            "env_keys": list(service.get("env", {}).keys()),
            "in_process": service.get("server_factory") is not None,
            # 执行落点：in_process / local（用户本机隧道）/ ssh（远端主机隧道）/
            # server（后端进程直连 stdio）
            "host": self._host_of(service),
            "scope": service.get("scope", "") or "",
            "tool_count": len(service.get("tools", []) or []),
        }

    @staticmethod
    def _host_of(service: dict) -> str:
        """返回服务的执行落点标识（用于展示与排障）。"""
        if service.get("server_factory") is not None:
            return "in_process"
        tunnel = service.get("tunnel")
        if tunnel is not None:
            return str(getattr(tunnel, "mode", "") or "local")
        return "server"

    def get_tools(self, service_name: str = None, force: bool = False) -> list[dict]:
        """获取 MCP 工具列表。

        :param service_name: 指定服务名称。为 None 时返回所有服务的工具。
        :param force: 是否强制重新连接服务拉取。False 时复用已缓存的工具列表，
            避免每次调用都重新启动 stdio 子进程。
        :return: 工具列表，每项包含 name、description、parameters、
            service、mcp_name（对模型暴露的命名空间化名称）
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
        已缓存工具列表且非强制刷新时直接复用缓存，避免重复启动子进程。
        """
        cached = service.get("tools")
        if cached and not force:
            logger.debug("MCP 服务 %s 命中工具缓存: %d 个", service_name, len(cached))
            return list(cached)

        if service.get("server_factory") is None and not service.get("command"):
            logger.error("MCP 服务 %s 未配置 server_factory/command，跳过", service_name)
            return []

        try:
            async with _open_session(service) as session:
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
                or getattr(tool, "inputSchema", None)
                or {},
                "service": service_name,
                "mcp_name": namespaced_tool_name(service_name, tool.name),
            })
        logger.info("MCP 服务 %s 返回 %d 个工具", service_name, len(tools))
        return tools

    def call_tool(
        self, tool_name: str, arguments: dict, service_name: str = ""
    ) -> dict:
        """调用指定的 MCP 工具。

        :param tool_name: 工具名称，可带命名空间（``mcp__<service>__<tool>``）
            或不带（此时按已发现的工具列表定位所属服务）
        :param arguments: 工具参数
        :param service_name: 服务名称；给定时直接在该服务内调用
        :return: 执行结果字典；找不到工具时返回错误信息
        """
        return _run_async(self._call_tool_async(tool_name, arguments, service_name))

    async def _call_tool_async(
        self, tool_name: str, arguments: dict, service_name: str = ""
    ) -> dict:
        """调用指定 MCP 工具的异步实现。"""
        parsed = parse_namespaced_tool_name(tool_name)
        if parsed:
            service_name, tool_name = parsed

        if service_name:
            if service_name not in self.services:
                logger.warning("未找到 MCP 服务: %s", service_name)
                return {"error": f"未找到 MCP 服务: {service_name}"}
            target_service_name = service_name
        else:
            target_service_name = await self._resolve_service(tool_name)
            if not target_service_name:
                logger.warning("未找到 MCP 工具: %s", tool_name)
                return {"error": f"未找到 MCP 工具: {tool_name}"}

        service = self.services[target_service_name]
        logger.info(
            "调用 MCP 工具: %s/%s (arguments=%s)",
            target_service_name,
            tool_name,
            arguments,
        )

        try:
            async with _open_session(service) as session:
                result = await session.call_tool(tool_name, arguments)
        except Exception as e:  # 连接或调用异常，优雅降级
            logger.error(
                "调用 MCP 工具 %s/%s 失败: %s", target_service_name, tool_name, e
            )
            return {"error": f"调用 MCP 工具 {tool_name} 失败: {e}"}

        return {
            "tool_name": tool_name,
            "service": target_service_name,
            "content": self._extract_text_content(result),
            # mcp 2.0 的 CallToolResult 字段为 is_error（无 isError 属性）
            "isError": bool(getattr(result, "is_error", False)),
        }

    async def _resolve_service(self, tool_name: str) -> str:
        """按裸工具名定位所属服务；缓存未命中时刷新一次工具列表再重试。"""
        for attempt in range(2):
            for name, service in self.services.items():
                for tool in service.get("tools", []) or []:
                    if tool.get("name") == tool_name:
                        return name
            if attempt == 0:
                logger.info("缓存中未找到工具 %s，刷新工具列表后重试", tool_name)
                await self._get_tools_async()
        return ""

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
    MCP 工具本身已按 ``mcp__<service>__<tool>`` 命名空间注入模型工具列表，
    本工具保留 ``help`` 作为发现入口、``call`` 作为兜底调用路径。
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
                "description": versions.active_tool_description("mcp"),
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
                            "description": (
                                "要调用的工具名称（action=call 时必填），"
                                "形如 mcp__<服务名>__<工具名>"
                            ),
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
                name = tool.get("mcp_name") or tool.get("name", "")
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
