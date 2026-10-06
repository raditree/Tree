#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""**终端钩子稳定性探针**——起一个 3 小时的 terminal 任务，逐拍量它。

用途：核心执行站的 terminal 通路有三段：**启动**（`terminal.exec` + `command`）、
**hooks 轮询**（`terminal.exec` + `hook_action=status` / `cancel` + `task_id`）、
**工具运行超时广播**（`system.tool.timeout`，默认 300 s、每个运行只广播一次）。
任一段不稳定，长任务都成了黑盒：现场能观察到的只剩"还在跑 / 已经死了"。

本插件把三段都走一遍并把**每拍的时刻 / 结果 / 耗时**留成时间线：

1. `hello` 后立刻经执行站发一条后台 terminal 命令（默认 3 小时）；
2. 订阅 `system.tool.timeout` 广播，记下核心判定的超时时刻（不取消，只看它响没响）；
3. 每 `--interval` 秒发一次 `hook_action=status`，量"钩子还活着没"；
4. 到 `--hours` 小时后自动停；也可以点面板上的「提前结束」按钮（发
   `hook_action=cancel`）；
5. 全程把 `(时刻, 事件, 详情)` 写进内存时间线，推成左栏 `activity` 面板里的表格。

**为什么要 3 小时**：这是核心工具的**超时阈值（默认 300 s）**的 36 倍，也是
DeepSeek 长上下文缓存持久化窗口的若干倍——只要有一处心跳丢了 / 有一拍回报晚了 /
有一次超时广播该来没来，这张表上就能看出它在哪一段、什么时候开始不老实。

跑它（**不需要真核心**）：
    python terminal_probe_plugin.py --selftest

接入真核心（`plugins.yaml`）：
    plugins:
      - id: terminal_probe
        command: "D:/app/python/python.exe"
        args: ["E:/programs/Tree/desktop/examples/plugins/terminal_probe_plugin.py",
               "--hours", "3", "--interval", "30",
               "--agent-id", "agt_xxx"]
        enabled: true
        scope: {}
