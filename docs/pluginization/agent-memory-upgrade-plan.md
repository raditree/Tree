# 记忆与上下文治理方案（AGENT-MEM）

> 侦察见 [agent-memory-recon.md](agent-memory-recon.md)；四个拍板项 D1~D4 见该文 §7。
> 本期只落档、不动代码。落地在插件仓：`plugins/tree.agent`（记忆引擎 / 工具 / REST / 快照段）、
> `plugins/tree.ui.default`（agent 配置页 / 记忆管理 / 快照查看器）；桌面仓只提交文档与契约清单。

---

## 1. 目标与边界

**一句话**：把"一个 markdown 随便写"升级为「异步分级存储 + 自动归纳 / 聚类 / 整理 / 衰减 + 可检索可审查」，
并把系统提示词快照从黑箱变成可见但不直接可编辑的透明产物。

| 做 | 不做（本期） |
| --- | --- |
| L0~L4 五层记忆 + score 四维 + tag/type/version | 改核心 35 条永久面（全部走插件委派申报） |
| 异步管道（滚动摘要 → embedding → 提取 / 去重 / 修正 / 衰减） | 每轮重建系统提示词快照（D1：只在初次对话 / compact 重建时刷新注入） |
| `memory` 模型工具（in / recall / forget / archive） | 让用户直接编辑最终快照字节（D3：只读查看） |
| 数据根结构化存储 + 旧文件一次性迁移备份 | 改工作空间私有目录翻译规则（记忆脱离工作空间，SSH 也存本机） |
| agent 配置页（4 tab）+ 记忆管理 + 快照查看器 | 改模型池 kind/protocol（复用现成 chat / embedding） |

---

## 2. 记忆分层模型

### 2.1 五层定义（用户方案原文 + 落地口径）

| 层 | 名字 | 来源与语义 | 落点 / 注入 |
| --- | --- | --- | --- |
| **L0** | 显式长期记忆 | 用户明确要求记住；agent 调 `memory.in(level=L0)` 主动记忆，初始 importance 最高、衰减周期最长。score > 0.6 **全量注入**快照 | 结构化记忆条目；注入段 `## 长期记忆（显式）` |
| **L3** | 异步滚动摘要 | 会话消息增量喂给**用户指定的额外 LLM**（模型池 chat，独立于 agent 主模型）生成滚动摘要，再经 embedding 向量化 | 每会话一份 `overview` + 向量；**不直接进快照**，是 L2/L1 的来源与会话相关性判据 |
| **L2** | 会话记忆 | 从 L3 摘要中提取，**一点一条**（结构化），自动去重 / 修正旧记忆 / 重要性判定 / 自动衰减 | 快照注入得分 TOP N（默认 10，UI 可配），其余 `memory.recall` 召回 |
| **L1** | 长期共享记忆 | L2 候选进入全局池，跨会话找可复用共享记忆（聚类 + 去重 + 修正），一点一条，同样四维 score + 衰减 | 快照注入得分 TOP N（默认 10，UI 可配），其余 `memory.recall` 召回 |
| **L4** | 归档 | 旧记忆被修正前的条目移入 archive，便于回溯审查 | `memory.recall(include_archive=true)` 可召回；不进快照 |

**层级关系**：`会话消息 → L3 摘要/向量 → L2 会话记忆 →（跨会话复用判定）→ L1 长期记忆 →（被修正时）→ L4 归档`。
L0 独立入口（用户显式），不经过 L3。任意层被修正都把旧 version 推入 L4。

### 2.2 记忆条目统一 schema（每条必备字段）

