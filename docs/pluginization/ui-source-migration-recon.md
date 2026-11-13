# UI 源码完全迁入 `plugins/`：语义对齐 · 侦察 · 实施方案

> 状态：方案稿（2026-11-08，三项决定已定稿：**UI 零依赖**、**核心面 43 → 35**、
> **核心只认识 `ui` / `headless` 两类插件**；第 10 节全部拍板，无遗留口径）。
> 本期只做语义对齐、侦察与落档，不改任何代码。
> 定位：承接 [ui-pluginization.md](ui-pluginization.md)（运行期插件化）与
> [ui-pluginization_detailed.md](ui-pluginization_detailed.md)（U1–U6 落地）。那两份讲的是
> 「界面怎么被核心拉起」，本文件只解决**源码与构建归属**：Flutter 工程还要不要住桌面仓根。
> 目标：下期照第 9 节顺序开工即可推，不需要再做第二轮侦查。

---

## 0. 一句话结论

运行期早已是插件（核心 `UiHost` 拉起 `tree_ui.exe`、只认 `ui_identity.dart` 读到的
`plugin.json`），但**源码仍住在桌面仓根**（`lib/` + `test/` + `windows/` + 部分 `assets/`）。
本期要迁的是**源码位置与构建归属**：把整个 Flutter 工程搬进 `tree-plugins` 仓的
`plugins/tree.ui.default/`，桌面仓只留核心、引导壳、发布工程与文档。

不迁的三样：运行期协议、`plugins.yaml` 语义、发布索引形状。迁完后用户机器上的启动链
（`Tree.exe` → 核心 → `tree_ui.exe`）**一个字节都不变**。

同时确定两条边界（2026-11-08）：

- **零依赖**：UI 自持契约（`protocol_contract.dart`），不依赖 `tree_protocol`；
- **核心面收窄**：删 8 条无人调用的端点（`store/*`、`logs/*`、`data-collection`），43 → 35；
  核心只认识 `ui` / `headless` 两类插件，领域接口一律由插件自注册。

---

## 1. 语义对齐（先钉钉子，后面所有决定都从这里推）

### 1.1 「迁移」一共有四层，只有第四层没做

| 层 | 内容 | 现状 | 出处 |
| --- | --- | --- | --- |
| ① 运行期形态 | 界面由核心拉起、附着 `TREE_CORE_URL/TOKEN`、发 `ui.hello` | ✅ 已完成 | `lib/main.dart`、`lib/io/ui_identity.dart` |
| ② 产物发布 | `tree-ui-default-<ver>.zip` 作为 release 资产，索引里用 `archive` | ✅ 已完成 | `tool/package_ui_plugin.dart` |
| ③ 装机与升级 | 面板从发布源安装/更新、卸载保留 `enabled:false` | ✅ 已完成 | `plugin_downloader.dart`、`core_server.dart` |
| ④ **源码位置** | Flutter 工程住在哪个仓、哪个目录；谁跑 `flutter build` | ❌ **本次要迁**（方案已定，待实施） | 本文件 |

结论：第 ④ 层不涉及任何协议改动，不存在「迁完要重测全部界面」的问题；风险集中在
**构建链、CI、跨仓扫描门禁、版本出处**四处。

### 1.2 术语（本文件内一律按这张表用词）

| 词 | 指什么 | 不是什么 |
| --- | --- | --- |
| **UI 应用** | 本仓现在的 Flutter 工程（`lib/`、`test/`、`windows/`、`assets/tray_icon.ico`） | 不是核心的一部分 |
| **UI 插件** | 运行期的 `tree.ui.default`（`plugin.json` + `tree_ui.exe` + `data/`） | 不是「另一个仓库里的另一种技术」 |
| **插件仓** | `raditree/tree-plugins`，本地挂在桌面仓的 `plugins/`（桌面仓 `.gitignore` 掉） | 不是桌面仓的源码目录 |
| **桌面仓** | 本仓：核心、loader、发布工程、文档、契约门禁 | 迁移后**不再含 Flutter 工程** |
| **loader / 引导壳** | 发行版里的 `Tree.exe`（纯 Dart） | 不是界面 |
| **核心** | `tree_core.exe`（含插件系统、`UiHost`） | 不 import 任何 UI 代码（实测成立） |

### 1.3 核心与插件的边界（2026-11-08 对齐）

**核心只认识两类插件：`ui` 与 `headless`；不认识任何具体插件 id，也不定义任何领域接口。**

1. **按类别，不按身份**：核心只读 `plugin.json` 的 `runtime` 决定宿主形态
   （`ui` → `UiHost`，`headless` → stdio 宿主）。禁止 `if (id == 'xxx')` 这类分支
   （现状偏差见 §2.5）。
2. **接口由插件自注册**：领域路由由插件经 `system.collect.api.routes` 申报，核心只做
   归属转发与响应形状校验；核心 router 的键集恒等于平台点位清单，不硬编码任何插件路由。
3. **核心只保留通用接入点位**（不是领域接口）：
   - REST 委派信封（转发、归属校验、`body_path` / `result_path` 大文件规则）；
   - WS 站点总线（`station/subscribe`、`station_delivery`、心跳）；
   - 执行站（核心只挂 `plugin.*` / `station.*` 两族平台命令）；
   - 文件传输信封（分片上传 / 打包下载）；
   - UI 宿主（进程拉起、环境变量注入、`TREE_UI_WINDOW_ID`）。
4. **平台点位 ≠ 领域接口**：插件管理、传输设置、引导页、发现面这类点位可以由核心定义
   （否则无法自举，论证见 §2.5），但核心**不得**为某个业务功能新增路由。判断一条新端点
   该不该进核心的唯一问题是：它是否在「零插件 → 装好并连上第一个插件」这条路径上。
5. **身份与附着**（原两条，保留）：
   - 身份只来自 exe 同级 `plugin.json`（`lib/io/ui_identity.dart`）；源码搬家不许改成
     编译期常量注册，否则 `ui.hello` 报的 id 与 `plugins.yaml` 对不上，连接会被整条关闭；
   - UI 只附着、不拉核心；`TREE_CORE_URL` / `TOKEN` / `DATA_ROOT` / `WINDOW_ID` 由核心注入。
