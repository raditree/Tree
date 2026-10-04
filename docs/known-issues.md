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

**状态**：已修复（2026-10-01；已接线到设置页现成的开关）；**2026-10-03 复发一次并加严修补**
（判据是"键在不在"、空串即可——见本节末尾）
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

### 2026-10-03 复发：判据是"**键在不在**"，不是"有没有正文"

**现场**（会话 `data/agt_1790845986535_e7df51_3/ses_1790927742041_b5d93d_72/messages.jsonl`，
契门，10:10:41 —— 逐条来自落库文件，非推测）：

| # | 时间 | kind | 内容 |
|---|---|---|---|
| 871 | 10:10:38.069 | tool | `set_todo_list`（本轮最后一个工具结果） |
| 872 | 10:10:41.499 | **user** | `[来自 凌川] ①②③④ 已全部落进 M4_REPORT.md…`（**插话**，打断在途那一轮） |
| 873 | 10:10:41.505 | text | 被打断那一轮的收尾正文（`## 汇报：第三方独立复核通过（4/4）…`，**没有思考卡**——这一跳模型没产出思考） |
| 874 | 10:10:41.966 | text(`llm_hidden`) | `模型端点返回 HTTP 400：…reasoning_content…`（插话触发的新一轮，请求以 873 收尾） |

⇒ 与 recon 的 **D6** 形态逐字相同：**请求以"没有 `reasoning_content` 的 assistant"收尾**。
"批中途注入"（recon-addendum）那条路已经堵住，这一条是**新的可达路径**：插话落在收尾正文
**之前**落库，而那条正文这一跳**根本没有思考**可挂。

**补测（第五轮探针，`.output/probe_thinking_empty.ps1`，4 个最小请求、`max_tokens=16`）**：

| 用例 | 形状（带 `tools`） | 结果 |
|---|---|---|
| H1 | 末尾 `assistant(text)` + `reasoning_content: ""` | **200** |
| H2 | 末尾 `assistant(tool_calls)` + `tool`，assistant 带 `reasoning_content: ""` | **200** |
| H3 | 末尾 `assistant(text)`，**整个键不给** | **400**（与现场报错逐字一致） |
| H4 | 末尾 `assistant(tool_calls)` + `tool`，带 `reasoning_content: "先读文件"` | 200 |

**结论（比 11.1 更精确）**：端点只检查**键在不在**，不检查内容。所以
"这一跳没有思考可回传"的正确表达是 `reasoning_content: ""`，**省略键才是 400**。

**修复**：思考模型的**每条 assistant**（历史翻译那份 + 工具循环在途那份）一律带这个键——
有思考正文就带正文，没有就带空串；非思考模型（`thinking: false`）一个键都不发
（OpenAI 系端点拒绝不认识的字段）。打标与消息位置无关，前缀缓存因此也不会因为
"同一条消息这次在末尾、下次在中间"而变字节。

**测试**：`test/reasoning_key_test.dart`（7 条：线协议空串/正文/缺键三态、往返保住标记、
真机现场形态、G1/G3 形态、有思考卡时仍回传正文、非思考模型不发键、`LlmSession` 在途那一跳）；
`test/notice_translation_test.dart` 的"防御哨兵"改成断言"带空串键"（原来只断言"留了日志"）。

---

## #2 压缩降级：`Bad state: 模型没有返回总结内容`

**状态**：已修复（2026-10-01；总结**复用原模型输出长度** + 沿用 agent 思考档位；单测 9/9、真实端点实测）
**影响**：压缩退化成截断摘要（要点可能不全），长任务上下文信息损失；反复出现。

### 现象

用户侧提示：

> 上下文已压缩，但总结模型调用失败，本次用的是截断摘要（要点可能不全）；下一次压缩会重新尝试完整总结。
> 失败原因：Bad state: 模型没有返回总结内容

> ⚠ **1.0.1 起文案变了**（唯一生成点：`packages/tree_core/lib/src/agent/conversation_service.dart`
> 的 `_notifyCompacted()`，自动压缩与手动压缩共用同一条口径）：
> 首行是 `上下文已压缩（来源：内置压缩｜插件中转站），当前 N 条`；降级原因（`但总结模型调用失败…失败原因：…`）
> 与"插件未接管"原因作为**后续行**附在同一条通知里。注意两档口径**不合并**：
> 早退型没接管（总开关关 / 没订阅该点位）**不写进**会话通知，但 REST 响应的 `relay_skip_reason` 仍然**全量**。

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

- **只编辑纯文本**：图片 / PDF / Office 这类复杂格式一律只读（写回去等于毁文件）；含 NUL 的二进制同样只读；
  **被截断的大文件**也只读——保存等于把文件截短。三种拒因都在标题栏如实写出来，不是灰着不给点。
- **分屏里同一个文件的两个窗格共享一份缓冲**（不是两份各写各的缓冲）：同一个 `CodeEditingController` + 一份
  `dirty` / `saving` / `loadedSize`（`lib/ui/services/editor_buffer.dart`），一边打字另一边立刻可见，
  谁保存都只发一次 PUT 且两边一起变成已保存 ⇒ **不存在"两份缓冲互相覆盖"**。此前"非活动窗格强制只读"的口径已被推翻；
  控制器归缓冲所有，同文件双开时先关掉的那个窗格不会 dispose 它，两个窗格都关掉才释放。
- **外部改动靠 `if_size` 检测**：保存时带上"我读到的那份大小"，磁盘现值不符 ⇒ 409 ⇒ 让用户在
  「覆盖保存（force）/ 放弃我的改动并刷新 / 取消」里选，绝不静默覆盖别人的改动。
- **编码跟随工作空间 IO**：UTF-8 文件写 UTF-8；原本不是 UTF-8 的按原代码页写回，**绝不静默转码**
  （宁可失败，也不把用户的 GBK 文件变成乱码）；新内容 > 1 MiB 时按 UTF-8。
- **自动保存只有"失焦"与"离开"两种触发**（可在设置里关掉改成纯手动 Ctrl+S），**没有定时器**：
  定时写入会打断正在输入的思路，而"每次按键都写盘"会把编辑器变成磁盘压力源。
- 前端把"源码"这一档叫**代码视图**（着色 + 可编辑），"文本"那一档仍是只读的 `SelectableText`。

## #12 集成终端（Ctrl+J）：PTY 平台层与远端（SSH）分支
### PTY 平台层的五个反直觉现象（真机踩出来的，都反直觉且都已修）

1. **`LocalAlloc` 不清零会偶发崩**：`STARTUPINFOW` 用 `LMEM_FIXED`（不清零）分配时，`lpDesktop`/`dwFlags`
   是垃圾值，`CreateProcessW` 会在 `wcslen(垃圾指针)` 上访问违例（0xC0000005）——首次调用拿到新页（全零）
   侥幸能过，第二次拿到复用页就崩。必须 `LMEM_ZEROINIT`。
2. **`HPCON` 要当值传**：`UpdateProcThreadAttribute(..., PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hPC, sizeof(HPCON), ...)`
   ——传 `&hPC` 会让子进程以 `0xC0000142 STATUS_DLL_INIT_FAILED` 立刻退出（微软示例与 node-pty 都是当值传）。
3. **必须 `dwFlags |= STARTF_USESTDHANDLES` 且三个 `hStd*` 都留 NULL**（官方示例里没有）：不加的话伪控制台属性
   等于白设，子进程会挂到**调用方自己的控制台**上——cmd.exe 把横幅打到宿主控制台、随即以 0 退出，
   而伪控制台那头只收到一串开关模式的空序列。