"""

import json
import os
import re
import sys
import threading
import time

JSONRPC_VERSION = "2.0"
METHOD_STATION_COMMAND = "station/command"
METHOD_STATION_REQUEST = "station/request"
METHOD_STATION_SUBSCRIBE = "station/subscribe"
METHOD_UI_MANIFEST = "ui/manifest"
METHOD_UI_UPDATE = "ui/update"

#: 执行站命令名（terminal 通路的唯一入口）
CMD_TERMINAL_EXEC = "terminal.exec"

#: 工具运行超时广播（拿到 `handle` 后可用 `tool.close` 显式关闭；本探针**不关**，
#: 只记它什么时候响了——"该响没响"也是一种稳定性问题）。
STATION_TOOL_TIMEOUT = "system.tool.timeout"

#: 面板按钮回调的事件名（判据在 `params.event` 上，**不是** `params.method`）
EVENT_UI_ACTION = "plugin_ui_action"

#: 左栏槽位键（`activity` = 活动栏图标 + 左栏整页，两处是同一个槽位）
SLOT_ACTIVITY = "terminal_probe.activity.1"
PANEL_TITLE = "终端稳定性探针"
PANEL_ICON = "terminal"

#: 受限控件集（协议 PluginUiViewType.all）
VIEW_TYPES = ("text", "list", "table", "form", "progress", "actions", "row", "column")

#: 时间线内部最多留多少条（面板只显示最近 MAX_POLL_ROWS 条）
MAX_TIMELINE = 800
MAX_POLL_ROWS = 25

#: 面板刷新节流（秒）
PANEL_MIN_INTERVAL = 0.5

#: 默认探针周期（小时）——足以跨越内核的 300 s 超时阈值与缓存持久化窗口
DEFAULT_HOURS = 3.0
#: 默认状态轮询间隔（秒）——间隔越短越能看出"哪一拍丢了"
DEFAULT_INTERVAL = 30.0


# ── 协议通道（模块级、可替换：自检时换成内存流，见 minimal_plugin.py 的说明） ──
STDIN = sys.stdin
STDOUT = sys.stdout
STDERR = sys.stderr

#: 从 terminal 回包文本里认 `shell=xxx`（比插件猜平台可靠得多）
SHELL_PATTERN = re.compile(r"shell\s*=\s*([A-Za-z0-9_.\-]+)", re.I)
POSIX_SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "ssh", "linux", "unix", "posix"}
CMD_SHELLS = {"cmd", "cmd.exe", "windows", "bat"}
POWERSHELL_SHELLS = {"powershell", "pwsh", "powershell.exe"}


def _sleep_command(kind, seconds):
    """长跑命令：**按 shell 家族生成**，不假设平台。"""
    seconds = max(1, int(seconds))
    if kind == "powershell":
        return "Start-Sleep -Seconds %d" % seconds
    if kind == "cmd":
        return "ping -n %d 127.0.0.1 > nul" % seconds
    return "sleep %d" % seconds


def _echo_command(text):
    """零成本命令：cmd / posix / powershell 三边都认 `echo`。"""
    return "echo %s" % text


def _looks_finished(text):
    """回包文本像“前台已经跑完”（而不是“后台已启动”）。"""
    value = str(text or "")
    return ("退出码" in value or "exit code" in value.lower()
            or "--- stderr ---" in value)


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
    line = "[terminal_probe %s] %s\n" % (time.strftime("%H:%M:%S"), text)
    err = getattr(STDERR, "buffer", None)
    if err is None:
        STDERR.write(line)
        STDERR.flush()
        return
    err.write(line.encode("utf-8", "backslashreplace"))
    err.flush()


def _duration_text(seconds):
    """秒数的人话（面板用）：< 60 s ⇒ 秒；< 1 h ⇒ 分秒；≥ 1 h ⇒ 时分。"""
    if not isinstance(seconds, (int, float)):
        return "—"
    seconds = int(max(0, seconds))
    if seconds < 60:
        return "%d s" % seconds
    if seconds < 3600:
        return "%d m %d s" % (seconds // 60, seconds % 60)
    hours = seconds // 3600
    minutes = (seconds % 3600) // 60
    return "%d h %d m" % (hours, minutes)


def _short_text(text, limit=120):
    value = text if isinstance(text, str) else str(text or "")
    if limit <= 0 or len(value) <= limit:
        return value
    return value[:limit] + "…"


def _positive_float(raw, fallback):
    try:
        value = float(str(raw).strip())
    except (TypeError, ValueError):
        return fallback
    return value if value > 0 else fallback


class Options(object):
    """命令行选项（全部有默认值；不带参数 = 起 3 小时探针，面板打开）。"""

    def __init__(self):
        self.hours = DEFAULT_HOURS
        self.interval = DEFAULT_INTERVAL
        # 「提前结束」按钮点下去时核心要不要 cascade（默认否：只停这一个 agent）
        self.agent_id = ""
        self.session_id = ""
        # 留空 = 平台默认命令（见 [_default_command]）
        self.command = ""
        # 默认用后台任务模式（带 `background: true` 提示）；--foreground 关掉
        # hook=true 才是核心的"后台任务模式"入口（键名是 `hook`，不是 `background`）
        self.background = True
        # output_file：hook 模式下的日志落点（留空 = 核心自取 .output/hook_<task_id>.log）
        self.output_file = ""
        # shell 家族：auto（从回包里的 `shell=` 学）/ posix / cmd / powershell
        self.shell = "auto"
        # 探针模式：auto（先 canary 再决定）/ hook（后台句柄轮询）/ echo（直接通路存活）
        self.mode = "auto"
        # 只声明面板、不启动探针（用于单独验面板形状）
        self.no_probe = False
        # --no-panel：一帧 UI 都不发（只当后台探针跑时用）
        self.no_panel = False
        # 每拍 `hook_action=status` 的等待超时（秒；核心侧无静态超时，靠心跳续期，
        # 这是插件自己兜底别永久挂住）
        self.command_timeout = 60.0

    def parse(self, argv):
        index = 0
        while index < len(argv):
            name = argv[index]
            value = argv[index + 1] if index + 1 < len(argv) else ""
            if name == "--hours":
                self.hours = _positive_float(value, self.hours)
                index += 2
                continue
            if name == "--interval":
                self.interval = _positive_float(value, self.interval)
                index += 2
                continue
            if name == "--command-timeout":
                self.command_timeout = _positive_float(value, self.command_timeout)
                index += 2
                continue
            if name == "--agent-id":
                self.agent_id = value
                index += 2
                continue
            if name == "--session-id":
                self.session_id = value
                index += 2
                continue
            if name == "--command":
                self.command = value
                index += 2
                continue
            if name == "--foreground":
                self.background = False
                index += 1
                continue
            if name == "--output-file":
                self.output_file = value
                index += 2
                continue
            if name == "--shell":
                self.shell = value.strip().lower() or "auto"
                index += 2
                continue
            if name == "--mode":
                self.mode = value.strip().lower() or "auto"
                index += 2
                continue
            if name == "--no-probe":
                self.no_probe = True
                index += 1
                continue
            if name == "--no-panel":
                self.no_panel = True
                index += 1
                continue
            index += 1


class TerminalProbePlugin(object):
    """串起整条探针流水线；所有对外动作都走 `command()`（自检时可替换）。"""

    def __init__(self, options):
        self.options = options
        self.plugin_id = "terminal_probe"
        self.name = "终端稳定性探针"

        # ── 协议状态 ────────────────────────────────────────────────────
        self._send_lock = threading.Lock()
        self._pending_lock = threading.Lock()
        self._pending = {}
        self._request_seq = 0

        # ── 探针状态（用同一个 _state_lock 保护所有字段） ─────────────────
        self._state_lock = threading.RLock()
        self._stop = threading.Event()
        self._probe_start_at = None      # epoch 秒
        self._probe_deadline = None      # epoch 秒
        self._probe_done = False
        self._task_id = ""
        self._poll_count = 0
        self._poll_errors = 0
        self._timeout_broadcasts = 0
        self._last_status_text = ""
        self._shell = ""             # 从 terminal 回包里学到的 `shell=...`
        self._degraded = False       # True = 没拿到后台句柄，改用通路存活模式

        # ── 时间线（面板数据源）：[(at, kind, text)]，最新在**后** ─────────
        self._timeline = []

        # ── 面板状态 ────────────────────────────────────────────────────
        self._ui_lock = threading.Lock()
        self._ui_last_push = 0.0
        self._ui_slot_key = SLOT_ACTIVITY
        self._panel_declared = False

    # ── 协议通道 ────────────────────────────────────────────────────────

    def emit(self, message):
        """写出一条报文（默认走 stdout）。自检时替换成内存收集器。"""
        send(message)

    def _send(self, message):
        with self._send_lock:
            self.emit(message)

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
            request_id = "probe-req-%d" % self._request_seq
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
        """经**执行站**下一条命令（`terminal.exec` 走这里）。

        [scope] 是这一次命令的身份（`{agent_id / session_id}`）：核心按目标 agent
        的真实归属解析 team / mode；`plugins.yaml` 的 scope 只是上限。
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

    def _subscribe(self, station="", point="", station_id=""):
        """订阅站点（协议方法 `station/subscribe`）。

        三种寻址（互斥）：`station`（按类型订）、`station`+`point`（按点位别名订）、
        `station_id`（按实例 id 直订）。本插件只用后两种。
        """
        params = {"replace": False}
        if station_id:
            params["station_id"] = station_id
        else:
            params["station"] = station
            if point:
                params["point"] = point
        response = self.request_core(METHOD_STATION_SUBSCRIBE, params)
        if response.get("timeout"):
            return {"ok": False, "error": "订阅超时"}
        error = response.get("error")
        if isinstance(error, dict):
            return {"ok": False, "error": error.get("message", "")}
        result = response.get("result")
        return result if isinstance(result, dict) else {"ok": False, "error": "空结果"}

    def _scope(self):
        """当前探针的目标身份（`agent_id` / `session_id`）——空字段不写。"""
        scope = {}
        if self.options.agent_id:
            scope["agent_id"] = self.options.agent_id
        if self.options.session_id:
            scope["session_id"] = self.options.session_id
        return scope

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
                # 先申报面板，再起启动线程（订阅要重试，别拖住握手后的第一条报文）
                self.declare_panel()
                threading.Thread(target=self._startup, name="startup",
                                 daemon=True).start()
                return
            if method == "tools/list":
                # 本插件不申报工具（它只订广播点位 + 下 terminal 命令）
                self._reply(request_id, {"tools": []})
                return
            if method == METHOD_STATION_REQUEST:
                self._reply(request_id, self.handle_station_request(params))
                return
            if method == "ping":
                self._reply(request_id, {"ok": True, "ts": int(time.time())})
                return
            self._reply(request_id, error={
                "code": -32601,
                "message": "method not found: %s" % method,
            })
        except Exception as error:  # noqa: BLE001 - 异常必须变成响应，不能让核心挂住
            self._reply(request_id, error={
                "code": -32603,
                "message": "terminal_probe 处理 %s 异常：%r" % (method, error),
            })

    # ── 启动流程 ────────────────────────────────────────────────────────

    def _startup(self):
        """hello 之后的开工动作（独立线程：这里面要等核心回包）。"""
        log("已就绪：plugin_id=%s 周期=%.2f h 轮询间隔=%.0f s"
            % (self.plugin_id, self.options.hours, self.options.interval))
        # ① 订阅工具超时广播：不为了取消，只为了看它"该响有没有响"
        self._subscribe_timeout()
        if self.options.no_probe:
            log("--no-probe：只声明面板，不启动探针")
            self._timeline_add("info", "未启动探针（--no-probe）")
            self.update_panel(force=True)
            return
        # ② 目标 agent：没有就如实记下、不猜（命令按 agent 的真实归属解析）
        if not self.options.agent_id:
            log("没有 --agent-id：不启动探针（用 --agent-id 指定目标 agent）")
            self._timeline_add("error", "缺少 --agent-id，未启动探针")
            self.update_panel(force=True)
            return
        # ③ 探针主体放到另一个线程（这里面会阻塞：轮询要等每次 hook 回包）
        threading.Thread(target=self._run_probe_worker, name="probe",
                         daemon=True).start()

    def _subscribe_timeout(self):
        result = self._subscribe("broadcast", point="tool.timeout")
        if result.get("ok"):
            log("已订阅 %s（工具运行超时广播）" % STATION_TOOL_TIMEOUT)
            self._timeline_add("subscribe", "已订阅 %s" % STATION_TOOL_TIMEOUT)
        else:
            # 订不上也要看得见：没有它，"超时该响没响"就成了不可观测
            log("订阅 %s 失败：%s" % (STATION_TOOL_TIMEOUT, result.get("error")))
            self._timeline_add(
                "subscribe_error",
                "订阅 %s 失败：%s" % (STATION_TOOL_TIMEOUT, result.get("error")))
        self.update_panel(force=True)

    # ── 探针主体 ────────────────────────────────────────────────────────

    def _learn_shell(self, text):
        """从 terminal 回包文本里学 `shell=`，并记进时间线（口径变了要看得见）。"""
        match = SHELL_PATTERN.search(str(text or ""))
        if not match:
            return ""
        value = match.group(1).strip().lower()
        if value == "cmd.exe":
            value = "cmd"
        elif value == "powershell.exe":
            value = "powershell"
        with self._state_lock:
            if value and value != self._shell:
                self._shell = value
                self._timeline_add("shell", "学到 shell=%s" % value)
                log("学到 shell=%s（后续长命令按它生成）" % value)
        return value

    def _shell_kind(self):
        """'posix' / 'cmd' / 'powershell'。还没学到就按插件本机平台兜底。"""
        if self.options.shell in ("posix", "cmd", "powershell"):
            return self.options.shell
        with self._state_lock:
            shell = self._shell
        if shell in POSIX_SHELLS:
            return "posix"
        if shell in CMD_SHELLS:
            return "cmd"
        if shell in POWERSHELL_SHELLS:
            return "powershell"
        return "cmd" if os.name == "nt" else "posix"

    def _canary(self):
        """先发一条零成本命令：学 `shell=`，顺带验证 terminal 通路本身通不通。"""
        started = time.time()
        arguments = {"command": _echo_command("terminal-probe-canary")}
        arguments.update(self._scope())
        result = self.command(CMD_TERMINAL_EXEC, arguments, scope=self._scope())
        duration_ms = int(max(0.0, time.time() - started) * 1000)
        if not result.get("ok"):
            self._timeline_add(
                "error", "canary 失败（%d ms）：%s"
                         % (duration_ms, result.get("error") or "未知原因"))
            return False
        payload = result.get("payload") or {}
        text = str(payload.get("text") or "")
        self._learn_shell(text)
        self._timeline_add(
            "canary", "terminal 通路可用（%d ms，shell=%s）"
                      % (duration_ms, self._shell or "未知"))
        return True

    def _run_probe_worker(self):
        if not self._start_probe():
            return
        if self._degraded:
            self._probe_loop_degraded()
        else:
            self._probe_loop()

    def _start_probe(self):
        """发起后台 terminal 命令。返回 True = 启动成功（可以进入轮询）。"""
        # 先 canary 学 shell（除非 --mode echo 跳过长命令），再按它的家族生成命令
        if self.options.mode != "echo":
            if not self._canary():
                self._probe_done = True
                self.update_panel(force=True)
                return False
        command = self.options.command or _sleep_command(
            self._shell_kind(), int(self.options.hours * 3600))
        started = time.time()
        self._probe_start_at = started
        self._probe_deadline = started + self.options.hours * 3600
        self._timeline_add("start", "启动 terminal 命令：%s" % command)
        log("启动探针：command=%s 时长=%.2f h 轮询间隔=%.0f s background=%s"
            % (command, self.options.hours, self.options.interval,
               self.options.background))
        self.update_panel(force=True)

        arguments = {"command": command}
        # **hook=true 才是核心的"后台任务模式"入口**（键名是 `hook`，不是
        # `background`——后者文档里没有，核心也不认，实测会被当成普通参数丢弃）。
        if self.options.background:
            arguments["hook"] = True
        if self.options.output_file:
            arguments["output_file"] = self.options.output_file
        if self.options.agent_id:
            arguments["agent_id"] = self.options.agent_id
        if self.options.session_id:
            arguments["session_id"] = self.options.session_id

        result = self.command(CMD_TERMINAL_EXEC, arguments, scope=self._scope())
        if not result.get("ok"):
            error = str(result.get("error") or "未知原因")
            self._timeline_add("error", "启动失败：%s" % error)
            log("启动失败：%s" % error)
            self._probe_done = True
            self.update_panel(force=True)
            return False

        payload = result.get("payload")
        payload = payload if isinstance(payload, dict) else {}
        self._task_id = self._extract_task_id(payload)
        text = _short_text(payload.get("text"))
        # 排障：把回包的**键名**原样记下来（值太长就不展开）
        self._timeline_add(
            "start_payload",
            "启动回包键名=%s text=%s"
            % (sorted(payload.keys()), _short_text(text, 120)))
        self._last_status_text = text
        self._timeline_add(
            "start", "已启动：task_id=%s text=%s"
                     % (self._task_id or "(无)", text))
        log("已启动：task_id=%s is_error=%s text=%s"
            % (self._task_id or "(无)", payload.get("is_error"), text))
        if not self._task_id:
            self._degraded = True
            if _looks_finished(text):
                note = ("回包里没有后台句柄，且文本像是**前台跑完**的输出"
                        "（核心可能不认 background: true）")
            else:
                note = "回包里没有后台句柄（task_id / handle）"
            self._timeline_add(
                "warn", note + " ⇒ 降级为「通路存活探针」（每拍 echo，量耗时与成败）")
            log(note + "；降级为通路存活探针")
        self.update_panel(force=True)
        return True

    @staticmethod
    def _extract_task_id(payload):
        """从启动回包里挖 `task_id`。

        核心把它写进 **text 正文**（形如 `task_id: hook_1790843170049_1`，
        见 builtin_tools.dart 与 plugin_execute_mounts_test.dart 的正则），
        也可能作为顶层字段；两路都认。
        """
        for key in ("task_id", "taskId", "id", "handle"):
            value = payload.get(key)
            if isinstance(value, str) and value:
                return value
        match = re.search(r"task_id\s*[:：]\s*(\S+)",
                          str(payload.get("text") or ""))
        return match.group(1) if match else ""

    def _probe_loop(self):
        """轮询循环：每 interval 秒发一次 `hook_action=status`，直到期或用户叫停。"""
        # **启动立即拍一次**：否则前 interval 秒里面板上没有钩子存活证据，
        # "轮询 0"会持续整个 interval，看起来像卡死。
        if not self._stop.is_set():
            self._poll_once()
        while not self._stop.is_set():
            remaining = self._probe_deadline - time.time()
            if remaining <= 0:
                break
            nap = min(self.options.interval, remaining)
            if nap <= 0:
                break
            # `Event.wait` 让我们在"用户点提前结束"时立刻醒来
            if self._stop.wait(nap):
                break
            self._poll_once()
        if self._stop.is_set():
            self._finish_probe("用户提前结束")
        else:
            self._finish_probe("周期到达（%.2f 小时）" % self.options.hours)

    def _probe_loop_degraded(self):
        """降级模式：没有后台句柄可查，改为每拍量「terminal 通路是否一直可用」。

        这不是原目标（查后台任务的钩子），但它保留了 3 小时这个尺度上最有价值的
        观测：通路会不会中途开始变慢 / 开始失败 / 开始报 shell 变化。
        """
        while not self._stop.is_set():
            remaining = self._probe_deadline - time.time()
            if remaining <= 0:
                break
            if self._stop.wait(min(self.options.interval, remaining)):
                break
            self._echo_once()
        if self._stop.is_set():
            self._finish_probe("用户提前结束（降级模式）")
        else:
            self._finish_probe("周期到达（%.2f 小时，降级模式）" % self.options.hours)

    def _echo_once(self):
        """降级模式的一拍：发一条短 `echo`，量它的耗时与成败。"""
        with self._state_lock:
            self._poll_count += 1
            sequence = self._poll_count
        arguments = {"command": _echo_command("probe-%d" % sequence)}
        arguments.update(self._scope())
        started = time.time()
        result = self.command(CMD_TERMINAL_EXEC, arguments, scope=self._scope())
        duration_ms = int(max(0.0, time.time() - started) * 1000)

        if not result.get("ok"):
            with self._state_lock:
                self._poll_errors += 1
                errors = self._poll_errors
            self._timeline_add(
                "poll_error",
                "通路探测 #%d 失败（%d ms，累计 %d 次）：%s"
                % (sequence, duration_ms, errors,
                   _short_text(result.get("error"), 160)))
            log("通路探测 #%d 失败（%d ms）：%s"
                % (sequence, duration_ms, result.get("error") or "未知原因"))
            self.update_panel()
            return

        payload = result.get("payload")
        payload = payload if isinstance(payload, dict) else {}
        text = str(payload.get("text") or "")
        self._learn_shell(text)          # shell 中途变了也要看得见
        with self._state_lock:
            self._last_status_text = text
        if payload.get("is_error"):
            with self._state_lock:
                self._poll_errors += 1
                errors = self._poll_errors
            self._timeline_add(
                "poll_error",
                "通路探测 #%d 返回 is_error（%d ms，累计 %d 次）：%s"
                % (sequence, duration_ms, errors, _short_text(text, 160)))
        else:
            self._timeline_add(
                "poll", "通路探测 #%d 成功（%d ms）" % (sequence, duration_ms))
        self.update_panel()

    def _poll_once(self):
        """发一次 `hook_action=status`，量钩子这一拍还活着没。"""
        if not self._task_id:
            return  # 启动回包没给 task_id 时已经在 _start_probe 里记过 warn
        arguments = {"hook_action": "status", "task_id": self._task_id}
        if self.options.agent_id:
            arguments["agent_id"] = self.options.agent_id
        if self.options.session_id:
            arguments["session_id"] = self.options.session_id

        # **先计数、先留痕**，再发命令：command() 一旦阻塞，面板上至少能看到
        # "第 N 拍发出去了"——否则"没发出去"和"发出去了没回来"永远分不开。
        with self._state_lock:
            self._poll_count += 1
            sequence = self._poll_count
        self._timeline_add(
            "poll_send", "轮询 #%d 已发出，等核心回包…" % sequence)
        self.update_panel(force=True)

        started = time.time()
        result = self.command(CMD_TERMINAL_EXEC, arguments, scope=self._scope())
        duration_ms = int(max(0.0, time.time() - started) * 1000)

        if not result.get("ok"):
            with self._state_lock:
                self._poll_errors += 1
                errors = self._poll_errors
            error = str(result.get("error") or "未知原因")
            self._timeline_add(
                "poll_error",
                "轮询 #%d 失败（%d ms，累计 %d 次失败）：%s"
                % (sequence, duration_ms, errors, _short_text(error, 160)))
            log("轮询 #%d 失败（%d ms）：%s" % (sequence, duration_ms, error))
            self.update_panel()
            return

        payload = result.get("payload")
        payload = payload if isinstance(payload, dict) else {}
        text = str(payload.get("text") or "")
        with self._state_lock:
            self._last_status_text = text
        self._timeline_add(
            "poll",
            "轮询 #%d 成功（%d ms）：%s"
            % (sequence, duration_ms, _short_text(text, 160)))
        log("轮询 #%d 成功（%d ms）：%s"
            % (sequence, duration_ms, _short_text(text, 160)))
        self.update_panel()

    def _cancel_probe(self):
        """「提前结束」：发 `hook_action=cancel`，然后收尾。"""
        with self._state_lock:
            if self._probe_done:
                return
        if self._task_id:
            arguments = {"hook_action": "cancel", "task_id": self._task_id}
            if self.options.agent_id:
                arguments["agent_id"] = self.options.agent_id
            if self.options.session_id:
                arguments["session_id"] = self.options.session_id
            result = self.command(CMD_TERMINAL_EXEC, arguments, scope=self._scope())
            if result.get("ok"):
                payload = result.get("payload") or {}
                self._timeline_add(
                    "cancel",
                    "已发送 cancel：%s"
                    % _short_text((payload or {}).get("text"), 120))
                log("已发送 cancel：%s" % _short_text((payload or {}).get("text"), 120))
            else:
                self._timeline_add(
                    "cancel_error",
                    "cancel 失败：%s" % (result.get("error") or "未知原因"))
                log("cancel 失败：%s" % (result.get("error") or "未知原因"))
        else:
            self._timeline_add("cancel", "无 task_id，跳过 cancel（只结束本地循环）")
        # 叫停轮询并收尾（先 set stop，让 `_probe_loop` 醒来后自己退出）
        self._stop.set()
        self._finish_probe("用户手动取消")

    def _finish_probe(self, reason):
        with self._state_lock:
            if self._probe_done:
                return
            self._probe_done = True
            elapsed = (time.time() - self._probe_start_at
                       if self._probe_start_at else 0.0)
        self._timeline_add(
            "end",
            "探针结束（%s，已运行 %s）" % (reason, _duration_text(elapsed)))
        log("探针结束：%s（已运行 %s）" % (reason, _duration_text(elapsed)))
        self.update_panel(force=True)

    # ── 时间线 ──────────────────────────────────────────────────────────

    def _timeline_add(self, kind, text):
        with self._state_lock:
            self._timeline.append({
                "at": time.time(),
                "kind": str(kind),
                "text": str(text),
            })
            if len(self._timeline) > MAX_TIMELINE:
                del self._timeline[:-MAX_TIMELINE]

    # ── 站点请求（目前只订工具超时广播） ─────────────────────────────────

    def handle_station_request(self, params):
        """站点 → 插件的请求。只认真实订阅的那个点位，其余一律"不改动"。"""
        station_id = str(params.get("station_id") or "")
        if station_id == STATION_TOOL_TIMEOUT:
            return self._handle_tool_timeout(params)
        # 非本插件的点位：不改动（`null` 与"空集合"不是一回事，见开发指南 §5.2）
        return {"reply": {"payload": None}}

    def _handle_tool_timeout(self, params):
        """工具超时广播：**照实记、不取消**——本插件就是要看它"该响没响"。"""
        payload = params.get("payload")
        payload = payload if isinstance(payload, dict) else {}
        handle = str(payload.get("handle") or "")
        tool = str(payload.get("tool") or "")
        elapsed_ms = payload.get("elapsed_ms")
        with self._state_lock:
            self._timeout_broadcasts += 1
            count = self._timeout_broadcasts
        self._timeline_add(
            "timeout",
            "核心判定超时 #%d：tool=%s handle=%s elapsed=%s ms"
            % (count, tool or "(空)", handle or "(空)", elapsed_ms))
        log("工具超时广播 #%d：tool=%s handle=%s elapsed=%s ms"
            % (count, tool or "(空)", handle or "(空)", elapsed_ms))
        self.update_panel()
        # 广播也要回一条（核心在等回包，只是不等它阻塞工具执行）
        return {"reply": {"payload": None}}

    # ── 左栏面板（activity 槽位：活动栏图标 + 左栏整页） ─────────────────

    def declare_panel(self):
        """发 `ui/manifest` 通知：声明**一条** `activity` 槽位（左栏整页）。

        声明**发一次就够**：前端断连重连时核心按缓存补发（`PluginUiCache`），
        之后的每次刷新走 `ui/update`。`--no-panel` 时整个方法什么都不做。
        """
        if self.options.no_panel:
            log("--no-panel：不申报左栏面板")
            return
        # 槽位键带实例 id：同一个脚本配成两个插件实例时互不覆盖
        self._ui_slot_key = "%s.activity.1" % self.plugin_id
        self.notify(METHOD_UI_MANIFEST, {"slots": [{
            "slot_key": self._ui_slot_key,
            "slot": "activity",
            "title": PANEL_TITLE,
            "icon": PANEL_ICON,
            "order": 25,
            "view": self._panel_view(),
        }]})
        self._panel_declared = True
        log("已声明左栏面板槽位 %s（activity：活动栏图标 + 左栏整页）"
            % self._ui_slot_key)

    def update_panel(self, force=False):
        """发 `ui/update`：按 slot_key **整块替换**面板视图（不做 diff）。

        节流 [PANEL_MIN_INTERVAL]：探针每 `interval` 秒刷一次，但面板刷新是整块重建，
        刷太勤只是闪。`force=True` 绕过节流（按钮回调、启动/结束这类"用户等着看"的）。
        """
        if self.options.no_panel:
            return
        now = time.monotonic()
        with self._ui_lock:
            if not force and now - self._ui_last_push < PANEL_MIN_INTERVAL:
                return
            self._ui_last_push = now
        self.notify(METHOD_UI_UPDATE, {
            "slot_key": self._ui_slot_key,
            "view": self._panel_view(),
        })

    def _panel_view(self):
        """左栏面板视图（受限控件集）：概览 + 进度 + 最近 N 条时间线 + 按钮。"""
        with self._state_lock:
            timeline = list(self._timeline)
            start_at = self._probe_start_at
            done = self._probe_done
            task_id = self._task_id
            polls = self._poll_count
            errors = self._poll_errors
            timeouts = self._timeout_broadcasts
            last_status = self._last_status_text
            degraded = self._degraded

        # 概览（一行）
        now = time.time()
        elapsed = (now - start_at) if start_at else 0.0
        total = max(1.0, self.options.hours * 3600.0)
        remaining = max(0.0, total - elapsed) if start_at else total
        if done:
            status_text = "已结束"
        elif start_at is None:
            status_text = "未启动"
        else:
            status_text = "运行中（剩余 %s）" % _duration_text(remaining)
        summary_parts = [
            "状态：%s" % status_text,
            "模式：%s" % ("降级（量通路存活）" if degraded else "后台钩子"),
            "task_id=%s" % (task_id or "—"),
            "轮询 %d（失败 %d）" % (polls, errors),
            "interval=%.0fs" % self.options.interval,
        ]
        if timeouts:
            summary_parts.append("超时广播 %d 次" % timeouts)
        if last_status:
            summary_parts.append("最近：%s" % _short_text(last_status, 80))
        children = [
            {"type": "text", "text": PANEL_TITLE, "style": "title"},
            {"type": "text", "text": " · ".join(summary_parts), "style": "caption"},
            {
                "type": "progress",
                "value": min(1.0, max(0.0, elapsed / total)),
                "label": "探针周期（%.2f 小时）" % self.options.hours,
                "detail": "%s / %s"
                          % (_duration_text(elapsed), _duration_text(total)),
            },
        ]

        # 时间线表格（最新在前）
        recent = list(reversed(timeline[-MAX_POLL_ROWS:]))
        rows = [
            [
                time.strftime("%H:%M:%S", time.localtime(record["at"])),
                record["kind"],
                _short_text(record["text"], 200),
            ]
            for record in recent
        ] or [["—", "—", "（还没有事件）"]]
        children.append({
            "type": "table",
            "columns": ["时间", "事件", "详情"],
            "rows": rows,
            "caption": "最近 %d 条事件（最新在最上面；" 
                       "kind: canary=通路预检 / shell=学到 shell / start=启动 / "
                       "poll=状态查询 / poll_error=查询失败 / "
                       "timeout=核心判定超时 / cancel=已发取消）" % len(rows),
        })

        # 按钮组
        buttons = []
        if not done:
            buttons.append({"action_id": "cancel", "label": "提前结束",
                            "style": "primary"})
        buttons.append({"action_id": "refresh", "label": "刷新"})
        children.append({"type": "actions", "buttons": buttons})

        return {"type": "column", "gap": 6, "children": children}

    # ── 面板交互 ────────────────────────────────────────────────────────

    def on_ui_action(self, params):
        """面板交互回调（核心 → 插件）。

        **判据在 `params.event` 上**（开发指南 §7.2）：核心把前端动作包成
        `{"method":"event","params":{"event":"plugin_ui_action", ...}}`，判
        `method == "plugin_ui_action"` 会永远不命中（"按钮点了没反应"）。
        """
        action_id = str(params.get("action_id") or "")
        slot_key = str(params.get("slot_key") or "")
        log("面板交互：slot=%s action=%s" % (slot_key, action_id))
        if action_id == "cancel":
            self._cancel_probe()
            return
        if action_id == "refresh":
            self.update_panel(force=True)
            return
        log("未知的面板动作（忽略）：%s" % action_id)

    # ── 通知 ────────────────────────────────────────────────────────────

    def on_notification(self, method, params):
        if method == "shutdown":
            log("收到 shutdown，退出")
            self._stop.set()
            sys.exit(0)
        if method == "event":
            event = str(params.get("event") or "")
            if event == EVENT_UI_ACTION:
                self.on_ui_action(params)
                return
            # 其它事件不关心（本插件不靠事件计数，靠 terminal hook 与广播）
            return
        if method == EVENT_UI_ACTION:
            # 裸 `method == "plugin_ui_action"` 形态（老核心 / 直连测试）：兼容收下
            self.on_ui_action(params)
            return
        # 其它通知（log / ui/* 等）：忽略

    # ── 读循环 ──────────────────────────────────────────────────────────

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
                # ① 响应：唤醒等待者
                with self._pending_lock:
                    entry = self._pending.pop(request_id, None)
                if entry is not None:
                    entry[1].update(message)
                    entry[0].set()
                continue
            if isinstance(method, str) and method and request_id is not None:
                # ② 请求：**另开线程**（处理中要等核心回包，读循环不能被占住）
                threading.Thread(
                    target=self.handle_request,
                    args=(request_id, method, message.get("params") or {}),
                    name="req-%s" % method,
                    daemon=True,
                ).start()
                continue
            # ③ 通知：就地处理（事件 / shutdown）
            self.on_notification(str(method or ""), message.get("params") or {})


