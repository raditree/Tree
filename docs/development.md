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
│   ├── tree_local_exec/       # 本机与 SSH 工作空间 IO（dartssh2 与中转站两条后端）
│   ├── tree_tunnel_protocol/  # SSH 执行器「中转站」协议的共享定义（方法名 / 错误码 / 帧 / 版本）
│   ├── tree_agent/            # 目标机（Linux）执行体：tree_agent 二进制
│   ├── tree_ssh_plugin/       # ssh_executor 中转站插件（binary 型内置插件）
│   ├── tree_core/             # 核心：服务 / LLM / 工具 / 团队 / Spec / MCP / 插件
│   └── tree_core_cli/         # tree_core.exe 入口 + 真进程端到端测试
├── test/                      # 前端测试（flutter test）
├── tool/                      # 构建与打包脚本（build_core / build_agent / build_ssh_plugin / build_plugins / package_windows / installer）
├── docs/                      # 文档（入口 docs/README.md）
└── plugins/                   # **插件仓（raditree/tree-plugins）的本地 clone**（独立 git 仓、对桌面仓已 gitignore）：
                               #   五个随包插件的 Dart 源码 + 公共骨架 `_kit` + 每个目录一份 `plugin.json`
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

### 3.1 SSH 相关包的构建（`tree_ssh_plugin` / `tree_agent`）

SSH 执行器链路上有**两个包要单独编译成二进制**（不是 `dart test` 能覆盖的：它们是随包分发、
目标机上没有 Dart 运行时的产物）。都走 `tool/` 下的脚本，从**仓根**执行：

| 包 | 编译脚本 | 入口 | 产出（默认目录） | 跑在哪 |
| --- | --- | --- | --- | --- |
| `tree_ssh_plugin`（`ssh_executor` 中转站插件） | `dart run tool/build_ssh_plugin.dart` | `packages/tree_ssh_plugin/bin/tree_ssh_executor.dart` | `build/plugins/tree_ssh_executor`（Windows 补 `.exe`，约 10 MB） | **用户本机**（与 `tree_core.exe` 同级） |
| `tree_agent`（目标机执行体） | `dart run tool/build_agent.dart` | `packages/tree_agent/bin/tree_agent.dart` | `build/agents/tree_agent-linux-{amd64,arm64}`（各约 6.5 MB） | **目标机 Linux** |

**为什么是二进制而非脚本**：两者都要 `dartssh2` / 常驻通道 / base64 分块推送等能力，编译成单文件后
目标机器上**不需要任何运行时**；核心侧按 `BuiltinPluginSpec.kind == binary` 解析插件（见
`packages/tree_core/lib/src/plugin/builtin_plugins.dart`）。

**可选参数**（`--out` 两者通用，留空即上表的默认目录）：

```powershell
# 中转站插件：只编「自机平台」那一份（Windows 出 .exe，Linux/macOS 无扩展名）
dart run tool/build_ssh_plugin.dart [--out <dir>]

# 目标机执行体：交叉编译，一次产出 amd64 + arm64 两份
dart run tool/build_agent.dart [--out <dir>] [--version <v>] [--arch x64,arm64]
```

- `tree_agent` 靠 `dart compile exe --target-os=linux --target-arch=<x64|arm64>` 在 Windows 上直接产出
  Linux 二进制（本仓 Dart 3.13.4 已实测可用，**无需 Linux 构建机**；首次会下载目标端 AOT 产物，约 2 分钟）；
  `--arch` 只接受 `x64` / `arm64`（写进文件名分别是 `amd64` / `arm64`）。
- `tree_agent` 的 `--version` 缺省取仓根 `pubspec.yaml` 的语义版本；插件那条**不接受版本参数**，
  一律从 `pubspec.yaml` 读。

