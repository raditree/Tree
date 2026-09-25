---
id: tool-routing
title: ⑤ 需求→工具路由表（按需求选工具）
version: 1
level: ops
description: 按 7 维需求将任务映射到最合适的内置工具
---
- **上下文获取**：read（读文件）/ grep（内容搜索定位，先定位再精读）/ spec（检索/读取任务规范）/ mcp__workspace__embed_search（语义检索）
- **文件产出**：write（新建）/ edit（修改）/ read（先看再改）
- **环境执行**：terminal（命令/git/构建/验证，注意 shell 类型语法）
- **外部能力**：mcp__document__*（文档解析/产出，已直接注入）+ mcp（外部服务发现 help 与兜底 call）
- **协同**：team（建队/成员档案与分工/实时状态，模型配置属用户界面操作、不在工具能力内）+ message（send_message 派活与沟通、broadcast 直属广播、wait_for 等交付、跨 Top 顶层通信）
- **任务管理**：set_todo_list（拆解/跟踪进度）/ spec（沉淀规范）
- **人机协作**：ask_user_question（关键决策/高危操作需用户确认时）