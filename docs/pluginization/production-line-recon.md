# 标准开发流生产线（Production Line）侦查与落档

> **状态**：2026-11-08 侦查 + 语义对齐完成，**只落档，不改代码**。
> **定位**：与 Agent 同级的第二条工作流——面向「每天只有 20 分钟分发任务、只做决策、不看过程」的用户。
> **本期边界**：只做规划、方案落档与语义对齐；执行阶段等「文档规范化」落地后再开（用户 Q7）。
> **输入**：2026-11-08 用户需求正文 + Q&A 八条（见 §4 定稿表）。

---

## 1. 结论先行

1. **产线不是 Agent 的一种**，而是一条**文档驱动的固定流水线**：Agent 是自由对话，产线是
   「侦查 → 对齐 → 定范围 → 拆任务 → 打包 → 执行 → 门控」的固定站位。
   两者在左活动栏**同级并列**，各有自己的配置页、数据与生命周期。
2. **三个实体**：产线实例（`ProductionLine`）、任务（`Task`）、员工（`Worker`）。
   员工 = 临时员工，按角色（主控/打包/执行/专家）绑定模型与工具白名单。
3. **两个阶段**：准备阶段（只在用户每天 20 分钟的**活跃窗口**内推进，全靠文档）与执行阶段
   （打包模型 → 执行模型）。准备阶段的产物先落档为**项目资产**（人读、可提交）与
   **插件数据**（机读、不入库）。窗口只是「用户在线」的边界，**单题不设时限**；
   未答问题跨日续答，**未回答前不实施**（§8.1）。
4. **一期可做**：数据模型 + 任务队列 + 准备阶段 + 模型配置页/工具选择；
   **执行阶段**依赖「文档规范化」完成（它是产线的前置能力，见 §10 P0）。
5. **推荐落点**：新插件 `tree.production.line`（`runtime: headless`，`requires` 依赖
   `tree.agent` + `tree.docnorm` + `local_executor`），UI 落在 `plugins/tree.ui.default`；
   **不加核心点位、不改核心面 35 条**。
6. **不做的**：不让核心认识「产线」（核心只认 `ui` / `headless`）；不把产线语义塞进
   `tree.agent` 的 conversation；不做「模型自动替你拍板」——拍板永远留痕在文档里。

---

## 2. 定位与边界

| 维度 | Agent（现有） | Production Line（本条线） |
| --- | --- | --- |
| 交互形态 | 自由对话，随时插话 | 固定站位；用户只答「待拍板」与看结论 |
| 用户投入 | 全程可参与 | 每天 20 分钟分发 + 拍板 |
| 主数据 | `agents/<id>.yaml` + 会话消息 | 产线配置 + 任务 + 文档产物 |
| 状态机 | `idle/working`（会话级） | 任务级 `draft → … → done/blocked`（§6.3） |
| 模型使用 | 一个 agent 一个主模型（成员可覆盖） | 四个角色槽位，可各绑模型与工具 |
| 失败恢复 | 会话继续 / 重试 | 任务级回退（重打包 / 重执行 / 阻塞等拍板） |
| 产物 | 聊天记录 + 工具卡 | 项目资产文档 + 运行台账 + 代码 diff |

**与 Agent 的关系**：同级、可互相引用（产线绑定一个工作空间），但**一期不互相派活**——
产线不调用既有 Agent 的 conversation，Agent 也不能直接驱动产线（见 §13 D6）。

---

## 3. 术语

| 名词 | 定义 | 落点 |
| --- | --- | --- |
| 产线实例 | 一条可复用的标准开发流，绑定工作空间与角色配置 | `<data_root>/production_lines/<line_id>/line.yaml` |
| 任务 | 产线的最小可验收单元，带依赖、写域、验收判据 | 同上 `tasks/<task_id>/task.yaml` |
| 准备阶段 | 侦查 → 语义对齐 → 定范围 → 拆任务 → 落档 | 项目资产 `docs/production_lines/<line>/` |
| 打包模型 | 只读/只搜/只跑命令，把任务所需片段一次性打齐 | 角色 `packer` |
| 执行模型 | 拿打包结果改文件并跑门控 | 角色 `executor` |
| 专家 | 针对一个具体问题临时召来的员工，回答窄而深 | 角色 `expert`，工具 `ask_expert` |
| 临时员工 | 会话内一次性员工，默认不落 `agents/`、不进团队名册 | 现有 `subagent`（§3.1） |
| 项目资产 | 人读、可提交、可评审的文档 | 工作空间内文档目录（默认 `docs/production_lines/`） |
| 插件数据 | 机器读、运行态、不提交 | 数据根 `production_lines/<id>/` |

---

## 4. 语义定稿（用户 Q&A 的落地口径）

| # | 用户结论 | 落地规则 |
| --- | --- | --- |
| Q1 | 产线与 Agent 同级；内部模型调用 = 临时员工 | 产线是独立实体与独立插件；打包/执行/专家都是**员工实例**，不是新 Agent |
| Q2 | 专家 = 针对一个问题研究的临时员工 | 专家是角色化的临时员工：输入「一个具体问题 + 必要上下文」，输出「结论 + 依据 + 未决」 |
| Q3 | 临时员工默认不能召临时员工；用户给它选了该工具才允许 | 员工工具白名单默认**不含** `subagent`；勾选后才允许，且仍受层级上限约束 |
| Q4 | 工具选择放在模型配置页（左导航 + 右内容） | 新增「模型配置页」组件，复用设置页左右布局；按单个 Agent/产线生效 |
| Q5 | 模型配置页与设置页**不合并** | 设置页管全局（模型池、凭据、主题…）；模型配置页管单个实体（角色、参数覆盖、工具） |
| Q6 | Agent 侧也加工具选择 | 同一套页面与后端字段，Agent 与产线共用；保持「统一」 |
| Q7 | 前置条件：文档规范化完成后才能开启；目前只能规划/落档/对齐 | 本期只落档；执行阶段切片排在 P0 文档规范化之后（§10） |
| Q8 | 目的：用户每天 20 分钟分发任务，只决策不看过程 | 20 分钟是**用户活跃窗口**：所有问题必须在该窗口内提出，单题不设时限；未答可次日窗口续答，**未答不实施**（§8.1）；执行阶段默认不打断用户，只上报结论与阻塞 |

**由 Q&A 推导出的四条不变量**：

1. **未答不实施**：每个 `Q` 都必须由用户回答；未答的任务停在 `awaiting_user`，跨日窗口续答，
   **禁止按默认值推进**（不写 `assumed`、不进打包/执行）。
2. **工具即权限**：没被勾选的工具**不出现在工具表里**（不是运行时再拒），并保留一层运行时兜底。
3. **专家不落盘**：专家只能产出回答，不能写工作空间；除非用户显式给它 `write/edit`（默认不给）。
4. **同级不越级**：产线不能改 Agent 的会话，Agent 不能改产线的队列；两者只能读写各自数据根。

---

## 5. 现状对照：能复用什么、缺什么

### 5.1 可复用（不改）

| 能力 | 现位置 | 产线怎么用 |
| --- | --- | --- |
| Agent 配置与模型池 | `plugins/tree.agent/lib/src/store/records.dart:122-149`、`lib/src/settings/domain_settings.dart:18-107` | 员工沿用同一份 `config/models/*.yaml` 与参数覆盖口径 |
| 按实体模型参数覆盖 | `agents/<id>.yaml` 的 `reasoning_effort` / `max_seqlen_override` / `max_output_tokens` / `compress_threshold` / `thinking_override` | 产线 `line.yaml` 用同样的键名，避免第二套语义 |
| 临时员工 | `lib/src/tool/subagent_tool.dart`、`lib/src/agent/subagent_service.dart`、`lib/src/store/subagent_store.dart` | 员工的身份、名册、会话内隔离、层级上限 |
| 消息信封与队列 | `lib/src/message/message_envelope.dart`、`lib/src/message/inbox_ledger.dart` | 员工间 `message`、任务内打回、崩溃重放 |
| 工具表与执行站 | `lib/src/tool/station_tool_runner.dart:43-152` | 工具白名单在此处过滤；工具名沿用 `read/write/list/grep/terminal/edit` 等 |
| 左活动栏 / 右栏窗口 | `plugins/tree.ui.default/lib/ui/pages/main_page.dart:1367-1395`、`lib/ui/widgets/right_panel_host.dart:54-113` | 产线作为第 4 个活动栏项；窗口宿主直接复用 |
| 设置页左右布局 | `lib/ui/pages/settings_page.dart:589-682` | 模型配置页复用同一套左目录 + 响应式断点 |
| 文档制度 | `docs/project-status.md`、`docs/work-log.md`、`packages/tree_protocol/test/docs_contract_test.dart` | 项目资产的格式与门禁（索引、断链、模板） |

