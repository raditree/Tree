# Agent 上下文交接（handover）与系统提示词快照留档

> 2026-11-23｜状态：方案定稿，按 §6 切片实施｜车道：R（新增）
> 目标仓：`plugins/tree.agent`（领域实现）＋ 桌面仓（本文档）

## 1. 结论

1. **快照留档与 head 解耦**：新增每会话 `prompts.jsonl` 追加日志，记录每次快照重建的
   `system_prompt / compaction_summary / effective_system / watermark`；**不进消息流、
   不动水位线、不改请求装配**。head 方案不做。
2. **handover 是独立的编排通道**：agent 调 `handover` 工具只写一条
   `pending_handover`，由会话层在**下一次 LLM 调用前**消费——用显式摘要 + 显式切点
   重置上下文，复用同一个模型继续跑。
3. **模型不变**：两条能力都只改“发给模型什么”，不换模型、不改端点协议。

## 2. 目标与非目标

**目标**

- 系统提示词快照可回溯：能看每一次重建的完整注入内容（含压缩摘要）与时间/原因/水位线。
- agent 能在开启新任务前主动清空自己的上下文，并留下可读的交接说明。
- 不破坏现有前缀缓存、工具批原子性、压缩不删消息等不变量。

**非目标（本期不做）**

- head 消息、消息流内注入、水位线随 head 自动调整。
- 插件任意写系统提示词快照正文。
- 把摘要并入首条 `system` 实发消息（本期只做 `effective_system` 展示投影）。
- UI 大改（只加提示词面板的版本选择；可后置）。

## 3. 现状侦察

| 能力 | 现状 | 落点 |
| --- | --- | --- |
| 系统提示词钉住 | 每会话一份，落 `session.json` 的 `system_prompt_pinned`，跨重启逐字复用；重建只在初次对话 / compact 后 | `conversation_service.dart` `_ensureSystemPromptPinned` / `_systemPromptPinned`；`records.dart` `CoreSession` |
| 快照查看 | `GET .../prompt-snapshot` 返回**当前**钉住值 + 分段 + dirty；**没有历史版本**，也不含摘要 | `memory_delegate.dart` `_promptSnapshot` |
| 压缩摘要 | 内置路径写 `compacted_summary` + `compacted_message_count`；引擎把它作为**第二条 system 消息**跟在提示词后 | `compaction_service.dart`；`llm_agent_engine.dart` `_buildMessages` |
| 中转站压缩 | 写整份 `compacted_context`（可含 assistant/tool），引擎原样用作基底、只刷新首条 system 槽位 | `records.dart` `CoreSession.compactedContext` |
| 手动压缩 | REST `/compact` 与执行站 `agent.compact` 在 agent 运行中一律拒绝（`agent_working`） | `delegate.dart`；`agent_runtime.dart` `_agentCompact` |
| 工具循环重建 | 每轮 API 调用前 `_compactBeforeTurn`，只有压缩真的发生才 `base = compacted` | `llm_session.dart` |
| 工具结果控制位 | `ToolOutcome` 只有 `content / isError / images`，工具无法请求“重建上下文” | `tool_runner.dart` |
| 工具循环缓存的在途消息 | `inFlight` 从不清空；`base` 被替换后 `current() = base + inFlight` 可能重复当前工具轨迹 | `llm_session.dart` |
| 系统提示词中转点 | `system.relay.prompt.system` **每轮**可改写，且压缩估算刻意不跟 | `llm_agent_engine.dart` |

结论：**存盘只差“历史版本 + 摘要视图”**；handover 差的是“工具发起 → 轮边界强制重建”的
控制通道，以及一个显式摘要/显式切点的写入入口。

## 4. 设计

### 4.1 系统提示词快照留档（S1）

**存储**：`data/<agent_id>/<session_id>/prompts.jsonl`，追加写，一行一个版本。
路径与 `usage.jsonl` 同目录、同原子追加原语（`AtomicFile.appendLine` + `WriteQueue`）。

**记录形状**

```json
{
  "version": 3,
  "at": "2026-11-23T10:00:00+08:00",
  "reason": "compact",
  "model_id": "deepseek-chat",
  "system_prompt": "……钉住的提示词原文……",
  "compaction_summary": "……压缩摘要（内置路径）……",
  "effective_system": "……system_prompt 与摘要按展示口径拼起来的完整内容……",
  "watermark": 42,
  "relay_context": false,
  "chars": 22129,
  "sha256": "……effective_system 的 sha256……"
}
```

- `reason`：`initial` / `compact` / `handover` / `manual_rebuild` / `relay` / `legacy`。
- `effective_system` 是**展示投影**：`system_prompt` + 空行 + 摘要（若有）。它不改实发结构；
  实发仍是“提示词一条 system + 摘要一条 system”。
- `relay_context=true` 表示该会话权威在中转站列表上（`compacted_context` 非空）；此时
  `compaction_summary` 通常为空，`effective_system` 只含提示词。
- `version` 从 1 递增；`sha256` 用于**相邻去重**：与上一条相同则不追加。

