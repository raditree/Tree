# 插件开发指南（Tree 桌面端）

> 面向"从零写一个能用的插件"。协议、站点体系、隔离语义、UI 槽位、调试手段都在这里；
> 可运行示例见 [`examples/plugins/`](../examples/plugins/)。
>
> 版本口径：本指南对应**点位化**（2026-10-01）之后的核心。旧版核心（`system.relay`
> 单实例、无 `station/stream`）的差异在 §11 单独列出。

---

## 1. 一分钟上手

插件是**一个本机进程**，用 **stdio 上的 JSON-RPC 2.0**（每行一条 JSON）与核心通信：

```
核心 ──spawn──▶ 插件进程
核心 ──{jsonrpc, id, method:"hello", params:{…}}──▶ 插件        （握手）
插件 ──{jsonrpc, id, result:{ok:true, …}}─────────▶ 核心        （应答）
核心 ──{jsonrpc, id, method:"tools/list"}────────▶ 插件        （申报工具）
插件 ──{jsonrpc, id, result:{tools:[…]}}─────────▶ 核心
核心 ──{jsonrpc, method:"ping"}──────────────────▶ 插件        （心跳，默认 10s）
插件 ──{jsonrpc, method:"log"/"event"}───────────▶ 核心        （通知，不等应答）
插件 ──{jsonrpc, id, method:"station/command"}───▶ 核心        （主动下命令）
核心 ──{jsonrpc, id, method:"station/request"}───▶ 插件        （站点请求，要回包）
```

三条铁律：

1. **stdout 只放协议报文**，一行一条、不能多行、不能夹日志；日志走 stderr 或
   `log` 通知（核心把 stderr 收进插件日志缓冲）。
2. **必须能并发处理**：核心会在你处理一个请求（例如一次 `tools/call`）时，把
   `ping`、`station/request` 也发给你。单线程顺序处理的插件会在"等 A 的回包"与
   "处理 B 的请求"之间**自锁**，并因心跳丢失被判定不可用。
3. **心跳是硬要求**：核心按 `ping` 判活。连续多拍不回 → 标 `degraded`；
   中转站请求在等待回包期间**依赖心跳续期**——心跳丢了，那一路立即判"未响应"。

最小骨架（Python，完整版见示例）：

```python
import json, sys, threading

def send(msg):
    sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
    sys.stdout.flush()

def handle(method, params):
    if method == "hello":      return {"ok": True}
    if method == "tools/list": return {"tools": []}
    if method == "ping":       return {"ok": True}
    raise NotImplementedError(method)          # 未知 method → JSON-RPC error

def worker(msg):
    try:
        result = handle(msg["method"], msg.get("params") or {})
        send({"jsonrpc": "2.0", "id": msg["id"], "result": result})
    except NotImplementedError as missing:
        send({"jsonrpc": "2.0", "id": msg["id"],
              "error": {"code": -32601, "message": "method not found: %s" % missing}})

for line in sys.stdin:                          # 读循环：只读，不干活
    msg = json.loads(line)
    if msg.get("method") and "id" in msg:       # 请求：**必回一条**（线程里做，别堵读循环）
        threading.Thread(target=worker, args=(msg,), daemon=True).start()
    # 通知（无 id）：自行处理，不必回
```

**为什么 `ping` 也要走线程池**：读循环一旦被某个慢活堵住，`ping` 就没人应答；核心按心跳
判活，会把你的中转订阅判成"未响应"并以 fail-open 放行原数据（你会看到"插件没生效"，
但插件进程其实还活着）。

---

## 2. 生命周期与 RPC 清单

### 2.1 核心 → 插件