### 5.2 缺口（本期要设计的部分）

| 缺口 | 影响 | 归属切片 |
| --- | --- | --- |
| 没有「产线 / 任务」实体与队列 | 无法分发、恢复、跟踪 | P1 |
| 没有按实体的**工具白名单**（Agent 也没有） | 无法把打包/执行模型限制在只读/可写 | P2 |
| 没有文档规范化与项目整理 | 产物无处可落、索引会红 | P0 / P6 |
| 临时员工不能配工具、不能 `message`、不暴露站点命令 | 打包与执行无法互问 | P4 |
| 没有角色化的模型绑定（本地 LFM3 默认） | 无法按成本路由 | P7 |
| 没有「专家」工具 | 窄问题无法深挖 | P5 |

---

## 6. 产品形态

### 6.1 左活动栏（与 Agent 同级）

现有内置项：`0=Agent 列表`、`1=插件管理`、`2=下载列表`
（`main_page.dart:82-83`、`:1367-1395`）。新增：

- `3=生产线`：列出产线实例（名称 / 当前任务 / 阻塞数 / 今日消耗），底部「+ 新建产线」；
- 选中产线后**中栏切到任务队列**，右栏窗口集合切到产线口径；
- 不混进 Agent 列表：Agent 列表只列 `agents/`，产线列表只列 `production_lines/`。

### 6.2 中栏：任务队列（默认页）

| 区域 | 内容 |
| --- | --- |
| 顶部 | 产线名 / 阶段（准备/执行/空闲）/ 今日预算用量 / 「暂停产线」 |
| 队列 | 按 `priority → created_at`；每行：`T3 标题`、状态 chip、依赖、写域、阻塞原因 |
| 决策收件箱 | 待拍板问题卡片（每轮新问题上限读设置 `questions.max_per_round`，默认 3；带默认选项与「全部按推荐」）；未答问题跨窗口保留、不占下一轮新额度，不做默认推进 |
| 任务详情 | 点击展开：意图 / 常规与特殊要求 / 范围 / 验收 / 产物链接 / 运行记录 |

**产线没有聊天流**：用户与产线的全部交互就是「任务 + 决策卡片 + 结论」，避免回到 Agent 的对话形态。

### 6.3 右栏窗口（复用窗口宿主）

| 窗口 | 内容 | 默认 |
| --- | --- | --- |
| 模型配置 | 角色槽位、模型、参数覆盖、工具白名单、专家/员工策略 | 首次进入打开 |
| 产物 | 项目资产树（recon/scope/plan/pack/acceptance/decisions） | 否 |
| 运行记录 | 每次打包/执行/专家调用的耗时、token、门控结果、失败原因 | 否 |
| 设置（全局） | 现有设置页不变 | 否 |

### 6.4 模型配置页（左导航 + 右内容）

**入口**：Agent 左栏右键「模型配置」、产线右栏「模型配置」；两块共用同一个组件。

左侧目录（7 项）：

| 目录项 | 右侧内容 | 作用域 |
| --- | --- | --- |
| 主模型 | 从全局模型池选一个；显示 max_seqlen / 是否支持工具调用 / 是否支持思考 | Agent / 产线主控 |
| 参数覆盖 | 思考强度、上下文上限、输出上限、压缩阈值、是否回传思考 | 同上 |
| 工具 | 分组勾选（见下表） | Agent / 角色 |
| 专家 | 是否允许 `ask_expert`、默认模型、默认工具、单任务次数上限 | 产线 |
| 临时员工 | 是否允许 `subagent` 再召、层级上限、继承策略 | Agent / 产线 |
| 并发与预算 | 并行任务数、单任务 token/时长上限、失败重试次数 | 产线 |
| 高级 | 禁区（`deny_globs`）、是否允许联网、是否允许 git 写操作 | 产线 |

**工具分组**（勾选后进入该角色的工具表；未勾选**不出现**）：

| 组 | 工具 | 打包模型默认 | 执行模型默认 | 专家默认 |
| --- | --- | --- | --- | --- |
| 读 | `read` / `list` / `grep` | ✅ | ✅ | ✅（只读问题） |
| 写 | `write` / `edit` | ❌ | ✅ | ❌ |
| 命令 | `terminal` | ✅（只读命令） | ✅ | ❌ |
| 协作 | `message` / `subagent` | ✅ `message` / ❌ `subagent` | ✅ `message` / ❌ `subagent` | ❌ / ❌ |
| 问答 | `ask_user_question` / `set_todo_list` | ❌ | ❌ | ❌ |
| 规范 | `spec` | ❌ | ✅ | ❌ |
| 插件 / MCP | 由站点申报的动态工具 | ❌ | 可选 | 可选 |

**校验**（保存时即报，不等到跑任务）：

- 打包模型缺 `read` + `grep` ⇒ 警告「无法打包片段」；
- 执行模型既无 `write` 也无 `edit` ⇒ 拒绝保存（无法落地）；
- 专家勾了 `write/edit/terminal` ⇒ 二次确认（高风险）；
- 勾 `subagent` 但层级上限为 0 ⇒ 拒绝。

**模型池按用途分类**（与 docnorm D33 同口径）：模型条目带 `kind: chat | embedding | decision`。
主模型 / 打包 / 执行 / 专家只能选 `chat`；`embedding` 仅供 docnorm 检索；`decision`（JEV）只能绑给
产线主控做流程决策（继续 / 重试 / 询问 / 停止），**不得绑给打包 / 执行**。选择器按角色过滤 `kind`；
缺少可用的 decision 模型时主控回退 chat，并记录 `decision_mode: chat`。

### 6.5 设置页 vs 模型配置页（Q5 定稿）

| | 设置页（全局） | 模型配置页（单个实体） |
| --- | --- | --- |
| 内容 | 模型池 CRUD / base_url / api_key / 主题 / 字体 / 插件源 / 托盘 | 选哪个模型、参数覆盖、工具白名单、专家与员工策略 |
| 写入 | `config/models/*.yaml`、`config/settings.yaml` | `agents/<id>.yaml`、`production_lines/<id>/line.yaml` |
| 变更生效 | 立即（全局） | 下一个任务生效；进行中的任务不换模型（避免半途换档） |

---

## 7. 数据模型与落档

### 7.1 目录布局（单写者：产线插件）

```text
<workspace>/docs/production_lines/<line_slug>/      # 项目资产（人读、可提交）
  recon.md            # 侦查：常规/特殊/疑惑/回退/注意
  scope.md            # 范围：in / out / 不做
  plan.md             # 任务拆分 + DAG + 写域
  decisions.md        # 拍板记录（按窗口分组；未答问题保留为 open）
  tasks/<task_id>/acceptance.md
  tasks/<task_id>/pack.md

<data_root>/production_lines/<line_id>/           # 插件数据（机读、不提交）
  line.yaml
  tasks/<task_id>/task.yaml
  tasks/<task_id>/pack.json                       # 片段 + 行号 + 基线命令（大块）
  runs/<run_id>.json                              # 打包/执行/专家调用台账
  inbox.jsonl                                     # 决策请求/回复台账（可重放）
  state.json                                      # 队列索引快照（可由 task.yaml 重建）
```

规则：

- **项目资产与插件数据严格分家**：片段、token、耗时、重试只进插件数据；人只读项目资产。
- `state.json` 只是索引，**唯一真值是每个 `task.yaml`**；启动时以 `task.yaml` 重建索引。
- 所有写入走原子写（临时名 + 改名），与 `store/atomic_file.dart` 同口径。
- 路径分段沿用 `safeSegment`（只允许 `[A-Za-z0-9_.-]`，见 `lib/src/paths.dart:73-89`）。
- `docs/production_lines/` 是**正式文档目录**：P0 的文档规范化（DN-3/DN-6）必须为它维护
  `docs/README.md` 索引，否则本仓的断链/索引门禁会红；索引由工具维护，产出方不手写。

### 7.2 `line.yaml`

```yaml
id: pl_...
name: 标准开发流
workspace_dir: E:/work/project
status: idle            # idle | working | paused
roles:
  orchestrator: { model_id: lfm3, tools: [read, grep, message] }
  packer:       { model_id: lfm3, tools: [read, list, grep, terminal, message] }
  executor:     { model_id: lfm3, tools: [read, write, edit, terminal, message, spec] }
  expert:       { model_id: lfm3, tools: [read, grep], max_per_task: 3 }
limits:
  max_parallel_tasks: 1
  max_tokens_per_task: 0      # 0 = 不设
  max_minutes_per_task: 0
  retries: 2
  max_questions_per_round: 3  # 设置项 questions.max_per_round 优先
policy:
  allow_spawn: false          # 临时员工再召（Q3）
  allow_git_write: false
  deny_globs: [".env", "**/*_key*", "**/id_rsa*"]
docs:
  asset_dir: docs/production_lines
  memory_manifest:            # 「项目记忆」= 这几份文档，按序读
    - docs/project-status.md
    - docs/work-log.md
    - docs/known-issues.md
    - docs/handover.md
```

