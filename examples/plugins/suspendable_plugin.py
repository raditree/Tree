#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""**可挂起插件（热重启最小参考实现）**：转储 → 退出 → 新一世取回续跑。

它只做一件事，就是把 docs/plugin-development.md §6.5 那条时序**跑成真的**：

  1. 核心发 `suspend`（只有 `plugins.yaml` 里声明了 `suspension: keep` 才会收到）；
  2. 先用 `station/command` 下 `plugin.stateDump` 把状态递进核心的**内存池**，
     **等它的回包到了**再回 `suspend` 的 ack —— 顺序反了核心就得靠"等一会儿"碰运气，
     而核心既不等也不判时长（D8：取消静态时长判死）；
  3. 回完 ack 就退出（核心收到 shutdown 后会等你，"等多久"完全由你的心跳说话）；
  4. 新一世的 `hello` 参数里带 `resume_dump_id`；你下 `plugin.stateFetch` 取回它；
  5. 取不到就按冷启动继续 —— **这不是错误**（`has_snapshot:false` + 可读 `reason`）。

它把"第几世"数给你看：工具 `era` 回 `restarts`（被热重启过几次）。**这个数字来自
快照本身**，所以只要它跨进程递增，就证明续跑真的发生了（不是"看起来成功了"）。

三条与协议同源的约束（写任何插件都不能破）：
  * stdout 只放协议报文，日志走 stderr；
  * 每个请求另开线程 —— 处理 `suspend` 时核心还在发 `ping`；
  * 业务失败一律走 result 里的 `ok:false` + 可读 `error`，不抛异常挂住读循环。

跑起来（**不需要真核心**）：
    python examples/plugins/suspendable_plugin.py --selftest

接进真核心（`plugins.yaml`）：
    plugins:
      - id: suspendable
        command: "D:/app/python/python.exe"
        args: ["E:/programs/Tree/desktop/examples/plugins/suspendable_plugin.py"]
        enabled: true
        suspension: keep     # ★ 没有这一行 = 不可挂起，热重启会直接冷启动
        scope: {team_id: team-1}
