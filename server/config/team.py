"""团队规模配置常量（创建 TOP agent 时设定，之后不可修改）。

团队规模（最大层级深度、每层成员上限）不再由 app.yaml / 用户等级承载，
而是在创建 TOP agent 时由用户指定并持久化到 ``teams`` 表；等级只负责
并发控制（``registration.levels.*.max_concurrent_agents``）。

本模块仅提供代码内默认值与硬上限：
- 创建 TOP 时未显式指定 → 用 DEFAULT_* 兜底；
- 创建请求值超出 HARD_* → 拒绝（防超量建队，保护宿主资源）。
"""
from typing import Any, Dict, Optional

# 创建 TOP 时未指定团队配置的默认值
DEFAULT_TEAM_MAX_LEVEL: int = 3
DEFAULT_TEAM_MAX_MEMBERS: int = 7

# 硬上限：创建请求校验用（超出即 400，不静默截断）
HARD_MAX_LEVEL: int = 5
HARD_MAX_MEMBERS: int = 100


def clamp_level(value: Any, default: int = DEFAULT_TEAM_MAX_LEVEL) -> int:
    """解析层级深度为合法整数（>=1），非法值回退 default。"""
    try:
        v = max(1, int(value))
    except (TypeError, ValueError):
        return default
    return v


def clamp_members(value: Any, default: int = DEFAULT_TEAM_MAX_MEMBERS) -> int:
    """解析每层成员上限为合法整数（>=1），非法值回退 default。"""
    try:
        v = max(1, int(value))
    except (TypeError, ValueError):
        return default
    return v


def resolve_team_config(
    max_level: Optional[Any] = None,
    max_members_per_level: Optional[Any] = None,
) -> Dict[str, int]:
    """归一化团队配置，返回 ``{"max_level": int, "max_members_per_level": int}``。"""
    return {
        "max_level": clamp_level(max_level),
        "max_members_per_level": clamp_members(max_members_per_level),
    }
