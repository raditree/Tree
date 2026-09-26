# Tree — Agent 团队桌面效率工具

LLM 驱动的 **agent 团队桌面效率工具**：根据任务难度动态组建 agent 团队，让 LLM agent 通过 Git 仓库层级协作，全部逻辑跑在**本机单进程**里。

- **前端**：Flutter 桌面应用（三栏式界面：agent 列表 | 消息交互 | 文件管理）
- **核心**：纯 Dart 进程 `tree_core`（可 `dart compile exe` 成单文件），持有全部 LLM / 工具 / 存储 / 团队 / Spec / MCP / 插件逻辑
- **平台**：Windows / Linux / macOS 桌面（Flutter 3.47.5 / Dart 3.13.4，已放弃 Windows 7/8）

> **分支说明**：`desktop` 分支把后端逻辑迁入本机核心进程，最终形态是**单机桌面
> 应用**——无后端服务、无账号体系、无 Docker/云端模式、无跨设备同步。`main` 分支保留
> "Flutter 前端 + Python 后端"的服务端形态；两条线在**独立 git worktree** 中并行开发：
>
> - 服务端线（`main`）：Flutter 3.7.12 / Dart 2.19.6（旧 SDK `D:\app\flutter\flutter`），保留 `server/` 与服务端数据；
> - 桌面线（`desktop`，本 worktree）：Flutter 3.47.5 / Dart 3.13.4，核心在 `packages/`，`server/` 已于 M7 删除。
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
| 只跑核心的协议与链路测试 | `cd packages/tree_core && dart test`（299 例，含真实 HTTP + WS 端到端） |
| 真 SSH 集成测试（本机无 sshd 时自动跳过） | 设 `TREE_SSH_TEST_HOST` / `TREE_SSH_TEST_USER` / `TREE_SSH_TEST_KEY` 后 `cd packages/tree_local_exec && dart test` |
| 真机 SSH 文件面板（列举/上传/打包/同步） | 设同样变量（可加 `TREE_SSH_TEST_ROOT`）后 `cd packages/tree_core && dart test test/ssh_files_integration_test.dart` |

### 打包（桌面发布形态）

一条命令出便携包（构建应用 + 编译核心 + 自检 + 压缩 zip）：

```powershell
# 用与构建应用同一个 SDK 的 dart 运行脚本（混用 SDK 会出现 AOT 产物与
# Flutter 引擎不匹配的怪问题）
& 'D:\app\flutter-sdk-3.47.5\flutter\bin\cache\dart-sdk\bin\dart.exe' `
    run tool/package_windows.dart `
    --flutter 'D:\app\flutter-sdk-3.47.5\flutter\bin\flutter.bat'
# 产物：dist/tree-desktop-1.0.0-windows-x64.zip
```

脚本做的事（以及为什么必须由脚本做）：

1. `flutter build windows --release`；
2. 用**同一个 SDK** 的 dart 把核心编译成 `tree_core.exe` 放进 Release 目录——
   发行版布局要求核心与 `Tree.exe`（`windows/CMakeLists.txt` 的 `BINARY_NAME`）**同目录**（`CoreProcessLauncher` 的解析顺序）；
3. 把 `build/native_assets/windows/*.dll`（pdfrx 的 `pdfium.dll`）拷到 exe 旁边：
   Dart native assets 只写进 `NativeAssetsManifest.json`，**不会**自动进发行目录，
   漏了这一步用户一打开 PDF 就报找不到 pdfium；
4. 写入 `使用说明.txt`（首次运行指引：数据目录、可直接手改的配置文件、常见问题）；
5. **自检**：真的启动一次打包好的核心，读到握手再让它优雅退出；
6. `tar -a -cf` 压成 zip（Windows 10+ 自带 bsdtar），产物在 `dist/`。

只要核心单文件（例如自己写壳）：`dart run tool/build_core.dart`，默认输出
`dist/tree_core.exe`（约 10 MB，无需 Dart 运行时）。

安装包（可选，需要 Inno Setup 6）：

```powershell
dart run tool/package_windows.dart --installer      # 自动探测 iscc 并编译
dart run tool/package_windows.dart --installer --iscc "D:\app\Inno Setup 6\ISCC.exe"
# 或手工：ISCC.exe /DAppVersion=1.0.0 /DReleaseDir="<...>\Release" tool\installer\tree-desktop.iss
```

