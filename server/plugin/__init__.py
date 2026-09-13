"""插件体系（一期骨架）- 进程内事件总线 + 插件注册表 + 看门狗 + 出站 SDK。

**启用开关（默认关闭；关闭时对现有行为零副作用）**：

- 环境变量 ``TREE_PLUGIN_ENABLED=1``：进程启动时启用（显式设置时优先，
  含 ``0`` 表示显式关闭）；
- 配置文件 ``server/configs/app.yaml`` → ``plugin.enabled: true``：未设置
  环境变量时按它启用（默认 false；进程启动时生效）；
- 代码调用 ``plugin.set_enabled(True)``：运行时启用（演示/测试/后续接线）；
- 关闭状态下：埋点 ``publish_tool_event`` 直接返回 False，不创建组件、
  不入队、不起线程（零副作用）。

**一期范围**（见 agentspace/.hard/20260913-plugin-stations/decisions/ADR.md）：
事件总线（D1/D4）、插件注册表（D2/D3）、看门狗（D7）、出站 SDK（D6）、
join 最小原语（D5）、白名单埋点（llm.py 工具执行处）+ 1 个示例插件；
不做 UI、不做宿主通道、不持久化（内存态 + 超时解除）。

**接线说明（一期已接线；默认关闭，不重启不生效）**：
- ``server/main.py`` lifespan 调用 ``init_plugin_system()``：仅当总开关
  开启（``TREE_PLUGIN_ENABLED=1``）时初始化组件并绑定主事件循环；
- ``server/agent/routes.py`` 4 处清理点调用 ``plugin_cascade(...)``：
  会话删除 / 历史清空 / agent 删除（含 TOP 团队解散）/ 配置更新；
- 埋点唯一入口为 ``safe_publish(...)``（llm.py 工具执行处示范点位）；
- 宿主通道（二期 M2；契约 §14）：``server/ws/endpoints.py`` 接线
  ``plugin_host_event``（上行帧）与 ``plugin_host_mark_lost``（断连回收）；
  执行器（重）注册处调用 ``plugin_host_reconcile``（best-effort 对账）；
- 示范插件自动注册（D-P2-6，默认关）：``TREE_PLUGIN_DEMO_READ_STATION=1`` +
  ``TREE_PLUGIN_DEMO_SCOPE="user_id=..."``（重启生效；零协议面）；
- M3 工程小件（均可配/可注入）：巡检循环（``PLUGIN_WATCHDOG_CHECK_INTERVAL_S``；
  判死阈值 ``PLUGIN_WATCHDOG_DEAD_STRIKES`` / ``PLUGIN_WATCHDOG_MAX_CONSECUTIVE_DEAD``）；
  F3 阈值 ``PLUGIN_STATION_ERROR_THRESHOLD``；链深上限 ``PLUGIN_STATION_CHAIN_MAX``；
  站防呆 ``loop_bypass`` / 链深 ``chain_bypass`` 计数；SDK ``workspace_read(..., encoding=...)``；
- 启用方式：``app.yaml`` 配 ``plugin.enabled: true``（或设 ``TREE_PLUGIN_ENABLED=1``
  覆盖）后重启后端进程生效。
"""

from __future__ import annotations

import logging
import os
import re
import threading
from typing import Any, Dict, Optional

from plugin.bus import (  # noqa: F401（对外门面 re-export）
    SCOPE_KEYS,
    EventBus,
    PluginEvent,
    Subscription,
    make_scope,
    normalize_scope,
    scope_matches,
)
from plugin.join import JoinBuffer, JoinResult  # noqa: F401
from plugin.registry import (  # noqa: F401
    GRANULARITY_FIELDS,
    PluginInstance,
    PluginRegistry,
    scope_key,
)
from plugin.host import (  # noqa: F401（对外门面 re-export）
    OP_HOST_START,
    OP_HOST_STOP,
    OP_HOST_STATUS,
    HostChannel,
    HostSession,
)
from plugin.sdk import PluginSDK, bind_loop as _sdk_bind_loop  # noqa: F401
from plugin.stations import (  # noqa: F401（对外门面 re-export）
    STATION_READ_RESULT,
    StationRequest,
    StationSub,
    StationsHub,
)
from plugin.watchdog import (  # noqa: F401
    DEFAULT_BEAT_INTERVAL,
    DEFAULT_CHECK_INTERVAL,
    DEFAULT_DEAD_STRIKES,
    DEFAULT_MAX_CONSECUTIVE_DEAD,
    DEFAULT_STALL_SECONDS,
    ProgressWatchdog,
)