### 7.3 `task.yaml` 与状态机

```yaml
id: T2
title: 会话列表支持按项目过滤
kind: conventional       # conventional（常规）| special（特殊）
status: queued
priority: 50
depends_on: [T1]
write_scope: [lib/ui/widgets/agent_list.dart]
read_scope: [lib/ui/widgets/, lib/io/]
acceptance:
  - dart analyze 无新增
  - agent_list 相关用例全绿
artifacts:
  recon: docs/production_lines/<line>/recon.md#T2
  acceptance: docs/production_lines/<line>/tasks/T2/acceptance.md
created_at: 2026-11-08T10:00:00+08:00
```

```text
draft ──侦查──▶ recon ──提问──▶ aligning ──拍板──▶ scoped ──▶ queued
                                   │  ▲                            │
                        窗口结束/未答 │  │ 次日窗口继续回答            ▼
                                   ▼  │                         packing
                              awaiting_user                        │
                                                                   ▼
                                              packed ──▶ running ──▶ gating ──▶ done
                                                 ▲                    │
                                                 └── 打回/重打包 ◀── 门控失败（≤retries）
                                                                      │
                                                         blocked（依赖/技术/超限）
```

规则：

- `done` 只能由门控通过触发；**不许 LLM 自报完成**；
- `awaiting_user` = 有未答的 `Q`：**跨日窗口续答**，期间不得进入 `packing`，更不得改代码；
- `blocked` 必须带 `blocked_reason`（依赖未完成 / 打包疑问 / 门控失败超限 / 预算超限）；
  等用户回答不再是 `blocked`，一律走 `awaiting_user`；
- `cancelled` 保留在队列里（可追溯），不从列表消失。

### 7.4 `runs/<run_id>.json`

```jsonc
{
  "run_id": "run_...", "task_id": "T2", "role": "packer|executor|expert",
  "model_id": "lfm3", "status": "ok|failed|cancelled",
  "started_at": 0, "elapsed_ms": 0,
  "tokens": {"prompt": 0, "completion": 0},
  "tool_calls": [{"name": "read", "path": "lib/ui/...", "ok": true}],
  "gate": [{"command": "dart analyze", "exit": 0}],
  "error": "", "artifacts": ["tasks/T2/pack.json"]
}
```

### 7.5 P1 实施记录（2026-11-09）

插件 `plugins/tree.production.line`（v0.1.0，headless / team）已落地 P1 数据模型 + 队列：

- 数据根：`<data_root>/production_lines/<team_id>/<line_id>/`（多团队不撞目录；`team_id` 只认核心 `scope`）；
  布局 = `line.yaml` / `tasks/<task_id>/task.yaml` / `runs/<run_id>.json` / `inbox.jsonl` / `state.json`。
- 命令（执行站 `production`）：`production.line.create|list|get`、`production.task.create|list|get|transition`、
  `production.queue.next|rebuild|recover`、`production.run.list`；缺 `data_dir` / `team_id` 一律 fail-closed。
- 状态机按 §7.3 落表：`done` 只由 `gating` 进入；`blocked` 必须带 `blocked_reason`；`cancelled`
  可从任意非终态进入并保留在列表里。
- 队列：`priority` 降序 → `created_at` 升序 → `id` 升序；`depends_on` 未 `done`（含缺依赖）不派发，
  `production.queue.next` 同时返回 `skipped[].waiting_on`。
- 索引与恢复：`state.json` 只含 `tasks / queue / dispatchable` 快照，内容未变时 0 写；`recover` 把
  `packing / packed / running / gating` 回 `queued`，按阶段补一条 `status=interrupted` 的 run
  （packing/packed=packer，running/gating=executor），重复调用 0 写。
- 写入用“临时文件 + 改名”；`task.yaml` 保留未知键（状态迁移写回不丢字段）。
- 验证：`dart analyze` 0；单测 26/26；`--selftest` 29/0；`build_plugins --only tree.production.line`
  产物自检通过；协议仓 `docs_contract_test` + `plugin_repo_contract_test` 14/14。

P1 出口 = 数据模型、状态机、队列、索引重建与崩溃恢复可用；REST 路由与 UI 面按 §10.2/§10.4
随 P2/P3 接入。DN-10 review 无阻塞项，记录三条非阻塞观察：`query` 的 cosine 未除查询范数
（后续按最大值归一，排序不受影响）；`check --edges` 的断链 findings 可能与契约违规重复计数；
`auto` 模式下无 embedding 时降级原因少一条 `reasons`。

### 7.6 P2 实施记录（2026-11-09）

Agent 侧工具白名单（`tree.agent` 增量，未新增核心点位）：

- 持久化：`CoreAgent.toolPolicy`（YAML 键 `tool_policy`）。**加法键**：null = 未配置
  （旧文件缺键 = 全量默认，`toJson` 不落盘）；空数组 = 显式全关。`fromJson` 对非 List
  的脏值按"未配置"处理（坏值只回退到旧语义，不放大权限）。
- 策略对象：`lib/src/tool/tool_policy.dart` —— `ToolPolicy{allowed, blocked}` +
  `allows(name)`（核心名与 `plugin__<插件>__<原生名>` 的原生名都命中）；分组
  `read / write / command / collab / workflow / plugin`；`kSubagentBlockedTools =
  {subagent, team, message}`。
- 工具表：`StationToolRunner.specsFor` 先组装（内置 + spec / tool_runs + 插件贡献）
  再按策略过滤；`catalogFor` 返回**不过滤**的目录（`{name, description, group,
  enabled}`）供 UI 勾选；`run()` 入口二次兜底——目录里存在但未勾选的工具直接回可读
  错误，不触达执行站；不存在的工具仍走原"未知工具"分支。
- 身份解析：`AgentRuntime.toolPolicyFor` —— 真实 agent 读 `agents/<id>.yaml`；临时员工
  继承会话主人策略再剔除协作类工具（名册未装载时按 `sub_` 前缀兜底，只收紧不放宽）。
- REST：新增 `GET /api/agents/{agentId}/tool-policy`（返回
  `{agent_id, tool_policy, tool_catalog, tool_groups}`）；`PATCH /api/agents/{agentId}`
  接受 `tool_policy`（数组 = 清单、`[]` = 全关、`null` = 恢复默认；未知工具名 400，
  存量清单里的名字放行以免插件离线时无法原样保存）；`models-info` 同步补这三键。
  改策略后调 `LlmAgentEngine.invalidateToolSnapshots(agentId)`（工具表是请求前缀的
  一部分，不能带旧表继续跑）。
- UI（`tree.ui.default`）：「模型信息」面板新增「工具（本 Agent）」分组勾选（每
  组显示"已选/总数"）；未改动勾选**不下发** `tool_policy`（保持"未配置 = 全量默认"，
  将来新增工具对老 agent 仍默认可用）；「恢复默认（全开）」下发 `null`。
  `ApiService.updateAgent` 增 `toolPolicy` / `clearToolPolicy`。
- 验证：`tree.agent` `dart analyze` 0；单测 **471/471**；`--selftest` **192/0**；
  `build_plugins --only tree.agent` 产物自检通过；协议仓契约 **14/14**；插件仓
  `check_plugin_repo_contract` 通过；UI `flutter analyze lib` 0；`flutter test`
  **938/939**（唯一失败是 `version_info_test` 的既有版本号漂移：pubspec `1.0.6+1`
  vs `kAppVersion='1.0.5'`，与本次改动无关）。

### 7.7 P3 实施记录（2026-11-09）

`tree.production.line` 0.2.0（headless / team）落地准备阶段，仍不新增核心点位：

- 命令（同执行站 `production`）：`production.prepare.intake|recon|questions|answer|
  all_recommended|window.open|window.close|read|finalize|status`。P1 的同步门面不动，
  P3 单独一条 async 门面（要 await `docnorm.query` / `llm.call` / `settings.get`）。
- 需求模板（§8.2）：五栏 `goal/current/acceptance/forbidden/deadline` 落
  `task.yaml.intake`；目标/验收为空阻断（`intake_incomplete`），空泛词只提示并给改写
  建议（优化/重构/差不多/尽快/你懂的/好用了就行）。
- 侦查（§8.3）：`docnorm.query`（repo = `line.workspace_dir`，mode=hybrid）取文档上下文，
  `llm.call` 出四块 JSON；**缺 docnorm / 缺 llm 一律 fail-closed**（`docnorm_unavailable`
  / `llm_unavailable`），不降级为凭空侦查。四节顺序固定，编号按行序重排为 R/S/Q/F/N；
  `flags` 截到 8 个并写进 `recon.md` 的元信息块。
