"""内置 grep 工具 - 在工作空间内按字面量/正则搜索文件内容。

通过 :class:`core.workspace_io.WorkspaceIO` 的 :meth:`grep_search` 执行搜索，
云端（容器内 ``grep``）/ 本地（前端 Dart 递归扫描）/ SSH（远端 ``grep``）
三模式共享同一通道，不经 shell 拼接，天然规避命令注入。
与 read / write / edit / terminal 同为内置工具，直接走 LLM 工具循环，不经 MCP。
"""

import logging
import re
from typing import Any, Dict, List

from io_.workspace_io import WorkspaceIO, run_io
from prompt import versions

logger = logging.getLogger(__name__)

# 单次调用返回的最大匹配行数（防止大仓库返回超长输出撑爆上下文）
DEFAULT_MAX_RESULTS = 200
# max_results 的硬上限（防模型传超大值）
_MAX_RESULTS_CAP = 2000


class GrepTool:
    """grep 工具 - 在工作空间内按模式搜索文件内容。"""

    def __init__(self, io: WorkspaceIO, workspace_id: str) -> None:
        """初始化 grep 工具。

        :param io: 工作空间 IO 实现（云端/本地/SSH）
        :param workspace_id: 工作空间标识
        """
        self.io = io
        self.workspace_id = workspace_id

    @staticmethod
    def _is_valid_path(path: str) -> bool:
        """校验搜索目标路径：仅允许字母数字、/_-.，拒绝绝对路径/盘符与 .. 回溯。

        与 read 工具同款白名单校验，防止路径穿越与命令注入。
        """
        if not path or len(path) > 4096:
            return False
        # 拒绝绝对路径与 Windows 盘符
        if (
            path.startswith("/")
            or path.startswith("\\")
            or re.match(r"^[A-Za-z]:", path)
        ):
            return False
        allowed = set(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/_.-"
        )
        if not all(ch in allowed for ch in path):
            return False
        # 拒绝任一路径段为 ``..``
        if ".." in path.replace("\\", "/").split("/"):
            return False
        return True

    def get_tool_definition(self) -> Dict[str, Any]:
        """返回 OpenAI function calling 格式的工具定义。"""
        return {
            "type": "function",
            "function": {
                "name": "grep",
                "description": versions.active_tool_description("grep"),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "pattern": {
                            "type": "string",
                            "description": "搜索模式：regex=false 时为字面量文本，"
                            "regex=true 时为正则表达式（如 'TODO|FIXME'）",
                        },
                        "path": {
                            "type": "string",
                            "description": "搜索范围：工作空间内相对目录或文件路径"
                            "（如 lib/src）；缺省搜索整个工作空间",
                        },
                        "regex": {
                            "type": "boolean",
                            "description": "是否将 pattern 视为正则表达式；"
                            "缺省 false（字面量精确匹配）",
                        },
                        "ignore_case": {
                            "type": "boolean",
                            "description": "是否忽略大小写；缺省 false",
                        },
                        "max_results": {
                            "type": "integer",
                            "description": "返回的最大匹配行数，缺省 200、上限 2000；"
                            "超出部分截断并在结果中标注 truncated",
                        },
                    },
                    "required": ["pattern"],
                },
            },
        }

    def execute(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """执行 grep 搜索。

        :param arguments: 工具参数，包含：
            - pattern: 搜索模式（必填）
            - path: 搜索范围（可选，缺省整个工作空间）
            - regex: 是否正则（可选，缺省 false）
            - ignore_case: 是否忽略大小写（可选，缺省 false）
            - max_results: 返回行数上限（可选，缺省 200）
        :return: 成功 ``{"exit_code": 0, "matches": ["path:line", ...], "count": N,
                 "truncated": bool, "stdout": "..."}``；无命中 exit_code=1、
                 matches 为空；失败返回 ``{"error": "..."}``
        """
        if not isinstance(arguments, dict):
            return {"error": "参数必须是字典类型"}

        pattern = arguments.get("pattern", "")
        if not isinstance(pattern, str) or not pattern.strip():
            return {"error": "pattern 不能为空"}

        path = arguments.get("path") or ""
        if isinstance(path, str) and path:
            if not self._is_valid_path(path):
                return {
                    "error": "非法搜索路径：必须为工作空间内相对路径（如 lib/src），"
                    "禁止绝对路径/盘符（如 E:\\foo.dart、E:/foo.dart）或 .. 回溯",
                }
        elif path:
            return {"error": "path 必须为字符串"}

        regex = bool(arguments.get("regex"))
        ignore_case = bool(arguments.get("ignore_case"))
        try:
            max_results = int(arguments.get("max_results") or DEFAULT_MAX_RESULTS)
        except (TypeError, ValueError):
            max_results = DEFAULT_MAX_RESULTS
        max_results = max(1, min(max_results, _MAX_RESULTS_CAP))

        result = run_io(
            self.io.grep_search(
                self.workspace_id,
                pattern,
                path=path if isinstance(path, str) else "",
                regex=regex,
                ignore_case=ignore_case,
            )
        )

        if result.get("error"):
            return {"error": result["error"], "pattern": pattern}

        stdout = result.get("stdout", "") or ""
        exit_code = int(result.get("exit_code", 0))
        all_lines: List[str] = [ln for ln in stdout.splitlines() if ln.strip()]
        truncated = len(all_lines) > max_results
        retained = all_lines[:max_results] if truncated else all_lines

        logger.info(
            "grep 工具搜索完成: pattern=%r path=%r regex=%s ignore_case=%s "
            "命中=%d 返回=%d",
            pattern, path, regex, ignore_case, len(all_lines), len(retained),
        )
        return {
            "pattern": pattern,
            "path": path if isinstance(path, str) and path else ".",
            "regex": regex,
            "ignore_case": ignore_case,
            "exit_code": exit_code,
            "matches": retained,
            "count": len(retained),
            "total": len(all_lines),
            "truncated": truncated,
            "stdout": "\n".join(retained),
        }