```
id            str    # 稳定 id（生成 16 字节 hex；手工 id 仅需前缀，冲突加位重试——沿用草案口径）
level         enum   # L0 | L1 | L2 | L3 | L4（L3 是 overview 记录，结构略异，见 §2.3）
tag           list[str]    # 必备：分类标签（如 project / preference / ssh / team）
type          enum         # 必备：fact | preference | decision | procedure | entity | summary
version       int          # 自动维护，每次修正 +1；旧 version 进 L4
title         str          # 一句话标题
content       str          # 正文（一点一条，L2/L1 不写长文）
keywords      list[str]    # 检索关键词（来自草案）
recall_cond   list[str]    # 召回条件（来自草案）
score         object       # 见 §3
embedding     list[float]? # 向量；无 embedding 模型时为空并标 degraded
source        object       # {agent_id, l3_id, created_from, sources: [{session_id, score, msg_ids[], at}]}
              # sources 为多来源列表，各带该会话里这条记忆的 score（同一会话多次命中取最高分去重），供 L1 可复用累加判定（D10）
created_at    ms
updated_at    ms
decay         object       # {half_life_days, last_decay_at, frozen} —— L0 frozen=true
status        active | archived
```

- `tag` / `type` / `version` 为**强制字段**，缺失的记忆条目视为损坏，管道跳过并写错误日志（红线：不留静默失败）。
- `version` 只由存储层自增，工具与 UI 都不得手填；修正 = 新建 version+1 的条目 + 旧条目进 L4。

### 2.3 L3 overview 附加结构

```
session_id    str
outline       str          # 滚动摘要正文（追加式：新消息 → LLM → 合并旧摘要）
topics        list[str]    # 从摘要提取的主题（供 L2 提取与聚类）
embedding     list[float]? # outline 的向量
msg_watermark str          # 已消化的消息游标（session 的 seq / msg_id）
updated_at    ms
```

- 每会话一份，落 `data/<agent>/<session>/overview.json`（理由见 recon §5 未知项 2：会话级、随会话走）。
- L2 提取以 `msg_watermark` 为增量起点，避免重复消化。

---

## 3. score 定义

```
score = w_i * importance + w_c * confidence
      + w_t * exp(-ln2 * age_days / half_life_days)
      + w_r * relevance
```

| 维度 | 取值 | 来源 |
| --- | --- | --- |
| `importance` | [0,1] | 提取 / 写入时由 LLM 判定（一点一条时同步给出）；L0 显式记忆初始置 1.0 |
| `confidence` | [0,1] | LLM 对"这条记忆是否正确 / 明确"的置信度；无 LLM 判定时降级为 0.5 并标 degraded |
| 时间衰减 | exp 指数，`half_life_days` 按层配置（L0 最长 / frozen 时不衰减） | 存储层按 `last_decay_at` 惰性重算，无需定时任务逐条写盘 |
| `relevance` | [0,1] | 会话相关性：L3 overview 的 topics/向量与本会话输入的匹配度；**初次构建快照时**按"用户输入 + 项目背景"判定一次，随快照钉住（D1） |

**已拍板默认值（AGENT-MEM-D7）**：权重 `w_i=0.35, w_c=0.20, w_t=0.25, w_r=0.20`；
L0 全量注入阈值 `0.6`；归档阈值 `score < 0.15`；置信度缺省降级值 `0.5`。

| 层 | 半衰期（天） | 说明 |
| --- | --- | --- |
| L0 | frozen（不衰减） | 用户显式长期记忆，衰减维度恒为 1.0 |
| L1 | 180 | 长期共享记忆，约半年衰减一半 |
| L2 | 30 | 会话记忆，约一个月衰减一半 |
| L3 / L4 | 不适用 | overview 不进 score；归档不参与注入 |

权重 / 半衰期 / TOP N / 阈值全部进配置（§4.4），UI 可调；默认值先落地，再按模型池环境实测校准。

**不变式**：
- score 变化是**惰性**的（读时按当前时间算），不触发快照重建（D1）。
- 快照重建时按当时 score 排序取注入集，注入后**字节钉住**直到下次重建。
- 衰减不删除记忆，只降分；低于清理阈值的条目进 L4 归档（可召回）。

---

## 4. 存储与配置

### 4.1 数据根布局（D2）

