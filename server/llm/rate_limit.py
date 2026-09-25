"""分级 API 限流：按 (user_id, agent_id) 粒度的令牌桶限流器。

按用户等级 + 「主动延迟」开关动态解析限流间隔（秒）：
- 主动延迟关闭（is_user_enabled=False）：interval = 60 / 等级 rate_per_minute
  （common 12 / pro 24 / ultra 60 / beta 300 次/分钟）；
- 主动延迟开启（is_user_enabled=True）：interval = 60 / 等级
  active_rate_per_minute（各等级均 6 次/分钟），适合交互式开发——放慢 agent
  节奏，避免一口气烧完大量 API 调用，让用户跟得上每个步骤；
- 等级配置缺失或 rate<=0 时回退 MIN_INTERVAL（60 / llm.rate_per_minute，默认 6/min）。
- 无论是否开启主动延迟都限流；缺少 user_id / agent_id 时直接放行。

实现采用游戏帧率控制式**固定时间步（fixed time-step pacing）**思想：
- 令牌桶容量 1：距上次调用已超过间隔时立即放行（等效帧率下界）；
- 无令牌时阻塞等待直至补满，保证任意滑动窗口内的平均频率不超过对应等级
  的限速（比简单 sleep 更平滑，也不会在长时间空闲后允许突发爆发）。

主动延迟开关按用户（openid）持久化（``server/data/rate_limit_store.py``），
本模块维护内存缓存（``_user_enabled``）与按 (user_id, agent_id) 的限流器
实例（``_limiters``），避免每次 API 调用都查 SQLite。
"""
import threading
import time
from typing import Dict, Optional, Tuple

# 日志器
import logging

from config import levels
from config.config import get_config
from data import user_store

logger = logging.getLogger(__name__)

# 主动延迟限流节奏：由 app.yaml (llm.rate_per_minute / llm.min_interval_seconds)
# 驱动。min_interval_seconds 为 0 时按 60/rate_per_minute 自动推导。
_RATE_CFG = (get_config() or {}).get("llm", {}) or {}
RATE_PER_MINUTE = float(
    _RATE_CFG.get("rate_per_minute", 6.0) or 6.0
)
_cfg_interval = float(_RATE_CFG.get("min_interval_seconds", 0) or 0)
# 最小调用间隔（秒）：优先取配置，否则按 60 / rate_per_minute 推导
MIN_INTERVAL = _cfg_interval if _cfg_interval > 0 else 60.0 / RATE_PER_MINUTE

# 用户开关内存缓存：user_id -> enabled
_user_enabled: Dict[str, bool] = {}
# 用户流式帧率内存缓存：user_id -> fps（缺省 DEFAULT_FRAME_RATE）
_user_frame_rate: Dict[str, int] = {}
# 按 (user_id, agent_id) 的限流器实例
_limiters: Dict[Tuple[str, str], "AgentRateLimiter"] = {}
_registry_lock = threading.Lock()


