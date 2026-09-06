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

# 本地执行请求默认超时（秒）。注意：它只是"无进度时的最大容忍窗口"——
# 前端周期性上报 tool_exec_progress（默认每 10s 一次）后会自动续期，真正在
# 执行的长任务（grep 数分钟 / terminal 360s+ / 测试脚本）不受该上限误杀。
_LOCAL_EXEC_TIMEOUT = 120

# 响应等待轮询切片（秒）：等待以该粒度刷新"最近活动时间"，前端在执行中
# 周期性上报 tool_exec_progress 时能及时续期，而不是一次性 long sleep 到死。
_WAIT_SLICE_SECONDS = 10.0
# 卡死判定窗口（秒）：距"最近一次进度上报（无进度时=请求发出时刻）"超过该
# 值仍无结果，判定该请求疑似卡死（前端失联 / 心跳中断），不等满默认 120s
# 就快速失败并触发自动停用——避免"发消息卡大半天"。区分"真卡死"与"只是
# 慢"的关键：只要前端在干活就会周期性上报进度（见 tool_exec_progress），
# 有进度上报即无限续期；只有进度中断（或从未上报）才滑出窗口判死。
_STALL_WITHOUT_PROGRESS_SECONDS = 60.0
# （诊断 / 回归测试用）执行器"冷热"状态阈值：仅供 _is_cold 冷热展示；
# 实际等待期的"活动/卡死"判定已由 tool_exec_progress 进度续期取代
# （见 _STALL_WITHOUT_PROGRESS_SECONDS 与 request 的切片轮询逻辑）。
_PROBE_GAP_SECONDS = 60.0
# 连续响应超时（含卡死判定）达到该次数后自动停用该 (user_id, team_id) 的
# 前端执行器（注销运行时注册，使请求快速失败并推送 registration_lost 供前端
# 复位后重注册自愈；已锁定 local/ssh 的 agents.mode 不随之改变，绝不静默回退
# 云端执行），防止后续请求继续逐个空等并占用线程池线程导致其他请求被阻塞。
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
        # (user_id, team_id) -> 最近一次成功往返时间戳（日志诊断 / 测试用；
        # 卡死判定的"活动"依据已由 tool_exec_progress 进度时间戳 _progress_at 取代）
        self._last_ok: Dict[Tuple[str, str], float] = {}
        # (user_id, team_id) -> 连续响应超时次数（达到阈值自动停用执行器）
        self._consecutive_timeouts: Dict[Tuple[str, str], int] = {}
        # tool_id -> 最近一次 tool_exec_progress 到达时间（时间戳）。
        # 请求等待循环据此区分"正在工作（进度续期）"与"疑似卡死（进度中断）"。
        self._progress_at: Dict[str, float] = {}
        # 后台推送（registration_lost 通知）的 in-flight future 集合：
        # run_coroutine_threadsafe 的 future 需持有引用，防止被 GC 静默取消
        self._send_futs: set = set()

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
            self._progress_at.pop(key, None)
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
        """执行器是否处于"冷"状态（诊断 / 回归测试用）。

        仅基于最近一次成功往返时间展示冷热；请求等待期的快速失败判定不再
        依赖本方法（已由 tool_exec_progress 进度续期 + 卡死窗口取代）。
        """
        return (
            time.time() - self._last_ok.get((user_id, team_id), 0.0)
            > _PROBE_GAP_SECONDS
        )

    def _disable_ssh_mode(self, user_id: str, team_id: str) -> None:
        """注销该 (user_id, team_id) 的 SSH 持久化配置（运行时侧）。

        使未锁定（agents.mode 为空）的 team 在失联后回落运行时判定（cloud）；
        已锁定 ``ssh`` 的 agent 模式取自 agents.mode，不受本注销影响（仍等
        前端重注册自愈）。state.ssh_manager 未初始化（单测环境）时跳过。
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

    def _notify_registration_lost(
        self,
        ws_manager: Any,
        user_id: str,
        team_id: str,
        mode: str,
    ) -> None:
        """向该用户仍存活的连接推送 ``registration_lost``（尽力而为）。

        后端因内部原因（连续超时自动停用 / WS 断连清理等）注销执行器注册时
        调用：前端据此把该 team 的 registered 复位为 false，待下次动作（发
        消息 / AskUserQuestion 作答等）经 ensureTeam 自动重注册自愈。已无
        活跃连接 / ws_manager 不可用 / 推送失败时静默降级为 warning 日志。
        """
        if ws_manager is None:
            return
        message = {
            "type": "registration_lost",
            "data": {"team_id": team_id, "mode": mode},
        }
        try:
            loop = self._loop
            if loop is not None and loop.is_running():
                fut = asyncio.run_coroutine_threadsafe(
                    ws_manager.send_message(user_id, message), loop
                )
                self._send_futs.add(fut)
                fut.add_done_callback(self._send_futs.discard)
            else:
                _run_async(ws_manager.send_message(user_id, message))
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "推送 registration_lost 失败: user_id=%s team_id=%s mode=%s (%s)",
                user_id, team_id, mode, exc,
            )

    def _register_timeout(
        self, user_id: str, team_id: str = "", ws_manager: Any = None
    ) -> None:
        """记录一次响应超时；连续超时达到阈值时自动停用该 team 的执行器。

        停用范围：该 (user_id, team_id) 的 local 与 SSH 注册一并注销（B2：
        SSH 失联同样快速失败），并注销 SSH 持久化配置使未锁定的 team 后续
        按"无执行器"判定；已锁定 local/ssh 的 agents.mode 不改变，绝不静默
        回退云端执行。team_id 未知（空串，兼容未携带 team_id 的历史调用）
        时回退为停用该用户全部注册。停用后向仍存活的连接推送
        ``registration_lost``，前端复位 registered 后于下次动作自动重注册。
        前端重新注册（register / register_ssh）时计数清零自动恢复。
        """
        key = (user_id, team_id)
        self._consecutive_timeouts[key] = (
            self._consecutive_timeouts.get(key, 0) + 1
        )
        if self._consecutive_timeouts[key] < _MAX_CONSECUTIVE_TIMEOUTS:
            return
        logger.warning(
            "前端执行器连续 %d 次响应超时，自动停用执行器注册（模式锁定不变，"
            "等待前端重注册恢复）: user_id=%s team_id=%r",
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
                    self._notify_registration_lost(ws_manager, user_id, t, "local")
                if t in (self._ssh_users.get(user_id) or set()):
                    self.unregister_ssh(user_id, t)
                    # SSH 持久化配置一并注销 → 未锁定 team 的 resolve_mode 回落
                    # cloud（已锁定 ssh 的 agent 仍等前端重注册恢复）
                    self._disable_ssh_mode(user_id, t)
                    self._notify_registration_lost(ws_manager, user_id, t, "ssh")
            except Exception:  # noqa: BLE001
                pass
        # 停用后计数清零
        self._consecutive_timeouts[key] = 0

    def note_progress(
        self,
        user_id: str,
        tool_id: str,
        team_id: str = "",
    ) -> bool:
        """由 WS 接收处理调用：记录一次工具执行进度（刷新活动时间戳）。

        前端在执行长任务期间周期性上报 ``tool_exec_progress``，等待该请求的
        :meth:`request` 据此区分"正在工作（进度续期，允许 360s+）"与"疑似
        卡死（进度中断，滑出窗口判死）"。仅在请求确实待响应（pending 存在
        且归属该用户）时刷新，乱报进度不产生副作用。
        """
        fut = self._pending.get(tool_id)
        if fut is None or fut.done():
            return False
        owner = self._pending_owner.get(tool_id)
        # 归属校验：只有请求归属 user_id 本人才能续期其卡死窗口，防止跨用户
        # 续期。pending 存在但 owner 缺失说明内部状态不一致，按"非本用户"
        # 处理（fail-closed）：宁可拒绝续期也不放行。
        if owner is None or owner[0] != user_id:
            return False
        self._progress_at[tool_id] = time.time()
        return True

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
        # 等待响应并做"卡死 vs 慢"检测：以切片轮询取代一次性 long sleep。
        # 判据：距"最近一次活动"（请求发出 或 tool_exec_progress 上报）超过
        # stall 窗口仍无结果 → 判定疑似卡死，快速失败并触发自动停用计数；
        # 前端在执行中周期性上报进度时无限续期——真正在干活的长任务
        # （grep 数分钟 / terminal 360s+）不会被等待上限误杀，而失联/冻结
        # 的前端（无任何进度上报）会在窗口内尽快暴露而不是空等满 120s。
        stall = min(float(timeout), _STALL_WITHOUT_PROGRESS_SECONDS)
        last_activity = time.time()
        try:
            while True:
                # 每次切片结束都在循环顶部重新读取最新进度时间戳后再判窗：
                # 防止"切片粒度(~10s) 与前端上报周期(~10s) 恰好对齐"时，读取
                # 永远赶在刚写入之前，导致有进度也误判卡死。_progress_at 只在
                # resolve/超时/清理时才移除，错过一个切片也会在下个切片读到。
                progress_ts = self._progress_at.get(key, 0.0)
                if progress_ts > last_activity:
                    last_activity = progress_ts
                if time.time() - last_activity >= stall:
                    # 滑出活动窗口：疑似卡死（从未上报进度 / 进度已中断）
                    raise concurrent.futures.TimeoutError()
                wait_for = min(
                    _WAIT_SLICE_SECONDS,
                    max(0.0, stall - (time.time() - last_activity)),
                )
                try:
                    result = fut.result(timeout=wait_for)
                except concurrent.futures.TimeoutError:
                    # 切片超时：回到循环顶部检查最新进度（续期或滑窗判死）
                    continue
                if isinstance(result, BaseException):
                    raise result
                # 成功往返：记录存活时间并清零连续超时计数
                self._last_ok[(user_id, team_id)] = time.time()
                self._consecutive_timeouts[(user_id, team_id)] = 0
                self._progress_at.pop(key, None)
                return result if isinstance(result, dict) else {"error": str(result)}
        except concurrent.futures.TimeoutError:
            # 疑似卡死：清理并快速失败（连带自动停用计数，见 _register_timeout）
            self._pending.pop(key, None)
            self._pending_owner.pop(key, None)
            self._progress_at.pop(key, None)
            # 取消可能仍在排队的发送协程，避免极晚投递导致响应无人匹配
            if send_fut is not None and not send_fut.done():
                send_fut.cancel()
            logger.warning(
                "本地执行请求疑似卡死(%.1fs 无结果且无进度上报): "
                "tool_id=%s op=%s",
                stall, tool_id, payload.get("op"),
            )
            self._register_timeout(user_id, team_id, ws_manager)
            return {"error": "本地执行器响应超时（疑似卡死，执行器已自动停用/待重注册）"}
        except Exception as exc:  # noqa: BLE001
            # 其它异常（如执行器注销 set_exception / 传输层错误）：快速失败
            self._pending.pop(key, None)
            self._pending_owner.pop(key, None)
            self._progress_at.pop(key, None)
            logger.warning("本地执行请求异常: %r (tool_id=%s)", exc, tool_id)
            return {"error": f"本地执行器错误: {exc}"}

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
        self._progress_at.pop(tool_id, None)
        return True
