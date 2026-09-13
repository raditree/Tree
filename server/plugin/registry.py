"""插件注册表 - 独立生命周期的实例管理（定义共享、实例按 scope 隔离）。

对应 ADR D2/D3：

- **实例按 scope 隔离**：实例键结构由粒度决定——
  team 级 ``(user_id, team_id)``、agent 级 ``(user_id, team_id, agent_id)``、
  session 级 ``(user_id, team_id, agent_id, session_id)``；
  前缀层级 team ⊂ agent ⊂ session（越细粒度实例只服务越小的范围）。
- **独立生命周期**：独立字典 + 独立锁，禁止与 ``session_cache`` 的 LRU
  混用（常驻实例不是请求间缓存）；提供空闲 TTL + Pin 常驻 + 级联清理
  （session 删 / agent 移除 / 团队解散 / 用户注销）。
- **实例内串行、实例间并行**：每个实例一个处理队列 + 一个常驻 worker
  线程，事件按到达顺序串行处理；不同实例各跑各的线程。
- **fail-closed 匹配**：实例 scope 中非空字段必须与事件 scope 对应字段
  相等；事件字段为空而实例要求该字段时不匹配（与总线过滤同向）。
"""

from __future__ import annotations

import logging
import os
import queue
import threading
import time
from typing import Any, Callable, Dict, List, Optional, Tuple

from plugin.bus import (
    EventBus,
    PluginEvent,
    Subscription,
    make_scope,
    scope_matches,
)
from plugin.watchdog import ProgressWatchdog

logger = logging.getLogger(__name__)

# 实例处理队列上限（实例内背压：满则丢弃 + 计数）
DEFAULT_INBOX_MAX = 256


def _read_idle_ttl_default() -> float:
    """读取实例空闲 TTL 默认值（env ``PLUGIN_INSTANCE_TTL_S``，默认 3600s）。"""
    try:
        value = float(os.environ.get("PLUGIN_INSTANCE_TTL_S", "") or 3600.0)
    except (TypeError, ValueError):
        return 3600.0
    return value if value > 0 else 3600.0


# 空闲 TTL 默认值（秒）：非 Pin 实例超过该时长无活动可被收集清理。
# 对齐协调裁定：默认 3600s（可经 PLUGIN_INSTANCE_TTL_S 配置）；Pin 豁免。
DEFAULT_IDLE_TTL = _read_idle_ttl_default()


def _read_sweep_interval_default() -> float:
    """读取 TTL 周期清扫间隔（env ``PLUGIN_TTL_SWEEP_INTERVAL_S``，默认 600s）。"""
    try:
        value = float(os.environ.get("PLUGIN_TTL_SWEEP_INTERVAL_S", "") or 600.0)
    except (TypeError, ValueError):
        return 600.0
    return value if value > 0 else 600.0


# TTL 周期清扫间隔（秒）：插件体系初始化后由清扫线程按此周期调用 cleanup_stale()
# （D-12/C1；建议 300–600s，env 可配）
DEFAULT_TTL_SWEEP_INTERVAL = _read_sweep_interval_default()

# 粒度 → scope 字段序列（前缀层级）
GRANULARITY_FIELDS: Dict[str, Tuple[str, ...]] = {
    "team": ("user_id", "team_id"),
    "agent": ("user_id", "team_id", "agent_id"),
    "session": ("user_id", "team_id", "agent_id", "session_id"),
}


def scope_key(granularity: str, scope: Dict[str, str]) -> Tuple[str, ...]:
    """按粒度从 scope 提取实例键（缺失字段为空串）。

    :raises ValueError: 未知粒度（fail-closed，不静默降级）
    """
    fields = GRANULARITY_FIELDS.get(str(granularity or "team"))
    if fields is None:
        raise ValueError(f"未知插件实例粒度: {granularity!r}")
    normalized = make_scope(**{k: (scope or {}).get(k, "") for k in
                               ("user_id", "team_id", "agent_id", "session_id")})
    return tuple(normalized[f] for f in fields)


