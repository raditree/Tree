# 生产线门控规范（冻结版）

> **状态**：2026-11-14 方案冻结。本期按本文件实施，产品形态见
> [production-line-product-form.md](production-line-product-form.md)，补齐切片见
> [production-line-completion-recon.md](production-line-completion-recon.md)。
>
> 本文件只定义**门控**：谁在什么时机、用什么证据、判定什么；不重复 UI 线框与产品叙事。
> 变更本文件必须新增决策记录（`DEC-xx`），不允许实现时“顺手放宽”。

---

## 0. 三条不可违反的原则

1. **Fail-closed**：门控缺证据、超时、状态不明，一律视为不通过；不把“没查到”当“没问题”。
2. **执行者不能自签**：Agent/执行进程不能写门控结果；门控由独立 runner 跑真实命令并落证据。
3. **没有全局跳过**：只有结构报告 high 项允许**逐项豁免**（owner + 原因 + 到期），
   其余门控不提供 force/skip 参数；UI 也不能传 `ready=true` 覆盖后端判定。

---

## 1. 门控分层

```text
L0 产线就绪门（structure → docnorm → index）
   ↓
L1 计划门（设计/不变量/任务/追踪/出口门禁）
   ↓
L2 任务门（派发前 / 执行中 / 出口）
   ↓
L3 批次门（漂移哨兵 / 集成 / 端到端验收）
   ↓
L4 稳定性门（租约/幂等/恢复/门控防篡改）
   ↓
L5 产品验收门（PS / TC）
```

任一层的 `fail` 都阻断后续层；不允许“先跑起来再补门控”。

---

## 2. 门控结果契约

所有门控统一返回：

```jsonc
{
  "gate": "TG-T1-04",
  "status": "pass|fail|blocked|waived",
  "code": "gate_failed",
  "message": "dart test test/foo_test.dart 失败：2 个用例",
  "missing": ["TG-T1-05", "TG-T1-06"],
  "evidence": [
    {"kind": "command", "path": "tasks/T1/gates/run-03/analyze.log", "sha256": "..."},
    {"kind": "json", "path": "tasks/T1/gates/run-03/result.json", "sha256": "..."}
  ],
  "checked_at": "2026-11-14T10:32:00+08:00"
}
```

- `status=waived` 只允许结构门 high 项，且必须带 `owner/reason/expires_at`。
- `blocked` 表示前置门未过；`fail` 表示门控执行了但没达标。
- 所有 `evidence.path` 相对产线资产目录，写入后只读。

### 2.1 `- [ ]` 勾选语义

本文件所有门控项都以 `- [ ]` 出现；这是逐条核对/确认的唯一格式：

```markdown
- [ ] LG-01 结构报告 fresh，high=0 或逐项豁免
  evidence: structure.json / findings.json / waivers.json
- [x] TG-11 出口清单全部勾选且有 evidence
  evidence: tasks/T1/gates/run-03/gate.json
- [ ] SG-03 杀进程后恢复不丢不重
  waived: owner=user reason=本机无故障注入环境 expires_at=2026-12-31
```

规则：

- **未勾选 = 不通过**，不允许“默认通过”。
- **勾选但没有 `evidence:` = 不通过**；`[x]` 只是人工确认，最终以 gate runner 的 `gate.json` 为准。
- `waived` 只允许结构门 high 项；必须写 owner/原因/到期，到期自动回到未通过。
- 每个门控项都要能定位到 `evidence` 路径；没有证据路径的门控项不得写入计划。
- UI 把 `- [ ]` 渲染成逐行核对表；计划/任务/批次三层都可复制同一份清单。

---

## 3. L0 产线就绪门

### 3.1 阶段顺序

```text
organizing（只允许 cleanup 任务）
→ normalizing（文档归一化）
→ indexing（包图/文档图/代码索引/测试映射）
→ ready（其他任务才可开）
```

### 3.2 门控清单

