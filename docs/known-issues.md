# Tree desktop 已知问题记录

> 记录"发现了但还没处理 / 正在处理"的问题：**现象 → 根因 → 证据 → 修复方向 → 状态**。
> 每条独立成节；处理完把状态改成"已修复（日期 + 验证方式）"，**条目保留**，便于回溯。
> 记录原则：只写**验证过**的事实（代码行号、日志、实测输出）；推测一律标注"推测"。

---

## #1 模型全程不挂 Spec（链路三处断裂）

**状态**：根因 1、3 **已修复**（2026-10-01）；根因 2（目录迁移）**未处理**。
**影响**：Spec 体系（任务型规范）实际未生效——索引里的规范模型看不到/不选，选了也不进上下文。

### 现象

- 长任务整场只调 1 次 `spec`（或 0 次），`session.json` 的 `selected_spec_ids` 长期为空；
  每轮工具结果里 `- "[Warning]spec 未选择"` 反复出现，模型持续无视。
- 现场样例 `ses_1790784272959_5f498a_3`（2026-10-01）：**143 次工具调用**
  （terminal 90 / read 33 / grep 13 / write 5 / **spec 1** / set_todo_list 1），
  唯一那次 `spec select` 发生在最后（L227，06:39:12），模型 L226 思考原文：
  *"Also handle spec warning — I should select general-task spec since this is a multi-step task."*
  —— 是被 Warning 逼出来的，不是被流程要求的。会话开头 L2 思考：*"先挂 spec？先看工作空间再说。"*，之后再没回来。
- 对照：上一会话 `ses_1790778341529_eb6ccb_3` 一开工就挂了 3 个（`spec-1788670137` / `flutter-fastapi` / `spec-1789268032`）。

### 根因 1：参考实现的「⑧ 已选 Spec 全文」章节没有移植

参考实现每次重建 system prompt 时，把本会话 `selected_spec_ids` 指向的规范**全文**注入：

| | 参考实现（`server/`） | 本仓库 |
| --- | --- | --- |
| ⑦ Spec 索引 | `agent/chat.py:719-722` | 有（`workspace_prompt.dart:60` `specIndexSection`） |
| **⑧ 已选 Spec 全文** | **`agent/chat.py:724-729`** → `_build_selected_specs_text()`（`chat.py:806-826`）→ `_read_spec_full_text()`（`chat.py:785-803`），读 `selected_spec_ids` 注入全文 | **完全没有** |
| 注入时机 | compact 后重建 system prompt 时刷新：`llm/llm.py:1564-1586`（rebuilder 由 `agent/chat.py:178` 挂上） | 压缩后确实会重建提示词（`conversation_service.dart:815`），但重建出来的内容里没有它 |

tree_core 里 `selectedSpecIds` 的读者只有三处，**没有一处进上下文**：

- `packages/tree_core/lib/src/tool/status_text.dart:37`（每轮工具结果的状态行）
- REST `GET /api/agents/{id}/specs`
- 前端 spec 面板

上下文装配处确认：`conversation_service.dart:787` 只传 `systemPromptWithWorkspace(agent)`；
`llm_agent_engine.dart:255-266` 只发 `system + 摘要 + 历史`。

**后果**：`spec select` 对上下文零影响，唯一痕迹是那一轮工具结果的全文；压缩一轮就被摘要吞掉，
此后不会再有重建注入。工具描述、`select` 的 note（`spec_service.dart:369`）、系统提示词
（`workspace_prompt.dart:64`）三处都承诺"实际注入发生在下次重构 context"——目前是**空头承诺**。

### 根因 2：自定义 Spec 目录迁移漏了（`<workspace>/spec/` → `<workspace>/.self/spec/`）

旧实现与参考一致，自定义 spec 落 `<工作空间>/spec/<id>.md`（`git show HEAD` 里 `SpecService.specDir = 'spec'`）；
新实现改成 `.self/spec/`（`spec_service.dart:109`），**没有搬文件、也没有只读兼容**。现场：

