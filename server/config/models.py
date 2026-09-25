"""LLM 模型配置加载。

扫描 ``server/configs/models/*.yaml``，每个文件解析为一个 :class:`ModelConfig`。
另提供自定义模型的写盘/删除（设置页「自定义模型」用）：``save_model_config`` /
``delete_model_config``，文件名由 ``model_id`` 净化后派生。
"""
import logging
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Optional

import yaml

logger = logging.getLogger(__name__)

# 模型配置目录：server/configs/models
_MODELS_DIR = Path(__file__).resolve().parent.parent / "configs" / "models"

# 模型 id 允许的字符集：字母数字与 . _ -
# 用于派生文件名，**必须**先净化再拼接，防止 path traversal（如 ../../etc/x）
_MODEL_ID_PATTERN = re.compile(r"^[A-Za-z0-9._-]+$")

# ModelConfig 固定字段，其余字段归入 extra
_KNOWN_FIELDS = {
    "name", "base_url", "api_key", "model_id", "api_model_id",
    "thinking", "if_vision",
}

# ---------------------------------------------------------------------------
# reasoning_effort（思考强度）
# ---------------------------------------------------------------------------
# 语义区分（重要）：
# - REASONING_EFFORT_ACCEPTED：**语法层**被各 OpenAI 兼容端点接受的枚举全集。
#   实测 DeepSeek 对枚举外取值返 422「unknown variant」，枚举内一律接受。
# - REASONING_EFFORT_CANONICAL：**语义层**有实际区分度的档位。多个取值在服务端
#   被映射到同一档（DeepSeek：minimal→low、medium→high、xhigh→high、
#   ultra→max），故 5~7 个选项里可能只有 3 个真正不同。
# - 前端「可选档位」下拉只应展示 CANONICAL（或模型 .yaml 显式声明的子集），
#   否则会给出选起来无差别的假选项。
REASONING_EFFORT_ACCEPTED = (
    "none",
    "minimal",
    "low",
    "medium",
    "high",
    "xhigh",
    "ultra",
    "max",
)
REASONING_EFFORT_CANONICAL = ("low", "high", "max")

# 别名 → 规范档位（与 DeepSeek 文档的映射表一致）
# ``none`` 不在映射内：它是独立语义（关闭思考），不能折叠到 low/high/max。
REASONING_EFFORT_ALIASES = {
    "minimal": "low",
    "medium": "high",
    "xhigh": "high",
    "ultra": "max",
}

# 模型 .yaml 中声明「思考强度可选档位」的键名。
#
# 这是**纯声明字段**，不是 API 参数：它只用于约束前端下拉与后端校验。
# `llm.LLMClient._build_api_kwargs` 的 ``reserved`` 集合必须包含该键，
# 否则会被当作 OpenAI 顶层参数透传并触发 SDK TypeError（历史故障：
# is_limitless_context 曾因此让 agent 完全无响应）。同理它必须出现在
# ``save_model_config`` 的扩展键白名单里，否则写盘时被静默丢弃。
REASONING_EFFORT_OPTIONS_KEY = "reasoning_effort_options"


def normalize_reasoning_effort(value: Any) -> Optional[str]:
    """把思考强度归一化到**被端点接受**的规范写法。

    处理三件事，缺一都会让请求被网关 422 拒绝：

    1. ``strip()`` —— 端点不接受前后空白（实测 ``"  high  "`` 返 422）；
    2. ``lower()`` —— 大小写敏感（实测 ``"HIGH"`` 返 422）；
    3. 别名折叠为规范档位（``minimal→low`` / ``medium→high`` /
       ``xhigh→high`` / ``ultra→max``），使存库值具备唯一表示。

    **不校验"是否属于该模型的可用档位"**：那是校验层
    (:func:`is_reasoning_effort_accepted`) 的职责，本函数只做归一化，
    以便校验失败时能把归一化结果与错误信息一起返回。

    :return: 归一化后的档位；空值 / 非字符串 / 枚举外取值返回 None
    """
    if not isinstance(value, str):
        return None
    normalized = value.strip().lower()
    if not normalized:
        return None
    normalized = REASONING_EFFORT_ALIASES.get(normalized, normalized)
    return normalized if normalized in REASONING_EFFORT_ACCEPTED else None


