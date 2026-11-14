# 生产线功能补齐侦查（PL-COMPLETE）

> **状态**：2026-11-14 侦查落档，**只改文档不改代码**；**P1 已拍板：2026-11-14 切「快速迭代」，按 PC-1~PC-8 推进**；
> P2~P8 仍待拍板（§10）。
> **输入**：用户 2026-11-14「Production line 差不多要正式给他把功能做全了，现在的他还是一个空骨架，本期侦查」。
> **对码范围**：`plugins/tree.production.line`（`0.11.1`）、`plugins/tree.ui.default`（`1.0.9+1`）、
> `plugins/tree.agent`、`plugins/tree.docnorm`、`plugins/files`。
> **上游文档**：[production-line-recon.md](production-line-recon.md)（P1~P8 语义）、
> [production-line-stability-recon.md](production-line-stability-recon.md)（STAB-PL / D1~D8）、
> [production-line-orchestrator-loop-plan.md](production-line-orchestrator-loop-plan.md)（D6-O / O1~O6）。

---

## 1. 结论先行

1. **后端不空，产品面空**。P1~P8、D6-O（O1~O5）、整理报告、逻辑去重都已落码；
   但用户从 UI 能做的只有「建线 → 手填标题+写域建任务 → 手点打包/执行 → 手点拍板」，
   **准备阶段（需求模板 → 侦查 → 追问 → 定范围 → 拆任务）在 UI 里完全不可达**。
   所以它看起来是一个空骨架，而不是缺后端。
