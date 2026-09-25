"""WebSocket 连接管理 - 维护用户与 WebSocket 连接的映射，支持单播与广播。

一个用户可能同时打开多个连接（如主消息面板、teammates 工作进度窗口），
因此每个用户维护一组连接，发送消息时向该用户所有连接推送。

每条连接分配唯一 ``connection_id``（uuid4.hex），连接表为
``user_id -> {connection_id: WebSocket}``：端点层可按 connection_id 精确
断连/清理该连接注册的执行器（避免幽灵注册）。消息推送默认按用户广播全部
连接（:meth:`send_message`）；需要精确定位时用 :meth:`send_to_connection`
只投递给指定连接（工具执行请求即按"注册该执行器的连接"定向投递）。

发送保护：``send_json`` 经 ``asyncio.wait_for`` 包裹（超时可注入，默认
``_SEND_TIMEOUT_SECONDS``），超时/异常即移除该连接并关闭，避免慢连接
无限堆积发送协程拖垮事件循环。**该超时按"单次 send_json"计时**：大帧分片后
每片独立计时，不按整条逻辑消息累计（否则大消息必然被误判死链）。

大帧分片：编码后超过 ``_WS_CHUNK_THRESHOLD_BYTES`` 的逻辑消息被切成
``frame_begin`` / ``frame_chunk`` x N / ``frame_end`` 序列逐片发送，由前端
传输层重组为同一条消息。动因见 ``tool/grep_tool.py`` 的 ``ws_max_size``
说明：后端 uvicorn 默认 16MiB，超限会**静默**关闭连接。
"""
import asyncio
import json
import logging
import uuid
from typing import Any, Dict, List

from fastapi import WebSocket

logger = logging.getLogger(__name__)

# 单条连接 send_json 的超时（秒）：正常毫秒级完成，10s 仍发不出去视为死链
_SEND_TIMEOUT_SECONDS = 10.0
# 移除死连接后尝试 close 的超时（秒）
_CLOSE_TIMEOUT_SECONDS = 1.0

# 大帧分片阈值（UTF-8 字节）：超过即分片。
# uvicorn ws_max_size 默认 16MiB，取 12MiB 留 4MiB 余量覆盖 JSON 转义膨胀。
_WS_CHUNK_THRESHOLD_BYTES = 12 * 1024 * 1024
# 单个分片的目标字节数（按字符边界回退，不切断码点）
_WS_CHUNK_PART_BYTES = 4 * 1024 * 1024

# 传输层分片帧类型名（不与任何既有业务 type 冲突）
_FRAME_BEGIN = "frame_begin"
_FRAME_CHUNK = "frame_chunk"
_FRAME_END = "frame_end"


def _peek_message_type(message: Dict[str, Any]) -> str:
    """取逻辑消息的 type（仅供分片日志，失败不抛）。"""
    try:
        value = message.get("type")
        return str(value) if value is not None else "?"
    except Exception:  # noqa: BLE001
        return "?"


def split_payload_by_bytes(text: str, max_bytes: int) -> List[str]:
    """按 UTF-8 字节预算切分 [text]，切点回退到**字符边界**（不切断码点）。

    与前端 ``_takeFramePart`` 同一口径：逐码点累加其 UTF-8 长度，超出预算即停。
    单个码点本身超过预算时单独成片，保证必然推进（不死循环）。
    """
    if max_bytes <= 0 or not text:
        return [text]
    parts: List[str] = []
    index = 0
    length = len(text)
    while index < length:
        slice_start = index
        bytes_used = 0
        while index < length:
            ch = text[index]
            # 代理对按一个码点处理，避免把补充平面字符切成两半
            if 0xD800 <= ord(ch) <= 0xDBFF and index + 1 < length:
                segment = text[index:index + 2]
            else:
                segment = ch
            size = len(segment.encode("utf-8"))
            if bytes_used and bytes_used + size > max_bytes:
                break
            bytes_used += size
            index += len(segment)
        parts.append(text[slice_start:index])
    return parts or [text]


