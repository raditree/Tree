# Tree

<img src="docs/images/logo.png" width="104" align="right" alt="Tree">

**插件化的 LLM agent 团队桌面工作台**：内核只做调度，能力全部由插件提供，连界面本身也是一份可装卸的插件。

- **界面**：Flutter 桌面应用，作为 `runtime: ui` 插件运行（可安装 / 卸载 / 替换；多窗口 = 多个 UI 插件进程）
- **内核**：纯 Dart 进程 `tree_core`，只保留 **35 条永久路由**（平台控制面、传输设置、引导壳、发现面）
- **功能插件**：agent、文件、本机 / SSH 执行、MCP、压缩、自迭代……各自承接原属核心的领域端点
- **平台**：Windows / Linux / macOS（维护配置：Flutter 3.47.5 + Dart 3.13.4）
- **数据**：全部在 `%APPDATA%\Tree`（可用 `TREE_HOME` / `--data-dir` 覆盖），明文配置、可直接手改

## 亮点

- **agent 能力全在插件**：会话、工具循环、上下文压缩、团队协作、提问、用量与 Spec 体系都在 `tree.agent` 里；内核不认识 agent / 会话 / 团队 / 模型。
- **插件平台的三类贡献面**：**广播站**（增量事件）、**收集站**（当前态快照 / 能力申报）、**委派**（插件承接 REST 端点）。站点分广播 / 执行 / 中转 / 收集四类，点位由插件在运行期申报——核心不维护静态能力清单，新增能力不需要核心发版。
- **路由即申报**：内核只硬编码自己的 35 条；其余 55 条由插件启动时经 `system.collect.api.routes` 申报，核心只做归属转发与响应校验（契约全集 90 条）。
- **UI 即插件**：同一插件内可开多个窗口（`w1`/`w2`…，核心拉起进程并注入 `TREE_UI_WINDOW_ID`），多个 UI 插件也可并存；全部 UI 被卸载时由不可卸载的极小引导壳接管插件管理。
- **文件与终端下沉执行器**：`local_executor` / `ssh_executor` 在插件内部定义执行站命令；UI 与 agent 都只经它们读写文件、开终端。SSH 终端复用 agent 已登记的租约，UI 不持有凭据。
- **Spec（规范）体系**：把"这类活怎么干"沉淀成规范，开工挂规范、长任务里全文进系统提示词；内置 general-task / hard-task / team-meeting / plugin-creator。
- **本地与 SSH 双模式**：工具、文件面板同一套语义；SSH 下 agent 在远端主机 / 容器里读写，**成员跟随 leader 的 SSH**。
- **harness 即 IDE**：不用离开应用就能改代码、跑命令——右侧文件面板直接编辑并保存（`Ctrl+S`、失焦自动保存、冲突检测），`Ctrl+J` 打开真·伪终端；改的跑的都在同一个项目目录里。

## 架构一览

```
┌──────────── 引导壳 Tree.exe（非 Flutter，不可卸载）────────────┐
│  拉起内核；全部 UI 卸载时打开核心自带的静态插件管理页             │
└───────────────────────────┬────────────────────────────────┘
                            │ 拉起
┌───────────────────────────┴────────────────────────────────┐
│ 内核 tree_core（纯 Dart，单文件可执行）                        │
│  CoreServer      35 条永久路由 / 鉴权 / 覆盖度不变量           │
│  PluginBus       进程表 · 站点总线 · 路由归属转发（35 + 55）    │
│  WsStationBridge UI 订阅 / 四态投递（data·closed·lagged·reset）│
│  Logs            插件日志落盘（PluginLogSink）                 │
└───────┬───────────────────────────────┬────────────────────┘
        │ stdio JSON-RPC 2.0            │ WebSocket（TREE_CORE_URL/TOKEN）
┌───────┴─────────────────┐      ┌──────┴──────────────────────┐
│ 功能插件（headless）      │      │ UI 插件（runtime: ui）        │
│ tree.agent / files /    │      │ tree-ui-default（可多窗口）   │
│ local_executor /        │      │                             │
│ ssh_executor / mcp /    │      │                             │
│ compact / extra-tools / │      │                             │
│ self_updater            │      │                             │
└─────────────────────────┘      └─────────────────────────────┘
```

内核的 35 条永久面 = 平台控制面 20（含 UI 多窗口 3、本地 zip 安装 1）+ 传输设置 11（含发布源设置 3）+ 引导壳 3 + 发现面 1。细节见 [架构文档](docs/architecture.md)、[UI 插件化](docs/pluginization/ui-pluginization.md) 与 [agent 插件化](docs/pluginization/agent_pluginization.md)。

## 插件清单

| 插件 | 角色 | 承接 / 能力 |
| --- | --- | --- |
| `tree.ui.default` | **ui** | 默认图形界面（Flutter，源码在插件仓 `plugins/tree.ui.default/`）；零依赖，自持 `lib/io/protocol_contract.dart` |
| `tree.agent` | headless | agent 与会话、工具循环、压缩、团队、提问、用量、Spec（含原生 `spec` 工具）、自建事件广播站、执行器激活站 |
| `files` | headless | 文件面板 13 条 REST（本机与 SSH 同形：列表 / 内容 / 读写 / PDF / 上传 / 同步 / 打包 / 结构改动） |
| `local_executor` | headless | 本机执行站：`file.*` / `exec.command` / 终端会话（PTY + 广播站输出） |
| `ssh_executor` | headless | SSH 工作空间执行站：`ssh.file.*` / `ssh.exec.command` / SSH 终端；目标机按需推送 `tree_agent` |
| `mcp` | headless | MCP 服务管理 3 条 REST 与工具接入 |
| `compact` | headless | 上下文压缩中转站（失败自动回退内置压缩） |
| `extra-tools` | headless | 补充工具定义 |
| `self_updater` | headless | 框架自迭代：列插件 / 看阶段 / 转储 / 热重启（含自重启） |