class AgentRateLimiter:
    """单个 agent 的令牌桶限流器（节奏由 app.yaml 的 llm.rate_per_minute 决定）。

    线程安全：``acquire`` 全程持有锁，串行化同一 agent 的令牌消费。
    实际运行中同一 (user_id, agent_id) 的 LLM 调用由其 broker worker 串行
    执行，锁主要防御多会话/直连消息等并发边角路径。

    等待期间支持取消：传入 ``cancel_event``（前端「停止」置位）后按 0.2s
    分片等待，收到取消立即返回 False，配合停止级联让限流等待不拖延停止。
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        # 下一次允许发起 API 调用的时间（time.monotonic 时间戳）
        self._next_allowed = 0.0

    def acquire(
        self,
        cancel_event: Optional[threading.Event] = None,
        interval: Optional[float] = None,
    ) -> bool:
        """获取令牌：通过则返回 True；等待期间被取消返回 False。

        ``interval`` 为本调用应遵循的最小间隔（秒），缺省或非正数时用
        ``MIN_INTERVAL`` 兜底；``_next_allowed`` 推进使用该 interval。

        返回 False 时**不消费令牌**（下次调用仍按原节奏），调用方应中止
        本轮 API 调用（如已收到停止信号）。
        """
        if not interval or interval <= 0:
            interval = MIN_INTERVAL
        with self._lock:
            now = time.monotonic()
            if now >= self._next_allowed:
                # 有令牌：立即放行，并把下次允许时间推到间隔之后
                self._next_allowed = now + interval
                return True
            wait = self._next_allowed - now

            # 无令牌：分片等待（可响应取消事件），直到令牌补满
            deadline = time.monotonic() + wait
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self._next_allowed = time.monotonic() + interval
                    return True
                if cancel_event is not None:
                    # 等待期间可响应「停止」：最多等 0.2s 检查一次
                    if cancel_event.wait(min(remaining, 0.2)):
                        return False
                else:
                    time.sleep(min(remaining, 0.2))


# ----------------------------------------------------------------------
# 用户开关与全局注册表
# ----------------------------------------------------------------------
def set_user_enabled(user_id: str, enabled: bool) -> None:
    """设置某用户是否开启主动延迟（内存缓存，由 REST 设置接口调用）。"""
    with _registry_lock:
        _user_enabled[user_id] = bool(enabled)


def is_user_enabled(user_id: str) -> bool:
    """查询某用户是否开启主动延迟（内存缓存，启动时从 DB 预载）。"""
    return bool(_user_enabled.get(user_id))


def _resolve_interval(user_id: str) -> float:
    """按用户等级 + 主动延迟开关解析最小调用间隔（秒）。

    - 主动延迟关闭（is_user_enabled=False）：用该等级配置的 ``rate_per_minute``；
    - 主动延迟开启（is_user_enabled=True）：用该等级配置的 ``active_rate_per_minute``；
    - 间隔 = 60 / rate（次/分钟）；等级配置缺失或 rate<=0 时回退 ``MIN_INTERVAL``。

    ``user_store.get_user_level`` / ``levels.get_level_config`` 均已对非法值
    兜底；此处再包一层异常保护，避免个别用户数据异常拖垮限流入口。
    """
    try:
        level = user_store.get_user_level(user_id)
        cfg = levels.get_level_config(level)
        if is_user_enabled(user_id):
            rate = float(cfg.get("active_rate_per_minute", 0) or 0)
        else:
            rate = float(cfg.get("rate_per_minute", 0) or 0)
    except Exception:  # noqa: BLE001 - 兜底：解析失败也按最小间隔限流
        rate = 0.0
    if rate <= 0:
        return MIN_INTERVAL
    return 60.0 / rate


def load_enabled_users(prefs: Dict[str, bool]) -> None:
    """启动时预载全部用户的主动延迟开关（来自 SQLite 持久化）。"""
    with _registry_lock:
        _user_enabled.clear()
        _user_enabled.update(prefs or {})
    logger.info("已加载 %d 个用户的主动延迟开关", len(_user_enabled))


# ----------------------------------------------------------------------
# 流式帧率（主动延迟开启时叠加的第二把旋钮）
# ----------------------------------------------------------------------
def set_user_frame_rate(user_id: str, frame_rate: int) -> int:
    """设置某用户的流式帧率（内存缓存，由 REST 设置接口调用）。

    :return: 规范化后的实际生效值（fps）
    """
    from data.frame_rate_store import clamp_frame_rate

    rate = clamp_frame_rate(frame_rate)
    with _registry_lock:
        _user_frame_rate[user_id] = rate
    return rate


def get_user_frame_rate(user_id: str) -> int:
    """查询某用户的流式帧率（fps）；未设置时返回库缺省值。"""
    from data.frame_rate_store import DEFAULT_FRAME_RATE, clamp_frame_rate

    with _registry_lock:
        if user_id in _user_frame_rate:
            return _user_frame_rate[user_id]
    return clamp_frame_rate(DEFAULT_FRAME_RATE)


def load_frame_rates(prefs: Dict[str, int]) -> None:
    """启动时预载全部用户的流式帧率（来自 SQLite 持久化）。"""
    from data.frame_rate_store import clamp_frame_rate

    with _registry_lock:
        _user_frame_rate.clear()
        _user_frame_rate.update(
            {str(k): clamp_frame_rate(v) for k, v in (prefs or {}).items()}
        )
    logger.info("已加载 %d 个用户的流式帧率", len(_user_frame_rate))


def frame_interval(user_id: str) -> float:
    """解析当前用户应采用的**帧间隔（秒）**：0 表示不节流。

    - 主动延迟未开启 → 0（不开帧率控制，保持原生流式速度）；
    - 已开启 → ``1 / fps``（fps 由用户在「设置」中调整，范围 20~1000）。

    每帧现查内存缓存（O(1) dict 读），因此**会话中途切换开关或调整帧率都能
    立即生效**，无需重建会话。
    """
    if not user_id or not is_user_enabled(user_id):
        return 0.0
    fps = get_user_frame_rate(user_id)
    if fps <= 0:
        return 0.0
    return 1.0 / float(fps)


def reset_user(user_id: str) -> None:
    """用户注销彻底删除时清理其开关/帧率缓存与限流器实例。"""
    with _registry_lock:
        _user_enabled.pop(user_id, None)
        _user_frame_rate.pop(user_id, None)
        for key in [k for k in _limiters if k[0] == user_id]:
            _limiters.pop(key, None)


def remove_agent(user_id: str, agent_id: str) -> None:
    """删除 agent 时清理其限流器实例（300+ agent 长跑防注册表膨胀）。

    agent 删除后不会再发起 API 调用，残留的 ``AgentRateLimiter`` 只会占
    内存；此处主动摘除，配合 broker ``remove_agent`` / 会话缓存 LRU 治理。
    """
    with _registry_lock:
        _limiters.pop((user_id, agent_id), None)


def set_user_level(user_id: str, level: str) -> None:
    """等级变更后清除该用户所有限流器实例，使新等级节奏立即生效。

    用户等级的内存缓存/落盘由 ``data.user_store`` 维护，这里只做限流器
    复位：下次 ``acquire`` 会按新等级重新解析间隔并重新获得一枚令牌，
    避免旧等级残留的 ``_next_allowed`` 拖延新等级的首个调用。
    """
    with _registry_lock:
        for key in [k for k in _limiters if k[0] == user_id]:
            _limiters.pop(key, None)


def acquire(
    user_id: str,
    agent_id: str,
    cancel_event: Optional[threading.Event] = None,
) -> bool:
    """分级 API 限流入口：按 (user_id, agent_id) 获取令牌。

    - 缺少 user_id / agent_id 时直接放行（不产生任何等待）。
    - 无论是否开启主动延迟都限流：间隔按用户等级 + 开关动态解析
      （关闭用等级 ``rate_per_minute``，开启用等级 ``active_rate_per_minute``）。
    - 等待期间可被 ``cancel_event`` 取消。
    - 返回 False 表示应中止本轮 API 调用（收到停止信号）。
    """
    if not user_id or not agent_id:
        return True
    interval = _resolve_interval(user_id)
    with _registry_lock:
        limiter = _limiters.get((user_id, agent_id))
        if limiter is None:
            limiter = AgentRateLimiter()
            _limiters[(user_id, agent_id)] = limiter
    return limiter.acquire(cancel_event, interval)


__all__ = [
    "AgentRateLimiter",
    "acquire",
    "frame_interval",
    "get_user_frame_rate",
    "is_user_enabled",
    "load_enabled_users",
    "load_frame_rates",
    "remove_agent",
    "reset_user",
    "set_user_enabled",
    "set_user_frame_rate",
    "set_user_level",
    "MIN_INTERVAL",
    "RATE_PER_MINUTE",
]
