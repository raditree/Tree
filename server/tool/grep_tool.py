"""内置 grep 工具 - 在工作空间内按字面量/正则搜索文件内容。

通过 :class:`core.workspace_io.WorkspaceIO` 的 :meth:`grep_search` 执行搜索，
云端（容器内 ``grep``）/ 本地（前端 Dart 递归扫描）/ SSH（远端 ``grep``）
三模式共享同一通道，不经 shell 拼接，天然规避命令注入。
与 read / write / edit / terminal 同为内置工具，直接走 LLM 工具循环，不经 MCP。
"""

import logging
import re
from typing import Any, Dict, List, Tuple

from io_.workspace_io import WorkspaceIO, run_io
from prompt import versions

logger = logging.getLogger(__name__)

# 单次调用返回的最大匹配行数（防止大仓库返回超长输出撑爆上下文）
DEFAULT_MAX_RESULTS = 200
# max_results 的硬上限（防模型传超大值）
_MAX_RESULTS_CAP = 2000
# 单行匹配结果的最大字符数：jsonl / 压缩产物等每行可能是一条完整记录
# （可达数百万 token），命中即整行返回会瞬间撑爆上下文，必须按行截断
DEFAULT_MAX_LINE_CHARS = 2000
# 全部匹配结果的总字符上限：达到后停止收集并整体标注 truncated
DEFAULT_MAX_TOTAL_CHARS = 100_000
# 超长行截断时，在命中点前后保留的上下文宽度
_MATCH_CONTEXT_CHARS = 1000


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

    @staticmethod
    def _truncate_line(
        line: str, pattern: str, regex: bool, ignore_case: bool
    ) -> Tuple[str, bool]:
        """将超长匹配行截断为「命中点 ± 上下文」窗口。

        单行内无法定位命中点时退化为取行首窗口；窗口固定为
        :data:`DEFAULT_MAX_LINE_CHARS` 宽，前后以 ``…`` 标注被裁掉的
        内容，返回 ``(截断后文本, 是否发生截断)``。
        """
        if len(line) <= DEFAULT_MAX_LINE_CHARS:
            return line, False

        start = -1
        if regex:
            flags = re.IGNORECASE if ignore_case else 0
            try:
                m = re.search(pattern, line, flags)
            except re.error:
                m = None
            if m:
                start = m.start()
        else:
            key = line.lower() if ignore_case else line
            needle = pattern.lower() if ignore_case else pattern
            start = key.find(needle)
        if start < 0:
            start = 0

        begin = max(0, start - _MATCH_CONTEXT_CHARS)
        end = begin + DEFAULT_MAX_LINE_CHARS
        if end > len(line):
            end = len(line)
            begin = max(0, end - DEFAULT_MAX_LINE_CHARS)
        seg = line[begin:end]
        prefix = "…" if begin > 0 else ""
        suffix = "…" if end < len(line) else ""
        return prefix + seg + suffix, True

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
                            "超出部分截断并在结果中标注 truncated。超长单行"
                            "（如 jsonl 大数据记录行）会按命中位置截断为"
                            "上下文窗口并标注 line_truncated",
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
                 "total": N, "truncated": bool, "line_truncated": bool,
                 "stdout": "..."}``；无命中 exit_code=1、matches 为空；失败
                 返回 ``{"error": "..."}``。超长单行按命中位置截断为上下文
                 窗口（标注 line_truncated），行数/总字符超出则标注 truncated
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

        # 两道截断防线：行数（max_results）+ 超长单行（命中点窗口）。
        # 另设总字符上限，防止多行超长行叠加后仍撑爆上下文。
        retained: List[str] = []
        truncated = False
        line_truncated = False
        total_chars = 0
        for ln in all_lines:
            if len(retained) >= max_results:
                truncated = True
                break
            tline, tl = self._truncate_line(ln, pattern, regex, ignore_case)
            if tl:
                line_truncated = True
            add_len = len(tline) + 1  # +1 记换行符
            if total_chars and total_chars + add_len > DEFAULT_MAX_TOTAL_CHARS:
                truncated = True
                break
            retained.append(tline)
            total_chars += add_len

        logger.info(
            "grep 工具搜索完成: pattern=%r path=%r regex=%s ignore_case=%s "
            "命中=%d 返回=%d 单行截断=%s 总字符=%d",
            pattern, path, regex, ignore_case, len(all_lines), len(retained),
            line_truncated, total_chars,
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
            "line_truncated": line_truncated,
            "stdout": "\n".join(retained),
        }