- `E:\programs\Tree\desktop\spec\` → 5 个自定义规范（`flutter-fastapi` / `flutter-tab` / `flutter` / `spec-1788670137` / `spec-1789268032`）
- `E:\programs\Tree\desktop\.self\spec\` → 只有 3 个内置（general-task / hard-task / team-meeting）

实测（真实数据根 + 该 agent 装配 `systemPromptWithWorkspace`）：**system prompt 3637 字符，
Spec 索引只有 3 条内置**。⇒ 上下文中已选的自定义 spec 从索引消失，
而旧会话 `selected_spec_ids` 仍指向它们（悬空引用，再 `select` 只会得到「Spec 不存在」）。

### 根因 3：提示词把"必须挂"改成了"可以不挂"

参考的工具定义（`server/prompt/versions/1.0.0/tools/builtin.yaml:100-107`）：

> **何时不用: 无。必须调用**，即使单文件修改也必须先 **read 并 select** easy spec 再开始任务
> **前置依赖**: 在搜索更多 spec 前必须先从四个内置基础 spec 中选择一个或多个

且参考 `task-paradigm.md` 的四个分型（easy / complex / hard / team-meeting）**每个都对应一个内置 spec**，
"必须挂"永远有对象。本仓库三处同向松绑：

1. 删掉了 `easy-task` → "小任务"这个分型**没有任何规范可挂**；
2. `agent/system_prompt_file.dart:191` 明写"**小任务**…**不必挂规范**"；
   `agent/workspace_prompt.dart:64` 写"没有合适的就不挂（不要硬凑）"；
3. 同时每轮工具结果仍无条件注入 `- "[Warning]spec 未选择"`，而提示词里的
   `[Warning] 负责规则` 又要求"立即行动"。

两条指令互相打架：一边说小任务不用挂，一边把"没挂"标成必须处理的 Warning ⇒
模型学会忽略这条 Warning ⇒ general/hard 任务一起漏挂。

另外，参考里 `select` 的前置（必须先 `read`，见 `server/tool/spec_tool.py:74-76` 的
`_read_spec_ids`、`:298-304` 的拒绝逻辑）在本仓库被删掉了（`select` 直接返回全文），
于是"读规范全文"不再是任何流程的必经步骤。

### 修复（2026-10-01，只做根因 1 + 3）

**根因 1 — 补上 ⑧「已选 Spec 全文」注入**（对齐参考 `chat.py` 第 ⑧ 章）：

- `agent/workspace_prompt.dart`：新增 `selectedSpecsProvider(agent, sessionId)` 与
  `selectedSpecsSection()`；`systemPromptWithWorkspace` 多一个 `sessionId` 参数
  （`selected_spec_ids` 是**会话级**的），段落顺序 = 软约束 → ⑦ 索引 → ⑧ 已选全文。
- `spec/spec_service.dart`：新增 `selectedSpecsSnapshot(agentId, sessionId)`（同步快照，
  没热就返回空 + 后台补一次，与 `indexSnapshot` 同一套路）与 `refreshSelectedSpecs()`
  （读会话里的 `selected_spec_ids` → 逐个取全文 → `### Spec: <id>` 拼接；**悬空 hook 跳过**）。
  `select` / `create` / `update` 成功后立即写热快照；REST 改选择（`PUT .../specs/selected`）
  也会立即刷新。
- `server/core_server.dart`：接上 `selectedSpecsProvider`，close 时按身份解绑。
- **两处装配同口径**：`ConversationService._contextOf` 与
  `CompactionService.estimateContextTokens` 都传 `sessionId`，避免压缩阈值失真。

**根因 3 — 收口自相矛盾的挂载口径**：

- `tool/spec_tool.dart` 描述补上"何时用：几乎没有例外……会改动文件或需要多步执行的任务不允许跳过"；
- `agent/system_prompt_file.dart`（种子）把"小任务……不必挂规范"改成
  **"问答与查阅（唯一可以不挂的类型）"**，并写明"开工第一步是判型并挂规范，不允许先探索再说"；
- `agent/workspace_prompt.dart` 的索引段去掉"没有合适的就不挂（不要硬凑）"这张
  **无限期免挂通行证**，改成与 `[Warning]spec 未选择` 一致的判定条件。

**生效提醒**：`.self/system_prompt.md` 是**已存在的文件**，种子改动只对新建/缺失的工作空间生效。
现有工作空间要让新口径生效，需要在右栏点一次「重置系统提示词」（会先备份成 `.bak.<n>`）。

