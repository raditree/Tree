# 插件开发指南（Tree 桌面端）

> 面向"从零写一个能用的插件"。协议、站点体系、隔离语义、UI 槽位、调试手段都在这里；
> 可运行示例见 [`examples/plugins/`](../examples/plugins/)。
>
> 在 agent 的工作空间里读到这份时，它是**核心播种的副本**（`.self/docs/plugin-development.md`，
> 选中 `plugin-creator` 规范时播种、由核心维护）：权威仍是应用目录 `plugins/`（发行版）与仓库
> `docs/` 里的原件——副本与原件内容逐字一致，别手改副本（下一次播种会覆盖）。
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
| `hello` | 进程起好后第一件事 | `{core_version, plugin_id, scope, config, resume_dump_id?}` | `{ok: true}`（其余字段忽略）。`resume_dump_id` 只在**热重启后的新一世**才出现，没快照时根本不递这个键（旧插件不受影响） |
| `tools/list` | 握手后（工具表刷新点也会再来） | `{}` | `{tools: [见 §6]}` |
| `tools/call` | 模型要调你的工具 | `{name, arguments, agent_id?, session_id?}` | `{text?, content?, isError?}`（见 §6.3） |
| `ping` | 每 `heartbeat_interval`（默认 10s） | `{}` | 任意合法响应（核心只看"这一拍回了没"） |
| `station/request` | 你订阅的点位被触发 | `{request_id, station_id, kind, scope, payload, meta, schema?}` | `{reply: {payload: …}}`（见 §5） |
| `station/cancel` | **通知**（无 id）：你接管的 LLM 流该收了 | `{request_id, reason?}` | 不需要应答 |
| `suspend` | **热重启前的转储请求**（只有条目声明了 `suspension: keep` 才会收到） | `{reason: "hot_restart"}` | `{ok: true}`；**先下 `plugin.stateDump`、等它回包、再回本条 ack**（见 §6.5） |

> **`suspend` 是本任务（插件热重启）唯一新增的 method**，并由
> `packages/tree_protocol/test/plugin_rpc_method_gate_test.dart` 钉住"新增 = 1"；
> 所有方法名都必须在 `tree_protocol` 的 `PluginRpcMethods` 里登记，否则门禁红。

### 2.2 插件 → 核心

| method | 形态 | 参数 | result |
|---|---|---|---|
| `station/command` | 请求 | `{command, arguments, team_id?, agent_id?, session_id?, mode_key?}` | `{command, ok, mount_id, payload, error}` |
| `station/subscribe` | 请求 | `{station, point?, scope?, replace?, station_id?}` | `{ok, station_id, station_ids, kind, scope, replaced, error, subscriptions}` |
| `station/unsubscribe` | 请求 | 同上（`station` / `point` / `station_id`） | `{ok, station_id, station_ids, kind, removed, error}` |
| `station/register` | 请求 | `{kind, name, readme, description?, schema?, max_subscriptions?, shared?, allowed_plugins?, config?}`（**`readme` 必填**，见 §3.3） | `{ok, station_id, kind, error}` |
| `station/unregister` | 请求 | `{station_id}` | `{ok, removed, error}` |
| `station/trigger` | 请求 | `{station_id, topic?, scope?, payload?, meta?}`（**必须带确定的 `mode_key`**，见 §3.3） | `{ok, station_id, kind, result, error}`；`result` 含 `summary` / `delivered` / `skipped` / `deliveries[]` |
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

### 3.1 全部内置点位（35 个 id：广播 10 + 执行 11 + 中转 12 + 收集 2）

| 点位 id | 类型 | 触发时机 | 回填/产出 |
|---|---|---|---|
| `system.relay.tool.pre` | 中转 | 每次工具调用**前** | 改参数（或 `null` 不改） |
| `system.relay.tool.post` | 中转 | 每次工具调用**后** | 改结果文本 |
| `system.relay.llm.handle` | 中转 | tool loop 每一跳投 LLM 前 | **接管**这一跳的响应（可流式） |
| `system.relay.llm.request` | 中转 | 同一位置，**仅未被接管时** | 改写请求体（messages/tools/参数） |
| `system.relay.context.compact` | 中转 | 要压缩上下文时（规划也归你） | 产出**摘要侧上下文** + 覆盖切点下标（之后的原文由核心追加） |
| `system.relay.prompt.system` | 中转 | 每轮构造系统提示词时 | 产出最终 system prompt |
| `system.relay.ssh.execute` | 中转 | 每次 SSH 工作空间操作（建/销隧道、读写、命令、拉心跳、开 PTY）时 | 订阅者（`ssh_executor` 插件）自己完成到目标机的通信，以同一形状 payload 回包；**无订阅者 fail-open 回退内置 dartssh2**（别名 `ssh.execute`，详见 [ssh-tunnel-protocol.md](ssh-tunnel-protocol.md) §2） |
| `system.relay.tool.repair` | 中转 | 收尾时发现历史里缺某次工具调用的结果 | `{repaired:true, text}` ⇒ 用插件那句落库；**落库与 `tool_end` 帧仍只走内置那一条**（别名 `tool.repair`） |
| `system.relay.tool.probe` | 中转 | 同一批：判断这次调用是否已有结果 | `{found:true, text}` / `{found:false}` / 不回 ⇒ 三档：**有结果 / 肯定没有 / 交回内置探针查库**（别名 `tool.probe`） |
| `system.relay.llm.register` | 中转 | 每个流式请求建立时（登记之后） | `{accepted, note}` ⇒ 回执只进日志；**内置登记表永远先建立**，取消/关闭/判死不在这一条上（别名 `llm.register`） |
| `system.relay.compact.skip.reason` | 中转 | 每一次「压缩没走插件」（早退不投） | `{reason}` ⇒ **覆盖还账上那一条**（REST 与压缩结论会看到）；已推进历史的通知不回改；不改分级位（别名 `compact.skip.reason`） |
| `system.relay.loop.run` | 中转 | 每一轮开始处（上下文装配完、进入内置 LlmSession **之前**） | 回 `{stream:true}` ⇒ **整轮循环形状归你**（第几跳、工具怎么排、何时收尾）；文本/思考/提示/用量经 `station/stream` 推回，**工具走 `tool.call` 并回带 `run_id`**；落库、卡片、取消与判死仍在核心（别名 `loop.run`，详见 §5.6） |
| `system.execute.fs` | 执行 | — | `fs.read` / `fs.write` / `fs.list` / `fs.grep` |
| `system.execute.terminal` | 执行 | — | `terminal.exec`（含 hook 后台任务）、`terminal.listRuns` / `terminal.stopRun` / `terminal.log`（后台任务的**结构化读口与控口**：列表回行不回散文，`exit_code`/`pid` 拿不到写 `null` 不省略键，终止**不保证杀得掉**且 `requested=false` 必带 `reason`，`log` 只递尾部；只看/只动目标 agent 自己的任务） |
| `system.execute.agent` | 执行 | — | `agent.message` / `agent.stop` / `agent.compact` |
| `system.execute.ui` | 执行 | — | `ui.push` |
| `system.execute.llm` | 执行 | — | `llm.call`（硬设 JSON 返回形式） |
| `system.execute.tool` | 执行 | — | `tool.call`（执行任意工具）、`tool.close`（按 `handle` **显式关闭**一次运行中的工具/请求：先尽力终止进程树、再让在途调用收敛；句柄失效或不归你管 ⇒ 可读拒绝，**绝不自动关**） |
| `system.execute.session` | 执行 | — | `session.rename`（会话重命名） |
| `system.execute.ssh` | 执行 | — | `ssh.reconnect`（重建目标 agent 的远端链路；与 REST `POST /api/agents/{id}/ssh/reconnect`、右栏文件面板「重连」按钮同一实现） |
| `system.execute.plugin` | 执行 | — | `plugin.list` / `plugin.restart` / `plugin.suspend` / `plugin.state` / `plugin.stateDump` / `plugin.stateFetch`（插件热重启的控制面，见 §6.5；模型能使唤的那一面见 §6.7；别名 `plugin`）。**后两条不得被申报成 agent tool**：它们是生命周期原语，只能由插件自己下 |
| `system.execute.station` | 执行 | — | `station.list` / `station.state`（**只看不动**的拓扑：谁接管了哪个点位、自建站归谁。内置点位任何 team 都可见，插件自建站只对订阅者所在 team 可见；接管权易手仍只走 `station/subscribe`，这里不开第二条路；别名 `station`，见 §6.9） |
| `system.execute.usage` | 执行 | — | `usage.query`（按会话取**逐调用用量账本**：`{session_id, usage_file, count, skipped, calls, summary{…,by_source}}`。行形状与 `UsageCall.toJson()` 逐字一致；账本在数据根下，插件的 `fs.read` 本来够不到，这一条是它唯一的问口；只读一个会话、只读尾部；别名 `usage`） |
| `system.broadcast` | 广播 | 通用主题（自定 topic） | 通知 |
| `system.broadcast.tool.pre` | 广播 | 工具调用前 | 通知 |
| `system.broadcast.tool.post` | 广播 | 工具调用后 | 通知 |
| `system.tool.timeout` | 广播 | 某次**工具运行/LLM 请求**超过阈值（默认 **300 s**）时，**每个运行只广播一次** | 通知：载荷 `{handle, agent_id, session_id, tool, command, elapsed_ms, started_at, point}`——拿到 `handle` 后可经执行站 `tool.close` 显式关闭这次运行（见下行）；别名 `tool.timeout`（`{station: 'broadcast', point: 'tool.timeout'}`） |
| `system.broadcast.plugin.state` | 广播 | 插件**生命周期跃迁**（booting / ready / restarting / suspended / failed / stopped）与**失活标记**（心跳连续丢失 / 恢复）| 通知：载荷 `{plugin_id, lifecycle, previous, generation, missed_heartbeats, reason, buffer}`；别名 `plugin.state`（`{station: 'broadcast', point: 'plugin.state'}`）；发布点**只有这两处**（跃迁集中在 `PluginBus._setLifecycle`，失活与 `health` 同一个判定源 `LivenessTracker`，**不另造时钟**）。要看某个插件的当前读数请下执行站命令 `plugin.state`——**那是“问”，这里是“推”**；三者各管各的轴：**活性看 `health`、启停看 `status`、阶段看 `lifecycle`** |
| `system.broadcast.turn.done` | 广播 | 本轮**正常结束**（会话收尾处） | 通知：`{agent_id, session_id, team_id, content_chars, elapsed_ms, finish_reason, tool_rounds}`；**不带正文**（正文有会话与 REST 两个正经读处）。别名 `turn.done` |
| `system.broadcast.turn.cancelled` | 广播 | 本轮**被取消**（与 done 互斥，一轮只出一条） | 通知额外带 `source`：`interjection`（被新消息插话）/ `user_stop`（用户按停）——不变量 5 的两种取消在审计里必须分得开 |
| `system.broadcast.turn.error` | 广播 | 本轮**错误终止** | 通知：`{…, error, failed_after_tools}`；`error` 就是核心已经发给用户那句**可读文案**（不另造一套说法）；取消与错误同时发生 ⇒ **先报错误** |
| `system.broadcast.ask.paused` | 广播 | `AskUserQuestion` **落盘并推帧之后**、开始等作答那一刻 | 通知：`{agent_id, session_id, team_id, question_id, question_count}`；**不带题面与选项**（那是用户与 agent 之间的内容，审计只需知道“谁在等、等几道”） |
| `system.broadcast.config.changed` | 广播 | `applyConfigs()` 逐条对账**完成后**，一条动作一个 topic | 通知：`{plugin_id, action, action_label, reason, generation}`；`action` 与 `PluginReconcileKind` 同源（`started` / `stopped` / `restarted` / `failed`）；**`unchanged` 一律不广播**（没改动的对账是噪声） |
| `plugin.tool.define` | 收集 | 工具表刷新 | 申报工具定义 |
| `plugin.capability.define` | 收集 | 与工具申报**同一趟** | 申报自己认得的**点位**（`{capabilities:[{capability_id, direction:push\|pull, event, description, schema}]}`）；**`schema` 为空就拒那一条**；申报只是描述，**不产生投递路** |

