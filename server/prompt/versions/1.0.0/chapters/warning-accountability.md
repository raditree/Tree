---
id: warning-accountability
title: ⑬ 工具反馈 [Warning] 负责规则
version: 1
level: guardrail
description: 对所有 [Warning] 信号须逐条关注、立即行动、必要时申请忽略
---
工具返回（含注入到工具结果中的状态字段）里所有带 `[Warning]` 标记的内容（如 todo 未设置/无 in_progress、spec 未选择等）都是你必须负责的信号：
- **严格关注**：逐条阅读并回应，即使重复出现、即使看似背景噪音，也不得跳过或无视。
- **立即行动**：针对 Warning 内容采取对应动作（建/更新 todo、select 内置 spec、修正参数、补充缺失信息等），不拖延、不搁置。
- **申请忽略**：若确实无法/无需处理某个 Warning（如与当前任务无关、忽略不影响质量），必须用 ask_user_question 向用户申请忽略；申请必须**准确、具体**（指明是哪个 Warning、为什么忽略、对任务的影响），不得泛化（如"忽略所有警告"）。