```
<dataRoot>/
├── memory/<agent_id>/
│   ├── records.semdb        # L0/L1/L2/L4 统一条目库（Sembast，纯 Dart），**向量作为条目字段同库存放**
│   ├── pipeline.log         # 异步管道的可读日志（失败 / 降级 / 去重 / 修正留痕）
│   └── config.json          # 该 agent 的记忆配置（模型 id / 权重 / TOP N）—— 已拍板落此处，不复用 settings 插件
├── data/<agent>/<session>/overview.json   # L3 会话摘要（随会话走）
└── agents/<agent_id>.yaml   # 保留 system_prompt 作为"自己的提示词源"（D3），不新增大字段
```

- **已拍板（AGENT-MEM-D6）**：向量直接存 `records.semdb` 的条目字段（Float32List 编码），不另建向量文件；
  `embedding` 字段与条目其余字段同事务写入，避免"条目在、向量丢"的割裂。
- 与 `tree.storage` 的取舍：本期**数据根直存**（D2），不引入插件依赖；
  若后续要多插件共享再迁 `storage.*`（recon §2.3）。
- Sembast 已在 `tree.agent` 的传递依赖里（`conversation_db.dart` 用），无新增依赖。

### 4.2 与工作空间解耦

- 记忆与提示词源都在数据根，**不再**经过 `PrivateWorkspaceIO` 的 `.self/xxx` 翻译；
  SSH agent 的记忆也写本机数据根（与 recon §4 约束 5 一致）。
- 现有 `MemoryService`（写 `.self/memory.md`）保留为**只读迁移源**，迁移完成后停止写入。

### 4.3 旧数据迁移（D2：一次性导入 + 备份）

- 启动时检测 `<dataRoot>/memory/<agent_id>/migrated.json` 标记，无标记则对每个 agent：
  1. 读工作空间 `.self/memory.md`（SSH agent 从远端工作空间读，读不到则跳过并记日志）→ 按 `##` 章节切分 →
     每条作为一个 L2 条目（importance/confidence 取默认、tag=['migrated']、type='fact'、version=1）。
  2. 读 `.self/system_prompt.md` + agent yaml 的 `system_prompt`：
     - agent yaml 的 `system_prompt` 继续作为"自己的提示词源"（D3），**不动**；
     - 文件里的内容若与 yaml 不同，作为 legacy 文本落 `memory/<agent_id>/legacy_system_prompt.md.bak`，不注入。
  3. 迁移成功写 `migrated.json`（含源文件 hash 与条目数），幂等；原文件**保留不删**（可回溯）。
- 迁移失败不阻塞启动，写 `pipeline.log` + 一次性可读提示。

### 4.4 配置项（**全部阈值都在 UI「agent 配置 → 记忆管理」页可配**，AGENT-MEM-D11）

**拍板**：方案里出现的**每一个阈值 / 权重 / 预算 / TOP N 都是 `config.json` 字段**，没有硬编码常量；
UI 的记忆管理页提供对应控件（数值输入 / 滑块），改完经 `PATCH .../memory-config` 即时落盘。
管道读配置取"当轮快照"——配置变更在**下一次管道 tick / 下一次快照重建**生效，不追溯已钉住的快照（D1）。

