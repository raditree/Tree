# Work Log（过去式）

> 只记**已经做完的事**，用表格；阶段与待办在 [project-status.md](project-status.md)。
> 约定：按日期倒序（新的在上）；一行一件事；细节一律引原文档或提交，不在这里复述。
> 归档：超过 300 行时，把最老的一段移到 `docs/archive/work-log-<阶段>.md`。

| 日期 | 事项 | 结论 / 关键数字 | 提交 | 原文档 |
| --- | --- | --- | --- | --- |
| 2026-11-08 | UI 移仓 S2 插件仓落源 | 242 文件迁入 `plugins/tree.ui.default/`；pubspec 零 path 依赖、自持 `protocol_contract.dart`（UI 实调 25 条路径）；插件仓 CI 增 ui job；analyze 0 问题、flutter test 908 通过/1 跳过、contract 门禁通过 | 插件仓 `9275cb9`；桌面仓 `38310b1` | [ui-source-migration-recon.md](pluginization/ui-source-migration-recon.md) §6 |
| 2026-11-08 | UI 移仓 S8 契约冻结 + 黑盒 | `/api/meta.ui_contract = 1.0`（只增不改）；新增 6 条黑盒用例（流式/工具卡/终端/站点重连/插件面板 + 套件自检），真核心 + 真插件进程、全程字面量；protocol 68 + core 663 全绿 | `ac58897` | [ui-source-migration-recon.md](pluginization/ui-source-migration-recon.md) §6 |
| 2026-11-08 | UI 移仓 S1 门禁先行 | 三条跨仓扫描改 `_uiSourceRoot()`（优先插件仓 UI 目录、回落根 `lib`、两处皆无即 fail）；legacy 扫描补 UI 目录、仓库根判据改根 pubspec；protocol 68 + core 657 全绿 | `09475a0` | [ui-source-migration-recon.md](pluginization/ui-source-migration-recon.md) §6 |
| 2026-11-08 | 核心面收窄 S7（43 → 35） | 删 store 4 / logs 3 / data-collection 1；基线改 coreOwned 35 / delegated 55 / contract 90 / kept 70；protocol 68 + core 657 全绿 | `223e9b9` | [ui-source-migration-recon.md](pluginization/ui-source-migration-recon.md) §2.5 |
| 2026-11-08 | 过程文档拆分 | status 只管阶段与当前事项；work-log 记过去式；完成即迁出 | `ba0e1ef` | [project-status.md](project-status.md) |
| 2026-11-08 | 项目状态入口上线 | 阶段模型（快速/稳定性/发版/维护/大版本）、待办总表、维护规则生效 | `4dc823b`、`9d1174d` | [project-status.md](project-status.md) |
| 2026-11-08 | UI 移仓方案定稿 | 核心只认 `ui`/`headless`、UI 零依赖（自持契约）、核心面 43→35、S1–S9 与回滚 | `70d6c9c`、`bae779d`、`91ad646` | [ui-source-migration-recon.md](pluginization/ui-source-migration-recon.md) |
| 2026-11-08 | 测试基线全绿 | 根仓 909 / core 675 / protocol 68 / agent 89 / local_exec 295 / tunnel 15 / cli 4 / launcher 11；analyze 零新增；修 cli 三处历史失效断言 | `d5ae71d` | — |
| 2026-11-08 | 消息/作答/停止改走 REST | 移除 WS `user_message`/`stop`/`user_answer` 依赖；补 `error` 帧提示；新建会话即切 `session_id` | `7d6d742` | — |
| 2026-11-08 | 插件面板与磁盘状态对齐 | 订阅 `plugin_config_changed` + 重新可见重拉；停用态只给「启用」；依赖一键补全；agent 列表启动退避 | `18732e7` | — |
| 2026-11-08 | 插件发布源与安装链修复 | 源顺序在下载阶段也回退；令牌只回 `token_set`；`with_dependencies` 补缺失依赖；停用态 restart 先启用 | `658e9e2` | — |
| 2026-11-08 | 核心单实例 + 默认界面 + 发行布局 | `runtime/core.json` 实例发现、loader 优先附着、首启按同目录 `tree_ui.exe` 登记、引导页种子带构建号 | `91eac9d` | — |
| 2026-11-02 | 会话存储 Sembast 化 + 折叠 F1–F4 | 显示/详细双 store（显示上限 10000，详情点击即查）；有工具即折叠；全局单组展开；TC-COLLAPSE-01 零位移通过 | `2d2f9e8`、`70248b2`、`c6a6a0d`、`f9cc17a` | [conversation-sembast-and-collapse-recon.md](conversation-sembast-and-collapse-recon.md) |
