"""处理站（半二期）— 数据流拦截：订阅 → 触发 → 处理 → 回填。

对应 ADR（D-PS1..PS7）与会议裁定（02-discussion §四）：

- **回传形态 B**：请求对象经订阅实例 worker 队列投递（复用实例内串行、
  背压与生命周期治理）；插件在站处理函数中 ``request.respond(payload)``
  回填（或直接返回 ``str`` / ``None``，由框架代为回填）；等待方（工具
  消费线程）分段等待，亚秒级响应取消。
- **订阅模型**：站 × scope 键位唯一（先到先得 + 计数；显式退订 /
  ``replace=True`` 替换）；触发解析 = scope 前缀匹配 + 最细粒度优先；
  0 命中放行 + 计数（fail-closed 方向）。
- **fail-open 红线**：一切异常路径放行原数据 + 分类计数 + 日志；
  绝不抛出、绝不出半成品；在途请求快速失败（实例销毁 / 队列满 →
  立即放行，不静默等满超时）。
- **进度通道**：等待期接通 watchdog run 登记/续期/结束（软窗、自动
  续期与判死联动留二期）；等待期续期由等待循环按节拍显式上报。

模块独立管理订阅记录（站 × 键位 → 订阅）；执行投递复用注册表实例
worker。对 ``registry`` 的接触点（显式 ≤3，既有事件路径行为不变）：

1. ``PluginInstance.offer_task``（新增：非阻塞任务投递，满则计数丢弃）；
2. ``PluginInstance._run`` 增加任务分派分支（事件分支语义不变）；
3. ``PluginRegistry.register(inbox_max=...)`` 透传队列容量（测试注入用）。

本模块所有入口为 fail-open：不影响工具主链路（与一期埋点红线一致）。
"""

from __future__ import annotations

import logging
import os
import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional, Tuple

from plugin.bus import make_scope, normalize_scope, scope_matches
from plugin.registry import PluginInstance, PluginRegistry, scope_key
from plugin.watchdog import ProgressWatchdog

logger = logging.getLogger(__name__)

# ----------------------------------------------------------------------
# 常量（环境变量可配；测试可缩参 —— R1/R2）
# ----------------------------------------------------------------------

# 本期唯一接入站（read 工具结果返回前）
STATION_READ_RESULT = "tool.read.result"

# 站订阅实例的哨兵事件类型（永不匹配真实事件；站实例不消费总线事件）
_STATION_NOOP_TYPES = {"plugin.station.noop"}

# 粒度排序（越细越优先；触发解析用）
_GRANULARITY_RANK = {"team": 1, "agent": 2, "session": 3}


def _env_float(name: str, default: float, *, minimum: float = 0.001) -> float:
    """读取浮点环境变量（非法/过小回退默认值）。"""
    raw = os.environ.get(name, "")
    try:
        value = float(raw) if str(raw).strip() else float(default)
    except (TypeError, ValueError):
        return float(default)
    return value if value >= minimum else float(default)


def _default_timeout_s() -> float:
    """站处理等待超时默认值（env ``PLUGIN_STATION_TIMEOUT_S``，默认 30s）。"""
    return _env_float("PLUGIN_STATION_TIMEOUT_S", 30.0, minimum=0.01)


def _default_wait_slice_s() -> float:
    """等待分段粒度（env ``PLUGIN_STATION_WAIT_SLICE_S``，默认 0.5s）。

    同时决定取消响应与在途失效发现的最坏延迟（R2：测试可缩至 0.05s 级）。
    """
    return _env_float("PLUGIN_STATION_WAIT_SLICE_S", 0.5, minimum=0.01)


def _default_beat_interval_s() -> float:
    """等待期进度续期节拍（env ``PLUGIN_STATION_BEAT_INTERVAL_S``，默认 10s）。"""
    return _env_float("PLUGIN_STATION_BEAT_INTERVAL_S", 10.0, minimum=0.1)


def _station_instance_noop(_event: Any) -> None:
    """站订阅实例的占位事件 handler（哨兵类型下不会收到真实事件）。"""
    return None


# ----------------------------------------------------------------------
# 请求对象
# ----------------------------------------------------------------------