6. **零依赖**（D2）：UI 的契约常量由 **UI 自己拥有**（手写，不从核心生成），`pubspec.yaml`
   不依赖 `tree_protocol`；一致性靠「核心面对外冻结 + 黑盒一致性套件」，不靠源码 diff。
7. **必须承认的边界**：核心不认识插件，只保证「任何插件注册同名路由都会被转发」。用户
   自定义插件要被**默认界面**全功能使用，前提是实现同一套 UI 契约（路由模式 + 帧形状 +
   展示语义）——即可替换默认实现。全新形态（新的界面区域 / 交互）需要声明式 UI 渲染，
   属于另一个产品级特性，不在本次范围。

---

## 2. 侦察结论（全部为实测，不是推测）

### 2.1 现状盘点

| 路径 | 规模（git 跟踪） | 归属 | 迁移后去处 |
| --- | --- | --- | --- |
| `lib/` | 114（`ui/` 91、`io/` 19、`demo/` 1、`main.dart`、`app_version.dart`、README） | UI | `plugins/tree.ui.default/lib/` |
| `test/` | 100 | UI | `plugins/tree.ui.default/test/` |
| `windows/` | 18 | UI（唯一发布平台） | `plugins/tree.ui.default/windows/` |
| `assets/tray_icon.ico` | 1 | UI | `plugins/tree.ui.default/assets/` |
| `assets/icon/app_icon.png` | 1 | 无代码引用（历史资源；exe 图标走 `windows/runner/resources/app_icon.ico`） | 删除，或留桌面仓 |
| `assets/bootstrap/index.html` | 1 | **核心**（引导页种子） | **留在桌面仓** |
| `android/` `ios/` `linux/` `macos/` `web/` | 20/38/9/27/7 | 无（产品只发 Windows） | 建议删除（D4） |
| `pubspec.yaml` / `analysis_options.yaml` | 2 | UI + 发布版本 | 拆分（D3） |
| `tool/` | 15 | 桌面仓发布工程 | 留在桌面仓，改读 UI 目录 |
| `packages/` | 277 | 核心 / 协议 / 执行器 | 不动 |

**关键**：`assets/` 是混合归属，整目录搬迁会直接打断核心引导页（`bootstrap_page.dart`
按 exe 同级 `assets/bootstrap/` 探测；`server_bootstrap_test.dart` 更把
`assets/bootstrap/index.html` 当作「仓库根」判据）。必须按文件拆。

### 2.2 依赖方向（实测）

```
UI (lib/test) ──唯一──> package:tree_protocol（path: packages/tree_protocol）
核心 / loader / 协议包 ──X──> UI（没有任何 import）
```

> 这是**迁移前**的现状。按 D2（零依赖），迁移后 UI 侧这条箭头消失：契约常量改由
> `lib/io/protocol_contract.dart` 自持；核心侧的三条跨仓**扫描**仍保留（它们是核心的
> 门禁，不是 UI 的依赖）。

反向耦合只有**三处源码扫描**（不是 import，是测试读文件）：

| 位置 | 现在读什么 | 迁完的后果 |
| --- | --- | --- |
| `packages/tree_core/test/heartbeat_settings_test.dart:148` | `../../lib/io/websocket_service.dart` | **找不到文件 → 红**（已有 `existsSync` 断言，会明确失败） |
| `packages/tree_protocol/test/protocol_completeness_test.dart:179` | 递归扫 `lib`（缺目录 `continue`） | **静默失去覆盖**（更危险：门禁变绿但没扫到 UI） |
| `packages/tree_core/test/legacy_plugin_ui_protocol_test.dart` | 递归扫仓库根 | 本地/CI 检出插件仓后仍会扫到，行为基本不变；需确认跳过 `build/` 与 `.dart_tool/` |

### 2.3 构建与发布链现状

```
flutter build windows --release（桌面仓根，读根 pubspec + windows/CMakeLists.txt）
  → build/windows/x64/runner/Release/Tree.exe（Flutter runner，~450 KB）
  → package_windows ①b：改名 tree_ui.exe + 写 plugin.json
  → package_windows ②：dart compile exe 核心 → tree_core.exe
  → ②'：拷 pdfium.dll / assets/bootstrap / docs/plugin-development.md / 字体检查
  → package_ui_plugin：收 Release 目录 → tree-ui-default-<ver>.zip → 合并 build/plugins/plugin-index.json
  → package_windows 后续：loader（tree_launcher → Tree.exe）、zip、Inno Setup
```

| 入口 | 对根目录的硬假设 |
| --- | --- |
| `tool/package_windows.dart` | `Directory.current` 即仓根：必须存在根 `pubspec.yaml`、`packages/tree_core_cli/bin/tree_core.dart`；`_binaryName(root)` 读 `windows/CMakeLists.txt`；`flutter build` 在根跑；`_copyBootstrapAsset(root, …)` 读根 `assets/bootstrap` |
| `tool/package_ui_plugin.dart` | 同上：根 `pubspec.yaml` 取版本；默认 `build/windows/x64/runner/Release`；索引写根 `build/plugins/plugin-index.json` |
| `tool/build_plugins.dart` | 读根 `pubspec.yaml` 版本（`app_version_define`）、遍历 `plugins/*/plugin.json`、按「有无 `<id>_plugin.dart`」判形状 |
| `.github/workflows/ci.yml` `app` job | 直接 `flutter pub get / analyze lib / test`，cwd = 仓根 |
| `tool/installer/tree-desktop.iss` | 只吃 `ReleaseDir`（`build/windows/x64/runner/Release`），**不需要改** |
| `tool/tree_launcher` | 只读核心握手 + `plugins.yaml`/插件快照，**不需要改** |
| `tool/dev_run.ps1` | cwd = 仓根，核心入口相对路径 + `flutter run` |

