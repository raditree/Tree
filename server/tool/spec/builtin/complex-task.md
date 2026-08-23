---
id: complex-task
title: 复杂任务（团队协作完成）
task_type: complex
description: 跨文件跨模块 / 需分工 / 新功能多组件 / 环境依赖变更的复杂任务，检索 Spec 后召集团队协作完成
when:
  - 跨文件、跨模块改动
  - 需要分工协作
  - 新功能涉及多组件
  - 环境依赖变更
  - 用户说"开发功能 / 重构 / 多步任务"
tags: [complex, 团队, 多模块, 新功能, 重构]
pinned: true
builtin: true
created_at: 0
updated_at: 0
version: 1
classification: 内部规范
risk: medium
changelog:
  - version: 1
    date: 2026-08-23
    changes: ["初版：纳入版本化提示词体系，补充版本与审计元数据"]
---

## 工作流（workflow）

1. **检索 Spec**：用 `spec search` 找适用自定义 Spec。
   - 命中 → `spec select` 挂 hook 并遵循其工作流执行。
   - 未命中 → 走下方通用流程，完成后 `spec create` 沉淀新 Spec。
2. **任务分解**：调用 `SetTodoList` 将任务拆成可独立验证的 todo 项（每项有明确完成判据）。
3. **团队分工**：按可并行度指派成员。
   - 可并行 / 需不同技能 → `team update_member` 给成员设置职责与分工后 `team assign_task` 指派。
   - 强耦合 / 需串行 → 自行逐步执行（不强行拆给团队）。
4. **按 todo 执行**：每项按 `ReadFile` → `WriteFile`/`EditFile`/`Terminal` → 验证 的循环完成，完成一项更新一项 todo。
5. **全量验证**：所有 todo 完成后整体验证（构建 + 测试 + 关键路径）。
6. **汇报**：向用户汇报完成内容、验证结果、遗留事项。
7. **沉淀**：本次任务若无适用 Spec，`spec create` 创建新 Spec 供下次复用。

## 该类任务规范

- **todo 必建且全程跟踪**：开始即 SetTodoList，过程中每完成一项更新进度。
- **先检索 Spec 再执行**：开工前必须 `spec search`，不盲目直接动手。
- **分工明确再指派**：用 `team update_member` 给成员设好职责/分工后再 `assign_task`；`assign_task` 必须包含：目标、输入、验收标准、产出物。
- **激活成员数量适中**：1-3 个成员为宜（成员已预建，按需激活，勿全员开工）。
- **并行避免同文件冲突**：按模块/目录拆分并行任务，同一文件不同成员同时写会产生冲突。
- 高风险操作（删除、覆盖、破坏性变更）用 `AskUserQuestion` 先与用户确认。

## 注意事项

- 若执行中发现架构级影响、方案分歧大、多方案需评审——**升级 hard-task**。
- 成员任务完成后必须验证其产出（`team view_member_output` / `view_member_log` 或直接读产物文件），不能直接采信。
- todo 状态以 `.self/todos.md` 为准，勿在对话中口头跟踪。
- 若任务中途发现其实很简单（单文件即可），可降级回 easy-task 直接完成。
