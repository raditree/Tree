# 产线主控完整决策循环（D6-O）交付计划

> 状态：**已实施（O1~O5 落码并过门禁；O6 真模型端到端联调待做）**。
> 实施结果见 [work-log.md](../work-log.md)（2026-11-12「D6-O 主控决策循环落地」）：
> 插件 `tree.production.line 0.9.0`（单测 156 / 自检 117）、UI 工作台主控条（UI 单测 20）。
> 上游拍板：D6「`orchestrator` 保留并接线——先接模型/工具配置 + 准备阶段消费，
> 完整的『继续/重试/询问/停止』决策循环单列切片」（见
> [production-line-stability-recon.md](production-line-stability-recon.md) §5）。
> 本文只定义**执行期**的主控循环；准备阶段（侦查 / 追问 / 拆任务）沿用现有实现。

---

## 1. 范围

**In（本期做）**

1. 执行期单步决策：对一条产线的任务池判断「继续 / 重试 / 询问 / 停止」，并把动作落盘。
2. 询问闭环：主控或员工发起问题 → 任务暂停 → 用户回答 → 任务回队列 → 循环继续。
3. 停止闭环：单任务停止（可恢复）与整线暂停（不再自动派发）。
4. 决策台账：每次决策一条 `runs` 记录（role=`orchestrator`），可回看、可审计。
5. 入口：REST + 工作台 UI（状态、动作、提问回答、暂停/恢复）。

**Out（本期不做）**

- 不改任务图 / 写域 / 验收判据；主控不能新建或删除任务（拆分仍是准备阶段的事）。
- 不新增员工角色；打包 / 执行 / 专家仍按现有 `agent.worker.run`。
- 不做跨产线调度、不做无限自主循环（每 tick 只做**一个**决策）。
- 不做“主控直接改代码”（它只能通过既有 executor 角色落地）。

---

## 2. 现状与缺口（代码事实）

| 能力 | 现状 | 位置 |
| --- | --- | --- |
| 状态机 | `draft → … → queued/packing/packed/running/gating → done/blocked/cancelled`；`blocked → awaiting_user / queued` 已允许 | `plugins/tree.production.line/lib/src/models.dart:21-103` |
| 派发 | `dispatch` 按状态自动选 pack/run，默认后台跑（`accepted:true`），同任务有 in-flight 锁 | `lib/src/api.dart:367-463` |
| 重试 | 仅门控失败：`gating → packed`，次数读 `limits.retries`（默认 2），超限 `blocked` | `lib/src/execution_service.dart:625-662` |
| 预算 | 打包/执行前后累计 usage，到点软停 `blocked`（`budget_exceeded`） | `lib/src/execution_service.dart` 预算段 |
| 任务内询问 | `production.task.message(kind=question)` 只记账；超过 3 条自动 `blocked`，**不暂停、不等回答** | `lib/src/execution_service.dart:882-938` |
| 准备阶段询问 | `production.prepare.answer` 只允许 `aligning / awaiting_user`，答完回 `aligning` | `lib/src/preparation_service.dart:376-422` |
| 主控消费 | 仅准备阶段用 `roles.orchestrator.model_id` 调 recon/scope，并把工具写进提示词 | `lib/src/preparation_service.dart:980-993` |
| 主控工具 | `kRoleDefaultTools['orchestrator'] = [read, grep, message]` | `lib/src/execution_service.dart:33-40` |

**缺口**：没有统一决策点；重试只回退到 `packed` 后需人工再派发；询问不暂停；
“停止”只有 `cancel`（终态）与门控 `blocked` 两种，没有“主控停止、可恢复”；
没有决策台账、没有幂等与并发保护。

---

## 3. 语义定稿

### 3.1 触发时机

| 触发 | 说明 |
| --- | --- |
| 任务终态 / 失败 | 打包或执行的后台 job 结束后，debounce 一次 tick |
| 用户回答运行期问题 | 回答落盘后立即 tick |
| 手动 | `POST /api/production/lines/{id}/orchestrate`（工作台按钮 / 排障） |
| 定时 | 产线有在途任务时每 `tick_interval_seconds`（默认 5s）检查一次；快照没变就**不调模型**；无在途任务不空转；可设 0 关闭 |
| 崩溃恢复 | 插件上线后对有在途任务的产线各 tick 一次（先走现有 `recover`） |

### 3.2 四种动作（每 tick 只做一个决策）