logger = logging.getLogger(__name__)

__all__ = [
    # 门面函数
    "is_enabled",
    "set_enabled",
    "get_bus",
    "get_registry",
    "get_watchdog",
    "bind_loop",
    "startup",
    "shutdown",
    "publish_tool_event",
    "safe_publish",
    "safe_process",
    "get_stations",
    "get_snapshot",
    "init_plugin_system",
    "plugin_cascade",
    "get_host_channel",
    "plugin_host_event",
    "plugin_host_mark_lost",
    "plugin_host_reconcile",
    # 开关常量
    "ENV_ENABLED",
    "ENV_DEMO_READ_STATION",
    "ENV_DEMO_SCOPE",
    # 类型（re-export）
    "EventBus",
    "PluginEvent",
    "Subscription",
    "make_scope",
    "normalize_scope",
    "scope_matches",
    "SCOPE_KEYS",
    "PluginRegistry",
    "PluginInstance",
    "scope_key",
    "GRANULARITY_FIELDS",
    "ProgressWatchdog",
    "DEFAULT_BEAT_INTERVAL",
    "DEFAULT_STALL_SECONDS",
    "DEFAULT_CHECK_INTERVAL",
    "DEFAULT_DEAD_STRIKES",
    "DEFAULT_MAX_CONSECUTIVE_DEAD",
    "PluginSDK",
    "JoinBuffer",
    "JoinResult",
    "StationsHub",
    "StationSub",
    "StationRequest",
    "STATION_READ_RESULT",
    "HostChannel",
    "HostSession",
    "OP_HOST_START",
    "OP_HOST_STOP",
    "OP_HOST_STATUS",
]

# 环境变量开关名（进程启动默认值）
ENV_ENABLED = "TREE_PLUGIN_ENABLED"


def _read_env_enabled() -> bool:
    """读取环境变量开关（TREE_PLUGIN_ENABLED=1/true/yes/on 视为启用）。"""
    value = str(os.environ.get(ENV_ENABLED, "") or "").strip().lower()
    return value in ("1", "true", "yes", "on")


def _read_config_enabled() -> bool:
    """读取 app.yaml 总开关（``plugin.enabled``；缺省/异常按关闭处理）。"""
    try:
        from config.config import get_config  # noqa: PLC0415（懒 import：避免循环依赖）

        section = get_config().get("plugin") or {}
        return bool(section.get("enabled", False))
    except Exception:  # noqa: BLE001
        logger.debug("插件总开关读取 app.yaml 失败（按关闭处理）", exc_info=True)
        return False


def _read_enabled() -> bool:
    """总开关初始值（进程启动时）：env 显式设置时优先，未设置回落 app.yaml。

    - ``TREE_PLUGIN_ENABLED`` 显式设置（非空，含 ``0`` 显式关闭）→ 以 env 为准；
    - 未设置 → ``app.yaml`` 的 ``plugin.enabled``（默认 false）。
    """
    raw = str(os.environ.get(ENV_ENABLED, "") or "").strip()
    if raw:
        return _read_env_enabled()
    return _read_config_enabled()


# 示范插件自动注册（D-P2-6；默认关；开启=演示/体验用；零协议面）
ENV_DEMO_READ_STATION = "TREE_PLUGIN_DEMO_READ_STATION"
ENV_DEMO_SCOPE = "TREE_PLUGIN_DEMO_SCOPE"


