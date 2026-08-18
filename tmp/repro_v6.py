# -*- coding: utf-8 -*-
"""Repro v6: tool_count>=7 时，每条消息后触发记忆维护（acb2a10 门控）→ 测量消息总耗时与事件循环响应性。"""
import asyncio, json, os, sys, time, subprocess, sqlite3
sys.path.insert(0, os.path.abspath("server"))
PORT = 8131

# 先把该 agent 的工具计数设为 8（>=7 触发记忆维护）
db = os.path.abspath("server/data/conversations.db")
conn = sqlite3.connect(db)
conn.execute("INSERT INTO agent_tool_count (user_id, agent_id, tool_count, updated_at) VALUES (?, ?, 8, ?) "
             "ON CONFLICT(user_id, agent_id) DO UPDATE SET tool_count = 8, updated_at = excluded.updated_at",
             ("user_5f90a51b531fd3c2d123bc3f", "agent_1787022784638", int(time.time()*1000)))
conn.commit(); conn.close()
print("tool_count set to 8")

def _start_server():
    env = dict(os.environ)
    return subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "main:app", "--host", "127.0.0.1", "--port", str(PORT), "--log-level", "warning"],
        cwd=os.path.abspath("server"), env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

async def main():
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
            print("SERVER NOT READY"); return
        from core.auth import create_token
        token = create_token({"openid": "user_5f90a51b531fd3c2d123bc3f"})
        import websockets
        uri = f"ws://127.0.0.1:{PORT}/ws?token={token}"
        async with websockets.connect(uri) as ws:
            t0 = time.time()
            await ws.send(json.dumps({"type": "user_message", "data": {"agent_id": "agent_1787022784638", "content": "你好，请用一句话回复。"}}))
            got = []
            deadline = time.time() + 120
            try:
                while time.time() < deadline:
                    try:
                        msg = json.loads(await asyncio.wait_for(ws.recv(), timeout=0.5))
                    except asyncio.TimeoutError:
                        continue
                    t = time.time() - t0
                    mtype = msg.get("type")
                    status = msg.get("data", {}).get("status", "")
                    got.append((mtype, t))
                    print(f"[{t:7.2f}s] {mtype} {status} {json.dumps(msg.get('data', {}), ensure_ascii=False)[:90]}")
            except Exception as e:
                print("recv err:", e)
            print(f"=== events={len(got)} total={time.time()-t0:.2f}s types={[g[0] for g in got]}")
    finally:
        proc.terminate()
        try:
            proc.communicate(timeout=5)
        except Exception:
            proc.kill()

asyncio.run(main())
