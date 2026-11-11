# 插件平台硬约束与决策记录

> **来源**：2026-11-11 迁自 `docs/handover.md`（该文件已移除），只保留仍需遵守 / 查阅的部分：
> 硬约束条例、拍板记录、关键文件地图、门禁顺序与常见坑。
> 现状与待办看 [project-status.md](project-status.md)，已完成的事看 [work-log.md](work-log.md)，
> 构建与发布看 [development.md](development.md) §8。

---

## 1. 硬约束条例（22 条，破坏即视为回归）

### 1.1 核心侧

1. 核心**只**硬编码 `ApiPaths.coreOwned` 的 **35 条**；不得为任何插件路由写专用 handler。
2. 核心不认识 agent / 会话 / 团队 / 模型 / 文件 / 终端等任何领域概念。
3. 委派层只做路由、身份透传、响应形状校验；四要素 fail-closed 校验留在核心，不下放插件。
4. 转发执行站命令时**无条件删除**调用方传入的 `root`，只注入租约根（路径守卫不可绕过）。
5. 大文件只走 `body_path` / `result_path`，禁止 base64 内联。
6. `/api/meta` 是聚合发现层：路由来自 `system.collect.api.routes`，站点来自内置点位 + 插件申报；
   核心不维护第二份静态清单。
7. 核心不持有 PTY，不实现执行语义，不新增通用流中继数据面。
8. 插件崩溃/停用 ⇒ 归属路由回 **503**（不是 404）；未申报/无归属才 404。

### 1.2 插件侧

9. 插件**不得** import / 依赖 `package:tree_core` 或 `package:tree_protocol`；
   复用能力只有两条路：核心内置执行站命令，或 UI 的 REST 委派端点。
10. 插件不得申报 `coreOwned` 同键，也不得占用保留前缀
    （`/api/plugin`、`/api/bootstrap`、`/api/meta`、`/api/logs`、`/api/store`）。
11. 声明了必需依赖的插件：缺依赖 ⇒ 409 + `missing_dependencies`，**不得带病启动**；
    自动安装只补缺，不做版本升级；卸载只停用下游依赖，不自动卸载。
12. 执行站（`exec.command` / `file.*` / `terminal.*`）由执行器插件内部定义并注册，非核心内置；
    核心只路由、透传身份、校验响应形状。
13. 自注册站点的归属是 `plugin_id`，不是单条 UI 连接；最后一个连接断开或显式注销才销毁。
14. `apiRequires` 在写盘前当场校验，不满足版本要求的插件不启动；
    安装 / 新增 / 启停共用同一份判定。

### 1.3 UI 侧

15. UI 插件只是 API 消费者，不提供 API；功能调用一律 REST，终端输出走广播站。
16. UI 必须连接后立即发 `ui.hello`（含能力与 `window_id`），重连重发；订阅在重连后自动重放。
17. UI 只能订阅广播站；向他人站点 `trigger` 一律可读拒绝；只能发布自己注册的广播站。
18. 核心不得为 UI 写启动逻辑：只给 `TREE_CORE_URL` / `TREE_CORE_TOKEN`，
    生命周期由插件平台管（安装/卸载/启停/重启）。
19. UI 包要排除核心二进制、调试符号与 agent 文件，`plugin.json` 与自校验必须通过。
20. 窗口归属按插件引用计数：任一窗口活着 ⇔ 插件在线；面板/`/api/meta` 的 `connections` 即窗口数。
21. 后台推 UI 只有三条合法路径：自建广播站、`system.broadcast`、委派端点；不新增专用推送通道。
22. 断线 / 站关闭必须给用户可见提示（顶部横幅），不允许静默失效。

---

## 2. 决策记录（2026-11-01 拍板）