> **两条必须一起重跑（版本耦合）**：脚本都会把仓根 `pubspec.yaml` 的 `version: x.y.z+n` 里
> `+` 之前那段（语义版本）注入成 `-DkAgentVersion` —— 插件用它说「我要哪个版本的 `tree_agent`」，
> `build_agent.dart` 用同一个值给二进制打标，两处不一致插件日志会报版本不匹配（功能仍靠 sha256 工作，
> 但是噪音与误判源）。所以**改了 `pubspec.yaml` 版本号就必须重跑这两条**：`tool/package_windows.dart`
> 出包前会逐个校验产物里的版本串（`_verifyBinaryVersion`），对不上**直接拒绝出包**。
> 为什么用 `+` 之前那段：构建号每打包都变，拿它当 agent 版本会导致每次都重推 6.5 MB。
>
> 这两份产物**缺失不会报错**（只是包内没有中转站，核心自动回退内置 dartssh2，功能不变），
> 只有「版本对不上」才会拦。出包流程见 §5，端到端真机验证见 §4。

### 3.2 插件仓的成品（`build_plugins.dart`）

五个随包插件（`minimal` / `suspendable` / `terminal_probe` / `compact` / `sample`）的**源码不在
本仓**，而在插件仓（clone 到桌面仓的 `plugins/`，2026-10-17 之前的 `examples/plugins/` 已删）。
构建从**仓根**执行，一条命令覆盖整仓：

```powershell
dart run tool/build_plugins.dart                  # 全编 + 逐个 `<exe> --selftest` + 写索引
dart run tool/build_plugins.dart --only compact   # 只编一个（开发回路；**索引与其余条目合并**）
dart run tool/build_plugins.dart --skip-selftest  # 只编译（CI 里先验编译面）
dart run tool/build_plugins.dart --out <目录> --index <文件>   # 改产物目录 / 索引落地
```

产出 `build/plugins/tree_<id>[.exe]` 与 `build/plugins/plugin-index.json`（**发布合同本体**）。
三条硬规矩写在脚本里而不是靠文档守：字段先过合同再编译（与装机端 `PluginDownloader` 读同一
份规则）、**编出来的 exe 必须真跑一遍 `--selftest`**（“能编译”不等于“协议对”，协议错在用户
机器上就是“插件起不来”）、索引里的 `bytes` 是真字节数。另两条容易踩的：

- `--only` **不会**把索引重写成那一条（与旧索引按 id 合并）——全量构建才不合并（仓里删掉的
  插件必须从索引消失，留着就是幽灵条目）；
- 插件仓没 clone 时本命令直接退 2 并告诉你该 clone 到哪，不静默产出空索引。

开发态不必先构建也能跑：真进程用例（`compact_plugin_e2e_test` / `compact_panel_ui_test` /
`sample_plugin_layout_e2e_test` / `plugin_self_station_e2e_test`）跑的是 `dart <插件仓里那个
.dart>` 起的**源码**，产物只归打包链与 `<exe> --selftest`。

## 4. 测试矩阵

| 层 | 命令 | 说明 |
| --- | --- | --- |
| 协议完备性 | `cd packages/tree_protocol && dart test` | 常量集合无重复 / 无遗漏；路由覆盖度；**文档契约门禁**（模块 README 的不变量节、docs 索引完整性） |
| 工作空间 IO | `cd packages/tree_local_exec && dart test` | 本机 + SSH（dartssh2 **与中转站两条后端**）语义；路径越界；后台执行的两条路 |
| **中转站协议** | `cd packages/tree_tunnel_protocol && dart test` | 帧编解码（分片 / 多帧 / `\r` / 坏帧不断读循环 / 超长行丢弃）、路径归一化与越界判定 |
| **目标机执行体** | `cd packages/tree_agent && dart test` | L2 全部方法；越界拒绝；分块读写；`exec.spawn` 台账对账；PTY。**POSIX 专属行为在 Windows 上 skip（19 条）**，真机归下面那条门控 |
| **中转站插件** | `cd packages/tree_ssh_plugin && dart test` | L1 分发 / 多隧道去重 / bootstrap 命令形状 / 退避节奏与 `down` 跃迁 / 真进程多帧 |
| 核心 | `cd packages/tree_core && dart test` | 存储 / LLM 循环 / 工具 / 团队 / Spec / MCP / 插件 / REST+WS 端到端 |
| 核心真进程 | `cd packages/tree_core_cli && dart test` | 编译产物能起、握手、鉴权、优雅退出（需 `TREE_CORE_EXE`） |
| 前端 | `flutter test`（仓库根） | 组件与 API 客户端 |
| 托盘与关窗 | `flutter run -d windows` 手动一次 | 点关闭按钮应**只隐藏窗口**（托盘图标出现、核心进程仍在），双击托盘图标恢复窗口；退出走托盘菜单 |
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