def is_reasoning_effort_accepted(value: Any) -> bool:
    """``value`` 是否为端点接受的枚举取值（先经归一化）。"""
    return normalize_reasoning_effort(value) is not None


def normalize_reasoning_effort_options(value: Any) -> Optional[list]:
    """归一化模型声明的「可选档位」列表。

    - 逐项归一化（折叠别名），去重并保序；
    - 丢弃枚举外/非法项；全部非法时返回 None（视为未声明）。

    未声明（None）与"声明为空列表"语义不同：前者回退全局
    :data:`REASONING_EFFORT_ACCEPTED`，后者表示该模型不应下发该参数。
    """
    if value is None:
        return None
    if isinstance(value, str):
        # 容忍 YAML 里写成逗号分隔的字符串
        value = [p for p in value.replace("，", ",").split(",")]
    if not isinstance(value, (list, tuple)):
        return None
    options = []
    for item in value:
        normalized = normalize_reasoning_effort(item)
        if normalized is not None and normalized not in options:
            options.append(normalized)
    return options if options else None


def declared_reasoning_effort_options(extra: Dict[str, Any]) -> Optional[list]:
    """读取模型 ``extra`` 中声明的可选档位（未经归一化，供原样回显）。"""
    return extra.get(REASONING_EFFORT_OPTIONS_KEY)


