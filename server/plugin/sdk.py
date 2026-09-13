"""插件出站 SDK - 受控白名单能力 + scope 强校验（fail-closed 出站防线）。

对应 ADR D6：插件经 SDK 使用四类出站能力（全部复用现有 API）：

- **workspace**：workspaceIO 读写（``io_.workspace_io`` 统一三模式通道）；
- **dispatch**：向 agent 推送消息（``agent.chat._dispatch_agent_message``，
  默认 ``active=False`` 防循环）；
- **ws**：向前端推送（``ws.ws_manager.send_message``，只增不改的 plugin_* 类型）；
- **log**：活动日志（``agent.chat._append_activity_log``）。

**fail-closed 出站校验**：SDK 绑定插件实例 scope；
- workspace 操作的目标 workspace_id 必须属于实例 scope 白名单
  （``agent_id`` / ``team_id`` 二者之一，别处一律拒绝，不触达底层 API）；
- dispatch / ws / log 的 user_id 一律取自实例 scope，插件不能任意指定；
- 不满足校验时返回错误（读取类返回 ``{"error": ...}``；推送类返回 False），
  绝不静默降级执行。

**循环 import 处理**：所有对 ``agent.chat`` / ``state`` 的引用都在函数体内
延迟 import；同时提供依赖注入点（测试/演示可替换底层实现）：

- ``set_io_provider(fn)``：替换 workspaceIO 提供者；
- ``set_dispatcher(fn)``：替换消息投递实现；
- ``set_ws_sender(fn)``：替换 WS 推送实现；
- ``set_log_fn(fn)``：替换活动日志实现；
- ``reset_injections()``：还原全部注入（测试清理用）。
"""

from __future__ import annotations

import logging
from typing import Any, Callable, Dict, List, Optional

logger = logging.getLogger(__name__)

# ----------------------------------------------------------------------
# 可注入的底层实现（None = 使用默认真实实现；测试/演示可替换）
# ----------------------------------------------------------------------
_io_provider: Optional[Callable[[str, str], Any]] = None
_dispatcher: Optional[Callable[..., Dict[str, Any]]] = None
_ws_sender: Optional[Callable[[str, Dict[str, Any]], bool]] = None
_log_fn: Optional[Callable[..., None]] = None
_bound_loop: Optional[Any] = None


def set_io_provider(fn: Optional[Callable[[str, str], Any]]) -> None:
    """替换 workspaceIO 提供者（签名 ``(user_id, mode_key) -> WorkspaceIO``）。"""
    global _io_provider
    _io_provider = fn


def set_dispatcher(fn: Optional[Callable[..., Dict[str, Any]]]) -> None:
    """替换消息投递实现（签名同 ``agent.chat._dispatch_agent_message``）。"""
    global _dispatcher
    _dispatcher = fn


def set_ws_sender(fn: Optional[Callable[[str, Dict[str, Any]], bool]]) -> None:
    """替换 WS 推送实现（签名 ``(user_id, message) -> bool``）。"""
    global _ws_sender
    _ws_sender = fn


def set_log_fn(fn: Optional[Callable[..., None]]) -> None:
    """替换活动日志实现（签名同 ``agent.chat._append_activity_log``）。"""
    global _log_fn
    _log_fn = fn


def bind_loop(loop: Any) -> None:
    """绑定主事件循环（供 ws_push 调度；可选，缺失时按兜底链尝试）。"""
    global _bound_loop
    _bound_loop = loop


def reset_injections() -> None:
    """还原全部注入与循环绑定（测试清理用）。"""
    global _io_provider, _dispatcher, _ws_sender, _log_fn, _bound_loop
    _io_provider = None
    _dispatcher = None
    _ws_sender = None
    _log_fn = None
    _bound_loop = None


def _default_io_provider(user_id: str, mode_key: str) -> Any:
    """默认 IO 提供者：走 chat 的统一 WorkspaceIO 通道（延迟 import 防循环）。"""
    from agent.chat import _get_workspace_io  # noqa: PLC0415（函数内延迟）

    return _get_workspace_io(user_id, mode_key)