| 配置键 | 默认 | 语义 / 出处 |
| --- | --- | --- |
| `memory.embedding_model` | 空 | 无则不向量化、降级 lexical（§5.3） |
| `memory.extract_llm_model` | 空 | 空 = 用 agent 主模型（§5.2 D5） |
| `memory.weights.importance` / `.confidence` / `.time` / `.relevance` | 0.35 / 0.20 / 0.25 / 0.20 | score 四维权（§3 D7） |
| `memory.l0_threshold` | 0.6 | L0 全量注入阈值（§3 / §7.1） |
| `memory.archive_threshold` | 0.15 | 低于此进 L4（§3 D7） |
| `memory.confidence_default` | 0.5 | LLM 未给置信度时的降级值（§3 D7） |
| `memory.half_life_days.L0` / `.L1` / `.L2` | frozen / 180 / 30 | 各层衰减半衰期（§3 D7） |
| `memory.top_n.L1` / `.L2` | 10 / 10 | 快照注入条数（§2.1） |
| `memory.l0_budget_tokens` | 4000 | L0 注入预算（§7.1 D9） |
| `memory.reuse.min_sources` | 2 | L1 可复用最少来源会话数（§5.4 D10） |
| `memory.reuse.min_score_sum` | 1.0 | L1 可复用来源 score 累加阈值（§5.4 D10） |
| `memory.cluster.similarity` | 0.82 | 向量余弦同题阈值（§5.4 D8） |
| `memory.cluster.lexical_jaccard` | 0.6 | 无向量降级 Jaccard 阈值（§5.4 D8） |
| `memory.cluster.tag_overlap_min` | 1 | 聚类的 tag 交集下限（§5.4 D8） |

- 模型 id 字段必须是模型池中 `kind=embedding` / `kind=chat`，校验复用 `DomainSettings.validateModelChange`（`domain_settings.dart`）；
  数值字段做范围校验（权重和 = 1.0、半衰期 > 0、阈值 ∈ [0,1] 或 >0、budget > 0），校验失败回可读 400。
- UI 记忆管理页按分组展示（score 权重 / 注入预算 / 衰减 / 聚类 / 可复用 / 模型），带"恢复默认"按钮
  （默认值即表内值，写回 `config.json` 前 `delete` 对应键）。
- 移动端式"高级"折叠：普通用户只调 TOP N / 预算 / 模型，权重与阈值收在高级区——但**都能改**（不做只读常量）。

---

## 5. 异步管道设计

### 5.1 触发与调度

- **触发**：会话有新消息落库 → 登记"待消化"任务（按 `agentId|sessionId` 串行，不同会话并行——与会话运行键同口径）。
- **不阻塞对话**：管道独立 Future，失败只记 `pipeline.log`，不影响 `user_message` 的回答链路。
- **无硬超时**：单次 LLM / embedding 调用沿用 `llm.call` 的软超时 + 显式关闭入口（`llm_json_caller.dart`）。
- **并发上限**：单 agent 同时最多 1 个 L3 摘要任务（单飞），避免摘要风暴。

### 5.2 流水线（每会话）

**已拍板（AGENT-MEM-D5）**：L3 摘要**新写一条 `llm.call` 路径**，不改造 `CompactionService._summarize`
——那条是压缩触发、与 `compactedSummary` 耦合，硬塞异步滚动会污染压缩语义与前缀缓存口径。
用 `responseFormat: 'text'` 避免 `json_object` 改写前缀（known-issues #27）；提示词与解析独立成
`plugins/tree.agent/lib/src/memory/l3_summarizer.dart`，与压缩互不调用。

```
1. 取 msg_watermark 之后的新消息 → 喂 extract LLM（新 llm.call 路径，text 形态，见上）
2. 合并旧 overview.outline → 新 L3 overview + topics → embedding（有模型时，D6 存 semdb）
3. 从 outline/topics 提取 L2 候选（一点一条，LLM 给 tag/type/importance/confidence）
4. 对每条候选：向量相似检索已有 L2/L1 →
   - 高相似且矛盾 ⇒ 修正：旧条目 version+1 内容替换，旧 version 进 L4
   - 高相似且一致 ⇒ 合并（更新 source / 提升 confidence）
   - 无相似 ⇒ 新建 L2
5. 跨会话复用判定（AGENT-MEM-D8，见 §5.4）：L2 条目与 L1 池聚类 → 可复用者提升为 L1
6. 衰减：按半衰期计算 score（惰性）→ 低于归档阈值（0.15）的条目进 L4
```

### 5.4 L1 跨会话聚类判据（AGENT-MEM-D8）

用户授权本方案定夺，取值如下（写进 `config.json`，可改）：

