# 项目状态

> 只回答三件事：**现在什么阶段**、**几条车道在跑**、**每条车道下一步做什么**。
> 过去式 → [work-log.md](work-log.md)；文档索引 → [README.md](README.md)。

**当前：大版本迭代**（核心微内核化 + UI 源码移仓）｜ 版本线 `1.0.5+1`
**出口**：S1–S6 完成 + 核心面 35 条 + 真机安装/升级验收通过 → 稳定性迭代 → 发版窗口

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
| **D 发版** | REL-1.0.5 push/tag/资产 | 排队（等发版窗口） | 覆盖安装验证 | [handover.md](handover.md) §6 |
| **E 稳定性** | — | 空闲（缺陷可插队） | 随时接 known-issues | [known-issues.md](known-issues.md) |
| **G 设置页与配色** | — | 已完成（SET-UI-1~4） | 待新任务 | [ui-settings-layout-and-neutral-theme-recon.md](pluginization/ui-settings-layout-and-neutral-theme-recon.md) §5 |
| **H 标准开发流生产线** | P0 文档归一化：DN-1 定稿（D1~D34 + P1~P8）；`J MP-1` 已就位，DN-2 可开工；DN-4 等 `I ST-1~3` | 待开始 | DN-2 六族适配器（含 Node/TS+Vue3+HTTP）→ DN-3 → DN-6 → 解锁 P1；**DN-4 前需 I ST-3，DN-9 前需 J MP-5，P3 前需 J MP-6 与 P8 golden set**；DN-11（状态/日志维护）可与 DN-4 并行 | [production-line-recon.md](pluginization/production-line-recon.md) §11 ＋ [doc-normalization-recon.md](doc-normalization-recon.md) §7/§8/§9 |
| **I 存储插件 tree.storage** | ST-2 分页 + CAS + tx | 进行中 | ST-3 导出导入 → ST-4 隔离白名单 → ST-6 docnorm 接入 | [tree-storage-recon.md](pluginization/tree-storage-recon.md) §7 |
| **J 模型池 kind/protocol** | MP-2 API 校验 | 进行中 | MP-3 设置页 → MP-4 消费方过滤 → MP-5 embedding / MP-6 JEV 客户端 | [model-pool-kinds-recon.md](pluginization/model-pool-kinds-recon.md) §7 |

**车道依赖**：`A：1 → 2 → 3 → 4 → 5`；`C` 必须等 `A` 的 S6 之后（行为改造不污染移仓回滚点）；
`B`、`E`、`G` 与 `A` 无依赖，可并行；`D` 需阶段切到发版窗口。
`G` 只改 UI 插件仓，不动核心/协议；D1~D6 已有默认口径（见方案 §8），可直接开工。
`H` 必须先完成 P0 文档归一化（产线的项目资产与索引依赖它），之后按 P1→P8 顺序推进；
P0 的语义、切片与拍板项见 [doc-normalization-recon.md](doc-normalization-recon.md) §7/§8（TREE 内插件，对目标仓库零侵入；本质=包功能收束，供产线免做全面侦查）；
`H` 的 P0 前置拆成两条独立车道：`I`（存储）与 `J`（模型池）。`DN-2` 只需 `J MP-1`（schema 兼容）即可开工；
`DN-4` 前需 `I ST-1~ST-3`；`DN-9` 前需 `J MP-5`（embedding）；`P3` 前需 `J MP-6`（JEV，可选）与 P8 golden set。
`H` 只新增 `tree.production.line` 插件与 UI 面，不改核心面 35 条基线；`I`/`J` 同样不新增核心点位。

## 并行规则

1. 每条待办有稳定 ID（如 `MIG-UI-3`）+ 至少一个方案文档定位；口头事项不进表。
2. 车道内按方案顺序推进；跨车道依赖只在上表写一行，不隐式阻塞。
3. 同一文件区域的改动尽量不跨车道并行，避免回滚互相污染。
4. 完成即从本表移除当前一步，在 [work-log.md](work-log.md) 表格加一行，并推进“下一步”。
5. 阶段切换改顶部“当前”，并在下面追加一行记录。

## 阶段变更记录

| 日期 | 变更 | 依据 |
| --- | --- | --- |
| 2026-11-08 | 建立本文件；判定为**大版本迭代** | 跨仓/契约/路由收窄同时进行 |