4. **读 isolate 的 `ReceivePort` 必须显式关**：不关的话 Dart VM 认为还有待处理事件，`dart run`/测试进程不退出。
5. **自定义文本输入连接必须带 `viewId`，否则文字被静默丢掉**（用户 2026-10-04：「模拟终端现在中英文都无法输入」；
   本条属**前端**踩的引擎坑，与 PTY 同一条"终端能打字"的链）。Windows 端 `TextInput.setClient` 会校验
   `client_config` 里的 `viewId`，缺了直接回错误（`Could not set client, view ID is null.`，见
   `shell/platform/windows/text_input_plugin.cc`）⇒ 平台侧 `active_model_` 一直是空的，而
   `FlutterWindowsView::SendText` → `TextInputPlugin::TextHook` 在 `active_model_ == nullptr` 时**直接 return**
   ⇒ 键盘交出来的 WM_CHAR 全被丢掉。Dart 侧 `TextInput.attach` 是 fire-and-forget，错误不会冒到界面上，
   现象就是"终端一个字都打不出来"。修法：`attach(viewId: View.of(context).viewId)`，并由
   `test/terminal_panel_test.dart` 钉住发给平台的配置。
   同一链路上还有第二个反直觉点：**键事件被判 `handled` 就不再派发文字**（`keyboard_manager.cc` 的
   `HandleOnKeyResult`：`if (handled) { return; }` 之后才 `DispatchText`）——所以终端对可打印字符必须判
   `ignored`、让平台把 WM_CHAR 交给输入法通道；两条合起来才是"终端能打字"的完整契约。

### PTY 的其余取舍

- **POSIX 分支没在真机验证**（本机 Windows）：只保证编译通过与参数形状有据可依（Linux `script -qefc`，
  macOS/BSD `script -q /dev/null`）；**script 后端做不到改尺寸**（拿不到 pty 主设备 fd），只记日志不抛，
  README 已如实标注；对应测试是跳过状态。
- **关会话时子进程的退出码是 `0xC000013A`（STATUS_CONTROL_C_EXIT）而不是 0**——这是
  `ClosePseudoConsole` 的正常表现，不是失败；接口不暴露 pid，验证的是「close 后 exitCode 在 15s 内收口」。
- **ConPTY 不是逐字节透传**：它自己维护屏幕缓冲、把子进程输出重新编码成 VT 序列再给我们（cmd.exe 能正常显示
  就是因为它）。所以"原始字节"指的是**我们这一层不解码、不清洗**——测试只断言"ESC 序列原样到达 +
  灌非法 UTF-8 不崩且会话继续可用"，没有断言非法字节逐字节重现。

### 远端（SSH）分支：真实边界与未验证项

**状态**：SSH 分支**已接线**（tree_local_exec 的 `SshShellChannel` + tree_core 的 `SshPtyAdapter`），
但**只用假通道验证过**——本仓库没有可连的远端 sshd，真链路仍是空白。
**影响**：Ctrl+J 的集成终端此前对**所有** SSH agent 一律回"暂不支持"；跟随团队 TOP SSH 的**成员**更糟：
判据只看 `agent.sshConfig`，成员自己那份是空的 ⇒ 被当成"本机"，在**本机工作目录**里起一个终端。

#### 先前的错误结论（已推翻）

旧口径写的是"SSH 通道只有一次性 exec，没有伪终端与流式会话"（`packages/tree_core/lib/src/terminal/`
的注释与 README、`lib/README.md` 的不变量 14、`CHANGELOG`）。**这对协议本身是错的**：SSH 的 session
通道支持 `shell` 与 `exec`，两者都能带 `pty-req` 拿真 PTY，dartssh2 也有 `SSHClient.shell()` /
`execute(..., pty:)`。实际缺的只是"我们没接线"，不是"远端做不到"。

（本仓库此前没有 #12：这条旧结论只散在上面的几处注释/文档里，没有进本文件。这次把它**收进来并改写成真实
边界**；`lib/README.md` 的不变量 14 属前端侧文档，按分工由协调者同步，本条目是权威口径。）

#### 现在的实现（判据与形状）

- 判据改成**有效 SSH**：`teamSshConfigFor(agent, store.agent) != null`（成员跟随团队 TOP 的 SSH）。
  本机 cwd 仍走 `files.rootFor(agent)`；远端分支的 cwd 由 `SshWorkspaceIO` 自己解决，核心不解析远端
  路径、也不回传本机路径（远端分支的 `terminal_ready.cwd` 是空串）。
- 形状：tree_local_exec 的 `SshShellChannel`（原始字节输出 / 写入 / 改尺寸 / 退出码 / 幂等 close），
  dartssh2 实现是 `DartSshTransport.openShell`，经 `SshWorkspaceIO.openShell` 透传（**复用缓存的那条
  连接**），再由 tree_core 的 `SshPtyAdapter` 接到 `PtyProcess`。
- `command` 为空 ⇒ `shell(pty:)` 开远端**登录 shell**；非空 ⇒ `execute(cmd, pty:)`，即远端登录 shell 以
  `-c` 执行（就是 `ssh -t host '<cmd>'`），退出码是**命令**的。**不用"把命令写进 shell 通道"**：真实
  dartssh2 的 `SSHClient.shell()` 没有 command 参数，写进 PTY 后拿到的退出码属于 shell，命令跑完 shell
  还活着，与本地 PTY（命令跑完即退出）语义不一致。
- 远端工作目录：`SshWorkspaceIO.openShell` 把**自己的远端根**作为工作目录；`shell` 请求没有 cwd 参数，
  因此登录 shell 分支会写一行 `cd '<远端根>'`（**这行会被远端 shell 回显**，如实标注）。

#### 真实边界（远端 sshd 侧）

- 远端 sshd 必须允许 `shell` / `pty-req`：`PermitTTY no` / 受限的 `ForceCommand` 会被
  `SSHChannelRequestError` 拒绝，我们把它包成可读的 `WorkspaceIoException`（终端回 `terminal_error`），
  **不会**静默降级成无 TTY 的一次性 exec。
- 只请求 `pty-req` 的 **term type / 行列 / 像素尺寸**（`SSHPtyConfig`），**不带 termios 模式**
  （`sendPtyReq` 的 `terminalModes` 参数没有被 `SSHPtyConfig` 暴露）⇒ 远端拿到的是默认终端模式。
- **没有 X11 转发、没有 ssh-agent 转发**：`SSHClient.shell()` 只在显式传 `x11:` / `agentHandler` 时才
  请求，我们都没接（远端 `git push` 之类若依赖 agent 会失败）。
- 输出是**原始字节**（不解码、不清洗，与本地 PTY 同口径）；PTY 模式下 stderr 通常被 sshd 并进 stdout，
  实现仍把 stdout + stderr 两路都灌进同一个流，一块字节都不丢。
- 判活复用既有 `SshLiveness`：终端输出有数据流动时记一次心跳（"数据在动 = 链路活着"），心跳本身仍由
  `DartSshTransport` 的定时器负责；`close()` **只关这条会话通道**，绝不 `SSHClient.close()`
  （SFTP / exec / 文件面板与它共用连接）。
- `exitCode` 一定收口：远端退出 / 对端关会话 / 链路断开 / 我们主动 close，四条路径都给结果，拿不到退出
  状态时给 **-1**（与 `DartSshTransport.run` 的 `?? -1` 同口径）；`close()` 幂等。

#### 还没验证的（谁要做谁看）

- **没有真机 SSH 目标验证过**：`DartSshTransport.openShell` 一行都没在真 sshd 上跑过。现有覆盖是假通道
  契约单测（`packages/tree_local_exec/test/ssh_shell_channel_test.dart`）与假 starter 的终端服务单测
  （`packages/tree_core/test/terminal_service_test.dart`），它们证明的是形状与生命周期，不是"远端真的能
  打字"。门控真机用例（`TREE_SSH_TEST_HOST/USER/KEY`）目前仍只覆盖 SFTP + exec，**没有** shell 通道。
- 登录 shell 分支的 `cd '<远端根>'` 回显，以及非 POSIX 远端（Windows OpenSSH）下 `cd ... && ...` 的行为，
  都没有验证过。
- SSH 分支**收不到** `command`（`SshPtyStarter` 签名里没有它）⇒ 远端一律登录 shell；要"命令终端"
  得先扩这个签名，**不要**为了它退回本机执行。

## #13 核心启动被外设预热拖住（界面看到的是「核心进程未能启动」）

