# UI 源码完全迁入 `plugins/`：语义对齐 · 侦察 · 实施方案

> 状态：方案稿（2026-11-08）。**本期只做语义对齐、侦察与落档，不改任何代码**。
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

---

## 1. 语义对齐（先钉钉子，后面所有决定都从这里推）

### 1.1 「迁移」一共有四层，只有第四层没做

| 层 | 内容 | 现状 | 出处 |
| --- | --- | --- | --- |
| ① 运行期形态 | 界面由核心拉起、附着 `TREE_CORE_URL/TOKEN`、发 `ui.hello` | ✅ 已完成 | `lib/main.dart`、`lib/io/ui_identity.dart` |
| ② 产物发布 | `tree-ui-default-<ver>.zip` 作为 release 资产，索引里用 `archive` | ✅ 已完成 | `tool/package_ui_plugin.dart` |
| ③ 装机与升级 | 面板从发布源安装/更新、卸载保留 `enabled:false` | ✅ 已完成 | `plugin_downloader.dart`、`core_server.dart` |
| ④ **源码位置** | Flutter 工程住在哪个仓、哪个目录；谁跑 `flutter build` | ❌ **本次要迁** | 本文件 |

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

### 1.3 三条不可让步的语义

1. **身份只来自 exe 同级 `plugin.json`**（`lib/io/ui_identity.dart`）。源码搬家不许改成
   「编译期常量注册」，也不许把清单写进 Dart 代码——否则装成插件后 `ui.hello` 报的 id
   与 `plugins.yaml` 对不上，核心会整条关闭连接。
2. **UI 只附着、不拉核心**（U1 已落地）。`TREE_CORE_URL` / `TREE_CORE_TOKEN` /
   `TREE_DATA_ROOT` / `TREE_UI_WINDOW_ID` 由核心注入，UI 不自行 spawn。
3. **「插件仓必须脱离桌面仓可编译」这条纪律，UI 是唯一例外**：
   - 现状纪律（`plugins/README.md` 四条约定 + `tool/check_plugin_repo_contract.dart`）：
     插件不得 `import package:tree_core|tree_protocol`，也不得在 pubspec 里依赖它们；
   - 实测：UI 的 113 个 `lib/` 文件 + 100 个 `test/` 文件里，**唯一**的 `package:tree_*`
     依赖就是 `tree_protocol`（REST 路径 / WS 帧类型 / 握手信封）；
   - 已有先例：`ssh_executor` / `self_updater` 依赖桌面仓的 `packages/tree_tunnel_protocol`
     （README 明写「本仓必须 clone 在桌面仓的 `plugins/` 下才能编出这两条」）；
   - 因此建议把例外**写进门禁**，而不是靠人记：`runtime: ui` 的插件允许依赖
     `tree_protocol`，`tree_core` 仍全面禁止（决策 D2）。
   - 代价必须说清：单独 clone 插件仓的人编不出 UI；这与 ssh_executor 的代价同源，接受。

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
| 2 | `check_plugin_repo_contract.dart` | 禁 `tree_core` + `tree_protocol`（import 与 pubspec 键） | 加 `runtime: ui` 白名单（只放 `tree_protocol`），并加自检用例 |
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

---

## 3. 目标布局