- **候选筛选**：L2 条目创建后，按 `tag` 交集 ≥ 1 **且** `type` 相同筛出 L1 池候选，再算向量相似度。
- **同题阈值**：余弦 ≥ `0.82` 判为"同一件事"→ 走合并 / 修正流程（同 §5.2 步骤 4）；
  `< 0.82` 视为新主题，新建 L1 条目。
- **可复用判定（AGENT-MEM-D10，用户 2026-11 修订）**：某 L1 条目的 `source.sources` 去重来源
  **≥ 2 个会话**，且**各来源 score 累加 `Σsource.score > reuse_min_score`**（默认 `1.0`）⇒ 才认定为
  "跨会话可复用"，进入快照 L1 TOP N 池；不满足的留在 L2 池（不进 L1 注入段）。
  - 默认值 `1.0` 的理由：相当于两来源平均 score ≥ 0.5，与 L0 注入阈值 0.6、归档阈值 0.15 形成梯度；
    时间衰减会让老来源分数下降，门槛不宜再高；只数来源数会把"在多会话里都平庸"的记忆误抬成长期记忆。
  - 每个 `source.sources[]` 带该来源会话里这条记忆的 score（同一会话多次命中取最高分），累加用它。
- **聚类粒度**：L1 一条 = 一个可复用结论（一点一条），不按会话聚合；多会话来源记在同一条目的
  `source.sources[]`（按 session_id 去重）。
- **无向量降级**：无 embedding 时用 tag 交集 + keywords Jaccard ≥ `0.6` 替代余弦，标 `degraded`（与 §5.3 一致）。

### 5.3 失败与降级（红线：不留静默失败）

| 失败 | 降级 | 留痕 |
| --- | --- | --- |
| 无 embedding 模型 | 检索回退 lexical（tag + keywords + grep），条目标 `degraded` | `pipeline.log` 一次 + 配置页黄条提示 |
| extract LLM 失败 | 保留 L3 outline 原文，跳过本轮 L2 提取，下次重试 | 失败计数 + 一次性广播 |
| 摘要合并矛盾 | 不自动采信，记入 L4 + 标 `needs_review`，UI 可见 | `pipeline.log` |
| 存储写失败 | 整批回滚（Sembast tx），任务标 failed | 日志 + UI 错误态 |

---

## 6. 模型工具 `memory`（新增）

经 `station_tool_runner._buildSpecs` 加 ToolSpec（工具组「记忆」），走现有工具循环；
执行落点复用 `MemoryService` 的新实现（数据根），不再写 markdown。

| action | 参数 | 回包 |
| --- | --- | --- |
| `in` | `level` / `title` / `content` / `tag[]` / `type` / `importance` | `id` / `version` / `score`；要求先 `recall` 去重（沿用草案口径） |
| `recall` | `query` / `level?` / `top_k` / `include_archive?` / `tags?` | 命中条目（含 score 明细）+ 是否走了 lexical 降级 |
| `forget` | `id` / `reason` | 移入 L4（不硬删） |
| `archive` / `restore` | `id` | 状态切换 |
| `overview` | `session_id?` | L3 摘要正文（给 agent 自省用） |

- 工具描述随代码走（`tool/*.dart` 的 `ToolSpec`），系统提示词种子 / 内置 Spec 的「工具路由」段同步加一行
  （架构 §8.1 的三处同口径规则）。
- 执行站命令 `agent.memory.*` 保留给产线（写侧改为新存储），新工具名不与它冲突。

---

## 7. 快照注入与查看器（D1 + D3）

### 7.1 注入机制

- 在 `workspace_prompt.dart` 增加 `memorySectionProvider(agent, sessionId) → String`，
  由 `promptStatePrewarm` 在钉住前预取（同步拼装不变，MEM-R4）：
  ```
  ## 记忆（本次快照，score 排序）
  ### 长期记忆（L0，score>0.6）
  - …
  ### 共享记忆（L1，TOP N）
  - …
  ### 会话记忆（L2，TOP N）
  - …
  ```
