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
就能整段命中。**三条一起成立才行**（少一条就整段不命中；2026-10-04 真机实测）：

1. `request.tools` 原样透传（工具定义在聊天模板里渲染在 messages **之前**）；
2. **不用** `llm.call` 的 `system` 参数（那会在最前面插一条 system 消息，整体错位）；
3. **`response_format` 显式传 `"text"`**：`llm.call` 缺省会硬设
   `{"type":"json_object"}`，而实测**端点为 JSON 模式改写了提示词**（同一批 messages
   恒定 +22 token，改写落在 messages 之前/其中）⇒ 上面那条"逐字一致"的前缀整段丢缓存。
   对照实验（两端点一致）：同一 492 token 前缀 plain 重发命中 384/256，**只加
   `json_object` 掉到 0**；`tools` 并没有被丢弃（+270 token 两种模式都在）。
   改走 text 后，输出格式由下面的指令约束；偶发非法 JSON ⇒ `llm.call` 如实报错
   ⇒ 本插件回 `null` ⇒ 核心回退内置压缩（兜底不变）。

切点（`cut`）在 **wire 坐标**里决定，三条规则：
    1. 保留最近 `--keep-rounds` 轮 user 及其之后；
    2. 该区域里的工具轮（assistant+tool_calls）超过 `--keep-tool-rounds`（默认 8）时，
       只保留最后 8 轮——单轮超长工具轨迹因此**压得动**；
    3. 切点不得落在 `tool` 消息上（否则尾部以孤儿工具结果开头，端点直接 400）。

尾部抄回后上下文只会变小（槽位 + 摘要 + 必读 + ≤8 个工具轮），不会再贴着阈值，
所以这里**不设**"输入太大就少压一点"的自适应：那只会多留原文、压得更少，方向是反的。

失败一律回 `null`（不接管）⇒ 核心回退内置 compact，上下文不会丢。

**左栏面板**（2026-10-03）：插件用 `ui/manifest` 申报一个 `activity` 槽位（左侧活动
栏的一个图标 + 左栏里的一整页内容），之后用 `ui/update` 推内容——最近 N 次压缩
（时间 / 来源 / 覆盖条数 / 耗时 / 降级或未接管原因、**用量**），外加一个「立即压缩
一次」按钮（经执行站 `agent.compact`，走核心既有的手动压缩入口）。

- 来源列：`relay`（本插件接管）、`builtin`（**核心内置** compact 的那次总结）、
  `llm.call`（经执行站的一次性调用——压缩插件的总结调用走的就是它）、`plugin`
  （`llm.handle` 被插件整体接管的一跳）；拿不到就显示 `未知`，**不猜**。
- **用量从哪来**：逐调用账本落在数据根下的会话目录里（`data/<agent>/<session>/
  usage.jsonl`），而本插件（`fs.read` 只在工作空间作用域内）**读不到数据根**——
  所以核心在压缩中转 payload 里捎上**最近 50 行**（`recent_usage`）+ 账本路径
  （`usage_file`，排障用）。它是个滚动窗口、**每次请求都重发**，这里按"整行内容"
  去重后并入面板。
- `--usage-jsonl PATH` 是**离线回放**旁路（不给核心时把一份账本文件喂给面板看）。
- 视图只能是**受限控件集**（text / list / table / form / progress / actions 与
  row / column 容器）：没有 webview、不执行插件 JS。
- `--no-panel` = 完全不申报面板（只在后台跑压缩时用）。

自检（**不需要真核心**）：

    python examples/plugins/compact_plugin.py --selftest
"""

import datetime
import json
import os
import re
import sys
import tempfile
import threading
import time

JSONRPC_VERSION = "2.0"
METHOD_STATION_COMMAND = "station/command"
METHOD_STATION_REQUEST = "station/request"
METHOD_STATION_SUBSCRIBE = "station/subscribe"

STATION_RELAY_CONTEXT_COMPACT = "system.relay.context.compact"

ERR_METHOD_NOT_FOUND = -32601
ERR_INTERNAL = -32603

# ── 插件布局（左栏面板）与面板交互 ──────────────────────────────────────────
METHOD_UI_MANIFEST = "ui/manifest"
METHOD_UI_UPDATE = "ui/update"

#: **面板按钮回调的事件名**。注意判据在 `params.event` 上：核心把前端动作包成
#: `{"jsonrpc":"2.0","method":"event","params":{"event":"plugin_ui_action",
#:   "slot_key":…,"action_id":…,"payload":…}}`（与 `agent.tool_call` 同一范式）。
#: 判 `method == "plugin_ui_action"` 会**永远不命中**（表现为"按钮点了没反应"）。
EVENT_UI_ACTION = "plugin_ui_action"

#: 执行站命令：手动压一次（`system.execute.agent` 点位，核心映射到 CompactionService）。
CMD_AGENT_COMPACT = "agent.compact"

#: 左栏槽位键：`activity` = 活动栏图标项 + 左栏整页内容（两侧是同一个槽位）。
SLOT_ACTIVITY = "compact.activity.1"
PANEL_TITLE = "上下文压缩"
#: 活动栏图标名走前端白名单（未知名回退扩展图标，见 lib/ui/widgets/plugin_ui_slots.dart）。
PANEL_ICON = "chart"
#: 面板里显示多少条记录（内部最多留 100 条，够翻不必刷）。
DEFAULT_PANEL_RECORDS = 10
#: 面板刷新节流（秒）：压缩可能连续触发，左栏页会整块重建，刷太勤只是闪。
PANEL_MIN_INTERVAL = 0.5
#: 受限控件集（协议 PluginUiViewType.all）：超出的类型前端渲染成"不支持的控件"占位。
VIEW_TYPES = ("text", "list", "table", "form", "progress", "actions", "row", "column")
#: 来源列的人话（核心给的 source 只有 relay / builtin；拿不到就"未知"）。
SOURCE_LABELS = {"relay": "relay", "builtin": "builtin"}

#: `usage.jsonl` 的 `source` → 面板"来源"列（**照核心 `UsageSource` 的口径**）。
#: `turn` 故意不在表里：那是对话自己的跳，不属于这个面板（会被跳过）。
USAGE_SOURCE_LABELS = {
    # 内置压缩（核心 `LlmSummarizer` 的一次总结补全）——核心的内置兜底就记这个来源，
    # 于是"内置压了几次、每次多少 token"在这里第一次可见。
    "compact": "builtin",
    # 执行站 `llm.call`：**压缩插件的总结调用走的就是它**（前缀复用那一跳）。
    "llm.call": "llm.call",
    # `llm.handle` 被插件**整体接管**的一跳（用量由插件回填，无则本地估算）。
    "plugin": "plugin",
}

#: 面板内部最多留多少条用量记录（面板只显示 panel_records 条，这里留余量即可）。
MAX_USAGE_RECORDS = 200
#: 面板表格的列名（顺序即展示顺序；面板与自检共用一份，防止两边漂移）。
#: 用 list 而不是 tuple：视图最终是 JSON，且自检的列名/单元格数一致性检查按数组看。
PANEL_COLUMNS = ["时间", "来源", "覆盖条数", "耗时", "降级 / 未接管原因"]

#: 固定的"伪推理"文案（Q6 定稿）：让伪造的这条 assistant 在带 tools 的思考模式端点上
#: 满足"历史 assistant 必须带 reasoning_content"的口径（见 recon.md 的 G1/G3 实测）。
REASONING_TEXT = "上下文压缩后，我先 read 相关文件，获取 todo 列表"

#: **追加在缓存前缀之后**的总结指令（最后一条 user 消息）。
#: 四个硬要求：①把输出形状写死在指令里（这一步**不**靠 `response_format` 强约束——
#: 那会让端点改写提示词、前缀缓存全丢，见模块 docstring 的"缓存"段）；
#: ②明确"只输出一个 json 对象、不要代码块/解释"（text 形态下格式全靠指令兜住）；
#: ③**完整优先，不要求少写**：这份摘要是后续唯一的背景来源，省下的字会变成后面
#:   重复探索的成本；防截断靠"不设小 max_tokens + 下面的 json 契约"，**不靠少写**；
#: ④键必须齐全（缺键 = 解析出的结构不完整，与"正文写得多"是两件事）。
SUMMARY_INSTRUCTION = """以上是本次任务到目前为止的完整上下文。请把它压成"继续这个任务所必需"的要点；\
**力求完整**（宁可写详细，也不要把还在生效的约束、结论、失败尝试丢掉）。

