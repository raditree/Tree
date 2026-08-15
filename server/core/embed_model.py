"""嵌入模型配置加载与 API 调用。

读取 ``server/configs/embed_model.yaml`` 获取嵌入模型配置，
提供 OpenAI 协议兼容的 embedding API 调用封装。
"""
import hashlib
import logging
from collections import OrderedDict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

import yaml
from openai import OpenAI

logger = logging.getLogger(__name__)

# 嵌入模型配置文件路径
_CONFIG_DIR = Path(__file__).resolve().parent.parent / "configs"
_EMBED_CONFIG_FILE = _CONFIG_DIR / "embed_model.yaml"

# EmbedModelConfig 固定字段，其余字段归入 extra
_KNOWN_FIELDS = {"name", "base_url", "api_key", "model_id"}

# 嵌入结果 LRU 缓存：key = MD5(text) + 可选的 dimensions 后缀
_embedding_cache: OrderedDict[str, List[float]] = OrderedDict()
_EMBEDDING_CACHE_MAX_SIZE = 1000


def _cache_key(text: str, dimensions: Optional[int] = None) -> str:
    """根据文本内容生成缓存键（MD5 哈希），dimensions 不同视为不同键。

    :param text: 输入文本
    :param dimensions: 向量维度（可选）
    :return: 缓存键字符串
    """
    key = hashlib.md5(text.encode("utf-8")).hexdigest()
    if dimensions is not None:
        key = f"{key}_d{dimensions}"
    return key


@dataclass
class EmbedModelConfig:
    """嵌入模型的配置。

    固定字段对应所有嵌入模型共有的属性；模型特有的参数
    （如 ``embedding_dimensions``、``max_input_length`` 等）存入 :attr:`extra`。
    """
    name: str
    base_url: str
    api_key: str
    model_id: str
    extra: Dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "EmbedModelConfig":
        """从配置字典构造 EmbedModelConfig，未识别字段放入 extra。"""
        extra = {k: v for k, v in data.items() if k not in _KNOWN_FIELDS}
        return cls(
            name=data.get("name", ""),
            base_url=data.get("base_url", ""),
            api_key=data.get("api_key", ""),
            model_id=data.get("model_id", ""),
            extra=extra,
        )

    def to_dict(self) -> Dict[str, Any]:
        """合并固定字段与 extra，返回完整配置字典。"""
        result: Dict[str, Any] = {
            "name": self.name,
            "base_url": self.base_url,
            "api_key": self.api_key,
            "model_id": self.model_id,
        }
        result.update(self.extra)
        return result

    def create_client(self) -> OpenAI:
        """根据配置创建 OpenAI client。

        :return: openai.OpenAI 实例
        """
        return OpenAI(
            base_url=self.base_url,
            api_key=self.api_key,
        )


def load_embed_model_config() -> Optional[EmbedModelConfig]:
    """读取 ``server/configs/embed_model.yaml``，返回嵌入模型配置。

    配置文件不存在或格式错误时返回 None。

    :return: EmbedModelConfig 实例，或 None
    """
    if not _EMBED_CONFIG_FILE.exists():
        logger.warning("嵌入模型配置文件不存在: %s", _EMBED_CONFIG_FILE)
        return None

    with open(_EMBED_CONFIG_FILE, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}

    if not isinstance(data, dict) or not data.get("model_id"):
        logger.warning(
            "嵌入模型配置缺少 model_id，跳过加载: %s", _EMBED_CONFIG_FILE
        )
        return None

    return EmbedModelConfig.from_dict(data)


