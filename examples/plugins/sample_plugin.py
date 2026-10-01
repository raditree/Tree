#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tree_core 示例插件（Python，**仅标准库**）：四站 + 插件布局全链路演示。

一句话：**它把核心发来的每一次工具调用都数一遍；某个 (agent, session) 超过阈值，
就经执行站发 agent.stop 停掉这一轮**——这正是 Q8「核心不设工具轮次上限，限制交给
插件做」的参考实现。同时把当前计数推成前端消息流里的一张卡片（插件布局）。

四件事（与本文件内的四段实现一一对应）：

1. **收集站**（_handle_station_request）：核心按站点 schema 来收集工具定义，本插件
   申报 echo / rounds / read_probe 三个工具，于是模型能调到
   plugin__<插件id>__echo（插件 id 取 plugins.yaml 的 id；id: sample 时为
   plugin__sample__echo）。tools/call 时返回结果。
2. **广播 / 事件订阅**（_on_event + _do_stop）：接收 agent.tool_call 事件，按
   (agent_id, session_id) 计数；**超过阈值（默认 200）** 就经 station/command 发
   agent.stop；发完**重置计数**并打一条可见日志（避免反复停）。
   事件派发只看 scope 里限定的维度，空 scope = 收全部事件，所以计数与 team 声明无关。
3. **执行站**（fs_read / _do_startup）：插件**主动**下 fs.read 命令读工作空间里的小
   文件，把结果打进日志（关键结论另发 log 通知，前端可见）。
4. **插件布局**（declare_panel / push_card）：`ui/manifest` 申报三个槽位
   （activity 左侧活动栏 + panel 右栏 Tab + **card 消息流卡片**），之后用 ui/update
   与 ui.push 刷新它们，内容 = 当前计数 / 阈值 / 进度。
   ⚠ card 槽位必须先在 manifest 里申报：`ui.push` 只发 update 帧、不建槽位，
   没申报过的 slot_key 会被前端静默忽略（卡片永远不出现，且没有任何报错）。

── 协议（行分隔 JSON-RPC 2.0，与 packages/tree_core/test/fixtures/fake_plugin.dart
   完全同构；那份 Dart 实现是本文件的对照物） ──────────────────────────────

核心 → 插件：
  - 请求（带 id）：hello（握手，params 里带 plugin_id）/ tools/list / tools/call /
    station/request（收集站采集请求）/ ping（心跳）；
  - 通知（无 id）：event（总线事件，本插件关心 agent.tool_call）/ shutdown（退出）。

插件 → 核心（宿主按**报文形状**分三类，顺序即优先级）：
  - 响应：有 id 且**没有 method** ⇒ 回填核心的在途请求；
  - 请求：**method + id** ⇒ 核心必回一条响应（M9 的「插件主动下命令」通道）。
    目前支持 station/command：入参 {command, arguments, team_id?, agent_id?,
    session_id?, mode_key?}，result 形如 {command, ok, mount_id, payload, error}；
    错误码 -32601 未知方法 / -32602 参数 / -32603 处理器异常 / -32001 scope 不满足；
    **单实例 + 每条消息带身份**：目标 agent 取请求里的 agent_id，team / mode 由核心按
    该 agent 的真实归属解析；plugins.yaml 的 scope 是**作用域上限**（声明了 team 就
    只能在自己 team 内活动）。
  - 通知：无 id（log / event）⇒ 核心转成前端 plugin_event。

── 边界情况（踩过的坑，务必保留） ───────────────────────────────────────

* **stdout 只允许 JSON-RPC**：任何日志走 stderr（核心收集 stderr 供排障；写坏 stdout
  等于污染协议）。本插件把 stdout / stderr 都**按 UTF-8 字节**写：Windows 上 Python
  对管道默认用 ANSI 代码页（如 cp936）编码，中文会变成非法 UTF-8 字节，核心侧只能
  按 U+FFFD 顶替（M9 3-O 治理的正是这条边界）。
* **入站请求必须另开线程处理**：处理 tools/call 时本插件可能还要「主动问核心」
  （read_probe 要等 station/command 的回包），而回包同样从 stdin 进来——若在读循环里
  同步等回包就会**死锁**。Dart 版 fake_plugin 靠单线程事件循环天然避开这一坑，Python
  必须显式开线程（见 _handle_request 的 threading.Thread）。
* **插件主动请求带 method + id**：核心用「有没有 method」区分响应与请求，所以用字符串
  id（sample-req-N）最省心；用 int 也不会被误当回包（判别不看 id 撞号）。
* **station/request 回包形状** = {reply: {payload: {...}}}；**不要**回带 scope——回带了
  就必须与请求四元组**精确相等**，否则整条回包被判跨 scope 拒绝。
* **收集站 schema 是严格校验**：根对象只允许 tools 一个键（多一个键即报「未声明的
  字段」）；每个工具定义含 tool_name / description / parameters / execution。
* **阈值触发后重置计数**：否则每一次后续调用都会再发一次 agent.stop（反复停）。
* **空 scope = 通配（作用于所有 team）**：`plugins.yaml` 不写 `scope.team_id` 也能
  `station/subscribe`（空 team 收所有 team 的消息、空 mode 收 local 与 ssh），
  `ui.push` 的帧带空 team_id（前端在任何 team 下都呈现）。仍然 fail-closed 的只有
  **消息信封**（中转 / 广播 / 收集的数据面必须能证明 team）与**执行类命令的落地**
  （挂载位置解析不出目标 agent 的 team / 工作面就拒绝执行）。
  本插件对"订阅被拒"仍留了一层防御性兜底（旧核心）：等第一个事件给出 `agent_id` 后
  在 worker 线程补订、`ui.push` 带上该身份。新核心里这条路径不会被触发。
* **本文件的 30s 等待**只为示例日志不永久挂住：核心侧对插件请求**没有静态超时**
  （plan §1.1：判活靠心跳），所以插件不该自己设"任务总时长"上限。

