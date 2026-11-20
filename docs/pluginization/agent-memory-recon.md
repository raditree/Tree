# 记忆与上下文治理侦察（AGENT-MEM）

> **本期只落档，不动代码**。输入：用户 2026-11 提出的「记忆机制升级 + 系统提示词快照透明化」方案；
> 四个拍板项已在侦察前定稿（见本文 §7）。对码范围：`plugins/tree.agent`（0.32.1）、
> `plugins/tree.ui.default`（1.0.10+）、`plugins/tree.settings`、`plugins/tree.storage`、
> `packages/tree_protocol`、`packages/tree_core`。记录原则：只写已核验的代码事实（路径 + 行号 / 符号名）；
> 推测一律标「待确认」。方案见 [agent-memory-upgrade-plan.md](agent-memory-upgrade-plan.md)。

---

## 1. 结论摘要

| ID | 结论 | 判定 | 证据 | 对方案的影响 |
| --- | --- | --- | --- | --- |
| MEM-R1 | 现有"记忆"就是 `.self/memory.md` 一个 markdown，按 budget 保留最近字符；`agent.memory.*` 是**执行站命令**而非模型工具 | 已核验 | `memory_service.dart:18/49/63-81`、`agent_tools.dart:38-40` | L0~L4 全要新建，旧的 `MemoryService` 只在迁移路径里保留 |
| MEM-R2 | 系统提示词**按会话钉住**在 `session.json.system_prompt_pinned`，断言"来源变了不重建，只有初次对话/compact 重建" | 已核验 | `conversation_service.dart:2244-2346`、`records.dart:309-322` | 拍板项①：记忆注入随快照重建才生效，异步管道只改存储 |
| MEM-R3 | **文档与代码有偏差**：`docs/architecture.md` §8.1 说系统提示词基础段来自 `.self/system_prompt.md`，但代码里 `systemPromptFileProvider` / `promptStatePrewarm` **没有生产接线点**（只在定义、测试、`reset` 端点出现） | 已核验（grep 全仓） | `workspace_prompt.dart:42,150`、`conversation_service.dart:2188,2302`、`prompt_store.dart:23-76`、`delegate.dart:440-450` | 拍板项③「编辑自己的提示词源」要先定：恢复文件接线 or 直接迁到数据根结构化存储（用户已拍板后者） |
| MEM-R4 | `systemPromptWithWorkspace` 是**同步**函数，会话生成与压缩估算两处共用，`specIndexProvider` 等 provider 是两处同口径的唯一手段 | 已核验 | `workspace_prompt.dart:6-42,141-173`、`compaction_service.dart:455,484` | 记忆段注入必须走同类 provider，**不能**改成异步函数或参数直传，否则压缩阈值失真 |
| MEM-R5 | `llm.embed`（OpenAI `/embeddings`，kind=embedding）与 `llm.call`（可指定 model_id，缺省 JSON / 显式 text）已落地，都是**执行站命令** | 已核验 | `agent_runtime.dart:777,990,1085-1149`、`embedding_client.dart:41-105`、`llm_json_caller.dart:1-75` | L3 摘要 + 向量化可直接复用，不用加新模型协议 |
| MEM-R6 | 数据根布局已有 `config/ data/ agents/ logs/ hooks/ store/ settings/ storage/ plugin_settings/`；**没有** `memory/` | 已核验 | `tree_paths.dart:29-158`、`settings_engine.dart:60-82` | 拍板项②：新增 `<dataRoot>/memory/<agent_id>/`（数据根下，非工作空间） |
| MEM-R7 | UI「模型信息」是右栏 `RightPanelEntry(id: 'modelInfo')`，`ModelInfoPanel` 一个 StatefulWidget 内放模型 / 提示词 / 参数 / 工具勾选；引导文案与 README 不变量 28 都按"模型信息"写死 | 已核验 | `main_page.dart:1955-1976`、`model_info_panel.dart:1-120`、`onboarding_steps.dart:62-66`、`lib/README.md:582-658` | 拍板项③：更名「agent 配置页」需同步改 UI 5 处 + 跨仓 README 门禁 |
| MEM-R8 | 新增 REST 需进 `tree_protocol.ApiPaths.delegated` + `contractRoutes`（当前 114 = 核心 35 + 委派 79），由 tree.agent 经 `system.collect.api.routes` 申报（36 条已申报） | 已核验 | `api_paths.dart:583-586`、`tree_agent_loop.dart:151`、`tree.agent_plugin.dart:349-352` | 记忆管理 / 快照查看的 REST 端点走委派申报，不动核心 35 条永久面 |

