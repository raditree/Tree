# Tree — Agent 团队桌面效率工具

LLM 驱动的 **agent 团队桌面效率工具**：根据任务难度动态组建 agent 团队、适配无限上下文 LLM，提供 **云端 / 本地 / SSH 三种运行模式** 的混合工作流，让 LLM agent 通过 Git 仓库层级协作。

- **前端**：Flutter 桌面应用（三栏式工作界面：agent 列表 | 消息交互 | 文件管理），移动端自动切换为单栏 + 底部导航
- **后端**：Python / FastAPI 服务（REST + WebSocket），七核心组件（ws / agent / tool / io_ / llm / data / config）组件化装配
- **目标平台**：Windows 7+ / Linux 桌面 + Android 移动端（受 Flutter 版本约束，请勿升级 Flutter ≥ 3.19）

> **分支说明**：`desktop` 分支正在把后端逻辑迁入前端进程，最终形态是**单机桌面
> 应用**（无后端、无账号体系、无 Docker/云端模式）。迁移期间下方章节仍描述
> `main` 分支的"Flutter 前端 + Python 后端"架构，M7 删除 `server/` 后整体改写。
>
> **两条线并行开发**：本分支检出在**独立 git worktree** 中，`main`（服务端线）留在
> 原目录，两条线互不干扰：
> - 服务端线（`main`）：Flutter 3.7.12 / Dart 2.19.6（旧 SDK 在 `D:\app\flutter\flutter`），
>   保留 `server/`、`server/data/conversations.db`、`server/.venv` 与全部服务端配置；
> - 桌面线（`desktop`，本 worktree）：Flutter 3.47.5 / Dart 3.13.4，
>   核心进程在 `packages/`，长期目标是把 `server/` 整体删除。
>
> **两条线之间不迁移数据**：桌面线从空的 `~/.tree` 起步，服务端库（含历史会话与
> SFT 数据）仍只属于服务端线。

---

## desktop 分支：单进程架构与开发运行

**运行形态**是 Flutter UI 进程 + **核心进程**（纯 Dart，`packages/tree_core`）：
核心在 `127.0.0.1` 上监听**随机端口**并持有**一次性随机 token**，启动时把
`{port, token, pid, version}` 以单行 JSON（`CoreHandshake`）写到 stdout；UI 解析后
据此配置 `ApiService.baseUrl` / `WebSocketService.baseUrl` 与 token。REST 路径与 WS
帧的形状与既有后端完全一致，因此 `lib/ui`（约 15k 行）**零改动**。

```
┌──────────────── Flutter UI 进程 ─────────────────┐
│ main.dart → CoreProcessLauncher.start()          │
│   ① 附着模式：TREE_CORE_URL + TREE_CORE_TOKEN    │
│   ② 否则拉起 tree_core（应用同目录 → .output/）  │
│   ③ 读 stdout 首行握手 → 注入 baseUrl + token    │
│ ApiService / WebSocketService → 127.0.0.1:<port> │
└──────────────────────────────────────────────────┘
                        │ HTTP + WS（本地 token 鉴权）
┌──────────────── tree_core 进程 ──────────────────┐
│ CoreServer         路由 + 401/501/404            │
│ MemoryStore        M1 内存；M2 落 ~/.tree        │
│ ConversationService + ReplyEngine（M1 固定回显） │
└──────────────────────────────────────────────────┘
```

### 开发运行

```powershell
# 1. 编译核心进程（首次，或核心代码改动后）
dart compile exe packages/tree_core_cli/bin/tree_core.dart -o .output/tree_core.exe

# 2. 运行应用（自动定位 .output/tree_core.exe 并拉起）
flutter run -d windows
```

核心可执行文件的查找顺序：`TREE_CORE_EXE` 环境变量 → **应用同目录**（发行版布局：
M7 打包时把 `tree_core.exe` 与 `Tree.exe` 放在一起）→ 从应用目录向上 8 层查找
`.output/tree_core.exe`（开发期）。都找不到时应用显示**带修复指引的错误页**，而不是白屏。

关闭应用窗口时，应用会向核心 stdin 写一行 `shutdown` 请它优雅退出（超时再强杀），
不会留下孤儿进程。

### 调试技巧

