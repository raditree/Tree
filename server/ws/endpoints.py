"""WebSocket 端点：JWT 鉴权、消息路由、反向执行通道。

自 main.py 迁出（P0 组件化重组）。承载实时消息：
- ``user_message``：用户发送消息（经 agent.chat 统一投递）
- ``heartbeat``：心跳检测
- ``stop``：取消指定 agent 的进行中任务
- ``user_answer`` / ``cancel_question``：AskUserQuestion 工具应答
- ``register_local_executor`` / ``unregister_local_executor``：本地执行器注册
- ``tool_exec_response``：前端工具执行结果回传
- ``plugin_host_event``：宿主通道上行（二期 M2；退出上报等）
"""
import asyncio
import json
import logging
from typing import Any, Dict

import jwt
from fastapi import FastAPI, WebSocket, WebSocketDisconnect

import state
from agent.chat import (
    USER_AGENT_ID,
    _active_tasks,
    _bind_main_loop,
    _cancel_active_task,
    _compacting_tasks,
    _dispatch_user_message,
    _stop_agent_tree,
    resume_after_answer,
)
from config.config import get_config
from data.conversation_store import (
    get_pending_question,
    mark_pending_answered,
    mark_pending_cancelled,
)
from data.session_cache import clear_user_agent
from plugin import (
    plugin_host_event,
    plugin_host_mark_lost,
    plugin_host_reconcile,
)
from ws.auth import TokenRevokedError, verify_token

logger = logging.getLogger(__name__)


def _extract_token(ws: WebSocket) -> str:
    """从 WebSocket 中提取 JWT token。

    优先从查询参数 ``token`` 获取，其次从 ``Authorization`` header 获取。
    """
    token = ws.query_params.get("token", "")
    if token:
        return token
    auth_header = ws.headers.get("authorization", "")
    if auth_header.startswith("Bearer "):
        return auth_header[len("Bearer "):].strip()
    return ""


def _persist_agent_mode(user_id: str, team_id: str, mode: str) -> None:
    """把执行器注册/注销消息表达的用户意图写回 agents.mode（尽力而为）。

    - 注册 local/ssh → 写回 "local"/"ssh"：断连/超时等瞬时失联后模式仍锁定，
      绝不静默回退云端；
    - 显式注销（切回 cloud）→ 写回 "cloud"：该 agent 后续消息按云端执行。
    仅记录意图，不影响注册/注销本身的成功判定；DB 异常时记 warning 放行。
    """
    try:
        from data.agent_store import set_agent_mode

        set_agent_mode(user_id, team_id, mode)
    except Exception as exc:  # noqa: BLE001
        logger.warning(
            "持久化运行模式失败（忽略）: user_id=%s team_id=%s mode=%s err=%s",
            user_id, team_id, mode, exc,
        )