---

## 2. 现状逐块侦察

### 2.1 记忆（L0~L4 全部缺席）

- `MemoryService`（`plugins/tree.agent/lib/src/agent/memory_service.dart`）：
  - `kMemoryFileName = 'memory.md'`，路径 `${privateSelfDir(agentId)}/memory.md`（`:18,49`）——**工作空间私有目录**，SSH agent 的记忆在远端那台机器上。
  - `get()`（`:54-81`）读全文、按 `budgetChars`（200~20000）**保留尾部**；`record()`（`:84-130`）追加 `## 时间 · purpose` 一节，`memory-id = sha256(purpose|taskId|summary)` 幂等去重。
  - 上限 `maxFileChars = 200000`，超出从最旧章节丢（`:33,182-199`）。
- 暴露面是**执行站命令**：`kAgentHostCommands` 里 `agent.memory.get` / `agent.memory.record`（`agent_tools.dart:38-40`），宿主在 `agent_runtime.dart:1004-1020`。
  **模型看不到它**——工具目录（`station_tool_runner.dart:98-230` 的 `_buildSpecs`）没有 memory 工具，`kAgentToolCommands`（`agent_tools.dart:12-20`）也不含它。
- 与产线的关系：`docs/architecture.md §8.1` 列的 `agent.memory.get/record` 消费方是 `tree.production.line`（记忆端口只存 hash/sources）。
- 草案仅有 `docs/pluginization/agent-memory-model-draft.md`（uuid / level / title / keywords / recall_conditions / content + `in`/`recall` 方案），**未实施、未进索引**。

### 2.2 系统提示词快照（黑箱的确切形状）

- 拼装：`systemPromptWithWorkspace(agent, sessionId, specIndex, selectedSpecs)`（`workspace_prompt.dart:141-173`），5 段顺序：
  `systemPromptFileProvider(agent)`（基础段）+ `agent.systemPrompt` + `workspacePromptSuffix(agent)`（工作空间软约束）+ Spec 索引 + 已选 Spec 全文。
- 钉住：`_ensureSystemPromptPinned`（`conversation_service.dart:2297-2321`）在初次对话预热后拼装并落 `session.json`；
  `_systemPromptPinned`（`:2325-2346`）同步取用；`invalidateSystemPrompt`（`:2265-2284`）只服务 compact 与排障。
  注释明确：改源文件 / 改 agent 提示词**不再触发重建**，要生效就开新会话或压缩（`:2255-2263`）。
- 用户视角：UI 里「系统提示词」输入框写的是 `agent.systemPrompt`（`api_service.dart:878-899` 的 `updateAgent`），
  **`PATCH /api/agents/{id}` 改它也不重建快照**——这就是"改了没用"与"看不到实际发了什么"两个体感的共同根因。
- **偏差 MEM-R3**：基础段 provider 无生产接线，`POST /api/agents/{id}/reset` 仍会播种 / 重置 `.self/system_prompt.md`
  （`delegate.dart:420-451`、`prompt_store.dart:29-76`），但那份文件不会进 `systemPromptWithWorkspace` 的输出。
  需在方案中明确处置（用户已拍板"不再播种，改存数据根用户数据"）。

### 2.3 可复用的现成能力（不必重造）