### 3.2 怎么订阅

```jsonc
// ① 直连点位 id（最明确，推荐）
{"station_id": "system.relay.llm.handle", "scope": {}}

// ② 类型 + 点位别名（别名比完整 id 抗改名）
{"station": "relay", "point": "llm.handle", "scope": {}}

// ③ 只写类型：中转站 = **一次订「工具调用前」+「工具调用后」两个点位**
{"station": "relay", "scope": {}}

// ④ 广播站通用主题（**不带 point 只订通用主题**，与 relay 的糖不对称；
//    要收"每次工具调用"的广播就订 tool.pre / tool.post 两次）
{"station": "broadcast", "scope": {"team_id": "agt_123"}}
{"station": "broadcast", "point": "tool.post", "scope": {}}
```

**部分成功要看逐条结果**：一次订阅多个点位时 `ok` 只在**全部成功**时为 true，`error` 是
拼接串、`replaced` 是逗号拼接——"到底哪个点位没订上"只能读 `subscriptions[]`（每条含
`station_id` / `ok` / `replaced` / `error`）。只看 `ok` 会把"一半订上"误判成"全没订上"。

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

### 3.3 插件自建站（`station/register`）：readme 必填、共享、自定义配置

站点全局化后**每个点位只有一个订阅者**，所以上面那条"自己转发"的正解长这样：
一个插件订阅内置点位 → **自建一个转发型站点** → 让别的插件订阅它 / 触发它。建站必须
走核心，否则下游没有回包通道与等待链。

```jsonc
// 插件 → 核心
{"jsonrpc":"2.0","id":3,"method":"station/register","params":{
  "kind": "relay",                  // broadcast | relay | collect（execute 不可自建）
  "name": "audit",                  // 只允许字母数字与 _ -，**不能带点号**
  "readme": "收到工具公告后按 team 单向改写再投递；订阅者回 null = 不改动。",
  "description": "审计转发站",       // 可选；卡片上那一行短说明
  "max_subscriptions": 8,           // 可选；缺省 relay 16、其余 32
  "shared": true,                   // 可选；缺省 false = 只有你能用
  "allowed_plugins": ["other"],     // 可选；非空 = 只开放给列出的插件
  "config": {"route": "team"}       // 可选；站点自定义配置（核心不解释语义）
}}
→ {"ok": true, "station_id": "plugin.sample.relay.audit", "kind": "relay", "error": ""}
```

**id 由核心拼**（`plugin.{你的 id}.{kind}.{name}`）：插件不能自选 id，也不能冒用内置 id
或别人的命名空间——"我的站点只能是我的"就是在这一条上强制的。

三条硬规矩（都在 `station/register` 里，业务拒绝一律回 `ok:false` + 可读 `error`，
**不会建出半个站点**）：

| 规矩 | 为什么 | 被拒时说的话 |
|---|---|---|
| **`readme` 必填**（非空且不全空白） | 站是你建的，"它干什么、什么时候被触发、订阅者该怎么回"只有你说得清；共享给别人时，这份 readme 是对方唯一能读到的说明书 | `station/register 需要 readme（站点介绍，必填）：这个站干什么、什么时候被触发、订阅者该怎么回。内置站点的介绍来自核心的点位表。` |
| `name` 里不能有点号 | 会与归属前缀判定撞车（插件 `a` 建 `b.relay.x` 能顶掉 `a.b` 的站） | 点名「只允许」的字符集 |
| 收集站必须带非空 `schema` | 输入格式由站点定义，订阅者要按它产出 | `收集站必须定义 schema（输入格式：fields 非空），当前为空` |

**内置站点的介绍来自点位表**（[station_points.dart](../packages/tree_core/lib/src/plugin/station_points.dart)），
插件与界面都**不能**改写；界面上改内置站只能改「可订阅插件数量」。

**同名重复注册 = 幂等**：返回既有站点、不报错、**也不覆盖**第一次写的 `readme`（插件重启
会再注册一遍，所以这条校验排在幂等分支之后——这次没带介绍也不该把既有站拒掉）。

共享出去的站怎么用（`shared` / `allowed_plugins` 这把闸门**订阅与触发共用**）：

```jsonc
// 别的插件订阅它（成为下游）
{"method":"station/subscribe","params":{"station_id":"plugin.sample.relay.audit"}}
// 别的插件（或订阅方自己）触发它
{"method":"station/trigger","params":{"station_id":"plugin.sample.relay.audit",
  "topic":"audit","scope":{"team_id":"agt_1","mode_key":"local"},"payload":{…}}}
```

- 闸门只认**显式声明**：`shared` 为 false ⇒ 别人连门都摸不到；`allowed_plugins` 非空 ⇒
  名单外一律拒（原因里写出当前名单）。**所有者永远能用你自己的站**——门是给别人的，
  不是防自己的。
- 触发时消息 `scope` **由核心按真实归属解析**，调用方自报的 team / mode 不作数（与订阅
  同一 fail-closed 口径）；而且**必须带确定的 `mode_key`**：空 mode 在*订阅*里是通配，
  但投递判据是"消息 ↔ 订阅者"，一条没有工作面的消息定不了投给谁（拒绝原因会指向
  `mode_key` 这个可改的字段）。
- **内置点位不可触发**：它们的触发时机由核心在固定接入点决定，要用内置能力请下
  `station/command`；**执行站不可触发**（由命令驱动，没有"触发一次"的语义）。
- 站点自定义 `config` **随 `meta` 下发给订阅者**（`meta` 里另有 `triggered_by` = 这次是谁
  触发的）。核心**不解释**这些键的含义——那是建站方与订阅者之间的契约；但订阅者必须
  读得到，否则界面上配的"其他参数"就是摆设。
