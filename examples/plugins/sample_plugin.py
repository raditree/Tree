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

5. **点位化的新能力**（2026-10-01，全部**默认关闭**、各自一个开关；完整口径见
   `docs/plugin-development.md`）——这些是"新协议怎么用"的可运行答案：

   | 开关 | 演示的点位 / 命令 | 落点 |
   |---|---|---|
   | `--relay-llm <关键词>` | 中转站 `system.relay.llm.handle`：**流式接管**（thinking + text 分片 + 可选 tool_call），末条 user 消息不含关键词就回 `null` 不接管 | `_handle_llm_handle` / `_stream_worker` |
   | `--relay-llm-tool-call` | 流式接管里**多推一段 `tool_call`**（默认不推：它会真的触发一次工具调用，干扰其它演示） | `_stream_worker` |
   | `--relay-prompt` | 中转站 `system.relay.prompt.system`：在 `default` 后面追加一行 | `_handle_prompt_system` |
   | `--llm-call <prompt>` | 执行站 `llm.call`：站点处硬设 `response_format=json_object`，打印回来的 `json` | `_do_llm_call` |
   | `--tool-call <tool> <json-args>` | 执行站 `tool.call`：默认**绕开**工具中转 / 广播（`relay:false`） | `_do_tool_call` |
   | `--rename-session` | 执行站 `session.rename`：把当前会话改成带时间戳的标题 | `_do_rename_session` |
   | `--watch-tools` | 广播站 `system.broadcast.tool.pre` + `.tool.post`：统计"看到了 N 次工具调用"并推到面板 | `_handle_tool_broadcast` |

   三条**新协议硬约束**在本文件里的落点（不看会踩）：
   - **流式接管必须在线程里推**：`station/request` 的**回包**与之后的
     `station/stream` 增量是同一根 stdout，但读循环必须继续应答 `ping`——所以
     回包在读循环线程里立刻发出（声明 `{"stream": true}`），增量交给
     `_stream_worker` 线程（见 §1 铁律 2）。
   - **开流后不可回退**：说了 `stream:true` 就必须 `done` 或 `error` 收尾；收到
     `station/cancel`（下行通知）要停流，之后**不要再**推 `done`（核心已经收尾）。
   - **`request_id` 必须原样带回**：每个 `station/stream` 都从请求的
     `params.request_id` 取（`_handle_station_request` 会先记进 `self.stream_request_id`）。

── 协议（行分隔 JSON-RPC 2.0，与 packages/tree_core/test/fixtures/fake_plugin.dart
   完全同构；那份 Dart 实现是本文件的对照物） ──────────────────────────────

核心 → 插件：
  - 请求（带 id）：hello（握手，params 里带 plugin_id）/ tools/list / tools/call /
    station/request（站点请求：收集站采集 / 中转站拦截 / 广播站通知）/ ping（心跳）；
  - 通知（无 id）：event（总线事件：本插件关心 agent.tool_call；**面板动作也走它**——
    `{"method":"event","params":{"event":"plugin_ui_action", slot_key, action_id,
    payload}}`，判据在 `params.event` 上，别判 `method`）/
    station/cancel（**下行**：我接管的 LLM 流该收了）/ shutdown（退出）。

插件 → 核心（宿主按**报文形状**分三类，顺序即优先级）：
  - 响应：有 id 且**没有 method** ⇒ 回填核心的在途请求；
  - 请求：**method + id** ⇒ 核心必回一条响应（M9 的「插件主动下命令」通道）。
    目前支持 station/command：入参 {command, arguments, team_id?, agent_id?,
    session_id?, mode_key?}，result 形如 {command, ok, mount_id, payload, error}；
    错误码 -32601 未知方法 / -32602 参数 / -32603 处理器异常 / -32001 scope 不满足；
    **单实例 + 每条消息带身份**：目标 agent 取请求里的 agent_id，team / mode 由核心按
    该 agent 的真实归属解析；plugins.yaml 的 scope 是**作用域上限**（声明了 team 就
    只能在自己 team 内活动）。
  - 通知：无 id（log / event / ui/manifest / ui/update / **station/stream**）⇒ 核心转成
    前端 plugin_event；`ui/*` 两个约定 method 例外（转成 UI 帧），`station/stream` 是
    **流式接管 LLM 的数据面**（核心按 `request_id` 关联到在途流，见 §5.4）。

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

import io
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
METHOD_STATION_STREAM = "station/stream"
METHOD_UI_MANIFEST = "ui/manifest"
METHOD_UI_UPDATE = "ui/update"
EVENT_TOOL_CALL = "agent.tool_call"
#: **面板按钮回调的事件名**。判据在 `params.event` 上（核心把前端动作包成
#: `method:"event"` 的通知，与 `agent.tool_call` 同一范式）——判 `method` 会永远不命中。
EVENT_UI_ACTION = "plugin_ui_action"
PHASE_START = "start"
PHASE_END = "end"

# 点位 id（2026-10-01 点位化：每个接入点是一个**独立站点实例**）
STATION_RELAY_TOOL_PRE = "system.relay.tool.pre"
STATION_RELAY_TOOL_POST = "system.relay.tool.post"
STATION_RELAY_LLM_HANDLE = "system.relay.llm.handle"
STATION_RELAY_PROMPT_SYSTEM = "system.relay.prompt.system"
STATION_BROADCAST_TOOL_PRE = "system.broadcast.tool.pre"
STATION_BROADCAST_TOOL_POST = "system.broadcast.tool.post"

# JSON-RPC 错误码（与核心 PluginRpcErrorCode 同表）
ERR_METHOD_NOT_FOUND = -32601
ERR_INVALID_PARAMS = -32602
ERR_INTERNAL = -32603

# 命令名（执行站按命令族分点位；对插件透明，仍然只带 command）
CMD_FS_READ = "fs.read"
CMD_UI_PUSH = "ui.push"
CMD_AGENT_STOP = "agent.stop"
CMD_LLM_CALL = "llm.call"
CMD_TOOL_CALL = "tool.call"
CMD_SESSION_RENAME = "session.rename"

DEFAULT_THRESHOLD = 200
DEFAULT_SLOT_KEY = "sample.card.tool_rounds"
# 流式接管的默认触发关键词（只有"最后一条 user 消息含它"才接管）
DEFAULT_RELAY_LLM_KEYWORD = "示例插件接管"

