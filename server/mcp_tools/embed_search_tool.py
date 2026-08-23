"""MCP 工具 - embed_search：在工作空间内进行向量嵌入搜索。

使用嵌入模型将查询转为向量，结合语义相似度对 grep 候选结果进行重排序，
实现更准确的语义搜索。嵌入模型未配置时自动降级为纯文本搜索。
"""

import logging
import math
from typing import Any, Dict, List, Optional, Tuple

from io_.workspace_io import WorkspaceIO, run_io
from data.embed_model import (
    EmbedModelConfig,
    get_embedding,
    get_embeddings_batch,
    get_max_input_length,
    load_embed_model_config,
    truncate_text,
)
from prompt import versions

logger = logging.getLogger(__name__)


def _cosine_similarity(a: List[float], b: List[float]) -> float:
    """计算两个向量的余弦相似度。

    :param a: 向量 A
    :param b: 向量 B
    :return: 余弦相似度（-1 ~ 1）
    """
    if not a or not b or len(a) != len(b):
        return 0.0

    dot = sum(x * y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(y * y for y in b))

    if norm_a == 0 or norm_b == 0:
        return 0.0

    return dot / (norm_a * norm_b)


class EmbedSearchTool:
    """embed_search 工具 - 在工作空间内进行向量嵌入搜索。

    搜索流程：
    1. 使用 grep 快速定位候选匹配行（通过 WorkspaceIO.grep_search）
    2. 若嵌入模型已配置，获取查询向量与各候选内容的向量
    3. 计算余弦相似度，按语义相关性重排序
    4. 返回 top-k 结果
    """

    def __init__(self, io: WorkspaceIO, workspace_id: str) -> None:
        """初始化 embed_search 工具。

        :param io: 工作空间 IO 实现（云端/本地）
        :param workspace_id: 工作空间标识
        """
        self.io = io
        self.workspace_id = workspace_id
        self._embed_config: Optional[EmbedModelConfig] = None

    def _get_embed_config(self) -> Optional[EmbedModelConfig]:
        """延迟加载嵌入模型配置（避免初始化时读取文件）。

        :return: EmbedModelConfig 实例，未配置时返回 None
        """
        if self._embed_config is None:
            self._embed_config = load_embed_model_config()
        return self._embed_config

    def get_tool_definition(self) -> Dict[str, Any]:
        """返回 OpenAI function calling 格式的工具定义。"""
        has_embed = self._get_embed_config() is not None
        desc = versions.active_tool_description(
            "embed_search.embed" if has_embed else "embed_search.grep"
        )
        return {
            "type": "function",
            "function": {
                "name": "embed_search",
                "description": desc,
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
        """执行向量嵌入搜索。

        :param arguments: 工具参数，包含：
            - query: 搜索查询字符串（必填）
            - top_k: 返回结果数量上限（可选，默认 5）
        :return: ``{"results": [{"file": "...", "line": N, "content": "...", "score": 0.0}]}``
        """
        if not isinstance(arguments, dict):
            return {"error": "参数必须是字典类型", "results": []}

        query = arguments.get("query", "")
        if not isinstance(query, str) or not query:
            return {"error": "query 不能为空", "results": []}

        top_k = arguments.get("top_k", 5)
        if not isinstance(top_k, int) or isinstance(top_k, bool):
            top_k = 5
        top_k = max(1, min(top_k, 100))

        # 获取嵌入模型配置
        embed_config = self._get_embed_config()

        # 截断保护：查询与候选内容均按配置的 max_input_length 截断后再嵌入，
        # 避免超长文本超出嵌入模型输入上限导致 API 报错（512 字符等）。
        max_len = get_max_input_length(embed_config) if embed_config else None

        # 获取查询向量（如果嵌入模型已配置）
        query_embedding: Optional[List[float]] = None
        if embed_config is not None:
            query_embedding = get_embedding(truncate_text(query, max_len), embed_config)
            if query_embedding is None:
                logger.warning(
                    "获取查询向量失败，降级为纯文本搜索"
                )

        # 使用 grep 搜索候选匹配行（通过 WorkspaceIO 接口，云端/本地均可）
        result = run_io(self.io.grep_search(self.workspace_id, query))

        if result.get("error"):
            return {"error": result["error"], "results": []}

        exit_code = result.get("exit_code", -1)
        if exit_code not in (0, 1):
            return {
                "error": f"grep 执行失败, exit_code={exit_code}",
                "results": [],
            }

        # 解析 grep 输出
        candidates: List[Tuple[str, int, str]] = []  # (file_path, line_num, content)
        stdout = result.get("stdout", "")
        for line in stdout.splitlines():
            parts = line.split(":", 2)
            if len(parts) < 3:
                continue
            file_path = parts[0]
            try:
                line_num = int(parts[1])
            except ValueError:
                continue
            content = parts[2]
            candidates.append((file_path, line_num, content))

        if not candidates:
            return {"results": []}

        # 如果嵌入模型可用，计算语义相似度并重排序
        if query_embedding is not None and embed_config is not None:
            # 批量获取所有候选内容的向量，减少 API 调用次数（逐条截断保护）
            candidate_texts = [truncate_text(content, max_len) for _, _, content in candidates]
            content_embeddings = get_embeddings_batch(candidate_texts, embed_config)

            scored_results: List[Dict[str, Any]] = []
            for i, (file_path, line_num, content) in enumerate(candidates):
                if content_embeddings is not None and i < len(content_embeddings):
                    score = _cosine_similarity(
                        query_embedding, content_embeddings[i]
                    )
                else:
                    score = 0.0
                scored_results.append({
                    "file": file_path,
                    "line": line_num,
                    "content": content,
                    "score": round(score, 4),
                })

            # 按相似度降序排列
            scored_results.sort(key=lambda x: x["score"], reverse=True)
            results = scored_results[:top_k]

            logger.info(
                "embed_search 向量搜索完成: query=%s, 候选 %d 条, 返回 %d 条",
                query[:100],
                len(candidates),
                len(results),
            )
            return {"results": results}

        # 降级为纯文本搜索（按 grep 输出顺序返回）
        plain_results: List[Dict[str, Any]] = []
        for file_path, line_num, content in candidates[:top_k]:
            plain_results.append({
                "file": file_path,
                "line": line_num,
                "content": content,
            })

        logger.info(
            "embed_search 文本搜索完成: query=%s, 命中 %d 条",
            query[:100],
            len(plain_results),
        )
        return {"results": plain_results}