"""内置 write 工具 - 向工作空间内写入文件。

通过 :class:`core.workspace_io.WorkspaceIO` 写入文件，云端/本地实现均可。
与 read / edit / terminal 同为内置工具，直接走 LLM 工具循环，不经 MCP。
"""

import logging
from typing import Any, Dict

from core.workspace_io import WorkspaceIO

logger = logging.getLogger(__name__)


class WriteTool:
    """write 工具 - 向工作空间内写入文件。"""

    def __init__(self, io: WorkspaceIO, workspace_id: str) -> None:
        """初始化 write 工具。

        :param io: 工作空间 IO 实现（云端/本地）
        :param workspace_id: 工作空间标识
        """
        self.io = io
        self.workspace_id = workspace_id

    @staticmethod
    def _is_valid_path(path: str) -> bool:
        """校验文件路径，仅允许字母数字、/_-.，防止命令注入。"""
        if not path or len(path) > 4096:
            return False
        allowed = set(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/_.-"
        )
        return all(ch in allowed for ch in path)

    def get_tool_definition(self) -> Dict[str, Any]:
        """返回 OpenAI function calling 格式的工具定义。"""
        return {
            "type": "function",
            "function": {
                "name": "write",
                "description": "向工作空间内写入文件，自动创建父目录",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "file_path": {
                            "type": "string",
                            "description": "要写入的文件路径（工作空间内相对路径）",
                        },
                        "content": {
                            "type": "string",
                            "description": "要写入的文件内容",
                        },
                    },
                    "required": ["file_path", "content"],
                },
            },
        }

    def execute(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """执行 write 命令，写入文件。

        :param arguments: 工具参数，包含：
            - file_path: 文件路径（必填）
            - content: 文件内容（必填）
        :return: 成功返回 ``{"success": true, "file_path": "..."}``；
                 失败返回 ``{"error": "..."}``
        """
        if not isinstance(arguments, dict):
            return {"error": "参数必须是字典类型"}

        file_path = arguments.get("file_path", "")
        if not isinstance(file_path, str) or not file_path:
            return {"error": "file_path 不能为空"}
        if not self._is_valid_path(file_path):
            return {"error": "非法文件路径，仅允许字母数字、/_-. 字符"}

        content = arguments.get("content", "")
        if not isinstance(content, str):
            return {"error": "content 必须是字符串"}

        result = self.io.write_file(self.workspace_id, file_path, content)
        if result.get("error"):
            return {"error": result["error"], "file_path": file_path}

        logger.info("write 工具写入文件成功: %s", file_path)
        return {"success": True, "file_path": file_path}
