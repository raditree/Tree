#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""**最小可运行插件**（Python 标准库；核心逻辑 60~100 行）：先跑通，再读大示例。

它只做四件事，别的什么都不做——这四件就是"一个插件能上线"的最小集合：

1. `hello`：握手，自报名字与能力（核心凭这个判定插件就绪）；
2. `ping`：心跳。**不回就会被打成 degraded**（中转请求的等待期也依赖心跳续期）；
3. `tools/list`：申报工具，这里只有一个 `hello_tool`；
4. `tools/call`：执行那个工具（回 `{content:[{type:text,text:…}], isError}`）。

三条铁律（写任何插件都不能破，详见 docs/plugin-development.md §1）：
  * **stdout 只放协议报文**：一行一条 JSON-RPC；日志走 stderr；
  * **必须能并发处理**：处理 `tools/call` 时核心还会发 `ping` —— 每个请求另开线程；
  * **必须回心跳**：不回 ping 会被判 degraded（不是停用，但中转站会立刻判"未响应"）。

跑起来（**不需要真核心**）：
    python examples/plugins/minimal_plugin.py --selftest

接进真核心（`plugins.yaml`）：
    plugins:
      - id: minimal
        command: "D:/app/python/python.exe"
        args: ["E:/programs/Tree/desktop/examples/plugins/minimal_plugin.py"]
        enabled: true
        scope: {}          # 空 scope = 作用于所有 team