| ID | 门控 | 通过判据 | 失败码 |
| --- | --- | --- | --- |
| LG-01 | 项目结构 | 结构报告 fresh；high=0 或逐项豁免；包职责覆盖全部包；公共 API 清单冻结；依赖环=0；分层违规=0；重复/大文件/文档缺口/TODO 已分类 | `structure_not_ready` |
| LG-02 | 文档归一化 | `docnorm` 的 `doc_state` 已生成、归一化产物落盘；无文档时 `no_docs` 明确 | `docnorm_not_ready` |
| LG-03 | 包图 | `pkg_index` 就绪且 `stale=false` | `index_not_ready` |
| LG-04 | 文档图 | `graph_*` 与 `doc_state` 指纹一致 | `index_not_ready` |
| LG-05 | 代码索引 | `dedup_chunks/dedup_vectors` 与 `baseline_sha` 一致 | `index_not_ready` |
| LG-06 | 测试映射 | `test/` ↔ `lib/` 映射已生成 | `index_not_ready` |
| LG-07 | 复合就绪 | LG-01~06 全过，且 `graph_version` 固定 | `line_not_ready` |

### 3.3 结构门细则

结构报告 `<line>/structure.json` 至少包含：

```jsonc
{
  "version": 1,
  "generated_at": "...",
  "workspace": "E:/work/project",
  "packages": [
    {"id": "tree_core", "responsibility": "核心路由与站点总线", "entry": "lib/tree_core.dart",
     "public_api": ["CoreServer", "StationBus"], "depends_on": ["tree_protocol"]}
  ],
  "findings": [
    {"id": "F-01", "severity": "high", "kind": "dependency_cycle",
     "targets": ["tree_core", "tree_protocol"], "suggestion": "抽出 shared 包"}
  ],
  "waivers": [
    {"finding_id": "F-07", "owner": "user", "reason": "下期拆分", "expires_at": "2026-12-31"}
  ]
}
```

判定：

- `packages[].responsibility` 不能为空；一个包只能有一个主职责；
- `public_api` 是冻结集合；新增/删除/改签名必须 `DEC-xx`；
- `findings` 中 `high` 必须为 0 或在 `waivers` 中且未过期；
- 报告 `generated_at` 必须晚于最近一次结构相关改动；否则重跑。

### 3.4 organizing 阶段的命令白名单

| 命令 | 非 cleanup 任务 | cleanup 任务 |
| --- | --- | --- |
| `task.create` | `409 structure_not_ready` | 允许 |
| `task.attach` | 拒绝 | 允许 |
| `queue.dispatch` / `start` / `tick` | 拒绝 | 允许 |
| `understand` | 拒绝 | 允许 |
| `audit` / `structure.plan` / `structure.reevaluate` | 允许 | 允许 |

- cleanup 任务必须 `task_type=cleanup`，有写域、门控、验收、回滚；
- cleanup 完成后重新跑结构报告；不通过继续 `organizing`，不允许进入 normalizing。

---

## 4. L1 计划门

### 4.1 计划必须包含 7 块

| 块 | 必须内容 | 失败码 |
| --- | --- | --- |
| 方案设计 | 现状/目标、架构/数据流、迁移策略、兼容窗口、回滚、被否决替代方案 | `plan_design_missing` |
| 不变量账本 | 行为/API/数据/权限/性能/UX 不变量 + 检查 + owner | `plan_invariants_missing` |
| 任务 DAG | `goal/task_type/写域/依赖/冲突/预算/合同` | `plan_tasks_missing` |
| 出口门禁 | 每任务 `- [ ]` 清单，可解析 | `plan_gate_missing` |
| 追踪矩阵 | `REQ → DEC → INV → TASK → GATE → EVIDENCE` | `plan_traceability_gap` |
| 风险与未知 | 高风险、未决问题、需拍板项 | `plan_risk_missing` |
| 变更控制 | plan 版本、变更单模板、回滚点 | `plan_change_control_missing` |

