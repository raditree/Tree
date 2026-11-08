# 项目状态（唯一入口）

> 这份文件回答三个问题：**现在处于什么阶段**、**接下来做什么**、**每件事的方案在哪**。
> 它是项目资产，随仓库版本控制；**改动事项的人在同一提交里更新它**（见 §7）。
> 最后更新：2026-11-08 ｜ 版本线：1.0.5+1 ｜ 当前阶段：**大版本迭代**

---

## 1. 当前状态卡

| 项 | 值 |
| --- | --- |
| 当前阶段 | **大版本迭代**（架构级：核心微内核化 + UI 源码完全插件化） |
| 阶段目标 | 核心只保留平台点位与通用接入面；UI 成为可独立构建的 `plugins/tree.ui.default` |
| 本阶段起点 | 2026-11-08（方案文档落档日） |
| 下一里程碑 | **S1 门禁先行** → **S8 契约冻结 + 黑盒套件** → S2 插件仓落源 |
| 阶段出口 | 方案文档中 S1–S6 全部完成、核心面 43→35、真机安装/升级验收通过 |
| 出口之后 | 稳定性迭代（清 known-issues、补 E2E）→ 发版窗口（下一版） |

**一句话**：现在不追求新功能，追求“**结构正确 + 可独立演进**”；新功能只做不破坏本阶段前提的小切片。

---

## 2. 阶段模型与晋级规则

同一时刻只允许**一个**主阶段。阶段切换必须更新 §1 与 §8 的变更记录。

| 阶段 | 做什么 | 不做什么 | 门禁 | 退出条件（进入下一阶段） |
| --- | --- | --- | --- | --- |
| **快速迭代** | 按切片交付新能力（A→E），每片一提交 | 不做跨仓/协议级重构；不拖欠 P0/P1 缺陷 | `dart analyze` 无新增 → 受影响包全量测试 → 契约门禁 → 涉及界面加 `flutter analyze/test` | 计划切片全部合入 + 全量测试绿 + 无阻塞缺陷 |
| **稳定性迭代** | 修缺陷、清 known-issues、补测试与真机验收 | 不加新功能；不动对外契约 | 全量测试 + E2E + 真机验收清单 | known-issues 的 P0/P1 清零 + 看板无阻塞项 |
| **发版窗口** | 版本号、打包、tag、release 资产、覆盖安装验证 | 代码改动（除阻断发版的修复） | 打包产物自检 + 全新安装 + 覆盖安装 + 回滚验证 | release 资产发布且真机通过 |
| **维护期** | 只处理用户反馈的阻断问题 | 不主动加功能、不做重构 | 针对性测试 + 发版前全量回归 | 新需求立项或架构改造立项 |
| **大版本迭代** | 跨仓/协议/架构级改造（如本次 UI 移仓、核心收窄） | 不并行第二个大改造；不把行为改造混进位置迁移 | 契约门禁 + 双轨验证 + 迁移/回滚演练 | 方案文档的 S 系列全部完成 + 旧路径退役 + 真机验收 |

**晋级原则**：出口条件未满足时只能在当前阶段内做“不扩大债务”的切片；需要越级时先在本文件登记理由。

---

## 3. 待办总表

状态值：`待开始` / `进行中` / `待验收` / `已完成` / `已搁置`。每条必须带方案文档索引（没有就先登记“待侦查”）。

| ID | 事项 | 阶段 | 状态 | 依赖 | 方案文档 |
| --- | --- | --- | --- | --- | --- |
| MIG-UI-1 | UI 移仓门禁先行：路径常量 + 缺目录即红 | 大版本 | 待开始 | 无 | [ui-source-migration-recon.md](pluginization/ui-source-migration-recon.md) §6 S1 |
| MIG-UI-2 | 契约冻结 + 黑盒一致性套件（`/api/meta.ui_contract`） | 大版本 | 待开始 | MIG-UI-1 | 同上 §6 S8 |
| MIG-UI-3 | 插件仓落源 `tree.ui.default`（零依赖 + 自持契约） | 大版本 | 待开始 | MIG-UI-2 | 同上 §5.1/§5.2、§6 S2 |
| MIG-UI-4 | 桌面仓删源 + 构建改道（`--ui-dir`） | 大版本 | 待开始 | MIG-UI-3 | 同上 §5.3、§6 S3 |
| MIG-UI-5 | CI 改道、文档同步、真机验收 | 大版本 | 待开始 | MIG-UI-4 | 同上 §5.4/§6 S4–S6 |
| CORE-FACE-1 | 核心面 43→35：删 `store/*`、`logs/*`、`data-collection` | 大版本 | 待开始 | 无（可与 MIG 并行） | 同上 §2.5、§6 S7 |
| CORE-DEPLUG-1 | 核心去插件化 5 处偏差（默认界面发现、内置目录、ssh 能力判定、`delegated` 迁出） | 大版本 | 待开始 | MIG-UI-5（行为改造最后做） | 同上 §2.5、§6 S9 |
| REL-1.0.5 | 1.0.5+1 发版：push、打 tag、上传 setup/zip 资产 | 发版窗口 | 待执行 | 门禁全绿（已满足） | [handover.md](../handover.md) §6、本文件 §2 |
| DOC-STATUS-1 | 本文件上线并接入维护规则 | 大版本 | 进行中 | 无 | 本文件 |