`iscc` **不需要在 PATH 上**：脚本会依次探测 PATH 与常见安装目录（`C:\Program Files
(x86)\Inno Setup 6`、`D:\app\Inno Setup 6`、`%LOCALAPPDATA%\Programs\Inno Setup 6`），
找不到才提示用 `--iscc` 指定——Inno 默认不把自己加进 PATH，只报「没有 iscc」会让人
以为装失败了。

`tool/installer/tree-desktop.iss` 会把整个 Release 目录（含 `tree_core.exe` 与
`pdfium.dll`）装进同一个目录、建开始菜单与桌面快捷方式；

- **默认每用户安装**（`PrivilegesRequired=lowest` → `%LOCALAPPDATA%\Programs`，不弹 UAC）；
  需要装到 Program Files 时用 `setup.exe /ALLUSERS` 或右键以管理员身份运行；
- **卸载不动 `%APPDATA%\Tree`**（模型密钥、agent 配置、会话记录是用户数据，不静默删）。

安装包自检（本仓库验证过的流程）：静默装到临时目录 → 检查 `Tree.exe` / `tree_core.exe` /
`pdfium.dll` / `使用说明.txt` 是否齐 → **用装好的核心跑一遍冒烟与文件写路径测试** →
静默卸载并确认无残留：

```powershell
$dir = "$env:TEMP\tree_probe"
Start-Process -Wait .\dist\installer\tree-desktop-1.0.0-windows-x64-setup.exe `
  -ArgumentList "/VERYSILENT","/SUPPRESSMSGBOXES","/NORESTART","/MERGETASKS=\"!desktopicon\"","/DIR=`"$dir`""
$env:TREE_CORE_EXE = "$dir\tree_core.exe"
cd packages\tree_core_cli; dart test test/binary_smoke_test.dart
Start-Process -Wait "$dir\unins000.exe" -ArgumentList "/VERYSILENT","/SUPPRESSMSGBOXES","/NORESTART"
```

门控冒烟测试（验证编译产物本身能起、能握手、能鉴权、能优雅退出）：

```powershell
$env:TREE_CORE_EXE='E:\programs\Tree\desktop\dist\tree_core.exe'
cd packages\tree_core_cli; dart test test/binary_smoke_test.dart
```

### 里程碑进度

- **M0a / M0b**：升级 Flutter 3.47.5 / Dart 3.13.4（放弃 Windows 7/8）；建立 `packages/` 纯 Dart 包骨架；协议冻结 + 完备性门禁
- **M1a**：`tree_core` 回环 HTTP + WS 服务（握手、本地 token 鉴权、路由与覆盖度不变量、WS 分帧与心跳、内存存储、流式回复骨架）
- **M1b**：前端接管（启动/附着核心、去登录与账号设置，`lib/ui` 零改动对接）
- **M2**：`~/.tree` 的 yaml（配置）+ jsonl/快照（会话）持久化，替换 M1 的内存存储
- **M3**：真实 LLM（手写 OpenAI 兼容 SSE + 完整工具循环语义：用量累计、上下文裁剪、取消、tool_call 回灌）
- **M4a**：本机工作空间 IO（read/write/edit/grep/terminal 与进程树终止、非 UTF-8 输出标记）
- **M4b**：`set_todo_list` + 后台 hook 模式 + SSH 工作空间（dartssh2 传输 + 远端根解析，语义单测 + 门控真机测试）
- **M4c / M4d**：待办 REST / Git 与模型信息等前端所需路由
- **M5a**：`ask_user_question` 提问回路（提问落盘 + 卡片帧 + 作答/取消/超时 + 重启补答 + REST 与历史叠加）
- **M5b**：团队数据模型（**成员即 agent**，团队字段写进 `agents/<id>.yaml`）+ `team` 工具 + 成员审核闸门 + 团队成员 REST + 成员级模型参数覆盖
- **M5c**：`message` 工具 + 消息派发（审核闸门、活动日志、`wait_for`、附件）+ 级联停止（含排队任务丢弃）
- **M5d**：Spec 体系（内置模板内嵌 + 自定义 spec 落盘工作空间、`spec` 工具、specs REST）+ 会话状态注入（todo / 已选 Spec 进入模型上下文）
- **M6a**：MCP（stdio JSON-RPC 客户端 + `mcp` 工具 + 已就绪 MCP 工具原生注入 + 服务注册 REST）
- **M6b**：插件总线 + 进程外插件宿主（`config/plugins.yaml`、`plugin__<id>__<tool>` 原生工具、事件分发、心跳巡检、快照 REST）
- **M6c**：插件 WS 增量（`plugin_status` 注册/停用、`plugin_event` 插件通知）
  - 说明：参考实现的"处理站（stations，插件间订阅路由）"**未在桌面端实现**——单用户本机插件以工具与事件为主，快照里的 `stations` 恒为空数组（字段保留，前端显示 0）；如需该能力再单独立项