**现象**：偶发（而且确实越来越频繁）地停在
「核心进程启动失败：Bad state: 等待核心进程握手超时（25s）」。

**根因**（不是玄学，也不是"核心整体变慢"）：核心进程的 stdout 首行握手是界面判"核心可用"的**唯一**依据，
而 CLI 的启动序列把两件**外设预热**排在了握手之前：
1. `mcp.refresh()` —— 逐个连 MCP 服务并 `listTools()`；MCP 客户端的**首次连接没有超时参数**
   （`mcp_client.dart` 的类文档写着"跑多久由心跳说了算"），一家半死的服务就能把它挂住
   （最终由判活窗口 ~30s 收口）；
2. `plugins.start()` —— 逐个 spawn 插件再 `listTools(timeout: 20s)`，而且是**串行**的：两家不通就是 40s。
两段相加超过界面的 25s 握手超时 ⇒ 用户看到"核心进程未能启动"，而核心其实还在老老实实连外设。

**修法**（断言见 `packages/tree_core/lib/src/server/README.md` 不变量 13）：
- 握手**不再等**外设：绑定回环端口、打印握手之后，才 `unawaited` 地开始预热；
- 预热**并行 + 有界 + 绝不抛**（`boot_warmup.dart`，预算 3s；超预算只记日志，未结束的任务继续在后台跑）；
- 模型真正干活那一轮由 `LlmAgentEngine.awaitReady` 有界等一次预热——否则会出现"第一轮悄悄少掉
  插件/MCP 工具"这种更难查的回归；
- 每一段都往 stderr 打 `[core:boot]` 分段耗时，"启动慢"从此是可归因的数字；
- 回归测试：`packages/tree_core_cli/test/cli_serve_test.dart` 用**两个永不回协议的假外设**（插件 + MCP）
  钉住"握手必须在 15s 内发出"（旧路径 ≥50s）。实测修复后该用例握手耗时 **3514ms**（含 `dart run` 编译在内）。

**边界（须知）**：
- 预热超预算时，那一轮对话**暂时**不带插件/MCP 工具（日志会写明），预热完成后自动补上
  （插件上线本来就会让工具表失效重建）；
- 预热窗口内界面拿到的插件快照可能是空的，`plugin_status` 增量到达后会自行合并；
- MCP 首次连接的最终上限仍由**判活窗口**（心跳间隔 × 连续未响应拍数）决定，不是由这里的 3s 预算决定：
  预算只管"界面与对话不再等它"。

## #14 中栏右侧「滑块乱跳」（自绘滑块旁边还活着一条原生 `Scrollbar`）

**现象**（用户 2026-10-03，附 58×374 截图）：主对话框（中栏会话区）右侧的滑块乱跳；同一条窄带里能看出
"两条短棒"，一条稳、一条跟着滚动乱动。

**根因**：`571c7cd`（"中栏改成按全局下标寻址的消息窗口"）把右侧滑块**自绘**成 `MessageScrollbar`
（按全局下标算几何；文件头还专门写明"原生 `Scrollbar` 跟随估算范围，窗口化列表里必然乱跳，故自绘"），
但**没有关掉原生那条**：桌面 `MaterialScrollBehavior.buildScrollbar` 会给每个竖向 `Scrollable` 自动包一条
Material `Scrollbar`，而全仓库没有任何 `ScrollConfiguration` / `ScrollBehavior` 覆写 ⇒ 中栏 `ListView` 上
两条滑块并存。原生滑块几何来自**已构建内容**的滚动范围（窗口化列表里那是估算值，随补页/淘汰变化）
⇒ 它必然乱跳，且与自绘那条落在同一条 14px 窄带里。

**证据**：

- 截图逐像素：背景 `#030705` = `brandBlack`；x=28..33 那条 6px 整条竖线 `#2B7A4B` = `brandDivider`
  （深色 `dividerColor`）⇒ 中栏右边缘的分隔条 `DraggableDivider`（`main_page.dart`，`width: 6` + `dividerColor`）。
  它左侧 8px 宽、颜色 = `onSurface@0.3` 的圆角短棒正是 Flutter 暗色原生 `Scrollbar` 的空闲态拇指
  （`flutter/lib/src/material/scrollbar.dart` 的 `idleColor`，`_kScrollbarThickness = 8.0` + 2px 边距 ⇒ x∈[18,26]），
  另一条 6px 宽、`onSurfaceVariant@0.4` 的是自绘 `MessageScrollbar` 的拇指（`right: 4, width: 6` ⇒ x∈[18,24]）
  ——两条拇指同处一条窄带、y 不同，就是用户看到的"两条短棒"。
- 组件测试（平台设为 windows）：中栏 `ListView` 的 `Viewport` **有** `Scrollbar` 祖先（旧代码）。

**修复**：

- 中栏列表上显式关掉原生滚动条：
  `ScrollConfiguration(behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false))`
  —— 只关滚动条（物理 / 越界指示 / 拖拽设备保留）；不做全局改造，其它面板仍用原生滑块。
- 顺带修掉拖拽两侧不互逆（同一症状的另一半，用户同日要求一并修）：
  `messageScrollbarIndexAt` 作为绘制几何的**严格逆**（旧口径画的分母是 `total - visible`、反解的乘数是
  `total`，差 `total/(total-visible)` 倍）；拖拽期间把几何输入与拇指位置**钉住**（以指针为准、松手再对齐真实下标）。
- 拖到最底下 = `total - 看得见的条数`（与"贴底"同义），中栏据此**直达底部**。

**验证**：

- `test/message_scrollbar_test.dart` 新增 4 条（都在旧代码上红过）：① 中栏列表子树上不许再有原生 `Scrollbar`
  （且列表照样能滚）；② 指针走 100px、拇指必须走 100px —— 旧口径走 **132px**（= 100/75 倍，平台已设 windows、
  镜头为鼠标指针）；③ 反解严格互逆（轨道顶 / 底 / 中间，含 6% 下限与短会话）；④ 反解单调不减。
- 回归：`test/message_list_scroll_test.dart`、`test/message_list_viewport_stable_test.dart`、
  `test/message_window_test.dart` 全绿；`flutter test` 全量 + `flutter analyze lib test` 零告警（见收尾汇报）。
- 断言落点：`lib/README.md` 不变量 19③。

**状态**：已修复（2026-10-03，验证方式见上）。

**遗留（本次不改）**：拖拽落点仍是估算（`下标 × 占位槽高度 88px`），真消息高度与占位槽不同 ⇒ 松手后拇指
会跳到列表的**真实**位置（一次，不是持续抖动）。要做到"拖到哪就精确到哪"得让列表按已知的真实高度反推落点
（密度修正），属于另一处取舍，未在本次范围内。

## #15 集成终端：中文输入的**拼音原文**漏进 shell（+ 同批补上选中 / 复制粘贴）

**现象**（用户 2026-10-03，附截图）：中文输入下模拟终端出 bug。截图里提示符后面是
`E:\programs\Tree\desktop>nninini1hn。hni。hani。h已亻尔晗《尔台和2《尔晗nnin《`
——拼音字母、中文标点（`。` `《`）、选字用的数字与若干已定字**混在一起被当成命令打给了 shell**；
同屏还能看到 IME 候选窗（`3 呢 / 4 拟 / …`），说明输入法本身是工作的。

**取证方式**：截图逐像素看不出字形，改用 **Windows 自带 OCR**（`Windows.Media.Ocr`，PowerShell 5.1 + WinRT，
无第三方依赖）读出上句原文；再按本机 SDK 的引擎版本（`bin/internal/engine.version` = `af7e796e…`）取
**同版本**引擎源码（`shell/platform/windows/text_input_plugin.cc`、`shell/platform/common/text_input_model.h`、
`shell/platform/windows/text_input_manager.cc`）核对机制。

**根因**：前端输入法通道（`lib/ui/services/terminal_ime_input.dart`）为了"不回显"**改写了平台侧模型**——
每次收到值后把 `TextInputModel` 置成"只剩未转发的尾巴 + **把选区强制折到末尾** + 重新标 `composing` 为
`[0, len)`"。而引擎侧的事实是：

