# Agent loop 三线结构侦察与语义对齐（AC-1）

> **状态**：2026-11-08 侦察完成，**只落档，不改代码**。
> **对象**：`plugins/tree.agent` 插件内逻辑（核心不参与领域语义）。
> **输入**：2026-11-08 的三线规格——Agent 实例维护 / 消息机 / Agent loop。
> **结论**：现实现是「`ConversationService` 会话适配 + `LlmAgentEngine` 上下文装配 + `LlmSession` 工具循环」
> 三层近似，**不是**规格里的三条独立异步线；直接照规格改会碰四条现有硬约束：
> 工具调用不被插话打断、系统提示词前缀缓存、同 agent 多会话并行、消息零丢失。
> 本文给出逐项对照、建议语义、冲突点与切片；**冲突点未拍板前不动代码**。

**拍板记录（2026-11-08，全部定稿）**：
C1 采用「一次 LLM 响应 + 其整个工具批」的迭代边界；C2 终止只作用于 `task`、`tip` 永不终止；
C3 队列按 session 分区、保留跨会话并行；C4 `system_message` 存 `role=system`、请求发 `LlmRole.system`；
C5 本期保留插件内 LLM 模块并抽 `LlmInvoker`；C6-a 系统提示词按 `agentId|sessionId` 钉住、
C6-b 工具表按会话快照并按四类信号失效；C7 记忆 MVP = `.self/memory.md` + 压缩摘要；
C8 stop 作废可运行 task、tip 保留；C9 仅显式 `error` fail-closed、其余 fail-open；
C10 保持 `idle/working` 两态、`asking` 为附加标记；C11 `direct` 优先、`queue` 逐条排空；
C12 历史加 `source_message_id` 等加法键。
**无剩余待拍板项；AC-1~AC-6 均无阻塞。**

---

## 1. 结论先行

1. **Agent 实例不存在**：没有按 agent 持有的运行时对象。模型、工作区、历史、名册、工具表都是
   每轮现取；`ConversationService` 只按 `agentId|sessionId` 持有 `_running` / `_chains` 两张表。
2. **消息机不存在**：没有统一的 `type / subtype / inject_mode / source / message_id` 信封；
   用户消息、团队消息、hook 唤醒、临时员工完成报告各走一条函数，最后都落到
   「落库 + 打断同会话在途轮 + 入队生成」。
3. **当前是「插话打断」，不是「注入不打断」**：新消息到达即置软取消，流式立刻停；
   工具批中途到达会在**下一个工具之前**收敛，**剩余工具被跳过**（`llm_session.dart:593-597`）。
   这与规格的「不打断当前生成，本次生成后立即终止」冲突，是本期最大的行为差异。
4. **中转站三步都不在插件里**：`system.relay.prompt.system` / `llm.handle` / `llm.request` / `loop.run`
   目前由核心接线并反向调用插件；插件自身没有订阅任何中转站，也没有
   「后置处理中转站」「请求体自动修复中转站」「`error / error_reason` 回包契约」。
5. **LLM 调用不是「LLM 插件」**：`LlmSession` 直接经 `HttpSseTransport` 发 HTTP/SSE；
   插件仓没有 `llm` 插件。规格里的「调用 LLM 插件」需要单独拍板边界。
6. **消息队列不落档**：`_chains` 是内存 `Future` 链，`_epoch` 只在 stop 时作废旧代次；
   插件退出/被杀后，尚未开始的消息只剩会话历史，没有「待处理」状态可恢复。
7. **状态与站点面不完整**：`agent_events` 广播站已有 `agent.tool_call` / `agent.turn.*` /
   `agent.ask.paused`，但没有「每个 Agent 的活动状态 + 相关 ID」主题；
   `agent_tools` 执行站有 `message.run`（以某 agent 身份发团队消息），但没有
   「其他插件给某 Agent 发消息」的命令。

---

## 2. 现状：三条线分别落在哪

### 2.1 第一条线：Agent 实例维护

**现状没有实例对象，只有分散的读取点。**