class PluginInstance:
    """一个插件实例（特定 plugin_id + 特定 scope 粒度）。

    - ``handler``：事件处理函数（``handler(event)``，在实例 worker 线程串行调用）；
    - ``event_types``：订阅的事件类型集合（None = 全部）；
    - ``pin``：常驻标记（TTL 清理跳过 Pin 实例）；
    - ``last_active``：实例活跃时间（实例级心跳，供 TTL 判定）。
    """

    def __init__(
        self,
        plugin_id: str,
        granularity: str,
        scope: Dict[str, str],
        handler: Callable[[PluginEvent], Any],
        *,
        event_types: Optional[set] = None,
        pin: bool = False,
        idle_ttl: float = DEFAULT_IDLE_TTL,
        inbox_max: int = DEFAULT_INBOX_MAX,
        watchdog: Optional[ProgressWatchdog] = None,
        name: str = "",
    ) -> None:
        self.plugin_id = str(plugin_id)
        self.granularity = str(granularity)
        self.scope = make_scope(**{k: (scope or {}).get(k, "") for k in
                                   ("user_id", "team_id", "agent_id", "session_id")})
        self.key = scope_key(self.granularity, self.scope)
        self.handler = handler
        self.event_types = set(event_types) if event_types else None
        self.pin = bool(pin)
        self.idle_ttl = float(idle_ttl)
        self.name = str(name or plugin_id)

        self.created_at = time.time()
        self.last_active = time.time()
        self.alive = True
        self.processed = 0
        self.dropped = 0
        self.errors = 0

        # 队列元素：PluginEvent（事件）/ callable（站任务，半二期）/ None（哨兵）
        self.inbox: "queue.Queue[Any]" = queue.Queue(
            maxsize=int(inbox_max)
        )
        self.subscription: Optional[Subscription] = None
        self._watchdog = watchdog
        self._worker: Optional[threading.Thread] = None
        self._lock = threading.Lock()

    # ------------------------------------------------------------------
    # 标识 / 匹配 / 投递
    # ------------------------------------------------------------------
    def instance_key(self) -> str:
        """实例唯一键（注册表内部键，可读字符串）。"""
        return f"{self.plugin_id}|{self.granularity}|" + "|".join(self.key)

    def matches(self, event: PluginEvent) -> bool:
        """事件匹配（type + scope，fail-closed 方向）。"""
        if not self.alive:
            return False
        if self.event_types is not None and event.type not in self.event_types:
            return False
        return scope_matches(self.scope, event.scope)

    def offer(self, event: PluginEvent) -> bool:
        """非阻塞投递到实例队列（满则丢弃 + 计数）。"""
        if not self.alive:
            return False
        try:
            self.inbox.put_nowait(event)
            return True
        except queue.Full:
            self.dropped += 1
            logger.warning(
                "插件实例队列已满，丢弃事件: %s key=%s", self.name, self.key
            )
            return False

    def offer_task(self, task: Callable[[], None]) -> bool:
        """非阻塞投递一个任务到实例队列（半二期：处理站请求复用实例 worker）。

        与 ``offer`` 同一背压语义（满则丢弃 + ``dropped`` 计数 + 返回 False）。
        任务由 worker 按 FIFO 与事件串行执行（实例内串行语义不变）。
        """
        if not self.alive or not callable(task):
            return False
        try:
            self.inbox.put_nowait(task)
            return True
        except queue.Full:
            self.dropped += 1
            logger.warning(
                "插件实例队列已满，丢弃任务: %s key=%s", self.name, self.key
            )
            return False

    def touch(self) -> None:
        """刷新实例活跃时间（实例级心跳；worker 处理完/注册表创建时调用）。"""
        self.last_active = time.time()
        if self._watchdog is not None:
            self._watchdog.touch_instance(self.instance_key())

    def idle_seconds(self, now: Optional[float] = None) -> float:
        """距最近一次活跃的秒数（TTL 判定用）。"""
        current = time.time() if now is None else float(now)
        return current - self.last_active

    # ------------------------------------------------------------------
    # worker：实例内串行处理
    # ------------------------------------------------------------------
    def start_worker(self) -> None:
        """启动实例 worker 线程（幂等）。"""
        if self._worker is not None and self._worker.is_alive():
            return
        self._worker = threading.Thread(
            target=self._run, name=f"plugin-{self.plugin_id}", daemon=True
        )
        self._worker.start()

    def _run(self) -> None:
        """worker 主循环：取事件 → 调 handler → 更新活动时间。"""
        while True:
            try:
                event = self.inbox.get(timeout=0.2)
            except queue.Empty:
                with self._lock:
                    if not self.alive:
                        return
                continue
            if event is None:
                # 停止哨兵
                return
            try:
                if callable(event):
                    # 半二期允许点②：站任务分派（处理站请求复用实例 worker）。
                    # 事件对象不可调用——事件分支行为与一期完全一致。
                    event()
                else:
                    self.handler(event)
                self.processed += 1
            except Exception:  # noqa: BLE001
                self.errors += 1
                logger.exception("插件处理失败: %s key=%s", self.name, self.key)
            finally:
                self.touch()

    def stop(self, timeout: float = 1.0) -> None:
        """停止实例 worker（投递停止哨兵；可重复调用）。"""
        with self._lock:
            if not self.alive:
                return
            self.alive = False
        try:
            self.inbox.put_nowait(None)
        except queue.Full:
            # 队列满：清一格再投入哨兵
            try:
                self.inbox.get_nowait()
                self.inbox.put_nowait(None)
            except Exception:  # noqa: BLE001
                pass
        if self._worker is not None and self._worker.is_alive():
            self._worker.join(timeout=timeout)

    def stats(self) -> Dict[str, Any]:
        """实例统计快照（观测/验收用）。"""
        return {
            "plugin_id": self.plugin_id,
            "granularity": self.granularity,
            "key": self.key,
            "pin": self.pin,
            "alive": self.alive,
            "processed": self.processed,
            "dropped": self.dropped,
            "errors": self.errors,
            "inbox": self.inbox.qsize(),
            "last_active": self.last_active,
        }