### 4.2 计划门清单

| ID | 门控 | 判据 | 失败码 |
| --- | --- | --- | --- |
| PG-00 | 计划 7 块完整 | 方案设计/不变量账本/任务 DAG/出口门禁/追踪矩阵/风险与未知/变更控制齐全 | `plan_incomplete` |
| PG-01 | 原始需求编号 | 每条需求有 `REQ-xx`，保留原文 | `plan_requirement_missing` |
| PG-02 | 需求→门控 | 每条 `REQ-xx` 至少映射一个任务与一个 `- [ ]` 门控 | `plan_traceability_gap` |
| PG-03 | 依赖图 | 无环；依赖都在本次计划或已存在任务中 | `plan_cycle` / `plan_dependency_missing` |
| PG-04 | 任务尺寸 | 1–5 文件、≤300 改动行、≤1 包；超出需拆分理由 | `plan_task_oversize` |
| PG-05 | 写域交叠 | 同批任务写域不相交；交叠必须串行或拆文件 | `plan_scope_overlap` |
| PG-06 | 任务门控 | 每个任务至少一个可执行门控；空话不算 | `plan_gate_missing` |
| PG-07 | 集成任务 | 多任务功能必须有 `integration` 任务，依赖全部代码任务 | `plan_integration_missing` |
| PG-08 | 契约/不变量变更 | 改 API/schema/权限/UX 必须有 `DEC-xx` 与门禁 | `plan_contract_change_unauthorized` |
| PG-09 | 迁移前置 | 迁移类计划必须先有基线/契约冻结任务 | `plan_baseline_missing` |
| PG-10 | 迭代闭环 | 至少一轮起草→批判→修正；high findings 已关闭或显式未决 | `plan_critic_open_high` |

### 4.3 批判/修正循环

```text
R1 起草 → R2 批判（只出 findings）→ R3 修正（打补丁）
→ 重跑 PG-01~PG-10 → 最多 3 轮 → plan-vN 交用户
```

- 每轮 findings 写 `<line>/plans/plan-vN/findings.json`；
- `high` 未关闭时不能落档；用户可看到“未解决 high”并显式承担，但仍需 `DEC-xx`；
- 修正只能打补丁，不允许整份重写导致已确认内容丢失。

---

## 5. L2 任务门

### 5.1 派发前门（Pre-dispatch）

| ID | 门控 | 判据 | 失败码 |
| --- | --- | --- | --- |
| TG-01 | 输入完整 | `brief` 或 `intake.goal` 非空；`acceptance` ≥1；附件哈希一致 | `task_input_incomplete` |
| TG-02 | 依赖完成 | `depends_on` 全部 `done` 且证据在 | `task_dependency_open` |
| TG-03 | 写域可用 | 不与在途任务写域交叠；租约可获取 | `task_scope_conflict` / `task_lease_conflict` |
| TG-04 | 预算/并行 | 未超 token/时间；并行槽位可用 | `task_budget_exceeded` / `task_parallel_limit` |
| TG-05 | 文档/索引就绪 | LG-07 通过 | `line_not_ready` |
| TG-06 | 结构就绪 | LG-01 通过；非 cleanup 任务不得在 organizing 阶段 | `structure_not_ready` |

### 5.2 执行中门（In-run）

| ID | 门控 | 判据 | 失败码 |
| --- | --- | --- | --- |
| TG-07 | 写域围栏 | 每次写前校验真实路径 ⊆ `write_scope`；越界拒绝 | `task_scope_violation` |
| TG-08 | 租约有效 | 写入带当前 fencing token；过期 token 拒绝 | `task_lease_expired` |
| TG-09 | 预算 | token/时间未超；到点软停 | `task_budget_exceeded` |
| TG-10 | 契约/API | 未授权改公共 API/schema/权限 → 阻断 | `contract_change_unauthorized` |

### 5.3 出口门（Exit）

每个任务必须有一份 `- [ ]` 清单；`done` 只认清单 + 证据。

