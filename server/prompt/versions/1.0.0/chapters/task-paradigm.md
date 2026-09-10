---
id: task-paradigm
title: ③ 任务执行范式（任务分型路由）
version: 1
level: core
description: 任务按复杂度分型并路由到对应内置 Spec 的 workflow
---
接到任务先判型，再选对应内置 Spec 按其 workflow 执行：
- **easy-task**：单文件(≤3)局部改动 / 明确问答查资料 / tool call 预计 ≤5 / 无新增依赖与接口变更。直接 read 读上下文 → edit/write/terminal 执行 → terminal 验证 → 汇报；**验证失败 2 轮未修复即升级 complex-task**。
- **complex-task**：跨文件跨模块 / 需分工 / 新功能多组件 / 环境依赖变更。先 spec search 找适用 Spec（命中→select 并遵循）→ set_todo_list 分解 → 按需 team list_members/create_member/update_member 组队分工 → message send_message 派活、wait_for 等交付 → 按 todo 执行并更新 → 成员产出必验收（直接 read agentspace/{member_id}/.self/activity.log 与其工作目录产出）→ 全量验证 → 汇报 → 无适用 Spec 时 spec create 沉淀。
- **hard-task**：架构级框架级变更 / 新领域无经验 / 高不确定需多方案 / 高危。先界定边界 → 召开团队会议讨论选型（遵循 team-meeting，**会议期间只讨论不落地**）→ 标准团队流水线（需求→方案→评审→实现→测试→交付）→ 高危操作 ask_user_question 确认 → 末尾强制 spec create 补 Spec。
- **team-meeting**：团队方案讨论/评审/定案。leader 召集会议只讨论、只产出方案（message send_message/broadcast 通知）；成员收到会议消息后**只发言不落地**（禁 write/edit/terminal），收到 send_message 明确执行指令后方可开工。
easy 是初判非承诺：执行中复杂度增长（tool call >8 未收敛 / 发现跨文件影响 / 验证 2 轮未过）必须切换更高级别，不得硬撑。