| 动作 | 含义 | 前置硬约束（不满足即降级） | 副作用 | 结果状态 |
| --- | --- | --- | --- | --- |
| `continue` | 继续推进批次 | 预算未超；空闲槽位 > 0；依赖已 done；写域不相交 | 对 `task_ids` 逐条后台 dispatch（pack 或 run） | `queued→packing` / `packed→running` |
| `retry` | 重试失败任务 | 该任务 `attempts < limits.retries`；不是预算停止；不是用户停止 | 重派当前阶段（重打包或重执行） | `packed→packing` 或 `blocked→queued`（见 §3.4） |
| `ask` | 向用户提问 | 同任务提问数 `< orchestrator.max_asks_per_task`（默认 3）；问题非空 | 追加问题到 `inbox.jsonl`；任务 `blocked`（`reason=question_pending`） | `*→blocked` |
| `stop` | 停止 | 终态任务不可停 | 单任务 `blocked`（`reason=orchestrator_stop`）；整线停止则 `line.status=paused` | `blocked` / `paused` |

**优先级**：`stop > ask > retry > continue`。同一 tick 同时命中时只执行优先级最高的一个，
其余在下一 tick 重新判断（避免一个 tick 里状态反复横跳）。

### 3.3 硬护栏（主控只能在这些边界内决策）

1. 不越过 `limits.max_parallel_tasks`、依赖与写域（复用 `queue.dispatch` 的判据）。
2. 不越过 `limits.retries`；预算到点只能 `stop`（或 `ask` 让用户加预算），不能再 `continue/retry`。
3. 每个任务最多问 `max_asks_per_task` 次；超过后只能 `stop`。
4. `line.status=paused` 时**任何动作都不执行**（除手动恢复）。
5. `done / cancelled` 不再决策。
6. 主控只能从 `task.yaml` 读取事实；不允许主控直接改任务字段（除 §3.4 的状态副作用）。

### 3.4 状态与恢复口径

- **询问**：复用 `blocked → awaiting_user / queued` 已允许的边，不新增状态。
  问题落 `inbox.jsonl`（`stage: execute`, `qid`, `status: open`）；任务 `blocked`，
  `blocked_reason=question_pending`。回答后清 `pending_question`，`blocked → queued`，
  由下一次 tick `continue`。
- **停止**：单任务 `blocked`（`orchestrator_stop`）+ `stop_reason`，用户点「恢复」走
  `blocked → queued`；整线停止用既有 `line.status: paused`（`idle/working/paused`，
  `models.dart:232`），恢复后立即 tick。
- **重试**：保留现有门控重试；主控 `retry` 只用于“打包失败 / 执行失败但未到上限”，
  走 `blocked → queued` 再重新打包（执行失败的旧 `packed` 产出不直接复用，避免脏包）。
- **不做隐式重试**：每次重试必须有一条 `runs` 台账（`role=orchestrator`, `action=retry`）。

---

## 4. 数据与配置

### 4.1 `line.yaml.orchestrator`（新增段，浅合并；缺省即默认）

```yaml
orchestrator:
  enabled: true            # false = 只保留手动派发
  tick_interval_seconds: 5 # 有在途任务时的定时；0 = 只靠事件
  auto_retry: true
  max_asks_per_task: 3
  stop_on_budget: true
  max_ticks_per_minute: 12 # 防抖 / 防模型空转（超限直接跳过本 tick）
```

> 模型与工具仍取 `roles.orchestrator.model_id / tools`，不重复配置。

### 4.2 `task.yaml.loop`（新增键，写回不丢未知键）

```yaml
loop:
  attempts: 0              # 主控重试次数（与 gate_attempts 分开计）
  ask_count: 0
  last_action: continue    # continue / retry / ask / stop
  last_decision_at: '...'
  stop_reason: ''
  pending_question: ''     # qid；非空 = 等回答
```

### 4.3 台账

- 每次决策写 `runs/<run_id>.json`：`role=orchestrator`、`action`、`reason`、`task_ids`、
  `model_id`、`usage`、`snapshot_hash`、`applied`（护栏降级时 `false` + `guard`）。
- `state.json` 增加 `orchestrator: {last_tick_at, last_action, consecutive_failures}`；
  该文件仍是可重建索引，`task.yaml` 继续是唯一真值。

---

## 5. 决策协议

### 5.1 输入快照（插件组装，不交给模型自己查）