| method | 何时 | 参数 | 期望的 result |
|---|---|---|---|
| `hello` | 进程起好后第一件事 | `{core_version, plugin_id, scope, config}` | `{ok: true}`（其余字段忽略） |
| `tools/list` | 握手后（工具表刷新点也会再来） | `{}` | `{tools: [见 §6]}` |
| `tools/call` | 模型要调你的工具 | `{name, arguments, agent_id?, session_id?}` | `{text?, content?, isError?}`（见 §6.3） |
| `ping` | 每 `heartbeat_interval`（默认 10s） | `{}` | 任意合法响应（核心只看"这一拍回了没"） |
| `station/request` | 你订阅的点位被触发 | `{request_id, station_id, kind, scope, payload, meta, schema?}` | `{reply: {payload: …}}`（见 §5） |
| `station/cancel` | **通知**（无 id）：你接管的 LLM 流该收了 | `{request_id, reason?}` | 不需要应答 |

### 2.2 插件 → 核心

| method | 形态 | 参数 | result |
|---|---|---|---|
| `station/command` | 请求 | `{command, arguments, team_id?, agent_id?, session_id?, mode_key?}` | `{command, ok, mount_id, payload, error}` |
| `station/subscribe` | 请求 | `{station, point?, scope?, replace?, station_id?}` | `{ok, station_id, station_ids, kind, scope, replaced, error, subscriptions}` |
| `station/unsubscribe` | 请求 | 同上（`station` / `point` / `station_id`） | `{ok, station_id, station_ids, kind, removed, error}` |
| `station/register` | 请求 | `{kind, name, description?, schema?, max_subscriptions?}` | `{ok, station_id, error}` |
| `station/unregister` | 请求 | `{station_id}` | `{ok, removed, error}` |
| `station/stream` | **通知** | `{request_id, delta?}` / `{request_id, done:true, …}` / `{request_id, error:{…}}` | 不等应答（见 §5.4） |
| `log` | **通知** | `{level, message}` | 进核心日志缓冲 |
| `event` | **通知** | 任意 JSON 对象 | 转成前端 `plugin_event` 帧 |
| `ui/manifest` / `ui/update` | **通知** | 见 §7 | 转成 UI 帧 |
| `shutdown` | **通知** | `{}` | 核心请求你退出 |

**请求 vs 通知**：带 `id` 且带 `method` = 请求（必回一条）；
不带 `id` = 通知（不回应答）。核心自己发的请求的**回包**形态是"有 id、没有 method"。

**错误约定**：协议级错误回 `{error: {code, message}}`（如 `-32601` 未知 method）；
**业务级失败一律走 result 里的 `ok:false` + 可读 `error`**（例如命令被隔离拒绝、
订阅被占用）。这样插件不必把"网络/协议问题"与"这件事不被允许"混在一起。

---

## 3. 站点体系：类型、点位、寻址

站点（station）= **拦截点 / 触发点**。类型只有**四种**，但每类下有若干**点位
（point）**，**每个点位是一个独立的站点实例**（各自的订阅者、计数、挂载位置）。

| 类型 | 语义 | 订阅读写 |
|---|---|---|
| 广播站 broadcast | 发布 topic → 多订阅者接收 + 持久公告板 | 订阅；**单向通知**，无回填 |
| 执行站 execute | 插件主动下命令，由挂载位置执行 | **不可订阅** |
| 中转站 relay | 拦截-回填：核心把数据交给你，你决定改不改 | 订阅；**每个点位唯一订阅者** |
| 收集站 collect | 一对多收集 + 汇聚，不回填原数据流 | 由核心按接入点代订阅（工具定义） |

### 3.1 全部内置点位（17 个 id）