def _default_dispatcher(**kwargs: Any) -> Dict[str, Any]:
    """默认消息投递：chat._dispatch_agent_message（延迟 import 防循环）。"""
    from agent.chat import _dispatch_agent_message  # noqa: PLC0415

    return _dispatch_agent_message(**kwargs)


def _default_log_fn(**kwargs: Any) -> None:
    """默认活动日志：chat._append_activity_log（延迟 import 防循环）。"""
    from agent.chat import _append_activity_log  # noqa: PLC0415

    _append_activity_log(**kwargs)


def _resolve_loop() -> Optional[Any]:
    """解析主事件循环：优先显式绑定，兜底复用 local_executor 已绑定的循环。"""
    if _bound_loop is not None and getattr(_bound_loop, "is_running", lambda: False)():
        return _bound_loop
    try:
        import state  # noqa: PLC0415

        loop = getattr(getattr(state, "local_executor", None), "_loop", None)
        if loop is not None and getattr(loop, "is_running", lambda: False)():
            return loop
    except Exception:  # noqa: BLE001
        pass
    return None


def ws_push_message(user_id: str, message: Dict[str, Any]) -> bool:
    """向前端推送一条插件消息（模块级；供 SDK 与内部件复用）。

    要求 ``message`` 为含 ``type`` 的字典。调度链：注入实现（测试/演示）→
    显式绑定循环 → local_executor 兜底循环；均不可用时降级丢弃并返回
    False（不阻塞、不抛异常）。
    """
    if not isinstance(message, dict) or not message.get("type"):
        logger.warning("插件 ws_push 被拒：消息须为含 type 的字典")
        return False
    if _ws_sender is not None:
        try:
            return bool(_ws_sender(user_id, dict(message)))
        except Exception as exc:  # noqa: BLE001
            logger.warning("插件 ws_push（注入实现）失败: %s", exc)
            return False
    loop = _resolve_loop()
    if loop is None:
        logger.warning(
            "插件 ws_push 丢弃：主事件循环未绑定"
            "（plugin.bind_loop / local_executor 均不可用）"
        )
        return False
    try:
        import asyncio  # noqa: PLC0415

        import state  # noqa: PLC0415

        ws_manager = getattr(state, "ws_manager", None)
        if ws_manager is None:
            logger.warning("插件 ws_push 丢弃：ws_manager 未初始化")
            return False
        coro = ws_manager.send_message(user_id, dict(message))
        try:
            running = asyncio.get_running_loop()
        except RuntimeError:
            running = None
        if running is loop:
            # 已在目标循环线程内：直接建任务，不阻塞等待
            loop.create_task(coro)
            return True
        fut = asyncio.run_coroutine_threadsafe(coro, loop)
        fut.result(timeout=10.0)
        return True
    except Exception as exc:  # noqa: BLE001
        logger.warning("插件 ws_push 失败: %s", exc)
        return False