| 维度 | 现在由谁提供 | 位置 | 事实 / 缺口 |
| --- | --- | --- | --- |
| 生命周期 | 每个数据根一个 `AgentRuntime` | `lib/src/runtime/agent_runtime.dart:217-237` | 不是每个 agent 一个实例；agent 级状态在 `ConversationService` 的两张 map 里 |
| 模型信息 | `CoreAgent.modelId` + `CoreSettings.model()` + 成员覆盖 | `conversation_service.dart:1663-1702`、`llm_agent_engine.dart:177-204` | 每轮解析一次，无实例级缓存 |
| 记忆信息 | **没有** | — | `.self/memory.md` 只在内置 spec 文案里被要求「写入」，当前提示词装配不读取它 |
| 工作区 | `workspaceDir` / `ssh` / 团队共享工作目录，按需解析 | `workspace_prompt.dart:54-104`、`agent_runtime.dart:1297+` | 懒解析；团队/SSH 变化时下一轮自然生效，没有「实例绑定」概念 |
| 会话历史 | `FileTreeStore` 读穿 + Sembast 双 store | `store/file_store.dart`、`store/conversation_db.dart:14-24` | 每轮从存储重读；不是实例持有的历史游标 |
| 团队名册 | `teammates.dart` / `TeamService` 现算 | `lib/src/teammates.dart`、`team/team_service.dart` | 无快照；名册变化下一轮自然生效 |
| 可用工具 | `StationToolRunner.specsFor` | `tool/station_tool_runner.dart:43-44` | 每次 `engine.run` 取一次，整轮复用；贡献工具在发消息时刷新（`agent_runtime.dart:451`、`:1279-1295`），无失效信号 |
| 活动状态 | `_running` / `isRunning()` 推导 | `conversation_service.dart:218-259` | 只活在内存；跨重启丢失；没有显式状态机 |

**结论**：目标里的「Agent 实例」应当是一个**缓存 + 状态持有者**，不是第二份事实源。
存储仍是唯一真值；实例只负责快照、失效信号、状态机与队列，避免双写。

### 2.2 第二条线：消息机

**现状是「多入口 + 一条落库/打断/入队路径」。**

| 入站路径 | 现在行为 | 位置 | 与规格的差 |
| --- | --- | --- | --- |
| UI 发消息 | REST → `sendMessage` → `handleUserMessage`：落库 `role=user`，打断同会话在途轮，`_enqueue` 一轮 | `agent_runtime.dart:445-479`、`conversation_service.dart:265-307` | 无 `type/subtype/inject_mode/message_id/source/destination`；立即打断 |
| 团队消息 | `message` 工具 → `TeamMessageDispatcher` → `conversation.deliver`：落库 `role=user` 加 `[来自 X]`，打断，入队 | `team/message_dispatcher.dart:642-743`、`conversation_service.dart:356-389` | 无信封；靠文本前缀表达发送者 |
| 临时员工任务 / 完成报告 | `notice` / `subagent_task` / `subagent_report` → `wake`：落库后唤醒一轮 | `conversation_service.dart:442-528` | 复用 `notice`，没有 `type/subtype` |
| terminal hook 完成 | `TerminalHookManager.wake` → `conversation.wake` | `agent_runtime.dart:139-148` | 同上 |
| 提问作答 | `QuestionBroker.answer`，作为工具结果回灌 | `agent/question_broker.dart`、`conversation_service.dart:398-405` | 不是消息；规格里也不应算消息 |
| 其他插件发消息 | **没有**「发给某 agent」的入口；只有 `agent_tools` 的 `message.run`（以某 agent 身份走团队消息） | `station/agent_tools.dart:8-17`、`agent_runtime.dart:694-696` | 缺执行站命令 |
| 系统消息 | 没有入站路径；`AgentNotice` 是 **`llm_hidden` 的 UI 提示**，不进模型上下文 | `agent/agent_engine.dart:82-90`、`conversation_service.dart:1055-1065` | 不要把 `AgentNotice` 当成规格里的 `system_message` |

**队列现状**：

- `_chains[agentId|sessionId]`：同一会话串行、不同会话并行（`conversation_service.dart:217-226`、`1593-1627`）。
- `_epoch[agentId]`：`stop` 时 +1，旧代次排队任务直接丢弃（`conversation_service.dart:229`、`325-348`）。
- 排队任务**只活在内存**；插件退出即丢。`droppedQueuedCount` 只是计数。
- 没有任何 `direct` / `queue` 区分；所有消息都按「尽快打断 + 下一轮」处理。

### 2.3 第三条线：Agent loop

**现状分两层**：`ConversationService._runTurn` 管「一轮」的落库/帧/状态，
`LlmAgentEngine.run` 装配上下文，`LlmSession.run` 跑工具循环。

