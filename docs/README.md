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
| [pluginization/agent-loop-restructure-recon.md](pluginization/agent-loop-restructure-recon.md) | **Agent loop 三线结构侦察与语义对齐（AC-1）**：Agent 实例 / 消息机 / loop 的现状对照、统一信封与直投/排队语义、队列落档、状态机、广播/执行/中转站点面、12 处冲突点与 AC-1~AC-6 切片 |
| [pluginization/production-line-recon.md](pluginization/production-line-recon.md) | **标准开发流生产线侦查与语义对齐**（本期只落档）：与 Agent 同级的三实体（产线/任务/员工）、20 分钟=用户活跃窗口（单题不设时限、未答次日续答、未答不实施）、打包→执行双模型与 `message` 回环、专家工具与工具白名单、模型信息并入模型配置页（左导航 + 右内容）、`docs/production_lines/` 项目资产 + `line.yaml`/`task.yaml`/`runs` 数据模型、P0~P8 切片与 TC-PL-01~14、D1~D10 全部拍板 |
| [pluginization/ui-settings-layout-and-neutral-theme-recon.md](pluginization/ui-settings-layout-and-neutral-theme-recon.md) | **设置页 IDE 式左右布局 + 中性配色 + 右栏自适应宽度侦查**（本期只落档）：设置页 14 节单列表现状、右栏 240~400px 宽度约束、7 个分类与 620/420 响应式断点、深/浅主题中性 token 对照（绿只留 5 类位置、消息流一起中性化）、窗口 `preferredWidth` 只放宽/用户缩过即停、SET-UI-1~4 切片与测试影响 |
| [doc-normalization-recon.md](doc-normalization-recon.md) | **文档归一化 / 包功能收束 / 复用识别**（本期只落档）：TREE 内 headless 插件 `tree.docnorm`，对目标仓库零侵入；`LanguageAdapter` 六方法 + **首批六族适配器（Dart/Python/Go/Rust/Node-TS（含 Vue 3 SFC）/Web-HTTP（OpenAPI、`.http`））**；三层规则源 + `contract` 契约侦查 + 只增不改（索引追加式）+ `DocPolicy`；双额度预算（`context_cap` / `stage_budget`）；建议四类（复用识别本期不上向量化，见 known-issues #45）；L0/L1/L2 单向依赖；GraphRAG 只对文档建图且**本期上 embeddings（默认 hybrid）**；`tree.storage`（Sembast）；安全默认（门禁只列不跑、规则包 pin+sha256、禁网、baseline dry-run）；**模型池按 `chat/embedding/decision` 分类，新增 JEV 决策模型支持（D33）**；**默认维护项目状态与工作日志（D34/DN-11，已有按仓库规范、缺失用内置模板，只追加/回填）**；D1~D34 默认口径、DN-1~DN-11 切片、P1~P8 拍板记录；本仓仅作 dogfood 示例 |
| [pluginization/tree-storage-recon.md](pluginization/tree-storage-recon.md) | **`tree.storage` 插件侦察与落档（ST 系列）**：headless 插件统一集合存储（Sembast、纯 Dart）；每团队 × 每插件一库 `<data_root>/storage/<team_id>/<plugin_id>/data.semdb`；执行站命令族 `storage.*`（ensure/put/get/delete/query/scan/count/tx/export/import/stats/compact/purge）；namespace=调用方 plugin_id + 白名单；单命令事务 + `rev` CAS，不提供长事务；DB 真源、NDJSON 仅快照；ST-1~ST-6 切片与 TC-ST-01~13 |
| [pluginization/model-pool-kinds-recon.md](pluginization/model-pool-kinds-recon.md) | **模型池 kind/protocol 扩展侦察与落档（MP 系列）**：`kind: chat/embedding/decision` + `protocol: openai/jev`，旧模型缺省 chat/openai 且不改文件；embedding 走 `/embeddings`（必填 `dimensions`），JEV 走 typed questions（noul/choice/score，概率+置信度）；选择器按 kind 过滤（Agent/产线打包执行只 chat、docnorm 只 embedding、产线主控可选 decision）；`kind` 创建后不可改；MP-1~MP-7 切片与 TC-MP-01~13 |
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
