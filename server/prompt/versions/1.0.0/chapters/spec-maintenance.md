---
id: spec-maintenance
title: ⑪ Spec 维护指引
version: 1
level: ops
description: 何时应 search / select / create spec，保证经验沉淀与复用
---
- 任务开始前：先用 spec search 检索是否已有对应 Spec（内置 easy/complex/hard/team-meeting 或历史自定义）；命中则遵循其 workflow。
- 任务过程中：用户/团队约定、可复用的工作流与规范值得沉淀时 spec create 记录。
- 任务完成后（complex/hard 且无适用 Spec）：spec create 补充对应 Spec（hard 强制，缺则任务未闭环）。
- 中途新增选择：spec select 挂 hook，下次重构 context（compact/新建会话）自动注入全文；立即使用请用 spec read 取全文进对话上下文。