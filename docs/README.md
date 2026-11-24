# 文档索引

入口文档是仓库根目录的 [README.md](../README.md)；规则约束在 [CONTRIBUTING.md](../CONTRIBUTING.md)。

## 活跃文档（跟着代码走）

| 文档 | 内容 |
| --- | --- |
| [project-status.md](project-status.md) | **项目状态（唯一入口）**：当前阶段、阶段模型、并行车道与下一步、维护规则（完成即迁出到 work-log） |
| [work-log.md](work-log.md) | **Work Log（过去式）**：表格形式，按日期倒序；日期 / 事项 / 结论与关键数字 / 提交号 / 原文档 |
| [plugin-platform.md](plugin-platform.md) | **插件平台硬约束与决策记录**：22 条硬约束条例（核心/插件/UI）、D-1~D-11 拍板记录、关键文件地图、门禁顺序与常见坑、接手第一小时（2026-11-11 迁自 handover.md） |
| [architecture.md](architecture.md) | 进程模型、核心模块、会话与工具循环、前缀缓存策略、并发、工作空间与私有目录、存储、活性口径、安全边界、**提示词资产索引（改提示词先看 §8.1）**、**跨模块不变量** |
| [development.md](development.md) | 环境、构建、测试矩阵（含门控真机 SSH / 编译产物冒烟）、打包与安装包、调试、发布检查单 |
| [team.md](team.md) | 团队与成员语义：成员即 agent、审核闸门、共享工作目录与私有分栏、SSH 跟随、会话并行、派活与回信、活动日志 |
| [plugin-development.md](plugin-development.md) | 写插件的系统指南：一分钟上手、协议与生命周期、站点与点位（点位由核心与插件申报，数量以 `/api/meta` 为准）、scope 两套含义、执行站命令、流式接管、UI 槽位、调试 |
| [exec_station_contract.md](exec_station_contract.md) | **执行站契约**（L-25）：`station/command` 回包信封的六个键、两个执行站命令表逐条对照（本机 8 / SSH 10 与四处能力差异）、失败来源全清单与错误码表、逐命令幂等标注、八环传递链与门禁设计 |
| [pluginization/ui-station-identity-root-fix.md](pluginization/ui-station-identity-root-fix.md) | **UI 站点身份「可晚到」与订阅回执（协议 1.1 根治）**：`ui.hello` 从“前置条件”降级为“身份声明”，身份前到达的 `station/*` 请求有界挂起、hello 后按序补放；新增 `station_ack` 回执与 9 个稳定错误码（`identity_required` / `station_not_found` / `not_broadcast` …）；客户端按码退避重订、`closed` 后恢复；P1~P4 切片、兼容矩阵与风险边界 |
| [pluginization/feishu-remote-control-ui-recon.md](pluginization/feishu-remote-control-ui-recon.md) | **飞书远程控制 UI 插件侦查（FEISHU-REMOTE）**：`runtime: ui` + 声明 `plugin.manage` + 无主窗口悬浮球；核心零改动可承载；飞书接入内置 Go sidecar（官方长连接 + RFC 8628 扫码建应用）；最小插件管理封装仅做 UI 类启停 + 引导页逃生口；不做 agent 配置（避免双实现）；默认只发最终消息、提问必推、60s 单消息保活原地更新；D1~D8 已拍板、S1~S5 切片与 TC-FR-01~14 |
| [pluginization/scope-de-domainization-recon.md](pluginization/scope-de-domainization-recon.md) | **L-23 `scope` 去领域化侦查**（本期不实现）：wire 消费点、4 类判定点、12 个插件的空 `scope` 声明、C1→C2 方案与 S0~S4 执行序 / 验收判据 |
| [pluginization/agent-memory-recon.md](pluginization/agent-memory-recon.md) | **记忆与上下文治理侦察（AGENT-MEM，本期只落档）**：现有 memory.md 与 `agent.memory.*` 执行站命令现状、系统提示词按会话钉住与"来源变了不重建"断言、**文档与代码偏差（基础段 provider 无生产接线）**、可复用能力（llm.embed / llm.call / Sembast）、数据根与 UI/契约接线点、8 条结论、未知项与风险、D1~D4 拍板 |
| [pluginization/agent-memory-upgrade-plan.md](pluginization/agent-memory-upgrade-plan.md) | **记忆与上下文治理方案（AGENT-MEM）**：L0~L4 五层模型（显式长期 / 异步滚动摘要 / 会话记忆 / 共享记忆 / 归档）、四维 score 公式、记忆条目 schema 与 L3 overview、数据根 `<dataRoot>/memory/<agent_id>/` 结构化存储 + 旧文件迁移、异步管道（摘要→向量→提取→去重→修正→衰减）与降级、`memory` 工具、快照段注入 + 只读查看器、9 条 REST 委派、agent 配置页 4 tab、M1~M5 切片与测试矩阵 |
| [pluginization/agent-loop-restructure-recon.md](pluginization/agent-loop-restructure-recon.md) | **Agent loop 三线结构侦察与语义对齐（AC-1）**：Agent 实例 / 消息机 / loop 的现状对照、统一信封与直投/排队语义、队列落档、状态机、广播/执行/中转站点面、12 处冲突点与 AC-1~AC-6 切片 |
| [pluginization/production-line-recon.md](pluginization/production-line-recon.md) | **标准开发流生产线侦查与语义对齐**（本期只落档）：与 Agent 同级的三实体（产线/任务/员工）、20 分钟=用户活跃窗口（单题不设时限、未答次日续答、未答不实施）、打包→执行双模型与 `message` 回环、专家工具与工具白名单、模型信息并入模型配置页（左导航 + 右内容）、`docs/production_lines/` 项目资产 + `line.yaml`/`task.yaml`/`runs` 数据模型、P0~P8 切片与 TC-PL-01~14、D1~D10 全部拍板 |
| [pluginization/production-line-stability-recon.md](pluginization/production-line-stability-recon.md) | **生产线稳定性侦查（STAB-PL-1~9）**：9 张现场截图的逐项根因与代码证据——建任务缺 `id`（P0）、空写域语义冲突、`lfm3` 无中生有、空 Agent 模型页 404、选产线后文件窗空态、执行工具未按角色拆分、选中行无圆角、模型池以 `model_id` 去重导致多端点不能并存、思考档位用兜底值冒充端点声明；含契约分裂/测试盲区/兜底持久化/一字段三身份等横向问题、执行顺序与 D1~D8 待拍板项 |
| [pluginization/production-line-orchestrator-loop-plan.md](pluginization/production-line-orchestrator-loop-plan.md) | **产线主控完整决策循环（D6-O）交付计划**：执行期「继续 / 重试 / 询问 / 停止」四动作、触发时机与优先级、硬护栏（并行/依赖/写域/重试/预算/提问上限）、`line.yaml.orchestrator` 与 `task.yaml.loop` 数据口径、决策 JSON 契约与失败暂停、单线 tick 锁与幂等、REST/UI 入口、O1~O6 切片与验收清单 |
| [pluginization/production-line-completion-recon.md](pluginization/production-line-completion-recon.md) | **生产线功能补齐侦查（PL-COMPLETE）**：后端 P1~P8/D6-O 已落码但产品面仍是骨架的证据链——准备阶段无 REST/UI、任务只有标题+写域、详情/台账/产物不可下钻、手动派发与定时 tick 驱动断链、无实时状态、`limits/policy/docs` 无配置面、手动派发绕过硬护栏、git 分支隔离与 O6 未做；给出三段式工作台形态、REST/事件/驱动/护栏设计、PC-1~PC-8 切片与 TC-PL-C01~15，P1~P8 待拍板 |
| [pluginization/production-line-product-form.md](pluginization/production-line-product-form.md) | **生产线最终产品形态（PL-PRODUCT）**：只做决定的工作台定位与六条设计原则、三个真实用户场景、信息架构（今日/准备/执行/工具四入口）、今日决定优先线框、准备四步（需求五栏→侦查四块→对齐→计划落档）、执行看板与内联详情抽屉（概览/计划/打包/门控/消息专家/台账）、复盘工具与配置、13 状态文案与操作矩阵、空态/异常/依赖态、交互规则、产品验收 PS-1~PS-8 与 PC 切片映射、PF-1~PF-8 待拍板 |
| [pluginization/production-line-gates.md](pluginization/production-line-gates.md) | **生产线门控规范（冻结版）**：L0 产线就绪（项目结构/文档归一化/索引）→ L1 计划门（7 块/需求逐条追踪/任务拆分/出口门禁）→ L2 任务门（派发/执行/出口）→ L3 批次漂移哨兵与集成验收 → L4 稳定性门（租约/幂等/恢复/防篡改）→ L5 产品验收；统一结果契约、错误码、证据目录、UI 禁用规则、TC 映射与变更控制 |
| [pluginization/ui-roundness-visual-upgrade-recon.md](pluginization/ui-roundness-visual-upgrade-recon.md) | **UI 视觉效果升级（更多圆角化）侦查 + 落地**：全仓 36 文件 / 108 行 / 84 处硬编码半径与 10 种数字字面值、主题层只覆盖 Card/Dialog/输入边框、M2 默认值（按钮/菜单/SnackBar/Tooltip/Checkbox 仅 1~4px）、5 档圆角令牌（**2/6/8/16/胶囊**）、表面→令牌映射、文件树/Agent 行/活动栏三处新增圆角面、S1~S4 切片与 D1~D9 拍板；追加文件面板三层头部紧凑化（106→88px）与 **tab 归属编辑器组**（不横跨目录、常显滑块/滚轮横滚/自动滚入视野） |
| [pluginization/ui-settings-layout-and-neutral-theme-recon.md](pluginization/ui-settings-layout-and-neutral-theme-recon.md) | **设置页 IDE 式左右布局 + 中性配色 + 右栏自适应宽度侦查**（本期只落档）：设置页 14 节单列表现状、右栏 240~400px 宽度约束、7 个分类与 620/420 响应式断点、深/浅主题中性 token 对照（绿只留 5 类位置、消息流一起中性化）、窗口 `preferredWidth` 只放宽/用户缩过即停、SET-UI-1~4 切片与测试影响 |
| [doc-normalization-recon.md](doc-normalization-recon.md) | **文档归一化 / 包功能收束 / 复用识别**（本期只落档）：TREE 内 headless 插件 `tree.docnorm`，对目标仓库零侵入；`LanguageAdapter` 六方法 + **首批六族适配器（Dart/Python/Go/Rust/Node-TS（含 Vue 3 SFC）/Web-HTTP（OpenAPI、`.http`））**；三层规则源 + `contract` 契约侦查 + 只增不改（索引追加式）+ `DocPolicy`；双额度预算（`context_cap` / `stage_budget`）；建议四类（复用识别本期不上向量化，见 known-issues #45）；L0/L1/L2 单向依赖；GraphRAG 只对文档建图且**本期上 embeddings（默认 hybrid）**；`tree.storage`（Sembast）；安全默认（门禁只列不跑、规则包 pin+sha256、禁网、baseline dry-run）；**模型池按 `chat/embedding/decision` 分类，新增 JEV 决策模型支持（D33）**；**默认维护项目状态与工作日志（D34/DN-11，已有按仓库规范、缺失用内置模板，只追加/回填）**；**DN-2 已实施：`plugins/tree.docnorm` 的 `docnorm.scan` 六族适配器 + fallback，输出包图/子包/API/依赖与 `degraded`**；**DN-3 已实施：`docnorm.contract` / `docnorm.check` + 三层规则合成（内置 → 根 `docnorm.yaml`）+ `DocPolicy` 四条检查，本仓结果与 `docs_contract_test.dart` 同口径**；D1~D34 默认口径、DN-1~DN-11 切片、P1~P8 拍板记录；本仓仅作 dogfood 示例 |
| [pluginization/tree-storage-recon.md](pluginization/tree-storage-recon.md) | **`tree.storage` 插件侦察与落档（ST 系列）**：headless 插件统一集合存储（Sembast、纯 Dart）；每团队 × 每插件一库 `<data_root>/storage/<team_id>/<plugin_id>/data.semdb`；执行站命令族 `storage.*`（ensure/put/get/delete/query/scan/count/tx/export/import/stats/compact/purge）；namespace=调用方 plugin_id + 白名单；单命令事务 + `rev` CAS，不提供长事务；DB 真源、NDJSON 仅快照；**ST-1~ST-5 已实施（CRUD / 分页 CAS / tx / 导出导入 / 白名单审计 / 维护），ST-6 随 DN-6**；ST-1~ST-6 切片与 TC-ST-01~13 |
| [pluginization/plugin-settings-recon.md](pluginization/plugin-settings-recon.md) | **插件设置服务 `tree.settings`（K 系列，K1~K5 已实施）**：用户拍板 **D 方案——独立设置插件，不做进核心**；`settings.*` 执行站命令族（define/list/get/set/reset/export）+ UI 委派 `/api/plugin-settings/*`；schema + 用户覆盖值 + `settings.changed` 广播；核心零改动、不存值；插件持最终值（设置服务 > env > 插件 config > 默认）；secret 只写不回显；v1 仅 team 作用域；**K1~K5 已实施（`plugins/tree.settings` + UI 设置页「插件设置」卡片；契约测试含并发/未知类型/脱敏）；真核心黑盒随 DN-2 联调**；TC-SET-01~10 |
| [pluginization/model-pool-kinds-recon.md](pluginization/model-pool-kinds-recon.md) | **模型池 kind/protocol 扩展侦察与落档（MP 系列）**：`kind: chat/embedding/decision` + `protocol: openai/jev`，旧模型缺省 chat/openai 且不改文件；embedding 走 `/embeddings`（必填 `dimensions`），JEV 走 typed questions（noul/choice/score，概率+置信度）；选择器按 kind 过滤（Agent/产线打包执行只 chat、docnorm 只 embedding、产线主控可选 decision）；`kind` 创建后不可改；**MP-1~MP-7 已实施（校验 / 绑定过滤 / embedding / JEV / 探测 / UI 编辑器），docnorm 消费随 DN-9**；MP-1~MP-7 切片与 TC-MP-01~13 |
| [conversation-sembast-and-collapse-recon.md](conversation-sembast-and-collapse-recon.md) | **会话存储 Sembast 化 + 中栏工具折叠侦查与拍板**：显示/详细双 store、seq 排序键、jsonl 一次性迁移、详情端点、N>3 折叠组与 TC-COLLAPSE-01 零位移判据（F1~F4 执行规格） |
| [scroll-model-rewrite-recon.md](scroll-model-rewrite-recon.md) | **中栏消息列表滚动模型重写（路线 2，实施中）**：反向 ListView + `before` 向上分页 + 锚点保持；取消全局槽位表 / `maxScrollExtent` 估算 / `padAboveStamp`·`contentShiftStamp` 补偿层；`MessageFeed` 连续窗口与全局下标、尾巴冻结与缓冲、实测裁剪、`at=`/`from=` 重锚、滑块几何只读 `total`、折叠单点锚点校正；I-1~I-8 不变量、R1~R8 切片与 TC-COLLAPSE-01 在新模型下的判据 |
| [pluginization/session-auto-title-plan.md](pluginization/session-auto-title-plan.md) | **会话自动命名（TITLE-AUTO）方案**：路线 3 两段式（首条消息规则即时出标题 → 首轮收尾 LLM 精修一次）；复用 `session.rename` 写库 + `session_renamed` 广播，核心/协议零改动；哨兵值 + pending 值双判据保护手动改名；默认会话、配置面、T1~T3 切片与 TC-TITLE-01~14，D1~D4 待拍板 |
| [pluginization/agent-context-handover-and-snapshot-recon.md](pluginization/agent-context-handover-and-snapshot-recon.md) | **上下文 handover 与系统提示词快照留档（车道 R）**：`prompts.jsonl` 版本化留档（含摘要的 `effective_system`、sha256 去重、REST 历史/版本查询）；`handover` 工具写 pending、轮边界显式摘要 + 显式切点重建（同一模型，不换模型）；不做 head；S1~S3 切片、切点算法与测试清单 |
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
