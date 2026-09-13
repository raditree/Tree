"""插件事件总线 - 统一信封 + 有界队列 + scope/type 过滤 + 异步分发。

对应 ADR D1（事件信封）与 D4/D9（广播订阅、异步与背压）：

- **统一信封**：``PluginEvent`` = {event_id, seq, type, ts, scope, source, payload}；
  scope 为 (user_id, team_id, agent_id, session_id) 四元组自描述键。
- **发布非阻塞**：``publish()`` 只做校验 + 入队（有界队列，满时按
  drop_oldest 丢弃最旧、保留最新并计数），
  绝不在调用线程做分发/处理，不阻塞 LLM 消费线程与事件循环（D9）。
- **异步分发**：单分发线程将事件投递给"匹配的订阅回调"；订阅回调由注册表
  构造，负责把事件投入各自插件实例的处理队列（实例内串行由注册表保证）。
- **过滤（fail-closed 方向）**：按 type 集合 + scope 条件过滤；订阅条件中
  **非空**的每个字段都必须与事件 scope 对应字段相等；事件字段为空而订阅
  要求了该字段时不投递（不能证明匹配即拒绝）。
- **入口校验（fail-closed）**：发布时 ``type`` 与 ``scope.user_id`` 必须
  非空，否则拒绝入队并计数（``dropped_invalid``）。
"""

from __future__ import annotations

import logging
import queue
import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional

logger = logging.getLogger(__name__)

# 事件队列上限（有界队列 + 满溢丢弃计数，防事件洪泛拖垮进程）
DEFAULT_QUEUE_MAX = 1000

# scope 四元组字段顺序（user → team → agent → session，由粗到细）
SCOPE_KEYS = ("user_id", "team_id", "agent_id", "session_id")


def make_scope(
    user_id: str = "",
    team_id: str = "",
    agent_id: str = "",
    session_id: str = "",
) -> Dict[str, str]:
    """构造标准 scope 四元组（缺失字段为空串，自描述键）。"""
    return {
        "user_id": str(user_id or ""),
        "team_id": str(team_id or ""),
        "agent_id": str(agent_id or ""),
        "session_id": str(session_id or ""),
    }


def normalize_scope(scope: Optional[Dict[str, str]]) -> Dict[str, str]:
    """把任意（可能部分缺失的）scope 字典归一化为标准四元组。"""
    scope = scope or {}
    return {key: str(scope.get(key) or "") for key in SCOPE_KEYS}


def scope_matches(cond: Dict[str, str], scope: Dict[str, str]) -> bool:
    """scope 条件匹配（fail-closed 方向）。

    条件 ``cond`` 中非空字段必须全部与 ``scope`` 对应字段相等；
    事件字段为空（未知）而条件要求该字段时判不匹配（不能证明即拒绝）。
    """
    for key in SCOPE_KEYS:
        want = str(cond.get(key) or "")
        if not want:
            continue
        if str(scope.get(key) or "") != want:
            return False
    return True


@dataclass
class PluginEvent:
    """插件事件统一信封（D1）。"""

    event_id: str
    seq: int
    type: str
    ts: float
    scope: Dict[str, str]
    source: str = ""
    payload: Dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> Dict[str, Any]:
        """序列化为可传输/可日志的字典（演示、调试与二期传输用）。"""
        return {
            "event_id": self.event_id,
            "seq": self.seq,
            "type": self.type,
            "ts": self.ts,
            "scope": dict(self.scope),
            "source": self.source,
            "payload": dict(self.payload),
        }


@dataclass(eq=False)
class Subscription:
    """订阅登记：匹配函数 + 投递回调（由注册表构造并管理）。

    ``eq=False``：以对象身份比较，确保移除操作精确对应具体订阅实例。
    """

    name: str
    match_fn: Callable[[PluginEvent], bool]
    deliver_fn: Callable[[PluginEvent], None]