- **禁用订阅者 ≠ 退订**：所有者可以把某个订阅者关掉（保留订阅关系与回包通道），触发时
  不投给它，但每条跳过都写进 `result.skipped` 并计入 `skipped_disabled`——不静默。
- 自建站与它的 `readme` / `shared` / `allowed_plugins` / `config`、以及每个订阅者的禁用标记，
  都**落盘 `config/stations.yaml`**：跨重启保留，插件重新上线也不会把用户关掉的东西悄悄打开。

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

**可选键 `reason`**（2026-10-05 新增，**纯增量**）：回 `null`（= 不接管 / 不改动）时，顺手说明**为什么**：

```jsonc
{"jsonrpc":"2.0","id":7,"result":{"reply":{"payload": null,
  "reason": "[repair_failed] 总结回包抢救失败：修复调用失败：端点 429（原文 4274 字，前 120 字：…）"}}}
```

核心会把它写进日志、并带进压缩结论（REST 的 `relay_skip_reason` 与会话提示）。
**不写也完全合法**（老插件零改动、行为逐字不变）——但那意味着核心侧只剩一句"插件回 null"，
"插件白跑一次、核心悄悄兜底"就成了事后查不出原因的黑洞（真实现场见 known-issues #31）。

> **`null` 与"空集合"不是一回事**：`reply: {payload: null}` = "我不改"（fail-open 走默认）；
> `[]` / `""` 是**真的把数据换成了空**——在 `llm.handle` 上会解码出"零个事件"，
> 核心只能判"回包认不出"从而不接管（还多一次往返）。要"不接管/不改动"，请回 `null`。

**fail-open 红线**（全部对插件友好）：无订阅者 ⇒ 核心零等待走默认路径；你没回 /
心跳丢失 / 回包非法 / 抛异常 ⇒ 一律回退默认路径并记日志。**你永远不会阻塞核心的
主流程**——但"你慢了"就是"生成慢了"，见 §5.7。

> `tool.post` 的两条回填路径差别要记牢：**回字符串** = 只换结果文本（`is_error` 保持原值）；
> **回对象** = 整体替换报文——要保留"这是一次失败调用"就必须带上 `"is_error": true`，
> 否则会被当成成功（`is_error` 缺省 false）。

### 5.3 各中转点位的载荷与回填

| 点位 | `payload` 关键字段 | 回填 |
|---|---|---|
| `system.relay.tool.pre` | `point`, `phase:"pre"`, `origin`（`agent`/`plugin`）, `source_plugin_id?`, `tool`, `call_id`, `round`, `arguments` | 改后的整条报文（改 `arguments` 即生效）或 `null` |
| `system.relay.tool.post` | 同上 + `result`, `is_error` | 改后的报文（改 `result` / `is_error`）或**字符串**（只换结果文本） |
| `system.relay.llm.handle` | `request:{model, messages, tools, max_tokens, temperature, reasoning_effort, stream}`, `turn`, `agent_id`, `session_id`（**单实例插件靠这两个字段就知道"这一次是谁在问"，不必等事件**） | 见 §5.4 |
| `system.relay.llm.request` | 同 `request` | 改后的请求体（`{model, messages, tools, max_tokens, …}`，未识别字段会透传进请求体）或 `null` |
| `system.relay.context.compact` | `system_prompt`（内置拼装的系统提示词，放在提示词槽位用）, `request`（**引擎这一轮真会发的那份线形请求** `{model, messages, tools, …}`——唯一的原料与缓存前缀）, `total_message_count`, `compacted_message_count`（当前水位线）, `existing_summary`, `compacted`, **`usage_file` + `recent_usage`**（可选：该会话用量账本的路径与最近 50 行，见下） | `{messages: [{role, content, …}, …], covered_message_count: N}`；`null` = 用内置 compact |
| `system.relay.prompt.system` | `default`（核心构造的完整 system prompt） | 最终 system prompt 字符串（空串 = 明确不要系统提示词）；`null` = 用 `default` |
| `system.relay.tool.repair` | `point`, `agent_id`, `session_id`, `tool_call_id`, `tool_name`, `text`（核心算出的内置那句） | `{repaired:true, text}` ⇒ 用这句落库；其余一律用内置那句 |
| `system.relay.tool.probe` | `point`, `agent_id`, `session_id`, `tool_call_id` | `{found:true, text}` / `{found:false}`；缺布尔 `found` ⇒ 按**未接管**回内置探针 |
| `system.relay.llm.register` | `point`, `handle`, `agent_id`, `session_id`, `model`, `turn` | `{accepted, note}` ⇒ note 只进日志；**fire-and-forget，不卡请求本身** |
| `system.relay.compact.skip.reason` | `point`, `agent_id`, `session_id`, `reason`（内置那句，已先记账） | `{reason}` ⇒ 覆盖还账上那一条（保留分级位）；空/晚 ⇒ 内置那句原样在 |
| `system.relay.loop.run` | `point`, `agent_id`, `session_id`, `team_id`, `mode`, `model`, `message_count`, `messages`（引擎这一轮真会用的那份线形消息）, `tools`（与会话同一份工具表） | 接管：`{stream:true}` ⇒ 之后用 `station/stream` 推 `delta{kind:text\|thinking\|notice}` / `usage` / `done{finish_reason,usage}` / `error`；不接管：不回 / `{taken:false}` / 只回整包（均留下一行说明） |