### 2.4 耦合点清单（13 条，迁移必须逐条处理）

| # | 耦合点 | 现状 | 迁移后必须 |
| --- | --- | --- | --- |
| 1 | 桌面仓 `.gitignore` 第 122 行 `plugins` | 插件仓整目录不入桌面仓版本控制 | 保持不变；UI 源码因此**只能进插件仓**，桌面仓不再有 UI 源 |
| 2 | `check_plugin_repo_contract.dart` | 禁 `tree_core` + `tree_protocol`（import 与 pubspec 键） | **不用改**：零依赖（D2）后 UI 里不出现这两个包，无需白名单 |
| 3 | `plugin_repo_contract_test.dart`（tree_protocol 包内） | 校验 `plugins/*/plugin.json` 字段纪律 | UI 的 `plugin.json` 必须满足同一套形状（id=目录名、三段版本、`command` 在 `files`） |
| 4 | `protocol_completeness_test.dart` 扫 `lib` | 缺目录静默跳过 | 改成「UI 源码根」常量；**目录不存在直接 fail**（防静默降级） |
| 5 | `heartbeat_settings_test.dart` 读 `../../lib/io/…` | 路径写死 | 同上，走同一常量 |
| 6 | `legacy_plugin_ui_protocol_test.dart` 扫仓库根 | 自动覆盖 `plugins/` 子树 | 确认跳过 AI/构建目录；把 UI 新目录纳入扫描（顺带覆盖） |
| 7 | 版本三处：根 `pubspec.yaml` / `lib/app_version.dart` / `plugin.json` | `version_info_test` 读根 pubspec 比对常量 | 版本出处改到 UI 的 `pubspec.yaml`；测试随之搬家；打包写 `plugin.json` 时取 UI 版本（D3） |
| 8 | `package_windows.dart` 的根假设 | 见 2.3 | 新增 `--ui-dir`（默认 `plugins/tree.ui.default`）；`flutter build`、`CMakeLists`、`pubspec` 都按 UI 目录解析；bootstrap 仍按桌面仓根拷 |
| 9 | `package_ui_plugin.dart` 的根假设 | 见 2.3 | 版本取 UI `pubspec.yaml`；`--build` 在 UI 目录跑；索引仍写桌面仓 `build/plugins/` |
| 10 | `build_plugins.dart` 遍历 `plugins/*` | 找不到 `<id>_plugin.dart` 即报错 | 识别 `runtime: ui`：**显式跳过并打印指路信息**（不许静默跳过，也不许按 Dart 插件编译） |
| 11 | `redirection_guard_test.dart` | 相对 `build/windows/x64/runner/Release/…` | 随 UI 测试搬家后路径自然成立（cwd = UI 目录） |
| 12 | `hook_probe_test.dart` | 往 `Directory.current/.output/` 写探针文件 | UI 仓 `.gitignore` 补 `.output/`；其余不变 |
| 13 | `lib/app_version.dart` 的 `PluginDocs` 向上找 `docs/plugin-development.md` | 最多上溯 8 层 | 新路径 `plugins/tree.ui.default/build/windows/...` 只比原来多一层，仍能上溯到桌面仓根；S6 真机/本地各验一次 |

### 2.5 核心面 / 插件面盘点与「43 → 35」判定

**UI 实际调用的接口面**（本次实测）：

- `ApiPaths` 25 条常量 + 约 42 个路径字面量（去重后约 50 条路径）；
- 其中**只有 14 条是核心平台面**（插件管理 10 + 传输设置 4），其余全部是插件面
  （agents / files / models / questions / terminal / mcp…）；
- UI 目前**一次都不调 `/api/meta`**，而 `/api/meta.routes` 只发布委派路由——
  即「核心面 + UI 调用」当前靠硬编码维持，没有运行时发现。

**43 条核心面的四类判定**（判据：从「零插件、零 UI」到「装好并连上第一个插件」是否需要它）：

| 类 | 条数 | 内容 | 结论 |
| --- | --- | --- | --- |
| A 自举闭包 | 21 | 插件控制面 17（snapshot/configs/restart/builtins/release/install-local/station）+ bootstrap 3 + meta 1 | **撤不掉**：装第一个插件、无界面时的恢复、发现面自举都靠它 |
| B 核心自身依赖 | 12 | 传输设置 9（帧率/心跳/丢失阈值）+ 发布源 3 + 数据收集 1 | **撤不掉**：核心的 WS hub、插件判活、下载器在启动时读它们 |
| C 无调用方 | 7 | `GET /api/store/{ns}`、`GET/PUT/DELETE /api/store/{ns}/{key}`、`GET /api/logs/sources`、`GET/DELETE /api/logs/{source}` | **本期删除**：界面与插件仓源码零调用（仅一处注释提及） |
| D 可迁无收益 | 3 | UI 多窗口 3 | **保留核心**：插件无法自己 spawn 界面进程，迁走只是把 HTTPS 面换宿主 |

**本次决定：43 → 35。** 删除 C 类 7 条 + B 类里的 `POST /api/settings/data-collection`
（代码注释已写「M7 移除」）。路由基线同步：

```
coreOwned 43 → 35    delegated 55 不变    contract 98 → 90    kept 75 → 70
```

`kept` 是**路径集合**（非方法路由），8 条方法路由对应 5 个路径常量
（`settingsDataCollection` / `logSources` / `logSource` / `storeNamespace` / `storeEntry`）。

- **前置检查（已完成）**：`git log -S` 核验过 UI 侧历史，`/api/store` 与 `/api/logs`
  从未被调用过（唯一出现是 `service_availability.dart` 的注释），因此可直接删除，无需弃用期。
- **保留但可再收窄**：`plugin/builtins/*` 3 条与 `BuiltinPluginCatalog` 同链，等内置目录
  退场时再评估（35 → 32，不在本期目标）。

**核心仍在「认识具体插件」的 5 处偏差**（与 §1.3 冲突，独立 track S9）：

