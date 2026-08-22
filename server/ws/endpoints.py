"""WebSocket 端点：JWT 鉴权、消息路由、反向执行通道。

自 main.py 迁出（P0 组件化重组）。承载实时消息：
- ``user_message``：用户发送消息（经 agent.chat 统一投递）
- ``heartbeat``：心跳检测
- ``stop``：取消指定 agent 的进行中任务
- ``user_answer`` / ``cancel_question``：AskUserQuestion 工具应答
- ``register_local_executor`` / ``unregister_local_executor``：本地执行器注册
- ``tool_exec_response``：前端工具执行结果回传
"""
import json
import logging
from typing import Any, Dict

import jwt
from fastapi import FastAPI, WebSocket, WebSocketDisconnect

import state
from agent.chat import (
    _active_tasks,
    _cancel_active_task,
    _dispatch_user_message,
)
from data.session_cache import clear_user_agent
from tool.ask_question_tool import get_ask_tool
from ws.auth import verify_token

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
        except jwt.InvalidTokenError:
            await ws.close(code=1008, reason="无效的 token")
            return

        user = payload.get("user", {})
        user_id = user.get("openid", "")
        if not user_id:
            await ws.close(code=1008, reason="无效的用户信息")
            return

        # 2. 接受连接并存储
        await state.ws_manager.connect(user_id, ws)
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
                if not data:
                    data = {
                        k: message.get(k)
                        for k in ("agent_id", "content", "attachments")
                        if message.get(k) is not None
                    }

                # 4. 根据消息类型分发处理
                if msg_type == "heartbeat":
                    await state.ws_manager.handle_heartbeat(user_id)
                elif msg_type == "user_message":
                    # 通过 broker 投递，working 时在 tool_call 间隙切入，
                    # idle 时立即处理（不阻塞 WebSocket 循环，便于后续消息切入）。
                    # dispatch 内部可能经反向 WS 读 roster（阻塞），await 保证其在线程池执行
                    await _dispatch_user_message(user_id, data)
                elif msg_type == "stop":
                    # 停止按钮：请求取消指定 agent/会话的进行中任务
                    agent_id = data.get("agent_id", "")
                    session_id = data.get("session_id")
                    if agent_id and _cancel_active_task(user_id, agent_id, session_id):
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
                                "data": {"message": "没有进行中的任务可停止"},
                            },
                        )
                elif msg_type == "user_answer":
                    # 用户回答 AskUserQuestion 工具的问题
                    qid = data.get("question_id", "")
                    answer = data.get("answer")
                    ask_tool = get_ask_tool(user_id)
                    if ask_tool is not None and qid:
                        ask_tool.resolve(qid, answer)
                    else:
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "error",
                                "data": {"message": "没有等待回答的问题"},
                            },
                        )
                elif msg_type == "cancel_question":
                    # 用户取消 AskUserQuestion 工具的问题
                    qid = data.get("question_id", "")
                    ask_tool = get_ask_tool(user_id)
                    if ask_tool is not None and qid:
                        ask_tool.cancel(qid)
                    else:
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "error",
                                "data": {"message": "没有等待回答的问题"},
                            },
                        )
                elif msg_type == "register_local_executor":
                    # 前端注册本地执行器：该顶部 agent 的工具调用转发到前端本地执行
                    base_dir = data.get("base_dir")
                    top_agent_id = (
                        data.get("top_agent_id") or data.get("agent_id") or user_id
                    )
                    # 互斥校验：local 与 ssh 不可共存（spec「三模式运行」场景）
                    from io_.mode_resolver import check_exclusive

                    ok, reason = check_exclusive(user_id, top_agent_id, "local")
                    if not ok:
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "register_local_executor_ack",
                                "data": {"success": False, "message": reason},
                            },
                        )
                        continue
                    state.local_executor.register(user_id, top_agent_id, base_dir)
                    # 清除该 agent 的会话缓存：即使此前会话已绑定云端工具，
                    # 下次发消息会重建会话并按本地模式重新绑定工具
                    clear_user_agent(user_id, top_agent_id)
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
                    top_agent_id = (
                        data.get("top_agent_id") or data.get("agent_id") or user_id
                    )
                    state.local_executor.unregister(user_id, top_agent_id)
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
                    top_agent_id = (
                        data.get("top_agent_id") or data.get("agent_id") or user_id
                    )
                    from io_.mode_resolver import check_exclusive

                    ok, reason = check_exclusive(user_id, top_agent_id, "ssh")
                    if not ok:
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "register_ssh_executor_ack",
                                "data": {"success": False, "message": reason},
                            },
                        )
                        continue
                    ok, reason = state.ssh_manager.register(
                        user_id, top_agent_id, data.get("config", {})
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
                    # 清除会话缓存：下次发消息重建会话并按 SSH 模式绑定工具
                    clear_user_agent(user_id, top_agent_id)
                    await state.ws_manager.send_message(
                        user_id,
                        {
                            "type": "register_ssh_executor_ack",
                            "data": {"success": True},
                        },
                    )
                elif msg_type == "unregister_ssh_executor":
                    # 前端注销某个顶部 agent 的 SSH 执行器：该 agent 恢复云端执行
                    top_agent_id = (
                        data.get("top_agent_id") or data.get("agent_id") or user_id
                    )
                    state.ssh_manager.unregister(user_id, top_agent_id)
                    await state.ws_manager.send_message(
                        user_id,
                        {
                            "type": "unregister_ssh_executor_ack",
                            "data": {"success": True},
                        },
                    )
                elif msg_type == "tool_exec_response":
                    # 前端返回工具执行结果：唤醒等待的后端请求
                    exec_id = data.get("exec_id", "")
                    result = data.get("result", {})
                    if not exec_id:
                        await state.ws_manager.send_message(
                            user_id,
                            {
                                "type": "error",
                                "data": {"message": "tool_exec_response 缺少 exec_id"},
                            },
                        )
                        continue
                    resolved = state.local_executor.resolve(user_id, exec_id, result)
                    if not resolved:
                        logger.warning(
                            "tool_exec_response 未匹配到待处理请求: user_id=%s exec_id=%s",
                            user_id,
                            exec_id,
                        )
                else:
                    await state.ws_manager.send_message(
                        user_id,
                        {"type": "error", "data": {"message": f"未知消息类型: {msg_type}"}},
                    )
        except WebSocketDisconnect:
            # 客户端主动断开连接
            pass
        finally:
            state.ws_manager.disconnect(user_id, ws)


__all__ = ["register_ws"]
