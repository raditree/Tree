"""内置 help 工具 - 列出所有可用的内置工具及 MCP 工具。"""

import logging

from core.config import get_config

logger = logging.getLogger(__name__)


class HelpTool:
    """内置 help 工具。

    列出所有已注册的内置工具及其描述，同时包含当前可用的 MCP 工具列表。
    """

    def __init__(
        self,
        registered_tools: list[dict] = None,
        mcp_manager: "MCPManager" = None,
    ) -> None:
        """初始化 help 工具。

        :param registered_tools: 已注册的工具定义列表，每项为 OpenAI function
            calling 格式的工具定义（或包含 ``definition`` 字段的注册项）
        :param mcp_manager: MCP 管理器实例，用于动态获取当前可用 MCP 工具；
            为 None 时退化为使用 ``mcp_tools`` 快照
        """
        self.registered_tools: list[dict] = (
            registered_tools if registered_tools is not None else []
        )
        self.mcp_manager = mcp_manager
        # 当前可用的 MCP 工具列表快照（无 mcp_manager 时的兜底，由 set_mcp_tools 注入）
        self.mcp_tools: list[dict] = []

    def get_tool_definition(self) -> dict:
        """返回 OpenAI function calling 格式的工具定义。"""
        return {
            "type": "function",
            "function": {
                "name": "help",
                "description": "列出所有可用的内置工具及其介绍",
                "parameters": {
                    "type": "object",
                    "properties": {},
                },
            },
        }

    def set_mcp_tools(self, mcp_tools: list[dict]) -> None:
        """设置当前可用的 MCP 工具列表。

        :param mcp_tools: MCP 工具列表，每项包含 name 与 description
        """
        self.mcp_tools = mcp_tools if mcp_tools is not None else []

    @staticmethod
    def _extract_name_desc(tool: dict) -> tuple[str, str]:
        """从工具定义中提取 name 与 description，兼容多种注册格式。

        支持以下格式：
        - ``{"definition": {"type": "function", "function": {"name":..., "description":...}}}``
          （llm.py 中 registered_tools 的注册项）
        - ``{"type": "function", "function": {"name":..., "description":...}}``
          （原始 OpenAI function calling 工具定义）
        - ``{"name":..., "description":...}``（扁平结构）
        """
        # 格式1: llm.py 中 registered_tools 的注册项
        if "definition" in tool:
            func = tool["definition"].get("function", {}) or {}
            return func.get("name", ""), func.get("description", "")
        # 格式2: 原始 OpenAI function calling 工具定义
        if "function" in tool:
            func = tool["function"] or {}
            return func.get("name", ""), func.get("description", "")
        # 格式3: 扁平结构
        return tool.get("name", ""), tool.get("description", "")

    @staticmethod
    def _resolve_config_path(config: dict, path: str):
        """按点号分隔路径读取配置值（如 ``docker.resource_limits.cpu``）。

        任意一级不存在时返回 None。
        """
        cur = config
        for part in path.split("."):
            if isinstance(cur, dict):
                cur = cur.get(part)
            else:
                return None
        return cur

    def _get_policy_lines(self) -> list[str]:
        """读取 ``help_policy`` 配置段，动态解析各限制项的当前值。

        值来源于 agents/docker 等源配置，随配置变化自动更新，不在此硬编码。
        """
        lines: list[str] = []
        try:
            policy = get_config().get("help_policy", []) or []
        except Exception:  # noqa: BLE001
            return lines
        for item in policy:
            name = item.get("name", "")
            path = item.get("path", "")
            value = self._resolve_config_path(get_config(), path)
            if name:
                shown = value if value is not None else "未配置"
                lines.append(f"- {name}: {shown}")
        return lines

    def execute(self, arguments: dict) -> dict:
        """执行 help 命令，返回所有可用工具的格式化列表。

        :param arguments: 工具参数（help 工具无参数）
        :return: 包含格式化工具列表字符串的字典
        """
        lines: list[str] = []

        # 团队规模与资源限制（披露给 LLM，避免其创建超出限制的成员/资源）
        policy_lines = self._get_policy_lines()
        if policy_lines:
            lines.append("【团队规模与资源限制】")
            lines.extend(policy_lines)
            lines.append("")

        lines += [
            "【MCP 工具使用流程】",
            "1. 调用 refresh：刷新并查看当前可用的 MCP 工具列表。",
            "2. 调用 mcp (action=call)：传入 tool_name 与 arguments 调用具体工具。",
            "   工具均在当前 agent 工作空间内执行。",
            "",
            "可用内置工具列表:",
        ]

        for tool in self.registered_tools:
            name, desc = self._extract_name_desc(tool)
            if name:
                lines.append(f"- {name}: {desc}" if desc else f"- {name}")

        # 追加 MCP 工具列表（动态获取，避免硬编码导致新注册工具缺失）
        lines.append("")
        lines.append("可用 MCP 工具列表:")
        mcp_tools = self._get_mcp_tools()
        if mcp_tools:
            for tool in mcp_tools:
                name = tool.get("name", "")
                desc = tool.get("description", "")
                if name:
                    lines.append(f"- {name}: {desc}" if desc else f"- {name}")
        else:
            lines.append("（暂无）")

        content = "\n".join(lines)
        logger.info(
            "help 工具执行完成, 内置工具 %d 个, MCP 工具 %d 个",
            len(self.registered_tools),
            len(mcp_tools),
        )
        return {"content": content}

    def _get_mcp_tools(self) -> list[dict]:
        """获取当前可用 MCP 工具列表。

        优先从 mcp_manager 动态获取（走工具缓存，不强制刷新）；
        无 mcp_manager 时回退到 mcp_tools 快照。
        """
        if self.mcp_manager is not None:
            try:
                return self.mcp_manager.get_tools() or []
            except Exception as exc:  # noqa: BLE001
                logger.warning("获取 MCP 工具列表失败: %s", exc)
                return []
        return list(self.mcp_tools)