_lock = threading.Lock()
_enabled = _read_enabled()
_bus: Optional[EventBus] = None
_registry: Optional[PluginRegistry] = None
_watchdog: Optional[ProgressWatchdog] = None
_stations: Optional[StationsHub] = None
_host: Optional[HostChannel] = None
_demo_plugin: Any = None
_initialized = False


# ----------------------------------------------------------------------
# 开关
# ----------------------------------------------------------------------
def is_enabled() -> bool:
    """总开关状态（默认关闭）。"""
    return _enabled


def set_enabled(value: bool) -> None:
    """设置总开关（运行时）。

    - 置 True：启用并懒初始化核心组件（总线/注册表/看门狗）；
    - 置 False：关闭事件接收（已初始化组件保持运行，直至 ``shutdown``）。

    置 False 不销毁组件：避免"关掉开关"隐式打断正在处理的插件任务；
    完整停止请用 ``shutdown()``。
    """
    global _enabled
    _enabled = bool(value)
    if _enabled:
        _ensure_initialized()
        # D-P2-6：开关开启时尝试 env 自动注册示范插件（默认关；幂等）
        _maybe_register_demo()
    logger.info("插件体系开关: %s", "enabled" if _enabled else "disabled")


def _maybe_register_demo() -> bool:
    """D-P2-6：env 自动注册示范插件（默认关；开启=演示/体验用；零协议面）。

    - ``TREE_PLUGIN_DEMO_READ_STATION=1`` 开启（1/true/yes/on）；
    - ``TREE_PLUGIN_DEMO_SCOPE`` 提供作用域（逗号/分号分隔 ``k=v``），至少含
      ``user_id``（缺省即跳过 + 告警，fail-closed）；粒度按提供字段推导
      （session_id > agent_id > team）；
    - 幂等：键位已占用 / 订阅失败仅记日志（返回 False），不影响启动。
    """
    global _demo_plugin
    raw = str(os.environ.get(ENV_DEMO_READ_STATION, "") or "").strip().lower()
    if raw not in ("1", "true", "yes", "on"):
        return False
    scope: Dict[str, str] = {}
    for part in re.split(r"[;,]", str(os.environ.get(ENV_DEMO_SCOPE, "") or "")):
        if "=" not in part:
            continue
        key, _, value = part.partition("=")
        key = key.strip()
        value = value.strip()
        if key in SCOPE_KEYS and value:
            scope[key] = value
    if not scope.get("user_id"):
        logger.warning(
            "示范插件自动注册跳过：缺 %s（需含 user_id；fail-closed）",
            ENV_DEMO_SCOPE,
        )
        return False
    if scope.get("session_id"):
        granularity = "session"
    elif scope.get("agent_id"):
        granularity = "agent"
    else:
        granularity = "team"
    try:
        from plugin.plugins.read_station_demo import register_demo_plugin  # noqa: PLC0415

        got = register_demo_plugin(granularity=granularity, scope=scope, pin=True)
    except Exception:  # noqa: BLE001
        logger.exception("示范插件自动注册异常（已忽略）")
        return False
    if got is None:
        logger.info("示范插件自动注册未生效：键位已占用或订阅失败（幂等静默）")
        return False
    _demo_plugin = got
    logger.info("示范插件已自动注册：%s（%s 粒度）", ENV_DEMO_READ_STATION, granularity)
    return True


# ----------------------------------------------------------------------
# 组件获取（懒初始化）
# ----------------------------------------------------------------------
def _ensure_initialized() -> None:
    """创建并启动单例组件（幂等，线程安全）。"""
    global _bus, _registry, _watchdog, _stations, _host, _initialized
    with _lock:
        if _initialized:
            return
        _watchdog = ProgressWatchdog()
        _bus = EventBus()
        _registry = PluginRegistry(bus=_bus, watchdog=_watchdog)
        _stations = StationsHub(registry=_registry, watchdog=_watchdog)
        # 宿主通道（二期 M2）：会话表 + op 承接（不自起线程；按需后台任务）
        _host = HostChannel()
        _bus.start()
        # D-12/C1：启动 TTL 周期清扫（空闲实例逐出；Pin 豁免；间隔 env 可配）
        _registry.start_sweeper()
        # M3/D-P2-7：启动看门狗巡检循环（check 周期 env 可配；判死/停用联动就绪）
        try:
            _watchdog.start()
        except Exception:  # noqa: BLE001
            logger.exception("看门狗巡检循环启动失败（忽略，不影响主流程）")
        _initialized = True
        logger.info(
            "插件体系已初始化（bus/registry/watchdog/stations/host + TTL 清扫 + 巡检就绪）"
        )