- 注入集在**快照重建时**一次性计算并随之钉住；之后异步管道再怎么更新，当前会话快照不变（D1）。
- 压缩估算（`CompactionService.estimateContextTokens`）走同一个 `systemPromptWithWorkspace`，自动同口径。
- **已拍板（AGENT-MEM-D9）**：L0 注入预算 **4k token**（走 `util/tokens.dart` 的统一口径 `ceil(字符/token_scale)`，
  按每模型 `token_scale` 折算），L1 / L2 各 TOP N 另计；超预算的 L0 条目按 score 从低到高裁掉，
  被裁条目仍可 `memory.recall` 召回。注入段总预算与裁剪留痕写进 `pipeline.log`。

### 7.2 快照查看器（D3）

- 新增 REST `GET /api/agents/{agentId}/sessions/{sessionId}/prompt-snapshot`（委派申报）：
  回 `{system_prompt, sections: [{name, chars, source}], pinned_at, dirty_sources, next_rebuild_hint}`。
  - `sections` 标明每段来自哪（agent 提示词源 / L0 / L1 / L2 / Spec / 工作空间段），
    `dirty_sources` 列出"来源已变但快照未重建"的段（改了提示词 / 记忆更新），`next_rebuild_hint` 提示开新会话或压缩。
  - **只读**，不支持 PATCH；编辑走"自己的提示词源"与记忆管理页。
- UI：agent 配置页第 4 个 tab「系统提示词」上半编辑 agent 提示词源（`PATCH agent.system_prompt`），
  下半只读展示快照 + 段来源 + dirty 提示。

---

## 8. 契约与 REST（委派申报，不动核心 35 条）

tree.agent 在 `kDeclaredRoutes` + `system.collect.api.routes` 追加（路径经命名空间校验，非保留前缀）：

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| GET | `/api/agents/{agentId}/memory` | 列表（level / tag / status / 分页） |
| POST | `/api/agents/{agentId}/memory` | 手动创建（UI 记忆管理） |
| PATCH | `/api/agents/{agentId}/memory/{memoryId}` | 编辑 / 修正（自动 version+1） |
| DELETE | `/api/agents/{agentId}/memory/{memoryId}` | 移入 L4 |
| POST | `/api/agents/{agentId}/memory/search` | 向量 / 混合检索（含 `include_archive` / `query`） |
| GET | `/api/agents/{agentId}/memory-config` | 读记忆配置 |
| PATCH | `/api/agents/{agentId}/memory-config` | 写记忆配置 |
| GET | `/api/agents/{agentId}/sessions/{sessionId}/prompt-snapshot` | 只读快照查看器 |
| GET | `/api/agents/{agentId}/memory/pipeline/status` | 管道状态（上次消化水位 / 失败计数 / 降级标记） |

> **路径歧义修正（M2 实施）**：配置端点刻意用 `memory-config` 而非 `memory/config`——后者与 `memory/{memoryId}` 段数相同，`{memoryId}` 占位符会把 "config" 当成记忆 id，PATCH 会误走「修正记忆」。同理 `memory/search` 也需在 item 分支显式排除 search 保留段。两处回归钉子见 `memory_delegate_test.dart`。

- `packages/tree_protocol/lib/src/api_paths.dart`：上述加入 `delegated` 集合（`contractRoutes` 自动包含）；
  核心 `coreOwned` 35 条不动。
- UI 经 `api_service.dart` 加对应方法（沿用 `updateAgent` / models-info 的写法）。

---

## 9. UI：模型信息页 → agent 配置页

### 9.1 结构

`RightPanelEntry(id: 'modelInfo')` 保留 id（兼容引导 / 测试定位），label 改「agent 配置」，
`bodyBuilder` 换成 `AgentConfigPanel`：左侧 tab 导航 + 右侧内容。