| 规格步骤 | 现实现 | 位置 | 差 |
| --- | --- | --- | --- |
| 前置：无系统提示词快照 → 构建 | `_ensureSystemPromptPinned`，按 `agentId\|sessionId` 钉住并落库 | `conversation_service.dart:1705-1784` | 已有；键是会话级，不是 agent 级（见 §4 C6） |
| 前置：无可用工具列表快照 → 构建 | `toolRunner.specsFor` 每次 `engine.run` 取一次 | `llm_agent_engine.dart:237-242` | 没有跨轮快照与失效信号 |
| 前置：队列不为空 → 注入 | 无 | — | 缺 |
| 0 队列不为空 → direct 注入 | 无；消息到达即打断 | `conversation_service.dart:557-574` | 缺；且当前行为相反 |
| 1 上下文超限 → 压缩 | 每跳 `_compactBeforeTurn(force:false)`；端点报超限再强制一次 | `llm_session.dart:328-331`、`:471-490` | 等价 |
| 2 拼接完整请求 | `LlmRequest(model, messages, tools, ...)` | `llm_session.dart:332-339` | 等价 |
| 3 前置处理中转站 | 无；核心的 `llmTurnHandler` 是「整跳接管」，`llmRequestRewriter` 是「投入前改写」 | `llm_session.dart:340-375` | 无 `error / error_reason` 契约；无「注入 tip」通道 |
| 4 请求体自动修复中转站 | 无中转站；内部有截断参数修复、工具结果补写、历史配对规范化 | `llm_session.dart:509-534`、`llm_agent_engine.dart:910-942`、`:626-900` | 能力有，但不是可订阅点位，也不可替换 |
| 5 调用 LLM 插件 | `transport.stream(request)`，直接 HTTP/SSE | `llm_session.dart:394-399`、`llm/llm_transport.dart` | 没有 LLM 插件边界 |
| 6 后置处理中转站 | 无；只有核心内置 `system.relay.tool.post` 改**工具结果** | — | 缺「对 thinking/content/tool 整体后处理」 |
| 7 串行执行工具 | `for (final call in calls)` 串行 | `llm_session.dart:593-655` | 等价 |
| 8 工具结果注入上下文 | `inFlight.add(LlmMessage.toolResult(...))` | `llm_session.dart:648-654` | 等价 |
| 9 工具调用为空 → 结束循环 | `if (calls.isEmpty) yield AgentDone(); return;` | `llm_session.dart:574-577` | 有；状态更新靠上层帧 |

**额外已有、规格未列但必须保留的步骤**：usage 记账与 `token_scale` 学习、重试提示、
请求活性看护、上下文超限重试、工具结果门控、截断修复提示词、取消/硬取消双信号。
这些属于基础设施，不应被「三线重构」误删。

---

## 3. 语义对齐（建议口径）

### 3.1 消息信封

建议统一为：

```jsonc
{
  "message_id": "msg_...",              // 幂等键；必填（UI 可由前端生成，插件必须带）
  "type": "system_message",             // system_message | common_message
  "subtype": "task",                    // tip | task
  "inject_mode": "direct",              // direct | queue；缺省 direct
  "source": {
    "team_id": "inner",                 // 特殊来源固定 inner；真实团队用 team id
    "agent_id": "plugin_tree.agent",    // user | system | plugin_<plugin_id> | agt_...
    "session_id": "main"                // 特殊来源固定 main；真实 agent 用真实会话
  },
  "target": {
    "team_id": "agt_...",               // 目标 agent 的真实归属
    "agent_id": "agt_...",              // 必须是真实 agent；不接受特殊来源 id
    "session_id": "session_default"     // 目标会话；缺省由消息机解析
  },
  "content": "文本",                    // 与现有 CoreMessage.content 同口径
  "attachments": [ /* 现有附件数组 */ ],
  "created_at": 0,
  "meta": {}
}
```

对齐规则：

- `content` 沿用现有「字符串 + 附件数组」，不引入 content block；附件路径语义不变。
- `message_id` 必须能作为历史去重键。建议 `CoreMessage.id = message_id`（仅入站消息；
  工具/思考段仍用自己生成的 id），或在 `CoreMessage` 增加 `source_message_id`；见 §4 C12。
- `type` / `subtype` / `inject_mode` 由**发起者**指定；缺省 `inject_mode=direct`。
- Agent 自身的 `message` 工具只允许 `type=common_message` + `subtype=task`；
  `system_message`、`tip`、特殊来源目标一律拒绝。
- 目标必须是真实 agent；`user` / `system` / `plugin_*` / `inner` 只能作为来源，
  不能作为 `target.agent_id`。团队名册本就不含这些虚拟身份，`message` 工具因此天然看不到。

### 3.2 通道与落库

| type | LLM 角色 | 是否进上下文 | 落库 | 说明 |
| --- | --- | --- | --- | --- |
| `system_message` | `system` | 是 | 是（建议 `role=system`） | 与钉住的系统提示词**分开**，按到达顺序插在 system 槽位之后；不要改钉住字节 |
| `common_message` | `user` | 是 | 是（`role=user`） | 现有用户/团队/hook 提示都归这里 |
| `AgentNotice`（现状） | 不进 | **否** | 是（`llm_hidden=true`） | 只给人看的过程提示；**不属于**本规格的消息机 |