**写入点**

1. `_ensureSystemPromptPinned` 首次拼装并落库后：`reason=initial`。
2. 压缩后重建并重钉后：`reason=compact`。
3. handover 生效后重建并重钉后：`reason=handover`。
4. 读取到会话已有 `system_prompt_pinned`、但日志为空：补一条 `reason=legacy`（只补一次）。
5. 可选（默认关）：`system.relay.prompt.system` 改写后的实发字节与上一条不同时记
   `reason=relay`——避免非确定性改写把日志刷爆。

**读取面**

`GET /api/agents/{agentId}/sessions/{sessionId}/prompt-snapshot` 保持现有字段不变，增量：

- `history`: `[{version, at, reason, chars, sha256, watermark}]`（元数据，轻量）；
- `?version=N`: 返回该版本的 `system_prompt / compaction_summary / effective_system / watermark`；
- 不传 `version` = 当前钉住值（与今天一致）。

**不变量**

- 只追加、不改写已有行；坏行跳过并计数，绝不因一行坏数据读不出历史。
- 不参与模型请求装配；写失败只记日志，不影响生成。
- 关停时 `flush`；硬杀最多丢最后一条（append-only）。

### 4.2 handover（S2）

**工具**

内置工具 `handover`（与 `read/write/...` 同一层声明），参数：

```json
{ "summary": "string（必填，≤64 KiB）" }
```

描述明确：用于“开启新任务前收束上下文”，**本轮工具批结束后生效**；旧历史不再进入模型，
但仍保留在会话历史里。

**pending 记录**

工具不直接改上下文，只写会话上的一条待生效记录（落 `session.json`）：

```json
{
  "summary": "……交接说明……",
  "tool_id": "tool_xxx",
  "created_at": "2026-11-23T10:00:00+08:00"
}
```

- 同一会话重复调用以**最新一条**为准（覆盖）。
- 工具层校验：非空、≤64 KiB、目标 agent 不是临时员工（`sub_…` 直接拒绝）。
- 落盘失败返回错误；成功只回一句“已登记，本轮批结束后生效”。

**消费时机**

两处，均为“轮边界”：

1. 工具循环每轮 API 调用前（`_compactTurnContext`）——处理正常 handover；
2. 每轮生成开始前（`_runReply` 的压缩检查之前）——处理崩溃/重启后遗留的 pending。

**切点算法**（纯函数，可单测）

输入：`messages()`、`tool_id`、本轮开始时间 `run_started_at`、当前水位线。

1. 找到 `CoreMessage.id == tool_id` 的工具卡下标 `h`；找不到 ⇒ 不切（保留原文，记日志）。
2. 在 `h` 之前找**本轮新到的输入**：`timestamp >= run_started_at` 且属于
   `user / notice / subagent_report / system_message`（跳过 `llm_hidden`）。
   - 找到 ⇒ `cut = 该下标`：保留这条新输入及其后全部内容（含 handover 卡）。
     宁可让模型多看到一条 handover 调用，也不吞用户插话。
3. 否则 `cut = h + 1`：handover 卡及其之前的本轮轨迹都不再进模型。
4. `cut = max(cut, 当前水位线)`；若 `cut <= 水位线` ⇒ 无事可做（提示一条 notice）。

切点允许落在工具卡上：引擎会用工具卡里的名称/参数补回 assistant 的 `tool_calls`
（`_buildMessages` 已有该能力），因此不会留下“孤立 tool 结果”。

**应用**

- 摘要正文 = 固定头 + handover 正文（与内置压缩的 `summaryHeader` 同级，便于区分来源）。
- `store.setCompacted(agent, session, summary, messageCount: cut)`：写摘要、清
  `compacted_context`（两条路径互斥）、推进水位线。
- `store.clearPendingHandover`：成功后再清，失败保留待重试。
- 通知：落一条 `llm_hidden` 消息（“上下文已按 handover 重置，当前 N 条”），用户可见、
  模型不可见。
- 重建系统提示词：`invalidateSystemPrompt` + `_ensureSystemPromptPinned(reason: handover)`；
  并追加一条 `prompts.jsonl` 记录。
- 返回重建后的 `AgentRunContext`，引擎 `base = rebuilt` 继续跑；**同一个模型、同一个 loop**。

**引擎侧：替换与压缩是两种语义**

现有 `compactContext` 的契约是“换前缀、**保留**本轮在途工具轨迹”（`llm_session_test`
有钉子：重建后 `tool_calls` / 工具结果不能丢）。handover 相反，要“整体丢掉旧轨迹”。
因此不复用压缩钩子，而是新增一个单独钩子 `replaceContext`：

- 返回非 null ⇒ `base = replaced; inFlight.clear();`
- 压缩钩子维持原语义（`base = compacted`，**不**清 `inFlight`）。

接线：`LlmAgentEngine.contextReplacer` → `ConversationService._replaceContextFor` →
`HandoverService.apply` → `LlmAgentEngine.buildMessagesFor(_contextOf(...))`。
`buildMessagesFor` 是 `_buildMessages` 的公开薄封装，只按当前存储（新摘要 + 新水位线）
重新装配，不走压缩中转点。