> 说明：`CORE-FACE-1` 与 `MIG-UI-*` 无强依赖，可并行；`CORE-DEPLUG-1` 属行为改造，
> 必须最后做，避免污染移仓切片的回滚点。

---

## 4. 进行中

- **DOC-STATUS-1**：建立项目状态入口（本文件），下一提交起生效。

---

## 5. 已完成（一行一条，细节在原文档）

> 规则：完成后**不删除**，压缩成一行结论 + 原文档链接 + 日期。超过两轮的旧条目移入归档（见 §7）。

- ✅ 2026-11-08 测试基线全绿：根仓 909、tree_core 675、tree_protocol 68、tree_agent 89、tree_local_exec 295、tree_tunnel_protocol 15、tree_core_cli 4、tree_launcher 11；修好 cli 端到端三处历史失效断言。
- ✅ 2026-11-08 插件发布源设置与多源下载回退、清单变更广播、依赖补齐、停用态重启修复（提交 `658e9e2`）。
- ✅ 2026-11-08 核心单实例闸门 + 默认界面播种 + 引导壳发行布局（提交 `91eac9d`）。
- ✅ 2026-11-08 插件面板与磁盘状态对齐、依赖一键补全、agent 列表启动重试（提交 `18732e7`）。
- ✅ 2026-11-08 发消息/作答/停止改走 REST 委派端点 + WS error 帧提示（提交 `7d6d742`）。
- ✅ 2026-11-02 会话存储 Sembast 化与中栏折叠 F1–F4（零位移用例 TC-COLLAPSE-01 通过）。
- ✅ 2026-11-08 UI 源码迁入 `plugins/` 的方案落档：语义（核心只认 `ui`/`headless`）、零依赖、核心面 43→35、S1–S9 分片 → [ui-source-migration-recon.md](pluginization/ui-source-migration-recon.md)。

---

## 6. 文档索引

| 类别 | 文档 | 用途 |
| --- | --- | --- |
| **状态** | 本文件 | 阶段、待办、完成记录 |
| 交接 | [handover.md](../handover.md) | 里程碑、发版口径、历史决策 |
| 架构 | [architecture.md](../architecture.md) | 跨模块不变量 |
| 已知问题 | [known-issues.md](../known-issues.md) | 缺陷与历史事故 |
| 开发规范 | [development.md](../development.md)、[CONTRIBUTING.md](../../CONTRIBUTING.md) | 构建、门禁、提交 |
| 插件开发 | [plugin-development.md](../plugin-development.md) | 插件协议与示例 |
| UI 插件化（运行期） | [ui-pluginization.md](pluginization/ui-pluginization.md) | 核心 ↔ UI 契约与批次 |
| UI 插件化（实施） | [ui-pluginization_detailed.md](pluginization/ui-pluginization_detailed.md) | U1–U6 |
| UI 插件化（验收） | [ui-pluginization_acceptance.md](pluginization/ui-pluginization_acceptance.md) | 验收口径 |
| **UI 移仓（本期）** | [ui-source-migration-recon.md](pluginization/ui-source-migration-recon.md) | 语义、侦察、S1–S9、回滚 |
| 会话存储 | [conversation-sembast-and-collapse-recon.md](../conversation-sembast-and-collapse-recon.md) | Sembast 与折叠 |
| Agent 插件化 | [agent_pluginization.md](pluginization/agent_pluginization.md)、[agent_api_contract.md](pluginization/agent_api_contract.md) | 领域交接 |
| 去领域化 | [scope-de-domainization-recon.md](pluginization/scope-de-domainization-recon.md) | 设置/范围收口 |

新增文档必须在本表登记一行，否则视为“不存在”。

---

## 7. 维护规则（文档卫生）

1. **同一提交**：改动某事项的代码/方案时，必须同步更新本文件对应行；禁止事后补状态。
2. **完成即标**：完成时把状态改成 `已完成`，并在 §5 增加一行（结论 + 原文档链接 + 日期）。
3. **完成后简化，不删除**：待办行从 §3 移除后，只在 §5 保留一行；细节一律引原文档，不在这里复述。
4. **归档阈值**：§5 超过 20 行或跨两个阶段时，把最老的条目移入
   `docs/archive/project-status-log.md`（只保留“一行 + 链接”的形态）。
5. **可追溯**：每条待办必须有稳定 ID（如 `MIG-UI-3`）与至少一个文档索引；口头事项不得进表。
6. **谁提交**：本文件属于项目资产，随仓库提交；由**当次改动的提交者**（人或 agent）负责更新，
   不设单独维护人。提交信息里不必单列本文件，但 PR 描述要写“更新了哪几行状态”。
7. **阶段切换**：改 §1 的同时在 §8 追加一行变更记录（日期 / 从 → 到 / 依据）。

---

## 8. 阶段变更记录

| 日期 | 变更 | 依据 |
| --- | --- | --- |
| 2026-11-08 | 建立本文件；判定当前为**大版本迭代** | 核心微内核化 + UI 源码移仓进行中，涉及跨仓/契约/路由收窄，符合大版本判据 |