```json
{
  "line": {"id": "...", "status": "working", "limits": {...}},
  "budget": {"exceeded": false, "used_tokens": 0},
  "tasks": [{"id": "T1", "status": "queued", "depends_on": [], "write_scope": ["lib/a"], "attempts": 0, "ask_count": 0}],
  "last_run": {"task_id": "T1", "role": "executor", "status": "failed", "error": "..."},
  "pending_question": {"task_id": "", "qid": ""},
  "available_slots": 1
}
```

### 5.2 输出契约（严格 JSON，代码围栏一律视为非法）

```json
{
  "action": "continue",
  "reason": "一句话",
  "task_ids": ["T1"],
  "stage": "auto",
  "question": {"text": "", "options": [], "default": ""},
  "stop_scope": "task"
}
```

- 只接受 `continue / retry / ask / stop`；未知动作、缺 `reason`、`task_ids` 不在池内 ⇒
  整条作废（不落状态），记 `runs` 失败 + `state.orchestrator.consecutive_failures += 1`。
- 连续 3 次失败 ⇒ `line.status=paused`，等人工恢复（防止坏配置无限烧 token）。
- 模型缺失 / `llm.call` 失败 ⇒ 同一失败路径；**不降级成“自动继续”**。
- 调用走 `llm.call` 的显式 `model_id`（D5），因此没有 Agent 也能运行；用量记账。

### 5.3 提示词口径

系统提示词固定四段：角色（产线主控）、事实（快照）、边界（§3.3 硬护栏）、输出契约。
用户提示词只给快照 JSON 与“上一条决策及结果”（避免同一动作反复触发）。
提示词资产登记到 `architecture.md` §8.1 的提示词索引。

### 5.4 tick 是什么（不是会话轮次）

一次 **tick = 一个短事务**：读一条产线的状态 → 让主控做一个动作 → 落盘 → 返回。
它不是“和模型聊一轮”，也不等打包/执行跑完（长任务仍走后台 job）。

- **事件驱动为主**：任务终态/失败、用户回答、手动按钮各触发一次 tick。
- **定时只是兜底**：防止“某个事件丢了导致产线停住”；有在途任务才检查，
  且快照哈希与上次相同就**跳过模型调用**（只花一次本地读盘）。
- **单线串行、全局并发**：同一条产线同时最多一个 tick，不同产线可并行；
  1s 内多次事件合并，`max_ticks_per_minute` 是硬上限。
- **可关**：`tick_interval_seconds: 0` + `enabled: false` 就退回纯手动派发。

### 5.5 上下文怎么办（无状态决策）

主控**不维护对话历史**，每次决策只看三类有界输入：

1. **事实真源**：`task.yaml` / `runs` / `inbox.jsonl`（不是聊天记录）。
2. **结构化快照**（§5.1）：任务状态、依赖、写域、attempts/ask_count、预算、
   `last_run`（角色 / 状态 / 错误摘要 ≤ 300 字）、`last_decision`（上一条动作与是否生效）。
3. **只读项目摘要**：需要“项目知识”时，把 `docs.memory_manifest` 里的文档摘要
   （由准备阶段同一套读取预算裁剪）放进快照；默认不塞全量文档。

为什么不让它带上下文：

- 状态机的事实都在磁盘上，**快照比对话更准**（对话可能过期、被截断）；
- 每次输入有界，成本可预测，也便于单测（给同一快照必得同一类动作）；
- 多轮语义已经落在字段里：问了几次看 `ask_count`，重试几次看 `attempts`，
  上一条动作看 `last_decision`——不需要模型“记得”。

### 5.6 主控工具：本期不参与决策（也不做 tool-calling）

**结论：执行期主控没有工具循环。** `roles.orchestrator.tools` 不是决策输入，tick 也不读它。

- 它现在只有一处真实用途：准备阶段把“主控可用工具”写进侦查提示词（D6 已接），
  用于约束规划落点，不是让模型调工具。
- 执行期的四种动作完全由**快照 + 硬护栏**决定；给主控 `read/grep` 也没有执行入口。
- UI 处理：主控角色卡的工具 chips 标注「仅准备阶段参考，不参与执行决策」；
  不建议让用户误以为主控会自己查代码。若后续确认完全无用，直接从主控卡移除。
- 以后若真要“主控自己 read/grep 再决策”，主控就不再是无状态 tick，而是一个
  **有状态 agent（多轮工具循环 + 上下文压缩 + 独立预算）**；那是另一种运行模式
  （例如 `orchestrator.mode: agent`），不能和本期的单步 JSON 决策混在一起。

