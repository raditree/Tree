"""WebSocket 连接管理 - 维护用户与 WebSocket 连接的映射，支持单播与广播。

一个用户可能同时打开多个连接（如主消息面板、teammates 工作进度窗口），
因此每个用户维护一组连接，发送消息时向该用户所有连接推送。
"""
from typing import Any, Dict, List

from fastapi import WebSocket


class WebSocketManager:
    """管理用户 WebSocket 连接，支持向指定用户发送消息与全局广播。"""

    def __init__(self) -> None:
        """初始化连接字典：user_id -> [WebSocket, ...]。"""
        self.connections: Dict[str, List[WebSocket]] = {}

    async def connect(self, user_id: str, websocket: WebSocket) -> None:
        """接受 WebSocket 连接并追加到该用户的连接列表。

        :param user_id: 用户标识
        :param websocket: WebSocket 连接实例
        """
        await websocket.accept()
        self.connections.setdefault(user_id, []).append(websocket)

    def disconnect(self, user_id: str, websocket: WebSocket) -> None:
        """从该用户的连接列表中移除指定连接（若存在）。"""
        sockets = self.connections.get(user_id)
        if sockets is None:
            return
        if websocket in sockets:
            sockets.remove(websocket)
        if not sockets:
            self.connections.pop(user_id, None)

    async def send_message(self, user_id: str, message: Dict[str, Any]) -> None:
        """向指定用户的所有连接发送 JSON 消息；用户无连接时静默忽略。

        :param user_id: 用户标识
        :param message: 消息字典，遵循 ``{"type": "...", "data": {...}}`` 协议
        """
        sockets = self.connections.get(user_id)
        if not sockets:
            return
        dead: List[WebSocket] = []
        for ws in list(sockets):
            try:
                await ws.send_json(message)
            except Exception:  # noqa: BLE001
                dead.append(ws)
        for ws in dead:
            sockets.remove(ws)
        if not sockets:
            self.connections.pop(user_id, None)

    async def broadcast(self, message: Dict[str, Any]) -> None:
        """向所有已连接用户广播 JSON 消息。

        :param message: 消息字典
        """
        for sockets in list(self.connections.values()):
            dead: List[WebSocket] = []
            for ws in list(sockets):
                try:
                    await ws.send_json(message)
                except Exception:  # noqa: BLE001
                    dead.append(ws)
            for ws in dead:
                sockets.remove(ws)

    async def handle_heartbeat(self, user_id: str) -> None:
        """处理客户端心跳：回复 heartbeat 消息。

        :param user_id: 用户标识
        """
        await self.send_message(user_id, {"type": "heartbeat"})