**SSH 执行器「中转站」端到端**（2026-10-10 新增；**真 sshd + 真 Linux 二进制 + 真插件进程**）：

```powershell
# 先产出两份二进制（缺了它们核心自动回退内置 dartssh2，功能不变）
dart run tool/build_ssh_plugin.dart     # → build/plugins/tree_ssh_executor[.exe]
dart run tool/build_agent.dart          # → build/agents/tree_agent-linux-{amd64,arm64}

# 目标机：起一个可连的 sshd（本机开发推荐 WSL；脚本见任务留痕 .self/e2e/setup_sshd.sh）
#   wsl -d Ubuntu -u root -- bash <repo>/.self/e2e/setup_sshd.sh   # 端口 2222、密钥认证

$env:TREE_SSH_TEST_HOST='127.0.0.1'; $env:TREE_SSH_TEST_PORT='2222'
$env:TREE_SSH_TEST_USER='treee2e'; $env:TREE_SSH_TEST_KEY='<私钥的绝对路径>'

# ① 线上协议黑盒（hello → ensure → 文件/命令/托管后台任务/PTY）
dart run tool/tunnel_e2e.dart
# ② 核心侧链路（内置目录解析 → 起真插件 → 建隧道 → 文件/命令/托管后台任务）
cd packages/tree_core; dart test test/ssh_tunnel_e2e_test.dart
```

两条都是**门控**：不设 `TREE_SSH_TEST_HOST` 就跳过（打印可读原因），与仓库其它真机用例同口径。

**用 Docker 起目标机 sshd**（本机有 Docker Desktop / Linux 容器时，比 WSL 更省事）：
镜像里只需要 sshd + 执行体依赖的 POSIX 工具（`util-linux` 给 `script`/`setsid`，`coreutils` 给
`base64`/`sha256sum`），**公钥走环境变量注入、镜像不落任何密钥**。在仓根建 `.self/e2e/sshd/`
（`.self/` 已被 gitignore，属开发态脚本）两个文件：

```dockerfile
# .self/e2e/sshd/Dockerfile
FROM debian:trixie-slim
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      openssh-server util-linux ca-certificates \
 && rm -rf /var/lib/apt/lists/* && mkdir -p /run/sshd
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh && chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

```sh
# .self/e2e/sshd/entrypoint.sh
#!/bin/sh
set -e
USER_NAME="${SSH_USER:-treee2e}"; PORT="${SSH_PORT:-2222}"
id -u "$USER_NAME" >/dev/null 2>&1 || useradd -m -s /bin/bash "$USER_NAME"
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
mkdir -p "$HOME_DIR/.ssh"
printf '%s\n' "${SSH_PUBKEY:?need SSH_PUBKEY}" > "$HOME_DIR/.ssh/authorized_keys"
chown -R "$USER_NAME:$USER_NAME" "$HOME_DIR/.ssh"
chmod 700 "$HOME_DIR/.ssh"; chmod 600 "$HOME_DIR/.ssh/authorized_keys"
mkdir -p /run/sshd
exec /usr/sbin/sshd -D -p "$PORT" -o PermitRootLogin=no \
  -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o UsePAM=yes
```

构建并拉起（发布到 `127.0.0.1:2222`，只绑回环；没有密钥对先 `ssh-keygen -t ed25519 -f .self/e2e/id_e2e`）：

```powershell
docker build -t tree-e2e-sshd .self/e2e/sshd
$pub=(Get-Content .self/e2e/id_e2e.pub -Raw).Trim()
docker run -d --name tree-e2e-sshd -p 127.0.0.1:2222:2222 `
  -e SSH_USER=treee2e -e SSH_PORT=2222 -e SSH_PUBKEY="$pub" tree-e2e-sshd
# 验一下能登录（应回 LOGIN_OK / x86_64，且 script/setsid/base64/sha256sum 齐）
ssh -i .self/e2e/id_e2e -p 2222 -o StrictHostKeyChecking=no -o BatchMode=yes `
  treee2e@127.0.0.1 'echo LOGIN_OK; uname -m'