"""

import json
import sys
import threading
import time

NAME = "可挂起插件（热重启示例）"
PLUGIN_ID = "suspendable"

#: 状态键：这份示例只保一个计数器，真实插件在这里放自己的会话游标 / 缓冲 / 句柄表。
STATE_KEY = "restarts"

# 协议通道 / 日志通道：**模块级、可替换**（原因与 minimal_plugin.py 一致：
# 自测要在同一进程里把通道指向内存流）。
STDIN = sys.stdin
STDOUT = sys.stdout
STDERR = sys.stderr

#: 本进程的状态。`resume_dump_id` = 核心在 hello 里告诉我的"上一世那份快照的键"。
STATE = {"era_pid": None, "resume_dump_id": "", "restarts": 0}
STATE_LOCK = threading.Lock()


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
    """日志**只走 stderr**（写 stdout 等于污染协议）。"""
    line = "[suspendable_plugin] %s\n" % text
    err = getattr(STDERR, "buffer", None)
    if err is None:
        STDERR.write(line)
        STDERR.flush()
        return
    err.write(line.encode("utf-8", "backslashreplace"))
    err.flush()


# ── 插件 → 核心：主动下命令（要拿回包，所以必须能等响应）──────────────────

_REQUEST_LOCK = threading.Lock()
_REQUEST_SEQ = [0]
_PENDING = {}          # id -> 事件 + 结果槽
_PENDING_LOCK = threading.Lock()


def request_core(method, params, timeout=15.0):
    """发一条 JSON-RPC **请求**并等它的响应。

    超时只是**自测与降级**用的兜底，不是协议判据：真核心那边永远按心跳说话
    （D8），它不会因为"你这条命令慢了"就把你判死。
    """
    with _REQUEST_LOCK:
        _REQUEST_SEQ[0] += 1
        request_id = "p-%d" % _REQUEST_SEQ[0]
    slot = {"done": threading.Event(), "message": None}
    with _PENDING_LOCK:
        _PENDING[request_id] = slot
    send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
    if not slot["done"].wait(timeout):
        with _PENDING_LOCK:
            _PENDING.pop(request_id, None)
        return {"ok": False, "error": "等核心的 %s 回包超时（%ss）" % (method, timeout)}
    return slot["message"] or {}


def deliver_response(message):
    """把核心的响应交给等着的那个请求（有 id、没有 method = 响应）。"""
    request_id = message.get("id")
    with _PENDING_LOCK:
        slot = _PENDING.pop(request_id, None)
    if slot is None:
        return False
    slot["message"] = message
    slot["done"].set()
    return True


def command(name, arguments=None, timeout=15.0):
    """走执行站下一条命令（`station/command`）。

    **回包形状是 {command, ok, mount_id, payload, error}**：命令真正的结论在
    `payload` 里，被拒时原因在 `error`。这里把两层抹平成一层给上层用。
    """
    response = request_core(
        "station/command",
        {"command": name, "arguments": arguments or {}},
        timeout=timeout,
    )
    envelope = response.get("result")
    if not isinstance(envelope, dict):
        return {"ok": False, "error": "执行站回包不是对象：%r" % (response,)}
    payload = envelope.get("payload")
    if isinstance(payload, dict) and payload:
        return payload
    return envelope


# ── 状态：转储与取回 ─────────────────────────────────────────────────────

def dump_payload():
    """要留给下一世的东西。**必须是 JSON 对象**（跨进程边界，不是进程内引用）。"""
    with STATE_LOCK:
        return {"restarts": STATE["restarts"], "dumped_at": int(time.time())}


def dump_state():
    """`plugin.stateDump`：把快照递进核心的内存池（不落盘，D4）。"""
    result = command("plugin.stateDump", {"payload": dump_payload()})
    if result.get("ok") is False:
        log("转储被拒：%s" % result.get("error"))
        return None
    dump_id = result.get("dump_id")
    log("快照已入池：%s（%s 字节）" % (dump_id, result.get("bytes")))
    return dump_id


def restore_state():
    """`plugin.stateFetch`：取回**上一世**的快照并数出这是第几世。"""
    result = command("plugin.stateFetch", {})
    if result.get("ok") is False:
        log("取回被拒（按冷启动继续）：%s" % result.get("error"))
        return
    if not result.get("has_snapshot"):
        log("没有可续跑的快照 ⇒ 冷启动：%s" % result.get("reason"))
        return
    payload = result.get("payload")
    if not isinstance(payload, dict):
        log("快照载荷不是对象，按冷启动继续：%r" % (payload,))
        return
    with STATE_LOCK:
        STATE["restarts"] = int(payload.get(STATE_KEY, 0)) + 1
    log("续跑成功：第 %d 世（上一世 %s 次）" % (STATE["restarts"] + 1, payload.get(STATE_KEY)))


def tool_definitions():
    return [{
        "name": "era",
        "description": "看这个插件现在是第几世、被热重启过几次（证明续跑真的发生了）",
        "inputSchema": {"type": "object", "properties": {}},
    }]


# ── 入站处理 ─────────────────────────────────────────────────────────────

def handle_request(request_id, method, params):
    """处理一条入站请求：**必须且只能**回一条响应（异常也要收敛成响应）。"""
    try:
        if method == "hello":
            with STATE_LOCK:
                STATE["era_pid"] = __import__("os").getpid()
                STATE["resume_dump_id"] = str(params.get("resume_dump_id") or "")
            send({"jsonrpc": "2.0", "id": request_id, "result": {
                "plugin_id": params.get("plugin_id") or PLUGIN_ID,
                "name": NAME,
                "capabilities": ["tools"],
            }})
            # 就绪后第一件事：问一句"有没有我的快照"。没有就冷启动，这不是错误。
            threading.Thread(target=restore_state, daemon=True).start()
            log("握手完成（resume_dump_id=%r）" % STATE["resume_dump_id"])
            return
        if method == "tools/list":
            send({"jsonrpc": "2.0", "id": request_id,
                  "result": {"tools": tool_definitions()}})
            return
        if method == "tools/call":
            name = str(params.get("name") or "")
            if name != "era":
                send({"jsonrpc": "2.0", "id": request_id, "result": {
                    "content": [{"type": "text", "text": "未知工具 %s" % name}],
                    "isError": True,
                }})
                return
            with STATE_LOCK:
                restarts = STATE["restarts"]
            send({"jsonrpc": "2.0", "id": request_id, "result": {
                "content": [{"type": "text", "text": json.dumps({
                    "pid": STATE["era_pid"],
                    "restarts": restarts,
                    "era": restarts + 1,
                }, ensure_ascii=False)}],
                "isError": False,
            }})
            return
        if method == "ping":
            # 心跳：**回了就算活着**。慢转储期间也靠它让核心知道"我还在忙"（D8）。
            send({"jsonrpc": "2.0", "id": request_id,
                  "result": {"ok": True, "ts": int(time.time())}})
            return
        if method == "suspend":
            # ★ 顺序是这段代码的全部要点：**先转储、等回包、再 ack**。
            dump_id = dump_state()
            send({"jsonrpc": "2.0", "id": request_id,
                  "result": {"ok": True, "dumped": dump_id is not None,
                             "dump_id": dump_id}})
            if str(params.get("reason") or "") == "hot_restart":
                # ack 已经写出去了，现在可以体面退场（下一世会接管这份快照）。
                threading.Thread(target=_exit_after_ack, daemon=True).start()
            return
        send({"jsonrpc": "2.0", "id": request_id,
              "error": {"code": -32601, "message": "method not found: %s" % method}})
    except Exception as error:  # noqa: BLE001 - 异常必须变成响应，不能挂住读循环
        send({"jsonrpc": "2.0", "id": request_id,
              "error": {"code": -32603, "message": "处理器异常：%r" % error}})


def _exit_after_ack():
    """让 ack 先落到管道上，再退出（别把回包挤在半路上）。"""
    time.sleep(0.05)
    sys.exit(0)


def serve():
    """读循环（主线程）：请求另开线程；通知按名字处理；响应交给等着的请求。"""
    log("已启动，等待核心 hello（声明 suspension: keep 才会收到 suspend）")
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
            deliver_response(message)
            continue
        if isinstance(method, str) and method and request_id is not None:
            threading.Thread(target=handle_request,
                             args=(request_id, method, message.get("params") or {}),
                             daemon=True).start()
            continue
        if method == "shutdown":
            log("收到 shutdown，退出")
            return
        # 其余通知（event / station/cancel / …）：本示例不订阅，忽略即可


# ── 自测（不连真核心）────────────────────────────────────────────────────

def selftest():
    """假核心：只回答 `station/command`，然后按 §6.5 的时序走一整轮"两世"。

    断言的都是**可数的东西**：转储请求确实在 ack **之前**发出、取回请求确实带了
    上一世的载荷、`era` 计数器确实跨进程加了一。
    """
    import io
    import queue

    global STDIN, STDOUT, STDERR
    inbound = io.BytesIO()
    outbound = queue.Queue()

    class _FakeStdin(object):
        @property
        def buffer(self):
            return self

        def readline(self):
            return outbound.get()

    saved = (STDIN, STDOUT, STDERR)
    STDIN = _FakeStdin()
    STDOUT = io.TextIOWrapper(inbound, encoding="utf-8", write_through=True)
    STDERR = io.StringIO()
    failures = []
    stored = {"payload": None}

    def sent():
        text = inbound.getvalue().decode("utf-8", "replace").strip()
        if not text:
            return []
        return [json.loads(one) for one in text.splitlines() if one.strip()]

    answered = set()          # 已经回过的插件请求 id（不能重复回答同一句）

    def answer_one(message):
        """把插件主动发来的 `station/command` 当假核心那样接一句。"""
        request_id = message.get("id")
        params = message.get("params") or {}
        command_name = params.get("command")
        arguments = params.get("arguments") or {}
        if command_name == "plugin.stateDump":
            stored["payload"] = arguments.get("payload")
            reply = {"ok": True, "dump_id": "suspendable#1",
                     "bytes": 42, "generation": 1}
        elif command_name == "plugin.stateFetch":
            has = stored["payload"] is not None
            reply = {"ok": True, "has_snapshot": has,
                     "dump_id": "suspendable#1", "generation": 0}
            if has:
                reply["payload"] = stored["payload"]
            else:
                reply["reason"] = "这是第一世（没有上一世）⇒ 按冷启动继续"
        else:
            reply = {"ok": False, "error": "自测假核心不认命令 %s" % command_name}
        outbound_response(request_id, reply)
        return command_name

    def wait_for_command(wanted, deadline=6.0):
        """扫插件已经发出的报文，逐条应答；等到 `wanted` 被应答为止。

        必须按 id 去重：`sent()` 是从头读整个缓冲区的，不记“答过了”就会
        把最早那条 stateFetch 反复应答，还永远等不到后来的 stateDump。
        """
        end = time.time() + deadline
        while time.time() < end:
            for message in sent():
                if message.get("method") != "station/command":
                    continue
                request_id = message.get("id")
                if request_id in answered:
                    continue
                answered.add(request_id)
                if answer_one(message) == wanted:
                    return True
            time.sleep(0.02)
        return False

    def indexOf_command(name):
        for index, message in enumerate(sent()):
            if (message.get("params") or {}).get("command") == name:
                return index
        return None

    def result_of(request_id, deadline=6.0):
        end = time.time() + deadline
        while time.time() < end:
            for message in sent():
                if message.get("id") == request_id and "result" in message:
                    return message["result"]
            time.sleep(0.02)
        return None

    def outbound_response(request_id, payload):
        """核心 → 插件的**响应**（执行站三件套形状：结论在 payload 里）。"""
        ask_raw({"jsonrpc": "2.0", "id": request_id, "result": {
            "command": "x", "ok": payload.get("ok", True),
            "mount_id": "selftest", "payload": payload,
            "error": payload.get("error", "")}})

    def ask_raw(message):
        """把核心的下行报文塞给插件（下行 = 请求/通知；响应也是同一形状）。"""
        outbound.put((json.dumps(message, ensure_ascii=False) + "\n").encode("utf-8"))

    try:
        threading.Thread(target=serve, daemon=True).start()

        # ① 第一世：hello（**没有** resume_dump_id）⇒ 取回应当落空
        ask_raw({"jsonrpc": "2.0", "id": 0, "method": "hello",
                 "params": {"plugin_id": PLUGIN_ID, "core_version": "selftest"}})
        if not wait_for_command("plugin.stateFetch"):
            failures.append("第一世没有下 plugin.stateFetch")
        # ② 核心发来 suspend ⇒ 必须先转储再 ack
        ask_raw({"jsonrpc": "2.0", "id": 1, "method": "suspend",
                 "params": {"reason": "hot_restart"}})
        if not wait_for_command("plugin.stateDump"):
            failures.append("suspend 后没有下 plugin.stateDump")
        ack = result_of(1)
        if not ack or ack.get("ok") is not True or ack.get("dumped") is not True:
            failures.append("suspend 的 ack 不对：%r" % (ack,))
        if stored["payload"] is None:
            failures.append("假核心没收到任何转储载荷")
        # ack 必须排在转储请求**之后**（顺序反了 = 核心只能靠等时长）
        dump_index = indexOf_command("plugin.stateDump")
        ack_index = None
        for index, message in enumerate(sent()):
            if message.get("id") == 1 and "result" in message:
                ack_index = index
                break
        if dump_index is None or ack_index is None or dump_index >= ack_index:
            failures.append("转储请求没有排在 suspend 的 ack 之前（dump=%s ack=%s）"
                            % (dump_index, ack_index))

        # ③ 第二世：hello 带 resume_dump_id ⇒ 取回上一世载荷，计数器 +1
        STATE["restarts"] = 0
        ask_raw({"jsonrpc": "2.0", "id": 2, "method": "hello",
                 "params": {"plugin_id": PLUGIN_ID, "resume_dump_id": "suspendable#1"}})
        end = time.time() + 6.0
        fetched_second_era = False
        while time.time() < end and not fetched_second_era:
            for message in sent():
                if message.get("method") != "station/command":
                    continue
                request_id = message.get("id")
                if request_id in answered:
                    continue
                answered.add(request_id)
                if answer_one(message) == "plugin.stateFetch":
                    fetched_second_era = True
                    break
            time.sleep(0.02)
        if not fetched_second_era:
            failures.append("第二世没有下 plugin.stateFetch")
        deadline = time.time() + 4.0
        while time.time() < deadline and STATE["restarts"] < 1:
            time.sleep(0.02)
        if STATE["restarts"] != 1:
            failures.append("续跑没把 restarts 加到 1（当前 %r）" % STATE["restarts"])

        # ④ 工具 era 把这个数字端出来（模型与面板都靠它判断"真的续上了"）
        ask_raw({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                 "params": {"name": "era", "arguments": {}}})
        era_result = result_of(3)
        text = None
        if era_result:
            content = era_result.get("content") or [{}]
            text = content[0].get("text")
        if not text or json.loads(text).get("restarts") != 1:
            failures.append("era 工具没回第几世：%r" % text)
    except Exception as error:  # noqa: BLE001
        failures.append("自测异常：%r" % (error,))
    finally:
        STDIN, STDOUT, STDERR = saved
    for failure in failures:
        sys.stdout.write("[FAIL] %s\n" % failure)
    sys.stdout.write("suspendable_plugin 自测：%s\n"
                     % ("全部通过（转储→ack→取回→第 2 世）" if not failures else "有失败项"))
    return 0 if not failures else 1


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    sys.exit(serve())
