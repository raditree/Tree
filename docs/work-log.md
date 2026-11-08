# Work Log（过去式）

> 只记**已经做完的事**，用表格；阶段与待办在 [project-status.md](project-status.md)。
> 约定：按日期倒序（新的在上）；一行一件事；细节一律引原文档或提交，不在这里复述。
> 归档：超过 300 行时，把最老的一段移到 `docs/archive/work-log-<阶段>.md`。

| 日期 | 事项 | 结论 / 关键数字 | 提交 | 原文档 |
| --- | --- | --- | --- | --- |
| 2026-11-08 | UI 移仓 S5 文档与开发回路 | README/CONTRIBUTING/development/handover 全部改到 `plugins/tree.ui.default`（目录、flutter 命令、门禁顺序、打包链）；CHANGELOG 记零依赖契约与 `ui_contract` 断言；dev_run 修 dart.bat 解析与 stderr 事件回调两处真问题，实测「核心就绪 → UI 附着 → 经核心刷新发布索引 → 关 UI 核心优雅退出且 core.json 清理」 | `ab5d97c` | [ui-source-migration-recon.md](pluginization/ui-source-migration-recon.md) §6 |
| 2026-11-08 | UI 移仓 S4 CI 与发布链收口 | 桌面仓 `app` job 改检出 tree-plugins → `plugins/tree.ui.default` 下跑 analyze/test；等价闸门本地全绿（analyze 0、UI 908 通过/1 跳过、contract 通过）；发布索引 UI 条目为 archive 1.0.5；installFromZip / install-local 13 条用例全绿（发布源实装留 S6 真机） | `abcc405` | [ui-source-migration-recon.md](pluginization/ui-source-migration-recon.md) §6 |
| 2026-11-08 | Agent loop AC-1 信封 + 台账 + 实例骨架 | `CoreMessage`/`CoreMessageRef` 加 7 个加法键（老 JSON 不多键）；`inbox.jsonl` 追加/状态合并/崩溃恢复；`AgentInstance`/Registry 懒建与 flush/dispose；analyze 0、tree.agent 396 全绿（新增 16） | 插件仓 `8794b3f` | [agent-loop-restructure-recon.md](pluginization/agent-loop-restructure-recon.md) §5 |
| 2026-11-08 | Agent loop AC-2 消息机改造 | 统一入站 `acceptMessage`（`type/subtype/inject_mode` 校验 + 特殊来源/保留坐标约束）；`tip` 只补上下文不唤醒、`task` 唤醒；direct/queue 双队列（direct 优先、queue 逐条）与 `inbox.jsonl` 全状态记账；Agent 状态机驱动 `agent.state` 广播；去掉「到达即打断」；analyze 0、tree.agent 408 全绿（新增 12） | 插件仓 `fcbab04` | [agent-loop-restructure-recon.md](pluginization/agent-loop-restructure-recon.md) §5 |
| 2026-11-08 | Agent loop 剩余语义拍板（C6-b/C8~C11） | 工具表按会话快照并按四类信号失效；stop 作废可运行 task、tip 保留；中转站仅显式 error fail-closed；状态保持 idle/working 两态、asking 为附加标记；direct 优先、queue 逐条排空；C1~C12 全部定稿 | — | [agent-loop-restructure-recon.md](pluginization/agent-loop-restructure-recon.md) §4 |
| 2026-11-08 | Agent loop 补充拍板 C12/C4 | 历史加 `source_message_id` 等加法键、不改既有 `CoreMessage.id`；`system_message` 存 `role=system`、请求发 `LlmRole.system`、不改钉住提示词；AC-1 无阻塞 | — | [agent-loop-restructure-recon.md](pluginization/agent-loop-restructure-recon.md) §4 |
| 2026-11-08 | Agent loop 五项核心语义拍板 | C1/I1 迭代边界、C2 tip 不终止、C3 队列按 session 分区、C5 本期抽 `LlmInvoker`、C6-a 会话级提示词快照 + C7 记忆 MVP；C4/C6-b/C8~C12 待拍板 | — | [agent-loop-restructure-recon.md](pluginization/agent-loop-restructure-recon.md) §4 |
| 2026-11-08 | Agent loop 三线结构侦察 + 语义对齐（AC-1） | 现状落在 `ConversationService`/`LlmAgentEngine`/`LlmSession` 三层；确认 12 处语义冲突（终止边界、tip 不终止、队列作用域、system 通道、LLM 插件边界等）；只落档未改码 | — | [agent-loop-restructure-recon.md](pluginization/agent-loop-restructure-recon.md) |
| 2026-11-08 | UI 移仓 S3 桌面仓删源 + 构建改道 | 删根 Flutter 工程与 5 个平台目录（344 文件）；`package_windows`/`package_ui_plugin` 增 `--ui-dir`（版本/CMake/字体门禁全按 UI 目录）、`build_plugins` 显式跳过 `runtime: ui`、`dev_run` 在 UI 目录跑；根 pubspec 收为最小清单；跨仓门禁去掉 `lib/` 回落；analyze 0 / protocol 68 / core 663；全量出包 + UI zip 18.9MB + 索引写入 | `877f5ac` | [ui-source-migration-recon.md](pluginization/ui-source-migration-recon.md) §6 |
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
