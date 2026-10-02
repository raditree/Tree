#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""**内置插件：compact（上下文压缩）**——把长会话压成"摘要 + 必读文件 + 待办"。

订阅中转点位 `system.relay.context.compact`，做**全权压缩**：核心把"引擎这一轮真会
发的那份请求"（`payload.request`，线形态 `{model, messages, tools, …}`）交给插件，
插件回一份新的上下文与覆盖条数。

**原料只有一样：`request.messages`。** 落库全量原文**不再下发**——那份东西既大
（动辄几 MB）又与"模型真正看到的那份"不同步（冷前缀早已被摘要/列表代表）。

产出结构（回包 `payload.messages`；引擎只把首条 system 槽位刷成最新提示词）：

    [0]      system  提示词槽位（内容由核心每轮覆盖，插件放快照即可）
    [1]      system  摘要：背景 / 轨迹 / 改动产出文件
    [2]      assistant(reasoning_content=固定文案, tool_calls=[read…, set_todo_list])
    [3..]    tool    一一对应的读取结果（必读文件 + todo 快照）
    [N..]    …       尾部原文**原样抄自 `request.messages[cut:]`**（助手工作、工具卡
                     全在里面，插件一个字都不改写）
    covered_message_count = total_message_count（尾部已抄进列表，核心不再追加）

**缓存**（长会话省钱的关键）：总结调用把 `request.messages[:cut]` 整段当 messages，
末尾只追加一条**user 指令**——前缀与对话那一轮逐字一致，端点侧已持久化的缓存单元
就能整段命中；同时 `request.tools` 原样透传给 `llm.call`（工具定义渲染在 messages
之前，缺了它前缀从第一个 token 就对不上）。注意**不要**用 `llm.call` 的 `system`
参数放指令：那会在最前面插一条 system 消息，把前缀整体错位。

切点（`cut`）在 **wire 坐标**里决定，三条规则：
    1. 保留最近 `--keep-rounds` 轮 user 及其之后；
    2. 该区域里的工具轮（assistant+tool_calls）超过 `--keep-tool-rounds`（默认 8）时，
       只保留最后 8 轮——单轮超长工具轨迹因此**压得动**；
    3. 切点不得落在 `tool` 消息上（否则尾部以孤儿工具结果开头，端点直接 400）。

尾部抄回后上下文只会变小（槽位 + 摘要 + 必读 + ≤8 个工具轮），不会再贴着阈值，
所以这里**不设**"输入太大就少压一点"的自适应：那只会多留原文、压得更少，方向是反的。

失败一律回 `null`（不接管）⇒ 核心回退内置 compact，上下文不会丢。

自检（**不需要真核心**）：

    python examples/plugins/compact_plugin.py --selftest
"""

import json
import sys
import threading
import time

JSONRPC_VERSION = "2.0"
METHOD_STATION_COMMAND = "station/command"
METHOD_STATION_REQUEST = "station/request"
METHOD_STATION_SUBSCRIBE = "station/subscribe"

STATION_RELAY_CONTEXT_COMPACT = "system.relay.context.compact"

ERR_METHOD_NOT_FOUND = -32601
ERR_INTERNAL = -32603

#: 固定的"伪推理"文案（Q6 定稿）：让伪造的这条 assistant 在带 tools 的思考模式端点上
#: 满足"历史 assistant 必须带 reasoning_content"的口径（见 recon.md 的 G1/G3 实测）。
REASONING_TEXT = "上下文压缩后，我先 read 相关文件，获取 todo 列表"

#: **追加在缓存前缀之后**的总结指令（最后一条 user 消息）。
#: 两个硬要求：必须含 "json" 字样（DeepSeek JSON 模式的硬要求）；不要太长
#: （它紧跟在被复用的前缀后面，越短越省）。
SUMMARY_INSTRUCTION = """以上是本次任务到目前为止的完整上下文。请把它压成"继续这个任务所必需"的要点，\
并**只输出一个 json 对象**（不要别的文字）：

{
  "background": "任务背景与目标、用户的关键约束（一段话）",
  "trajectory": "已经做过什么、结论是什么、哪些尝试失败或已被推翻（不要罗列无关细节）",
  "files_changed": [{"path": "工作空间相对路径", "change": "新增/修改/删除 + 一句话"}],
  "required_files": [{"path": "工作空间相对路径", "start_line": 1, "line_count": 80,
                      "why": "为什么后续必须读它"}]
}

规则：
- 路径只允许**工作空间相对路径**（如 `lib/a.dart`、`docs/x.md`），不要绝对路径、不要 `..`；
- `required_files` 不超过 %(max_files)d 个，按重要性排序，**精确到行范围**（只给真正要读的那段）；
  优先列：核心文档 / 计划文档（`.self/plan/**`）/ 正在编辑或与任务直接相关的模块；
  不要列目录、不要列日志、不要列你已完整读过且结论已写进 trajectory 的文件；