> **压缩点位：原料只有"引擎真会发的那份"（2026-10 定稿）**。只要这个点位有订阅者，
> 核心就不再算切点、也不再下发落库全量原文——它把 `request`（预压缩态的线形请求：
> 系统提示词 + 已有压缩产物 + 水位线之后的原文 + `tools`）整份交出来，你回一份
> **新上下文** + `covered_message_count`。
>
> ```jsonc
> // 请求 payload（节选）：messages 是**引擎口径**（LlmMessage.toWire() 形状）
> {"system_prompt": "…", "total_message_count": 12, "compacted_message_count": 2,
>  "existing_summary": "…", "compacted": true,
>  "request": {"model": "…", "messages": [{"role": "system", "content": "…"}, …],
>              "tools": [{"type": "function", "function": {"name": "read", …}}],
>              "stream": false}}
>
> // 回包（reply.payload）：接管
> {"messages": [
>    {"role":"system","content":"…"},                       // 提示词槽位（内容会被核心刷新）
>    {"role":"system","content":"## 背景…## 轨迹…## 改动与产出文件…"},   // 摘要
>    {"role":"assistant","content":"","tool_calls":[…]},    // 例如伪造的 read / todo 调用
>    {"role":"tool","tool_call_id":"…","content":"…"},      // 与上面严格配对
>    …原样抄回的尾部（见下）…],
>  "covered_message_count": 12}
> // 回 null / 回包不合法 = 不接管，核心回退内置 compact
> ```
>
> **两种回包风格**（都合法，按你的切点在哪个坐标系里选）：
>
> - **只回摘要侧 + 给切点**：`covered = 保留窗口的起点`，尾部原文由核心按自己的口径
>   翻译追加——省事、工具卡配对与门控最准，但切点要用**原文下标**表达；
> - **把尾部也抄回来**（本仓库内置插件走这条）：切点在 **wire 坐标**里决定，尾部从
>   `request.messages[cut:]` **原样截取**（一个字都不改写），`covered = total_message_count`
>   ——不需要原文下标映射，助手工作与工具卡天然保真。
>
> 规矩与回退（全部 fail-open，越界绝不猜值）：
>
> - `covered_message_count` **必填**且落在 `[当前水位线, 原文总条数]`：核心据此决定下一轮
>   从原文第几条继续追加。缺失 / 非数字 / 越界 / `messages` 为空数组 / 某条消息还原不成
>   合法消息 ⇒ **整包按未接管处理**，回退内置 compact（会记一条可读日志）；
> - **首条 system 是"提示词槽位"**：核心**每一轮**都用最新提示词覆盖它的正文（首条不是
>   system 时由核心在最前补一条；`prompt.system` 明确回空串时删掉槽位）。所以不要把摘要
>   写在首条 system 上——摘要请放在槽位**之后**；
> - **结构硬约束**：抄回的尾部**不得以 `tool` 消息开头**（它的 `assistant(tool_calls)`
>   若留在摘要侧，端点会因"孤儿工具结果"直接 400）；同理，喂给总结模型的前缀若以
>   `assistant(tool_calls)` 收尾而缺配对结果也会 400——把总结指令作为**最后一条 user
>   消息**追加在末尾，可以顺手避开"以 assistant 收尾"那类形态；
> - 落库后你的列表就是**权威**（与内置路径互斥：你接管时清掉会话上的内置摘要，内置
>   compact 接手时清掉你的列表）。要么稳定接管、要么干脆别订；
> - 同一个点位**每轮压缩只问一次**，且此时这一轮生成是阻塞等你回包的（无静态超时，
>   靠心跳续期，见 §5.1）。
>
> **可选字段：`usage_file` + `recent_usage`（逐调用用量，2026-10-03）**
>
> 逐调用用量账本在**数据根**下的会话目录里（`data/<agent>/<session>/usage.jsonl`），
> 而插件**读不到数据根**（`fs.read` 只在你的工作空间作用域内）——所以核心在压缩载荷里
> 捎上"最近一批"：`usage_file` 是该会话账本的绝对路径（**只作排障**，你打不开它），
> `recent_usage` 是**解析后的行对象**（早 → 晚，最多 50 行；形状与 `usage.jsonl` 的行
> 完全一致）。它是个**滚动窗口**：每次压缩请求都重发同一批行，按行去重后再展示。
>
> ```jsonc
> // usage.jsonl 的一行（recent_usage 的元素同形）
> {"at": "2026-10-03T16:31:55.000000",   // ISO-8601 本机时区字符串
>  "source": "compact",                   // turn | compact | llm.call | plugin
>  "model": "…", "prompt_tokens": 1200, "cached_tokens": 900,  // cached 可为 null
>  "completion_tokens": 120, "estimated": false, "duration_ms": 1800}
> ```
>
> - `source` 四类：`turn` = 对话自己的跳；**`compact` = 内置压缩的那次总结**；
>   `llm.call` = 执行站一次性调用（你的总结调用就在其中）；`plugin` = `llm.handle`
>   被插件整体接管的一跳。
> - **未接线 / 账本还不存在 ⇒ 载荷里干脆没有这两个键**（"没有这条通路"与"确实还没
>   调用过"是两件事，别把缺键当成空数组）；读失败也只记一句日志，**不影响这次压缩**
>   （遥测 fail-open）。
> - 用量**不参与压缩决策**：它是给面板/日志看的账，不是水位线的依据。
>
> **缓存是长会话省钱的关键**：把 `request.messages` 整段当自己 `llm.call` 的 `messages`
> 前缀，**末尾只追加一条 user 指令**（含 "json" 字样），并把 `request.tools` 原样透传
> ——前缀与对话那一轮逐字一致，端点侧已持久化的缓存单元就能整段命中（DeepSeek 命中价
> 约为未命中的 1/10）。`request.messages` 与引擎**真会发出去的那份**逐字一致：它走的是
> 同一套历史翻译、工具结果门控与**预算硬裁**（`fitContextToBudget`）——这也是它必须由
> 引擎现拼、而不是给你落库原文的原因。三条注意：
>
> 1. **不要**用 `llm.call` 的 `system` 参数放指令：那会在最前面插一条 system 消息，
>    把整个前缀错位，缓存全丢；
> 2. `tools` 必须一起带（工具定义在聊天模板里渲染在 messages **之前**）；
> 3. 命中情况看回包 `usage.cached_tokens`（DeepSeek 的 `prompt_cache_hit_tokens` 已归一到
>    该字段）；**`response_format` 必须显式传 `"text"`**（`llm.call` 新增的参数，2026-10-04）
>    ——`llm.call` 缺省是站点硬设的 `{"type":"json_object"}`，而真机实测**端点为 JSON 模式
>    改写了提示词**（同一批 messages 恒定 **+22 token**，且改写落在 messages 区域之前/其中）
>    ⇒ 上面那条"逐字一致"的前缀**整段丢缓存**（对照：同一 492 token 前缀 plain 重发命中
>    `384/256`，**只加 `json_object` 掉到 `0`**；`tools` 并未被丢弃，+270 token 两种模式都在）。
>    ⚠️ 本节旧版写的"`response_format` 只是请求参数、**不影响**前缀匹配"**已被真机证伪**；
>    走 text 之后输出形状靠你在提示词里写死（非法 JSON 会让 `llm.call` 如实报错）。
>
> **参考实现**：内置插件「上下文压缩」（[`plugins/compact/compact_plugin.dart`](../plugins/compact/compact_plugin.dart)，
> 界面里一项开关，随包为 `tree_compact[.exe]`）——
> 摘要（背景 / 轨迹 / 改动产出文件）+ 必读文件（≤11 个、精确行范围，用伪造的 `read`
> 工具调用拼进上下文）+ todo 快照（`set_todo_list get`）；**尾部原样抄回**
> （`covered = total_message_count`），切点保留最近 `--keep-rounds` 轮 user，且在该区域
> 里最多保留 `--keep-tool-rounds`（默认 8）个工具轮（单轮超长工具轨迹因此压得动），
> 并且**切点永不落在 `tool` 消息上**（否则尾部以孤儿工具结果开头 = 端点 400）。
> 任何一步失败都回 `null`，而且**带一句可读原因**（回包可选键 `reason`）。
> 可直接读它当模板（`dart run plugins/compact/compact_plugin.dart --selftest`，193 条，
> 不需要真核心；编译：`dart run tool/build_plugins.dart --only compact`）。

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

**两个 id 别搞混**：`station/stream` 里的 `request_id` 要填**请求 `params` 里那个**
（如 `relay-1790863620-1`），不是 JSON-RPC 报文的 `id`——后者是"这条请求的回包"的关联键。
填错的后果是核心**关联不上任何流**（会记一条可读日志，但插件侧收不到任何反馈）。

**"回包后立刻推流"是安全的**：核心在处理完你的回包之后才登记这条流，而同一 tick 到达的
第一片增量会先暂存、登记后按键重放（顺序不乱）。不需要靠 sleep/节流兜底。

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

### 5.6 整轮接管：把 tool loop 交出去（`system.relay.loop.run`）

上面那些点位有一个共同边界：**编排仍在核心**——哪怕你用 `llm.handle` 接管了每一跳，
“这是第几跳、工具怎么排、什么时候算完”还是核心定的。要拿走整个循环形状（并行工具、
先反思一轮、自己定终止条件、按业务分支决定要不要再问模型），接这一条。

```jsonc
// 1) 订阅（中转点位：唯一订阅者）
{"jsonrpc":"2.0","id":1,"method":"station/subscribe","params":{
  "station_id":"system.relay.loop.run","replace":true}}

// 2) 核心会在每一轮开始处问你（上下文已经装配完）
{"method":"station/request","params":{"station_id":"system.relay.loop.run","request_id":"req-42",
 "payload":{"point":"system.relay.loop.run","agent_id":"agt_1","session_id":"ses_1",
   "team_id":"team-1","mode":"local","model":"…","message_count":12,
   "messages":[{"role":"user","content":"…"}],           // 引擎这一轮真会用的那份
   "tools":[{"name":"read","description":"…","parameters":{…}}]}}}   // 与会话同一份工具表

// 3) 接管信号与 llm.handle 同一个约定：回 stream:true
{"jsonrpc":"2.0","id":"<上面的 id>","result":{"stream":true}}

// 4) 文本、思考、提示、用量、收尾经 station/stream 推回同一个 request_id
{"method":"station/stream","params":{"request_id":"req-42","delta":{"kind":"text","text":"我查完了"}}}
{"method":"station/stream","params":{"request_id":"req-42","delta":{"kind":"notice","text":"先跑三个工具"}}}
{"method":"station/stream","params":{"request_id":"req-42","done":true,"finish_reason":"stop","usage":{"prompt_tokens":120,"completion_tokens":30}}}

// 5) 工具必须走 tool.call，并回带 run_id（就是那个 request_id）
{"method":"station/call","params":{"station_id":"system.execute.tool","command":"tool.call",
  "arguments":{"tool":"read","arguments":{"path":"a.txt"},"run_id":"req-42","call_id":"c1"}}}
```

四条必须写明白的纪律：

- **接管信号只有一个**：`{"stream": true}`。不回 / 回 `{"taken": false}` / 只回整包（没有
  `stream`）⇒ 核心走内置 loop，**每种都留下一行日志**说清为什么没生效。只收流式：取消与
  单方面收尾都靠这条流，一次性回整包等于让核心无法中途收尾。
- **写侧全部在核心**：落库、上行帧、用量账本、取消与判死都不交出去。你报的 `usage` 会被
  翻成与内置同一张表（`total_tokens` 有真值用真值；`cached_tokens=0` **不写键**；上限拿不到
  就**不写** `max_tokens`）。
- **工具走 `tool.call`**（同一条唯一入口）：所以 `tool.pre` / `tool.post` / `tool.timeout`、
  运行台账、`ask_user_question` 的提问审批**一个都不会绕过**；核心拿到这一次调用后会替你
  播 `tool_start` / `tool_end` 卡片。直接往流里推 `tool_call` 增量**不会**产生任何历史
  （只留一行日志）。
- **接管期间不开第二条写入口**：同一会话的 `agent.message` 会被拒（那会双写历史）。