**关键区分**：`AgentNotice`（重试进度、错误可见文案、停止提示）不是 `system_message`。
前者是 UI 提示，后者是模型上下文里的 system 通道。现实现把二者都叫 notice，重构时必须拆开。

### 3.3 subtype / inject_mode 矩阵

| 状态 | `tip` | `task` |
| --- | --- | --- |
| idle | 注入上下文；**不启动 loop**；保持 idle | 注入上下文；置 working；启动 loop |
| working，`direct` | 在下一个可插入点注入；**不动 loop** | 在下一个可插入点注入；按 §4 C1 的边界终止当前 loop，随后由消息机启动新 loop |
| working，`queue` | 等当前 loop 结束后注入；不产生 LLM 调用；继续排空队列 | 等当前 loop 结束后注入；单独跑一轮 loop |

「可插入点」建议定义为：**每次 LLM 请求之前**（即上一跳的工具结果全部落地之后），
以及**loop 开始之前**。流式生成中、工具执行中都不是插入点。

### 3.4 特殊来源

| 来源 | `team_id` | `agent_id` | `session_id` | 方向 | 说明 |
| --- | --- | --- | --- | --- | --- |
| 内部/系统 | `inner` | `system` | `main` | 单向 → agent | 系统提示、编排插件注入的上下文 |
| 用户 | `inner` | `user` | `main` | 单向 → agent | 唯一回程是 `ask_user_question`，不是 `message` |
| 其他插件 | `inner` | `plugin_<plugin_id>` | `main` | 单向 → agent | 插件 id 保留点号，例如 `plugin_tree.agent` |

- 这些是**虚拟来源**，不建议为它们建完整 Agent 实例（没有模型/工作区/loop）。
  「也作为 Agent 处理」落在**统一身份与路由**上，而不是让它们跑 loop。
- `inner` / `main` 是保留字：真实 team / session 不允许取这两个值。
- 特殊来源的消息**不进入团队名册**，`team` / `message` 工具看不到、也发不进去。
- `ask_user_question` 是唯一向用户发消息的工具；它不是本消息机的一条出站消息，
  而是工具调用 + 提问卡片 + 作答回灌。

### 3.5 队列与零丢失

建议每个 `agent × session` 一条**收件箱台账**：

```text
data/<agent>/<session>/inbox.jsonl
{message_id, envelope, status, attempts, enqueued_at, updated_at}
status ∈ pending | inflight | done | failed | cancelled
```

- 收到消息：先追加 `pending` 并 flush，再向调用方回执；**回执前已落盘**。
- 开始处理：写 `inflight`；注入历史并落库后写 `done`。
- 崩溃恢复：`inflight` 视为 `pending` 重放；靠 `message_id` 与历史去重。
- 插件停止/退出：`store.flush()` + `inbox.flush()`，内存队列清空前必须落档。
- `direct` 与 `queue` 分两条逻辑队列，但共用同一份台账；`direct` 优先。
- 现有 `_chains` 串行链保留（同会话不并发写流），但它只是执行调度，不是消息账本。

### 3.6 状态机

建议显式状态：

```text
idle --task 到达--> working
working --本轮 loop 结束，队列无可运行 task--> idle
working --本轮 loop 结束，队列还有 task--> working（下一轮）
working --ask_user_question 在途--> working（附加 asking=true）
tip（任意状态）--> 状态不变
stop --> idle（并取消/作废可运行消息，见 §4 C8）
```

广播站建议新增 topic `agent.state`：

```jsonc
{"event":"agent.state","team_id":"...","agent_id":"...","session_id":"...",
 "state":"working","queue_depth":1,"own_running":true,"subagent_running":false,
 "run_id":"...","updated_at":0}
```

现有 `agent_status`（working/idle）帧继续供 UI 使用，但**单一真值**应是状态机；
帧由状态机派生，避免两套判断（当前 `isRunning` 与 `agent_status` 已有一处特例逻辑）。

### 3.7 站点面

| 站点 | 类型 | 建议 id / 命令 | 载荷 / 回包 |
| --- | --- | --- | --- |
| 消息发送 | execute（插件自建，`shared:true`） | `plugin.tree.agent.execute.agent_loop`；命令 `agent.message.send` | 入参 = §3.1 信封（`source` 由核心 `meta.source_plugin_id` 强制覆盖为 `plugin_<id>`）；回包 `{ok, message_id, queued, state}` |
| 状态查询 | 同上 | `agent.state.list` / `agent.state.get` | 回包 `{agents:[{team_id, agent_id, sessions:[...], state, queue_depth}]}` |
| 状态广播 | broadcast（复用 `agent_events`） | topic `agent.state` | 每次状态迁移发一条；晚订阅者用 `agent.state.list` 取权威快照 |
| 前置处理 | relay（插件自建，`shared:true`） | `plugin.tree.agent.relay.llm.pre` | 入参完整请求；回包 `{request?, error, error_reason}` |
| 请求体修复 | relay | `plugin.tree.agent.relay.llm.repair` | 入参完整请求；回包 `{request?, error, error_reason}` |
| 后置处理 | relay | `plugin.tree.agent.relay.llm.post` | 入参 `{thinking, content, tool_calls}`；回包同形 + `{error, error_reason}` |

