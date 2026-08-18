"""本地执行器客户端 - 通过反向 WebSocket 把工具执行请求转发给前端本地执行器。

本地运行模式下，后端完整运行在云端，但工具调用环境转移到用户本机：
- 前端（Flutter）在 WebSocket 连接建立后发送 ``register_local_executor``，
  通知后端"本顶部 agent 的工具调用应转发到本地执行"。
- 后端 :class:`LocalExecutorClient.request` 把每个工具执行请求包装成
  ``tool_exec_request`` 消息推送给前端，并阻塞等待 ``tool_exec_response``。
- 前端执行完成后回传结果，:meth:`resolve` 唤醒等待方。

本地模式按顶部 agent 单独控制：``register_local_executor`` 携带
``top_agent_id``，后端以 ``(user_id, top_agent_id)`` 记录，同一用户的不同
顶部 agent 可分别处于本地/云端模式。

由于工具 handler 运行在聊天消费线程（非事件循环线程），此处使用
``concurrent.futures.Future``（线程安全）实现跨线程的请求/响应配对。
"""

from __future__ import annotations

import asyncio
import concurrent.futures
import logging
import time
import uuid
from typing import Any, Dict, Optional

logger = logging.getLogger(__name__)

# 本地执行请求默认超时（秒）
_LOCAL_EXEC_TIMEOUT = 120

# 执行器"冷启动"判定：距上次成功往返超过该时长视为冷（首次响应需先探测）。
# 冷执行器用短超时等待首个响应，避免前端执行器已失联时每个请求都空等满
# _LOCAL_EXEC_TIMEOUT，导致一条消息要卡几分钟（表现为"发消息卡大半天"）。
_PROBE_GAP_SECONDS = 60.0
# 冷启动探测超时（秒）：远小于响应超时，失联执行器快速失败并触发自动停用
_PROBE_TIMEOUT_SECONDS = 15.0
# 连续响应超时达到该次数后自动停用该用户的本地执行器（回退云端执行），
# 防止后续请求继续逐个空等超时并占用线程池线程导致其他请求被阻塞。
_MAX_CONSECUTIVE_TIMEOUTS = 2


def _run_async(coro: "Any") -> Any:
    """在安全的事件循环上下文中运行协程（兼容已运行的 event loop）。

    仅作为未绑定主循环时的兜底：FastAPI WebSocket 绑定在 uvicorn 主事件循环，
    跨循环 ``asyncio.run`` 会失败，因此正常情况下应通过 :meth:`LocalExecutorClient.bind_loop`
    绑定主循环并使用 ``run_coroutine_threadsafe`` 发送。
    """
    try:
        asyncio.get_running_loop()
    except RuntimeError:
        return asyncio.run(coro)

    result: "list[Any]" = []

    def _runner() -> None:
        result.append(asyncio.run(coro))

    thread = concurrent.futures.ThreadPoolExecutor(max_workers=1)
    fut = thread.submit(_runner)
    try:
        return fut.result(timeout=_LOCAL_EXEC_TIMEOUT + 30)
    finally:
        thread.shutdown(wait=False)


