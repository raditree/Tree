"""提示词版本选择层。

依据 ``configs/app.yaml`` 的 ``prompt.version`` 决定**当前激活版本**，并对外
提供统一的激活解析器（对 chat.py / llm.py / 各工具消费方）：

    active_version()                 -> 激活版本号
    active_system_head()             -> 静态头章节
    active_system_tail()             -> 静态尾章节
    active_compressor(raw)           -> 上下文压缩提示词
    active_tool_description(name)    -> 工具描述

内容本体由 :mod:`prompt.loader` 从 ``versions/<version>/`` 数据目录加载。
激活版本解析结果带缓存；配置到未登记版本时 **fail-fast（raise）**，不做静默回退，
保证生产行为可预期、可审计。
"""

from __future__ import annotations

from functools import lru_cache
from typing import Dict, Optional

from .loader import VersionMissingError, load_version
from .schema import PromptVersion

# ---------------------------------------------------------------------------
# 配置读取（惰性 import，避免 import 期耦合 config / 循环依赖）
# ---------------------------------------------------------------------------

_DEFAULT_VERSION = "1.0.0"


def _read_configured_version() -> str:
    try:
        from config.config import get_config
        cfg = get_config() or {}
    except Exception:  # noqa: BLE001  # 配置缺失/不可用时不阻断，回退到默认版本
        return _DEFAULT_VERSION
    prompt_cfg = cfg.get("prompt") or {}
    version = prompt_cfg.get("version", _DEFAULT_VERSION)
    return str(version) if version else _DEFAULT_VERSION


# ---------------------------------------------------------------------------
# 加载与缓存
# ---------------------------------------------------------------------------

_cache: Dict[str, Optional[PromptVersion]] = {}


def _get_version(version: str) -> PromptVersion:
    """加载并缓存指定版本；版本未登记则 raise。"""
    pv = _cache.get(version)
    if pv is not None:
        return pv
    try:
        pv = load_version(version)
    except VersionMissingError:
        raise
    except FileNotFoundError as exc:
        raise VersionMissingError(f"提示词版本未登记（数据目录缺失）: {version}") from exc
    _cache[version] = pv
    return pv


def get_version(version: str) -> PromptVersion:
    """显式加载指定版本（供审计 / 运维查看某一特定版本）。"""
    return _get_version(version)


def list_versions() -> tuple:
    """已缓存版本列表（便于运维查看已加载过的版本）。"""
    return tuple(sorted(_cache))


# ---------------------------------------------------------------------------
# 激活解析器（对外公共入口）
# ---------------------------------------------------------------------------

def active_version() -> str:
    """返回运行中的激活版本号（来自 app.yaml ``prompt.version``）。"""
    return _active_lazy().version


@lru_cache(maxsize=4)
def _active_lazy_version() -> str:
    return _read_configured_version()


def _active_lazy() -> PromptVersion:
    return _get_version(_active_lazy_version())


def active_system_head() -> tuple:
    """激活版本的静态头章节。"""
    return _active_lazy().system_head


def active_system_tail() -> tuple:
    """激活版本的静态尾章节。"""
    return _active_lazy().system_tail


def active_chapters() -> tuple:
    """激活版本的静态全量章节（头 + 尾）。"""
    pv = _active_lazy()
    return pv.system_head + pv.system_tail


def active_compressor(raw: str) -> str:
    """返回激活版本的上下文压缩提示词。"""
    return _active_lazy().compressor(raw)


def active_tool_description(name: str) -> str:
    """返回激活版本的指定工具描述。

    :raises KeyError: 该工具在当前激活版本未登记描述
    """
    pv = _active_lazy()
    try:
        return pv.tool_descriptions[name]
    except KeyError:
        raise KeyError(
            f"工具 '{name}' 在当前提示词版本 v{pv.version} 未登记描述"
        ) from None