def get_embedding(
    text: str,
    config: EmbedModelConfig,
    dimensions: Optional[int] = None,
) -> Optional[List[float]]:
    """调用嵌入模型 API，返回文本的向量表示。

    内置 MD5 哈希 LRU 缓存，相同的文本内容不会重复调用 API。

    :param text: 输入文本
    :param config: 嵌入模型配置
    :param dimensions: 向量维度（模型支持动态维度时可选）
    :return: 浮点数向量列表，调用失败时返回 None
    """
    # 检查缓存命中
    key = _cache_key(text, dimensions)
    if key in _embedding_cache:
        _embedding_cache.move_to_end(key)
        return _embedding_cache[key]

    client = config.create_client()

    kwargs: Dict[str, Any] = {
        "input": text,
        "model": config.model_id,
    }
    # 如果配置中指定了 dimensions 或显式传入了 dimensions，则使用
    if dimensions is not None:
        kwargs["dimensions"] = dimensions
    elif "embedding_dimensions" in config.extra:
        kwargs["dimensions"] = int(config.extra["embedding_dimensions"])

    try:
        response = client.embeddings.create(**kwargs)
    except Exception as e:
        logger.error("调用嵌入模型 API 失败: %s", e)
        return None

    if not response.data or len(response.data) == 0:
        logger.warning("嵌入模型 API 返回空数据")
        return None

    result = response.data[0].embedding

    # 写入缓存
    _embedding_cache[key] = result
    _embedding_cache.move_to_end(key)
    if len(_embedding_cache) > _EMBEDDING_CACHE_MAX_SIZE:
        _embedding_cache.popitem(last=False)

    return result


def get_embeddings_batch(
    texts: List[str],
    config: EmbedModelConfig,
    dimensions: Optional[int] = None,
) -> Optional[List[List[float]]]:
    """批量调用嵌入模型 API，返回多个文本的向量表示。

    内置 MD5 哈希 LRU 缓存，对每个文本单独检查缓存，
    仅将未命中缓存的文本发送给 API，减少不必要的调用。

    :param texts: 输入文本列表
    :param config: 嵌入模型配置
    :param dimensions: 向量维度（模型支持动态维度时可选）
    :return: 浮点数向量列表的列表，调用失败时返回 None
    """
    if not texts:
        return []

    # 逐条检查缓存，分离已缓存和未缓存
    keys = [_cache_key(t, dimensions) for t in texts]
    results: List[Optional[List[float]]] = [None] * len(texts)
    uncached_indices: List[int] = []
    uncached_texts: List[str] = []

    for i, (text, key) in enumerate(zip(texts, keys)):
        if key in _embedding_cache:
            _embedding_cache.move_to_end(key)
            results[i] = _embedding_cache[key]
        else:
            uncached_indices.append(i)
            uncached_texts.append(text)

    # 如果全部命中缓存，直接返回
    if not uncached_texts:
        return results  # type: ignore[return-value]

    # 调用 API 获取未缓存的向量
    client = config.create_client()

    kwargs: Dict[str, Any] = {
        "input": uncached_texts,
        "model": config.model_id,
    }
    if dimensions is not None:
        kwargs["dimensions"] = dimensions
    elif "embedding_dimensions" in config.extra:
        kwargs["dimensions"] = int(config.extra["embedding_dimensions"])

    try:
        response = client.embeddings.create(**kwargs)
    except Exception as e:
        logger.error("批量调用嵌入模型 API 失败: %s", e)
        # 有缓存数据时返回带 None 占位的原始长度列表，否则返回 None
        if any(r is not None for r in results):
            return results
        return None

    if not response.data:
        logger.warning("嵌入模型 API 返回空数据")
        # 有缓存数据时返回带 None 占位的原始长度列表，否则返回 None
        if any(r is not None for r in results):
            return results
        return None

    # 将 API 返回的向量按 index 排序后填入对应位置
    sorted_data = sorted(response.data, key=lambda x: x.index)
    for idx, item in zip(uncached_indices, sorted_data):
        embedding = item.embedding
        key = keys[idx]
        _embedding_cache[key] = embedding
        results[idx] = embedding

    # 裁剪缓存到最大容量
    while len(_embedding_cache) > _EMBEDDING_CACHE_MAX_SIZE:
        _embedding_cache.popitem(last=False)

    return results  # type: ignore[return-value]