def get_bus() -> EventBus:
    """获取事件总线单例（懒初始化）。"""
    _ensure_initialized()
    assert _bus is not None
    return _bus


def get_registry() -> PluginRegistry:
    """获取插件注册表单例（懒初始化）。"""
    _ensure_initialized()
    assert _registry is not None
    return _registry


def get_watchdog() -> ProgressWatchdog:
    """获取看门狗单例（懒初始化）。"""
    _ensure_initialized()
    assert _watchdog is not None
    return _watchdog


def get_stations() -> StationsHub:
    """获取处理站中枢单例（懒初始化）。"""
    _ensure_initialized()
    assert _stations is not None
    return _stations


def get_host_channel() -> HostChannel:
    """获取宿主通道单例（懒初始化；二期 M2）。"""
    _ensure_initialized()
    assert _host is not None
    return _host


def get_snapshot(user_id: str = "", team_id: str = "") -> Dict[str, Any]:
    """面板只读快照（二期 M1-b；契约 §15.1）。

    - 总开关关闭 / 组件未初始化：返回 ``enabled=false`` 骨架（200 语义）；
    - 只读、无副作用；按 ``user_id`` 过滤（可选再按 ``team_id``）。
    """
    from plugin.snapshot import build_snapshot  # noqa: PLC0415

    return build_snapshot(
        enabled=is_enabled(),
        user_id=str(user_id or ""),
        team_id=str(team_id or ""),
        registry=_registry,
        stations=_stations,
        watchdog=_watchdog,
    )


def bind_loop(loop: Any) -> None:
    """绑定主事件循环（供 ws_push 等出站调度；可选，缺失时按兜底链尝试）。"""
    _sdk_bind_loop(loop)
    if _stations is not None:
        # M3 防呆判据 A：记录主 loop 线程 ident（事件循环线程内同步触发即放行）
        try:
            _stations.bind_main_loop_ident()
        except Exception:  # noqa: BLE001
            logger.debug("站防呆主循环 ident 绑定失败（忽略）", exc_info=True)


# ----------------------------------------------------------------------
# 生命周期
# ----------------------------------------------------------------------
def startup() -> None:
    """显式启动组件（供 main.lifespan 后续接线调用；幂等）。

    注意：本函数只初始化组件，不放宽开关语义（事件发布仍受总开关控制）。
    """
    _ensure_initialized()


def shutdown() -> None:
    """停止全部组件并置总开关为关（幂等；测试清理/进程退出用）。"""
    global _initialized, _bus, _registry, _watchdog, _stations, _host, _demo_plugin, _enabled
    with _lock:
        if not _initialized and _bus is None:
            _enabled = False
            return
        registry, bus, stations, host, watchdog = (
            _registry,
            _bus,
            _stations,
            _host,
            _watchdog,
        )
        _initialized = False
        _bus = None
        _registry = None
        _watchdog = None
        _stations = None
        _host = None
        _demo_plugin = None
        _enabled = False
    try:
        if watchdog is not None:
            # M3：巡检循环先停（避免拆卸期间触发停用回调）
            watchdog.stop()
        if host is not None:
            # 宿主通道后台任务（级联停止/对账）有界收尾；daemon 线程不阻塞退出
            host.drain(0.5)
        if stations is not None:
            stations.reset()
        if registry is not None:
            registry.shutdown()
        if bus is not None:
            bus.stop()
    except Exception:  # noqa: BLE001
        logger.exception("插件体系关闭异常")
    logger.info("插件体系已关闭")