- 追问（§8.4）：上限 = `tree.settings` 覆盖值 > `line.limits.max_questions_per_round` >
  默认 3，统一夹到 1–10；设置键受 `tree.settings` 的 key 规则限制落成
  `questions_max_per_round`（分组 `questions`，标题「追问」），首次用到时惰性
  `settings.define`，设置服务不可用则回退 line.yaml。**未答问题不占新额度**：重跑侦查时
  已有 open 问题原样保留（原编号 / 原选项），重复正文不重复登记，超出的新问题截断并
  以 `dropped` 回给调用方。
- 台账与状态：问题/回答追加到 `line/inbox.jsonl`（可重放），窗口与读取计数落
  `line/prepare.json`；每轮重写 `decisions.md`（按窗口分组，open / ✅ 回答 / 覆盖记录）。
  `window.close` 把有未答题的 aligning 任务转 `awaiting_user`；`window.open` 转回
  `aligning`（次日续答）；`finalize` 在存在未答问题时回 `questions_open`（**未答不实施**），
  `scoped` 只由 `finalize` 触发。
- 点状读取（§8.1）：`production.prepare.read` 统一入口，文件 ≤ 8 / `grep` ≤ 2 轮，按
  `(line, task)` 计数并落 `prepare.json`；超限回 `budget_exceeded`。`grep` 只扫文本类
  扩展名、跳过 `.git/.dart_tool/build/node_modules`，最多 300 文件 / 50 条命中。
- 落档（§8.5/§8.6）：`finalize` 先写 `scope.md` / `plan.md` / `tasks/<id>/acceptance.md`
  到 `<workspace>/<docs.asset_dir>/<line_id>/`，再以 `queued` 建子任务（`prepared_by`
  指回准备任务），最后把准备任务转 `scoped` 并返回 ≤10 行的分发摘要；计划校验
  （重复 id / 缺验收 / 依赖不在本批 / 与既有任务撞 id）都在建任务前报错。
- 集成注意：`llm.call` 由 `tree.agent` 按 **agent 身份**选模型，所以准备阶段命令的
  scope 必须带 `agent_id`（UI / 主控 agent 作为发起者）；缺失时模型调用会失败并回
  `llm_failed`，任务停在原地（可重试，未写任何代码）。
- 验证：`dart analyze` 0；单测 **49/49**（新增 preparation 22 条 + 门面 7 条）；
  `--selftest` **38/0**（含完整窗口 → 落档链路）；`build_plugins --only
  tree.production.line` 产物自检通过；协议仓契约 **14/14**；插件仓零核心依赖门禁通过。

### 7.8 P4 实施记录（2026-11-10）

`tree.production.line` 0.3.0 + `tree.agent` 0.30.0 落地打包与执行，仍不新增核心点位：

- 员工通道（`tree.agent` 增量）：新增宿主命令 `agent.worker.run`
  （`{role, task, tools, model_id, reuse}`）→ `{worker_id, role, status, report,
  model_id, tools, reused}`。`lib/src/worker/worker_spec.dart` 做纯参数校验：
  角色只认 `packer / executor / expert`；`packer / expert` 拒绝 `write/edit`
  （打包只读、专家不落盘）；`executor` 必须至少含 write/edit；`team` 永远禁用，
  `subagent` 只有显式 `allow_spawn` + 白名单才放行（Q3）。
- 员工策略：`AgentRuntime.toolPolicyFor` 对 `role ∈ {packer,executor,expert}` 的
  员工**直接用显式工具表**（不再继承父级全量），只保留 `kWorkerBlockedTools =
  {subagent, team}`；普通临时员工仍是"继承父策略 + 剔除 subagent/team/message"。
  员工复用要求**同角色**（id 或显示名），跨角色给可读错误。
- 打包（§9.1）：`production.task.pack` 要求 `queued / packing` 且 `write_scope`
  非空；经 `agent.worker.run`（role=packer，默认
  `read/list/grep/terminal/message`）产出 JSON → `parsePackJson`（files 为空 /
  绝对路径 / `..` / 空内容一律 `pack_incomplete`）；片段越出 `read_scope` 或命中
  `policy.deny_globs` 拒绝；落 `tasks/<id>/pack.json`（机读）+ 项目资产
  `tasks/<id>/pack.md`（人读）+ `runs/<run_id>.json`（role=packer）；
  失败转 `blocked` 并记 `last_error`。
- 执行与门控（§9.2）：`production.task.run` 只接受 `packed`；执行前后各跑一次
  `git status --porcelain`（读不到就 fail-closed，任务仍停 `packed`），差集必须
  全部落在 `write_scope` 且不命中禁区，否则 `blocked` 并记 `violations`；
  通过后经 `local.exec.command`（本插件自己的 `local.lease.register` 租约）跑门控
  （显式 `gate` > `pack.baseline` > `dart analyze`）。门控失败按
  `limits.retries` 回 `packed`（回包 `status=retry` 带 attempts），超限 `blocked`；
  **`done` 只由门控通过触发**。
- 台账与线程（§7.4 / §9.3）：`runs/<run_id>.json` 增 `worker_id / changed_files /
  gate[{command,ok,exit_code,output}]`；任务内 `message` 落
  `runs/messages.jsonl`（`production.task.message|messages`），`kind=question` 超过
  3 条自动 `blocked`（避免无限来回）。
- 集成注意：`agent.worker.run` 与 `local.exec.command` 都要求命令 scope 带
  `agent_id`（发起者身份），缺失回 `agent_required`；员工会话按任务分栏
  （`pl_<line>_<task>`），复用同一条线程。
- 验证：`tree.agent` analyze 0（2 条既有 info）、单测 **480/480**（新增 worker
  spec / worker service / worker 策略 3 组）、`--selftest` **193/0**；
  `tree.production.line` analyze 0、单测 **65/65**（新增 execution 8 条 +
  execution_service 7 条）、`--selftest` **53/0**（含完整 打包 → 执行 → 门控 → done）；
  两插件 `build_plugins --only ...` 产物自检通过；协议仓契约 14/14；插件仓零核心依赖
  门禁通过。

### 7.9 P5 实施记录（2026-11-10）

`tree.production.line` 0.4.0 + `tree.agent` 0.31.0 落地专家工具，仍不新增核心点位：

- 工具贡献（`tree.production.line`）：`buildServer` 申报 `tools: [ask_expert]`，启动时
  订阅 `plugin.tree.agent.collect.tools`，采集请求回 `{tools:[expertToolSpec()]}`。
  工具名进模型表时由核心加前缀（`plugin__tree.production.line__ask_expert`），执行经
  `plugin.toolCall` 回到本插件。
- 工具调用落点：`tools/call` 的 scope 只有身份四元组（没有 `data_dir`），所以工具处理器
  绕回本插件自己的执行站命令 `production.task.expert`——核心在 `station/request` 的
  `meta.data_dir` 里带数据根。非产线任务会话（`session_id` 不以 `pl_` 开头）直接回可读
  错误：`ask_expert` 只对打包 / 执行的员工会话开放。
- 专家语义（`expert.dart` 纯逻辑 + `ProductionExecutionService._expert`）：
  - 默认关闭：`roles.expert.enabled` 默认 `false`（老产线缺键同样按关闭）⇒ `expert_disabled`；
    启用后 `ask_expert` 自动进入打包 / 执行的角色工具表（未启用不出现）；
  - 次数上限：按 `runs/<run_id>.json` 里 `role=expert` 计数（失败也算一次），
    `roles.expert.max_per_task` 默认 3，到点回 `expert_limit_exceeded`；
  - 只读：专家工具表默认 `read/grep`；出现 `write/edit/subagent/team/ask_expert`
    一律 `expert_tools_invalid`（不靠运行时兜底）；只有打包 / 执行能发起，`role=expert`
    回 `expert_not_allowed`（专家不能再召专家）；
  - 输入契约：`{question, context, desired_output}`；`context` > 12 000 字符回
    `expert_context_too_large`（不截断后硬塞，禁止整库）；
  - 输出固定四段：专家只回 JSON `{conclusion, evidence[], suggestion, open[]}`，
    `conclusion` 缺失 ⇒ `expert_bad_answer`；渲染为「结论 / 依据 / 建议 / 未决」文本，
    回给调用方并附「本任务已用 / 上限 / 剩余」；
  - 台账：每次调用落 `runs/<run_id>.json`（`role=expert`、`asked_by`、`question`、
    `answer`、`worker_id`、`tokens` / `tool_calls`）；失败也落（status=failed），
    因此同样计入次数。