- `files_changed` 只列**改动或产出的文件**（不是读过的文件）；
- 拿不准的字段宁可留空，**不要编造路径**。
"""


# ── 协议通道（模块级、可替换：自检时换成内存流，见 minimal_plugin.py 的说明） ──
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
    """日志**只走 stderr**（写 stdout 等于污染协议）。"""
    line = "[compact_plugin %s] %s\n" % (time.strftime("%H:%M:%S"), text)
    err = getattr(STDERR, "buffer", None)
    if err is None:
        STDERR.write(line)
        STDERR.flush()
        return
    err.write(line.encode("utf-8", "backslashreplace"))
    err.flush()


def clip(text, limit):
    """按字符截断并标注（截断必须可见，否则模型以为读全了）。"""
    value = text if isinstance(text, str) else str(text or "")
    if limit <= 0 or len(value) <= limit:
        return value
    return "%s…[截断，共 %d 字]" % (value[:limit], len(value))


class Options(object):
    """命令行选项（全部有默认值；内置插件面板启用时不传任何参数）。"""

    def __init__(self):
        self.keep_rounds = 1
        self.keep_tool_rounds = 8
        self.max_files = 11
        self.max_lines_per_file = 400
        self.max_chars_total = 60000
        self.command_timeout = 180.0
        self.reasoning_text = REASONING_TEXT
        self.dry_run = False

    def parse(self, argv):
        index = 0
        while index < len(argv):
            name = argv[index]
            value = argv[index + 1] if index + 1 < len(argv) else ""
            if name == "--keep-rounds":
                self.keep_rounds = _positive_int(value, self.keep_rounds)
                index += 2
                continue
            if name == "--keep-tool-rounds":
                self.keep_tool_rounds = _positive_int(value, self.keep_tool_rounds)
                index += 2
                continue
            if name == "--max-files":
                self.max_files = _positive_int(value, self.max_files)
                index += 2
                continue
            if name == "--max-lines-per-file":
                self.max_lines_per_file = _positive_int(
                    value, self.max_lines_per_file)
                index += 2
                continue
            if name == "--max-chars-total":
                self.max_chars_total = _positive_int(value, self.max_chars_total)
                index += 2
                continue
            if name == "--command-timeout":
                try:
                    self.command_timeout = float(value)
                except ValueError:
                    pass
                index += 2
                continue
            if name == "--reasoning-text":
                self.reasoning_text = value
                index += 2
                continue
            if name == "--dry-run":
                self.dry_run = True
                index += 1
                continue
            index += 1


def _positive_int(raw, fallback):
    try:
        value = int(str(raw).strip())
    except (TypeError, ValueError):
        return fallback
    return value if value > 0 else fallback


def _non_negative_int(raw):
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return 0
    return value if value > 0 else 0


# ── wire 形态的小工具（只认 LlmMessage 的线形状） ────────────────────────────


def role_of(message):
    return str((message or {}).get("role") or "")


def has_tool_calls(message):
    calls = (message or {}).get("tool_calls")
    return isinstance(calls, list) and len(calls) > 0


def is_tool(message):
    return role_of(message) == "tool"


def is_user(message):
    return role_of(message) == "user"


class CompactPlugin(object):
    """串起整条压缩流水线；所有对外动作都走 `command()`（自检时可替换）。"""

    def __init__(self, options):
        self.options = options
        self.plugin_id = "compact"
        self.name = "上下文压缩（内置）"
        self._send_lock = threading.Lock()
        self._pending_lock = threading.Lock()
        self._pending = {}
        self._request_seq = 0
        self._hello = threading.Event()
        self._counters = {"requests": 0, "taken": 0, "declined": 0}

    # ── 协议通道 ────────────────────────────────────────────────────────

    def _send(self, message):
        with self._send_lock:
            send(message)

    def _reply(self, request_id, result=None, error=None):
        message = {"jsonrpc": JSONRPC_VERSION, "id": request_id}
        if error is not None:
            message["error"] = error
        else:
            message["result"] = result if result is not None else {}
        self._send(message)

    def notify(self, method, params):
        self._send({"jsonrpc": JSONRPC_VERSION, "method": method, "params": params})

    def request_core(self, method, params, timeout=None):
        """插件**主动**发一条请求并等核心响应（核心必回且只回一条）。"""
        with self._pending_lock:
            self._request_seq += 1
            request_id = "compact-req-%d" % self._request_seq
            gate = threading.Event()
            holder = {}
            self._pending[request_id] = (gate, holder)
        self._send({
            "jsonrpc": JSONRPC_VERSION,
            "id": request_id,
            "method": method,
            "params": params,
        })
        wait = self.options.command_timeout if timeout is None else timeout
        if not gate.wait(wait):
            with self._pending_lock:
                self._pending.pop(request_id, None)
            return {"timeout": True, "method": method}
        return holder

    def command(self, command, arguments, scope=None):
        """经**执行站**下一条命令（`llm.call` / `fs.read` / `tool.call`）。

        [scope] 是这一次命令的身份：核心按目标 agent 的**真实归属**解析 team / mode，
        `plugins.yaml` 的 scope 只是上限——所以 `scope: {}` 的内置开关形态照样能用。
        身份同时写进 `params` 顶层与 `arguments`（挂载位置只读 arguments）。
        """
        params = {"command": command, "arguments": arguments}
        if scope:
            for key, value in scope.items():
                if value:
                    params[key] = value
        response = self.request_core(METHOD_STATION_COMMAND, params)
        if response.get("timeout"):
            return {"ok": False, "error": "等待核心响应超时", "command": command}
        error = response.get("error")
        if isinstance(error, dict):
            return {"ok": False, "error": error.get("message", ""), "command": command}
        result = response.get("result")
        return result if isinstance(result, dict) else {"ok": False, "error": "空结果"}

    def subscribe_compact_point(self):
        """订阅压缩点位（`replace: false`：绝不抢占别人的订阅）。"""
        response = self.request_core(METHOD_STATION_SUBSCRIBE, {
            "station": "relay",
            "point": "context.compact",
            "replace": False,
        })
        if response.get("timeout") or isinstance(response.get("error"), dict):
            error = response.get("error") or {}
            return {"ok": False, "error": error.get("message") or "超时"}
        result = response.get("result")
        return result if isinstance(result, dict) else {"ok": False, "error": "空结果"}

    # ── 入站请求 ────────────────────────────────────────────────────────

    def handle_request(self, request_id, method, params):
        """**必须且只能回一条响应**；异常收敛成 -32603（绝不冲掉读循环）。"""
        try:
            if method == "hello":
                self.plugin_id = str(params.get("plugin_id") or self.plugin_id)
                self._reply(request_id, {
                    "plugin_id": self.plugin_id,
                    "name": self.name,
                    "capabilities": ["stations"],
                })
                self._hello.set()
                threading.Thread(target=self._subscribe_loop, name="subscribe",
                                 daemon=True).start()
                return
            if method == "tools/list":
                # 本插件不申报工具（它只消费压缩点位）
                self._reply(request_id, {"tools": []})
                return
            if method == METHOD_STATION_REQUEST:
                self._reply(request_id, self.handle_station_request(params))
                return
            if method == "ping":
                self._reply(request_id, {"ok": True, "ts": int(time.time())})
                return
            self._reply(request_id, error={
                "code": ERR_METHOD_NOT_FOUND,
                "message": "method not found: %s" % method,
            })
        except Exception as error:  # noqa: BLE001 - 异常必须变成响应，不能让核心挂住
            self._reply(request_id, error={
                "code": ERR_INTERNAL,
                "message": "compact 插件处理 %s 异常：%r" % (method, error),
            })

    def _subscribe_loop(self):
        """握手后订阅点位；失败就有限重试（核心可能还没把站点挂好）。"""
        for attempt in range(1, 6):
            result = self.subscribe_compact_point()
            if result.get("ok"):
                log("已订阅 %s（第 %d 次尝试）" % (STATION_RELAY_CONTEXT_COMPACT, attempt))
                return
            log("订阅失败（第 %d 次）：%s" % (attempt, result.get("error")))
            time.sleep(1.0)
        log("订阅 %s 连续失败：本插件不会接管压缩（"
            "若已有别的插件占着这个点位，先停用它）" % STATION_RELAY_CONTEXT_COMPACT)

    def handle_station_request(self, params):
        """站点 → 插件的请求。只认真实订阅的那个点位，其余一律"不改动"。"""
        station_id = str(params.get("station_id") or "")
        if station_id != STATION_RELAY_CONTEXT_COMPACT:
            return {"reply": {"payload": None}}
        return {"reply": {"payload": self.handle_compact(params)}}

    # ── 压缩主体 ────────────────────────────────────────────────────────

    def handle_compact(self, params):
        """中转站压缩：返回回包 payload（dict）或 None（不接管）。"""
        started = time.time()
        self._counters["requests"] += 1
        payload = params.get("payload")
        if not isinstance(payload, dict):
            log("压缩请求缺少 payload 对象：不接管")
            return self._decline()
        scope = params.get("scope")
        scope = scope if isinstance(scope, dict) else {}
        agent_id = str(payload.get("agent_id") or scope.get("agent_id") or "")
        session_id = str(payload.get("session_id") or scope.get("session_id") or "")
        identity = {"agent_id": agent_id, "session_id": session_id}
        system_prompt = str(payload.get("system_prompt") or "")
        total = _non_negative_int(payload.get("total_message_count"))
        frozen = _non_negative_int(payload.get("compacted_message_count"))

        # 原料：引擎这一轮真会发的那份请求（没有它就不接管——不同口径的前缀没有意义）
        request = payload.get("request")
        if not isinstance(request, dict):
            log("载荷没有 request（引擎口径的线形请求）：不接管")
            return self._decline()
        wire = request.get("messages")
        if not isinstance(wire, list) or not wire:
            log("request.messages 不是非空数组：不接管")
            return self._decline()
        tools = request.get("tools")
        tools = tools if isinstance(tools, list) else None

        # 切点（wire 坐标）。
        # **不做"输入超预算就把 cut 往前推"那种自适应**：总结输入就是引擎本来要发的
        # 一份前缀（有界，且超长工具结果早已被门控换成"提示 + 预览"）+ 一条短指令；
        # 真撞上窗口上限时会由端点报错 ⇒ llm.call 失败 ⇒ 这里回 null ⇒ 核心走内置
        # compact（12k 字截断摘要）。而"推 cut"的副作用是**多留原文、压得更少**，方向反了。
        cut = self.wire_cut(wire, self.options.keep_rounds)
        if cut <= 0:
            log("没有可压的内容（切点 %d：整段都要保留）：不接管" % cut)
            return self._decline()

        # 总结调用：**前缀 = request.messages[:cut]**（与对话逐字一致 ⇒ 命中缓存），
        # 末尾只追加一条 user 指令；tools 原样透传（前缀对齐的另一半）。
        # 注意：**不用** llm.call 的 system 参数（那会在最前面插 system 消息，整体错位）。
        call_messages = list(wire[:cut])
        call_messages.append({
            "role": "user",
            "content": SUMMARY_INSTRUCTION % {"max_files": self.options.max_files},
        })
        arguments = {
            "messages": call_messages,
            "agent_id": agent_id,
            "session_id": session_id,
        }
        if tools:
            arguments["tools"] = tools
        summary_result = self.command("llm.call", arguments, scope=identity)
        if not summary_result.get("ok"):
            log("llm.call 失败：%s（不接管）" % summary_result.get("error"))
            return self._decline()
        summary_payload = summary_result.get("payload")
        summary_payload = summary_payload if isinstance(summary_payload, dict) else {}
        parsed = summary_payload.get("json")
        if not isinstance(parsed, dict):
            log("总结模型没有回 json 对象（text 前 120 字：%s）：不接管"
                % clip(str(summary_payload.get("text") or ""), 120))
            return self._decline()
        usage = summary_payload.get("usage") or {}
        log("摘要完成：模型=%s 前缀 %d 条 prompt_tokens=%s cached_tokens=%s"
            % (summary_payload.get("model"), cut, usage.get("prompt_tokens"),
               usage.get("cached_tokens")))

        # 必读文件 + todo：同一条 assistant，多个 tool_calls（一一配对）
        entries = self.required_files(parsed)
        tool_calls = []
        tool_results = []
        budget = self.options.max_chars_total
        for index, entry in enumerate(entries):
            call_id = "call_read_%d" % (index + 1)
            tool_calls.append(self.read_call(call_id, entry))
            text = self.read_result(entry, identity, budget)
            budget -= len(text)
            tool_results.append({
                "role": "tool",
                "tool_call_id": call_id,
                "content": text,
            })
        todo_call_id = "call_todo_1"
        tool_calls.append({
            "id": todo_call_id,
            "type": "function",
            "function": {
                "name": "set_todo_list",
                "arguments": json.dumps({"action": "get"}, ensure_ascii=False),
            },
        })
        tool_results.append({
            "role": "tool",
            "tool_call_id": todo_call_id,
            "content": self.todo_result(identity),
        })

        assistant = {
            "role": "assistant",
            "content": "",
            "tool_calls": tool_calls,
        }
        if self.options.reasoning_text:
            assistant["reasoning_content"] = self.options.reasoning_text
        out_messages = [
            # ① 提示词槽位：内容由核心每轮用最新提示词覆盖（插件放快照即可）
            {"role": "system", "content": system_prompt},
            {"role": "system", "content": self.summary_text(parsed)},
            assistant,
        ]
        out_messages.extend(tool_results)
        # ④ 尾部原文**原样抄回**（助手工作 / 工具卡都在里面，一个字不改写）：
        #    这样 covered = 原文总条数，核心不需要按原文下标继续追加。
        out_messages.extend(wire[cut:])

        self._counters["taken"] += 1
        log("接管压缩：前缀 %d/%d 条（尾部保留 %d 条），"
            "必读 %d 个文件 + todo，共 %d 条上下文，耗时 %.1fs"
            % (cut, len(wire), len(wire) - cut, len(entries),
               len(out_messages), time.time() - started))
        if self.options.dry_run:
            log("--dry-run：拼好了但按「不接管」返回（核心会走内置 compact）")
            return self._decline()
        return {
            "messages": out_messages,
            # 尾部已抄进列表 ⇒ 原文全部覆盖（上界就是 total_message_count）
            "covered_message_count": total if total > 0 else frozen,
        }

    def _decline(self):
        self._counters["declined"] += 1
        return None

    # ── 切点（wire 坐标） ───────────────────────────────────────────────

    def wire_cut(self, messages, keep_rounds):
        """返回切点下标：`messages[:cut]` 进总结，`messages[cut:]` 原样保留。

        三条规则（顺序执行，后一条只可能把切点往后推）：
        1. 保留最近 `keep_rounds` 轮 user 及其之后（找不到就从头保留 = 切点 0）；
        2. 保留区里的工具轮（`assistant` + `tool_calls`）超过 `--keep-tool-rounds` 时，
           只留最后这么多轮（单轮超长工具轨迹因此压得动，也避免"压完还在阈值上"）；
        3. **切点不得落在 `tool` 消息上**：尾部若以孤儿工具结果开头，端点直接 400
           （它的 assistant 在总结那一侧，不会被发出去）。
        """
        length = len(messages)
        seen = 0
        cut = 0
        for index in range(length - 1, -1, -1):
            if not is_user(messages[index]):
                continue
            seen += 1
            if seen >= keep_rounds:
                cut = index
                break
        tool_starts = [
            index for index in range(cut, length) if has_tool_calls(messages[index])
        ]
        limit = self.options.keep_tool_rounds
        if len(tool_starts) > limit:
            cut = tool_starts[len(tool_starts) - limit]
        while cut < length and is_tool(messages[cut]):
            cut += 1
        return cut

    # ── 必读文件 / todo ─────────────────────────────────────────────────

    def required_files(self, parsed):
        """归一 `required_files`：非法项**保留成失败条目**（模型要看得到原因）。"""
        raw = parsed.get("required_files")
        if not isinstance(raw, list):
            return []
        entries = []
        for item in raw:
            if len(entries) >= self.options.max_files:
                break
            entries.append(self.normalize_file(item))
        return entries

    def normalize_file(self, item):
        if isinstance(item, str):
            item = {"path": item}
        if not isinstance(item, dict):
            return {"path": "", "start_line": 0, "line_count": 0,
                    "why": "", "error": "必读条目必须是对象或字符串"}
        path = str(item.get("path") or "").strip().replace("\\", "/")
        while path.startswith("./"):
            path = path[2:]
        why = str(item.get("why") or "").strip()
        error = ""
        if not path:
            error = "缺少 path"
        elif path.startswith("/") or (len(path) > 1 and path[1] == ":"):
            error = "只允许工作空间相对路径（拿到的是绝对路径：%s）" % path
        elif ".." in path.split("/"):
            error = "路径不能越出工作空间（含 ..）：%s" % path
        start_line = _non_negative_int(item.get("start_line"))
        line_count = _non_negative_int(item.get("line_count"))
        if line_count > self.options.max_lines_per_file:
            line_count = self.options.max_lines_per_file
        return {"path": path, "start_line": start_line, "line_count": line_count,
                "why": why, "error": error}

    @staticmethod
    def read_call(call_id, entry):
        arguments = {"path": entry["path"]}
        if entry["start_line"] > 0:
            arguments["start_line"] = entry["start_line"]
        if entry["line_count"] > 0:
            arguments["line_count"] = entry["line_count"]
        return {
            "id": call_id,
            "type": "function",
            "function": {
                "name": "read",
                "arguments": json.dumps(arguments, ensure_ascii=False),
            },
        }

    def read_result(self, entry, identity, budget):
        """读一个必读文件；失败也返回可读文本（tool_calls 与结果必须一一对应）。"""
        path = entry["path"]
        why = ("（%s）" % entry["why"]) if entry["why"] else ""
        if entry["error"]:
            return "读取失败 %s%s：%s" % (path, why, entry["error"])
        arguments = {"path": path}
        arguments.update(identity)
        if entry["start_line"] > 0:
            arguments["start_line"] = entry["start_line"]
        if entry["line_count"] > 0:
            arguments["line_count"] = entry["line_count"]
        result = self.command("fs.read", arguments, scope=identity)
        if not result.get("ok"):
            return "读取失败 %s%s：%s" % (path, why, result.get("error") or "未知原因")
        data = result.get("payload")
        data = data if isinstance(data, dict) else {}
        content = str(data.get("content") or "")
        header = "%s%s（共 %s 行，本次从第 %s 行起）" % (
            path, why, data.get("total_lines"), data.get("start_line"))
        allow = max(0, budget - len(header) - 8)
        body = clip(content, allow) if allow > 0 else "…（本次必读总量已达上限，未读取）"
        return "%s\n%s" % (header, body)

    def todo_result(self, identity):
        """待办快照：`tool.call` 调真实的 `set_todo_list get`（真数据、真工具）。"""
        arguments = {"tool": "set_todo_list", "arguments": {"action": "get"}}
        arguments.update(identity)
        result = self.command("tool.call", arguments, scope=identity)
        if not result.get("ok"):
            return "待办读取失败：%s" % (result.get("error") or "未知原因")
        data = result.get("payload")
        data = data if isinstance(data, dict) else {}
        text = str(data.get("result") or "")
        if data.get("is_error"):
            return "待办读取失败：%s" % clip(text, 400)
        return "## 待办（set_todo_list 快照）\n%s" % clip(
            text.strip() or "（暂无待办）", 4000)

    @staticmethod
    def summary_text(parsed):
        background = str(parsed.get("background") or "").strip()
        trajectory = str(parsed.get("trajectory") or "").strip()
        lines = [
            "## 背景",
            background or "（无）",
            "",
            "## 轨迹",
            trajectory or "（无）",
            "",
            "## 改动与产出文件",
        ]
        files = parsed.get("files_changed")
        if isinstance(files, list) and files:
            for item in files:
                if isinstance(item, dict):
                    path = str(item.get("path") or "").strip()
                    change = str(item.get("change") or "").strip()
                else:
                    path, change = str(item).strip(), ""
                if not path and not change:
                    continue
                lines.append("- %s%s" % (path, ("：" + change) if change else ""))
        else:
            lines.append("- （本次没有改动/产出文件）")
        return "\n".join(lines)

    # ── 读循环 ──────────────────────────────────────────────────────────

    def on_notification(self, method, params):
        if method == "shutdown":
            log("收到 shutdown，退出")
            sys.exit(0)
        # station/cancel（我们没接流式）与 event 等通知：忽略即可

    def serve(self):
        """读循环（主线程）：响应唤醒等待者；请求**另开线程**；通知就地处理。"""
        log("已启动，等待核心握手（stdout 只走 JSON-RPC）")
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
                with self._pending_lock:
                    entry = self._pending.pop(request_id, None)
                if entry is not None:
                    entry[1].update(message)
                    entry[0].set()
                continue
            if isinstance(method, str) and method and request_id is not None:
                # **另开线程**：压缩要等 llm.call / fs.read 的回包，读循环不能被占住
                # （等待期间核心还会发 ping；不回 ping 会被判失活 ⇒ 中转请求立即失败）
                threading.Thread(
                    target=self.handle_request,
                    args=(request_id, method, message.get("params") or {}),
                    name="req-%s" % method,
                    daemon=True,
                ).start()
                continue
            self.on_notification(str(method or ""), message.get("params") or {})


# ── 自检（假命令通道：真编排逻辑，不连真核心） ─────────────────────────────


def _wire_fixture(rounds=1, tail_user="第三轮要求"):
    """一段引擎口径的 wire 上下文：system×2 + 两轮历史 + 最后一条 user。"""
    messages = [
        {"role": "system", "content": "你是助手（引擎拼装的提示词）"},
        {"role": "system", "content": "【上一次压缩的摘要】"},
        {"role": "user", "content": "第一轮要求"},
        {"role": "assistant", "content": "第一轮回答"},
    ]
    for index in range(rounds):
        messages.append({"role": "user", "content": "第 %d 轮要求" % (index + 2)})
        messages.append({
            "role": "assistant",
            "content": "",
            "reasoning_content": "先读一下文件",
            "tool_calls": [{
                "id": "c%d" % index,
                "type": "function",
                "function": {"name": "read",
                             "arguments": "{\"path\": \"lib/a.dart\"}"},
            }],
        })
        messages.append({"role": "tool", "tool_call_id": "c%d" % index,
                         "content": "class A {}"})
        messages.append({"role": "assistant", "content": "第 %d 轮回答" % (index + 2)})
    messages.append({"role": "user", "content": tail_user})
    messages.append({"role": "assistant", "content": "最后一轮回答"})
    return messages


def _single_turn_fixture(rounds):
    """**单轮超长工具轨迹**：一条 user，后面跟 `rounds` 个工具轮 + 收尾回答。

    这正是"keep 死保整轮"会压不动的情形：切点必须在轮**内部**往前挪。
    """
    messages = [
        {"role": "system", "content": "你是助手（引擎拼装的提示词）"},
        {"role": "user", "content": "把整个仓库扫一遍并修掉所有 TODO"},
    ]
    for index in range(rounds):
        messages.append({
            "role": "assistant",
            "content": "",
            "reasoning_content": "继续扫",
            "tool_calls": [{
                "id": "s%d" % index,
                "type": "function",
                "function": {"name": "grep",
                             "arguments": "{\"q\": \"TODO\", \"page\": %d}" % index},
            }],
        })
        messages.append({"role": "tool", "tool_call_id": "s%d" % index,
                         "content": "第 %d 轮工具结果" % (index + 1)})
    messages.append({"role": "assistant", "content": "扫完了，共 10 处"})
    return messages


def _summary_fixture():
    return {
        "background": "用户要求把登录改成 JWT。",
        "trajectory": "已定位 auth 模块为 session 实现。",
        "files_changed": [{"path": "lib/auth.dart", "change": "修改：改为 JWT 校验"}],
        "required_files": [
            {"path": "lib/auth.dart", "start_line": 1, "line_count": 60,
             "why": "正在改的模块"},
            {"path": "docs/plan.md", "why": "计划文档"},
            {"path": "E:/abs/path.md", "why": "非法：绝对路径"},
            {"path": "../escape.md", "why": "非法：越界"},
            {"path": "missing.md", "why": "读失败"},
        ],
    }


def _fixture_command(summary_json, fail_commands=()):
    """假命令通道：记录调用，按命令返回与核心同形状的结果。"""
    calls = []

    class _Fake(object):
        def __call__(self, command, arguments, scope=None):
            calls.append({"command": command, "arguments": arguments,
                          "scope": scope})
            if command in fail_commands:
                return {"ok": False, "error": "%s 被用例置为失败" % command}
            if command == "llm.call":
                return {"ok": True, "command": command, "payload": {
                    "ok": True, "json": summary_json,
                    "text": json.dumps(summary_json, ensure_ascii=False),
                    "model": "demo-model",
                    "usage": {"prompt_tokens": 1200, "cached_tokens": 1100},
                }}
            if command == "fs.read":
                path = arguments.get("path")
                if path == "missing.md":
                    return {"ok": False, "error": "文件不存在"}
                return {"ok": True, "command": command, "payload": {
                    "path": path, "content": "// %s 的内容" % path,
                    "total_lines": 120,
                    "start_line": arguments.get("start_line") or 1,
                    "truncated": False,
                }}
            if command == "tool.call":
                return {"ok": True, "command": command, "payload": {
                    "tool": "set_todo_list", "is_error": False,
                    "result": "- [~] t1 | status=in_progress progress=50 | 改 JWT",
                }}
            return {"ok": False, "error": "未知命令 %s" % command}

    return _Fake(), calls


def _params(wire, frozen=0):
    return {
        "station_id": STATION_RELAY_CONTEXT_COMPACT,
        "scope": {"team_id": "t1", "agent_id": "agt_1", "session_id": "ses_1"},
        "payload": {
            "agent_id": "agt_1",
            "session_id": "ses_1",
            "system_prompt": "你是助手（压缩时快照）",
            "total_message_count": 12,
            "compacted_message_count": frozen,
            "existing_summary": "",
            "compacted": False,
            "request": {
                "model": "demo-model",
                "messages": wire,
                "tools": [{"type": "function",
                           "function": {"name": "read", "description": "读文件",
                                        "parameters": {"type": "object"}}}],
                "stream": False,
            },
        },
    }


def _payload_of(reply):
    """从站点回包里取出 payload（非 dict / 缺字段一律 None = 不接管）。"""
    if not isinstance(reply, dict):
        return None
    body = reply.get("reply")
    if not isinstance(body, dict):
        return None
    return body.get("payload")


def _plugin(summary=None, fail_commands=()):
    plugin = CompactPlugin(Options())
    fake, calls = _fixture_command(summary or _summary_fixture(), fail_commands)
    plugin.command = fake
    return plugin, calls


def _roles(messages):
    return [message.get("role") for message in messages]


def _structure_problems(messages):
    """结构合法性（两条硬规则的机器版本，端点 400 的根因都在这）：

    1. 每条 `tool` 消息必须有**前置**的 `assistant(tool_calls)` 且 `tool_call_id` 配对
       ——否则是"孤儿工具结果"；
    2. 每条带 `tool_calls` 的 `assistant` 必须被后续的 `tool` 结果**配平**，且中间不得
       被别的消息（`user` / `system` / 下一条 `assistant`）打断——否则是"悬空 tool_calls"。
    """
    problems = []
    pending = []
    for index, message in enumerate(messages):
        role = role_of(message)
        if role == "assistant":
            if pending:
                problems.append("第 %d 条 assistant 打断了未配对的 tool_calls：%s"
                                % (index, pending))
                pending = []
            if has_tool_calls(message):
                pending = [str((call or {}).get("id") or "")
                           for call in message.get("tool_calls") or []]
            continue
        if role == "tool":
            call_id = str(message.get("tool_call_id") or "")
            if call_id not in pending:
                problems.append("第 %d 条 tool 没有配对的前置 tool_calls：%s"
                                % (index, call_id))
            else:
                pending.remove(call_id)
            continue
        if pending:
            problems.append("第 %d 条 %s 打断了未配对的 tool_calls：%s"
                            % (index, role, pending))
            pending = []
    if pending:
        problems.append("结尾仍有未配对的 tool_calls：%s" % pending)
    return problems


def selftest():
    """真编排 + 假命令：把最容易静默出错的几条钉死。"""
    failures = []
    wire = _wire_fixture(rounds=1)

    # ① 正常接管：切点 = 最后一条 user；尾部原样抄回；covered = 原文总条数
    plugin, calls = _plugin()
    payload = _payload_of(plugin.handle_station_request(_params(wire)))
    if not isinstance(payload, dict):
        failures.append("接管失败：回包 payload 不是对象")
        return _report(failures, calls, plugin)
    cut = plugin.wire_cut(wire, plugin.options.keep_rounds)
    if payload.get("covered_message_count") != 12:
        failures.append("covered 应为原文总条数 12，实际 %s"
                        % payload.get("covered_message_count"))
    out = payload.get("messages") or []
    expected_roles = (["system", "system", "assistant"] + ["tool"] * 6
                      + _roles(wire[cut:]))
    if _roles(out) != expected_roles:
        failures.append("回包角色序列不对：%s" % _roles(out))
    if out[0].get("content") != "你是助手（压缩时快照）":
        failures.append("首条不是提示词槽位：%s" % out[0])
    if "## 背景" not in str(out[1].get("content")):
        failures.append("第二条不是摘要：%s" % out[1])
    assistant = out[2]
    if assistant.get("reasoning_content") != REASONING_TEXT:
        failures.append("伪推理缺失：%s" % assistant.get("reasoning_content"))
    tool_calls = assistant.get("tool_calls") or []
    results = [m for m in out if m.get("role") == "tool"]
    if len(tool_calls) != 6:
        failures.append("tool_calls 应为 6（5 读 + 1 todo），实际 %d" % len(tool_calls))
    if [m.get("tool_call_id") for m in results] != [c.get("id") for c in tool_calls]:
        failures.append("tool_calls 与 tool 结果没有一一配对")
    if (tool_calls[-1].get("function") or {}).get("name") != "set_todo_list":
        failures.append("最后一个 tool_call 应是 set_todo_list")
    if out[len(out) - (len(wire) - cut):] != wire[cut:]:
        failures.append("尾部没有原样抄回（顺序或内容变了）")

    # ② 总结调用：前缀 = request.messages[:cut] + 一条 user 指令；带 tools；不用 system
    llm_calls = [c for c in calls if c["command"] == "llm.call"]
    if len(llm_calls) != 1:
        failures.append("llm.call 应恰好 1 次，实际 %d" % len(llm_calls))
    else:
        sent = llm_calls[0]["arguments"]["messages"]
        if sent[:-1] != wire[:cut]:
            failures.append("总结前缀与对话前缀不逐字一致（缓存会失效）")
        last = sent[-1]
        if last.get("role") != "user" or "json" not in str(last.get("content")):
            failures.append("末尾不是含 json 字样的 user 指令：%s" % last)
        if "system" in llm_calls[0]["arguments"]:
            failures.append("不该用 llm.call 的 system 参数（会让前缀整体错位）")
        if not llm_calls[0]["arguments"].get("tools"):
            failures.append("tools 没有透传（前缀对齐的另一半）")
        if "最后一轮回答" in json.dumps(sent, ensure_ascii=False):
            failures.append("keep 段不该进总结输入")

    # ③ 必读文件 / todo：非法路径与读失败都留可读结果；行范围与身份透传
    text = json.dumps(results, ensure_ascii=False)
    for must in ["只允许工作空间相对路径", "含 ..", "文件不存在", "在改的模块",
                 "## 待办"]:
        if must not in text:
            failures.append("必读/todo 结果缺少：%s" % must)
    reads = [c for c in calls if c["command"] == "fs.read"]
    if not reads or reads[0]["arguments"].get("start_line") != 1 \
            or reads[0]["arguments"].get("line_count") != 60:
        failures.append("行范围没有透传：%s" % reads[:1])
    if not reads or reads[0]["arguments"].get("agent_id") != "agt_1" \
            or reads[0]["scope"].get("session_id") != "ses_1":
        failures.append("fs.read 没带身份：%s" % reads[:1])

    # ④ 工具轮上限：**单轮**里 10 个工具轮 ⇒ 只保留最后 8 轮（单轮超长轨迹因此压得动）
    single = _single_turn_fixture(10)
    capped, capped_calls = _plugin()
    if not isinstance(_payload_of(capped.handle_station_request(_params(single))), dict):
        failures.append("工具轮上限用例接管失败")
    else:
        kept_start = capped.wire_cut(single, capped.options.keep_rounds)
        kept = single[kept_start:]
        rounds_kept = len([m for m in kept if has_tool_calls(m)])
        if rounds_kept != capped.options.keep_tool_rounds:
            failures.append("工具轮上限没生效：保留了 %d 轮" % rounds_kept)
        if kept and is_tool(kept[0]):
            failures.append("切点落在 tool 消息上（尾部会出现孤儿工具结果）")
        sent = [c for c in capped_calls
                if c["command"] == "llm.call"][0]["arguments"]["messages"]
        if "第 1 轮工具结果" not in json.dumps(sent, ensure_ascii=False):
            failures.append("被挤出去的早期工具轮没有进总结输入")

    # ⑤ 切点**永不落在 `tool` 消息上**（尾部以孤儿工具结果开头 ⇒ 端点 400）
    for name, fixture in [
        ("单轮 10 轮工具", _single_turn_fixture(10)),
        ("多轮 3 轮工具", _wire_fixture(rounds=3)),
        ("首条就是 tool", [{"role": "tool", "tool_call_id": "c", "content": "x"},
                           {"role": "user", "content": "要求"}]),
    ]:
        probe = CompactPlugin(Options())
        for rounds in (1, 2, 5):
            position = probe.wire_cut(fixture, rounds)
            if 0 < position < len(fixture) and is_tool(fixture[position]):
                failures.append("孤儿保护失效（%s / keep=%d）：切点 %d"
                                % (name, rounds, position))

    # ⑥ 没有 request / 没有可压内容 / llm.call 失败 ⇒ 一律不接管
    no_request, _ = _plugin()
    without = _params(wire)
    without["payload"].pop("request")
    if _payload_of(no_request.handle_station_request(without)) is not None:
        failures.append("没有 request 时应回 null")
    nothing, _ = _plugin()
    only_tail = _params([{"role": "user", "content": "刚开的新会话"}])
    if _payload_of(nothing.handle_station_request(only_tail)) is not None:
        failures.append("没有可压内容时应回 null")
    failing, _ = _plugin(fail_commands=("llm.call",))
    if _payload_of(failing.handle_station_request(_params(wire))) is not None:
        failures.append("llm.call 失败时应回 null")

    # ⑦ 多轮 fixture：总结输入与回包**都必须结构合法**（无孤儿 tool / 无悬空 tool_calls），
    #    且总结输入末端必须是 user 指令
    multi, multi_calls = _plugin()
    multi_payload = _payload_of(multi.handle_station_request(
        _params(_wire_fixture(rounds=3))))
    if not isinstance(multi_payload, dict):
        failures.append("多轮 fixture 接管失败")
    else:
        sent = [c for c in multi_calls
                if c["command"] == "llm.call"][0]["arguments"]["messages"]
        if sent[-1].get("role") != "user":
            failures.append("多轮 fixture 的总结输入末端不是 user 指令")
        if multi_payload.get("covered_message_count") != 12:
            failures.append("多轮 fixture 的 covered 不是原文总条数：%s"
                            % multi_payload.get("covered_message_count"))
        for label, messages in (("总结输入", sent),
                                ("回包上下文", multi_payload["messages"])):
            problems = _structure_problems(messages)
            if problems:
                failures.append("%s结构不合法：%s" % (label, problems))

    # ⑦b 三种 fixture × 默认配置：结构都必须合法（这是 400 的机器化防线）
    for name, fixture in [
        ("多轮 1 轮工具", _wire_fixture(rounds=1)),
        ("多轮 3 轮工具", _wire_fixture(rounds=3)),
        ("单轮 12 轮工具", _single_turn_fixture(12)),
    ]:
        probe, probe_calls = _plugin()
        result = _payload_of(probe.handle_station_request(_params(fixture)))
        if not isinstance(result, dict):
            failures.append("%s：接管失败" % name)
            continue
        sent = [c for c in probe_calls
                if c["command"] == "llm.call"][0]["arguments"]["messages"]
        for label, messages in (("总结输入", sent), ("回包上下文", result["messages"])):
            problems = _structure_problems(messages)
            if problems:
                failures.append("%s / %s 结构不合法：%s" % (name, label, problems))
        if result.get("covered_message_count") != 12:
            failures.append("%s：covered 不是原文总条数" % name)

    # ⑦c **超大输入照样接管**：这里刻意不设"输入太大就少压一点"的自适应
    #    （那只会多留原文、压得更少）；真撞窗口上限时由端点报错 ⇒ 回 null
    huge = _wire_fixture(rounds=2)
    huge.insert(2, {"role": "user", "content": "粘了一整份日志：" + "x" * 300000})
    huge_plugin, huge_calls = _plugin()
    huge_payload = _payload_of(huge_plugin.handle_station_request(_params(huge)))
    if not isinstance(huge_payload, dict):
        failures.append("超大输入时应照常接管（不该有预算自适应）")
    else:
        sent = [c for c in huge_calls
                if c["command"] == "llm.call"][0]["arguments"]["messages"]
        if len(sent) != huge_plugin.wire_cut(huge, huge_plugin.options.keep_rounds) + 1:
            failures.append("超大输入的总结输入长度不对：%d" % len(sent))
        if _structure_problems(huge_payload["messages"]):
            failures.append("超大输入的回包结构不合法")

    # ⑧ 必读上限
    capped5, calls5 = _plugin()
    capped5.options.max_files = 2
    if not isinstance(_payload_of(capped5.handle_station_request(_params(wire))), dict):
        failures.append("max_files 用例接管失败")
    else:
        reads5 = [c for c in calls5 if c["command"] == "fs.read"]
        if len(reads5) != 2:
            failures.append("max_files=2 时读了 %d 个文件" % len(reads5))

    # ⑨ 非本点位：一律"不改动"
    other = _payload_of(plugin.handle_station_request(
        {"station_id": "system.relay.prompt.system"}))
    if other is not None:
        failures.append("非本点位请求不该回填充")

    return _report(failures, calls, plugin)


def _report(failures, calls, plugin):
    for failure in failures:
        sys.stdout.write("[FAIL] %s\n" % failure)
    sys.stdout.write(
        "compact_plugin 自检：%s（%d 次命令调用，接管 %d / 拒绝 %d）\n" % (
            "全部通过" if not failures else "有失败项",
            len(calls), plugin._counters["taken"], plugin._counters["declined"]))
    return 0 if not failures else 1


def main():
    options = Options()
    options.parse(sys.argv[1:])
    plugin = CompactPlugin(options)
    return plugin.serve()


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    sys.exit(main())
