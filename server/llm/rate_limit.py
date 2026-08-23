"""主动延迟限流：按 (user_id, agent_id) 粒度的令牌桶限流器。

「主动延迟」开关（前端设置页）开启后，限制单个 agent 的 LLM API 调用频率
为平均 6 次/分钟（即每次调用最小间隔 10s）。适合交互式开发——放慢 agent
节奏，避免一口气烧完大量 API 调用，让用户跟得上每个步骤。

实现采用游戏帧率控制式**固定时间步（fixed time-step pacing）**思想：
- 令牌桶容量 1：距上次调用已超过间隔时立即放行（等效帧率下界）；
- 补充速率 6 令牌/分钟（1 令牌/10s）：无令牌时阻塞等待直至补满，
  保证任意滑动窗口内的平均频率不超过 6 次/分钟（比简单 sleep 更平滑，
  也不会在长时间空闲后允许突发爆发，与「平均限速」语义一致）。

开启状态按用户（openid）持久化（``server/data/rate_limit_store.py``），
本模块维护内存缓存（``_user_enabled``）与按 (user_id, agent_id) 的限流器
实例（``_limiters``），避免每次 API 调用都查 SQLite。
"""
import threading
import time
from typing import Dict, Optional, Tuple

# 日志器
import logging

from config.config import get_config

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

    def acquire(self, cancel_event: Optional[threading.Event] = None) -> bool:
        """获取令牌：通过则返回 True；等待期间被取消返回 False。

        返回 False 时**不消费令牌**（下次调用仍按原节奏），调用方应中止
        本轮 API 调用（如已收到停止信号）。
        """
        with self._lock:
            now = time.monotonic()
            if now >= self._next_allowed:
                # 有令牌：立即放行，并把下次允许时间推到间隔之后
                self._next_allowed = now + MIN_INTERVAL
                return True
            wait = self._next_allowed - now

            # 无令牌：分片等待（可响应取消事件），直到令牌补满
            deadline = time.monotonic() + wait
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self._next_allowed = time.monotonic() + MIN_INTERVAL
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


def load_enabled_users(prefs: Dict[str, bool]) -> None:
    """启动时预载全部用户的主动延迟开关（来自 SQLite 持久化）。"""
    with _registry_lock:
        _user_enabled.clear()
        _user_enabled.update(prefs or {})
    logger.info("已加载 %d 个用户的主动延迟开关", len(_user_enabled))


def reset_user(user_id: str) -> None:
    """用户注销彻底删除时清理其开关缓存与限流器实例。"""
    with _registry_lock:
        _user_enabled.pop(user_id, None)
        for key in [k for k in _limiters if k[0] == user_id]:
            _limiters.pop(key, None)


def acquire(
    user_id: str,
    agent_id: str,
    cancel_event: Optional[threading.Event] = None,
) -> bool:
    """主动延迟限流入口：按 (user_id, agent_id) 获取令牌。

    - 用户未开启 / 缺少 user_id / agent_id 时直接放行（不产生任何等待）。
    - 开启时等待令牌（平均 6 次/分钟），等待期间可被 ``cancel_event`` 取消。
    - 返回 False 表示应中止本轮 API 调用（收到停止信号）。
    """
    if not user_id or not agent_id:
        return True
    if not is_user_enabled(user_id):
        return True
    with _registry_lock:
        limiter = _limiters.get((user_id, agent_id))
        if limiter is None:
            limiter = AgentRateLimiter()
            _limiters[(user_id, agent_id)] = limiter
    return limiter.acquire(cancel_event)


__all__ = [
    "AgentRateLimiter",
    "acquire",
    "is_user_enabled",
    "load_enabled_users",
    "reset_user",
    "set_user_enabled",
    "MIN_INTERVAL",
    "RATE_PER_MINUTE",
]
