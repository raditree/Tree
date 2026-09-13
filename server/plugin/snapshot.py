"""只读面板快照合成（二期 M1-b）—— 面板数据源（契约 §15.1 定稿形状）。

- **纯合成**（依赖注入）：输入各组件与过滤条件，输出扁平 dict；
  registry / stations / watchdog 为 ``None`` 时按"未启用骨架"输出（200 语义）；
- **只读**：不产生任何副作用；供 REST 端点与测试直接调用；
- **逐块容错**：任一子收集异常仅记录日志并按空值输出，快照整体保持可用；
- 形状（与柳依对齐样例）::

    {"enabled": bool, "generated_at": ts,
     "instances": [{plugin_id, name, granularity, scope, status,
                    last_heartbeat, queue_depth, disabled_reason}],
     "stations":  [{station_id, subscriptions: [...], counts, gauges, timing}],
     "watchdog":  {"active_runs": int, "judged_dead": int},
     "config":    {instance_ttl_s, ttl_sweep_interval_s, station_timeout_s,
                   status_max_per_sec}}

字段可增；前端防御式解析（缺字段容错、未知忽略）。
"""

from __future__ import annotations

import logging
import time
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)


def build_config_summary() -> Dict[str, Any]:
    """关键配置摘要（面板展示；静态默认值，不含敏感信息）。"""
    from plugin import registry as _registry  # noqa: PLC0415
    from plugin import stations as _stations  # noqa: PLC0415
    from plugin import status as _status  # noqa: PLC0415

    try:
        station_timeout: Optional[float] = float(
            _stations._default_timeout_s()  # noqa: SLF001（包内部件：取权威默认值）
        )
    except Exception:  # noqa: BLE001
        station_timeout = None
    return {
        "instance_ttl_s": getattr(_registry, "DEFAULT_IDLE_TTL", None),
        "ttl_sweep_interval_s": getattr(
            _registry, "DEFAULT_TTL_SWEEP_INTERVAL", None
        ),
        "station_timeout_s": station_timeout,
        "status_max_per_sec": getattr(_status, "DEFAULT_MAX_PER_SEC", None),
    }


def _collect_instances(
    registry: Optional[Any], *, user_id: str, team_id: str
) -> List[Dict[str, Any]]:
    """实例区块（按 user / team 过滤；缺组件返回空）。"""
    out: List[Dict[str, Any]] = []
    if registry is None:
        return out
    try:
        for inst in registry.instances():
            scope = dict(getattr(inst, "scope", {}) or {})
            if user_id and scope.get("user_id", "") != user_id:
                continue
            if team_id and scope.get("team_id", "") != team_id:
                continue
            inbox = getattr(inst, "inbox", None)
            try:
                queue_depth = int(inbox.qsize()) if inbox is not None else 0
            except Exception:  # noqa: BLE001
                queue_depth = 0
            out.append(
                {
                    "plugin_id": str(getattr(inst, "plugin_id", "")),
                    "name": str(getattr(inst, "name", "")),
                    "granularity": str(getattr(inst, "granularity", "")),
                    "scope": scope,
                    "status": (
                        "registered"
                        if getattr(inst, "alive", False)
                        else "destroyed"
                    ),
                    "last_heartbeat": float(
                        getattr(inst, "last_active", 0.0) or 0.0
                    ),
                    "queue_depth": queue_depth,
                    # M3 巡检停用（判死联动）落地后填充
                    "disabled_reason": "",
                }
            )
    except Exception:  # noqa: BLE001
        logger.debug("快照实例收集异常（按空输出）", exc_info=True)
        return []
    return out


def _collect_stations(stations: Optional[Any]) -> List[Dict[str, Any]]:
    """站区块（按 station_id 分组订阅；counts/gauges/timing 为全局口径）。"""
    if stations is None:
        return []
    try:
        st = stations.stats()
    except Exception:  # noqa: BLE001
        logger.debug("快照站点统计异常（按空输出）", exc_info=True)
        return []
    subs_by_station: Dict[str, List[Dict[str, Any]]] = {}
    for sub in st.get("subscriptions", []) or []:
        sid = str(sub.get("station_id", ""))
        subs_by_station.setdefault(sid, []).append(
            {
                "subscriber": str(sub.get("inst_key", "")),
                "plugin_id": str(sub.get("plugin_id", "")),
                "granularity": str(sub.get("granularity", "")),
                "scope": dict(sub.get("scope", {}) or {}),
                "timeout_s": sub.get("timeout_s"),
            }
        )
    counts = dict(st.get("counts", {}) or {})
    gauges = dict(st.get("gauges", {}) or {})
    timing = dict(st.get("timing", {}) or {})
    known = list((st.get("stations", {}) or {}).keys())
    for sid in subs_by_station:
        if sid not in known:
            known.append(sid)
    # 说明：counts / gauges / timing 当前为"全局口径"（单站场景）；多站细分
    # 随 M3 观测增强评估（契约 §15.3 字段最小集不要求站级细分）。
    return [
        {
            "station_id": sid,
            "subscriptions": subs_by_station.get(sid, []),
            "counts": counts,
            "gauges": gauges,
            "timing": timing,
        }
        for sid in known
    ]


def _collect_watchdog(watchdog: Optional[Any]) -> Dict[str, Any]:
    """看门狗区块（active_runs=存活 run 数；judged_dead 待 M3 接入）。"""
    active = 0
    if watchdog is not None:
        try:
            active = int(watchdog.task_count())
        except Exception:  # noqa: BLE001
            active = 0
    return {"active_runs": active, "judged_dead": 0}


def build_snapshot(
    *,
    enabled: bool,
    user_id: str = "",
    team_id: str = "",
    registry: Optional[Any] = None,
    stations: Optional[Any] = None,
    watchdog: Optional[Any] = None,
    generated_at: Optional[float] = None,
) -> Dict[str, Any]:
    """合成面板只读快照（组件缺失 → 空值；未启用 → 空骨架，均 200 语义）。"""
    return {
        "enabled": bool(enabled),
        "generated_at": float(
            generated_at if generated_at is not None else time.time()
        ),
        "instances": _collect_instances(
            registry, user_id=str(user_id or ""), team_id=str(team_id or "")
        ),
        "stations": _collect_stations(stations),
        "watchdog": _collect_watchdog(watchdog),
        "config": build_config_summary(),
    }