| tab | 内容 | 来源 |
| --- | --- | --- |
| 模型配置 | 现有模型下拉 / 参数覆盖 / 模型 info 卡 + **新增** embedding 模型、提取 LLM 两个选择器 | `ModelInfoPanel` 现有逻辑（仅列 kind=chat）+ 模型池按 kind 过滤 |
| 工具配置 | 现有工具勾选 + tool_groups | 原样迁入 |
| 记忆管理 | 向量搜索 / 手动创建 / 编辑 / 删除（移入 L4）/ L4 归档浏览 / 管道状态；**全部阈值配置控件**（score 权重 / L0 阈值与 4k 预算 / 归档阈值 / 半衰期 / TOP N / 聚类余弦与 Jaccard / 可复用来源数与累加阈值 / 模型选择），分组展示 + 高级折叠 + 恢复默认 | 新 REST §8（含 `PATCH .../memory-config`）；字段全集见 §4.4 |
| 系统提示词 | 上半编辑自己的提示词源（`agent.system_prompt`），下半只读快照查看器 | §7.2 |

- 旧 `.self/system_prompt.md` 的重置按钮（`file_panel.dart` / `api_service.dart:2565` reset）改为
  "重置自己的提示词源"= 清 `agent.system_prompt`；不再播种文件。
- 期望宽度从 480 调宽（4 tab 内容），沿用 `preferredWidth` 只放宽、用户拖过即停的口径。

### 9.2 文档 / 引导同步（UI 在插件仓）

- `plugins/tree.ui.default/lib/README.md` 不变量 28（窗口列表）、`onboarding_steps.dart:62-66`、
  `main_page.dart` entry label、`api_service.dart` 注释 → 全部"模型信息"改"agent 配置"。
- `docs/README.md`、`docs/architecture.md` §8.1 提示词资产表改写（基础段不再是文件播种而是快照查看）。
- `CHANGELOG.md` 按断言变更记条目（配置页 tab 结构、快照只读、记忆脱离工作空间）。

---

## 10. 切片（建议顺序，开工前按项目状态投车道）

| 切片 | 内容 | 出口判据 | 依赖 |
| --- | --- | --- | --- |
| **M1 存储骨架** | `memory/<agent_id>/` semdb schema + score / tag/type/version 不变量 + 旧文件迁移 | 单测：schema 校验 / version 自增 / 迁移幂等 / 无静默失败 | 无 |
| **M2 REST + 配置** | §8 委派路由 + `contractRoutes` + UI API 方法 + config 校验 | 契约测试绿（114→+9）、黑盒假核心 | M1 |
| **M3 异步管道** | L3 摘要 / embedding / L2 提取 / L1 聚类 / L4 归档 / 降级 | 假 LLM + 假时钟单测：去重 / 修正 / 衰减 / 失败降级 | M1, M2 |
| **M4 工具 + 快照段** | `memory` ToolSpec + 执行落点 + `memorySectionProvider` 注入 + 快照 REST | 逐字一致断言：两处拼装同字节；快照重建前后钉住 | M3 |
| **M5 配置页** | agent 配置页 4 tab + 记忆管理 + 快照查看器 + 引导 / README / CHANGELOG | UI 单测 + `flutter analyze lib` + 跨仓 README 门禁 | M2, M4 |

**测试矩阵**（每切片按 `CONTRIBUTING.md` §2）：
- 纯函数（score / 衰减 / 去重判据）：边界 + 错误分支单测。
- 存储 / 工具：本机与 SSH 同形断言（记忆脱离工作空间后两者应完全一致）；越界与失败路径。
- REST：新路由进 `contractRoutes` + 端到端（假核心）；快照查看器只读（无 PATCH）。
- 异步管道：假 LLM / 假 embedding / 假时钟；禁止真实网络与睡眠。
- UI：组件测试 + 假核心 HTTP；窗口更名后引导定位仍生效。

**车道建议**：桌面仓新开「N 记忆与上下文治理」车道（状态：待开始，本期文档完成即挂方案链接）；
M1~M5 按上表顺序推进，与车道 H（生产线）无文件区域冲突（不同插件目录）。

---