# ── 自检（假命令通道：真编排逻辑，不连真核心） ─────────────────────────────


def _fake_command_factory(calls, start_payload=None, status_text="still running"):
    """假命令通道：记录调用、按命令返回与核心同形状的结果。"""
    start_payload = start_payload if start_payload is not None else {
        "task_id": "task-1", "text": "started (background)", "is_error": False,
    }

    def fake(command, arguments, scope=None):
        calls.append({"command": command, "arguments": arguments, "scope": scope})
        if command == CMD_TERMINAL_EXEC:
            hook = arguments.get("hook_action")
            if hook == "status":
                return {"ok": True, "command": command,
                        "payload": {"text": status_text, "is_error": False}}
            if hook == "cancel":
                return {"ok": True, "command": command,
                        "payload": {"text": "cancelled", "is_error": False}}
            return {"ok": True, "command": command, "payload": dict(start_payload)}
        return {"ok": False, "error": "未知命令 %s" % command}

    return fake


def _plugin(options=None, calls=None, start_payload=None, status_text="still running"):
    """造一个走假命令通道的插件，并把**发出的报文收进内存**（`plugin.sent`）。"""
    calls = calls if calls is not None else []
    plugin = TerminalProbePlugin(options or Options())
    plugin.command = _fake_command_factory(calls, start_payload, status_text)
    plugin.sent = []
    plugin.emit = plugin.sent.append
    return plugin, calls