class PluginRegistry:
    """插件实例注册表（独立生命周期管理，线程安全）。"""

    def __init__(
        self,
        bus: Optional[EventBus] = None,
        watchdog: Optional[ProgressWatchdog] = None,
    ) -> None:
        self._lock = threading.Lock()
        self._instances: Dict[str, PluginInstance] = {}
        self._bus = bus
        self._watchdog = watchdog or ProgressWatchdog()
        # TTL 周期清扫线程（D-12/C1：显式 start_sweeper() 后启动）
        self._sweeper: Optional[threading.Thread] = None
        self._sweeper_stop = threading.Event()

    # ------------------------------------------------------------------
    # 注册 / 查询 / 注销
    # ------------------------------------------------------------------
    def register(
        self,
        plugin_id: str,
        handler: Callable[[PluginEvent], Any],
        *,
        granularity: str = "team",
        scope: Optional[Dict[str, str]] = None,
        event_types: Optional[set] = None,
        pin: bool = False,
        idle_ttl: float = DEFAULT_IDLE_TTL,
        name: str = "",
        inbox_max: Optional[int] = None,
    ) -> PluginInstance:
        """注册（或幂等复用）一个插件实例。

        同一 (plugin_id, 粒度, scope) 已存在且存活时复用现有实例
        （更新 handler / 订阅类型 / Pin 标记），否则创建新实例
        （启动 worker，并在绑定总线时自动挂上订阅）。

        :param inbox_max: 实例队列容量（仅新建实例时生效；None=默认
            ``DEFAULT_INBOX_MAX``；半二期测试注入用）。
        """
        inst = PluginInstance(
            plugin_id,
            granularity,
            scope or {},
            handler,
            event_types=event_types,
            pin=pin,
            idle_ttl=idle_ttl,
            inbox_max=(
                int(inbox_max) if inbox_max is not None else DEFAULT_INBOX_MAX
            ),
            watchdog=self._watchdog,
            name=name,
        )
        key = inst.instance_key()
        # D-13（C2）：存在性检查与插入必须收敛在**同一临界区**内完成。
        # 修复前两段 with 之间存在无锁间隙——并发注册同键时，两个线程都可能
        # 通过检查、后者覆盖前者，前者成为"不在注册表、却已启动 worker/订阅"
        # 的孤儿实例（重复投递/泄漏）。归并后任何线程要么自己插入、要么必然
        # 看到先插入的实例并复用，不再存在孤儿窗口。
        with self._lock:
            existing = self._instances.get(key)
            if existing is not None and existing.alive:
                # 复用：更新 handler / 订阅类型 / Pin 标记并刷新活跃时间
                existing.handler = handler
                existing.event_types = inst.event_types
                existing.pin = bool(pin)
                existing.touch()
                return existing
            # 不存在（或旧实例已停）→ 同一临界区内立即插入
            self._instances[key] = inst
        inst.start_worker()
        inst.touch()
        if self._bus is not None:
            inst.subscription = self._make_subscription(inst)
            self._bus.add_subscription(inst.subscription)
        logger.info("插件实例已注册: %s", key)
        return inst

    def get(self, instance_key: str) -> Optional[PluginInstance]:
        """按键取实例（不存在返回 None）。"""
        with self._lock:
            return self._instances.get(str(instance_key))

    def instances(self) -> List[PluginInstance]:
        """全部实例快照。"""
        with self._lock:
            return list(self._instances.values())

    def unregister(self, instance: Any) -> bool:
        """注销实例（停 worker、移订阅、清心跳）；接受实例对象或键字符串。"""
        if isinstance(instance, PluginInstance):
            key = instance.instance_key()
        else:
            key = str(instance)
        with self._lock:
            inst = self._instances.pop(key, None)
        if inst is None:
            return False
        inst.stop()
        if self._watchdog is not None:
            self._watchdog.drop_instance(key)
        if self._bus is not None and inst.subscription is not None:
            self._bus.remove_subscription(inst.subscription)
            inst.subscription = None
        logger.info("插件实例已注销: %s", key)
        return True

    # ------------------------------------------------------------------
    # 生命周期：TTL / 级联清理
    # ------------------------------------------------------------------
    def collect_stale(self, now: Optional[float] = None) -> List[PluginInstance]:
        """收集空闲 TTL 超时且非 Pin 的存活实例（供清理）。"""
        stale: List[PluginInstance] = []
        for inst in self.instances():
            if not inst.alive or inst.pin:
                continue
            if inst.idle_seconds(now=now) >= inst.idle_ttl:
                stale.append(inst)
        return stale

    def cleanup_stale(self, now: Optional[float] = None) -> int:
        """清理空闲超时的非 Pin 实例（TTL），返回清理数量。"""
        removed = 0
        for inst in self.collect_stale(now=now):
            if self.unregister(inst):
                removed += 1
        return removed

    # ------------------------------------------------------------------
    # TTL 周期清扫驱动（D-12/C1）
    # ------------------------------------------------------------------
    def start_sweeper(self, interval: Optional[float] = None) -> None:
        """启动 TTL 周期清扫线程（幂等；D-12/C1）。

        周期调用 ``cleanup_stale()`` 逐出空闲超时且非 Pin 的实例
        （Pin 豁免语义不变）。间隔默认 ``DEFAULT_TTL_SWEEP_INTERVAL``
        （env ``PLUGIN_TTL_SWEEP_INTERVAL_S`` 可配，建议 300–600s）。
        """
        with self._lock:
            if self._sweeper is not None and self._sweeper.is_alive():
                return
            seconds: float = DEFAULT_TTL_SWEEP_INTERVAL
            if interval is not None:
                try:
                    seconds = max(1.0, float(interval))
                except (TypeError, ValueError):
                    seconds = DEFAULT_TTL_SWEEP_INTERVAL
            self._sweeper_stop.clear()
            self._sweeper = threading.Thread(
                target=self._sweep_loop,
                args=(seconds,),
                name="plugin-ttl-sweeper",
                daemon=True,
            )
            self._sweeper.start()
            logger.info("插件实例 TTL 清扫线程已启动（间隔 %.1fs）", seconds)

    def stop_sweeper(self, timeout: float = 1.0) -> None:
        """停止 TTL 清扫线程（幂等；停止后可再次 start）。"""
        with self._lock:
            thread = self._sweeper
            self._sweeper = None
            self._sweeper_stop.set()
        if thread is not None and thread.is_alive():
            thread.join(timeout=timeout)

    def _sweep_loop(self, interval: float) -> None:
        """清扫线程主循环：周期清理空闲超时实例（异常不终止循环）。"""
        while not self._sweeper_stop.wait(interval):
            try:
                removed = self.cleanup_stale()
                if removed:
                    logger.info("插件实例 TTL 清扫: 清理 %d 个空闲超时实例", removed)
            except Exception:  # noqa: BLE001
                logger.exception("插件实例 TTL 清扫失败（已忽略，继续下一轮）")
        logger.debug("插件实例 TTL 清扫线程退出")

    def cleanup_scope(
        self,
        *,
        user_id: Optional[str] = None,
        team_id: Optional[str] = None,
        agent_id: Optional[str] = None,
        session_id: Optional[str] = None,
    ) -> int:
        """级联清理：删除与给定条件匹配的实例（提供的字段须相等）。

        - 清 user：该用户全部实例；
        - 清 team (user+team)：该团队全部（team/agent/session 粒度）；
        - 清 agent (+agent_id)：该 agent 的 agent/session 粒度实例；
        - 清 session (+session_id)：该 session 的 session 粒度实例。

        语义说明：条件中提供的字段与实例 scope 对应字段**相等**才命中；
        实例 key 中为空（未到该粒度）而条件要求具体值时不会误删
        （如清 session 不影响同 agent 的其他 session 与 agent 级实例）。

        :return: 清理数量
        """
        cond = make_scope(
            user_id=user_id or "",
            team_id=team_id or "",
            agent_id=agent_id or "",
            session_id=session_id or "",
        )
        removed = 0
        for inst in self.instances():
            if scope_matches(cond, inst.scope):
                if self.unregister(inst):
                    removed += 1
        return removed

    def cascade_cleanup(
        self,
        user_id: str,
        *,
        team_id: str = "",
        agent_id: str = "",
        session_id: str = "",
    ) -> int:
        """级联清理单点入口（契约 §5.1；供路由接线调用）。

        匹配规则：``user_id`` 必选；team/agent/session 为空 = 不限定，
        非空必须与实例 scope 对应字段相等才命中（fail-closed 方向）。

        - 传 ``session_id``：仅销毁该会话的 session 级实例（agent/team 级实例
          ``session_id=""`` 不受影响）；
        - 传 ``agent_id``：销毁该 agent 的 agent 级 + 其全部 session 级实例；
        - 传 ``team_id``：销毁该团队全部实例（团队解散语义）。
        """
        return self.cleanup_scope(
            user_id=user_id, team_id=team_id, agent_id=agent_id, session_id=session_id
        )

    def touch(self, instance_key: str) -> None:
        """按键刷新实例活跃时间（不存在则静默忽略；契约 §5）。"""
        inst = self.get(instance_key)
        if inst is not None:
            inst.touch()

    def set_pin(self, plugin_id: str, pinned: bool = True) -> int:
        """设置某插件全部实例的 Pin 标记（Pin 豁免 TTL 清理）；返回变更数。"""
        count = 0
        for inst in self.instances():
            if inst.plugin_id == str(plugin_id):
                inst.pin = bool(pinned)
                count += 1
        return count

    def list_instances(
        self,
        plugin_id: Optional[str] = None,
        user_id: Optional[str] = None,
    ) -> List[PluginInstance]:
        """按条件列出实例（``None`` = 不过滤；契约 §5）。"""
        return [
            inst
            for inst in self.instances()
            if (plugin_id is None or inst.plugin_id == str(plugin_id))
            and (user_id is None or inst.scope.get("user_id") == str(user_id))
        ]

    def count(self) -> int:
        """当前实例数（观测用）。"""
        with self._lock:
            return len(self._instances)

    def stats(self) -> List[Dict[str, Any]]:
        """全部实例统计快照（观测/验收用）。"""
        return [inst.stats() for inst in self.instances()]

    def shutdown(self) -> None:
        """停止周期清扫、停止全部实例并清空注册表（进程退出 / 测试清理用）。"""
        self.stop_sweeper()
        for inst in self.instances():
            self.unregister(inst)

    # ------------------------------------------------------------------
    # 内部：订阅构造
    # ------------------------------------------------------------------
    def _make_subscription(self, inst: PluginInstance) -> Subscription:
        """把实例包装为总线订阅（匹配 + 投递到实例队列）。"""

        def _match(event: PluginEvent) -> bool:
            return inst.matches(event)

        def _deliver(event: PluginEvent) -> None:
            inst.offer(event)

        return Subscription(
            name=inst.instance_key(), match_fn=_match, deliver_fn=_deliver
        )