单次调用也不依赖 KV cache 命中（每次提示词很短，且快照会变）。

---

## 6. 执行、并发与幂等

1. **单线单 tick**：`Map<lineId, Future>` 进程内锁；已有 tick 在跑时新触发直接丢弃
   （不是排队，避免风暴）。
2. **决策后立即落盘**：先写 `runs`（`applied=false`）→ 应用副作用 → 回填 `applied`；
   崩溃时最多多一条“已决策未执行”，下次 tick 重新判断（幂等）。
3. **dispatch 沿用现有 in-flight 锁**；tick 不直接 await 长任务，只发起后台 job。
4. **防抖**：同一产线 1s 内多次事件合并为一次 tick；`max_ticks_per_minute` 为硬上限。
5. **REST 30s 截止**：`orchestrate` 只做一次决策并立即返回（`accepted` 或 `noop`），
   不等待打包/执行完成。

---

## 7. 接口与 UI

### 7.1 执行站 / REST

| 类型 | 接口 | 说明 |
| --- | --- | --- |
| 命令 | `production.orchestrator.tick` | 手动推进一次（幂等） |
| 命令 | `production.orchestrator.status` | 最近决策 / 连续失败 / 暂停原因 |
| 命令 | `production.task.question` | 员工或主控发起运行期问题（`stage=execute`） |
| 命令 | `production.task.answer` | 回答运行期问题 → `blocked → queued` |
| REST | `POST /api/production/lines/{id}/orchestrate` | 手动 tick |
| REST | `POST /api/production/lines/{id}/pause` / `resume` | 整线暂停/恢复（写 `line.status`） |
| REST | `POST /api/production/lines/{id}/tasks/{taskId}/answer` | 回答运行期问题 |
| REST | `GET /api/production/lines/{id}/orchestrator` | 状态 + 最近动作（读 `runs`） |

### 7.2 UI（`ProductionLineWorkbench`）

1. 顶部主控条：`enabled` / 当前动作 / 连续失败 / 「暂停」「恢复」「立即决策」。
2. 决策收件箱区分 `prepare` 与 `execute` 两类问题；运行期问题给回答框 + 选项。
3. 任务卡展示 `loop.attempts / ask_count / stop_reason`；`blocked` 任务给「恢复」。
4. 运行台账增加 `orchestrator` 行（动作、理由、被护栏降级的原因）。

---

## 8. 交付切片与门禁

| 切片 | 内容 | 门禁 |
| --- | --- | --- |
| **O1 数据与纯逻辑** | `line.yaml.orchestrator` 默认合并；`task.yaml.loop`；快照组装；动作校验（§3.3/§5.2）纯函数 | `dart analyze` 0；store/models 单测：默认值、旧文件兼容、动作校验真值表 |
| **O2 运行期询问闭环** | `task.question/answer`；`blocked` + `pending_question`；回答回 `queued`；REST + UI 收件箱 | 单测：问 → blocked → 答 → queued；超上限只 stop；UI 回答用例 |
| **O3 决策 tick（继续/停止）** | `orchestrator.tick`；单线锁、幂等、台账；continue 批次派发；stop 单任务/整线 | 单测：continue 不越并行/依赖/写域；stop 可恢复；重复 tick 0 副作用 |
| **O4 重试与预算** | `retry` 上限、打包/执行失败重试、预算到点只能 stop；连续失败暂停 | 单测：重试次数边界、预算停止、连续 3 次失败暂停 |
| **O5 驱动与 UI** | 事件 debounce + 定时 + 崩溃恢复 tick；工作台主控条与台账行 | UI 单测 + 插件单测；`--selftest` 增决策场景 |
| **O6 联调与文档** | 真模型一次端到端（准备 → 打包 → 执行 → 决策 → ask/answer → done）；文档/提示词索引/工作日志 | production.line analyze 0 + 单测 + 自检；UI analyze 0 + 受影响用例；docs_contract |

> 每个切片独立可回滚：O1 只加字段；O2/O3 新命令不动旧命令语义；O4 只在护栏内改
> 派发选择；O5 定时器可用 `enabled=false` / `tick_interval_seconds=0` 关闭。

### 8.1 涉及文件与改动点（实施导航）