**边界**

- 压缩服务不可用（无内置摘要器/无中转点）时 handover 仍可用：它不需要总结模型。
- 临时员工轮不支持 handover（工具层直接拒绝），避免父子会话水位线互相污染。
- handover 不唤醒 loop；它只影响下一次请求。若当前没有在途 loop，pending 在下一次
  生成开始前消费。
- 用户中止 / 崩溃：pending 已落盘，下次生成前消费；同一条幂等（切点不倒退）。

### 4.3 与 head 方案的关系

不做 head。将来若需要“快照作为一条消息注入”，只需把 `prompts.jsonl` 的某一条记录
**投影**成消息即可；存储格式不需要改。这样本轮的能力不会把消息流、水位线、UI 历史
耦合在一起。

## 5. 不变量与边界

1. **前缀缓存**：重建只发生在初次对话 / compact / handover；两次重建之间继续复用钉住字节。
2. **压缩不删消息**：只推进水位线，会话全文仍在。
3. **工具批原子性**：handover 只在批结束后生效，不在批中间切。
4. **不吞用户输入**：批期间新到的用户消息优先，切点让位。
5. **临时员工隔离**：不继承父会话的 handover / 水位线。
6. **中转站路径不被破坏**：`compacted_context` 非空时 handover 走 `setCompacted` 会把列表
   清空（与现有互斥口径一致），日志里记 `relay_context=true`。
7. **插件零核心依赖**：不改核心路由；`prompt-snapshot` 是 tree.agent 已申报的委派路由。
8. **模型不变**：不新增模型字段、不改端点请求形状。

## 6. 切片与门禁

| 切片 | 内容 | 门禁 |
| --- | --- | --- |
| **S1 快照留档** | `TreePaths.promptSnapshotsFile`、`PromptSnapshotLog`、写入点、`flush` | `dart analyze` 0；`dart test`（新增日志测试 + 既有 system_prompt_pin 测试） |
| **S2 handover 后端** | `PendingHandover` + store 方法；`handover` 工具；`handoverCut`；轮边界消费；`inFlight.clear` | 同上 + `compaction_test` / `llm_session` 相关测试 |
| **S3 REST** | `prompt-snapshot` 的 `history` / `version` | `memory_delegate_test` |
| **S4 UI（可选后置）** | 提示词面板版本选择 | UI 仓 analyze + 受影响的 widget 测试 |

提交纪律：S1/S2/S3 各自可独立提交；S1 不改变任何模型行为，可先合入。

## 7. 测试清单

**S1**

- 记录一次 initial：`prompts.jsonl` 出现 1 行，字段齐全，`effective_system` 含摘要。
- 相同内容连续两次记录：只追加 1 行（sha256 去重）。
- 坏行 / 手改坏文件：读取跳过并计数，不抛异常。
- 旧会话只有 `system_prompt_pinned`：首次读取补 `legacy` 一行。
- 压缩后重建：新增 `reason=compact`，`watermark` 与 session 一致。

**S2**

- `handoverCut`：卡在中间、卡在末尾、其后有新用户消息、仅有工具卡、找不到卡五种形状。
- 工具写入 pending：非空/超长/临时员工三种拒绝路径。
- 工具批结束后下一次请求：system + handover 摘要，旧历史不在；同一模型。
- 用户插话场景：切点让位，用户消息仍在上下文里。
- 无压缩服务时 handover 仍生效。
- 崩溃/重启：pending 遗留、下次生成前消费、幂等。
- `inFlight.clear`：重建后请求里不出现重复的工具轨迹。

**S3**

- `prompt-snapshot` 默认仍返回当前值；`history` 元数据按时间倒序；
- `?version=N` 返回全文；不存在版本返回 404/可读错误。

## 8. 已拍板口径

1. 切点：按 §4.2 算法（优先保留本轮新用户输入；否则切到 handover 卡之后）。
2. 系统提示词：handover 时重建并重钉（`reason=handover`）。
3. 工具归属：内置 `handover` 工具；不接受插件直接写快照正文。
4. 摘要实发：本期不并入首条 system，只做 `effective_system` 展示投影。
5. 日志保留：append-only；读取默认只读尾部；暂不做自动归档（后续按 2 MB 阈值评估）。

## 9. 风险

- **工具表变更**：新增 `handover` 会改变一次请求的工具定义前缀，造成一次性缓存失效；
  与既有工具表变更同类，接受。
- **pending 双消费**：用“切点不倒退 + 成功后才清”保证幂等。
- **在途消息重复**：`inFlight.clear()` 是必要修正；需要回归“重建后请求不重复”。
- **中转站提示词改写**：快照记录的是钉住值，不是 relay 后的实发值；默认不记 `relay`，
  需要严格回溯时再开开关。
- **误用**：handover 会让模型丢掉旧上下文；工具描述必须写清“只在准备开启新任务时用”，
  并在 UI 留可见 notice。