def _notifications(sent, method):
    return [m for m in sent if m.get("method") == method]


def _last_view(sent, method):
    hits = _notifications(sent, method)
    if not hits:
        return {}
    params = hits[-1].get("params")
    view = params.get("view") if isinstance(params, dict) else None
    return view if isinstance(view, dict) else {}


def _declared_slot(sent):
    hits = _notifications(sent, "ui/manifest")
    if not hits:
        return {}
    params = hits[-1].get("params")
    slots = params.get("slots") if isinstance(params, dict) else None
    if isinstance(slots, list) and slots and isinstance(slots[0], dict):
        return slots[0]
    return {}


def _view_problems(node, path="view"):
    """面板视图只能用**受限控件集**，且字段形状要对（返回可读问题列表）。"""
    problems = []
    if not isinstance(node, dict):
        return ["%s 不是对象" % path]
    kind = node.get("type")
    if kind not in VIEW_TYPES:
        return ["%s 的类型 %r 不在受限控件集内" % (path, kind)]
    if kind == "text" and not str(node.get("text") or "").strip():
        problems.append("%s 是空文本" % path)
    if kind == "table":
        columns = node.get("columns")
        rows = node.get("rows")
        if not isinstance(columns, (list, tuple)) or not columns:
            problems.append("%s 表格缺列名" % path)
        if not isinstance(rows, (list, tuple)):
            problems.append("%s 表格缺 rows" % path)
        elif isinstance(columns, (list, tuple)):
            for index, row in enumerate(rows):
                if not isinstance(row, (list, tuple)) or len(row) != len(columns):
                    problems.append(
                        "%s 第 %d 行的单元格数与本列表不符" % (path, index + 1))
    if kind == "progress":
        value = node.get("value")
        if not isinstance(value, (int, float)) or not 0.0 <= float(value) <= 1.0:
            problems.append("%s 的 progress.value 必须在 0~1：%r" % (path, value))
    if kind == "actions":
        buttons = node.get("buttons")
        if not isinstance(buttons, list) or not buttons:
            problems.append("%s 的 actions 没有按钮" % path)
        else:
            for index, button in enumerate(buttons):
                if (not isinstance(button, dict) or not button.get("action_id")
                        or not button.get("label")):
                    problems.append(
                        "%s 第 %d 个按钮缺 action_id / label" % (path, index + 1))
    children = node.get("children")
    if isinstance(children, list):
        for index, child in enumerate(children):
            problems.extend(_view_problems(child, "%s.children[%d]" % (path, index)))
    return problems