- 站点「一个点位只有一个订阅者」是核心现规则；需要多级处理时由订阅者再自建转发站。
- 无订阅者 / 回 `null` = 不处理，走内置路径（与现有核心中转站同口径）。
- 传输异常 / 超时 = **fail-open** + 日志；只有显式 `error:true` 才 fail-closed 终止 loop。
  这与现有中转站「异常不搞崩一轮生成」的纪律一致，同时给显式错误一个硬出口。
- 执行站命令的来源身份取 `station/request` 的 `meta.source_plugin_id`
  （核心在 `plugin_bus.dart:2707-2714` 已带），插件必须用它覆盖调用方自报的 `source`。

---

## 4. 语义冲突与拍板结论

### C1 「本次生成后立即终止」的边界

规格注 (3)：「消息注入不打断当前生成（包括工具调用阶段和生成阶段），但是在本次生成后立即终止。」
三种可能解释：

| 解释 | 行为 | 代价 |
| --- | --- | --- |
| I1 迭代边界终止（**建议**） | 当前 LLM 响应 + 它触发的**整个工具批**跑完；若有新 task，本轮 loop 结束，不进入下一跳；消息机随后开新 loop | 保住工具原子性；新 task 要等当前批跑完 |
| I2 字面 step 0 | 下一个 LLM 请求前注入 direct，loop 继续，不额外终止 | 与注 (3) 冲突；task 不会「立即」生效 |
| I3 流结束即终止 | 当前 LLM 流一结束就终止，跳过未执行的工具 | 与「不打断工具调用阶段」冲突；会丢工具 |

**建议 I1**，并明确「本次生成 = 一次 LLM 响应 + 其工具批」。这样：
- 流式生成不被切断；
- 工具批不被切成半批（现实现会在工具之间检查软取消并跳过剩余工具，见 `llm_session.dart:593-597`，必须改）；
- 终止点唯一、可测试。

**拍板（2026-11-08）：采用 I1。**

### C2 `tip` 与「立即终止」的冲突

规格说 `tip`「仅注入消息到上下文，**不动 agent loop**」，注 (3) 又说「消息注入……本次生成后立即终止」。
两者不能同时按字面成立。

**建议**：终止规则只作用于 `task`；`tip` 永不终止、永不唤醒 loop。
`queue` 里的 `tip` 在 loop 结束后注入，不产生 LLM 调用，然后继续排空队列。
否则一条 tip 就能打断正在工作的 agent，与 tip 的定义矛盾。

**拍板（2026-11-08）：终止只作用于 `task`；`tip` 永不终止、永不唤醒 loop。**

### C3 队列作用域：按 agent 还是按 agent×session

规格写「每个 Agent 实例的消息队列」，现实现按 `agent × session` 并行。
按字面改成 agent 级串行，会让「同一 agent 的不同会话并行」失效（现实现明确支持，
且 UI 按 session 过滤帧）。

**建议**：实例持有**按 session 分区的队列**，调度仍是 `agent × session` 串行、跨 session 并行。
对外可以叫「Agent 实例的消息队列」，但内部是分区队列；需要用户确认这是否满足「每个 Agent 实例」的字面要求。

**拍板（2026-11-08）：按 session 分区，保留跨会话并行；对外称 Agent 实例队列。**

### C4 `system_message` 的落库与回放

> 状态：**已拍板**（2026-11-08）。

现 `CoreMessage.role` 只有 `user` / `agent`；`LlmMessage` 支持 `system`。
两种做法：

- **建议**：历史里存 `role=system`，请求装配时按顺序发成 `LlmRole.system`；不改钉住的系统提示词。
- 备选：把系统消息拼进钉住的系统提示词。**不建议**：会改变前缀字节，破坏端点缓存，
  且与「快照只在初次对话 / compact 后重建」的现有断言冲突。

风险：部分 OpenAI 兼容端点对多条 system 消息支持不一致；需要在 AC-1 用真实端点做一次兼容性验证。
UI 对 `role=system` 的显示口径也要确认（当前可能按未知 role 兜底）。

**C4 拍板（2026-11-08）：历史存 `role=system`；请求装配时发 `LlmRole.system`；不改钉住的系统提示词。**

### C5 「调用 LLM 插件」的边界