```
raditree/Tree（桌面仓，只留核心 / loader / 发布工程 / 文档）
├── packages/                      # tree_protocol / tree_core / tree_core_cli / tree_agent(…) 不动
├── tool/
│   ├── package_windows.dart       # 改：--ui-dir，flutter build 在 UI 目录跑
│   ├── package_ui_plugin.dart     # 改：版本与构建目录取 UI
│   ├── build_plugins.dart         # 改：runtime: ui 显式跳过
│   ├── check_plugin_repo_contract.dart  # 改：ui 白名单
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
├── README.md                      # 改：新增「UI 插件是唯一允许依赖 tree_protocol 的例外」
├── .gitignore                     # 改：/.output/、**/windows/flutter/ephemeral/ 等
├── .github/workflows/ci.yml       # 改：新增 ui job（Flutter SDK）
├── _kit/ · compact/ · … · tree.agent/   # 不动
└── tree.ui.default/               # 新增：原 Flutter 工程整体迁入
    ├── plugin.json                # 新增（源与真相：id/version/runtime:ui/command/files）
    ├── pubspec.yaml               # 新增（tree_protocol: path: ../../packages/tree_protocol）
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

### D2 协议依赖例外：允许 `runtime: ui` 依赖 `tree_protocol`
- **推荐**：门禁从「禁 `tree_core` + `tree_protocol`」改为「禁 `tree_core`；`tree_protocol`
  仅当该目录 `plugin.json` 的 `runtime == ui` 时放行」。
- 理由：UI 与核心共用 REST 路径 / WS 帧常量是**设计上的单一真相源**（协议包就是为跨端共享
  而存在）；抄一份常量表会让「核心改了路径、界面还在打旧路径」这类故障重新出现。
- 备选（不推荐）：把 UI 用到的常量抽成新包 `tree_ui_protocol`——两份真相源，长期必漂。
- 影响：插件仓单独 clone 编不出 UI（已在 `plugins/README.md` 写明同类代价）。

### D3 版本口径：UI 版本取自 UI 的 `pubspec.yaml`
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

### D4 平台目录：只搬 `windows/`，其余删除
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

### D8 CI：桌面仓 `app` job → 插件仓 `ui` job
- **推荐**：
  - 桌面仓 `ci.yml`：`app` job 改为检出插件仓（`path: plugins`）+ `working-directory:
    plugins/tree.ui.default`，命令不变（`flutter pub get / analyze lib / test`）；
  - 插件仓 `ci.yml`：新增 `ui` job（同 SDK、同 working-directory），让插件仓自己的 PR
    也能跑界面门禁；`contract` job 的白名单改动自动生效。
- 影响：桌面仓 PR 的界面门禁依赖插件仓 `master` 的当前版本（与现有 protocol/core job
  检出 `tree-plugins` 的做法一致）。

### D9 开发回路：`dev_run.ps1` 留在桌面仓，参数指向 UI 目录
- **推荐**：脚本仍住 `tool/`（它要做的是「先起核心、再跑 UI」，天然属于桌面仓），把
  `flutter run` 的 cwd 改成 `plugins/tree.ui.default`。
- 理由：开发者的核心里程碑都在桌面仓；把脚本搬进插件仓反而要反过来找核心入口。

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
pubspec.yaml    → plugins/tree.ui.default/pubspec.yaml（改：路径依赖 + 去 flutter: 段调整见 5.2）
```

新增手写文件：`plugins/tree.ui.default/plugin.json`（内容 = 现在 `package_windows.dart`
`_writeUiManifest` 的字段 + `files: ["**"]`，与 `package_ui_plugin.dart` 的 `_manifest`
对齐；版本由打包脚本按 UI pubspec 重写）。

### 5.2 插件仓侧改动

| 文件 | 改动 |
| --- | --- |
| `plugins/tree.ui.default/pubspec.yaml` | `name: tree_ui_default`（或 `tree_ui`）；`version: 1.0.5+1` 起步；`tree_protocol: path: ../../packages/tree_protocol`；其余依赖原样 |
| `plugins/tree.ui.default/plugin.json` | `id/name/version` + `runtime: ui` + `command: tree_ui.exe` + `files: ["**"]` + `requires.api` + 可选依赖 `tree.agent` |
| `plugins/tree.ui.default/.gitignore` | 新增：`.output/`、`windows/flutter/ephemeral/`、`*.pdb`（沿用桌面仓现有规则） |
| `plugins/.gitignore` | 已有 `.dart_tool/`、`build/`；补 `**/windows/flutter/ephemeral/` |
| `plugins/README.md` | 四条约定处补「UI 例外」：`runtime: ui` 可依赖 `tree_protocol`，不可依赖 `tree_core`；目录形状一节补 `tree.ui.default/` |
| `plugins/.github/workflows/ci.yml` | 新增 `ui` job（Flutter 3.47.5、`working-directory: tree.ui.default`、`flutter analyze lib` + `flutter test`） |