def resolve_reasoning_effort_options(extra: Dict[str, Any]) -> list:
    """解析该模型**实际生效**的可选档位列表（供前端下拉使用）。

    - 模型显式声明了 ``reasoning_effort_options`` → 用声明值（归一化后）；
    - 未声明 → 回退 :data:`REASONING_EFFORT_CANONICAL`
      （而非 ACCEPTED 全集：后者含多个选起来无差别的别名）。
    """
    declared = normalize_reasoning_effort_options(
        declared_reasoning_effort_options(extra)
    )
    return declared if declared else list(REASONING_EFFORT_CANONICAL)


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
    thinking: bool = False
    if_vision: bool = False
    extra: Dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "ModelConfig":
        """从配置字典构造 ModelConfig，未识别字段放入 extra。

        ``thinking`` / ``if_vision`` 为顶层布尔字段（默认 false），
        spec「thinking 支持：ModelConfig ``thinking`` 字段」「read_tool 图像：
        ModelConfig ``if_vision`` 字段」。其余未识别字段归入 extra。
        """
        extra = {k: v for k, v in data.items()
                 if k not in _KNOWN_FIELDS and k not in ("thinking", "if_vision")}
        return cls(
            name=data.get("name", ""),
            base_url=data.get("base_url", ""),
            api_key=data.get("api_key", ""),
            model_id=data.get("model_id", ""),
            api_model_id=data.get("api_model_id", ""),
            thinking=bool(data.get("thinking", False)),
            if_vision=bool(data.get("if_vision", False)),
            extra=extra,
        )

    def to_dict(self) -> Dict[str, Any]:
        """合并固定字段与 extra，返回完整配置字典。"""
        result: Dict[str, Any] = {
            "name": self.name,
            "base_url": self.base_url,
            "api_key": self.api_key,
            "model_id": self.model_id,
            "api_model_id": self.api_model_id,
            "thinking": self.thinking,
            "if_vision": self.if_vision,
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


# ----------------------------------------------------------------------
# 自定义模型写盘 / 删除（设置页「自定义模型」）
# ----------------------------------------------------------------------
def is_valid_model_id(model_id: str) -> bool:
    """``model_id`` 是否可安全用作文件名（防路径穿越）。

    仅靠字符集白名单不够：``".."`` 与 ``"."`` 都由允许字符组成，却会派生
    ``...yaml`` / ``..yaml`` 这类可疑路径，故额外拒绝"全点"与纯分隔符。
    """
    if not model_id:
        return False
    # 全点（"." / ".." / "..."）不是合法模型名，且靠近路径穿越语义
    if model_id.strip(".") == "":
        return False
    return bool(_MODEL_ID_PATTERN.match(model_id))


def model_config_path(model_id: str) -> Optional[Path]:
    """按 ``model_id`` 派生配置文件路径；非法 id 返回 None。"""
    if not is_valid_model_id(model_id):
        return None
    # 二次确认：解析后的父目录必须就是 _MODELS_DIR（防符号链接/编码绕过）
    candidate = (_MODELS_DIR / f"{model_id}.yaml").resolve()
    try:
        if candidate.parent != _MODELS_DIR.resolve():
            return None
    except OSError:
        return None
    return candidate


def save_model_config(data: Dict[str, Any]) -> ModelConfig:
    """把一条模型配置写入 ``configs/models/<model_id>.yaml``（原子写）。

    采用「临时文件 + ``os.replace``」原子替换：写盘失败不会留下半成品文件，
    也不会破坏已有同名配置。

    **不校验 name/base_url/api_key 的业务必填性**：那是路由层职责（更新时这些
    字段可由既有配置回填）。此处只保证 ``model_id`` 可安全用作文件名。

    :raises ValueError: ``model_id`` 非法（空或含路径穿越字符）
    :return: 写入后的 :class:`ModelConfig`
    """
    model_id = str(data.get("model_id") or "").strip()
    if not is_valid_model_id(model_id):
        raise ValueError(
            "model_id 非法：仅允许字母、数字与 . _ -（且不能为空）"
        )

    path = model_config_path(model_id)
    if path is None:
        raise ValueError("model_id 非法")

    _MODELS_DIR.mkdir(parents=True, exist_ok=True)
    # 只落盘已知字段 + 允许的扩展键，避免把任意键写进配置文件
    payload: Dict[str, Any] = {
        "name": str(data.get("name") or "").strip(),
        "base_url": str(data.get("base_url") or "").strip(),
        "api_key": str(data.get("api_key") or ""),
        "model_id": model_id,
    }
    api_model_id = str(data.get("api_model_id") or "").strip()
    if api_model_id:
        payload["api_model_id"] = api_model_id
    for key in (
        "thinking", "if_vision", "max_seqlen", "reasoning_effort",
        "max_output_tokens", "compress_threshold", "temperature", "top_k",
        "timeout_seconds", "max_retries",
        # 纯声明字段（不透传 API，见 REASONING_EFFORT_OPTIONS_KEY 注释）
        REASONING_EFFORT_OPTIONS_KEY,
    ):
        if key in data and data[key] is not None:
            payload[key] = data[key]
    # extra_body 允许直接透传（如 thinking 开关）
    if isinstance(data.get("extra_body"), dict):
        payload["extra_body"] = data["extra_body"]

    tmp_path = path.with_suffix(".yaml.tmp")
    try:
        with open(tmp_path, "w", encoding="utf-8") as f:
            yaml.safe_dump(payload, f, allow_unicode=True, sort_keys=False)
        os.replace(tmp_path, path)
    finally:
        if tmp_path.exists():
            try:
                tmp_path.unlink()
            except OSError:
                pass
    logger.info("自定义模型已写入: %s", path.name)
    return ModelConfig.from_dict(payload)


def delete_model_config(model_id: str) -> bool:
    """删除 ``configs/models/<model_id>.yaml``。

    :return: 是否实际删除；id 非法或文件不存在时返回 False
    """
    path = model_config_path(model_id)
    if path is None or not path.exists():
        return False
    try:
        path.unlink()
    except OSError as exc:
        logger.warning("删除模型配置文件失败 %s: %s", path.name, exc)
        return False
    logger.info("自定义模型已删除: %s", path.name)
    return True


def reload_model_configs() -> Dict[str, ModelConfig]:
    """重新扫描磁盘并把结果写回 ``state.model_configs``，返回新配置。

    **必须**在每次自定义模型写/删之后调用：``state.model_configs`` 是进程启动
    时的快照，而全部生效路径（``PATCH /api/agents/{id}`` 的模型校验、agent 会话
    创建、成员模型解析、team 工具的 create_member）都读该快照。只写 YAML 而不刷新
    快照，会出现"下拉里看得见新模型、选中却被 400 拒绝"的双轨制问题。

    延迟 import ``state`` 以避免 ``config`` 包反向依赖 ``state`` 造成循环导入。
    """
    configs = load_model_configs()
    try:
        import state

        state.model_configs = configs
    except Exception as exc:  # noqa: BLE001
        logger.warning("刷新 state.model_configs 失败: %s", exc)
    return configs