| 需求 | 做法 |
| --- | --- |
| 单独调试/重启核心（不必重启应用） | 先跑 `tree_core.exe --port 8001 --verbose`，再给应用设 `TREE_CORE_URL=http://127.0.0.1:8001` 与 `TREE_CORE_TOKEN=<握手行里的 token>` |
| 查看核心请求日志 | 核心加 `--verbose`（访问日志走 stderr；stdout 只放握手行） |
| 只跑核心的协议与链路测试 | `cd packages/tree_core && dart test`（49 例，含真实 HTTP + WS 端到端） |

### 里程碑进度

- **M0a / M0b**：升级 Flutter 3.47.5 / Dart 3.13.4（放弃 Windows 7/8）；建立 `packages/` 纯 Dart 包骨架；协议冻结 + 完备性门禁
- **M1a**：`tree_core` 回环 HTTP + WS 服务（握手、本地 token 鉴权、路由与覆盖度不变量、WS 分帧与心跳、内存存储、流式回复骨架）
- **M1b**：前端接管（启动/附着核心、去登录与账号设置，`lib/ui` 零改动对接）
- **M2**：`~/.tree` 的 yaml（配置）+ jsonl/快照（会话）持久化，替换 M1 的内存存储
- **M3–M7**：真实 LLM → 工具层 → 团队编排 → 插件/MCP → 文档能力与打包（删除 `server/`）

---

## 功能特性

- **账号体系**：用户名 / 密码注册登录（已替换微信登录），JWT 会话；支持退出登录、注销账号（十日倒计时 + 数据保留 31 天后彻底删除）；登录接口带速率限制（防暴力破解）。
- **三种运行模式**（按顶部 agent 独立切换）：
  - **云端（cloud）**：后端 Docker 容器沙箱，初始化为 Git 仓库，具备白名单网络与下载上限；
  - **本地（local）**：前端在本机执行工具（后端经反向 WebSocket 委托）；
  - **SSH**：前端用纯 Dart 的 `dartssh2` 建立到远端主机的连接并执行（**IP 相对前端机器**），后端仅做模式判定与配置持久化。
- **Agent 团队**：动态组建层级团队（层级深度可配置，顶部 agent 为 Level 0，默认最大 2 级），成员在创建顶部 agent 时预建；每个 agent 拥有独立工作空间，用户仅直接可见顶部 agent 工作目录；团队成员消息经 broker 串行投递、工作成果经上下文隔离汇总。
- **模型接入**：OpenAI 协议统一接入，每个模型一个独立配置文件（`server/configs/models/*.yaml`），支持普通 LLM 与无限上下文 LLM（原子上下文管理）。
- **内置工具体系**（结构化模板，单一事实来源在 `server/prompt/versions/*/tools/builtin.yaml`）：
  - `read / write / edit`：文件读写与精确替换（含图像自动识别）；
  - `terminal`：沙箱命令执行，**hook 模式**支持后台长任务（输出实时重定向到工作空间文件，结束后自动推送 `[terminal hook]` 提示唤醒 agent 续跑，可 `status`/`cancel`）；
  - `mcp`：调用外部 MCP 能力（文档解析 / 搜索 / 第三方服务）；
  - `team`：成员管理、点对点/广播消息、任务指派与进度跟踪；
  - `set_todo_list`：任务分解与增量进度汇报；
  - `ask_user_question`：向用户提问；
  - `spec`：任务规范（Spec）的检索 / 选择 / 沉淀。
- **提问管理**：提问持久化到数据库并作为会话消息展示；agent 提问后主动暂停，用户在右侧问题面板随时作答（可跨断线/刷新），答后自动恢复执行；覆盖主 agent 与团队成员。
- **上下文管理**：普通 LLM 记忆管理 + 手动/自动上下文压缩；无限上下文 LLM 原子上下文管理；上下文持久化到数据库（重启不丢失）；集中式版本化提示词体系（`server/prompt/versions/`，含系统章节 / 工具描述 / 压缩器，可版本化审计与回滚）。
- **文件能力**：多格式文件查看器（UTF-8、docx/odt/doc/rtf/pdf/pptx/xlsx/xls/jpg/png、markdown/svg 预览、一键复制）、双向文件同步、Git 历史与分支查看。
- **数据与 SFT**：对话 / 提问 / 工具调用等数据入库，支持每日定时导出 SFT 数据集（仅配置的管理员可访问）。
- **安全**：白名单式出站网络（iptables + 出站代理）、单次下载数据量上限（<1G）、磁盘软上限告警；工作空间/文件/提问接口按用户归属校验；文本与 SSH 路径穿越防护；**SSH 密码不落后端库**（连接由前端发起，凭据仅存前端）；CORS 允许源与凭据随配置、杜绝任意源带凭据。