```

然后照上面那段设好 `TREE_SSH_TEST_HOST=127.0.0.1` / `PORT=2222` / `USER=treee2e` /
`KEY=<id_e2e 绝对路径>`，跑 `dart run tool/tunnel_e2e.dart` 与 `ssh_tunnel_e2e_test.dart`。用完收尾：
`docker rm -f tree-e2e-sshd`（容器无常驻数据，删了不留痕）。

## 5. 打包与安装包

```powershell
# 便携 zip（构建应用 + 编译核心 + 拷 pdfium.dll + 写使用说明 + 自检 + 压缩）
dart run tool/package_windows.dart --flutter "<flutter.bat 的路径>"
# 产物：dist/tree-desktop-<版本>-windows-x64.zip

# 只要核心单文件
dart run tool/build_core.dart            # → dist/tree_core.exe（约 10 MB）

# SSH 执行器的两份二进制（2026-10-10 新增；缺了它们核心自动回退内置 dartssh2，功能不变）
# ⚠ 改了 pubspec 的版本号就**必须重跑这两条**：出包脚本会校验产物里的版本串，不一致直接拒绝出包
dart run tool/build_ssh_plugin.dart      # → build/plugins/tree_ssh_executor[.exe]（约 10 MB，跑在用户本机）
dart run tool/build_agent.dart           # → build/agents/tree_agent-linux-{amd64,arm64}（各约 6.5 MB）
                                         #   交叉编译（--target-os/--target-arch，本仓 Dart 3.13.4 实测可用；
                                         #   首次会下载目标端 AOT 产物，约 2 分钟）

# 插件仓（clone 在 `plugins/`）的五个成品 + 发布合同（见 §3.2）
# ⚠ 出包前必须跑：`package_windows.dart` 只按 `build/plugins/plugin-index.json` 拷成品，
#   索引不在就是“面板上能装、随包却没带”（它会打一行跳过，不会静默）
dart run tool/build_plugins.dart