- 平台送来的永远是**模型整段文本** + `composingBase/Extent`（`SendStateUpdate(*active_model_)`）；
  **提交那一刻不发状态**，随后的"结束组字"事件（`ComposeEndHook`）发的是"整段文本 + composing 无效"；
- `TextInputModel::AddText`：**选区折叠时是"在光标处追加"，选区非折叠时才"替换选区"**
  （`text_input_model.h` 原文）——IME 提交正是靠"组字区被选中"来完成替换。

于是提交退化成**追加**：残留拼音留在模型里，跟提交结果一起被整段送回来；我们按 `composing` 无效把它当成
已定字**整段转发** ⇒ 截图那一串。同一处还有第二半：模型里已经有交出去的内容时，整段回流会被**重复**转发。

**修复**（断言见 `lib/README.md` 不变量 14）：

- 输入法通道改成两条硬口径：**只补差额**（自己记住"已交给 PTY 的前缀"，只发新定下来的那一截；组字尾巴一个字不发，
  尾巴若被引擎连在结果前一起送回来也剥掉；结果 == 组字时按长度判据不误剥）+ **原样回显**（一个字都不改地
  `setEditingState`，模型与 IME 的认知才一致）。**改写平台侧模型 = 拼音漏进 shell**，这条线不要再碰。
- 顺带把"光标那一格在哪"报给平台（`setEditableSizeAndTransform` + `setMarkedTextRect`）：Windows 的
  `TextInputManager::MoveImeWindow` 就是拿 `caret_rect_` 摆 `ImmSetCandidateWindow` / `ImmSetCompositionWindow`
  的；不报就用**上一个可编辑控件**（被 Ctrl+J 顶掉的 composer）的陈旧矩形 —— 截图里候选窗出现在终端底部、
  而提示符在顶部，正是这个。
- **同批补齐两项缺能力**（用户同一句里一起提的"没法选中文字，没法复制粘贴"，属"没实现"而非 bug）：
  左键拖拽选区（绝对行号锚定，输出/回滚都不丢锚点，resize 清选区）+ 复制（Ctrl+Shift+C / Ctrl+Insert /
  有选区时的 Ctrl+C）+ 粘贴（Ctrl+V / Shift+Insert / 右键菜单，`\n`→`\r`，`?2004` 时包 `ESC[200~…ESC[201~`）。

**验证**：

- `test/terminal_ime_input_test.dart`（15 条，其中"引擎把残留组字 + 结果整段送回来 ⇒ 只发新定字"这条在旧实现上红过：
  旧实现发的是 `['ni你']`，正确是 `['你']`；另有"平台重发整段只补差额""收缩不重发""原样回显"三条防回归）。
- `test/terminal_selection_test.dart`（7 条纯逻辑）+ `test/terminal_panel_test.dart`（新增 9 条；把面板接线临时拆掉后
  其中 6 条红：拖拽选中、两条复制键路、三条粘贴路、单击清选区）。
- 全量 `flutter test` + `flutter analyze lib test` 零告警（见收尾汇报）。

**状态**：已修复（2026-10-03）。

**遗留（如实记录，我无法在本环境肉眼验收）**：候选窗定位这条是**按引擎源码推的**（本机 SDK 不带 C++ 源码，
依据取自已核对版本的 GitHub 源），需要在真机上确认候选窗贴住了终端光标；若仍偏移，下一步是按 `caret_rect_`
的坐标系（`SetCaretPos` 用客户区像素）再校一次缩放。

## #16 Tree 的终端里"新建的 reparse point 跟随不了"⇒ 那里的 `flutter build windows` 必然失败

> **2026-10-03 下半场推翻过一次结论**（保留教训）：先前写成"环境侧、不是代码缺陷、代码改不了"——
> 那只是**一半**。链接确实是"不受信任的装入点"（这一半是 OS 行为，改不了）；另一半**在我们自己的
> 进程上下文**：Tree 那条进程链带着 RedirectionGuard 的 `Enforce`，而它来自**提权的安装器**，
> 完全可以在我们这边修掉。下面是坐实后的机制、修法与验证。

**现象**（用户 2026-10-03）：同一个命令、同一个仓库——
`dart run tool/package_windows.dart --installer --flutter <flutter.bat>`——
**在 Tree 的集成终端里失败**（CMake：`add_subdirectory given source
"flutter/ephemeral/.plugin_symlinks/<插件>/windows" which is not an existing directory`），
**在用户自己开的终端里成功**（55.1s 出 `Tree.exe`，随后 zip 与安装包都出来）。
用户原话：「Tree 的 terminal 和我（用户）直接在本机使用的 terminal 在行为上有分歧」（后来又报「上一轮修复没修好吗」）。

### 真正的机制（2026-10-03 实测坐实）

**① 被拒绝的是"非管理员创建的重定向点"**：Windows 11 的 **RedirectionGuard**
（`PROCESS_MITIGATION_REDIRECTION_TRUST_POLICY`，`winnt.h`）：

| Flags | 含义 |
| --- | --- |
| `0x1`（`EnforceRedirectionTrust`）| **拒绝跟随**文件系统上"非管理员创建的"重定向点（并记录该尝试） |
| `0x2`（`AuditRedirectionTrust`）| 只记录、**仍然允许** |
| `0x0` | 不受影响 |

`flutter pub get` 以**非提权**身份创建的 `windows/flutter/ephemeral/.plugin_symlinks/*` 正是
"非管理员创建的重定向点"——这一半是 OS 行为，谁也改不了（本机实测：我们从零新建的链接一样是"不受信任"）。

**② 拒不拒绝，取决于进程自己的策略，而策略沿调用链传播**。实测矩阵（同一个链接、
`GetProcessMitigationPolicy(过程, 16)` 读数 + 实际跟随）：

| 进程 / 上下文 | 策略 | 跟随 `window_manager` 链接 |
| --- | --- | --- |
| `Tree.exe`（正在跑的那个，13:58:35 起） | **0x1** | — |
| `tree_core.exe`（它的子） | 0x1 | — |
| Tree 终端里的 `cmd` / `pwsh` | 0x1 | **FAIL**（`无法遍历该路径，因为它包含不受信任的装入点`，errno 448 / `ERROR_UNTRUSTED_MOUNT_POINT`） |
| 经 WMI 起的 `powershell`（父 = `WmiPrvSE`） | 0x1 | FAIL ⇒ **不只是直接父子继承，调用者上下文也会传播** |
| `explorer.exe`（4 个实例全测） | **0x0** | — |
| **用户手开的 `cmd`（14:58 那个，父 = explorer）** | **0x0** | **OK**（那次打包成功，55.1s） |
| 任务计划起的 `powershell`（父 = svchost） | **0x0** | OK |
| 经 `explorer.exe <文件>` 起的命令 | **0x0** | OK |

**③ 污染源是安装器**：那个 `Tree.exe` 是 **13:58:35** 启动的（正好在安装收尾之后），它的父进程
（pid 31032）已退出 = **安装器**。安装器是**提权**进程，而 RedirectionGuard 的设计目的正是防
"低权位置 → 高权位置的重定向提权"，所以**提权进程默认带着 Enforce**，并把它传给整棵子树
⇒ Tree 的核心、集成终端、以及用户在终端里跑的构建命令全部被污染。

**④ 这条策略清不掉、也不能给子进程关掉**（都实测过）：

- `SetProcessMitigationPolicy(ProcessRedirectionTrustPolicy, 0)` → **`ERROR_ACCESS_DENIED`(5)**，
  读数纹丝不动（安全缓解是"粘"的）；
- `winnt.h` 里**没有** `PROCESS_CREATION_MITIGATION_POLICY*_REDIRECTION_TRUST_*`
  （连 `POLICY2_*` 那一组都没有这一条）⇒ `PROC_THREAD_ATTRIBUTE_MITIGATION_POLICY` 没有创建期开关；