最低模板：

```markdown
- [ ] `dart analyze` 退出码 0
- [ ] 目标测试全绿
- [ ] 原始需求条目 REQ-xx 对应的验收用例通过
- [ ] golden corpus N/N，输出 diff = 0
- [ ] `git diff --name-only` ⊆ `write_scope`
- [ ] 公共 API diff = 0，或 DEC-xx 已批准
- [ ] schema checksum 未变，或迁移单已批准
- [ ] 依赖图无新增环/分层违规
- [ ] 回滚演练通过
- [ ] 文档更新（如需）已完成
```

| ID | 门控 | 判据 | 失败码 |
| --- | --- | --- | --- |
| TG-11 | 出口清单 | 所有 `- [ ]` 已勾选且每项有 evidence | `task_exit_gate_open` |
| TG-12 | 证据完整 | 命令、退出码、stdout/stderr 哈希、时间戳齐全 | `task_evidence_missing` |
| TG-13 | 无越界 | `changed_files ⊆ write_scope` | `task_scope_violation` |
| TG-14 | 无未授权契约变更 | API/schema/权限/错误码未变或 DEC 已批 | `contract_change_unauthorized` |
| TG-15 | 回滚可用 | 回滚步骤/脚本存在且演练通过 | `task_rollback_missing` |
| TG-16 | 文档一致 | 契约/README/工作日志与代码一致（如任务涉及） | `task_doc_drift` |

### 5.4 证据目录

```text
<line>/tasks/<task>/gates/<runId>/
  gate.json          # 机器结果
  analyze.log
  test.log
  golden.diff
  scope.diff
  api.diff
  schema.sha256
  rollback.log
```

- 所有文件只读；执行者进程不能写 `gate.json`；
- `gate.json` 由独立 gate runner 生成并签名/哈希；
- UI 只展示 runner 结果，不采信 Agent 自述。

---

## 6. L3 批次门（漂移哨兵）

每批任务完成后（进入下一批前）必须跑：

| ID | 哨兵 | 判据 | 失败码 |
| --- | --- | --- | --- |
| BG-01 | 范围漂移 | 本批 `changed_files ⊆ 计划写域并集` | `drift_scope` |
| BG-02 | API 漂移 | 公共 API 集合与冻结清单一致，或 DEC 已批 | `drift_api` |
| BG-03 | Schema 漂移 | schema checksum 与基线一致，或迁移单已批 | `drift_schema` |
| BG-04 | Golden 漂移 | 旧/新输出 diff = 0（或约定容差内） | `drift_behavior` |
| BG-05 | 依赖图漂移 | 无新增环、无分层违规、无跨包私有引用 | `drift_dependency` |
| BG-06 | 数据漂移 | 迁移前后行数/校验和/不变量对账通过 | `drift_data` |
| BG-07 | 文档漂移 | 契约/README/决策记录与代码一致 | `drift_doc` |
| BG-08 | 追踪完整 | 每个 diff 能映射到任务/需求 | `drift_untraceable` |

- 任一哨兵 fail ⇒ 停止派发下一批，任务转 `blocked`，首屏显示原因与证据；
- 不允许“先合并再对账”；对账必须在批次出口前完成。

### 6.1 集成/端到端门

| ID | 门控 | 判据 | 失败码 |
| --- | --- | --- | --- |
| BG-09 | 集成任务 | `integration` 任务完成，依赖全部代码任务 | `integration_missing` |
| BG-10 | 原始验收 | 每条 `REQ-xx` 的验收场景通过 | `acceptance_failed` |
| BG-11 | 回归 | 全量测试 + 关键路径 smoke 通过 | `regression_failed` |
| BG-12 | 性能/兼容 | 性能预算与兼容窗口达标 | `nonfunctional_failed` |

---

## 7. L4 稳定性门

