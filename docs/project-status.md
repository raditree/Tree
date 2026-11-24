# 项目状态

> 只回答三件事：**现在什么阶段**、**几条车道在跑**、**每条车道下一步做什么**。
> 过去式 → [work-log.md](work-log.md)；文档索引 → [README.md](README.md)。

**当前：快速迭代**（按切片交付新能力；本期主线 PL-COMPLETE 生产线功能补齐）｜ 版本线 `1.0.8+1`
**出口**：PC-1~PC-10 切片全合入 + 全量测试绿 + 无阻塞缺陷（真模型 E2E 待有模型池环境）→ 稳定性迭代 / 发版窗口

---

## 阶段模型

| 阶段 | 允许 | 门禁 | 晋级 |
| --- | --- | --- | --- |
| 快速迭代 | 按切片交付新能力 | analyze → 受影响包测试 → 契约 | 切片全合入 + 全量绿 + 无阻塞缺陷 |
| 稳定性迭代 | 只修缺陷、补测试 | 全量测试 + E2E + 真机清单 | P0/P1 清零 |
| 发版窗口 | 只做发版工程 | 产物自检 + 全新/覆盖安装 + 回滚 | 资产发布且真机通过 |
| 维护期 | 只接用户阻断问题 | 针对性测试 + 发版前回归 | 新需求或改造立项 |
| 大版本迭代 | 跨仓/协议/架构改造 | 契约门禁 + 双轨验证 + 迁移演练 | 方案 S 系列完成 + 旧路径退役 |

## 并行车道

同一阶段内允许多条车道并行；**最多 3 条「进行中」**，各自独立提交、门禁与回滚。
状态：`进行中` / `待开始` / `排队` / `空闲`。

