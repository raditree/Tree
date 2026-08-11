"""WebSocket 连接管理 - 维护用户与 WebSocket 连接的映射，支持单播与广播。"""
from typing import Any, Dict

from fastapi import WebSocket


class WebSocketManager:
    """管理用户 WebSocket 连接，支持向指定用户发送消息与全局广播。"""

    def __init__(self) -> None:
        """初始化连接字典：user_id -> WebSocket。"""
        self.connections: dict[str, WebSocket] = {}

    async def connect(self, user_id: str, websocket: WebSocket) -> None:
        """接受 WebSocket 连接并存储到连接字典。

        :param user_id: 用户标识
        :param websocket: WebSocket 连接实例
        """
        await websocket.accept()
        self.connections[user_id] = websocket

    def disconnect(self, user_id: str) -> None:
        """从连接字典中移除用户连接（若存在）。"""
        self.connections.pop(user_id, None)

    async def send_message(self, user_id: str, message: Dict[str, Any]) -> None:
        """向指定用户发送 JSON 消息；连接不存在时静默忽略。

        :param user_id: 用户标识
        :param message: 消息字典，遵循 ``{"type": "...", "data": {...}}`` 协议
        """
        websocket = self.connections.get(user_id)
        if websocket is None:
            return
        await websocket.send_json(message)

    async def broadcast(self, message: Dict[str, Any]) -> None:
        """向所有已连接用户广播 JSON 消息。

        :param message: 消息字典
        """
        for websocket in list(self.connections.values()):
            await websocket.send_json(message)

    async def handle_heartbeat(self, user_id: str) -> None:
        """处理客户端心跳：回复 heartbeat 消息。

        :param user_id: 用户标识
        """
        await self.send_message(user_id, {"type": "heartbeat"})
