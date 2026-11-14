# 生产线功能补齐 Spec（production-line-v1）

## Why

生产线后端已有建线、准备、打包、执行、决策、门控、台账等能力，但产品面仍是空骨架：
准备阶段不可达、任务只有标题、派发后不自动推进、状态恒为 `idle`、台账无法下钻，
更没有项目结构整理、文档归一化、需求逐条门控与防漂移机制。

本 spec 把冻结的产品形态与门控规范落成可实施的一期范围：
用户在 1 分钟内记录并理解需求，按「项目结构整理 → 文档归一化 → 索引 → 计划 → 执行」
推进，仓库级迁移/重构不因语义漂移而返工。

## What Changes

- **L0 就绪门**：项目结构整理成为硬前置；未理干净只允许 `cleanup` 任务；
  文档归一化支持预检写入/回滚；索引就绪后产线才 `ready`。
- **理解**：需求提交后 T+0 落盘，T+60s 出首版理解卡（允许 partial）；
  LLM #1 总结需求与附件关键词，双查询图谱检索（两次 embed ≤5s），
  检索阶段 P95 ≤10s，LLM #2 结论必须带 `evidence_id`。
- **任务输入**：`brief / acceptance / references / attachments` 与
  `task_type / gate / conflicts_with / serial_group` 进入任务模型；
  新增任务 REST 与编辑预检；附件落 `.input`，首版允许只存不读。
- **计划**：计划必须含方案设计、不变量账本、任务 DAG、每任务 `- [ ]` 出口门禁、
  追踪矩阵、风险、变更控制；LLM 起草 → 独立批判 → 修正，最多 3 轮再交用户；
  任务拆分器做尺寸/写域交叠/环/集成任务校验，并计算批次。
- **防漂移**：`REQ-xx` 逐条门控；基线/契约冻结；行为保持与行为改变分开；
  增量迁移；追踪矩阵；每批次漂移哨兵；计划/变更单版本化。
- **执行驱动**：手动派发后触发 tick；定时 tick 认 `queued`；`finalize` 后启动；
  产线状态由后端计算；手动派发同样过依赖/并行/写域护栏。
- **记忆**：直接套 `tree.agent` 记忆，产线只经 `agent.memory.get/record` 消费，
  不复制记忆读写逻辑，不存记忆正文。
- **UI**：今日/准备/执行/工具四入口；任务详情进右栏 `RightPanelHost`；
  就绪/结构/归一化/计划/理解/任务详情都有门控可视与禁用规则。
- **稳定性**：租约 + fencing、幂等、崩溃恢复、独立门控 runner、换模型黄金任务；
  执行者不能自签 `done`。
- **BREAKING**：`production.line.status` 不再由 UI 推断，改由后端投影；
  非 cleanup 任务在 `organizing` 阶段一律 `409 structure_not_ready`。

## Impact

- Affected specs：生产线产品形态 `production-line-product-form.md`、
  门控规范 `production-line-gates.md`、补齐侦查 `production-line-completion-recon.md`。
- Affected code：
  - `plugins/tree.production.line/lib/src/{service,preparation_service,execution_service,orchestrator_service,queue,models,store,audit}.dart`
  - `plugins/tree.agent`（`agent.memory.get/record` 与图像输入）
  - `plugins/tree.ui.default`（生产线工作台、右栏详情、门控/计划/结构页面）
  - `packages/tree_protocol`（路由契约与错误码）
- 数据：`task.yaml` 加法字段，旧任务无需迁移；计划新增 `plans/plan-vN/`；
  结构新增 `structure.json`；归一化新增 `normalization/<runId>/`。

---

## ADDED Requirements

### Requirement: 项目结构整理硬前置

系统 SHALL 在项目结构未通过前禁止开启除 `cleanup` 外的任何任务。

#### Scenario: 结构未通过
- **WHEN** 产线处于 `organizing` 且结构报告存在 high 项
- **THEN** `task.create/task.attach/queue.dispatch/start/tick` 对非 `cleanup` 任务返回
  `409 structure_not_ready`，并带 `missing[]`