| 点位 id | 类型 | 触发时机 | 回填/产出 |
|---|---|---|---|
| `system.relay.tool.pre` | 中转 | 每次工具调用**前** | 改参数（或 `null` 不改） |
| `system.relay.tool.post` | 中转 | 每次工具调用**后** | 改结果文本 |
| `system.relay.llm.handle` | 中转 | tool loop 每一跳投 LLM 前 | **接管**这一跳的响应（可流式） |
| `system.relay.llm.request` | 中转 | 同一位置，**仅未被接管时** | 改写请求体（messages/tools/参数） |
| `system.relay.context.compact` | 中转 | 上下文压缩要出摘要时 | 产出摘要正文 |
| `system.relay.prompt.system` | 中转 | 每轮构造系统提示词时 | 产出最终 system prompt |
| `system.execute.fs` | 执行 | — | `fs.read` / `fs.write` / `fs.list` / `fs.grep` |
| `system.execute.terminal` | 执行 | — | `terminal.exec` |
| `system.execute.agent` | 执行 | — | `agent.message` / `agent.stop` / `agent.compact` |
| `system.execute.ui` | 执行 | — | `ui.push` |
| `system.execute.llm` | 执行 | — | `llm.call`（硬设 JSON 返回形式） |
| `system.execute.tool` | 执行 | — | `tool.call`（执行任意工具） |
| `system.execute.session` | 执行 | — | `session.rename`（会话重命名） |
| `system.broadcast` | 广播 | 通用主题（自定 topic） | 通知 |
| `system.broadcast.tool.pre` | 广播 | 工具调用前 | 通知 |
| `system.broadcast.tool.post` | 广播 | 工具调用后 | 通知 |
| `plugin.tool.define` | 收集 | 工具表刷新 | 申报工具定义 |

### 3.2 怎么订阅

```jsonc
// ① 直连点位 id（最明确，推荐）
{"station_id": "system.relay.llm.handle", "scope": {}}

// ② 类型 + 点位别名（别名比完整 id 抗改名）
{"station": "relay", "point": "llm.handle", "scope": {}}

// ③ 只写类型：中转站 = **一次订「工具调用前」+「工具调用后」两个点位**
{"station": "relay", "scope": {}}

// ④ 广播站通用主题
{"station": "broadcast", "scope": {"team_id": "agt_123"}}
```

回包（③ 会返回两条订阅的逐项结果）：

```jsonc
{"ok": true, "station_id": "system.relay.tool.pre",
 "station_ids": ["system.relay.tool.pre", "system.relay.tool.post"],
 "kind": "relay", "scope": {...}, "replaced": "", "error": "",
 "subscriptions": [{"station_id": "system.relay.tool.pre", "ok": true, "replaced": "", "error": ""},
                   {"station_id": "system.relay.tool.post", "ok": true, "replaced": "", "error": ""}]}
```

**每点位唯一订阅者**（中转站）：先到先得；第二人被拒 `key_conflict`，要接管就带
`replace: true`（回包里 `replaced` 是被你顶掉的那个插件 id）。需要"按 team / agent
分开处理"时，正解是**由这个订阅者自己转发**（在插件内再建站点分发），而不是多插件
各订一份。

---

## 4. 隔离语义：scope 的两套含义（最容易踩的一条）

四元组 `scope = {team_id, agent_id, session_id, mode_key}`，`mode_key ∈ {local, ssh}`。

| 方向 | 空字段的含义 |
|---|---|
| **订阅声明**（`station/subscribe` 的 `scope`、`plugins.yaml` 的 `scope`） | **不设条件（通配）**：空 team = 作用于**所有 team**；空 mode = local 与 ssh **都收** |
| **消息信封**（核心投给你的请求里的 `scope`） | 空 = 不可证明归属 ⇒ 核心**拒绝投递**（你不会收到这类消息） |
| **执行类命令的落地**（`fs.*` / `terminal.exec` / `agent.*`） | fail-closed：team / agent / mode 必须解析得出且与目标 agent 的真实归属**精确吻合**，否则拒绝执行 |
| **`ui.push` 的 team** | 允许为空 = 推给**所有 team**（前端任何 team 下都可见） |

实践建议：

