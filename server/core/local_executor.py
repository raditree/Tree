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
import uuid
from typing import Any, Dict, Optional

logger = logging.getLogger(__name__)

# 本地执行请求默认超时（秒）
_LOCAL_EXEC_TIMEOUT = 120


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
        try:
            # 优先在主事件循环中发送（绑定于 uvicorn 主循环的 WS 连接跨循环会失败）
            loop = self._loop
            if loop is not None and loop.is_running():
                send_fut = asyncio.run_coroutine_threadsafe(
                    ws_manager.send_message(user_id, message), loop
                )
                send_fut.result(timeout=max(5, timeout))
            else:
                _run_async(ws_manager.send_message(user_id, message))
        except Exception as exc:  # noqa: BLE001
            self._pending.pop(key, None)
            logger.warning("推送本地执行请求失败: %s", exc)
            return {"error": f"推送本地执行请求失败: {exc}"}
        try:
            result = fut.result(timeout=timeout)
            if isinstance(result, BaseException):
                raise result
            return result if isinstance(result, dict) else {"error": str(result)}
        except concurrent.futures.TimeoutError:
            self._pending.pop(key, None)
            logger.warning("本地执行请求超时: exec_id=%s op=%s", exec_id, payload.get("op"))
            return {"error": "本地执行器响应超时"}
        except Exception as exc:  # noqa: BLE001
            self._pending.pop(key, None)
            logger.warning("本地执行请求异常: %s", exc)
            return {"error": f"本地执行器错误: {exc}"}
        finally:
            # 超时/异常后确保清理
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
