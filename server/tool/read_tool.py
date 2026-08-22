"""内置 read 工具 - 读取工作空间内的文件内容。

通过 :class:`core.workspace_io.WorkspaceIO` 读取文件，云端/本地实现均可。
与 write / edit / terminal 同为内置工具，直接走 LLM 工具循环，不经 MCP。
图像文件（.png/.jpg/.jpeg/.webp/.gif）支持以 base64 形式返回，供视觉模型
（``if_vision=True``）读取；非视觉模型读取时由 LLM 层做降级处理。
"""

import base64
import logging
import os
from typing import Any, Dict, List

from io_.workspace_io import WorkspaceIO, run_io

logger = logging.getLogger(__name__)

# 支持的图像扩展名（自动识别图像文件）
_IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".bmp"}
# 图像 MIME 映射
_IMAGE_MIME = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".webp": "image/webp",
    ".gif": "image/gif",
    ".bmp": "image/bmp",
}


class ReadTool:
    """read 工具 - 读取工作空间内的文件内容。"""

    def __init__(self, io: WorkspaceIO, workspace_id: str) -> None:
        """初始化 read 工具。

        :param io: 工作空间 IO 实现（云端/本地）
        :param workspace_id: 工作空间标识
        """
        self.io = io
        self.workspace_id = workspace_id

    @staticmethod
    def _is_valid_path(path: str) -> bool:
        """校验文本文件路径，仅允许字母数字、/_-.，防止命令注入。"""
        if not path or len(path) > 4096:
            return False
        allowed = set(
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/_.-"
        )
        return all(ch in allowed for ch in path)

    @staticmethod
    def _is_valid_image_path(path: str) -> bool:
        """校验图像文件路径：在文本白名单基础上放宽空格/中文等字符。

        图像文件常带描述性名称（如「屏幕截图 2026-08-12 183834.png」），
        文本白名单会拒绝空格/中文导致无法读取。图像分支使用更宽松校验，
        但仍拒绝绝对路径、``..`` 回溯与 shell 元字符（防命令注入）。
        """
        if not path or len(path) > 4096:
            return False
        # 拒绝绝对路径与 shell 元字符
        if path.startswith("/") or path.startswith("\\"):
            return False
        if ".." in path.replace("\\", "/").split("/"):
            return False
        forbidden = set("|;&$`<>'\"*?~")
        if any(ch in forbidden for ch in path):
            return False
        return True

    def get_tool_definition(self) -> Dict[str, Any]:
        """返回 OpenAI function calling 格式的工具定义。"""
        return {
            "type": "function",
            "function": {
                "name": "read",
                "description": (
                    "[读取工作空间文件内容] | "
                    "贡献维度: 上下文获取（获取文件/代码/配置现状，是所有修改与判断的前提）\n"
                    "何时使用: 修改任何文件前必须先 read 看清楚当前内容；"
                    "查找代码/配置/文档内容；排查问题时读取相关文件；"
                    "读取图像文件（png/jpg/jpeg/webp/gif，自动识别并返回 base64）\n"
                    "何时不用: 已确定文件内容无需重读；大目录浏览用 Terminal ls\n"
                    "前置依赖: 文件必须存在于工作空间\n"
                    "省钱技巧: 大文件用 start_line/line_count 只读需要的行为表/函数，"
                    "避免整文件全读占用大量上下文"
                ),
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
                        "start_line": {
                            "type": "integer",
                            "description": "起始行号（从 1 开始），只读取该行起的片段；"
                            "缺省为 1 表示从文件开头。配合 line_count 分段读取大文件",
                        },
                        "line_count": {
                            "type": "integer",
                            "description": "读取的行数，只返回从 start_line 起的连续 line_count 行；"
                            "缺省表示读到文件末尾",
                        },
                        "image": {
                            "type": "boolean",
                            "description": "强制按图像读取（返回 base64）；"
                            "扩展名为 png/jpg/jpeg/webp/gif 时自动识别，无需显式传参",
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
            - image: 是否按图像读取（可选，扩展名可自动识别）
        :return: 文本文件 ``{"content": "...", "file_path": "..."}``；
                 图像文件 ``{"image_base64": "...", "mime": "...", "file_path": "..."}``；
                 失败返回 ``{"error": "..."}``
        """
        if not isinstance(arguments, dict):
            return {"error": "参数必须是字典类型"}

        file_path = arguments.get("file_path", "")
        if not isinstance(file_path, str) or not file_path:
            return {"error": "file_path 不能为空"}

        # 图像识别：显式 image 参数或扩展名命中
        ext = os.path.splitext(file_path)[1].lower()
        is_image = bool(arguments.get("image")) or ext in _IMAGE_EXTS
        if is_image:
            if not self._is_valid_image_path(file_path):
                return {"error": "非法图像路径"}
            return self._read_image(file_path)

        if not self._is_valid_path(file_path):
            return {"error": "非法文件路径，仅允许字母数字、/_-. 字符"}

        encoding = arguments.get("encoding", "utf-8") or "utf-8"

        result = run_io(self.io.read_file(self.workspace_id, file_path, encoding))

        if result.get("error"):
            return {"error": result["error"], "file_path": file_path}

        content = result.get("content", "")
        content = self._apply_line_range(content, arguments)
        logger.info(
            "read 工具读取文件成功: %s (encoding=%s)", file_path, encoding
        )
        return {"content": content, "file_path": file_path}

    def _read_image(self, file_path: str) -> Dict[str, Any]:
        """读取图像文件为 base64（供视觉模型消费）。

        WorkspaceIO 的 read_file 仅返回文本，图像需经 exec 命令编码。
        依次尝试：python3 → python → base64 命令（覆盖云端容器/本地 Windows）。
        """
        ext = os.path.splitext(file_path)[1].lower()
        mime = _IMAGE_MIME.get(ext, "image/png")

        # python one-liner：读取二进制文件输出 base64（不换行）
        py_code = (
            "import base64,sys;"
            "sys.stdout.write(base64.b64encode(open(sys.argv[1],'rb').read()).decode())"
        )
        candidates: List[List[str]] = [
            ["python3", "-c", py_code, file_path],
            ["python", "-c", py_code, file_path],
            ["base64", "-w0", file_path],
        ]
        last_err = ""
        for argv in candidates:
            result = run_io(self.io.exec_argv(self.workspace_id, list(argv)))
            if result.get("error") or result.get("exit_code", 0) != 0:
                last_err = str(result.get("error") or result.get("stderr") or "")
                continue
            b64 = (result.get("stdout") or "").strip()
            if not b64:
                last_err = "base64 输出为空"
                continue
            # 校验合法 base64（防乱码）
            try:
                base64.b64decode(b64, validate=True)
            except Exception as exc:  # noqa: BLE001
                last_err = f"base64 解码校验失败: {exc}"
                continue
            logger.info("read 工具读取图像成功: %s (%s)", file_path, mime)
            return {
                "image_base64": b64,
                "mime": mime,
                "file_path": file_path,
            }
        return {
            "error": f"读取图像失败（无可用 base64 编码器: {last_err}）",
            "file_path": file_path,
        }

    @staticmethod
    def _apply_line_range(content: str, arguments: Dict[str, Any]) -> str:
        """按 start_line / line_count 裁剪内容，节省 LLM 上下文。

        - 未提供任何行控制参数时返回全文（保持向后兼容）。
        - 行号从 1 开始计数。
        """
        has_range = (
            arguments.get("start_line") is not None
            or arguments.get("line_count") is not None
        )
        if not has_range:
            return content

        try:
            start = int(float(arguments.get("start_line") or 1))
        except (TypeError, ValueError):
            start = 1
        if start < 1:
            start = 1

        try:
            count = int(float(arguments.get("line_count") or 0))
        except (TypeError, ValueError):
            count = 0
        # count <= 0 视为不限制（读到末尾）
        if count <= 0:
            count = None

        lines = content.split("\n")
        start_idx = start - 1
        end_idx = len(lines) if count is None else start_idx + count
        end_idx = max(start_idx, min(end_idx, len(lines)))

        return "\n".join(lines[start_idx:end_idx])