**测试**：`workspace_prompt_test`（⑧ 段：provider / 显式参数 / 空则不注入 / sessionId 透传 / 段落顺序）、
`spec_service_test`（select 后提示词即带全文、冷缓存按会话恢复、悬空 hook 跳过）。

### 剩余（根因 2，未处理）

- **B. 迁移 + 兼容**：把 `<工作空间>/spec/*.md` 迁到 `.self/spec/`（不覆盖已有 `.self` 文件），
  或索引同时只读旧目录；现场仍是 `spec/` 5 个自定义规范 vs `.self/spec/` 3 个内置。


---

## #3 压缩触发过早：估算口径 ≠ 实际发送口径

**状态**：已修复（2026-10-01；单测覆盖两条口径）
**影响**：用户设 512000 上下文 / 80% 压缩，实测在真实上下文约 1/3 时就触发压缩。

### 现象

设置 `max_seqlen_override = 512000`、阈值 0.8（触发线 409600 估算 token），
但长会话在**真实 prompt_tokens 还在 20 万上下**时就压了，用户怀疑"哪里用了默认值"。

### 排查结论：不是默认值

- `maxSeqlenFor` **优先**用 `agent.maxSeqlenOverride`（512000），兜底值 128000 未被用到；
- `thresholdFor`：库里存的是 `compress_threshold: 0.0`（= 未覆盖）→ 默认 **0.8**，与用户意图一致。

### 根因：估算把"从不发给模型的东西"也算进去了

以现场会话 `ses_1790784272959_5f498a_3` 实测：

| 项目 | 字符数 | 计入估算？ | 真的发给模型？ |
| --- | --- | --- | --- |
| 思考消息（kind=thinking） | **456,747** | ✅ | ❌ 引擎不回灌（`llm_agent_engine.dart` 的 `if (ref.isThinking) continue`） |
| 超门控的工具结果（4 条） | **312,431** | ✅ 按**全文** | ❌ 只有 ~300 字符预览 + 提示 |
| 其余工具结果 | 315,230 | ✅ | ✅ |
| 正文文本 | 872 | ✅ | ✅ |

- 估算：`(456,747 + 872 + 627,661) / 2.64 ≈ 411k` → 越线 409,600 ⇒ **触发压缩**
- 实际发送：`(872 + 315,230 + ~2,800) / 2.64 ≈ 121k`

即估算里有 **~290k token 的"幽灵上下文"**（思考 173k + 被门控结果 117k），
所以"估算 411k / 端点真实 20 万"能同时成立——两个数根本不是同一个口径。

### 修复（2026-10-01）

1. **思考按开关计入**：`estimateContextTokens` 只在"回传思考"开启（见 #4）时计 thinking，
   关闭时与引擎一样排除；总结输入（`_summarize` / `_digest`）同样过滤，
   避免把从不发送的 CoT 从摘要后门塞回上下文。
2. **工具结果按门控后计**：新增 `ToolResultGate.forModelChars()`（同步、不落盘）
   与 `estimateTokensFromChars()`，估算与发送共用同一条规则。
3. `CoreMessage.isThinking` 补齐（原来只有 `CoreMessageRef` 上有）。

**测试**：`compaction_test.dart` 新增两条"估算口径 = 实际发送"。

---

## #4 思考（reasoning_content）不回传

**状态**：已修复（2026-10-01；已接线到设置页现成的开关）
**影响**：官方 DeepSeek 端点在"带 tools"的请求里要求原样回传历史 `reasoning_content`，
缺失会让同会话后续请求持续 400。

### 根因

参考实现（`server/llm/llm.py`）是**回传**的，注释还写明了动机：
"thinking 内容原样回写进 assistant 消息，供下一轮上下文回传网关，**避免同一 assistant
消息进入下一轮时网关 400**"；带 tool_calls 的那条 assistant 消息（L1086-1088）与
无 tool_call 的最终回复（L1283-1285）都回写，`tests/test_thinking.py` 两个分支都有断言。

desktop 移植时只搬了解析（显示思考卡片），**没搬回写**：历史里的 thinking 一律 `continue`。
所以现状是"一直不回传"——当前网关容忍，换成官方端点才会 400。

### 修复

