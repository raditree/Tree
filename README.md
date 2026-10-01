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
帧的形状与既有后端完全一致，因此 `lib/ui`（约 15k 行）在 M1 迁移时**零改动**即完成对接（后续里程碑按需演进）。

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
D:\app\flutter-sdk-3.47.5\flutter\bin\cache\dart-sdk\bin\dart.exe compile exe packages/tree_core_cli/bin/tree_core.dart -o build/windows/x64/runner/Debug/tree_core.exe

# 2. 运行应用（自动定位 .output/tree_core.exe 并拉起）
D:\app\flutter-sdk-3.47.5\flutter\bin\flutter.bat run -d windows
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
| 只跑核心的协议与链路测试 | `cd packages/tree_core && dart test`（含真实 HTTP + WS 端到端） |
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
- **M6c**：插件 WS 增量（`plugin_status` 注册/停用/健康度、`plugin_event` 插件通知）
  - 说明：当时"处理站（stations，插件间订阅路由）"未在桌面端实现，快照里的 `stations` 恒为空数组；**M9 Q11 已补齐站点体系**（广播站 / 执行站 / 中转站 + 新增收集站），`stations` 现在返回真实站点实例与订阅
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
- **M8a**：工作空间根口径与**软约束**——SSH 的根不收窄（`ssh.root` 留空 = 远端登录用户的 `HOME`，`~`/相对路径按远端 HOME 展开），文件面板与工具层同根；系统提示词在运行时追加「工作空间（软约束）」一段（数据/项目文件可能分处根下不同子目录、不得自行收窄），**不落库**且与压缩估算共用同一函数（否则阈值会失真）。顺带修掉前端 SSH 配置弹窗与核心 `SshConfig.parse` 的键名错位（弹窗写 `private_key_path` / `remote_base_dir`，核心只读 `key_path` / `root`，此前私钥会被静默丢弃、远端根永远落回 HOME），弹窗默认值也从 `/` 改为留空
- **M8b**：按需加载与增量传输——文件面板保持**逐层懒加载**（点开一层才列一层，根目录只发一次 `listdir`），`syncToLocal` 新增 `path`（空 = 根）：「同步到本地」只同步**当前所在目录**，不再默认拉整棵根；远端同步/打包去掉「先全树统计再复制」的双遍遍历，改为**边走边拉边算**（列一层复制一层，触顶即停并回报已处理进度）。真机验收 `open@192.168.0.208`：整棵 3 文件 / 5019 字节，子树 2 文件 / 19 字节
- **M8c**：单文件**不设大小上限**，改流式/分片——`WorkspaceFiles` 增加 `sizeOf` / `openRead(offset,length)` / `writeStream`（本地走 `dart:io`，远端走 dartssh2 的 `SftpFile.read(offset,length)` / `write(stream)`）；核心 `/download` 边读边发（`FileService.openDownload` + `http_io.writeStream`），上传去掉单文件上限、远端 `upload_complete` 改成流式写；`content` 预览先问大小、只读前 8 MB 并返回 `truncated`/`size`/`preview_bytes`（不再 413），PDF 信息对大文件只读头尾；前端查看器与文件面板都**流式落盘**，PDF 预览下载到临时文件后交给 `PdfViewer.file` 渐进加载
- **M8d**：左侧活动栏新增「下载」面板——`DownloadCenter`（全局任务状态机：running/done/failed/cancelled + 进度 + 取消）与 `DownloadPanel`；文件下载在后台流式进行，进度、取消、落盘路径都在列表里；**每条任务标注来源 team**（顶部 agent 名，缺名时退回 agent id），因为同一个列表里会混着不同 agent 工作空间的产物
- **M9**：14 项修复与优化（Q1–Q13 + 全局「心跳判活」规约）——收口 M7 遗留的远端 Git 与 SSH 判活/重连
  - **全局规约**：**一切静态时间超时取消**，判超时改看**心跳丢失**（I=10s / N=3，判活窗口 I×N=30s）；本地执行体活性 = **进程存活**（活着永不超时）；丢失必须**显式**报错/标记，不静默丢弃。详见[心跳判活口径](#心跳判活口径m9-规约)
  - **Q1** 上下文超限：工具结果按 **8000 token** 门控（全文落 `.self/results/`，送模型的只有"字符数 + 路径 + 300 字符预览"；界面与落库仍留全文）；**每轮 API 调用前**压缩；端点报超限自动压缩一次并重试该轮；`max_seqlen` 取不到不再默默兜 128000（显式提示）。Token 口径统一为 `tokens = ceil(字符数 / token_scale)`，`token_scale` 逐模型存 `models/<id>.yaml`（初值 2.00），端点回真实 `prompt_tokens` 破水位线时才学习
  - **Q2** 删除 cloud 运行模式：前端三态改两态（local / ssh），**默认 local**，进页面/切 team 自动落本地执行器
  - **Q3** 消息按**段**聚合：thinking 段遇正文/工具即关闭；正文段遇工具即关闭并**独立落库**（工具轮之间的中间输出不再并进最终回复）；工具调用一条一张卡片；落库顺序用**单调序号**（同一 agent+session 时间戳严格递增），历史重载顺序与事件顺序严格一致
  - **Q4** 远端 Git：SSH 侧加 exec 通道 + `gitLog` / `gitBranches`（本地侧复用既有实现）；非仓库 / 无 git ⇒ 空列表 + 退出码，面板显示空而不是 400
  - **Q5** 多文件粘贴：原生侧读 **CF_HDROP** 文件列表（多选文件 Ctrl+V ⇒ 多个附件），优先级 文件列表 → 单张位图 → 文本路径 → 普通文本
  - **Q6** 输入框草稿按 **team+session** 缓存（文本与附件一起、**纯内存**），切换即恢复，发送成功后清空该键
  - **Q7** 下载列表「打开文件所在位置」：Windows `explorer /select,"<path>"`；**文件夹任务定位到 tar.gz 压缩包本身**；文件已被移动/删除给提示而非静默失败
  - **Q8** 删除工具轮次上限：终止条件只剩 取消 / 出错 / 模型给出最终文本；限额交给插件（插件监视轮次，超限经执行站 `agent.stop` 发停止信号）
  - **Q9** `spec` 工具瘦身：只留 `select` / `create` / `update`；`select` **直接返回所选 Spec 全文**（删除 `search` / `list` 与"先 read 再 select"约束）；索引**注入系统提示词**（默认全列、>50 条截断）；内置 3 条只读（`general-task` / `hard-task` / `team-meeting`，落工作空间 `.self/spec/`；`easy-task` 已按使用数据移除、`complex-task` 更名 `general-task`）
  - **Q10** `grep` 无匹配时返回**扫描文件清单**（≤200，超出注明总数）+ **生效的排除目录** + 扫描根，帮模型区分"真没有"与"被误排除"；默认口径 = 不扫描**隐藏路径**（`.[!.]*`，如 `.git` / `.dart_tool` / `.self`）+ 依赖/构建目录，要搜隐藏路径显式传 `include_hidden=true`（依赖/构建目录是硬黑名单，不受该开关影响）
  - **Q11** 站点体系（三站 + 收集站）：执行站首命令集 `fs.read` / `fs.write` / `fs.list` / `fs.grep` / `terminal.exec` / `agent.message` / `agent.stop` / `agent.compact` / `ui.push`；**站点全局唯一**（每类站一个实例，id 是类型常量，不按 team / mode 复制）；中转站"**每个点位全局唯一订阅者**"（先到先得 / 显式 `replace` 接管，需分流由订阅者自行转发）；收集站由**站点定义输入格式**、多订阅者各回目标数据、站点汇总后交后续处理（如注册工具）；订阅者未响应 ⇒ **返回部分结果 + 显式列出未响应者**（不整体失败、不静默）。**插件可订阅站点**：JSON-RPC `station/subscribe` / `station/unsubscribe`（`relay` / `broadcast`；scope 按目标 agent 的真实归属解析，声明是作用域上限）；**每次工具调用的前/后各触发一次中转站**（工具层唯一入口 `WorkspaceToolRunner.run` 的入/出口），核心把**完整 tool_call 报文**交给插件——改参数、改结果、或什么都不改由插件内部决定；回填支持 string / 对象 / 数组（整体替换），未接线 / 无订阅者 / 插件未回 / 回包非法一律 **fail-open 放行原始报文**
  - **Q12** 插件布局：声明式槽位（左侧活动栏项 / 右栏 Tab / 状态栏 / 消息流内联卡片，**不做 webview/iframe，不执行插件 JS**），槽位走独立通道（manifest 声明 + `plugin_ui_manifest` / `plugin_ui_update` / `plugin_ui_action` 三帧，**不经三站**）；受限控件集 text / list / table / form / progress / actions，未知控件渲染成「不支持的控件」占位；槽位带 `team_id`，只呈现当前 team；插件可经 `ui.push` 注入消息流卡片。**生产端**：插件发 `ui/manifest` / `ui/update` **通知**即被核心转成上述帧（`plugin_id` 一律取实例 id、`team_id` 以 `plugins.yaml` 声明为准 ⇒ 不可自述越权；槽位数与视图体积有上限，非法声明整帧拒绝并记可读原因）
  - **Q13** token rate 管道统一：**思考 / 正文 / 工具调用参数**共用同一条节拍器（参数按 `字符数 / token_scale` 折算 token ⇒ `write` 这类大参数自然排队、`read` 几乎不等），工具结果**直推不延迟** ⇒ UI 只有一条速率曲线
  - **Q14** 思考回传与估算口径：`thinking` 开关（**模型默认 + 每个 agent 可覆盖**：右栏「模型信息」/成员「模型配置」的「回传思考」三态下拉，存 `agents/<id>.yaml` 的 `thinking_override`，PATCH 键 `thinking`）决定历史思考是否作为 `reasoning_content` **回传**（DeepSeek 带 `tools` 的请求必须原样回传，缺失会让同会话后续请求持续 400；默认关闭 = 不回传、省输入 token）。**上下文估算与压缩阈值按同一开关计口径**：关闭时不把思考算进上下文，工具结果按**门控后**的那一份（预览 + 提示）计——否则估算会比实际发送大出几十万 token，压缩在真实上下文只有 1/3 时就触发
  - **降级与补发**：插件 / MCP / 站点均无静态超时；插件连续 N 拍无心跳 ⇒ `degraded`（status 仍 `registered`，**不是停用**）；MCP 在途请求抛错但不杀进程 / 不关连接；WS 断链期间广播帧进**待补发队列**（上限 + 计数丢弃），重连后按拍原样重播（帧**无 TTL**），前端按**消息 id** 去重防重复渲染

---

## 功能特性

- **单进程、无后端**：Flutter UI + 核心进程；无账号体系、无 Docker/云端模式、无跨设备同步。运行模式只有两态：**local（默认）/ ssh**（M9 Q2 删除 cloud，进页面/切 team 自动落 local）。
- **本地 / SSH 工作空间**：本地直接在工作目录里执行工具；SSH 用 `dartssh2` 连远端（连接由核心发起，IP 相对本机；私钥/口令存在用户自己的 `agents/<id>.yaml`）。
- **Agent 团队**：成员就是 agent（`agents/<id>.yaml` 里的 `team_id`/`parent_agent_id`/`level`）；层级与每层人数可配（默认 3 / 7）；**审核闸门**（未分配模型或未审核的成员不接收消息）；消息派发与**级联停止**；成员活动日志。
- **内置工具**：

  | 工具 | 说明 |
  | --- | --- |
  | `read` / `write` / `edit` / `grep` | 工作空间读写、精确替换（唯一匹配）、检索（默认排除隐藏路径与依赖/构建目录，`include_hidden=true` 可放行隐藏路径） |
  | `terminal` | 本机 / 远端命令执行；**hook 模式**后台长任务（输出重定向到文件，结束后推送提示唤醒 agent 续跑） |
  | `set_todo_list` | 任务分解与增量进度汇报 |
  | `ask_user_question` | 向用户提问并等待作答（落盘、跨重启用） |
  | `team` / `message` | 建队 / 名册 / 档案 / 审核状态；派活、广播、等待完成 |
  | `spec` | 规范**选择 / 创建 / 更新**（`select` 直接返回全文；索引注入系统提示词；4 个内置模板 + 工作空间自定义） |
  | `mcp` | 已注册 MCP 服务的工具（原生注入 + 兜底调用） |
  | `plugin` | 已加载插件的工具（同上） |

- **提问回路**：提问落盘 `data/questions.json` → 前端卡片 → 作答幂等 → 继续生成；`stop` 取消在途提问；重启后的补答会写回会话。
- **Spec 与会话状态**：Spec **索引注入系统提示词**（行格式 `- <id> [task_type] 标题（内置）（适用: when 摘要）`，id 用反引号包裹；默认全列、>50 条截断并注明「其余可用 `spec select` 直取」），模型直接 `spec select` 拿全文——M9 Q9 删除了 `search` / `list` / `read` 与"先 read 再 select"约束；每次工具结果前注入"当前 in_progress todo + 已选 Spec"，模型不会忘记约定。
- **MCP**：`config/mcp.yaml` 注册 stdio 服务，工具以 `mcp__<服务>__<工具>` 原生注入模型工具列表；服务不可用只影响自己（可读错误 + 重连一次）。
- **插件**：`config/plugins.yaml` 注册进程外插件，工具以 `plugin__<插件>__<工具>` 注入；事件总线（按 scope 四元组过滤）+ 心跳巡检 + `plugin_status` / `plugin_event` 增量；心跳连续丢失只标 **degraded**（插件面板橙色「心跳降级」角标 + 丢失拍数/判活窗口），**不杀进程**，恢复即自动清除。插件可经声明式槽位（活动栏 / 右栏 Tab / 状态栏 / 消息流卡片）出界面，也可经**收集站**申报自己的工具定义。
- **站点体系（M9 Q11）**：广播站 / 执行站 / 中转站 + **收集站**（一对多收集、不回填）；站点是**持久化实例**（类型 / schema / 订阅上限 / 订阅者，跨重启保留），触发即调用实例方法。**站点全局唯一**：每类站一个实例，id 就是类型常量（`system.broadcast` / `system.execute` / `system.relay` / `plugin.tool.define`），**不按 team / mode 复制**；team / agent / session / mode 是**每次交互携带的四元组 scope** `(team_id, agent_id, session_id, mode_key)`，投递时按「消息 ↔ 订阅者」精确匹配，跨 scope 不投递（fail-closed）。**每个点位全局只允许一个订阅者**：需要按团队分开处理时，由该订阅者自己转发（在插件内再建站点分发），而不是重复订阅。
- **数据都在用户能直接看的地方**：`~/.tree` 下的 yaml / jsonl / 快照，可手改。

---

## 心跳判活口径（M9 规约）

**一句话**：**一切"静态时间"超时都取消**——任务跑多久都不因为时间失败；但**仍然会超时**，判据换成**心跳丢失**（怕的是"心跳还在、却因为总时间到了被丢掉"）。

| 项 | 口径 |
| --- | --- |
| 心跳间隔 | **I = 10s**（好心跳的节奏；Dart 侧是可被设置覆盖的常量，设置页可调列入 Wave 3 设置项） |
| 丢失阈值 | **N = 3**（连续 3 拍没收到心跳即判"心跳丢失"） |
| 判活窗口 | **I × N = 30s**：窗口内没有任何心跳 ⇒ 判失活 / 超时 |
| 不是总时长上限 | **心跳还在的任务永远不超时**——判据是"最近一次心跳过了多久"，不是"任务总共跑了多久" |
| 本地执行体 | 活性 = **进程存活**（OS 层）：进程活着永不超时，进程消失按正常退出处理 |
| 失败必须显式 | 心跳丢失一律显式报错 / 标记，**不得静默丢弃**；消息改为重连补发 |

统一心跳形态：`heartbeat{scope, seq, ts}` ⇒ `heartbeat_ack`；同时记录**最近心跳时间**与**连续丢失计数**，供上层重连决策与界面显示。

| 对象 | 落地形态 |
| --- | --- |
| 工具调用 | 无静态上限；执行端心跳丢失 ⇒ 该次调用以显式「心跳丢失」失败 |
| `terminal` | 无静态上限；心跳丢失 ⇒ **软超时**：不杀进程，转 hook 模式后台执行并返回查询 / 续看方式 |
| 消息发送（WS / 团队派发） | 无静态上限；连接心跳丢失 ⇒ 判超时并**登记补发**，重连后按拍重播（帧**无 TTL**，只有队列上限） |
| 执行器命令（local / ssh RPC） | 无静态上限；心跳丢失 ⇒ 显式失败并触发重连 |
| 插件宿主（stdio 通道） | 无静态上限；连续 N 拍丢失 ⇒ 标 **degraded**（插件面板橙色「心跳降级」角标），**不杀进程**，心跳恢复即自动清除 |
| MCP 客户端 | 无静态上限；每 I 发一次 ping，连续 N 拍无心跳 ⇒ 在途请求显式抛错（不挂起、不杀进程、不关连接） |
| LLM 传输 | 只有**建连**保留短超时（否则无法诊断）；流式读取**无总时长上限**，收到任意字节即刷新心跳，空闲到心跳丢失才判超时 |
| 前端 WS 心跳 | 前端每 **10s** 发一次 `heartbeat`；**必须小于核心判活窗口 I×N = 30s**（两侧注释都写死了这条约束：只改一侧会让"在线但空闲"的连接被判失活） |

> 唯一保留的"静态窗口"是收尾性质的：本地进程**已经死了之后**，残余管道再等 300ms 输出静默 + 3s 兜底才放弃——属收尾而不是任务上限（否则持续输出型后台进程会让工具调用永久挂住）。

---

## 插件契约（插件 ↔ 核心）

插件是**进程外子进程**，与核心之间走**行分隔 JSON-RPC 2.0**（方法与 MCP 同风格、独立命名）。两个方向的能力不对称，插件作者按下面对照即可。

### 插件 → 核心：主动请求（Wave 3-K）

插件用标准 JSON-RPC **请求**（`method` + `id`）**主动**调核心；核心**必回且只回一条**响应——成功 `{jsonrpc, id, result}`，失败 `{jsonrpc, id, error: {code, message}}`。处理器抛异常也会被收敛成**错误响应**：异常不会冲掉读循环，插件也不会永久挂起等回包。

判别只看报文形状（**有 `method` + 有 `id` ⇒ 请求**），因此插件用自增 int id 发请求，不会与核心在途请求撞号而被当成回包吞掉。

目前支持的方法只有 **`station/command`**（执行站命令）：

```jsonc
// 插件 → 核心
{"jsonrpc":"2.0","id":7,"method":"station/command",
 "params":{"command":"fs.read",
           "agent_id":"agt_1","session_id":"session_default",   // 身份（可选，见下）
           "arguments":{"agent_id":"agt_1","path":"README.md"}}}
```

- **入参** `{command, arguments, team_id?, agent_id?, session_id?, mode_key?}`：`command` 取执行站白名单——`fs.read` / `fs.write` / `fs.list` / `fs.grep` / `terminal.exec` / `agent.message` / `agent.stop` / `agent.compact` / `ui.push`；`arguments` 是该命令自己的参数对象（可省略）。身份字段放 `params` 顶层或 `arguments` 里等价。`fs.grep` 与内置 `grep` 同一默认口径（不扫描 `.[!.]*` 隐藏路径），`arguments.include_hidden=true` 放行。
- **result 形状** `{command, ok, mount_id, payload, error}`：`ok=false` 时**可读失败原因在 `error`**（跨 team / 跨模式 / 参数缺失 / 挂载位置未接线…），**不是 JSON-RPC 错误**——插件据此自查原因，不会只看到一句「调用失败」；`mount_id` 是实际执行命令的挂载位置（如 `core.execute.fs.read`），空串 = 未挂载。
- **错误码**（JSON-RPC `error.code`）：`-32601` 未知方法 · `-32602` 参数非法 · `-32603` 处理器异常 · `-32001` scope 不满足。
- **单实例 + 每条消息带身份（Q2）**：插件进程只有一个，身份按**这一次请求**解析——目标 agent 取请求里的 `agent_id`（缺省才回退到 `plugins.yaml` 的 `scope.agent_id`）；`team` / `mode` 由核心按**目标 agent 的真实归属**（团队 + `local|ssh` 工作面）解析，**不信任插件声明**。
- **`plugins.yaml` 的 `scope` 是作用域上限**：声明了 `team` 的插件只能在自己 team 内活动（跨 team 回 `-32001`）；**不声明 scope 的插件可服务任意 team**（一个实例同时服务多队），但每条命令都要带 `agent_id` 且必须能证明归属（agent 不存在 / 归属解析不出 / 请求里带的 `team_id` 与真实归属不一致，一律 `-32001`）。不带 agent 的团队级命令（如 `ui.push`）只要求能确定 `team_id`。
- 命令执行前仍会按四元组做隔离校验，任一不符即**明确拒绝**（fail-closed，跨 scope 的命令不会打到别的工作空间）。

```yaml
# <数据根>/config/plugins.yaml（片段）
plugins:
  - id: sample
    command: node
    args: ["sample-plugin.js"]
    granularity: team
    scope: {team_id: team-1}   # 作用域**上限**：不写 = 单实例服务任意 team（身份按每条命令解析）
```

### 核心 → 插件：请求与通知

| 报文 | 形态 | 说明 |
| --- | --- | --- |
| `hello` / `tools/list` / `tools/call` / `ping` / `shutdown` | 请求（核心等回包） | 握手、工具申报、工具调用、心跳探测、优雅关闭。**`tools/call` 除 `{name, arguments}` 外还带调用点身份 `scope: {team_id, agent_id, session_id, mode_key}`**（单实例插件据此知道"这一次是谁在问"） |
| `station/request` | 请求（核心等回包） | **收集站请求**：站点把请求投给订阅的插件，`params` = `{request_id, station_id, kind, scope, payload, meta?, schema?}`；插件按站点 schema 回 `{"reply": {"payload": ...}}`（失败回 `{"reply": {"error": "可读原因"}}`）。回包可回带 `scope`，带了就必须与请求四元组精确相等 |
| `event` | **通知（不等回包）** | 插件订阅到的总线事件（按四元组过滤），`params` 即事件体 |

插件也可主动发**通知**（如 `log` / `event`，不带 `id`），核心收集后转成前端 `plugin_event`。站点体系（广播 / 执行 / 中转 / 收集）与订阅、schema、部分结果语义见上文「站点体系」。

---

## 架构概览

```
┌────────── Flutter UI（lib/ui 直连本地核心） ────────┐
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
│   ├── settings.yaml          # 全局设置（token 帧率 / 推送帧率 / 消息切入）
│   ├── models/<id>.yaml       # 模型（含明文 api_key；用户私有文件）
│   ├── mcp.yaml               # MCP 服务
│   └── plugins.yaml           # 插件
├── agents/<id>.yaml           # agent / 团队成员（含 ssh、workspace_dir、system_prompt）
├── data/
│   ├── questions.json         # 提问记录（跨会话）
│   └── <agent>/<session>/
│       ├── session.json       # 会话元数据（原子快照）
│       └── messages.jsonl     # 消息追加日志（一行一条）
└── workspaces/<agent_id>/     # 默认工作空间（可在 agent yaml 里改；SSH 则是对端工作空间）
    └── .self/                 # 该工作空间/团队的私有状态（提示词与规范按团队分隔）
        ├── system_prompt.md   # 系统提示词基础段（首启播种；改完下一轮生效）
        └── spec/*.md          # 内置（general-task/hard-task/team-meeting）+ 自定义 Spec
```

Windows 上是 `%APPDATA%\Tree`；`TREE_HOME` 环境变量或 `--data-dir` 可覆盖。

---

## 常见问题

- **核心进程没起来**：检查 `TREE_CORE_URL` / `TREE_CORE_TOKEN` 是否指向手工启动的 `tree_core --verbose`；发行版布局下 `tree_core.exe` 应与 `Tree.exe` 同目录。
- **SSH 连不上**：连接由**核心**发起，地址需从本机可达；检查 `agents/<id>.yaml` 的 `ssh:` 段。文件面板与工具层的「工作空间根」就是这里的 `root`（`workspace_dir` 只对本地工作空间生效）。
- **SSH 的根填哪一级**（M8a）：**不收窄**——`root` 留空就是远端登录用户的 `HOME`。数据文件与项目文件常常分处根下不同子目录（例如 `~/data` 与 `~/proj`），所以根保留在用户给的那一级，由系统提示词里的「工作空间（软约束）」说明“布局是混合的、按用户指示定位”，而不是要求你把根改到某个项目子目录。SSH 配置弹窗的「远端根目录」留空即 HOME（历史键名 `private_key_path` / `remote_base_dir` 仍被核心解析器兼容）。
- **插件 / MCP 没生效**：看对应 yaml 的 `command` 是否可执行；`GET /api/plugin/snapshot` 与 `GET /api/mcp/services` 会给出 `disabled_reason` / `errors`。坏服务只影响自己。
- **插件面板出现橙色「心跳降级」角标**：表示连续 3 拍（≈30s）没收到该插件的心跳——**不是停用**（`status` 仍是 `registered`，进程还活着，只是不回应心跳）。先查插件是否卡在某个长任务上；确认无救再显式重启（核心**不会**因为它降级而杀进程）。
- **模型不可用**：`~/.tree/config/models/<id>.yaml` 的 `base_url` / `api_key`，以及 agent 的 `model_id` 是否指向它。
- **改配置何时生效**：`agents/*.yaml` 与 `config/*.yaml` 在核心启动时读取；MCP / 插件也可经 REST 即时注册；工作空间里的 `.self/system_prompt.md` 下一轮对话即生效（按 agent 缓存，后台刷新）。
- **系统提示词从哪来**（Q6）：每个工作空间 = `.self/system_prompt.md`（基础段，按团队/工作空间分隔）→ agent 自己的 `system_prompt` → 工作空间软约束 → Spec 索引。首次用到该工作空间（或文件被删）时核心会写入一份默认内容；之后**只读用户的版本**，清空文件即等于不要基础段。
- **系统提示词 / Spec 被改坏了**：右侧活动栏（右栏顶部）有两个一键重置按钮——现有文件先备份成 `.bak.<n>`（保留旧备份、序号顺延），再写回默认内容；Spec 的自定义文件会一并清理，备份里可找回。等价接口：`POST /api/agents/{id}/reset`（body `{target: system_prompt|spec|all}`）。

---

## 文档

- [开发规格（迁移方案与历史规格）](.trae/specs/)
- [M9 计划：14 项修复与优化（唯一事实源）](docs/m9-plan.md)
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
- **Docker 及容器生态** —— 服务端线（`main` 分支）云端模式 agent 工作空间的沙箱隔离基础（桌面线已无云端模式）。
- 以及所有直接或间接支撑本项目的**开源软件与贡献者**。
