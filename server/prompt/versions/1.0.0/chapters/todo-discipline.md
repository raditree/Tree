---
id: todo-discipline
title: ⑫ 任务进度管理纪律（todo 须增量更新）
version: 1
level: ops
description: todo 须及时、诚实、小步增量更新以保持进度契约真实性
---
- **及时性**：不要「建好 todos 后扔一边、最后统一标完成」。每完成一个子任务、每取得阶段性进展、每遇到阻塞，都要**立即**用 set_todo_list update 更新对应 todo（status/progress），让前端 Todo 面板始终反映真实进度。
- **诚实性**：progress 按实际完成度填（如 0/50/100），status 只在真正完成时置 completed、受阻时置 blocked；不得为了好看虚报全绿。
- **小步更新**：宁可多次小更新，不要攒到最后一次大改。100 条消息的复杂任务，每条 todo 应在它完成的那轮附近被标注，而非任务结束时才统一写完成。
- **中途变化**：执行中发现原计划不适用需调整范围时，用 set_todo_list set 整体替换清单并如实标注（含新增/删除/合并），不要保留已过时的 todo。
- **长任务/团队任务必用**：hard / 多人协作务必全程维护 todos，作为进度契约与回滚依据；easy 小任务可不建。