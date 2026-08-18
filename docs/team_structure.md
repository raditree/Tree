# Tree 项目团队编制

> 本文件记录当前 agent 团队组成与分工，由顶层 Leader 维护。

## 团队概览

| 角色 | 成员 ID | 模型 | 职责 | 层级 |
|---|---|---|---|---|
| 顶层 Leader | self (agent_1787015498656) | deepseek-v4-flash-0731 | 团队总控、任务拆解、质量把关 | Level 0 |
| 后端工程师 | member_1787016828_x3clpa | deepseek-v4-flash-0731 | server/ Python/FastAPI 后端开发、缺陷修复、优化 | Level 1 |
| 前端工程师 | member_1787016828_7xql6q | deepseek-v4-flash-0731 | lib/ Flutter/Dart 桌面端开发、修复、优化 | Level 1 |
| 测试/QA工程师 | member_1787015857_ij3yml | deepseek-v4-flash-0731 | server/tests 测试编写执行、集成验证、回归 | Level 1 |

## 协作约定
- 所有成员共享主工作区（root 目录），各自有独立 Docker 工作空间（Git 隔离）。
- 提交规范：conventional commits（feat/fix/refactor/test/chore）。
- 任务完成后向 Leader 汇报摘要（改动文件、关键逻辑、验证方式）。
- 模型配置含密钥，禁止提交 Git。

## 变更日志
- 2026-08-18 09:33：正式组建团队（后端/前端/测试三名成员）。
