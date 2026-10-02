# 文档索引

入口文档是仓库根目录的 [README.md](../README.md)；规则约束在 [CONTRIBUTING.md](../CONTRIBUTING.md)。

## 活跃文档（跟着代码走）

| 文档 | 内容 |
| --- | --- |
| [architecture.md](architecture.md) | 进程模型、核心模块、会话与工具循环、前缀缓存策略、并发、工作空间与私有目录、存储、活性口径、安全边界、**提示词资产索引（改提示词先看 §8.1）**、**跨模块不变量** |
| [development.md](development.md) | 环境、构建、测试矩阵（含门控真机 SSH / 编译产物冒烟）、打包与安装包、调试、发布检查单 |
| [team.md](team.md) | 团队与成员语义：成员即 agent、审核闸门、共享工作目录与私有分栏、SSH 跟随、会话并行、派活与回信、活动日志 |
| [plugin-development.md](plugin-development.md) | 写插件的系统指南：一分钟上手、协议与生命周期、17 个点位、scope 两套含义、执行站命令、流式接管、UI 槽位、调试 |
| [known-issues.md](known-issues.md) | 已知问题台账（现象 / 根因 / 修复 / 验证 / 遗留），按发现顺序编号 |
| [../CHANGELOG.md](../CHANGELOG.md) | 版本变更记录（自首个开源版本 1.0.0 起） |

各模块的 README（职责 / 入口 / **不变量** / 测试）：
[tree_core](../packages/tree_core/README.md) ·
[tree_protocol](../packages/tree_protocol/README.md) ·
[tree_local_exec](../packages/tree_local_exec/README.md) ·
[tree_core_cli](../packages/tree_core_cli/README.md) ·
[lib（Flutter UI）](../lib/README.md) ·
[examples/plugins](../examples/plugins/README.md)

tree_core 内部的 13 个业务模块各自也有 README（文件清单 + 不变量 + 测试）：
见 [tree_core 的模块地图](../packages/tree_core/README.md#模块地图)。

## 归档（历史，不再更新）

服务端线（Python 后端）与更早形态的文档都收在 [archive/](archive/README.md)：M9 的 14 项决策实施记录、
"8 大项改造"的评审 / 方案 / 测试报告、最初的 SSH 设计、team 工具诊断与改造记录、某次运行的团队编制。
**M9 决策的"现在是什么口径"已整合进 [architecture.md §14](architecture.md)**；
**与现行文档冲突时以现行文档为准。**

## 写文档的要求

见 [CONTRIBUTING.md §3 文档制度](../CONTRIBUTING.md)：先说结论再给证据、给路径与符号名、
命令可直接复制、不写个人绝对路径；模块行为改动必须同步该模块 README 的"不变量"节。
新增/移动文档要同步本索引（有门禁测试兜底）。