# 安装包（需要 Inno Setup 6；iscc 不在 PATH 时用 --iscc 指定）
dart run tool/package_windows.dart --installer
dart run tool/package_windows.dart --installer --iscc "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
```

脚本替你做的、**必须由脚本做**的事（漏一个用户就会踩坑）：

1. `flutter build windows --release --no-tree-shake-icons`：**不做图标字体子集化**。子集化会静默丢掉
   一批明明在用的图标（实测 2026-10-04：`badge_outlined` / `chat_bubble` / `folder` / `visibility(_off)` /
   `keyboard_double_arrow_left/right` 都不在子集里），后果是**按钮一片空白**——而且只有发布版会犯（Debug 不子集化）；
   脚本随后还会**逐个人 `lib/` 里用到的 `Icons.*` 对一遍字体 cmap**，缺一个直接打包失败并点名，
   不把空白按钮发给用户（代价：字体 18 KB → 1.6 MB，安装包约 +0.5 MB）；
2. 用**同一个 SDK** 编译 `tree_core.exe` 并放进 Release 目录——发行版要求核心与 `Tree.exe` 同目录；
3. 拷 `build/native_assets/windows/*.dll`（pdfrx 的 `pdfium.dll`）到 exe 旁边（native assets 不会自动进发行目录）；
4. 拷**插件成品与开发指南** → 发行目录 `plugins/`（核心按**自身可执行文件同级**的
   `plugins/<name>[.exe]` 解析内置插件）：成品按 `build/plugins/plugin-index.json` 里的
   `files[].target` 逐条拷（那份索引是**装机端唯一读的合同**，打包链按同一份拷才能做到
   “发布仓库有的，安装包也有”；自己扫目录就是第二份真相、两边一定会漂），另拷一份
   `docs/plugin-development.md` → `plugins/plugin-development.md`（应用内「打开插件开发说明」
   与核心播种到工作空间的那一份都找它）；2026-10-17：**不再拷 `examples/plugins/` 的 Python
   脚本**（最后一份示例迁进插件仓后那个目录已删），配套的 `__pycache__`/`*.pyc` 过滤也跟着
   删了——打包链不再产 Python 文件；
5. 写 `使用说明.txt`（数据目录、可手改的配置文件、常见问题）；
6. **自检**：真启动一次打包好的核心，读到握手再让它优雅退出；
7. 压 zip 到 `dist/`。

安装包自检（本仓库验证过的流程）：静默装到临时目录 → 检查
`Tree.exe` / `tree_core.exe` / `pdfium.dll` / `使用说明.txt` /
**`plugins/tree_ssh_executor.exe`（中转站插件，与 `Tree.exe` 同级）** /
**`plugins/` 里索引列出的那几条插件成品**（按 `build/plugins/plugin-index.json` 逐条点名，
少一条就是面板上那个开关拉不上去）** /
**`agents/tree_agent-linux-{amd64,arm64}`（目标机执行体，与 `plugins/` 同级）** 是否齐 →
用装好的核心跑一遍冒烟与文件写路径测试 → 静默卸载并确认无残留。

> **新目录是怎么进包的**：安装器用 `Source: "{#ReleaseDir}\*"` + `recursesubdirs createallsubdirs`
> **整目录递归**，所以 `agents/` 与 `plugins/` 下的新文件**不需要改 `.iss`**；
> 需要保证的只有"复制进发行目录"这一步 —— 那是 `tool/package_windows.dart` 的
> `_copySshExecutorArtifacts`（`build/plugins/` 与 `build/agents/` → 发行目录），
> 并在复制前**逐个校验产物里的版本串**（`_verifyBinaryVersion`）：与 `pubspec.yaml` 的版本
> （`+` 之前那部分）不一致就**直接拒绝出包**并告诉你要先跑哪条构建命令。
> 为什么加这道闸：2026-10-11 出 1.0.3+2 时**忘了重编两份二进制**，包里因此装着 1.0.2 的插件与 agent
> （目标机上出现 `~/.tree/agent/1.0.2/`），功能上完全看不出来 —— 这种"包名与包内容版本对不上"
> 只能靠出包失败来拦。

## 6. 验收基线（M9 起：不得劣化）

改动合并前，下列基线**只能持平或更好**；数字变小必须解释（并说明是有意裁剪用例还是丢了覆盖）。

| 项 | 当前基线 |
| --- | --- |
| 静态检查 | `dart analyze`（6 个 Dart 包的 `lib test` + `tree_core_cli/bin` + `tool/`）+ `flutter analyze lib test` 全干净 |
| `tree_protocol` | 38 passed（含协议完备性 + 文档契约门禁） |
| `tree_tunnel_protocol` | 15 passed（帧编解码 / 路径归一化与越界判定） |
| `tree_agent` | 89 passed / 19 skipped（skip = POSIX 专属行为，见下注） |
| `tree_ssh_plugin` | 154 passed（含"真进程一次塞多帧" + **断连完整性 13 条** + **左栏面板 18 条**） |
| `tree_local_exec` | 293 passed / 4 skipped |
| `tree_core` | 1218 passed / 3 skipped（含另一会话在途的 subagent-transcript 测试；本轮 +1 为「挂账被召回时告知」） |
| `tree_core_cli` | 6 passed（需 `TREE_CORE_EXE` 指向编译产物） |
| 前端 `flutter test` | 811 passed |
| 真机 SSH 回归（`TREE_SSH_TEST_*` 具备时） | ① `packages/tree_local_exec` 的 SSH 用例与 `packages/tree_core/test/ssh_files_integration_test.dart`；② **中转站两条门控**：`dart run tool/tunnel_e2e.dart`（线上协议黑盒，**37 项**，含 ⑧ 断连完整性五条）与 `packages/tree_core/test/ssh_tunnel_e2e_test.dart`（核心侧链路，含 ⑨ 断连不误发 + 恢复后接续） |

> **2026-10-11 11:03 复测**（判死口径精确化 + 面板动作反馈 + `conn_id` 前缀）：`tree_ssh_plugin` **154**
> （152 + 面板侧 2 条）、`tree_local_exec` **293~4**（291 + 2 条判死钉子）、`tree_core` **1217~3**
> （含另一会话在途的 `subagent_transcript_*` 测试文件，非本次引入）。
>
> 上表数字于 **2026-10-11（1.0.3+3）逐包重测**：`tree_protocol` 38、`tree_tunnel_protocol` 15、
> `tree_agent` **89~19**、`tree_ssh_plugin` **136**、`tree_local_exec` **290~4**、`tree_core` **1202~3**、
> `tree_core_cli` **6**、前端 **811**。
> 相对上一版（1.0.3）的差额来源：`tree_ssh_plugin` **+13** 是"断连完整性"钉子
> （`test/tunnel_keepalive_test.dart`：失败面分类 / spawn 必带静默上限 / 保活与卡死强拆 /
> `reconnect` 探针 / 上一世 agent 清理的 token 守卫形状）；`tree_local_exec` **+3** 是传输层的
> "重连中等待后只重发一次 / 请求级失败不判死 / 等超预算如实失败 / 插件不可用才判死"（1 条原用例被 4 条新用例替换）。
> **真机门控本次具备并跑过**（WSL 起的真 sshd + 交叉编译出的真二进制），不再写"环境不具备"：
> `tool/tunnel_e2e.dart` **37 项全过（0 失败）**，其中
> ⑦ 段钉**关停/接续四条**（执行器被 kill ⇒ 旧 pid 消失 / **在跑的后台进程仍然活着** /
> 重建后 **agent 从台账认出上一世的任务** / 跨过重建仍拿到退出码与日志 / 关隧道后**执行器立即退出不留孤儿**），
> ⑧ 段钉**断连完整性五条**（执行器命令行带 `--root` 与 `--idle-timeout-ms 90000`（真机读 `/proc/<pid>/cmdline`）/
> 从服务端掐断通道后插件进 `reconnecting` / **此时请求回 `tunnel_not_ready` 而不是判死的 `tunnel_down`** /
> 自动重连后目标机上**只剩一个**执行器且上一世 pid 已退掉 / `SIGSTOP` 制造的**卡死**被保活强拆且旧的被收掉）；
> `packages/tree_core/test/ssh_tunnel_e2e_test.dart` 一条用例全过，含 **⑨ 断连不误发 + 恢复后接续**
> （起长任务 → 掐断通道 → 断言 hook 的 `exitCode` **没有**提前失败 → 自动重连后从落盘台账拿到**真实**退出码与日志）。
> 唯一仍未跑的是 zip / 安装包的静默装卸（对外系统级动作，由用户自己装机实测）。
> `tree_agent` 的 **19 条 skip 是 POSIX 专属行为**（`script` / `setsid` / `kill -0` / 符号链接语义）——
> Windows 开发机上注定跑不了，它们的覆盖来自上表最后一行那两条真机门控，不是丢了断言。
> 上表数字此前于 **2026-10-05 逐包重测**（此前记的 33 / 159+1 / 849+1 / 217 已经过时——那是更早里程碑的旧值，
> 不是某次改动造成的）。基线是**下限**：只许持平或更好。**注意**：`dart test` 计时敏感的用例（例如
> `tree_core` 的 `llm_transport_liveness_test`）在**多套测试并发跑**时可能偶发失败；复核请单独跑一遍。
> **2026-10-07（1.0.2+6）逐包重测**：`tree_protocol` 38、`tree_local_exec` **261~4**（+6：新增 `ssh_link_fault_test`）、
> `tree_core` **1200~2**（+1：执行站 `ssh.reconnect` 用例；另有内置点位清单门禁 17→18、命令 13→14 的同步）、
> `tree_core_cli` 4~2、前端 **811**（当时高于基线 789，差额来自 1.0.2+5 之后的其它提交、**非当次引入**）。
> **2026-10-05 发布 1.0.2+5 时再次逐包重测**：38 / 255~4 / **1199~2** / 789（`tree_core` 从 1188 升到 1199，
> 差额是本次为"失败载荷穿到插件"补的 4 条回归用例）。`tree_core_cli` **没有 `lib/`**：
> 单独分析它要跑 `dart analyze`（整包），`dart analyze lib test` 会以 `Directory or file doesn't exist: lib` 退出（code 64）。

## 7. 调试

| 需求 | 做法 |
| --- | --- |
| 单独调试 / 重启核心（不必重启应用） | 先跑 `tree_core.exe --port 8001 --verbose`，再给应用设 `TREE_CORE_URL=http://127.0.0.1:8001` 与 `TREE_CORE_TOKEN=<握手行里的 token>` |
| 看核心请求日志 | 核心加 `--verbose`（访问日志走 **stderr**；stdout 只放握手行） |
| 只跑核心链路测试 | `cd packages/tree_core && dart test`（含真实 HTTP + WS 端到端） |
| 看某个 agent 的私有状态 | `<工作空间>/.tree/<agent_id>/.self/`（提示词 / 规范 / 结果 / 活动日志） |
| 看 / 改**模型实际收到的提示词** | 真源：`agent/system_prompt_file.dart`（种子）、`spec/builtin_specs.dart`（内置规范）、`agent/workspace_prompt.dart`（拼装顺序）、各工具文件的 `ToolSpec`；运行期副本：`<工作空间>/.tree/<agent_id>/.self/{system_prompt.md, spec/}`。完整对照表见 [architecture.md §8.1](architecture.md) |
| 数据目录换地方 | `TREE_HOME=<dir>` 或 `tree_core --data-dir <dir>`（换了数据根就是**另一个实例身份**：单实例锁按数据根区分） |
| 想同时开两份（调试） | 给第二份不同的 `TREE_HOME`，或显式 `TREE_INSTANCE_KEY=<任意不同值>`；都不设则第二份会退出并把已有窗口叫到前面 |
| 前端连不上核心 | 看 UI 错误页给出的修复指引；确认 `tree_core.exe` 位置或 `TREE_CORE_*` 环境变量 |

## 8. 发布检查单

- [ ] `dart analyze`（6 个 Dart 包 + `tree_core_cli/bin` + `tool/`）+ `flutter analyze lib test` 零告警
- [ ] 7 个包测试全绿（`tree_protocol` / `tree_tunnel_protocol` / `tree_agent` / `tree_ssh_plugin` /
      `tree_local_exec` / `tree_core` / `tree_core_cli`）+ `flutter test`；数字对照 §6 基线
- [ ] **出包前先产出两份 SSH 执行器二进制**：`dart run tool/build_ssh_plugin.dart` 与
      `dart run tool/build_agent.dart`。`package_windows.dart` 会把 `build/plugins/`、
      `build/agents/` 复制进发行目录 —— 产物**缺失**不会报错（只是包内没有中转站、核心自动回退内置
      dartssh2）；产物**版本对不上**则会**直接拒绝出包**（`_verifyBinaryVersion`，2026-10-11 加），
      所以**改了版本号必须重跑上面两条**。出包后按下面那条再核一遍必备件
- [ ] 门控真机端到端（`TREE_SSH_TEST_*` 具备时）：`dart run tool/tunnel_e2e.dart` 与
      `packages/tree_core/test/ssh_tunnel_e2e_test.dart`
- [ ] `CHANGELOG.md` 记录本次版本的用户可见变化
- [ ] `tool/package_windows.dart` 出的 zip 自检通过；安装包流程走一遍
- [ ] 便携目录的 `plugins/` 里没有 `__pycache__` / `*.pyc` 等本地产物（脚本已过滤 + 清残留，再出现说明有别的路径漏了）
- [ ] `docs/known-issues.md` 的未决项已复核（哪些已修、哪些进下个版本）
- [ ] 新增/修改的行为在对应模块 README 的**不变量**节里有落点