class EventBus:
    """进程内事件总线（线程安全、非阻塞发布、单分发线程）。"""

    def __init__(self, max_queue: int = DEFAULT_QUEUE_MAX) -> None:
        self.max_queue = int(max_queue)
        self._queue: "queue.Queue[Optional[PluginEvent]]" = queue.Queue(
            maxsize=self.max_queue
        )
        self._lock = threading.Lock()
        self._subscriptions: List[Subscription] = []
        self._seq = 0
        self._dispatcher: Optional[threading.Thread] = None
        self._started = False

        # 统计（观测/验收）
        self._stats: Dict[str, int] = {
            "published": 0,       # 成功入队
            "dropped_full": 0,    # 队列满丢弃
            "dropped_invalid": 0, # 校验不过 / 未启动
            "dispatched": 0,      # 成功投递到订阅的累计次数
        }

    # ------------------------------------------------------------------
    # 生命周期
    # ------------------------------------------------------------------
    def start(self) -> None:
        """启动分发线程（幂等）。"""
        with self._lock:
            if self._started:
                return
            self._started = True
            self._dispatcher = threading.Thread(
                target=self._dispatch_loop, name="plugin-bus-dispatcher", daemon=True
            )
            self._dispatcher.start()

    def stop(self, timeout: float = 1.0) -> None:
        """停止分发线程（投递停止哨兵；未处理事件丢弃）。

        可重复调用（幂等）；停止后 ``publish`` 拒绝入队（返回 False）。
        """
        with self._lock:
            if not self._started:
                return
            self._started = False
            dispatcher = self._dispatcher
            self._dispatcher = None
            # 丢弃积压事件（清空队列，为停止哨兵腾位）
            while True:
                try:
                    self._queue.get_nowait()
                except queue.Empty:
                    break
        try:
            self._queue.put_nowait(None)
        except queue.Full:
            pass
        if dispatcher is not None and dispatcher.is_alive():
            dispatcher.join(timeout=timeout)

    @property
    def started(self) -> bool:
        """是否已启动（观测用）。"""
        return self._started

    # ------------------------------------------------------------------
    # 发布 / 订阅
    # ------------------------------------------------------------------
    def publish(
        self,
        event_type: str,
        scope: Optional[Dict[str, str]],
        payload: Optional[Dict[str, Any]] = None,
        source: str = "",
    ) -> bool:
        """发布事件（非阻塞入队）。

        校验（fail-closed 入口防线）：``type`` 与 ``scope.user_id`` 必须非空，
        否则拒绝发布并计数（``dropped_invalid``）。

        :return: 是否成功入队（False = 校验不过 / 未启动 / 队列满）
        """
        if not event_type:
            self._bump("dropped_invalid")
            return False
        normalized = normalize_scope(scope)
        if not normalized["user_id"]:
            self._bump("dropped_invalid")
            logger.debug("插件事件缺少 user_id，拒绝发布: type=%s", event_type)
            return False
        with self._lock:
            if not self._started:
                self._stats["dropped_invalid"] += 1
                return False
            self._seq += 1
            event = PluginEvent(
                event_id=uuid.uuid4().hex,
                seq=self._seq,
                type=str(event_type),
                ts=time.time(),
                scope=normalized,
                source=str(source or ""),
                payload=dict(payload or {}),
            )
        try:
            self._queue.put_nowait(event)
        except queue.Full:
            # 溢出策略（默认 drop_oldest）：腾出最旧一条、保留最新（保现场），
            # 计数 dropped_full；极端竞争下腾挪失败才丢弃本次事件。
            dropped_old: Optional[PluginEvent] = None
            try:
                dropped_old = self._queue.get_nowait()
            except queue.Empty:  # 另一线程已腾出空间
                dropped_old = None
            try:
                self._queue.put_nowait(event)
            except queue.Full:
                self._bump("dropped_full")
                logger.warning(
                    "插件事件队列已满且腾挪失败，丢弃: type=%s seq=%s",
                    event.type,
                    event.seq,
                )
                return False
            self._bump("dropped_full")
            logger.warning(
                "插件事件队列已满，丢弃最旧事件保最新: dropped_id=%s 新事件 type=%s seq=%s",
                getattr(dropped_old, "event_id", None),
                event.type,
                event.seq,
            )
        self._bump("published")
        return True

    def add_subscription(self, subscription: Subscription) -> None:
        """登记订阅（由注册表在插件实例创建时调用）。"""
        with self._lock:
            self._subscriptions.append(subscription)

    def remove_subscription(self, subscription: Subscription) -> bool:
        """移除订阅（由注册表在插件实例销毁时调用）。"""
        with self._lock:
            try:
                self._subscriptions.remove(subscription)
                return True
            except ValueError:
                return False

    def subscription_count(self) -> int:
        """当前订阅数（观测用）。"""
        with self._lock:
            return len(self._subscriptions)

    def stats(self) -> Dict[str, int]:
        """总线统计快照（观测/验收用）。"""
        with self._lock:
            data = dict(self._stats)
            data["subscriptions"] = len(self._subscriptions)
        data["queue_size"] = self._queue.qsize()
        return data

    # ------------------------------------------------------------------
    # 内部：分发
    # ------------------------------------------------------------------
    def _bump(self, key: str) -> None:
        with self._lock:
            self._stats[key] = self._stats.get(key, 0) + 1

    def _dispatch_loop(self) -> None:
        """分发线程主循环：取事件 → 匹配订阅 → 投递。"""
        while True:
            try:
                item = self._queue.get(timeout=0.2)
            except queue.Empty:
                with self._lock:
                    if not self._started:
                        return
                continue
            if item is None:
                # 停止哨兵
                return
            try:
                self._dispatch_event(item)
            except Exception:  # noqa: BLE001
                logger.exception(
                    "插件事件分发失败: %s", getattr(item, "type", "?")
                )

    def _dispatch_event(self, event: PluginEvent) -> None:
        """把事件投递给全部匹配订阅（单个订阅失败不影响其他订阅）。"""
        with self._lock:
            subs = list(self._subscriptions)
        for sub in subs:
            try:
                if sub.match_fn(event):
                    sub.deliver_fn(event)
                    with self._lock:
                        self._stats["dispatched"] += 1
            except Exception:  # noqa: BLE001
                logger.exception("插件订阅投递失败: %s", sub.name)