- **M6a**：MCP（stdio JSON-RPC 客户端 + `mcp` 工具 + 已就绪 MCP 工具的原生注入 + 服务注册 REST）
- **M7a**：打包（`dart run tool/build_core.dart` → 单文件 `tree_core.exe`；`TREE_CORE_EXE` 门控的真可执行文件冒烟测试：握手 → HTTP 鉴权 → shutdown 优雅退出）
- **M7b**：删除 `server/`（服务端 Python 整体移除）；完备性门禁从"扫 Python 源码"改为"扫本仓库源码"；README 改写为桌面架构
- **M7d-1**：工作空间文件服务（目录树 / 文件内容 / PDF 基本信息 / Git 历史与分支；路径安全边界 + 可读错误）
- **M7c**：前端"运行模式"改为写 agent 配置（`workspace_dir` / `ssh` 经 `PATCH /api/agents/{id}`，核心据此决定工具在哪跑）；**删除前端执行引擎**（`ssh_workspace_executor` / `mcp_stdio_tunnel` / `plugin_host_sessions` + 两个执行器服务改为配置适配器）与**反向执行协议**（7 个上行 + 7 个下行帧、WS 处理者注册表、核心桩）
- **M7d-2**：文件下载 + 前端路径门禁收紧（`Uri.parse('$baseUrl/api/...')` 这类调用点此前全部漏检）
- **M7d-3**：文件写路径——分片上传（`upload_init+chunk+complete`，分片顺序追加到系统临时文件后整体落 `.input/{yyyymmdd}/`）、`syncToLocal`（核心与前端同机，直接复制整棵工作空间、排除 `.git`）、`download_folder`（系统 `tar` 打包 tar.gz，先按未压缩大小设上限）。**删除 multipart `upload` 通道**：小文件走分片只多两次轻量请求，却少维护一条契约。附带修掉两个只有真跑才暴露的问题：中文文件名/目录的 `Content-Disposition` 会让 `dart:io` 抛 `FormatException`（改用 RFC 5987 `filename*`）、未捕获异常时 500 回包本身也会失败导致客户端只看到"连接被关掉"（新增 `errorLog` 落到 stderr）；真 exe 冒烟测试扩到"上传 → 打包下载 → 同步到本地"全链路
- **M7d-4**：上下文压缩——`POST /api/agents/{id}/compact` 把会话早期历史交给模型总结成一条摘要，此后每轮只发「摘要 + 未压缩的近期消息」；保留规则 = 最近 3 条用户要求及其之后 + 尾部 8 条，单轮超长时退化为只留尾部；**不删除任何消息**（水位线是 `session.json` 里的"已总结前缀条数"，界面历史完整可回看）；估算超过 `compress_threshold × max_seqlen` 时在生成前自动压缩；压缩期间推 `agent_status=compacting` 并与生成互斥（`agent_working` / `already_compacting`）；旧摘要并入新摘要，不会越压越多
- **M7e**：PDF 预览改成**前端渲染**（方案②）——核心只提供 PDF 字节（`/download`），光栅化交给 Flutter 插件 pdfrx（内置 pdfium）：`PdfPreview` 组件替掉旧的"核心逐页渲染成 PNG + 自绘翻页栏"，滚动/缩放/翻页/选中复制都由插件处理。删掉 `pdf_preview` 接口与前端的 `getPdfPreview`，核心的 501 桩集合因此**清空**（覆盖度测试也改成断言"空集合"，别让桩悄悄长回来）；打包脚本新增 native assets 拷贝（否则发布包缺 `pdfium.dll`）
- **M7g**：SSH 远端文件面板——`SshTransport` 增加 SFTP 一层目录列举（名字/类型/大小/mtime），`WorkspaceFiles`（列目录 / 读字节 / 写字节）由 `LocalWorkspaceIO` 与 `SshWorkspaceIO` 各自实现，`FileService` 按 agent 是否配 `ssh:` 分流：list/content/download/pdf_info 读远端字节，分片上传仍是「本地暂存 → complete 时一次 SFTP 写」，`download_folder` 先把子树拉回本地临时目录再本地 tar 打包（远端不一定有 tar，且二进制过 `exec` 会被当文本解码），`syncToLocal` 补上**条数 + 字节双上限**（真机验收在巨大远端根上被拖到超时，光有条数限制挡不住）。真机验收：`open@192.168.0.208:22`（密钥 `~/.ssh/id_ed25519`），`TREE_SSH_TEST_HOST` 门控测试跑通全链路
- **M7f**：Windows 打包与安装——`tool/package_windows.dart` 一条命令出便携 zip（构建应用 + 用同一 SDK 编译核心到同目录 + 写首次运行说明 + 启动核心读握手自检 + bsdtar 压缩），`tool/installer/tree-desktop.iss` 提供 Inno Setup 安装包（卸载保留 `%APPDATA%\Tree` 用户数据）
- **M7（剩余）**：
  - 远端 Git 面板（`gitLog`/`gitBranches` 目前对 SSH 仍返回可读 400：需要经 `exec` 跑 git 再解析输出）；SSH 连接的断线重连策略调优

