"""前端执行器客户端 - 通过反向 WebSocket 把工具执行请求转发给前端执行器。

本地（local）与 SSH（ssh）两种"前端执行"模式共用本客户端：
- 本地模式：前端（Flutter）发送 ``register_local_executor``，通知后端"本顶部
  agent 的工具调用应转发到用户本机执行"；前端在用户选择的目录中执行。
- SSH 模式：前端发送 ``register_ssh_executor``，通知后端"本顶部 agent 的工具
  调用应转发到前端发起的 SSH 会话执行"；SSH 连接由前端（dartssh2）建立，
  IP 相对前端机器，后端仅转发。
- 后端 :meth:`request` 把每个工具执行请求包装成 ``tool_exec_request`` 消息推送给
  前端，并阻塞等待 ``tool_exec_response``；前端执行完成后回传结果，:meth:`resolve`
  唤醒等待方。

两种模式都按顶部 agent 单独控制：注册消息携带 ``team_id``，后端以
``(user_id, team_id)`` 记录（local 记入 ``_users``、ssh 记入 ``_ssh_users``），
同一用户的不同顶部 agent 可分别处于 local / ssh / cloud 模式（local 与 ssh 互斥，
由 mode_resolver 保证）。所有在途状态（pending 配对 / 冷热探测 / 超时计数）
同样以 ``(user_id, team_id)`` 粒度隔离：请求 id 形如
``{user_id}:{team_id}:{uuid}``，注销某个 team 不会误杀同用户其他 team 的
在途请求。

由于工具 handler 运行在聊天消费线程（非事件循环线程），此处使用
``concurrent.futures.Future``（线程安全）实现跨线程的请求/响应配对。
"""

from __future__ import annotations

import asyncio
import concurrent.futures
import logging
import time
import uuid
from typing import Any, Dict, Optional, Tuple

logger = logging.getLogger(__name__)

# 本地执行请求默认超时（秒）
_LOCAL_EXEC_TIMEOUT = 120