| # | 位置 | 现状 | 应改为 |
| --- | --- | --- | --- |
| 1 | `builtin_plugins.dart` `kDesktopUiPluginId` + `seedDesktopUiPlugin()` | 按 id 播种默认界面 | 按 `runtime: ui` + 同目录 `plugin.json` 通用发现，不认 id |
| 2 | `BuiltinPluginCatalog.specs` | 静态枚举 sample / compact / ssh_executor / self_updater 及二进制名 | 目录改由发布索引提供，核心不再枚举 |
| 3 | `seedDefaultEnabledBuiltins` | 按 id 清单「首次出现即默认开」 | 随 #2 退场（默认值归发布/安装方） |
| 4 | `plugin_bus.dart` `sshExecutorLookup()` | 先 `id != kSshExecutorPluginId` 过滤，再判能力 | 纯能力判定（`ssh-executor`），不认 id |
| 5 | `api_paths.dart` `delegated`（55 条领域路由） | 核心协议包维护具体接口清单 | 重新定性为「UI ↔ 插件契约」，随 T2 由 UI 自持；核心只留平台面 + 信封 |

---

## 3. 目标布局

```
raditree/Tree（桌面仓，只留核心 / loader / 发布工程 / 文档）
├── packages/                      # tree_protocol / tree_core / tree_core_cli / tree_agent(…) 不动
├── tool/
│   ├── package_windows.dart       # 改：--ui-dir，flutter build 在 UI 目录跑
│   ├── package_ui_plugin.dart     # 改：版本与构建目录取 UI
│   ├── build_plugins.dart         # 改：runtime: ui 显式跳过
│   ├── check_plugin_repo_contract.dart  # 不改（零依赖后无例外）
│   ├── dev_run.ps1                # 改：flutter run --project 指向 UI 目录
│   ├── installer/                 # 不改
│   └── tree_launcher/             # 不改
├── assets/
│   ├── bootstrap/index.html       # 核心：引导页种子（留在根）
│   └── icon/app_icon.png          # 无引用历史资源（建议删；要留就留在根）
├── docs/                          # 产品文档与插件化文档（含本文件）
├── pubspec.yaml                   # 改：最小工具清单（name/version/path: tree_protocol）
├── analysis_options.yaml          # 删（随 UI 走）
└── .github/workflows/ci.yml       # 改：app job → 插件仓 UI job

raditree/tree-plugins（插件仓，本地挂在桌面仓 plugins/）
├── README.md                      # 改：补「UI 插件零依赖：自持契约，不 import 核心包」
├── .gitignore                     # 改：/.output/、**/windows/flutter/ephemeral/ 等
├── .github/workflows/ci.yml       # 改：新增 ui job（Flutter SDK）
├── _kit/ · compact/ · … · tree.agent/   # 不动
└── tree.ui.default/               # 新增：原 Flutter 工程整体迁入
    ├── plugin.json                # 新增（源与真相：id/version/runtime:ui/command/files）
    ├── pubspec.yaml               # 新增（零 path 依赖：契约自持）
    ├── analysis_options.yaml      # 新增
    ├── lib/                       # 114 文件原样
    ├── test/                      # 100 文件原样
    ├── windows/                   # 18 文件原样（BINARY_NAME 仍为 Tree → 打包时改名）
    └── assets/tray_icon.ico       # 1 文件
```

**为什么目录用 `tree.ui.default`**：`plugins/tree.agent/` 已是「目录名 = 插件 id（含点）」的
先例；`plugin_repo_contract_test` 会断言 id 等于目录名，用点号才与 `plugin.json` 的 id 一致。

---

## 4. 方案决策（每条都给了推荐，下期按推荐执行即可）

### D1 仓归属：进 `tree-plugins`，不进桌面仓
- **推荐**：UI 源码进插件仓 `tree.ui.default/`；桌面仓 `.gitignore` 的 `plugins` 不动。
- 备选：桌面仓新建 `ui/` 目录（不是 `plugins/`）——与用户「完全迁移到 plugins/」的指令不符。
- 影响：桌面仓 PR 不再包含界面代码；界面改动的评审发生在插件仓。

### D2 零依赖：UI 自持契约，不共享 `tree_protocol`
- **决定（2026-11-08）**：UI 插件对桌面仓**零源码/构建依赖**。`plugins/tree.ui.default/`
  新增手写 `lib/io/protocol_contract.dart`（UI 用到的路径与帧常量，UI 自己拥有），
  `pubspec.yaml` 里**没有** `tree_protocol` path 依赖；也不做「从核心生成 + diff 门禁」。
- 契约面实测（本次盘点）：
  - `ApiPaths` 25 条常量（14 条平台面 + 11 条插件面）；
  - 分片三件套 3 个常量 + 3 个类型名、`WsStreamSeq`、`Terminal*` 三组、`Station*` 四个模型；
  - 另约 42 个路径字面量（插件面为主）；领域帧名本来就是字面量（`msg_chunk` / `ui.hello`…）。
  - 合计需自持约 600 行、6 个自包含片段（都只依赖 `dart:`）。
- 一致性不靠 diff，靠两件事：
  1. **核心面对外冻结**：UI 用到的平台面按「只增不改」管理；破坏性变更走新路径/新帧名，
     并在 `/api/meta` 增 `ui_contract` 版本（S8）；
  2. **黑盒一致性套件**：真核心 + 真界面，覆盖流式、工具卡、终端、站点重连、插件面板五条链路。
- 收益：插件仓 `flutter pub get / analyze / test` **不需要桌面仓在上一级**；`check_plugin_repo_contract`
  无需任何白名单；插件仓 CI 的 UI job 可不检出桌面仓。
- 代价（必须接受）：协议变更要改两处；验证强度从编译期降为黑盒测试；核心不能随手改名。
  因此 S8 的黑盒套件是这条决策的**成对前提**，不允许只做零依赖不做套件。