- **AND** 仅 `cleanup` 任务可以创建、打包、执行
- **AND** 首屏展示结构报告入口与未通过原因

#### Scenario: 结构通过
- **WHEN** 结构报告 fresh、high=0 或逐项豁免、包职责/API/依赖/重复/规模/文档/TODO 已分类
- **THEN** `structure.ready=true`，产线进入 `normalizing`
- **AND** 豁免必须带 `owner/reason/expires_at`，无全局跳过

### Requirement: 文档归一化与索引就绪门

系统 SHALL 在文档归一化与索引构建完成前禁止开任务，并支持归一化预检写入与回滚。

#### Scenario: 归一化预检
- **WHEN** 用户请求 `production.normalize.plan`
- **THEN** 返回每个文件的 diff、动作、skipped/rejected，0 写盘

#### Scenario: 应用与回滚
- **WHEN** 用户确认 `production.normalize.apply`
- **THEN** 写前记录 `before_sha256`、生成备份/补丁，只追加/索引，不新建
- **AND** 重复 apply 幂等；失败自动回滚；默认不自动 commit
- **AND** 写入期间产线暂停开新任务，完成后重建索引

#### Scenario: 就绪复合门
- **WHEN** LG-01~06 全过且 `graph_version` 固定
- **THEN** `line.ready=true`；否则 `409 line_not_ready`

### Requirement: 1 分钟理解与双查询检索

系统 SHALL 在需求提交后 T+0 落盘任务，T+60s 内给出首版理解卡（允许 partial）。

#### Scenario: 理解流水线
- **WHEN** 用户提交需求与附件
- **THEN** LLM #1 输出 `requirement_summary / keywords / constraints / attachment_summaries / ambiguities`
- **AND** 查询 A 用需求原文、查询 B 用关键词；两次 embed 合计 ≤5s
- **AND** 双查询结果 RRF 合并去重，检索阶段 P95 ≤10s
- **AND** LLM #2 输出理解卡与首轮问题，每条结论带 `evidence_id`
- **AND** 无证据内容进入“未知”，不伪造

#### Scenario: 检索超时
- **WHEN** 检索到 10s 仍未完成
- **THEN** 用已召回部分组包，标 `partial/recall_gap`，仍只调一次 LLM #2
- **AND** UI 分段显示 `摘要 / 检索 / 模型` 耗时

### Requirement: 任务输入与附件

系统 SHALL 支持任务内容、验收、引用与附件，并在派发前预检。

#### Scenario: 创建任务
- **WHEN** 用户填写标题、`brief`、`acceptance`、写域/读域、依赖、优先级、类型与附件
- **THEN** 可保存草稿、加入队列或立即开始
- **AND** `brief/acceptance` 缺失、附件哈希不一致、依赖未满足、写域交叠、并行满时阻止派发并给出原因

#### Scenario: 附件
- **WHEN** 用户上传图片/文档
- **THEN** 文件经分片通道落 `.input/production_lines/<line>/tasks/<task>/attachments/`
- **AND** 登记 `sha256/size/type`，不写入项目资产，不 base64 入包
- **AND** 视觉模型可总结图片；非视觉模型标 `image_manual_reference` 并提示补文字
- **AND** PDF/Office/二进制首版只存不读，登记为 known issue

### Requirement: 计划多轮迭代与任务拆分

系统 SHALL 生成包含 7 块内容的计划，并在给用户审查前完成多轮批判/修正。

#### Scenario: 计划内容
- **WHEN** 进入计划阶段
- **THEN** 计划包含方案设计、不变量账本、任务 DAG、每任务 `- [ ]` 出口门禁、
  追踪矩阵、风险与未知、变更控制
- **AND** 每条 `REQ-xx` 至少映射一个任务与一个门控

#### Scenario: 多轮迭代
- **WHEN** LLM 完成草稿
- **THEN** 独立批判调用输出 findings（high/med/low + 证据 + 建议），修正调用打补丁
- **AND** 最多 3 轮；high 未关闭不落档；用户看到 plan diff 与未解决项