收尾判据（与不变量 8 同一口径，**不拿时长杀长任务**）：核心下发 `station/cancel`（用户
停止）或插件心跳丢失 ⇒ 核心**单方面收尾**：关流、如实落一条取消结论（取消只发
`AgentDone(cancelled:true)`，**不发错误**）、并**拒收该 `run_id` 之后的 `tool.call`**（否则就
是“核心已收尾、插件还在写工作空间”的孤儿行为）。

想让别人看见你自己的事件？用收集站 `plugin.capability.define` 把它连字段表一起**申报**
出去（见 §3.1），别的插件就能在拓扑里发现它。

### 5.7 性能与超时

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
| `terminal.exec` | `command`，或 `hook_action`(`status`/`cancel`)+`task_id` | `{text, is_error}` | 执行命令（支持后台任务模式；`text` 是**给模型看的散文**） |
| `terminal.listRuns` | `session_id?`, `only_running?`, `limit?`（缺省 50，上限 500） | `{total, count, truncated, runs:[{task_id, command, session_id, running, exit_code, elapsed_seconds, started_at, log_relative, remote, remote_log, detached, cancelled, pid, fail_streak}]}` | 后台（hook）任务的**结构化行**（新的在前）；只看**目标 agent 自己**的；`exit_code`/`pid` 拿不到写 `null` 不省略键 |
| `terminal.stopRun` | `task_id` | `{task_id, requested, running, exit_code, reason?}` | 终止一条后台任务；**不保证杀得掉**（失联转的、远端没 pid 的都杀不掉），`requested=false` 必带 `reason`；命令本身仍算跑成（杀不掉 ≠ 没执行） |
| `terminal.log` | `task_id`, `tail_chars?`（能下调不能上调） | `{task_id, log_relative, remote_log, tail:true, tail_chars, text, has_content, reason?}` | 读日志**尾部**（可能在远端工作空间，所以走 `fs.read` 不够）；文件还不存在 ⇒ `has_content:false` + `reason` |
| `agent.message` | `message`/`content`, `session_id?` | `{…}` | 给某 agent 的会话发消息 |
| `agent.stop` | `agent_id?`, `cascade?`（缺省 true） | `{any_running, reason?, …}` | 停止（级联）生成 |
| `agent.compact` | `agent_id?`, `session_id?` | `{…}` | **发起上下文压缩** |
| `ui.push` | `slot_key`, `view?` | `{pushed, slot, slot_key, unregistered}` | 往消息流推一张卡片（§7） |
| `llm.call` | `messages?` 或 `prompt?`, `system?`, `model?`, `temperature?`, `max_tokens?`, `tools?`（OpenAI 工具声明**原样透传**，给压缩插件对齐对话前缀用）, `response_format?`（`"json_object"` 缺省 / `"text"` = **不发**该字段，为复用对话前缀缓存；也接受 `{"type": …}`） | 成功 `{ok, json, text, model, usage}`；失败 `{ok:false, error, error_kind?, text, text_length, truncated_suspect?}`（**失败也带模型正文原文**，见下表后说明） | **站点处缺省硬设 JSON 返回形式**的 LLM 调用，复用目标 agent 的模型（显式 `"text"` 时改用对话同形态，见 §「缓存」第 3 条） |
| `tool.call` | `tool`, `arguments?`, `relay?`（默认 false）, `run_id?` / `call_id?`（**只在整轮接管 `loop.run` 里用**，见 §5.6：`run_id` = 那一轮的 `request_id`） | `{tool, result, is_error, relayed}` | 执行**任意工具**（内置 / MCP / 插件工具同一入口）。带了 `run_id` 而它**不在册**（那一轮已收尾 / 属于别的插件）⇒ **这次调用被拒**，核心同时替你播上 `tool_start` / `tool_end` 卡片 |
| `session.rename` | `title`（必填）, `session_id?` | `{renamed, title, session_id}` | 会话重命名（前端即时刷新标题） |
| `ssh.reconnect` | `agent_id?` | `{ok, agent_id, stale?}` | 重建目标 agent 的远端（SSH）链路；与 REST /api/agents/{id}/ssh/reconnect、右栏文件面板「重连」按钮同一实现 |
| `plugin.list` | — | `{ok, plugins:[{plugin_id, name, enabled, running, lifecycle, generation, suspendable, health}]}` | 看全部插件（需能证明 `team_id`） |
| `plugin.state` | `plugin_id` | `{ok, …, lifecycle, generation, suspendable, snapshots[], kill_reason, last_error}` | 看一个插件的运行态（只读） |
| `plugin.restart` | `plugin_id`, `keep_state?`（缺省 true） | `{ok, resumed, dump_id, generation, lifecycle, reason}` | **热重启**（见 §6.5）；目标就是自己时核心**先应答再动手**，回包带 `deferred: true` |
| `plugin.suspend` | `plugin_id` | `{ok, suspended, dump_id, generation, note}` | 请求转储并记 `suspended`；**不代为退出**，也不拉起下一世 |
| `plugin.stateDump` | `payload`（JSON 对象） | `{ok, dump_id, generation, bytes, pool_entries, pool_bytes}` | 递一份可续跑状态快照进核心**内存池**（不落盘） |
| `plugin.stateFetch` | `dump_id?`（只能是自己上一世的那个） | 有：`{ok, has_snapshot:true, dump_id, payload, bytes}`；没：`{ok, has_snapshot:false, reason}` | 取回**上一世**的快照（一份只喂一世） |
| `station.list` | — | `{ok, team_id, count, stations:[{station_id, kind, kind_label, builtin, description, subscriber_count, subscribers, handled_by?, commands?, counts}]}` | **拓扑只看不动**：谁接管了哪个点位（中转点位看 `handled_by`）；列表是**投影**，不递 `readme`/公告板/`config`（需那些请对单一点位下 `station.state`，见 §6.9） |
| `station.state` | `station_id` 或 `point`（订阅时那套别名，如 `llm.handle`） | `{ok, team_id, station:{…整份 describe}}` | 看一个站点的当前读数（**订得到就问得到**）；内置点位全可见，插件自建站只对订阅者所在 team 可见 |
| `usage.query` | `session_id?`, `tail_bytes?`（≤ 2 MiB） | `{ok, agent_id, session_id, usage_file, count, skipped, calls:[{at,source,model,prompt_tokens,cached_tokens,completion_tokens,estimated,duration_ms}], summary:{calls,prompt_tokens,completion_tokens,cached_tokens,by_source}}` | 按会话取**逐调用用量账本**（计费/预算类插件的地基）；会话口径与其他命令一致（参数 → scope → 默认会话）且回包 **echo 生效值**；`estimated=true` 的行是本地估算，**不得当计费依据** |

**失败回包也可能带 `payload`**（2026-10-05 新增，**纯增量**）：`ok:false` 只表示"这次命令
没跑成"，不代表产出没有价值。典型是 `llm.call` 拿到了 200、模型正文却解析不出 JSON：
这时回包是 `{"ok":false, "error":"…", "payload":{"error_kind":"json_parse","text":"<模型正文原文>",
"text_length":9380,"truncated_suspect":false,"model":"…"}}`——**`text` 是已付费的那次产出**，
插件应当据此自愈（本地修 JSON / 发一次小的"判断 + 修 JSON"调用），而不是当场弃权。
> 为什么写进指南：这一跳真机踩空过——核心侧明明把原文放进了回包，插件却收到空 `payload`、
> 报"原文 0 字"，一次 448k prompt（≈100% 命中缓存）的总结就被整包丢掉（known-issues #31）。
> 老插件只读 `ok`/`error` 时行为**逐字不变**；写自愈逻辑时请读 `payload`。

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
这条当作事实，不要假装有沙箱，也不要指望核心拦你。

### 6.5 插件热重启：`suspend` + `plugin.stateDump` / `stateFetch`

目标很窄：**优雅转储 → 退出 → 新一世取回续跑**。全程不落磁盘、也不拿时长当判据。

要能被挂起，`plugins.yaml` 的条目必须显式声明（**缺省 = 不可挂起，热重启就冷启动**）：

```yaml
plugins:
  - id: my_plugin
    suspension: keep        # 只认 keep；留空 = 不可挂起
```

时序（你作为插件要做的事）：

1. 核心发 `suspend`（**这是本任务唯一新增的 method**）；
2. 你用 `station/command` 下 `plugin.stateDump`，`arguments.payload` 就是你要留下的状态，
   **等它的回包到了**再回 `suspend` 的 ack（`{ok:true, dumped:true}`）——顺序反了的话，
   核心只能靠"等一会儿"来碰运气，而它**不等也不判时长**；
3. 回完 ack 就可以退（核心收到 `shutdown` 后会等你，等多久都由你的心跳说话）；
4. 新一世的 `hello` 参数里会带 `resume_dump_id`（没快照时根本没这个键）；
5. 你下 `plugin.stateFetch` 取回它。核心只认"上一世"那一份，且一份只喂一世；
   拿不到就按冷启动继续（`has_snapshot:false` + `reason`），**这不是错误**。
   **核心没点名（hello 里没这个键）就不要去自己取一份**：`stateFetch` 是按 `pluginId`
   认"上一世"的（代际由核心算，不接受插件指定），而取回就是**消费**——多实例插件里
   先抢到的那一个，会让真正该续的那一世只拿得到 `has_snapshot:false`。

