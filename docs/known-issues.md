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

---

## #MCP 服务「首次信任确认」是死链（`needs_confirmation` 从未下发）

**状态**：**未处理**（2026-10-02 记录；用户口径：与 MCP 传输/懒连接那次改动分开，另开任务）。
**影响**：MCP 面板上"非可信启动器注册的服务需用户确认后再启动"这条安全链路**完全不生效**——
不会提示、不会拒绝启动，`McpTrustStore` 里存的口令也没人读。

### 现象

- 面板代码读取 `service['needs_confirmation']`，但核心从不返回该字段 ⇒ 恒为 `false`
  ⇒ `_confirmTrustIfNeeded()` 直接 return，`_promptTrust()` / 徽标永不出现。
- `McpTrustStore.checkLaunch(...)`（"宿主侧据此拒绝启动"的判定）**没有任何生产调用点**，只有单测在调。

### 根因与证据

- 核心全仓 grep `needs_confirmation` **0 命中**（`packages/tree_core`、`packages/tree_core_cli`）：
  `McpServerConfig.toApiJson()` 只给 name/transport/command/args/url/headers/builtin/enabled/scope。
- `lib/io/mcp_trust_store.dart` 只有定义与测试引用：`grep checkLaunch|isTrusted lib` 的命中全在
  `mcp_trust_store.dart` 自身与 `mcp_config_panel.dart` 的展示态计算。
- 信任结果存在**前端本地**（SharedPreferences），而"拒绝启动"必须发生在**核心**——两者之间没有通道：
  这是 M6a 留下的设计缺口（不是实现 bug）。

### 修复方向（待定夺）

1. 判定：由核心计算 `needs_confirmation`（需先定口径：所有 stdio 服务首次都要确认 / 仅非白名单启动器 /
   仅非面板渠道注册的服务）；
2. 存放：确认结果落到**核心侧**（`mcp.yaml` 该条目加 `trusted`），否则核心无从"拒绝启动"；
3. 执行：`McpService._connect` 前检查，未受信 ⇒ 拒绝连接 + 可读错误（文案沿用 `checkLaunch` 的语义），
   面板一键确认（新增 REST 动作或复用 POST 注册带 `trusted`）；
4. HTTP 传输不执行本地命令 ⇒ 不参与该流程。


---

## #6 重建的历史与「实发那一份」不逐字一致 → 长会话前缀缓存只命中 system 提示词

**状态**：**已修复**（2026-10-02；`tree_core` 816 通过 / 0 失败，新增回归用例钉住不变量）。
**影响**：长会话每发一条新消息，端点（DeepSeek 上下文缓存）只命中 ~12k token —— 正好是
system 提示词 + 压缩摘要，其余 **373k 全部按未命中价计费**；工具循环的每一跳同理。
即"发消息启动 tool loop 会对消息产生破坏性更改"。

### 现象（真机）

- 同一会话连续两次请求：`373,899 / 1,027` 与 `373,857 / 1,068`，**缓存命中都只有 12,288**。
- 数据现场：`%APPDATA%\Tree\data\agt_1790406811628_73afa9_44\ses_1790864583576_01e5cd_3`
  （905 条消息 / 水位线 192；system 提示词 12,018 字符 + 摘要 2,293 字符 ≈ 12k token）。

### 根因：`_buildMessages` 是**重新推导**，而不是复用"当初发出去的那份字节"

端点前缀缓存只在**逐字相同**的公共前缀上命中。重建路径有四处与实发不同（每一处都足以
让缓存从该条消息起整段落空）：

| # | 消息 | 实发（`LlmSession`） | 重建（`LlmAgentEngine._buildMessages`） |
| --- | --- | --- | --- |
| 1 | assistant 的 `tool_calls[].function.arguments` | 模型**原始流式串**（`llm_session.dart:376-383`，含空格/原样转义） | `jsonEncode(解析后的 Map)` → 规范形态，字节不同 |
| 2 | `role: tool` 的 content | `sessionStatusText`（含 `结果返回时间：<秒>`，`status_text.dart:13-18`）+ 门控结果 | 只有门控结果（状态前缀整段丢失） |
| 3 | 超长结果的重定向文件名 | `.self/results/<DateTime.now()>_<每次 run 从 1 起的序号>.<工具名>.result`（`llm_result_gate.dart` 原 `_nextPath`） | 每轮换名字 ⇒ 每轮**重写一份内容相同的文件**，提示里的路径逐轮变化 |
| 4 | 同一跳的"正文 + tool_calls" | **同一条** assistant（content + tool_calls） | 拆成"正文一条 + tool_calls 一条"；`reasoning_content` 还被 `trim()` 重排 |