| ID | 门控 | 判据 | 失败码 |
| --- | --- | --- | --- |
| SG-01 | 单执行者 | 同一任务同时只有一个有效租约；重复派发只执行一次 | `duplicate_execution` |
| SG-02 | 幂等 | 重复命令不重复建任务/不重复写 | `idempotency_violation` |
| SG-03 | 崩溃恢复 | 杀进程/断网/部分写后恢复不丢不重 | `recovery_failed` |
| SG-04 | 门控防篡改 | 执行者改 `gate.json`/证据被拒 | `gate_tampered` |
| SG-05 | 换模型回归 | 黄金任务在新模型下仍通过 | `model_swap_regression` |
| SG-06 | 恢复 SLO | 恢复耗时在 SLO 内；blocked/retry 指标可查 | `recovery_slo_missed` |

---

## 8. L5 产品验收门

| ID | 对应 | 判据 |
| --- | --- | --- |
| AG-01 | PS-0 / TC-PL-C19 | 摘要 + 双查询；两次 embed ≤5s；检索 P95 ≤10s |
| AG-02 | PS-10 / TC-PL-C20 | LLM #2 结论均有 `evidence_id`；无证据进未知 |
| AG-03 | PS-11 / TC-PL-C21 | 就绪门未过时开任务全部 409 |
| AG-04 | PS-12 / TC-PL-C22 | 归一化预检写入、幂等、回滚 |
| AG-05 | PS-13 / TC-PL-C23 | 项目文档默认只读；文档任务串行 |
| AG-06 | PS-14 / TC-PL-C24 | 附件摘要/图片边界正确 |
| AG-07 | PS-15 / TC-PL-C26 | 稳定性控制面失败语义 |
| AG-08 | PS-16 / TC-PL-C27 | 任务拆分、批次、计划版本 |
| AG-09 | PS-17/18 / TC-PL-C28 | 计划迭代、追踪矩阵、漂移哨兵 |
| AG-10 | PS-19 / TC-PL-C29 | 项目整理硬前置 |
| AG-11 | TC-PL-C15 | 真模型端到端 |

---

## 9. 错误码归一

| 码 | 含义 | UI 动作 |
| --- | --- | --- |
| `structure_not_ready` | 项目结构未整理 | 打开结构报告；只显示 cleanup 入口 |
| `line_not_ready` | 文档/索引/复合门未过 | 打开就绪清单；禁止开任务 |
| `plan_incomplete` | 计划 7 块/依赖/验收缺失 | 回到计划审阅，定位字段 |
| `plan_traceability_gap` | 需求→门控断链 | 高亮断链行；禁止落档 |
| `plan_cycle` | 依赖成环 | 高亮环；要求拆分/去依赖 |
| `plan_scope_overlap` | 写域交叠 | 串行或拆文件；重算批次 |
| `plan_gate_missing` | 任务无门控 | 补 `- [ ]` 清单 |
| `plan_task_oversize` | 任务超预算 | 拆分建议 |
| `plan_integration_missing` | 缺集成任务 | 自动建议新增 |
| `plan_contract_change_unauthorized` | 契约变更无 DEC | 阻止落档；引导开变更单 |
| `task_scope_violation` | 越界写 | 拒绝写入；任务 blocked |
| `task_lease_expired` | 租约过期 | 拒绝写入；重派发 |
| `gate_failed` | 门控命令失败 | 显示命令/日志；重试或取消 |
| `gate_evidence_missing` | 门控无证据 | 不允许 done |
| `drift_scope/api/schema/behavior/dependency/data/doc` | 批次漂移 | 停下一批；显示 diff 与证据 |
| `duplicate_execution` | 重复执行 | 拒绝第二次 |
| `recovery_failed` | 恢复失败 | 人工介入；保留现场 |
| `gate_tampered` | 门控被改 | 拒绝并告警 |
| `model_swap_regression` | 换模型回归失败 | 回滚模型；黄金任务报告 |

错误响应统一：`{status, code, message, missing[], evidence[]}`。

---

## 10. UI 映射