三条红线：

* **不落盘**：快照只在核心进程内存里，核心退了就没有。不要把会话事实唯一地寄存在
  插件状态里（消息与工具结果由核心落库在先）。
* **不要给 `plugin.stateDump` / `plugin.stateFetch` 申报 agent tool**：它们是生命周期
  原语，不是给模型使唤的能力（可申报的四条见 `PluginToolSurface.agentToolCommands`）。
* **不要指望时长**：没有任何"多少毫秒内必须转储完"的上限，也没有"慢了就杀"。反过来，
  装死也不划算——连续 N 拍（缺省 3×I）没有任何入站报文会被判失活，那时核心会收尸。

最小可运行参考实现：[`plugins/suspendable/suspendable_plugin.dart`](../plugins/suspendable/suspendable_plugin.dart)
（Dart，住插件仓；`dart run plugins/suspendable/suspendable_plugin.dart --selftest` 用假核心把
“两世”跑一遍）。转储与取回的管道（`suspend` 分支、`plugin.stateDump` / `plugin.stateFetch` 的
信封剥层）都在骨架 `plugins/_kit/plugin_kit.dart` 里，插件侧只交“这一世要留什么”。

### 6.6 重启窗口里对外保持正常状态（保活与暂存）

上面那套“转储→退出→取回”中间有几百毫秒你不在。这段时间**核心不会把失败扔给会话**：
指向你的站点请求会先进一个**有界暂存队列**，你新一世 `ready` 后按 **FIFO** 补发。

作为插件作者你需要知道四件事：

* **会补发，也会丢弃**：重放前逐条复查归属（四元组）与 `request_id` 是否已收尾，
  已取消/迟到的那条不递给你。所以**不要**把“收到同一条 `call_id` 两次”当异常。
* **每插件默认 32 条 + 全局字节上限**：溢出的那条**当场**按该点位既有的兜底口径
  处理（中转站就是放行原数据），不会排队到你回来。不订中转站的插件对这件事完全无感。
* **新一世必须重新 `station/subscribe`**：上一世那几份声明在你重新申报的**当场作废**
  （留着它 = 旧归属还能把请求递给你这个新归属的进程）。改了 `scope` 后忘了重报 =
  你以为能接管工具改写，实际站点上已经没人了；这也是“为什么不把旧声明一直挂着”的理由。
* **只有窗口内才暂存**：`stopped` / `failed` 是**不投递**（可读原因）而不是排队，
  否则会话会永远等一条不会被投递的请求。配置驱动的换一世（改了 `args`/`scope` 后对账）
  与热重启算**同一个窗口**。

面板与 REST 现在能看到两个相关读数：`lifecycle`（阶段）与 `buffered_station_requests`
（这个插件当前积压了几条）。广播点 `system.broadcast.plugin.state` 的载荷里也带
 `buffer`（全局水位）；订阅方式见 §3.1 与 §7.1。

### 6.7 agent tool 那一面：`plugin_hot_restart`（阶段 3）

“重启一个插件”已经是一个模型能使唤的动作了：内置插件 **`self_updater`**（框架自迭代插件，
随包二进制）经收集站 `plugin.tool.define` 申报**一个** tool：

| 参数 | 语义 |
|---|---|
| `action` | `list` / `state` / `restart` / `suspend`（四个问法对应四条执行站命令） |
| `plugin_id` | 目标插件；`list` 可省略。填自己的 id 就是“重启我自己”，这是**允许**的 |
| `keep_state` | `restart` 时是否尝试续跑（缺省 `true`；目标没声明 `suspension: keep` 就按冷启动，回包会写明） |
| `wait_ready` | `restart` 后再读一次 `plugin.state`，把新一世的阶段/代际附进结果（缺省 `true`；重启自己时无效） |

它自己不碰任何插件状态，只是把动作转成执行站 `plugin.*` 命令，所以下面这些**对所有插件都成立**：

* **身份只能由核心给你**：`tools/call` 的参数里有一个可选的 `scope`（本次调用的四元组），
  把它**原样**带回 `station/command` 的顶层参数。自己编一个 `team_id` 就是越权，
  而核心会拿目标 agent 的真实归属再核一遍，对不上就拒。没有可证明的归属 ⇒ 四条控制面命令
  全部被拒（fail-closed），而且工具回包会把这件事说破，不留一个“不知道为什么失败”。
* **快照两条不得做成 tool**（`plugin.stateDump` / `plugin.stateFetch`）：它们是插件自己
  生命周期的一部分，模型没有资格代它发言。需要它们的时候只有两个时刻：收到 `suspend`
  时（**先转储、等回包、再 ack**）与 `hello` 完成后（问一次“有没有我的快照”）。
* **每一次控制面动作都进审计**（谁 / 何时 / 目标 / 结论），一行一条；快照两条不记。
  自重启那一条记的是“已受理”，结论在紧随其后的“自重启收尾”行里。
* **“强制停止”只能由用户按**：`ApiPaths.pluginConfigRestart`
  （`POST /api/plugin/configs/{pluginId}/restart`）的 body `mode`
  可取 `cold`（缺省，不带 body ⇒ 与旧请求逐字一致）/ `hot` / `force_stop`，第三个值是全框架
  **唯一**能因为一个按钮而 `kill()` 的入口（核心自己从不因为时长杀插件）。

写自己的插件时能拿到的两个现成好处：声明 `suspension: keep` ⇒ 面板上的“热重启（保留状态）”
与 agent 的那条 tool 对你就都是“换个进程接着干”；而随包二进制都建议带一条 `--selftest`
（输出走 stderr、退出码 0 = 全部通过）：装机后的端到端验证读的是退出码，不是“面板有没有报错”。

### 6.8 发布仓库：插件管理只拉 release（阶段 5）

用户口径（2026-10-16 定稿）：**`plugins/` 仓里是插件源码，插件管理只拉 release**。
装机端只读 `raditree/tree-plugins` 的 **GitHub Release 资产**，不 `git clone` 源码：
源目录形状、构建产物在不在、谁负责编译，不该在用户机器上现场猜。

合同的原文在 [plugins/README.md](../plugins/README.md)；装机端的实现是
[plugin_downloader.dart](../packages/tree_core/lib/src/plugin/plugin_downloader.dart)，
**改了合同必须同时改那里的校验**（两边各说各话的结局是“面板列不出来”或“装上去起不来”）。

| 路由 | 做什么 | 失败时的形状 |
|---|---|---|
| `GET /api/plugin/release` | 读**本地缓存**的索引（一个 URL 都不碰，`online: false`） | 200 + `ok:false` + 可读原因 |
| `POST /api/plugin/release/refresh` | `releases/latest` → `plugin-index.json` → 缓存 | 200 + `ok:false` + 原因 + `cached`（上一次那份） |
| `POST /api/plugin/release/{pluginId}/install` | 资产进缓存 → 闸门 → 原子改名 → 写条目 + 热应用 | 400 + `detail`（那一次确实什么都没改） |

三个关键点（都是现场能复现的）：

* **索引 = 合同**：`schema: 1` 不认就整份拒（“不猜新字段的含义”），而 `plugins[]` 里的
  坏条目**只跳过自己**并把原因交出去（面板逐条显示“跳过：…”）。`target` / `asset` 必须是
  纯文件名，`bytes` 不符就**不缓存半截**，`command` 必须在 `files[].target` 里。
* **换文件先过闸门**：该插件的旧进程**已确认退出**才动 `plugins/`。核心不会为了换文件
  去杀一个正在干活的插件（强杀只有用户的「强制停止」那一条路，见 §6.7），也不按墙钟等：
  等的是“退出已确认”与“心跳判失活”两个事件。换不成 ⇒ 旧文件一字未动，原因原样递到面板。
* **来源标记只是展示**：装完写进 `plugins.yaml` 的 `source: release` / `repo_version`
  由 `PluginConfigStore` 当未知键原样保留，行为一律只读已知键；详情页据此回答
  “这一条是从哪里装的、装的是哪一版”。内置 id **不给覆盖**（内置项只走内置开关，
  否则两个开关会抢同一条目）。
* **也不给盖掉随包的插件源码**：`files[].target` 撞上 `BuiltinPluginCatalog.protectedFileNames()`
  （示例/压缩脚本、SSH 执行器与自迭代插件的二进制）就整条跳过 —— “撞 id”与“撞文件名”
  是两道不同的防线：后者不需要撞上内置 id 就能把 `sample_plugin.py` 覆盖掉，而现象是
  “示例插件突然起不来”，归因要翻到一份远端 JSON 里去。跳过发生在**列清单**时（面板当场
  说得出原因），不是等用户点了安装才失败。