### D3 版本口径：UI 版本取自 UI 的 `pubspec.yaml`（已定 2026-11-08）
- **推荐**：
  - UI 插件版本 = `plugins/tree.ui.default/pubspec.yaml` 的 `version`（`app_version.dart`
    常量由随 UI 搬家的 `version_info_test.dart` 钉住）；
  - 核心 / loader / 安装包版本 = 桌面仓根 `pubspec.yaml`（保留，见下）；
  - 打包写 `plugin.json` 与发布索引用 **UI 版本**；两者允许不同，兼容性由
    `requires.api` 约束（`ui-pluginization_detailed.md` §6 已定）。
- 根 `pubspec.yaml` 的处置：保留为**最小工具清单**（`name`、`version`、`environment`、
  `tree_protocol` path 依赖——`tool/package_windows.dart` 实测唯一 import 的包），
  删掉 Flutter 依赖与 `flutter:` 段。**不要删根 pubspec**：`dart run tool/*.dart`
  需要包解析上下文，`build_plugins.dart` 也靠它读产品版本。
- 备选（不推荐）：两仓版本强制相等——UI 与核心的发布节奏不同，强绑会逼着「没改核心也升核心版本」。

### D4 平台目录：只搬 `windows/`，其余删除（已定 2026-11-08）
- **推荐**：`android/ ios/ linux/ macos/ web/` 直接删除（git 历史保留）。
- 理由：产品只发 Windows（CI、安装器、tree_launcher、RedirectionGuard 全部只覆盖 Windows）；
  留着它们只会让「该在哪个目录跑 flutter build」多出五种错误答案。
- 影响：未来要发其它平台需重新 `flutter create --platforms=…`。

### D5 `assets/` 按归属拆三份
- **推荐**：`tray_icon.ico` → UI 仓；`icon/app_icon.png`（无代码引用）建议删除；
  `bootstrap/index.html` → 留桌面仓。
- 理由：`bootstrap` 被**核心**消费（运行时按 exe 同级 `assets/bootstrap/` 探测），
  搬走会让新装机的引导页退化成内置最小页；`tray_icon.ico` 是 `tray_manager` 的运行时资产
  （`lib/io/tray_service.dart` + pubspec `assets:`），必须跟 UI 走。

### D6 构建入口分工：`build_plugins.dart` 显式跳过 UI
- **推荐**：`build_plugins.dart` 读到 `runtime: ui` 时打印
  `[skip] tree.ui.default 是 UI 插件，由 tool/package_ui_plugin.dart 产出（见文档）` 并跳过；
  `package_ui_plugin.dart` 成为 UI 唯一构建入口。
- 理由：`plugins/README.md` 明确「静默跳过会让面板只剩没得上」，所以必须是**显式**跳过；
  同时避免有人拿 `dart compile exe` 去编一个 Flutter 工程。

### D7 跨仓门禁：路径常量 + 缺目录即红
- **推荐**：在 `packages/tree_protocol/lib` 暴露一个测试用不了的东西不合适——改为在两条
  测试里各写一个 `_uiSourceRoot()`（`Directory('../../plugins/tree.ui.default/lib')`），
  并加 `expect(dir.existsSync(), isTrue, reason: 'UI 源码目录不存在：迁移没搬完或路径漂了')`。
- 理由：当前 `protocol_completeness_test` 对缺失 `lib/` 是 `continue`，迁移后会**静默变绿**，
  这是门禁类代码最不能接受的失败方式。
- **2026-11-13 修订（用户反馈）**：远端/单仓环境没有插件仓时，"缺目录即红"会让整包测试
  长期红且难归因。口径改为：**缺目录 ⇒ 该条跨仓门禁可见跳过（skip）**；同时新增
  `TREE_REQUIRE_PLUGIN_REPO=1` 强制开关，桌面仓 CI 已设（它本来就会检出 `plugins/`），
  保证"有仓的环境必须真扫"。涉及 5 个测试文件，见 `docs/work-log.md` 2026-11-13 行。

### D8 CI：桌面仓 `app` job → 插件仓 `ui` job
- **推荐**：
  - 桌面仓 `ci.yml`：`app` job 改为检出插件仓（`path: plugins`）+ `working-directory:
    plugins/tree.ui.default`，命令不变（`flutter pub get / analyze lib / test`）；
  - 插件仓 `ci.yml`：新增 `ui` job（同 SDK、同 working-directory），让插件仓自己的 PR
    也能跑界面门禁；`contract` job **不需要改**（零依赖后没有例外）。
- 影响：桌面仓 PR 的界面门禁依赖插件仓 `master` 的当前版本（与现有 protocol/core job
  检出 `tree-plugins` 的做法一致）。

### D9 开发回路：`dev_run.ps1` 留在桌面仓，参数指向 UI 目录
- **推荐**：脚本仍住 `tool/`（它要做的是「先起核心、再跑 UI」，天然属于桌面仓），把
  `flutter run` 的 cwd 改成 `plugins/tree.ui.default`。
- 理由：开发者的核心里程碑都在桌面仓；把脚本搬进插件仓反而要反过来找核心入口。

### D10 核心面收窄：43 → 35（2026-11-08 决定）
- **删除**：`store/*` 4 条、`logs/*` 3 条、`settings/data-collection` 1 条（判据与清单见 §2.5）。
- 理由：界面与插件仓源码**零调用**；`data-collection` 的代码注释本就写着「M7 移除」。
- 基线：`coreOwned 43 → 35`、`contract 98 → 90`、`kept 75 → 70`；同步
  `protocol_completeness_test`、`docs/pluginization/ui-pluginization.md` §4.1/§4.5、README/CONTRIBUTING。
- **不做**：不删 C 类之外的任何一条；`plugin/builtins/*` 留到内置目录退场（35 → 32 是后续可选目标）。

### D11 核心去插件化：5 处偏差独立成 track（S9）
- **推荐**：把 §2.5 的 5 处「核心认识具体插件」单列，不塞进搬仓分片。
- 理由：搬仓是**可回滚的位置调整**；去插件化是**行为改造**，混在一起会让回滚点失效。
- 优先级：`seedDesktopUiPlugin` 通用化（#1）与 `sshExecutorLookup` 纯能力化（#4）先做；
  内置目录退场（#2/#3）与 `delegated` 迁出（#5）随后。