#### Scenario: 任务拆分
- **WHEN** 任务超过 1–5 文件/300 行/1 包，或写域交叠、成环、缺门控、缺集成任务
- **THEN** 校验拒绝或确定性修正；多任务功能必须有 `integration` 任务
- **AND** 批次按硬依赖 + 写域不相交计算

### Requirement: 防语义漂移门控

系统 SHALL 用需求逐条门控、基线/契约冻结、不变量账本、变更分类、增量迁移、
追踪矩阵与批次漂移哨兵防止仓库级迁移/重构漂移。

#### Scenario: 任务出口
- **WHEN** 任务准备标记 `done`
- **THEN** 所有 `- [ ]` 清单已勾选且每项有 evidence
- **AND** `changed_files ⊆ write_scope`，API/schema/权限未越权，回滚演练通过

#### Scenario: 批次出口
- **WHEN** 一批任务完成
- **THEN** 跑 BG-01~08 漂移哨兵：范围/API/schema/golden/依赖图/数据/文档/追踪
- **AND** 任一 fail 停止下一批，任务转 `blocked` 并展示证据

### Requirement: 执行驱动与产线状态

系统 SHALL 让任务从派发到完成自动推进，状态由后端计算。

#### Scenario: 手动派发
- **WHEN** 用户手动派发任务
- **THEN** 先过依赖/并行/写域/预算/就绪门护栏，再打包执行
- **AND** 执行结束后触发下一次 tick

#### Scenario: 定时与恢复
- **WHEN** 定时 tick 触发
- **THEN** 存在 `queued` 或其它可推进任务时正常决策，不再因“无在途任务”跳过
- **WHEN** 准备阶段 `finalize` 完成
- **THEN** 按拍板启动执行；产线状态投影为 `准备中/执行中/空闲/已暂停`

### Requirement: 记忆端口

系统 SHALL 直接复用 `tree.agent` 记忆，产线不维护第二套记忆逻辑。

#### Scenario: 读取与回写
- **WHEN** 准备/打包/执行需要记忆
- **THEN** 调 `agent.memory.get {agent_id,purpose,budget_chars}`，使用返回的 text/sources/hash
- **WHEN** 任务进入终态
- **THEN** 调 `agent.memory.record` 回写摘要，产线不直接写 `.self/memory.md`
- **AND** 记忆不可用时任务继续，台账记 `memory_unavailable`

### Requirement: 工作台与右栏详情

系统 SHALL 提供今日/准备/执行/工具四入口，任务详情在右栏窗口打开。

#### Scenario: 今日
- **WHEN** 用户打开生产线
- **THEN** 首屏只显示待你决定、需要处理、正在跑、刚完成
- **AND** 无悬停才显示次要操作

#### Scenario: 准备与执行
- **WHEN** 用户进入准备
- **THEN** 按需求五栏 → 侦查四块 → 对齐 → 计划落档线性推进
- **AND** 未答问题禁止落档
- **WHEN** 用户打开任务详情
- **THEN** 右栏 `productionTask` 窗口展示概览/计划/打包/门控/消息专家/台账
- **AND** 门控清单逐条可核对，证据可跳转

### Requirement: 稳定性控制面

系统 SHALL 在失败时守住边界，执行者不能自签 `done`。

#### Scenario: 重复与过期
- **WHEN** 重复派发或旧 worker 写入
- **THEN** 同一任务只执行一次；过期 fencing token 写入被拒

#### Scenario: 崩溃恢复与门控防篡改
- **WHEN** 进程被杀/断网/部分写
- **THEN** 恢复不丢不重；执行者改 `gate.json` 或证据被拒
- **AND** 换模型后黄金任务仍通过

### Requirement: 兼容、安全与可访问

系统 SHALL 保持旧任务兼容，并遵守现有路由/权限/租约约束。

#### Scenario: 旧任务
- **WHEN** 读取没有新字段的旧 `task.yaml`
- **THEN** 默认 `task_type=code`、`gate` 用产线默认门控，不迁移、不报错

#### Scenario: 访问控制
- **WHEN** 非授权 scope 调用生产线命令
- **THEN** 按现有四要素校验拒绝，不因新增端点放宽