class PluginSDK:
    """绑定某一插件实例 scope 的出站能力封装（无状态、可跨线程调用）。"""

    def __init__(self, scope: Optional[Dict[str, str]]) -> None:
        scope = scope or {}
        self.scope: Dict[str, str] = {
            key: str(scope.get(key) or "")
            for key in ("user_id", "team_id", "agent_id", "session_id")
        }

    # ------------------------------------------------------------------
    # 校验辅助（fail-closed）
    # ------------------------------------------------------------------
    def _require_user(self) -> str:
        """取 scope.user_id；为空则拒绝（不能证明归属即不允许出站）。"""
        if not self.scope["user_id"]:
            raise PermissionError("插件出站被拒：实例 scope 缺少 user_id")
        return self.scope["user_id"]

    def _workspace_whitelist(self) -> List[str]:
        """实例 scope 允许操作的 workspace_id 白名单（agent_id / team_id）。"""
        allowed: List[str] = []
        for key in ("agent_id", "team_id"):
            value = self.scope.get(key) or ""
            if value and value not in allowed:
                allowed.append(value)
        return allowed

    def _resolve_workspace_id(self, workspace_id: Optional[str]) -> str:
        """解析并校验目标 workspace_id（fail-closed）。

        - 显式传入：必须在白名单内，否则拒绝；
        - 缺省：取白名单首个（agent_id 优先），白名单为空则拒绝。
        """
        allowed = self._workspace_whitelist()
        if workspace_id:
            if workspace_id not in allowed:
                raise PermissionError(
                    f"插件出站被拒：workspace_id={workspace_id!r} "
                    f"不在实例 scope 白名单 {allowed!r} 内"
                )
            return workspace_id
        if not allowed:
            raise PermissionError(
                "插件出站被拒：实例 scope 无可用 workspace 归属（需 agent_id 或 team_id）"
            )
        return allowed[0]

    def _mode_key(self) -> str:
        """IO 通道的模式归属键：优先 team_id（TOP），否则 agent_id。"""
        return self.scope["team_id"] or self.scope["agent_id"] or self.scope["user_id"]

    # ------------------------------------------------------------------
    # 能力 1：workspaceIO（读 / 写）
    # ------------------------------------------------------------------
    def workspace_read(
        self,
        path: str,
        workspace_id: Optional[str] = None,
        encoding: str = "utf-8",
    ) -> Dict[str, Any]:
        """读取工作空间文件（经统一 WorkspaceIO 通道；三模式路径语义一致）。

        :param encoding: 文本编码（M3 新增可选参，缺省 utf-8 兼容既有调用；
            非法/解码失败按 fail-open 返回 ``{"error": ...}``，绝不抛出）。
        """
        try:
            ws = self._resolve_workspace_id(workspace_id)
        except PermissionError as exc:
            return {"error": str(exc)}
        try:
            provider = _io_provider or _default_io_provider
            io = provider(self.scope["user_id"], self._mode_key())
            from io_.workspace_io import run_io  # noqa: PLC0415

            try:
                pending = io.read_file(
                    ws, str(path), encoding=str(encoding or "utf-8")
                )
            except TypeError:
                # 兼容不接受 encoding 形参的既有 provider（按默认编码读取）
                pending = io.read_file(ws, str(path))
            result = run_io(pending)
            if isinstance(result, dict):
                return result
            return {"error": "workspace_read 返回异常结果"}
        except Exception as exc:  # noqa: BLE001
            logger.warning("插件 workspace_read 失败: %s", exc)
            return {"error": f"workspace_read 失败: {exc}"}

    def workspace_write(
        self, path: str, content: str, workspace_id: Optional[str] = None
    ) -> Dict[str, Any]:
        """写入工作空间文件（同 workspace_read 的归属校验）。"""
        try:
            ws = self._resolve_workspace_id(workspace_id)
        except PermissionError as exc:
            return {"error": str(exc)}
        try:
            provider = _io_provider or _default_io_provider
            io = provider(self.scope["user_id"], self._mode_key())
            from io_.workspace_io import run_io  # noqa: PLC0415

            result = run_io(io.write_file(ws, str(path), str(content)))
            if isinstance(result, dict):
                return result
            return {"error": "workspace_write 返回异常结果"}
        except Exception as exc:  # noqa: BLE001
            logger.warning("插件 workspace_write 失败: %s", exc)
            return {"error": f"workspace_write 失败: {exc}"}

    # ------------------------------------------------------------------
    # 能力 2：向 agent 推送（默认 active=False 防循环）
    # ------------------------------------------------------------------
    def dispatch_agent_message(
        self,
        target_ids: Any,
        content: str,
        *,
        session_id: Optional[str] = None,
        extra: Optional[Dict[str, Any]] = None,
        active: bool = False,
    ) -> Dict[str, Any]:
        """向指定 agent 推送消息（默认被动通道，不触发总结反向推送）。"""
        try:
            user_id = self._require_user()
        except PermissionError as exc:
            return {"error": str(exc)}
        if not target_ids or not content:
            return {"error": "dispatch_agent_message 参数不完整（target_ids/content 必填）"}
        payload_extra: Dict[str, Any] = {
            "session_id": session_id or self.scope["session_id"] or "",
        }
        if extra:
            payload_extra.update(extra)
        kwargs: Dict[str, Any] = {
            "user_id": user_id,
            "target_ids": target_ids,
            "content": str(content),
            "source_agent_id": self.scope["agent_id"] or self.scope["team_id"],
            "team_id": self.scope["team_id"],
            "extra": payload_extra,
            "active": bool(active),
        }
        try:
            dispatch = _dispatcher or _default_dispatcher
            result = dispatch(**kwargs)
            if isinstance(result, dict):
                return result
            return {"error": "dispatch_agent_message 返回异常结果"}
        except Exception as exc:  # noqa: BLE001
            logger.warning("插件 dispatch_agent_message 失败: %s", exc)
            return {"error": f"dispatch_agent_message 失败: {exc}"}

    # ------------------------------------------------------------------
    # 能力 3：WS 推送（只增不改；尽力而为，失败不抛异常）
    # ------------------------------------------------------------------
    def ws_push(self, message: Dict[str, Any]) -> bool:
        """向前端推送一条插件消息（要求消息为含 ``type`` 的字典）。

        调度链：注入实现（测试/演示）→ 显式绑定循环 → local_executor 兜底
        循环；均不可用时降级丢弃并返回 False（不阻塞、不抛异常）。
        （实现见模块级 :func:`ws_push_message`——供内部件复用。）
        """
        try:
            user_id = self._require_user()
        except PermissionError as exc:
            logger.warning("插件 ws_push 被拒: %s", exc)
            return False
        return ws_push_message(user_id, message)

    # ------------------------------------------------------------------
    # 能力 4：活动日志
    # ------------------------------------------------------------------
    def activity_log(
        self, message: str, workspace_id: Optional[str] = None
    ) -> bool:
        """向实例归属工作空间追加一行活动日志（复用 chat 的统一通道）。"""
        try:
            ws = self._resolve_workspace_id(workspace_id)
        except PermissionError as exc:
            logger.warning("插件 activity_log 被拒: %s", exc)
            return False
        kwargs: Dict[str, Any] = {
            "workspace_id": ws,
            "message": str(message),
            "user_id": self.scope["user_id"],
            "mode_key": self._mode_key(),
        }
        try:
            log_fn = _log_fn or _default_log_fn
            log_fn(**kwargs)
            return True
        except Exception as exc:  # noqa: BLE001
            logger.warning("插件 activity_log 失败: %s", exc)
            return False

    # ------------------------------------------------------------------
    # 契约 §7 兼容别名（薄包装，语义与既有方法一致）
    # ------------------------------------------------------------------
    def push_to_agent(
        self,
        target_ids: Any,
        content: str,
        session_id: str = "",
    ) -> Dict[str, Any]:
        """向 agent 推送消息（契约 §7；active=False 防循环，归属取实例 scope）。"""
        return self.dispatch_agent_message(
            target_ids, content, session_id=(session_id or None)
        )

    def emit_frontend(
        self, event_type: str, data: Optional[Dict[str, Any]] = None
    ) -> bool:
        """向前端推送 ``plugin_event``（只增不改协议；无连接/无循环时静默失败）。"""
        import time as _time  # noqa: PLC0415

        message: Dict[str, Any] = {
            "type": "plugin_event",
            "data": {
                "event_type": str(event_type),
                "scope": dict(self.scope),
                "ts": _time.time(),
            },
        }
        if data:
            message["data"].update(dict(data))
        return self.ws_push(message)

    def log_activity(self, message: str) -> bool:
        """向实例归属工作空间追加活动日志（契约 §7）。"""
        return self.activity_log(message)