发布一版（在 `tree-plugins` 仓根）：把 `plugin-index.json` 与索引里点到的每个文件
一起传成 release 的资产 —— `gh release create v0.1.0 release/plugin-index.json <各资产>`。
只传文件不改索引（或反之）会被判成“发布与索引不同版”，并给出这句原因。

### 6.9 控制面的“只看”层：拓扑、后台任务、用量与水位（阶段 6）

这一节把阶段 6 新增的四组读口放在一处，因为它们回答的都是同一类问题：
**动手之前先把现场看清楚**。全部只读，全部走执行站（不可订阅）。

- **`station.list` / `station.state`（拓扑）**：热重启一个插件前必须先能看见“谁接管了
  哪个点位”——接走 `relay.llm.handle` 的那个插件一停，整条 LLM 就回退内置实现；看不见
  就只能猜，而猜错的代价是停在正在干活的插件上。归属只有一条：**内置点位对任何 team
  可见**（它们是系统接口，不是任何人的私有数据），**插件自建站只对订阅者所在 team 可见**
  （别人的站里写着别人的 topic 与配置，连“它存在”都不该漏出去）；`team_id` 证明不了 ⇒
  整条命令拒（fail-closed）。`station.state` 认订阅时那套别名（`llm.handle`）：“订得到、
  问不到”是自相矛盾的面。接管权易手**仍然只走 `station/subscribe`**，这一族里没开第二条路。
- **`terminal.listRuns` / `stopRun` / `log`（后台任务）**：台账与任务表早就跨重启存活，
  `hook_action=status` 也早就存在——但那回的是**写给模型看的散文**；转发/看护类插件要的是
  行。三条共同约束：只看/只动**目标 agent 自己**的任务（任务表是全进程一份，不按 agent
  过滤就等于泄别人跑过什么命令）；拿不到的读数写 `null` **不省略键**；上限能下调不能上调。
- **`usage.query`（用量账本）**：存量的读取范围问题——账本在数据根下的会话目录，插件的
  `fs.read` 只在工作空间作用域内，永远够不到。核心只把已有的容错读取递出去：只读一个会话、
  只读尾部、行形状与 `UsageCall.toJson()` 逐字一致（字段表只有一处出处），聚合也只在核心
  算一份（算两份就与面板上那份漂）。
- **水位（`plugin_status` 帧的两个新键）**：快照池与重启暂存队列都是“超限就丢”的有界结构，
  光有“丢”这个动作不够——帧里多 `state_pool`（entries/bytes/denied + 三条上限）与
  `restart_buffer`（本插件在队条数 + 上限 + `overflow`/`dropped`/`replayed`）。两种“没了”
  必须分得开：`overflow` = 超限当场拒收（背压），`dropped` = 重启没成/插件下线后主动弃。
  旧前端看不到这些键也不受影响（**只增键**与 `lifecycle` 同一条纪律）。
- **并发形状的上界**：判活取消了时长硬上限（只认心跳丢失），所以“一个迟迟不回包的订阅者”
  可以无限挂着等待。站点因此给在途等待加了一个数量上界（每站点缺省 64）：超限**当场**回
  failed 并计 `overload_skipped`，**不排队**（排队只是把无界改成延后，热点点位上一样堆得
  起来），走的仍是与“心跳丢失”同一条 fail-open 路。插件侧看到的仍是“这次没接管”。

> 阶段 6 的 A 级点位批**已全部接完**（中转站 `tool.repair` / `tool.probe` / `llm.register` /
> `compact.skip.reason`，与收集站 `plugin.capability.define`）。接它们的纪律不变：表项 +
> 常量 + 进 `StationHubIds.all` + readme 四段式 + 投递口 + 派生用例计数；**接管只能改文案或
> 附加观测，不能替换判据**（落库、可关闭性、分级位这三样永远在核心手里）。

---

## 7. 广播站与前端 UI

### 7.1 广播（单向通知）

订阅 `system.broadcast`（通用主题）或 `system.broadcast.tool.pre|post`（工具调用事件）。
工具广播**不等回包**：核心不等你应答，投递失败只进公告板与计数，不影响工具调用。

**轮次类广播与工具广播是两套投递纪律**（阶段 6）：`turn.done` / `turn.cancelled` /
`turn.error` / `ask.paused` / `config.changed` 这五个点位**订了才投**（没订阅者就一条都不发）；
而 `agent.tool_call` 这类旧事件仍走“命中 scope 就推”的 legacy 事件流。分流判据只有一张表
（`PluginBus._agentEventPoints`）：**命中点位的不再走 legacy**，否则一个事件两种形状会同时
漂在插件侧。广播的 topic 由点位 id 去掉 `system.broadcast.` 前缀**推导**，不另记一张表。
载荷纪律：**证明不了归属就不投**（运行期四元组拼不出合法 scope ⇒ fail-closed，只记一行日志），
投递失败也**只记日志**——插件侧的问题绝不能拖垮生成那一轮。

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
**广播要回一条 `{"reply":{"payload":null}}`**：核心的 `publish()` 仍会对每个订阅者等回包
（调用方不等，所以拖不慢工具调用），但**不回会被记为未响应/投递失败**并出现在计数与日志里——
广播不是"可以不回"，而是"回了也没人用"。回 `null` 表示"收到，无内容"。

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
| `activity` | **左栏整页**：左侧活动栏的一个图标项 + 左栏里的一整页内容（同一个槽位两处呈现） | 点击回调走 `plugin_ui_action` 上行帧 |
| `panel` | 右栏 Tab | 声明后才出现 |
| `status` | 状态条 | 单行 |
| `card` | 消息流内联卡片 | **必须先声明**；未声明的 `slot_key` 会被前端静默丢弃（这是最常见的"我推了但看不到"） |

视图是**受限控件集的 JSON**（`column` / `row` / `text` / `button` / `divider` / `image` /
`list` 等，风格 `body|title|caption|mono`）：不执行任何插件 JS。

`ui.push`（执行站命令）适合"随对话出现"的卡片：`slot_key` 必须是已声明的 `card` 槽位；
`view` 省略 = 注销该卡片。

**面板交互的线上形状**（前端 → 核心 → 插件）—— 两段形状**不一样**，判错就是"按钮点了没反应"：

```jsonc
// ① 前端 → 核心（WS 上行帧）
{"type":"plugin_ui_action","data":{
  "plugin_id":"demo","team_id":"team_1","agent_id":"agent_1","session_id":"session_default",
  "slot_key":"demo.activity.1","action_id":"refresh","payload":{}}}

// ② 核心 → 插件（**event 通知**，与 agent.tool_call 同一范式）
{"jsonrpc":"2.0","method":"event","params":{
  "event":"plugin_ui_action",          // ← 判据在这个键上，不是 method
  "plugin_id":"demo","team_id":"team_1","agent_id":"agent_1","session_id":"session_default",
  "slot_key":"demo.activity.1","action_id":"refresh","payload":{}}}
```

- **判据必须写在 `params["event"]` 上**：`if params.get("event") == "plugin_ui_action"`。
  写成 `if method == "plugin_ui_action"` 永远不命中（核心的 `method` 一律是 `event`），
  表现就是"面板按钮点了没反应"，且**没有任何报错**——最容易浪费半天的坑。
- `payload` 的语义由**插件**解释（核心只透传）：按钮点击 = 按钮声明的 `payload`；
  表单提交 = `submit.payload` 与各字段值合并（**字段值覆盖同名键**）。
- 动作是**单向通知**：核心不解释语义、也不回执。插件要"反馈"只能自己再推一帧
  `ui/update`（或 `log`）；操作失败**务必**写进 `log` 通知，否则用户在界面上看不到任何反应。
- 插件不在线时核心会**显式回一帧 `error` 并记日志**（不静默丢弃）；未知 `action_id`
  由插件自己决定怎么处理（示例插件记一条 `log` 通知 + 忽略）。


**槽位生命周期**（2026-10-02 起的前端口径）：槽位跟着"插件是否在运行"走——

- 插件**停用 / 条目被删除 / 启动失败 / 进程退出**（核心推 `plugin_status(disabled)`）⇒ 前端**立即注销**
  它声明的全部槽位：卡片与面板一起消失（不留在界面上当僵尸）；
- 前端**断连**时清空槽位注册表（离线期间核心不会重放已停用插件的声明），重连后按核心缓存的**当前态**重建；
- 因此**重新启用 / 重启后要重新发 `ui/manifest` 与 `ui.push`**——在插件启动时发一次即可（本来就是推荐做法），
  界面会自动回来；不要指望"插件不跑了界面还留着"。
- **心跳丢失（degraded）不算下线**：进程还活着、槽位保留（恢复后照旧），所以别把 `ping` 当负担。

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
    description: 把工具公告转发给队友   # 可选：插件介绍（「插件详情页」正文读这里）
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
- `description` 是**插件介绍**：界面上的「编辑」弹窗可以直接写它（落盘这份 yaml）。
  面板的**插件详情页**正文读的就是这里——刻意**不取**协议握手里的说明：`initialize`
  只在插件连上之后才有，而**启动失败的插件最需要介绍**。空串不写这一键（不给全表
  添一行噪声）。