运行环境：Python 3.8+（标准库；无第三方依赖）。启动方式见 examples/plugins/README.md。
"""

import json
import os
import queue
import sys
import threading
import time

# ── 协议常量 ────────────────────────────────────────────────────────────────
JSONRPC_VERSION = "2.0"
METHOD_STATION_REQUEST = "station/request"
METHOD_STATION_COMMAND = "station/command"
EVENT_TOOL_CALL = "agent.tool_call"
PHASE_START = "start"
PHASE_END = "end"

# JSON-RPC 错误码（与核心 PluginRpcErrorCode 同表）
ERR_METHOD_NOT_FOUND = -32601
ERR_INVALID_PARAMS = -32602
ERR_INTERNAL = -32603

# 命令名（执行站首命令集里本插件用到的两条）
CMD_FS_READ = "fs.read"
CMD_UI_PUSH = "ui.push"
CMD_AGENT_STOP = "agent.stop"

DEFAULT_THRESHOLD = 200
DEFAULT_SLOT_KEY = "sample.card.tool_rounds"

ENV = {
    "threshold": "SAMPLE_PLUGIN_TOOL_ROUND_LIMIT",
    "agent_id": "SAMPLE_PLUGIN_AGENT_ID",
    "read_path": "SAMPLE_PLUGIN_READ_PATH",
    "team_id": "SAMPLE_PLUGIN_TEAM_ID",
    "slot_key": "SAMPLE_PLUGIN_SLOT_KEY",
    "card_interval": "SAMPLE_PLUGIN_CARD_INTERVAL",
    "cascade": "SAMPLE_PLUGIN_STOP_CASCADE",
}


class Options(object):
    """运行参数：命令行 > 环境变量 > 默认值。"""

    def __init__(self):
        self.threshold = DEFAULT_THRESHOLD
        self.agent_id = ""
        self.read_path = "README.md"
        self.team_id = ""
        self.slot_key = DEFAULT_SLOT_KEY
        self.card_interval = 5.0
        self.card_min_interval = 1.0
        self.cascade = False
        self.fs_demo = True
        # 中转站订阅：工具调用前/后各来一次（pre / post），插件决定改不改
        self.relay = True
        # 声明左侧活动栏 / 右栏面板 / 消息流卡片槽位（ui/manifest；card 必须先申报）
        self.panel = True
        # 自建站点演示（station/register + 按 station_id 订阅）：
        # 站点全局唯一、每个点位只有一个订阅者，插件要按 team / agent 分开处理时，
        # 正解是"自己建站再分发"——这个开关把那条路走一遍。
        self.self_station = False


def _env(name):
    value = os.environ.get(name)
    return value if value is not None else ""


def _print_help():
    # 帮助一律走 stderr：stdout 是协议通道，--help 也不能污染它。
    sys.stderr.write(
        "sample_plugin.py —— tree_core 示例插件（Python 标准库）\n"
        "\n"
        "命令行参数（同名环境变量见括号）：\n"
        "  --threshold N        工具轮次阈值，超过即发 agent.stop（默认 %d）\n"
        "                       （%s）\n"
        "  --agent-id ID        执行站命令的目标 agent（默认取事件里的 agent）\n"
        "                       （%s）\n"
        "  --read-path PATH     启动自检要读的工作空间文件，相对路径（默认 README.md）\n"
        "                       （%s）\n"
        "  --team-id TEAM       仅用于日志/卡片文案；**作用域以 plugins.yaml 为准**\n"
        "                       （%s）\n"
        "  --slot-key KEY       卡片槽位键（默认 %s）（%s）\n"
        "  --card-interval SEC  卡片周期刷新秒数（默认 5）（%s）\n"
        "  --stop-cascade       agent.stop 级联停整棵团队树（默认只停该 agent）\n"
        "                       （%s=1）\n"
        "  --no-relay           不订阅中转站（默认订阅：工具调用前/后各一次）\n"
        "  --self-station       自建一个广播站并订阅它（演示插件自建站点：\n"
        "                       站点全局唯一 + 每个点位只有一个订阅者，\n"
        "                       需按 team 分流时由插件自己建站分发）\n"
        "  --no-panel           不声明插件面板槽位（默认声明 activity + panel + card）\n"
        "  --no-fs-demo         不做启动 fs.read 自检\n"
        "  -h, --help           本帮助（打到 stderr）\n"
        % (
            DEFAULT_THRESHOLD,
            ENV["threshold"],
            ENV["agent_id"],
            ENV["read_path"],
            ENV["team_id"],
            DEFAULT_SLOT_KEY,
            ENV["slot_key"],
            ENV["card_interval"],
            ENV["cascade"],
        )
    )


def parse_options(argv):
    """手写解析（不用 argparse：要保证 --help / 报错都不写 stdout）。"""
    options = Options()
    # 环境变量兜底
    if _env(ENV["threshold"]).strip():
        options.threshold = int(_env(ENV["threshold"]).strip())
    if _env(ENV["agent_id"]).strip():
        options.agent_id = _env(ENV["agent_id"]).strip()
    if _env(ENV["read_path"]).strip():
        options.read_path = _env(ENV["read_path"]).strip()
    if _env(ENV["team_id"]).strip():
        options.team_id = _env(ENV["team_id"]).strip()
    if _env(ENV["slot_key"]).strip():
        options.slot_key = _env(ENV["slot_key"]).strip()
    if _env(ENV["card_interval"]).strip():
        options.card_interval = float(_env(ENV["card_interval"]).strip())
    if _env(ENV["cascade"]).strip() in ("1", "true", "True", "yes"):
        options.cascade = True

    values = {
        "--threshold": "threshold",
        "--agent-id": "agent_id",
        "--read-path": "read_path",
        "--team-id": "team_id",
        "--slot-key": "slot_key",
        "--card-interval": "card_interval",
    }
    index = 0
    while index < len(argv):
        token = argv[index]
        if token in ("-h", "--help"):
            _print_help()
            sys.exit(0)
        if token == "--no-fs-demo":
            options.fs_demo = False
            index += 1
            continue
        if token == "--no-relay":
            options.relay = False
            index += 1
            continue
        if token == "--no-panel":
            options.panel = False
            index += 1
            continue
        if token == "--self-station":
            options.self_station = True
            index += 1
            continue
        if token == "--stop-cascade":
            options.cascade = True
            index += 1
            continue
        if token in values:
            if index + 1 >= len(argv):
                sys.stderr.write("参数 %s 缺少取值\n" % token)
                sys.exit(2)
            raw = argv[index + 1]
            field = values[token]
            if field in ("threshold",):
                setattr(options, field, int(raw))
            elif field in ("card_interval",):
                setattr(options, field, float(raw))
            else:
                setattr(options, field, raw)
            index += 2
            continue
        sys.stderr.write("未知参数：%s（用 --help 看用法；注意 stdout 是协议通道）\n" % token)
        sys.exit(2)
    return options


class SamplePlugin(object):
    """插件主体：入站三类判别 + 四站演示。"""

    def __init__(self, options):
        self.options = options
        # 插件 id：以核心 hello 里的 plugin_id 为准（= plugins.yaml 的 id）；
        # 工具在模型眼里的名字是 plugin__<插件id>__<工具名>，由核心按来源路由。
        self.plugin_id = "sample"
        self.name = "示例插件（Python）"

        # 计数状态（只数 phase=start）
        self.counts = {}       # (agent_id, session_id) -> 本任务内计数
        self.started_at = {}   # (agent_id, session_id, call_id) -> monotonic
        self.total_started = 0
        self.stop_count = 0
        self.last_duration_ms = None
        self.first_agent_seen = ""
        # 事件里见过的第一个 session（懒订阅中转站 / 卡片按 agent 下发时补全身份用）
        self.first_session_seen = ""
        # 中转站是否已订阅成功（懒订阅：没声明 team 时只能等事件告诉我们 agent）
        self._relay_subscribed = False
        # 启动时订中转站被拒（多半缺 team）⇒ 等第一个事件给出 agent 后再试一次
        self._relay_lazy_pending = False
        # 中转站：本插件处理过的中转请求数（pre / post 各算一次）
        self.relay_handled = 0
        self._state_lock = threading.Lock()

        # stdout / stderr 写锁（多个线程都会写）
        self._io_lock = threading.Lock()
        self._stderr_lock = threading.Lock()

        # 插件主动请求：id -> (Event, holder)；由读循环回填
        self._pending = {}
        self._pending_lock = threading.Lock()
        self._next_request_id = 0

        # 后台任务（停止信号 / 卡片 / fs 自检）：**绝不在读循环里同步等回包**
        self._jobs = queue.Queue()
        self._worker = threading.Thread(target=self._work_loop, name="worker")
        self._worker.daemon = True
        self._timer = threading.Thread(target=self._timer_loop, name="timer")
        self._timer.daemon = True
        self._hello = threading.Event()
        self._closed = False
        self._last_card_at = 0.0

    # ── 出站：写 stdout（永远 UTF-8 字节） ────────────────────────────────

    def _send(self, message):
        data = (json.dumps(message, ensure_ascii=False) + "\n").encode("utf-8")
        with self._io_lock:
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()

    def _stderr(self, text):
        with self._stderr_lock:
            sys.stderr.buffer.write(text.encode("utf-8", "backslashreplace"))
            sys.stderr.buffer.flush()

    def log(self, message, notify=False, level="info"):
        """日志：**永远写 stderr**；notify=True 时另发一条 log 通知（前端 plugin_event）。"""
        stamp = time.strftime("%H:%M:%S")
        self._stderr("[sample_plugin %s] %s\n" % (stamp, message))
        if notify:
            try:
                self.notify("log", {"level": level, "message": message})
            except Exception:
                pass

    def notify(self, method, params):
        """通知（无 id）⇒ 核心转发成前端 plugin_event。"""
        self._send({"jsonrpc": JSONRPC_VERSION, "method": method, "params": params})

    def request_core(self, method, params, timeout=30.0):
        """插件**主动**发一条请求并等核心响应（核心必回且只回一条）。"""
        with self._pending_lock:
            self._next_request_id += 1
            request_id = "sample-req-%d" % self._next_request_id
            gate = threading.Event()
            holder = {}
            self._pending[request_id] = (gate, holder)
        self._send({
            "jsonrpc": JSONRPC_VERSION,
            "id": request_id,
            "method": method,
            "params": params,
        })
        # 这个等待只是示例自身的兜底（不让日志永久挂住）；核心侧对插件请求**没有
        # 静态超时**（判活靠心跳），所以插件不该把"任务总时长"写死在这里。
        if not gate.wait(timeout):
            with self._pending_lock:
                self._pending.pop(request_id, None)
            return {"timeout": True, "method": method}
        return holder

    def command(self, command, arguments, scope=None):
        """经**执行站**下一条命令。

        [scope] 是**这一次命令的身份**（`{agent_id / session_id / team_id}`）：
        单实例插件的正解——不带 agent 的团队级命令（ui.push）在没声明
        `scope.team_id` 时定不出作用域会被 fail-closed 拒绝，带上 agent_id 后核心
        按该 agent 的真实归属解析，因此**空 scope 的配置也能推卡片**。
        留空 = 只按 plugins.yaml 的声明。
        """
        params = {"command": command, "arguments": arguments}
        if scope:
            params.update({key: value for key, value in scope.items() if value})
        response = self.request_core(METHOD_STATION_COMMAND, params)
        if response.get("timeout"):
            self.log("station/command %s 等不到核心响应（示例兜底超时）" % command)
            return {"ok": False, "error": "等待核心响应超时", "command": command}
        error = response.get("error")
        if isinstance(error, dict):
            # 未知方法 / 参数非法 / 处理器异常 / scope 不满足（-32001）：**显式**记下来
            self.log("station/command %s 被核心拒绝：code=%s message=%s"
                     % (command, error.get("code"), error.get("message")), notify=True)
            return {"ok": False, "error": error.get("message", ""), "command": command}
        result = response.get("result")
        return result if isinstance(result, dict) else {"ok": False, "error": "空结果"}

    def subscribe_station(self, station, replace=False, station_id="", scope=None):
        """**订阅站点**（协议方法）：`station/subscribe`。

        两种寻址方式（二选一）：
        - `station`：按**类型**订内置站——`relay`（工具调用前/后各一次，核心把完整
          tool_call 报文交过来，插件改什么、甚至不改，都由插件内部决定）或
          `broadcast`（发布-订阅读）；
        - `station_id`：按**实例 id** 订某个具体站点（自建站的消费入口）。

        [scope] 是**订阅声明的身份**（如 `{agent_id: ...}`）：plugins.yaml 的 scope 是
        作用域上限，请求里带 agent 时核心按该 agent 的真实归属解析出 team ——
        **没声明 `scope.team_id` 的插件因此在学到 agent 后仍能订上中转站**。

        订阅被业务规则拒绝（已被占 / 超上限 / 缺 team / 不是自己的自建站）时返回里带
        可读 `error`，不会变成一句"调用失败"。
        """
        params = {"station_id": station_id} if station_id else {"station": station}
        params["replace"] = replace
        if scope:
            params["scope"] = {key: value for key, value in scope.items() if value}
        label = station_id or station
        response = self.request_core("station/subscribe", params)
        if response.get("timeout") or isinstance(response.get("error"), dict):
            error = response.get("error") or {}
            message = error.get("message") or "超时"
            self.log("订阅 %s 站点失败：%s" % (label, message), notify=True)
            # 一律回"可判定的结果"（含传输层失败）：调用方据此决定要不要推迟重订
            return {"ok": False, "error": message}
        result = response.get("result") or {}
        if result.get("ok"):
            self.log("已订阅 %s 站点：station_id=%s scope=%s"
                     % (label, result.get("station_id"), result.get("scope")))
        else:
            self.log("订阅 %s 站点被拒：%s" % (label, result.get("error")), notify=True)
        return result

    def register_own_station(self, kind="broadcast", name="team_fanout"):
        """**自建站点并订阅**（协议方法）：`station/register` → `station/subscribe`。

        为什么需要它（用户定稿语义）：站点全局唯一、**每个点位只有一个订阅者**。
        插件要按 team / agent 分开处理时，不能"每个 team 订一份"，而应由一个
        转发型订阅者接管内置站，再**自己建站**做分发——建站必须经核心，否则下游
        没有回包通道与等待链。

        要点：**id 由核心拼**（`plugin.<插件id>.<类型>.<name>`），插件不能自选 id；
        所以这里只给 `kind` + `name`，并用返回的 `station_id` 去订阅。
        """
        response = self.request_core("station/register", {
            "kind": kind,
            "name": name,
            "description": "示例插件自建站：按 team 再分发",
        })
        if response.get("timeout") or isinstance(response.get("error"), dict):
            error = response.get("error") or {}
            self.log("自建站点失败：%s" % (error.get("message") or "超时"), notify=True)
            return ""
        result = response.get("result") or {}
        if not result.get("ok"):
            self.log("自建站点被拒：%s" % result.get("error"), notify=True)
            return ""
        station_id = result.get("station_id") or ""
        self.log("已自建站点：%s（id 由核心按插件身份拼装）" % station_id)
        # 建完就订阅自己（转发型订阅者的第一步）；别的插件订不到别人的站
        self.subscribe_station("", station_id=station_id)
        return station_id

    # ── 工具定义（收集站申报 + tools/list 共用一份，避免两处写歪） ─────────

    def tool_definitions(self):
        return [
            {
                "tool_name": "echo",
                "description": "回显输入（示例插件的收集站申报工具）",
                "parameters": {
                    "type": "object",
                    "properties": {"text": {"type": "string"}},
                    "required": ["text"],
                },
                "execution": {"method": "tools/call", "name": "echo"},
            },
            {
                "tool_name": "rounds",
                "description": "查看示例插件统计的工具调用轮次（计数 / 阈值 / 已停次数）",
                "parameters": {"type": "object", "properties": {}},
                "execution": {"method": "tools/call", "name": "rounds"},
            },
            {
                "tool_name": "read_probe",
                "description": "经执行站 fs.read 读一个工作空间文件（演示插件主动下命令）",
                "parameters": {
                    "type": "object",
                    "properties": {"path": {"type": "string"}},
                },
                "execution": {"method": "tools/call", "name": "read_probe"},
            },
        ]

    def tools_list(self):
        """tools/list 形状：**未声明 team** 的插件走这条老路径（工具仍可用）。"""
        return [
            {
                "name": definition["tool_name"],
                "description": definition["description"],
                "inputSchema": definition["parameters"],
            }
            for definition in self.tool_definitions()
        ]

    def call_tool(self, name, arguments):
        if name == "echo":
            return self._text_result("plugin-echo: %s" % arguments.get("text", ""))
        if name == "rounds":
            with self._state_lock:
                counts = dict(self.counts)
                total = self.total_started
                stops = self.stop_count
                duration = self.last_duration_ms
            return self._text_result(json.dumps({
                "plugin_id": self.plugin_id,
                "threshold": self.options.threshold,
                "total_started": total,
                "stop_count": stops,
                "last_duration_ms": duration,
                "counts": {"%s|%s" % key: value for key, value in counts.items()},
            }, ensure_ascii=False))
        if name == "read_probe":
            path = arguments.get("path") or self.options.read_path
            summary = self.fs_read(path=path, reason="read_probe 工具调用")
            if summary is None:
                return self._text_result("fs.read 失败（详见插件 stderr 日志）", is_error=True)
            return self._text_result(summary)
        return self._text_result("未知工具 %s" % name, is_error=True)

    @staticmethod
    def _text_result(text, is_error=False):
        return {"content": [{"type": "text", "text": text}], "isError": is_error}

    # ── ① 收集站：按站点 schema 申报工具定义 ──────────────────────────────

    def _handle_station_request(self, params):
        """站点 → 插件的请求（收集站与中转站共用这条 `station/request` 通道）。

        - `kind == "collect"`（收集站）：回包 payload 必须**严格**符合站点 schema
          （根对象只允许 tools 一个键；每个元素 = 一条工具定义）；
        - `kind == "relay"`（中转站）：核心把**完整 tool_call 报文**放在 payload 里
          （`phase` = pre | post）。插件返回的内容即"最终数据"：
          返回改过的报文 = 改写生效；返回 `None` = 什么都不改（放行原数据）；
          返回非法类型 = 核心按 fail-open 放行原数据并记原因。
          这里演示：pre 阶段给参数补一个 `_relay_seen` 标记，post 阶段给结果加一行统计。
        """
        kind = params.get("kind")
        if kind == "relay":
            payload = params.get("payload")
            if not isinstance(payload, dict):
                # 返回 None 表示"不改动"，但这里参数形态不对，显式说明更好排查
                return {"reply": {"error": "中转请求的 payload 必须是对象"}}
            phase = payload.get("phase")
            with self._state_lock:
                relay_count = self.relay_handled + 1
                self.relay_handled = relay_count
            if phase == "pre":
                arguments = payload.get("arguments")
                if not isinstance(arguments, dict):
                    arguments = {}
                # 演示"插件自己决定改不改"：只加一个标记键，不动业务参数
                return {"reply": {"payload": {
                    **payload,
                    "arguments": {**arguments, "_relay_seen": relay_count},
                }}}
            if phase == "post":
                result = payload.get("result")
                text = result if isinstance(result, str) else str(result)
                # 面板里显示"已处理中转次数"（有声明面板时才刷）
                if self.options.panel:
                    self.update_panel()
                return {"reply": {"payload": {
                    **payload,
                    "result": "%s\n[示例插件] 本次工具调用已经过中转（第 %d 次）"
                              % (text, relay_count),
                }}}
            # 未知 phase：不改动（显式返回 None = 放行原数据）
            return {"reply": {"payload": None}}
        if kind != "collect":
            # 本插件只订阅收集站与中转站；其余站点类型显式拒绝（不静默）
            return {"reply": {"error": "示例插件只响应收集站（collect）与中转站（relay）"
                                       "请求，收到 kind=%s" % kind}}
        schema = params.get("schema") or {}
        fields = [field.get("name") for field in (schema.get("fields") or [])]
        if fields and "tools" not in fields:
            return {"reply": {"error": "站点 schema 未声明 tools 字段：%s" % fields}}
        definitions = self.tool_definitions()
        self.log("收集站请求：申报 %d 个工具（%s）"
                 % (len(definitions), ", ".join(d["tool_name"] for d in definitions)))
        return {"reply": {"payload": {"tools": definitions}}}

    # ── ② 广播 / 事件订阅：数轮次，超阈值就发停止信号 ──────────────────────

    def _on_event(self, params):
        if params.get("event") != EVENT_TOOL_CALL:
            # 订阅是 scope 通配的（plugins.yaml 里 scope 为空即收全部事件），
            # 其它事件只记 stderr，不做任何动作。
            self.log("收到非 tool_call 事件（忽略）：%s" % params.get("event"))
            return
        agent_id = str(params.get("agent_id", ""))
        session_id = str(params.get("session_id", ""))
        call_id = str(params.get("call_id", ""))
        phase = params.get("phase")
        with self._state_lock:
            if agent_id and not self.first_agent_seen:
                self.first_agent_seen = agent_id
            if session_id and not self.first_session_seen:
                self.first_session_seen = session_id
            # 懒订阅中转站：启动时没订上（多半是没声明 scope.team_id ⇒ 缺 team），
            # 现在事件把 agent 告诉我们了 —— 只入队，绝不在读循环里等回包。
            lazy_relay = (
                self.options.relay
                and not self._relay_subscribed
                and self._relay_lazy_pending
                and bool(agent_id)
            )
            if lazy_relay:
                self._relay_lazy_pending = False  # 只试一次，失败也不再重排
        if lazy_relay:
            self._jobs.put(("subscribe_relay", agent_id, session_id))
        if phase == PHASE_END:
            # 结束事件：统计耗时（插件契约里 end 就是为了这个）
            with self._state_lock:
                started = self.started_at.pop((agent_id, session_id, call_id), None)
                if started is not None:
                    self.last_duration_ms = int((time.monotonic() - started) * 1000)
            return
        if phase != PHASE_START:
            return
        key = (agent_id, session_id)
        with self._state_lock:
            count = self.counts.get(key, 0) + 1
            self.counts[key] = count
            self.total_started += 1
            self.started_at[(agent_id, session_id, call_id)] = time.monotonic()
            over = count > self.options.threshold
            if over:
                # **发完就重置**：否则后续每一次调用都会再发一次停止信号（反复停）
                self.counts[key] = 0
        if over:
            self.log("⚠ 工具轮次超限：agent=%s session=%s 本任务已调用 %d 次 > 阈值 %d"
                     " ⇒ 经执行站发 agent.stop，计数已重置"
                     % (agent_id, session_id, count, self.options.threshold), notify=True)
            # 读循环里**只入队**：等回包会死锁（回包也从同一条 stdin 进来）
            self._jobs.put(("stop", key, count))
        else:
            self._jobs.put(("card",))

    def _do_stop(self, key, count):
        """（worker 线程）发停止信号：执行站 agent.stop。"""
        agent_id, session_id = key
        result = self.command(CMD_AGENT_STOP, {
            "agent_id": agent_id,
            # 默认只停该 agent 的当前生成（cascade=false）；要停整棵团队树用
            # --stop-cascade / SAMPLE_PLUGIN_STOP_CASCADE=1。
            "cascade": self.options.cascade,
        })
        with self._state_lock:
            self.stop_count += 1
        self.log("agent.stop（第 %d 次）：ok=%s mount_id=%s error=%s"
                 % (self.stop_count, result.get("ok"), result.get("mount_id"),
                    result.get("error") or ""), notify=True)
        self.push_card(force=True)

    # ── ③ 执行站：插件主动下 fs.read ──────────────────────────────────────

    def fs_read(self, path=None, reason="启动自检"):
        """下一条 fs.read，把结果打进日志；返回可读摘要（失败返回 None）。

        agent_id 的取法：--agent-id / 环境变量优先；没配就用事件里见过的第一个 agent。
        核心按该 agent 的**真实归属**（team / mode）解析作用域，并与插件声明的上限做
        fail-closed 校验（跨 team / 身份对不上都会被拒，错误信息里能看出原因）。
        """
        target = self.options.agent_id or self.first_agent_seen
        target_path = path or self.options.read_path
        if not target:
            self.log("跳过 fs.read 演示（%s）：没有目标 agent（用 --agent-id 指定）" % reason)
            return None
        result = self.command(CMD_FS_READ, {
            "agent_id": target,
            "path": target_path,
            "line_count": 20,
        })
        if not result.get("ok"):
            self.log("fs.read 演示失败（%s）：agent=%s path=%s error=%s"
                     % (reason, target, target_path, result.get("error") or ""), notify=True)
            return None
        payload = result.get("payload") or {}
        content = payload.get("content") or ""
        lines = content.splitlines()
        preview = "\n".join(lines[:8])
        summary = ("fs.read 成功（%s）：agent=%s path=%s total_lines=%s truncated=%s"
                   "\n%s" % (reason, target, payload.get("path"), payload.get("total_lines"),
                              payload.get("truncated"), preview))
        self.log(summary, notify=True)
        return summary

    def _do_startup(self):
        """hello 之后的开工动作（在独立线程里：这里面要等核心回包）。"""
        self.log("已就绪：插件 id=%s 阈值=%d 槽位=%s（作用域见 plugins.yaml，"
                 "请求参数改不了作用域）"
                 % (self.plugin_id, self.options.threshold, self.options.slot_key),
                 notify=True)
        # **订阅中转站**：此后每次工具调用的前/后，核心都会把完整 tool_call 报文
        # 发过来（station/request，kind=relay），本插件决定改什么 / 不改。
        #
        # 空 scope 也是合法声明（通配：作用于所有 team），所以正常情况下这里一次就成。
        # 只在**被拒**时（旧核心的 fail-closed / 点位已被别的插件占用）才退到兜底：
        # 推迟到第一个事件之后按事件里的 agent_id 补订（单实例 + 每条消息带身份），
        # 代价是这一轮任务的**第一次工具调用**漏掉。
        if self.options.relay:
            result = self.subscribe_station("relay", replace=True)
            if result.get("ok"):
                self._relay_subscribed = True
            else:
                self._relay_lazy_pending = True
                self.log("中转站订阅推迟到第一个事件之后（本次被拒：%s）"
                         % (result.get("error") or "见上一条日志"), notify=True)
        # **自建站点**：站点全局唯一、每个点位只有一个订阅者；插件要按 team / agent
        # 分开处理时，正解是自己建站再分发（这里是那条路的最小演示）。
        if self.options.self_station:
            self.register_own_station()
        # **声明插件面板**：ui/manifest → 核心转成 plugin_ui_manifest 帧 →
        # 前端把它挂到左侧活动栏（activity 槽位）与右栏 Tab（panel 槽位）。
        if self.options.panel:
            self.declare_panel()
        if self.options.fs_demo:
            self._jobs.put(("fs", "启动自检"))
        self.push_card(force=True)

    # ── ④ 插件布局 A：声明左侧活动栏 / 右栏面板槽位 ───────────────────────

    def declare_panel(self):
        """发一条 `ui/manifest` **通知**（无 id）：声明本插件在该 team 上的全部槽位。

        - `activity` = 左侧活动栏项（和「Agent 列表 / 插件 / 下载」并列）；
        - `panel` = 右栏 Tab；
        - `card` = **消息流内联卡片**（push_card 的落点，见下）；
        - 视图是**声明式受限控件集**（text / list / table / form / progress /
          actions 与 row / column 容器）——**没有 webview、不执行插件 JS**；
        - `plugin_id` / `team_id` 一律由**核心按实例与 plugins.yaml 声明**填充，
          插件自述的这两个字段不会被采信（防越权）。

        ⚠ **card 槽位必须在这里申报一次**：`ui.push` 只发 `plugin_ui_update` 帧、
        **不建槽位**——前端的注册表要求「槽位先由 manifest 存在，update 才生效」，
        没申报过的 slot_key 会被直接忽略（表现为"卡片永远不出现"，且没有任何报错）。
        """
        slots = [
            {
                "slot_key": "%s.activity.1" % self.plugin_id,
                "slot": "activity",
                "title": "示例插件",
                "icon": "extension",
                "order": 10,
                "view": {
                    "type": "column",
                    "gap": 6,
                    "children": [
                        {"type": "text", "text": "示例插件 · 面板", "style": "title"},
                        {"type": "text",
                         "text": "工具轮次计数与中转处理次数都在这里刷新",
                         "style": "caption"},
                        {"type": "actions", "buttons": [
                            {"action_id": "refresh", "label": "刷新",
                             "style": "primary"},
                            {"action_id": "push_card", "label": "推一张卡片"},
                        ]},
                    ],
                },
            },
            {
                "slot_key": "%s.panel.1" % self.plugin_id,
                "slot": "panel",
                "title": "示例插件",
                "view": self.card_view(),
            },
            {
                # 消息流内联卡片：**必须在这里申报**，push_card 的 ui.push 才能生效
                "slot_key": self.options.slot_key,
                "slot": "card",
                "title": "示例插件 · 工具轮次监视",
                "order": 10,
                "view": self.card_view(),
            },
        ]
        self._notify("ui/manifest", {"slots": slots})
        self.log("已声明插件面板槽位 %d 个（activity + panel + card）" % len(slots))

    def _activity_view(self):
        """左侧活动栏视图：中转计数 + 工具轮次进度。"""
        return {
            "type": "column",
            "gap": 6,
            "children": [
                {"type": "text", "text": "示例插件 · 面板", "style": "title"},
                {"type": "text",
                 "text": "已处理中转 %d 次" % self.relay_handled, "style": "body"},
                {"type": "progress",
                 "value": min(1.0, float(self.total_started)
                              / float(max(1, self.options.threshold))),
                 "label": "工具轮次 / 阈值",
                 "detail": "%d / %d" % (self.total_started, self.options.threshold)},
                {"type": "actions", "buttons": [
                    {"action_id": "refresh", "label": "刷新"},
                ]},
            ],
        }

    def update_panel(self):
        """发 `ui/update`：按 slot_key **整块替换**某槽位视图（不做 diff）。

        `view` 缺省 / 为 null = 注销该槽位。

        **两个槽位一起刷**（activity + panel）：manifest 只在 hello 时发一次，之后的
        每一次刷新都走 ui/update。只刷 activity 会让右栏 Tab 永远停在启动那一刻的
        「已计数 0 次」——看起来像插件没生效，实际是那个视图从来没被更新过。
        """
        self._notify("ui/update", {
            "slot_key": "%s.activity.1" % self.plugin_id,
            "view": self._activity_view(),
        })
        self._notify("ui/update", {
            "slot_key": "%s.panel.1" % self.plugin_id,
            "view": self.card_view(),
        })

    def _notify(self, method, params):
        """发一条 JSON-RPC **通知**（无 id，核心不回包）。"""
        self._send({"jsonrpc": JSONRPC_VERSION, "method": method, "params": params})

    # ── ④ 插件布局：推 card 槽位帧 ────────────────────────────────────────

    def card_view(self):
        """声明式视图模型（受限控件集）：column 容器 + text / progress / table。"""
        with self._state_lock:
            counts = sorted(self.counts.items(), key=lambda item: -item[1])[:5]
            total = self.total_started
            stops = self.stop_count
            duration = self.last_duration_ms
        top = counts[0][1] if counts else 0
        threshold = max(1, self.options.threshold)
        rows = [
            [agent or "(空)", session or "(空)", str(count), "—"]
            for (agent, session), count in counts
        ]
        if not rows:
            rows = [["—", "—", "0", "—"]]
        duration_text = "—" if duration is None else "%d ms" % duration
        return {
            "type": "column",
            "gap": 6,
            "children": [
                {"type": "text", "text": "示例插件 · 工具轮次监视", "style": "title"},
                {
                    "type": "text",
                    "text": "阈值 %d 次 · 已计数 %d 次 · 已发停止 %d 次 · 最近一次耗时 %s"
                            % (self.options.threshold, total, stops, duration_text),
                    "style": "body",
                },
                {
                    "type": "progress",
                    "value": min(1.0, float(top) / float(threshold)),
                    "label": "当前最高计数 / 阈值",
                    "detail": "%d / %d" % (top, self.options.threshold),
                },
                {
                    "type": "table",
                    "columns": ["agent", "session", "计数", "最近耗时"],
                    "rows": rows,
                },
            ],
        }

    def push_card(self, force=False):
        """ui.push：**复用 4.1 的 card 槽位帧**（核心内置挂载位置 core.frontend.card，
        帧类型 plugin_ui_update，带 team_id）。

        槽位本身由 declare_panel 的 `ui/manifest` 申报（`ui.push` 只更新、不建槽位）。
        刷新时**顺带把面板也刷一遍**：三个视图同源，只刷一个会出现"卡片在跳、面板
        停在 0"的错位观感。

        命令身份：见过事件之后一律带 `agent_id` / `session_id`（`--agent-id` 显式指定
        时以它为准），这样**没声明 `scope.team_id` 的配置也能把卡片推出去**。
        """
        now = time.monotonic()
        if not force and (now - self._last_card_at) < self.options.card_min_interval:
            return  # 事件密集时节流，避免刷屏
        self._last_card_at = now
        if self.options.panel:
            self.update_panel()
        # **带上事件里学到的身份**：ui.push 是不带 agent 的团队级命令，没声明
        # `scope.team_id` 时定不出作用域会被拒；带 agent_id 后核心按该 agent 的真实
        # 归属解析 —— 空 scope 的配置因此也能推卡片（启动时还没有 agent，则只按声明）。
        scope = {}
        if not self.options.agent_id and self.first_agent_seen:
            scope = {"agent_id": self.first_agent_seen,
                     "session_id": self.first_session_seen}
        result = self.command(CMD_UI_PUSH, {
            "slot_key": self.options.slot_key,
            "view": self.card_view(),
        }, scope=scope)
        if result.get("ok"):
            self.log("卡片已推送：slot_key=%s" % self.options.slot_key)
        elif not self.first_agent_seen and not self.options.agent_id:
            # 启动那一刻还没见过任何事件 ⇒ 既没有声明 team 也借不到 agent 身份：
            # 这次推不出去是**预期内**的，等第一个事件到了就会带上 agent 重推。
            self.log("卡片暂未推送（还没有身份可用）：等第一个工具调用事件之后会带 "
                     "agent_id 重推；若一直失败，检查 plugins.yaml 的 scope.team_id")
        else:
            self.log("卡片推送失败（检查 plugins.yaml 是否声明了 scope.team_id，"
                     "以及前端通道是否可用）：%s" % (result.get("error") or ""), notify=True)

    # ── 入站：请求 / 响应 / 通知 ──────────────────────────────────────────

    def _reply(self, request_id, result=None, error=None):
        message = {"jsonrpc": JSONRPC_VERSION, "id": request_id}
        if error is not None:
            message["error"] = error
        else:
            message["result"] = result if result is not None else {}
        self._send(message)

    def _handle_request(self, request_id, method, params):
        """**必须且只能回一条响应**；异常收敛成 -32603（绝不冲掉读循环）。"""
        try:
            if method == "hello":
                self.plugin_id = str(params.get("plugin_id") or self.plugin_id)
                self._reply(request_id, {
                    "plugin_id": self.plugin_id,
                    "name": self.name,
                    "capabilities": ["tools", "events", "stations"],
                })
                self._hello.set()
                threading.Thread(target=self._do_startup, name="startup",
                                 daemon=True).start()
                return
            if method == "tools/list":
                self._reply(request_id, {"tools": self.tools_list()})
                return
            if method == "tools/call":
                name = str(params.get("name", ""))
                if not name:
                    # 参数非法用 -32602（与协议表的错误码一致，不静默）
                    self._reply(request_id, error={
                        "code": ERR_INVALID_PARAMS,
                        "message": "tools/call 需要 name（要调用的工具名）",
                    })
                    return
                arguments = params.get("arguments")
                if not isinstance(arguments, dict):
                    arguments = {}
                self._reply(request_id, self.call_tool(name, arguments))
                return
            if method == METHOD_STATION_REQUEST:
                self._reply(request_id, self._handle_station_request(params))
                return
            if method == "ping":
                # 心跳：回一条即算"这一拍活着"（核心对任意入站报文都记心跳）
                self._reply(request_id, {"ok": True, "ts": int(time.time())})
                return
            self._reply(request_id, error={
                "code": ERR_METHOD_NOT_FOUND,
                "message": "method not found: %s" % method,
            })
        except Exception as error:  # noqa: BLE001 - 异常必须变成响应，不能让核心挂住
            self._reply(request_id, error={
                "code": ERR_INTERNAL,
                "message": "示例插件处理 %s 异常：%r" % (method, error),
            })

    def _on_notification(self, method, params):
        if method == "event":
            self._on_event(params)
            return
        if method == "plugin_ui_action":
            # 用户在插件面板上点了按钮 / 提交了表单（前端 → 核心 → 插件）。
            # 核心只透传 slot_key / action_id / payload，语义由插件自己解释；
            # 惯例是**再推一帧 ui/update** 把槽位刷新。
            self._on_ui_action(params)
            return
        if method == "shutdown":
            self.log("收到 shutdown，退出")
            self._closed = True
            sys.exit(0)
        # 其余通知（例如核心未来新增的）只记 stderr：未知类型不该让插件崩。

    def _on_ui_action(self, params):
        """面板交互回调：刷新面板 / 推卡片。"""
        action_id = str(params.get("action_id", ""))
        slot_key = str(params.get("slot_key", ""))
        self.log("面板交互：slot=%s action=%s" % (slot_key, action_id))
        if action_id == "refresh":
            self.update_panel()
            return
        if action_id == "push_card":
            self.push_card(force=True)
            return
        # 未知 action：显式记下来（不静默），但不算错误
        self.log("未知的面板动作（忽略）：%s" % action_id)

    def serve(self):
        """读循环（主线程）：按形状分三类——响应 / 请求 / 通知。"""
        while True:
            raw = sys.stdin.buffer.readline()
            if not raw:
                self.log("stdin 已关闭（核心退出？），插件退出")
                return
            line = raw.decode("utf-8", "replace").strip()
            if not line:
                continue
            try:
                message = json.loads(line)
            except ValueError:
                self.log("收到非 JSON 行（跳过）：%s" % line[:200])
                continue
            if not isinstance(message, dict):
                continue
            method = message.get("method")
            request_id = message.get("id")
            if method is None and request_id is not None:
                # ① 响应：核心对我方主动请求的回包 —— 唤醒等待者
                with self._pending_lock:
                    entry = self._pending.pop(request_id, None)
                if entry is not None:
                    entry[1].update(message)
                    entry[0].set()
                continue
            if isinstance(method, str) and method and request_id is not None:
                # ② 请求：**另开线程**处理（处理中可能要等核心回包，读循环不能被占住）
                threading.Thread(
                    target=self._handle_request,
                    args=(request_id, method, message.get("params") or {}),
                    name="req-%s" % method,
                    daemon=True,
                ).start()
                continue
            # ③ 通知：无 id（log / event / shutdown）
            self._on_notification(str(method or ""), message.get("params") or {})

    # ── 后台线程 ──────────────────────────────────────────────────────────

    def _work_loop(self):
        while True:
            job = self._jobs.get()
            if job is None:
                return
            try:
                if job[0] == "stop":
                    self._do_stop(job[1], job[2])
                elif job[0] == "card":
                    self.push_card()
                elif job[0] == "fs":
                    self.fs_read(reason=job[1])
                elif job[0] == "subscribe_relay":
                    self._do_subscribe_relay(job[1], job[2])
            except Exception as error:  # noqa: BLE001 - 后台任务异常不影响协议循环
                self.log("后台任务 %s 异常（已忽略）：%r" % (job[0], error))

    def _do_subscribe_relay(self, agent_id, session_id):
        """（worker 线程）懒订阅中转站：用事件里的 agent 身份订。

        为什么能成：plugins.yaml 的 scope 是**作用域上限**，请求里带 agent 时核心按该
        agent 的**真实归属**解析 team —— 所以 `scope: {}` 的插件同样订得上。

        为什么只订一次：**每个点位只有一个订阅者**（中转站尤其）。订第二个 team 要用
        `replace=True` 抢点位，那会把前一个 team 的拦截丢掉；要按 team 分流，正解是
        自建站点再分发（见 `--self-station`）。
        """
        result = self.subscribe_station(
            "relay",
            replace=True,
            scope={"agent_id": agent_id, "session_id": session_id},
        )
        if result.get("ok"):
            self._relay_subscribed = True
            self.log("中转站已按事件身份订上：agent=%s session=%s（此后工具调用前/后各一次）"
                     % (agent_id, session_id), notify=True)
        else:
            self.log("中转站懒订阅仍失败（不重试）：%s" % (result.get("error") or "未知原因"),
                     notify=True)

    def _timer_loop(self):
        while not self._closed:
            time.sleep(max(1.0, self.options.card_interval))
            self._jobs.put(("card",))

    def run(self):
        self._worker.start()
        self._timer.start()
        self.log("示例插件启动，等待核心 hello（stdout 只走 JSON-RPC，日志见 stderr）")
        self.serve()


def main():
    options = parse_options(sys.argv[1:])
    SamplePlugin(options).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
