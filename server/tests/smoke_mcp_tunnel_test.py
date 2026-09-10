"""第三方 MCP 隧道（local / ssh）端到端冒烟测试。

用**真实子进程**模拟"宿主执行器"（用户本机 / 远端主机）：宿主按
``mcp_stdio_open|write|read|close`` 拉起并桥接 MCP 服务子进程的 stdio，
本端经 ``mcp_tools.frontend_tunnel.tunnel_client`` 把该字节流适配成
``ClientSession`` 需要的流对。

验证点（全部走标准 MCP 协议，不经任何直调捷径）：
- ``initialize`` / ``tools/list`` / ``tools/call`` 经隧道全程可用；
- 通知（无 id）与请求响应在同一隧道上互不饿死；
- 宿主进程退出后隧道读取快速失败，不悬挂调用方。

运行：``server\\.venv\\Scripts\\python.exe tests\\smoke_mcp_tunnel_test.py``
"""
from __future__ import annotations

import os
import queue
import subprocess
import sys
import threading
from typing import Any, Dict, List, Optional, Sequence

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from mcp import ClientSession  # noqa: E402

from mcp_tools.frontend_tunnel import (  # noqa: E402
    FrontendTunnelError,
    tunnel_client,
)

# 宿主侧 MCP 服务脚本：一个最小但完整的 stdio MCP server（单个 echo 工具）。
_HOST_SERVER_SRC = '''
import sys

from mcp import types
from mcp.server.lowlevel import Server
from mcp.server.stdio import stdio_server
import anyio


async def _on_list_tools(ctx, params):
    return types.ListToolsResult(
        tools=[
            types.Tool(
                name="echo",
                description="回显 text 参数",
                inputSchema={
                    "type": "object",
                    "properties": {"text": {"type": "string", "description": "待回显文本"}},
                    "required": ["text"],
                },
            )
        ]
    )


async def _on_call_tool(ctx, params):
    args = getattr(params, "arguments", None) or {}
    if not args.get("text"):
        return types.CallToolResult(
            content=[types.TextContent(type="text", text="缺少 text")],
            isError=True,
        )
    return types.CallToolResult(
        content=[types.TextContent(type="text", text="echo:" + str(args["text"]))]
    )


server = Server("tunnel-probe", version="0.1.0",
                on_list_tools=_on_list_tools, on_call_tool=_on_call_tool)


async def main():
    async with stdio_server() as (read, write):
        await server.run(read, write, server.create_initialization_options())


anyio.run(main)
'''


class _ProcTunnel:
    """把隧道四操作桥接到一个真实子进程（模拟宿主执行器）。"""

    mode = "local"

    def __init__(self, script_path: str) -> None:
        self._script = script_path
        self._proc: Optional[subprocess.Popen] = None
        self._lines: "queue.Queue[Any]" = queue.Queue()
        self._reader: Optional[threading.Thread] = None
        self.closed = False

    def open(
        self,
        command: str,
        args: Sequence[str],
        env: Optional[Dict[str, str]],
        needs_confirmation: bool = False,
    ) -> str:
        self._proc = subprocess.Popen(
            [command, *args],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )

        def _pump() -> None:
            assert self._proc and self._proc.stdout
            for line in iter(self._proc.stdout.readline, b""):
                self._lines.put(line)
            self._lines.put(EOFError("宿主 MCP 子进程已退出"))

        self._reader = threading.Thread(target=_pump, daemon=True)
        self._reader.start()
        return "host-session-1"

    def write(self, session_id: str, data: bytes) -> None:
        assert self._proc and self._proc.stdin
        self._proc.stdin.write(data)
        self._proc.stdin.flush()

    def read(self, session_id: str) -> bytes:
        if self.closed:
            raise FrontendTunnelError("会话已关闭")
        try:
            item = self._lines.get(timeout=1.0)
        except queue.Empty:
            return b""
        if isinstance(item, BaseException):
            raise FrontendTunnelError(str(item))
        return item

    def close(self, session_id: str) -> None:
        self.closed = True
        if self._proc is None:
            return
        try:
            if self._proc.stdin:
                self._proc.stdin.close()
        except Exception:  # noqa: BLE001
            pass
        try:
            self._proc.terminate()
            self._proc.wait(timeout=5)
        except Exception:  # noqa: BLE001
            pass


class _DeadTunnel(_ProcTunnel):
    """open 后立即"进程退出"的宿主：用于验证快速失败。"""

    def read(self, session_id: str) -> bytes:
        raise FrontendTunnelError("宿主 MCP 子进程已退出")


def _run(coro: Any) -> Any:
    import anyio

    return anyio.run(lambda: coro)


async def _exercise(tunnel: Any) -> Dict[str, Any]:
    """经隧道完成一次 initialize / tools/list / tools/call。"""
    out: Dict[str, Any] = {}
    async with tunnel_client(
        tunnel, command=sys.executable, args=["-c", _HOST_SERVER_SRC], env={}
    ) as (read, write):
        async with ClientSession(read, write) as session:
            init = await session.initialize()
            out["server_name"] = init.server_info.name
            listed = await session.list_tools()
            out["tools"] = [t.name for t in listed.tools]
            ok = await session.call_tool("echo", {"text": "hello"})
            out["ok_text"] = ok.content[0].text
            out["ok_is_error"] = bool(getattr(ok, "is_error", False))
            bad = await session.call_tool("echo", {})
            out["bad_is_error"] = bool(getattr(bad, "is_error", False))
    return out


async def _expect_failure(tunnel: Any) -> str:
    """宿主进程不可用时，调用应在有限时间内失败而不是悬挂。"""
    try:
        async with tunnel_client(
            tunnel, command=sys.executable, args=["-c", "pass"], env={}
        ) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
    except Exception as exc:  # noqa: BLE001 - 断言用
        return f"{type(exc).__name__}: {exc}"
    return ""


def main() -> int:
    import tempfile

    with tempfile.NamedTemporaryFile(
        "w", suffix=".py", delete=False, encoding="utf-8"
    ) as fh:
        fh.write(_HOST_SERVER_SRC)
        script_path = fh.name

    failures: List[str] = []
    try:
        result = _run(_exercise(_ProcTunnel(script_path)))
        print("隧道往返结果:", result)
        if result.get("server_name") != "tunnel-probe":
            failures.append(f"serverInfo 不符: {result.get('server_name')!r}")
        if result.get("tools") != ["echo"]:
            failures.append(f"tools/list 不符: {result.get('tools')!r}")
        if result.get("ok_text") != "echo:hello":
            failures.append(f"tools/call 结果不符: {result.get('ok_text')!r}")
        if result.get("ok_is_error"):
            failures.append("成功调用被标记为 isError")
        if not result.get("bad_is_error"):
            failures.append("失败调用未被标记为 isError")

        err = _run(_expect_failure(_DeadTunnel(script_path)))
        print("隧道中断表现:", err or "(无异常——不符合预期)")
        if not err:
            failures.append("宿主进程退出后调用未失败")
    finally:
        try:
            os.unlink(script_path)
        except OSError:
            pass

    if failures:
        print("\nMCP TUNNEL SMOKE TEST FAILED:")
        for item in failures:
            print(" -", item)
        return 1
    print("\nMCP TUNNEL (FRONTEND STDIO) SMOKE TEST PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
