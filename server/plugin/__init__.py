"""插件体系（一期骨架）- 进程内事件总线 + 插件注册表 + 看门狗 + 出站 SDK。

**启用开关（默认关闭；关闭时对现有行为零副作用）**：

- 环境变量 ``TREE_PLUGIN_ENABLED=1``：进程启动时默认启用；
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
- 启用方式：设 ``TREE_PLUGIN_ENABLED=1`` 后重启后端进程生效。
"""

from __future__ import annotations

import logging
import os
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
from plugin.sdk import PluginSDK, bind_loop as _sdk_bind_loop  # noqa: F401
from plugin.watchdog import (  # noqa: F401
    DEFAULT_BEAT_INTERVAL,
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
    "init_plugin_system",
    "plugin_cascade",
    # 开关常量
    "ENV_ENABLED",
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
    "PluginSDK",
    "JoinBuffer",
    "JoinResult",
]

# 环境变量开关名（进程启动默认值）
ENV_ENABLED = "TREE_PLUGIN_ENABLED"


def _read_env_enabled() -> bool:
    """读取环境变量开关（TREE_PLUGIN_ENABLED=1/true/yes/on 视为启用）。"""
    value = str(os.environ.get(ENV_ENABLED, "") or "").strip().lower()
    return value in ("1", "true", "yes", "on")


_lock = threading.Lock()
_enabled = _read_env_enabled()
_bus: Optional[EventBus] = None
_registry: Optional[PluginRegistry] = None
_watchdog: Optional[ProgressWatchdog] = None
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
    logger.info("插件体系开关: %s", "enabled" if _enabled else "disabled")


# ----------------------------------------------------------------------
# 组件获取（懒初始化）
# ----------------------------------------------------------------------
def _ensure_initialized() -> None:
    """创建并启动单例组件（幂等，线程安全）。"""
    global _bus, _registry, _watchdog, _initialized
    with _lock:
        if _initialized:
            return
        _watchdog = ProgressWatchdog()
        _bus = EventBus()
        _registry = PluginRegistry(bus=_bus, watchdog=_watchdog)
        _bus.start()
        # D-12/C1：启动 TTL 周期清扫（空闲实例逐出；Pin 豁免；间隔 env 可配）
        _registry.start_sweeper()
        _initialized = True
        logger.info("插件体系已初始化（bus/registry/watchdog + TTL 清扫就绪）")


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


def bind_loop(loop: Any) -> None:
    """绑定主事件循环（供 ws_push 等出站调度；可选，缺失时按兜底链尝试）。"""
    _sdk_bind_loop(loop)


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
    global _initialized, _bus, _registry, _watchdog, _enabled
    with _lock:
        if not _initialized and _bus is None:
            _enabled = False
            return
        registry, bus = _registry, _bus
        _initialized = False
        _bus = None
        _registry = None
        _watchdog = None
        _enabled = False
    try:
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
    try:
        return registry.cascade_cleanup(
            user_id, team_id=team_id, agent_id=agent_id, session_id=session_id
        )
    except Exception:  # noqa: BLE001
        logger.exception("插件级联清理失败（已忽略，不影响主流程）")
        return 0
