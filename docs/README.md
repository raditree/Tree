# 文档索引

入口文档是仓库根目录的 [README.md](../README.md)；规则约束在 [CONTRIBUTING.md](../CONTRIBUTING.md)。

## 活跃文档（跟着代码走）

| 文档 | 内容 |
| --- | --- |
| [project-status.md](project-status.md) | **项目状态（唯一入口）**：当前阶段、阶段模型、并行车道与下一步、维护规则（完成即迁出到 work-log） |
| [work-log.md](work-log.md) | **Work Log（过去式）**：表格形式，按日期倒序；日期 / 事项 / 结论与关键数字 / 提交号 / 原文档 |
| [handover.md](handover.md) | **交接文档**：当前事实与基线数字、已完成提交、环境与门禁、遗留项（P0~P3）、硬约束条例、关键文件地图、待拍板决策 |
| [architecture.md](architecture.md) | 进程模型、核心模块、会话与工具循环、前缀缓存策略、并发、工作空间与私有目录、存储、活性口径、安全边界、**提示词资产索引（改提示词先看 §8.1）**、**跨模块不变量** |
| [development.md](development.md) | 环境、构建、测试矩阵（含门控真机 SSH / 编译产物冒烟）、打包与安装包、调试、发布检查单 |
| [team.md](team.md) | 团队与成员语义：成员即 agent、审核闸门、共享工作目录与私有分栏、SSH 跟随、会话并行、派活与回信、活动日志 |
| [plugin-development.md](plugin-development.md) | 写插件的系统指南：一分钟上手、协议与生命周期、站点与点位（点位由核心与插件申报，数量以 `/api/meta` 为准）、scope 两套含义、执行站命令、流式接管、UI 槽位、调试 |
| [exec_station_contract.md](exec_station_contract.md) | **执行站契约**（L-25）：`station/command` 回包信封的六个键、两个执行站命令表逐条对照（本机 8 / SSH 10 与四处能力差异）、失败来源全清单与错误码表、逐命令幂等标注、八环传递链与门禁设计 |
| [pluginization/scope-de-domainization-recon.md](pluginization/scope-de-domainization-recon.md) | **L-23 `scope` 去领域化侦查**（本期不实现）：wire 消费点、4 类判定点、12 个插件的空 `scope` 声明、C1→C2 方案与 S0~S4 执行序 / 验收判据 |
| [conversation-sembast-and-collapse-recon.md](conversation-sembast-and-collapse-recon.md) | **会话存储 Sembast 化 + 中栏工具折叠侦查与拍板**：显示/详细双 store、seq 排序键、jsonl 一次性迁移、详情端点、N>3 折叠组与 TC-COLLAPSE-01 零位移判据（F1~F4 执行规格） |
| [ssh-tunnel-protocol.md](ssh-tunnel-protocol.md) | **SSH 执行器「中转站」协议**：core ⇄ ssh_executor 插件 ⇄ tree_agent 三层的消息面、错误码、分块帧、版本协商、后台任务落盘台账与 PTY 契约（中转站 =「处理拓展点位」：首选 `ssh.execute` 点位投递、`tunnel.*` 作兼容层） |
| [known-issues.md](known-issues.md) | 已知问题台账（现象 / 根因 / 修复 / 验证 / 遗留），按发现顺序编号 |
| [../CHANGELOG.md](../CHANGELOG.md) | 版本变更记录（自首个开源版本 1.0.0 起） |

各模块的 README（职责 / 入口 / **不变量** / 测试）：
[tree_core](../packages/tree_core/README.md) ·
[tree_protocol](../packages/tree_protocol/README.md) ·
[tree_local_exec](../packages/tree_local_exec/README.md) ·
[tree_core_cli](../packages/tree_core_cli/README.md) ·
[lib（Flutter UI）](../lib/README.md) ·
[插件仓（tree-plugins，本地 clone 在 `plugins/`）](../plugins/README.md)

tree_core 内部的 6 个平台模块（`plugin` / `server` / `settings` / `store` / `util` / `ws`）各自也有 README
（文件清单 + 不变量 + 测试）：见 [tree_core 的模块地图](../packages/tree_core/README.md#模块地图)。
领域模块（agent / 文件 / 执行器）的 README 在插件仓各插件下。

## 归档（历史，不再更新）

服务端线（Python 后端）与更早形态的文档都收在 [archive/](archive/README.md)：M9 的 14 项决策实施记录、
"8 大项改造"的评审 / 方案 / 测试报告、最初的 SSH 设计、team 工具诊断与改造记录、某次运行的团队编制。
**M9 决策的"现在是什么口径"已整合进 [architecture.md §14](architecture.md)**；
**与现行文档冲突时以现行文档为准。**

## 写文档的要求

见 [CONTRIBUTING.md §3 文档制度](../CONTRIBUTING.md)：先说结论再给证据、给路径与符号名、
命令可直接复制、不写个人绝对路径；模块行为改动必须同步该模块 README 的"不变量"节。
新增/移动文档要同步本索引（有门禁测试兜底）。