# ----------------------------------------------------------------------
# 白名单埋点入口
# ----------------------------------------------------------------------
def publish_tool_event(
    session: Any,
    tool_name: str,
    args: Any,
    result_str: Any,
    result_ts: str = "",
    ok: Optional[bool] = None,
) -> bool:
    """发布"工具执行"事件（白名单埋点，供 llm.py 工具执行处调用）。

    - 总开关关闭时立即返回 False（零副作用：不校验、不创建组件、不入队）；
    - scope 从会话对象尽力提取（user/team/agent/session，缺失留空）；
    - **fail-closed 入口**：无 ``user_id`` 归属的事件拒绝发布；
    - 事件字段最小化（防敏感数据扩散）：工具名 / 参数键名 / 结果长度 /
      成败 / 时间文本；不含参数值与结果正文（如需扩展另行评审）。

    :return: 是否成功入队
    """
    if not _enabled:
        return False
    try:
        scope: Dict[str, str] = {
            "user_id": str(getattr(session, "user_id", "") or ""),
            "team_id": str(getattr(session, "team_id", "") or ""),
            "agent_id": str(getattr(session, "agent_id", "") or ""),
            "session_id": str(getattr(session, "session_id", "") or ""),
        }
        if not scope["user_id"]:
            return False
        payload: Dict[str, Any] = {
            "tool": str(tool_name or ""),
            "args_keys": sorted(args.keys()) if isinstance(args, dict) else [],
            "result_chars": len(str(result_str or "")),
            "ok": bool(ok) if ok is not None else True,
            "ts_text": str(result_ts or ""),
        }
        return safe_publish("tool.call.completed", scope, payload, source="llm.tool_loop")
    except Exception:  # noqa: BLE001
        # 埋点永不抛出（不能影响工具主链路）
        logger.exception("插件埋点发布失败（已忽略，不影响主线）")
        return False


def safe_publish(
    event_type: str,
    scope: Any,
    payload: Any = None,
    source: str = "",
) -> bool:
    """埋点安全发布（契约 §10.1：业务代码唯一允许调用的埋点入口）。

    - 总开关关闭 / 组件未初始化：静默 no-op（返回 False，**不创建组件**，
      零副作用）；
    - ``scope.user_id`` 为空：拒绝（fail-closed 入口防线）；
    - 一切异常吞掉（禁止影响工具执行链路）。
    """
    if not _enabled:
        return False
    bus = _bus
    if bus is None:
        return False
    try:
        scope_dict = normalize_scope(scope)
        if not scope_dict["user_id"]:
            return False
        return bus.publish(
            str(event_type), scope_dict, dict(payload or {}), source=str(source or "")
        )
    except Exception:  # noqa: BLE001
        logger.exception("插件埋点发布失败（已忽略，不影响主线）")
        return False


def safe_process(
    station_id: str,
    data: Any,
    scope: Any = None,
    *,
    meta: Any = None,
    cancel_event: Any = None,
    timeout_s: Any = None,
) -> Any:
    """处理站安全触发入口（业务代码唯一允许调用的站入口；fail-open）。

    - 总开关关闭 / 组件未初始化：原样返回 ``data``（零副作用，近零开销）；
    - 有订阅：交由插件处理并回填（回填结果作为返回值）；
    - 一切异常路径（无订阅/超时/取消/插件异常/非法回填/实例失效/队列满）：
      原样返回 ``data`` + 分类计数（站内部统计），绝不抛出、绝不影响主链路。
    """
    if not _enabled:
        return data
    hub = _stations
    if hub is None:
        return data
    try:
        return hub.process(
            station_id,
            data,
            scope,
            meta=meta,
            cancel_event=cancel_event,
            timeout_s=timeout_s,
        )
    except Exception:  # noqa: BLE001
        logger.exception("处理站调用失败（已忽略，返回原数据）")
        return data