| 能力 | 落点 | 备注 |
| --- | --- | --- |
| Embedding（向量化） | `llm.embed` 宿主命令（`agent_runtime.dart:1085-1149`）+ `EmbeddingClient`（`embedding_client.dart:41-105`） | 只认 kind=embedding；无模型时回 `no_embedding_model`；batch + 维度校验齐全 |
| 提取 / 判定 LLM | `llm.call` 宿主命令（`llm_json_caller.dart:12-75`） | 可显式 `model`；缺省 JSON（`response_format`），显式 `responseFormat: 'text'` 走纯文本；软超时不中止 |
| 会话压缩摘要 | `CompactionService`（`compaction_service.dart:716-778`）+ `session.compactedSummary` | L3「滚动摘要」可复用其调用链，但它是**压缩触发**的，不是异步定时的——差异见 §5 未知项 |
| 会话存储 | `ConversationDb`（Sembast，`conversation_db.dart:11,456`） | 与记忆库分离：记忆存数据根 `memory/`，会话存 `data/` |
| 集合存储 | `tree.storage` 的 `storage.*`（`tree-storage-recon.md`） | 每团队 × 每插件一库；namespace = plugin_id；**备选**，本期用户已拍板数据根直存 |
| 插件设置 | `tree.settings` 的 `settings.*` + plugin 绑定全局库（`settings_engine.dart:49-82`） | 模型 id / TOP-N 等配置项可放这里，也可直接进 agent 记录，见方案 §4.4 |
| 提示词预热 | `conversation_service.promptStatePrewarm`（`:2188,2302`） | 目前无生产接线；记忆段要进快照，靠它预取而非改同步拼装 |

### 2.4 UI 与契约接线点

- 右栏窗口宿主：`RightPanelEntry`（`right_panel_host.dart:10-47`）+ `main_page.dart:1949-1980`（`modelInfo` entry，preferredWidth 480）。
- 面板：`model_info_panel.dart`（单 StatefulWidget，模型下拉 / 提示词编辑 / 参数覆盖 / 工具勾选 / 模型 info 卡）。
- API：`api_service.dart:878-915`（`updateAgent`）、`:938+`（models-info）、`:2565+`（reset）。
- 引导与文档：`onboarding_steps.dart:62-66`（"3/8 确认它的模型信息"）、`lib/README.md:19,582-658`（不变量 28：窗口种类 9 个内置，含模型信息）、
  `docs/README.md`（文档索引门禁）、`docs/architecture.md §8.1`（提示词资产表）。
- 协议：`ApiPaths.delegated` / `contractRoutes`（`api_paths.dart:583-586`）+ tree.agent 的 `kDeclaredRoutes`（`tree_agent_loop.dart:151`）
  与 `system.collect.api.routes` 申报（`tree.agent_plugin.dart:349-352`）。

---

## 3. 文档侦察结论（先文档后代码）

| 文档 | 关键结论 | 与代码的偏差 |
| --- | --- | --- |
| `docs/architecture.md` §4/§8.1 | 系统提示词钉住策略；基础段来自 `.self/system_prompt.md`；工具表每轮现取 | 基础段 provider 无生产接线（MEM-R3）；本期按用户拍板改存数据根，文档需重写 |
| `docs/project-status.md` | 快速迭代；车道 H（生产线）进行中；最多 3 条进行中 | 本次治理需新开车道（见方案 §7） |
| `docs/pluginization/agent-memory-model-draft.md` | 记忆模型草案（uuid/level/keywords/recall_conditions）+ `in`/`recall` | 用户新方案（L0~L4 + score + 异步管道）取代它；草案未进索引 |
| `CONTRIBUTING.md` §3/§4 | 文档制度；模块 README 必须有不变量 + 测试；CHANGELOG 只记断言 | 方案落地时需同步 tree.agent / UI README 与 CHANGELOG（本期仅文档，不触发） |
| `docs/pluginization/production-line-completion-recon.md` | PC 系列切片体例、D 拍板项写法 | 本文沿用其体例 |

---

## 4. 依赖与约束

1. **前缀缓存是硬约束**（架构 §4）：`system` 一变整条历史前缀缓存作废；记忆段必须随快照钉住，不能每轮变字节。
2. **同步拼装约束**（MEM-R4）：`systemPromptWithWorkspace` 两处共用，记忆注入只能走 provider（预取快照），不能改成 async 或直传参数。
3. **插件零核心依赖**：tree.agent 不得 import `tree_core` / `tree_protocol`；新增 REST 只能委派申报（`CONTRIBUTING.md` §5）。
4. **两个 git 仓**：tree.agent 与 UI 源码都在插件仓（`plugins/` 是独立 clone），桌面仓只提交文档 / 内核 / 发布工程。本期文档在桌面仓。
5. **per-agent 私有目录翻译**：现有 `.self/xxx` → `.tree/<agent_id>/.self/xxx`（`PrivateWorkspaceIO`）；用户拍板后记忆与提示词源**脱离工作空间**，不再经过这层翻译（SSH agent 的记忆也在本机数据根）。
6. **测试纪律**：时间衰减 / 滚动窗口 / 去重都要可注入时钟与假 LLM；禁止真实网络与真实睡眠（`CONTRIBUTING.md` §2）。

