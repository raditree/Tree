"""内置 edit 工具 - 对工作空间内文件执行精确字符串替换。

通过 :class:`core.workspace_io.WorkspaceIO` 读取文件、在 Python 中执行
精确字符串替换后写回文件。要求 ``old_text`` 在文件中唯一匹配。
与 read / write / terminal 同为内置工具，直接走 LLM 工具循环，不经 MCP。

自动兼容 LF / CRLF 换行：文件为 CRLF 时，old_text / new_text 会按 CRLF
归一后再匹配与写回（LLM 传参通常为 LF），无需预先转换文件换行符。
"""

import logging
from typing import Any, Dict

from io_.workspace_io import WorkspaceIO
from prompt import versions
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
                "description": versions.active_tool_description("edit"),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "file_path": {
                            "type": "string",
                            "description": "工作空间内相对路径（如 lib/foo.dart）；"
                            "禁止绝对路径或盘符（如 E:\\foo.dart、E:/foo.dart 会被拒绝）",
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
            return {
                "error": "非法文件路径：必须为工作空间内相对路径（如 lib/foo.dart），"
                "禁止绝对路径/盘符（如 E:\\foo.dart、E:/foo.dart）或 .. 回溯；"
                "仅允许字母数字、/_-. 字符",
            }

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

        # 1.5 换行容错：文件为 CRLF 时，把 old/new 统一转为 CRLF 再匹配，
        #     使 edit 对 LF/CRLF 文件一视同仁（LLM 传参通常为 LF），
        #     避免 CRLF 文件「未找到匹配」需手动转 LF 或脚本替换。
        eol = "\r\n" if "\r\n" in content else "\n"
        needle = old_text.replace("\r\n", "\n").replace("\n", eol)
        replacement = new_text.replace("\r\n", "\n").replace("\n", eol)

        # 2. 统计匹配次数
        match_count = content.count(needle)
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

        # 3. 执行替换并写回（needle/replacement 已按文件换行风格归一）
        new_content = content.replace(needle, replacement, 1)
        write_result = self._write_tool.execute({
            "file_path": file_path,
            "content": new_content,
        })
        if "error" in write_result:
            return {"error": write_result["error"], "file_path": file_path}

        logger.info("edit 工具替换成功: %s", file_path)
        return {"success": True, "replacements": 1, "file_path": file_path}