接线到**设置页现成的**「思考模型（thinking）」开关（模型配置 `thinking`，参考实现也正是
用它 gate 回写：`thinking_text = ... if self.thinking else ""`）：

1. `LlmMessage` 增加 `reasoningContent`，`toWire()` 在 assistant 消息**顶层**输出
   `reasoning_content`（与 `content` 同级），`charCount` / `estimatedTokens` 一并计入；
2. `_buildMessages` 开启时把历史思考**攒起来挂到下一条 assistant 消息**上——
   包括带 `tool_calls` 的那条（它是引擎在 `flushTools` 里现拼的）；关闭时维持原行为；
3. 开关说明写进设置页（含代价）+ 与 #3 的估算口径联动。
4. **三级可设置**：模型级 = 设置页「自定义模型」的 `thinking`；**agent 级覆盖 = 右栏「模型信息」的
   「回传思考」下拉**（跟随模型 / 开启 / 关闭，三态）、成员页「模型配置」也有同一项。
   存储为 `agents/<id>.yaml` 的 `thinking_override`（`null` = 不覆盖），
   PATCH 的键是 `thinking`，生效顺位 = **agent 覆盖 → 模型默认**；
   上下文估算与压缩阈值走同一个 `passBackReasoningFor(agent)`。

**默认关闭**：现网关不需要，且回传会把思考每轮重发（现场会话 ≈ +173k 输入 token）。
开启后复用思考链能让后续思考更短、成功率更高，属用户按端点/成本自行取舍——
所以做成三级开关（模型默认 + 每个 agent 可覆盖），而不是一次性全局决定。

**测试**：`llm_agent_engine_test.dart` 两条（开启时挂到两种 assistant 消息上 / 默认关闭时
请求体里不出现该字段）。

---

## #2 压缩降级：`Bad state: 模型没有返回总结内容`

**状态**：已修复（2026-10-01；总结**复用原模型输出长度** + 沿用 agent 思考档位；单测 9/9、真实端点实测）
**影响**：压缩退化成截断摘要（要点可能不全），长任务上下文信息损失；反复出现。

### 现象

用户侧提示：

> 上下文已压缩，但总结模型调用失败，本次用的是截断摘要（要点可能不全）；下一次压缩会重新尝试完整总结。
> 失败原因：Bad state: 模型没有返回总结内容

### 已确认的代码事实（行号按**修复前**的版本；修复见下）

- 抛出点：`packages/tree_core/lib/src/llm/llm_summarizer.dart:71`
  —— `summary.isEmpty` 就抛 `StateError('模型没有返回总结内容')`。
- 该实现**只收集 `LlmTextDelta`**（`llm_summarizer.dart:62-68`），忽略：
  - `LlmThinkingDelta`（`llm_types.dart:251`，正文是 thinking 时拿不到内容）
  - `LlmFinishEvent`（`llm_types.dart:280`，拿不到 `finish_reason`，无法区分"截断"与"真空"）
- 请求形状（`llm_summarizer.dart:52-60`）：只发一条 user 消息、`temperature: 0.2`、
  `max_tokens = min(成员 max_output_tokens, 2048)`（`_outputBudget`，`llm_summarizer.dart:84-88`）；
  **没有传 `reasoning_effort`**，也没有任何"关思考/限思考"的手段。
- 编解码只读 `choices[0].delta.content`（`openai_codec.dart:90-95`）：若端点忽略 `stream: true`
  返回**非流式**体（内容在 `message.content`），整轮**一个事件都不会产生** ⇒ 同样是"没有返回总结内容"。
- 线上模型配置 `config/models/deepseek-v4.1-flash.yaml`：`thinking: true`、`max_output_tokens: 65536`、
  `max_seqlen: 65536`；该 agent 覆盖 `reasoning_effort: high`。
  注意 `CoreModelConfig.thinking` 目前**未被任何请求路径消费**（仅解析与落盘），属既存事实。

### 复现结论（2026-10-01 真实端点实测）

用与核心**完全一致**的请求体（`stream:true` + `stream_options.include_usage` + `temperature:0.2`，
输入取真实会话的 12k 字总结输入）打 `deepseek-v4.1-flash`，三种变体对比：