def selftest():
    """真编排 + 假命令：把最容易静默出错的几条钉死。"""
    failures = []

    # ① 启动探针：发出 terminal.exec + command，拿到 task_id
    options = Options()
    options.hours = 0.001
    options.interval = 0.05
    options.agent_id = "agt_test"
    options.session_id = "ses_test"
    plugin, calls = _plugin(options=options)
    if not plugin._start_probe():
        failures.append("_start_probe 应成功启动（假通道返回 task_id）")
    else:
        exec_calls = [c for c in calls if c["command"] == CMD_TERMINAL_EXEC
                      and "terminal-probe-canary" not in str(
                          c["arguments"].get("command") or "")]
        if not exec_calls:
            failures.append("_start_probe 没有发出 terminal.exec")
        else:
            args = exec_calls[0]["arguments"]
            if "command" not in args:
                failures.append("启动调用缺 command 参数：%r" % args)
            if args.get("agent_id") != "agt_test":
                failures.append("启动调用没带 agent_id：%r" % args)
            if args.get("session_id") != "ses_test":
                failures.append("启动调用没带 session_id：%r" % args)
            # **核心只认 `hook=true`**（不是 `background`；后者文档里没有、核心也不认）。
            if args.get("hook") is not True:
                failures.append("默认应请求后台任务模式（hook=true）：%r" % args)
            if exec_calls[0]["scope"].get("agent_id") != "agt_test":
                failures.append("启动调用的 scope 没带 agent：%r"
                                % exec_calls[0]["scope"])
        if plugin._task_id != "task-1":
            failures.append("task_id 没提取到：%r" % plugin._task_id)

    # ② 轮询：发 hook_action=status + task_id（agent 身份也要带）
    calls.clear()
    plugin._poll_once()
    polls = [c for c in calls if c["command"] == CMD_TERMINAL_EXEC]
    if len(polls) != 1:
        failures.append("轮询应恰好 1 次 terminal.exec，实际 %d" % len(polls))
    else:
        args = polls[0]["arguments"]
        if args.get("hook_action") != "status":
            failures.append("轮询没发 hook_action=status：%r" % args)
        if args.get("task_id") != "task-1":
            failures.append("轮询没带 task_id：%r" % args)
        if args.get("agent_id") != "agt_test":
            failures.append("轮询没带 agent_id：%r" % args)
    if plugin._poll_count != 1:
        failures.append("_poll_count 应为 1，实际 %d" % plugin._poll_count)
    if plugin._poll_errors != 0:
        failures.append("成功轮询不该计入失败：%d" % plugin._poll_errors)

    # ③ 轮询失败照样计数（不静默、不终止）
    failing_plugin, failing_calls = _plugin(options=options)
    failing_plugin._start_probe()

    def failing_command(command, arguments, scope=None):
        failing_calls.append({"command": command, "arguments": arguments,
                              "scope": scope})
        return {"ok": False, "error": "假装的钩子故障"}

    failing_plugin.command = failing_command
    failing_plugin._poll_once()
    if failing_plugin._poll_errors != 1:
        failures.append("失败轮询应计入 _poll_errors：%d" % failing_plugin._poll_errors)
    if not any("poll_error" == record["kind"]
               for record in failing_plugin._timeline):
        failures.append("轮询失败应记进时间线（不静默）")

    # ④ 工具超时广播：计数 + 记进时间线 + 回 {payload: null}
    broadcast_plugin, _ = _plugin(options=options)
    reply = broadcast_plugin.handle_station_request({
        "station_id": STATION_TOOL_TIMEOUT,
        "kind": "broadcast",
        "payload": {"handle": "h-1", "tool": "terminal.exec",
                    "elapsed_ms": 300000, "point": STATION_TOOL_TIMEOUT},
    })
    if broadcast_plugin._timeout_broadcasts != 1:
        failures.append("超时广播没有计数：%d" % broadcast_plugin._timeout_broadcasts)
    if not any(record["kind"] == "timeout" for record in broadcast_plugin._timeline):
        failures.append("超时广播应记进时间线")
    body = reply.get("reply") if isinstance(reply, dict) else None
    if not isinstance(body, dict) or body.get("payload") is not None:
        failures.append("超时广播应回 {reply:{payload:null}}：%r" % reply)

    # ⑤ 非本点位：不改动（回 null，不返回别的形状）
    other = broadcast_plugin.handle_station_request({
        "station_id": "system.relay.llm.handle", "kind": "relay",
    })
    body = other.get("reply") if isinstance(other, dict) else None
    if not isinstance(body, dict) or body.get("payload") is not None:
        failures.append("非本点位应回 {reply:{payload:null}}：%r" % other)

    # ⑥ 取消：发 hook_action=cancel，标记结束，再调不重复发
    cancel_plugin, cancel_calls = _plugin(options=options)
    cancel_plugin._start_probe()
    cancel_calls.clear()
    cancel_plugin._cancel_probe()
    cancels = [c for c in cancel_calls
               if c["command"] == CMD_TERMINAL_EXEC
               and c["arguments"].get("hook_action") == "cancel"]
    if len(cancels) != 1:
        failures.append("_cancel_probe 应发恰好 1 次 cancel，实际 %d" % len(cancels))
    if cancels and cancels[0]["arguments"].get("task_id") != "task-1":
        failures.append("cancel 没带 task_id：%r" % cancels[0]["arguments"])
    if not cancel_plugin._probe_done:
        failures.append("取消后 _probe_done 应为 True")
    # 幂等：再调一次不该再发 cancel
    cancel_calls.clear()
    cancel_plugin._cancel_probe()
    if [c for c in cancel_calls if c["arguments"].get("hook_action") == "cancel"]:
        failures.append("重复取消不该再发 cancel")
    if not any(record["kind"] == "end" for record in cancel_plugin._timeline):
        failures.append("取消应记进时间线（end）")

    # ⑦ 面板声明：ui/manifest 只发一次、只有一条 activity 槽位，视图合法
    panel_plugin, _ = _plugin(options=options)
    panel_plugin.declare_panel()
    manifests = _notifications(panel_plugin.sent, "ui/manifest")
    if len(manifests) != 1:
        failures.append("ui/manifest 应恰好 1 次，实际 %d" % len(manifests))
    else:
        params = manifests[0].get("params") or {}
        slots = params.get("slots")
        if not isinstance(slots, list) or len(slots) != 1:
            failures.append("ui/manifest 应声明 1 条槽位：%r" % (slots,))
        else:
            slot = slots[0]
            if slot.get("slot") != "activity":
                failures.append("槽位类型应是 activity：%r" % slot.get("slot"))
            if slot.get("slot_key") != SLOT_ACTIVITY:
                failures.append("slot_key 不对：%r" % slot.get("slot_key"))
            if not slot.get("title") or not slot.get("icon"):
                failures.append("槽位缺 title / icon：%r" % slot)
            problems = _view_problems(slot.get("view"))
            if problems:
                failures.append("面板声明视图不合法：%s" % problems)
            rendered = json.dumps(slot, ensure_ascii=False)
            if '"cancel"' not in rendered and '"refresh"' not in rendered:
                failures.append("面板缺按钮（cancel / refresh）：%s" % rendered[:200])

    # ⑧ 面板视图：有 start / poll / timeout / cancel 事件后能看到对应行
    view_plugin, _ = _plugin(options=options)
    view_plugin._start_probe()
    view_plugin._poll_once()
    view_plugin._handle_tool_timeout({"payload": {"handle": "h1",
                                                  "tool": "terminal.exec",
                                                  "elapsed_ms": 300000}})
    view = view_plugin._panel_view()
    text = json.dumps(view, ensure_ascii=False)
    for must in ["task-1", "start", "poll", "timeout", "终端稳定性探针"]:
        if must not in text:
            failures.append("面板视图里看不到 %r：%s" % (must, text[:400]))
    problems = _view_problems(view)
    if problems:
        failures.append("面板视图不合法：%s" % problems)

    # ⑨ 探针循环：极小周期能自己退出
    loop_options = Options()
    loop_options.hours = 0.001   # 3.6 秒
    loop_options.interval = 0.05
    loop_options.agent_id = "agt_test"
    loop_plugin, _ = _plugin(options=loop_options)
    started = time.time()
    loop_plugin._run_probe_worker()
    elapsed = time.time() - started
    if elapsed > 8.0:
        failures.append("探针循环没能在周期后退出：%.1f s" % elapsed)
    if not loop_plugin._probe_done:
        failures.append("探针循环结束后 _probe_done 应为 True")

    # ⑩ 面板动作回传：核心走 event 通知（判据在 params.event 上）
    action_plugin, action_calls = _plugin(options=options)
    action_plugin._start_probe()
    action_calls.clear()
    action_plugin.on_notification("event", {
        "event": EVENT_UI_ACTION,
        "slot_key": SLOT_ACTIVITY,
        "action_id": "cancel",
        "payload": {},
    })
    cancels = [c for c in action_calls
               if c["command"] == CMD_TERMINAL_EXEC
               and c["arguments"].get("hook_action") == "cancel"]
    if not cancels:
        failures.append("event 形态的面板动作没被处理（判据必须看 params.event）")
    if not action_plugin._probe_done:
        failures.append("面板「提前结束」应让探针标记结束")
    # 裸 method 形态（老核心）也要兼容
    legacy_plugin, legacy_calls = _plugin(options=options)
    legacy_plugin._start_probe()
    legacy_calls.clear()
    legacy_plugin.on_notification(EVENT_UI_ACTION, {
        "action_id": "refresh", "slot_key": SLOT_ACTIVITY, "payload": {},
    })
    if not _notifications(legacy_plugin.sent, "ui/update"):
        failures.append("裸 method=plugin_ui_action 的 refresh 应刷面板")

    # ⑪ --no-panel：一帧 UI 都不发
    silent_options = Options()
    silent_options.no_panel = True
    silent_options.agent_id = "agt_test"
    silent_plugin, _ = _plugin(options=silent_options)
    silent_plugin.declare_panel()
    silent_plugin.update_panel(force=True)
    if silent_plugin.sent:
        failures.append("--no-panel 时不该发任何 UI 帧：%r"
                        % (silent_plugin.sent[:1],))

    # ⑫ 无 task_id 的启动回包：仍启动成功、轮询自动跳过、时间线有 warn
    no_id_plugin, no_id_calls = _plugin(
        options=options, start_payload={"text": "started (no id)", "is_error": False})
    if not no_id_plugin._start_probe():
        failures.append("没有 task_id 的启动回包也应视作启动成功")
    no_id_calls.clear()
    no_id_plugin._poll_once()
    if [c for c in no_id_calls if c["command"] == CMD_TERMINAL_EXEC]:
        failures.append("没有 task_id 时不该发 hook_action=status")
    if not any(record["kind"] == "warn" for record in no_id_plugin._timeline):
        failures.append("没有 task_id 应记一条 warn（不静默）")

    total_polls = plugin._poll_count + loop_plugin._poll_count
    total_errors = plugin._poll_errors + loop_plugin._poll_errors
    for failure in failures:
        sys.stdout.write("[FAIL] %s\n" % failure)
    sys.stdout.write(
        "terminal_probe_plugin 自检：%s（共 %d 次轮询，含 %d 次失败）\n"
        % ("全部通过" if not failures else "有失败项", total_polls, total_errors))
    return 0 if not failures else 1


def main():
    options = Options()
    options.parse(sys.argv[1:])
    plugin = TerminalProbePlugin(options)
    return plugin.serve()


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    sys.exit(main())