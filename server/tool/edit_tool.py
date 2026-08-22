"""内置 edit 工具 - 对工作空间内文件执行精确字符串替换。

通过 :class:`core.workspace_io.WorkspaceIO` 读取文件、在 Python 中执行
精确字符串替换后写回文件。要求 ``old_text`` 在文件中唯一匹配。
与 read / write / terminal 同为内置工具，直接走 LLM 工具循环，不经 MCP。
"""

import logging
from typing import Any, Dict

from io_.workspace_io import WorkspaceIO
from tool.read_tool import ReadTool
from tool.write_tool import WriteTool

logger = logging.getLogger(__name__)


class EditTool:
    """edit 工具 - 对工作空间内文件执行精确字符串替换。"""

    def __init__(self, io: WorkspaceIO, workspace_id: str) -> None:
        """初始化 edit 工具。

        :param io: 工作空间 IO 实现（云端/本地）
        :param workspace_id: 工作空间标识
        """
        self.io = io
        self.workspace_id = workspace_id
        # 复用内置 read/write 工具的实现，保持文件读写逻辑一致
        self._read_tool = ReadTool(io, workspace_id)
        self._write_tool = WriteTool(io, workspace_id)

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
                "name": "edit",
                "description": (
                    "[对工作空间文件执行精确字符串替换] | "
                    "贡献维度: 文件产出（对已有文件做局部精准修改，保留其余内容）\n"
                    "何时使用: 修改已有文件的某段内容（改逻辑/文案/参数）；"
                    "old_text 必须在文件中唯一匹配，否则返回错误\n"
                    "何时不用: 新建文件用 write；大段重写用 write 覆盖；"
                    "不确定匹配内容时先 read 确认\n"
                    "前置依赖: 文件已存在；编辑前应先 read 拿到准确的 old_text"
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "file_path": {
                            "type": "string",
                            "description": "要编辑的文件路径（工作空间内相对路径）",
                        },
                        "old_text": {
                            "type": "string",
                            "description": "要被替换的精确文本",
                        },
                        "new_text": {
                            "type": "string",
                            "description": "替换后的新文本",
                        },
                    },
                    "required": ["file_path", "old_text", "new_text"],
                },
            },
        }

    def execute(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """执行 edit 命令，对文件进行精确字符串替换。

        :param arguments: 工具参数，包含：
            - file_path: 文件路径（必填）
            - old_text: 要被替换的文本（必填）
            - new_text: 替换后的新文本（必填）
        :return: 成功返回 ``{"success": true, "replacements": 1}``；
                 失败返回 ``{"error": "..."}``
        """
        if not isinstance(arguments, dict):
            return {"error": "参数必须是字典类型"}

        file_path = arguments.get("file_path", "")
        if not isinstance(file_path, str) or not file_path:
            return {"error": "file_path 不能为空"}
        if not self._is_valid_path(file_path):
            return {"error": "非法文件路径，仅允许字母数字、/_-. 字符"}

        old_text = arguments.get("old_text")
        if not isinstance(old_text, str):
            return {"error": "old_text 必须是字符串"}
        new_text = arguments.get("new_text")
        if not isinstance(new_text, str):
            return {"error": "new_text 必须是字符串"}

        # 1. 读取文件内容
        read_result = self._read_tool.execute({"file_path": file_path})
        if "error" in read_result:
            return {"error": read_result["error"], "file_path": file_path}
        content = read_result.get("content", "")

        # 2. 统计匹配次数
        match_count = content.count(old_text)
        if match_count == 0:
            logger.info("edit 工具未找到匹配文本: %s", file_path)
            return {"error": "未找到匹配的文本", "file_path": file_path}
        if match_count > 1:
            logger.info(
                "edit 工具找到多处匹配: %s, count=%d", file_path, match_count
            )
            return {
                "error": "找到多处匹配，请提供更精确的文本",
                "file_path": file_path,
                "match_count": match_count,
            }

        # 3. 执行替换并写回
        new_content = content.replace(old_text, new_text, 1)
        write_result = self._write_tool.execute({
            "file_path": file_path,
            "content": new_content,
        })
        if "error" in write_result:
            return {"error": write_result["error"], "file_path": file_path}

        logger.info("edit 工具替换成功: %s", file_path)
        return {"success": True, "replacements": 1, "file_path": file_path}