def init_plugin_system() -> None:
    """插件体系初始化挂载点（供 ``server/main.py`` lifespan 调用）。

    - 总开关关闭（默认）：直接 no-op——不创建组件、不起线程（零副作用）；
    - 总开关开启：初始化核心组件并尝试绑定当前主事件循环（供 ws_push 调度）。
    """
    if not _enabled:
        return
    _ensure_initialized()
    try:
        import asyncio

        loop = asyncio.get_running_loop()
    except RuntimeError:
        loop = None
    if loop is not None:
        _sdk_bind_loop(loop)
        if _stations is not None:
            # M3 防呆判据 A：记录主 loop 线程 ident（本函数在 lifespan 主 loop 线程执行）
            try:
                _stations.bind_main_loop_ident()
            except Exception:  # noqa: BLE001
                logger.debug("站防呆主循环 ident 绑定失败（忽略）", exc_info=True)
    # D-P2-6：进程启动路径的示范插件自动注册（默认关；幂等）
    _maybe_register_demo()


def plugin_cascade(
    user_id: str,
    *,
    team_id: str = "",
    agent_id: str = "",
    session_id: str = "",
) -> int:
    """插件实例级联清理单点入口（供 ``server/agent/routes.py`` 接线调用）。

    - 总开关关闭 / 组件未初始化：直接返回 0（零副作用）；
    - 一切异常吞掉：级联清理失败绝不影响路由主流程。

    :return: 清理的实例数
    """
    if not _enabled:
        return 0
    registry = _registry
    if registry is None:
        return 0
    removed = 0
    try:
        removed = registry.cascade_cleanup(
            user_id, team_id=team_id, agent_id=agent_id, session_id=session_id
        )
    except Exception:  # noqa: BLE001
        logger.exception("插件级联清理失败（已忽略，不影响主流程）")
    # 处理站（半二期）：订阅随 scope 级联销毁（并入级联单点；失败不影响主流程）
    hub = _stations
    if hub is not None:
        try:
            hub.cascade_cleanup(
                user_id, team_id=team_id, agent_id=agent_id, session_id=session_id
            )
        except Exception:  # noqa: BLE001
            logger.exception("站订阅级联清理失败（已忽略，不影响主流程）")
    # 宿主通道（二期 M2）：scope 销毁 → 会话回收（best-effort；失败不影响主流程）
    host = _host
    if host is not None:
        try:
            host.cascade_cleanup(
                user_id, team_id=team_id, agent_id=agent_id, session_id=session_id
            )
        except Exception:  # noqa: BLE001
            logger.exception("宿主通道级联清理失败（已忽略，不影响主流程）")
    return removed


# ----------------------------------------------------------------------
# 宿主通道（二期 M2；契约 §14）
# ----------------------------------------------------------------------
def plugin_host_event(user_id: str, data: Any) -> bool:
    """宿主通道上行帧入口（供 ``server/ws/endpoints.py`` 接线）。

    - 总开关关闭 / 组件未初始化：False（零副作用）；
    - 一切异常吞掉：绝不影响 WS 主循环。
    """
    if not _enabled:
        return False
    host = _host
    if host is None:
        return False
    try:
        return host.on_event(
            str(user_id or ""), data if isinstance(data, dict) else {}
        )
    except Exception:  # noqa: BLE001
        logger.exception("宿主通道上行处理失败（已忽略）")
        return False


def plugin_host_mark_lost(user_id: str, team_ids: Any) -> int:
    """断连回收：把该用户指定 team 的宿主会话标记 ``lost``（不 kill）。

    :return: 新标记数（总开关关闭 / 未初始化时 0）
    """
    if not _enabled:
        return 0
    host = _host
    if host is None:
        return 0
    try:
        return host.mark_lost(str(user_id or ""), team_ids)
    except Exception:  # noqa: BLE001
        logger.exception("宿主通道断连标记失败（已忽略）")
        return 0


def plugin_host_reconcile(user_id: str, team_id: str) -> int:
    """执行器（重）注册后 best-effort 对账调度（后台线程；返回排期数）。"""
    if not _enabled:
        return 0
    host = _host
    if host is None:
        return 0
    try:
        return host.reconcile_async(str(user_id or ""), str(team_id or ""))
    except Exception:  # noqa: BLE001
        logger.exception("宿主通道对账调度失败（已忽略）")
        return 0