class LocalExecutorClient:
    """管理某用户到前端本地执行器的反向 WS 请求/响应。"""

    def __init__(self) -> None:
        # user_id -> {top_agent_id: base_dir}（base_dir 仅供后端记录/展示；
        # 本地模式按顶部 agent 单独控制，因此以 (user_id, top_agent_id) 区分）
        self._users: Dict[str, Dict[str, str]] = {}
        # (user_id, exec_id) -> concurrent.futures.Future 待响应
        self._pending: Dict[str, "concurrent.futures.Future[Dict[str, Any]]"] = {}
        # 主事件循环（lifespan 中绑定，用于从后台线程安全推送 WS 消息）
        self._loop: "Optional[asyncio.AbstractEventLoop]" = None
        # user_id -> 最近一次成功往返时间戳（冷启动探测依据）
        self._last_ok: Dict[str, float] = {}
        # user_id -> 连续响应超时次数（达到阈值自动停用执行器）
        self._consecutive_timeouts: Dict[str, int] = {}

    def bind_loop(self, loop: "asyncio.AbstractEventLoop") -> None:
        """绑定后端主事件循环。

        工具 handler 运行在聊天消费线程（非事件循环线程），发送 WS 消息时必须
        通过 ``run_coroutine_threadsafe`` 提交到主循环执行，否则 FastAPI
        WebSocket（绑定于 uvicorn 主循环）跨循环调用会挂起或报错。
        """
        self._loop = loop

    def is_local(self, user_id: str, top_agent_id: Optional[str] = None) -> bool:
        """当前用户/顶部 agent 是否已注册本地执行器。

        :param user_id: 用户标识
        :param top_agent_id: 顶部 agent ID；None 时表示"该用户是否注册了任一
                             本地顶部 agent"（兼容 request 的粗粒度守卫）
        """
        regs = self._users.get(user_id)
        if not regs:
            return False
        if top_agent_id is None:
            return True
        return top_agent_id in regs

    def register(
        self,
        user_id: str,
        top_agent_id: str,
        base_dir: Optional[str] = None,
    ) -> None:
        """注册某个顶部 agent 的本地执行器。

        :param user_id: 用户标识
        :param top_agent_id: 顶部 agent ID（本地模式按顶部 agent 单独控制）
        :param base_dir: 用户为该顶部 agent 选择的本地工作目录（仅供记录，不参与路径映射）
        """
        if not top_agent_id:
            top_agent_id = user_id
        self._users.setdefault(user_id, {})[top_agent_id] = base_dir or ""
        # 重新注册视为执行器恢复：清零连续超时计数，避免旧失败记录继续触发停用
        self._consecutive_timeouts.pop(user_id, None)
        logger.info(
            "用户 %s 顶部 agent %s 已启用本地执行器（base_dir=%s）",
            user_id,
            top_agent_id,
            base_dir,
        )

    def unregister(self, user_id: str, top_agent_id: str) -> None:
        """注销某个顶部 agent 的本地执行器，并使该用户所有待响应请求失败。

        :param user_id: 用户标识
        :param top_agent_id: 顶部 agent ID
        """
        if not top_agent_id:
            top_agent_id = user_id
        regs = self._users.get(user_id)
        if regs is not None:
            regs.pop(top_agent_id, None)
            if not regs:
                self._users.pop(user_id, None)
        for key, fut in list(self._pending.items()):
            if key.startswith(f"{user_id}:"):
                if not fut.done():
                    fut.set_exception(RuntimeError("本地执行器已注销"))
                self._pending.pop(key, None)
        logger.info("用户 %s 顶部 agent %s 已注销本地执行器", user_id, top_agent_id)

    def _is_cold(self, user_id: str) -> bool:
        """执行器是否处于"冷"状态：距上次成功往返超过探测间隔。

        冷状态下首个响应改用短超时探测，失联执行器快速失败；热状态下
        （对话进行中频繁往返）保持完整响应超时，不误伤慢速但正常的工具。
        """
        return time.time() - self._last_ok.get(user_id, 0.0) > _PROBE_GAP_SECONDS

    def _register_timeout(self, user_id: str) -> None:
        """记录一次响应超时；连续超时达到阈值时自动停用该用户的本地执行器。

        停用后 is_local 返回 False，后续请求立即返回错误，调用方回退到
        云端（Docker）通道，不再逐个请求空等 120s，也不占用线程池线程阻塞
        其他请求。前端重新注册（register）时自动恢复。
        """
        self._consecutive_timeouts[user_id] = (
            self._consecutive_timeouts.get(user_id, 0) + 1
        )
        if self._consecutive_timeouts[user_id] >= _MAX_CONSECUTIVE_TIMEOUTS:
            logger.warning(
                "本地执行器连续 %d 次响应超时，自动停用（回退云端执行）: user_id=%s",
                _MAX_CONSECUTIVE_TIMEOUTS,
                user_id,
            )
            for top_agent_id in list(self._users.get(user_id, {}).keys()):
                try:
                    self.unregister(user_id, top_agent_id)
                except Exception:  # noqa: BLE001
                    pass

    def request(
        self,
        ws_manager: Any,
        user_id: str,
        payload: Dict[str, Any],
        timeout: float = _LOCAL_EXEC_TIMEOUT,
    ) -> Dict[str, Any]:
        """发送一个工具执行请求并阻塞等待前端响应。

        在事件循环线程中调用时同样可用：发送 WS 消息优先通过 ``bind_loop``
        绑定的主循环使用 ``run_coroutine_threadsafe`` 执行（线程安全），
        阻塞等待响应使用 ``concurrent.futures.Future``，跨线程安全。

        :param ws_manager: WebSocketManager 实例
        :param user_id: 用户标识
        :param payload: 执行请求负载（op / agent_id / path 等）
        :param timeout: 等待响应超时秒数
        :return: 前端返回的结果字典；失败时 ``{"error": ...}``
        """
        if not self.is_local(user_id):
            return {"error": "本地执行器未启用"}
        exec_id = uuid.uuid4().hex
        key = f"{user_id}:{exec_id}"
        fut: "concurrent.futures.Future[Dict[str, Any]]" = concurrent.futures.Future()
        self._pending[key] = fut
        message = {
            "type": "tool_exec_request",
            "data": {"exec_id": exec_id, **payload},
        }
        # 发送超时远小于响应超时：send 仅推送 WS 消息，正常毫秒级完成。
        # 主事件循环短暂繁忙时 send_message 可能延迟入队，此时不立即放弃——
        # 消息仍可能被延迟投递到前端，继续等待响应可避免工具调用误判失败。
        send_timeout = min(10.0, timeout)
        send_fut: "Optional[concurrent.futures.Future[Any]]" = None
        try:
            # 优先在主事件循环中发送（绑定于 uvicorn 主循环的 WS 连接跨循环会失败）
            loop = self._loop
            if loop is not None and loop.is_running():
                send_fut = asyncio.run_coroutine_threadsafe(
                    ws_manager.send_message(user_id, message), loop
                )
                send_fut.result(timeout=send_timeout)
            else:
                _run_async(ws_manager.send_message(user_id, message))
        except concurrent.futures.TimeoutError:
            # 发送超时：消息可能仍在主事件循环队列中等待投递。
            # 不移除 pending、不返回错误，继续等待响应（前端执行后回传结果时仍能匹配）。
            logger.debug(
                "本地执行请求发送超时，继续等待响应: exec_id=%s op=%s",
                exec_id, payload.get("op"),
            )
        except Exception as exc:  # noqa: BLE001
            self._pending.pop(key, None)
            logger.warning(
                "推送本地执行请求失败: %r (exec_id=%s, op=%s)",
                exc, exec_id, payload.get("op"),
            )
            return {"error": f"推送本地执行请求失败: {exc}"}
        # 冷启动探测：执行器长时间无成功往返时，先用短超时等待首个响应，
        # 避免前端执行器已失联（未注销、WS 断开等）后每个请求都空等满
        # timeout（默认 120s），一条消息叠加多次请求就是"卡大半天"。
        wait_timeout = timeout
        if self._is_cold(user_id):
            wait_timeout = min(timeout, _PROBE_TIMEOUT_SECONDS)
        try:
            result = fut.result(timeout=wait_timeout)
            if isinstance(result, BaseException):
                raise result
            # 成功往返：记录存活时间并清零连续超时计数（探测不再触发）
            self._last_ok[user_id] = time.time()
            self._consecutive_timeouts[user_id] = 0
            return result if isinstance(result, dict) else {"error": str(result)}
        except concurrent.futures.TimeoutError:
            self._pending.pop(key, None)
            # 取消可能仍在排队的发送协程，避免极晚投递导致响应无人匹配
            if send_fut is not None and not send_fut.done():
                send_fut.cancel()
            logger.warning(
                "本地执行请求超时(等待 %.0fs): exec_id=%s op=%s",
                wait_timeout, exec_id, payload.get("op"),
            )
            self._register_timeout(user_id)
            return {"error": "本地执行器响应超时"}
        except Exception as exc:  # noqa: BLE001
            self._pending.pop(key, None)
            logger.warning("本地执行请求异常: %r (exec_id=%s)", exc, exec_id)
            return {"error": f"本地执行器错误: {exc}"}
        finally:
            # 仅当请求被放弃（future 仍未完成，即超时/异常路径）时才兜底清理，
            # 避免在正常返回路径上把已交付的结果从 pending 中提前移除；
            # 正常路径的清理由 resolve() 在匹配时完成（set_result + pop）。
            # 注意：不使用 fut.set_running_or_notify_cancel() 判断，因为它会把
            # 尚未完成的 future 置为 RUNNING，导致后续 set_result 抛 InvalidStateError。
            if not fut.done():
                self._pending.pop(key, None)

    def resolve(self, user_id: str, exec_id: str, result: Dict[str, Any]) -> bool:
        """由 WS 接收处理调用：用前端返回结果唤醒等待方。

        :param user_id: 用户标识
        :param exec_id: 执行请求标识
        :param result: 前端返回的结果字典
        :return: 是否成功匹配到待响应请求
        """
        key = f"{user_id}:{exec_id}"
        fut = self._pending.get(key)
        if fut is None or fut.done():
            return False
        fut.set_result(result)
        self._pending.pop(key, None)
        return True
