"""等级（registration）配置解析辅助模块。

供限流 / 并发 / 团队等模块复用，统一通过 config.config.get_config() 读取。
所有读取均容错：registration 段不存在时不抛异常，按默认值返回。
"""
from typing import Any, Dict

from config.config import get_config

# 默认等级
DEFAULT_LEVEL = "common"

# 合法等级名称集合（只允许 common/pro/ultra/beta）
_VALID_LEVELS = frozenset({"common", "pro", "ultra", "beta"})

# registration 段整体缺失时的默认值
_DEFAULT_REGISTRATION: Dict[str, Any] = {
    "enabled": True,
    "restore_level": False,
    "key_dir": "",
    "levels": {},
}


def _registration() -> Dict[str, Any]:
    """返回整个 registration 段（缺失或非 dict 时返回默认值，不抛异常）。"""
    reg = get_config().get("registration")
    if not isinstance(reg, dict):
        return dict(_DEFAULT_REGISTRATION)
    return reg


def _levels() -> Dict[str, Any]:
    """返回 registration.levels 段（缺失或非 dict 时返回空 dict）。"""
    levels = _registration().get("levels")
    if not isinstance(levels, dict):
        return {}
    return levels


def is_valid_level(level: str) -> bool:
    """判断 level 名称是否合法（只允许 common/pro/ultra/beta）。"""
    return level in _VALID_LEVELS


def get_level_config(level: str) -> dict:
    """返回某等级配置。

    对 level 名称做校验，非法名称一律视为 DEFAULT_LEVEL；
    指定等级缺失时用 DEFAULT_LEVEL 兜底，再缺失返回空 dict。
    """
    levels = _levels()
    if not levels:
        return {}
    if not is_valid_level(level):
        level = DEFAULT_LEVEL
    cfg = levels.get(level)
    if not isinstance(cfg, dict):
        cfg = levels.get(DEFAULT_LEVEL)
    if not isinstance(cfg, dict):
        return {}
    return cfg


def get_levels() -> dict:
    """返回 registration.levels 全部等级配置（缺失时返回空 dict）。"""
    return _levels()


def get_registration_config() -> dict:
    """返回整个 registration 段；缺失时按默认值
    {enabled: True, restore_level: False, key_dir: "", levels: {}} 返回。"""
    return _registration()