`plugins/` 下的 `minimal` / `sample` / `suspendable` / `terminal_probe` 是测试与示例插件，`_kit` 是插件仓公共骨架。插件源码独立成仓，本仓 `plugins/` 是它的本地 clone。

**UI 源码也在插件仓**（`plugins/tree.ui.default/`，Flutter 工程）：桌面仓只留内核、引导壳、发布工程与文档。界面门禁与 `flutter` 命令都要先进那个目录（见下）。

## 快速开始（从源码）

```powershell
# 开发回路：脚本起核心（stdout 握手），再把 URL / token 注入 flutter run
# （脚本会在 plugins/tree.ui.default 里跑 flutter run）
.\tool\dev_run.ps1

# 单独编译内核
dart run tool/build_core.dart --out dist/tree_core.exe

# 编译插件仓全部插件（逐个 --selftest，并写发布索引；runtime: ui 会显式跳过）
dart run tool/build_plugins.dart

# 出便携包（在 UI 目录构建 + 编译核心 + 自检 + 压 zip）
# --ui-dir 默认 plugins/tree.ui.default
dart run tool/package_windows.dart --flutter "<flutter.bat 的路径>"
# 产物：dist/tree-desktop-<版本>-windows-x64.zip

# 把 UI 发行目录打成 UI 插件包（tree-ui-default-<版本>.zip）+ 合并发布索引
dart run tool/package_ui_plugin.dart --build

# 界面自己的门禁（在插件仓的 UI 工程里跑）
cd plugins/tree.ui.default
flutter pub get; flutter analyze lib; flutter test
```

完整环境要求、测试矩阵、打包与安装包流程、调试技巧（附着模式 / 只跑核心 / 真机 SSH 门控测试）：[开发文档](docs/development.md)。

## 数据与配置

```
%APPDATA%\Tree\                     # Windows；TREE_HOME / --data-dir 可覆盖
├── config/                          # settings.yaml / models/*.yaml / mcp.yaml / plugins.yaml
├── agents/<agent_id>.yaml           # agent 与团队成员（ssh、workspace_dir、system_prompt…）
├── data/<agent>/<session>/          # session.json + messages.jsonl（一行一条，追加写）
└── workspaces/<agent_id>/           # 默认工作空间（可在 agent yaml 里改；SSH 则是对端工作空间）
    ├── <项目文件…>                   # 团队共享
    └── .tree/<agent_id>/.self/      # 每个 agent 的私有状态（提示词 / 规范 / 结果 / 活动日志）
```

## 文档

| 文档 | 内容 |
| --- | --- |
| [docs/plugin-platform.md](docs/plugin-platform.md) | **插件平台硬约束与决策记录**：22 条硬约束、D-1~D-11 拍板、文件地图、门禁顺序 |
| [docs/architecture.md](docs/architecture.md) | 进程模型、站点体系、路由归属、工作空间、团队、存储 |
| [docs/development.md](docs/development.md) | 环境、构建、测试矩阵、打包与安装包、调试、发布检查单 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 开发规则约束：提交规范、测试要求、文档制度、跨模块不变量 |
| [docs/pluginization/ui-pluginization.md](docs/pluginization/ui-pluginization.md) | UI 插件化与核心收束（核心侧唯一事实来源） |
| [docs/pluginization/agent_pluginization.md](docs/pluginization/agent_pluginization.md) | agent 能力插件化（`tree.agent` 承接范围与契约） |
| [docs/pluginization/ui-pluginization_acceptance.md](docs/pluginization/ui-pluginization_acceptance.md) | 逐批次验收清单与台账 |
| [docs/plugin-development.md](docs/plugin-development.md) | 写插件的系统指南（协议、站点与点位、scope、执行站命令、流式接管） |
| [docs/team.md](docs/team.md) | 团队与成员语义（共享工作目录、私有分栏、SSH 跟随、会话并行、派活与回信） |
| [docs/known-issues.md](docs/known-issues.md) | 已知问题台账（现象 / 根因 / 修复 / 验证） |
| [docs/README.md](docs/README.md) | 全部文档索引（含历史与设计稿） |

## 分支说明

- `desktop`（当前分支）：单机桌面形态，内核 + 插件进程 + UI 插件；`server/` 已于 M7 删除。
- `main`：保留"Flutter 前端 + Python 后端"的服务端形态（旧 SDK 工具链）。

两条线在独立 git worktree 中并行开发，**不迁移数据**。

## 许可

[MIT](LICENSE)。

## 致谢

机制设计大量借鉴了优秀的研究与开源成果：

- **Anthropic / Claude Code** —— Spec 机制即 Skill 机制的思想来源（规范三件套、todo、AskUserQuestion、Hook 后台任务）。
- **MCP 社区** —— Model Context Protocol，`mcp` 工具与全局 MCP 服务管理构建于其上。
- **dartssh2** —— 纯 Dart SSH/SFTP 客户端，支撑 SSH 运行模式。
- **Flutter / Dart 团队**，以及 OpenAI Chat Completions 协议、FastAPI、Docker 等生态。