# 执行器"冷启动"判定：距上次成功往返超过该时长视为冷（首次响应需先探测）。
# 冷执行器用短超时等待首个响应，避免前端执行器已失联时每个请求都空等满
# _LOCAL_EXEC_TIMEOUT，导致一条消息要卡几分钟（表现为"发消息卡大半天"）。
_PROBE_GAP_SECONDS = 60.0
# 冷启动探测超时（秒）：远小于响应超时，失联执行器快速失败并触发自动停用
_PROBE_TIMEOUT_SECONDS = 15.0
# 连续响应超时达到该次数后自动停用该 (user_id, team_id) 的前端执行器
# （回退云端执行），防止后续请求继续逐个空等超时并占用线程池线程导致
# 其他请求被阻塞。
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
    """管理某用户到前端执行器（本地 / SSH）的反向 WS 请求/响应。"""

    def __init__(self) -> None:
        # user_id -> {team_id: base_dir}（base_dir 仅供后端记录/展示；
        # 本地模式按顶部 agent 单独控制，因此以 (user_id, team_id) 区分）
        self._users: Dict[str, Dict[str, str]] = {}
        # user_id -> {team_id}（SSH 模式按顶部 agent 单独控制；
        # 仅记录"该顶部 agent 的工具调用应转发到前端 SSH 会话执行"）
        self._ssh_users: Dict[str, set] = {}
        # tool_id -> concurrent.futures.Future 待响应。
        # tool_id 全局唯一且自描述：request 生成的 id 形如
        # ``{user_id}:{team_id}:{uuid}``，hook 请求沿用外部传入的 tool_id。
        self._pending: Dict[str, "concurrent.futures.Future[Dict[str, Any]]"] = {}
        # tool_id -> (user_id, team_id)：pending 归属索引，注销/失效按
        # (user_id, team_id) 粒度精确匹配（不误杀同用户其他 team 的在途请求）
        self._pending_owner: Dict[str, Tuple[str, str]] = {}
        # 主事件循环（lifespan 中绑定，用于从后台线程安全推送 WS 消息）
        self._loop: "Optional[asyncio.AbstractEventLoop]" = None
        # (user_id, team_id) -> 最近一次成功往返时间戳（冷启动探测依据）
        self._last_ok: Dict[Tuple[str, str], float] = {}
        # (user_id, team_id) -> 连续响应超时次数（达到阈值自动停用执行器）
        self._consecutive_timeouts: Dict[Tuple[str, str], int] = {}

    def bind_loop(self, loop: "asyncio.AbstractEventLoop") -> None:
        """绑定后端主事件循环。

        工具 handler 运行在聊天消费线程（非事件循环线程），发送 WS 消息时必须
        通过 ``run_coroutine_threadsafe`` 提交到主循环执行，否则 FastAPI
        WebSocket（绑定于 uvicorn 主循环）跨循环调用会挂起或报错。
        """
        self._loop = loop

    def is_local(self, user_id: str, team_id: Optional[str] = None) -> bool:
        """当前用户/顶部 agent 是否已注册本地执行器。

        :param user_id: 用户标识
        :param team_id: 顶部 agent ID；None 时表示"该用户是否注册了任一
                             本地顶部 agent"（兼容 request 的粗粒度守卫）
        """
        regs = self._users.get(user_id)
        if not regs:
            return False
        if team_id is None:
            return True
        return team_id in regs

    def base_dir_of(
        self, user_id: str, team_id: Optional[str] = None
    ) -> str:
        """返回用户/顶部 agent 注册的本地工作目录（base_dir）。

        base_dir 由前端 ``register_local_executor`` 上报，即用户在本地执行
        模式下选择的目录。附件上传、工作文件落盘等需要本地真实根目录的
        场景应通过本方法获取，而非直接访问 ``_users`` 私有字段。

        :param user_id: 用户标识
        :param team_id: 顶部 agent ID；None 时返回该用户任一已注册
                             本地执行器的 base_dir（取第一个非空）
        :return: 本地工作目录；未注册或为空时返回 ""
        """
        regs = self._users.get(user_id) or {}
        if team_id is None:
            for value in regs.values():
                if value:
                    return value
            return ""
        return regs.get(team_id) or ""

    def register(
        self,
        user_id: str,
        team_id: str,
        base_dir: Optional[str] = None,
    ) -> None:
        """注册某个顶部 agent 的本地执行器。

        :param user_id: 用户标识
        :param team_id: 顶部 agent ID（本地模式按顶部 agent 单独控制）
        :param base_dir: 用户为该顶部 agent 选择的本地工作目录（仅供记录，不参与路径映射）
        """
        if not team_id:
            team_id = user_id
        self._users.setdefault(user_id, {})[team_id] = base_dir or ""
        # 重新注册视为执行器恢复：清零该 (user_id, team_id) 的连续超时计数，
        # 避免旧失败记录继续触发停用
        self._consecutive_timeouts.pop((user_id, team_id), None)
        logger.info(
            "用户 %s 顶部 agent %s 已启用本地执行器（base_dir=%s）",
            user_id,
            team_id,
            base_dir,
        )

    def _fail_pending(self, user_id: str, team_id: str, reason: str) -> None:
        """使指定 (user_id, team_id) 的所有待响应请求失败并清理。

        仅失效该 team 的 pending：同用户其他 team 的在途请求不受影响。
        """
        target = (user_id, team_id)
        for key, owner in list(self._pending_owner.items()):
            if owner != target:
                continue
            fut = self._pending.pop(key, None)
            self._pending_owner.pop(key, None)
            if fut is not None and not fut.done():
                fut.set_exception(RuntimeError(reason))

    def unregister(self, user_id: str, team_id: str) -> None:
        """注销某个顶部 agent 的本地执行器，并使该 team 的待响应请求失败。

        :param user_id: 用户标识
        :param team_id: 顶部 agent ID
        """
        if not team_id:
            team_id = user_id
        regs = self._users.get(user_id)
        if regs is not None:
            regs.pop(team_id, None)
            if not regs:
                self._users.pop(user_id, None)
        self._fail_pending(user_id, team_id, "本地执行器已注销")
        logger.info("用户 %s 顶部 agent %s 已注销本地执行器", user_id, team_id)

    def is_ssh(self, user_id: str, team_id: Optional[str] = None) -> bool:
        """当前用户/顶部 agent 是否已注册 SSH 前端执行器。

        :param user_id: 用户标识
        :param team_id: 顶部 agent ID；None 时表示"该用户是否注册了任一
                             SSH 顶部 agent"
        """
        regs = self._ssh_users.get(user_id)
        if not regs:
            return False
        if team_id is None:
            return True
        return team_id in regs

    def register_ssh(self, user_id: str, team_id: str) -> None:
        """注册某个顶部 agent 的 SSH 前端执行器。

        :param user_id: 用户标识
        :param team_id: 顶部 agent ID（SSH 模式按顶部 agent 单独控制）
        """
        if not team_id:
            team_id = user_id
        self._ssh_users.setdefault(user_id, set()).add(team_id)
        # 重新注册视为执行器恢复：清零该 (user_id, team_id) 的连续超时计数
        self._consecutive_timeouts.pop((user_id, team_id), None)
        logger.info("用户 %s 顶部 agent %s 已启用 SSH 前端执行器", user_id, team_id)

    def unregister_ssh(self, user_id: str, team_id: str) -> None:
        """注销某个顶部 agent 的 SSH 前端执行器，并使该 team 的待响应请求失败。

        :param user_id: 用户标识
        :param team_id: 顶部 agent ID
        """
        if not team_id:
            team_id = user_id
        regs = self._ssh_users.get(user_id)
        if regs is not None:
            regs.discard(team_id)
            if not regs:
                self._ssh_users.pop(user_id, None)
        self._fail_pending(user_id, team_id, "SSH 前端执行器已注销")
        logger.info("用户 %s 顶部 agent %s 已注销 SSH 前端执行器", user_id, team_id)

    def _has_frontend_executor(self, user_id: str, team_id: str = "") -> bool:
        """该用户/顶部 agent 是否注册了前端执行器（本地或 SSH）。

        :param team_id: 顶部 agent ID；非空时按 (user_id, team_id) 精确判定，
            空串时回退"该用户是否注册了任一前端执行器"（兼容未携带 team_id
            的历史调用）。
        """
        if team_id:
            return (
                team_id in (self._users.get(user_id) or {})
                or team_id in (self._ssh_users.get(user_id) or set())
            )
        return bool(self._users.get(user_id)) or bool(self._ssh_users.get(user_id))

    def _is_cold(self, user_id: str, team_id: str = "") -> bool:
        """执行器是否处于"冷"状态：距上次成功往返超过探测间隔。

        冷状态下首个响应改用短超时探测，失联执行器快速失败；热状态下
        （对话进行中频繁往返）保持完整响应超时，不误伤慢速但正常的工具。
        """
        return (
            time.time() - self._last_ok.get((user_id, team_id), 0.0)
            > _PROBE_GAP_SECONDS
        )

    def _disable_ssh_mode(self, user_id: str, team_id: str) -> None:
        """注销该 (user_id, team_id) 的 SSH 持久化配置。

        使后续 ``resolve_mode`` 判定为 cloud（新会话/工具绑定回落云端 IO），
        与 local 执行器停用后的回落行为保持一致。state.ssh_manager 未初始化
        （单测环境）时跳过。
        """
        try:
            import state

            ssh_manager = state.ssh_manager
            if ssh_manager is not None:
                ssh_manager.unregister(user_id, team_id)
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "自动停用时注销 SSH 模式配置失败: user_id=%s team_id=%s (%s)",
                user_id, team_id, exc,
            )

    def _register_timeout(self, user_id: str, team_id: str = "") -> None:
        """记录一次响应超时；连续超时达到阈值时自动停用该 team 的执行器。

        停用范围：该 (user_id, team_id) 的 local 与 SSH 注册一并注销（B2：
        SSH 失联同样快速失败），并注销 SSH 持久化配置使后续请求按
        "无执行器"处理（resolve_mode 回落 cloud）。team_id 未知（空串，
        兼容未携带 team_id 的历史调用）时回退为停用该用户全部注册。
        前端重新注册（register / register_ssh）时计数清零自动恢复。
        """
        key = (user_id, team_id)
        self._consecutive_timeouts[key] = (
            self._consecutive_timeouts.get(key, 0) + 1
        )
        if self._consecutive_timeouts[key] < _MAX_CONSECUTIVE_TIMEOUTS:
            return
        logger.warning(
            "前端执行器连续 %d 次响应超时，自动停用（回退云端执行）: "
            "user_id=%s team_id=%r",
            _MAX_CONSECUTIVE_TIMEOUTS, user_id, team_id,
        )
        if team_id:
            teams = [team_id]
        else:
            # team 未知：停用该用户全部 local / ssh 注册（历史兜底行为）
            teams = list((self._users.get(user_id) or {}).keys())
            for t in (self._ssh_users.get(user_id) or set()):
                if t not in teams:
                    teams.append(t)
        for t in teams:
            try:
                if t in (self._users.get(user_id) or {}):
                    self.unregister(user_id, t)
                if t in (self._ssh_users.get(user_id) or set()):
                    self.unregister_ssh(user_id, t)
                    # SSH 持久化配置一并注销 → 后续 resolve_mode 回落 cloud
                    self._disable_ssh_mode(user_id, t)
            except Exception:  # noqa: BLE001
                pass
        # 停用后计数清零
        self._consecutive_timeouts[key] = 0

    def request(
        self,
        ws_manager: Any,
        user_id: str,
        payload: Dict[str, Any],
        timeout: float = _LOCAL_EXEC_TIMEOUT,
        team_id: str = "",
    ) -> Dict[str, Any]:
        """发送一个工具执行请求并阻塞等待前端响应。

        在事件循环线程中调用时同样可用：发送 WS 消息优先通过 ``bind_loop``
        绑定的主循环使用 ``run_coroutine_threadsafe`` 执行（线程安全），
        阻塞等待响应使用 ``concurrent.futures.Future``，跨线程安全。

        :param ws_manager: WebSocketManager 实例
        :param user_id: 用户标识
        :param payload: 执行请求负载（op / agent_id / path / team_id 等）
        :param timeout: 等待响应超时秒数
        :param team_id: 顶部 agent ID（隔离粒度）；空串时回退读取 payload["team_id"]
        :return: 前端返回的结果字典；失败时 ``{"error": ...}``
        """
        team_id = team_id or str(payload.get("team_id") or "")
        if not self._has_frontend_executor(user_id, team_id):
            return {"error": "前端执行器未启用（本地或 SSH）"}
        # 请求 id 携带 (user_id, team_id)：全局唯一且自描述，响应配对与
        # 注销失效均按 (user_id, team_id) 粒度进行，不同 team 互不串扰。
        tool_id = f"{user_id}:{team_id}:{uuid.uuid4().hex}"
        key = tool_id
        fut: "concurrent.futures.Future[Dict[str, Any]]" = concurrent.futures.Future()
        self._pending[key] = fut
        self._pending_owner[key] = (user_id, team_id)
        message = {
            "type": "tool_exec_request",
            "data": {"tool_id": tool_id, "team_id": team_id, **payload},
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
                "本地执行请求发送超时，继续等待响应: tool_id=%s op=%s",
                tool_id, payload.get("op"),
            )
        except Exception as exc:  # noqa: BLE001
            self._pending.pop(key, None)
            self._pending_owner.pop(key, None)
            logger.warning(
                "推送本地执行请求失败: %r (tool_id=%s, op=%s)",
                exc, tool_id, payload.get("op"),
            )
            return {"error": f"推送本地执行请求失败: {exc}"}
        # 冷启动探测：执行器长时间无成功往返时，先用短超时等待首个响应，
        # 避免前端执行器已失联（未注销、WS 断开等）后每个请求都空等满
        # timeout（默认 120s），一条消息叠加多次请求就是"卡大半天"。
        wait_timeout = timeout
        if self._is_cold(user_id, team_id):
            wait_timeout = min(timeout, _PROBE_TIMEOUT_SECONDS)
        try:
            result = fut.result(timeout=wait_timeout)
            if isinstance(result, BaseException):
                raise result
            # 成功往返：记录存活时间并清零连续超时计数（探测不再触发）
            self._last_ok[(user_id, team_id)] = time.time()
            self._consecutive_timeouts[(user_id, team_id)] = 0
            return result if isinstance(result, dict) else {"error": str(result)}
        except concurrent.futures.TimeoutError:
            self._pending.pop(key, None)
            self._pending_owner.pop(key, None)
            # 取消可能仍在排队的发送协程，避免极晚投递导致响应无人匹配
            if send_fut is not None and not send_fut.done():
                send_fut.cancel()
            logger.warning(
                "本地执行请求超时(等待 %.0fs): tool_id=%s op=%s",
                wait_timeout, tool_id, payload.get("op"),
            )
            self._register_timeout(user_id, team_id)
            return {"error": "本地执行器响应超时"}
        except Exception as exc:  # noqa: BLE001
            self._pending.pop(key, None)
            self._pending_owner.pop(key, None)
            logger.warning("本地执行请求异常: %r (tool_id=%s)", exc, tool_id)
            return {"error": f"本地执行器错误: {exc}"}
        finally:
            # 仅当请求被放弃（future 仍未完成，即超时/异常路径）时才兜底清理，
            # 避免在正常返回路径上把已交付的结果从 pending 中提前移除；
            # 正常路径的清理由 resolve() 在匹配时完成（set_result + pop）。
            # 注意：不使用 fut.set_running_or_notify_cancel() 判断，因为它会把
            # 尚未完成的 future 置为 RUNNING，导致后续 set_result 抛 InvalidStateError。
            if not fut.done():
                self._pending.pop(key, None)
                self._pending_owner.pop(key, None)

    def send_request(
        self, ws_manager: Any, user_id: str, payload: Dict[str, Any]
    ) -> Dict[str, Any]:
        """非阻塞发送一个工具执行请求（不等待响应）。

        hook 模式专用：本地前端托管分离进程执行长任务，进程退出后经
        ``tool_exec_response`` 回传，由 :meth:`register_hook` 挂的 done
        回调触发。发送失败返回 ``{"error": ...}``，不抛异常。

        :param ws_manager: WebSocketManager 实例
        :param user_id: 用户标识
        :param payload: 执行请求负载（必须含 tool_id / op 等）
        :return: ``{"success": True}`` 或 ``{"error": ...}``
        """
        if not self._has_frontend_executor(
            user_id, str(payload.get("team_id") or "")
        ):
            return {"error": "前端执行器未启用（本地或 SSH）"}
        tool_id = payload.get("tool_id", "")
        message = {
            "type": "tool_exec_request",
            "data": {"tool_id": tool_id, **payload},
        }
        try:
            loop = self._loop
            if loop is not None and loop.is_running():
                send_fut = asyncio.run_coroutine_threadsafe(
                    ws_manager.send_message(user_id, message), loop
                )
                send_fut.result(timeout=10.0)
            else:
                _run_async(ws_manager.send_message(user_id, message))
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "推送本地 hook 执行请求失败: %r (tool_id=%s, op=%s)",
                exc, tool_id, payload.get("op"),
            )
            return {"error": f"推送本地 hook 执行请求失败: {exc}"}
        return {"success": True}

    def register_hook(
        self,
        user_id: str,
        tool_id: str,
        on_done: Any,
        team_id: str = "",
    ) -> None:
        """登记一个 hook 任务的完成回调。

        把 ``tool_id`` 存入 ``_pending`` 并挂 done 回调，归属记录为
        ``(user_id, team_id)``：收到 ``tool_exec_response`` 时由既有
        :meth:`resolve` 触发；执行器注销（unregister / unregister_ssh）时
        按 (user_id, team_id) 粒度以异常触发，保证 hook 不会悬挂。
        """
        fut: "concurrent.futures.Future[Dict[str, Any]]" = concurrent.futures.Future()
        self._pending[tool_id] = fut
        self._pending_owner[tool_id] = (user_id, team_id)

        def _done(f: "concurrent.futures.Future[Dict[str, Any]]") -> None:
            try:
                result = f.result()
            except Exception as exc:  # noqa: BLE001
                result = {"error": f"本地执行器 hook 异常: {exc}"}
            try:
                on_done(result)
            except Exception:  # noqa: BLE001
                logger.exception("hook on_done 回调失败: tool_id=%s", tool_id)

        fut.add_done_callback(_done)

    def cancel_hook(
        self,
        ws_manager: Any,
        user_id: str,
        tool_id: str,
        pidfile: str = "",
    ) -> Dict[str, Any]:
        """通知前端终止一个 hook 任务（尽力终止）。

        发送 ``tool_exec_cancel`` 消息：本地模式前端据此 ``process.kill()``；
        SSH 模式前端据 ``pidfile`` 经远端 ``kill -TERM`` 终止后台进程。
        进程退出后前端仍会回传 ``tool_exec_response``，后端据此将任务标记
        为 cancelled。

        :param pidfile: SSH hook 的远端 pidfile 路径（空串表示本地模式）
        """
        message = {
            "type": "tool_exec_cancel",
            "data": {"tool_id": tool_id, "pidfile": pidfile},
        }
        try:
            loop = self._loop
            if loop is not None and loop.is_running():
                send_fut = asyncio.run_coroutine_threadsafe(
                    ws_manager.send_message(user_id, message), loop
                )
                send_fut.result(timeout=10.0)
            else:
                _run_async(ws_manager.send_message(user_id, message))
        except Exception as exc:  # noqa: BLE001
            logger.warning("推送取消 hook 请求失败: %r (tool_id=%s)", exc, tool_id)
            return {"error": f"推送取消 hook 请求失败: {exc}"}
        return {"success": True}

    def resolve(
        self,
        user_id: str,
        tool_id: str,
        result: Dict[str, Any],
        team_id: str = "",
    ) -> bool:
        """由 WS 接收处理调用：用前端返回结果唤醒等待方。

        :param user_id: 用户标识（响应归属校验：仅能唤醒本用户的 pending）
        :param tool_id: 执行请求标识（pending 字典键，前端原样回传）
        :param result: 前端返回的结果字典
        :param team_id: 可选归属校验：pending 记录了 team 且与传入不一致时拒绝
        :return: 是否成功匹配到待响应请求
        """
        fut = self._pending.get(tool_id)
        if fut is None or fut.done():
            return False
        owner = self._pending_owner.get(tool_id)
        if owner is not None and owner[0] != user_id:
            return False
        if team_id and owner is not None and owner[1] and owner[1] != team_id:
            return False
        fut.set_result(result)
        self._pending.pop(tool_id, None)
        self._pending_owner.pop(tool_id, None)
        return True