- Agent 侧（`tree.agent`）：
  - `tool_policy.dart` 增 `kOptInTools = {ask_expert}` 与 `isOptInTool`；
    `StationToolRunner.specsFor` 在全量默认（`tool_policy` 未配置）时**不出现**
    `ask_expert`，`catalogFor` 标 `enabled=false`，`run()` 入口对未显式勾选的调用
    回可读错误（默认不能召专家）。
  - `worker_spec.dart`：`role=expert` 的工具表出现 `ask_expert` ⇒ `worker_tools_invalid`
    （专家不能再召专家）；打包 / 执行带 `ask_expert` 合法。
- 集成注意：打包 / 执行的提示词里要带上 `line_id` 与 `task_id`（工具参数），
  `ask_expert` 的上下文只放已打包片段或文件引用；专家调用不改任务状态，只在
  `runs/` 留痕。
- 验证：`tree.production.line` analyze 0、单测 **75/75**（新增 expert 纯逻辑 5 条 +
  门面 5 条）、`--selftest` **67/0**（新增收集站 / 默认关闭 / 次数上限 / 只读 /
  再召拒绝 / tools/call 两条）；`tree.agent` analyze 0（2 条既有 info）、单测
  **483/483**（新增 opt-in / 专家再召 3 条）、`--selftest` **193/0**；两插件
  `build_plugins --only ...` 产物自检通过；协议仓契约 14/14；插件仓零核心依赖门禁通过。

### 7.10 P6 实施记录（2026-11-10）

`tree.production.line` 0.5.0 落地项目整理，仍不新增核心点位：

- 命令（同执行站 `production`）：`production.audit.run`
  （`{line_id, task_id?, write?}`）。显式给了 `task_id` 就必须存在（拼错不静默）；
  缺 `data_dir` / `team_id` / `workspace_dir` 一律 fail-closed，工作空间不存在回
  `workspace_unavailable`。
- 只读边界：扫描**不改任何工作空间文件**；唯一写入是项目资产
  `<workspace>/<docs.asset_dir>/<line>/audit.md`；`write=false` 时连它都不写
  （纯查询，供 UI 预览）。单测以“审计前后工作空间文件集合”断言只新增 audit.md。
- 扫描范围（有界、确定性）：跳过 `.git/.dart_tool/build/node_modules/.docnorm` 等目录；
  只读文本扩展名；单次 ≤ 2000 个文件、单文件 ≤ 512 KiB、台账 ≤ 500 条；到点写
  `notes` 说明（不静默截断）。
- 四块内容：
  - 文档审计：按 `line.yaml.docs.memory_manifest` 逐份判断存在性（`checked` /
    `missing`）；清单为空时留说明；
  - TODO 台账：只认大写 `TODO/FIXME/XXX/HACK`（避免正文里的 “todo” 误报），
    记 `path / line / marker / text`（正文裁到 200 字符）；
  - 冗余候选：FNV-1a 64 位内容摘要做重复组（≥ 1 KiB 且 ≥ 2 个路径）+ 超大文件
    （≥ 256 KiB），均按体积降序；不引入额外依赖；
  - 说明：扫描截断等。
- 报告 schema 固定（`version: 1`）：顶层 `version / line_id / task_id /
  generated_at / workspace / files{scanned,skipped,bytes} / docs{checked,missing} /
  todos[] / redundancy{duplicates[],large_files[]} / notes[]`；单测钉死键集合，
  防实现细节漂移。
- 落档：`audit.md` 由 `renderAuditMd` 渲染（文档审计 / TODO 台账 / 冗余候选 /
  说明四节），机读真值是回包里的 `report`；不写入插件数据根。
- 验证：analyze 0、单测 **84/84**（新增审计纯逻辑 4 条 + 门面 5 条）、
  `--selftest` **77/0**（新增 schema / TODO / 文档审计 / 重复组 / 超大文件 /
  write=false / 只读断言 10 条）；`build_plugins --only tree.production.line`
  产物自检通过；协议仓契约 14/14；插件仓零核心依赖门禁通过。

### 7.11 P8 实施记录（2026-11-10）

**口径修订（用户定稿）**：不做「模型硬绑定」——`line.yaml.roles.*.model_id` 里的
`lfm3` 只是新建产线的模板默认值，用户随时在模型池自选/替换；P7 的「角色固定绑定 +
降级阶梯」不再实施。P8 只做并行调度、预算软停与模型元数据发现。

`tree.production.line` 0.6.0：

- 命令（执行站 `production`）：`production.queue.dispatch`（`{line_id, limit?}`）与
  `production.task.budget`（`{line_id, task_id}`）。
- DAG 派发（只读计划，不改状态）：按 `priority → created_at → id` 扫描 `queued`，
  逐个判「`depends_on` 全部 `done`」→「`write_scope` 非空」→「写域与在途任务 /
  已入选批次两两不相交」→「并行槽位（`limits.max_parallel_tasks`，在途 =
  `packing/packed/running/gating`）未满」；返回 `batch / batch_ids / running /
  skipped[{id,reason}] / slots_used / slots_free / count`。
  `reason` 取值：`depends_on`（带 `waiting_on`）、`write_scope_missing`、
  `write_scope_overlap`（带 `with_task` / `scope`）、`max_parallel`、`limit`
  （调用方传的 `limit` 截断，带 `limit`）。`slots_free` 是**派发前**读数
  （不扣除本批，本批尚未迁移到 `packing`）；`count = batch.length`。
  真正的状态迁移仍由 `production.task.pack` 做，UI 按 `batch` 并发发起即可。
- 写域交叠判据（`writeScopesOverlap`）：字面路径按目录语义（`lib/a` 与
  `lib/a/b.dart` 交叠、`lib/a` 与 `lib/ab` 不交叠）；含 `*` / `?` 的规则用
  `matchesWriteScope` 互测；两边都是通配时比较第一个通配符前的字面前缀。
  **宁可少并行也不让两个写者碰同一文件**。
- 预算：`limits.max_tokens_per_task` 统计输入 + 输出 token 总量；
  `max_minutes_per_task` 统计该任务所有员工调用的墙钟时长（门控不计）；0 = 不设。
  每次员工调用（成功/失败都算）把 `tokens.prompt/completion` 与 `elapsed_ms`
  累加进 `task.yaml.usage`；`production.task.budget` 报告上限、用量、剩余与原因。
- 软停（硬语义）：调用**前**已到点 ⇒ 不发起员工、直接软停；调用**后**到点 ⇒
  当前产出照常保留（`pack.json` / `pack.md` / 已改文件 + `changed_files`），
  但不进 `packed` / 不跑门控 / 不进 `done`；两种情况都写一条
  `status=budget_exceeded` 的 run（有产出时原 run 标 `budget_exceeded: true`）、
  任务标 `budget_exceeded: true` 并转 `blocked`（原因含 token / 时长读数）。
  `blocked` 后再次打包会先被状态机拒绝 ⇒「不静默继续」。
  `production.task.budget` 的 `budget_exceeded` 是**软停标记**（历史），`exceeded`
  是按**当前** `limits` 与累计 `usage` 的实时判定；用户加预算后把任务迁回 `queued`
  会清掉 `budget_exceeded` / `budget` 快照（run 台账仍保留历史），再从队列重新打包。

`tree.agent` 0.32.0（模型元数据发现，OpenAI 兼容端点）：

- 新增路由 `GET/POST /api/models/{modelId}/meta`：GET 读缓存；POST 用模型自己的
  `base_url` + `api_key` 请求 `{base_url}/models`（自动去掉已带的
  `/chat/completions` 后缀），挑出目标模型条目并解析。
- 缓存 `<data_root>/config/model_meta.json`（模型池 YAML 仍是用户配置的唯一真值，
  探测结果只读、可随时重刷）；`PATCH` 改端点/密钥与 `DELETE` 删模型时清掉缓存。
- 解析口径：价格支持 `pricing.{prompt,completion}`（每 token，OpenRouter 口径）与
  `*_per_million`，统一折算成「每 1M token、USD」；思考档位取
  `reasoning_effort_options / reasoning_efforts / supported_reasoning_efforts /
  reasoning.supported_efforts` 等声明并去重；上下文取 `context_length /
  max_context_length / top_provider.context_length`；端点只回 id 时按「未声明」处理
  （不报错，UI 回退 `low/high/max`）。探测失败保留上次成功的价格/档位，只追加
  `error` 与时间。
- `GET /api/models` 与 `models-info` 的每条模型在**缓存存在时**附带只读 `meta`
  （未探测的模型不出现该键，旧契约不变）。
