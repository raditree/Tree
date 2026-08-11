"""MCP 工具 - read：读取工作空间内的文件内容。

通过 ``docker_manager.exec_in_workspace`` 在 agent 的 Docker 工作空间内
执行 ``cat`` 命令读取文件，文件路径需通过防注入校验。
"""

import logging
from typing import Any, Dict

from core.docker_manager import DockerManager

logger = logging.getLogger(__name__)


class ReadTool:
    """read 工具 - 读取工作空间内的文件内容。"""

    def __init__(self, docker_manager: DockerManager, workspace_id: str) -> None:
        """初始化 read 工具。

        :param docker_manager: Docker 工作空间管理器实例
        :param workspace_id: 工作空间标识
        """
        self.docker_manager = docker_manager
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
                "name": "read",
                "description": "读取工作空间内指定文件的内容",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "file_path": {
                            "type": "string",
                            "description": "要读取的文件路径（工作空间内相对路径）",
                        },
                        "encoding": {
                            "type": "string",
                            "description": "文件编码，默认 utf-8",
                        },
                    },
                    "required": ["file_path"],
                },
            },
        }

    def execute(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """执行 read 命令，读取文件内容。

        :param arguments: 工具参数，包含：
            - file_path: 文件路径（必填）
            - encoding: 文件编码（可选，默认 utf-8）
        :return: 成功返回 ``{"content": "...", "file_path": "..."}``；
                 失败返回 ``{"error": "..."}``
        """
        if not isinstance(arguments, dict):
            return {"error": "参数必须是字典类型"}

        file_path = arguments.get("file_path", "")
        if not isinstance(file_path, str) or not file_path:
            return {"error": "file_path 不能为空"}
        if not self._is_valid_path(file_path):
            return {"error": "非法文件路径，仅允许字母数字、/_-. 字符"}

        # encoding 参数目前仅作记录，cat 输出由 docker_manager 按 utf-8 解码
        encoding = arguments.get("encoding", "utf-8") or "utf-8"

        result = self.docker_manager.exec_in_workspace(
            self.workspace_id, ["cat", file_path]
        )

        # Docker 不可用或容器不存在
        if result.get("error"):
            return {"error": result["error"], "file_path": file_path}

        exit_code = result.get("exit_code", -1)
        if exit_code != 0:
            logger.info("read 工具读取文件失败: %s, exit_code=%s", file_path, exit_code)
            return {
                "error": f"文件不存在或无法读取: {file_path}",
                "file_path": file_path,
            }

        content = result.get("stdout", "")
        logger.info("read 工具读取文件成功: %s (encoding=%s)", file_path, encoding)
        return {"content": content, "file_path": file_path}
