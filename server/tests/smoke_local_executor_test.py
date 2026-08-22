"""临时冒烟测试：单进程内启动后端并验证 register_local_executor / tool_exec_request / tool_exec_response 端到端。"""
import asyncio
import json
import os
import sys
import threading
import time

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

import uvicorn
import websockets
from ws.auth import create_token

import main as m

PORT = 8124
user = {"openid": "ws_smoke_user"}
token = create_token(user)


def _run_server() -> None:
    uvicorn.run(m.app, host="127.0.0.1", port=PORT, log_level="warning")


async def main_async() -> None:
    async with websockets.connect("ws://127.0.0.1:%d/ws?token=%s" % (PORT, token)) as ws:
        # 1. 注册本地执行器（服务端 lifespan 已绑定主循环）
        await ws.send(json.dumps({"type": "register_local_executor", "data": {"base_dir": "C:/proj"}}))
        ack = json.loads(await ws.recv())
        print("ack:", ack)
        assert ack["type"] == "register_local_executor_ack", ack
        assert m._local_executor.is_local("ws_smoke_user") is True
        print("register_local_executor OK")

        # 2. 后台线程触发 request（服务端同一实例），验证推送 + 回传闭环
        holder: dict = {}

        def do_request() -> None:
            holder["res"] = m._local_executor.request(
                m.ws_manager,
                "ws_smoke_user",
                {"op": "grep_search", "workspace_id": "top", "pattern": "abc"},
                timeout=8,
            )

        t = threading.Thread(target=do_request)
        t.start()
        req = json.loads(await ws.recv())
        print("req:", json.dumps(req, ensure_ascii=False)[:180])
        assert req["type"] == "tool_exec_request"
        exec_id = req["data"]["exec_id"]
        await ws.send(
            json.dumps(
                {
                    "type": "tool_exec_response",
                    "data": {"exec_id": exec_id, "result": {"exit_code": 1, "stdout": ""}},
                }
            )
        )
        t.join(timeout=8)
        print("request result:", holder.get("res"))
        assert holder["res"].get("exit_code") == 1, holder.get("res")
        print("WS END-TO-END TEST PASSED")


if __name__ == "__main__":
    server_thread = threading.Thread(target=_run_server, daemon=True)
    server_thread.start()
    # 等待服务就绪
    for _ in range(40):
        try:
            import socket

            s = socket.create_connection(("127.0.0.1", PORT), timeout=0.3)
            s.close()
            break
        except OSError:
            time.sleep(0.25)
    try:
        asyncio.run(main_async())
    finally:
        print("done")
