"""WebSocket 连接管理 - 维护用户与 WebSocket 连接的映射，支持单播与广播。

一个用户可能同时打开多个连接（如主消息面板、teammates 工作进度窗口），
因此每个用户维护一组连接，发送消息时向该用户所有连接推送。

每条连接分配唯一 ``connection_id``（uuid4.hex），连接表为
``user_id -> {connection_id: WebSocket}``：端点层可按 connection_id 精确
断连/清理该连接注册的执行器（避免幽灵注册），消息推送仍按用户广播全部连接。

发送保护：``send_json`` 经 ``asyncio.wait_for`` 包裹（超时可注入，默认
``_SEND_TIMEOUT_SECONDS``），超时/异常即移除该连接并关闭，避免慢连接
无限堆积发送协程拖垮事件循环。
"""
import asyncio
import logging
import uuid
from typing import Any, Dict

from fastapi import WebSocket

logger = logging.getLogger(__name__)

# 单条连接 send_json 的超时（秒）：正常毫秒级完成，10s 仍发不出去视为死链
_SEND_TIMEOUT_SECONDS = 10.0
# 移除死连接后尝试 close 的超时（秒）
_CLOSE_TIMEOUT_SECONDS = 1.0


class WebSocketManager:
    """管理用户 WebSocket 连接，支持向指定用户发送消息与全局广播。"""

    def __init__(self, send_timeout: float = _SEND_TIMEOUT_SECONDS) -> None:
        """初始化连接字典：user_id -> {connection_id: WebSocket}。

        :param send_timeout: 单条连接 send_json 超时秒数（可注入以便测试）
        """
        self.connections: Dict[str, Dict[str, WebSocket]] = {}
        self.send_timeout = send_timeout

    async def connect(self, user_id: str, websocket: WebSocket) -> str:
        """接受 WebSocket 连接，分配 connection_id 并加入该用户的连接表。

        :param user_id: 用户标识
        :param websocket: WebSocket 连接实例
        :return: 本次连接的 connection_id（uuid4.hex）
        """
        await websocket.accept()
        connection_id = uuid.uuid4().hex
        self.connections.setdefault(user_id, {})[connection_id] = websocket
        return connection_id

    def connection_id_of(self, user_id: str, websocket: WebSocket) -> str:
        """反查某连接的 connection_id；未注册时返回空串。"""
        for connection_id, ws in (self.connections.get(user_id) or {}).items():
            if ws is websocket:
                return connection_id
        return ""

    def disconnect_by_id(self, user_id: str, connection_id: str) -> None:
        """按 connection_id 从该用户的连接表中移除指定连接（若存在）。"""
        conns = self.connections.get(user_id)
        if conns is None:
            return
        conns.pop(connection_id, None)
        if not conns:
            self.connections.pop(user_id, None)

    def disconnect(self, user_id: str, websocket: WebSocket) -> None:
        """从该用户的连接列表中移除指定连接（按实例反查，兼容旧调用）。"""
        connection_id = self.connection_id_of(user_id, websocket)
        if connection_id:
            self.disconnect_by_id(user_id, connection_id)

    def _drop_dead(self, user_id: str, connection_id: str) -> None:
        """把发送失败的连接从连接表移除（调用方负责关闭）。"""
        self.disconnect_by_id(user_id, connection_id)

    async def _close_quietly(self, websocket: WebSocket) -> None:
        """尽力关闭连接：失败/超时均忽略（连接已从表中移除，不影响他人）。"""
        try:
            await asyncio.wait_for(websocket.close(), timeout=_CLOSE_TIMEOUT_SECONDS)
        except Exception:  # noqa: BLE001
            pass

    async def send_message(self, user_id: str, message: Dict[str, Any]) -> None:
        """向指定用户的所有连接发送 JSON 消息；用户无连接时静默忽略。

        每条连接的发送经 ``asyncio.wait_for`` 超时保护：超时/异常即把该连接
        移除并关闭，不无限堆积发送协程。

        :param user_id: 用户标识
        :param message: 消息字典，遵循 ``{"type": "...", "data": {...}}`` 协议
        """
        conns = self.connections.get(user_id)
        if not conns:
            return
        dead: list = []
        for connection_id, ws in list(conns.items()):
            try:
                await asyncio.wait_for(
                    ws.send_json(message), timeout=self.send_timeout
                )
            except Exception:  # noqa: BLE001
                dead.append((connection_id, ws))
        for connection_id, ws in dead:
            self._drop_dead(user_id, connection_id)
            logger.warning(
                "WS 连接发送失败/超时，已移除: user_id=%s connection_id=%s",
                user_id, connection_id,
            )
            await self._close_quietly(ws)
        if user_id in self.connections and not self.connections[user_id]:
            self.connections.pop(user_id, None)

    async def broadcast(self, message: Dict[str, Any]) -> None:
        """向所有已连接用户广播 JSON 消息。

        :param message: 消息字典
        """
        for user_id in list(self.connections.keys()):
            await self.send_message(user_id, message)

    async def handle_heartbeat(self, user_id: str) -> None:
        """处理客户端心跳：回复 heartbeat 消息。

        :param user_id: 用户标识
        """
        await self.send_message(user_id, {"type": "heartbeat"})