---

## 架构概览

后端对「工具执行」抽象为统一的 `WorkspaceIO`，按模式路由（优先级 `local > ssh > cloud`）：

```
后端 (Python / FastAPI)                          前端 (Flutter)
─────────────────────                            ─────────────
WS/REST 认证 + 会话                                JWT / token
mode_resolver 三模式判定 ── 配置/模式 ───────────▶ 模式开关 + SSH 配置
CloudWorkspaceIO ── Docker 容器（沙箱 + 白名单网络）
LocalWorkspaceIO ──tool_exec_request(反向 WS)──▶ LocalExecutorService 本机执行
SSHWorkspaceIO(委托)──tool_exec_request(反向 WS)─▶ SshExecutorService ─▶ dartssh2 ─▶ 远端主机
                   ◀── tool_exec_response ──────┘
```

- **云端**：命令在后端 Docker 容器内执行（隔离 + 沙箱）。
- **本地 / SSH**：后端只做模式判定与委托转发，真正的命令执行发生在前端本机 / 前端可达的远端主机上，`IP 相对前端`；SSH 配置（host/port/username 等定位信息）持久化在后端，**密码不传后端、不落库**。

---

## 项目结构

```
flutter_application_tree/
├── lib/                      # Flutter 前端
│   ├── main.dart             # 应用入口（登录态路由）
│   ├── io/                   # api / websocket / auth / 本地与 SSH 执行器 / 平台判断
│   └── ui/                   # 页面（登录/主界面/设置）+ 组件 + 数据模型 + 主题
├── server/                   # Python 后端（七核心组件）
│   ├── main.py / state.py    # 应用入口 + 全局状态容器
│   ├── ws/                   # WebSocket：认证、连接管理、消息处理
│   ├── agent/                # 会话主逻辑、路由、团队 broker、上下文隔离
│   ├── tool/                 # 内置工具 + hook 后台任务管理器
│   ├── io_/                  # WorkspaceIO 抽象 + 三模式 + 本地反向执行器 + Docker/SSH 管理
│   ├── llm/                  # LLM 会话（压缩 / thinking / usage / 限流）
│   ├── data/                 # SQLite 存储层 + 数据 REST
│   ├── config/ + configs/    # 配置加载 + app.yaml / 模型配置
│   ├── prompt/               # 提示词多版本体系（versions/）
│   ├── docker/               # agent 工作空间基础镜像
│   ├── mcp_tools/            # MCP 工具实现
│   └── tests/                # 后端测试
├── android/ ios/ linux/ macos/ web/ windows/   # Flutter 平台脚手架
└── .trae/specs/              # 开发规格文档
```

---

## 快速开始

### 1. 构建 Docker 工作空间镜像（可选）

```bash
docker build -t agent-workspace:latest server/docker
```

> 镜像需安装 `git` 与 `iptables`（用于沙箱白名单网络）。不重建镜像时，下载上限代理仍生效，但 iptables 白名单层不可用。

### 2. 配置后端

```bash
cd server
python -m venv .venv                  # 可选，建议使用虚拟环境
.venv\Scripts\pip install -r requirements.txt   # Windows
```

- 复制并填写模型配置：`server/configs/models/model.example.yaml` → `*.yaml`
- 修改 `server/configs/app.yaml`：服务端口、**JWT 密钥（生产环境务必修改默认值）**、CORS 允许源、Docker 资源限制、沙箱白名单等。

### 3. 启动后端

```bash
cd server
.venv\Scripts\python.exe main.py
```

启动后控制台输出 `Application startup complete`，服务监听 `0.0.0.0:8000`。

### 4. 启动前端

```bash
flutter pub get
```

- **Windows 桌面**（主平台）：

  ```bash
  flutter run -d windows
  ```

- **Linux 桌面**：需先安装构建依赖（Debian/Ubuntu）：

  ```bash
  sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev
  flutter run -d linux
  ```

- **Android**（模拟器/真机，需 Android SDK + JDK，minSdk 21+）：

  ```bash
  flutter run -d android
  ```

  后端地址：模拟器默认自动使用 `10.0.2.2:8000`（映射宿主机，应用内置）；
  真机请在「设置 → 后端配置」填写电脑的局域网 IP + 端口。

首次登录需注册账号（用户名 + 密码）。

---

## 配置说明