| 位置 | 展示 | 禁止动作 |
| --- | --- | --- |
| 产线头 | `初始化中/准备中/执行中/空闲/已暂停` + 就绪清单 | 未就绪时禁用开始理解/建任务/派发/启动 |
| 结构整理页 | 包职责/API/依赖环/重复/规模/文档 + 豁免 | high 未修复/未豁免时禁用“完成整理” |
| 计划审阅页 | 7 块、findings、追踪矩阵、`- [ ]` 门禁、批次 | 未过 PG 门时禁用“锁定/落档” |
| 任务详情 | 出口清单、证据、diff、回滚 | 未过 TG 门时禁用“标记完成”（不存在人工 done） |
| 批次出口 | 漂移报告 | 任一哨兵 fail 时禁用下一批派发 |
| 台账 | 每次门控结果/证据/耗时 | 不允许编辑证据 |

---

## 11. 验收映射

| 门控 | 自动化 | 手工/真机 |
| --- | --- | --- |
| LG-01~07 | 单测/契约测试 | 结构报告截图 + 重审 |
| PG-01~10 | 计划单测 + 黄金计划 | 用户审阅 plan diff |
| TG-01~16 | 任务/门控单测 | 任务详情证据 + 回滚演练 |
| BG-01~12 | 漂移哨兵单测 + golden | 迁移批次演练 |
| SG-01~06 | 故障注入脚本 | 杀进程/断网/换模型演练 |
| AG-01~11 | TC-PL-C15/19~29 | 产品场景 PS-0~19 |

---

## 12. 实施切片映射

| 切片 | 覆盖门控 |
| --- | --- |
| PC-2B 就绪门 | LG-02~07 |
| PC-2D 结构整理硬门 | LG-01、TG-06、AG-10 |
| PC-2C 归一化预检写入 | LG-02、AG-04 |
| PC-3E 任务拆分器 | PG-03~07、TG-01 |
| PC-3F 计划迭代与漂移防护 | PG-01~10、BG-01~08 |
| PC-5B/5F | LG-01~07 UI |
| PC-5D/5E | PG-01~10 UI |
| PC-10 稳定性控制面 | SG-01~06 |
| PC-8 真模型 E2E | BG-09~12、AG-01~11 |

---

## 附录 A：全量门控核对清单（复制到计划 / 任务 / 批次）

> 用法：计划阶段复制 L0/L1；每个任务复制 L2；每批复制 L3/L4；验收复制 L5。
> 每项必须有 `evidence:`，否则视为未通过。

### A.1 L0 产线就绪门

```markdown
- [ ] LG-01 结构报告 fresh；high=0 或逐项豁免；包职责覆盖全部包；公共 API 清单冻结；依赖环=0；分层违规=0；重复/大文件/文档缺口/TODO 已分类
  evidence: structure.json / findings.json / waivers.json
- [ ] LG-02 docnorm 的 doc_state 已生成；归一化产物落盘；无文档时 no_docs 明确
  evidence: docnorm/state.json
- [ ] LG-03 pkg_index 就绪且 stale=false
  evidence: graph/pkg_index.json
- [ ] LG-04 graph_* 与 doc_state 指纹一致
  evidence: graph/graph_meta.json
- [ ] LG-05 dedup_chunks/dedup_vectors 与 baseline_sha 一致
  evidence: dedup/index_meta.json
- [ ] LG-06 test/ ↔ lib/ 映射已生成
  evidence: graph/test_map.json
- [ ] LG-07 LG-01~06 全过，且 graph_version 固定
  evidence: line/ready.json
```

### A.2 L1 计划门