### 5.3 桌面仓侧改动

| 文件 | 改动 |
| --- | --- |
| `tool/package_windows.dart` | 新增 `--ui-dir`（默认 `plugins/tree.ui.default`）；`flutter build`、`_binaryName`、UI 版本、`_writeUiManifest` 全部改按 UI 目录；`_copyBootstrapAsset` 与 docs 拷贝仍按桌面仓根；`--skip-build` 的默认 Release 目录改成 `<ui-dir>/build/windows/x64/runner/Release` |
| `tool/package_ui_plugin.dart` | 版本取 `<ui-dir>/pubspec.yaml`；`--build` 在 UI 目录跑；默认 Release 目录同上；zip 与索引输出仍落桌面仓 `build/`、`dist/` |
| `tool/build_plugins.dart` | `runtime: ui` 显式跳过（D6）；其余插件解析不变 |
| `tool/check_plugin_repo_contract.dart` | 白名单（D2）+ `--selftest` 增加「UI 目录依赖 tree_protocol 应放行、依赖 tree_core 仍红」两条 |
| `packages/tree_protocol/test/plugin_repo_contract_test.dart` | 新增 UI `plugin.json` 形状校验（复用同一套字段断言） |
| `packages/tree_protocol/test/protocol_completeness_test.dart` | 扫描根改 `_uiSourceRoot()` + 缺目录 fail；`registered` 键改新相对路径 |
| `packages/tree_core/test/heartbeat_settings_test.dart` | 同一条 `_uiSourceRoot()` |
| `packages/tree_core/test/legacy_plugin_ui_protocol_test.dart` | 扫描根追加 UI 目录（或依赖仓库根递归自然覆盖，需验证跳过 `build/`） |
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
| `docs/handover.md` | 仓布局与 CI 口径 |
| `CHANGELOG.md` | 迁移条目（用户可见：安装位置与升级路径不变） |
| 本文件 | S6 完成后把「状态」改为已实施，并补实测结论 |

### 5.5 明确**不改**的东西（避免下期顺手扩大范围）

- 核心的 `runtime: ui` 分类、`UiHost`、`seedDesktopUiPlugin`；
- `plugins.yaml` 字段与 `plugin.json` 身份机制；
- 发布索引 `schema: 1` 与 `archive` 形态；
- 安装器 `.iss`、`tree_launcher`、`UiHost` 的启动参数；
- 用户数据根布局（`~/.tree`）与升级路径。

---

## 6. 分片计划（每片一提交、一份门禁）

门禁顺序沿用项目现行口径：`dart analyze`（无新增）→ 受影响包全量 `dart test` →
`tree_protocol` 契约门禁 → 涉及界面时 `flutter analyze lib` + `flutter test`。