| 变体 | 结果 | 正文 | 思考 | finish_reason | completion_tokens | 用时 |
| --- | --- | --- | --- | --- | --- | --- |
| A 现状 `max_tokens=2048` | **失败** | **0 字** | 4870 字符 | `length` | 2048（全花在思考上） | 12.2s |
| B `max_tokens=8192` | 成功 | 2470 字 | 9975 字符 | `stop` | 5092 | 26.5s |
| C `max_tokens=2048` + `reasoning_effort=low` | 成功 | 1799 字 | 1485 字符 | `stop` | 1432 | 8.6s |

> 变体 C 只用来验证"压思考"确实有效，**不是**采用的方案：总结要保持 agent 原有的思考模式（见下）。

**根因确认**：`max_tokens` 是"思考 + 正文"的**总预算**；2048 被思考吃满 ⇒ `finish_reason=length`
且正文一个字都没开始 ⇒ 抛 `StateError('模型没有返回总结内容')` ⇒ `_summarize` 回退成截断摘要并标 degraded。
输入越长思考越久，所以这**不是偶发**——长会话几乎必然失败（对应用户看到的"多次出现"）。

### 修复（2026-10-01）

`packages/tree_core/lib/src/llm/llm_summarizer.dart`：

1. **预算直接复用原模型的输出长度**：删掉"总结该短"这个独立口径（曾是 2048），
   改用模型/成员配置的 `max_output_tokens`（配置为 0 时不发送 `max_tokens`，与对话引擎同口径）。
   总结是 agent loop 的延续、摘要会成为后续每一轮的上下文底座，不该有比对话更紧的输出上限。
2. **沿用 agent 的思考档位**：请求带 `config.reasoningEffort`（与对话引擎同一来源、含成员级覆盖），
   修掉"对话用 high、总结不带档位"的不一致。
   （中途试过"另立 16384 口径"与"`reasoning_effort=low` 降档重试"，两个都按
   "总结要保持原思考模式、且不另立口径"撤销。）
3. **诊断**：消费 `LlmThinkingDelta` / `LlmFinishEvent`；正文为空时错误里带上
   `finish_reason` / 思考字数 / 输出上限，不再只有一句"没有返回总结内容"。

**修复后实测**（走生产入口 `LlmSummarizer.summarize`，真实端点 + 同一 12k 字输入）：

- 线上配置（模型 `max_output_tokens=65536` → 请求同值）+ 成员 `reasoning_effort=high`：
  **一次通过**，23.2s，总结 **2154 字**。
- 对照（修复前的 2048 预算）：思考 4870 字符吃满预算、`finish_reason=length`、正文 0 字 ⇒ 失败。

测试：`test/llm_summarizer_test.dart` 8/8 通过（含"首轮只有思考 → 降档重试成功"、
"两次都空 → 错误带 finish_reason"、"传输失败不重试"）；`tree_core` 全量 605 通过 / 1 跳过
（3 例 `mcp_client_liveness_test` 是并发压测下的既知抖动，单独跑 5/5 通过）。

### 遗留观察（未处理）

- **非流式响应体**：`SseParser` 只认 `data:` 行（`sse_parser.dart:24-42`），
  `OpenAiCodec.decodeChunk` 只读 `choices[0].delta.content`（`openai_codec.dart:90-95`）。
  若端点忽略 `stream:true` 返回普通 JSON（内容在 `message.content`），整轮**一个事件都不会产生**
  ⇒ 同样表现为"没有返回总结内容"。当前端点上未观察到（HTTP 200 + 正常 SSE），
  仅作为同类症状的**可能来源**记录，本轮未改传输层。
- **输出上限就是成员配置的那一个**：线上 agent 的 `max_output_tokens=0`（用模型默认 65536）。
  若有人把成员输出上限显式设成 2048，总结仍会因"思考吃满"失败——那是该配置的必然结果
  （错误信息现在会指明原因），不再是总结侧的独立口径。
- `CoreModelConfig.thinking`（模型 yaml 的 `thinking: true`）目前**没有任何请求路径消费**
  （只解析与落盘）——将来若要单独给总结关思考，这是现成的开关位。

---

## #5 插件面板「切到 agent 就没了 / 刷新就回不来」