证据（各处实测）：

- 消息 1：用真实数据 + 真实引擎重建请求，第 2 条消息（system/摘要之后第一条）就是那条
  `tool_calls` assistant：实发 `{"file_path": "notes/hello.txt", "start_line": 1}`、
  重建 `{"file_path":"notes/hello.txt","start_line":1}`。在有 373k 上下文的真机会话里，
  这条消息正好紧跟 system+摘要 ⇒ 缓存命中停在 ~12k。
- 消息 3：`E:\programs\Tree\desktop\.self\results\` 里 **42 个文件只有 14 份不同内容**；
  同一份 23,081 字符的 read 结果被写成 `20261002_103401_001` … `20261002_121305_001`
  **共 13 个文件**（`_cache` / `_seq` 是"每个 run 一个门控实例"，历史翻译每轮都会重跑一遍）。
- 复现用例：`packages/tree_core/test/llm_prefix_stability_test.dart`（修复前两条用例分别在
  消息 2 / 消息 3 处报"与上一轮实发不一致"；修复后全绿）。

### 修复（2026-10-02）

1. **落库"送模型的那一份"，重建时原样取用**（不再重新推导）：
   - `CoreMessage.toolArgumentsRaw` / `toolResultForModel`（`records.dart`，键
     `tool_arguments_raw` / `tool_result_for_model`，空则不写，老会话文件零变化）；
   - 实发时定稿：`LlmSession` 把原始参数串与"状态前缀 + 门控结果"随事件带出
     （`AgentToolStart.rawArguments` / `AgentToolEnd.modelContent`），
     `ConversationService` 落库；重建优先取这两份，缺了才回退旧口径。
2. **重定向落点改成内容指纹**：`.self/results/<工具名>_<FNV-1a 64 指纹>.result`
   （`ToolResultGate.fingerprint`，纯整数运算、无新依赖）——同一份结果永远同一个路径，
   不再每轮堆文件，提示文本逐字稳定。
3. **同跳正文与 tool_calls 合成一条** assistant、`reasoning_content` 逐字保留（不 trim、
   不插分隔符）：重建出来的消息序列与实发的**结构**也一致。

### 遗留（须知）

- **修复前落库的老消息**没有 `tool_arguments_raw` / `tool_result_for_model`，只能按旧口径
  推导 ⇒ 老会话里那些消息所在位置仍会对不齐。等它们被压缩 / 滚出窗口（或手动压缩一次，
  保留窗只剩新的几轮）后，缓存命中就能恢复到接近全量。
- 若端点把 `tool_calls.arguments` 原样规范化输出（与 `jsonEncode` 同形），老消息第 1 处
  差异不存在；第 2、3、4 处差异与端点无关，必然存在。

---

## #7 本地执行被「等输入」的子进程永久挂死（裸 `echo` 触发）

**状态**：**已修复**（2026-10-02）。三处：① `-NonInteractive` + 关掉子进程 stdin；
② 本地**软**超时 → hook 模式（超时不再杀进程、转后台并在结束时唤醒 agent）；
③ terminal 提示词写明 hook 模式可以"做别的事 / 直接结束本轮等唤醒"。
回归用例：`tree_local_exec/test/exec_no_interactive_hang_test.dart`、`exec_soft_timeout_test.dart`、
`tree_core/test/terminal_soft_timeout_test.dart`。**需重建核心 exe 才对安装版生效**。

**影响**：一次 terminal 调用就能把整轮会话卡死——**没有超时、没有取消路径**，模型只能干等，
用户看得到「工具执行中，请稍候…」却永远不会返回。

### 现象（真机）

- 2026-10-02 13:01:23，会话 `ses_1790864583576_01e5cd_3` 发起
  `echo "=== 上轮文件最近提交 ==="; git log --oneline -3 -- …; echo; echo "=== README/known-issues … ==="; …`，
  到 13:15 仍未返回（>13 分钟），UI 一直「工具执行中」。
- 进程现场（`Get-CimInstance Win32_Process`）：`pwsh.exe` PID 39276（父进程 `tree_core.exe`）活着、
  CPU 0.65s、**4 秒内读写计数一个都不动**、没有任何子进程；同轮 `conhost.exe` 是它的 console。
- 把它的 console 附上来读屏（`AttachConsole` + `ReadConsoleOutputCharacterW`）只有三行：

  ```
  cmdlet Write-Output 位于命令管道位置 1
  请提供以下参数的值:
  InputObject:
  ```

  —— PowerShell **正在等 stdin 输参数**（读屏时探针自己的输出正好接在 `InputObject:` 光标后，可佐证光标停在那里）。

### 根因：两条各自"合理"的设计叠在一起

1. `echo` 在 PowerShell 里是 `Write-Output` 的别名，而它的 `-InputObject` 是**必填**参数：
   裸 `echo;`（无参数）⇒ PowerShell 弹参数提示并**读 stdin**。
2. `LocalWorkspaceIO.exec` 用 `Process.start(..., runInShell: false)`，Dart 侧给子进程的 stdin 是
   **一条永不写入、也永不关闭的管道**（没有任何一处关过它）；而本地执行的活性判据是
   「进程还活着」（`local_workspace_io.dart:435-437`，M9 1.1 明令取消静态总时长硬超时）
   ⇒ 没人喂输入、也不判超时 ⇒ **永久等待**。

即：**只要命令里有任何一处会读 stdin 的写法（裸 `echo`、`Read-Host`、git 凭据提示、`pause`/`choice`、REPL），
本地执行就会永久挂住。**

### 证据（可复现）

用包自己的 `Shell.argsFor` + `Process.start` 逐条实测（一次性探针已删，结论固化进新用例）：

| 用例 | 命令 | 结果 |
| --- | --- | --- |
| A | `echo; echo after-bare-echo` | **10s 不返回**（超时后杀掉），stdout 空 |
| B | `echo "hello"; echo "world"` | 593ms 退出，码 0 |
| C | 现场那条命令（含裸 `echo;`） | **10s 不返回**，stdout 已吐出首个 `echo` 与两条 `git log` 结果 |
| D | 同 A，但 spawn 后 `stdin.close()` | 707ms 退出，stderr `Write-Output: … 缺少一个或多个必需参数: InputObject。` |
| E | 同 A，参数加 `-NonInteractive` | 699ms 退出，同上 stderr |

### 修复（2026-10-02）

1. **`Shell.argsFor` / `Shell.argsForScript` 加 `-NonInteractive`**：PowerShell 的参数提示、
   `Read-Host` 之类**立刻变成错误**，而不是等输入（D/E 实测）。
2. **spawn 后立刻关掉子进程 stdin**：`LocalWorkspaceIO.exec`（`await process.stdin.close()`）与
   `TerminalHooks.start`（后台 hook 同理）——原生子进程（git 凭据、`pause`、REPL）也只拿到
   EOF 报错，不再静默挂死。

### 验证（2026-10-02）

- `tree_local_exec`：**159 通过 / 1 跳过**（新增"裸 echo 不挂"与"软超时交出活着的进程"两组用例），
  `dart analyze lib test` 干净；
- `tree_core`：**823 通过 / 1 跳过**（新增 `test/terminal_soft_timeout_test.dart`：软超时转后台 +
  结束回调唤醒 + 提示词断言），`dart analyze lib test` 干净。

### 兼容层：裸 echo 直接补成空串（2026-10-02）

`-NonInteractive` + 关 stdin 只是"让它别再挂死"，根因还在：模型照 cmd 习惯写裸 `echo;`。
与 `&&` / `||` 的处理同一路数，现在在包装层直接兼容：

- `Shell.translateBareEcho` 把**命令位置上无参**的 `echo` / `write-output` 补成 `echo ''`
  （cmd 语义：输出一个空行）。只认命令位置，且后面必须紧跟 `;` / 换行 / `|` / `)` / `}` / 行注释 / 结尾，
  所以 `echo hi`、`echo $x`、`function echo {}`、引号内的 `echo` 一律不动；拿不准（引号不闭合、
  here-string、块注释）整体原样返回——与 `translateLogicalOperators` 同一条"保守回退"口径。
- 接线顺序：**先** `translateBareEcho`（在模型原始命令上认命令位置最准）**再**折叠 `&&` / `||`。
- 于是三层防护：① 兼容翻译（不再进入交互）；② `-NonInteractive`（其余提示立刻报错）；
  ③ 关掉子进程 stdin（原生子进程只拿 EOF）。第 ④ 层才是 300s 软超时转后台。
- 用例：`test/shell_translate_test.dart` 新增"裸 echo 兼容翻译"组（补空串 / 不动的情况 / 保守回退 +
  包装层接线），`test/exec_no_interactive_hang_test.dart` 新增"裸 echo 真的输出一个空行"（真机跑）。

### 遗留项：本地软超时 → hook 模式（2026-10-02 已实现）

原来只有远端 `adoptDetached` 有"不终止、转后台"的兜底；本地是"进程活着就永不超时"，
所以卡死的命令只能靠手杀。现在本地也接上了：

- `LocalWorkspaceIO.exec(timeout:)` 的语义改回可用，但是**软**的：到点仍在跑就
  **不杀进程、不丢输出**，抛 `LocalExecStillRunning`（携带 `RunningLocalExec`：pid、退出码 future、
  输出快照）；`Duration.zero`（默认）= 永不软超时（老行为）。
- terminal 接住它：`TerminalHooks.adoptRunning` 把**还活着的本机进程**登记成后台任务——
  `HookTask.process` 非空 ⇒ `hook_action=cancel` 杀得掉；退出时补写"完整输出"到日志并回调
  `onFinished` ⇒ 经 `conversation.wake` 自动唤醒 agent；返回文本写明"本轮不必继续等它：可以
  接着做别的事，或者**直接结束本轮**，结束时自动唤醒你"。
- 缺省软超时 **300s**（`timeout_seconds`，0 = 永不软超时）；**没接 hook 时不启用**——登记不了
  后台任务时，老口径"一直等"反而更诚实。
- 提示词（terminal 的工具描述）同步写明：`hook` 模式下可以接着做别的事、或者直接结束本轮
  （结束 tool loop），任务结束会把 `[terminal hook]` 完成提示注入会话把你唤醒。

仍留在桌上的：

- 事故里那两次已发出的命令都是**手动杀掉**（`taskkill /PID <pid> /T /F`）才让会话继续的；
  修复只对重建核心之后新起的命令生效。
- SSH 失联转后台的 `detached` 任务**不会**自动唤醒（本机拿不到远端退出），返回文本现在也如实
  写了这一点，避免模型干等。

---

## #8 核心重启后「冷 → 热」的 Spec 快照让 `[0]` 换字节 ⇒ 整条前缀缓存作废（0 命中）

**状态**：**已修复**（2026-10-02；按用户要求把系统提示词**按会话钉住**）。
**影响**：核心重启后的前 1~2 条消息会**整条前缀 miss**（68k 会话按全价付一次）；修复前用户连续遇到两次。

### 现象（用户第三次反馈，含对我的关键更正）

- 用户原话：**"压缩后是 32k，跑了一圈后再发消息变成了 68k。再发消息结果 0 命中"**。
- 卡片：`68,049 / 1,132`（无缓存行 = 0 命中）→ `73,560 / 1,205`（缓存 72,832）→
  `72,874 / 462`（缓存 71,936）。**同一轮内**第 2/3 跳 98.7%~99%（历史逐跳稳定），
  只有"新消息的第一跳"整条 miss。
- 我第一版结论（"压缩那一跳的固有代价"）**是错的**：压缩把 prompt 从 490k 压到 32k，而对不上
  的那一跳是**压缩之后又跑完一轮**才发的（用户更正）。

### 根因：⑦ 索引 / ⑧ 已选全文两处快照是**异步**补热的

`SpecService` 的 `indexSnapshot()` 冷的时候返回 `renderIndex(_builtinDocuments())`（只有内置模板）
并起一个后台全量扫描；`selectedSpecsSnapshot()` 冷的时候返回**空串**（整段不注入）再后台补扫。
它们拼进 `systemPromptWithWorkspace()`，也就是消息序列的 `[0] system`。

真机量化（本机数据 + 真实代码，2026-10-02）：

| | ⑦ Spec 索引 | ⑧ 已选 Spec 全文 | 两段合计 |
| --- | --- | --- | --- |
| **冷**（重启后、还没扫过） | 623 字（只有 4 条内置模板） | **0 字** | 865 字 |
| **热**（后台补扫完成） | 908 字（多出工作空间的 `desktop` / `flaky`） | **7,388 字**（`general-task` 全文） | 8,567 字 |

第一处不同在第 **645** 字 ⇒ 从 `[0]` 里那一点往后**全部**是新字节；而 `[0]` 在消息最前面，
整条前缀（含 68k 历史）因此全部对不上 ⇒ 0 命中。时间线也对得上：核心 13:34:56 重启（冷），
第一轮用冷串（32k），后台扫完，**下一轮**用热串（68k）⇒ 0 命中。

### 修复（2026-10-02，按用户要求定稿：**中间不切 system prompt**）

用户原话：**"要求在中间不切 system prompt（用快照），system prompt 只在会话初始化或
compact 后，发消息不引起系统提示词更新"**。据此实现：

1. **按会话钉住**：`ConversationService._systemPrompts`（键 `agentId|sessionId`）。
   `_contextOf` 取的是**钉住值**，不是每轮现拼。
2. **只有三处重建**：
   - 会话初始化（本进程第一次为该会话拼装）；
   - **compact 之后**（每轮入口的自动压缩 + 工具循环内压缩都算）——此时前缀本来就要重写，
     重建不额外亏；
   - `invalidateSystemPrompt`：用户**显式**改 agent 配置（`PATCH /api/agents`）或重置工作空间
     （`POST …/reset`）时调用。**发消息永远不调它**。
3. **重建前先热 ⑦/⑧ 快照**：`SpecService.ensureSnapshots(agentId, sessionId)` 只在冷的时候真的扫一次，
   由 `ConversationService.promptStatePrewarm` 在**拼 `AgentRunContext` 之前** await（必须在这里：
   `systemPrompt` 进引擎前就拼好了）。这样重启后的第一轮直接拿到"热串"，与重启前逐字相同，
   跨重启也不再白丢一次。

### 这个决定的直接后果（须知）

- 会话**中途** `spec select / create / update` 不再立即改变系统提示词：
  `spec select` 仍会把规范全文作为**工具结果**返回（当轮模型看得到），但 ⑧ 章进 system 要等下一次
  compact。这是"发消息不重建"的必然代价；如果希望"显式挂规范立刻生效"，可以在 `spec` 工具成功时
  也失效一次（那属于用户/模型的显式动作，不是发消息）——**目前未做，待定夺**。
- 每跳 usage 仍不落库（`messages.jsonl` 只记每轮最后一跳），排查只能靠卡片 + 落盘行对数字。

### 配套策略：工具表**按"发消息"刷新**，不进钉住（2026-10-02 用户要求）

用户原话：**"system prompt 不中途重建，但 MCP 与 plugin 产生的工具至少要在每次发消息时刷新"**。

- 工具表在请求体的 `tools` 字段里，**不参与消息前缀** ⇒ 每次刷新不伤缓存；
  系统提示词在第 0 条消息里 ⇒ 一变就整条前缀作废。两者因此是不同处置：一个钉住、一个每轮现取。
- 现状（未改代码，本来就是刷新语义）：`LlmAgentEngine.run` 每次运行都调
  `toolRunner.specsFor(agentId, sessionId)`；`WorkspaceToolRunner.specsFor` 现取
  `McpService.allTools()` 与 `PluginTool.dynamicSpecsFor(...)`（后者是"缓存 + 失效点"，
  插件上线 / 下线 / 重启后下一次取用即更新）。源码里那句注释就是这条口径：
  "**工具表刷新处**（模型每轮生成前都走这里）"。
- **防回归用例**：`test/tool_list_refresh_test.dart`——第二轮"服务就绪"后新工具
  （`mcp__demo__ping`）必须立刻出现在该轮请求的 `tools` 里，**同时**系统提示词仍是第一轮那串
  字节。谁把工具表缓存进"钉住的上下文"，这条就红。既有的插件侧覆盖见
  `test/plugin_tool_table_test.dart`（上线/下线 ⇒ 工具表变化 + 缓存失效点）与 `plugin_hot_apply_test.dart`。
- 范围：**同一轮内**（tool loop 的后续跳）工具表在 `LlmSession` 里固定——符合"每次发消息刷新"；
  若要"每一跳都刷新"需在 `LlmSession` 每跳重取（tools 不在前缀里，不影响缓存），**目前未做**。

### 验证（2026-10-02）

- 新增 `test/tool_list_refresh_test.dart`（工具表每轮现取 + 系统提示词不变）。
- 新增 `test/system_prompt_pin_test.dart`：① 外部来源（Spec 索引 provider）变了，第二轮**仍是同一串
  字节**；② `invalidateSystemPrompt` 之后才重建。
- `tree_core` 全量 **823 通过 / 1 跳过**，`dart analyze lib test` 干净。

---

## #9 leader 在团队会话里 `wait_for` 后再无回复 + 成员干活的会话与用户所在会话不一致

### 现象（用户真机，2026-10-02 14:30–14:32）

Test 团队（leader `agt_1790848305616_be41c9_3`，成员 Developer `member_1790922416419_8ad203_d`）：

1. 用户在 **Test 的团队会话**里说"让他写一个 hello world 的 .http"：leader 派发成功（`message send_message`
   卡片刻着成员 id），接着 `wait_for` 卡片返回 `outcome: completed`——**然后这个会话就再没有
   任何回复**（用户原话："wait_for 结束后 Test 竟然没被唤醒"）；
2. teammates 窗口里 Developer 全程像"没反应"（进度页/日志 Tab 都是空的）；
3. Developer 的交付回信出现在 **Test 的默认会话**里，而不是用户发消息的那个会话（用户原话：
   "Developer 的回信被发到了 Test 的默认会话"）。成员自己则是在**它自己的默认会话**里干完的活。

### 证据（本机数据）

- `data/agt_...be41c9_3/ses_1790921516531_3927f4_3/messages.jsonl`：最后一条就是
  `tool_name=message / action=wait_for` 的工具结果（14:31:08），其后再无任何 agent 消息。
- `data/member_...8ad203_d/session_default/messages.jsonl`：Developer 干活全过程（派活消息 + write + read +
  terminal + 汇报 + 最终文本）——**不在团队会话里**。
- `data/agt_...be41c9_3/session_default/messages.jsonl`：`[来自 Developer] 【任务完成】…`（14:31:00）
  与 Test 的回复（14:31:13）——回信落到了**默认会话**。
- `workspaces/member_...8ad203_d/.self/activity.log`：只有两行 `[start(成员)]/[done(成员)]`，
  证明成员**确实执行了**（不是没接单）。

### 根因 1：打断只按 agent 找在途轮次，跨会话也会被掐掉

- `ConversationService._interruptForNewMessage` 从 `_running[agentId]` 取在途 token，`deliver()`
  （团队消息，`conversation_service.dart` 的"团队消息也是有人对它说话"分支）与 `user_message` 一样
  会调用它；
- 取消是**协作式**的：`llm_session.dart` 的轮次循环开头就是
  `if (isCancelled()) { yield AgentDone(cancelled: true); return; }` ⇒ 被打断那一轮在**下一次 LLM 跳之前**
  就收尾，工具结果之后不会再有正文；
- `conversation_service.dart` 收尾时 `cancelled && token.interrupted` **刻意不推**"已停止本轮生成"
  （插话语义：用户刚发的话就是上下文）——于是另一个会话里表现为"答复凭空消失"。
- 本机时序完全对上：leader 14:30:42 起 `wait_for` → 14:31:00 成员回发触发 `deliver()`（落 leader 默认会话）
  → 在途 token 被置 cancelled → 14:31:08 `wait_for` 返回并落 tool 结果 → 下一跳发现 cancelled ⇒ 直接收尾。

### 根因 2：agent 侧派活的会话缺省与用户侧不一致

- `message` 工具的 `session_id` 缺省是 `session_default`（`TeamMessageDispatcher._sessionOf`）；
- 用户侧接口 `POST /api/agents/{leaderId}/teammate/{memberId}/message` 则**带当前会话**
  （`lib/io/api_service.dart` 的注释写得很清楚："不传则落到默认会话，成员进度不会出现在当前 teammates 窗口"）；
- `TeammateDetailPage` 的历史（`getConversationHistory(memberId, sessionId)`）与实时帧（`session_id`
  不等于当前会话就丢弃）都按当前会话过滤 ⇒ 派活落到成员默认会话、回信落到 leader 默认会话时，
  用户在团队会话里两头都看不到。

### 修复（2026-10-02）

1. **运行链改成会话级：同一 agent 的不同会话并行**（`packages/tree_core/lib/src/agent/conversation_service.dart`）：
   运行键从 `agentId` 改成 `agentId|sessionId`（`_RunToken` 记 `agentId` + `sessionId`，`_chains` / `_running`
   都按它索引）⇒ **跨会话的消息既不打断、也不排队**（两条链并行发言），同一会话内仍串行、仍会插话打断
   （同一会话的流式片段交错会污染前端 `msg_chunk` 追加）。配套三处：
   - `_interruptForNewMessage(agentId, sessionId:)` 只找本会话那条链，并且只 `questions.cancelForSession`
     （别的会话可能也在等人回答，不能一起取消）；
   - `cancelAgent`（`stop`）是 **agent 级**的：该 agent 的每个在途会话都要取消（epoch 仍按 agent 作废排队任务）；
   - `agent_status` 的 `idle` 只在"该 agent 一个在途轮次都不剩"时才广播——前端 working 集合是按 agent 记的，
     否则会话 A 先结束会给还在跑会话 B 的 agent 误报"空闲"。
   理由：各会话历史互相独立，在途那一轮**根本看不到**别的会话的消息；跨会话打断只会白白毁掉那一轮的答复。
2. **派活/回发继承发起会话**（`packages/tree_core/lib/src/tool/message_tool.dart`）：
   `MessageTool.run` 在 `session_id` 缺省时补 `invocation.sessionId`（`ToolInvocation` 本来就带会话），
   显式传 `session_id` 的调用方仍然优先；schema 描述同步改为"缺省 = 发起这一跳的会话"。
   派活落发起会话后，成员的执行与回信都留在同一个会话里，teammates 窗口与主会话都能看到。
3. **成员与 team leader 共享工作目录**（新增 `packages/tree_core/lib/src/team/team_workspace.dart`）：
   `teamWorkspaceFor(agent, lookup)` 一路向上解析到团队 TOP，返回 `owner` + `owner.workspace_dir`；
   **成员自己 yaml 里的 `workspace_dir` 不生效**（否则"共享"就成了可被旧配置悄悄覆盖的软约定）。
   四个解析点全部改走它：CLI 的 `WorkspaceToolRunner.resolveWorkspaceDir`（**工具根**）、
   CLI 的 `TeamMessageDispatcher.workspaceDirOf`（文件投递 / 活动日志）、`FileService.rootFor`（文件面板）、
   以及系统提示词里的 `teamWorkspaceProvider`（接线在 `CoreServer.start`，`close` 时按身份解绑）。
   TOP 自身 owner == 自己 ⇒ **既有 agent 的工具根与提示词字节完全不变**（不碰前缀缓存）。
   旧成员无需迁移：它是 `workspace_dir: ""`，解析时自然跟到 TOP。
4. **成员在左栏的可见性（同日二改）**：先判"成员不独立出现在左栏"（列表只喂 `teamId` 为空的顶层
   agent），同日**二改为允许出现**——左栏列出全部 agent，`railAgentsOf` 只决定顺序（顶层在前、成员紧跟
   它的 TOP，找不到 TOP 的兜底列在末尾），不再过滤；`_agents` 本来就完整，按 id 找 agent（提问导航 /
   执行器注册 / 删除）不受影响。其余口径不变：成员仍复用 leader 的工作目录与 SSH（见第 3 条）。
5. **移除「消息切入设置」**：`ApiPaths.settingsMessageCutin` 常量、`CoreSettings.messageCutinDirect`
   （字段 / getter / setter / applyMap / toMap / extra 白名单）、`core_server` 的
   `GET|POST /api/settings/message-cutin` 两个端点与 `_getMessageCutin`/`_setMessageCutin`、
   前端的 `ApiService.set/getMessageCutinDirect` 与设置页「消息切入模式」卡片（含本地
   `message_cutin_direct` prefs）全部删掉；三个测试里的对应用例同步清理。
6. **私有状态按 agent 分栏：`<共享根>/.tree/<agent_id>/.self/`**（新增
   `packages/tree_core/lib/src/agent/private_workspace_io.dart`）：规范与工具提示里写的
   `.self/…` 是**模型口径**，由 `PrivateWorkspaceIO`（同时装饰 `WorkspaceIO` 与 `WorkspaceFiles`，
   在 `WorkspaceToolRunner._ioFor` 包一层 ⇒ 工具、Spec、系统提示词、结果门控、插件文档播种
   全部生效，本地与 SSH 共用一份）**单向**翻译成 `.tree/<agent_id>/.self/…`；活动日志路径
   （`memberLogPath` / `_activityPath`）同步改到该分栏。用装饰器而不是改常量：`.self` 这条口径
   散在规范文本、工具描述与 `SpecService.specDir` / `SystemPromptStore.promptPath` /
   `kPluginGuideWorkspacePath` / `ToolResultGate.resultsDir` 里，装饰器让它们一个都不用改。
   核心启动时把旧 `.self` **一次性迁移**到 TOP 的分栏（`migrateLegacySelfDir`，幂等）。
7. **成员跟随 leader 的 SSH**（`teamSshConfigFor`）：成员自己没有 `ssh:` 配置时用团队 TOP 那份

## #11 源码编辑器（着色 / 编辑保存 / 分屏）的边界与取舍


## #12 集成终端（Ctrl+J）的边界：VT 解析器覆盖到哪、PTY 与远程怎么算

**状态**：**已知边界 + 刻意取舍**（2026-10-02 定稿）。这一版给了真 PTY 的集成终端
（Windows ConPTY / POSIX `script`，前端自制 VT 解析器），下面这些是**故意**留的口径：

### VT 解析器没做 / 做得不完整的部分（v"真终端"体验的真实上限）

1. **没有回滚缓冲**：`CSI 3 J`(ED3) 等同无操作——往上翻看不到历史输出。
2. **没有制表位表**：TAB、`CSI I`/`Z` 固定 8 列步进；HTS(`ESC H`)、TBC(`CSI g`) 不生效。
3. **组合记号 / 零宽字符直接丢弃**，不做「贴到前一格合成」（某些语言的变音符会丢）。
4. **真彩被就近压成 256 色**：`38;2` / `38:2` 取三个数值折算；ITU T.416 的
   `38:2:<色空间>:r:g:b` 在色空间非空时会取值错位。
5. **未处理** SGR `21`（双下划线 / 关粗体）、`10–19`（字体）、`4:3`（花式下划线）。
6. **OSC 不解析内容**：窗口标题、OSC 8 超链接、OSC 52 剪贴板全丢。
7. **鼠标 / 焦点上报只记状态、不回写**（`?1000`–`?1006`、`?1004`）；`?2004` / `?1` 也只暴露状态。
8. **不支持 8 位 C1 控制码**（`0x9B` 等）。
9. **备用屏只有一块主屏快照**，无多屏栈。
10. 光标键模式（DECCKM）、原点模式已生效，但行内编辑不做字符集级细节（charset 切换不生效）。

**结论**：`cmd`/`powershell`、`git`、`npm`/`pnpm`、`python -i`、交互式 REPL 这类
「逐行 + 颜色 + 清屏」的程序没问题；**`vim` / `top` 能进备用屏、能画界面、能用方向键与
Ctrl+C，但没有回滚、组合字符会丢**——离"能长期当主力编辑器用"还差上面 1/3/6/7 这几项。

### 只支持本机 agent（刻意）

agent 配了 SSH 时终端直接回可读错误：SSH 通道只有一次性 `exec`，没有伪终端与流式会话。
判据是「这个 agent 配了 SSH」而不是「远端后端接线了没有」——不给用户留下"能开但打不了字"的错觉。

### 没跑真机端到端

- 核心：会话生命周期（开 / 写 / 改尺寸 / 退出 / 断连收尾 / 五种拒绝）有 8 个单测，PTY 平台实现
  另有自己的单测（见 `tree_local_exec` 的 README）；**没有在真机上开过 Tree 应用**跑一遍。
- 前端：VT 解析器 36 例、终端面板 10 例（假 WS）；**渲染效果没有在真窗口里肉眼验收过**。
- 因此"端到端串起来是否顺滑"（焦点、尺寸换算、中文输入、滚动）只能等第一次真机使用时才算数。