class StationRequest:
    """站请求对象（系统 → 插件；跨线程；respond 幂等、先到先赢）。

    - ``data``：流入数据（str；只读语义——插件经 respond 回传结果）；
    - ``meta``：随请求元信息（如 tool_name；payload 最小化）；
    - ``respond(payload)``：插件回填（``str`` 替换 / ``None`` 不改动 /
      其他类型判非法并立即终结）；返回是否被采纳；
    - 等待方与插件竞态采取"先到先赢"：终结后到达的 respond 无效化
      （迟到/重复分类计数）。

    线程安全：内部锁保护终结槽；``data``/``meta`` 构造后只读。
    """

    __slots__ = (
        "req_id",
        "station_id",
        "scope",
        "data",
        "meta",
        "deadline",
        "_lock",
        "_done",
        "_outcome",
        "_result",
        "_event",
        "_bump",
    )

    def __init__(
        self,
        station_id: str,
        scope: Dict[str, str],
        data: str,
        meta: Optional[Dict[str, Any]],
        deadline: float,
        bump: Callable[[str], None],
    ) -> None:
        self.req_id = uuid.uuid4().hex
        self.station_id = str(station_id)
        self.scope = dict(scope or {})
        self.data = data
        self.meta = dict(meta or {})
        self.deadline = float(deadline)
        self._lock = threading.Lock()
        self._done = False
        self._outcome: Optional[str] = None
        self._result: Optional[str] = None
        self._event = threading.Event()
        self._bump = bump

    # ------------------------------------------------------------------
    # 插件侧：回填
    # ------------------------------------------------------------------
    def respond(self, payload: Any = None) -> bool:
        """回填处理结果（幂等、先到先赢）。

        - ``str``（含空串）→ 替换数据（采纳，返回 True）；
        - ``None`` → 不改动、放行原数据（采纳，返回 True）；
        - 其它类型 → 判非法（请求立即以 ``invalid`` 终结），返回 False；
        - 请求已终结（超时/取消/已回填）→ 无效化并分类计数，返回 False。
        """
        ok = False
        with self._lock:
            if self._done:
                # 已终结：重复（成功回填后）或迟到（其它终结后）
                key = (
                    "duplicate_response"
                    if self._outcome == "responded"
                    else "late_response"
                )
                self._bump(key)
            else:
                if payload is None:
                    self._outcome = "responded"
                    self._result = None
                    ok = True
                elif isinstance(payload, str):
                    self._outcome = "responded"
                    self._result = payload
                    ok = True
                else:
                    self._outcome = "invalid"
                    self._result = None
                self._done = True
        self._event.set()
        return ok

    # ------------------------------------------------------------------
    # 只读辅助（插件与等待方）
    # ------------------------------------------------------------------
    def is_done(self) -> bool:
        """请求是否已终结（任何原因）。"""
        with self._lock:
            return self._done

    @property
    def outcome(self) -> Optional[str]:
        """终结原因（``responded`` / ``invalid`` / ``timeout`` / ``cancelled`` / ``handler_error``）。"""
        with self._lock:
            return self._outcome

    @property
    def result(self) -> Optional[str]:
        """回填结果（仅 ``responded`` 且为 str 时非 None；None=不改动）。"""
        with self._lock:
            return self._result

    @property
    def remaining_s(self) -> float:
        """剩余等待预算（秒；可能为负）。"""
        return self.deadline - time.monotonic()

    def to_dict(self) -> Dict[str, Any]:
        """调试/演示用快照（不含 data 正文）。"""
        with self._lock:
            return {
                "req_id": self.req_id,
                "station_id": self.station_id,
                "scope": dict(self.scope),
                "meta": dict(self.meta),
                "done": self._done,
                "outcome": self._outcome,
                "result_chars": len(self._result or ""),
            }

    # ------------------------------------------------------------------
    # 内部：终结与等待原语
    # ------------------------------------------------------------------
    def _snapshot(self) -> Tuple[bool, Optional[str], Optional[str]]:
        """锁内快照（done / outcome / result）。"""
        with self._lock:
            return self._done, self._outcome, self._result

    def _end(self, outcome: str) -> bool:
        """内部终结（幂等；先到先赢）。等待方（超时/取消/失效）与
        插件异常路径使用。"""
        with self._lock:
            if self._done:
                return False
            self._outcome = str(outcome)
            self._result = None
            self._done = True
        self._event.set()
        return True

    def _wait(self, seconds: float) -> None:
        """分段等待原语（由等待循环调用）。"""
        self._event.wait(max(0.0, float(seconds)))