## 11. 追加拍板记录（AGENT-MEM-D5~D11，2026-11 用户定稿）

首轮 D1~D4 见 [recon §7](agent-memory-recon.md)；本轮把侦察 §5 的待清项全部拍死：

| ID | 拍板 | 落地位置 |
| --- | --- | --- |
| **D5** | L3 摘要**新写 `llm.call` 路径**，不改造 `CompactionService._summarize` | §5.2（新 `memory/l3_summarizer.dart`） |
| **D6** | 向量作为条目字段存 `records.semdb`，不另建向量文件 | §4.1 |
| **D7** | score 权重 `0.35/0.20/0.25/0.20`、L0 阈值 `0.6`、归档阈值 `0.15`、L0/L1/L2 半衰期 `frozen/180/30` 天、置信度缺省 `0.5` | §3 |
| **D8** | L1 聚类判据由本方案定夺：tag 交集 ≥1 + 同 type 筛选、余弦 ≥0.82 同题、无向量回退 Jaccard ≥0.6 | §5.4 |
| **D9** | L0 注入预算 **4k token**（统一 token 口径），超预算按 score 裁剪、可 recall | §7.1 |
| **D10** | **L1 可复用判据修订**：来源 ≥2 会话**且各来源 score 累加 > 阈值**（默认 `1.0`，即平均 ≥0.5）；`source` 扩为带 score 的多来源列表 | §5.4 / §2.2 |
| **D11** | **所有阈值 / 权重 / 预算 / TOP N 都在 UI「agent 配置 → 记忆管理」页可配**，无硬编码常量；配置落 `config.json`，下次 tick / 快照重建生效 | §4.4 / §9.1 |
| — | 记忆配置落 `config.json`（不复用 `tree.settings` 的 plugin 绑定库） | §4.4 |

以上均为**默认值进配置**、可后续按模型池实测调整；调整走配置不改代码（D7 的权重 / 阈值、D8 的阈值、D9 的预算、D10 的累加阈值都是 `config.json` 字段）。

**仍属实施细节（不阻塞、不需再拍板）**：D6 的 Float32List 在 semdb 里的具体编码、D5 摘要提示词文案、
`pipeline.log` 的轮转策略——由 M1 / M3 切片按本仓既有口径（`write_queue` / `core_log_sink`）自行定夺。

### 11.1 M3 落地时自查发现并修正的偏差（2026-11）

M3 提交后自查，发现五处"实现与方案/自身注释不符"，已在同批修正并补回归钉子：

| 偏差 | 现象 | 修正 | 回归钉子 |
| --- | --- | --- | --- |
| `embedder` 是死代码 | 管道注入了它但从不调用，D6「向量存 semdb」没兑现 | L3 overview 更新时对 outline 向量化并写入 `overview.json.embedding` | `L3 overview 真的被向量化` |
| 降级标记失真 | `_similarity` 两分支都返回 Jaccard，`degraded` 恒 true | 降级只由 L3 向量化失败驱动；去重走 lexical 是常态不算降级 | `无 embedding 模型 ⇒ degraded=true` |
| 阈值误用 | `cluster.similarity`(0.82，为余弦设计)当 Jaccard 阈值，中文短句几乎判不出同题 | Jaccard 用 `cluster.lexicalJaccard`(0.6)；cosine 才用 0.82 | `内容不同但同题 → 修正`（改成硬断言） |
| L1 提升污染归档 | `put(asCorrection:true)` 让 L2→L1 在 L4 留旧版垃圾 | 提升用 `put()` 直接覆盖、version 不变、不写 archive | `L1 提升不写 archive` |
| 新 id 用真实时钟 | `_newId` 用 `DateTime.now()`，测试不可控 | 改用注入时钟 `_now` | 全量测试可复现 |

排查口径：这五处都是**注释/文档说 A、代码做 B**——正是"文档与代码冲突以代码为准，但偏差要记档"那条侦察纪律要抓的形态。M4/M5 落地时同样先自查再提交。
