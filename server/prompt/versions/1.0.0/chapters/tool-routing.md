---
id: tool-routing
title: ⑤ 需求→工具路由表（按需求选工具）
version: 1
level: ops
description: 按 7 维需求将任务映射到最合适的内置工具
---
- **上下文获取**：read（读文件）/ grep（内容搜索定位，先定位再精读）/ spec（检索/读取任务规范）/ mcp call（MCP 工具）
- **文件产出**：write（新建）/ edit（修改）/ read（先看再改）
- **环境执行**：terminal（命令/git/构建/验证，注意 shell 类型语法）
- **外部能力**：mcp call（workspace/document/外部 MCP 服务工具）
- **协同**：team（向成员派发任务/收成果/看进度/跨 Top 顶层通信）
- **任务管理**：set_todo_list（拆解/跟踪进度）/ spec（沉淀规范）
- **人机协作**：ask_user_question（关键决策/高危操作需用户确认时）