---

## 5. 未知项 / 待确认（不阻塞本期文档，开工前要清）

1. **L3 滚动摘要的触发模型**：复用 `CompactionService._summarize` 的调用链改造成"定时 + 增量"，还是新写一条 `llm.call` 路径？
   `compaction_service.dart:716-778` 现在是压缩触发、按 `compactedSummary` 增量；异步任务需要独立的调度与并发控制。
2. **"会话 overview（session relevance）"的落点**：用户方案要求"每个会话在后台异步维护 overview，根据 L3 生成"；
   它存 `<dataRoot>/memory/<agent_id>/` 还是 `data/<agent>/<session>/overview.json`？倾向于后者（会话级、随会话走），待定。
3. **L1 跨会话共享的判据**：「跨会话寻找可复用共享记忆」的聚类键是什么（tag + type + 向量相似度阈值？），
   "一点一条"的粒度与 L2 的区别要不要在 UI 上可见？
4. **score 权重与阈值**：importance / confidence / 时间衰减 / 会话相关性四维如何加权，`0.6` 是全量注入的固定阈值还是可配？
   方案给出默认公式与可配项，具体数值待模型池环境实测校准。
5. **embedding 缺失降级**：无 embedding 模型时 L2/L1 的向量检索回退 lexical（grep / tag 匹配）——
   与 `tree.docnorm` 的 hybrid 降级口径是否统一？
6. **旧数据迁移边界**：`.self/memory.md`（可能在远端工作空间）与 `.self/system_prompt.md`（有 `.bak.<n>`）如何迁入数据根，
   导入后原文件保留还是删除；SSH 场景要不要从远端拉取——用户已拍板"数据根下 + 一次性导入并备份"，具体搬移方式待切片细化。

---

## 6. 初始风险

| 风险 | 说明 | 缓解方向 |
| --- | --- | --- |
| 快照失效误解 | 记忆更新后用户期待"立刻生效"，但拍板①决定只在重建时注入 | UI 明确显示"当前快照版本 / 下次生效时机"（快照查看器），文档写死口径 |
| 异步管道吞失败 | LLM / embedding 调用失败若静默，记忆库会悄悄缺条目 | 失败写 `<dataRoot>/memory/<agent_id>/pipeline.log` + 广播一次可读提示（红线：不留静默失败） |
| 快照体积膨胀 | L0 全量 + L1/L2 TOP10 + 工作空间段 + Spec 全文，长会话可能撑爆上限 | 注入预算（字符 / token 双限）+ 超出按 score 截断，压缩估算复用同一拼装函数 |
| 两个 git 仓漏提交 | 本期只文档；后续切片 UI + agent 改动必须两仓分别提交 | 每个切片验收清单加"两仓提交号"一栏 |
| 文档门禁红 | 新增文档未进 `docs/README.md` 索引 / 相对链接失效 | 方案与笔记同批改索引，提交前跑 `packages/tree_protocol` 的 `docs_contract_test.dart` |

---

## 7. 已拍板项（用户 2026-11 定稿）

| ID | 拍板 | 直接后果 |
| --- | --- | --- |
| D1 | **遵守现有断言**：异步管道只更新存储，记忆注入只在初次对话 / compact 重建快照时刷新 | 不动 `systemPromptPinned` 语义；不每轮重建；UI 要展示快照版本与"下次生效"提示 |
| D2 | **数据根下**：`<dataRoot>/memory/<agent_id>/` 结构化存储；老 `memory.md` / `system_prompt.md` 一次性导入并备份 | 记忆与工作空间解耦（SSH agent 也存本机）；迁移切片要处理远端旧文件 |
| D3 | **编辑"自己的提示词源" + 只读快照展示**：UI 编辑 agent 自己的提示词源，另给只读的最终快照查看器 | 不开放整份快照编辑；快照查看器展示实际注入字节（含各段来源） |
| D4 | **先出侦察笔记 + 方案文档**，确认后再开工代码 | 本期桌面仓只改文档；代码切片见方案文档，不夹带实现 |