| 编号 | 问题 | 结论 |
| --- | --- | --- |
| D-1 | 本地 zip 安装（L-10） | **本期补端点**：`POST /api/plugin/install/local`，复用仓库通道的安装后处理（known-issues #38 已改状态） |
| D-2 | `scope` 去领域化（L-23） | **本期只做侦查，不做实现**：报告见 [pluginization/scope-de-domainization-recon.md](pluginization/scope-de-domainization-recon.md)，下期按 §5 的 S0~S4 执行 |
| D-3 | 功能裁剪（L-27） | **维持现状（36 条功能面）**：候选裁剪项仍有实现与调用方（`token-rate` 等），缺的是使用数据而非代码清理；不随迁移做 |
| D-4 | 发版版本号 | **当期为 `1.0.5+1`**（`1.0.5` 对应插件化收口，build 号重新从 1 起）。后续发版见 [project-status.md](project-status.md) / [work-log.md](work-log.md)（2026-11-10 已发 `1.0.7+1` / 插件 `1.0.6`） |
| D-5 | 数据接管范围（L-05） | **仅 `agents.yaml` + 会话历史**；工作空间是用户文件，接管风险与回滚成本都高，本轮不进 |
| D-6 | 图像内联与 JSON 上限（契约 Q-3） | **两层保证**：所有内联图像归一到长边 `[360p, 1024p]`（等比压缩/拉伸）→ 再以 JSON 上限（建议 4 MiB）兜底，超限走 `result_path`（契约 §7 已记） |
| D-7 | REST 面错误结构（契约 Q-4） | **统一为 `{status, code, message}`**，REST 面同批做，不另开片 |
| D-8 | P1 真机 SSH 环境 | **本机 docker 跑 sshd 容器**（不依赖 WSL / 外部机器），跑 `ssh.file.*` 分块、`rename` 原子性、SSH 终端 |
| D-9 | 插件仓 CI | **两仓都加 `.github`**：插件仓独立 workflow 跑 `check_plugin_repo_contract.dart` + 各插件 `dart analyze` / `dart test` |
| D-10 | P0 前置 L-22 | **拆** `core_settings`（平台级 vs 领域级），**按乙方案·分文件**：领域键落 `config/agent_settings.yaml`、核心退出该键并条件化删旧键（带备份）；细则、覆盖风险与迁移顺序见 [agent_pluginization.md §4.8.1](pluginization/agent_pluginization.md)。不拆则数据接管无法开工 |
| D-11 | P1 的 E2E 口径 | **先手工跑 + 逐条记录证据**；只把事件面三项（E2E-03/04/05）脚本化（替身已成熟），其余等环境稳定再脚本化 |

---

## 3. 关键文件地图

| 关注点 | 从哪读起 |
| --- | --- |
| 核心路由（35 条） | `packages/tree_core/lib/src/server/core_server.dart` |
| 插件平台（进程 / 站点 / 委派 / 窗口） | `packages/tree_core/lib/src/plugin/plugin_bus.dart`（大文件，按符号搜） |
| UI 进程与窗口号 | `packages/tree_core/lib/src/plugin/ui_host.dart` |
| UI WS 订阅桥 | `packages/tree_core/lib/src/plugin/station_ws_bridge.dart` |
| 协议真源 | `packages/tree_protocol/lib/src/api_paths.dart`（`coreOwned` / `delegated` / `kept`） |
| UI 附着核心 | `plugins/tree.ui.default/lib/io/core_attachment.dart`、`lib/io/ui_identity.dart` |
| 托盘与退群 | `plugins/tree.ui.default/lib/io/tray_service.dart` |
| 503 提示 | `plugins/tree.ui.default/lib/io/service_availability.dart` + `lib/ui/...` 顶部横幅 |
| 终端传输面 | `plugins/tree.ui.default/lib/ui/services/terminal_transport.dart` |
| UI 自持契约 | `plugins/tree.ui.default/lib/io/protocol_contract.dart`（零依赖；只增不改） |
| agent 插件委派 | `plugins/tree.agent/lib/src/delegate.dart` |
| agent 执行器激活 | `plugins/tree.agent/lib/src/station/agent_executor.dart`、`runtime/agent_runtime.dart` |
| 文件插件 | `plugins/files/lib/` |
| SSH 执行站 | `plugins/ssh_executor/lib/src/exec_station.dart` |
| 构建与打包 | `tool/build_core.dart`、`build_plugins.dart`、`package_windows.dart`、`package_ui_plugin.dart`、`installer/tree-desktop.iss` |
| 契约门禁 | `packages/tree_protocol/test/protocol_completeness_test.dart`、`test/docs_contract_test.dart`、`tool/check_plugin_repo_contract.dart` |