# ----------------------------------------------------------------------
# 订阅记录
# ----------------------------------------------------------------------


@dataclass(eq=False)
class StationSub:
    """站订阅记录（站 × scope 键位唯一）。

    ``inst_key`` 为订阅实例的注册表键（``plugin_id|granularity|...``）；
    投递时按该键实时取实例（实例销毁后由等待方快速失败兜底）。
    """

    station_id: str
    plugin_id: str
    granularity: str
    scope: Dict[str, str]
    key: Tuple[str, ...]
    inst_key: str
    handler: Callable[[StationRequest], Any]
    timeout_s: Optional[float] = None
    created_at: float = field(default_factory=time.time)


# ----------------------------------------------------------------------
# 处理站中枢
# ----------------------------------------------------------------------


class StationsHub:
    """处理站中枢：订阅管理、触发、等待、回填、降级、统计。

    线程安全：订阅表与统计由内部锁保护；``process`` 的快速路径
    （无订阅）为近零开销（原子读计数快照 + 直接返回）。
    """

    def __init__(
        self,
        registry: PluginRegistry,
        watchdog: Optional[ProgressWatchdog] = None,
    ) -> None:
        self._registry = registry
        self._watchdog = watchdog
        self._lock = threading.Lock()
        # 订阅表：{(station_id, *scope_key) : StationSub}
        self._subs: Dict[Tuple[str, ...], StationSub] = {}
        # 站元信息：{station_id: {"description":..., "created_at":...}}
        self._stations: Dict[str, Dict[str, Any]] = {}
        # 快速路径快照（无锁读；订阅数变化时在锁内更新）
        self._active_count = 0
        # 分类计数（ADR D-PS6 + R4 扩展键）
        self._counts: Dict[str, int] = {
            "requests": 0,            # 进入站处理流程（命中订阅并投递）的请求
            "responded": 0,           # 有效回填（str 替换或 None 不改动）
            "timeout": 0,             # 等待超时（放行）
            "cancelled": 0,           # 取消 / 在途失效（放行）
            "no_subscriber": 0,       # 0 命中 / 订阅实例缺失（放行）
            "rejected_conflict": 0,   # 订阅冲突被拒（先到先得）
            "invalid_response": 0,    # 非法回填类型（放行）
            "overflow": 0,            # 实例队列满，投递失败（放行）
            "handler_error": 0,       # 插件处理异常（放行）
            "reentrant_bypass": 0,    # 防重入立即放行（同实例 worker 线程内触发）
            "late_response": 0,       # 迟到回填（请求已终结后到达）
            "duplicate_response": 0,  # 重复回填（已成功回填后再次）
            "unsubscribed": 0,        # 显式退订 / 替换移除
            "subscriptions_cascaded": 0,  # 级联清理移除
            "internal_errors": 0,     # 兜底内部异常（不应出现；观测用）
        }
        self._runs_registered = 0
        self._runs_finished = 0
        # 观测（二期 M1：供面板"站"区块；规格见 observability-guard-design-notes §1.2）
        self._waits_in_flight = 0      # 等待在飞数（_await_response 入口 +1 / finally −1）
        self._wait_ms_total = 0.0      # 累计等待时长（毫秒；投递成功后等待段墙钟）
        self._wait_ms_max = 0.0        # 单次等待峰值（毫秒，单调不减）

    # ------------------------------------------------------------------
    # 站注册
    # ------------------------------------------------------------------
    def register_station(self, station_id: str, description: str = "") -> bool:
        """登记站元信息（幂等；订阅时会自动登记）。"""
        sid = str(station_id or "")
        if not sid:
            return False
        with self._lock:
            meta = self._stations.get(sid)
            if meta is None:
                self._stations[sid] = {
                    "description": str(description or ""),
                    "created_at": time.time(),
                }
            elif description:
                meta["description"] = str(description)
        return True

    # ------------------------------------------------------------------
    # 订阅管理
    # ------------------------------------------------------------------
    def subscribe(
        self,
        station_id: str,
        plugin_id: str,
        handler: Callable[[StationRequest], Any],
        *,
        granularity: str = "agent",
        scope: Optional[Dict[str, str]] = None,
        replace: bool = False,
        timeout_s: Optional[float] = None,
        pin: bool = False,
        inbox_max: Optional[int] = None,
        name: str = "",
    ) -> bool:
        """订阅处理站（站 × scope 键位唯一；先到先得）。

        - 同键位已存在且其订阅实例存活 → 拒绝（``rejected_conflict`` + 日志），
          除非 ``replace=True``（显式替换）；
        - 同键位旧订阅实例已销毁 → 视为残留，自动清理后接受新订阅；
        - 订阅实例（承载 worker）不存在时按需创建（``pin`` 常驻、
          ``inbox_max`` 队列容量可注入；哨兵事件类型，不消费总线事件）。

        :return: 是否订阅成功。
        """
        sid = str(station_id or "")
        pid = str(plugin_id or "")
        if not sid or not pid or not callable(handler):
            logger.warning("站订阅参数非法: station=%r plugin=%r", sid, pid)
            return False
        g = str(granularity or "agent")
        try:
            key = scope_key(g, scope or {})
        except ValueError:
            logger.warning("站订阅粒度非法: %r", granularity)
            return False
        sc = make_scope(
            **{
                k: (scope or {}).get(k, "")
                for k in ("user_id", "team_id", "agent_id", "session_id")
            }
        )
        if not sc["user_id"]:
            # fail-closed 入口防线（与总线/埋点同向）：无归属不订阅
            logger.warning("站订阅缺少 user_id，拒绝: station=%s plugin=%s", sid, pid)
            return False
        inst_key = f"{pid}|{g}|" + "|".join(key)
        full_key: Tuple[str, ...] = (sid, *key)

        with self._lock:
            self._stations.setdefault(
                sid, {"description": "", "created_at": time.time()}
            )
            existing = self._subs.get(full_key)
            if existing is not None:
                old_inst = self._registry.get(existing.inst_key)
                if old_inst is None or not old_inst.alive:
                    # 残留订阅（实例已销毁）：惰性清理后接受新订阅
                    self._subs.pop(full_key, None)
                    logger.info("清理残留站订阅: %s → %s", full_key, existing.plugin_id)
                    existing = None
            if existing is not None and not replace:
                self._counts["rejected_conflict"] += 1
                logger.info(
                    "站订阅冲突（先到先得拒绝）: %s 已被 %s 订阅",
                    sid,
                    existing.plugin_id,
                )
                return False
            if existing is not None and replace:
                self._subs.pop(full_key, None)
                self._counts["unsubscribed"] += 1
            sub = StationSub(
                station_id=sid,
                plugin_id=pid,
                granularity=g,
                scope=sc,
                key=key,
                inst_key=inst_key,
                handler=handler,
                timeout_s=(float(timeout_s) if timeout_s is not None else None),
            )
            self._subs[full_key] = sub
            self._active_count = len(self._subs)
        # 确保实例存在（锁外；register 会启动 worker 线程）
        inst = self._registry.get(inst_key)
        if inst is None:
            try:
                self._registry.register(
                    pid,
                    _station_instance_noop,
                    granularity=g,
                    scope=sc,
                    event_types=set(_STATION_NOOP_TYPES),
                    pin=bool(pin),
                    inbox_max=(int(inbox_max) if inbox_max is not None else None),
                    name=str(name or f"{pid}:station"),
                )
            except Exception:  # noqa: BLE001
                logger.exception("站订阅实例创建失败: %s", inst_key)
                with self._lock:
                    self._subs.pop(full_key, None)
                    self._active_count = len(self._subs)
                return False
        logger.info("站订阅成功: %s ← %s（%s 粒度）", sid, pid, g)
        return True

    def unsubscribe(
        self,
        station_id: str,
        plugin_id: Optional[str] = None,
        *,
        granularity: Optional[str] = None,
        scope: Optional[Dict[str, str]] = None,
    ) -> int:
        """显式退订（按条件匹配删除；返回移除数量）。

        条件为空 = 只按站匹配（删除该站全部订阅）；``plugin_id`` /
        ``granularity`` / ``scope``（精确键位）可进一步限定。
        """
        sid = str(station_id or "")
        removed = 0
        with self._lock:
            for full_key in list(self._subs.keys()):
                sub = self._subs[full_key]
                if sub.station_id != sid:
                    continue
                if plugin_id is not None and sub.plugin_id != str(plugin_id):
                    continue
                if granularity is not None and sub.granularity != str(granularity):
                    continue
                if scope is not None:
                    try:
                        if sub.key != scope_key(sub.granularity, scope):
                            continue
                    except ValueError:
                        continue
                self._subs.pop(full_key, None)
                removed += 1
            if removed:
                self._counts["unsubscribed"] += removed
                self._active_count = len(self._subs)
        if removed:
            logger.info("站显式退订: %s（%d 条）", sid, removed)
        return removed

    def resolve(self, station_id: str, scope: Dict[str, str]) -> Optional[StationSub]:
        """触发解析：scope 前缀匹配 + 最细粒度优先。

        - 匹配：订阅 scope 的非空字段必须与事件 scope 对应字段相等
          （事件字段为空而订阅要求该字段 → 不匹配；fail-closed 方向）；
        - 排序：粒度（session > agent > team）优先，同粒度取"非空字段更多"
          （更具体）者；键位唯一性保证结果确定。
        """
        sid = str(station_id or "")
        best: Optional[StationSub] = None
        best_rank: Tuple[int, int] = (-1, -1)
        with self._lock:
            for sub in self._subs.values():
                if sub.station_id != sid:
                    continue
                if not scope_matches(sub.scope, scope):
                    continue
                rank = (
                    _GRANULARITY_RANK.get(sub.granularity, 0),
                    sum(1 for part in sub.key if part),
                )
                if rank > best_rank:
                    best_rank = rank
                    best = sub
        return best

    # ------------------------------------------------------------------
    # 触发：处理站主流程
    # ------------------------------------------------------------------
    def process(
        self,
        station_id: str,
        data: Any,
        scope: Optional[Dict[str, str]],
        *,
        meta: Optional[Dict[str, Any]] = None,
        cancel_event: Optional[threading.Event] = None,
        timeout_s: Optional[float] = None,
    ) -> Any:
        """触发处理站：有订阅则交由插件处理并回填，否则原样放行。

        **fail-open**：所有降级路径返回原 ``data`` + 分类计数，绝不抛出。

        :param data: 流入数据（str；非 str 直通，契约外输入不处理）
        :param scope: 事件 scope 四元组
        :param cancel_event: 等待期取消检查（≤分段粒度响应）
        :param timeout_s: 本次等待超时（覆盖 订阅级 / env 默认）
        """
        try:
            if self._active_count <= 0:
                # 快速路径：无任何订阅（近零开销）
                return data
            if not isinstance(data, str):
                logger.debug("站输入非 str（直通）: station=%s", station_id)
                return data
            req_scope = normalize_scope(scope)
            if not req_scope["user_id"]:
                logger.debug("站请求缺少 user_id（直通）: station=%s", station_id)
                return data
            sub = self.resolve(station_id, req_scope)
            if sub is None:
                self._bump("no_subscriber")
                return data
            inst = self._registry.get(sub.inst_key)
            if inst is None or not inst.alive:
                # 订阅实例缺失/已销毁：放行（订阅残留由下次 subscribe 惰性清理）
                self._bump("no_subscriber")
                logger.debug("站订阅实例不可用（放行）: %s", sub.inst_key)
                return data
            # F1 防重入（裁决补最小实现）：目标实例 worker 线程 == 当前线程
            # （插件 handler 内同步触发、命中同实例站）→ 立即放行 + 计数，
            # 避免请求排入自身队列形成自等（最坏 30s 卡顿）。
            # 说明：仅只读比较线程对象（不修改 registry）；跨实例环不在本
            # 判定范围（留超时兜底收敛；链深上限二期）。
            worker = getattr(inst, "_worker", None)
            if worker is not None and worker is threading.current_thread():
                self._bump("reentrant_bypass")
                logger.info(
                    "站重入 bypass（同实例 worker 线程内触发，立即放行）: %s",
                    sub.inst_key,
                )
                return data
            eff_timeout = self._pick_timeout(timeout_s, sub)
            req = StationRequest(
                station_id=sub.station_id,
                scope=req_scope,
                data=data,
                meta=meta,
                deadline=time.monotonic() + eff_timeout,
                bump=self._bump,
            )
            task = self._make_task(sub, req)
            if not inst.offer_task(task):
                # 实例队列满：立即 fail-open（快速失败；绝不静默等超时）
                self._bump("overflow")
                logger.warning("站请求投递失败（队列满，放行）: %s", sub.station_id)
                return data
            self._bump("requests")
            outcome, result = self._await_response(req, inst, cancel_event)
            if outcome == "responded":
                self._bump("responded")
                # None = 不改动（放行原数据）；str（含空串）= 替换
                return data if result is None else result
            for reason in ("timeout", "cancelled", "invalid", "handler_error"):
                if outcome == reason:
                    self._bump(reason if reason != "invalid" else "invalid_response")
                    break
            return data
        except Exception:  # noqa: BLE001
            # 单一入口吞异常（绝不影响工具主链路）
            self._bump("internal_errors")
            logger.exception("处理站内部异常（已忽略，放行原数据）: %s", station_id)
            return data

    # ------------------------------------------------------------------
    # 等待与进度通道
    # ------------------------------------------------------------------
    def _await_response(
        self,
        req: StationRequest,
        inst: PluginInstance,
        cancel_event: Optional[threading.Event],
    ) -> Tuple[Optional[str], Optional[str]]:
        """等待回填（分段；≤亚秒级响应取消/失效；接通进度通道）。"""
        # 观测计时用 perf_counter：Windows 下 time.monotonic() 粒度为 ~15.6ms，
        # 会把毫秒级等待吞成 0（deadline/节拍等秒级判定仍用 monotonic，不受影响）。
        t0 = time.perf_counter()
        with self._lock:
            self._waits_in_flight += 1
        inst_key = inst.instance_key()
        run_id = f"station:{req.req_id}"
        wd = self._watchdog
        registered = False
        if wd is not None:
            try:
                wd.register_run(inst_key, run_id, auto_tick=False, max_run_seconds=None)
                registered = True
                with self._lock:
                    self._runs_registered += 1
            except Exception:  # noqa: BLE001
                logger.debug("站进度通道登记失败（忽略）", exc_info=True)
        slice_s = _default_wait_slice_s()
        beat_s = _default_beat_interval_s()
        last_beat = time.monotonic()
        try:
            while True:
                done, outcome, result = req._snapshot()
                if done:
                    return outcome, result
                if cancel_event is not None and cancel_event.is_set():
                    # 取消（"停止"按钮）：立即放行（≤分段粒度响应）
                    req._end("cancelled")
                    return req._snapshot()[1], None
                if not inst.alive:
                    # 实例销毁/级联清理：在途请求立即失效（快速失败）
                    req._end("cancelled")
                    return req._snapshot()[1], None
                if time.monotonic() >= req.deadline:
                    req._end("timeout")
                    continue
                # 分段等待（取消检查窗口 ≤ slice_s）
                req._wait(
                    min(slice_s, max(0.0, req.deadline - time.monotonic()))
                )
                # 等待期进度续期（节拍上报；失败忽略）
                if registered:
                    now = time.monotonic()
                    if now - last_beat >= beat_s:
                        try:
                            wd.note_progress(inst_key, run_id)
                        except Exception:  # noqa: BLE001
                            pass
                        last_beat = now
        finally:
            dt_ms = (time.perf_counter() - t0) * 1000.0
            with self._lock:
                self._waits_in_flight -= 1
                self._wait_ms_total += dt_ms
                if dt_ms > self._wait_ms_max:
                    self._wait_ms_max = dt_ms
            if registered:
                try:
                    wd.finish_run(inst_key, run_id)
                    with self._lock:
                        self._runs_finished += 1
                except Exception:  # noqa: BLE001
                    pass

    def _make_task(
        self, sub: StationSub, req: StationRequest
    ) -> Callable[[], None]:
        """构造投递给订阅实例 worker 的任务闭包。

        插件处理函数返回值即回填（``str``/``None``）；若函数内部已自行
        ``respond``，框架不再重复回填；异常 → 请求以 ``handler_error`` 终结。
        """

        def _task() -> None:
            try:
                ret = sub.handler(req)
            except Exception:  # noqa: BLE001
                logger.exception("站插件处理异常: %s", sub.station_id)
                req._end("handler_error")
                return
            if not req.is_done():
                req.respond(ret)

        return _task

    def _pick_timeout(
        self, override: Optional[float], sub: StationSub
    ) -> float:
        """超时取值：调用级 > 订阅级 > env 默认（R1 可缩参）。"""
        for candidate in (override, sub.timeout_s):
            if candidate is None:
                continue
            try:
                return max(0.01, float(candidate))
            except (TypeError, ValueError):
                continue
        return _default_timeout_s()

    # ------------------------------------------------------------------
    # 级联清理 / 统计 / 重置
    # ------------------------------------------------------------------
    def cascade_cleanup(
        self,
        user_id: str,
        *,
        team_id: str = "",
        agent_id: str = "",
        session_id: str = "",
    ) -> int:
        """级联清理：移除与条件匹配的站订阅（订阅随 scope 销毁）。

        匹配方向与 ``registry.cascade_cleanup`` 一致：条件非空字段必须与
        订阅 scope 对应字段相等才命中（fail-closed 方向）。
        """
        cond = make_scope(
            user_id=user_id or "",
            team_id=team_id or "",
            agent_id=agent_id or "",
            session_id=session_id or "",
        )
        if not cond["user_id"]:
            return 0
        removed = 0
        with self._lock:
            for full_key in list(self._subs.keys()):
                sub = self._subs[full_key]
                if scope_matches(cond, sub.scope):
                    self._subs.pop(full_key, None)
                    removed += 1
            if removed:
                self._counts["subscriptions_cascaded"] += removed
                self._active_count = len(self._subs)
        if removed:
            logger.info("站订阅级联清理: user=%s（%d 条）", user_id, removed)
        return removed

    def stats(self) -> Dict[str, Any]:
        """统计快照（观测 / 验收用；含分类计数 + 进度通道 + 等待观测）。"""
        with self._lock:
            subs = [
                {
                    "station_id": sub.station_id,
                    "plugin_id": sub.plugin_id,
                    "granularity": sub.granularity,
                    "scope": dict(sub.scope),
                    "inst_key": sub.inst_key,
                    "timeout_s": sub.timeout_s,
                }
                for sub in self._subs.values()
            ]
            stations = {sid: dict(meta) for sid, meta in self._stations.items()}
            counts = dict(self._counts)
            active = self._active_count
            gauges = {"waits_in_flight": self._waits_in_flight}
            timing = {
                "wait_ms_total": round(self._wait_ms_total, 3),
                "wait_ms_max": round(self._wait_ms_max, 3),
            }
        progress: Dict[str, Any] = {
            "runs_registered": self._runs_registered,
            "runs_finished": self._runs_finished,
        }
        if self._watchdog is not None:
            try:
                progress["runs_active"] = self._watchdog.task_count()
            except Exception:  # noqa: BLE001
                progress["runs_active"] = None
        return {
            "stations": stations,
            "subscriptions": subs,
            "subscription_count": active,
            "counts": counts,
            "gauges": gauges,
            "timing": timing,
            "progress": progress,
        }

    def reset(self) -> None:
        """清空订阅与统计（测试清理 / 门面 shutdown 用）。"""
        with self._lock:
            self._subs.clear()
            self._stations.clear()
            self._active_count = 0
            for key in self._counts:
                self._counts[key] = 0
            self._runs_registered = 0
            self._runs_finished = 0
            self._waits_in_flight = 0
            self._wait_ms_total = 0.0
            self._wait_ms_max = 0.0

    # ------------------------------------------------------------------
    # 内部工具
    # ------------------------------------------------------------------
    def _bump(self, key: str) -> None:
        """分类计数（线程安全；键不存在时惰性创建，观测用）。"""
        with self._lock:
            self._counts[key] = self._counts.get(key, 0) + 1


__all__ = [
    "STATION_READ_RESULT",
    "StationRequest",
    "StationSub",
    "StationsHub",
]
