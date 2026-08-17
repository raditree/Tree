"""LLM 模型配置加载。

扫描 ``server/configs/models/*.yaml``，每个文件解析为一个 :class:`ModelConfig`。
"""
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Optional

import yaml

# 模型配置目录：server/configs/models
_MODELS_DIR = Path(__file__).resolve().parent.parent / "configs" / "models"

# ModelConfig 固定字段，其余字段归入 extra
_KNOWN_FIELDS = {"name", "base_url", "api_key", "model_id", "api_model_id", "is_limitless_context"}


@dataclass
class ModelConfig:
    """单个 LLM 模型的配置。

    固定字段对应所有模型共有的属性；模型特有的参数（如 ``max_seqlen``、
    ``temperature``、``top_k`` 等）存入 :attr:`extra`。
    """
    name: str
    base_url: str
    api_key: str
    model_id: str
    api_model_id: str = ""
    is_limitless_context: bool = False
    extra: Dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "ModelConfig":
        """从配置字典构造 ModelConfig，未识别字段放入 extra。"""
        extra = {k: v for k, v in data.items() if k not in _KNOWN_FIELDS}
        return cls(
            name=data.get("name", ""),
            base_url=data.get("base_url", ""),
            api_key=data.get("api_key", ""),
            model_id=data.get("model_id", ""),
            api_model_id=data.get("api_model_id", ""),
            is_limitless_context=bool(data.get("is_limitless_context", False)),
            extra=extra,
        )

    def to_dict(self) -> Dict[str, Any]:
        """合并固定字段与 extra，返回完整配置字典。"""
        result: Dict[str, Any] = {
            "name": self.name,
            "base_url": self.base_url,
            "api_key": self.api_key,
            "model_id": self.model_id,
            "is_limitless_context": self.is_limitless_context,
        }
        result.update(self.extra)
        return result


def load_model_configs() -> Dict[str, ModelConfig]:
    """扫描 ``configs/models/*.yaml``，返回 ``model_id -> ModelConfig`` 映射。

    缺少 ``model_id`` 的配置文件会被跳过。目录不存在时返回空字典。
    """
    configs: Dict[str, ModelConfig] = {}
    if not _MODELS_DIR.exists():
        return configs

    for yaml_file in sorted(_MODELS_DIR.glob("*.yaml")):
        with open(yaml_file, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
        if not isinstance(data, dict) or not data.get("model_id"):
            continue
        model_cfg = ModelConfig.from_dict(data)
        configs[model_cfg.model_id] = model_cfg

    return configs


def get_model_configs() -> Dict[str, ModelConfig]:
    """获取模型池配置（仅从 YAML 配置加载）。

    :return: model_id -> ModelConfig 映射
    """
    return load_model_configs()
