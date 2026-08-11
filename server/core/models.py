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
_KNOWN_FIELDS = {"name", "base_url", "api_key", "model_id", "is_limitless_context"}


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


def enrich_with_provider_models(
    configs: Dict[str, ModelConfig],
) -> Dict[str, ModelConfig]:
    """通过各供应商 API（``/models``）拉取实际可用模型，并入模型池。

    以 yaml 中的 (base_url, api_key) 作为供应商标识，对每个供应商调用
    ``client.models.list()`` 获取模型 id 列表。已在 yaml 配置中的模型保留原配置；
    新增的模型使用供应商的 base_url/api_key，``max_seqlen`` 沿用供应商首个配置的默认值。

    API 调用失败（网络/认证）时静默跳过该供应商，不影响已有配置。

    :param configs: 已有的模型配置（model_id -> ModelConfig）
    :return: 合并后的模型配置字典
    """
    merged: Dict[str, ModelConfig] = dict(configs)
    # 按供应商（base_url, api_key）分组
    providers: Dict[tuple, list] = {}
    for cfg in configs.values():
        providers.setdefault((cfg.base_url, cfg.api_key), []).append(cfg)

    for (base_url, api_key), cfgs in providers.items():
        sample = cfgs[0]
        default_max_seqlen = int(sample.extra.get("max_seqlen", 8192))
        try:
            from openai import OpenAI

            client = OpenAI(base_url=base_url, api_key=api_key)
            remote_models = client.models.list()
        except Exception:  # noqa: BLE001
            # 供应商不可达或认证失败，静默跳过
            continue
        for m in remote_models:
            mid = getattr(m, "id", None)
            if not mid or mid in merged:
                continue
            merged[mid] = ModelConfig(
                name=mid,
                base_url=base_url,
                api_key=api_key,
                model_id=mid,
                is_limitless_context=False,
                extra={"max_seqlen": default_max_seqlen},
            )
    return merged


# 全局模型池缓存（yaml + 供应商 API 拉取结果）
_model_pool: Dict[str, ModelConfig] = {}
_model_pool_refreshed: bool = False


def get_model_configs(refresh: bool = False) -> Dict[str, ModelConfig]:
    """获取完整模型池配置（yaml 配置 + 供应商 API 拉取的模型）。

    :param refresh: 为 True 时强制重新从供应商 API 拉取
    :return: model_id -> ModelConfig 映射
    """
    global _model_pool, _model_pool_refreshed
    if refresh or not _model_pool_refreshed:
        _model_pool = enrich_with_provider_models(load_model_configs())
        _model_pool_refreshed = True
    return _model_pool