- UI（`tree.ui.default`）：模型编辑弹窗去掉「可选档位（逗号分隔）」手填，改为
  显示端点声明档位 + 「从端点探测」按钮 + 价格行；模型池列表行展示
  `$x / 1M 输入 · $y / 1M 输出`；保存时把当前候选档位写回
  `reasoning_effort_options`（后端仍按它校验成员覆盖）。
- 验证：产线 analyze 0 / 单测 **100/100** / 自检 **87/0**（含发版前审查补的
  派发 `limit` / 缺写域 / 调用前超限 / 执行后软停 / 重新入队清标记用例）；
  tree.agent analyze 0 / 单测 **497/497** / 自检 **208/0**（新增
  元数据测试 6 条）；UI `model_pool_test` 15/15（全量套件仅存量的
  `version_info_test` 因 pubspec `1.0.6+1` 与 `kAppVersion 1.0.5` 历史漂移而红，
  与本片无关）；两个插件 `build_plugins` 产物自检通过；协议仓契约 14/14；
  插件仓零核心依赖门禁通过。

---

## 8. 准备阶段（用户活跃窗口）

### 8.1 20 分钟窗口语义（硬约束）

- 20 分钟 = **用户活跃窗口**，不是单题时限，也不是整段准备阶段的硬截断；
- 所有问题必须在窗口内**提出**，但**单题不设时间上限**，用户可以慢慢答；
- 窗口到点仍有未答问题 ⇒ 任务转 `awaiting_user`，保留草稿与未答问题，
  **次日窗口原样继续**；
- **未答不实施**：不得按默认值冻结、不得进入打包/执行、不得改代码。

窗口内建议节奏（可压缩，不是硬门禁）：

| 阶段 | 建议 | 窗口到点行为 |
| --- | --- | --- |
| 侦查 | 5 min | 暂停并保留 `recon.md` 草稿；未读完的背景标 `unknown` |
| 追问/对齐 | 8 min | 转 `awaiting_user`，未答问题逐条保留 |
| 定范围 + 拆任务 | 5 min | 已完成就落档；未完成则暂停 |
| 落档与确认 | 2 min | 写 `decisions.md` + 队列，结束本窗口 |

**速度纪律**：对齐阶段**默认只读文档、不读代码**；只有 L0 标了 `flags` 的条目允许点状读取，
**每会话 ≤ 8 个文件**（计入读取上限），`grep` ≤ 2 轮；不做构建、不跑全量测试。
与 [doc-normalization-recon.md](../doc-normalization-recon.md) D32 同口径。

### 8.2 约束用户输入：需求模板

新建任务时只要求五栏（每栏一句话即可，可空）：

| 栏 | 写法示例 | 不接受的写法 |
| --- | --- | --- |
| 目标 | 「会话列表能按项目过滤」 | 「优化一下列表」 |
| 现状 | 「左栏只有 flat 列表」 | 「你懂的」 |
| 验收 | 「选中项目后只剩该项目会话；有测试」 | 「好用了就行」 |
| 禁区 | 「不动数据库结构」 | （留空也可以） |
| 期限 | 「今天 20 分钟内分发」 | 「尽快」 |

页面内嵌「好/坏例子」对照（教用户如何澄清），并对空泛词（优化/重构/差不多/尽快）
给一次**可点选的改写建议**。

### 8.3 侦查输出（四块，分开列）

`recon.md` 固定四节，顺序不可换：

1. **常规要求**：能用成熟技术栈/既有实现直接解决的（逐条编号 `R1…`，每条给落点文件）；
2. **特殊要求**：传统方案做不到或代价异常的（逐条 `S1…`，必须写清「为什么常规做不到」）；
3. **疑惑与待拍板**：`Q1…`（最多 N 条，N 读设置 `questions.max_per_round`，默认 3；每条含默认选项、推荐、不选后果）；
4. **回退选项与注意事项**：`F1…`（特殊要求失败时走哪条常规路）+ `N1…`（风险/兼容/数据）。

**语义对齐靠文档**：每一轮只改这四节，不在聊天里飘；用户拍板后**冻结**该节
（写入 `decisions.md`，之后只允许追加「变更原因」）。

### 8.4 追问协议（硬规则）

1. 一次最多 **N 个新问题**（N = 设置项 `questions.max_per_round`，默认 3，范围 1–10；上一轮未答问题保留展示、不占新额度）；每题 ≤ 60 字，总长 ≤ 400 字。
2. 每题必须给：编号、默认选项、推荐项、不选后果（一句话）。
3. 只问「影响范围 / 不可逆 / 成本数量级」，**不问实现细节**（实现由产线自己定）。
4. 提供「全部按推荐」一键拍板——**必须用户点击**才生效，系统不自动应用；拍板后不再重复问同类问题。
5. **单题不设时限**；窗口到点未答 ⇒ 保留为 `open`，任务转 `awaiting_user`，次日窗口继续。
6. 未答问题**绝不按默认实施**；下一窗口重提时保留原编号与原选项，只允许追加新信息。
7. 用户回答与原需求冲突时，**以最新回答为准**，并在 `decisions.md` 记录覆盖关系。
8. 不允许用问题清单替代方案：先给「我的理解」再给问题。

> **设置项（用户可配）**：`tree.production.line` 启动时向 `tree.settings` 注册
> `{"key":"questions.max_per_round","group":"questions","type":"int",
> "title":"每轮最多追问数","default":3,"min":1,"max":10}`
> （group `questions` 标题「追问」）；设置页「插件 → 生产线」渲染。每轮开始读取，
> **下一轮生效**（已提出的问题不改）。合并顺序：`tree.settings` 覆盖值 >
> `line.yaml.limits.max_questions_per_round` > 默认 3；`tree.settings` 缺失时按后两者
> 运行，不阻断产线启动。

### 8.5 定范围与拆任务

- `scope.md`：in / out / 明确不做（out 也要写，防止后面越做越大）；
- `plan.md`：任务 DAG，每个任务必须有：标题、`kind`、`depends_on`、`read_scope`、
  `write_scope`、验收判据、预计改动文件数；
- **`write_scope` 是并行与权限的判据**：写域交叠的任务不允许并行（§9.6）。

### 8.6 落档顺序与完成判据

1. 写 `recon.md` → 用户补齐/拍板 → 冻结；
2. 写 `scope.md` + `plan.md`；
3. 写每个任务的 `task.yaml`（状态 `queued`）与 `acceptance.md`；
4. 重建 `state.json` 索引；
5. 产出「本窗口分发摘要」（≤ 10 行）：任务数、常规/特殊占比、未答问题数、预计门控命令。

**准备阶段完成的判据**：`recon.md` 四节齐全 + 每条 `Q` 都已由用户 `answered`（**没有 assumed**）
+ `plan.md` 每个任务都有验收判据 + 队列状态可重建。未满足时任务停在 `awaiting_user`。

---

## 9. 细化与执行阶段

### 9.1 打包模型（packer）

| 项 | 约定 |
| --- | --- |
| 工具 | `read` / `list` / `grep` / `terminal`（默认只读命令）+ `message`；**没有** `write/edit` |
| 输入 | `task.yaml` + `plan.md` + 项目记忆清单（§7.2）+ 允许的 `read_scope` |
| 产出 | `pack.json`：文件清单（路径 + 行区间 + 原片段）、测试基线命令、依赖关系、风险点 |
| 硬规则 | 片段一次性打齐；**任何疑问先 `message` 打回**（任务转 `blocked`，不得猜） |
| 禁止 | 不改文件；不跑构建/测试（只允许读命令，如 `git status`、`wc -l`） |

**打包完整性判据**：执行模型不需要再 `read` 也能改对；若执行模型不得不求助 ⇒ 视为打包失败，
任务回到 `packing` 重打（计入重试）。

### 9.2 执行模型（executor）

| 项 | 约定 |
| --- | --- |
| 工具 | `read` / `write` / `edit` / `terminal` + `message` + `spec`（默认） |
| 输入 | `pack.json`（完整片段）+ `acceptance.md` |
| 产出 | 文件改动 + `runs/<run_id>.json`（含门控命令与输出） |
| 门控 | `dart analyze` → 受影响包 `dart test` → `tree_protocol` 访问控制 → 涉及 UI 才跑 `flutter` |
| 失败 | 重试 ≤ `limits.retries`（默认 2）→ 仍失败转 `blocked`，附「最后一次失败输出摘要」 |
| 禁止 | 越出 `write_scope` 写文件；改 `acceptance.md` 让门控通过；删测试 |

### 9.3 两个模型的交互

```text
packer ──pack.json──▶ executor
   ▲                     │
   └──message（问题/缺片段）┘
```

- 两个角色都工具里有 `message`，**只能一对一**（同一任务内的线程），不建群；
- 线程落 `runs/messages.jsonl`；用户可在「运行记录」里看，但不被打断；
- 打回超过 3 次 ⇒ 自动 `blocked` 并升级给用户（避免无限来回烧 token）。