- 顺带排除（免得再走一遍）：把 `.plugin_symlinks/*` 从链接**换成真实目录副本**也不行——Flutter 工具
  每次 `flutter build windows` 都会调 `createPluginSymlinks`，它的判据是
  `if (link.existsSync()) continue;`，而 Dart 的 `Link.existsSync()` 对**真实目录返回 false**
  ⇒ 它会去 `createSync` 撞 `PathExistsException`（errno 183）**直接崩**（实测过一次，现场已还原）。

⇒ **唯一干净的办法：换一个干净的父亲**——让 explorer 重新把自己拉起来（实测 explorer 派生的一切都是 0x0）。

### 修法（已实现）

- **`windows/runner/main.cpp`**：启动时自检 `GetProcessMitigationPolicy(16)`：
  - `--tree-rt-selfcheck`：**只**打印 `tree-rt-selfcheck: flags=0x… would-relaunch=…` 后退出（不起 Flutter；
    打包自检与回归用例用它）；
  - 带着缓解（`flags != 0`）且不是重启来的 ⇒ `ShellExecuteW(nullptr, L"open", L"explorer.exe", "<自己的 exe 路径>")`
    重新拉起自己并退出（**必须让 explorer 当父亲**：直接 ShellExecute 自己的 exe 仍是本进程创建，缓解照旧继承）；
  - 起不来、或重启后仍带着 ⇒ 往 **stderr** 留一句可读的话（不静默）后**照常启动**（绝不把用户挡在门外）；
  - 这两个标记不会传给 Dart 层。
- **`tool/installer/tree-desktop.iss`**：安装后的"启动 Tree"改经 `explorer.exe`（断掉污染源，配注释说明理由）。
  **必须写全路径 `{win}\explorer.exe`**：第一版写成裸名 `explorer.exe`，`[Run]` 把它当**相对路径**
  （去 `{app}` 下找）⇒ 安装收尾弹「Unable to execute file … CreateProcess failed; code 2（找不到文件）」
  （用户 2026-10-03 真机截图）。改成全路径后用**小安装器**实测过 Inno 语义：安装日志显示解析为
  `C:\Windows\explorer.exe`，`[Run]` 条目执行后目标进程 `RT=0x0000`、父链 `RT=0x0000`、能跟随那些链接 ✓。
  两条顺手记下的经验（免得再踩）：`postinstall` 条目在**静默安装下不执行**（Finished 页不显示）；
  `DefaultDirName={tmp}` 那种"临时安装"的目录在安装结束就被清掉，而 explorer 是**异步**拉起的
  ⇒ 被拉起的脚本会"文件已不在"（真安装用的是 `{app}`，不受影响）。
- **终端侧的可读防呆**（上一轮做的，本轮补全）：命中**两种措辞**时弹一次指引——① 系统措辞
  `不受信任的装入点` / `untrusted mount point` / `无法遍历该路径`；② **CMake 措辞**
  `add_subdirectory given source … which is not an existing directory` **且**同时出现 `.plugin_symlinks`
  （单看是通用措辞，判据是"两半同时命中"）。**上一轮只认了 ①**，而用户实际踩到的正是 ② ⇒
  那次"加了提示"在真实路径上根本没弹出来（本轮补上，用例：`test/terminal_output_notice_test.dart`
  两条 CMake 场景 + `test/terminal_panel_test.dart` 的分帧用例；旧防呆上这些用例全红）。
  指引文案也一并**改正**：从"先去管理员终端 `flutter pub get`"改成"退出 Tree 从开始菜单重开一次
  （新版本启动时会自愈）／先在系统终端里跑这条命令"。

### 验证

- 机制：上表的策略读数 + 跟随测试 + "用户手开 cmd 成功 / Tree 终端失败"的对照；
- 修法依据：经 `explorer.exe` 启动的进程实测 **`RT=0x0` 且跟随 OK**（即使从被污染的上下文发起）；
- 代码：`test/redirection_guard_test.dart`（**门控**：非 Windows 或没有构建好的 `Tree.exe` 时跳过）
  钉住自检契约。**先红证据**：旧 exe（13:57 那版）不认 `--tree-rt-selfcheck`，什么都不打印并去起界面；
  新 exe 打印状态行且带上缓解时 `would-relaunch=1`。

### 状态

**已修复**（2026-10-03：runner 自愈 + 安装器改走 shell）。

**生产路径旁的证据**（用户 2026-10-03 装完新包后）：正在跑的
`D:\app\Tree Desktop\Tree.exe` 是 `RT=0x0000`、父进程 = `explorer`（15:55:58 启动），
它的 `tree_core.exe` 也是 `0x0000` —— 也就是**新装的这条链是干净的**，终端里那些构建命令不会再被拦。
（安装器自己那次"启动 Tree"因为上面的裸名 bug 报了错、没拉起来；用户是从开始菜单起的 —— 结论不受影响。）

### 遗留（如实记录）

- **已经在跑的那个 Tree 实例**仍带着缓解（它是从提权的安装器继承的）。重装/升级后由新安装器经 shell
  启动即干净；手动办法是**退出 Tree，再从开始菜单启动**（explorer 派生 ⇒ 0x0）。
- 若 shell 那条链本身也不干净（例如整个会话由提权进程派生），自愈重启也救不了；那时 runner 会在 stderr
  留痕，终端侧给指引——这条链路在用户态修不掉（策略既清不掉、也没有创建期开关）。
- **教训（保留）**：先前用"不继承上下文的 WMI 进程也失败"来说明"与继承无关"——今天实测 WMI 起的进程
  **`RT=0x1`**（调用者上下文会传播），那个对照实验选错了对象，结论因此偏了半边。

### 前端全量测试里的一条并发偶发：`file_tree_viewer_sync_test`「重命名」

**现象**：`flutter test`（整仓、并发跑）时 `test/file_tree_viewer_sync_test.dart` 的
「打开文件后在树里**重命名**它：窗格路径跟着改并按新路径重拉」会**偶发**红；
**单跑该文件 8/8 全绿**。2026-10-03 一天内出现三次（每次都在全量、且每次都是同一条）。

**危害**：它会把"真的失败"淹没掉——今天已两次需要人工判断"这条红是不是它"。

**待办**：收敛成确定性用例（方向：给这条用例独占临时工作空间 / 等待稳定后再断言 /
把"按新路径重拉"的等待从轮询改成显式同步点）。修之前，全量出现这条红时**先单跑确认**。

## （历史）当时的证据与排除项

- 现场取证：`Test-Path <链接>\windows` = `False`、`cmd dir` = File Not Found；现场自造
  `mklink /J`、`mklink /D`（C:→C:、E:→E:）创建"成功"但同样跟随不了；系统预置链接
  （`C:\Documents and Settings` → `C:\Users` 等）正常；`.NET` 抛的原文是
  「无法遍历该路径，因为它包含不受信任的装入点」。
- 排除项（仍然有效，别再重复排查）：不是链接数据坏了（`fsutil reparsepoint query` 与能用的系统链接同构）；
  工作区路径上没有 junction；C:/E: 都是 `DriveType=3` 的本地 NTFS；`fltmc`/`fsutil fsinfo` 的
  Access denied 只是没提权（当初误读为"被虚拟化"，已在文档更正）；**不是**仓库代码设了缓解
  （PTY 的 `CreateProcess` 属性表里只有 `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`）；
  **没有**针对 `Tree.exe` 的 IFEO / AppCompat / Exploit Guard 注册表项，`runner.exe.manifest`
  里也没有缓解声明（⇒ 不是"按映像"，是继承来的）。


## #17 SSH 的远端命令环境 ≠ 用户 ssh 登录环境（agent 看不到 nvcc 这类工具）

**现象**（用户 2026-10-03）：「我发现 SSH 下也有类似情况（上次我有 nvcc，另一个 agent 没有）」。