| 层 | 文件 | 改动 |
| --- | --- | --- |
| 数据/模型 | `plugins/tree.production.line/lib/src/models.dart` | `buildLineMap` 增 `orchestrator` 默认段；`TaskRecord` 增 `loop` 只读视图；`kTaskTransitions` 按 §3.4 复核（不新增状态） |
| 存储 | `lib/src/store.dart` | `task.loop` 读写助手；`runs(role=orchestrator)`；`line.status` 暂停/恢复；`state.json.orchestrator` 游标 |
| 决策纯逻辑（新） | `lib/src/orchestrator.dart` | 快照组装、动作 JSON 解析与校验（§5.2）、护栏优先级（§3.3）、提示词 |
| 决策服务（新） | `lib/src/orchestrator_service.dart` | tick、单线锁、debounce、`max_ticks_per_minute`、连续失败暂停、台账 |
| 执行 | `lib/src/execution_service.dart` | 运行期 `question/answer`；打包/执行失败写 `loop.attempts`；job 结束回调 tick |
| 命令/路由 | `lib/src/service.dart` / `lib/src/api.dart` | `production.orchestrator.tick|status`、`production.task.question|answer`；REST §7.1 |
| 插件入口 | `tree.production.line_plugin.dart` | 接线 decision LLM（`llm.call` + `model_id`）、事件钩子、定时器、崩溃恢复 tick |
| UI | `plugins/tree.ui.default/lib/ui/widgets/production_line_workbench.dart` | 主控条（暂停/恢复/立即决策）、运行期问题回答、`orchestrator` 台账行、任务卡 loop 字段 |
| UI 配置 | `.../create_production_line_dialog.dart` | `orchestrator` 段（enabled/tick/auto_retry/max_asks/stop_on_budget）；主控工具 chips 标注「仅准备阶段参考」或移除 |
| 测试 | `plugins/tree.production.line/test/` | 新增 `orchestrator_test.dart`（纯逻辑真值表）、`orchestrator_service_test.dart`（tick 闭环）；扩充 `api_test.dart` / `execution_service_test.dart`；UI 扩充 `production_line_panel_test.dart` |

> 建议开工顺序：O1（纯逻辑 + 单测）→ O2（问答闭环）→ O3（tick continue/stop）→
> O4（retry/budget）→ O5（驱动/UI）→ O6（真模型联调）。每片先跑 `dart analyze`
> 与对应单测，再进下一片。

---

## 9. 验收清单（用户可见）

1. 新建任务 → 主控自动 `continue` 打包、执行、门控，无需手点；任务进 `done`。
2. 门控失败 1 次 → 自动 `retry`；重试超限 → `blocked` 并在台账说明原因。
3. 主控判断信息不足 → 任务 `blocked` + 收件箱出现运行期问题；回答后自动回队列并继续。
4. 预算到点 → 停在该任务，台账写 `budget_exceeded`；不会继续烧 token。
5. 工作台「暂停」后不再自动派发；「恢复」后继续。
6. 同一条产线并发触发两次 tick：只有一次生效，另一次被丢弃。
7. 主控模型未配置 / 调用失败：产线停下并给出可读原因，不静默继续。

---

## 10. 风险与回滚

| 风险 | 缓解 |
| --- | --- |
| 模型决策抖动导致反复重试 | 优先级 + 次数上限 + 连续失败暂停 + 每次决策落台账 |
| 与用户手动派发冲突 | 单线 tick 锁 + dispatch in-flight 锁；手动动作优先，tick 看到状态已变就重新判断 |
| 30s 委派超时 | tick 只做一次决策并立即返回，长任务继续走后台 job |
| 旧产线文件无新键 | 全部默认值 + 浅合并，不批量改写文件 |
| 成本失控 | `max_ticks_per_minute`、`max_asks_per_task`、预算软停、`enabled=false` 总开关 |

**回滚**：`orchestrator.enabled=false` 即回到现在的“手动派发”；新增字段与台账不影响
旧读取路径。

---

## 11. 本期默认口径（如需调整请直接指出）

1. 询问复用 `blocked`，不新增任务状态；整线停止复用 `line.status=paused`。
2. 主控停止的任务可恢复（`blocked → queued`）；`cancelled` 仍是用户显式取消。
3. 定时 tick 默认 5s、仅在途任务时运行；`enabled` 默认 `true`（用户可在产线配置关闭）。
4. 重试只重做“当前阶段”，不复用旧 `pack.json`；每次重试都记台账。
5. 主控工具在执行期不参与决策；主控卡 chips 本期**建议直接移除**（若保留则标注
   「仅准备阶段参考」），`roles.orchestrator.tools` 字段与准备阶段提示词不动。