---

## 功能特性

- **单进程、无后端**：Flutter UI + 核心进程；无账号体系、无 Docker/云端模式、无跨设备同步。
- **本地 / SSH 工作空间**：本地直接在工作目录里执行工具；SSH 用 `dartssh2` 连远端（连接由核心发起，IP 相对本机；私钥/口令存在用户自己的 `agents/<id>.yaml`）。
- **Agent 团队**：成员就是 agent（`agents/<id>.yaml` 里的 `team_id`/`parent_agent_id`/`level`）；层级与每层人数可配（默认 3 / 7）；**审核闸门**（未分配模型或未审核的成员不接收消息）；消息派发与**级联停止**；成员活动日志。
- **内置工具**：

  | 工具 | 说明 |
  | --- | --- |
  | `read` / `write` / `edit` / `grep` | 工作空间读写、精确替换（唯一匹配）、检索（自动排除依赖/构建目录） |
  | `terminal` | 本机 / 远端命令执行；**hook 模式**后台长任务（输出重定向到文件，结束后推送提示唤醒 agent 续跑） |
  | `set_todo_list` | 任务分解与增量进度汇报 |
  | `ask_user_question` | 向用户提问并等待作答（落盘、跨重启用） |
  | `team` / `message` | 建队 / 名册 / 档案 / 审核状态；派活、广播、等待完成 |
  | `spec` | 任务规范检索 / 选择 / 沉淀（4 个内置模板 + 工作空间自定义） |
  | `mcp` | 已注册 MCP 服务的工具（原生注入 + 兜底调用） |
  | `plugin` | 已加载插件的工具（同上） |

- **提问回路**：提问落盘 `data/questions.json` → 前端卡片 → 作答幂等 → 继续生成；`stop` 取消在途提问；重启后的补答会写回会话。
- **Spec 与会话状态**：`select` 之前必须先 `read`；每次工具结果前注入"当前 in_progress todo + 已选 Spec"，模型不会忘记约定。
- **MCP**：`config/mcp.yaml` 注册 stdio 服务，工具以 `mcp__<服务>__<工具>` 原生注入模型工具列表；服务不可用只影响自己（可读错误 + 重连一次）。
- **插件**：`config/plugins.yaml` 注册进程外插件，工具以 `plugin__<插件>__<工具>` 注入；事件总线（按 scope 过滤）+ 心跳巡检 + `plugin_status` / `plugin_event` 增量。
- **数据都在用户能直接看的地方**：`~/.tree` 下的 yaml / jsonl / 快照，可手改。

