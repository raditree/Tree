"""MCP 工具 - embed_search：在工作空间内进行文本搜索。

当前实现为基于 ``grep -r`` 的简单文本搜索，后续将替换为向量嵌入搜索。
搜索范围覆盖工作空间内所有文本文件，排除 ``.git`` 目录。
"""

import logging
import shlex
from typing import Any, Dict, List

from core.docker_manager import DockerManager

logger = logging.getLogger(__name__)


class EmbedSearchTool:
    """embed_search 工具 - 在工作空间内进行文本搜索。

    当前使用 grep 实现简单文本搜索，后续将替换为向量嵌入搜索。
    """

    def __init__(self, docker_manager: DockerManager, workspace_id: str) -> None:
        """初始化 embed_search 工具。

        :param docker_manager: Docker 工作空间管理器实例
        :param workspace_id: 工作空间标识
        """
        self.docker_manager = docker_manager
        self.workspace_id = workspace_id

    def get_tool_definition(self) -> Dict[str, Any]:
        """返回 OpenAI function calling 格式的工具定义。"""
        return {
            "type": "function",
            "function": {
                "name": "embed_search",
                "description": (
                    "在工作空间内搜索文本。当前为基于 grep 的文本搜索，"
                    "后续将替换为向量嵌入搜索。"
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {
                            "type": "string",
                            "description": "搜索查询字符串",
                        },
                        "top_k": {
                            "type": "integer",
                            "description": "返回结果数量上限，默认 5",
                        },
                    },
                    "required": ["query"],
                },
            },
        }

    def execute(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """执行 embed_search 命令，搜索工作空间内的文本。

        :param arguments: 工具参数，包含：
            - query: 搜索查询字符串（必填）
            - top_k: 返回结果数量上限（可选，默认 5）
        :return: ``{"results": [{"file": "...", "line": N, "content": "..."}]}``
        """
        if not isinstance(arguments, dict):
            return {"error": "参数必须是字典类型", "results": []}

        query = arguments.get("query", "")
        if not isinstance(query, str) or not query:
            return {"error": "query 不能为空", "results": []}

        # 校验 top_k：必须是整数，限制在 1-100
        top_k = arguments.get("top_k", 5)
        if not isinstance(top_k, int) or isinstance(top_k, bool):
            top_k = 5
        top_k = max(1, min(top_k, 100))

        # 使用 grep -rnI 递归搜索：
        #   -r 递归子目录
        #   -n 输出行号
        #   -I 忽略二进制文件
        #   --exclude-dir=.git 排除 .git 目录
        #   -- 终止选项解析，query 作为模式
        # shlex.quote 转义 query，防止 shell 注入
        grep_cmd = (
            f"grep -rnI --exclude-dir=.git -- {shlex.quote(query)} ."
        )
        result = self.docker_manager.exec_in_workspace(
            self.workspace_id, ["sh", "-c", grep_cmd]
        )

        # Docker 不可用或容器不存在
        if result.get("error"):
            return {"error": result["error"], "results": []}

        # grep 无匹配时退出码为 1，属正常情况
        exit_code = result.get("exit_code", -1)
        if exit_code not in (0, 1):
            return {
                "error": f"grep 执行失败, exit_code={exit_code}",
                "results": [],
            }

        # 解析 grep 输出：格式为 ./path/to/file:line_number:content
        results: List[Dict[str, Any]] = []
        stdout = result.get("stdout", "")
        for line in stdout.splitlines():
            # 拆分为 file:line:content，最多拆分 2 次
            parts = line.split(":", 2)
            if len(parts) < 3:
                continue
            file_path = parts[0]
            try:
                line_num = int(parts[1])
            except ValueError:
                continue
            content = parts[2]
            results.append({
                "file": file_path,
                "line": line_num,
                "content": content,
            })
            if len(results) >= top_k:
                break

        logger.info(
            "embed_search 工具搜索完成: query=%s, 命中 %d 条",
            query[:100],
            len(results),
        )
        return {"results": results}