文档入口：[architecture.md](architecture.md)（进程与不变量）、[development.md](development.md)（构建/打包/发布）、
[plugin-development.md](plugin-development.md)（写插件）、[team.md](team.md)（团队语义）、
[ui-pluginization.md](pluginization/ui-pluginization.md)（核心侧权威口径）、
[ui-pluginization_acceptance.md](pluginization/ui-pluginization_acceptance.md)（验收台账）、
[agent_pluginization.md](pluginization/agent_pluginization.md)（agent 承接范围）、
[agent_api_contract.md](pluginization/agent_api_contract.md)（逐条契约与样例）、
[known-issues.md](known-issues.md)（台账，当前最大编号 #47）。

---

## 4. 门禁顺序（每个改动片按此顺序）

```powershell
# 1) 静态检查（改动的包，无新增 error / warning）—— 从根目录跑路径形式即可
<flutter-sdk>/bin/dart.bat analyze packages/tree_core
# 2) 包内全量测试 —— 必须先进包目录（根包是 Flutter app，没有 package:test，
#    从根目录跑 `dart test packages/xxx` 会报 "Could not find package `test`"）
cd packages/tree_core; <flutter-sdk>/bin/dart.bat test
# 3) 契约 / 文档门禁（路由或帧有变动时必跑）
cd packages/tree_protocol; <flutter-sdk>/bin/dart.bat test
# 4) 插件仓零核心依赖检查（从根目录跑）
<flutter-sdk>/bin/dart.bat run tool/check_plugin_repo_contract.dart
#    （插件仓内用 --plugin-root . 跑同一份脚本）
# 5) 只有动了 UI 才跑（UI 源码在插件仓的 tree.ui.default）
cd plugins/tree.ui.default; <flutter-sdk>/bin/flutter.bat analyze lib
<flutter-sdk>/bin/flutter.bat test
```

插件仓各自跑自己的测试（`cd plugins/<name> && dart test`）。桌面仓根**不再有 Flutter 工程**：
根目录只留工具脚本，`dart run tool/*.dart` 用的根 pubspec 只声明 `tree_protocol`。

### 常见坑（都已踩过）

1. `plugins/` 是独立仓的本地 clone，桌面仓提交**不带**插件改动；两侧分别提交。
2. 站点 `seq` 是通道级：不发 `reset` 就会在重连后整段丢帧。
3. 执行器 `file.*` 的条目必须是**工作空间根相对**，本机与 SSH 同形（否则 spec reset 路径会多一层）。
4. 核心 `stdout` 只允许握手行，日志走 `stderr`；核心 stderr 若无人读且是管道，会在 shutdown 时卡住。
5. 网络/LLM/时钟不进单测：用假传输、假时钟、可注入节拍器。
6. 用例判据**挂在证据上，不要挂在挂钟上**（known-issues #42）：订阅成功的同步回证是点名本站的
   `reset` 帧；注册/注销轮询 `/api/meta` 的 `ui[].connections`；每轮前先确认
   `missed_heartbeats` 已被新入站心跳清零。放宽 sleep 治不了这一类。

---

## 5. 接手第一小时

1. 读本文 §1；再读 [ui-pluginization.md](pluginization/ui-pluginization.md) §1、§4（不要读全过程记录）。
2. 按 §4 跑一遍 `tree_protocol` + `tree_core` 门禁，确认与 [project-status.md](project-status.md) 的基线一致。
3. `dart run tool/dev_run.ps1` 起一次，确认 UI 附着、插件列表、终端可用。
4. 从 [project-status.md](project-status.md) 的车道挑一件；**先改文档口径，再改代码**（避免半截漂移）。
5. 提交前按 §4 全量过门禁；两仓分别提交。

**不要做**：不要给插件路由补核心 handler；不要让 UI 直连执行站；不要把大文件塞进 JSON；
不要用 PATH 里的 `dart`；不要动 `git config`；不要未经确认就 push / 打 tag / 删 tag。
