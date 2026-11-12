# 项目状态

> 只回答三件事：**现在什么阶段**、**几条车道在跑**、**每条车道下一步做什么**。
> 过去式 → [work-log.md](work-log.md)；文档索引 → [README.md](README.md)。

**当前：稳定性迭代**（只修缺陷、补测试；产线与模型池 9 项问题先侦查后修）｜ 版本线 `1.0.7+1`
**出口**：P0/P1 清零 + 全量测试 / E2E / 真机清单通过 → 发版窗口（新能力一律不入本期）

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
| **D 发版** | REL-1.0.7 | 已完成（桌面 `v1.0.7+1` / 插件 `v1.0.6`，GitHub + Gitee 资产已传） | 覆盖安装验证 | [work-log.md](work-log.md)（2026-11-10 REL-1.0.7） |
| **E 稳定性** | STAB-PL-1~9 产线与模型池问题侦查 + 落地（D1~D7 全部完成，含 D7-5 数据副本回归） | 进行中 | 真机验收产线文件窗 / 角色配置 | [production-line-stability-recon.md](pluginization/production-line-stability-recon.md) |
| **G 设置页与配色** | — | 已完成（SET-UI-1~4） | 待新任务 | [ui-settings-layout-and-neutral-theme-recon.md](pluginization/ui-settings-layout-and-neutral-theme-recon.md) §5 |
| **H 标准开发流生产线** | D6-O 主控决策循环 O1~O5（插件 `0.9.0` + UI 主控条 / 运行期问答 / loop 字段） | 进行中（O6 待真模型联调） | 真模型端到端：准备 → 打包 → 执行 → 决策 → ask/answer → done；真机验收暂停/恢复 | [production-line-orchestrator-loop-plan.md](pluginization/production-line-orchestrator-loop-plan.md) |
| **I 存储插件 tree.storage** | — | 已完成（ST-1~ST-6；docnorm 已接入） | 待新任务 | [tree-storage-recon.md](pluginization/tree-storage-recon.md) §7 |
| **J 模型池 kind/protocol** | — | 已完成（MP-1~MP-7；embedding 已被 DN-9 消费） | 待新任务（JEV 待产线主控） | [model-pool-kinds-recon.md](pluginization/model-pool-kinds-recon.md) §7 |
| **K 插件设置服务 tree.settings** | — | 已完成（K1~K5；真核心黑盒随 DN-2 联调） | 新任务 | [plugin-settings-recon.md](pluginization/plugin-settings-recon.md) §7 |
| **L UI 圆角化** | RND-UI-1 + S1~S4 已落地（UI 插件 `f208763`；版本随发版车道 D） | 已完成 | 真机视觉验收（深/浅、240px 窄栏、tab 溢出） | [ui-roundness-visual-upgrade-recon.md](pluginization/ui-roundness-visual-upgrade-recon.md) §4 |

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
| 2026-11-12 | **大版本迭代 → 稳定性迭代**；车道 E 接产线与模型池 9 项问题，先出侦查文档 | 用户 2026-11-12 拍板：本期只侦察、只修缺陷；证据见 [production-line-stability-recon.md](pluginization/production-line-stability-recon.md) |
| 2026-11-08 | 建立本文件；判定为**大版本迭代** | 跨仓/契约/路由收窄同时进行 |
