# -*- coding: utf-8 -*-
"""Repro v5: 本地模式 + 前端【正常回包】（模拟健康前端）→ 看消息是否还等、等在哪。"""
import asyncio, json, os, sys, time, subprocess
sys.path.insert(0, os.path.abspath("server"))
PORT = 8130
OUT = os.path.abspath("tmp/repro_v5.txt")

def _start_server():
    env = dict(os.environ)
    return subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "main:app", "--host", "127.0.0.1", "--port", str(PORT), "--log-level", "warning"],
        cwd=os.path.abspath("server"), env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

def log(f, *a):
    line = " ".join(str(x) for x in a)
    print(line, flush=True)
    f.write(line + "\n"); f.flush()

async def main():
    f = open(OUT, "w", encoding="utf-8")
    proc = _start_server()
    try:
        import socket
        ready = False
        for _ in range(80):
            try:
                s = socket.create_connection(("127.0.0.1", PORT), timeout=0.5); s.close(); ready = True; break
            except OSError:
                await asyncio.sleep(0.25)
        if not ready:
            log(f, "SERVER NOT READY"); return

        from core.auth import create_token
        token = create_token({"openid": "user_5f90a51b531fd3c2d123bc3f"})
        import websockets
        uri = f"ws://127.0.0.1:{PORT}/ws?token={token}"
        async with websockets.connect(uri) as ws:
            await ws.send(json.dumps({"type": "register_local_executor", "data": {"base_dir": "C:/proj", "top_agent_id": "agent_1787022784638"}}))
            ack = json.loads(await asyncio.wait_for(ws.recv(), timeout=3))
            log(f, "ack:", ack.get("type"))

            send_t = time.time()
            await ws.send(json.dumps({"type": "user_message", "data": {"agent_id": "agent_1787022784638", "content": "你好，请用一句话回复。"}}))
            log(f, "msg sent")

            n_req = 0
            rtts = []
            deadline = time.time() + 60
            try:
                while time.time() < deadline:
                    try:
                        msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=0.5))
                    except asyncio.TimeoutError:
                        continue
                    t = time.time() - send_t
                    mtype = msg.get("type")
                    if mtype == "tool_exec_request":
                        n_req += 1
                        req_t = time.time()
                        d = msg.get("data", {})
                        op = d.get("op"); path = d.get("path")
                        # 模拟健康前端：立即回包（read_file 返回空内容，其他返回空结果）
                        if op == "read_file":
                            result = {"exit_code": 0, "content": ""}
                        else:
                            result = {"exit_code": 0, "stdout": ""}
                        await ws.send(json.dumps({"type": "tool_exec_response", "data": {"exec_id": d.get("exec_id"), "result": result}}))
                        rtts.append(time.time() - req_t)
                        log(f, f"[{t:6.2f}s] tool_exec_request #{n_req} op={op} path={path} -> responded in {rtts[-1]*1000:.0f}ms")
                        continue
                    log(f, f"[{t:6.2f}s] {mtype} {json.dumps(msg.get('data', {}), ensure_ascii=False)[:110]}")
                    if mtype == "agent_status" and msg.get("data", {}).get("status") == "idle":
                        break
            except Exception as e:
                log(f, "recv err:", e)
            log(f, f"=== done: tool_exec_request={n_req}, total={time.time()-send_t:.2f}s")
    finally:
        proc.terminate()
        try:
            proc.communicate(timeout=5)
        except Exception:
            proc.kill()
        f.close()

asyncio.run(main())