ENV = {
    "threshold": "SAMPLE_PLUGIN_TOOL_ROUND_LIMIT",
    "agent_id": "SAMPLE_PLUGIN_AGENT_ID",
    "read_path": "SAMPLE_PLUGIN_READ_PATH",
    "team_id": "SAMPLE_PLUGIN_TEAM_ID",
    "slot_key": "SAMPLE_PLUGIN_SLOT_KEY",
    "card_interval": "SAMPLE_PLUGIN_CARD_INTERVAL",
    "cascade": "SAMPLE_PLUGIN_STOP_CASCADE",
    "relay_llm": "SAMPLE_PLUGIN_RELAY_LLM",
    "llm_call": "SAMPLE_PLUGIN_LLM_CALL",
    "tool_call": "SAMPLE_PLUGIN_TOOL_CALL",
    "tool_call_args": "SAMPLE_PLUGIN_TOOL_CALL_ARGS",
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
        # 点位化（2026-10-01）新增演示：**全部默认关闭**（既有默认行为一个字不变）
        self.relay_llm = ""            # 非空 = 订阅 system.relay.llm.handle 并按关键词流式接管
        self.relay_llm_tool_call = False   # 流式接管里是否多推一段 tool_call（默认不推）
        self.relay_prompt = False      # 订阅 system.relay.prompt.system，在 default 后追加一行
        self.llm_call = ""             # 非空 = 启动后发一次 llm.call（执行站）
        self.tool_call = ""            # 非空 = 启动后发一次 tool.call（执行站）
        self.tool_call_args = {}       # tool.call 的 arguments（JSON 对象）
        self.rename_session = False    # 用 session.rename 把当前会话改成带时间戳的标题
        self.watch_tools = False       # 订阅两个工具广播点位，统计工具调用次数
        self.selftest = False          # --selftest：用假核心跑协议自测（不连真核心）



def _env(name):
    value = os.environ.get(name)
    return value if value is not None else ""


# stdout 的写锁**放模块级**：`--selftest` 会在同一个进程里把 stdout 换成管道，
# 全局锁能保证"换过之后"的写入同样串行（一行一条 JSON-RPC，不许交错）。
_STDOUT_LOCK = threading.Lock()


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
        "  --relay-llm KEYWORD  点位化：订阅 system.relay.llm.handle，最后一条 user\n"
        "                       消息含 KEYWORD 时**流式接管**这一跳（thinking + 分片\n"
        "                       正文 + done；不含则回 null 不接管）。默认关闭\n"
        "                       （%s）\n"
        "  --relay-llm-tool-call 流式接管里多推一段 tool_call（默认不推：会真的触发\n"
        "                       一次工具调用，干扰别的演示）\n"
        "  --relay-prompt       点位化：订阅 system.relay.prompt.system，在 default\n"
        "                       后面追加一行「（本提示词由示例插件改写）」\n"
        "  --llm-call PROMPT    点位化：启动后发一次执行站 llm.call（站点处硬设\n"
        "                       response_format=json_object），把 json 打进日志\n"
        "                       （%s）\n"
        "  --tool-call TOOL JSON 点位化：启动后发一次执行站 tool.call，打印\n"
        "                       result / is_error。JSON 是 arguments 对象，如 '{}'\n"
        "                       （%s / %s）\n"
        "  --rename-session     点位化：用 session.rename 把当前会话改成带时间戳的标题\n"
        "  --watch-tools        点位化：订阅 system.broadcast.tool.pre / .tool.post，\n"
        "                       统计并在面板显示「看到了 N 次工具调用」\n"
        "  --selftest           用**假核心**跑一遍协议自测（不连真核心，无需参数）\n"
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
            ENV["relay_llm"],
            ENV["llm_call"],
            ENV["tool_call"],
            ENV["tool_call_args"],
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
    if _env(ENV["relay_llm"]).strip():
        options.relay_llm = _env(ENV["relay_llm"]).strip()
    if _env(ENV["llm_call"]).strip():
        options.llm_call = _env(ENV["llm_call"]).strip()
    if _env(ENV["tool_call"]).strip():
        options.tool_call = _env(ENV["tool_call"]).strip()
    if _env(ENV["tool_call_args"]).strip():
        options.tool_call_args = _parse_json_object(
            _env(ENV["tool_call_args"]).strip(), ENV["tool_call_args"]
        )

    values = {
        "--threshold": "threshold",
        "--agent-id": "agent_id",
        "--read-path": "read_path",
        "--team-id": "team_id",
        "--slot-key": "slot_key",
        "--card-interval": "card_interval",
        "--relay-llm": "relay_llm",
        "--llm-call": "llm_call",
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
        if token == "--relay-llm-tool-call":
            options.relay_llm_tool_call = True
            index += 1
            continue
        if token == "--relay-prompt":
            options.relay_prompt = True
            index += 1
            continue
        if token == "--rename-session":
            options.rename_session = True
            index += 1
            continue
        if token == "--watch-tools":
            options.watch_tools = True
            index += 1
            continue
        if token == "--selftest":
            options.selftest = True
            index += 1
            continue
        # `--tool-call` 要两个取值（工具名 + arguments 的 JSON 对象），单独解析
        if token == "--tool-call":
            if index + 2 >= len(argv):
                sys.stderr.write(
                    "参数 --tool-call 需要两个取值：工具名 与 arguments 的 JSON 对象"
                    "（例如 --tool-call read '{\"path\": \"a.txt\"}'）\n"
                )
                sys.exit(2)
            options.tool_call = argv[index + 1]
            options.tool_call_args = _parse_json_object(argv[index + 2], "--tool-call")
            index += 3
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
            elif field in ("relay_llm",):
                setattr(options, field, raw.strip())
            else:
                setattr(options, field, raw)
            index += 2
            continue
        sys.stderr.write("未知参数：%s（用 --help 看用法；注意 stdout 是协议通道）\n" % token)
        sys.exit(2)
    return options


def _parse_json_object(raw, source):
    """把命令行 / 环境变量里的 JSON 对象解析成 dict（**只接受对象**，报错可读）。"""
    try:
        value = json.loads(raw)
    except ValueError as error:
        sys.stderr.write("%s 的 JSON 解析失败：%s（收到：%s）\n" % (source, error, raw))
        sys.exit(2)
    if not isinstance(value, dict):
        sys.stderr.write("%s 需要 JSON **对象**（如 {\"path\": \"a.txt\"}），"
                         "收到：%s\n" % (source, raw))
        sys.exit(2)
    return value



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

        # ── 点位化（2026-10-01）新增状态 ────────────────────────────────────
        # LLM 处理点位 / 系统提示词点位的处理次数（面板与日志用）
        self.llm_handle_seen = 0
        self.llm_handle_taken = 0
        self.prompt_rewrites = 0
        # 工具广播（system.broadcast.tool.pre / .post）计数
        self.tool_broadcast_total = 0
        self.tool_broadcast_pre = 0
        self.tool_broadcast_post = 0
        self.tool_broadcast_last = ""
        # 流式接管：request_id -> 流状态 {"cancelled": bool, "reason": str}
        # 读循环填、_stream_worker 读（用同一个 _state_lock 保护）
        self._streams = {}
        # 最近一次 station/request 的 request_id：**流式增量必须原样带回它**
        # （回包与后续 station/stream 是两条独立报文，靠这个 id 关联，不能自己编）
        self.stream_request_id = ""
        # 启动后要发的执行站演示命令（llm.call / tool.call / session.rename）
        self._startup_commands = []
        if options.llm_call:
            self._startup_commands.append("llm_call")
        if options.tool_call:
            self._startup_commands.append("tool_call")
        if options.rename_session:
            self._startup_commands.append("rename_session")

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
        with _STDOUT_LOCK, self._io_lock:
            out = getattr(sys.stdout, "buffer", None)
            if out is None:
                # 没有 buffer（理论上不会发生）：退回文本通道，仍然一行一条 + 强刷
                sys.stdout.write(data.decode("utf-8"))
                sys.stdout.flush()
                return
            out.write(data)
            out.flush()

    def _stderr(self, text):
        data = text.encode("utf-8", "backslashreplace")
        with self._stderr_lock:
            out = getattr(sys.stderr, "buffer", None)
            if out is None:
                # 没有 buffer（selftest 里被换成 StringIO）：退回文本通道
                sys.stderr.write(data.decode("utf-8"))
                sys.stderr.flush()
                return
            out.write(data)
            out.flush()

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

        **top_agent_id**：核心两处都会读 `agent_id`（`_resolveCommandScope` 从
        params 顶层**或** arguments 取；挂载位置只读 arguments）——只写在
        arguments 里最省事，两种路径都认。所以这里不再单独提供顶层参数。
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

    def subscribe_station(self, station, replace=False, station_id="", scope=None, point=""):
        """**订阅站点**（协议方法）：`station/subscribe`。

        三种寻址方式（互斥）：
        - `station`：按**类型**订内置站——`relay` / `broadcast`；
        - `station` + `point`：按**点位别名**订某一个接入点（比完整 id 抗改名），
          例如 `point="llm.handle"` / `"prompt.system"` / `"tool.pre"`；
        - `station_id`：按**实例 id** 直接订（自建站的消费入口）。

        ⚠ **点位化语义**（2026-10-01，最容易踩的一条）：`station="relay"` **不带
        point** = 一次订**工具调用前 + 工具调用后两个点位**（与点位化之前"一个实例收
        两段"行为等价）；回包结构也从单条变成
        `{ok, station_id, station_ids:[...], subscriptions:[{station_id, ok, replaced, error}], …}`
        ——**旧字段 `station_id` 仍在**（= 第一个点位），但"订上没订上"要看
        `station_ids` / `subscriptions` 或聚合的 `ok`（全部成功才为 true）。

        [scope] 是**订阅声明的身份**（如 `{agent_id: ...}`）：plugins.yaml 的 scope 是
        作用域上限，请求里带 agent 时核心按该 agent 的真实归属解析出 team ——
        **没声明 `scope.team_id` 的插件因此在学到 agent 后仍能订上中转站**。

        订阅被业务规则拒绝（已被占 / 超上限 / 缺 team / 不是自己的自建站）时返回里带
        可读 `error`，不会变成一句"调用失败"。
        """
        if station_id:
            params = {"station_id": station_id}
            label = station_id
        else:
            params = {"station": station}
            if point:
                params["point"] = point
            label = "%s/%s" % (station, point) if point else station
        params["replace"] = replace
        if scope:
            params["scope"] = {key: value for key, value in scope.items() if value}
        response = self.request_core("station/subscribe", params)
        if response.get("timeout") or isinstance(response.get("error"), dict):
            error = response.get("error") or {}
            message = error.get("message") or "超时"
            self.log("订阅 %s 站点失败：%s" % (label, message), notify=True)
            # 一律回"可判定的结果"（含传输层失败）：调用方据此决定要不要推迟重订
            return {"ok": False, "error": message}
        result = response.get("result") or {}
        station_ids = result.get("station_ids") or ([result.get("station_id")]
                                                    if result.get("station_id") else [])
        if result.get("ok"):
            self.log("已订阅 %s 站点：station_ids=%s scope=%s"
                     % (label, station_ids, result.get("scope")))
        else:
            # 部分成功：逐条结果是唯一能看出"哪个点位没订上"的地方，别只看聚合 ok
            self.log("订阅 %s 站点被拒：%s（逐条：%s）"
                     % (label, result.get("error"), result.get("subscriptions")),
                     notify=True)
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
                broadcast = self.tool_broadcast_total
                taken = self.llm_handle_taken
            return self._text_result(json.dumps({
                "plugin_id": self.plugin_id,
                "threshold": self.options.threshold,
                "total_started": total,
                "stop_count": stops,
                "last_duration_ms": duration,
                "counts": {"%s|%s" % key: value for key, value in counts.items()},
                # 点位化新增：流式接管次数与广播看到的工具调用次数
                "llm_handle_taken": taken,
                "tool_broadcast_seen": broadcast,
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
        """站点 → 插件的请求（收集站 / 中转站 / 广播站共用这条 `station/request`）。

        判据是 `params.station_id`（点位化之后**每个点位是一个独立站点实例**，
        所以"哪个点位"看 id 就够；`kind` 仍可用于粗分类）：

        - `system.relay.tool.pre|post`（中转）：核心把**完整 tool_call 报文**放在
          payload 里（`payload.phase` = pre | post）。返回改过的报文 = 改写生效；
          返回 `None` = 什么都不改（放行原数据）；非法类型 = 核心 fail-open 放行。
          这里 pre 给参数补 `_relay_seen` 标记、post 给结果加一行统计。
        - `system.relay.llm.handle`（中转，**接管**）：payload 是
          `{request:{model, messages, tools, …}, turn, agent_id, session_id}`；
          回 `{"payload": None}` = 不接管（照走系统 LLM），回
          `{"payload": {"stream": true}}` = **流式接管**（增量随后用
          `station/stream` **通知**推，见 `_stream_worker`）。
        - `system.relay.prompt.system`（中转）：payload 是 `{default, agent_id,
          session_id}`；回字符串 = 最终 system prompt，回 `None` = 用 `default`。
        - `system.broadcast.tool.pre|post`（广播，**单向通知**）：payload 是本次工具
          调用的报文。广播的语义是通知，但仍要回一条（核心在等回包，只是不等它阻
          塞工具执行）；回 `{"payload": None}` 表示"收到了，没有附言"。
        - `plugin.tool.define`（收集站）：回包 payload 必须严格符合站点 schema
          （根对象只允许 `tools` 一个键）。
        """
        station_id = str(params.get("station_id") or "")
        # 最近一次请求的 request_id：流式增量必须原样带回它（核心靠它关联在途流）
        self.stream_request_id = str(params.get("request_id") or "")
        # 站点请求也携带身份（payload.agent_id / params.scope.agent_id）：这是**不动
        # 事件通路**也能学到目标 agent 的地方（`--llm-call` 之类启动命令要用）。
        payload = params.get("payload")
        payload_is_dict = isinstance(payload, dict)
        payload = payload if payload_is_dict else {}
        scope = params.get("scope")
        scope = scope if isinstance(scope, dict) else {}
        agent_id = str(payload.get("agent_id") or scope.get("agent_id") or "")
        session_id = str(payload.get("session_id") or scope.get("session_id") or "")
        if agent_id or session_id:
            with self._state_lock:
                if agent_id and not self.first_agent_seen:
                    self.first_agent_seen = agent_id
                if session_id and not self.first_session_seen:
                    self.first_session_seen = session_id
        if station_id == STATION_RELAY_LLM_HANDLE:
            return self._handle_llm_handle(params)
        if station_id == STATION_RELAY_PROMPT_SYSTEM:
            return self._handle_prompt_system(params)
        if station_id in (STATION_BROADCAST_TOOL_PRE, STATION_BROADCAST_TOOL_POST):
            return self._handle_tool_broadcast(station_id, params)
        kind = params.get("kind")
        if kind == "relay":
            if not payload_is_dict:
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
        if kind == "broadcast":
            # 通用广播主题（system.broadcast）：收到了，没有附言
            self.log("收到广播（topic=%s）：%s"
                     % ((params.get("meta") or {}).get("topic"), station_id))
            return {"reply": {"payload": None}}
        if kind != "collect":
            # 其余站点类型显式拒绝（不静默）：本插件只订上面那几个点位
            return {"reply": {"error": "示例插件不响应该点位的请求：station_id=%s kind=%s"
                                       % (station_id, kind)}}
        schema = params.get("schema") or {}
        fields = [field.get("name") for field in (schema.get("fields") or [])]
        if fields and "tools" not in fields:
            return {"reply": {"error": "站点 schema 未声明 tools 字段：%s" % fields}}
        definitions = self.tool_definitions()
        self.log("收集站请求：申报 %d 个工具（%s）"
                 % (len(definitions), ", ".join(d["tool_name"] for d in definitions)))
        return {"reply": {"payload": {"tools": definitions}}}

    # ── 点位化 ①：中转站 system.relay.llm.handle（流式接管） ───────────────

    @staticmethod
    def _message_text(message):
        """把一条消息的 content 归一成纯文本（string 或 [{type:text, text:…}] 都认）。"""
        if not isinstance(message, dict):
            return ""
        content = message.get("content")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            parts = []
            for item in content:
                if isinstance(item, dict):
                    text = item.get("text")
                    if isinstance(text, str):
                        parts.append(text)
            return "\n".join(parts)
        return ""

    def _last_user_text(self, messages):
        """最后一条 role=user 消息的正文（没有就空串）。"""
        if not isinstance(messages, list):
            return ""
        for message in reversed(messages):
            if isinstance(message, dict) and message.get("role") == "user":
                return self._message_text(message)
        return ""

    def _handle_llm_handle(self, params):
        """`system.relay.llm.handle`：决定**接管**还是放行（三选一）。

        回包形态（`reply.payload`）：
        - `None` = 不接管 ⇒ 核心走系统 LLM；
        - `{...完整响应...}` = 一次性接管；
        - `{"stream": true}` = **流式接管**（本插件用这条），之后必须用
          `station/stream` 通知推增量并以 `done` / `error` 收尾。

        回包必须**马上**发（`_reply` 在读循环线程里已经发了），推流交给
        `_stream_worker` 线程——推流期间读循环还得应答 `ping`（硬约束）。
        """
        payload = params.get("payload")
        payload = payload if isinstance(payload, dict) else {}
        request = payload.get("request")
        request = request if isinstance(request, dict) else {}
        # ⚠ request_id 在 **params 顶层**（与 payload 平级），不在 payload 里。
        # 兜底用"最近一次站点请求的 request_id"：并发多路时那是**尽力而为**的猜测，
        # 真核心里每条请求都带自己的 request_id，所以正常路径永远走前者。
        request_id = str(params.get("request_id") or "") or self.stream_request_id
        with self._state_lock:
            self.llm_handle_seen += 1
        keyword = self.options.relay_llm
        if not keyword:
            # 防御：没开开关却订上了这个点位（不可能由本文件造成）⇒ 一律不接管
            return {"reply": {"payload": None}}
        if not request_id:
            self.log("llm.handle 请求没有 request_id：无法推流，按不接管处理", notify=True)
            return {"reply": {"payload": None}}
        user_text = self._last_user_text(request.get("messages"))
        if keyword not in user_text:
            self.log("LLM 处理点位：最后一条 user 消息不含关键词「%s」⇒ 不接管（走系统 LLM）"
                     % keyword)
            return {"reply": {"payload": None}}
        turn = payload.get("turn")
        with self._state_lock:
            self.llm_handle_taken += 1
            self._streams[request_id] = {"cancelled": False, "reason": ""}
        self.log("LLM 处理点位：命中关键词「%s」⇒ **流式接管**第 %s 跳（request_id=%s）"
                 % (keyword, turn, request_id), notify=True)
        worker = threading.Thread(
            target=self._stream_worker,
            args=(request_id, keyword, user_text),
            name="llm-stream",
            daemon=True,
        )
        worker.start()
        # 声明接管的回包：**必须在推第一条增量之前**送到核心（否则增量会被丢弃）
        return {"reply": {"payload": {"stream": True}}}

    def _stream_cancelled(self, request_id):
        with self._state_lock:
            state = self._streams.get(request_id)
            return bool(state and state.get("cancelled"))

    def _stream_worker(self, request_id, keyword, user_text):
        """（独立线程）推 `station/stream` 增量，最后 `done` 收尾。

        三条硬约束（都在这个函数里体现）：
        1. **开流后不可回退**：必须 `done` 或 `error` 收尾；
        2. **推流期间继续应答 `ping`**：所以它在自己线程里跑，不占读循环；
        3. **收到 `station/cancel` 就停**：`_on_station_cancel` 会把状态标成
           cancelled，这里每片之间检查一次；取消后核心已收尾，**不要再推 `done`**。
        """
        chunks = [
            ("thinking", "示例插件正在接管这一跳：先复述关键词「%s」。" % keyword),
            ("text", "【示例插件已接管本轮 LLM】"),
            ("text", "你的问题是：「%s」" % user_text.strip()[:80]),
            ("text", "这段文字由插件用 station/stream 分片推给你，"),
            ("text", "核心没有调用任何真模型。"),
        ]
        if self.options.relay_llm_tool_call:
            chunks.append(("tool_call", ""))
        try:
            for kind, text in chunks:
                # 每片之间稍等：既让界面看得出"逐字到达"，也留出收到 cancel 的窗口
                for _ in range(5):
                    if self._stream_cancelled(request_id):
                        break
                    time.sleep(0.05)
                if self._stream_cancelled(request_id):
                    self.log("流式接管：request_id=%s 已被取消，停止推流（不再发 done）"
                             % request_id)
                    return
                if kind == "tool_call":
                    # tool_call 增量：分片参数用 arguments_delta（演示用开关控制，
                    # 因为它会**真的**触发一次工具调用，干扰别的演示）
                    self.notify(METHOD_STATION_STREAM, {
                        "request_id": request_id,
                        "delta": {"kind": "tool_call", "index": 0, "id": "call_demo_1",
                                  "name": "read",
                                  "arguments_delta": "{\"file_path\": \"README.md\"}"},
                    })
                    continue
                self.notify(METHOD_STATION_STREAM, {
                    "request_id": request_id,
                    "delta": {"kind": kind, "text": text},
                })
            if self._stream_cancelled(request_id):
                return
            # 收尾：done + finish_reason + usage（缺了它这一轮会一直等）
            self.notify(METHOD_STATION_STREAM, {
                "request_id": request_id,
                "done": True,
                "finish_reason": "stop",
                "usage": {"prompt_tokens": 12, "completion_tokens": 34},
            })
            self.log("流式接管完成：request_id=%s 已发 done（finish_reason=stop）"
                     % request_id, notify=True)
        except Exception as error:  # noqa: BLE001 - 推流异常也必须给核心一个交代
            self.log("流式接管异常（改为 error 收尾）：%r" % error)
            self.notify(METHOD_STATION_STREAM, {
                "request_id": request_id,
                "error": {"message": "示例插件推流异常：%r" % error},
            })
        finally:
            with self._state_lock:
                self._streams.pop(request_id, None)
            if self.options.panel:
                self.update_panel()

    def _on_station_cancel(self, params):
        """**下行通知** `station/cancel`：用户按了停止，别再把算力烧在推流上。

        只标状态、不阻塞：推流线程每片检查一次，自己收尾（核心已把这条流关掉，
        迟到 / 之后的增量都会被丢弃，不会报错）。
        """
        request_id = str(params.get("request_id") or "")
        reason = str(params.get("reason") or "")
        with self._state_lock:
            state = self._streams.get(request_id)
            if state is not None:
                state["cancelled"] = True
                state["reason"] = reason
        if state is None:
            self.log("收到 station/cancel（request_id=%s）但该流不在途（已收尾 / 非本插件）"
                     % request_id)
            return
        self.log("收到 station/cancel：request_id=%s reason=%s ⇒ 停止推流"
                 % (request_id, reason or "（核心未给原因）"), notify=True)

    # ── 点位化 ②：中转站 system.relay.prompt.system（改写系统提示词） ──────

    def _handle_prompt_system(self, params):
        """`system.relay.prompt.system`：回**最终 system prompt**。

        payload = `{default, agent_id, session_id}`（`default` = 核心构造好的完整
        system prompt）。回 `None` = 用 `default`；回空串 = **明确不要**系统提示词
        （与"不改"是两种语义，别混）；回字符串 = 用你的。本插件演示后者：在
        `default` 后面追加一行，作为"这段提示词被插件动过"的可见证据。
        """
        payload = params.get("payload")
        payload = payload if isinstance(payload, dict) else {}
        default = payload.get("default")
        if not isinstance(default, str):
            default = "" if default is None else str(default)
        with self._state_lock:
            self.prompt_rewrites += 1
            count = self.prompt_rewrites
        marker = "（本提示词由示例插件改写）"
        self.log("系统提示词点位：第 %d 次改写（agent=%s，原长 %d 字符）"
                 % (count, payload.get("agent_id"), len(default)))
        if self.options.panel:
            self.update_panel()
        if not default:
            return {"reply": {"payload": marker}}
        return {"reply": {"payload": default.rstrip() + "\n" + marker}}

    # ── 点位化 ③：广播站 system.broadcast.tool.pre|post（单向通知） ─────────

    def _handle_tool_broadcast(self, station_id, params):
        """工具调用广播：统计"看到了 N 次工具调用"并推到面板。

        广播语义是**单向通知**（`origin` = agent | plugin、`tool`、`call_id`、
        `round`、`arguments` / `result` / `is_error`），但它仍是一条 `station/request`
        ——核心在等这一条回包（只是通知方不等它阻塞工具执行），所以照回
        `{"payload": None}`（没有附言），别不回。
        """
        payload = params.get("payload")
        payload = payload if isinstance(payload, dict) else {}
        phase = str(payload.get("phase") or "")
        tool = str(payload.get("tool") or "")
        origin = str(payload.get("origin") or "")
        is_post = station_id == STATION_BROADCAST_TOOL_POST or phase == "post"
        with self._state_lock:
            self.tool_broadcast_total += 1
            if is_post:
                self.tool_broadcast_post += 1
            else:
                self.tool_broadcast_pre += 1
            total = self.tool_broadcast_total
            self.tool_broadcast_last = "%s %s（origin=%s call_id=%s round=%s）" % (
                "结束" if is_post else "开始", tool, origin,
                payload.get("call_id"), payload.get("round"))
        if is_post:
            self.log("工具广播（第 %d 次）：%s result=%s is_error=%s"
                     % (total, self.tool_broadcast_last,
                        str(payload.get("result"))[:60], payload.get("is_error")))
        else:
            self.log("工具广播（第 %d 次）：%s" % (total, self.tool_broadcast_last))
        if self.options.panel:
            self.update_panel()
        return {"reply": {"payload": None}}


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

    # ── ③ 执行站：插件主动下命令（fs.read / llm.call / tool.call / session.rename） ──

    def _resolve_demo_agent(self, what):
        """解析"这次演示命令打给哪个 agent"；解析不出来返回空串。

        取法：`--agent-id` / 环境变量优先，其次事件 / 站点请求里见过的第一个 agent。
        **为什么不能猜**：核心按目标 agent 的**真实归属**（team / mode）解析命令作用
        域，猜错的后果是 fail-closed 拒绝（有可读原因），而不是"帮你去执行"。
        """
        target = self.options.agent_id or self.first_agent_seen
        if not target:
            self.log("跳过 %s 演示：没有目标 agent（用 --agent-id 指定，"
                     "或先让该 agent 发生一次工具调用 / 站点请求）" % what, notify=True)
        return target

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

    # ── 点位化 ④：三条新执行站命令（llm.call / tool.call / session.rename） ──

    def _do_llm_call(self):
        """（worker 线程）`llm.call`：借**目标 agent 的模型**发一次 JSON 调用。

        站点处**缺省硬设** `response_format=json_object`，所以回包里的 `json` 是端点
        已经解析好的对象；`text` 是原始文本（端点没按 JSON 回时 `json` 为空，插件应看
        `text` 与服务端的 `ok`）。这个示例就用缺省形式。
        要**复用对话前缀缓存**的调用（如压缩插件的总结调用）必须显式传
        `"response_format": "text"`——`json_object` 会让端点改写提示词、前缀整段不命中。
        失败一律 `ok:false` + **可读 error**（例如"该 agent 尚未指定模型"）——不崩。
        """
        prompt = self.options.llm_call
        target = self._resolve_demo_agent("llm.call")
        if not target:
            return
        arguments = {
            "agent_id": target,
            "prompt": prompt,
            "system": "你是示例插件的 JSON 助手：只回一个 JSON 对象。",
        }
        self.log("经执行站发 llm.call（agent=%s prompt=%s）" % (target, prompt[:60]))
        result = self.command(CMD_LLM_CALL, arguments)
        if not result.get("ok"):
            self.log("llm.call 失败：%s" % (result.get("error") or "未知原因"), notify=True)
            return
        payload = result.get("payload") or {}
        self.log("llm.call 成功：model=%s usage=%s\njson=%s\ntext=%s"
                 % (payload.get("model"), payload.get("usage"),
                    json.dumps(payload.get("json"), ensure_ascii=False),
                    str(payload.get("text"))[:200]), notify=True)

    def _do_tool_call(self):
        """（worker 线程）`tool.call`：执行**任意工具**（内置 / MCP / 插件工具同一入口）。

        两点口径（与"命令失败"分得很开）：
        - 命令本身成功 = `ok:true`；**工具自己**失败体现在 `is_error:true` +
          `result` 文本里（模型会看到那种可读原因，插件也一样读得到）；
        - 默认**绕开**工具中转 / 广播（`relay:false`）：插件既订了 tool.pre 又
          tool.call 时，绕开才不会自锁；要审计自己的调用就传 `"relay": true`
          （那要求插件能并发处理，本插件是线程化读循环，可以）。
        """
        tool = self.options.tool_call
        target = self._resolve_demo_agent("tool.call")
        if not target:
            return
        arguments = {
            "agent_id": target,
            "tool": tool,
            "arguments": dict(self.options.tool_call_args),
            # 演示"默认绕开"：这里显式写 false，等价于不传
            "relay": False,
        }
        self.log("经执行站发 tool.call（tool=%s arguments=%s relay=False）"
                 % (tool, json.dumps(self.options.tool_call_args, ensure_ascii=False)))
        result = self.command(CMD_TOOL_CALL, arguments)
        if not result.get("ok"):
            self.log("tool.call 失败（命令没跑起来）：%s"
                     % (result.get("error") or "未知原因"), notify=True)
            return
        payload = result.get("payload") or {}
        self.log("tool.call 结果：tool=%s is_error=%s relayed=%s\nresult=%s"
                 % (payload.get("tool"), payload.get("is_error"),
                    payload.get("relayed"), str(payload.get("result"))[:400]),
                 notify=True)

    def _do_rename_session(self):
        """（worker 线程）`session.rename`：把当前会话改成带时间戳的标题。

        `title` 必填（空标题会被执行站显式拒绝——store 层"空标题 = 不改名"不能在
        命令层静默成功）；`session_id` 缺省 = 目标 agent 的默认会话。
        前端会**即时刷新**标题，所以这条演示是"看得见"的。
        """
        target = self._resolve_demo_agent("session.rename")
        if not target:
            return
        title = "示例插件改名 %s" % time.strftime("%Y-%m-%d %H:%M:%S")
        arguments = {"agent_id": target, "title": title}
        if self.first_session_seen:
            arguments["session_id"] = self.first_session_seen
        result = self.command(CMD_SESSION_RENAME, arguments)
        if not result.get("ok"):
            self.log("session.rename 失败：%s" % (result.get("error") or "未知原因"),
                     notify=True)
            return
        payload = result.get("payload") or {}
        self.log("session.rename 成功：renamed=%s title=%s session_id=%s"
                 % (payload.get("renamed"), payload.get("title"),
                    payload.get("session_id")), notify=True)

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
        # **点位化：LLM 接管点位**（`--relay-llm`）。它和工具前/后**不是**一个实例：
        # 每个点位各自"唯一订阅者"，所以这里单独按 `point` 订，不会顶掉上面那次订阅。
        if self.options.relay_llm:
            self.subscribe_station("relay", point="llm.handle", replace=True)
        # **点位化：系统提示词点位**（`--relay-prompt`）
        if self.options.relay_prompt:
            self.subscribe_station("relay", point="prompt.system", replace=True)
        # **点位化：工具广播**（`--watch-tools`）：两个主题族是**两个点位**，
        # 所以要订两次（`station="broadcast"` 不带 point 只订通用主题 `system.broadcast`，
        # 与中转站的"不带 point = 两个点位"**规则不同**——见下方 README 的坑列表）。
        if self.options.watch_tools:
            self.subscribe_station("broadcast", point="tool.pre")
            self.subscribe_station("broadcast", point="tool.post")
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
        # 三条新执行站命令的演示：**入队不阻塞**（等回包会死锁，见文件头边界情况）
        for job in self._startup_commands:
            self._jobs.put((job,))
        # 卡片是"声明式布局"的演示：**没声明槽位就别推**（ui.push 只更新、不建槽位，
        # 推给不存在的 slot_key 前端会静默忽略——白等一次回包还被记一次失败）
        if self.options.panel:
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
        """左侧活动栏视图：中转计数 + 工具轮次进度 + 点位化演示的计数。"""
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
                {"type": "text", "text": self._points_summary(), "style": "caption"},
                {"type": "actions", "buttons": [
                    {"action_id": "refresh", "label": "刷新"},
                ]},
            ],
        }

    def _points_summary(self):
        """点位化演示（默认关闭）的当前计数，一行说清"哪些开关开着、看到多少"。"""
        with self._state_lock:
            parts = ["LLM 接管 %d/%d 次" % (self.llm_handle_taken, self.llm_handle_seen)]
            if self.options.relay_prompt:
                parts.append("提示词改写 %d 次" % self.prompt_rewrites)
            if self.options.watch_tools:
                parts.append("看到了 %d 次工具调用（pre %d / post %d）"
                             % (self.tool_broadcast_total, self.tool_broadcast_pre,
                                self.tool_broadcast_post))
            return " · ".join(parts)

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
        children = [
            {"type": "text", "text": "示例插件 · 工具轮次监视", "style": "title"},
            {
                "type": "text",
                "text": "阈值 %d 次 · 已计数 %d 次 · 已发停止 %d 次 · 最近一次耗时 %s"
                        % (self.options.threshold, total, stops, duration_text),
                "style": "body",
            },
        ]
        if self.options.watch_tools:
            # 点位化演示：广播站点位看到的工具调用次数（`--watch-tools`）
            with self._state_lock:
                children.append({
                    "type": "text",
                    "text": "广播点位：看到了 %d 次工具调用"
                            "（开始 %d / 结束 %d）最近：%s"
                            % (self.tool_broadcast_total, self.tool_broadcast_pre,
                               self.tool_broadcast_post,
                               self.tool_broadcast_last or "—"),
                    "style": "caption",
                })
        children.extend([
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
        ])
        return {"type": "column", "gap": 6, "children": children}

    def push_card(self, force=False):
        """ui.push：**复用 4.1 的 card 槽位帧**（核心内置挂载位置 core.frontend.card，
        帧类型 plugin_ui_update，带 team_id）。

        槽位本身由 declare_panel 的 `ui/manifest` 申报（`ui.push` 只更新、不建槽位）。
        刷新时**顺带把面板也刷一遍**：三个视图同源，只刷一个会出现"卡片在跳、面板
        停在 0"的错位观感。

        命令身份：见过事件之后一律带 `agent_id` / `session_id`（`--agent-id` 显式指定
        时以它为准），这样**没声明 `scope.team_id` 的配置也能把卡片推出去**。

        `--no-panel`（没声明槽位）时**直接不推**：`ui.push` 只更新、不建槽位，推给
        不存在的 slot_key 前端会静默忽略——白等一次回包，还平白多一条失败日志。
        """
        if not self.options.panel:
            return
        now = time.monotonic()
        if not force and (now - self._last_card_at) < self.options.card_min_interval:
            return  # 事件密集时节流，避免刷屏
        self._last_card_at = now
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
            # ⚠ **先判 `params.event`**：核心把 UI 动作也包成 `event` 通知
            # （`{"method":"event","params":{"event":"plugin_ui_action",…}}`，
            #  与 `agent.tool_call` 同一范式）。先转 `_on_event` 会被它当"非
            #  tool_call 事件"丢掉，面板按钮就成了"点了没反应"。
            if params.get("event") == EVENT_UI_ACTION:
                self._on_ui_action(params)
                return
            self._on_event(params)
            return
        if method == "station/cancel":
            # **下行通知**（无 id）：我接管的 LLM 流该收了 —— 只标状态，推流线程自己停
            self._on_station_cancel(params)
            return
        if method == EVENT_UI_ACTION:
            # 裸 `method == "plugin_ui_action"` 的形态（老核心 / 直连测试）：
            # 兼容留着——否则老核心配新插件时按钮依然是"点了没反应"。
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
        # 未知 action：显式记下来（不静默），但不算错误。**走 log 通知**：
        # 前端能看见——否则用户点了没反应、日志也没人看（这条链路以前就是这么"静默"的）。
        self.log("未知的面板动作（忽略）：%s" % action_id, notify=True)

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
                elif job[0] == "llm_call":
                    self._do_llm_call()
                elif job[0] == "tool_call":
                    self._do_tool_call()
                elif job[0] == "rename_session":
                    self._do_rename_session()
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

    def run_in_thread(self):
        """读循环跑在**后台线程**里（`--selftest` 专用：假核心要在主线程里读 stdout）。

        与 [run] 的唯一区别是读循环不占主线程——协议语义一个字没变（同一份 serve）。
        """
        for thread in (self._worker, self._timer):
            thread.start()
        self.log("示例插件启动（selftest 模式），等待假核心 hello")
        reader = threading.Thread(target=self.serve, name="serve", daemon=True)
        reader.start()
        return reader


# ══════════════════════════════════════════════════════════════════════════
# --selftest：**假核心**（往 stdin 写、读 stdout 断言），不连真核心、不需要参数
# ══════════════════════════════════════════════════════════════════════════
#
# 为什么把假核心写在**同一个进程**里（而不是 spawn 自己一遍）：本文件已经是一份
# "读循环 + 出站写"的完整实现，进程内换掉 sys.stdin / sys.stdout 就等价于外部核心，
# 断言可以精确到"某条报文的某个字段"，也不必管子进程的编码 / 超时。真实 spawn 的
# 端到端由核心侧的 Dart e2e（sample_plugin_layout_e2e_test）负责，两边互补。
#
# 覆盖的点位化新路径（都是"协议形状"层面的硬约束，写错就静默失效）：
#   ① 订阅 system.relay.llm.handle 的回包（ok / station_ids / 逐条 subscriptions）；
#   ② station/stream 的 request_id 必须取自请求（不自己编）；
#   ③ 收到 station/cancel（下行通知）能停流、不崩、之后仍应答 ping；
#   ④ llm.call / tool.call / session.rename 三条命令的请求构造；
#   ⑤ 关键词不匹配时回 null（不接管，走系统 LLM）；
#   ⑥ 两个工具广播点位的订阅 + 回包（广播也要回，只是通知方不等它）。


class FakeCore(object):
    """假核心：进程内换掉 stdin / stdout，按报文形状收发。"""

    def __init__(self):
        self.request_id = ""       # 最近一次我方请求 id（由 request() 回填）
        self.last_request_id = ""
        self.inbound = []          # 插件 → 核心（请求 / 响应 / 通知）
        self.logs = []             # 插件 → 核心的 log 通知（前端 plugin_event）
        self.replies = {}          # 我方请求 id → 预设 result（None = 回一条通用 ok）
        self._req_seq = 0
        self._replied = set()
        self._stdin_r = None
        self._stdin_w = None
        self._stdout_r = None
        self._stdout_w = None
        self._old_stdin = None
        self._old_stdout = None
        self._reader = None

    # ── 生命周期 ─────────────────────────────────────────────────────────

    def __enter__(self):
        self._stdin_r, self._stdin_w = os.pipe()
        self._stdout_r, self._stdout_w = os.pipe()
        self._old_stdin = sys.stdin
        self._old_stdout = sys.stdout
        # io.TextIOWrapper 必须**保留引用**（被 GC 会把底层 fd 一起关掉）
        sys.stdin = io.TextIOWrapper(os.fdopen(self._stdin_r, "rb", 0), encoding="utf-8")
        sys.stdout = io.TextIOWrapper(os.fdopen(self._stdout_w, "wb", 0), encoding="utf-8")
        self._reader = threading.Thread(target=self._read_loop, name="fake-core-read")
        self._reader.daemon = True
        self._reader.start()
        return self

    def __exit__(self, *_exc):
        sys.stdin = self._old_stdin
        sys.stdout = self._old_stdout
        for fd in (self._stdin_w, self._stdout_r):
            try:
                os.close(fd)
            except OSError:
                pass
        return False

    # ── 收 / 发 ──────────────────────────────────────────────────────────

    def _read_loop(self):
        """（读线程）插件 stdout → 分类：响应回填 / 请求入队 / 通知入通知表。"""
        while True:
            try:
                raw = os.read(self._stdout_r, 65536)
            except OSError:
                return
            if not raw:
                return
            for line in raw.decode("utf-8", "replace").splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    message = json.loads(line)
                except ValueError:
                    # stdout 混进非 JSON 就是**协议污染**，SelftestCase 会因此失败
                    self.inbound.append({"raw": line})
                    continue
                self.inbound.append(message)
                if message.get("method") == "log":
                    self.logs.append(str((message.get("params") or {}).get("message", "")))

    def send(self, message):
        """假核心 → 插件（往 stdin 写一行 JSON）。"""
        data = (json.dumps(message, ensure_ascii=False) + "\n").encode("utf-8")
        os.write(self._stdin_w, data)

    def request(self, method, params):
        self._req_seq = getattr(self, "_req_seq", 0) + 1
        rid = "core-%d" % self._req_seq
        self.last_request_id = rid
        self.send({"jsonrpc": JSONRPC_VERSION, "id": rid, "method": method,
                   "params": params})
        return rid

    def notify(self, method, params):
        self.send({"jsonrpc": JSONRPC_VERSION, "method": method, "params": params})

    def hello(self, extra_args=None):
        """握手：插件会在 hello 之后**另开线程**做开工动作（订阅 / 面板 / 命令）。"""
        return self.request("hello", {"core_version": "selftest", "plugin_id": "sample",
                                      "scope": {}, "config": {}})
    # ── 断言用的读取 ─────────────────────────────────────────────────────

    def _wait(self, match, timeout=10.0):
        deadline = time.monotonic() + timeout
        seen = 0
        while time.monotonic() < deadline:
            while seen < len(self.inbound):
                message = self.inbound[seen]
                seen += 1
                if match(message):
                    return message
            time.sleep(0.01)
        return None

    def response(self, rid, timeout=10.0):
        """等某条请求的响应（有 id、没有 method）。"""
        return self._wait(lambda m: m.get("id") == rid and m.get("method") is None,
                          timeout)

    def reply(self, rid, result):
        """预设：插件发来 id=rid 的请求时回这个 result。"""
        self.replies[rid] = result

    def incoming(self, method):
        """等插件**主动发来**的一条请求（method + id）。"""
        return self._wait(lambda m: m.get("method") == method and "id" in m)

    def command_request(self, command, timeout=10.0):
        """等插件主动下的一条 station/command，并断言 command 名对得上。"""
        message = self._wait(
            lambda m: m.get("method") == METHOD_STATION_COMMAND
            and (m.get("params") or {}).get("command") == command,
            timeout,
        )
        return message

    def stream_notifications(self, request_id):
        return [m for m in self.inbound
                if m.get("method") == METHOD_STATION_STREAM
                and (m.get("params") or {}).get("request_id") == request_id]

    def generic_reply(self, method=None):
        """最近一次收到的**插件主动请求**的通用回包（method 非空时按它过滤）。

        `station/subscribe` 的回包**按请求内容现算**（而不是给一个固定的两点位形状）：
        真核心里「带 point / 给 station_id」只订一个点位，只有「不带 point 的 relay」
        才是一次订 tool.pre + tool.post。假核心若固定回两点位，自测就会锁住一个
        **真核心永远不会返回**的契约。
        """
        for message in reversed(self.inbound):
            if message.get("method") and message.get("id") is not None:
                if method is None or message.get("method") == method:
                    return self._generic_result(message)
        return {}

    @staticmethod
    def _generic_result(request=None):
        """通用回包：**故意给全**（订阅 / 自建站 / 命令都能认的形状）。"""
        params = (request or {}).get("params") or {}
        points = FakeCore._subscribed_points(params)
        return {
            "ok": True,
            "station_id": points[0],
            "station_ids": points,
            "kind": "relay", "scope": {"team_id": "team-1"},
            "replaced": "", "error": "",
            "subscriptions": [
                {"station_id": pid, "ok": True, "replaced": "", "error": ""}
                for pid in points
            ],
            "payload": {"text": "ok", "json": {"ok": True},
                        "model": "selftest-model",
                        "usage": {"prompt_tokens": 1, "completion_tokens": 1}},
        }

    @staticmethod
    def _subscribed_points(params):
        """假核心侧复刻真核心的点位解析（订阅回包用）。"""
        explicit = (params.get("station_id") or "").strip()
        if explicit:
            return [explicit]
        kind = (params.get("station") or "").strip()
        point = (params.get("point") or "").strip()
        relay_points = {
            "tool.pre": "system.relay.tool.pre",
            "tool.post": "system.relay.tool.post",
            "llm.handle": "system.relay.llm.handle",
            "llm.request": "system.relay.llm.request",
            "context.compact": "system.relay.context.compact",
            "prompt.system": "system.relay.prompt.system",
        }
        broadcast_points = {
            "tool.pre": "system.broadcast.tool.pre",
            "tool.post": "system.broadcast.tool.post",
        }
        if kind == "relay":
            if point:
                return [relay_points.get(point, "system.relay." + point)]
            # 不带 point 的 relay = 一次订工具前 + 工具后（点位化的兼容糖）
            return ["system.relay.tool.pre", "system.relay.tool.post"]
        if kind == "broadcast":
            if point:
                return [broadcast_points.get(point,
                                             "system.broadcast." + point)]
            # 不带 point 的 broadcast = 只订通用主题（与 relay 的糖**不对称**）
            return ["system.broadcast"]
        return ["plugin.tool.define"]

    def settle_loop(self):
        """把插件发来的请求按预设 / 通用 ok 回掉（一次遍历，幂等）。"""
        for message in list(self.inbound):
            rid = message.get("id")
            if rid is None or not message.get("method") or rid in self._replied:
                continue
            self._replied.add(rid)
            result = self.replies.get(rid)
            if result is None:
                result = self._generic_result()
            self.send({"jsonrpc": JSONRPC_VERSION, "id": rid, "result": result})

    def streaming(self, timeout=15.0):
        """收尾清扫：持续把在途请求回掉（含启动流程里排队的那几条）。"""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.settle_loop()
            time.sleep(0.02)

    def settle(self, timeout=5.0):
        """把当前所有在途请求回掉（不睡眠等待新请求）：握手后用一次即可。"""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.settle_loop()
            time.sleep(0.02)


class SelftestCase(object):
    """一个自测用例：跑插件实例（线程）+ 假核心，断言失败**不静默**。"""

    def __init__(self, name, argv, agent_id=None):
        self.name = name
        self.argv = argv
        self.agent_id = agent_id
        self.failures = []
        self.notes = []
        self.stream_request_ids = []   # 我方每次 llm.handle 请求里带的 request_id

    def check(self, condition, message):
        if not condition:
            self.failures.append(message)

    def note(self, message):
        self.notes.append(message)

    def run(self):
        from io import StringIO  # noqa: PLC0415 - 只为接住插件的 stderr
        options = parse_options(self.argv)
        plugin = SamplePlugin(options)
        saved_stderr = sys.stderr
        # 插件的日志很多：自测里静音，失败时把尾部回放出来（可读原因必须看得到）
        captured = StringIO()
        sys.stderr = captured
        try:
            with FakeCore() as core:
                plugin.run_in_thread()
                self.core = core
                try:
                    self.body(core, plugin)
                finally:
                    plugin._closed = True
                    core.notify("shutdown", {})
                    core.streaming(timeout=5.0)
        except Exception as error:  # noqa: BLE001 - 用例异常 = 失败，不炸整个 selftest
            self.failures.append("用例异常：%r" % (error,))
        finally:
            sys.stderr = saved_stderr
        if self.failures:
            # 失败时回放插件日志尾部：自测把 stderr 静音了，但"可读原因"必须看得到
            tail = [line for line in captured.getvalue().splitlines()[-6:] if line]
            if tail:
                self.failures.append("插件日志尾部：%s" % " ｜ ".join(tail))
        return self

    # ── 通用断言片段 ─────────────────────────────────────────────────────

    def handshake(self, core, plugin, hello=True):
        """握手 + 把在途请求回掉（含首次 station/subscribe），返回 False = 已失败。"""
        if hello:
            core.hello()
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline and not plugin._hello.is_set():
            time.sleep(0.01)
        self.check(plugin._hello.is_set(), "插件未在 10s 内完成 hello 握手")
        if not plugin._hello.is_set():
            return False
        # 订阅是**插件主动发来的请求**：回掉启动流程里排队的全部请求再往下走
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            if core.incoming("station/subscribe") is not None:
                break
            time.sleep(0.01)
        core.settle(timeout=2.0)
        return True

    def subscribe_requests(self, core):
        return [m for m in core.inbound if m.get("method") == "station/subscribe"]

    def ask_llm(self, core, text, request_id=None, ack=True):
        """发一条 llm.handle 请求；ack=True 时把回包读掉并返回 payload（reply.payload）。

        ⚠ `params.request_id`（关联 `station/stream` 用）与 JSON-RPC 的 `id`（关联
        回包用）是**两个不同的东西**。真核心里前者是 `relay-<秒>-<序号>`、后者由
        JSON-RPC 层生成；这里故意取一个可预测的值，好断言"插件原样带回"。
        """
        stream_id = request_id or "relay-%d" % (len(self.stream_request_ids) + 1)
        rid = core.request(METHOD_STATION_REQUEST, {
            "request_id": stream_id,
            "station_id": STATION_RELAY_LLM_HANDLE,
            "kind": "relay",
            "scope": {"team_id": "team-1", "agent_id": self.agent_id or "agt_demo",
                      "session_id": "ses_demo", "mode_key": "local"},
            "payload": {
                "point": STATION_RELAY_LLM_HANDLE,
                "turn": 1,
                "agent_id": self.agent_id or "agt_demo",
                "session_id": "ses_demo",
                "request": {"model": "selftest-model", "stream": True,
                            "messages": [{"role": "system", "content": "你是助手"},
                                         {"role": "user", "content": text}]},
            },
            "meta": {"purpose": "llm.handle", "turn": 1},
        })
        self.stream_request_ids.append(stream_id)
        if not ack:
            return None
        return self.wait_reply(core, rid)

    def stream_id(self, index=-1):
        """我方最近一次 llm.handle 请求里带的 `request_id`（插件必须原样带回）。

        ⚠ 注意与"报文 id（core-N）"区分：前者是 **params.request_id**（核心生成、
        用来关联 `station/stream`），后者是 JSON-RPC 的 id（用来关联回包）。
        """
        if not self.stream_request_ids:
            return ""
        return self.stream_request_ids[index]

    def stream_done(self, core, request_id, timeout=15.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for message in core.stream_notifications(request_id):
                params = message.get("params") or {}
                if params.get("done") or params.get("error"):
                    return params
            time.sleep(0.02)
        return None

    def wait_reply(self, core, rid, timeout=10.0):
        """等我方 `station/request` 的回包（`{reply:{payload:…}}`），返回 payload。"""
        response = core.response(rid, timeout)
        self.check(response is not None, "station/request 没收到回包（核心会一直等）")
        if response is None:
            return None
        reply = (response.get("result") or {}).get("reply") or {}
        return reply.get("payload")

    def wait_notification(self, core, method, since=0, timeout=3.0):
        """等插件**发出**的一条通知（method 匹配），返回报文；超时返回 None。

        [since] 传"动作发送前的 `len(core.inbound)`"：旧报文不该被算成本次的结果，
        否则用例会在"插件其实没反应"时假通过（这正是这条链路以前的样子）。
        """
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for message in core.inbound[since:]:
                if message.get("method") == method:
                    return message
            time.sleep(0.01)
        return None

    # ── 用例实现 ─────────────────────────────────────────────────────────

    def body(self, core, plugin):
        name = self.name
        if name == "订阅 llm.handle":
            self.case_subscribe_llm_handle(core, plugin)
        elif name == "流式接管的 request_id":
            self.case_stream_request_id(core, plugin)
        elif name == "station/cancel 停流":
            self.case_cancel(core, plugin)
        elif name == "不命中关键词不接管":
            self.case_no_takeover(core, plugin)
        elif name == "llm.call 构造":
            self.case_llm_call(core, plugin)
        elif name == "tool.call 构造":
            self.case_tool_call(core, plugin)
        elif name == "session.rename 构造":
            self.case_rename(core, plugin)
        elif name == "prompt.system 改写":
            self.case_prompt_system(core, plugin)
        elif name == "tool 广播订阅":
            self.case_broadcast(core, plugin)
        elif name == "面板动作回传":
            self.case_ui_action(core, plugin)
        else:
            self.failures.append("未知用例 %s" % name)

    def case_subscribe_llm_handle(self, core, plugin):
        """① 订阅 `system.relay.llm.handle`：请求带 point 别名，回包形状完整。

        注意：**不在这里另发一次 `subscribe_station`**——插件启动线程已经在订了，
        再发一次会和它抢同一个 request_core 通道（假核心按 id 回包，重复调用只会
        多出一条 timeout 日志）。这里直接验证"请求形状 + 通用回包可被解析"。
        """
        if not self.handshake(core, plugin):
            return
        deadline = time.monotonic() + 10.0
        found = None
        while time.monotonic() < deadline and found is None:
            for message in self.subscribe_requests(core):
                params = message.get("params") or {}
                if params.get("point") == "llm.handle" or \
                        params.get("station") == STATION_RELAY_LLM_HANDLE or \
                        params.get("station_id") == STATION_RELAY_LLM_HANDLE:
                    found = params
                    break
            time.sleep(0.01)
        self.check(found is not None,
                   "没发出 llm.handle 的订阅请求（--relay-llm 没生效？）")
        if found is None:
            return
        # 回包形状：{ok, station_id, station_ids, kind, scope, replaced, error, subscriptions}
        # ——**带 point 的订阅只订一个点位**：station_ids 就是那一个、subscriptions 一条。
        #   （只有"不带 point 的 relay"才是糖：一次订 tool.pre + tool.post 两个点位。）
        self.check(found.get("station") == "relay" and found.get("point") == "llm.handle",
                   "订阅请求形状不对：应为 {station: relay, point: llm.handle}，实际 %s"
                   % found)
        self.check("replace" in found, "订阅请求没带 replace（点位的接管语义靠它）")
        reply = core.generic_reply("station/subscribe")
        self.check(reply.get("ok") is True, "订阅回包 ok 不为 true：%s" % reply)
        self.check(reply.get("station_ids") == [STATION_RELAY_LLM_HANDLE],
                   "带 point 的订阅应只报一个点位：%s" % reply.get("station_ids"))
        self.check(reply.get("station_id") == STATION_RELAY_LLM_HANDLE,
                   "旧字段 station_id 仍在，且等于 station_ids[0]：%s"
                   % reply.get("station_id"))
        self.check(isinstance(reply.get("subscriptions"), list)
                   and len(reply.get("subscriptions") or []) == 1,
                   "逐条 subscriptions 应是一条（部分成功时唯一的可读来源）")
        # 顺带演示"糖"：不带 point 的 relay = 一次订工具前 + 工具后两个点位
        sugar = type(core)._generic_result(
            {"params": {"station": "relay"}})
        self.check(sugar.get("station_ids") == ["system.relay.tool.pre",
                                                "system.relay.tool.post"]
                   and len(sugar.get("subscriptions") or []) == 2,
                   "不带 point 的 relay 应一次订两个工具点位：%s"
                   % sugar.get("station_ids"))
        self.note("订阅请求：station=relay point=llm.handle replace=%s；回包 ok=%s "
                  "station_ids=%s subscriptions=%d 条；糖（不带 point）=%s"
                  % (found.get("replace"), reply.get("ok"), reply.get("station_ids"),
                     len(reply.get("subscriptions") or []), sugar.get("station_ids")))

    def case_stream_request_id(self, core, plugin):
        """②③ 流式接管：request_id 取自请求；分片 + done 收尾；中途一直应答 ping。"""
        if not self.handshake(core, plugin):
            return
        core.settle(timeout=0.5)
        # 中途要能应答 ping（核心在等流时同时看心跳）——现在发一拍
        ping_rid = core.request("ping", {})
        payload = self.ask_llm(core, "请用示例插件接管：你好")
        self.check(payload is not None, "llm.handle 无回包")
        self.check(isinstance(payload, dict) and payload.get("stream") is True,
                   "命中关键词时应回 {stream: true}，实际：%s" % payload)
        ping_response = core.response(ping_rid, timeout=5.0)
        self.check(ping_response is not None, "推流期间 ping 没被应答（心跳会丢）")
        rid = self.stream_id()
        done = self.stream_done(core, rid)
        self.check(done is not None, "没等到 done / error 收尾（这一轮会一直等）")
        if done is not None:
            self.check(done.get("done") is True, "收尾不是 done：%s" % done)
            self.check(done.get("finish_reason") == "stop",
                       "done 没带 finish_reason：%s" % done)
            self.check(bool(done.get("usage")), "done 没带 usage：%s" % done)
        notes = core.stream_notifications(rid)
        self.check(len(notes) >= 4, "增量太少（应 3~5 片 + done）：%d" % len(notes))
        # **最关键的一条**：每一条增量都带"请求里那个 request_id"，不能自己编
        self.check(all((m.get("params") or {}).get("request_id") == rid for m in notes),
                   "station/stream 的 request_id 与请求不一致（核心会丢弃整条流）")
        kinds = [(m.get("params") or {}).get("delta", {}).get("kind")
                 for m in notes if (m.get("params") or {}).get("delta")]
        self.check("thinking" in kinds, "没有 thinking 增量：%s" % kinds)
        self.check(kinds.count("text") >= 3, "text 增量不足 3 片：%s" % kinds)
        text = "".join((m.get("params") or {}).get("delta", {}).get("text", "")
                       for m in notes
                       if (m.get("params") or {}).get("delta", {}).get("kind") == "text")
        self.check("示例插件已接管本轮 LLM" in text, "正文分片拼不出预期内容：%r" % text)
        self.note("增量 %d 条（kinds=%s），request_id 全部原样带回，ping 期间未阻塞"
                  % (len(notes), kinds))

    def case_cancel(self, core, plugin):
        """③ 收到 station/cancel：停流、不崩、之后仍应答 ping、不再推 done。

        取消是**逐片检查**的（读循环线程只标状态）——所以断言的口径是"取消消息被
        插件读到时，最多只剩**一片**在飞"，而不是"一片都没有"。
        """
        if not self.handshake(core, plugin):
            return
        core.settle(timeout=0.5)
        pid = "relay-selftest-cancel"
        payload = self.ask_llm(core, "请用示例插件接管：会被取消", request_id=pid)
        self.check(isinstance(payload, dict) and payload.get("stream") is True,
                   "命中关键词应回 {stream: true}：%s" % payload)
        # 声明接管之后**立刻**取消（不等 done）
        core.notify("station/cancel", {"request_id": pid, "reason": "用户已停止本轮生成"})
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            if any("停止推流" in entry for entry in core.logs):
                break
            time.sleep(0.02)
        self.check(any("停止推流" in entry for entry in core.logs),
                   "插件没报告收到 station/cancel 并停流：%s" % core.logs[-3:])
        ping_rid = core.request("ping", {})
        self.check(core.response(ping_rid, timeout=5.0) is not None,
                   "取消之后插件不再应答 ping（读循环被推流占住了？）")
        time.sleep(0.8)   # 留出"如果没停流"会继续推片的时间窗
        notes = core.stream_notifications(pid)
        self.check(not any((m.get("params") or {}).get("done") for m in notes),
                   "取消之后仍推了 done（核心已收尾，会记无效 id）")
        deltas = [m for m in notes if (m.get("params") or {}).get("delta")]
        self.check(len(deltas) <= 1,
                   "取消之后还在推增量（说明没真的停流）：%d 条" % len(deltas))
        # 取消之后插件必须还能正常接管下一条流（读循环 / 线程都没被取消弄坏）
        again = "relay-selftest-after-cancel"
        payload = self.ask_llm(core, "请用示例插件接管：取消之后再来一次",
                               request_id=again)
        self.check(isinstance(payload, dict) and payload.get("stream") is True,
                   "取消之后无法再接管（流状态没清干净）：%s" % payload)
        self.check(self.stream_done(core, again) is not None,
                   "取消之后的第二条流没能在 15s 内收尾")
        self.note("取消后增量 %d 条、无 done、ping 仍通；第二条流正常接管并收尾"
                  % len(deltas))

    def case_no_takeover(self, core, plugin):
        """⑤ 关键词不匹配 ⇒ 回 `{"payload": null}`（不接管，走系统 LLM）。"""
        if not self.handshake(core, plugin):
            return
        core.settle(timeout=0.5)
        payload = self.ask_llm(core, "这是一条普通消息，没有关键词")
        # wait_reply 已经把"回包存在"断言过了；空 payload 正是"不接管"的语义
        self.check(payload is None,
                   "不命中时应回 {reply:{payload:null}}，实际：%r" % (payload,))
        self.check(not core.stream_notifications(self.stream_id()),
                   "不接管却推了 station/stream 增量")
        self.note("不命中关键词：回包 payload=null，无任何增量")

    def case_llm_call(self, core, plugin):
        """④-a `llm.call` 的请求构造（含 agent_id 解析与 json/text 打印）。"""
        if not self.handshake(core, plugin):
            return
        core.settle(timeout=0.5)
        message = core.command_request(CMD_LLM_CALL)
        self.check(message is not None, "没有发出 llm.call 命令")
        if message is None:
            return
        params = message.get("params") or {}
        arguments = params.get("arguments") or {}
        self.check(params.get("command") == CMD_LLM_CALL,
                   "command 名不对：%s" % params.get("command"))
        self.check(arguments.get("prompt") == "回一个 JSON：{\"ok\":true}",
                   "prompt 没带上：%s" % arguments)
        self.check(arguments.get("agent_id") == "agt_demo",
                   "agent_id 必须在 arguments 里（挂载位置只读 arguments）：%s" % arguments)
        self.check("system" in arguments, "system 提示词没带上")
        core.settle(timeout=0.5)
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            if any("llm.call 成功" in entry for entry in core.logs):
                break
            time.sleep(0.02)
        self.check(any("llm.call 成功" in entry for entry in core.logs),
                   "llm.call 回包没被解析成可读日志：%s" % core.logs[-3:])
        self.note("llm.call 请求：command=%s agent_id=%s prompt=%r"
                  % (params.get("command"), arguments.get("agent_id"),
                     arguments.get("prompt")))

    def case_tool_call(self, core, plugin):
        """④-b `tool.call` 的请求构造（默认 relay=false，绕开中转 / 广播）。"""
        if not self.handshake(core, plugin):
            return
        core.settle(timeout=0.5)
        message = core.command_request(CMD_TOOL_CALL)
        self.check(message is not None, "没有发出 tool.call 命令")
        if message is None:
            return
        arguments = (message.get("params") or {}).get("arguments") or {}
        self.check(arguments.get("tool") == "read", "tool 名不对：%s" % arguments)
        self.check(arguments.get("arguments") == {"file_path": "README.md"},
                   "arguments 没原样带上：%s" % arguments)
        self.check(arguments.get("relay") is False,
                   "默认必须绕开工具中转 / 广播（relay=false）：%s" % arguments)
        self.check("agent_id" in arguments, "agent_id 没带上：%s" % arguments)
        core.settle(timeout=0.5)
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            if any("tool.call 结果" in entry for entry in core.logs):
                break
            time.sleep(0.02)
        self.check(any("tool.call 结果" in entry for entry in core.logs),
                   "tool.call 回包没被解析：%s" % core.logs[-3:])
        self.note("tool.call 请求：tool=%s arguments=%s relay=%s"
                  % (arguments.get("tool"), arguments.get("arguments"),
                     arguments.get("relay")))

    def case_rename(self, core, plugin):
        """④-c `session.rename` 的请求构造（title 必填、带时间戳）。"""
        if not self.handshake(core, plugin):
            return
        core.settle(timeout=0.5)
        message = core.command_request(CMD_SESSION_RENAME)
        self.check(message is not None, "没有发出 session.rename 命令")
        if message is None:
            return
        arguments = (message.get("params") or {}).get("arguments") or {}
        title = str(arguments.get("title") or "")
        self.check(bool(title.strip()), "title 为空会被执行站拒绝：%s" % arguments)
        self.check("示例插件改名" in title, "title 不像本插件的命名：%r" % title)
        self.check(len(title) > len("示例插件改名 "), "title 没带时间戳：%r" % title)
        self.check(arguments.get("agent_id") == "agt_demo", "agent_id 没带上：%s" % arguments)
        core.settle(timeout=0.5)
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            if any("session.rename 成功" in entry for entry in core.logs):
                break
            time.sleep(0.02)
        self.check(any("session.rename 成功" in entry for entry in core.logs),
                   "session.rename 回包没被解析：%s" % core.logs[-3:])
        self.note("session.rename 请求：title=%r" % title)

    def case_prompt_system(self, core, plugin):
        """`--relay-prompt`：订阅 prompt.system，并在 default 后追加一行。"""
        if not self.handshake(core, plugin):
            return
        deadline = time.monotonic() + 10.0
        found = None
        while time.monotonic() < deadline and found is None:
            for message in self.subscribe_requests(core):
                if (message.get("params") or {}).get("point") == "prompt.system":
                    found = message
                    break
            time.sleep(0.01)
        self.check(found is not None, "没发出 prompt.system 的订阅请求")
        core.settle(timeout=0.5)
        rid = core.request(METHOD_STATION_REQUEST, {
            "request_id": "relay-selftest-prompt",
            "station_id": STATION_RELAY_PROMPT_SYSTEM,
            "kind": "relay",
            "scope": {"team_id": "team-1", "agent_id": "agt_demo",
                      "session_id": "ses_demo", "mode_key": "local"},
            "payload": {"point": STATION_RELAY_PROMPT_SYSTEM, "agent_id": "agt_demo",
                        "session_id": "ses_demo", "default": "你是 Tree 的助手。"},
        })
        payload = self.wait_reply(core, rid)
        self.check(payload is not None, "prompt.system 请求没收到回包")
        self.check(isinstance(payload, str) and payload.startswith("你是 Tree 的助手。"),
                   "改写后的提示词应保留 default 原文：%r" % payload)
        self.check(isinstance(payload, str)
                   and "（本提示词由示例插件改写）" in payload,
                   "改写标记没加上：%r" % payload)
        self.note("prompt.system 回包：%r" % payload)

    def case_broadcast(self, core, plugin):
        """`--watch-tools`：订两个广播点位，收到工具调用通知并计数、照常回包。"""
        if not self.handshake(core, plugin):
            return
        core.settle(timeout=0.5)
        deadline = time.monotonic() + 10.0
        points = set()
        while time.monotonic() < deadline and len(points) < 2:
            for message in self.subscribe_requests(core):
                params = message.get("params") or {}
                if params.get("station") == "broadcast":
                    points.add(str(params.get("point")))
            time.sleep(0.01)
        self.check(points == {"tool.pre", "tool.post"},
                   "两个工具广播点位没都订上（广播站不带 point 只订通用主题）：%s" % points)
        # 模拟核心发来的两条广播（pre / post）：插件必须回包（通知方在等回包）
        for phase, point in (("pre", STATION_BROADCAST_TOOL_PRE),
                             ("post", STATION_BROADCAST_TOOL_POST)):
            rid = core.request(METHOD_STATION_REQUEST, {
                "request_id": "broadcast-%s" % phase, "station_id": point,
                "kind": "broadcast",
                "scope": {"team_id": "team-1", "agent_id": "agt_demo",
                          "session_id": "ses_demo", "mode_key": "local"},
                "payload": {"point": point, "phase": phase, "origin": "agent",
                            "tool": "read", "call_id": "call_b1", "round": 1,
                            "agent_id": "agt_demo", "session_id": "ses_demo",
                            "arguments": {"file_path": "a.txt"},
                            "result": "A 的内容", "is_error": False},
                "meta": {"topic": "tool.%s" % phase},
            })
            payload = self.wait_reply(core, rid)
            self.check(payload is None,
                       "广播回包应是 {reply:{payload:null}}（没有附言）：%s" % payload)
        with plugin._state_lock:
            total = plugin.tool_broadcast_total
            pre = plugin.tool_broadcast_pre
            post = plugin.tool_broadcast_post
        self.check(total == 2 and pre == 1 and post == 1,
                   "广播计数不对：total=%s pre=%s post=%s" % (total, pre, post))
        self.note("广播点位：%s；计数 total=%d pre=%d post=%d"
                  % (sorted(points), total, pre, post))

    def case_ui_action(self, core, plugin):
        """面板按钮回传：**核心发的是 `event` 通知**（判据在 `params.event` 上）。

        这条链路以前是断的：本插件当时判 `method == "plugin_ui_action"`，而核心实际发
        `{"method":"event","params":{"event":"plugin_ui_action",…}}` ⇒ 面板按钮"点了没
        反应"（而它的兄弟分支 `_on_event` 还会把这个事件当"非 tool_call 事件"丢掉）。
        所以这里把两种形态都喂一遍，断言插件**发出了一帧 `ui/update`**——那是"处理过"
        的唯一证据（动作是单向通知，核心不解释语义、也没有回执）。
        """
        if not self.handshake(core, plugin):
            return
        core.settle(timeout=0.5)
        slot_key = "%s.activity.1" % plugin.plugin_id

        # ① 线上真实形状：event 通知 + params.event == "plugin_ui_action"
        before = len(core.inbound)
        core.notify("event", {
            "event": EVENT_UI_ACTION,
            "plugin_id": plugin.plugin_id,
            "team_id": "team-1",
            "agent_id": "agt_demo",
            "session_id": "ses_demo",
            "slot_key": slot_key,
            "action_id": "refresh",
            "payload": {},
        })
        update = self.wait_notification(core, METHOD_UI_UPDATE, before)
        self.check(update is not None,
                   "event 形态的面板动作没被处理（判据必须是 params.event，不是 method）")
        if update is not None:
            params = update.get("params") or {}
            self.check(params.get("slot_key") == slot_key,
                       "刷新的不是面板槽位：%r" % params.get("slot_key"))
            self.check(isinstance(params.get("view"), dict),
                       "ui/update 没带 view（整块替换必须有视图）：%r" % params)
            self.note("面板动作回传（event 形态）：刷新了 %s" % params.get("slot_key"))

        # ② 老核心 / 直连测试的形态：裸 method=plugin_ui_action 同样要处理
        before2 = len(core.inbound)
        core.notify(EVENT_UI_ACTION, {"action_id": "refresh", "slot_key": ""})
        self.check(self.wait_notification(core, METHOD_UI_UPDATE, before2) is not None,
                   "裸 method=plugin_ui_action 的形态没兼容（老核心点按钮会没反应）")

        # ③ 无关事件不该被误当成面板动作（判据放宽不能宽到把 tool_call 也吃进去）
        before3 = len(core.inbound)
        core.notify("event", {"event": EVENT_TOOL_CALL, "agent_id": "agt_demo",
                              "session_id": "ses_demo", "call_id": "call_x",
                              "tool": "read", "phase": PHASE_END, "round": 1})
        self.check(self.wait_notification(core, METHOD_UI_UPDATE, before3, timeout=0.5)
                   is None, "非面板事件不该触发面板刷新")
        # 未知 action 不刷面板、但要留在日志里（不静默）
        before4 = len(core.inbound)
        core.notify("event", {"event": EVENT_UI_ACTION, "action_id": "不存在的动作",
                              "slot_key": slot_key, "payload": {}})
        self.check(self.wait_notification(core, METHOD_UI_UPDATE, before4, timeout=0.5)
                   is None, "未知 action 不该刷新面板")
        self.check(any("不存在的动作" in line for line in core.logs),
                   "未知 action 必须留日志（不静默）：%s" % core.logs[-3:])
        # 按钮回调是**单向**的：全程不该冒出响应报文（核心没发请求过来）
        self.check(not [m for m in core.inbound[before:]
                        if m.get("id") is not None and m.get("method") is None],
                   "面板动作是通知：插件不该回响应")


def _selftest(argv, out=None):
    """跑全部自测用例；返回进程退出码（0 = 全通）。"""
    # 输出**强制 ASCII**：Windows 控制台默认 GBK，中文注释与箭头会让自测自己崩在
    # 编码上（"自测因为日志编码失败"是最容易浪费排查时间的一种假失败）。
    stream = out or sys.stdout
    if hasattr(stream, "buffer"):
        def write(text):
            stream.buffer.write(text.encode("utf-8", "backslashreplace"))
            stream.buffer.flush()
    else:
        def write(text):
            stream.write(text)
            stream.flush()
    write("sample_plugin 自测（假核心，不连真核心）\n")
    shared = ["--no-fs-demo", "--no-panel", "--no-relay"]
    agent = ["--agent-id", "agt_demo"]
    keyword = ["--relay-llm", "示例插件接管"]
    cases = [
        SelftestCase("订阅 llm.handle", shared + keyword, agent_id="agt_demo"),
        SelftestCase("流式接管的 request_id", shared + keyword, agent_id="agt_demo"),
        SelftestCase("station/cancel 停流", shared + keyword, agent_id="agt_demo"),
        SelftestCase("不命中关键词不接管", shared + keyword, agent_id="agt_demo"),
        SelftestCase("llm.call 构造",
                     shared + agent + ["--llm-call", "回一个 JSON：{\"ok\":true}"]),
        SelftestCase("tool.call 构造",
                     shared + agent + ["--tool-call", "read", "{\"file_path\": \"README.md\"}"]),
        SelftestCase("session.rename 构造", shared + agent + ["--rename-session"]),
        SelftestCase("prompt.system 改写", shared + ["--relay-prompt"], agent_id="agt_demo"),
        SelftestCase("tool 广播订阅", shared + ["--watch-tools"], agent_id="agt_demo"),
        # 面板动作回传：**不带 --no-panel**（本用例要的就是面板槽位 + 它的刷新帧）
        SelftestCase("面板动作回传", ["--no-fs-demo"], agent_id="agt_demo"),
    ]
    failed = 0
    for case in cases:
        case.run()
        if case.failures:
            failed += 1
            # 用纯 ASCII 的标记：Windows 控制台默认 GBK，✓/✗ 会让自测自己崩在编码上
            write("[FAIL] %s\n" % case.name)
            for failure in case.failures:
                write("    - %s\n" % failure)
        else:
            write("[ok] %s：%s\n" % (case.name, "；".join(case.notes) or "通过"))
    total = len(cases)
    write("自测结果：%d/%d 通过%s\n"
          % (total - failed, total, "" if not failed else "（有失败项，见上）"))
    return 0 if not failed else 1


def main():
    options = parse_options(sys.argv[1:])
    if options.selftest:
        return _selftest(sys.argv[1:])
    SamplePlugin(options).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