- 界面上的「启用」开关会写这份文件；改动在核心下次启动或热应用时生效。
- 插件脚本路径：相对路径按**核心进程的工作目录**解析（桌面端是 `plugins/`）。

---

## 10. 调试与测试

| 手段 | 怎么做 |
|---|---|
| 插件日志 | `log` 通知（`{"method":"log","params":{"level":"info","message":"…"}}`）或直接写 stderr |
| 面板 | 设置 → 插件开发：「插件」段看实例状态与订阅，**「站点」段看每个点位**的订阅者/计数（`requests` / `responded` / `timeout` / `no_subscriber` 等）。两类卡片**都能点进详情页**：插件页全程只读（介绍 / 基本信息 / 内置运行时 / 运行态 / 提供的工具 / 它建的与它订阅的站）；站点页重新 GET 一次真值，可改「可订阅插件数量」、订阅者的**禁用开关**、以及 `config` 里的自定义项（增 / 删 / 改） |
| 骨架探针 | 先用 §1 的最小骨架跑通 `hello` / `ping` / `tools/list`，再加站点订阅；不要一上来就写全功能 |
| 不用真核心自测 | 写一个假核心：按 §2 的报文往你的 stdin 写，读你的 stdout 断言（示例仓库里的 `sample_plugin.py --selftest` 就是这么做的） |
| 常见坑 | ① stdout 混入日志 ⇒ 解析失败；② 单线程顺序处理 ⇒ 自锁 + 心跳丢失；③ 忘了 `ui/manifest` 声明 `card` 槽位 ⇒ 推了看不到；④ 订阅写了错的 `mode_key` ⇒ 收不到消息；⑤ 流式接管忘了 `done` ⇒ 该轮一直等（最终被取消/心跳判死）；⑥ **面板按钮判据写成 `method == "plugin_ui_action"`** ⇒ 永远不命中，表现为"点了没反应"（真实形状见 §7.2，判据在 `params.event` 上） |

---

## 11. 从旧核心迁移（点位化之前）

| 旧 | 新 | 迁移动作 |
|---|---|---|
| `system.relay`（工具前/后共用一个实例） | `system.relay.tool.pre` + `.tool.post` | 核心**自动迁移**落盘订阅（旧订阅复制到两个点位、含更早一代 `system.relay@team@mode`，行为等价）；插件代码不用改：`{"station":"relay"}` 现在一次订两个点位 |
| `system.execute`（九条命令共用一个实例） | `system.execute.fs/terminal/agent/ui/llm/tool/session` | 插件无感（命令名不变，核心按命令路由） |
| 无流式接管 | `station/stream` + `station/cancel` | 想用就用；不用则一次 `reply` 仍可 |
| `point` 参数不存在 | `station/subscribe` 支持 `point` | 可选：用别名代替完整 id |
| 点位化前"广播站只有一个" | 通用主题 + `tool.pre` / `tool.post` | 广播站**没有**"不带 point = 全订"的糖（`{"station":"broadcast"}` 仍是通用主题）；要工具广播就订两个点位 |

---

## 12. 完整示例

- [`plugins/minimal/minimal_plugin.dart`](../plugins/minimal/minimal_plugin.dart)：**最小骨架（Dart，已迁插件仓）**
  （hello / ping / tools/list / 一个工具；读循环、并发、异常收敛都在 `plugins/_kit/plugin_kit.dart`），
  `dart run plugins/minimal/minimal_plugin.dart --selftest` 用假核心自检。
  编译成成品：`dart run tool/build_plugins.dart --only minimal`。
- [`plugins/suspendable/suspendable_plugin.dart`](../plugins/suspendable/suspendable_plugin.dart)：**热重启参考实现（Dart）**
  ——“先转储等回包、再 ack、退；新一世 `hello` 拿 `resume_dump_id` 主动取回”这条时序的活文档，
  工具 `era` 回一个**来自快照本身**的世数（自检 16 条：冷启动不下取回、dump 先于 ack、
  转储未回包时 ack 一句都不发、慢转储在途心跳照答、取不到按冷启动且留一行）。
  编译：`dart run tool/build_plugins.dart --only suspendable`。
- [`plugins/terminal_probe/terminal_probe_plugin.dart`](../plugins/terminal_probe/terminal_probe_plugin.dart)：**terminal 三段通路的探针（Dart）**
  ——`terminal.exec` + `hook: true` 起长任务、`hook_action=status` 逐拍量、`system.tool.timeout` 广播只记不取消；
  拿不到句柄就如实**降级**成"通路存活"（每一拍 echo），并把降级原因写进时间线。它还交了左栏 `activity`
  面板的完整形状（`ui/manifest` 一次 + `ui/update` 整块替换 + 按钮动作从 `params.event` 判）。
  自检 77 条（走**真帧面**：订阅、面板声明、执行站命令都在帧上断言）。编译：`--only terminal_probe`。
- [`examples/plugins/sample_plugin.py`](../examples/plugins/sample_plugin.py)：全功能参考实现
  ——工具申报、活动栏面板、消息流卡片、工具前/后中转改写、**LLM 流式接管**（`--relay-llm`）、
  `prompt.system` 改写（`--relay-prompt`）、`llm.call` / `tool.call` / `session.rename`
  三条新命令（`--llm-call` / `--tool-call` / `--rename-session`）、工具广播订阅（`--watch-tools`）、
  自建站点（`--self-station`）、心跳与 `--selftest`。
- [`plugins/compact/compact_plugin.dart`](../plugins/compact/compact_plugin.dart)：**内置插件
  「上下文压缩」（Dart，成品 `tree_compact[.exe]`）**——`system.relay.context.compact` 的完整实现
  （摘要 + 必读文件 + todo 快照，编排 `llm.call` / `fs.read` / `tool.call`），也是"压缩点位怎么接"
  与"前缀缓存三条件怎么满"的活文档（tools 原样透传 / 不用 `llm.call` 的 `system` /
  `response_format` 显式 `text`，少一条就整段不命中）。它还交了另一份完整面：**不接管必须带原因**
  （回包可选键 `reason` + 面板 + 日志三处落点）、**总结回包坏了的三段抢救**（本地结构修复 →
  一次“判完整性 + 修 json”小调用 → 放弃）、**用量从载荷里的 `recent_usage` 并入面板**（插件读不到
  数据根，按整行内容去重）。自检 193 条（同样走真帧面）。编译：`--only compact`。
- [`examples/plugins/compact_plugin.py`](../examples/plugins/compact_plugin.py)：上面那份的
  **Python 旧版**，暂时还住在示例目录里：两份真进程用例（`compact_plugin_e2e_test.dart` /
  `compact_panel_ui_test.dart`）目前还拿它拼命令，改跑 Dart 产物后一并删除。
- [packages/tree_self_updater](../packages/tree_self_updater/README.md)：**binary 型内置插件**的参考实现
  （框架自迭代插件）：自带协议常量表、两条申报路共用同一份参数表、`suspend` 里「先转储等回包再 ack」，
  带 `--selftest`（退出码 0 = 全绿）。它不是脚本，但是“一个插件能做到什么”的最小可读完整面（见 §6.7）。
- 这些脚本都**不依赖第三方库**、都能被绝对路径启动（不依赖 cwd）。
- 尚未提供可运行示例的点位：`system.relay.llm.request`（投入前改写）——口径见 §5.3，
  接法与其他中转点位完全一致；`system.relay.loop.run`（**整轮接管**）——口径与帧序列见
  §5.6，没示例是因为接管者得**自带一份模型调用**（它才是循环的主人）：`sample_plugin.py`
  里那套 `--relay-llm` 的流式写法就是它的下半身，把“每跳被问一次”换成“每轮被问一次”
  并把工具改成 `tool.call` + `run_id` 即成。要看逐帧形状，读测试夹具
  [`test/fixtures/fake_llm_plugin.dart`](../packages/tree_core/test/fixtures/fake_llm_plugin.dart)
  的 `--loop-mode`（`stream` / `tool` / `late-tool` / `decline` / `whole` 五种回法，
  端到端用例在 `test/plugin_loop_relay_test.dart`）。
- 运行：Dart 那批先 `dart run tool/build_plugins.dart` 产出到 `build/plugins/`，再把成品 exe 的路径
  写进 `plugins.yaml`（或直接在「设置 → 插件开发」里启用）；Python 脚本拷到桌面端的 `plugins/`
  目录（或直接写绝对路径）同理。两者都能在面板与消息流里看到它。

有疑问先看两条不变量：**"空 = 通配"只适用于订阅声明**；**任何异常都 fail-open，
绝不阻塞生成**。其余细节都能从这两条推出来。
