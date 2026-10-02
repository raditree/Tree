# Tree

<img src="docs/images/logo.png" width="104" align="right" alt="Tree">

**LLM 驱动的 agent 团队桌面工作台**：按任务难度动态组建 agent 团队，让多个 agent 在同一个项目目录里协作，全部逻辑跑在**本机单进程**里——无服务器、无账号、无云端。

- **界面**：Flutter 桌面应用（三栏：agent 列表 ｜ 会话与工具卡片 ｜ 文件 / 模型 / 提问面板）
- **核心**：纯 Dart 进程 `tree_core`（`dart compile exe` 单文件，约 10 MB，无需运行时）
- **平台**：Windows / Linux / macOS（维护配置：Flutter 3.47.5 + Dart 3.13.4）
- **数据**：全部在 `%APPDATA%\Tree`（可用 `TREE_HOME` / `--data-dir` 覆盖），明文配置、可直接手改

## 亮点

- **团队即能力**：leader 用 `team` 工具创建成员、用 `message` 派活与 `wait_for` 等交付；成员与 leader **共享同一个工作目录**（同一个项目），私有状态按 agent 分栏。
- **Spec（规范）体系**：把"这类活怎么干"沉淀成规范文件，开工第一步挂规范，长任务里规范全文进系统提示词；内置 general-task / hard-task / team-meeting / plugin-creator。
- **可扩展**：MCP（stdio 与 Streamable HTTP）+ 插件站点体系（广播 / 执行 / 中转 / 收集，17 个点位），插件能接管 LLM 这一跳、改工具调用前后的数据、申报自己的工具与 UI 槽位。
- **本地与 SSH 双模式**：工具、文件面板、Git 面板同一套语义；SSH 模式下的 agent 在远端主机/容器里读写，**成员跟随 leader 的 SSH**。
- **为长会话省 token**：系统提示词按会话钉住（只在会话初始化 / 压缩后重建）、工具表每轮刷新（不进消息前缀）、工具结果过长自动截断到工作空间并只送模型一份预览——前缀缓存能持续命中。
- **不按时间杀任务**：M9 起取消一切静态超时，判活只认心跳/进程存活；远端成员失联会以**显式错误 + 部分结果**收口，绝不静默丢消息。

## 架构一览

```
┌──────────────── Flutter UI 进程 ─────────────────┐
│ ApiService / WebSocketService                    │
└───────────────────────┬──────────────────────────┘
                        │ 127.0.0.1 随机端口 + 一次性 token（仅经 stdout 握手）
┌───────────────────────┴──────────────────────────┐
│ tree_core（纯 Dart，单文件可执行）                 │
│  CoreServer        路由 / 鉴权 / 覆盖度不变量       │
│  ConversationService + LlmAgentEngine             │
│                    会话 / 工具循环 / 压缩 / 缓存    │
│  WorkspaceIO       Local（dart:io）/ SSH（dartssh2）│
│  TreeStore         yaml 配置 + jsonl 会话           │
│  Team / Spec / MCP / Plugin 子系统                 │
└──────────────────────────────────────────────────┘
```

细节见 [架构文档](docs/architecture.md) 与各模块 README（[core](packages/tree_core/README.md) / [protocol](packages/tree_protocol/README.md) / [local_exec](packages/tree_local_exec/README.md) / [cli](packages/tree_core_cli/README.md) / [UI](lib/README.md)）。

## 快速开始（从源码）

```powershell
# 1) 编译核心
dart compile exe packages/tree_core_cli/bin/tree_core.dart -o build/windows/x64/runner/Debug/tree_core.exe
# 2) 运行应用（会自动找到并拉起核心）
flutter run -d windows
```

一条命令出便携包（构建 + 编译核心 + 自检 + 压 zip）：

```powershell
dart run tool/package_windows.dart --flutter "<flutter.bat 的路径>"
# 产物：dist/tree-desktop-<版本>-windows-x64.zip
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
| [docs/architecture.md](docs/architecture.md) | 进程模型、会话与工具循环、工作空间与私有目录、团队、存储、插件/站点体系 |
| [docs/development.md](docs/development.md) | 环境、构建、测试矩阵、打包与安装包、调试、发布检查单 |
| [CONTRIBUTING.md](CONTRIBUTING.md) | 开发规则约束：提交规范、测试要求、文档制度、跨模块不变量 |
| [docs/team.md](docs/team.md) | 团队与成员语义（共享工作目录、私有分栏、SSH 跟随、会话并行、派活与回信） |
| [docs/plugin-development.md](docs/plugin-development.md) | 写插件的系统指南（协议、17 个点位、scope、执行站命令、流式接管） |
| [docs/known-issues.md](docs/known-issues.md) | 已知问题台账（现象 / 根因 / 修复 / 验证） |
| [docs/README.md](docs/README.md) | 全部文档索引（含历史与设计稿） |

## 分支说明

- `desktop`（当前分支）：后端逻辑已迁入本机核心进程，**单机桌面应用**；`server/` 已于 M7 删除。
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
- 所有直接或间接支撑本项目的开源软件与贡献者。