---

## 架构概览

```
┌────────── Flutter UI（lib/ui 零改动对接） ──────────┐
│ ApiService / WebSocketService → 127.0.0.1:<端口>    │
└──────────────────────┬──────────────────────────────┘
                       │ 本地回环 HTTP + WS（一次性 token，仅经 stdout 握手下发）
┌──────────────────────┴──────────────────────────────┐
│ tree_core（纯 Dart，可 dart compile exe 成单文件）    │
│  CoreServer      路由 + 鉴权 + 覆盖度不变量           │
│  LlmAgentEngine  OpenAI 兼容 SSE + 工具循环 + 用量/裁剪│
│  WorkspaceIO     Local / SSH（dartssh2）             │
│  TreeStore       ~/.tree：yaml 配置 + jsonl/快照会话  │
│  Team / Spec / MCP / Plugin 子系统                   │
└─────────────────────────────────────────────────────┘
```

---

## 项目结构

```
desktop/                       # desktop 分支（独立 git worktree）
├── lib/                       # Flutter 前端（ui 零改动；io 只做进程附着与传输）
├── packages/
│   ├── tree_protocol/         # 协议单一真源（WS 帧 / REST 路径 / 握手）+ 完备性门禁
│   ├── tree_local_exec/       # 本机与 SSH 工作空间 IO（dartssh2）
│   ├── tree_core/             # 核心：服务 / 存储 / LLM / 工具 / 团队 / Spec / MCP / 插件
│   └── tree_core_cli/         # tree_core.exe 入口 + 真进程端到端测试
├── tool/build_core.dart       # 打包脚本
└── test/                      # 前端测试
```

（`server/` 已于 M7 删除；服务端形态仍在 `main` 分支。）

---

## 配置与数据（`~/.tree`）

```
~/.tree/
├── config/
│   ├── settings.yaml          # 全局设置（帧率 / 主动延迟 / 消息切入 / 数据收集）
│   ├── models/<id>.yaml       # 模型（含明文 api_key；用户私有文件）
│   ├── mcp.yaml               # MCP 服务
│   └── plugins.yaml           # 插件
├── agents/<id>.yaml           # agent / 团队成员（含 ssh、workspace_dir、system_prompt）
├── spec/builtin/*.md          # 内置 Spec（首次启动写入，可查看 / 手改副本）
├── data/
│   ├── questions.json         # 提问记录（跨会话）
│   └── <agent>/<session>/
│       ├── session.json       # 会话元数据（原子快照）
│       └── messages.jsonl     # 消息追加日志（一行一条）
└── workspaces/<agent_id>/     # 默认工作空间（可在 agent yaml 里改）
```

Windows 上是 `%APPDATA%\Tree`；`TREE_HOME` 环境变量或 `--data-dir` 可覆盖。

---

## 常见问题

- **核心进程没起来**：检查 `TREE_CORE_URL` / `TREE_CORE_TOKEN` 是否指向手工启动的 `tree_core --verbose`；发行版布局下 `tree_core.exe` 应与 `Tree.exe` 同目录。
- **SSH 连不上**：连接由**核心**发起，地址需从本机可达；检查 `agents/<id>.yaml` 的 `ssh:` 段（`root` 为空 = 远端登录用户的 HOME）。文件面板对 SSH 的「工作空间根」就是这里的 `root`，`workspace_dir` 只对本地工作空间生效。
- **插件 / MCP 没生效**：看对应 yaml 的 `command` 是否可执行；`GET /api/plugin/snapshot` 与 `GET /api/mcp/services` 会给出 `disabled_reason` / `errors`。坏服务只影响自己。
- **模型不可用**：`~/.tree/config/models/<id>.yaml` 的 `base_url` / `api_key`，以及 agent 的 `model_id` 是否指向它。
- **改配置何时生效**：`agents/*.yaml` 与 `config/*.yaml` 在核心启动时读取；MCP / 插件也可经 REST 即时注册。

---

## 文档

- [开发规格（迁移方案与历史规格）](.trae/specs/)
- [里程碑进度](#里程碑进度)

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