- 想服务全部 team：`scope: {}`（写全空）。**不要**为了通过校验去写一个假的 team。
- 想只服务一个团队：`scope: {team_id: "agt_..."}`。声明是**上限**，核心按目标 agent 的
  真实归属校验；你声明了就只能服务它。
- `agent_id` / `session_id` 可以写得更细（如"只订某成员的 LLM 接管"）；写细了就必须与
  消息一致，**不能放大**。
- `mode_key` 一般**留空**：命令的 mode 由核心按目标 agent 的工作空间（有没有配 SSH）
  解析，你声明只作上限校验。填错（例如 SSH 团队声明 local）会被拒绝。

---

## 5. 中转站：触发、回包、流式

### 5.1 你会收到什么

```jsonc
// 核心 → 插件
{"jsonrpc":"2.0","id":7,"method":"station/request","params":{
  "request_id": "relay-1789000000-42",
  "station_id": "system.relay.tool.pre",
  "kind": "relay",
  "scope": {"team_id":"agt_1","agent_id":"agt_1","session_id":"session_default","mode_key":"local"},
  "payload": { …点位相关，见下表… },
  "meta": {"tool":"read","call_id":"call_abc"}
}}
```

### 5.2 你要回什么

```jsonc
{"jsonrpc":"2.0","id":7,"result":{"reply":{"payload": <回填> }}}
```

| 回填 | 含义 |
|---|---|
| `null`（或省略 `payload`） | **不改动**：核心按原数据继续（对"接管"类点位 = 不接管） |
| `String` / `Map` / `List` | **整体替换**原数据（具体形状见点位表） |
| 其它类型 | 判为非法：放宽原数据并记可读原因（fail-open，不会让你搞崩一轮生成） |

**fail-open 红线**（全部对插件友好）：无订阅者 ⇒ 核心零等待走默认路径；你没回 /
心跳丢失 / 回包非法 / 抛异常 ⇒ 一律回退默认路径并记日志。**你永远不会阻塞核心的
主流程**——但"你慢了"就是"生成慢了"，见 §5.6。

> `tool.post` 的两条回填路径差别要记牢：**回字符串** = 只换结果文本（`is_error` 保持原值）；
> **回对象** = 整体替换报文——要保留"这是一次失败调用"就必须带上 `"is_error": true`，
> 否则会被当成成功（`is_error` 缺省 false）。

### 5.3 各中转点位的载荷与回填

| 点位 | `payload` 关键字段 | 回填 |
|---|---|---|
| `system.relay.tool.pre` | `point`, `phase:"pre"`, `origin`（`agent`/`plugin`）, `source_plugin_id?`, `tool`, `call_id`, `round`, `arguments` | 改后的整条报文（改 `arguments` 即生效）或 `null` |
| `system.relay.tool.post` | 同上 + `result`, `is_error` | 改后的报文（改 `result` / `is_error`）或**字符串**（只换结果文本） |
| `system.relay.llm.handle` | `request:{model, messages, tools, max_tokens, temperature, reasoning_effort, stream}`, `turn`, `agent_id`, `session_id` | 见 §5.4 |
| `system.relay.llm.request` | 同 `request` | 改后的请求体（`{model, messages, tools, max_tokens, …}`，未识别字段会透传进请求体）或 `null` |
| `system.relay.context.compact` | `prompt`（核心拼好的压缩提示词）, `instruction`, `header`, `message_count`, `compacted`, `existing_summary` | `"摘要正文"` 或 `{summary: "…"}`；`null` = 用内置摘要器 |
| `system.relay.prompt.system` | `default`（核心构造的完整 system prompt） | 最终 system prompt 字符串（空串 = 明确不要系统提示词）；`null` = 用 `default` |

### 5.4 接管 LLM：一次性 与 流式

`system.relay.llm.handle` 有两种接管方式。

**① 一次性接管**（简单，适合"换一个模型/直接构造答案"）：

