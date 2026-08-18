"""内置 terminal 工具 - 在工作空间内执行 shell 命令。

通过 :class:`core.workspace_io.WorkspaceIO` 执行命令（云端容器 / 本地目录），
避免经 MCP stdio 嵌套调用导致的解析错误。与 read/write/edit 工具同级，
统一走 LLM 工具循环的 tool_call 执行通道。
"""

import logging
from typing import Any, Dict

from core.workspace_io import WorkspaceIO

logger = logging.getLogger(__name__)


class TerminalTool:
    """terminal 工具 - 在工作空间内执行 shell 命令。"""

    def __init__(self, io: WorkspaceIO, workspace_id: str) -> None:
        """初始化 terminal 工具。

        :param io: 工作空间 IO 实现（云端/本地）
        :param workspace_id: 工作空间标识
        """
        self.io = io
        self.workspace_id = workspace_id

    def get_tool_definition(self) -> Dict[str, Any]:
        """返回 OpenAI function calling 格式的工具定义。"""
        return {
            "type": "function",
            "function": {
                "name": "terminal",
                "description": (
                    "在工作空间内执行 shell 命令，包括 git 命令。"
                    "命令在 /workspace 目录下执行。"
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "command": {
                            "type": "string",
                            "description": "要执行的 shell 命令",
                        },
                        "timeout": {
                            "type": "integer",
                            "description": "超时时间（秒），默认 30",
                        },
                    },
                    "required": ["command"],
                },
            },
        }

    def execute(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """执行 terminal 命令，在工作空间内运行 shell 命令。

        :param arguments: 工具参数，包含：
            - command: shell 命令（必填）
            - timeout: 超时秒数（可选，默认 30）
        :return: ``{"stdout": "...", "exit_code": N}``；命令为空时返回
                 ``{"error": "..."}``
        """
        if not isinstance(arguments, dict):
            return {"error": "参数必须是字典类型"}

        command = arguments.get("command", "")
        if not isinstance(command, str) or not command.strip():
            return {"error": "command 不能为空"}

        timeout = arguments.get("timeout", 30)
        if not isinstance(timeout, int) or isinstance(timeout, bool):
            timeout = 30
        timeout = max(1, min(timeout, 3600))

        result = self.io.exec_shell(self.workspace_id, command, timeout)

        if result.get("error"):
            return {"error": result["error"], "exit_code": -1}

        stdout = result.get("stdout", "")
        exit_code = result.get("exit_code", -1)
        # timeout 命令超时退出码为 124
        if exit_code == 124:
            logger.info(
                "terminal 工具命令超时: timeout=%ds, command=%s",
                timeout,
                command[:200],
            )
            return {
                "stdout": stdout,
                "exit_code": exit_code,
                "error": f"命令执行超时（{timeout} 秒）",
            }

        logger.info(
            "terminal 工具执行完成: exit_code=%s, command=%s",
            exit_code,
            command[:200],
        )
        return {"stdout": stdout, "exit_code": exit_code}