现实现没有 LLM 插件，HTTP/SSE 在 `llm_transport.dart` / `llm_session.dart` 内。

| 方案 | 内容 | 代价 |
| --- | --- | --- |
| A（**建议本期**） | 保留插件内 LLM 模块，抽 `LlmInvoker` 接口；消息机/loop 只依赖接口 | 不跨仓、不动 356 条现有测试的传输层；但「LLM 插件」字面未落地 |
| B | 新建 `llm` 插件，经执行站/中转站流式调用 | 需要新协议（流帧、取消、usage、错误码）、跨仓版本协商；应单独立项 |

**建议先 A**：本期把边界抽出来，等协议稳定后再把实现搬到独立插件。
如果用户要求本期就必须是插件，则需要先补一份 LLM 插件流式契约，不能直接开工。

**拍板（2026-11-08）：本期采用方案 A（抽 `LlmInvoker`，LLM 插件后置）。**

### C6 快照失效：系统提示词与工具表

- 系统提示词：现按 `agentId|sessionId` 钉住，只在初次对话 / compact 后重建
  （`conversation_service.dart:1711-1783`）。**建议保留**。改成 agent 级会破坏会话级
  `selected_spec_ids` 与跨重启前缀缓存。
  **C6-a 拍板（2026-11-08）：保留会话级钉住；只在初次对话 / compact 后重建。**
- 工具表：现每轮重建。目标要「无快照才构建」，意味着要定义失效信号：
  1. 工具贡献收集站的结果变化；
  2. MCP / 工具插件上下线；
  3. agent 工作空间模式（local/ssh）变化；
  4. 显式 `agent.tools.refresh` 命令。
  **建议**：默认按 `agentId|sessionId` 钉住；收到上述任一信号时只失效对应 agent 的快照。
  没有失效信号就重建，会让「快照」退化成每轮缓存，失去意义。
  **C6-b 拍板（2026-11-08）：工具表按 `agentId|sessionId` 钉住；收到上述四类信号时只失效对应 agent 的快照。**
- 记忆信息若进入系统提示词快照，也会受「只在初次对话 / compact 后重建」约束：
  用户更新 `.self/memory.md` 后，要开新会话或压缩一次才生效。需要确认这是否可接受。

### C7 「记忆信息」的定义

现实现没有记忆读取。可能指：

- **建议 MVP**：`.self/memory.md` 的当前文本 + 会话压缩摘要（`compactedSummary`）。
  在系统提示词快照构建时注入一个独立段；实例缓存该文本，按 C6 的快照时机刷新。
- 若指结构化长期记忆（向量/条目/检索），需要单独的产品与存储设计，不应塞进本次 loop 重构。

**C7 拍板（2026-11-08）：MVP 采用 `.self/memory.md` + 压缩摘要；结构化长期记忆不在本期。**

### C8 `stop` 与队列

> 状态：**已拍板**（2026-11-08）。

现状：`stop` 取消在途轮次并 bump epoch，**丢弃所有未开始的排队任务**（`conversation_service.dart:321-348`）。
规格未定义 stop。

**建议**：保留「stop 取消当前生成并作废可运行 task」的用户语义；在 inbox 台账里把被丢弃的
消息标 `cancelled`（而不是静默消失）；`tip` 是否也作废需要确认（建议 tip 保留，
因为它不产生生成，只是上下文补充）。

**C8 拍板（2026-11-08）：stop 作废可运行 task 并在台账标 `cancelled`；`tip` 保留。**

### C9 中转站错误契约与超时

> 状态：**已拍板**（2026-11-08）。

规格只给了 `error` / `error_reason`，没给超时、重试、多订阅者合并规则。

**建议**：
- 入参与回包都带 `error:boolean` + `error_reason:string`；`error=true` ⇒ 记录（inbox/turn 事件 + 日志）
  ⇒ 终止 loop ⇒ 把 `error_reason` 作为本轮失败原因返回给消息机/UI。
- 无订阅者、回 `null`、回包非法、异常、超时 ⇒ 不终止，走内置路径，并留一行可读日志。
- 一个点位一个订阅者；需要多级时用转发站，不在核心侧做合并。

**C9 拍板（2026-11-08）：仅显式 `error:true` fail-closed；其余一律 fail-open + 可读日志。**

### C10 状态是否增加 `asking`

> 状态：**已拍板**（2026-11-08）。

`ask_user_question` 在途时，现实现仍是 `working`，另有 `agent.ask.paused` 事件。
规格只提 working/idle。

**建议**：状态机保持 `idle/working` 两态，`asking` 作为 `working` 的附加布尔/事件，
避免新增第三种状态影响现有 UI 的「停止/发送」按钮判断。

**C10 拍板（2026-11-08）：保持 `idle/working` 两态；`asking` 作为 `working` 的附加标记/事件。**