2. **第一个硬断点：准备阶段没有 REST，也没有 UI**。`production.prepare.*` 十条命令只在
   插件执行站里（[preparation_service.dart:17-27](../../plugins/tree.production.line/lib/src/preparation_service.dart#L17-L27)），
   插件 REST 路由表里没有任何一条 `prepare` 路由
   （[api.dart:64-87](../../plugins/tree.production.line/lib/src/api.dart#L64-L87)），UI 的 API 层也没有对应方法
   （[api_service.dart:1216-1502](../../plugins/tree.ui.default/lib/io/api_service.dart#L1216-L1502)）。
   结果是「拍板」按钮只在已经有问题时才有意义，而问题本身无法从 UI 产生。
3. **第二个硬断点：执行驱动会停住**。手动派发完成后不会触发下一次主控 tick
   （[api.dart:573-650](../../plugins/tree.production.line/lib/src/api.dart#L573-L650)）；
   定时 tick 在没有在途任务时直接跳过
   （[orchestrator_service.dart:126-130](../../plugins/tree.production.line/lib/src/orchestrator_service.dart#L126-L130)）。
   `prepare.finalize` 只把子任务建成 `queued`，不会把产线转 `working`，也不会拉一次 tick
   （[preparation_service.dart:640-650](../../plugins/tree.production.line/lib/src/preparation_service.dart#L640-L650)）。
   即：**准备阶段结束、队列里有任务时，产线不会自己开始跑**。
4. **第三个硬断点：任务只有「标题 + 写域」**。新建任务对话框只收集两项
   （[production_line_workbench.dart:1403-1408](../../plugins/tree.ui.default/lib/ui/widgets/production_line_workbench.dart#L1403-L1408)、
   [:1488-1523](../../plugins/tree.ui.default/lib/ui/widgets/production_line_workbench.dart#L1488-L1523)）；
   REST 的 `PATCH task` 只接受状态迁移
   （[api.dart:248-265](../../plugins/tree.production.line/lib/src/api.dart#L248-L265)），
   依赖、优先级、读域、验收判据、`kind`、需求模板都只能在 `task.yaml` 里手工写。
5. **第四个硬断点：没有实时状态，也没有下钻**。工作台只在 `initState` / 切回可见时拉一次
   任务与台账（[production_line_workbench.dart:122-162](../../plugins/tree.ui.default/lib/ui/widgets/production_line_workbench.dart#L122-L162)），
   全文件没有 Timer / 站点订阅；台账只显示前 20 条一行摘要
   （[:915-928](../../plugins/tree.ui.default/lib/ui/widgets/production_line_workbench.dart#L915-L928)），
   产物只列路径文本、不能点开
   （[:1193-1210](../../plugins/tree.ui.default/lib/ui/widgets/production_line_workbench.dart#L1193-L1210)）。
   `pack.json`、门控输出、员工问答、专家调用这些最需要看的东西，UI 一个都没有展示入口。
6. **核心差异还没落地：没有「先摘要关键词 + 双查询检索 + 一次 LLM」的理解链**。当前侦查已经是
   `docnorm.query` → `llm.call` 的单次调用（[preparation_service.dart:188-207](../../plugins/tree.production.line/lib/src/preparation_service.dart#L188-L207)），
   但只查一次文档、没有关键词、没有附件摘要：既没有 LLM #1 总结需求/附件/关键词，
   也没有「原文 + 关键词」两次 embed 与 RRF 合并，更没有 `evidence_id` 与检索门控（§4.9）。
7. **补齐的正确姿势是「接产品闭环」**：新增准备阶段 REST、10s 检索/上下文包服务、任务详情/编辑 REST、
   事件广播、驱动补洞与工作台三段式 UI；后端已有能力全部复用。
8. **阶段口径冲突**：当前是「稳定性迭代（只修缺陷、补测试）」且明确「新能力一律不入本期」
   （[project-status.md:6](../project-status.md#L6)）。本项属于**新能力补齐**，需拍板切阶段
   或单开一条不占本期发布窗口的车道（§10 P1）。

---

## 2. 什么叫「功能做全」（验收口径）

以**用户能在 UI 里完成一条产线的完整生命周期**为准，不以「命令能跑」为准。

### 2.1 三条用户路径

| 路径 | 起点 | 终点 | 当前 |
| --- | --- | --- | --- |
| **准备** | 新建产线 | 需求五栏 → 侦查四块 → 逐题拍板 → 范围与任务计划落档 | 不可达（无 REST / 无 UI） |
| **执行** | 队列里有 `queued` 任务 | 主控自动 continue/retry/ask/stop → 打包 → 执行 → 门控 → `done` | 只能手点；跑完第一步后停住 |
| **复盘** | 任务结束 | 看台账、门控输出、产物、整理报告、逻辑去重 | 只看到一行摘要与路径文本 |

### 2.2 六条可验收目标

| # | 目标 |
| --- | --- |
| G1 | 从空白产线开始，用户不离开 UI 完成：建线 → 需求五栏 → 侦查 → 拍板 → 拆任务 → 启动执行 |
| G2 | 执行期自动推进；暂停/恢复/立即决策/回答运行期问题都可用；每一步有可见的决策记录 |
| G3 | 任务详情可看可改：范围、依赖、优先级、验收、`kind`；能看到 pack、改动文件、门控输出、消息与专家调用 |
| G4 | 产物可打开：`recon / scope / plan / decisions / acceptance / pack / audit` 能在工作台点开并落到文件窗 |
| G5 | 配置面完整：角色、`limits`、`policy`、`docs.memory_manifest` 都能在 UI 改；手动派发也遵守依赖/并行/写域护栏（或显式强制） |
| G6 | 真模型端到端一次通过（O6），并且缺模型、缺依赖、门控失败、预算超限、主控连续失败这五条异常路径都能看到原因并恢复 |

### 2.3 缺陷 / 欠交付 / 新能力：三分口径

判据：

- **缺陷**：已定稿行为 + 已写验收，实现与之不符；修复不引入新入口、不改语义。
- **欠交付**：方案/验收写了，但从未实现；补齐需要新增入口或模块，工作量等同新能力。
- **新能力**：方案未定稿，或会改变既有语义 / 状态机 / 数据契约。

| 项 | 判定 | 理由 |
| --- | --- | --- |
| 手动派发后主控不继续 | **缺陷** | D6-O §3.1「事件驱动为主」，实现只给主控派发挂事件 tick |
| 定时 tick 有 `queued` 仍跳过 | **缺陷** | §3.1 定位是「防停住」兜底，现在首任务永远起不来 |
| `line.status` 恒 `idle` | **缺陷** | §7.2 定义 `idle/working/paused`，实现只有 pause/resume 会写 |
| 手动派发绕过依赖/并行/写域 | **缺陷** | §3.3/§9.6 是硬护栏，REST 路径未复用 queue 判据 |
| 台账/产物/详情不可下钻 | 缺陷偏欠交付 | §6.3 与 TC-PL-11/12 要求可看；可小步先补 |
| 准备阶段 UI + REST | **欠交付 → 按新能力立项** | §6.2/§10.4 要求 UI，但 §10.2 从未给 prepare 路由，属方案缺口 |
| 任务字段编辑（依赖/优先级/验收） | **新能力** | `task.yaml` 有字段但无编辑契约，会动状态机与队列语义 |
| `limits/policy/docs` 配置面 | **欠交付 → 能力补齐** | §6.4 只有栏目名，从未落地 |
| 事件广播站 | **欠交付 → 能力补齐** | §10.3 定稿但从未实现，需要新站 + UI 订阅 |
| git 任务分支隔离（D3） | **新能力** | 定稿默认开但从未实现，引入分支生命周期与回退语义 |

**结论**：不能整体算「补能力缺陷」。稳定性迭代内可以先修前 4 条真缺陷（并小步补台账/产物下钻）；
准备阶段、任务编辑、配置面、事件推送属于欠交付/新能力，应单开 PC 车道或切快速迭代。

### 2.4 不做什么（沿用既有定稿）

- 不做无人值守连跑一整天；「自动推进」只到「把当前队列跑完」。
- 不做跨产线调度、不做产线互调 Agent 会话。
- 不放松「`done` 只由门控通过触发」「未答不实施」「专家不落盘」三条硬语义。
- 不新增核心点位；REST 全部由 `tree.production.line` 自行申报。

---

## 3. 现状对照（能力 × 后端 × REST × UI）

图例：✅ 已有且可达｜⚠️ 部分可用｜❌ 缺失。

| 能力 | 后端 | REST | UI | 判定与证据 |
| --- | --- | --- | --- | --- |
| 产线 CRUD / 配置 | ✅ | ✅ | ✅ | 建/改/删线、角色模型与工具、主控段都在建线弹窗 |
| 角色模型 / 工具白名单 | ✅ | ✅ | ✅ | 四张角色卡；执行必须含 `write/edit` |
| `limits` 配置 | ✅ 默认值 | ✅ PATCH 浅合并 | ❌ | 建线弹窗没有并行数/重试/预算字段（`create_production_line_dialog.dart:563-660` 只有角色与主控） |
| `policy` 配置 | ✅ 默认值 | ✅ | ❌ | `deny_globs` / `allow_git_write` / `allow_spawn` 无 UI |
| `docs.memory_manifest` | ✅ 默认值 | ✅ | ❌ | 侦查要看哪几份文档，用户改不了 |
| 需求模板五栏 | ✅ | ❌ | ❌ | `production.prepare.intake` 只有命令 |
| 侦查四块 | ✅ | ❌ | ❌ | `production.prepare.recon` 只有命令 |
| 追问 / 拍板 | ✅ | ⚠️ | ⚠️ | 只有 `GET questions` 与 `POST decision`；问题无法从 UI 产生 |
| 20 分钟窗口 open/close | ✅ | ❌ | ❌ | `production.prepare.window.*` 只有命令 |
| 定范围 / 拆任务 / 落档 | ✅ | ❌ | ❌ | `production.prepare.finalize` 只有命令 |
| 任务创建 | ✅ | ✅ | ⚠️ | UI 只给标题 + 写域 |
| 任务读详情 | ✅ | ✅ | ❌ | UI 只拉列表，不 GET 单任务 |
| 任务编辑（依赖/优先级/验收/读域/kind） | ❌ | ❌ | ❌ | PATCH 只做状态迁移 |
| 队列计划（依赖/写域/并行） | ✅ | ❌ | ❌ | `production.queue.dispatch` 只读计划，UI 未接 |
| 派发 pack / run | ✅ | ✅ | ✅ | 手点，后台跑 |
| 主控 tick / pause / resume / status | ✅ | ✅ | ✅ | 主控条 + 暂停/恢复/立即决策 |
| 自动推进（事件 / 定时） | ⚠️ | — | — | 只有主控自己派发后的事件 tick 会接上（§4.4） |
| 运行台账 | ✅ | ✅ | ⚠️ | 只显示 20 条一行摘要，无详情 |
| `pack.json` / 门控输出 / 改动文件 | ✅ | ❌ | ❌ | 数据在 `runs/` 与 `pack.json`，REST 未暴露 |
| 任务内消息 / 专家调用 | ✅ | ❌ | ❌ | `production.task.messages|expert` 只有命令 |
| 预算 | ✅ | ❌ | ❌ | `production.task.budget` 只有命令；UI 不显示用量 |
| 产物列表 | ✅ | ✅ | ⚠️ | 只列路径文本，不能打开 |
| 产物打开（文件窗） | ✅ files 插件 `line:<id>` 作用域 | — | ⚠️ | 文件窗能按产线浏览，但工作台没有跳转入口 |
| 整理报告 / 逻辑去重 | ✅ | ✅ | ✅ | 工作台可直接跑 |
| 实时状态 | ❌ | — | ❌ | 无广播站、无轮询 |
| git 任务分支隔离 | ❌ | — | — | 设计 D3 默认开，但只做了 `git status` 差集 |
| 真模型端到端 | ❌ | — | — | O6 待做（`project-status.md:34`） |

---

## 4. 空骨架证据链（逐项根因）

### 4.1 准备阶段是「命令行的能力」，不是产品能力

- 准备阶段有完整命令：`intake / recon / questions / answer / all_recommended / window.open /
  window.close / read / finalize / status`（[preparation_service.dart:17-27](../../plugins/tree.production.line/lib/src/preparation_service.dart#L17-L27)）。
- 但 REST 路由表只有 `lines / tasks / runs / artifacts / audit / dedup / questions /
  answer / orchestrate / pause / resume / orchestrator / dispatch / decision / cancel / migrate`
  （[api.dart:64-87](../../plugins/tree.production.line/lib/src/api.dart#L64-L87)）。
  **没有 `intake`、`recon`、`window.*`、`finalize`、`status`**。
- UI 侧没有 `prepare*` 方法（[api_service.dart:1216-1502](../../plugins/tree.ui.default/lib/io/api_service.dart#L1216-L1502)），
  工作台也没有准备阶段区域（[production_line_workbench.dart:895-980](../../plugins/tree.ui.default/lib/ui/widgets/production_line_workbench.dart#L895-L980)）。

**影响**：用户能看到的「拍板」只是运行期/历史问题的回答框；产线最核心的 20 分钟准备流程
（需求 → 侦查 → 追问 → 拆任务）完全无法在应用里发生。**这是「空骨架」的第一原因。**

### 4.2 任务模型被压缩成「标题 + 写域」

- 新建任务对话框只收 `title` 与 `write_scope`（[production_line_workbench.dart:1488-1523](../../plugins/tree.ui.default/lib/ui/widgets/production_line_workbench.dart#L1488-L1523)），
  提交体只有四项（[:223-233](../../plugins/tree.ui.default/lib/ui/widgets/production_line_workbench.dart#L223-L233)）。
- `PATCH /tasks/{taskId}` 只接受 `to/status`，其余字段被忽略
  （[api.dart:248-265](../../plugins/tree.production.line/lib/src/api.dart#L248-L265)）。
- 后端 `task.yaml` 支持 `kind / priority / depends_on / read_scope / acceptance / intake /
  artifacts / gate`（[models.dart:203-234](../../plugins/tree.production.line/lib/src/models.dart#L203-L234)），
  但没有任何 UI/REST 编辑入口。

**影响**：任务无法表达依赖与优先级，队列排序/并行计划退化；验收判据与需求模板只能靠人改 YAML，
「准备阶段拆出来的任务」与「用户手建的任务」不是同一种数据。

### 4.3 详情、台账与产物都不可下钻

- 工作台运行台账只取 20 条、每条一行（[production_line_workbench.dart:915-928](../../plugins/tree.ui.default/lib/ui/widgets/production_line_workbench.dart#L915-L928)）。
- 产物只显示 `path` 文本（[:1193-1210](../../plugins/tree.ui.default/lib/ui/widgets/production_line_workbench.dart#L1193-L1210)）。
- UI 没有调用 `GET /tasks/{taskId}`（`api_service.dart` 只有列表方法 `:1294-1305`），
  因此 `pack.json`、`changed_files`、`gate[{command,ok,exit_code,output}]`、`last_error`、
  `usage`、`loop` 都没有展示位置。
- `production.task.messages` / `expert` 命令存在（[execution_service.dart:25-34](../../plugins/tree.production.line/lib/src/execution_service.dart#L25-L34)），
  但 REST 未暴露，UI 也无入口。

**影响**：任务失败时用户只看到 `blocked` 和一句 `last_error`；无法判断是打包不全、门控失败还是写域越界，
也无法查看员工之间的消息与专家结论。**排障能力为零，等于骨架。**

### 4.4 驱动断链：队列不会自己开始，也不会自己继续

代码事实：

1. **手动派发不触发 tick**：`POST .../dispatch` → `dispatchProductionTask`，后台 job 结束后直接返回，
   没有调用 `_scheduleEventTick`（[api.dart:573-650](../../plugins/tree.production.line/lib/src/api.dart#L573-L650)）。
   事件 tick 只在「主控派发」路径里挂上
   （[tree.production.line_plugin.dart:247-302](../../plugins/tree.production.line/tree.production.line_plugin.dart#L247-L302)）。
2. **定时 tick 只认在途任务**：`trigger == 'timer'` 时没有任何 `packing/packed/running/gating`
   就直接 `skipped(idle)`（[orchestrator_service.dart:126-130](../../plugins/tree.production.line/lib/src/orchestrator_service.dart#L126-L130)）。
3. **准备落档不启动**：`prepare.finalize` 把子任务建成 `queued` 后只返回分发摘要
   （[preparation_service.dart:640-650](../../plugins/tree.production.line/lib/src/preparation_service.dart#L640-L650)），
   不改 `line.status`、不 tick。
4. **产线状态没有生命周期**：`line.status` 默认 `idle`，只有 `pause/resume` 会写 `paused/working`
   （[api.dart:429-461](../../plugins/tree.production.line/lib/src/api.dart#L429-L461)、
   [models.dart:261-268](../../plugins/tree.production.line/lib/src/models.dart#L261-L268)）。
   正常跑任务时它仍是 `idle`，UI 却把它当状态展示（[production_line_panel.dart:304-341](../../plugins/tree.ui.default/lib/ui/widgets/production_line_panel.dart#L304-L341)）。

**影响**：即使准备阶段能从 UI 跑完，落档后的 `queued` 任务也不会自动开始；用户手点第一步后，
主控也接不上后续批次。D6-O 的「事件驱动为主」在实际产品路径上没有闭环。

### 4.5 没有实时状态

- 工作台只在 `initState` 和「不可见 → 可见」时拉数据
  （[production_line_workbench.dart:83-113](../../plugins/tree.ui.default/lib/ui/widgets/production_line_workbench.dart#L83-L113)、
  [:122-162](../../plugins/tree.ui.default/lib/ui/widgets/production_line_workbench.dart#L122-L162)），
  全文件没有 `Timer` / `StationClient` / 订阅逻辑。
- 插件只注册了执行站 `production`（[tree.production.line_plugin.dart:154-177](../../plugins/tree.production.line/tree.production.line_plugin.dart#L154-L177)），
  没有实现设计里的 `plugin.tree.production.line.broadcast.task_state`
  （[production-line-recon.md:885-893](production-line-recon.md#L885-L893)）。

**影响**：打包/执行在主控后台跑，界面不刷新；用户看到的是点击前那一刻的快照。
「运行中」没有任何进度感，也没法在任务阻塞时即时提示。

### 4.6 配置面缺失：默认值成了唯一配置

- `line.yaml` 后端有完整的 `limits / policy / docs` 默认段
  （[models.dart:309-329](../../plugins/tree.production.line/lib/src/models.dart#L309-L329)），
  建线弹窗只配置「角色 + 主控循环」（[create_production_line_dialog.dart:563-660](../../plugins/tree.ui.default/lib/ui/widgets/create_production_line_dialog.dart#L563-L660)）。
- 因此并行数、重试次数、单任务 token/时长预算、禁区、项目记忆清单都不可调；
  用户只能接受默认值，或直接改 `line.yaml`。

**影响**：真实项目里「预算 / 禁区 / 侦查读哪些文档」是第一等配置；缺了它们，产线无法托管任何有风险的项目。

### 4.7 手动派发绕过硬护栏

- `queue.dispatch` 会判依赖、写域交叠与 `max_parallel_tasks`
  （[queue.dart:138-180](../../plugins/tree.production.line/lib/src/queue.dart#L138-L180)）。
- 但 `POST .../dispatch` 只判任务状态与同任务 in-flight 锁
  （[api.dart:590-637](../../plugins/tree.production.line/lib/src/api.dart#L590-L637)），
  不查 `depends_on`、不查并行槽位、不查写域交叠；UI 又是逐任务手点派发
  （[production_line_workbench.dart:1055-1082](../../plugins/tree.ui.default/lib/ui/widgets/production_line_workbench.dart#L1055-L1082)）。

**影响**：多任务时用户手点两次就能让两个写域重叠的任务并行跑，直接违背 §9.6「宁可少并行也不让两个写者碰同一文件」。
需要明确：手动派发是「用户显式越权」还是「必须同样受护栏」。

### 4.8 隔离与联调缺位

- 设计 D3「每个任务默认在 `pl/<line>/<task>` 分支执行」未实现；执行前后只用
  `git status --porcelain` 做差集判权（[execution_service.dart:457-463](../../plugins/tree.production.line/lib/src/execution_service.dart#L457-L463)、
  [:538-548](../../plugins/tree.production.line/lib/src/execution_service.dart#L538-L548)）。
  失败回退只能靠人工 `git checkout`，与设计「回退 = 丢弃分支」不一致
  （[production-line-recon.md:818-822](production-line-recon.md#L818-L822)）。
- O6「真模型端到端（准备 → 打包 → 执行 → 决策 → ask/answer → done）」仍是待办
  （[project-status.md:34](../project-status.md#L34)）。所有单测都是假 LLM，真实模型下的
  提示词质量、JSON 合法性、工具调用与预算尚未验证。

### 4.9 核心差异缺位：没有「先摘要关键词 + 双查询检索 + 一次 LLM」的理解链

产品要的是「LLM #1 总结用户要求/附件/关键词 → 原文与关键词两次 embed（合计 ≤5s）→
双查询图谱检索 + RRF 合并 → 上下文包 → LLM #2 直接进入语义对齐」。当前实现方向相同
（一次 `docnorm.query` + 一次 `llm.call`），但只有单查询、无摘要、无附件、无门控：

| 要求 | 现状 | 证据 |
| --- | --- | --- |
| LLM #1 摘要/关键词 | 没有；需求原文直接拼进 prompt | `reconUserPrompt` 只吃需求 + `memory`（[preparation.dart:806-825](../../plugins/tree.production.line/lib/src/preparation.dart#L806-L825)） |
| 双查询 | 只有一次 `docnorm.query`；没有关键词查询与 RRF | `_queryDocs` 单次调用（[preparation_service.dart:188-207](../../plugins/tree.production.line/lib/src/preparation_service.dart#L188-L207)） |
| 附件摘要 | 没有附件输入（PC-3A/3D 才加），更无图片总结 | `task.attachments` 未实现 |
| 两次 embed ≤5s | 无 embed 预算/并行/超时降级 | 无 embed 调度 |
| 一次性上下文包 | 没有；模型只看文档块 + 需求文本 | 无 `evidence_id` / 配额 / 裁剪口径 |
| 证据与覆盖 | 侦查 JSON 是模型自述，没有逐条证据强制、没有覆盖读数 | `parseReconJson` 只校验四块结构（[preparation.dart](../../plugins/tree.production.line/lib/src/preparation.dart)） |
| 检索 10s / 缓存 | 无检索预算、无 partial、无理解缓存 | 无 `understanding` 服务 |

**影响**：LLM 不是问题，问题是**没有先摘要就检索、单查询召回不全、上下文不打包、没有门控**，
导致召回可能跟需求无关，模型只能基于半份事实编理解。这一项必须单独立切片（PC-2A/PC-5A）：
先 LLM #1 摘要/关键词，再双查询（两次 embed ≤5s）+ RRF，检索阶段 ≤10s，
仍只调 LLM #2；附件摘要由 PC-3D 接入。

### 4.10 没有前置就绪门：文档归一化/索引未完成也能开任务

产品要求「文档归一化 + 索引构建完成之前不得开任何任务」；当前没有这个门：

| 要求 | 现状 | 证据 |
| --- | --- | --- |
| 文档归一化门 | `prepare.recon` 直接 `docnorm.query`，不检查 `doc_state` 是否就绪；无文档也能继续 | `_queryDocs` / `_callLlm`（[preparation_service.dart:188-207](../../plugins/tree.production.line/lib/src/preparation_service.dart#L188-L207)） |
| 索引门 | `task.create` / `queue.dispatch` / `start` / `tick` 都不查 `pkg_index`、`graph_*`、`dedup_*` | 任务创建与派发命令（[api.dart:248-290](../../plugins/tree.production.line/lib/src/api.dart#L248-L290), [api.dart:573-650](../../plugins/tree.production.line/lib/src/api.dart#L573-L650)） |
| 状态表达 | 产线状态没有 `初始化中`，索引缺失时界面仍可点「新建/开始」 | `line.status` 计算（[orchestrator_service.dart:126-160](../../plugins/tree.production.line/lib/src/orchestrator_service.dart#L126-L160)） |
| 失效重检 | 工作空间 HEAD 变化/索引 stale 后，没有自动冻结开新任务 | 无 readiness 服务/缓存版本校验 |

**影响**：首任务可能在空图谱上打包/执行，理解卡没有文档/代码证据，等于把「真实全面」的地基抽掉；
必须加产线级 `line.ready` 门，所有开任务命令统一校验，前端只做镜像。

### 4.11 文档归一化会写既有文档，但没有预检/回滚；产线也没有项目文档维护

两个现状必须一起看：

1. **`docnorm` 的归一化不是只读**：`baseline` 在 `commit=true` 时直接 `writeAsStringSync`
   追加章节/索引行；整篇改写要进 `rewrite_allowlist`（[baseline.dart:1082-1228](../../plugins/tree.docnorm/lib/src/baseline.dart#L1082-L1228)）。
   现有 `commit=false` 只返回 diff（`_Plan.toJson` 含 `diff`），但没有备份、补丁、回滚命令，
   也没有把「归一化写入」纳入产线门禁；当前就绪门只检查结果，不保护过程。
2. **产线不维护项目文档**：`prepare.finalize` 只写 `docs/production_lines/<line>/` 下的
   `recon/scope/plan/decisions/acceptance`（[preparation_service.dart:620-676](../../plugins/tree.production.line/lib/src/preparation_service.dart#L620-L676)），
   `audit` 只写 `audit.md`；`docs.memory_manifest` 里的 project-status/work-log/known-issues
   只被 `_projectContext` 读入（[execution_service.dart:1333-1362](../../plugins/tree.production.line/lib/src/execution_service.dart#L1333-L1362)）。
   执行/门控没有「更新文档」步骤，代码任务默认也不改 `docs/`。

**影响**：归一化可能改脏既有文档却没有回滚路径；同时用户会误以为产线会维护 work-log/known-issues，
实际不会。需要把「归一化写入」拆成独立预检写入阶段（PC-2C），把「项目文档维护」明确为
默认只读 + 显式文档任务（PC-3C）。

### 4.12 图谱检索没有接入附件，图片边界完全未定义

产品要求理解阶段把附件也作为输入；当前 `production.prepare.recon` 只查文档，
没有附件 evidence，也没有图片处理：

| 要求 | 现状 | 证据 |
| --- | --- | --- |
| 附件进入理解 | 准备阶段输入只有五栏 + `docnorm.query`；`task.attachments` 尚未实现（PC-3A） | `_recon` 调用 `_queryDocs` / `_callLlm`（[preparation_service.dart:188-207](../../plugins/tree.production.line/lib/src/preparation_service.dart#L188-L207)） |
| 图片视觉 | 现有 `agent.worker.run` 没有 attachments 透传（PC-3B 才加） | `SubagentTurnRequest` 无附件字段 |
| 图片边界 | 无像素上限、EXIF 剥离、动图首帧、透明处理、重复去重、超量降级、非视觉降级 | 无附件理解模块 |
| 安全 | 没有「base64 不入上下文包」「MIME 嗅探」「SVG 禁脚本」的约束 | 无 attachment context builder |

**影响**：用户上传设计稿/截图后，理解卡完全看不到图；或者实现时把 base64 塞进 JSON、
把动图/超大图直接送模型，导致超时/超 token/隐私问题。需要单列 **PC-3D 附件理解边界**，
把「LLM #1 先总结附件摘要/关键词 → 关键词进入查询 B → 图片预处理与安全」钉死（§5.2.10 口径）。

---

## 5. 产品形态定稿（建议）

> 最终产品形态（先摘要关键词 + 双查询检索 + 一次 LLM、默认落地页、准备四步、任务看板与右栏详情页、复盘工具、状态文案）见
> [production-line-product-form.md](production-line-product-form.md)；本节只给补齐所需的最小骨架。

### 5.1 工作台三段式

选中产线后，中栏工作台固定三段（不是三个页面来回跳）：

```text
┌ 产线头：名称 / 工作空间 / 真实状态 / 进度 3/8 / 预算 / [开始执行] [暂停] [恢复] [立即决策] ┐
├ 准备阶段（未完成时展开，完成可折叠）                                                       │
│   ① 需求五栏（目标/现状/验收/禁区/期限）→「开始侦查」                                       │
│   ② 侦查四块（常规 R / 特殊 S / 待拍板 Q / 回退与注意 F/N）                                 │
│   ③ 决策收件箱（默认项/推荐/不选后果；逐条或全部按推荐）                                     │
│   ④ 范围与计划（in/out、任务 DAG、写域）→「确认并落档」                                      │
├ 执行阶段                                                                                   │
│   任务看板（按状态分组，显示依赖/写域/重试/预算；支持批量派发）                                 │
│   任务详情抽屉（意图/模板/验收/依赖/范围/pack/改动/门控/消息/专家/台账）                        │
├ 复盘与工具（折叠）：运行台账 · 产物 · 整理报告 · 逻辑去重                                      │
└                                                                                           ┘
```

### 5.2 准备阶段交互（对齐 §8）

1. **需求五栏**必须可保存草稿；空泛词给改写建议；目标/验收为空禁止提交（后端已判）。
2. **侦查四块**按固定顺序展示，`Q` 卡片显示默认选项、推荐项与不选后果；支持「全部按推荐」。
3. **窗口**：顶部显示本轮窗口剩余时间（仅提示，不硬截断）；离开/关闭窗口时提示未答问题会跨日保留。
4. **落档**：确认前展示 `scope.md` / `plan.md` 预览与任务列表；落档后展示 ≤10 行分发摘要，
   并提供「开始执行」按钮（或自动触发一次 tick，见 §6.3）。
5. **未答不实施**：有 open 问题时「确认并落档」置灰，并给出还差哪几题。

### 5.3 执行阶段交互

1. 任务看板按 `blocked / awaiting_user / queued / packing / packed / running / gating / done / cancelled` 分组；
   `blocked` 行必须显示 `blocked_reason`，并提供「恢复 / 重试 / 取消」。
2. 顶部主控条显示：`enabled / last_action / consecutive_failures / last_tick_at`；
   「立即决策」回包要能展开看 `guard`（被哪条护栏降级）。
3. 运行期问题卡保留在收件箱顶部，回答后任务回 `queued`，下一次 tick 继续。
4. 所有任务状态/台账/主控游标走事件推送或 3s 轮询（§6.2），不要求用户切页刷新。

### 5.4 配置页

建线/编辑弹窗补三组：

| 组 | 字段 | 默认 |
| --- | --- | --- |
| 并发与预算 | `max_parallel_tasks / max_tokens_per_task / max_minutes_per_task / retries` | `1 / 0 / 0 / 2` |
| 安全边界 | `deny_globs / allow_git_write / allow_spawn` | 现有默认 |
| 项目记忆 | `docs.asset_dir / memory_manifest`（多行路径） | 现有默认 |

---

## 6. 后端缺口与接口设计

### 6.1 REST 补齐（全部由产线插件申报，不新增核心点位）

| 方法 | 路径 | 复用命令 | 说明 |
| --- | --- | --- | --- |
| POST | `/api/production/lines/{id}/tasks/{taskId}/prepare/intake` | `production.prepare.intake` | 五栏落 `task.yaml.intake` |
| POST | `.../prepare/recon` | `production.prepare.recon` | 需要 `agent_id`（`llm.call` 身份） |
| GET | `.../prepare` | `production.prepare.status` | 窗口/读取计数/侦查摘要/未答问题 |
| POST | `.../prepare/window/open` / `close` | `production.prepare.window.*` | 跨日续答 |
| POST | `.../prepare/finalize` | `production.prepare.finalize` | 落档 + 建子任务 + 返回摘要 |
| POST | `.../tasks/{taskId}/understand` | `production.prepare.understand` | **LLM #1 摘要 + 双查询 + LLM #2**：返回 `understanding_id/digest_ms/retrieval_ms/llm_ms/partial/recall_gap/degraded/coverage/evidence`；`reuse_context_id` 可复用上下文包与摘要重试 |
| GET | `.../tasks/{taskId}/understand/{understandingId}` | `production.prepare.understand.status` | 进度 / 结果 / 证据（流式或轮询） |
| GET | `/api/production/lines/{id}/graph` | `production.graph.status` | 包图/文档图/代码块索引的新鲜度与覆盖 |
| GET | `/api/production/lines/{id}/ready` | `production.line.ready` | **前置就绪门**：`{ready, phase, progress, missing[], graph_version, checked_at}` |
| POST | `/api/production/lines/{id}/graph/rebuild` | `production.graph.rebuild` | 文档归一化/索引重建或重试；完成后重新判门 |
| POST | `/api/production/lines/{id}/normalize/plan` | `production.normalize.plan` | **预检写入**：`docnorm` `commit=false` 的 diff/动作/skipped/rejected；0 写盘 |
| POST | `/api/production/lines/{id}/normalize/apply` | `production.normalize.apply` | 确认后串行写盘；备份 + `before_sha256` + patch；失败回滚；不自动 commit |
| POST | `/api/production/lines/{id}/normalize/rollback` | `production.normalize.rollback` | 按 `runId` 回滚归一化写入，重新阻塞直到重建完成 |
| GET | `/api/production/lines/{id}/normalize/{runId}` | `production.normalize.status` | 写入状态、文件、备份/补丁、错误 |
| PATCH | `/api/production/lines/{id}/tasks/{taskId}`（扩展） | 新 `production.task.update` | 非终态任务可改 `title/brief/kind/priority/depends_on/read_scope/write_scope/acceptance/references`；终态只读 |
| POST/DELETE | `.../tasks/{taskId}/attachments` | `production.task.attach/detach` | 附件登记/移除；来源限 `.input/`，复制进 `.input/production_lines/<line>/tasks/<task>/attachments/` 并记 `sha256/size/type` |
| POST | `/api/production/lines/{id}/tasks`（扩展） | `production.task.create` | 建任务可带 `brief/acceptance/depends_on/references/attachment_sources` |
| POST | `/api/production/lines/{id}/queue/plan` | `production.queue.dispatch` | 只读派发计划（依赖/写域/槽位） |
| POST | `/api/production/lines/{id}/start` | `line.status=working` + tick | 准备落档后的显式启动 |
| GET | `.../tasks/{taskId}/pack` | 读 `pack.json` | 片段清单、基线命令、风险点（大块走 `result_path`？见 §6.5） |
| GET | `.../tasks/{taskId}/messages` | `production.task.messages` | 员工消息线程 |
| GET | `.../tasks/{taskId}/budget` | `production.task.budget` | 上限/用量/剩余/软停原因 |
| GET | `.../runs/{runId}` | 读 `runs/<id>.json` | 单条台账详情（含门控输出、tool_calls、usage） |
| GET | `.../artifacts/{path}` | 读项目资产 | 工作台点开产物（或复用 files 插件 `line:<id>`） |

> 读大文件（`pack.json`、门控输出、产物正文）统一走两种方式之一：小内容内联，大内容走
> files 插件/`result_path` 磁盘读取；**禁止 base64 内联**（项目硬约束）。

### 6.2 事件面（实时状态）

新增自建广播站 `plugin.tree.production.line.broadcast.task_state`：

```jsonc
{
  "seq": 42,                    // 单调递增；断线重连按 seq 去重
  "line_id": "pl_...",
  "type": "task_state|line_status|decision|question|run_finished",
  "task_id": "T3",
  "status": "running",
  "loop": {"attempts": 1, "ask_count": 0},
  "at": "2026-11-14T10:00:00+08:00"
}
```

- 写入点：状态迁移成功、主控决策落盘、运行期问题写入、run 结束。
- UI 只订阅广播站（UI 不能订阅执行/收集站）；晚订阅必须能靠 REST 快照对齐
  （`GET tasks` + `GET runs` + `GET orchestrator`）。
- 兜底：工作台可见时 3s 轮询；收到推送后停轮询，断开后恢复。**不要求核心新增推送通道。**

### 6.3 驱动口径修正（关键）

| 触发 | 现状 | 建议 |
| --- | --- | --- |
| `prepare.finalize` 完成 | 不 tick，`line.status` 仍 `idle` | 落档后把产线转 `working` 并立即 tick 一次（或 UI 展示「开始执行」显式触发；二选一，建议自动） |
| 手动派发 job 结束 | 不 tick | 结束后 debounce 一次事件 tick，与主控派发路径一致 |
| 定时 tick | 无在途任务即跳过 | 改为「有非终态任务（含 `queued`）就允许 tick」，仍用快照哈希跳过未变化；避免首任务永远起不来 |
| 产线状态 | 只有手动 pause/resume 写 | `working = 有非终态任务或无 blocked`；`idle = 全 done/cancelled`；`paused` 保持人为覆盖；状态由后端计算，UI 只读 |
| 连续失败暂停 | 已有 | 保留；恢复时清 `consecutive_failures` |

> 这与 D6-O §5.4「无在途任务不空转」有冲突：建议把「空转」定义改为「快照未变化」，
> 而不是「没有 in-flight」。因为 `queued` 任务本身就是待办，不算空转。需拍板（§10 P3）。

### 6.4 护栏

- 手动派发默认同样检查 `depends_on`、`max_parallel_tasks`、写域交叠；不满足回 409 并给原因。
- 如需越权，显式传 `force: true`，台账记录 `forced_by_user`；建议首版**不提供**强制，先保证安全。
- `queue/plan` 作为「批量派发」的数据源：UI 只对 `batch` 里的任务并发发起 dispatch。

### 6.5 数据与保留

- `runs` 目前无上限；建议每任务保留最近 N 条（默认 50）与全部失败/决策记录，超出归档到
  `<line>/runs/archive/`（不删除）。
- 门控输出单条上限（建议 16 KiB，超出截断并标 `truncated` + `output_path`）。
- `pack.json` 可能很大：REST 只回摘要（文件数/总字节/基线命令），正文按需读或走 files 插件。
- 事件 seq 落 `state.json` 游标，崩溃恢复后从游标继续，不重复推送。

---

## 7. 语义定稿（建议默认，待拍板项见 §10）

1. **准备阶段必须有 UI**；命令行能力保留给自检与外部调用，不作为产品入口。
2. **计划与任务同源**：`prepare.finalize` 建出的任务与手建任务使用同一套 `task.yaml` 字段；
   手建任务也必须能补 `acceptance / depends_on / read_scope / kind`。
3. **任务编辑边界**：`done / cancelled` 只读；`packing / packed / running / gating` 只能改
   `priority` 与 `depends_on`（不改写域/验收）；`draft / recon / aligning / scoped / queued /
   awaiting_user / blocked` 可改全部计划字段。改 `write_scope` 必须重算队列计划。
4. **产线状态由后端计算**，UI 不再把 `line.status=idle` 当作「没在工作」。
5. **自动推进只到队列跑完**：全部任务终态后产线回 `idle`，不自动生成新任务。
6. **事件优先、轮询兜底**：推送丢失不能导致界面永久停更。
7. **产物与文件同源**：工作台打开产物走 files 插件 `line:<id>` 作用域，不新增第二套文件读取。
8. **失败可见**：任何 `blocked` 必须能在 UI 看到 `blocked_reason` 与对应 run/门控输出。

---

## 8. 交付切片（每片一次提交 + 一次门禁）

> 顺序按依赖排：先补后端可达性，再做 UI；每片独立可回滚。

| 切片 | 内容 | 依赖 | 门禁 |
| --- | --- | --- | --- |
| **PC-1 驱动补洞** | `finalize` 后启动、手动派发后事件 tick、定时 tick 认 `queued`、产线状态计算、`start` 路由 | — | 插件单测：首任务自动起步、跑完自动 continue、暂停后不派发、状态计算真值表；自检新增 3 场景 |
| **PC-2 准备阶段 REST** | `prepare/*` 六条写路由 + `GET prepare`；错误码映射；`agent_id` 透传 | PC-1 | 插件单测：intake→recon→answer→finalize 全链路；REST 形状测试；契约路由基线同步 |
| **PC-2B 前置就绪门** | `production.line.ready` + `graph.rebuild`；文档归一化（`doc_state`/`no_docs`）+ 包图 + 文档图 + 代码索引 + 测试映射的完成判定；`line.ready` 固定 `graph_version`；`understand/task.create/task.attach/queue.dispatch/start/tick` 统一门控；HEAD/stale 自动失效 | PC-2 | 单测：任一项缺失时上述命令全部 `409 line_not_ready` 且带 `missing[]`；补齐后自动放行；stale 后重新阻塞；无文档 `no_docs` 可放行；无 force 参数 |
| **PC-2C 归一化预检写入** | `production.normalize.plan/apply/rollback/status`；复用 `docnorm` `commit=false` 的 diff 与 `commit=true` 写入；写前 `before_sha256` + 备份/补丁；只追加/索引、不新建；`rewrite` 需 allowlist + 二次确认；失败回滚；幂等；不自动 commit；写入期间任务全禁 | PC-2B | 单测：plan 0 写盘且有 diff；apply 后文件内容与 diff 一致；重复 apply 0 写盘；写入失败回滚到原文；rewrite 未授权拒绝；路径穿越/符号链接拒绝；`graph_version` 含文档内容 hash |
| **PC-2A 摘要 + 双查询检索** | `production.prepare.understand|status`；**LLM #1** 总结需求/附件/关键词（`digest_ms` 单独计）→ **两次 embed**（原文 + 关键词，合计 ≤5s）→ 双查询图谱聚合（`pkg_index` + 文档 graph + dedup 代码块/向量 + git/测试/风险）→ RRF 合并 → 上下文包（`evidence_id`/配额/裁剪）→ **LLM #2**；召回门控（`recall_gap`/`single_query` 不补第三轮）；证据校验；理解缓存与预 warm；检索 10s 硬超时出 partial | PC-2 + PC-2B | 单测/基准：摘要调用发生且无附件也跑；两次 embed 有独立超时与合计 ≤5s 预算；双查询都贡献、RRF 去重；检索 P95 ≤10s（不含两次 LLM）；冷启动/单路失败出 `partial/recall_gap/degraded`；结论引用 `evidence_id`；缓存命中 0 摘要/0 检索/0 模型 |
| **PC-3 任务输入与编辑 REST** | `production.task.create/update` 增 `brief/acceptance/depends_on/references`（字段白名单+状态边界）、`GET pack/messages/budget`、`GET runs/{id}`、`queue/plan`、`start`；派发前预检（内容/验收/依赖/写域） | PC-1 | 单测：缺内容/验收拒绝入队、终态拒改、在途只改优先级/依赖、改写域触发计划重算；大文件走磁盘/截断 |
| **PC-3C 文档维护边界** | 代码任务默认不写 `docs/`；计划可单独列文档任务（`write_scope` 只含目标文档、与同文档代码任务串行）；执行站写域校验；不自动改 work-log/project-status/known-issues；文档任务验收/台账 | PC-3 | 单测：代码任务越界写 docs 被拒；文档任务只写目标文档；同文档任务不并行；项目文档未被自动修改 |
| **PC-3A 附件上传与登记** | `production.task.attach/detach`；`.input/日期目录 → .input/production_lines/<line>/tasks/<task>/attachments/` 复制、`sha256/size/type`、同名后缀、越界/超限拒绝；`pack.json` 附件快照；提示词增附件/引用段；UI 上传/预览/移除；首版允许只存（known-issues #51） | PC-3 | 单测：复制与哈希、路径穿越/符号链接/超限拒绝、改附件使 `packed→queued`；UI 单测：上传预览、缺附件报错、文本附件可读 |
| **PC-3B 图像视觉** | `agent.worker.run` 增 `attachments`；`SubagentTurnRequest` 透传到现有 vision 通道；非视觉模型预检降级 | PC-3A + tree.agent | 单测：视觉模型收到 image part、非视觉模型只列路径不伪造；内联尺寸/JSON 上限沿用既有约束 |
| **PC-3D 附件理解边界** | LLM #1 总结附件（文本摘要/图片视觉总结/关键词）；关键词并入查询 B；图片预处理（像素上限/EXIF 剥离/长边 360–1024/动图首帧/透明/去重/最多 4 张/总 ≤12MB）；非视觉 `image_manual_reference`；MIME 嗅探、路径校验、base64 不入包/日志、SVG 禁脚本；LLM #2 默认读摘要，必要时附图 | PC-3A/3B + PC-2A | 单测：文本附件摘要/关键词进查询 B；视觉模型总结图片、非视觉不伪造；超大图降采样/拒绝；损坏图 unreadable；重复图去重；>4 张截断；EXIF 不残留；base64 不出现在上下文包/日志 |
| **PC-9 记忆端口** | `tree.agent` 新增 `agent.memory.get/record`（`.self/memory.md` + 压缩摘要；未来升级只改 agent）；产线只加 `MemoryPort`（prepare/pack/run 三处注入）与终态回写；run 台账记 `memory_hash/sources`；项目文档收敛为一个 `projectContext` helper | PC-3 + tree.agent | 单测：记忆块进提示词、`pack.json` 无记忆正文、记忆变化不使 pack 失效、记忆不可用任务仍完成；契约测试钉住 `get/record` 形状 |
| **PC-4 事件广播** | `broadcast.task_state`（seq）+ 写点 + REST 快照对齐；UI 订阅 + 3s 轮询兜底 | PC-1/PC-3 | 插件单测：seq 单调、重连去重；UI 单测：推送更新、断线轮询、断线横幅 |
| **PC-5 准备阶段 UI** | 五栏表单、问题卡（默认/推荐/后果）、窗口提示、落档预览与摘要、开始执行（理解卡见 PC-5A） | PC-2 | UI 单测：空泛词提示、未答禁止落档、全部按推荐、落档后任务可见；`flutter analyze` 0 |
| **PC-5B 就绪门 UI** | 产线头「初始化中」、清单/进度/重新检测、开任务按钮禁用、`409` 文案翻译、完成后自动刷新；「查看构建日志」 | PC-2B | UI 单测：缺项逐条显示、按钮禁用、补齐后自动放行、stale 后重新显示阻塞；`flutter analyze` 0 |
| **PC-5C 归一化预览 UI** | 归一化文件列表、diff 查看、动作/rewrite 警告、应用/取消、写入进度、失败回滚提示、运行记录 | PC-2C | UI 单测：plan 不写盘、diff 正确、rewrite 需二次确认、apply 后刷新就绪门、失败显示回滚结果；`flutter analyze` 0 |
| **PC-5A 理解卡 UI** | 「开始理解」→ LLM #1 摘要进度 → 10s 检索倒计时 →「上下文已就绪」→ LLM #2 单独计时 → 理解卡（一句话/影响面/复用/约定/风险/未知/问题/覆盖读数）；`[E#]` 证据点开文件或文档；「重新理解」/「重试」；partial/recall_gap/degraded/stale 徽标 | PC-2A + PC-5B | UI 单测：摘要阶段可见、10s 内上下文就绪、模型阶段单独计时、检索超时显示上下文包摘要、evidence 跳转正确、重试复用摘要+上下文、重新理解生成新 id；`flutter analyze` 0 |
| **PC-6 执行监控 UI** | 主控条增强（guard/连续失败）、任务分组看板、右栏任务详情页（内容/附件/pack/改动/门控/消息/专家/usage）、批量派发 | PC-3A/PC-4 | UI 单测：blocked 原因可见、门控输出展开、批量派发只发 batch；零位移/滚动不回归 |
| **PC-7 复盘与配置 UI** | 台账详情、产物点开（files `line:<id>`）、`limits/policy/docs` 配置、预算显示 | PC-3/PC-6 | UI 单测：产物跳转带正确作用域、配置回写不丢未知键；配置改动下一任务生效 |
| **PC-8 真模型 E2E + 文档** | O6 全链路：准备 → 打包 → 执行 → 决策 → ask/answer → done；异常五路径；提示词索引/工作日志 | PC-5/PC-5A/PC-5B/PC-5C/PC-6/PC-7/PC-9 | 真模型一次通过 + 截图/台账证据；插件 analyze 0 + 全量测试 + 自检；UI 全量测试；docs_contract |

### 8.1 实施导航（文件级）

| 层 | 文件 | 改动 |
| --- | --- | --- |
| 驱动 | `plugins/tree.production.line/tree.production.line_plugin.dart` | manual dispatch 后 `_scheduleEventTick`；finalize 回调；`start` |
| 驱动 | `lib/src/orchestrator_service.dart` | 定时 tick 条件、状态计算、`consecutive_failures` 恢复 |
| 理解（新） | `lib/src/understanding.dart` / `lib/src/understanding_service.dart` | LLM #1 摘要/关键词、两次 embed、双查询检索+RRF、上下文包/证据、召回门控、LLM #2、证据校验、检索 10s 超时、缓存与预 warm |
| 就绪门（新） | `lib/src/readiness.dart` / `lib/src/readiness_service.dart` | 文档归一化/包图/文档图/代码索引/测试映射完成判定、`line.ready`、`graph_version`、HEAD/stale 失效、开任务命令统一门控 |
| 归一化写入（新） | `lib/src/normalization.dart` / `lib/src/normalization_service.dart` | 复用 `docnorm` plan/apply；diff、备份/补丁、`before_sha256`、回滚、幂等、写入期任务冻结 |
| 文档边界（新） | `lib/src/docs_guard.dart` | 项目文档默认只读、文档任务写域/串行校验、禁止自动改 work-log/project-status/known-issues |
| 附件理解（新） | `lib/src/attachment_context.dart` | 附件摘要/关键词（交 LLM #1）、图片预处理/限额/安全、多模态 part、非视觉降级、base64 不入包 |
| 理解检索 | `lib/src/dedup_store.dart`（复用） / `tree.docnorm` `docnorm.query` | 代码块/向量 top-k、文档 BM25/hybrid、`pkg_index` 读取 |
| REST | `lib/src/api.dart` | 新增 prepare/understand/ready/graph.rebuild/normalize/attachments/pack/messages/budget/runs/{id}/queue plan/start 路由 |
| 存储 | `lib/src/store.dart` | `task.update` 白名单写回（保留未知键）、附件复制与哈希、理解缓存、run 读取、保留策略 |
| 记忆 | `tree.agent` / `plugins/tree.production.line/lib/src/memory_port.dart`（新） | agent 侧 `memory.get/record`；产线只做端口适配与三处注入，不读 `.self/memory.md` |
| 事件 | `tree.production.line_plugin.dart` / `lib/src/service.dart` | 注册广播站、状态迁移写点 |
| UI API | `plugins/tree.ui.default/lib/io/api_service.dart` | 新增 prepare/understand/ready/normalize/task update/pack/messages/budget/run detail/start 方法 |
| UI 工作台 | `lib/ui/widgets/production_line_workbench.dart` | 三段式布局、准备阶段、任务看板、右栏详情页、轮询/订阅 |
| UI 配置 | `lib/ui/widgets/create_production_line_dialog.dart` | `limits/policy/docs` 三组 |
| UI 新组件 | `lib/ui/widgets/production_*` | 建议拆：准备面板、**就绪门清单**、**归一化预览**、**理解卡**、右栏任务详情页、事件客户端（避免单文件继续膨胀） |
| 测试 | `plugins/tree.production.line/test/` | 新增 `prepare_api_test`、`understanding_test`（含 10s 检索基准）、`readiness_test`、`normalization_test`、`docs_boundary_test`、`attachment_understanding_test`、`task_update_test`、`attachment_test`、`driver_test`、`events_test` |
| 测试 | `plugins/tree.ui.default/test/` | 扩充 `production_line_panel_test`；新增准备阶段/就绪门/归一化预览/理解卡/详情/事件用例 |

---

## 9. 测试与验收

| 编号 | 判据 |
| --- | --- |
| TC-PL-C01 | 空白产线 → 五栏 → 侦查 → 全部按推荐 → 落档 → 队列出现任务，全程 UI 不离开工作台 |
| TC-PL-C02 | 存在未答问题时「确认并落档」被拒，提示还差哪几题；跨窗口重开后问题原编号保留 |
| TC-PL-C03 | 落档后任务自动开始（或「开始执行」一键起步）；无在途任务时定时 tick 不再永远 `idle` |
| TC-PL-C04 | 手点第一步派发，完成后主控自动 continue 下一批；暂停后不再派发，恢复后继续 |
| TC-PL-C05 | 两个写域交叠任务：手动派发第二个被 409 拒绝；`queue/plan` 的 `skipped` 给出 `with_task` |
| TC-PL-C06 | 任务详情能看到 `pack.json` 摘要、`changed_files`、门控输出、`last_error`、usage |
| TC-PL-C07 | 任务内消息与专家调用在详情里可看；专家超限/默认关闭给出可读原因 |
| TC-PL-C08 | 打包/执行中界面实时更新（推送或轮询）；断线重连后状态与 REST 快照一致 |
| TC-PL-C09 | 产物 `recon/scope/plan/decisions/acceptance/pack` 可在工作台点开，落到文件窗正确作用域 |
| TC-PL-C10 | `limits/policy/docs` 修改后下一任务生效；未知键不丢；非法值保存前拦截 |
| TC-PL-C11 | 终态任务不可编辑；在途任务只能改优先级/依赖；改写域会重算队列计划 |
| TC-PL-C12 | 预算到点软停可见（任务 `blocked` + 原因 + 台账 `budget_exceeded`），不会继续烧 token |
| TC-PL-C13 | 主控连续 3 次决策失败 → 产线 `paused`，UI 显示原因并可恢复 |
| TC-PL-C14 | 缺模型 / 缺 `tree.docnorm` / 缺 `local_executor` 时，准备或执行在入口处给出缺失项，不进入半途 |
| TC-PL-C15 | 真模型 E2E：准备 → 打包 → 执行 → 门控 → done；其中至少一次 ask/answer 闭环 |
| TC-PL-C16 | 任务内容/验收/附件可保存；缺内容或验收不能入队；保存草稿可后补 |
| TC-PL-C17 | 文本附件可读、图片按视觉能力处理、PDF/Office 标不可读；附件越界/超限/改后重打包均符合 §6.0 |
| TC-PL-C18 | 记忆块进准备/打包/执行提示词；`pack.json` 无记忆正文；记忆升级后产线零改动；记忆不可用时任务仍完成并记 `memory_unavailable` |
| TC-PL-C19 | 摘要 + 双查询：LLM #1 无附件也跑；两次 embed 合计 ≤5s；两路查询都贡献并 RRF 去重；单路失败标 `single_query`；检索 P95 ≤10s（不含两次 LLM） |
| TC-PL-C20 | LLM #2 结论均引用存在的 `evidence_id`；无证据项进「未知」；覆盖读数与图谱实际一致；「重新理解」生成新 id、 `reuse_context_id` 不重新摘要/检索 |
| TC-PL-C21 | 前置就绪门：文档归一化/包图/文档图/代码索引/测试映射任一缺失时，理解/建任务/附件/派发/启动/tick 全部 `409 line_not_ready`；补齐后自动放行；HEAD 变化后重新阻塞；无 force 开关 |
| TC-PL-C22 | 归一化预检写入：plan 0 写盘并返回 diff；apply 内容与 diff 一致；重复 apply 0 写盘；失败回滚；rewrite 未授权拒绝；写入期间任务全禁 |
| TC-PL-C23 | 文档维护边界：代码任务越界写 `docs/` 被拒；文档任务只写目标文档且与同文档任务串行；work-log/project-status/known-issues 不被自动修改 |
| TC-PL-C24 | 附件理解：LLM #1 总结文本/图片并产出关键词；关键词进入查询 B；非视觉 `image_manual_reference`；超大/动图/透明/损坏/重复/超量按 §5.2.10；上下文包/日志无 base64 |
| TC-PL-C25 | 关键词质量：摘要输出含 terms/synonyms/entities/files/apis 与附件关键词；空关键词/摘要失败按 `digest_fallback` 或重试，不用原文静默替代 |

---

## 10. 拍板项（建议值）

| # | 问题 | 建议 | 影响 |
| --- | --- | --- | --- |
| P1 | 阶段口径：新能力补齐与「稳定性迭代」冲突 | **已拍板（2026-11-14）：切「快速迭代」**；分两步走——PC-1 先修 §2.3 的 4 条驱动/护栏缺陷，再按 PC-2~PC-8 交付欠交付/新能力 | 已解除开工阻塞 |
| P2 | 准备阶段是否必须 UI 化 | 必须；命令行只留自检/外部调用 | 本期最大工作量 |
| P3 | 定时 tick 是否认 `queued` 任务 | 认；用快照哈希防空转 | 解决首任务起不来 |
| P4 | `finalize` 后自动启动还是显式「开始执行」 | 自动启动 + 保留按钮兜底 | 影响用户心智 |
| P5 | 手动派发是否受依赖/并行/写域硬约束 | 受约束；首版不给 `force` | 安全优先 |
| P6 | git 任务分支隔离（设计 D3）是否本期做 | 建议单列 PC-9，不与 UI 闭环混做 | 影响回退能力 |
| P7 | 任务编辑边界 | 按 §7.3：终态只读、在途只改优先级/依赖、其余可改计划字段 | 防止执行中改范围 |
| P8 | 事件推送与轮询的主从 | 推送优先、3s 轮询兜底 | 实时性与实现成本 |

---

## 11. 风险与回滚

| 风险 | 表现 | 对策 |
| --- | --- | --- |
| 准备阶段 UI 把 20 分钟窗口做成硬倒计时 | 用户被催、草稿丢失 | 只提示不截断；草稿落盘；跨日续答 |
| 自动 tick 过于积极 | 模型调用成本上升 | 快照哈希 + `max_ticks_per_minute` + 连续失败暂停 |
| 事件推送与 REST 快照不一致 | 界面回跳、状态错乱 | seq 单调 + 晚订阅快照对齐 + 轮询兜底 |
| 产物读大文件卡 UI | 打开 pack/门控输出卡死 | 摘要内联、正文按需/磁盘/文件窗；禁止 base64 |
| 手动派发加护栏影响现有习惯 | 用户点不动 | 409 给明确原因与 `queue/plan` 建议；保留「立即决策」自动路径 |
| 任务编辑破坏在途状态 | 执行中改写域 | 按状态分级白名单；改计划字段重算队列 |
| 后端接口扩太多 | 维护成本 | 全部复用现有命令门面，REST 只做参数/形状映射 |

**回滚**：每个 PC 片独立提交；准备阶段 REST/UI 可整体隐藏（入口开关），驱动改动可用
`orchestrator.enabled=false` + 手动派发回退；事件站可停订，轮询兜底不影响功能。

---

## 12. 证据索引

- 准备阶段命令：`plugins/tree.production.line/lib/src/preparation_service.dart:17-27`
- REST 路由表：`plugins/tree.production.line/lib/src/api.dart:64-87`
- 任务 PATCH 只做状态迁移：`lib/src/api.dart:248-265`
- 手动派发无 tick / 无护栏：`lib/src/api.dart:573-650`
- 定时 tick 跳过无在途：`lib/src/orchestrator_service.dart:126-130`
- 事件 tick 仅主控派发接线：`tree.production.line_plugin.dart:247-302`
- 产线状态默认 `idle`：`lib/src/models.dart:261-268`；仅 pause/resume 写状态：`lib/src/api.dart:429-461`
- `limits/policy/docs` 默认段：`lib/src/models.dart:309-329`
- `task.yaml` 字段视图：`lib/src/models.dart:203-234`
- 执行站命令表：`lib/src/execution_service.dart:25-34`
- git status 差集：`lib/src/execution_service.dart:457-463`、`:538-548`
- 设计 D3 分支隔离：`docs/pluginization/production-line-recon.md:818-822`
- 设计 §10.3 广播站：`docs/pluginization/production-line-recon.md:885-893`
- 工作台加载 / 台账 / 产物：`plugins/tree.ui.default/lib/ui/widgets/production_line_workbench.dart:122-162`、`:915-928`、`:1193-1210`
- 新建任务两项：同文件 `:1403-1408`、`:1488-1523`
- 建线弹窗角色与主控：`plugins/tree.ui.default/lib/ui/widgets/create_production_line_dialog.dart:563-660`
- UI API 生产线方法：`plugins/tree.ui.default/lib/io/api_service.dart:1216-1502`
- 产线列表状态展示：`plugins/tree.ui.default/lib/ui/widgets/production_line_panel.dart:304-341`
- O6 待联调：`docs/project-status.md:34`、`docs/work-log.md` 2026-11-12 条目

---

## 13. 完成后需同步的文档

1. [project-status.md](../project-status.md)：新增 PC 车道与当前一步；阶段口径按 P1 更新。
2. [work-log.md](../work-log.md)：每片一行（结论 + 关键数字 + 提交号 + 原文档）。
3. [production-line-recon.md](production-line-recon.md) §10.2：REST 表补 prepare/task update/events。
4. [production-line-orchestrator-loop-plan.md](production-line-orchestrator-loop-plan.md) §3.1 / §5.4：
   定时 tick 条件与产线状态口径按 §6.3 修订。
5. [architecture.md](../architecture.md) §8.1：新增准备阶段/主控提示词资产条目。
6. [docs/README.md](../README.md)：登记本文档。
