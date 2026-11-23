# 会话自动命名（TITLE-AUTO）方案

> **状态**：2026-11-23 落档并拍板（D1~D4 见 §6）；用户选定**路线 3（两段式：规则即时 + LLM 精修）**。
> **输入**：用户 2026-11-23「本期做：会话自动命名」，路线对比后选定路线 3；同日拍板 **D3 用 `title_source` 字段，D1/D2/D4 按建议默认**。
> **对码范围**：`plugins/tree.agent`（`0.32.1`）、`plugins/tree.ui.default`。
> **不涉及**：核心 35 条路由基线、`tree_protocol` 契约、插件平台、新增插件。

---

## 1. 结论先行

1. **通道已经通了，缺的只是"谁来生成标题"**。改标题 + 广播 + UI 刷新三段都在：
   `session.rename` 执行站命令写库后广播 `session_renamed`
   （[agent_runtime.dart:1541-1566](../../plugins/tree.agent/lib/src/runtime/agent_runtime.dart#L1541-L1566)），
   UI 收到后即时改列表标题
   （[message_panel.dart:694-717](../../plugins/tree.ui.default/lib/ui/widgets/message_panel.dart#L694-L717)）。
2. **不需要新增任何核心点位**：自动命名在 tree.agent 内部触发，走已有的 store + hub，
   UI 零协议改动。
3. **两段式 = 两个挂点**：
   - 规则段：首条用户消息入站后立即用本地规则出标题（零成本、离线可用、用户立刻看到）；
   - LLM 段：本轮收尾时用一次 `llm.call` 精修，仅在 `title_source=auto` 时覆盖。
4. **手动改名天然优先**：`CoreSession` 新增 `title_source`，三值：
   `''`（从未命名）/ `auto`（规则初稿）/ `auto_final`（LLM 精修完成）/ `manual`（用户手动）。
   手动改名（UI PATCH / `session.rename`）写 `manual`；自动命名只覆盖 `''` 与 `auto`；
   精修完成写 `auto_final`，之后再无自动触发路径。旧会话缺字段时按「标题是否仍是哨兵值」
   回填（哨兵 ⇒ `''`，否则 `manual`），存量用户改过的标题不会被覆盖。
5. **默认会话必须一起处理**：`session_default` 的初始标题是「默认会话」，
   而 UI 现在**禁止**对它重命名
   （[session_list_panel.dart:73-76](../../plugins/tree.ui.default/lib/ui/widgets/session_list_panel.dart#L73-L76)）。
   拍板：**默认会话参与自动命名，同时放开默认会话的手动重命名**（删除仍禁止）。
6. **成本可控**：每会话最多一次 LLM 调用（数百 token），首轮结束才发；无模型时静默降级为规则标题。
7. **只对新会话生效**：不回溯命名历史会话，避免升级后启动时批量打模型。

---

## 2. 现状证据

| 事实 | 证据 |
| --- | --- |
| 新建会话标题固定「新会话」 | [file_store.dart:240-263](../../plugins/tree.agent/lib/src/store/file_store.dart#L240-L263) |
| 默认会话标题固定「默认会话」 | [file_store.dart:219-237](../../plugins/tree.agent/lib/src/store/file_store.dart#L219-L237) |
| 改名 = 写库 + 广播（空标题显式拒绝） | [agent_runtime.dart:1538-1566](../../plugins/tree.agent/lib/src/runtime/agent_runtime.dart#L1538-L1566) |
| UI 已订阅 `session_renamed` 并刷新列表 | [message_panel.dart:694-717](../../plugins/tree.ui.default/lib/ui/widgets/message_panel.dart#L694-L717) |
| UI 对未知会话已有本地兜底标题（首条 chunk 前 30 字） | [message_panel.dart:645-668](../../plugins/tree.ui.default/lib/ui/widgets/message_panel.dart#L645-L668) |
| 已存在 fire-and-forget 钩子范式（记忆管道） | [conversation_service.dart:2478-2484](../../plugins/tree.agent/lib/src/agent/conversation_service.dart#L2478-L2484)、[agent_runtime.dart:830-847](../../plugins/tree.agent/lib/src/runtime/agent_runtime.dart#L830-L847) |
| 已存在"专用模型优先、缺省 agent 主模型"的取模型范式 | [memory_pipeline_wiring.dart:95-128](../../plugins/tree.agent/lib/src/memory/memory_pipeline_wiring.dart#L95-L128) |
| 首条消息入站两处挂点 | [conversation_service.dart:707-709](../../plugins/tree.agent/lib/src/agent/conversation_service.dart#L707-L709)、[:842-845](../../plugins/tree.agent/lib/src/agent/conversation_service.dart#L842-L845) |
| 本轮收尾挂点（已有 `subagent == null` 判据） | [conversation_service.dart:1588-1593](../../plugins/tree.agent/lib/src/agent/conversation_service.dart#L1588-L1593) |
| 会话记录当前无"标题来源"字段 | [records.dart:257-350](../../plugins/tree.agent/lib/src/store/records.dart#L257-L350) |

---

## 3. 语义与时序（路线 3）

```
用户发首条消息
  → _appendInbound（两处入站共用）
  → [新增] autoTitleRequest(agentId, sessionId, text)      // fire-and-forget
      ├─ 开关关 / title_source=manual / 会话已有多条消息 → 不做
      ├─ 规则生成标题（§4.1）
      ├─ store.renameSession(source: auto) + hub.broadcast(session_renamed)
      └─ title_source 落盘为 auto
  → 正常回答…

本轮收尾（_runReply finally）
  → [新增] autoTitleRefineRequest(agentId, sessionId)      // fire-and-forget
      ├─ 开关关 / title_source != auto → 不做（用户已手动改名或已精修过）
      ├─ 取首条用户消息 + 首轮最终回复 → llm.call（§4.2）
      ├─ 解析失败/空/超时 → 保留规则标题（source 仍是 auto）
      └─ store.renameSession(source: auto_final) + hub.broadcast(session_renamed)
```

**幂等**：判据全在落盘的 `title_source` 上，进程重启后语义不变。规则段要求"会话仅 1 条消息"，
LLM 段要求 `auto` 且成功后转 `auto_final`——同一会话最多一次规则命名 + 一次精修。

**并发**：同一会话连续快速发多条消息时，规则段在第一条入站即完成；后续消息不再满足
"仅 1 条消息"判据。LLM 段每轮收尾最多触发一次，精修成功后 `auto_final` 会挡住后续轮的重复调用。

---

## 4. 标题生成规格

### 4.1 规则段（零成本）

1. 输入：首条用户正文（剥离附件占位、图片标记、`@` 提及）。
2. 清洗：去 Markdown 围栏与代码块内容、去 URL、去行首列表符/标题符、连续空白折叠为单空格。
3. 弱前缀可选剥离：`请`、`帮我`、`麻烦`、`你能不能`（仅当剥离后仍有 ≥4 字）。
4. 截断：中文按字符 24 字；英文按词边界 48 字符；超出加 `…`。
5. 去尾部标点：`。！？；：，.!?;:,`。
6. 结果为空或纯符号 ⇒ **不命名**，保持「新会话」（避免生成噪音标题）。
7. 不改大小写、不做翻译，保持用户语言。

### 4.2 LLM 精修段

- 输入：首条用户消息（截断 2000 字）+ 首轮最终回复（截断 1500 字）。
- 模型：新增配置 `title_llm_model`，空 ⇒ 用该 agent 主模型（与 `extractLlmModel` 同口径）。
- system：`你是会话标题生成器。根据用户首条消息与助手首轮回复，输出一个能让人一眼认出主题的标题：只输出一行纯文本，不超过 16 个字，不加引号、句号、序号或“标题：”前缀；保持用户语言；不编造消息里没有的信息。`
- `response_format: text`（与记忆摘要一致，复用前缀缓存口径）。
- 解析：取首行 → 去首尾引号/书名号 → 去 `标题[:：]` 前缀 → 去尾部标点 → 截断 16 字。
- 失败/空/超时（建议 20s）⇒ 保留规则标题，只记日志。
- 跳过条件：`subagent != null`（临时员工的回合不命名父会话）。

### 4.3 覆盖判据

| 场景 | `title_source` | 规则段 | LLM 段 |
| --- | --- | --- | --- |
| 新建会话（标题=新会话） | `''` | 命名 → `auto` | 覆盖 → `auto_final` |
| 默认会话（标题=默认会话） | `''` | 命名 → `auto` | 覆盖 → `auto_final` |
| 用户已手动改名（含旧会话回填） | `manual` | 跳过 | 跳过 |
| 已精修过 | `auto_final` | 跳过（也非 1 条消息） | 跳过 |
| 升级前的旧会话，标题非哨兵 | 回填 `manual` | 跳过 | 跳过 |
| 用户把标题手动改回「新会话」 | `manual` | 跳过（来源优先于标题值） | 跳过 |

---

## 5. 落点与改动清单

### 5.1 tree.agent

| 文件 | 改动 |
| --- | --- |
| `lib/src/store/records.dart` | `CoreSession` 新增 `titleSource`（落盘键 `title_source`，缺省 `''`）；`fromJson` 缺失时按哨兵回填；`toApiJson` 不暴露（UI 无需感知） |
| `lib/src/store/tree_store.dart` | `renameSession` 增加 `{String source = 'manual'}` |
| `lib/src/store/file_store.dart` | `renameSession` 落盘 `title_source`；创建会话/默认会话时 `titleSource = ''` |
| `lib/src/store/memory_store.dart` | 同步签名与语义 |
| `lib/src/agent/auto_title.dart`（新增） | 规则清洗/截断、LLM 提示词、输出解析（纯函数，可单测） |
| `lib/src/agent/conversation_service.dart` | 新增两个可选钩子 `autoTitleRequest` / `autoTitleRefineRequest`；在两处入站与收尾处各调一次（不 await） |
| `lib/src/runtime/agent_runtime.dart` | 接线两个钩子；`_autoTitleOf` / `_refineAutoTitle` 读配置、调 `llmCaller`、写库并广播；把 `_sessionRename` 的"写库+广播"抽成内部方法复用 |
| `lib/src/settings/domain_settings.dart` | 新增 `autoTitle` / `autoTitleRefine` / `titleLlmModel` 三个标量（落 `agent_settings.yaml`） |
| `lib/src/delegate.dart` | 新增 `GET/POST /api/settings/auto-title`（D4 选全局设置） |
| 测试 | 见 §9 |

### 5.2 tree.ui.default

| 文件 | 改动 |
| --- | --- |
| `lib/ui/widgets/session_list_panel.dart` | 放开默认会话「重命名」（删除仍禁止） |
| `lib/io/api_service.dart` | 新增 auto-title 设置读写；标题来源不暴露给 UI |
| `lib/ui/pages/settings_page.dart` | 新增「会话自动命名」卡片：总开关、LLM 精修开关、标题模型选择器 |
| 测试 | 会话列表重命名入口、设置卡片读写 |

---

## 6. 拍板记录（2026-11-23）

| 编号 | 问题 | 结论 |
| --- | --- | --- |
| D1 | 默认会话是否参与自动命名 | **参与**；同时放开默认会话的手动重命名（删除保持禁止） |
| D2 | LLM 精修默认开还是关 | **默认开**（每会话一次；无模型自动降级） |
| D3 | 覆盖凭据用哪种 | **`title_source` 落盘字段**（`''` / `auto` / `auto_final` / `manual`），旧会话按哨兵回填 |
| D4 | 配置面放哪 | **全局设置页**（`agent_settings.yaml`），一次配置对所有 agent 生效 |

---

## 7. 边界与风险

1. **不回溯**：升级后存量的「新会话 / 默认会话」不会批量改名（否则一次启动可能打几十次模型）。
2. **模型不可用**：规则标题仍在，只是不再精修；日志一条，不弹错。
3. **用户手动改名竞态**：LLM 返回前用户改名 ⇒ 标题 ≠ pending，放弃覆盖。
4. **多 UI / 多端**：改名后统一广播 `session_renamed`，各端一致。
5. **标题长度**：列表已 ellipsis，超长不影响布局；规则/LLM 双截断。
6. **注入风险**：标题是纯文本展示，不经过 Markdown；规则段保留用户原文也不执行。
7. **团队会话**：成员回信落到父会话时，若父会话仍是哨兵且无消息，可能由成员触发命名——
   规则段只接受 `role=user` 的首条消息作为输入，成员回信不参与（实现时按 role 过滤）。

---

## 8. 不做什么

- 不做标题翻译、不做多语言切换。
- 不做历史会话批量补命名。
- 不做"命名可撤销/历史版本"。
- 不为命名新增核心路由或协议帧。
- 不为命名新增独立插件（路线 5 留作长期演进）。

---

## 9. 测试矩阵

| 编号 | 用例 | 期望 |
| --- | --- | --- |
| TC-TITLE-01 | 首条消息为普通中文 | 规则标题 = 清洗后前 24 字（去尾部标点） |
| TC-TITLE-02 | 首条消息含 Markdown 围栏 / URL | 围栏内容与 URL 被剥离 |
| TC-TITLE-03 | 首条消息为空 / 纯符号 | 不命名，保持「新会话」 |
| TC-TITLE-04 | 首条消息超长 | 截断 + `…`，长度不超上限 |
| TC-TITLE-05 | 会话已有历史消息 | 规则段不改名 |
| TC-TITLE-06 | `title_source=manual` | 规则段/LLM 段都不覆盖 |
| TC-TITLE-07 | 规则段成功后广播 | UI 列表标题即时更新（`session_renamed` 帧） |
| TC-TITLE-08 | LLM 返回带引号/「标题：」/多行 | 解析出干净单行标题 |
| TC-TITLE-09 | LLM 返回空 / 报错 / 超时 | 保留规则标题，不抛错 |
| TC-TITLE-10 | 用户在主模型未配置时触发精修 | 跳过 LLM，不产生错误帧 |
| TC-TITLE-11 | 同一会话连发多条消息 | 只命名一次，只调一次 LLM |
| TC-TITLE-12 | 临时员工回合收尾 | 不触发命名 |
| TC-TITLE-13 | 默认会话首条消息 | 按 D1 口径命名；UI 可手动改名 |
| TC-TITLE-14 | 自动命名开关关闭 | 两段都不执行，标题保持原值 |
| TC-TITLE-15 | 旧 `session.json` 缺 `title_source` | 标题为哨兵 ⇒ 回填 `''`；否则回填 `manual` |
| TC-TITLE-16 | 手动改名后重启进程 | 仍是 `manual`，不会被重新命名 |
| TC-TITLE-17 | 精修成功后下一轮收尾 | `auto_final` 挡住重复 LLM 调用 |
| TC-TITLE-18 | `title_source=auto_final` 的会话 | 规则段/LLM 段都跳过 |

---

## 10. 切片与门禁

| 切片 | 内容 | 门禁 |
| --- | --- | --- |
| **T1** | 规则段 + 钩子接线 + 广播（默认开，无配置面）— **已落地（插件仓 `e6984b9`）** | `dart analyze`（tree.agent）0 → 该包全量测试 → `tree_protocol` 访问控制（无改动也跑） |
| **T2** | LLM 精修段 + 配置项 + 降级 — **已落地（插件仓 `cf5df22`）**；补 TC-TITLE-08~11 | 同上 |
| **T3** | 配置 REST + UI 设置卡片 + 默认会话可改名 | 同上，另跑 `tree.ui.default` analyze 与相关 widget 测试；涉及 UI 才跑 flutter |

每个切片独立提交（`plugins` 仓）；文档仓同步更新 `project-status.md` 与 `work-log.md`。

---

## 11. 落地状态

1. ~~用户确认 D1~D4~~（2026-11-23 已拍板，见 §6）。
2. `project-status.md` 并行车道表新增「Q 会话自动命名」。
3. 按 T1 → T2 → T3 顺序实现，每片走门禁与独立提交。
