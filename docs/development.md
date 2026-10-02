# 开发

> 面向**搭环境 / 跑测试 / 打包**的人。规则约束见 [../CONTRIBUTING.md](../CONTRIBUTING.md)。

## 1. 环境

| 项 | 值 |
| --- | --- |
| Flutter | **3.47.5**（stable） |
| Dart | **3.13.4**（随 Flutter 提供，位于 `<flutter>/bin/cache/dart-sdk/bin/dart`） |
| 平台 | Windows 10+ / Linux / macOS（Windows 7/8 不支持） |
| 其它 | 打包与安装包需要 Windows + `tar`（Win10 自带 bsdtar）；可选 Inno Setup 6 |

**务必用与构建应用同一个 Flutter SDK 里的 dart**（例如
`<flutter>/bin/cache/dart-sdk/bin/dart`）来编译核心与跑脚本：混用两个 SDK 会出现
AOT 产物与 Flutter 引擎不匹配的怪问题。下面的命令用 `dart` / `flutter` 代指这两个可执行文件。

```powershell
flutter --version          # 确认 3.47.5
dart --version             # 确认 3.13.4
```

## 2. 仓库结构

```
desktop/
├── lib/                       # Flutter 前端（ui 三栏界面；io 只做进程附着与传输）
├── packages/
│   ├── tree_protocol/         # 协议单一真源（WS 帧 / REST 路径 / 握手）+ 完备性门禁
│   ├── tree_local_exec/       # 本机与 SSH 工作空间 IO（dartssh2）
│   ├── tree_core/             # 核心：服务 / LLM / 工具 / 团队 / Spec / MCP / 插件
│   └── tree_core_cli/         # tree_core.exe 入口 + 真进程端到端测试
├── test/                      # 前端测试（flutter test）
├── tool/                      # 构建与打包脚本（build_core.dart / package_windows.dart / installer）
├── docs/                      # 文档（入口 docs/README.md）
└── examples/plugins/          # 可运行插件示例（Python 标准库）
```

## 3. 构建与运行

```powershell
# 1) 编译核心（首次，或核心代码改动后）
dart compile exe packages/tree_core_cli/bin/tree_core.dart `
    -o build/windows/x64/runner/Debug/tree_core.exe

# 2) 运行应用（自动定位并拉起核心）
flutter run -d windows
```

核心可执行文件查找顺序：`TREE_CORE_EXE` → 应用同目录（发行版布局）→ 向上 8 层找
`.output/tree_core.exe`（开发期）。都找不到时应用显示**带修复指引**的错误页。

## 4. 测试矩阵

| 层 | 命令 | 说明 |
| --- | --- | --- |
| 协议完备性 | `cd packages/tree_protocol && dart test` | 常量集合无重复 / 无遗漏；路由覆盖度；**文档契约门禁**（模块 README 的不变量节、docs 索引完整性） |
| 工作空间 IO | `cd packages/tree_local_exec && dart test` | 本机 + SSH（dartssh2）语义；路径越界 |
| 核心 | `cd packages/tree_core && dart test` | 存储 / LLM 循环 / 工具 / 团队 / Spec / MCP / 插件 / REST+WS 端到端 |
| 核心真进程 | `cd packages/tree_core_cli && dart test` | 编译产物能起、握手、鉴权、优雅退出（需 `TREE_CORE_EXE`） |
| 前端 | `flutter test`（仓库根） | 组件与 API 客户端 |
| 静态检查 | `dart analyze`（每个包）+ `flutter analyze lib test` | **必须零告警**才能提交 |

**门控真机测试**（本机没有 sshd / 没有编译产物时自动跳过，设了才跑）：

```powershell
# SSH 语义与文件面板（真机）
$env:TREE_SSH_TEST_HOST='192.168.0.10'; $env:TREE_SSH_TEST_USER='open'
$env:TREE_SSH_TEST_KEY='C:\Users\me\.ssh\id_ed25519'; $env:TREE_SSH_TEST_ROOT='/mnt/space'
cd packages/tree_local_exec; dart test
cd ../tree_core; dart test test/ssh_files_integration_test.dart