```markdown
- [ ] PG-00 方案设计/不变量账本/任务 DAG/出口门禁/追踪矩阵/风险与未知/变更控制 7 块齐全
  evidence: plans/plan-vN/plan.json
- [ ] PG-01 每条原始需求有 REQ-xx，且原文保留
  evidence: plans/plan-vN/requirements.json
- [ ] PG-02 每条 REQ-xx 至少映射一个任务与一个 - [ ] 门控，且门控有 evidence 位
  evidence: plans/plan-vN/traceability.json
- [ ] PG-03 依赖无环；依赖都在本次计划或已存在任务中
  evidence: plans/plan-vN/dag.json
- [ ] PG-04 每任务 1–5 文件、≤300 改动行、≤1 包；超限有拆分理由
  evidence: plans/plan-vN/size.json
- [ ] PG-05 同批任务写域不相交；交叠已串行或拆文件
  evidence: plans/plan-vN/batches.json
- [ ] PG-06 每任务至少一个可执行门控（命令/检查 + 期望）
  evidence: plans/plan-vN/gates/
- [ ] PG-07 多任务功能有 integration 任务，依赖全部代码任务
  evidence: plans/plan-vN/tasks.json
- [ ] PG-08 公共 API/schema/权限/UX 变更均有 DEC-xx 与对应门控
  evidence: decisions/DEC-xx.json
- [ ] PG-09 迁移计划先有基线冻结与契约冻结任务
  evidence: baseline-v1 / contract.md
- [ ] PG-10 至少一轮起草→批判→修正；high findings 已关闭或显式未决
  evidence: plans/plan-vN/findings.json
```

### A.3 L2 任务门（每任务复制一份）

```markdown
- [ ] TG-01 brief 或 intake.goal 非空；acceptance ≥1；附件 sha256 与登记一致
  evidence: tasks/T1/input.json
- [ ] TG-02 depends_on 全部 done 且证据在
  evidence: tasks/T1/deps.json
- [ ] TG-03 写域不与在途任务交叠；租约可获取
  evidence: tasks/T1/lease.json
- [ ] TG-04 未超 token/时间预算；并行槽位可用
  evidence: tasks/T1/budget.json
- [ ] TG-05 LG-07 通过
  evidence: line/ready.json
- [ ] TG-06 LG-01 通过；非 cleanup 任务不在 organizing 阶段
  evidence: line/structure.json
- [ ] TG-07 每次写前 realpath ⊆ write_scope；越界拒绝
  evidence: tasks/T1/gates/run-*/scope.log
- [ ] TG-08 写入带当前 fencing token；过期 token 拒绝
  evidence: tasks/T1/gates/run-*/lease.log
- [ ] TG-09 token/时间未超；到点软停
  evidence: tasks/T1/usage.json
- [ ] TG-10 未授权改公共 API/schema/权限 → 阻断
  evidence: tasks/T1/gates/run-*/api.diff
- [ ] TG-11 出口清单全部勾选，且每项有 evidence
  evidence: tasks/T1/gates/run-*/gate.json
- [ ] TG-12 命令、退出码、stdout/stderr 哈希、时间戳齐全
  evidence: tasks/T1/gates/run-*/
- [ ] TG-13 changed_files ⊆ write_scope
  evidence: tasks/T1/gates/run-*/scope.diff
- [ ] TG-14 公共 API/schema/权限/错误码未变，或 DEC-xx 已批准
  evidence: tasks/T1/gates/run-*/api.diff / schema.sha256
- [ ] TG-15 回滚脚本/步骤存在且演练通过
  evidence: tasks/T1/gates/run-*/rollback.log
- [ ] TG-16 契约/README/工作日志与代码一致（如任务涉及）
  evidence: tasks/T1/gates/run-*/docs.log
```

### A.4 L3 批次门（每批复制一份）