"""

import json
import sys
import threading
import time

NAME = "最小示例插件（Python）"

# 协议通道 / 日志通道：**模块级、可替换**。
# 换成引用而不是到处直接写 `sys.stdout` 的原因：自测（假核心）要在同一个进程里把
# 这两个通道指向内存流；直接换 `sys.stdout` 会在"恢复"时触发一次没人消费的 flush，
# 把自测自己堵死在管道上（这是个很贵的坑，所以这里用注入而不是全局替换）。
STDIN = sys.stdin
STDOUT = sys.stdout
STDERR = sys.stderr


def send(message):
    """写一条协议报文：**stdout 只走这里**，一行一条、写完就刷。"""
    data = (json.dumps(message, ensure_ascii=False) + "\n").encode("utf-8")
    out = getattr(STDOUT, "buffer", None)
    if out is None:
        STDOUT.write(data.decode("utf-8"))
        STDOUT.flush()
        return
    out.write(data)
    out.flush()


def log(text):
    """日志**只走 stderr**（核心把 stderr 收进插件日志缓冲；写 stdout 等于污染协议）。"""
    line = "[minimal_plugin] %s\n" % text
    err = getattr(STDERR, "buffer", None)
    if err is None:
        STDERR.write(line)
        STDERR.flush()
        return
    err.write(line.encode("utf-8", "backslashreplace"))
    err.flush()


def tool_definitions():
    """工具的唯一定义处：模型看到的名字是 plugin__<插件id>__hello_tool。"""
    return [{
        "name": "hello_tool",
        "description": "回显一句话（最小示例插件的唯一工具）",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
        },
    }]


def handle_request(request_id, method, params):
    """处理一条入站请求：**必须且只能**回一条响应（异常也要收敛成响应）。"""
    try:
        if method == "hello":
            # params 里有 plugin_id / core_version / scope / config；自报身份用 name
            send({"jsonrpc": "2.0", "id": request_id, "result": {
                "plugin_id": params.get("plugin_id") or "minimal",
                "name": NAME,
                "capabilities": ["tools"],
            }})
            log("握手完成：plugin_id=%s" % (params.get("plugin_id") or "minimal"))
            return
        if method == "tools/list":
            send({"jsonrpc": "2.0", "id": request_id,
                  "result": {"tools": tool_definitions()}})
            return
        if method == "tools/call":
            name = str(params.get("name") or "")
            arguments = params.get("arguments")
            arguments = arguments if isinstance(arguments, dict) else {}
            if name != "hello_tool":
                send({"jsonrpc": "2.0", "id": request_id, "result": {
                    "content": [{"type": "text", "text": "未知工具 %s" % name}],
                    "isError": True,
                }})
                return
            # 工具成功 = isError:false；失败要把**可读原因**写进 text（模型看得到）
            send({"jsonrpc": "2.0", "id": request_id, "result": {
                "content": [{"type": "text",
                             "text": "hello_tool: %s" % arguments.get("text", "")}],
                "isError": False,
            }})
            return
        if method == "ping":
            # 心跳：内容不看，**回了就算活着**（千万别在这里做慢活）
            send({"jsonrpc": "2.0", "id": request_id,
                  "result": {"ok": True, "ts": int(time.time())}})
            return
        send({"jsonrpc": "2.0", "id": request_id,
              "error": {"code": -32601, "message": "method not found: %s" % method}})
    except Exception as error:  # noqa: BLE001 - 异常必须变成响应，不能让核心挂住
        send({"jsonrpc": "2.0", "id": request_id,
              "error": {"code": -32603, "message": "处理器异常：%r" % error}})


def serve():
    """读循环（主线程）：有 id + method = 请求（**另开线程**）；无 id = 通知。"""
    log("已启动，等待核心 hello（stdout 只走 JSON-RPC）")
    while True:
        raw = STDIN.buffer.readline()
        if not raw:
            log("stdin 已关闭（核心退出？），插件退出")
            return
        line = raw.decode("utf-8", "replace").strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            log("收到非 JSON 行（跳过）：%s" % line[:200])
            continue
        if not isinstance(message, dict):
            continue
        method = message.get("method")
        request_id = message.get("id")
        if method is None and request_id is not None:
            continue    # 响应（核心对我方主动请求的回包）：最小插件不主动请求
        if isinstance(method, str) and method and request_id is not None:
            # **另开线程**：处理中可能还要回别的请求（例如 ping），读循环不能被占住
            threading.Thread(target=handle_request,
                             args=(request_id, method, message.get("params") or {}),
                             daemon=True).start()
            continue
        if method == "shutdown":
            log("收到 shutdown，退出")
            return
        # 其余通知（log / event / ui/* …）：最小插件不订阅，忽略即可


def selftest():
    """假核心自测：**进程内**换成内存流收发，断言四条主路径（不连真核心）。"""
    import io
    import queue

    global STDIN, STDOUT, STDERR
    inbound = io.BytesIO()
    outbound = queue.Queue()

    class _FakeStdin(object):
        """假核心 → 插件：读它的 `readline()`（阻塞到有数据为止）。

        `buffer` 指向自己：真 stdin 是 TextIOWrapper（`.buffer` 才是字节流），
        读循环统一走 `.buffer.readline()` 拿字节，所以这里补一个同名字段。
        """

        @property
        def buffer(self):
            return self

        def readline(self):
            return outbound.get()

    saved = (STDIN, STDOUT, STDERR)
    # 这里用的是**模块级通道注入**，不是替换 sys.*：不碰真实 stdout，
    # 自测结束后也无需"恢复一次没人消费的 flush"（那个坑见文件头的说明）。
    STDIN = _FakeStdin()
    STDOUT = io.TextIOWrapper(inbound, encoding="utf-8", write_through=True)
    STDERR = io.StringIO()
    failures = []

    def ask(request_id, method, params):
        outbound.put((json.dumps({"jsonrpc": "2.0", "id": request_id,
                                  "method": method, "params": params}) + "\n")
                     .encode("utf-8"))

    def replies(timeout=5.0):
        """等插件把回包写完（它另有线程，所以用轮询而不是直接读）。"""
        deadline = time.time() + timeout
        while time.time() < deadline:
            text = inbound.getvalue().decode("utf-8", "replace").strip()
            if text:
                try:
                    return [json.loads(line) for line in text.splitlines()]
                except ValueError:
                    pass
            time.sleep(0.02)
        return []

    try:
        threading.Thread(target=serve, daemon=True).start()
        ask(0, "hello", {"plugin_id": "minimal", "core_version": "selftest"})
        ask(1, "tools/list", {})
        ask(2, "tools/call", {"name": "hello_tool", "arguments": {"text": "hi"}})
        ask(3, "tools/call", {"name": "nope", "arguments": {}})
        ask(4, "ping", {})
        deadline = time.time() + 5.0
        by_id = {}
        while time.time() < deadline and len(by_id) < 5:
            for message in replies(timeout=0.3):
                by_id[message.get("id")] = message.get("result") or {}
            time.sleep(0.02)
        if len(by_id) < 5:
            failures.append("只收到 %d/5 条回包" % len(by_id))
        if by_id.get(0, {}).get("name") != NAME:
            failures.append("hello 回包不对：%s" % by_id.get(0))
        if [t.get("name") for t in by_id.get(1, {}).get("tools", [])] != ["hello_tool"]:
            failures.append("tools/list 回包不对：%s" % by_id.get(1))
        text = (by_id.get(2, {}).get("content") or [{}])[0].get("text")
        if text != "hello_tool: hi":
            failures.append("tools/call 回包不对：%s" % by_id.get(2))
        if by_id.get(3, {}).get("isError") is not True:
            failures.append("未知工具应回 isError:true：%s" % by_id.get(3))
        if by_id.get(4, {}).get("ok") is not True:
            failures.append("ping 没回 ok：%s" % by_id.get(4))
    except Exception as error:  # noqa: BLE001
        failures.append("自测异常：%r" % (error,))
    finally:
        STDIN, STDOUT, STDERR = saved
    for failure in failures:
        sys.stdout.write("[FAIL] %s\n" % failure)
    sys.stdout.write("minimal_plugin 自测：%s（%d/5 条回包）\n"
                     % ("全部通过" if not failures else "有失败项", len(by_id)))
    return 0 if not failures else 1


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    sys.exit(serve())