| 车道 | 当前一步 | 状态 | 下一步 | 方案 |
| --- | --- | --- | --- | --- |
| **A UI 移仓** | MIG-UI-7 清理与真机验收（S6） | 进行中 | 车道 D 发版 | [ui-source-migration-recon.md](pluginization/ui-source-migration-recon.md) §6 |
| **B 核心收窄** | — | 空闲（S7 已完成） | 待新任务（S9 归车道 C） | 同上 §2.5 |
| **C 去插件化** | CORE-DEPLUG-1 | 排队（最后做） | 默认界面发现 → ssh 能力判定 | 同上 §2.5 |
| **D 发版** | REL-1.0.8 | 已完成源码 tag（桌面 `v1.0.8+1` / 插件 `v1.0.7`，两仓 GitHub + Gitee 已推） | 出包与 Release 资产上传 | [work-log.md](work-log.md)（2026-11-22 REL-1.0.8） |
| **E 稳定性** | STAB-PL-1~9 产线与模型池问题侦查 + 落地（D1~D7 全部完成，含 D7-5 数据副本回归） | 进行中 | 真机验收产线文件窗 / 角色配置 | [production-line-stability-recon.md](pluginization/production-line-stability-recon.md) |
| **G 设置页与配色** | — | 已完成（SET-UI-1~4） | 待新任务 | [ui-settings-layout-and-neutral-theme-recon.md](pluginization/ui-settings-layout-and-neutral-theme-recon.md) §5 |
| **H 标准开发流生产线** | **Task 1~11 全部落地，PC-1~10 功能完整**：执行驱动与状态真值、结构硬门、归一化预检写入 + 复合就绪门、1 分钟理解（LLM #1 摘要 + 双查询 + RRF + `evidence_id` + 60s partial）、任务输入/附件（`.input` 落盘 + sha256 + 图片边界 + 视觉/非视觉 + PDF/Office 只存）、记忆端口（`agent.memory.get/record`，产线只存 hash/sources）、任务拆分器（PG-03~07 + plan-vN）、计划 7 块 + REQ 追踪 + 起草/批判/修正 + DEC + BG-01~08、UI 四入口 + 准备四步 + 计划审查 + 右栏 `productionTask` + 结构/归一化页 + `broadcast.task_state`（单调 seq + 3s 轮询）、稳定性（租约/fencing、幂等、事件日志/对账、独立 gate runner + `gate.json` 封签、SLO 指标） | 进行中（功能完整，PC-1~10 全部落地；剩余仅真模型 E2E） | 在有模型池/密钥的环境执行真模型 E2E（AG-11 / TC-PL-C15）；确定性 E2E 已覆盖全链路与异常五路径，前置与证据留存见 `plugins/tree.production.line/tool/e2e_real_model.md` | [production-line-product-form.md](pluginization/production-line-product-form.md) ＋ [production-line-completion-recon.md](pluginization/production-line-completion-recon.md) ＋ [production-line-gates.md](pluginization/production-line-gates.md) |
| **I 存储插件 tree.storage** | — | 已完成（ST-1~ST-6；docnorm 已接入） | 待新任务 | [tree-storage-recon.md](pluginization/tree-storage-recon.md) §7 |
| **J 模型池 kind/protocol** | — | 已完成（MP-1~MP-7；embedding 已被 DN-9 消费） | 待新任务（JEV 待产线主控） | [model-pool-kinds-recon.md](pluginization/model-pool-kinds-recon.md) §7 |
| **K 插件设置服务 tree.settings** | — | 已完成（K1~K5；真核心黑盒随 DN-2 联调） | 新任务 | [plugin-settings-recon.md](pluginization/plugin-settings-recon.md) §7 |
| **L UI 圆角化** | RND-UI-1 + S1~S4 已落地（UI 插件 `f208763`；版本随发版车道 D） | 已完成 | 真机视觉验收（深/浅、240px 窄栏、tab 溢出） | [ui-roundness-visual-upgrade-recon.md](pluginization/ui-roundness-visual-upgrade-recon.md) §4 |
| **M 核心与 UI 生命周期** | 最后一个 UI 进程退出 ⇒ 核心收尾剩余插件并退出；全部停用/卸载/从未连上 ⇒ 保持引导页模式 | 已完成 | 真机 E2E-14（托盘退出 / 直接结束 UI 进程 / 全部停用） | [ui-pluginization.md](pluginization/ui-pluginization.md) §4.1.1 ＋ `ui-pluginization_acceptance.md` D-13/E-16/E2E-14 |
| **N 记忆与上下文治理** | **M1~M6 全部完成**：存储骨架 / REST / 异步管道 / 工具 + 快照段 / agent 配置页 / 衰减改全局乘数 + embedding 分槽与混合检索 + 合并提升续命 + 归档保留原层级。验证：`tree.agent` analyze 0、memory 8 套件 74 项全绿；UI analyze 0、`agent_config_panel_test` 3 项全绿 | 已完成 | 排期 known-issues #55；#54 提示词 provider 接线独立修复 | [agent-memory-recon.md](pluginization/agent-memory-recon.md) ＋ [agent-memory-upgrade-plan.md](pluginization/agent-memory-upgrade-plan.md) §10/§11.2 |
| **O 热重启可靠性** | P0~P3 已落地：tree.agent 真实转储/续跑（中断轮次收尾、pending 重放）、生命周期系统广播、UI 运行态与末尾页自愈、suspend 全程日志 | 已完成 | 真机复验「agent 自调 plugin_hot_restart 不再卡住」 | [work-log.md](work-log.md)（2026-11-22 热重启） |
| **P 中栏滚动模型重写** | **R2~R3 完成**（反向 ListView + `before=` 向上分页 + 阅读期缓冲/角标 + 折叠单点锚点，D1~D3 已拍板；旧槽位表模型删除，`dart analyze` 0、全量 1057 项绿）；R8 文档收尾进行中 | 进行中 | R4 新侧落后裁剪实测补偿 → R5 seek 精修 → R7 chunk 不整面板 `setState` | [scroll-model-rewrite-recon.md](scroll-model-rewrite-recon.md) §4 |
| **Q 会话自动命名** | **T1~T3 全部落地**：规则段 + `title_source`（`e6984b9`）、LLM 精修 + 配置项（`cf5df22`）、配置接口 + 设置卡片 + 默认会话可重命名（`87c6fff`）；记忆 LLM 已泛化为「后台异步处理模型」并作为标题精修缺省模型（`899f538`），且模型链局部优先（`88aec20`） | 已完成 | 真机视觉验收：首条消息即时标题 / 首轮后精修 / 手动改名不被覆盖 / 设置卡片三处即时保存 | [session-auto-title-plan.md](pluginization/session-auto-title-plan.md) §10 |
| **R 上下文 handover 与快照留档** | **S1~S3 全部落地**：`prompts.jsonl` 版本化留档（initial/compact/handover/legacy + sha256 去重）、`handover` 工具 + pending 记录 + 轮边界整体替换（`replaceContext`，不动压缩语义）、`prompt-snapshot` 的 `history` / `?version=N`；tree.agent analyze 0、全量 **685** 项绿 | 已完成 | UI 提示词面板版本选择（S4，可后置） | [agent-context-handover-and-snapshot-recon.md](pluginization/agent-context-handover-and-snapshot-recon.md) §6 |