```jsonc
{"reply":{"payload":{"content":"最终答案", "reasoning_content":"可选思考",
                     "tool_calls":[{"id":"call_1","function":{"name":"read","arguments":"{\"path\":\"a.txt\"}"}}],
                     "usage":{"prompt_tokens":10,"completion_tokens":5},
                     "finish_reason":"stop"}}}
// 也接受 OpenAI 原样响应：{"choices":[{"message":{…},"finish_reason":"stop"}],"usage":{…}}
```

**② 流式接管**（逐字出现在界面上）：

```jsonc
// 第一次回包：声明接管
{"jsonrpc":"2.0","id":7,"result":{"reply":{"payload":{"stream": true}}}}

// 之后用通知推增量（可多次；request_id 必须原样带上）
{"jsonrpc":"2.0","method":"station/stream","params":{"request_id":"relay-1789000000-42",
  "delta":{"kind":"text","text":"你好"}}}
{"jsonrpc":"2.0","method":"station/stream","params":{"request_id":"…",
  "delta":{"kind":"thinking","text":"先看文件"}}}
{"jsonrpc":"2.0","method":"station/stream","params":{"request_id":"…",
  "delta":{"kind":"tool_call","index":0,"id":"call_1","name":"read","arguments_delta":"{\"pa"}}}

// 收尾（二选一）
{"jsonrpc":"2.0","method":"station/stream","params":{"request_id":"…","done":true,
  "finish_reason":"stop","usage":{"prompt_tokens":10,"completion_tokens":5}}}
{"jsonrpc":"2.0","method":"station/stream","params":{"request_id":"…","error":{"message":"上游 500"}}}
```

`delta.kind` 也接受 OpenAI 分片写法：`{"choices":[{"delta":{"content":"…"}}]}`。

**流式接管的规矩**（都是硬约束）：

- **开流后不可回退**：你说了 `stream:true` 就必须以 `done` 或 `error` 收尾。已经吐出的
  内容不会撤回，核心也不会改走系统 LLM（否则界面会重复输出）。
- **推流时保持 `ping` 应答**：核心在等你的流时同时看心跳；心跳丢了，这一路立即以失败
  收尾。所以读循环要能并发（见 §1 铁律 2）。
- **取消**：用户按停止时，核心给你发 `station/cancel`（通知，带同一个 `request_id`）。
  收到后尽快停流；之后你**迟到**的 `delta` 会被丢弃，不会报错。
- **未知 `request_id`** 的 `station/stream` 会被丢弃并记日志：注意在**回包之后**才推流，
  且在 `done` 之后别再推。
- **工具调用也能接管**：把 `tool_call` 增量推完（`done`）后，核心会照常执行工具、把结果
  回灌进上下文、继续下一跳——你的插件因此可以自己驱动整个工具循环。

### 5.5 压缩与系统提示词的注意点

- 压缩点位在**工具循环每一跳前**都可能被触发（长任务里上下文是一轮轮长的）。你的处理
  速度直接等于生成速度；重入保护在核心侧（你在压缩处理里再下 `agent.compact` 会被拒）。
- 系统提示词点位每轮生成调一次（压缩后重建时会再调一次）。你改写后的提示词**不进**
  压缩阈值估算（估算读的是内置构造结果），所以"改得多"会与进度条口径有偏差。

### 5.6 性能与超时

- 不设静态总超时：核心按**心跳判活**等你（长任务不会被时间杀）。
- 但"你慢 = 生成慢"：`tool.pre/post` 在每次工具调用的关键路径上，`llm.handle` 在每一跳上。
  能在几十毫秒内决定的事，不要做成一秒。
- 无订阅者时核心**零等待**：没配插件时这些点位没有任何开销。

---

## 6. 执行站：命令与工具

命令走 `station/command`（**不是**站点订阅）。命令按命令族分点位，但对插件是透明的：
只带 `command` 即可。

### 6.1 命令清单