**状态**：已修复（2026-10-01；前端 team 过滤 + 核心态缓存重放；前端 170 通过、核心 719 通过）
**影响**：Q12 插件布局在真机上**实际不可用**——插件声明了槽位也看不到面板；能看到的窗口只有"应用刚起来、还没选任何 agent"那一段。

### 现象（用户实测）

> 一开始有的，但我切到 tree 后好像就没了（我不确定是发消息前就没了还是发消息后没了）

补充：刷新 / 重连 GUI 后也不会回来（要等插件进程重启）。

### 根因 1：空 `team_id` 被当成"只属于未选 team"

槽位的 team 归属有两条来源，前端把它们当成了同一个东西：

| | 值 | 来源 |
| --- | --- | --- |
| 插件声明的 team | **空串** | `plugins.yaml` 的 `scope`（示例插件与默认配置都是空映射） |
| 当前 team | **非空** | `Agent.teamScopeId`：agent 自身 `team_id` 为空时**回退到 agent 自身 id**（`lib/ui/models/agent.dart:66`） |

`PluginUiRegistry._visible` 原是精确相等：`slot.teamId == _teamId`。于是"空 = 不限定归属"的槽位被拿去和"具体 team"比相等 ⇒ 永不匹配。选 agent 之前 `_teamId` 是空串、恰好相等 ⇒ 看得见；一连上 agent（`main_page.dart` 的 `_setTeamScope(targetAgent.teamScopeId)`）⇒ 全部滤掉。
**即：没在 `plugins.yaml` 里声明 `scope.team_id` 的插件面板永远不呈现。**

**修复**：空 `team_id` 与插件配置同义 = **不限定归属** ⇒ 任何 team 下都呈现（`slot.teamId.isEmpty || slot.teamId == _teamId`）；限定 team 的槽位仍要求精确匹配，跨 team 隔离不变。

### 根因 2：声明只发一次，核心不缓存

`ui/manifest` 只在插件 `hello` 之后发一次（示例插件 `_do_startup`），而 `PluginBus` 的广播是"当下有谁在听就发给谁"；前端 `PluginUiRegistry` 是内存态。所以下面三种时序都会让面板**永久消失**（直到插件进程重启）：前端刷新 / 重连；插件比前端先就绪（启动竞态）；前端断线期间插件重启。

**修复**：核心缓存每个插件**最后一个生效**的 UI 帧（`PluginUiCache`，挂在 `PluginBus` 的**唯一广播出口**上——这样执行站 `ui.push` 的卡片也自动入缓存），新连接注册时**只重放给那一条连接**（`CoreServer._replayPluginUi`，不广播：否则每次有人重连都会让所有连接重刷面板）；插件下线（`_disconnect`）即作废缓存。

### 修复途中踩到的坑（已由测试钉住）

`PluginUiCache.record` 最初按"帧里读到的 team_id"判归属是否变化。`plugin_status` / `plugin_event` **不带** `team_id` ⇒ 被当成"归属变成空" ⇒ 把刚存下的 manifest 整条作废 ⇒ 缓存永远是空的、重放永远没内容（真机表现与修复前一样）。现在**先按帧类型挡在外面**，非 UI 帧不参与归属判定。

### 验证

- `test/plugin_ui_registry_test.dart`：新增真机回归（空 scope 插件的 activity/panel 槽位在 `agent 回退 id` 作 team 作用域时可见、跨 team 切换仍可见、而限定 `t2` 的槽位在 `team-2` 下仍隐藏）。
- `test/plugin_ui_bridge_test.dart`：缓存 8 例（重放顺序 manifest 先于 update、同类型只留最后一个、多插件字典序、归属变化作废、下线作废、非 UI 帧不得清缓存）。
- `test/plugin_ui_replay_test.dart`（新）：真插件 → 真核心 → 真 WS——后连客户端收到补发的 `plugin_ui_manifest` 且**既有连接一帧都不多收**；插件下线后新连接不再收到该插件槽位。
- 全量：`tree_core` 719 通过 / 1 跳过，前端 170 通过，`tree_protocol` 29 通过，三处 analyze 零 issue。
  （`-j 4` 并发跑时 `message_interrupt_test` / `questions_api_test` 各有 1 例假失败，单独跑与默认并发全量均通过——属并发压测下的既知抖动，非本次改动引入。）

