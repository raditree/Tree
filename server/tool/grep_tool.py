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
# max_depth 的硬上限（防模型传超大值），0 表示不限深度
_MAX_DEPTH_CAP = 100
# exclude 的模式数量与单条长度上限（防超长 shell 参数 / 滥用）
_MAX_EXCLUDE_PATTERNS = 50
_MAX_EXCLUDE_PATTERN_CHARS = 256
# 默认排除目录（依赖 / 缓存 / 构建产物）。这些目录动辄数百 MB 且几乎不含项目
# 源码，纳入扫描有两个后果：本地模式把海量命中行一次性经反向 WS 回传，单帧超过
# uvicorn ws_max_size 默认 16MiB 会被静默关闭连接（连带注销执行器注册、打断
# 在途工具调用）；云端/SSH 模式则白白耗时。显式把 path 指向其中某个目录
# （如 path='.venv/lib'）时该目录不再被排除，见 _merge_default_excludes。
DEFAULT_EXCLUDE_PATTERNS = [
    ".venv", "venv",
    "node_modules",
    ".pub-cache", ".dart_tool",
    "build", "dist",
    "__pycache__", ".mypy_cache", ".pytest_cache", ".ruff_cache", ".tox",
]


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

    @staticmethod
    def _parse_exclude(raw: Any) -> Tuple[List[str], str]:
        """解析 exclude 参数（逗号分隔的 basename glob 列表）。

        三模式的排除语义统一为「按名称（basename）匹配」：grep 的
        ``--exclude`` 在递归下按基名匹配、但在命令行文件下会退化为「路径后缀」
        匹配，Dart 本地实现只按基名匹配。为杜绝同一模式在不同模式/分支下行为
        不一致，这里直接拒绝含路径分隔符的模式。

        :param raw: 原始参数（缺省/空串表示不额外排除）
        :return: ``(模式列表, 错误信息)``，错误信息非空表示参数非法
        """
        if raw is None or raw == "":
            return [], ""
        if not isinstance(raw, str):
            return [], (
                "exclude 必须为字符串（逗号分隔的 glob，"
                "如 'node_modules,*.min.js'）"
            )
        patterns: List[str] = []
        for item in raw.split(","):
            pat = item.strip()
            if not pat:
                continue
            if len(pat) > _MAX_EXCLUDE_PATTERN_CHARS:
                return [], (
                    f"exclude 模式过长（>{_MAX_EXCLUDE_PATTERN_CHARS} 字符）: "
                    f"{pat[:_MAX_EXCLUDE_PATTERN_CHARS]}"
                )
            if any(ord(ch) < 32 for ch in pat):
                return [], "exclude 模式不能包含控制字符/换行"
            if "/" in pat or "\\" in pat:
                return [], (
                    f"exclude 仅支持按名称（basename）匹配，不能包含路径分隔符: "
                    f"{pat}（如排除 lib 下生成的 .g.dart 请写 '*.g.dart'，"
                    f"排除目录请写目录名如 'build'）"
                )
            if pat not in patterns:  # 去重保序
                patterns.append(pat)
        if len(patterns) > _MAX_EXCLUDE_PATTERNS:
            return [], f"exclude 模式过多（上限 {_MAX_EXCLUDE_PATTERNS} 个）"
        return patterns, ""

    @staticmethod
    def _merge_default_excludes(exclude: List[str], path: str) -> List[str]:
        """把 :data:`DEFAULT_EXCLUDE_PATTERNS` 并入用户 exclude（用户在前、去重保序）。

        :param exclude: 用户显式传入的排除模式
        :param path: 搜索目标（工作空间内相对路径），空串表示整个工作空间
        :return: 实际生效的排除模式列表

        ``path`` 的任一路径段命中某个默认模式时跳过该模式：显式写
        ``path='.venv'`` / ``path='.venv/lib'`` 说明就是要在该目录内搜索，
        默认排除不应把它挡掉。按路径段（而非仅最后一段）放行是为了让云端
        ``grep --exclude-dir`` 对命令行目录的匹配行为与本地/SSH 一致，避免
        同一 path 在不同模式下有的被排除、有的没有。
        """
        segments = (
            {seg for seg in path.strip("/").split("/") if seg} if path else set()
        )
        merged = list(exclude)
        for pat in DEFAULT_EXCLUDE_PATTERNS:
            if pat in segments or pat in merged:
                continue
            merged.append(pat)
        return merged

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
                        "max_depth": {
                            "type": "integer",
                            "description": "目录递归深度上限：1 表示只搜索目标目录"
                            "本层的文件（不进入子目录），N 表示最多向下 N 层；"
                            "缺省 0 表示不限深度（上限 100）",
                        },
                        "exclude": {
                            "type": "string",
                            "description": "在默认排除之外追加排除的文件/目录模式，"
                            "逗号分隔的 glob，仅按名称（basename）匹配、支持 * 与 ?，"
                            "如 '*.g.dart,*.min.js'；不接受带路径的模式（如 "
                            "lib/*.dart，会报错），请改用名称模式（*.g.dart）或"
                            "目录名（build）。默认已排除 .git 与依赖/缓存/构建产物"
                            "目录（.venv、venv、node_modules、.pub-cache、"
                            ".dart_tool、build、dist、__pycache__、.mypy_cache、"
                            ".pytest_cache、.ruff_cache、.tox）；显式把 path 指向"
                            "其中某个目录（如 path='.venv'）时该目录不再被排除",
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
            - max_depth: 目录递归深度上限（可选，1=仅目标目录本层，缺省 0 不限）
            - exclude: 在默认排除之外追加排除的文件/目录 glob，逗号分隔（可选）
            - max_results: 返回行数上限（可选，缺省 200）
        :return: 成功 ``{"exit_code": 0, "matches": ["path:行号:内容", ...],
                 "count": N, "total": N, "truncated": bool,
                 "line_truncated": bool, "stdout": "..."}``；无命中 exit_code=1、
                 matches 为空；失败返回 ``{"error": "..."}``。三模式统一输出
                 ``path:行号:内容``（与 ``grep -n`` 一致，行号从 1 起）。超长
                 单行按命中位置截断为上下文窗口（标注 line_truncated），
                 行数/总字符超出则标注 truncated（本地模式下前端已在发送端
                 按同一套上限截断并把标记并入，故 ``total`` 是"收到的命中行
                 数"，可能小于真实命中数）。返回的 ``exclude`` 是
                 「用户模式 + :data:`DEFAULT_EXCLUDE_PATTERNS`」的合并结果
                 （显式 path 指向的默认排除目录会被放行）
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

        # max_depth：缺省/空值按 0（不限深度）处理，负值归零，超上限截断
        max_depth = 0
        raw_depth = arguments.get("max_depth")
        if raw_depth not in (None, ""):
            try:
                max_depth = int(raw_depth)
            except (TypeError, ValueError):
                return {"error": "max_depth 必须为整数（1 起为层数，0 表示不限）"}
            max_depth = max(0, min(max_depth, _MAX_DEPTH_CAP))

        exclude, exclude_err = self._parse_exclude(arguments.get("exclude"))
        if exclude_err:
            return {"error": exclude_err}
        # 并入默认排除目录（显式 path 指向者放行），避免依赖/缓存/构建产物目录
        # 被全工作区扫描（本地模式下会造成超大回传帧，见 DEFAULT_EXCLUDE_PATTERNS）
        exclude = self._merge_default_excludes(
            exclude, path if isinstance(path, str) else ""
        )

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
                max_depth=max_depth,
                exclude=exclude,
            )
        )

        if result.get("error"):
            return {"error": result["error"], "pattern": pattern}

        stdout = result.get("stdout", "") or ""
        exit_code = int(result.get("exit_code", 0))
        all_lines: List[str] = [ln for ln in stdout.splitlines() if ln.strip()]
        # 本地模式的前端已按同一套上限在发送端截断（见 local_executor_service
        # .dart: truncateGrepLine / _GrepCollector）——超限帧会被 WS 服务端按
        # ws_max_size 静默关闭，所以截断不能只留在这里。把它的标记并入结果，
        # 避免模型把"被截断的部分命中"当成全量。
        sender_truncated = bool(result.get("truncated"))
        sender_line_truncated = bool(result.get("line_truncated"))

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
        truncated = truncated or sender_truncated
        line_truncated = line_truncated or sender_line_truncated

        logger.info(
            "grep 工具搜索完成: pattern=%r path=%r regex=%s ignore_case=%s "
            "max_depth=%d exclude=%s 收到=%d 返回=%d 单行截断=%s 截断=%s "
            "发送端截断=%s 总字符=%d",
            pattern, path, regex, ignore_case, max_depth, exclude,
            len(all_lines), len(retained), line_truncated, truncated,
            sender_truncated, total_chars,
        )
        return {
            "pattern": pattern,
            "path": path if isinstance(path, str) and path else ".",
            "regex": regex,
            "ignore_case": ignore_case,
            "max_depth": max_depth,
            "exclude": exclude,
            "exit_code": exit_code,
            "matches": retained,
            "count": len(retained),
            "total": len(all_lines),
            "truncated": truncated,
            "line_truncated": line_truncated,
            "stdout": "\n".join(retained),
        }