```markdown
- [ ] BG-01 本批 changed_files ⊆ 计划写域并集
  evidence: batches/B1/gates/scope.diff
- [ ] BG-02 公共 API 集合与冻结清单一致，或 DEC-xx 已批
  evidence: batches/B1/gates/api.diff
- [ ] BG-03 schema checksum 与基线一致，或迁移单已批
  evidence: batches/B1/gates/schema.sha256
- [ ] BG-04 golden 输出 diff=0（或约定容差内）
  evidence: batches/B1/gates/golden.diff
- [ ] BG-05 依赖图无新增环、无分层违规、无跨包私有引用
  evidence: batches/B1/gates/dependency.diff
- [ ] BG-06 迁移前后行数/校验和/不变量对账通过
  evidence: batches/B1/gates/data_reconcile.json
- [ ] BG-07 契约/README/决策记录与代码一致
  evidence: batches/B1/gates/doc.diff
- [ ] BG-08 每个 diff 能映射到任务/需求
  evidence: batches/B1/gates/traceability.json
- [ ] BG-09 integration 任务完成，依赖全部代码任务
  evidence: tasks/T-int/gates/run-*/gate.json
- [ ] BG-10 每条 REQ-xx 的验收场景通过
  evidence: batches/B1/gates/acceptance.json
- [ ] BG-11 全量测试 + 关键路径 smoke 通过
  evidence: batches/B1/gates/regression.log
- [ ] BG-12 性能预算与兼容窗口达标
  evidence: batches/B1/gates/nonfunctional.json
```

### A.5 L4 稳定性门

```markdown
- [ ] SG-01 同一任务同时只有一个有效租约；重复派发只执行一次
  evidence: stability/lease_fencing.json
- [ ] SG-02 重复命令不重复建任务/不重复写
  evidence: stability/idempotency.json
- [ ] SG-03 杀进程/断网/部分写后恢复不丢不重
  evidence: stability/recovery.json
- [ ] SG-04 执行者改 gate.json/证据被拒
  evidence: stability/gate_tamper.json
- [ ] SG-05 黄金任务在新模型下通过
  evidence: stability/model_swap.json
- [ ] SG-06 恢复耗时在 SLO 内；blocked/retry 指标可查
  evidence: stability/slo.json
```

### A.6 L5 产品验收门

```markdown
- [ ] AG-01 PS-0 / TC-PL-C19：摘要 + 双查询；两次 embed ≤5s；检索 P95 ≤10s
  evidence: acceptance/AG-01.json
- [ ] AG-02 PS-10 / TC-PL-C20：LLM #2 结论均有 evidence_id；无证据进未知
  evidence: acceptance/AG-02.json
- [ ] AG-03 PS-11 / TC-PL-C21：就绪门未过时开任务全部 409
  evidence: acceptance/AG-03.json
- [ ] AG-04 PS-12 / TC-PL-C22：归一化预检写入、幂等、回滚
  evidence: acceptance/AG-04.json
- [ ] AG-05 PS-13 / TC-PL-C23：项目文档默认只读；文档任务串行
  evidence: acceptance/AG-05.json
- [ ] AG-06 PS-14 / TC-PL-C24：附件摘要/图片边界正确
  evidence: acceptance/AG-06.json
- [ ] AG-07 PS-15 / TC-PL-C26：稳定性控制面失败语义
  evidence: acceptance/AG-07.json
- [ ] AG-08 PS-16 / TC-PL-C27：任务拆分、批次、计划版本
  evidence: acceptance/AG-08.json
- [ ] AG-09 PS-17/18 / TC-PL-C28：计划迭代、追踪矩阵、漂移哨兵
  evidence: acceptance/AG-09.json
- [ ] AG-10 PS-19 / TC-PL-C29：项目整理硬前置
  evidence: acceptance/AG-10.json
- [ ] AG-11 TC-PL-C15：真模型端到端
  evidence: acceptance/AG-11.json
```

---

## 13. 冻结与变更

- 本文件版本 `gates-v1`，冻结日期 2026-11-14。
- 新增/修改门控必须：
  1. 新增 `DEC-xx`，写明原因、影响切片、回滚方式；
  2. 更新本文件与对应 TC；
  3. 不允许实现先放宽、文档后补。
- 本文件不定义具体提示词；提示词只负责“让模型产出可过门控的计划”，不能替代门控。