# 编译产物冒烟
$env:TREE_CORE_EXE='E:\programs\Tree\desktop\dist\tree_core.exe'
cd packages/tree_core_cli; dart test test/binary_smoke_test.dart
```

## 5. 打包与安装包

```powershell
# 便携 zip（构建应用 + 编译核心 + 拷 pdfium.dll + 写使用说明 + 自检 + 压缩）
dart run tool/package_windows.dart --flutter "<flutter.bat 的路径>"
# 产物：dist/tree-desktop-<版本>-windows-x64.zip

# 只要核心单文件
dart run tool/build_core.dart            # → dist/tree_core.exe（约 10 MB）

# 安装包（需要 Inno Setup 6；iscc 不在 PATH 时用 --iscc 指定）
dart run tool/package_windows.dart --installer
dart run tool/package_windows.dart --installer --iscc "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
```

脚本替你做的、**必须由脚本做**的事（漏一个用户就会踩坑）：

1. `flutter build windows --release`；
2. 用**同一个 SDK** 编译 `tree_core.exe` 并放进 Release 目录——发行版要求核心与 `Tree.exe` 同目录；
3. 拷 `build/native_assets/windows/*.dll`（pdfrx 的 `pdfium.dll`）到 exe 旁边（native assets 不会自动进发行目录）；
4. 写 `使用说明.txt`（数据目录、可手改的配置文件、常见问题）；
5. **自检**：真启动一次打包好的核心，读到握手再让它优雅退出；
6. 压 zip 到 `dist/`。

安装包自检（本仓库验证过的流程）：静默装到临时目录 → 检查
`Tree.exe` / `tree_core.exe` / `pdfium.dll` / `使用说明.txt` 是否齐 →
用装好的核心跑一遍冒烟与文件写路径测试 → 静默卸载并确认无残留。

## 6. 验收基线（M9 起：不得劣化）

改动合并前，下列基线**只能持平或更好**；数字变小必须解释（并说明是有意裁剪用例还是丢了覆盖）。

| 项 | 当前基线 |
| --- | --- |
| 静态检查 | `dart analyze` × 4 包 + `flutter analyze lib test` 全干净 |
| `tree_protocol` | 33 passed（含协议完备性 + 文档契约门禁） |
| `tree_local_exec` | 159 passed / 1 skipped |
| `tree_core` | 849 passed / 1 skipped |
| 前端 `flutter test` | 217 passed |
| 真机 SSH 回归（`TREE_SSH_TEST_*` 具备时） | `list` / `upload` / `download_folder` / `syncToLocal` 四项通过 |

## 7. 调试

| 需求 | 做法 |
| --- | --- |
| 单独调试 / 重启核心（不必重启应用） | 先跑 `tree_core.exe --port 8001 --verbose`，再给应用设 `TREE_CORE_URL=http://127.0.0.1:8001` 与 `TREE_CORE_TOKEN=<握手行里的 token>` |
| 看核心请求日志 | 核心加 `--verbose`（访问日志走 **stderr**；stdout 只放握手行） |
| 只跑核心链路测试 | `cd packages/tree_core && dart test`（含真实 HTTP + WS 端到端） |
| 看某个 agent 的私有状态 | `<工作空间>/.tree/<agent_id>/.self/`（提示词 / 规范 / 结果 / 活动日志） |
| 看 / 改**模型实际收到的提示词** | 真源：`agent/system_prompt_file.dart`（种子）、`spec/builtin_specs.dart`（内置规范）、`agent/workspace_prompt.dart`（拼装顺序）、各工具文件的 `ToolSpec`；运行期副本：`<工作空间>/.tree/<agent_id>/.self/{system_prompt.md, spec/}`。完整对照表见 [architecture.md §8.1](architecture.md) |
| 数据目录换地方 | `TREE_HOME=<dir>` 或 `tree_core --data-dir <dir>` |
| 前端连不上核心 | 看 UI 错误页给出的修复指引；确认 `tree_core.exe` 位置或 `TREE_CORE_*` 环境变量 |

## 8. 发布检查单

- [ ] `dart analyze` × 4 包 + `flutter analyze lib test` 零告警
- [ ] 5 层测试全绿（含门控真机 SSH / 编译产物冒烟，若环境具备）
- [ ] `CHANGELOG.md` 记录本次版本的用户可见变化
- [ ] `tool/package_windows.dart` 出的 zip 自检通过；安装包流程走一遍
- [ ] `docs/known-issues.md` 的未决项已复核（哪些已修、哪些进下个版本）
- [ ] 新增/修改的行为在对应模块 README 的**不变量**节里有落点