| 命令 | 参数 | 结果 payload | 说明 |
|---|---|---|---|
| `fs.read` | `path`/`file_path`, `start_line?`, `line_count?` | `{path, content, total_lines, truncated, …}` | 读工作空间小文件 |
| `fs.write` | `path`, `content` | `{path, bytes_written}` | 写文件 |
| `fs.list` | `path?`, `max_depth?`, `max_entries?` | `{entries, count, truncated}` | 列目录 |
| `fs.grep` | `pattern`, `regex?`, `ignore_case?`, `path?`, … | `{matches:[{path,line,text}], count, truncated}` | 内容检索 |
| `terminal.exec` | `command`，或 `hook_action`(`status`/`cancel`)+`task_id` | `{text, is_error}` | 执行命令（支持后台任务模式） |
| `agent.message` | `message`/`content`, `session_id?` | `{…}` | 给某 agent 的会话发消息 |
| `agent.stop` | `agent_id?`, `cascade?`（缺省 true） | `{any_running, reason?, …}` | 停止（级联）生成 |
| `agent.compact` | `agent_id?`, `session_id?` | `{…}` | **发起上下文压缩** |
| `ui.push` | `slot_key`, `view?` | `{pushed, slot, slot_key, unregistered}` | 往消息流推一张卡片（§7） |
| `llm.call` | `messages?` 或 `prompt?`, `system?`, `model?`, `temperature?`, `max_tokens?` | `{ok, json, text, model, usage}` | **站点处硬设 JSON 返回形式**的 LLM 调用，复用目标 agent 的模型 |
| `tool.call` | `tool`, `arguments?`, `relay?`（默认 false） | `{tool, result, is_error, relayed}` | 执行**任意工具**（内置 / MCP / 插件工具同一入口） |
| `session.rename` | `title`（必填）, `session_id?` | `{renamed, title, session_id}` | 会话重命名（前端即时刷新标题） |

### 6.2 身份从哪来

- 命令要落到某个 agent 的工作面时，核心按 **目标 agent 的真实归属**解析 team / mode：
  带 `agent_id`（params 顶层或 `arguments` 里都行），或让你的 `plugins.yaml` 声明
  `scope.agent_id`。
- `plugins.yaml` 的 `scope.team_id` 是**上限**：声明了就只能服务该 team。**留空 = 所有 team**
  （命令按每条命令的 `agent_id` 解析真实归属）。
- 解析不出归属（agent 不存在 / 没声明也没带 agent 且该 agent 无团队）⇒ 拒绝并给可读原因。

### 6.3 工具：申报与执行

申报（`tools/list` 的返回，或用收集站申报，见 §8）：

```jsonc
{"tools":[{"name":"etl_stats","description":"统计工作空间里的 CSV 行数",
  "parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}]}
```

调用（核心 → 你）：

```jsonc
{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{
  "name":"etl_stats","arguments":{"path":"data.csv"},
  "agent_id":"agt_1","session_id":"session_default"}}
```

回包约定：

```jsonc
{"jsonrpc":"2.0","id":9,"result":{"text":"行数 1200", "isError": false}}
```

- `text`（或 `content`）是给模型看的文本；`isError:true` 表示这次工具失败（`text` 里写
  可读原因，模型会看到并可能自行纠正）。
- 命名空间：注册进模型工具表后，模型看到的名字是 `plugin__{插件id}__{工具名}`。
- **`tool.call` 让插件反向执行工具**：`{"command":"tool.call","arguments":{"tool":"read",
  "arguments":{"path":"a.txt"}}}`；工具名可用模型可见名（含 `plugin__` / `mcp__`）。
  默认**绕开**工具中转与广播——若你既是 `tool.call` 的调用方、又订了 `tool.pre`，
  不绕开就可能自锁。要审计自己的调用就传 `"relay": true`（并确保你能并发处理）。

### 6.4 权限现实