**根因**：工具命令走 SSH 的 **exec 通道**（`DartSshTransport.run` → `client.runWithResult(cmd)`），
按 sshd 的语义那是**非交互、非登录** shell（`$SHELL -c '<cmd>'`）——`/etc/profile`、`~/.profile` 里
"登录时才加载"的 PATH（CUDA / conda / 自建工具链）全都不在 ⇒ agent 看不到用户 ssh 进来时明明有的
`nvcc`。而**交互终端**（Ctrl+J 的远端分支）走 `shell(pty:)`，本来就是**登录 shell**，所以那边看起来是对的
——"同一个远端，两条路两个环境"，这正是用户觉得"行为有分歧"的地方。

**修复**（断言见 `packages/tree_local_exec/README.md` 不变量 15）：远端命令**默认套一层登录外壳**
`bash -lc '<cmd>'`；`bash` 不在退 `sh -lc`；都探测失败就**原样发**（与旧行为完全一致）并留日志；
**一次连接只探测一次**并缓存；模板可用 agent yaml 的 `ssh.login_shell` 替换（必须带 `{cmd}` 占位）或写空串**关掉**，
非法模板只跳过那一档；命令一律 **POSIX 单引号转义**。配套把 `resolveRemoteRoot` 改成**带标记**
（`printf __TREE_HOME__%s "$HOME"`）取远端 HOME——登录外壳会读 profile，欢迎语不再污染解析。

**验证**：`test/ssh_login_shell_test.dart`（9 条：单引号穿壳 / 模板渲染与非法模板跳过 /
`bash → sh → 原样发` 的回退 / 空串关掉 / 结论缓存 / reset）；`test/ssh_workspace_io_test.dart` 的
`resolveRemoteRoot` 组（含新命令形状）；`tree_local_exec` 全量通过；`tree_core` 1005 条通过。

**遗留**：**真机 sshd 未验证**（本机没有可连的远端，与 #12 同一限制）：`bash` / `sh` 探测与登录外壳
在真实远端上的表现需要一次真机确认（门控用例 `TREE_SSH_TEST_*` 目前只覆盖 SFTP + exec，**没有**覆盖
这条包装）；profile 若往 stdout 打欢迎语，那些字会混进命令输出（真嫌吵就 `ssh.login_shell: ''` 关掉）。

## #18 Tree 的终端/工具继承 core 的环境，与"用户自己的终端"不同口径

**现象**（用户 2026-10-03，与 #16 同一句话引出来的另一半）：同一条命令在 Tree 的终端与用户自己的终端里
行为不同。实测两份具体差异：agent 的 shell **多了**
`C:\Program Files\WindowsApps\Microsoft.PowerShell_7.6.6.0_x64__8wekyb3d8bbwe`（连带把 shell 选成了
**MSIX 打包版 pwsh**），**少了** `C:\Program Files\GitHub CLI\`（于是 agent 里 `gh` 不见了）。

**根因**：core 进程"被谁拉起来就继承谁的环境"，而本地 exec / 本地 PTY / 后台 hook 脚本全都继承 core 的那一份；
用户自己的终端拿的是**登录时的环境**（机器级 + 用户级注册表按 Windows 的规则合成）。

**修复**（断言见 `packages/tree_local_exec/README.md` 不变量 14）：按登录口径重建环境
（`HKLM\…\Session Manager\Environment` + `HKCU\Environment`；`Path` = 机器级 + `;` + 用户级；
同名用户级覆盖机器级；`REG_EXPAND_SZ` 按合成后的表展开，查找表带上继承值；**注册表里没有的继承变量原样保留**；
任何一步失败**整体退回继承**并留痕），接线四处：本地 `exec`、`git`、本地 PTY、后台 hook 脚本。

**验证**：真注册表实跑对比（重建后那条 WindowsApps 消失、`GitHub CLI` 回来、无残留未展开的 `%` 段）
+ 13 条纯函数用例；`tree_core` 1005 条 / `tree_local_exec` 全量通过。

**遗留**：本条只覆盖"环境变量"这一半；**reparse point 那条**（#16）是操作系统的安全缓解，
环境重建管不了（实测换 5.1、换 cmd、换不继承任何上下文的 WMI 进程都一样跟随不了）。
另外 MCP 服务与插件宿主仍继承 core 的环境——它们是"工具进程"不是"用户的终端"，本次没动
（避免顺手改坏既有配置），若也要对齐，按同一处 builder 接上即可。



## #19 中栏：右侧拇指不上滑跟手 / 拖到中段落点很怪且那一段不渲染 / 松手拇指"回落"

**现象**（用户 2026-10-03，push 新 Tree 之后）：① 页面上滚，右侧拇指不动；② 可以拖动拇指上滑，但很怪，
且有些部分不渲染；③ 拖动松手后拇指回落到底部或顶部，中间页面却不跟着回落。

**根因（三条同源，已用探针实测坐实，脚本在 `.self/probe/`）**：

1. **窗口区间只在"父组件重建"时才上报**。`_MessageListViewState` 只在 `build` 里注册一次帧后回调
   （`_flushWindow`），而**滚动不重建父组件**（`ListView` 的懒构建只重建子项）⇒ 滚动期间**一次都不上报**：

   ```
   P2 阅读模式下滚到中段 pixels=219512 reports=[[2496,4999],[2496,2508]]   ← 只有重建那一下补了一次
   P2 滚轮/拖拽 120px：pixels 219512 → 219632，reports=[]                    ← 滚动期间零上报
   ```

   拇指的几何输入就是这个上报值 ⇒ 症状①（不动）与症状③（松手交回"旧坐标"⇒ 弹回旧位置，而内容其实已经动了）。
   附带缺陷：`_builtFirst/_builtLast` 只在 `build` 里重置，两次重建之间是**并集**（上例报了 [2496,4999]，
   真值 [2496,2508]）⇒ 面板会去补一片根本不在视口附近的段。
2. **落点是"下标 × 占位槽高度(88)"**，而已加载消息的真实高度各不相同（实测 user 单行 ≈ 68px、长回答几百 px），
   从 0 开始算误差会一路累积 ⇒ 拖到哪都不太准；且拖拽期间同样不上报（同根因 1）⇒ 拖过去的那一段
   **永远停在占位槽**（"有些部分未渲染"）。
3. **缺口横跨视口时不做高度补偿**：补页把占位槽换成真消息会改变高度；面板只在"整页都在视口上方"时
   `padAboveStamp++`，而视口本身就在缺口里是常态 ⇒ 视口上方长高把用户正在读的一段整体推下去。

**探针给出的关键事实**（`sliver_seek_probe_test.dart`）：`jumpTo` 的像素落点由我们算的值直接决定
（sliver 不校正），但 `maxScrollExtent` 是估算值（实测同一次会话内 437424 / 439424 / 435424 来回变）；
占位区里 `pixels / 88` **就是**全局下标（实测 2495.8 vs 上报的 first=2496）。

**修复**（断言见 [lib/README.md](../lib/README.md) 不变量 19②③）：

- **窗口坐标变成一等公民**（`MessageWindowCoordinate`）：每帧刷新，由**滚动通知**与 itemBuilder 两侧驱动；
  权威区间取自渲染树里 SliverList **这一趟真的布局过**的子项（`childScrollOffset != null`——被
  `AutomaticKeepAlive` 留在树里的屏外子项不算，itemBuilder 收集的区间只作兜底）。
- **拇指直接监听坐标**（`ValueListenableBuilder`）：滚动只重绘拇指、不重建列表（丝滑）。
- **落点按坐标算**（`pixelOffsetForIndex`：以视口第一条为锚点、占位区 88px/条）+ 松手/点击后
  **反馈校正 ≤3 次**（`MessageSeekCorrection`：两点割线反推真实步长；用户一动就放弃）。
- **缺口在视口顶切开**（`splitGapAtViewportTop`）：先补"视口及以下"（不改变视口上方高度），
  再补"整段在视口上方"那份（走既有高度补偿）。
- **补页 + 淘汰同一时刻只跑一趟**（反复触发只覆盖"最新坐标"，一趟内请求串行；视口附近已加载好时
  第一道 `gapsFor` 就是空 ⇒ 滚动零网络、零 `setState`）；淘汰口径 400 → **200**（"仅缓存坐标附近"）。
- 顺带：`_itemKeys` 超过 2000 条时按"还在槽位表里"清一次（长会话里它只增不减）。

**验证**：`test/message_window_coordinate_test.dart`（14 条纯函数：坐标 / 落点 / 校正 / 切分）、
`test/message_list_scroll_test.dart` 新增 3 条（**在旧代码上全部红过**：滚动不上报、松手不回跳、点哪到哪）、
`test/message_scrollbar_test.dart` 跟着改成"坐标输入"。

**状态**：已修复（2026-10-03）。

**遗留（如实记录）**：① 补页把**视口内**的占位槽换成真消息时，那一段自身的高度会变（视口顶锚得住，
顶以下的内容仍会往下让一点）——占位高度本来就不是真高度，这一条改不掉，要彻底解决得给占位槽
一个"按已见消息平均高度"的估计值（未做，属于另一处取舍）；② 面板的补页流程没有端到端用例
（需要假核心 HTTP），本次只验证到"坐标上报 / 切分逻辑 / 列表侧补偿"三层，真机核对清单见
`docs/development.md` 的手工核对项。

## #20 终端：拼音原文又漏进 shell（我们自己的 `setEditingState` 回推打掉了引擎的组字态）

**现象**（用户 2026-10-03：「模拟终端又出问题」，与 #15 同一症状）。截图（`.input/20261003/`）用
Windows 自带 OCR（`Windows.Media.Ocr`，无第三方依赖）读出：

```
E:\programs\Tree\desktop>nninininfizZfit09i。hani。ha。hni。hinil
3 呢  4 拟  5 倪  6 妮  7 泥  8 腻  9 谫
```

= 拼音原文进了 shell，且**没有换行**（正说明它不是"回车执行的命令"，而是被当成**定字**发出去的文本）。

**先排除"旧构建"**：`D:\app\Tree Desktop\Tree.exe` 是 10-02 的，但 Flutter Windows 的 Dart 代码在
`data/app.so` —— 它是 **10-03 13:57** 的，晚于 #15 的修复提交（13:12）⇒ 跑的就是含修复的构建，
**这是真回归**。

**根因（同版本引擎源码坐实）**：引擎版本 `af7e796e…`（`bin/internal/engine.version`），取同版本源码
（`engine/src/flutter/shell/platform/{common/text_input_model.{h,cc}, windows/text_input_plugin.cc}`，
落地在 `.self/probe/engine/`）：

```cc
// text_input_plugin.cc（kSetEditingStateMethod 分支）
active_model_->SetText(text->value.GetString());   // ← 只传 text，其余走默认参数
...
active_model_->SetComposingRange(TextRange(composing_base, composing_extent), cursor_offset);

