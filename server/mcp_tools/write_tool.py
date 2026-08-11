"""MCP 工具 - write：向工作空间内写入文件。

通过 ``docker_manager.exec_in_workspace`` 在 agent 的 Docker 工作空间内
执行命令写入文件，写入前会自动创建父目录。文件路径需通过防注入校验。
"""

import logging
from typing import Any, Dict

from core.docker_manager import DockerManager

logger = logging.getLogger(__name__)


class WriteTool:
    """write 工具 - 向工作空间内写入文件。"""

    def __init__(self, docker_manager: DockerManager, workspace_id: str) -> None:
        """初始化 write 工具。

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

        # 1. 创建父目录：file_path 已通过校验，dirname 直接切片即可
        if "/" in file_path:
            parent_dir = file_path.rsplit("/", 1)[0]
        else:
            parent_dir = "."
        mkdir_result = self.docker_manager.exec_in_workspace(
            self.workspace_id, ["sh", "-c", f"mkdir -p {parent_dir}"]
        )
        if mkdir_result.get("error"):
            return {"error": mkdir_result["error"], "file_path": file_path}
        if mkdir_result.get("exit_code", -1) != 0:
            return {
                "error": f"创建父目录失败: {mkdir_result.get('stdout', '')}",
                "file_path": file_path,
            }

        # 2. 写入文件：使用 heredoc + 唯一定界符，避免内容中的 shell 元字符干扰
        #    定界符加单引号前缀，禁用变量替换，保证内容原样写入
        delimiter = "WRITE_TOOL_EOF_9f8a7b6c"
        heredoc_script = (
            f"cat > {file_path} <<'{delimiter}'\n{content}\n{delimiter}"
        )
        write_result = self.docker_manager.exec_in_workspace(
            self.workspace_id, ["sh", "-c", heredoc_script]
        )
        if write_result.get("error"):
            return {"error": write_result["error"], "file_path": file_path}
        if write_result.get("exit_code", -1) != 0:
            return {
                "error": f"写入文件失败: {write_result.get('stdout', '')}",
                "file_path": file_path,
            }

        logger.info("write 工具写入文件成功: %s", file_path)
        return {"success": True, "file_path": file_path}