### D12 零依赖的成对前提：契约冻结 + 黑盒一致性（S8，已定 2026-11-08）
- **推荐**：`/api/meta` 增 `ui_contract` 版本；新增真核心 + 真界面的黑盒套件，覆盖
  流式、工具卡、终端、站点重连、插件面板五条链路。
- 理由：D2 去掉了编译期一致性，必须用运行时/黑盒补回；**只做零依赖不做套件不允许合入**。
- 影响：S8 是 S2（插件仓落源）的**前置**——顺序调整为 S1 → S8 → S2 → S3。

---

## 5. 改造清单（逐文件，可直接照做）

### 5.1 搬家清单（两仓两提交，不是 `git mv` 跨仓）

> 插件仓是独立仓库，**无法用一次 `git mv` 跨仓**。正确顺序：先在插件仓落源并合入
> （S2），再在桌面仓删源（S3）。S2 合入但 S3 未做时，两处各有一份源码——这段时间
> **只允许改插件仓那份**，桌面仓那份冻结（在 S2 的 PR 描述里写明）。

插件仓新增（源 = 桌面仓对应路径）：

```
lib/            → plugins/tree.ui.default/lib/
test/           → plugins/tree.ui.default/test/
windows/        → plugins/tree.ui.default/windows/
assets/tray_icon.ico → plugins/tree.ui.default/assets/tray_icon.ico
analysis_options.yaml → plugins/tree.ui.default/analysis_options.yaml
pubspec.yaml    → plugins/tree.ui.default/pubspec.yaml（改：零 path 依赖，见 5.2）
```

新增手写文件：

- `plugins/tree.ui.default/plugin.json`（内容 = 现在 `package_windows.dart` `_writeUiManifest`
  的字段 + `files: ["**"]`，与 `package_ui_plugin.dart` 的 `_manifest` 对齐；版本由打包脚本按 UI pubspec 重写）；
- `plugins/tree.ui.default/lib/io/protocol_contract.dart`（**UI 自持契约**：25 条路径 +
  分片/终端/站点/序号常量与模型，来源按 22–24 行的盘点逐段拷入；文件头写
  `UI 自有契约，不从核心生成`）。

### 5.2 插件仓侧改动

| 文件 | 改动 |
| --- | --- |
| `plugins/tree.ui.default/pubspec.yaml` | `name: tree_ui_default`（或 `tree_ui`）；`version: 1.0.5+1` 起步；**无任何 path 依赖**（不写 `tree_protocol`）；其余 pub 依赖原样 |
| `plugins/tree.ui.default/lib/io/protocol_contract.dart` | 手写自持契约（D2）；只依赖 `dart:`；内容 = UI 实际用到的路径 / 帧 / 模型子集 |
| `plugins/tree.ui.default/plugin.json` | `id/name/version` + `runtime: ui` + `command: tree_ui.exe` + `files: ["**"]` + `requires.api` + 可选依赖 `tree.agent` |
| `plugins/tree.ui.default/.gitignore` | 新增：`.output/`、`windows/flutter/ephemeral/`、`*.pdb`（沿用桌面仓现有规则） |
| `plugins/.gitignore` | 已有 `.dart_tool/`、`build/`；补 `**/windows/flutter/ephemeral/` |
| `plugins/README.md` | 目录形状补 `tree.ui.default/`；写明「UI 插件零依赖：自持契约，不 import 核心包」，四条约定**无需例外** |
| `plugins/.github/workflows/ci.yml` | 新增 `ui` job（Flutter 3.47.5、`working-directory: tree.ui.default`、`flutter analyze lib` + `flutter test`）；**不检出桌面仓** |

### 5.3 桌面仓侧改动

| 文件 | 改动 |
| --- | --- |
| `tool/package_windows.dart` | 新增 `--ui-dir`（默认 `plugins/tree.ui.default`）；`flutter build`、`_binaryName`、UI 版本、`_writeUiManifest` 全部改按 UI 目录；`_copyBootstrapAsset` 与 docs 拷贝仍按桌面仓根；`--skip-build` 的默认 Release 目录改成 `<ui-dir>/build/windows/x64/runner/Release` |
| `tool/package_ui_plugin.dart` | 版本取 `<ui-dir>/pubspec.yaml`；`--build` 在 UI 目录跑；默认 Release 目录同上；zip 与索引输出仍落桌面仓 `build/`、`dist/` |
| `tool/build_plugins.dart` | `runtime: ui` 显式跳过（D6）；其余插件解析不变 |
| `tool/check_plugin_repo_contract.dart` | **不改**（零依赖后无需白名单）；`--selftest` 可补一条「UI 目录不出现核心包」的回归样例 |
| `packages/tree_protocol/test/plugin_repo_contract_test.dart` | 新增 UI `plugin.json` 形状校验（复用同一套字段断言） |
| `packages/tree_protocol/test/protocol_completeness_test.dart` | 扫描根改 `_uiSourceRoot()` + 缺目录 fail；`registered` 键改新相对路径 |
| `packages/tree_core/test/heartbeat_settings_test.dart` | 同一条 `_uiSourceRoot()` |
| `packages/tree_core/test/legacy_plugin_ui_protocol_test.dart` | 扫描根追加 UI 目录（或依赖仓库根递归自然覆盖，需验证跳过 `build/`） |
| `packages/tree_protocol/lib/src/api_paths.dart` | **删 8 条**（`store*` 4、`logs*` 3、`settingsDataCollection` 1）与对应路径常量；`coreOwned` 43 → 35、`contract` 98 → 90、`kept` 75 → 70（D10） |
| `packages/tree_core/lib/src/server/core_server.dart` | 删上述 8 条路由注册与 handler；`docs/pluginization/ui-pluginization.md` §4.1/§4.5 同步 |
| `packages/tree_protocol/test/protocol_completeness_test.dart` 基线 | `coreOwned 35 / delegated 55 / contract 90 / kept 70` |
| `tool/dev_run.ps1` | `flutter run` 加 `--project`/改 cwd 到 UI 目录 |
| `.github/workflows/ci.yml` | `app` job 改检出插件仓 + `working-directory`（D8） |
| `pubspec.yaml` | 最小工具清单（D3） |
| `analysis_options.yaml` | 删除（随 UI 走） |
| 删除 | `lib/`、`test/`、`windows/`、`android/`、`ios/`、`linux/`、`macos/`、`web/`、`assets/tray_icon.ico` |
| 保留不动 | `assets/bootstrap/`、`tool/installer/`、`tool/tree_launcher/`、`packages/`、`docs/` |
| 待定 | `assets/icon/app_icon.png`（无引用；建议一并删除） |

