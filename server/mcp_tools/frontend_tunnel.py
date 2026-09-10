"""第三方 MCP 服务的 stdio 隧道传输（local / ssh 模式）。

local / ssh 模式下，第三方 stdio MCP 服务的**子进程由宿主进程拉起**（本地模式
= 用户本机前端执行器；SSH 模式 = 远端主机），后端不直接接触该进程。本模块把
四个宿主侧操作适配成 mcp SDK ``ClientSession`` 需要的流对，协议层
（initialize / tools/list / tools/call / notifications 路由）完全复用 SDK：

- ``mcp_stdio_open``：宿主拉起 ``command``/``args``，返回会话 id；
- ``mcp_stdio_write``：后端把待写出的 JSON-RPC 帧（base64 原始字节）交给宿主
  写入子进程 stdin；
- ``mcp_stdio_read``：宿主等待 stdout 上出现完整的一行（JSON-RPC 报文以换行
  分隔）后原样回传（base64）；窗口内无数据则返回空串，由本端续等；
- ``mcp_stdio_close``：宿主关闭子进程。

读写分属两个独立任务（对齐 SDK ``stdio_client`` 的两条管道协程），因此服务端
主动推送的通知（logging 等）不会与请求响应互相饿死。阻塞的宿主调用统一经
``anyio.to_thread`` 执行：隧道往返经反向 WS 完成，阻塞事件循环会导致
``ClientSession`` 的收发协程与我们自己抢同一个 loop。

设计取舍：一次工具调用对应一次 ``tunnel_client``（open → call → close），与
后端直连 stdio 的既有语义一致（见 ``mcp_tool._open_session``），避免跨请求持有
宿主子进程带来的生命周期与并发复杂度。
"""

from __future__ import annotations

import base64
import logging
from contextlib import asynccontextmanager, suppress
from typing import Any, AsyncIterator, Dict, Optional, Sequence

import anyio
import mcp_types as types

from mcp.shared.message import SessionMessage

logger = logging.getLogger(__name__)

# 单次 read 的等待切片（秒）：宿主在该窗口内没有整行可读时返回空串，由本端
# 轮询续等——数分钟的 tools/call 不会被单次等待上限截断。
READ_SLICE_SECONDS = 10.0
# open 等待上限：冷启动（npx 首次拉包）可能很慢
OPEN_TIMEOUT_SECONDS = 300.0
WRITE_TIMEOUT_SECONDS = 60.0
CLOSE_TIMEOUT_SECONDS = 30.0


class FrontendTunnelError(RuntimeError):
    """宿主执行器无法完成隧道操作（未注册 / 未授权 / 子进程已退出）。"""


class FrontendTunnel:
    """经反向 WS（local）/ SSH 隧道（ssh）在宿主进程上驱动第三方 MCP 服务。

    只做"字节搬运"：请求/响应的配对、超时与卡死检测复用
    :class:`io_.local_executor.LocalExecutorClient` 的既有机制（宿主在执行期间
    周期性上报 ``tool_exec_progress``，长任务因此不会被误判超时）。
    """

    def __init__(
        self,
        local_executor: Any,
        ws_manager: Any,
        user_id: str,
        team_id: str,
        mode: str = "local",
    ) -> None:
        self._executor = local_executor
        self._ws = ws_manager
        self._user_id = user_id
        self._team_id = team_id
        self.mode = mode

    def _call(self, payload: Dict[str, Any], timeout: float) -> Dict[str, Any]:
        """发一条宿主侧隧道请求并返回结果（错误统一转成异常）。"""
        data = dict(payload)
        data.setdefault("team_id", self._team_id)
        resp = self._executor.request(
            self._ws, self._user_id, data, timeout=timeout, team_id=self._team_id
        )
        if not isinstance(resp, dict):
            raise FrontendTunnelError(f"宿主执行器返回非法结果: {resp!r}")
        error = resp.get("error")
        if error:
            raise FrontendTunnelError(str(error))
        return resp

    def open(
        self,
        command: str,
        args: Sequence[str],
        env: Optional[Dict[str, str]],
        needs_confirmation: bool = False,
    ) -> str:
        """在宿主进程上拉起 MCP 服务子进程，返回宿主侧会话 id。"""
        resp = self._call(
            {
                "op": "mcp_stdio_open",
                "command": command,
                "args": list(args or []),
                "env": dict(env or {}),
                # 非可信启动器需宿主侧用户首次确认（见前端 MCPTrustStore）
                "needs_confirmation": bool(needs_confirmation),
            },
            OPEN_TIMEOUT_SECONDS,
        )
        session_id = str(resp.get("session_id") or "")
        if not session_id:
            raise FrontendTunnelError("宿主执行器未返回 MCP 会话 id")
        return session_id

    def write(self, session_id: str, data: bytes) -> None:
        """把一帧请求字节写入宿主侧子进程的 stdin。"""
        self._call(
            {
                "op": "mcp_stdio_write",
                "session_id": session_id,
                "data": base64.b64encode(data).decode("ascii"),
            },
            WRITE_TIMEOUT_SECONDS,
        )

    def read(self, session_id: str) -> bytes:
        """取宿主侧子进程 stdout 上已完整的行（无数据时返回空字节）。"""
        resp = self._call(
            {
                "op": "mcp_stdio_read",
                "session_id": session_id,
                "timeout": READ_SLICE_SECONDS,
            },
            READ_SLICE_SECONDS + 30.0,
        )
        raw = resp.get("data") or ""
        if not raw:
            return b""
        try:
            return base64.b64decode(raw)
        except (ValueError, TypeError) as exc:
            raise FrontendTunnelError(f"宿主返回的 MCP 报文不是合法 base64: {exc}") from exc

    def close(self, session_id: str) -> None:
        """关闭宿主侧会话（终止子进程）。失败仅记日志（尽力而为）。"""
        try:
            self._call(
                {"op": "mcp_stdio_close", "session_id": session_id},
                CLOSE_TIMEOUT_SECONDS,
            )
        except Exception as exc:  # noqa: BLE001 - 关闭失败不应影响调用方结果
            logger.debug("关闭 MCP 隧道会话失败(忽略): %s", exc)


