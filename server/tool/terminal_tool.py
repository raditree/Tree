"""内置 terminal 工具 - 在工作空间内执行 shell 命令。

通过 :class:`core.workspace_io.WorkspaceIO` 执行命令（云端容器 / 本地目录），
避免经 MCP stdio 嵌套调用导致的解析错误。与 read/write/edit 工具同级，
统一走 LLM 工具循环的 tool_call 执行通道。
"""

import logging
from typing import Any, Dict

from io_.workspace_io import WorkspaceIO, run_io

logger = logging.getLogger(__name__)

# terminal 工具默认执行超时（秒）：长命令（构建/测试/安装）默认给 120s，
# 避免无限阻塞 tool loop；显式传入 timeout 时仍可覆盖（1-3600s）。
_DEFAULT_TIMEOUT = 120
_MAX_TIMEOUT = 3600


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
                    "[在工作空间执行 shell 命令（含 git）] | "
                    "贡献维度: 环境执行（运行构建/测试/安装/文件操作，验证与运维的唯一途径）\n"
                    "何时使用: 运行构建与测试（验证改动）；安装依赖；"
                    "git 操作；文件/目录管理（ls/mkdir/rm）；运行脚本；查看环境\n"
                    "何时不用: 读/写/改文件内容用 read/write/edit（更精确、可追溯）；"
                    "仅需内容查看时避免用 cat 取代 read\n"
                    "前置依赖: 命令须符合当前执行环境的 shell 语法"
                    "（cloud=sh；local Windows=cmd.exe；ssh=远端 shell，见 system prompt）"
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
                            "description": "超时时间（秒），默认 120；超时返回错误并继续，避免无限阻塞",
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
            - timeout: 超时秒数（可选，默认 120）
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

        result = run_io(self.io.exec_shell(self.workspace_id, command, timeout))

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