def chunk_message_frame(message: Dict[str, Any]) -> List[Dict[str, Any]]:
    """把逻辑消息切成可发送的帧序列（未超阈值时原样单帧返回）。

    超阈值时产出 ``frame_begin`` + ``frame_chunk`` x N + ``frame_end``，
    前端传输层据 ``id`` 重组为原始 JSON 后再走业务分发。
    """
    payload = json.dumps(message, ensure_ascii=False)
    encoded_len = len(payload.encode("utf-8"))
    if encoded_len <= _WS_CHUNK_THRESHOLD_BYTES:
        return [message]

    transfer_id = f"frg_{uuid.uuid4().hex}"
    parts = split_payload_by_bytes(payload, _WS_CHUNK_PART_BYTES)
    logger.warning(
        "WS 出站消息超过分片阈值，已分片: type=%s bytes=%d chunks=%d id=%s",
        _peek_message_type(message), encoded_len, len(parts), transfer_id,
    )
    frames: List[Dict[str, Any]] = [{
        "type": _FRAME_BEGIN,
        "id": transfer_id,
        "total": len(parts),
        "bytes": encoded_len,
    }]
    for seq, part in enumerate(parts):
        frames.append({
            "type": _FRAME_CHUNK,
            "id": transfer_id,
            "seq": seq,
            "part": part,
        })
    frames.append({
        "type": _FRAME_END,
        "id": transfer_id,
        "total": len(parts),
    })
    return frames


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

    async def _send_maybe_chunked(
        self, websocket: WebSocket, message: Dict[str, Any]
    ) -> None:
        """发送单条逻辑消息：超阈值时分片逐片发送。

        **超时按单次 ``send_json`` 计时**（而非整条逻辑消息累计）：分片后每片
        独立套 ``asyncio.wait_for``，否则大消息必然超过 ``send_timeout`` 而被
        误判为死链移除。任一片失败即向上抛，由调用方走既有的移除/关闭策略。
        """
        for frame in chunk_message_frame(message):
            await asyncio.wait_for(
                websocket.send_json(frame), timeout=self.send_timeout
            )

    async def send_message(self, user_id: str, message: Dict[str, Any]) -> None:
        """向指定用户的所有连接发送 JSON 消息；用户无连接时静默忽略。

        每条连接的发送经 ``asyncio.wait_for`` 超时保护：超时/异常即把该连接
        移除并关闭，不无限堆积发送协程。超限消息自动分片（见 [_send_maybe_chunked]）。

        :param user_id: 用户标识
        :param message: 消息字典，遵循 ``{"type": "...", "data": {...}}`` 协议
        """
        conns = self.connections.get(user_id)
        if not conns:
            return
        dead: list = []
        for connection_id, ws in list(conns.items()):
            try:
                await self._send_maybe_chunked(ws, message)
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

    async def send_to_connection(
        self, user_id: str, connection_id: str, message: Dict[str, Any]
    ) -> bool:
        """向指定用户的指定连接发送 JSON 消息（定向投递）。

        与 :meth:`send_message` 的差别：只投递给 ``connection_id`` 对应的那一条
        连接，同用户其他并行实例（其他连接）不会收到——工具执行请求据此精确
        投递给"注册了该执行器的连接"，非目标实例收不到请求，也就不会用自身的
        失败结果抢先占位。

        连接不存在 / 已被移除时返回 ``False``（调用方可据此快速失败，不必空等
        响应超时）；发送超时或异常时按 :meth:`send_message` 同样的策略把该连接
        移除并关闭后返回 ``False``。

        :param user_id: 用户标识
        :param connection_id: 目标连接 id
        :param message: 消息字典，遵循 ``{"type": "...", "data": {...}}`` 协议
        :return: 是否成功投递
        """
        ws = (self.connections.get(user_id) or {}).get(connection_id)
        if ws is None:
            return False
        try:
            await self._send_maybe_chunked(ws, message)
        except Exception:  # noqa: BLE001
            self._drop_dead(user_id, connection_id)
            logger.warning(
                "WS 定向发送失败/超时，已移除连接: user_id=%s connection_id=%s",
                user_id, connection_id,
            )
            await self._close_quietly(ws)
            return False
        return True

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