本仓库**没有工具审批层**：模型调用工具、插件经执行站调用工具，都是"agent 的权限"。
插件能做 `fs.write` / `terminal.exec`（只要 scope 能证明归属）。写插件时请把
"能做什么"当作自己的责任，而不是指望核心拦你。

---

## 7. 广播站与前端 UI

### 7.1 广播（单向通知）

订阅 `system.broadcast`（通用主题）或 `system.broadcast.tool.pre|post`（工具调用事件）。
工具广播**不等回包**：核心不等你应答，投递失败只进公告板与计数，不影响工具调用。

```jsonc
{"station_id":"system.broadcast.tool.post","scope":{}}
```

你会收到：

```jsonc
{"method":"station/request","params":{"station_id":"system.broadcast.tool.post","kind":"broadcast",
 "payload":{"point":"…","phase":"post","origin":"agent","tool":"write","call_id":"call_1",
            "round":3,"agent_id":"agt_1","session_id":"session_default",
            "arguments":{…},"result":"已写入 12 字节","is_error":false},
 "meta":{"topic":"tool.post","origin":"agent","tool":"write"}}}
```

`origin` = `agent`（模型发起的调用）或 `plugin`（插件经 `tool.call` 发起、且显式 `relay:true`）。
你可以回一个 `payload`（会被记录），但广播的语义是**通知**，别依赖它。

### 7.2 前端槽位（声明式，无 JS）

用 `ui/manifest` 声明槽位，`ui/update` 更新内容，`ui.push` 往消息流推卡片：

```jsonc
// 声明（插件上线时发一次）
{"jsonrpc":"2.0","method":"ui/manifest","params":{
  "plugin_id":"sample", "title":"示例插件",
  "slots":[
    {"slot_key":"sample.activity.main","slot":"activity","title":"示例插件","order":10},
    {"slot_key":"sample.panel.main","slot":"panel","title":"示例插件"},
    {"slot_key":"sample.card.rounds","slot":"card","title":"工具轮次"}
  ]}}

// 更新（可多次）
{"jsonrpc":"2.0","method":"ui/update","params":{
  "slot_key":"sample.activity.main",
  "view":{"type":"column","children":[{"type":"text","text":"已计数 3 次"}]}}}
```

槽位类型：

| `slot` | 位置 | 备注 |
|---|---|---|
| `activity` | 左侧活动栏条目 | 点击回调走 `plugin_ui_action` 上行帧 |
| `panel` | 右栏 Tab | 声明后才出现 |
| `status` | 状态条 | 单行 |
| `card` | 消息流内联卡片 | **必须先声明**；未声明的 `slot_key` 会被前端静默丢弃（这是最常见的"我推了但看不到"） |

视图是**受限控件集的 JSON**（`column` / `row` / `text` / `button` / `divider` / `image` /
`list` 等，风格 `body|title|caption|mono`）：不执行任何插件 JS。按钮点击会以
`plugin_ui_action` 上行帧回到你的进程（含 `slot_key` / `action` / 参数）。

`ui.push`（执行站命令）适合"随对话出现"的卡片：`slot_key` 必须是已声明的 `card` 槽位；
`view` 省略 = 注销该卡片。

---

## 8. 收集站：集中申报工具定义

除了 `tools/list`，插件还能在**工具表刷新点**按 schema 申报工具定义（`plugin.tool.define`）。
核心会向每个启用插件发 `station/request`（`kind: collect`），你要按 schema 产出：

```jsonc
{"reply":{"payload":{"tools":[
  {"tool_name":"etl_stats","description":"统计 CSV 行数",
   "parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]},
   "execution":{"method":"tools/call","name":"etl_stats"}}]}}}
```

- `execution.method` 当前支持 `tools/call`（缺省）；`name` 缺省 = `tool_name`。
- 产出会被 schema 严格校验（多一个字段都会被拒），错误会以可读原因回报给你。
- 没有工具就产出 `{"tools": []}`——**不要不回**，未响应会被记成"未响应的订阅者"。