**输出契约（违反即本次压缩作废，请严格照做）**：
1. **只输出一个 json 对象**：第一个字符就是 `{`，最后一个字符就是 `}`；
2. **不要** markdown 代码块（不要 ``` ），**不要**任何解释或前后缀文字；
3. 下面这**四个键全部都要出现**，结构照抄（没有内容就给 `""` 或 `[]`，不要省略键）：

{
  "background": "任务背景与目标、用户的关键约束（尽量完整）",
  "trajectory": "已经做过什么、结论是什么、哪些尝试失败或已被推翻（力求完整、够继续任务）",
  "files_changed": [{"path": "工作空间相对路径", "change": "新增/修改/删除 + 一句话"}],
  "required_files": [{"path": "工作空间相对路径", "start_line": 1, "line_count": 80,
                      "why": "为什么后续必须读它"}]
}

规则：
- **字符串里不要出现裸换行**（要换行就写 `\\n`），引号要转义，**不要尾逗号、不要注释**；
- 内容写多没问题，**但一个字都不要落在 json 之外**：写长的代价只是 token，
  写坏（夹解释 / 半截 json / 少引号）的代价是整次压缩作废；
- 路径只允许**工作空间相对路径**（如 `lib/a.dart`、`docs/x.md`），不要绝对路径、不要 `..`；
- `required_files` 不超过 %(max_files)d 个，按重要性排序，**精确到行范围**（只给真正要读的那段）；
  优先列：核心文档 / 计划文档（`.self/plan/**`）/ 正在编辑或与任务直接相关的模块；
  不要列目录、不要列日志、不要列你已完整读过且结论已写进 trajectory 的文件；
- `files_changed` 只列**改动或产出的文件**（不是读过的文件）；
- 拿不准的字段宁可留空，**不要编造路径**。
"""


#: 「抢救」契约：**只在总结回包解析失败时**用，最多一次。
#:
#: 为什么值得花这第二笔小钱：总结调用是一次**复用对话前缀**的付费调用（现场是
#: 734k prompt、≈100% 命中缓存）；它成功返回、只是正文不是合法 json 时，整笔投入
#: 都会丢（回退内置压缩）。而这一步的输入**只有那段原文**（几千 token），便宜三个数量级。
#:
#: 三点口径：
#: ① 顺带完成"原文是否被截断"的**判断**——由模型判，不由插件猜（也不做本地补全）；
#: ② 这一次**不发** `response_format`（站点缺省硬设 `json_object`，正好得到强制 JSON）；
#: ③ **不设 `max_tokens`**：给"修 json"设一个小上限，本身就可能是下一次截断
#:    （设 4k ⇒ 再截断 ⇒ 钱又白花），一律沿用该模型自己的输出上限。
REPAIR_INSTRUCTION = """下面是一次模型调用的**原始输出**：它本应是一个 json 对象，但解析失败了。\
请只做两件事，且只输出一个 json 对象（不要解释、不要 markdown 代码块）：

1. 判断原文是否**完整**：被截断 / 缺尾部 / 字符串断在半截 ⇒ `complete` 给 false；
   原文完整、只是夹了解释 / 有尾逗号 / 引号没转义这类纯语法问题 ⇒ `complete` 给 true；
2. 把原文修成**严格合法**的 json 放进 `summary`，结构照：
   {"background": 字符串, "trajectory": 字符串, "files_changed": 数组, "required_files": 数组}
   **只允许**使用原文里确实出现过的信息；原文没有的键给 `""` / `[]`，**绝不编造**路径或结论；
   **不要为了短而删要点**：原文写下的信息尽量原样保留（改写可以、省略不行）；
   若原文被截断，就按已有内容补齐缺的键，并在 `reason` 里写明截断位置。

输出形状（三个键都要有）：
{"complete": true, "reason": "", "summary": {"background": "", "trajectory": "", "files_changed": [], "required_files": []}}

以下是原始输出（原样，未做任何处理）：
-----
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
        # 左栏面板：默认申报（内置插件面板启用时就是这个形态）
        self.no_panel = False
        self.panel_records = DEFAULT_PANEL_RECORDS
        # 「立即压缩一次」没有上下文时（动作帧缺 agent_id）的兜底目标
        self.agent_id = ""
        # ③ 逐调用用量（`<会话目录>/usage.jsonl`）的**可选**路径：
        # 填了就把里面的压缩行并进面板（见 [_collect_records]）。留空 = 不读。
        self.usage_jsonl = ""

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
            if name == "--no-panel":
                self.no_panel = True
                index += 1
                continue
            if name == "--panel-records":
                self.panel_records = _positive_int(value, self.panel_records)
                index += 2
                continue
            if name == "--agent-id":
                self.agent_id = value
                index += 2
                continue
            if name == "--usage-jsonl":
                self.usage_jsonl = value
                index += 2
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


def _elapsed_ms(started):
    """从 `started`（time.time()）到现在的毫秒数；没给就返回 None（面板显示"—"）。"""
    if started is None:
        return None
    return int(max(0.0, time.time() - started) * 1000)


def _duration_text(value):
    """耗时的人话（面板单元格）：None = "—"。"""
    if not isinstance(value, (int, float)):
        return "—"
    if value < 1000:
        return "%d ms" % int(value)
    return "%.1f s" % (float(value) / 1000.0)


def _epoch_of(raw):
    """`usage.jsonl` 的 `at`（**ISO-8601 本机时区字符串**）→ epoch 秒；认不出返回 0。

    容忍三种写法（都来自"用户手改文件"这一既有前提）：ISO 字符串（正路）、
    epoch 秒、epoch 毫秒。核心侧 `JsonTime.encode` 写的是
    `datetime.toIso8601String()`（形如 `2026-10-03T16:31:55.000000`，无偏移 = 本机时区）。
    """
    if isinstance(raw, bool):  # bool 是 int 的子类，先挡掉
        return 0.0
    if isinstance(raw, (int, float)):
        value = float(raw)
        return value / 1000.0 if value > 100000000000 else value
    text = str(raw or "").strip()
    if not text:
        return 0.0
    if text.endswith("Z"):  # 3.10 及以前的 fromisoformat 不认 Z
        text = text[:-1] + "+00:00"
    try:
        return datetime.datetime.fromisoformat(text).timestamp()
    except ValueError:
        return 0.0


def _token_text(value):
    """token 数的人话：>= 1000 用 k（面板列窄，别铺一串数字）。"""
    value = _non_negative_int(value)
    if value >= 1000:
        return "%.1fk" % (value / 1000.0)
    return str(value)


def _usage_note(item):
    """用量行在面板"说明"列里的样子：模型 + 输入/缓存/输出（+ 估算）。

    `cached_tokens = null` **不显示成 0**（核心的口径就是"null = 端点没给这个字段"），
    `estimated = true` 必须看得见（那是本地估算，不能当计费依据）。
    """
    parts = []
    model = str(item.get("model") or "").strip()
    if model:
        parts.append(clip(model, 24))
    parts.append("输入 %s" % _token_text(item.get("prompt_tokens")))
    cached = item.get("cached_tokens")
    if isinstance(cached, int) and not isinstance(cached, bool) and cached > 0:
        parts.append("缓存 %s" % _token_text(cached))
    parts.append("输出 %s" % _token_text(item.get("completion_tokens")))
    text = "用量 " + " · ".join(parts)
    if item.get("estimated") is True:
        text += "（估算）"
    return text


def _record_from_usage_line(item, agent_id="", session_id=""):
    """把 `usage.jsonl` 的一行归一成面板记录；与压缩无关的行返回 None。

    **字段表就是契约**（核心 `store/usage_log.dart` 的 `UsageCall.toJson()`）：

        at                ISO-8601 本机时区字符串（`JsonTime.encode`）
        source            turn | compact | llm.call | plugin
        model             实际请求的模型 id
        prompt_tokens     这一跳的输入 token（端点真值优先，缺失则本地估算）
        cached_tokens     命中前缀缓存的输入 token；**null = 端点没给这个字段**
        completion_tokens 这一跳生成的 token
        estimated         数值里是否含本地估算（true = 别当计费依据）
        duration_ms       这一跳从发出请求到收流的耗时（毫秒）

    映射到面板（只认"压缩相关"的三类，见 [USAGE_SOURCE_LABELS]）：
    `compact`（内置压缩的总结）→ 来源 `builtin`；`llm.call`（压缩插件的总结调用
    走的就是它）→ `llm.call`；`plugin`（`llm.handle` 被整体接管的一跳）→ `plugin`。
    `turn`（对话自己的跳）与形状不认识的行 → None，由调用方跳过。

    **拿不到就留白、不猜**：账本里没有"覆盖条数"这一说（那是压缩的产物，不是调用的
    账），所以 `covered` 恒为 None（面板显示"—"），缺的字段一律不编造。
    """
    if not isinstance(item, dict):
        return None
    label = USAGE_SOURCE_LABELS.get(str(item.get("source") or "").strip().lower())
    if label is None:
        return None
    at = _epoch_of(item.get("at"))
    if at <= 0:
        # 连时间都读不出来的行不显示：面板按时间排序，它会沉到最底下且时间列是"—"，
        # 除了让人怀疑面板坏了没有任何价值。
        return None
    duration = item.get("duration_ms")
    return {
        "at": at,
        "source": label,
        "covered": None,
        "duration_ms": duration if isinstance(duration, (int, float)) else None,
        "note": _usage_note(item),
        "agent_id": str(agent_id or item.get("agent_id") or ""),
        "session_id": str(session_id or item.get("session_id") or ""),
        "model": str(item.get("model") or ""),
        # 这一行是"用量的账"而不是"本插件的一次压缩"（概览里的"最近原因"只看后者）
        "kind": "usage",
    }


def _usage_lines(path):
    """读一份 `usage.jsonl`（**离线回放**旁路，`--usage-jsonl`）：返回原始行对象。

    运行时那条正路是核心在压缩载荷里捎来的 `recent_usage`（插件读不到数据根，
    见 [CompactPlugin._ingest_recent_usage]）；这个入口只是开发期"把一份账本喂给
    面板看"的替代品。

    文件不存在 / 读不了 / 行坏了 ⇒ 一律跳过：那是一条**可选**数据源，它的问题不该
    让面板变空（面板的首要职责是"为什么没接管"，不是替别的模块报错）。
    """
    if not path:
        return []
    lines = []
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    lines.append(json.loads(line))
                except ValueError:
                    continue
    except (OSError, UnicodeDecodeError):
        return []
    return lines


def _view_problems(node, path="view"):
    """面板视图只能用**受限控件集**，且字段形状要对（返回可读问题列表）。

    核心侧只校验"能不能解析成节点"：字段写错（按钮没 label、表格列名与单元格数不符）
    会渲染成空控件而**不报错**，所以自检在这里把"看着像坏了"的情形也钉住。
    """
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
                    problems.append("%s 第 %d 行的单元格数与本列表不符" % (path, index + 1))
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
                    problems.append("%s 第 %d 个按钮缺 action_id / label" % (path, index + 1))
    children = node.get("children")
    if isinstance(children, list):
        for index, child in enumerate(children):
            problems.extend(_view_problems(child, "%s.children[%d]" % (path, index)))
    return problems


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
        self._counters = {"requests": 0, "taken": 0, "declined": 0,
                          "salvaged": 0, "repaired": 0}
        # ── 左栏面板的状态 ──────────────────────────────────────────────
        # 面板是**只读展示**（它不给插件任何额外权限）：记录来自 ① 插件自己经手的
        # 压缩 ② 「立即压缩一次」的核心回执 ③（可选）逐调用用量文件。
        self._ui_panel = not options.no_panel
        self._ui_lock = threading.Lock()
        self._ui_last_push = 0.0
        self._ui_slot_key = SLOT_ACTIVITY
        self._ui_status = {"subscribed": False, "detail": "等待核心握手"}
        self._identity = {"agent_id": options.agent_id, "session_id": ""}
        self._watermark = None  # (已覆盖条数, 原文总条数)：核心报的水位线
        self._records = []      # 面板记录（最新在**后**；展示时倒序）
        # **最近一次"不接管"的原因**：回包里的可选键 `reason` 就是它（见
        # [handle_station_request]）。核心会把原因写进日志与会话提示——
        # 没有它，"插件白跑一次、核心悄悄兜底"事后无从诊断。
        self._last_decline_reason = ""
        # 逐调用用量（核心捎来的 `recent_usage` / `--usage-jsonl` 回放）：
        # 按"整行内容"去重后按 **canonical 行 → 归一后的记录** 存（dict 保序）。
        self._usage_records = {}
        self._usage_file = ""   # 账本路径（排障用；插件自己读不到它）

    # ── 协议通道 ────────────────────────────────────────────────────────

    def emit(self, message):
        """写出一条报文（默认走 stdout）。自检时替换成内存收集器（见 selftest）。"""
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
                # 先申报左栏面板（`hello` 应答后 `plugin_id` 才是实例 id），
                # 再起订阅线程（订阅要重试，别拖住握手后的第一条报文）。
                self.declare_panel()
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
        """握手后订阅点位；失败就有限重试（核心可能还没把站点挂好）。

        订阅结果**如实投到面板上**：没订上就等于这个插件永远不会被叫到，
        "为什么没接管"的答案就在这一行里（最常见的是已有别的插件占着这个点位）。
        """
        last_error = ""
        self._set_status(False, "正在订阅 %s…" % STATION_RELAY_CONTEXT_COMPACT)
        for attempt in range(1, 6):
            result = self.subscribe_compact_point()
            if result.get("ok"):
                log("已订阅 %s（第 %d 次尝试）" % (STATION_RELAY_CONTEXT_COMPACT, attempt))
                self._set_status(True, "已订阅 %s" % STATION_RELAY_CONTEXT_COMPACT)
                return
            last_error = str(result.get("error") or "未知原因")
            log("订阅失败（第 %d 次）：%s" % (attempt, last_error))
            time.sleep(1.0)
        log("订阅 %s 连续失败：本插件不会接管压缩（"
            "若已有别的插件占着这个点位，先停用它）" % STATION_RELAY_CONTEXT_COMPACT)
        self._set_status(False, "未订上点位：%s（最后错误：%s）"
                         % (STATION_RELAY_CONTEXT_COMPACT, last_error))

    def handle_station_request(self, params):
        """站点 → 插件的请求。只认真实订阅的那个点位，其余一律"不改动"。"""
        station_id = str(params.get("station_id") or "")
        if station_id != STATION_RELAY_CONTEXT_COMPACT:
            return {"reply": {"payload": None}}
        payload = self.handle_compact(params)
        reply = {"payload": payload}
        # **不接管时把"为什么"一起回给核心**（回包可选键 `reason`，纯增量）：
        # 核心会把它写进日志与压缩结论（`relay_skip_reason` / 会话提示），
        # 否则一次不接管在核心侧只剩"插件回 null"这句通用文案（现场那次
        # 734k prompt 的总结失败就是这样丢掉全部诊断信息的）。
        # 老核心读不到这个键也不受影响（只当普通回包）。
        if payload is None and self._last_decline_reason:
            reply["reason"] = self._last_decline_reason
        return {"reply": reply}

    # ── 左栏面板（activity 槽位：活动栏图标 + 左栏整页） ─────────────────────

    def declare_panel(self):
        """发 `ui/manifest` 通知：声明**一条** `activity` 槽位（左栏整页）。

        `activity` 在前端是**一个槽位两处呈现**：左侧活动栏的一个图标项 + 左栏里的
        一整页内容（页内容就是这里的 `view`）。视图只能是**受限控件集**（text / list /
        table / form / progress / actions 与 row / column 容器）——没有 webview、
        不执行插件 JS，所以别指望放图表或交互式 HTML。

        声明**发一次就够**：前端断连重连时核心按缓存补发（`PluginUiCache`），
        之后的每次刷新走 `ui/update`。`--no-panel` 时整个方法什么都不做。
        """
        if not self._ui_panel:
            log("--no-panel：不申报左栏面板")
            return
        # 槽位键带实例 id：同一个脚本配成两个插件实例时互不覆盖。
        self._ui_slot_key = "%s.activity.1" % self.plugin_id
        self.notify(METHOD_UI_MANIFEST, {"slots": [{
            "slot_key": self._ui_slot_key,
            "slot": "activity",
            "title": PANEL_TITLE,
            "icon": PANEL_ICON,
            "order": 20,
            "view": self._panel_view(),
        }]})
        log("已声明左栏面板槽位 %s（activity：活动栏图标 + 左栏整页）"
            % self._ui_slot_key)

    def update_panel(self, force=False):
        """发 `ui/update`：按 slot_key **整块替换**面板视图（不做 diff）。

        节流 [PANEL_MIN_INTERVAL]：压缩可能连续触发，而前端收到 update 会重建左栏
        那一页（表单状态会重置），刷太勤只是闪。`force=True` 绕过节流（按钮回调、
        订阅结果这类"用户等着看"的刷新）。
        """
        if not self._ui_panel:
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

    def _set_status(self, subscribed, detail):
        """更新"点位订阅"这一行的状态并刷面板（订阅没订上必须看得见）。"""
        with self._ui_lock:
            # 按键更新而不是整体替换：同一时刻可能有别的提示挂在状态里（如"正在压缩…"）
            self._ui_status["subscribed"] = bool(subscribed)
            self._ui_status["detail"] = str(detail)
        self.update_panel(force=True)

    def _remember_identity(self, agent_id, session_id):
        """记住最近一次见到的会话：动作帧没带 `agent_id` 时按钮靠它找到目标。"""
        with self._ui_lock:
            if agent_id:
                self._identity["agent_id"] = str(agent_id)
            if session_id:
                self._identity["session_id"] = str(session_id)

    def _record(self, source, covered=None, duration_ms=None, note="",
                agent_id="", session_id=""):
        """追加一条面板记录（**唯一**的写入点；字段表见 [_collect_records]）。"""
        with self._ui_lock:
            self._records.append({
                "at": time.time(),
                "source": str(source or ""),
                "covered": covered if isinstance(covered, int) else None,
                "duration_ms": duration_ms,
                "note": str(note or ""),
                "agent_id": str(agent_id or ""),
                "session_id": str(session_id or ""),
                "kind": "own",
            })
            if len(self._records) > 100:  # 内部留一点余量即可
                del self._records[:-100]

    def _collect_records(self):
        """**面板的数据源（可替换点）**：返回按时间**倒序**（最新在前）的记录列表。

        每条记录的字段（缺项用 None / 空串，视图只认这 9 个键）：

            at           epoch 秒（面板只显示 HH:MM:SS）
            source       'relay'（本插件接管）/ 'builtin'（核心内置压缩）/ 'llm.call' /
                         'plugin' / '' = 未知
            covered      覆盖条数（原文条数，int 或 None）
            duration_ms  本次耗时（毫秒，int 或 None）
            note         降级 / 未接管 / 失败的可读原因；用量行的这里是 token 账
            agent_id / session_id  这一次属于哪个会话（拿不到就是空串）
            model        用量行的模型 id（本插件自己的记录没有这个信息，空串）
            kind         'own' = 本插件经手的一次压缩；'usage' = 逐调用账本的一行
                         （概览里的"最近原因"只看 'own'：账目不是原因）

        当前口径：两类记录并成一张表（都按时间倒序）——
        ① 这个插件**自己经手**的东西：中转点位的接管 / 不接管（含原因与耗时），
           以及用户点「立即压缩一次」后核心回的 `CompactionResult`（来源 / 覆盖条数 /
           降级原因 / 未压缩原因）；
        ② 核心在压缩载荷里捎来的**逐调用用量**（`recent_usage`，见
           [_ingest_recent_usage]）：内置压缩（`builtin`）、`llm.call`、
           `plugin` 接管的调用，含模型 / 输入 / 缓存 / 输出 / 耗时。

        ⚠ "拿不到就留白"仍是硬口径：没有 `recent_usage`（核心没接线 / 账本还不存在）
        时这里就只有①，来源列不会凭空多出 `builtin`；账本里没有"覆盖条数"，
        用量行的那一列就是"—"（那是压缩的产物，不是调用的账）。
        字段表变动只需要改 [_record_from_usage_line] 一处。
        """
        # 离线回放旁路（`--usage-jsonl`）：读一份账本文件喂进来。同一条行会被去重，
        # 所以这里重复读是幂等的（只在没有核心捎数据时才有意义）。
        if self.options.usage_jsonl:
            self._ingest_recent_usage(_usage_lines(self.options.usage_jsonl))
        with self._ui_lock:
            records = list(self._records)
            records.extend(self._usage_records.values())
        records.sort(key=lambda item: item.get("at") or 0, reverse=True)
        return records

    def _ingest_recent_usage(self, lines, path="", agent_id="", session_id=""):
        """把核心捎来的"最近用量行"并进面板数据源；返回本次新增的条数。

        为什么必须**去重**：`recent_usage` 是个**滚动窗口**——每次压缩请求核心都带
        最近 N 行，同一行会被反复送来。不去重的话，面板几轮之后就被同一批记录刷屏。
        去重键 = 整行内容的 canonical JSON（同一行 → 同一个键；手改过的一行自然算新行）。
        """
        if not isinstance(lines, list):
            return 0
        added = 0
        with self._ui_lock:
            if path:
                self._usage_file = str(path)
            for line in lines:
                if not isinstance(line, dict):
                    continue
                key = json.dumps(line, sort_keys=True, ensure_ascii=False)
                if key in self._usage_records:
                    continue
                record = _record_from_usage_line(line, agent_id, session_id)
                if record is None:  # `turn` 行 / 形状不认识：不是本面板的事
                    continue
                self._usage_records[key] = record
                added += 1
            if len(self._usage_records) > MAX_USAGE_RECORDS:
                for key in list(self._usage_records)[:len(self._usage_records)
                                                    - MAX_USAGE_RECORDS]:
                    del self._usage_records[key]
        return added

    def _panel_view(self):
        """左栏面板视图（受限控件集）：概览 + 水位 + 最近 N 次表格 + 动作按钮。"""
        records = self._collect_records()
        limit = max(1, self.options.panel_records)
        shown = records[:limit]
        with self._ui_lock:
            status = dict(self._ui_status)
            identity = dict(self._identity)
            counters = dict(self._counters)
            watermark = self._watermark
            usage_count = len(self._usage_records)
        children = [
            {"type": "text", "text": PANEL_TITLE, "style": "title"},
            {"type": "text",
             "text": self._panel_summary(status, identity, counters, records,
                                         usage_count),
             "style": "caption"},
        ]
        if watermark is not None:
            covered, total = watermark
            value = (float(covered) / float(total)) if total > 0 else 0.0
            children.append({
                "type": "progress",
                "value": min(1.0, max(0.0, value)),
                "label": "已覆盖原文条数（核心报的水位线）",
                "detail": "%d / %d" % (covered, total),
            })
        if not shown:
            children.append({
                "type": "text",
                "text": "还没有压缩记录：点下面「立即压缩一次」，或者等上下文到阈值时"
                        "自动压一次（核心内置兜底的那几次也会记在下面，来源显示 "
                        "`builtin`）。",
                "style": "body",
            })
        # 表格**一直渲染**（没记录时给一行占位）：列名先亮出来，用户一眼知道这里会
        # 记什么；空表格配一句指引，比整块消失更不像"插件坏了"。
        children.append({
            "type": "table",
            "columns": PANEL_COLUMNS,
            "rows": [self._panel_row(record) for record in shown] or [
                ["—", "—", "—", "—", "（还没有压缩记录）"],
            ],
            "caption": "最近 %d 次（最新在最上面；来源未知 = 本插件没经手；"
                       "带「用量」的行来自核心捎来的 usage.jsonl）" % len(shown),
        })
        children.append({
            "type": "actions",
            "buttons": [
                {"action_id": "compact_now", "label": "立即压缩一次", "style": "primary"},
                {"action_id": "refresh", "label": "刷新"},
            ],
        })
        return {"type": "column", "gap": 6, "children": children}

    def _panel_summary(self, status, identity, counters, records, usage_count=0):
        """面板头部那行概览：订阅状态 + 经手统计 + 用量条数 + 最近一次没接管的原因。"""
        parts = ["点位订阅：%s" % (status.get("detail") or "未知")]
        parts.append("经手 %d 次（接管 %d / 未接管 %d）"
                     % (counters.get("requests", 0), counters.get("taken", 0),
                        counters.get("declined", 0)))
        if usage_count:
            parts.append("用量记录 %d 条" % usage_count)
        agent_id = identity.get("agent_id") or ""
        session_id = identity.get("session_id") or ""
        if agent_id or session_id:
            parts.append("最近会话：%s%s" % (agent_id or "(无 agent)",
                                            ("/" + session_id) if session_id else ""))
        else:
            parts.append("最近会话：未知（等一次压缩 / 工具事件）")
        for record in records:
            # 只要"本插件这一次为什么没成"（用量行的说明不是原因：里面是 token 账）
            if record.get("kind") != "usage" and record.get("note"):
                parts.append("最近原因：%s" % clip(record["note"], 160))
                break
        manual = status.get("manual")
        if manual:
            parts.append(manual)
        return " · ".join(parts)

    @staticmethod
    def _panel_row(record):
        """一条记录 → 表格的一行（单元格只放标量文本，表格渲染器只认标量）。"""
        at = record.get("at") or 0
        # 时间读不出来的行不会进面板（见 [_record_from_usage_line]），这里只兜一手
        when = time.strftime("%H:%M:%S", time.localtime(at)) if at > 0 else "—"
        covered = record.get("covered")
        return [
            when,
            SOURCE_LABELS.get(record.get("source") or "",
                              record.get("source") or "未知"),
            "—" if covered is None else str(covered),
            _duration_text(record.get("duration_ms")),
            record.get("note") or "—",
        ]

    # ── 面板交互（前端按钮 → 核心 → 插件） ─────────────────────────────────

    def on_ui_action(self, params):
        """面板交互回调（核心 → 插件）。

        **判据在 `params.event` 上**：核心把它包成
        `{"method":"event","params":{"event":"plugin_ui_action", slot_key, action_id,
        payload}}`（与 `agent.tool_call` 同一范式）。老核心 / 直连测试发裸
        `method == "plugin_ui_action"` 的形态，[on_notification] 两种都收。
        """
        action_id = str(params.get("action_id") or "")
        slot_key = str(params.get("slot_key") or "")
        log("面板交互：slot=%s action=%s" % (slot_key, action_id))
        if action_id == "compact_now":
            self.start_manual_compact(params)
            return
        if action_id == "refresh":
            self.update_panel(force=True)
            return
        # 未知 action：显式记下来（不静默），但不算错误
        log("未知的面板动作（忽略）：%s" % action_id)

    def start_manual_compact(self, params):
        """「立即压缩一次」：**不在读循环里等回包**（回包也从同一条 stdin 进来）。

        动作帧自带 `agent_id` / `session_id`（前端按当前上下文填的），优先用它；没有就
        用站点请求 / 事件里学到的"最近一次见到的"；再没有就如实写进面板（不猜目标）。
        """
        payload = params.get("payload")
        payload = payload if isinstance(payload, dict) else {}
        agent_id = str(params.get("agent_id") or payload.get("agent_id") or "").strip()
        session_id = str(
            params.get("session_id") or payload.get("session_id") or "").strip()
        self._remember_identity(agent_id, session_id)
        with self._ui_lock:
            agent_id = agent_id or self._identity.get("agent_id") or ""
            session_id = session_id or self._identity.get("session_id") or ""
        if not agent_id:
            self._record("", note="立即压缩未发出：不知道目标 agent（先让它发生一次"
                                  "压缩 / 工具调用，或用 --agent-id 指定）")
            self.update_panel(force=True)
            return
        with self._ui_lock:
            self._ui_status["manual"] = "正在压缩…"
        self.update_panel(force=True)
        threading.Thread(target=self._do_compact_now, args=(agent_id, session_id),
                         name="compact-now", daemon=True).start()

    def _do_compact_now(self, agent_id, session_id):
        """（worker 线程）经执行站 `agent.compact` 手动压一次，并把回执记进面板。

        核心侧这条命令与 REST `/compact` 是**同一个入口**：它会拒绝"正在生成"的
        agent（压缩改写上下文，与生成并发读写不安全），所以失败信息要原样留痕。
        """
        started = time.time()
        identity = {"agent_id": agent_id, "session_id": session_id}
        result = self.command(CMD_AGENT_COMPACT, dict(identity), scope=identity)
        duration_ms = _elapsed_ms(started)
        if not result.get("ok"):
            note = "立即压缩失败：%s" % (result.get("error") or "未知原因")
            log("agent.compact 失败：%s" % note)
            self._record("", duration_ms=duration_ms, note=note,
                         agent_id=agent_id, session_id=session_id)
            self._finish_manual(agent_id, session_id)
            return
        payload = result.get("payload")
        payload = payload if isinstance(payload, dict) else {}
        record_source = str(payload.get("source") or "").strip().lower()
        covered = payload.get("summarized_messages")
        note = ""
        if payload.get("compressed") is not True:
            note = "未压缩：%s" % (payload.get("reason") or "未知原因")
        elif payload.get("degraded"):
            note = "降级：%s" % (payload.get("degraded_reason") or "总结失败")
        elif payload.get("relay_skip_reason"):
            # ② 落地后的可选键：中转站没接管的可读原因（没有它就只剩"降级/成功"两种观感）
            note = "中转未接管：%s" % payload.get("relay_skip_reason")
        log("手动压缩：compressed=%s source=%s 覆盖=%s 耗时=%s note=%s"
            % (payload.get("compressed"), record_source or "(未知)", covered,
               _duration_text(duration_ms), note or "-"))
        self._record(record_source, covered=covered if isinstance(covered, int) else None,
                     duration_ms=duration_ms, note=note,
                     agent_id=agent_id, session_id=session_id)
        self._finish_manual(agent_id, session_id)

    def _finish_manual(self, agent_id, session_id):
        """手动压缩收尾：清掉"正在压缩…"并把结果推到面板上。"""
        with self._ui_lock:
            self._ui_status.pop("manual", None)
        self._remember_identity(agent_id, session_id)
        self.update_panel(force=True)

    # ── 压缩主体 ────────────────────────────────────────────────────────

    def handle_compact(self, params):
        """中转站压缩：返回回包 payload（dict）或 None（不接管）。"""
        started = time.time()
        self._counters["requests"] += 1
        # 每次请求都先把"上次为什么不接管"清掉：回给核心的 reason 必须属于**这一次**
        self._last_decline_reason = ""
        payload = params.get("payload")
        if not isinstance(payload, dict):
            log("压缩请求缺少 payload 对象：不接管")
            return self._decline("请求缺少 payload 对象", started)
        scope = params.get("scope")
        scope = scope if isinstance(scope, dict) else {}
        agent_id = str(payload.get("agent_id") or scope.get("agent_id") or "")
        session_id = str(payload.get("session_id") or scope.get("session_id") or "")
        identity = {"agent_id": agent_id, "session_id": session_id}
        # 记住"最近一次见到的会话"：面板上的「立即压缩一次」按钮靠它找到目标 agent
        self._remember_identity(agent_id, session_id)
        # **逐调用用量**：核心在载荷里捎来最近 N 行（插件读不到数据根）。放在这里
        # （早于下面每一处"不接管"）——不接管时面板也要能看到"这次为什么没压"和
        # "最近的调用都花了多少"。喂不进来（键不存在）就什么都不发生。
        added_usage = self._ingest_recent_usage(
            payload.get("recent_usage"),
            path=str(payload.get("usage_file") or ""),
            agent_id=agent_id,
            session_id=session_id,
        )
        if added_usage:
            log("已并入 %d 条用量记录（账本：%s）"
                % (added_usage, self._usage_file or "未提供路径"))
        system_prompt = str(payload.get("system_prompt") or "")
        total = _non_negative_int(payload.get("total_message_count"))
        frozen = _non_negative_int(payload.get("compacted_message_count"))
        if total > 0:
            # 核心报的水位线（原文总条数 / 之前已覆盖条数）：面板拿它画进度
            self._watermark = (frozen, total)

        # 原料：引擎这一轮真会发的那份请求（没有它就不接管——不同口径的前缀没有意义）
        request = payload.get("request")
        if not isinstance(request, dict):
            log("载荷没有 request（引擎口径的线形请求）：不接管")
            return self._decline("载荷没有 request（引擎口径的线形请求）",
                                 started, agent_id, session_id)
        wire = request.get("messages")
        if not isinstance(wire, list) or not wire:
            log("request.messages 不是非空数组：不接管")
            return self._decline("request.messages 不是非空数组",
                                 started, agent_id, session_id)
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
            return self._decline("没有可压的内容（整段都要保留）",
                                 started, agent_id, session_id)

        # 总结调用：**前缀 = request.messages[:cut]**（与对话逐字一致 ⇒ 命中缓存），
        # 末尾只追加一条 user 指令；tools 原样透传（前缀对齐的另一半）。
        # 注意：**不用** llm.call 的 system 参数（那会在最前面插 system 消息，整体错位）；
        # **必须** response_format="text"（缺省是站点硬设的 json_object，端点会为它
        # 改写提示词 ⇒ 前缀整段丢缓存，真机对照见模块 docstring 的"缓存"段）。
        call_messages = list(wire[:cut])
        call_messages.append({
            "role": "user",
            "content": SUMMARY_INSTRUCTION % {"max_files": self.options.max_files},
        })
        arguments = {
            "messages": call_messages,
            "agent_id": agent_id,
            "session_id": session_id,
            # **必须 text**：缺省是站点硬设的 `json_object`，端点会为它改写提示词
            # ⇒ 上面辛苦对齐的前缀整段丢缓存（真机对照见模块 docstring 的"缓存"段）。
            "response_format": "text",
        }
        if tools:
            arguments["tools"] = tools
        summary_result = self.command("llm.call", arguments, scope=identity)
        # **钱别白花**：这次调用可能已经跑完并付过费（现场：734k prompt、≈100% 命中
        # 缓存、19.5s），只是正文不是合法 json。走"读 → 本地修复 → 一次判断+修 json"
        # 三段抢救；三段都不行才不接管（并把原因说清楚）。
        parsed, raw_text, origin = self.recover_summary(
            summary_result, identity, agent_id, session_id)
        if parsed is None:
            detail = str(summary_result.get("error") or "").strip()
            where = ("总结调用 llm.call 失败：%s" % (detail or "未知原因")
                     if origin == "llm_call_failed" else "总结回包抢救失败：%s" % origin)
            log("总结回包不可用（%s）：不接管" % where)
            return self._decline(
                "%s；原文 %d 字，前 120 字：%s"
                % (where, len(raw_text), clip(raw_text, 120)),
                started, agent_id, session_id, code=origin.split(":")[0])
        result_payload = self._result_payload(summary_result)
        usage = result_payload.get("usage") or {}
        log("摘要完成：模型=%s 前缀 %d 条 prompt_tokens=%s cached_tokens=%s 来源=%s"
            % (result_payload.get("model"), cut, usage.get("prompt_tokens"),
               usage.get("cached_tokens"), origin))
        if origin != "primary":
            # 抢救回来的摘要**必须显式标注**（它可能不完整）——把标记留在 dict 上，
            # 由 [summary_text] 写进上下文正文，模型与用户都看得见。
            parsed = dict(parsed)
            parsed["_recovered_from"] = origin

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
            return self._decline("--dry-run：拼好了但按不接管返回",
                                 started, agent_id, session_id)
        covered = total if total > 0 else frozen
        # 面板记录：**接管成功**也要留痕（来源 relay + 覆盖条数 + 耗时），
        # 否则"压了几次、每次多大"就只能靠翻服务端账单猜——那正是这次要修的。
        self._record("relay", covered=covered, duration_ms=_elapsed_ms(started),
                     agent_id=agent_id, session_id=session_id)
        self.update_panel()
        return {
            "messages": out_messages,
            # 尾部已抄进列表 ⇒ 原文全部覆盖（上界就是 total_message_count）
            "covered_message_count": covered,
        }

    def _decline(self, reason="", started=None, agent_id="", session_id="",
                 code=""):
        """不接管：计数 + 记一条面板记录 + 给核心留一份原因。

        **原因必须可见**：用户真正踩到的坑几乎都是"插件白跑一次、核心悄悄兜底了"，
        而"为什么没接管"以前在类型上就丢了（回一个 null 就没了）。现在它有三处落点：
        ① 面板记录；② stderr 日志；③ **回包可选键 `reason`**（[handle_station_request]
        把它交给核心 ⇒ 核心日志 / `relay_skip_reason` / 会话提示）。

        [code] = 机读的原因分类（`llm_call_failed` / `repair_failed` / `payload_missing`
        / `nothing_to_compact` …），写进面板与回包原因的前缀，便于统计与检索。
        """
        self._counters["declined"] += 1
        text = reason or "未知原因"
        self._last_decline_reason = ("[%s] %s" % (code, text)) if code else text
        self._record("", duration_ms=_elapsed_ms(started),
                     note="未接管：%s" % self._last_decline_reason,
                     agent_id=agent_id, session_id=session_id)
        self.update_panel()
        return None

    # ── 总结回包：读取 / 抢救（"钱别白花"） ─────────────────────────────

    @staticmethod
    def _result_payload(result):
        """从一次站点命令回包里取出 `payload`（dict）；没有就给空 dict。"""
        payload = result.get("payload") if isinstance(result, dict) else None
        return payload if isinstance(payload, dict) else {}

    @staticmethod
    def salvage_json(text):
        """**免费**的本地修复：只清结构噪声，**不猜内容、不补字段**。

        能救回的典型：模型把 json 包进 ``` 代码块 / 前后带一句解释 / 尾逗号 /
        零宽字符 / BOM。救不回也不硬救——**是不是被截断、要不要补全，交给一次显式的
        小调用去判断**（见 [REPAIR_INSTRUCTION]），插件自己不猜（用户口径）。
        """
        raw = text if isinstance(text, str) else ""
        if not raw.strip():
            return None
        cleaned = raw.replace("\ufeff", "").replace("\u200b", "")
        candidates = []
        start, end = cleaned.find("{"), cleaned.rfind("}")
        if start >= 0 and end > start:
            candidates.append(cleaned[start:end + 1])
        candidates.append(cleaned)
        for candidate in candidates:
            variants = (candidate, re.sub(r",\s*([}\]])", r"\1", candidate))
            for variant in variants:
                try:
                    value = json.loads(variant)
                except (ValueError, TypeError):
                    continue
                if isinstance(value, dict):
                    return value
        return None

    def repair_json(self, text, identity, agent_id, session_id):
        """**花小钱**的一次"判断完整性 + 修 json"调用（最多一次）。

        返回 `(summary | None, 失败原因)`。要点：
        - 输入**只有那段原文**（几千 token），与主调用那几十万 token 的前缀无关；
        - **不发** `response_format`（站点缺省硬设 `json_object`，正好强制 JSON）；
        - **不带** `tools`（这里没有前缀需要对齐）；
        - **不设 `max_tokens`**：设小了就是下一次截断、钱又白花（用户明确要求）。
        """
        arguments = {
            "messages": [{"role": "user",
                          "content": REPAIR_INSTRUCTION + str(text)}],
            "agent_id": agent_id,
            "session_id": session_id,
        }
        result = self.command("llm.call", arguments, scope=identity)
        payload = self._result_payload(result)
        if not result.get("ok") and not payload:
            return None, "修复调用失败：%s" % (result.get("error") or "未知原因")
        parsed = payload.get("json")
        if not isinstance(parsed, dict):
            return None, "修复调用也没回 json 对象"
        summary = parsed.get("summary")
        if not isinstance(summary, dict):
            return None, "修复结果里没有 summary 对象"
        complete = parsed.get("complete")
        if complete is False or str(complete).strip().lower() == "false":
            summary = dict(summary)
            summary["_incomplete_reason"] = str(
                parsed.get("reason") or "模型判定原文不完整")
        return summary, ""

    def recover_summary(self, result, identity, agent_id, session_id):
        """把一次"总结调用"的回包变成可用摘要：`(parsed | None, 原文, 来源)`。

        三段，**总计最多一次额外调用**（用户 2026-10-05 定案）：
        1. `primary` —— 回包本来就是合法 json（happy path，零额外成本）；
        2. `salvage` —— 免费本地修复（去代码块 / 夹话 / 尾逗号 / 零宽字符）；
        3. `repair` —— 一次小的"判断完整性 + 修 json"调用；
        都不行 ⇒ `None` + 来源串（`llm_call_failed` / `repair_failed: …`），
        供上层把原因写清楚——**不是只回一句"失败"**。
        """
        payload = self._result_payload(result)
        raw = str(payload.get("text") or "")
        parsed = payload.get("json")
        if isinstance(parsed, dict):
            return parsed, raw, "primary"
        if not result.get("ok") and not raw:
            return None, "", "llm_call_failed"
        truncated = bool(payload.get("truncated_suspect"))
        log("总结回包不是合法 json（error_kind=%s 正文 %d 字%s）：开始抢救"
            % (payload.get("error_kind") or "-", len(raw),
               "，疑似被截断" if truncated else ""))
        salvaged = self.salvage_json(raw)
        if isinstance(salvaged, dict):
            self._counters["salvaged"] += 1
            log("本地修复成功（未额外调用模型）")
            return salvaged, raw, "salvage"
        repaired, why = self.repair_json(raw, identity, agent_id, session_id)
        if isinstance(repaired, dict):
            self._counters["repaired"] += 1
            log("修复调用成功（原文%s）"
                % ("疑似被截断，已在摘要里标注" if truncated else "疑似纯语法问题"))
            return repaired, raw, "repair"
        return None, raw, ("repair_failed:%s" % why if why else "repair_failed")

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
        lines = []
        # **抢救回来的摘要必须显式标注**（见 [CompactPlugin.recover_summary]）：
        # 花钱救回来的是"可能不完整"的摘要，绝不能让下一轮的自己以为它是完整的。
        recovered = str(parsed.get("_recovered_from") or "")
        if recovered:
            how = ("由一次 JSON 修复调用补全" if recovered == "repair"
                   else "由本地结构修复得到")
            note = "> ⚠️ 本摘要%s，**可能不完整**" % how
            incomplete = str(parsed.get("_incomplete_reason") or "").strip()
            if incomplete:
                note += "：模型判定原文被截断（%s）" % incomplete
            lines.extend([note, ""])
        lines.extend([
            "## 背景",
            background or "（无）",
            "",
            "## 轨迹",
            trajectory or "（无）",
            "",
            "## 改动与产出文件",
        ])
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
        if method == "event":
            # **核心把面板动作也包成 `event` 通知**：判据在 `params.event` 上
            # （见 [EVENT_UI_ACTION]）。别的 agent 事件只用来学"最近见到的会话"。
            event = str(params.get("event") or "")
            if event == EVENT_UI_ACTION:
                self.on_ui_action(params)
                return
            self._remember_identity(params.get("agent_id"), params.get("session_id"))
            return
        if method == EVENT_UI_ACTION:
            # 裸 `method == "plugin_ui_action"` 形态（老核心 / 直连测试）：
            # 兼容收下——否则老核心配新插件时按钮依然是"点了没反应"。
            self.on_ui_action(params)
            return
        # station/cancel（我们没接流式）与其它通知：忽略即可

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


def _fixture_command(summary_json, fail_commands=(), compact_result=None,
                     llm_seq=None):
    """假命令通道：记录调用，按命令返回与核心同形状的结果。

    [llm_seq] = 只作用于 `llm.call` 的**逐次回包脚本**（list；元素 `None` = 用默认的
    成功回包）——自愈用例靠它构造"第一次坏、第二次好"这种序列。
    """
    calls = []
    queue = list(llm_seq) if llm_seq else []

    class _Fake(object):
        def __call__(self, command, arguments, scope=None):
            calls.append({"command": command, "arguments": arguments,
                          "scope": scope})
            if command in fail_commands:
                return {"ok": False, "error": "%s 被用例置为失败" % command}
            if command == "llm.call":
                scripted = queue.pop(0) if queue else None
                if scripted is not None:
                    return scripted
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
            if command == "agent.compact":
                # 核心 `_stationCompact` 的回执形状 = CompactionResult.toJson()
                # （+ agent_id / session_id），见 core_server.dart
                payload = compact_result if compact_result is not None else {
                    "success": True, "compressed": True, "context_size": 9,
                    "summarized_messages": 6, "source": "builtin",
                    "session_id": "ses_1",
                }
                return {"ok": True, "command": command, "payload": payload}
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


def _plugin(summary=None, fail_commands=(), compact_result=None, options=None,
            llm_seq=None):
    """造一个走假命令通道的插件，并把**发出的报文收进内存**（`plugin.sent`）。

    自检不该往 stdout 写协议帧（那是给真核心的通道，混进自检报告里只会碍眼）——
    面板相关的用例因此都读 `plugin.sent`，而不是去劫持全局 `send`。
    """
    plugin = CompactPlugin(options or Options())
    fake, calls = _fixture_command(summary or _summary_fixture(), fail_commands,
                                   compact_result, llm_seq)
    plugin.command = fake
    plugin.sent = []
    plugin.emit = plugin.sent.append
    return plugin, calls


def _notifications(sent, method):
    """从收集到的报文里挑出某个 method 的通知。"""
    return [message for message in sent if message.get("method") == method]


def _last_view(sent, method):
    """最后一个某 method 通知的 params.view（没有就是空 dict）。"""
    hits = _notifications(sent, method)
    if not hits:
        return {}
    params = hits[-1].get("params")
    view = params.get("view") if isinstance(params, dict) else None
    return view if isinstance(view, dict) else {}


def _declared_slot(sent):
    """最后一条 `ui/manifest` 声明里的第一个槽位（没有就是空 dict）。"""
    hits = _notifications(sent, "ui/manifest")
    if not hits:
        return {}
    params = hits[-1].get("params")
    slots = params.get("slots") if isinstance(params, dict) else None
    if isinstance(slots, list) and slots and isinstance(slots[0], dict):
        return slots[0]
    return {}


def _usage_fixture():
    """`usage.jsonl` 的样本行（**字段表 = 核心 `UsageCall.toJson()`**，逐个用它们）。

    四行覆盖三种要显示的来源 + 一种**必须被跳过**的（`turn` = 对话自己的跳），
    外加三类边界：`cached_tokens = null`（端点没给）、`estimated = true`（本地估算）、
    以及"耗时超过 1 秒"（面板要显示成人话的秒）。
    """
    return [
        # 内置压缩的一次总结：面板来源列要显示 builtin
        {"at": "2026-10-03T16:31:55.000000", "source": "compact",
         "model": "demo-model", "prompt_tokens": 1200, "cached_tokens": 900,
         "completion_tokens": 120, "estimated": False, "duration_ms": 1800},
        # 执行站 llm.call（压缩插件的总结调用走这条）：端点没给 cached_tokens + 估算值
        {"at": "2026-10-03T16:38:02.500000", "source": "llm.call",
         "model": "demo-model", "prompt_tokens": 800, "cached_tokens": None,
         "completion_tokens": 60, "estimated": True, "duration_ms": 700},
        # llm.handle 被插件整体接管的一跳
        {"at": "2026-10-03T16:39:10.000000", "source": "plugin",
         "model": "demo-model", "prompt_tokens": 300, "cached_tokens": 0,
         "completion_tokens": 30, "estimated": False, "duration_ms": 260},
        # 对话自己的跳：**不属于压缩面板**，必须被跳过
        {"at": "2026-10-03T16:40:00.000000", "source": "turn",
         "model": "demo-model", "prompt_tokens": 10, "cached_tokens": None,
         "completion_tokens": 5, "estimated": False, "duration_ms": 90},
    ]


def _panel_table(view):
    """从面板视图里取出那张表格节点（没有就是空 dict）。"""
    for child in (view or {}).get("children") or []:
        if isinstance(child, dict) and child.get("type") == "table":
            return child
    return {}


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
        if llm_calls[0]["arguments"].get("response_format") != "text":
            failures.append("总结调用必须显式 response_format=text"
                            "（json_object 会让端点改写提示词、前缀缓存整段丢）")
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

    # ⑩ 左栏面板声明：`ui/manifest` 只发一次、只有一条 **activity** 槽位
    #    （activity = 活动栏图标 + 左栏整页），视图只能用受限控件集
    panel_plugin, _ = _plugin()
    panel_plugin.declare_panel()
    manifests = _notifications(panel_plugin.sent, "ui/manifest")
    if len(manifests) != 1:
        failures.append("ui/manifest 应恰好发 1 次，实际 %d" % len(manifests))
    else:
        params = manifests[0].get("params") or {}
        slots = params.get("slots")
        if not isinstance(slots, list) or len(slots) != 1:
            failures.append("ui/manifest 应声明 1 条槽位，实际 %r" % (slots,))
        else:
            slot = slots[0]
            if slot.get("slot") != "activity":
                failures.append("槽位类型应是 activity（左栏整页），实际 %r"
                                % slot.get("slot"))
            if slot.get("slot_key") != SLOT_ACTIVITY:
                failures.append("slot_key 不对：%r" % slot.get("slot_key"))
            if not slot.get("title") or not slot.get("icon"):
                failures.append("槽位缺 title / icon：%r" % slot)
            view = slot.get("view")
            problems = _view_problems(view)
            if problems:
                failures.append("面板声明视图不合法：%s" % problems)
            rendered = json.dumps(view, ensure_ascii=False)
            if '"compact_now"' not in rendered:
                failures.append("面板缺「立即压缩一次」按钮（action_id=compact_now）")
            size = len(json.dumps(slot, ensure_ascii=False).encode("utf-8"))
            if size > 64 * 1024:
                failures.append("面板声明 %d 字节，超过核心 64 KB 上限（会被整帧拒）"
                                % size)
    if panel_plugin._collect_records():
        failures.append("刚起来的插件不该有压缩记录：%r"
                        % (panel_plugin._collect_records()[:1],))
    # 空态也要说清"接下来怎么办"（否则用户对着空表格只会以为插件坏了）
    empty_view = _declared_slot(panel_plugin.sent).get("view")
    if "还没有压缩记录" not in json.dumps(empty_view, ensure_ascii=False):
        failures.append("面板空态缺一句可操作的话（点按钮 / 等自动压缩）")

    # ⑩b `--no-panel`：一帧 UI 都不发（只想后台跑压缩时用）
    silent_options = Options()
    silent_options.no_panel = True
    silent_plugin, _ = _plugin(options=silent_options)
    silent_plugin.declare_panel()
    silent_plugin.update_panel(force=True)
    if silent_plugin.sent:
        failures.append("--no-panel 时不该发任何 UI 帧：%r" % (silent_plugin.sent[:1],))

    # ⑪ 压缩之后面板要如实刷新（来源 / 覆盖条数 / 耗时都要出现在表里）
    taken_panel, _ = _plugin()
    taken_panel.handle_station_request(_params(wire))  # 走真编排（假命令通道）
    updates = _notifications(taken_panel.sent, "ui/update")
    if not updates:
        failures.append("接管一次压缩后应发一帧 ui/update 刷新面板")
    else:
        params = updates[-1].get("params") or {}
        if params.get("slot_key") != SLOT_ACTIVITY:
            failures.append("ui/update 的 slot_key 不对：%r" % params.get("slot_key"))
        view = params.get("view") or {}
        problems = _view_problems(view)
        if problems:
            failures.append("刷新后的面板视图不合法：%s" % problems)
        rendered = json.dumps(view, ensure_ascii=False)
        for must in ["relay", '"12"', "ms"]:
            if must not in rendered:
                failures.append("面板表里看不到 %r：%s" % (must, rendered[:300]))

    # ⑪b **不接管也要留痕**：面板的重点是"为什么没接管"（用户踩到的正是这个）
    decline_panel, _ = _plugin()
    without_request = _params(wire)
    without_request["payload"].pop("request")
    decline_panel.handle_station_request(without_request)
    decline_records = decline_panel._collect_records()
    if not decline_records or "未接管" not in str(decline_records[0].get("note") or ""):
        failures.append("不接管必须记进面板（note 里要能看到原因）：%r"
                        % (decline_records[:1],))
    if _view_problems(_last_view(decline_panel.sent, "ui/update")):
        failures.append("不接管后的面板视图不合法")

    # ⑫ 面板动作回传：核心发的是 **event 通知**（判据在 params.event 上），
    #    同时兼容裸 method 形态（老核心 / 直连测试）
    action_plugin, _ = _plugin()
    action_plugin.on_notification("event", {
        "event": EVENT_UI_ACTION,
        "slot_key": SLOT_ACTIVITY,
        "action_id": "refresh",
        "agent_id": "agt_1",
        "session_id": "ses_1",
        "payload": {},
    })
    if not _notifications(action_plugin.sent, "ui/update"):
        failures.append("event 形态的面板动作没被处理（判据必须看 params.event）")
    legacy_plugin, _ = _plugin()
    legacy_plugin.on_notification(EVENT_UI_ACTION, {"action_id": "refresh"})
    if not _notifications(legacy_plugin.sent, "ui/update"):
        failures.append("裸 method=plugin_ui_action 形态没兼容（老核心点按钮会没反应）")
    noise_plugin, _ = _plugin()
    noise_plugin.on_notification("event", {
        "event": "agent.tool_call", "agent_id": "agt_9", "session_id": "ses_9",
    })
    if noise_plugin.sent:
        failures.append("非 UI 事件不该触发面板帧：%r" % (noise_plugin.sent[:1],))
    if noise_plugin._collect_records():
        failures.append("非 UI 事件不该产生面板记录")
    if noise_plugin._identity.get("agent_id") != "agt_9":
        failures.append("agent 事件应当被用来学习「最近见到的会话」")

    # ⑬ 「立即压缩一次」：经执行站 `agent.compact`，回执要落进面板
    manual_plugin, manual_calls = _plugin()
    manual_plugin._do_compact_now("agt_1", "ses_1")
    compact_calls = [c for c in manual_calls if c["command"] == CMD_AGENT_COMPACT]
    if len(compact_calls) != 1:
        failures.append("agent.compact 应恰好调 1 次，实际 %d" % len(compact_calls))
    elif compact_calls[0]["arguments"].get("agent_id") != "agt_1" \
            or compact_calls[0]["scope"].get("session_id") != "ses_1":
        failures.append("agent.compact 没带身份：%r" % (compact_calls[0],))
    manual_records = manual_plugin._collect_records()
    if not manual_records or manual_records[0].get("source") != "builtin" \
            or manual_records[0].get("covered") != 6:
        failures.append("手动压缩的回执没记进面板：%r" % (manual_records[:1],))
    if "builtin" not in json.dumps(_last_view(manual_plugin.sent, "ui/update"),
                                   ensure_ascii=False):
        failures.append("手动压缩后面板没刷新出 builtin 来源")

    # ⑬b 降级 / 未压缩 / 中转未接管 / 命令失败：四种"不顺利"都必须在面板上有原因
    for label, kwargs, must in [
        ("降级", {"compact_result": {
            "success": True, "compressed": True, "degraded": True,
            "degraded_reason": "端点 429：限流", "summarized_messages": 30,
            "source": "builtin"}}, "限流"),
        ("未压缩", {"compact_result": {
            "success": True, "compressed": False, "reason": "too_few_messages"}},
         "too_few_messages"),
        ("中转未接管（② 的可选键）", {"compact_result": {
            "success": True, "compressed": True, "source": "builtin",
            "summarized_messages": 8,
            "relay_skip_reason": "中转站没订上 compact 点位"}}, "没订上"),
        ("命令失败", {"fail_commands": ("agent.compact",)}, "失败"),
    ]:
        probe_plugin, _ = _plugin(**kwargs)
        probe_plugin._do_compact_now("agt_1", "ses_1")
        records = probe_plugin._collect_records()
        if not records or must not in str(records[0].get("note") or ""):
            failures.append("%s 的原因没出现在面板记录里（%r 不在 %r）"
                            % (label, must, records[:1]))

    # ⑬c 按钮走"没有 agent 就不猜"的路径：如实写进面板，不静默
    blind_plugin, blind_calls = _plugin()
    blind_plugin.on_notification("event", {
        "event": EVENT_UI_ACTION, "action_id": "compact_now", "payload": {},
    })
    if [c for c in blind_calls if c["command"] == CMD_AGENT_COMPACT]:
        failures.append("没有 agent 时不该猜一个目标去压缩")
    blind_records = blind_plugin._collect_records()
    if not blind_records or "不知道目标 agent" not in str(
            blind_records[0].get("note") or ""):
        failures.append("没有 agent 时必须如实写进面板：%r" % (blind_records[:1],))
    # 但动作帧带了身份时（前端按当前上下文填的）就该照做——这里用线程外的同步路径验
    identified_plugin, identified_calls = _plugin()
    identified_plugin.start_manual_compact({
        "agent_id": "agt_7", "session_id": "ses_7", "payload": {},
    })
    deadline = time.time() + 5.0
    while time.time() < deadline and not [
            c for c in identified_calls if c["command"] == CMD_AGENT_COMPACT]:
        time.sleep(0.02)
    if not [c for c in identified_calls if c["command"] == CMD_AGENT_COMPACT]:
        failures.append("动作帧带身份时「立即压缩一次」应真的发出命令")

    # ⑭ **核心捎来的用量**（`recent_usage`）：喂进面板后来源 / 耗时 / token 都要对，
    #    且重复喂同一批（滚动窗口每次请求都会重发）不能刷屏（去重）
    usage_plugin, _ = _plugin()
    with_usage = _params(wire)
    with_usage["payload"]["usage_file"] = "E:/data/agt_1/ses_1/usage.jsonl"
    with_usage["payload"]["recent_usage"] = _usage_fixture()
    usage_plugin.handle_station_request(with_usage)
    usage_records = usage_plugin._collect_records()
    labels = [record.get("source") for record in usage_records]
    for expected in ("relay", "builtin", "llm.call", "plugin"):
        if labels.count(expected) != 1:
            failures.append("面板来源列少了 / 多了 %r：%r" % (expected, labels))
    if "turn" in labels:
        failures.append("对话自己的跳（source=turn）不该进压缩面板：%r" % labels)
    if not usage_plugin._usage_file.endswith("usage.jsonl"):
        failures.append("载荷里的 usage_file 没被记住（排障要用）：%r"
                        % usage_plugin._usage_file)
    usage_view = json.dumps(usage_plugin._panel_view(), ensure_ascii=False)
    for must in ["builtin", "llm.call", '"plugin"', "1.2k", "缓存 900",
                 "输出 120", "1.8 s", "16:31:55", "（估算）"]:
        if must not in usage_view:
            failures.append("面板视图里看不到 %r：%s" % (must, usage_view[:400]))
    if "缓存 0" in usage_view:
        failures.append("cached_tokens=null 不该显示成 0（拿不到就留白）")
    if "最近原因：用量" in usage_view:
        failures.append("概览的「最近原因」不该拿用量行的说明充当原因")
    # 滚动窗口：同一批行会被反复送来 ⇒ 去重后用量条数不变（否则面板会被刷屏）
    before_dedup = len(usage_plugin._usage_records)
    again = usage_plugin._ingest_recent_usage(_usage_fixture())
    if again != 0 or len(usage_plugin._usage_records) != before_dedup:
        failures.append("重复喂同一批用量行应全部去重（新增 %d 条，共 %d 条）"
                        % (again, len(usage_plugin._usage_records)))

    # ⑭b 核心没捎用量（未接线 / 账本还不存在）：面板照常工作，**不凭空造记录**
    plain_plugin, _ = _plugin()
    plain_plugin.handle_station_request(_params(wire))
    plain_labels = [record.get("source") for record in plain_plugin._collect_records()]
    if plain_labels != ["relay"]:
        failures.append("没有 recent_usage 时不该多出记录：%r" % plain_labels)
    if "用量记录" in json.dumps(plain_plugin._panel_view(), ensure_ascii=False):
        failures.append("没有用量时概览里不该提用量条数")

    # ⑭c 上限：账本可能很长 ⇒ 插件内部要有界，面板只显示 panel_records 条
    bulk_plugin, _ = _plugin()
    bulk = _params(wire)
    bulk["payload"]["recent_usage"] = [
        {"at": "2026-10-03T%02d:%02d:00.000000" % (4 + index // 60, index % 60),
         "source": "compact", "model": "demo-model", "prompt_tokens": index,
         "cached_tokens": None, "completion_tokens": 1, "estimated": False,
         "duration_ms": 10}
        for index in range(300)
    ]
    bulk_plugin.handle_station_request(bulk)
    if len(bulk_plugin._usage_records) > MAX_USAGE_RECORDS:
        failures.append("内部用量记录没有上限：%d 条"
                        % len(bulk_plugin._usage_records))
    bulk_table = _panel_table(bulk_plugin._panel_view())
    if len(bulk_table.get("rows") or []) != bulk_plugin.options.panel_records:
        failures.append("面板应只显示 %d 条，实际 %d"
                        % (bulk_plugin.options.panel_records,
                           len(bulk_table.get("rows") or [])))

    # ⑭d 离线回放旁路（`--usage-jsonl`）：读一份账本文件，按同一张字段表归一，
    #     坏行 / 不存在的文件都不能把面板弄空或弄崩
    try:
        with tempfile.TemporaryDirectory(prefix="compact_selftest_") as folder:
            usage_path = os.path.join(folder, "usage.jsonl")
            with open(usage_path, "w", encoding="utf-8") as handle:
                for item in _usage_fixture():
                    handle.write(json.dumps(item, ensure_ascii=False) + "\n")
                handle.write("这不是 JSON\n")
                handle.write(json.dumps({"source": "compact"}) + "\n")  # 缺 at
            usage_options = Options()
            usage_options.usage_jsonl = usage_path
            file_plugin, _ = _plugin(options=usage_options)
            file_records = file_plugin._collect_records()
            file_labels = sorted(record.get("source") for record in file_records)
            if file_labels != ["builtin", "llm.call", "plugin"]:
                failures.append("离线回放的来源列不对：%r" % (file_labels,))
            file_view = json.dumps(file_plugin._panel_view(), ensure_ascii=False)
            if '"42"' in file_view or "这不是 JSON" in file_view:
                failures.append("坏行 / 缺时间字段的行漏进了面板")
    except OSError as error:
        failures.append("usage.jsonl 用例建不了临时文件：%r" % error)
    missing_path, _ = _plugin()
    missing_path.options.usage_jsonl = "不存在的目录/usage.jsonl"
    if missing_path._collect_records():
        failures.append("usage.jsonl 不存在时应静默返回空（面板不该报错）")

    # ⑮ 订阅结果如实上面板（"为什么没接管"的答案常常就在这一行）
    status_plugin, _ = _plugin()
    status_plugin._set_status(False, "未订上点位：system.relay.context.compact")
    status_text = json.dumps(_last_view(status_plugin.sent, "ui/update"),
                             ensure_ascii=False)
    if "未订上点位" not in status_text:
        failures.append("订阅失败没显示到面板上：%s" % status_text[:200])
    if status_plugin._collect_records():
        failures.append("状态刷新不该凭空造出一条压缩记录")

    # ⑯ **钱别白花**：总结回包坏掉时的三段抢救（本地修复 → 一次修 json → 放弃）
    # ⑯a 免费本地修复：正文夹了说明 + 尾逗号 —— 不额外调用模型也要能接管
    bad_text = ('好的，以下是压缩结果：\n'
                '{"background": "背景", "trajectory": "轨迹", '
                '"files_changed": [], "required_files": [],}\n（完）')
    salvage_plugin, salvage_calls = _plugin(llm_seq=[{
        "ok": True, "command": "llm.call",
        "payload": {"ok": False, "error": "模型正文不是合法 JSON（text 形态）",
                    "error_kind": "json_parse", "text": bad_text,
                    "text_length": len(bad_text), "truncated_suspect": False},
    }])
    salvage_payload = _payload_of(
        salvage_plugin.handle_station_request(_params(_wire_fixture())))
    salvage_llm = [c for c in salvage_calls if c["command"] == "llm.call"]
    if not isinstance(salvage_payload, dict):
        failures.append("⑯a 本地能修好的回包应接管，实际没接管")
    elif "由本地结构修复得到" not in json.dumps(salvage_payload,
                                             ensure_ascii=False):
        failures.append("⑯a 抢救回来的摘要没有显式标注")
    if len(salvage_llm) != 1:
        failures.append("⑯a 本地能修好就不该再调模型：llm.call %d 次"
                        % len(salvage_llm))

    # ⑯b 本地修不了（截断）⇒ **恰好一次**"判断 + 修 json"调用
    truncated_text = '{"background": "背景", "trajectory": "轨迹被截断在'
    repair_summary = {"background": "背景", "trajectory": "轨迹",
                      "files_changed": [], "required_files": []}
    repair_plugin, repair_calls = _plugin(llm_seq=[
        {"ok": True, "command": "llm.call",
         "payload": {"ok": False, "error": "模型正文不是合法 JSON",
                     "error_kind": "json_parse", "text": truncated_text,
                     "text_length": len(truncated_text),
                     "truncated_suspect": True}},
        {"ok": True, "command": "llm.call",
         "payload": {"ok": True,
                     "json": {"complete": False,
                              "reason": "在 trajectory 中途截断",
                              "summary": repair_summary},
                     "text": json.dumps(repair_summary, ensure_ascii=False),
                     "model": "demo-model",
                     "usage": {"prompt_tokens": 300, "cached_tokens": 0}}},
    ])
    repair_payload = _payload_of(
        repair_plugin.handle_station_request(_params(_wire_fixture())))
    repair_llm = [c for c in repair_calls if c["command"] == "llm.call"]
    if not isinstance(repair_payload, dict):
        failures.append("⑯b 修复调用成功后应接管，实际没接管")
    else:
        body = json.dumps(repair_payload, ensure_ascii=False)
        if "由一次 JSON 修复调用补全" not in body or "不完整" not in body:
            failures.append("⑯b 修复得到的摘要没有标注不完整：%s" % body[:200])
        if "截断" not in body:
            failures.append("⑯b 模型判定的截断原因没进摘要：%s" % body[:200])
    if len(repair_llm) != 2:
        failures.append("⑯b 应恰好 2 次 llm.call（总结 + 修复），实际 %d"
                        % len(repair_llm))
    else:
        repair_args = repair_llm[1]["arguments"]
        if "response_format" in repair_args:
            failures.append("⑯b 修复调用不该带 response_format（站点缺省即 json_object）")
        if "tools" in repair_args:
            failures.append("⑯b 修复调用不该透传 tools（没有前缀要对齐）")
        if "max_tokens" in repair_args:
            failures.append("⑯b 修复调用**不设 max_tokens**（设小了就是下一次截断）")
        if truncated_text not in str(repair_args["messages"][0]["content"]):
            failures.append("⑯b 修复调用没有把原文原样带上")

    # ⑯c 连修复也失败 ⇒ 不接管，且**原因要跟着回包出去**（核心据此写日志与会话提示）
    giveup_plugin, _ = _plugin(llm_seq=[
        {"ok": True, "command": "llm.call",
         "payload": {"ok": False, "error": "模型正文不是合法 JSON",
                     "error_kind": "json_parse", "text": truncated_text,
                     "text_length": len(truncated_text),
                     "truncated_suspect": True}},
        {"ok": False, "error": "端点 429：限流"},
    ])
    giveup_reply = giveup_plugin.handle_station_request(_params(_wire_fixture()))
    if _payload_of(giveup_reply) is not None:
        failures.append("⑯c 抢救失败时应不接管（回 payload=None）")
    giveup_reason = (giveup_reply.get("reply") or {}).get("reason")
    if not isinstance(giveup_reason, str) or "repair_failed" not in giveup_reason:
        failures.append("⑯c 不接管的回包没带可读原因：%r" % (giveup_reason,))

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