def register_ws(app: FastAPI) -> None:
    """将 /ws 端点挂载到 FastAPI 应用。"""

    @app.websocket("/ws")
    async def websocket_endpoint(ws: WebSocket):
        """WebSocket 端点，承载实时消息（agent 对话、状态变更、同步进度等）。

        消息格式：``{"type": "message_type", "data": {...}}``

        推送的消息类型：
        - ``msg_start`` / ``msg_chunk`` / ``msg_end``：流式文本段
        - ``tool_start`` / ``tool_end``：工具调用卡片
        - ``agent_status``：agent 状态变更
        - ``error``：错误消息
        - ``heartbeat``：心跳响应
        """
        # 1. 验证 JWT token
        token = _extract_token(ws)
        if not token:
            await ws.close(code=1008, reason="缺少 token")
            return
        try:
            payload = verify_token(token)
        except jwt.ExpiredSignatureError:
            await ws.close(code=1008, reason="token 已过期")
            return
        except TokenRevokedError:
            await ws.close(code=1008, reason="token 已撤销")
            return
        except jwt.InvalidTokenError:
            await ws.close(code=1008, reason="无效的 token")
            return

        user = payload.get("user", {})
        user_id = user.get("openid", "")
        if not user_id:
            await ws.close(code=1008, reason="无效的用户信息")
            return

        # 2. 接受连接并存储（每条连接分配 connection_id，供断连精确清理）
        connection_id = await state.ws_manager.connect(user_id, ws)
        # 本连接运行在主事件循环线程：绑定循环引用，供消息分发层（同步
        # 函数，可能运行在工具线程/线程池）经 run_coroutine_threadsafe
        # 线程安全推送 WS 消息（session_created / 总结反向推送等）。
        _bind_main_loop()
        # 本连接注册过的执行器 (mode, team_id) 列表：断连时等价前端主动
        # unregister，避免连接死亡后执行器幽灵注册（工具请求继续空等）。
        conn_regs: list = []
        # 2.1 重连状态同步：将当前仍有进行中任务的 agent/会话状态补推给前端，
        #     保证前端重启（WebSocket 重连）后"工作中"标识与"停止"按钮能恢复显示。
        for (active_uid, active_agent_id, active_session_id) in list(_active_tasks.keys()):
            if active_uid == user_id:
                await state.ws_manager.send_message(
                    user_id,
                    {
                        "type": "agent_status",
                        "data": {
                            "agent_id": active_agent_id,
                            "status": "working",
                            "session_id": active_session_id,
                        },
                    },
                )
        # 2.2 补推进行中的上下文压缩状态（compacting）：compress 是长时间
        #     操作（LLM 总结），重连后前端据此恢复「压缩中」标识。
        for (compact_uid, compact_agent_id, compact_session_id) in list(
            _compacting_tasks
        ):
            if compact_uid == user_id:
                await state.ws_manager.send_message(
                    user_id,
                    {
                        "type": "agent_status",
                        "data": {
                            "agent_id": compact_agent_id,
                            "status": "compacting",
                            "session_id": compact_session_id,
                        },
                    },
                )
        try:
            # 3. 循环接收消息并处理
            while True:
                message_text = await ws.receive_text()
                try:
                    message = json.loads(message_text)
                except json.JSONDecodeError:
                    await state.ws_manager.send_message(
                        user_id,
                        {"type": "error", "data": {"message": "消息格式错误，需为 JSON"}},
                    )
                    continue

                if not isinstance(message, dict):
                    await state.ws_manager.send_message(
                        user_id,
                        {"type": "error", "data": {"message": "消息需为 JSON 对象"}},
                    )
                    continue

                msg_type = message.get("type")
                data: Dict[str, Any] = message.get("data", {})
                if not isinstance(data, dict):
                    data = {}
                # 兼容两种字段位置：优先 data 子对象，回退到顶层字段
                # 注意必须保留 session_id：前端 user_message 将字段放在顶层，
                # 若丢弃 session_id 会回退到默认会话，造成跨会话串扰。
                # active（Task 7.1）：主动/被动标记同样透传（缺省由
                # _dispatch_user_message 兜底为 true）。
                if not data:
                    data = {
                        k: message.get(k)
                        for k in ("agent_id", "content", "attachments",
                                  "session_id", "active")
                        if message.get(k) is not None
                    }

                # 4. 根据消息类型分发处理
                if msg_type == "heartbeat":
                    await state.ws_manager.handle_heartbeat(user_id)
                elif msg_type == "user_message":
                    # ID 存在性校验：缺 agent_id（team_id 由其派生）即拒绝，
                    # 不以空串/默认值降级继续。
                    if not data.get("agent_id"):
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "error",
                                "data": {
                                    "message": "user_message 缺少 agent_id，已拒绝"
                                },
                            },
                        )
                        continue
                    # 通过 broker 投递，working 时在 tool_call 间隙切入，
                    # idle 时立即处理（不阻塞 WebSocket 循环，便于后续消息切入）。
                    # dispatch 内部可能经反向 WS 读 roster（阻塞），await 保证其在线程池执行
                    await _dispatch_user_message(user_id, data)
                elif msg_type == "stop":
                    # 停止按钮：级联停止 TOP agent + 其下全部成员（或单成员）。
                    # 取消事件置位 + 清空 broker 排队消息 + 复位持久化
                    # work_status + 推送 idle，使 UI 立即停止、不复活。
                    agent_id = data.get("agent_id", "")
                    session_id = data.get("session_id")
                    if agent_id:
                        result = await _stop_agent_tree(
                            user_id, agent_id, session_id
                        )
                        if result.get("stopped"):
                            await state.ws_manager.send_message(
                                user_id,
                                {
                                    "type": "agent_status",
                                    "data": {
                                        "agent_id": agent_id,
                                        "status": "stopping",
                                        "session_id": session_id,
                                    },
                                },
                            )
                        else:
                            await state.ws_manager.send_message(
                                user_id,
                                {
                                    "type": "error",
                                    "data": {
                                        "message": "没有进行中的任务可停止",
                                    },
                                },
                            )
                    else:
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "error",
                                "data": {"message": "缺少 agent_id"},
                            },
                        )
                elif msg_type == "user_answer":
                    # 用户回答 AskUserQuestion 工具的问题：按 qid 查存活态
                    # 提问，回写 answered 状态并触发该 agent 唤醒续跑。
                    qid = data.get("question_id", "")
                    answer = data.get("answer")
                    pending = get_pending_question(qid)
                    if pending is None or pending["status"] != "pending":
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "error",
                                "data": {"message": "没有等待回答的问题"},
                            },
                        )
                        continue
                    # 归属校验：仅提问所属用户可回答
                    if pending.get("user_id") != user_id:
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "error",
                                "data": {"message": "无权操作该提问"},
                            },
                        )
                        continue
                    mark_pending_answered(qid, str(answer or "") if answer is not None else "")
                    await state.ws_manager.send_message(
                        user_id,
                        {
                            "type": "ask_user_question_resolved",
                            "data": {"id": qid, "session_id": pending["session_id"]},
                        },
                    )
                    # 唤醒：注入答案并重新触发该 agent 执行（异步，不阻塞 WS）
                    asyncio.create_task(
                        resume_after_answer(
                            pending["user_id"],
                            pending["agent_id"],
                            pending["team_id"],
                            pending["session_id"],
                            str(answer or "") if answer is not None else "",
                            pending["is_member"],
                            # 原发送方：成员续跑后总结精确回发到"谁发给它的那位"；
                            # 旧数据空串（用户直发）归一为 USER_AGENT_ID（读取侧等效）。
                            pending.get("sender_id") or USER_AGENT_ID,
                        )
                    )
                elif msg_type == "cancel_question":
                    # 用户取消 AskUserQuestion 工具的问题
                    qid = data.get("question_id", "")
                    pending = get_pending_question(qid)
                    if pending is None or pending["status"] != "pending":
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "error",
                                "data": {"message": "没有等待回答的问题"},
                            },
                        )
                    elif pending.get("user_id") != user_id:
                        # 归属校验：仅提问所属用户可取消
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "error",
                                "data": {"message": "无权操作该提问"},
                            },
                        )
                    else:
                        mark_pending_cancelled(qid)
                elif msg_type == "register_local_executor":
                    # 前端注册本地执行器：该顶部 agent 的工具调用转发到前端本地执行
                    base_dir = data.get("base_dir")
                    # ID 存在性校验：缺 team_id 即拒绝（不以 agent_id/用户标记降级）
                    team_id = str(data.get("team_id") or "")
                    if not team_id:
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "register_local_executor_ack",
                                "data": {
                                    "success": False,
                                    "message": "register_local_executor 缺少 team_id",
                                },
                            },
                        )
                        continue
                    # 互斥校验：local 与 ssh 不可共存（spec「三模式运行」场景）
                    from io_.mode_resolver import check_exclusive

                    ok, reason = check_exclusive(user_id, team_id, "local")
                    if not ok:
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "register_local_executor_ack",
                                "data": {"success": False, "message": reason},
                            },
                        )
                        continue
                    state.local_executor.register(
                        user_id, team_id, base_dir, connection_id
                    )
                    # 记录到本连接：断连时等价 unregister，避免幽灵注册
                    conn_regs.append({"mode": "local", "team_id": team_id})
                    # 清除该 agent 的会话缓存：即使此前会话已绑定云端工具，
                    # 下次发消息会重建会话并按本地模式重新绑定工具
                    clear_user_agent(user_id, team_id)
                    # 注册即表达"该 agent 走本地执行"的用户意图：写回 agents.mode，
                    # 断连/超时等瞬时失联后 resolve_mode 仍锁定 local（不静默回退云端）
                    _persist_agent_mode(user_id, team_id, "local")
                    # 宿主通道（二期 M2；契约 §14.3-3）：执行器（重）注册后
                    # best-effort 对账回收失联会话（总开关关闭时零副作用）
                    plugin_host_reconcile(user_id, team_id)
                    # 注册成功回应
                    await state.ws_manager.send_message(
                        user_id,
                        {
                            "type": "register_local_executor_ack",
                            "data": {"success": True},
                        },
                    )
                elif msg_type == "unregister_local_executor":
                    # 前端注销某个顶部 agent 的本地执行器：该 agent 恢复云端执行
                    # ID 存在性校验：缺 team_id 即拒绝
                    team_id = str(data.get("team_id") or "")
                    if not team_id:
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "unregister_local_executor_ack",
                                "data": {
                                    "success": False,
                                    "message": "unregister_local_executor 缺少 team_id",
                                },
                            },
                        )
                        continue
                    if not state.local_executor.unregister(
                        user_id, team_id, connection_id
                    ):
                        # 该 team 的注册已归属同用户其他连接（另一实例已接管）：
                        # 本连接的注销不影响它，也不得把 agents.mode 改成 cloud
                        # （否则会静默关掉仍在生效的本地模式）。
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "unregister_local_executor_ack",
                                "data": {
                                    "success": False,
                                    "message": "该 agent 的本地执行器已由其他连接接管",
                                },
                            },
                        )
                        continue
                    # 该 team 的注册不再归属本连接（防重复清理）
                    conn_regs = [
                        r for r in conn_regs
                        if not (r["mode"] == "local" and r["team_id"] == team_id)
                    ]
                    # 显式注销即用户把该 agent 切回云端：更新模式锁定并清会话
                    # 缓存（下次消息重建会话并按 cloud 模式绑定工具）。断连清理
                    # 路径（finally）不写 mode，避免前端瞬时掉线把已锁定 local
                    # 误改成 cloud 而静默回退云端执行。
                    _persist_agent_mode(user_id, team_id, "cloud")
                    clear_user_agent(user_id, team_id)
                    await state.ws_manager.send_message(
                        user_id,
                        {
                            "type": "unregister_local_executor_ack",
                            "data": {"success": True},
                        },
                    )
                elif msg_type == "register_ssh_executor":
                    # 前端注册 SSH 执行器：该顶部 agent 的工具调用转发到远端主机执行。
                    # 先互斥校验（local 与 ssh 不可共存），再测试连接，成功后持久化。
                    # ID 存在性校验：缺 team_id 即拒绝
                    team_id = str(data.get("team_id") or "")
                    if not team_id:
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "register_ssh_executor_ack",
                                "data": {
                                    "success": False,
                                    "message": "register_ssh_executor 缺少 team_id",
                                },
                            },
                        )
                        continue
                    from io_.mode_resolver import check_exclusive

                    ok, reason = check_exclusive(user_id, team_id, "ssh")
                    if not ok:
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "register_ssh_executor_ack",
                                "data": {"success": False, "message": reason},
                            },
                        )
                        continue
                    # 数据最小化：后端不存储/消费 SSH 密码（连接由前端发起），
                    # 在边界处即剔除，避免密码经 WS 传送到后端。
                    ssh_cfg = {
                        k: v
                        for k, v in data.get("config", {}).items()
                        if k != "password"
                    }
                    ok, reason = state.ssh_manager.register(
                        user_id, team_id, ssh_cfg
                    )
                    if not ok:
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "register_ssh_executor_ack",
                                "data": {"success": False, "message": reason},
                            },
                        )
                        continue
                    # 登记到前端执行器客户端：SSH 模式工具调用经反向 WS 委托前端执行
                    state.local_executor.register_ssh(
                        user_id, team_id, connection_id
                    )
                    # 记录到本连接：断连时等价 unregister，避免幽灵注册
                    conn_regs.append({"mode": "ssh", "team_id": team_id})
                    # 清除会话缓存：下次发消息重建会话并按 SSH 模式绑定工具
                    clear_user_agent(user_id, team_id)
                    # 注册即表达"该 agent 走 SSH 执行"的用户意图：写回 agents.mode，
                    # 断连/超时等瞬时失联后 resolve_mode 仍锁定 ssh（不静默回退云端）
                    _persist_agent_mode(user_id, team_id, "ssh")
                    # 宿主通道（二期 M2；契约 §14.3-3）：执行器（重）注册后
                    # best-effort 对账回收失联会话（总开关关闭时零副作用）
                    plugin_host_reconcile(user_id, team_id)
                    # 附带 app.yaml 下发的单连接并发上限：前端据此限制同一 SSH
                    # 连接上同时执行的工具数（超出排队），改 app.yaml 后重开 SSH
                    # 模式即生效，无需重新构建前端。
                    ssh_cfg_section = get_config().get("ssh") or {}
                    try:
                        ssh_max_concurrent = int(
                            ssh_cfg_section.get("max_concurrent_per_team") or 0
                        )
                    except (TypeError, ValueError):
                        ssh_max_concurrent = 0
                    await state.ws_manager.send_message(
                        user_id,
                        {
                            "type": "register_ssh_executor_ack",
                            "data": {
                                "success": True,
                                # 0/缺失表示"不覆盖"，前端保持默认 42
                                "max_concurrent_per_team":
                                    ssh_max_concurrent or None,
                            },
                        },
                    )
                elif msg_type == "unregister_ssh_executor":
                    # 前端注销某个顶部 agent 的 SSH 执行器：该 agent 恢复云端执行
                    # ID 存在性校验：缺 team_id 即拒绝
                    team_id = str(data.get("team_id") or "")
                    if not team_id:
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "unregister_ssh_executor_ack",
                                "data": {
                                    "success": False,
                                    "message": "unregister_ssh_executor 缺少 team_id",
                                },
                            },
                        )
                        continue
                    if not state.local_executor.unregister_ssh(
                        user_id, team_id, connection_id
                    ):
                        # 同 local：注册已归属同用户其他连接，不得清掉 ssh_manager
                        # 配置、也不得把 agents.mode 改成 cloud。
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "unregister_ssh_executor_ack",
                                "data": {
                                    "success": False,
                                    "message": "该 agent 的 SSH 执行器已由其他连接接管",
                                },
                            },
                        )
                        continue
                    state.ssh_manager.unregister(user_id, team_id)
                    # 该 team 的注册不再归属本连接（防重复清理）
                    conn_regs = [
                        r for r in conn_regs
                        if not (r["mode"] == "ssh" and r["team_id"] == team_id)
                    ]
                    # 显式注销即用户把该 agent 切回云端：更新模式锁定并清会话缓存
                    _persist_agent_mode(user_id, team_id, "cloud")
                    clear_user_agent(user_id, team_id)
                    await state.ws_manager.send_message(
                        user_id,
                        {
                            "type": "unregister_ssh_executor_ack",
                            "data": {"success": True},
                        },
                    )
                elif msg_type == "tool_exec_response":
                    # 前端返回工具执行结果：唤醒等待的后端请求
                    # 配对标识：user_id（token）+ team_id（可缺省，后端生成的
                    # tool_id 自带 user:team:uuid 前缀；缺省时按 tool_id 匹配）
                    tool_id = data.get("tool_id", "")
                    result = data.get("result", {})
                    team_id = str(data.get("team_id") or "")
                    if not tool_id:
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "error",
                                "data": {"message": "tool_exec_response 缺少 tool_id"},
                            },
                        )
                        continue
                    resolved = state.local_executor.resolve(
                        user_id, tool_id, result, team_id=team_id
                    )
                    if not resolved:
                        logger.warning(
                            "tool_exec_response 未匹配到待处理请求: user_id=%s team_id=%s tool_id=%s",
                            user_id,
                            team_id,
                            tool_id,
                        )
                elif msg_type == "tool_exec_progress":
                    # 前端回报工具执行进度：刷新该 tool 的"最近活动"时间戳，
                    # 使后端 request() 的卡死判定（_STALL_WITHOUT_PROGRESS）得以
                    # 续期——区分"正在执行的长任务（允许 360s+）"与"真卡死/
                    # 失联（无进度滑出窗口判死）"。仅对待响应的 pending 生效，
                    # 乱报/未知 tool_id 被 note_progress 拒绝，不产生副作用。
                    tool_id = data.get("tool_id", "")
                    if not tool_id:
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "error",
                                "data": {"message": "tool_exec_progress 缺少 tool_id"},
                            },
                        )
                        continue
                    team_id = str(data.get("team_id") or "")
                    noted = state.local_executor.note_progress(
                        user_id, tool_id, team_id=team_id
                    )
                    logger.debug(
                        "tool_exec_progress: user_id=%s team_id=%s tool_id=%s noted=%s",
                        user_id, data.get("team_id", ""), tool_id, noted,
                    )
                elif msg_type == "plugin_host_event":
                    # 宿主通道上行（二期 M2；契约 §14.3-4）：退出上报等。
                    # 独立命名空间分支（只增不改）；未启用/未知会话静默忽略。
                    plugin_host_event(user_id, data)
                else:
                    await state.ws_manager.send_message(
                        user_id,
                        {"type": "error", "data": {"message": f"未知消息类型: {msg_type}"}},
                    )
        except WebSocketDisconnect:
            # 客户端主动断开连接
            pass
        finally:
            # 1) 从连接表移除本连接（按 connection_id 精确移除，不影响同用户
            #    其他并行连接）
            state.ws_manager.disconnect_by_id(user_id, connection_id)
            # 2) 断连清理执行器注册：本连接注册过的 (mode, team_id) 一并注销，
            #    与前端主动 unregister 等价，避免幽灵注册（工具请求继续空等）。
            #    注意：此处只清运行时注册、**不写 agents.mode**——本地/SSH 是
            #    用户对该 agent 的持久化意图，瞬时断连不得把它静默改成 cloud
            #    （否则前端重连前的后台任务会悄悄改跑云端执行）。
            #    归属校验：该 team 的注册已由同用户其他连接接管时跳过（见
            #    LocalExecutorClient._owns_executor），不清掉生效中的注册。
            cleared_teams: list = []
            for reg in conn_regs:
                try:
                    if reg["mode"] == "local":
                        cleared = state.local_executor.unregister(
                            user_id, reg["team_id"], connection_id
                        )
                    else:
                        cleared = state.local_executor.unregister_ssh(
                            user_id, reg["team_id"], connection_id
                        )
                    if not cleared:
                        # 该 team 的注册已归属其他连接（其他实例已接管）：
                        # 本连接断连不影响它，也不需要通知前端"注册已丢失"。
                        continue
                    cleared_teams.append(reg["team_id"])
                    if reg["mode"] == "ssh" and state.ssh_manager is not None:
                        # 仅在本连接确实注销成功后才清 SSH 持久化配置：注册已
                        # 被其他连接接管时必须保留（与 unregister_ssh_executor
                        # 分支同一归属原则），否则会误清接管连接的 SSH 配置。
                        state.ssh_manager.unregister(user_id, reg["team_id"])
                    logger.info(
                        "WS 断连清理执行器注册: user_id=%s team_id=%s mode=%s connection_id=%s",
                        user_id, reg["team_id"], reg["mode"], connection_id,
                    )
                    # 3) 通知该用户仍存活的连接：该 team 的执行器注册已丢失。
                    #    前端据此复位 registered=false，待下次动作经 ensureTeam
                    #    自动重注册自愈（本地/SSH 一致）。
                    if state.ws_manager.connections.get(user_id):
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "registration_lost",
                                "data": {
                                    "mode": reg["mode"],
                                    "team_id": reg["team_id"],
                                },
                            },
                        )
                except Exception:  # noqa: BLE001
                    logger.exception(
                        "WS 断连清理执行器注册失败: user_id=%s reg=%r",
                        user_id, reg,
                    )
            # 4) 宿主通道（二期 M2；契约 §14.3-3）：本连接注销成功的 team
            #    会话标记失联（不 kill；前端重连/执行器重注册后对账回收）
            if cleared_teams:
                plugin_host_mark_lost(user_id, cleared_teams)


__all__ = ["register_ws"]