---

## 9. 配置（`plugins.yaml`）

```yaml
plugins:
  - id: sample                     # 唯一；决定插件工具命名空间 plugin__sample__xxx
    name: 示例插件
    enabled: true
    command: python                 # 启动命令（argv[0]）
    args: ["plugins/sample_plugin.py", "--slot-key", "sample.card.rounds"]
    cwd: ""                         # 可选
    env: {}                         # 可选
    granularity: team               # team / agent / session（实例粒度声明，缺省 team）
    scope: {}                       # 作用域上限：空 = 作用于所有 team（§4）
```

- 写 `scope` 只影响**声明上限**：空 = 全部 team；填了就只能服务它。
- `granularity` 是**声明性**的实例粒度（界面按它分组/提示）；站点与命令的隔离一律按
  运行期四元组解析（§4），不靠它兜底。
- 界面上的「启用」开关会写这份文件；改动在核心下次启动或热应用时生效。
- 插件脚本路径：相对路径按**核心进程的工作目录**解析（桌面端是 `plugins/`）。

---

## 10. 调试与测试

| 手段 | 怎么做 |
|---|---|
| 插件日志 | `log` 通知（`{"method":"log","params":{"level":"info","message":"…"}}`）或直接写 stderr |
| 面板 | 设置 → 插件开发：「插件」段看实例状态与订阅，**「站点」段看每个点位**的订阅者/计数（`requests` / `responded` / `timeout` / `no_subscriber` 等） |
| 骨架探针 | 先用 §1 的最小骨架跑通 `hello` / `ping` / `tools/list`，再加站点订阅；不要一上来就写全功能 |
| 不用真核心自测 | 写一个假核心：按 §2 的报文往你的 stdin 写，读你的 stdout 断言（示例仓库里的 `sample_plugin.py --selftest` 就是这么做的） |
| 常见坑 | ① stdout 混入日志 ⇒ 解析失败；② 单线程顺序处理 ⇒ 自锁 + 心跳丢失；③ 忘了 `ui/manifest` 声明 `card` 槽位 ⇒ 推了看不到；④ 订阅写了错的 `mode_key` ⇒ 收不到消息；⑤ 流式接管忘了 `done` ⇒ 该轮一直等（最终被取消/心跳判死） |

---

## 11. 从旧核心迁移（点位化之前）

| 旧 | 新 | 迁移动作 |
|---|---|---|
| `system.relay`（工具前/后共用一个实例） | `system.relay.tool.pre` + `.tool.post` | 核心**自动迁移**落盘订阅（旧订阅复制到两个点位，行为等价）；插件代码不用改：`{"station":"relay"}` 现在一次订两个点位 |
| `system.execute`（九条命令共用一个实例） | `system.execute.fs/terminal/agent/ui/llm/tool/session` | 插件无感（命令名不变，核心按命令路由） |
| 无流式接管 | `station/stream` + `station/cancel` | 想用就用；不用则一次 `reply` 仍可 |
| `point` 参数不存在 | `station/subscribe` 支持 `point` | 可选：用别名代替完整 id |

---

## 12. 完整示例

- [`examples/plugins/sample_plugin.py`](../examples/plugins/sample_plugin.py)：
  演示工具申报、活动栏面板、消息流卡片、中转站工具前/后改写、**LLM 接管（流式）**、
  `llm.call` / `tool.call` / `session.rename`、广播订阅、自建站点、心跳与 selftest。
- 运行：把 `examples/plugins/` 下的脚本拷到桌面端的 `plugins/` 目录，在
  「设置 → 插件开发」里启用，即可在面板与消息流里看到它。

有疑问先看两条不变量：**"空 = 通配"只适用于订阅声明**；**任何异常都 fail-open，
绝不阻塞生成**。其余细节都能从这两条推出来。