// text_input_model.h
bool SetText(const std::string& text,
             const TextRange& selection = TextRange(0),
             const TextRange& composing_range = TextRange(0));   // ← 默认：折叠在 0
// text_input_model.cc
bool TextInputModel::SetText(...) {
  ...
  composing_range_ = composing_range;
  composing_ = !composing_range.collapsed();     // ← 折叠 ⇒ composing_ = false
}
bool TextInputModel::SetComposingRange(const TextRange& range, size_t cursor_offset) {
  if (!composing_) return false;                 // ← 组字态已没，救不回来
  ...
}
void TextInputModel::AddText(const std::u16string& text) {
  DeleteSelected();
  if (composing_) { text_.erase(composing_range_.start(), composing_range_.length()); ... }
  text_.insert(...);                             // ← composing_ 为假 = **追加**
}
```

#15 的修复把输入法通道改成了"**原样回显**"（每次 `updateEditingValue` 都 `setEditingState(value)`）。
而 `setEditingState` 走的是上面那条**默认参数**路径 ⇒ 每一次状态回流都把引擎的 `composing_` 打成 `false`，
随后的 `SetComposingRange` 因 `!composing_` 直接返回 false ⇒ **组字态被抹掉**。于是 IME 下一轮的
`AddText`/`UpdateComposingText` 从"替换组字区"**退化成"追加"**：拼音不断堆在模型里、每一轮"."又把"。"追加进去；
我们的"只补差额"（`_forwarded`）把多出来的部分当**新定字**转发给 PTY ⇒ 截图那一串（连 `ComposeCommitHook`
里的 `CommitComposing()` 也因组字区已被重置为折叠而成了 no-op）。

**修复**：输入法通道**绝不回推**（唯一一次是 `attach()` 时发一次空状态把模型清干净）；
"只补差额"与"残留组字前缀剥除"保留。断言见 [lib/README.md](../lib/README.md) 不变量 14。

**验证**：`test/terminal_ime_input_test.dart` 新增「组字期间**不许**回推 `setEditingState`」
（用 mock platform messenger 数 `TextInput.setEditingState` 的出现次数；**旧代码上必红**：Expected 0 / Actual 1）
与「attach 只发一次"清空"」；原有 15 条时序用例继续绿。

**状态**：已修复（2026-10-03）。

**遗留（如实记录）**：这条的最终确认要真机跑一次中文输入（本地无自动化手段驱动真 IME）：
在终端里打拼音 → 选字 → 按回车，shell 里应只出现选中的字。若仍有残留，下一步是在 `updateEditingValue`
里加一条**可开关的诊断流水**（记录 text/composing/forwarded/preedit），拿真机序列再定位。

## #21 终端：清屏键无效（只把 `Ctrl+L` 发给 shell，而 cmd 没有这个绑定）

**现象**（用户 2026-10-03：「清屏键无效」，与 #20 同一条消息里报的）。

**根因**：工具条那颗「清屏（Ctrl+L）」只做 `_sendInput(<int>[0x0c])`——把 `Ctrl+L` 送给 shell 就完事了。
但那是"交给 shell 办"的路子，而 **shell 未必有这个绑定**：本机默认 shell 是 `cmd.exe`
（#15/#16 的截图里提示符就是 `E:\programs\Tree\desktop>`），cmd 没有 Ctrl+L ⇒ 按下去什么都不发生。
（顺带：终端自己的 `VtScreen` 完全有能力清屏——`ED2`/`ED3` 都实现了，回滚历史上限 2000 行。）

**修复**：`_clearScreen()` = **本地立刻清**（往 `VtScreen` 喂标准序列 `ESC[2J` + `ESC[3J` + `ESC[H`：
清屏 + 清历史 + 游标归位，并复位回滚视图与选区）**＋ 仍然把 `0x0c` 送给 shell**
（bash / PSReadLine 会自己重画提示符，两者叠加不冲突）。工具条按钮与 `Ctrl+L` 走同一条路。
断言见 [lib/README.md](../lib/README.md) 不变量 14。

**验证**：`test/terminal_panel_test.dart` 新增 2 条（按钮 / Ctrl+L 各一条：屏上不许再有非空白字符、
`historyLength == 0`、且 `0x0c` 确实发出去了）——把 `_clearScreen` 临时退回"只发 0x0c"时**两条都红**
（Expected false / Actual true）。

**状态**：已修复（2026-10-03）。

**遗留**：cmd 这类"自己不重画提示符"的 shell 上，清屏后提示符要等下一次输出才回来（本地清屏是确定的，
提示符是否立刻回来取决于 shell 自己）——如实记录，不做"替 shell 补画提示符"这种越界的事。

## #22 SSH 下 `terminal hook=true` 把**远端路径当本机路径用**（现场报 `No such file`）

**现象**（SSH 端 agent 2026-10-04 现场）：「`hook=true` 那条路看不到我远端工作空间的文件——对确实存在的
脚本报 `No such file`，**不可用于监视远端训练**；只有『同步命令 + 小 `timeout_seconds`』能用。」

**根因**：后台任务的启动实现（`TerminalHooks.start`）**只知道本机**：`io.resolve('.output/hook_x.log')` 在
SSH 下返回的是**远端绝对路径**（`/home/u/proj/.output/…`），而它拿这个路径去 `dart:io` 的
`File(...).parent.create()` / `File(scriptPath).writeAsString()`（写到了**本机**盘符根下），再把同一个远端
路径当 `Process.start(workingDirectory:)` 的工作目录起**本机**进程 ⇒ 目录不存在，直接 `No such file`。
即便侥幸建出来，跑的也是本机进程，不是远端那条命令。同一条缺陷还波及 `adoptRemote` / `adoptDetached`
（SSH 软超时 / 失联转后台）：它们的日志写入与 `renderStatus` 的尾部读取也都走 `dart:io`，远端日志读不到。

**证据**：`packages/tree_core/lib/src/tool/terminal_hooks.dart` 的 `start`（旧实现用 `File` + `Process.start`）；
`packages/tree_local_exec/lib/src/ssh_workspace_io.dart` 的 `resolve`（POSIX 拼接、返回远端绝对路径）；
`WorkspaceIO` / `SshTransport` 当时都**没有**"起了不等"的原语。

**修复**（2026-10-04）：
- `tree_local_exec` 新增并列原语 `BackgroundExecHost`（`background_exec.dart`）：本机 = 脚本 + 重定向直写日志；
  远端 = `nohup` 起在远端 + 日志落**远端工作空间** + 退出码写**哨兵文件**（本机 3s 轮询，含 `GONE` 可辨退出码）；
- `TerminalHooks` 退化为"纯台账"（执行/日志全走 io），并新增**落盘台账**（`<数据根>/hooks`）+ 重启**接续**
  （启动即探哨兵，已结束就**投递回原会话**，未结束就重挂轮询；agent/会话不存在如实记日志）；
- 后台 hook 登记进运行中工具表（`watchdog:false` / `crossCall:true`）：右栏「正在执行的 tool」**看得见、用户关得掉**；
- 顺带修好 `adoptRemote` / `adoptDetached` 的同源日志缺陷。

**验证**：`packages/tree_local_exec/test/background_exec_test.dart`（本机真起真杀；远端用假 transport 钉命令形状、
哨兵轮询、`GONE`、`attachBackground` 不重跑、`cancel` 如实）、
`packages/tree_core/test/terminal_hooks_ssh_test.dart`（唤醒 / 面板关闭路由 / 接续投递回原会话 / 工作空间不可用如实上报）、
`hook_ledger_test.dart`（原子写与损坏容错）；既有 4 个本机 hook 测试全绿（零回归）。

**状态**：已修复（2026-10-04）。

**遗留（如实）**：**真 SSH 链路未端到端验证**——本机没有可连的 sshd，只保证命令形状、协议与恢复逻辑在
假 transport 下正确；`nohup` / `tail` / `kill` 在真实远端主机上的行为需在真机上复核。另外远端 `cancel`
是**尽力而为**（`kill -TERM` 进程组 + 单进程；拿不到 pid 时如实返回 false），且远端 pid 可能被复用 ⇒
`GONE` 判定以**哨兵文件**为主判据。

**真机复核（2026-10-04 补充）**：已在真机 `open@192.168.0.208:/mnt/space`（`hostname=open`、UTC、
`setsid` 存在）上端到端复核：命令确实在**远端**执行、日志落在远端工作空间、退出码与产物正确 ⇒ 上一条
"未端到端验证"的遗留**已消除**；复核同时发现 #23（远端 `hook=true` 不立即返回）。

## #23 SSH 下 `terminal hook=true` **不立即返回**（阻塞到命令结束，hook 退化成同步调用）

**现象**（2026-10-04 真机）：`hook=true` 起的远端命令**确实在远端跑**（#22 已修），但**工具不立即返回**——
`startBackground` 阻塞的时长 ≈ 命令时长：实测 `sleep 25` 阻塞 **25.09s**，返回时日志早已写满、产物也已生成。

**根因**：远端命令形状 `mkdir -p … && cd <root> && { nohup sh -c '…' > <日志> 2>&1 < /dev/null ; } & echo $!`——
`&` 挂在**组**上，但组内的 `nohup` 仍以前台跑完，承载组的子壳要等它结束才退出；而该子壳仍握着
**SSH 通道的 stdout/stderr** ⇒ 通道直到命令结束才 EOF ⇒ `SshTransport.run` 直到命令结束才返回。
（原注释里"三路重定向 ⇒ 通道立刻收工"的推断不成立：重定向加在**内层命令**上，没加在**承载它的子壳**上。）

**证据**（ssh CLI，`sleep 6`，基线 `true` = 262ms）：当前形状 **6283ms**；`nohup … & echo $!` 6270ms；
`setsid nohup … & echo $!` 6277ms；`( setsid sh -c '…' >L 2>&1 </dev/null & ) ; echo $!` 606ms（`$!` 落空）；
**`( setsid nohup sh -c '…' >L 2>&1 </dev/null & echo $! )` 266ms ✅**。
生产代码路径（`SshWorkspaceIO.startBackground`）修复前 `sleep 25` → `RETURN_MS=25090`；修复后 → **76ms / 74ms**。

**修复**（2026-10-04）：命令形状改为
`mkdir -p … && cd <root> && ( setsid nohup sh -c '<cmd> ; printf %s $? > <哨兵>' > <日志> 2>&1 < /dev/null & echo $! )`
——后台化与 `echo $!` 都放进**子壳**：子壳立刻退出 ⇒ 通道立刻 EOF ⇒ `run` 立刻返回，pid 仍回到 stdout；
`setsid` 让命令自成**进程组**（pgid == pid），`cancel` 的 `kill -TERM -<pid>` 才落在正确进程组。

**验证**：`packages/tree_local_exec/test/background_exec_test.dart` 钉新形状（并断言**不含**旧形状）；
`ssh_integration_test.dart` 新增门控真机用例「`startBackground` 立即返回」：命令跑 8s 而返回 < 4s、
返回时命令仍在跑、随后拿得到退出码与产物（真机 `/mnt/space` 通过）。

**状态**：已修复（2026-10-04）。

**遗留（如实）**：命令依赖 **`setsid`**（util-linux / busybox 一般都有，纯 POSIX 远端未必）——缺失时该远端
起不了后台命令；暂**不做**静默降级（宁可显式失败），确有需要再加"无 `setsid` 回退"。只在本例真机
（Debian 系）核过 `setsid` 存在，未在所有目标远端逐一核。

## #24 `readFile().text` 吃掉文件**结尾换行**（`write → read` 不保真）

**现象**：门控真机用例 `真 SSH：连接 + SFTP 读写改 + exec + 清理` **一直失败**：写入 `'hello\n世界\n'` 后读回
`text == 'hello\n世界'`——**结尾换行丢了**（`totalLines` 仍是 2，从返回值上看不出异常）。因为该用例门控
（无 sshd 就跳过），这条失败此前从未在本地/CI 暴露。

**根因**：`readFile` 用 `const LineSplitter().convert(text)` 再 `join('\n')` 拼回 `text`。`LineSplitter` 把结尾
换行当**行终止符**吃掉（`'a\nb\n'` ⇒ `['a','b']`），`join('\n')` 就少一个换行。本机
（`local_workspace_io.dart`）与远端（`ssh_workspace_io.dart`）**各写了一遍**，同样的丢失。

**修复**（2026-10-04，用户裁定"改代码保真"）：取行逻辑收成**共用一处** `sliceFileLines`
（`packages/tree_local_exec/lib/src/workspace_io.dart`）：选区覆盖**末行**且原文以换行结尾 ⇒ 补回结尾换行；
只取中段 ⇒ 不补。本机与远端都改调它（防两端漂移）。

**影响面核对**：`text` 的消费方要么是显示（`read` 工具 / 提示词 / spec 预览），要么本来就防御了缺换行
（`message_dispatcher._appendActivity` 有 `if (!existing.endsWith('\n'))`）；**文件面板 / 编辑器**走**原始字节**
（`FileService._contentJson` / `writeContent`），不受影响；既有单测写的内容本来就没有结尾换行，全部仍绿。

**验证**：`local_workspace_io_test` / `ssh_workspace_io_test` 新增「结尾换行保真」组（`'a\nb\n'` 原样读回 /
只取中段不凭空补）；门控真机用例转绿。

**状态**：已修复（2026-10-04）。**遗留**：无。
