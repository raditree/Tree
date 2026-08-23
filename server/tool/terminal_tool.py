"""内置 terminal 工具 - 在工作空间内执行 shell 命令。

通过 :class:`core.workspace_io.WorkspaceIO` 执行命令（云端容器 / 本地目录），
避免经 MCP stdio 嵌套调用导致的解析错误。与 read/write/edit 工具同级，
统一走 LLM 工具循环的 tool_call 执行通道。
"""

import logging
from typing import Any, Dict, Optional

from io_.workspace_io import WorkspaceIO, run_io
from prompt import versions
from tool.hook_manager import get_hook_manager

logger = logging.getLogger(__name__)

# terminal 工具默认执行超时（秒）：长命令（构建/测试/安装）默认给 120s，
# 避免无限阻塞 tool loop；显式传入 timeout 时仍可覆盖（1-3600s）。
# hook 模式不受本超时约束（后台独立进程/线程，无时长上限）。
_DEFAULT_TIMEOUT = 120
_MAX_TIMEOUT = 3600


class TerminalTool:
    """terminal 工具 - 在工作空间内执行 shell 命令。"""

    def __init__(
        self,
        io: WorkspaceIO,
        workspace_id: str,
        hook_callback: Optional[Any] = None,
    ) -> None:
        """初始化 terminal 工具。

        :param io: 工作空间 IO 实现（云端/本地/SSH）
        :param workspace_id: 工作空间标识
        :param hook_callback: hook 模式完成回调（由 chat.py 注入，用于唤醒
                              发起该命令的 agent 续跑）
        """
        self.io = io
        self.workspace_id = workspace_id
        self.hook_callback = hook_callback

    def get_tool_definition(self) -> Dict[str, Any]:
        """返回 OpenAI function calling 格式的工具定义。"""
        return {
            "type": "function",
            "function": {
                "name": "terminal",
                "description": versions.active_tool_description("terminal"),
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
                        "hook": {
                            "type": "boolean",
                            "description": (
                                "true 则以后台 hook 模式启动命令：输出实时重定向到 "
                                "output_file，工具立即返回（不阻塞），命令结束后会自动"
                                "收到 [terminal hook] 提示继续任务。适用于构建/测试/长"
                                "脚本等长任务"
                            ),
                        },
                        "output_file": {
                            "type": "string",
                            "description": (
                                "hook 模式下的输出重定向文件（工作空间相对路径，如 "
                                ".output/xxx.log）；缺省自动派生 .output/hook_<id>.log"
                            ),
                        },
                        "hook_action": {
                            "type": "string",
                            "enum": ["status", "cancel"],
                            "description": (
                                "hook 任务管理动作：status=查询后台任务状态；"
                                "cancel=取消后台任务（需配合 task_id）"
                            ),
                        },
                        "task_id": {
                            "type": "string",
                            "description": "hook 任务的 task_id（status/cancel 时使用）",
                        },
                    },
                    "required": ["command"],
                },
            },
        }

    def execute(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """执行 terminal 命令，在工作空间内运行 shell 命令。

        :param arguments: 工具参数，包含：
            - command: shell 命令（必填，status/cancel 时可为空串）
            - timeout: 超时秒数（可选，默认 120）
            - hook: bool，true 则后台启动（hook 模式）
            - output_file: hook 输出重定向文件（可选）
            - hook_action: status/cancel 管理后台任务
            - task_id: status/cancel 用
        :return: ``{"stdout": "...", "exit_code": N}``；命令为空时返回
                 ``{"error": "..."}``
        """
        if not isinstance(arguments, dict):
            return {"error": "参数必须是字典类型"}

        hook_manager = get_hook_manager()
        hook_action = arguments.get("hook_action")
        task_id = arguments.get("task_id", "")

        # 分支 1/2：hook 任务查询 / 取消
        if hook_action == "status":
            if not task_id:
                return {"error": "hook_action=status 需要提供 task_id"}
            return hook_manager.status(task_id)
        if hook_action == "cancel":
            if not task_id:
                return {"error": "hook_action=cancel 需要提供 task_id"}
            return hook_manager.cancel(task_id)

        command = arguments.get("command", "")
        if not isinstance(command, str) or not command.strip():
            return {"error": "command 不能为空"}

        # 分支 3：hook 模式后台启动（立即返回，不阻塞 tool loop）
        hook = arguments.get("hook", False)
        if isinstance(hook, str):
            hook = hook.strip().lower() in ("true", "1", "yes")
        if hook:
            output_file = arguments.get("output_file", "") or ""
            if not isinstance(output_file, str):
                output_file = ""
            result = hook_manager.start(
                self.io, self.workspace_id, command,
                output_file=output_file,
                timeout=arguments.get("timeout"),
                on_complete=self.hook_callback,
            )
            if result.get("error"):
                return {"error": result["error"]}
            return {
                "stdout": (
                    "后台任务已启动（hook 模式），输出已重定向到工作空间文件 "
                    f"{result['output_file']}；命令结束后会自动收到 [terminal hook] "
                    "提示，届时读取该文件继续任务。可先用 read 工具 tail 查看实时输出。"
                ),
                "exit_code": 0,
                "task_id": result["task_id"],
                "output_file": result["output_file"],
            }

        # 分支 4：普通阻塞执行（原逻辑不变）
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