### 5.4 文档同步（不改会被下一个人按旧路径操作）

| 文档 | 改动 |
| --- | --- |
| `README.md` | 目录结构、开发命令（`flutter` 命令加 `cd plugins/tree.ui.default`） |
| `CONTRIBUTING.md` | 门禁顺序与工作目录；「UI 改动在插件仓」 |
| `docs/development.md` | 构建链一节（`package_windows` 现在从哪读 UI） |
| `docs/pluginization/ui-pluginization_detailed.md` | §4「代码改造清单（本仓）」改为「插件仓」；§1 交付物表 |
| `docs/plugin-platform.md` | 仓布局与 CI 口径 |
| `CHANGELOG.md` | 迁移条目（用户可见：安装位置与升级路径不变） |
| 本文件 | S6 完成后把「状态」改为已实施，并补实测结论 |

### 5.5 明确**不改**的东西（避免下期顺手扩大范围）

- 核心的 `runtime: ui` 分类、`UiHost`；`seedDesktopUiPlugin` 的**通用化**属 S9，本 track 不动；
- `plugins.yaml` 字段与 `plugin.json` 身份机制；
- 发布索引 `schema: 1` 与 `archive` 形态；
- 安装器 `.iss`、`tree_launcher`、`UiHost` 的启动参数；
- 用户数据根布局（`~/.tree`）与升级路径；
- 平台点位的去留（A/B/D 类），本 track 只删 C 类 8 条。

---

## 6. 分片计划（每片一提交、一份门禁）

门禁顺序沿用项目现行口径：`dart analyze`（无新增）→ 受影响包全量 `dart test` →
`tree_protocol` 契约门禁 → 涉及界面时 `flutter analyze lib` + `flutter test`。

| 片 | 内容 | 门禁 | 回滚点 |
| --- | --- | --- | --- |
| **S1 门禁先行（不搬文件）** | D7 路径常量与「缺目录即红」+ 三条跨仓测试改造；此时 UI 目录不存在 ⇒ 测试**应当红**，用 `--skip` 注掉或临时以旧路径兜底并在 S3 切回 | 协议/核心包测试 | 单提交 revert，无源码移动 |
| **S2 插件仓落源** | 复制 5.1 全部文件 + 新增 `plugin.json`/`pubspec`（零依赖）/`protocol_contract.dart`/`analysis_options` + `.gitignore` + README + 插件仓 `ui` job（不检出桌面仓）；桌面仓此片**不动** | 插件仓 CI：contract 全绿、`ui` job 全绿 | 插件仓 revert（桌面仓未动，用户无感） |
| **S3 桌面仓删源 + 构建改道** | 删除根 Flutter 工程与无用平台目录；`package_windows`/`package_ui_plugin`/`build_plugins`/`dev_run.ps1` 改造；根 pubspec 最小化；S1 的临时兜底切到新路径 | `dart run tool/package_windows.dart --skip-build` 出包；`package_ui_plugin` 产 zip+索引；两包测试 | 桌面仓 revert + 插件仓保留（源码还在插件仓，可再迁） |
| **S4 CI 与发布链收口** | 桌面仓 `app` job 改检出插件仓；两仓 CI 全绿；用发布源实装一次 UI 插件 | CI + 手工安装（面板「安装/更新」） | 改回 `app` job（源码已在插件仓，回滚只影响门禁） |
| **S5 文档与开发回路** | 5.4 全部文档 + `dev_run.ps1` 实测 | `flutter run` 附着核心一遍；文档链接检查 | 文档 revert |
| **S6 清理与真机验收** | 删除桌面仓残留（空目录、旧注释、`analysis_options`）；全量门禁；真机安装 + 卸载 + 升级 | 见第 7 节 | revert 各片 |
| **S7 核心面收窄 43 → 35（D10）** | 删 `store/*` 4、`logs/*` 3、`settings/data-collection` 1；protocol 常量与 core router 同步；基线改 35/55/90/70 | `dart test packages/tree_protocol`、`dart test packages/tree_core`、`dart analyze` | 单提交 revert（端点恢复即可） |
| **S8 契约冻结 + 黑盒一致性（D2/D12）** | `/api/meta` 增 `ui_contract`；新增真核心 + 真界面套件（流式/工具卡/终端/站点重连/插件面板）；**S2 的前置** | E2E 五条链路全绿；`/api/meta` 字段断言 | 单提交 revert（去掉版本字段与套件） |
| **S9 核心去插件化（D11，独立 track）** | §2.5 五处偏差：默认界面通用发现、内置目录退场、seed 默认值、ssh 能力判定、`delegated` 迁出 | 各片独立门禁；不影响 S1–S8 回滚 | 逐项 revert |

依赖关系：**S1 → S8 → S2 → S3** 必须顺序执行（S8 是零依赖的成对前提，不能先搬后补）；
S4/S5 可在 S3 后并行；S6 最后；S7/S9 与移仓无强依赖，可并行推进，但 S9 最后做（行为改造）。

---

## 7. 验收清单（命令级）

**桌面仓**

