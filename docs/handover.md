# 交接文档：插件化收口（2026-10-26）

> 读者：接手这套代码的人。
> 本文只写**当前事实、硬约束与待办**；设计与推演过程在 [ui-pluginization.md](pluginization/ui-pluginization.md)
> 与 [agent_pluginization.md](pluginization/agent_pluginization.md)，不要从本文脑补设计。
> 文中数字（路由数、测试数）都是**最后一次实测值**，改动后请同步。

---

## 1. 一句话现状

内核已收成**纯调度面**（39 条永久路由），agent / 文件 / 本机与 SSH 执行 / MCP / 压缩全部由插件承接，
Flutter 前端已是一份可装卸的 `kind: ui` 插件（支持同插件多窗口、多 UI 插件并存）。
**代码主干完成，剩下的是 4 项 P0 未开工、5 项真机验收（P1）、发版工程**（逐项展开见 [§7.4](#74-展开侦查2026-10-31只读核对)）。

| 基线 | 值 | 出处 |
| --- | --- | --- |
| 核心永久路由 | **39**（控制面 19 + 传输设置 9 + 引导壳 3 + 发现面 1 + 日志 3 + 存储 4） | `ApiPaths.coreOwned` |
| 插件委派路由 | **54** | `ApiPaths.delegated` |
| 契约全集 | **93**（39 + 54） | `contractRoutes` |
| 可达路径白名单 | **71** | `ApiPaths.kept` |
| 待交接路由 | **0** | `pendingHandoffRoutes` |
| 内置 Spec | 4（general-task / hard-task / team-meeting / plugin-creator） | `plugins/tree.agent/lib/src/spec/builtin_specs.dart` |
| 核心内置插件条目 | 4（sample / compact / ssh_executor / self_updater） | `packages/tree_core/lib/src/plugin/builtin_plugins.dart` |

---

## 2. 任务背景（为什么长成现在这样）

核心定位从「单体 agent 应用」改为「**面向未来的插件型超级应用的调度核心**」。四步落地：

1. **协议面收束**：REST 路径与 WS 帧单一真源在 `packages/tree_protocol`；核心只硬编码自己的永久面。
2. **路由去静态化**：插件启动时经 `system.collect.api.routes` 申报端点，核心只做归属转发 + 响应形状校验；
   保留前缀、`coreOwned` 同键、双插件抢同一 `method+pattern` 一律可读拒收。
3. **领域下沉**：agent/llm/tool/files/terminal 共 52 个文件从核心删除，落到 `tree.agent` / `files` /
   `local_executor` / `ssh_executor`；核心不再持有 PTY、不认识会话与工具。
4. **UI 插件化**：Flutter 前端变成 `runtime: ui` 插件，经 `TREE_CORE_URL` + `TREE_CORE_TOKEN` 附着核心；
   核心只记连接与能力，不管窗口内容；UI 多窗口 = 多进程。

明确的**不做**（已拍板）：核心通用流中继原语、UI 新数据面、Git 端点、stdio 侧多实例、引导壳托盘（本期）。

---

## 3. 当前架构（四角色）

```
引导壳 Tree.exe（非 Flutter，不可卸载）
  ├─ 拉起内核；提供插件管理页兜底（无可用 UI 时）
内核 tree_core（纯 Dart）
  ├─ CoreServer：39 条永久路由 / 鉴权 / 路由覆盖度不变量
  ├─ PluginBus：插件进程表 · 站点总线 · 委派路由归属 · UI 窗口表
  └─ WsStationBridge：UI 订阅、四态投递（data / closed / lagged / reset）
功能插件（stdio JSON-RPC 2.0）
  tree.agent / files / local_executor / ssh_executor / mcp / compact / extra-tools / self_updater
UI 插件（WebSocket 客户端）
  tree-ui-default …（每窗口一个进程，靠 TREE_UI_WINDOW_ID 区分）
```

要点：

- **站点四类**：广播 / 执行 / 中转 / 收集；点位由核心与插件各自申报，`/api/meta` 是唯一发现面。
- **插件三类贡献面**：广播站（增量事件）、收集站（快照 / 能力申报）、委派（承接 REST）。
- **UI 只消费不提供**：功能调用一律 REST 委派；WS 上行白名单仅
  `ui.hello` / `station/subscribe` / `station/unsubscribe` / 自有站 `trigger` / 终端帧 / `heartbeat`。
- **多窗口语义**：`POST /api/plugin/windows` 由**核心**拉起进程并分配 `w1`/`w2`…（序号只增不复用，
  单插件上限 8），窗口号经 `TREE_UI_WINDOW_ID` 注入、在 `ui.hello.window_id` 回带；
  关一个窗口只更新状态，**最后一个**退出才做插件级收尾（才发一次 `closed`）。
- **托盘归属**：回环端口当锁（`tray:<core instanceKey>`），同一核心只有一个窗口装托盘；
  「退出 Tree」先列窗口再逐个关（自己放最后）。
- **站点水位**：`seq` 是**通道级**计数；每条新通道订阅成功必发 `reset`，UI 把领域站
  `reset`/`lagged` 合成 `station_resync` 重拉快照。

---

## 4. 已交付（可直接核对）

### 4.1 桌面仓 `desktop` 分支

| 提交 | 内容 |
| --- | --- |
| `258a28c` | `refactor(core)!`：删除领域实现；核心 39 条路由；UI 多窗口三端点；新通道 `reset`；协议基线 39/54/93/71 |
| `bb01f2f` | `feat(ui)`：多窗口与托盘归属锁、`station_resync` 重拉快照、503 提示条、终端走执行器 REST、Git 面板下线 |
| `f7183f2` | `docs(pluginization)`：L-01 三差异清零记录、reset/快照口径、窗口级 `ui_hello_seen`、台账与 README 回写 |
| `503f6d3` | `docs`：重写项目 README（四角色架构） |
| `5035102` | `docs`：校准 CONTRIBUTING 与 known-issues（编号去重、终态口径、新增 #38–#41） |

### 4.2 插件仓 `plugins/`（分支 `master`，独立 git 仓）

| 提交 | 内容 |
| --- | --- |
| `c03aecf` | `ssh_executor`：分块读写、原子 `rename`、`list.details`、条目改工作空间根相对（L-01 差异 3 根因） |
| `750f282` | `ssh_executor`：SSH 终端会话（复用 tree.agent 租约，REST + 广播站） |
| `3345430` | `local_executor`：本机 PTY 终端会话 |
| `ff220f7` | `files`：新增插件，13 条文件路由（含 SSH 全量，无降级缺口） |
| `df1c485` | `tree.agent`：执行器激活站 `executor.activate` + `POST /api/agents/{id}/activate`、原生 spec 工具、reset 路径归一 |
| `85fa4f6` | `self_updater`：修文档相对链接 |

### 4.3 测试基线（最后一次实测）

| 套件 | 结果 |
| --- | --- |
| `packages/tree_core` | analyze 干净；`dart test` **618 passed / 2 skipped**（#42 第一轮修复后 15 轮全量连绿，含 5 轮 `-j 16` 超订；第二轮补掉四处挂钟判据与一处 fixture 假前提后再压 15 轮，全绿） |
| `packages/tree_protocol` | **68 passed**（含路由完备性与文档门禁） |
| 根仓 | `flutter analyze` 仅既有 10 issues（`tree_tunnel_protocol` + `thinking_window_test`，与插件化无关）；`flutter test` **886 passed** |
| `plugins/tree.agent` | **363 passed** |
| `plugins/ssh_executor` | **187 passed** |
| `plugins/files` | **10 passed** |
| `plugins/local_executor` | 自检 **23 passed** |

---

## 5. 环境与门禁

### 5.1 工具链

- 维护版本：**Flutter 3.47.5 / Dart 3.13.4**，本机实测在
  `D:\app\flutter-sdk-3.47.5\flutter\bin\`（`dart.bat` / `flutter.bat`）。
- ⚠️ PATH 里的 `dart`/`flutter` 指向 `D:\app\flutter\flutter`，是 **2.19.6** 老 SDK，
  会给出莫名其妙的语法/依赖错误。一律用上面维护 SDK 的全路径。
- 两套 SDK 并存时，收尾前关掉另一套 SDK 的 IDE，避免旧缓冲区覆盖已提交代码。

### 5.2 门禁（每个改动片按此顺序）

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
# 5) 只有动了 UI 才跑（根目录）
<flutter-sdk>/bin/flutter.bat analyze lib test
<flutter-sdk>/bin/flutter.bat test
```

插件仓各自跑自己的测试（`cd plugins/<name> && dart test`）。

### 5.3 常见坑（都已踩过）

1. `plugins/` 是独立仓的本地 clone，桌面仓提交**不带**插件改动；两侧分别提交。
2. 站点 `seq` 是通道级：不发 `reset` 就会在重连后整段丢帧。
3. 执行器 `file.*` 的条目必须是**工作空间根相对**，本机与 SSH 同形（否则 spec reset 路径会多一层）。
4. 核心 `stdout` 只允许握手行，日志走 `stderr`；核心 stderr 若无人读且是管道，会在 shutdown 时卡住。
5. 网络/LLM/时钟不进单测：用假传输、假时钟、可注入节拍器。
6. 用例判据**挂在证据上，不要挂在挂钟上**（known-issues #42，两轮共修七处）：
   - 站点面：`publish` / 插件下线 / 站点注销都只作用于「通道已建好」的订阅，用固定
     sleep 等另一条连接的订阅帧处理完，满负载跑全量时会假红。订阅成功的同步回证是
     **点名本站的 `reset` 帧**；注册 / 注销没有确认帧，轮询核心状态或 `/api/meta` 的
     `ui[].connections`。同一连接内的帧按序处理（`_handleHello` / `_handleSubscribe` /
     `_handleRegister` 都是同步 `void`），所以 hello 之后紧跟的同连接帧不需要等。
   - 收尸面：看门狗每轮记一次丢拍，判活窗口只有 3 拍，用例不能靠「跑很多轮 × 固定
     sleep」间接假设证据会到——每轮前先确认 `missed_heartbeats` 已被新入站心跳清零。
   - 放宽 sleep 治不了这一类：360ms 窗口照样被满负载跨过。
   - **两个节拍源**也算挂在挂钟上：`PluginBus.start()` / `applyConfigs()` 会自己挂一个
     自主看门狗，用例手按 `watchdog()` 时它仍在 `await` 期间偷记拍，把「判失活 → 强杀 →
     销账」整条链自己跑完。断言按拍数成立的性质时，间隔要给到 5 分钟（摘掉自主节拍，
     判活窗口本身不变），节拍归用例管。
   - **fixture 的前提要能证伪**：`suspendable_plugin.dart` 的「沉默但不退」原先没有
     钉住事件循环，核心关掉 stdin 后虚拟机自己就退了——用例一直只在赌进程死得比断言慢。
     赌生死和赌时间戳是同一件事。

---

## 6. 仓库与发版状态

| 项 | 状态（2026-10-31 实测） |
| --- | --- |
| 桌面仓分支 | `desktop`（`main` 是旧的服务端 Python 形态，不合并） |
| 插件仓分支 | `master`（`plugins/` 内） |
| 工作区 | 两仓均干净 |
| 推送 | 桌面仓 **GitHub 已同步**到 `4b75dac`；**Gitee 落后 85 个提交**（`gitee/desktop` 停在 `477dbfc`）；插件仓 GitHub 已同步到 `85fa4f6` |
| 版本号 | `pubspec.yaml` → `1.0.4+3`，**与已发布 tag 同号** |
| Tag | 最新 annotated tag = `v1.0.4+3`（→ `41ccddf`，2026-10-19，已在 origin）；**插件化的 88 个提交未被任何 tag 覆盖** |
| 发布资产 | **未挂**（setup / 插件 zip） |

> 原先本节写「未 push / 未打 tag」，与仓库实况不符，已按实测更正。
> 由此 **D-4「沿用 `1.0.4+3`」不可行**：该版本已有 annotated tag 且已推到 origin，
> 沿用等于给两个不同提交挂同一个版本号，必须 bump。

发版流程（细节见 [development.md](development.md) 发布检查单）：

1. 两仓分别 push；桌面仓**两个远端都要推**（GitHub 已同步、Gitee 落后 85 个提交）；
2. `dart run tool/build_core.dart`、`dart run tool/build_plugins.dart`（逐个 `--selftest` + 写发布索引）；
3. `dart run tool/package_windows.dart --flutter <flutter.bat>` → `dist/tree-desktop-<版本>-windows-x64.zip`；
4. `dart run tool/package_ui_plugin.dart --build` → `tree-ui-default-<版本>.zip`；
5. Inno Setup 编译 `tool/installer/tree-desktop.iss` 出 setup；
6. 打 annotated tag，挂 setup / zip 资产；
7. 插件包按「Gitee 优先、GitHub 兜底」上传，不改既有 release 内容。

---

## 7. 遗留项（按优先级）

### P0 · 阻塞交付

| 项 | 现状 | 完成标志 | 关联 |
| --- | --- | --- | --- |
| **数据接管 + 回滚** | 未设计。插件直接读写 `agents.yaml` 与 `data/`，升级中途失败无退路 | 原地接管 + 一次性备份 + 回滚入口 + 「接管失败可回滚」用例 | L-05 / G-5；前置 **L-22** `core_settings` 拆分；known-issues #39 |
| **性能基线** | 50ms/32token 合并、首字延迟差 ≤50ms 均未测 | 固定脚本压测，与迁移前数据对比并落文档 | L-06 / G-6；known-issues #40 |
| **本地 zip 安装** | 只有仓库安装通道，无本地端点/UI 入口 | 补 `POST /api/plugin/install/local`，或明确本期不做并改文案 | L-10；known-issues #38 |
| **compact 命令面失效** | A5 撤了领域实现、没撤点位表 ⇒ 20 条内置命令「申报了、路由得到、执行必失败」，随包插件 compact 的 `llm.call` / `fs.read` / `tool.call` / `agent.compact` 四条全踩在上面。**已收口（2026-10-31，片 1 / 片 3（桌面）+ 片 2 / 片 4 / Q-7 (a)（插件））**：点位表领域族清零（36 → 28 点位、29 → 9 命令）、撤 `tool.` / `agent.` 前缀禁令、落盘空壳读侧对账、两处门禁；两执行器改名成对称的 `local.*` / `ssh.*` 各 10 条 + 租约统一到插件侧 + tree.agent 换口 + 核心撤 `workspace/register` 与租约簿记 ⇒ **文件与终端两族真机已能打通**；让名的另一半由 tree.agent 在 `agent_tools` 站认领 `llm.call` / `fs.read` / `tool.call` / `agent.compact` / `session.rename`（插件仓 `b21e946`），compact / sample **命令名零改动**即恢复 | 真机复核 compact 的三条功能（总结调用 / 必读文件 / todo 快照） | **L-25 Q-5 / Q-7**；known-issues **#43**；契约 §8.4 落地状态 |
| **执行站契约登记** | 契约文档已落（[exec_station_contract.md](exec_station_contract.md)：信封 / 命令表 / 码来源 / 幂等逐条对照 + 目标口径 + §8 已拍板统一口径）；**片 1 / 2 / 3 / 4 / 5 均已合**（2026-10-31，片 5 = 桌面仓 `8876254` + 插件仓 `f578894`）；`code` 八环链路、`tree_protocol` 码表、§5 门禁五条断言全部落地，门禁六条用例与 tree_core 全量 627 条跑绿（`ssh_lease_unknown` / `local_lease_unknown` 已归并为 `lease_unknown`） | 文档 §8.4 全部落地，门禁跑绿 | L-25 |
| **插件仓 CI** | 脚本 `tool/check_plugin_repo_contract.dart` 已可跑（`--selftest` 5/5），未接进 tree-plugins CI | 插件仓流水线跑同一脚本 | L-21 |
| **发版工程** | 见 §6，全部未执行 | push + tag + setup/zip 资产 | — |

### P1 · 真机验收（必须在有环境的机器上做）

| 项 | 内容 |
| --- | --- |
| **L-03** | 事件面双轨：帧序 / 丢帧 / `closed` / `reset` 与快照对齐 |
| **L-15** | E2E-01~13（其中 **E2E-13 = 多窗口 / 多 UI 插件**；E2E-04 断线重连、E2E-06 依赖 L-03） |
| **L-16** | `architecture.md §13` 的 12 项跨模块不变量回归 |
| **L-07 / G-7** | 崩溃 → 503 顶部提示条的真机复现（代码已接，需现场确认） |
| **真 sshd** | SSH 终端、`ssh.file.*` 分块、`ssh.rename` 原子性（单测用假通道，真链路空白） |

### P2 · 可延后（已拍板不做或下期）

> 逐项的现状证据与开展入口见 [§7.4](#74-展开侦查2026-10-31只读核对)；其中 **L-04 的过渡映射代码确实存在**（就是 `frame_router.dart` 整层），原「未发现」的说法已更正。

L-04 过渡映射（需一个版本周期）、**L-13 引导壳托盘**（known-issues #41）、L-14、L-18、
L-20 stdio 多实例、L-23 scope 去领域化（协议破坏性变更，单独立项）、L-27 功能裁剪、L-30~L-34 插件侧契约复测。

### P3 · 文档债

- `docs/ssh-tunnel-protocol.md:363-369` 的 UI 视图段落**复核结论是"已是当前协议"**（manifest 只发一次 → `ui/update`，动作判据 `params['event']`），无需删段，只差一句"这是当前协议"的口径（见 §7.4 L-18）。
- ~~`docs/plugin-development.md` 的「35 个点位」是静态旧数字~~ → **复核：全文已无 `N 个点位` 的静态数字**，此项可删。
- `known-issues` 已去重（终端迁移 → #37），后续新增取当前最大号 +1。

### 7.4 展开侦查（2026-10-31，只读核对）

> 这一节只回答两件事：**要动手时第一眼该看哪**、**第一条该跑什么**。结论不重复正文其它节。
> 核对方式：源码 grep + 现有测试清单；**未做任何代码改动**。

**P0**

| 项 | 现状证据（已核实） | 缺口 | 开展入口 |
| --- | --- | --- | --- |
| 数据接管 + 回滚 | 前置 **L-22 仍未开始**：核心 `core_settings.dart` 仍混装模型池 / token 节奏与平台开关（acceptance L-22 行）；`plugins/tree.agent/lib/` 内无备份 / 接管代码（只有 `paths.dart:5` 写了"同一文件只…"的布局口径）；known-issues #39 | **已拍板（D-5 + D-10）**：先拆 settings（平台级 vs 领域级），再只接管 `agents.yaml` + 会话历史，补「原地接管 + `.bak`/时间戳备份 + 回滚入口 + 接管失败可回滚」用例；工作空间不进本轮 | `packages/tree_core/lib/src/settings/core_settings.dart`、`plugins/tree.agent/lib/src/paths.dart:5`、known-issues #39 |
| 性能基线 | `tool/` 下**没有任何压测脚本**（只有 build / package / contract 检查类）；无迁移前后对比数据；known-issues #40 | 固定脚本：同 prompt / 同模型档 / 同会话长度，记首字延迟、每帧 token、帧率、CPU | 新建 `tool/bench_*.dart`；对照基线见 §4.3 |
| 本地 zip 安装 | 安装通道只有 `POST /api/plugin/release/{id}/install`（`packages/tree_core/lib/src/server/core_server.dart:2784`，清单 2742 / 刷新 2759 / 卸载 2887）；全仓无 `install/local`；前端 `file_picker` 只用于工作空间文件同步 | **已拍板补端点（D-1）**：`POST /api/plugin/install/local`，复用仓库通道的安装后处理与面板流程；未实现前不算关闭 | `core_server.dart:2742-2890`、`packages/tree_core/lib/src/plugin/plugin_downloader.dart`（安装实现）、known-issues #38 |
| 插件仓 CI | **两仓都没有 `.github/`**（路径不存在）；脚本 `tool/check_plugin_repo_contract.dart` 可跑（`--selftest` 5/5） | **已拍板（D-9）**：两仓都加 `.github`，插件仓独立 workflow 跑同一脚本 + 各插件 `dart analyze` / `dart test` | 插件仓根目录新增 `.github/workflows/`；脚本入口见 §5.2 第 4 步 |
| 发版工程 | 最新 annotated tag 仍 `v1.0.4+3`（插件化提交未被任何 tag 覆盖）；`dist/` 存在；远端 `origin`（GitHub）+ `gitee` 都在，本地分支已与 `origin/desktop` 齐平 | 按 §6 七步执行（bump 版本、两远端推、构建、打包、ISP、tag、挂资产） | §6 发布检查单 |

**P1（真机验收）**

| 项 | 现状证据（已核实） | 缺口 | 开展入口 |
| --- | --- | --- | --- |
| L-03 事件面双轨 | `lib/io/frame_router.dart:11-93`：topic 的 kind → 旧帧名、`closed` 不转投、`reset`/`lagged` 合成 `station_resync`；`test/frame_router_test.dart` **5 条**（含 seq 水位：重复/回退丢弃、跳号记账、reset 清零） | 真机双轨比对：帧序 / 丢帧 / `closed` / `reset` 与快照对齐；替身测试不能证明投递真到达 | `flutter test test/frame_router_test.dart`；真机跑 E2E-03 / 04 / 05 |
| L-15 E2E-01~13 | 清单定义在 `docs/pluginization/ui-pluginization_acceptance.md:182-194`（01~13，**E2E-07 Git 已删**）；**仓库内没有 E2E 脚本**（`tool/tunnel_e2e.dart` 只覆盖隧道专项） | **已拍板（D-11）**：先按清单手工执行并逐条记录证据；只把事件面三项（E2E-03/04/05）脚本化，其余等环境稳定再脚本化 | 先读该清单；E2E-04 依赖 L-03、E2E-06 依赖事件站 |
| L-16 §13 12 项 | `docs/architecture.md:218-260` §13 共 **12 项**（工具路径 / 私有状态 / 提示词重建 / 判活 / 插话与 stop / 失败可读 / 协议常量 / 落库优先 / 密钥不进日志 / 能力坏路径 / Windows RedirectionGuard 自愈 / SSH 降级只在一维） | 无统一回归脚本，需逐项手工确认（第 11 项有 `--tree-rt-selfcheck` 可自动验证） | `docs/architecture.md#13-跨模块不变量assertions` |
| L-07 / G-7 503 提示条 | `lib/io/service_availability.dart:7-42`（记最近一次 503 + 领域成功后清空 + 手动关闭）+ `test/service_availability_test.dart` **2 条** | 真机复现：强杀/停用插件 → 领域请求应 503 而非 404，顶部横幅出现且可关闭 | 起 `tool/dev_run.ps1` 后杀插件进程；核心分支在 `plugin_bus.dart` 崩溃/停用处 |
| 真 sshd | `plugins/ssh_executor/test/fake_ssh.dart` 是**模拟通道**；`executor_process_test.dart` 起真实 stdio 进程但**不是真 sshd**；`bootstrap_test.dart:194` 只是引用 2026-10-10 的历史实测；`tool/probe_command_len.dart` 已不在仓库 | 起真 sshd 跑：`ssh.file.*` 分块读、`rename` 原子性、SSH 终端（**已拍板 D-8：本机 docker 跑 sshd 容器**，不依赖 WSL / 外部机器） | `plugins/ssh_executor/README.md` + 上述三个测试文件；先准备 docker 容器与 `.ssh/config` 夹具 |

**P2（已拍板不做/下期）**

| 项 | 现状证据（已核实） | 展开时要知道的事 |
| --- | --- | --- |
| L-04 过渡映射删除 | **过渡代码是存在的**，就是 `lib/io/frame_router.dart` 整层（`:15` 自述"这一层只做**换收口**"）+ `LegacyFrameBus` + `test/frame_router_test.dart`（`:180` 一条专测旧总线）。acceptance 里"未发现过渡代码"是错的 | 前置＝L-03 真机签收 + 一个版本周期；删除面＝该文件 + LegacyFrameBus + 5 条用例 + 各面板的 `LegacyFrameBus` 注册 |
| L-13 引导壳托盘 | `tool/tree_launcher/bin/tree_launcher.dart:13`「本期不做 Windows 托盘图标（需要 Win32 FFI 或第三方包）」、`:272` 用户提示同口径；known-issues #41 | 改动面＝launcher（Win32 FFI 或托盘包）+ 安装器；与 UI 插件托盘归属锁（`tray:<core instanceKey>`）不能混为一谈 |
| L-14 运行中更新可能挂起 | `packages/tree_core/test` 内**零命中**「运行中 / update·running / hot update」；最接近的是 `plugin_config_api_test.dart` 的 install / uninstall / 依赖用例 | 补一条「运行中的内置插件从仓库更新」回归；夹具可复用该文件现有的假索引与假产物 |
| L-18 UI 视图文档对齐 | `docs/ssh-tunnel-protocol.md:363-369` 描述的 `ui/manifest` 只发一次 + 之后 `ui/update`、动作判据在 `params['event']` —— **已经是当前协议**，不是旧协议；`plugin_ui_action` 仍在使用（`plugins/sample` / `terminal_probe` 按 `event` 通知处理，裸 `method` 仅作老核心兼容）；`plugin-development.md:922` 的退役声明不冲突 | 要做的是**补一句口径**（"这是当前协议"）并全仓复核，**不是删段**；顺带可修 §7 P3 的「35 个点位」旧数字 |
| L-20 stdio 多实例 | `plugin_bus.dart:290` `Map<String, PluginHost> _hosts`，键＝`config.id`（**一插件一宿主**）；无任何 `(plugin_id, agent_id)` 键痕迹；站点 id 也按插件 id | 改动面＝宿主表键 + 站点命名空间 + 委派按信封 `agent_id` 路由 + 每实例看门狗/并发上限；属平台立项 |
| L-23 scope 去领域化 | `packages/tree_core/lib/src/plugin/station_scope.dart:5`（四字段 `team_id/agent_id/session_id/mode_key`）、`:117-129`（序列化进 wire 的 `scope` map）；mode_key 已明确不兜底成 `local`（`:103-106`） | **侦查已完成（D-2，本期不实现）**：见 [pluginization/scope-de-domainization-recon.md](pluginization/scope-de-domainization-recon.md)；下期按 S0~S4 执行（mode_key → team_id 两步下沉，agent/session 保留） |
| L-27 功能裁剪 | 路由口径 36/54/93/71 出自 `ApiPaths`（§1 基线表）；候选裁剪项**都还有实现与调用方**——`token-rate` 在 `plugins/tree.agent/lib/src/delegate.dart:59,531-544` 与 `tree.agent_plugin.dart:1730` 自检、前端设置页仍在用 | 缺的是**真实使用数据**与产品决策，不是代码清理；不要与迁移混做 |
| L-30~L-34 契约复测 | L-30：`plugins/tree.agent/lib/src/delegate.dart:81-105` `_bodyOf` 抛 `FormatException`（未统一成 400，顶层兜底待复核）；L-31：`packages/tree_protocol/lib/src/api_paths.dart:33-35` 仍是双 `{memberId}`，tree.agent 申报用 `{leaderId}`；L-32 `createAgent` 仍缺建成员参数；L-33 三处（未知 session 200 / DELETE 200 / 空 body token-rate）未复测；L-34 `sub_` id 语义未定 | 全部等 G-1 行为基线冻结后单独评审；L-31 必须核心 + 前端 + 插件 + 契约常量同批改 |

---

## 8. 硬约束条例（破坏即视为回归）

### 8.1 核心侧

1. 核心**只**硬编码 `ApiPaths.coreOwned` 的 39 条；不得为任何插件路由写专用 handler。
2. 核心不认识 agent / 会话 / 团队 / 模型 / 文件 / 终端等任何领域概念。
3. 委派层只做路由、身份透传、响应形状校验；四要素 fail-closed 校验留在核心，不下放插件。
4. 转发执行站命令时**无条件删除**调用方传入的 `root`，只注入租约根（路径守卫不可绕过）。
5. 大文件只走 `body_path` / `result_path`，禁止 base64 内联。
6. `/api/meta` 是聚合发现层：路由来自 `system.collect.api.routes`，站点来自内置点位 + 插件申报；
   核心不维护第二份静态清单。
7. 核心不持有 PTY，不实现执行语义，不新增通用流中继数据面。
8. 插件崩溃/停用 ⇒ 归属路由回 **503**（不是 404）；未申报/无归属才 404。

### 8.2 插件侧

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

### 8.3 UI 侧

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

## 9. 关键文件地图

| 关注点 | 从哪读起 |
| --- | --- |
| 核心路由（39 条） | `packages/tree_core/lib/src/server/core_server.dart` |
| 插件平台（进程 / 站点 / 委派 / 窗口） | `packages/tree_core/lib/src/plugin/plugin_bus.dart`（大文件，按符号搜） |
| UI 进程与窗口号 | `packages/tree_core/lib/src/plugin/ui_host.dart` |
| UI WS 订阅桥 | `packages/tree_core/lib/src/plugin/station_ws_bridge.dart` |
| 协议真源 | `packages/tree_protocol/lib/src/api_paths.dart`（`coreOwned` / `delegated` / `kept`） |
| UI 附着核心 | `lib/io/core_attachment.dart`、`lib/io/ui_identity.dart` |
| 托盘与退群 | `lib/io/tray_service.dart` |
| 503 提示 | `lib/io/service_availability.dart` + `lib/ui/...` 顶部横幅 |
| 终端传输面 | `lib/ui/services/terminal_transport.dart` |
| agent 插件委派 | `plugins/tree.agent/lib/src/delegate.dart` |
| agent 执行器激活 | `plugins/tree.agent/lib/src/station/agent_executor.dart`、`runtime/agent_runtime.dart` |
| 文件插件 | `plugins/files/lib/` |
| SSH 执行站 | `plugins/ssh_executor/lib/src/exec_station.dart` |
| 构建与打包 | `tool/build_core.dart`、`build_plugins.dart`、`package_windows.dart`、`package_ui_plugin.dart`、`installer/tree-desktop.iss` |
| 契约门禁 | `packages/tree_protocol/test/protocol_completeness_test.dart`、`test/docs_contract_test.dart`、`tool/check_plugin_repo_contract.dart` |

文档入口：[architecture.md](architecture.md)（进程与不变量）、[development.md](development.md)（构建/打包）、
[plugin-development.md](plugin-development.md)（写插件）、[team.md](team.md)（团队语义）、
[ui-pluginization.md](pluginization/ui-pluginization.md)（核心侧权威口径）、
[ui-pluginization_acceptance.md](pluginization/ui-pluginization_acceptance.md)（验收台账）、
[agent_pluginization.md](pluginization/agent_pluginization.md)（agent 承接范围）、
[agent_api_contract.md](pluginization/agent_api_contract.md)（逐条契约与样例）、
[known-issues.md](known-issues.md)（台账，当前最大编号 #43）。

---

## 10. 接手第一小时

1. 读本文 §1/§3/§8；再读 `docs/pluginization/ui-pluginization.md` §1、§4（不要读全过程记录）。
2. 按 §5.2 跑一遍 `tree_protocol` + `tree_core` 门禁，确认基线数字与 §4.3 一致。
3. `dart run tool/dev_run.ps1` 起一次，确认 UI 附着、插件列表、终端可用。
4. 从 §7 的 P0 挑一件；**先改文档口径，再改代码**（避免半截漂移）。
5. 提交前按 §5.2 全量过门禁；两仓分别提交。

**不要做**：不要给插件路由补核心 handler；不要让 UI 直连执行站；不要把大文件塞进 JSON；
不要用 PATH 里的 `dart`；不要动 `git config`；不要未经确认就 push / 打 tag / 删 tag。

---

## 11. 决策记录（2026-11-01 拍板）

| 编号 | 问题 | 结论 |
| --- | --- | --- |
| D-1 | 本地 zip 安装（L-10） | **本期补端点**：`POST /api/plugin/install/local`，复用仓库通道的安装后处理（known-issues #38 已改状态） |
| D-2 | `scope` 去领域化（L-23） | **本期只做侦查，不做实现**：报告已落 [pluginization/scope-de-domainization-recon.md](pluginization/scope-de-domainization-recon.md)，下期按 §5 的 S0~S4 执行 |
| D-3 | 功能裁剪（L-27） | **维持现状（36 条功能面）**：候选裁剪项仍有实现与调用方（`token-rate` 等），缺的是使用数据而非代码清理；不随迁移做 |
| D-4 | 发版版本号 | **`1.0.5+1`**（`1.0.5` 对应插件化收口，build 号重新从 1 起） |
| D-5 | 数据接管范围（L-05） | **仅 `agents.yaml` + 会话历史**；工作空间是用户文件，接管风险与回滚成本都高，本轮不进 |
| D-6 | 图像内联与 JSON 上限（契约 Q-3） | **两层保证**：所有内联图像归一到长边 `[360p, 1024p]`（等比压缩/拉伸）→ 再以 JSON 上限（建议 4 MiB）兜底，超限走 `result_path`（契约 §7 已记） |
| D-7 | REST 面错误结构（契约 Q-4） | **统一为 `{status, code, message}`**，REST 面同批做，不另开片 |
| D-8 | P1 真机 SSH 环境 | **本机 docker 跑 sshd 容器**（不依赖 WSL / 外部机器），跑 `ssh.file.*` 分块、`rename` 原子性、SSH 终端 |
| D-9 | 插件仓 CI | **两仓都加 `.github`**：插件仓独立 workflow 跑 `check_plugin_repo_contract.dart` + 各插件 `dart analyze` / `dart test` |
| D-10 | P0 前置 L-22 | **拆** `core_settings`（平台级 vs 领域级），**按乙方案·分文件**：领域键落 `config/agent_settings.yaml`、核心退出该键并条件化删旧键（带备份）；细则、覆盖风险与迁移顺序见 [agent_pluginization.md §4.8.1](pluginization/agent_pluginization.md)。不拆则数据接管无法开工 |
| D-11 | P1 的 E2E 口径 | **先手工跑 + 逐条记录证据**；只把事件面三项（E2E-03/04/05）脚本化（替身已成熟），其余等环境稳定再脚本化 |