| 片 | 内容 | 门禁 | 回滚点 |
| --- | --- | --- | --- |
| **S1 门禁先行（不搬文件）** | D2 白名单 + D7 路径常量与「缺目录即红」+ 三条跨仓测试改造；此时 UI 目录不存在 ⇒ 测试**应当红**，用 `--skip` 注掉或临时以旧路径兜底并在 S3 切回 | 协议/核心包测试 | 单提交 revert，无源码移动 |
| **S2 插件仓落源** | 复制 5.1 全部文件 + 新增 `plugin.json`/`pubspec`/`analysis_options` + `.gitignore` + README + 插件仓 `ui` job；桌面仓此片**不动** | 插件仓 CI：contract 全绿、`ui` job 全绿 | 插件仓 revert（桌面仓未动，用户无感） |
| **S3 桌面仓删源 + 构建改道** | 删除根 Flutter 工程与无用平台目录；`package_windows`/`package_ui_plugin`/`build_plugins`/`dev_run.ps1` 改造；根 pubspec 最小化；S1 的临时兜底切到新路径 | `dart run tool/package_windows.dart --skip-build` 出包；`package_ui_plugin` 产 zip+索引；两包测试 | 桌面仓 revert + 插件仓保留（源码还在插件仓，可再迁） |
| **S4 CI 与发布链收口** | 桌面仓 `app` job 改检出插件仓；两仓 CI 全绿；用发布源实装一次 UI 插件 | CI + 手工安装（面板「安装/更新」） | 改回 `app` job（源码已在插件仓，回滚只影响门禁） |
| **S5 文档与开发回路** | 5.4 全部文档 + `dev_run.ps1` 实测 | `flutter run` 附着核心一遍；文档链接检查 | 文档 revert |
| **S6 清理与真机验收** | 删除桌面仓残留（空目录、旧注释、`analysis_options`）；全量门禁；真机安装 + 卸载 + 升级 | 见第 7 节 | revert 各片 |

依赖关系：S1 → S2 → S3 必须顺序执行；S4/S5 可在 S3 后并行；S6 最后。

---

## 7. 验收清单（命令级）

**桌面仓**

```powershell
flutter analyze                      # 迁移后根目录已无 Flutter 工程 ⇒ 该命令应不可用/不适用
dart analyze                         # 期望：仅剩既有 info（tunnel_protocol / thinking_window）
dart test packages/tree_protocol     # 68 条全绿（含插件仓合同门禁）
dart test packages/tree_core         # 675 条全绿（含两条跨仓扫描）
dart test packages/tree_agent
dart test packages/tree_local_exec
dart test packages/tree_tunnel_protocol
dart test packages/tree_core_cli
dart test tool/tree_launcher
dart run tool/check_plugin_repo_contract.dart --selftest
dart run tool/check_plugin_repo_contract.dart --plugin-root plugins   # UI 例外放行、tree_core 仍红
dart run tool/package_windows.dart --skip-build                       # 引导壳 + 核心 + 资产落位
dart run tool/package_ui_plugin.dart --build                          # zip + 索引
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

1. **先写 S1**（门禁与路径常量），提交后确认：删掉 UI 目录时两条测试**会红**；
2. **在插件仓开 PR**：按 5.1 复制、5.2 改文件；CI 跑 `contract` + 新增 `ui` job；
3. 合入插件仓后**当天开 S3 PR**：删除根 Flutter 工程、改四个工具脚本、最小化根 pubspec；
4. 本地跑第 7 节「桌面仓」全部命令 + 「反向证明」三条；
5. 开 S4：CI 改道 + 用发布源实装一次 UI；
6. 开 S5：文档与 `dev_run.ps1`；
7. 开 S6：清理 + 真机四项验收 + 回写本文件状态。

---

## 10. 待拍板（下期开工前需要一句话确认）

| # | 问题 | 推荐 | 不选的代价 |
| --- | --- | --- | --- |
| Q1 | 是否接受「`runtime: ui` 可依赖 `tree_protocol`」这一门禁例外 | **接受**（D2） | 只能抽新协议包或抄常量表，两条都会产生第二真相源 |
| Q2 | `android/ ios/ linux/ macos/ web/` 是否直接删除 | **删除**（D4） | 保留则「在哪跑 flutter build」有六个候选，迟早有人跑错 |
| Q3 | UI 版本是否允许独立于核心版本 | **允许**（D3） | 强制相等会把「只改界面」变成「核心也跟着升版本」 |
| Q4 | 目录名用 `tree.ui.default`（与 id 一致）还是 `ui_default` | **`tree.ui.default`** | 用别名需在合同门禁里开洞，且与 `tree.agent` 先例不一致 |