### 9.4 专家工具（`ask_expert`）

- 触发：打包/执行模型遇到「一个具体、可独立研究」的问题（API 用法、协议细节、库行为、方案对比）；
- 输入：`{question, context, desired_output}`；`context` 只能是已打包片段或文件引用，不能是整库；
- 专家 = 临时员工（角色 `expert`），默认工具 `read/grep`（纯推理问题可全关）；
- 输出固定四段：**结论 / 依据（文件:行） / 建议 / 未决**；
- 默认**不能召专家**也不能召临时员工（Q3）；用户勾选后才允许；
- 限制：单任务 ≤ `roles.expert.max_per_task`（默认 3）、必须落 `runs/` 台账。

### 9.5 临时员工（Worker）语义

沿用现有 `subagent` 的三条不变量（会话内、不进名册、不可被 `message` 寻址），新增：

- **工具白名单**：员工工具 = 角色配置的白名单（不再是「继承父的全部」），默认剔除
  `subagent` / `team` / `write`（专家）；
- **再召**：只有白名单含 `subagent` 才允许，且层级沿用 `SubagentLimits.maxDepth`；
- **归属**：员工记录仍挂在产线实例下，不写 `agents/`、不进团队名册。

### 9.6 并发与预算

- 默认 `max_parallel_tasks: 1`（同一工作空间只有一个写者）；
- 只有 `write_scope` **完全不相交** + `depends_on` 已满足时才允许并行（上限可配）；
- 预算：单任务 token / 时长上限到点即**软停**（产出当前结果 + 标 `budget_exceeded`），不静默继续。

### 9.7 隔离与回退（建议默认开）

- 每个任务默认在 `pl/<line>/<task>` 分支上执行（工作空间是 git 仓时）；
- 回退 = 丢弃分支，主分支零污染；
- `allow_git_write: false` 时执行模型不得 `commit/push`，只产出 diff 摘要与建议提交信息。

---

## 10. 技术落点

### 10.1 插件形态

- 新插件 `plugins/tree.production.line/`（目录名 = id），`runtime: headless`，
  `granularity: team`，`scope: {}`；
- `requires.plugins` 声明依赖 `tree.agent`（员工执行边界）、`tree.docnorm`（准备阶段的
  `docnorm.query` / `docnorm.check`）、`tree.settings`（追问上限等用户设置，可选）与
  `local_executor`（命令）；**缺 `tree.docnorm` 时准备阶段 fail-closed**，不得降级为
  “凭空侦查”；缺 `tree.settings` 时退回 `line.yaml` + 默认值，不阻断启动；
- **不 import** `tree_core` / `tree_protocol`（插件纪律）；跨插件只走站点与委派；
- 启动经 `system.collect.api.routes` 申报自己的路由，核心只做归属转发与形状校验。

### 10.2 REST 路由（由产线插件申报，进 `/api/meta.routes`）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET/POST | `/api/production/lines` | 列表 / 新建 |
| GET/PATCH/DELETE | `/api/production/lines/{lineId}` | 详情 / 改配置 / 删除 |
| GET/POST | `/api/production/lines/{lineId}/tasks` | 队列 / 建任务 |
| GET/PATCH | `/api/production/lines/{lineId}/tasks/{taskId}` | 详情 / 改状态（有限状态） |
| POST | `/api/production/lines/{lineId}/tasks/{taskId}/dispatch` | 进入打包/执行 |
| POST | `/api/production/lines/{lineId}/tasks/{taskId}/decision` | 回答 `Q` |
| POST | `/api/production/lines/{lineId}/tasks/{taskId}/cancel` | 取消 |
| GET | `/api/production/lines/{lineId}/runs` | 运行台账 |
| GET | `/api/production/lines/{lineId}/artifacts` | 产物树（只读） |
| GET | `/api/production/lines/{lineId}/audit` | 项目整理报告 |