```powershell
flutter analyze                      # 迁移后根目录已无 Flutter 工程 ⇒ 该命令应不可用/不适用
dart analyze                         # 期望：仅剩既有 info（tunnel_protocol / thinking_window）
dart test packages/tree_protocol     # 68 条全绿；契约基线 35 / 55 / 90 / 70
dart test packages/tree_core         # 675 条全绿（含两条跨仓扫描）
dart test packages/tree_agent
dart test packages/tree_local_exec
dart test packages/tree_tunnel_protocol
dart test packages/tree_core_cli
dart test tool/tree_launcher
dart run tool/check_plugin_repo_contract.dart --selftest
dart run tool/check_plugin_repo_contract.dart --plugin-root plugins   # 零依赖：无任何白名单
dart run tool/package_windows.dart --skip-build                       # 引导壳 + 核心 + 资产落位
dart run tool/package_ui_plugin.dart --build                          # zip + 索引
```

**S7 额外核验（核心面 43 → 35）**

```powershell
# 1. 四条已删端点应当 404（而不是 401/500）
curl.exe -s -o NUL -w "%{http_code}`n" -H "Authorization: Bearer $env:TREE_TOKEN" http://127.0.0.1:$env:TREE_PORT/api/store/x
# 2. 核心 router 键集 == coreOwned（35），由 protocol_completeness_test 钉住
# 3. 已发布界面的关键链路不受影响：状态栏、主题、插件面板、文件面板
```

**插件仓（cwd = `plugins`）**

```powershell
cd plugins/tree.ui.default
flutter pub get && flutter analyze lib && flutter test
```

**反向证明（防「搬了但没生效」）**

1. 桌面仓根**不存在** `lib/main.dart` 时 `package_windows.dart` 仍能出包（说明构建链真的改道了）；
2. 插件仓 `tree.ui.default/lib/io/websocket_service.dart` 仍被两条跨仓测试读到
   （说明门禁没有静默降级）；
3. 删掉 `plugins/tree.ui.default` 后，`protocol_completeness_test` **必须红**
   （缺目录即失败，而不是跳过）。

**真机（S6）**

1. 全新安装 → 双击 `Tree.exe` → 出界面；`/api/meta.ui` 出现 `tree.ui.default`；
2. 面板「从发布仓库安装」同一版本 → 覆盖安装成功、界面热重启后仍能连上；
3. 卸载 UI 插件 → 文件清空、条目保留 `enabled:false`、引导页可用；
4. 升级安装包（不含 UI 源变化）→ 用户数据与会话不丢。

---

## 8. 风险与回滚

| 风险 | 触发方式 | 缓解 / 回滚 |
| --- | --- | --- |
| **两仓不同步**（S2 后、S3 前） | 有人继续在桌面仓改 UI | S2 PR 写明「桌面仓 UI 源冻结」；S3 紧接同一天完成 |
| 插件仓单独 clone 编不出 UI | 第三方 checkout | 与 `ssh_executor` 同源代价；README 明写「需桌面仓在上一级」 |
| 插件仓 CI 需要 Flutter | 新增 `ui` job | SDK 固定 3.47.5（与桌面仓一致）；`windows-latest` 预装 Flutter 支持 |
| 跨仓路径随仓名变化 | 目录改名 | 两条测试集中到 `_uiSourceRoot()`，改一处即可 |
| 根 `pubspec.yaml` 最小化后工具跑不起来 | `dart run tool/…` 缺包解析 | 保留 `tree_protocol` path 依赖；S3 门禁里显式跑两个打包脚本 |
| Flutter 产物路径更深 | RedirectionGuard #16 | 自愈逻辑与目录深度无关；S6 在真机验证一次 `flutter build` |
| 升级覆盖安装 | 安装器删旧目录策略 | 安装器只吃 Release 目录，无需改；S6 做一次覆盖安装 |
| 版本口径混乱 | 两处版本不一致 | `plugin.json` / 索引一律取 UI 版本；`version_info_test` 随 UI 搬家后仍钉常量 |

**总回滚**：S3 的 revert 即可把源码搬回桌面仓根（插件仓副本可留可删），用户侧无感知；
S2/S4/S5/S6 各自 revert 不影响运行期。

---

## 9. 下期开工顺序（照抄即可）

1. **先写 S1**（路径常量与「缺目录即红」），提交后确认：删掉 UI 目录时两条测试**会红**；
2. **写 S8**（`ui_contract` + 黑盒套件）：这是零依赖的成对前提，必须在搬源之前合入；
3. **在插件仓开 PR**：按 5.1 复制、5.2 改文件（**pubspec 零 path 依赖** + 自持契约）；CI 跑
   `contract` + 新增 `ui` job（**不检出桌面仓**）；
4. 合入插件仓后**当天开 S3 PR**：删除根 Flutter 工程、改四个工具脚本、最小化根 pubspec；
5. 本地跑第 7 节「桌面仓」全部命令 + 「反向证明」三条；
6. 开 S4：CI 改道 + 用发布源实装一次 UI；
7. 开 S5：文档与 `dev_run.ps1`；
8. 开 S7：核心面 43 → 35（可与 S4/S5 并行）；
9. 开 S6：清理 + 真机四项验收 + 回写本文件状态；
10. 最后开 S9：核心去插件化 5 处偏差（行为改造，单独 track）。

---

## 10. 已拍板（2026-11-08 全部结项，无遗留问题）

| # | 问题 | 结论 |
| --- | --- | --- |
| Q1 | 是否接受「`runtime: ui` 可依赖 `tree_protocol`」 | **零依赖**（D2）：UI 自持契约，不依赖协议包 |
| Q2 | `android/ ios/ linux/ macos/ web/` 是否删除 | **全部删除**（D4）：只保留 `windows/` |
| Q3 | UI 版本是否允许独立于核心版本 | **允许**（D3）：UI 取自身 `pubspec.yaml`，`requires.api` 兜底 |
| Q4 | 目录名 | **`tree.ui.default`**（与插件 id、`tree.agent` 先例一致） |
| Q5 | 8 条端点直接删还是先弃用 | **直接删**（D10）：已核验 UI 历史从未调用 |
| Q6 | S8 是否为 S2 前置 | **是**（D12）：先冻结契约 + 建黑盒套件，再搬源 |

下期直接从第 9 节第 1 步开始，无需再确认任何口径。