### 模型配置（`server/configs/models/*.yaml`）

每个 `.yaml` 文件一个模型，必填字段见 `model.example.yaml`。`is_limitless_context: true` 表示无限上下文 LLM。

### 应用配置（`server/configs/app.yaml`）

| 段 | 说明 |
| --- | --- |
| `server` | 服务监听地址与端口 |
| `cors` | 跨域允许源列表与是否允许凭据（默认不放任意源；**不可** `*` + 凭据组合） |
| `prompt` | 提示词体系版本选择 |
| `agents` | 每用户顶层 agent 上限、团队最大层级深度 |
| `docker` | 工作空间镜像、每层成员上限、CPU/内存/磁盘配额 |
| `upload` | 单文件大小上限、沙箱总大小上限（软上限告警） |
| `llm` | 单次调用超时、重试次数、主动延迟限流（rate_per_minute / min_interval_seconds） |
| `data_export` | 每日 SFT 导出时刻与管理员 openid 列表 |
| `sandbox.network` | 白名单式出站网络 + 单次下载上限 |
| `help_policy` | `help` 工具向 LLM 披露的团队规模与资源限制项 |
| `jwt` | 会话令牌密钥、算法与有效期（生产环境务必改默认密钥） |

---

## 常见问题

- **Docker 不可用**：后端会优雅降级，云端模式工作空间隔离、Git 层级协作、沙箱限制不可用；本地 / SSH 模式不受影响。
- **本地 / SSH 模式下命令执行不生效**：这两种模式需要前端保持 WebSocket 连接（前端承载执行）；检查执行器注册是否成功（设置页模式开关）。
- **SSH 主机连不上**：SSH 连接由**前端**发起，地址需从前端所在机器可达（相对前端，而非相对后端）。
- **模型 API 拉取失败**：不影响已配置的 YAML 模型；提供服务商不可达时仅跳过该提供商的运行期拉取。
- **Windows 7 支持**：请保持 Flutter 版本 ≤ 3.19，使用 Visual Studio 2019 Build Tools + Windows 10 SDK 10.0.19041.0 构建。
- **Android 模拟器连不上后端**：模拟器默认后端为 `10.0.2.2:8000`（已内置）；若后端监听 `0.0.0.0` 仍不通，检查防火墙。真机需在设置页填电脑局域网 IP。
- **Android 明文 HTTP 告警**：本地开发已开启 `usesCleartextTraffic="true"`（AndroidManifest.xml），可直接访问 `http://` 后端。
- **移动端功能限制**：本地执行模式、目录选择与系统保存对话框（file_picker 的 `getDirectoryPath`/`saveFile` 仅桌面支持）在 Android/iOS 不可用，界面已自动隐藏对应入口；文件下载在移动端保存到应用文档目录。
- **Linux 构建失败（缺 GTK）**：按「快速开始」安装 `clang cmake ninja-build pkg-config libgtk-3-dev`。

---

## 文档

- [后端文档](server/README.md)
- [开发规格](.trae/specs/)

---

## 许可协议

本项目基于 [MIT License](LICENSE) 开源发布。

---

## 致谢

本项目在机制设计与工程实现上大量借鉴了优秀的研究成果与开源项目，特此致谢：

- **Anthropic 与 Claude Code 团队** —— 本项目的 **Spec 机制即为 Skill（技能）机制**：规范驱动的开发流程（`spec.md` / `tasks.md` / `checklist.md` 三件套）、任务清单（todo）跟踪、向用户提问（AskUserQuestion）范式、以及 terminal 工具的 hook 后台任务（与 Claude Code 的 Hooks 一脉相承），均承袭自该体系的设计思想。
- **Anthropic 与 MCP 社区** —— **MCP（Model Context Protocol）** 开放协议，本项目的 `mcp` 工具与全局 MCP 服务管理即构建于该协议之上。
- **dartssh2 开源作者** —— 纯 Dart 实现的 SSH/SFTP 客户端，支撑了「前端发起连接」的 SSH 运行模式。
- **Google Flutter/Dart 团队** —— 跨端桌面 + 移动应用框架与工具链。
- **FastAPI 作者及社区** —— 高性能异步 Python Web 框架。
- **OpenAI** —— Chat Completions 协议，作为本项目 LLM 统一接入的基础。
- **Docker 及容器生态** —— 云端模式 agent 工作空间的沙箱隔离基础。
- 以及所有直接或间接支撑本项目的**开源软件与贡献者**。