### C11 direct 与 queue 的优先级、顺序

> 状态：**已拍板**（2026-11-08）。

**建议**：`direct` 优先于 `queue`；同类按 `created_at` + `message_id` 稳定排序；
`direct` 在一次插入点**全部注入**；`queue` 每次只取最早一条，tip 连续排空、task 单独跑 loop。
如果 `direct task` 与 `queue task` 同时存在，`direct` 先跑；`queue` 在当前 loop 结束后继续。

**C11 拍板（2026-11-08）：`direct` 优先；同类稳定排序；`queue` 逐条，tip 连续排空、task 单独跑 loop。**

### C12 `message_id` 与历史 schema

> 状态：**已拍板**（2026-11-08）。

`CoreMessage` 目前没有 `type/subtype/inject_mode/source/destination/source_message_id`
（`store/records.dart:380-565`）。收敛顺序建议：

1. 先加**加法键**（不删不改既有键），保证 UI `ChatMessage.fromJson` 安全忽略；
2. `message_id` 与 `CoreMessage.id` 的关系二选一：
   - 直接用 `message_id` 当 `id`（简单，但工具/思考段 id 生成逻辑要区分入站/出站）；
   - 增加 `source_message_id`（不侵入现有 id 语义，去重时查它）。
   **建议后者**，风险最小。
3. display store 不含这些元数据；detail store 的 payload 增量带，避免显示层膨胀。

**C12 拍板（2026-11-08）：采用加法键（`source_message_id` + envelope 元数据），不改既有键与 `CoreMessage.id` 语义。**

---

## 5. 切片建议（拍板后执行）

> 2026-11-08 已拍板 C1~C12 全部条目，无剩余待确认项；AC-1~AC-6 均无阻塞。
> **AC-1 已完成**：加法 schema + `inbox.jsonl` 台账 + `AgentInstance` 骨架；
> analyze 0、tree.agent 396 全绿（新增 16 条）。
> **AC-2 已完成**：信封校验 + 特殊来源规则 + direct/queue 双队列 + tip 不唤醒 /
> task 唤醒 + `agent.state` 状态广播 + 去掉「到达即打断」；
> analyze 0、tree.agent 408 全绿（新增 12 条）。
> **AC-3 已完成**：每跳插入点注入（tip / system_message，只追加不改前缀）+ 工具批
> 原子（只认硬取消）+ `direct task` 迭代边界终止 + 工具表按会话快照与失效；
> analyze 0、tree.agent 414 全绿（新增 6 条）。

| 切片 | 内容 | 证明点 / 门禁 |
| --- | --- | --- |
| **AC-1 信封 + 台账 + 实例骨架** | 加法 schema（`source_message_id` 等）；`inbox.jsonl` 追加/状态/恢复；`AgentInstance` 空壳与生命周期；不改变现有行为 | `dart analyze` 0 新增；`dart test`（tree.agent 全量）；崩溃恢复单测；历史读写兼容 |
| **AC-2 消息机改造** | `type/subtype/inject_mode` 校验；特殊来源；direct/queue 双队列；tip 不唤醒；task 唤醒；状态机 + `agent.state` 广播；去掉「到达即打断」 | 注入/唤醒/状态迁移单测；现有 `message_dispatcher_test` / `subagent_tool_test` / `question_broker_test` 全绿 |
| **AC-3 loop 前置 + 注入点** | 队列排空规则；direct 插入点；工具批原子性（删掉工具之间跳过的软取消）；task 的迭代边界终止（C1/I1）；工具表快照与失效 | `llm_session_test` 扩展：流中到达不切断、工具批跑完、下一跳前注入；前缀缓存字节不变断言 |
| **AC-4 loop 三步中转站** | 前置 / 请求体修复 / 后置三个 relay 站；`error/error_reason` 契约；无订阅者 fail-open；显式 error 终止并回报 | 站级单测：无订阅、null、非法回包、显式 error、异常、超时；`system_message` post 处理 |
| **AC-5 站点面** | `agent_loop` 执行站 `agent.message.send` / `agent.state.list`；`agent.state` 广播；来源身份强制 | 伪造 `source` 被覆盖；跨插件发送；晚订阅快照；scope fail-closed |
| **AC-6 LLM 边界（本期只抽接口）** | 抽 `LlmInvoker`；LLM 插件作为后续独立立项，不在本期新建 | 现有 356 条测试全绿；接口替换测试；不新增跨插件流式协议 |

门禁顺序沿用项目规则：`dart analyze`（无新增错误/告警）→ 受影响包全量 `dart test` →
`tree_protocol` 访问控制 → 涉及 UI 才跑 `flutter`。
AC-1/AC-2 会改插件仓 `plugins/tree.agent`；若需同步桌面仓文档，按 `docs` 索引门禁更新。