def _serialize(session_message: SessionMessage) -> bytes:
    """把一条 MCP 报文序列化为 stdio 帧（换行分隔的 JSON）。"""
    json_text = session_message.message.model_dump_json(
        by_alias=True, exclude_unset=True
    )
    return (json_text + "\n").encode("utf-8")


def _parse_line(line: bytes) -> Optional[SessionMessage]:
    """解析一行 stdio 帧；无法解析时返回 None（记日志丢弃）。"""
    text = line.decode("utf-8", errors="replace").strip()
    if not text:
        return None
    try:
        return SessionMessage(
            types.jsonrpc_message_adapter.validate_json(text, by_name=False)
        )
    except ValueError:
        logger.warning("丢弃无法解析的 MCP 报文: %r", text[:200])
        return None


@asynccontextmanager
async def tunnel_client(
    tunnel: FrontendTunnel,
    command: str,
    args: Sequence[str],
    env: Optional[Dict[str, str]],
    needs_confirmation: bool = False,
) -> AsyncIterator[Any]:
    """打开一个经隧道驱动的 MCP 会话流对（``(read_stream, write_stream)``）。

    与 ``mcp.client.stdio.stdio_client`` 同形，可直接喂给 ``ClientSession``。
    """
    session_id = await anyio.to_thread.run_sync(
        lambda: tunnel.open(command, args, env, needs_confirmation)
    )
    read_stream_writer, read_stream = anyio.create_memory_object_stream[SessionMessage](0)
    write_stream, write_stream_reader = anyio.create_memory_object_stream[SessionMessage](0)
    closing = False

    async def read_pump() -> None:
        """轮询宿主侧 stdout，把完整行解析后推入 read_stream。"""
        buffer = b""
        try:
            async with read_stream_writer:
                while True:
                    data = await anyio.to_thread.run_sync(
                        lambda: tunnel.read(session_id)
                    )
                    if not data:
                        continue
                    buffer += data
                    lines = buffer.split(b"\n")
                    buffer = lines.pop()
                    for line in lines:
                        message = _parse_line(line)
                        if message is not None:
                            await read_stream_writer.send(message)
        except anyio.ClosedResourceError:
            pass
        except Exception as exc:  # noqa: BLE001 - 隧道中断即关闭读流，会话据此感知
            # 收尾阶段关闭宿主会话会使阻塞中的 read 立刻返回错误，属正常路径
            level = logging.DEBUG if closing else logging.WARNING
            logger.log(
                level,
                "MCP 隧道读取中断（%s 模式，session=%s）: %s",
                tunnel.mode, session_id, exc,
            )

    async def write_pump() -> None:
        """把 ClientSession 写出的报文逐条经隧道写入宿主侧子进程。"""
        try:
            async with write_stream_reader:
                async for session_message in write_stream_reader:
                    payload = _serialize(session_message)
                    await anyio.to_thread.run_sync(
                        lambda: tunnel.write(session_id, payload)
                    )
        except (anyio.ClosedResourceError, anyio.BrokenResourceError):
            pass
        except Exception as exc:  # noqa: BLE001 - 写失败即关闭读流，避免请求悬挂
            logger.warning(
                "MCP 隧道写入中断（%s 模式，session=%s）: %s",
                tunnel.mode, session_id, exc,
            )
            with suppress(Exception):
                await read_stream_writer.aclose()

    async def shutdown() -> None:
        """收尾：停流 → 关闭宿主侧会话（终止子进程并唤醒阻塞的 read）。"""
        nonlocal closing
        closing = True
        with suppress(Exception):
            await read_stream_writer.aclose()
        with suppress(Exception):
            write_stream.close()
        await anyio.to_thread.run_sync(lambda: tunnel.close(session_id))

    async with anyio.create_task_group() as task_group:
        task_group.start_soon(read_pump)
        task_group.start_soon(write_pump)
        try:
            yield read_stream, write_stream
        finally:
            # 关闭必须完成，否则宿主侧子进程泄漏；close 本身有界（见 CLOSE_TIMEOUT）
            with anyio.CancelScope(shield=True):
                await shutdown()
            task_group.cancel_scope.cancel()