**车道 H 门控覆盖**（冻结版 [production-line-gates.md](pluginization/production-line-gates.md)）：
LG-01~07 就绪门（结构 / 文档归一化 / 包图 / 文档图 / 代码索引 / 测试映射 / 复合就绪）；
PG-00~10 计划门（7 块 / REQ 追踪 / 依赖 / 尺寸 / 写域 / 任务门控 / 集成 / 契约变更 / 迁移前置）；
TG-01~16 任务门（输入 / 依赖 / 写域 / 预算 / 就绪 / 围栏 / 租约 / 出口）；
BG-01~12 批次门（范围 / API / schema / golden / 依赖图 / 数据 / 文档 / 追踪 / 集成）；
SG-01~06 稳定性门（单执行者 / 幂等 / 崩溃恢复 / 门控防篡改 / 换模型回归 / 恢复 SLO）；
AG-01~10 已由确定性 E2E 覆盖，AG-11（真模型端到端）待有模型池环境执行。
**已知限制**：① 真模型 E2E 需本机模型池 / 密钥（见 [known-issues.md](known-issues.md) #53）；
② PDF / Office / 非视觉图片附件首版只存不读（设计性限制，见 [known-issues.md](known-issues.md) #51）。

**车道依赖**：`A：1 → 2 → 3 → 4 → 5`；`C` 必须等 `A` 的 S6 之后（行为改造不污染移仓回滚点）；
`B`、`E`、`G` 与 `A` 无依赖，可并行；`D` 需阶段切到发版窗口。
`L` 只改 UI 插件仓，与 `A` 同仓：已在 A 未触碰的文件区域内完成（按文件区域避让）。
`G` 只改 UI 插件仓，不动核心/协议；D1~D6 已有默认口径（见方案 §8），可直接开工。
`H` 必须先完成 P0 文档归一化（产线的项目资产与索引依赖它），之后按 P1→P8 顺序推进
（P7 已按用户定稿取消：不做模型硬绑定，`lfm3` 仅是新建产线模板默认值，模型由用户在模型池自选）；
P0 的语义、切片与拍板项见 [doc-normalization-recon.md](doc-normalization-recon.md) §7/§8（TREE 内插件，对目标仓库零侵入；本质=包功能收束，供产线免做全面侦查）；
`H` 的 P0 前置拆成两条独立车道：`I`（存储）与 `J`（模型池）。`DN-2` 只需 `J MP-1`（schema 兼容）即可开工；
`DN-4` 前需 `I ST-1~ST-3`（已完成）；`DN-9` 前需 `J MP-5`（已完成）；`P3` 前需 `J MP-6`（已完成）与 P8 golden set。
`H` 只新增 `tree.production.line` 插件与 UI 面，不改核心面 35 条基线；`I`/`J` 同样不新增核心点位。
`H` 的 **PL-COMPLETE 功能补齐**按三分口径处理（[§2.3](pluginization/production-line-completion-recon.md#L76-L98)）：
4 条驱动/护栏属**缺陷**（PC-1 先修）；准备阶段 UI、任务编辑、配置面、事件推送属**欠交付/新能力**，按 PC-2~PC-7 交付。
**P1 已拍板（2026-11-14）：切快速迭代，按 PC-1~PC-8 推进。**
`K`（`tree.settings`）与 `I`/`J` 无依赖，可并行；`H` 的设置项在 K 落地前用 `.docnorm/config.json` + env，不阻塞。

## 并行规则

1. 每条待办有稳定 ID（如 `MIG-UI-3`）+ 至少一个方案文档定位；口头事项不进表。
2. 车道内按方案顺序推进；跨车道依赖只在上表写一行，不隐式阻塞。
3. 同一文件区域的改动尽量不跨车道并行，避免回滚互相污染。
4. 完成即从本表移除当前一步，在 [work-log.md](work-log.md) 表格加一行，并推进“下一步”。
5. 阶段切换改顶部“当前”，并在下面追加一行记录。

## 阶段变更记录

| 日期 | 变更 | 依据 |
| --- | --- | --- |
| 2026-11-14 | **稳定性迭代 → 快速迭代**；主线切到 PL-COMPLETE 生产线功能补齐，按 PC-1~PC-8 切片交付 | 用户 2026-11-14 拍板「切到快速迭代」；方案与三分口径见 [production-line-completion-recon.md](pluginization/production-line-completion-recon.md) §2.3/§8 |
| 2026-11-12 | **大版本迭代 → 稳定性迭代**；车道 E 接产线与模型池 9 项问题，先出侦查文档 | 用户 2026-11-12 拍板：本期只侦察、只修缺陷；证据见 [production-line-stability-recon.md](pluginization/production-line-stability-recon.md) |
| 2026-11-08 | 建立本文件；判定为**大版本迭代** | 跨仓/契约/路由收窄同时进行 |