---

## 6. 回归与测试清单

现有可直接复用/扩展的测试：

- `plugins/tree.agent/test/llm_session_test.dart`：工具循环、取消、usage、截断修复。
- `plugins/tree.agent/test/llm_agent_engine_test.dart`：历史翻译、工具配对、自动修复、前缀。
- `plugins/tree.agent/test/message_dispatcher_test.dart`：团队消息、广播、wait_for、补发。
- `plugins/tree.agent/test/question_broker_test.dart`：提问等待/作答/取消。
- `plugins/tree.agent/test/subagent_tool_test.dart` / `subagent_registry_test.dart`：临时员工。
- `plugins/tree.agent/test/conversation_stream_seq_test.dart`：流式序号与重播去重。
- `plugins/tree.agent/test/ported_store_test.dart` / `conversation_db_test.dart`：存储与双 store。
- `plugins/tree.agent/test/agent_runtime_test.dart`：REST 发消息/取消的现有语义。

本期需要新增的判据（建议编号）：

| 编号 | 判据 |
| --- | --- |
| TC-MSG-01 | 信封缺 `message_id` / 非法 `type/subtype/inject_mode` 被拒，且不落历史 |
| TC-MSG-02 | `tip` 在 idle 与 working 下都不启动/不终止 loop |
| TC-MSG-03 | `task` 在 idle 下启动一轮；在 working 下等当前工具批完成后开新 loop |
| TC-MSG-04 | `direct` 在一次插入点全部注入；`queue` 在 loop 结束后逐条注入 |
| TC-MSG-05 | `queue=[tip, task]` 时 tip 被排空、task 仍能跑（C2） |
| TC-MSG-06 | `inbox.jsonl` 在 `inflight` 时被杀，重启后重放且只生效一次（C12） |
| TC-MSG-07 | 特殊来源 `user/system/plugin_*` 不能作为目标；`message` 工具拒绝 |
| TC-MSG-08 | 插件经 `agent.message.send` 发送时，自报 `source` 被 `source_plugin_id` 覆盖 |
| TC-LOOP-01 | 流式生成中到达消息不切断当前流 |
| TC-LOOP-02 | 工具批中途到达消息，整批工具全部执行完，剩余工具不被跳过 |
| TC-LOOP-03 | 前置 relay 回 `error:true` ⇒ 终止 loop、`error_reason` 可见、无下一跳 |
| TC-LOOP-04 | 请求体修复 relay 回包替换请求；无订阅者走内置 |
| TC-LOOP-05 | 后置 relay 分别替换 thinking/content/tool；非法回包 fail-open |
| TC-LOOP-06 | `system_message` 以 `role=system` 进请求且不改钉住的系统提示词字节 |
| TC-STATE-01 | idle→working→idle 迁移与 `agent.state` 广播一致；`asking` 不新增状态 |
| TC-STATE-02 | `agent.state.list` 返回晚订阅者的权威快照 |

---

## 7. 证据索引

- 会话适配与状态：`plugins/tree.agent/lib/src/agent/conversation_service.dart:149-259`、`:265-574`、`:705-1194`、`:1593-1627`、`:1663-1842`
- 引擎与上下文装配：`plugins/tree.agent/lib/src/llm/llm_agent_engine.dart:64-319`、`:626-900`
- 工具循环：`plugins/tree.agent/lib/src/llm/llm_session.dart:275-657`
- 存储与历史：`plugins/tree.agent/lib/src/store/records.dart:380-565`、`store/conversation_db.dart:14-24`、`store/tree_store.dart:28-232`
- 消息投递：`plugins/tree.agent/lib/src/team/message_dispatcher.dart:15-25`、`:642-775`、`tool/message_tool.dart:14-114`
- 运行时接线：`plugins/tree.agent/lib/src/runtime/agent_runtime.dart:120-215`、`:445-519`、`:694-696`、`:1279-1295`
- 站点注册：`plugins/tree.agent/tree.agent_plugin.dart:41-152`、`lib/src/station/agent_tools.dart:8-42`
- 事件广播：`plugins/tree.agent/lib/src/plugin/agent_events.dart:21-111`
- 系统提示词：`plugins/tree.agent/lib/src/agent/workspace_prompt.dart:141-169`
- 现核心中转站口径：`docs/plugin-development.md` §5（尤其 §5.2 回包、§5.3 请求改写、§5.6 整轮接管）
- 执行站来源身份：`packages/tree_core/lib/src/plugin/plugin_bus.dart:2700-2716`
- 插件迁移背景：[agent_pluginization.md](agent_pluginization.md)、[agent_api_contract.md](agent_api_contract.md)