Agent 侧（`tree.agent` 增量，不加新路由前缀）：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/agents/{agentId}/tool-policy` | 返回「可选工具目录 + 已选」 |
| PATCH | `/api/agents/{agentId}` | 请求体新增 `tool_policy` 键（加法，不破坏旧客户端） |

### 10.3 站点面

| 站点 | 类型 | 用途 |
| --- | --- | --- |
| `plugin.tree.production.line.broadcast.task_state` | 广播（自建） | 任务状态迁移；UI 晚订阅用 REST 快照对齐 |
| `plugin.tree.production.line.execute.line` | 执行（自建） | `production.task.dispatch` / `production.task.decide`（供其他插件与 UI 委派） |
| `agent.worker.run` | 执行（`tree.agent` 增量） | 产线调员工：`{role, task, tools, model_id, reuse}`；回包含 `worker_id` 与最终报告 |

不新建 relay 站点：产线的「打包/执行」是**任务级编排**，不是 LLM 请求级改写。

### 10.4 UI 落点（tree.ui.default）

| 改动 | 位置 |
| --- | --- |
| 活动栏第 4 项 | `main_page.dart:1367-1395`（新增 `ActivityBarItem`） |
| 左栏产线列表 | 新 `ui/widgets/production_line_list.dart` |
| 中栏任务队列 | 新 `ui/widgets/production_queue_panel.dart` |
| 决策卡片 | 新 `ui/widgets/decision_card.dart`（复用问答卡片样式，不新建聊天流） |
| 模型配置页 | 新 `ui/widgets/entity_model_config_page.dart`（与设置页同构） |
| 模型配置入口 | Agent 列表右键 + 产线右栏窗口；现有「模型信息」窗口**合并进**本页面，旧入口重定向 |
| API 调用 | 走 `ApiService` + REST 委派；UI 不直连插件、不读写插件数据 |

### 10.5 Agent 侧工具选择的后端改动

1. `CoreAgent.toJson/fromJson` 增 `tool_policy`（加法键，旧文件缺省 = 全量默认）；
2. `StationToolRunner.specsFor` 在组装后按白名单过滤（**工具表里不出现**未选工具）；
3. `run()` 入口再做一次白名单兜底（防模型记住旧工具名）；
4. 临时员工继承父的白名单，再按 §9.5 剔除；
5. `models-info` 补 `tool_policy` 与「可选工具目录」（目录由内置 + 插件申报 + MCP 合成）。

---

## 11. 切片（每片一次提交 + 一次门禁）

| 切片 | 内容 | 依赖 | 证明点 / 门禁 |
| --- | --- | --- | --- |
| **P0 文档规范化**（前置，独立车道） | 资产目录规范、模板（recon/scope/plan/acceptance/decisions）、索引自动维护、断链与过期基线检查；对接 [doc-normalization-recon.md](../doc-normalization-recon.md) 的 DN-3 + DN-6，把 `docs/production_lines/` 纳入索引维护 | — | 文档契约门禁扩展；全仓断链 0；现有文档迁移演练 |
| **P1 数据模型 + 队列** | 插件骨架、`line.yaml` / `task.yaml` / `runs`、状态机、索引重建、崩溃恢复 | P0 | 单测：状态迁移合法/非法、`inflight→queued` 重放、不重复执行 |
| **P2 模型配置页 + 工具白名单** | Agent `tool_policy` 加法键、工具目录、`specsFor` 过滤、UI 共用页面 | P1 | 现有 agent 全量绿；未选工具不出现且运行被拒 |
| **P3 准备阶段** | 侦查四块、追问协议、活跃窗口、`awaiting_user` 跨日续答、决策落档；消费 `pkg_index` 与图谱 | P2 + DN-7 + DN-9 + DN-10 | 固定样例输出结构稳定；追问上限读设置（默认 3，可配 1–10）；未答不实施、次日可续答；`flags` 点状读取 ≤ 8 文件/会话 |
| **P4 打包 + 执行** | `agent.worker.run`、`pack.json`、`runs`、`message` 线程、门控与重试 | P3 | 假 LLM 端到端；写域越界被拒；门控失败不进 `done` |
| **P5 专家工具** | `ask_expert`、专家角色、次数/工具上限、台账 | P4 | 默认不能召员工；超限拒绝；专家不写文件 |
| **P6 项目整理** | 文档审计、TODO 台账、死代码/冗余候选、只读报告 | P0/P3 | 报告 schema 稳定；不写产物目录之外 |
| **P7 本地模型 LFM3**（已取消） | ~~角色默认绑定、工具调用能力探测、降级阶梯~~；用户口径：**不做模型硬绑定**，模型由用户在模型池自选，`lfm3` 只是新建产线的模板默认值 | — | 不再实施 |
| **P8 并行与预算** | DAG 调度、写域并行判据、token/时长预算、软停；模型元数据（价格 / 思考档位）发现 | P4 | 写域交叠拒绝并行；预算到点不静默继续 |

**P0 出口 = DN-3 + DN-6**，完成即解锁 P1（数据模型/队列，**不依赖 `pkg_index`**）；
**DN-7（收束产物）与 DN-9/DN-10（图谱）是 P3 前置**，不阻塞 P1/P2。

> **进度（2026-11-10）**：P1 已完成（§7.5）、P2 已完成（§7.6）、P3 已完成（§7.7）、
> P4 已完成（§7.8）、P5 已完成（§7.9）、P6 已完成（§7.10）、P8 已完成（§7.11）。
> P7 按用户定稿**取消**（不做模型硬绑定：模型池由用户自选，产线只存用户选中的
> `model_id`）。规划内切片全部完成；后续按缺陷与用户反馈开增量片。

门禁顺序沿用项目规则：`dart analyze`（无新增）→ 受影响包全量 `dart test` →
`tree_protocol` 访问控制 → 涉及 UI 才跑 `flutter`。

---

## 12. 测试与验收

| 编号 | 判据 |
| --- | --- |
| TC-PL-01 | 队列在 `inflight` 时被杀，重启后回到 `queued` 且只执行一次 |
| TC-PL-02 | `task.yaml` 与 `state.json` 冲突时，以 `task.yaml` 为准并自动重建索引 |
| TC-PL-03 | 一轮新问题 > 设置上限（默认 3，可配 1–10）被截断，改设置下一轮生效；窗口到点未答 ⇒ 转 `awaiting_user`、草稿保留、次日可续答；**不按默认实施** |
| TC-PL-04 | 打包模型调用 `write/edit` 被拒（工具表里也没有） |
| TC-PL-05 | 执行模型越出 `write_scope` 写文件被拒，任务转 `blocked` |
| TC-PL-06 | 专家默认无写权限、不能召员工；勾选后才允许且受层级上限约束 |
| TC-PL-07 | Agent 未勾选的工具不出现在 `specsFor`，强行调用返回可读错误 |
| TC-PL-08 | `write_scope` 交叠的两个任务不允许并行；不交叠时可并行 |
| TC-PL-09 | 门控失败重试到上限后转 `blocked`，不得标记 `done` |
| TC-PL-10 | 模型不支持工具调用时给出明确提示与降级路径（不空转） |
| TC-PL-11 | 项目资产与插件数据分家：产物目录只出现文档，片段只在插件数据 |
| TC-PL-12 | 状态广播与 REST 快照一致（晚订阅者拿到权威状态） |
| TC-PL-13 | 缺 `tree.docnorm` 时准备阶段 fail-closed，给出可读缺失依赖，不进入 `packing` |
| TC-PL-14 | 读取代码只允许 `flags` 条目，且每会话累计 ≤ 8 个文件；超限被拒并记入 run 台账 |

---

## 13. 风险、回退与「不做」清单

| 风险 | 表现 | 对策 |
| --- | --- | --- |
| 双写冲突 | 文档说 A、`task.yaml` 说 B | 唯一真值 `task.yaml`；文档只放内容；单写者 = 插件 |
| 打包片段过大 | 执行模型上下文爆掉 | 按任务切分 + 行区间 + 片段上限；超出转多任务 |
| 模型幻觉改错文件 | 越界写、改验收 | 写域校验 + 验收文件只读 + git 分支回退 |
| 本地模型能力不足 | 不会用工具 / 输出格式漂 | 能力探测 + 角色降级阶梯 + 结构化输出校验 |
| 20 分钟窗口不够用 | 侦查/追问没做完 | 窗口只暂停不放弃：读取预算 + `awaiting_user` 跨日续答 + 未答不实施 |
| 执行不可逆 | 直接改主分支 | 默认任务分支；`allow_git_write: false` |
| 员工无限套娃 | token 爆炸 | 默认禁止再召；层级上限；单任务次数上限 |

**回退选项（准备阶段必须写进 `recon.md`）**：每条特殊要求都要给一个「做不到时走哪条常规路」，
否则该任务不允许进入执行阶段。

**明确不做**：

- 不做「产线自动改需求文档」——需求以用户原话与拍板记录为准；
- 不做「无人值守连跑一整天」——一期只到「任务队列 + 单任务执行」；
- 不做「产线互调 Agent 会话」——一期只共享模型池与工作空间；
- 不新增核心内置点位、不改核心面 35 条基线。

---

## 14. 拍板记录（2026-11-08 定稿；2026-11-09 追加 D11）

> 用户 2026-11-08 追加拍板：**20 分钟 = 用户活跃窗口**（单题不设时限、未答次日续答、未答不实施，
> 见 §8.1）；项目资产目录定为 **`docs/production_lines/`**；「模型信息」窗口**并入**「模型配置」；
> 其余待拍板项**按推荐默认执行**。
> 2026-11-09 追加：**每轮追问上限改由用户设置决定**（D11），不再硬编码 3。

| # | 结论 | 影响 |
| --- | --- | --- |
| D1 | **独立插件** `tree.production.line`，`requires [tree.agent, tree.docnorm, tree.settings(可选), local_executor]`；缺 `tree.docnorm` 时准备阶段 fail-closed，缺 `tree.settings` 时退回 `line.yaml` | 边界清晰；多两到三个插件依赖要发布/装 |
| D2 | **复用** `tree.agent` 的临时员工，新增 `agent.worker.run` 执行站 | 不复制 LLM/工具循环；需扩展 `tree.agent` |
| D3 | 执行隔离默认用 **git 任务分支**，可关 | 回退干净；要求工作空间是 git 仓 |
| D4 | 项目资产目录 **`docs/production_lines/`**，由文档规范化（DN-3/DN-6）自动维护索引 | 人可见、可评审；需索引门禁配合 |
| D5 | 工具白名单走 **工具表过滤 + 运行时兜底** | 省 token、少误调；要改 `specsFor` |
| D6 | 产线**一期不调用**既有 Agent（不派活） | 避免双向依赖与队列语义纠缠 |
| D7 | 专家回答**摘要进上下文，原回答落 `runs/`** | 控上下文；可追溯 |
| D8 | 默认并行任务数 **1** | 单写者；需要时按写域放开 |
| D9 | **默认不允许**自动 `commit/push`，只给 diff 与提交信息 | 用户 20 分钟只决策，不处理事故 |
| D10 | 「模型信息」窗口**合并**进「模型配置」页，旧入口指向新页 | 避免两处改模型 |
| D11 | 每轮追问上限**由用户配置**：`questions.max_per_round`（int，默认 3，范围 1–10，team 作用域）进设置页，下一轮生效；`line.yaml` 保留兜底 | 用户可调；需接 `tree.settings` |

---

## 15. 证据索引

- Agent 配置持久化：`plugins/tree.agent/lib/src/store/records.dart:122-149`、`lib/src/agent_store.dart:165-226`
- 模型池与参数口径：`plugins/tree.agent/lib/src/settings/domain_settings.dart:18-130`
- Agent 配置视图：`plugins/tree.agent/lib/src/agent_config.dart:33-76`
- 临时员工：`plugins/tree.agent/lib/src/tool/subagent_tool.dart:96-208`、`lib/src/agent/subagent_service.dart`、`lib/src/store/subagent_store.dart:19-306`
- 工具表与执行站：`plugins/tree.agent/lib/src/tool/station_tool_runner.dart:43-152`
- 消息信封与台账：`plugins/tree.agent/lib/src/message/message_envelope.dart`、`lib/src/message/inbox_ledger.dart`
- 数据根布局：`plugins/tree.agent/lib/src/paths.dart:9-89`
- 委派路由表：`plugins/tree.agent/lib/src/delegate.dart:32-79`
- 站点与委派协议：[plugin-development.md](../plugin-development.md) §3（点位）、§6.8（发布与安装）
- 执行站契约：[exec_station_contract.md](../exec_station_contract.md)
- Agent loop 语义（direct/queue、inbox、状态机）：[agent-loop-restructure-recon.md](agent-loop-restructure-recon.md) §3
- UI 左活动栏与窗口宿主：`plugins/tree.ui.default/lib/ui/pages/main_page.dart:82-83`、`:1367-1395`；
  `lib/ui/widgets/right_panel_host.dart:54-113`
- 设置页左右布局与响应式断点：`plugins/tree.ui.default/lib/ui/pages/settings_page.dart:589-682`；
  [ui-settings-layout-and-neutral-theme-recon.md](ui-settings-layout-and-neutral-theme-recon.md) §3
- 文档契约门禁：`packages/tree_protocol/test/docs_contract_test.dart`
- P0 文档规范化的通用口径与切片：[doc-normalization-recon.md](../doc-normalization-recon.md) §7/§8
- 当前阶段与车道：[project-status.md](../project-status.md)
