# 首个 UI 插件的构建与迁移计划

> 状态：计划稿（2026-10-24）。
> 定位：[ui-pluginization.md](ui-pluginization.md) 的配套实施文档，只讲 **UI 插件侧**怎么建、怎么迁、怎么验收。
> 前置：核心侧的批次 D（`runtime: ui` + `UiHost`）已交付。若核心侧未就绪，本计划只能进行到 U2。

---

## 0. 一句话

把现在这个 Flutter 应用改造成 `runtime: ui` 插件 `tree.ui.default`：**它不再拉起核心，而是被核心拉起并附着上去**；现有的主题、字体、右栏窗口、文件查看器等界面能力全部原样保留，只改「谁来启动谁」。

---

## 1. 范围与交付物

| 交付物 | 位置 |
| --- | --- |
| UI 插件可执行体 | `tree-plugins` 仓 release 资产：`tree-ui-default-<ver>.zip` |
| 插件清单 | 包内 `plugin.json` |
| 索引条目 | `plugin-index.json` 的 `plugins[]` 中新增一项 |
| 本仓代码改造 | **已迁出**：UI 源码现在插件仓 `plugins/tree.ui.default/`（`lib/` attach 化与站点订阅、`pubspec.yaml`）；本仓只剩 `tool/`（打包脚本）与核心侧点位 |

**不做**：不改核心的 `runtime: headless | ui` 分类机制（那是批次 D 的事）；不在本阶段实现悬浮球或多窗口（属于后续 UI 插件，见 §8）。

---

## 2. 插件身份与产物

```json
{
  "id": "tree.ui.default",
  "name": "Tree 默认界面",
  "version": "1.0.5",
  "runtime": "ui",
  "command": "tree_ui.exe",
  "args": [],
  "granularity": "team",
  "scope": {},
  "requires": { "api": ">=1.0 <2.0" },
  "files": ["**"]
}
```

要点：

- **可执行体必须改名 `tree_ui.exe`**，避免与不可卸载的 loader `Tree.exe` 同名。
  打包脚本在压缩前改名，不重命名整个产品。
- **单实例由 `UiHost` 保证**（每个插件 id 一个宿主进程）；`granularity` 只影响 headless
  的实例编组，UI 沿用契约内的默认值 `team`（当前核心的 `plugins.yaml` 校验只接受
  `team / agent / session`，写 `singleton` 会被拒——这是核心侧的既有值域，不是本插件要改的）。
- `scope: {}`：UI 订阅用通配，不需要单独设计。
- `requires.api`：与 `/api/meta` 的 `api_version` 比对。**2026-10-25 已补齐核心侧启用前校验**
  （`PluginConfig.apiRequires` + `PluginBus.apiBlock`，配置存储校验形状）；区间不满足时
  条目不落盘、进程不启动，HTTP 回 409（带 `requires_api` / `core_api`）。运行期实际能力
  探测仍以 `/api/meta` 为准。

### 产物内容

Flutter Windows release 目录整体打包：

```
tree_ui.exe
flutter_windows.dll
data/            # icudtl.dat、app.so 等
*.dll            # 原生依赖
plugin.json
```

排除：调试符号、`*.pdb`、旧的 `tree.exe`。

---

## 3. 运行形态

| 项 | 约定 |
| --- | --- |
| 启动者 | loader 拉核心 → 核心的 `UiHost` 拉起 `tree_ui.exe` |
| 通信 | WS 客户端（`TREE_CORE_URL` + `TREE_CORE_TOKEN`），另用 REST 调委派端点 |
| 握手 | 连上后第一帧发 `ui.hello {plugin_id, version, capabilities:["plugin.manage"]}` |
| 退出 | 用户关窗 ⇒ 进程退出 ⇒ `UiHost` 置 stopped ⇒ 卸载可执行文件；核心继续运行 |
| 崩溃 | `UiHost` 记录退出码，广播 `plugin_status` 置 stopped；不自动无限重启（避免安装/卸载时打架） |
| 崩溃后重拉 | 用户在引导页或托盘点「启动界面」→ `POST /api/plugin/configs/{id}/restart` |

**关键：UI 不再拥有核心的生命周期。** 关闭界面不等于关闭系统；系统是否有界面由 `ui.hello` 连接数决定。

身份来源：可执行体同目录的 `plugin.json`（`id` / `version`），能力默认声明
`plugin.manage`。**没有清单时不发 `ui.hello`**（开发期 `flutter run`）：未在
`plugins.yaml` 声明的 id 会让核心拒绝并关闭整条连接，开发回路会直接断掉。

---

## 4. 代码改造清单（插件仓 `plugins/tree.ui.default/`）

> 2026-11-08：本清单里的 UI 文件已整体迁入插件仓（S2/S3），下表的 `lib/...` 均指
> `plugins/tree.ui.default/lib/...`。桌面仓根不再有 Flutter 工程。

| 文件 | 改动 | 理由 |
| --- | --- | --- |
| lib/main.dart | 删除"默认拉起核心"分支；改为**先读 `TREE_CORE_URL`/`TREE_CORE_TOKEN`**，缺失则直接报错退出（不自行 spawn） | 启动顺序反转 |
| ~~`lib/io/core_process_launcher.dart`~~ | **已删除**（U1）；启动核心的逻辑归 loader | UI 不再管核心进程 |
| `lib/io/api_service.dart`（构造处） | base URL 从环境变量取；保留 `--dart-define` 覆盖供开发 | 端口随机 |
| `lib/io/websocket_service.dart` | token 从环境变量取；连接后发送 `ui.hello`；订阅改为**按 topic 订阅** | 站点化 |
| 新增 `lib/io/station_client.dart` | 封装 `station/subscribe` / `station_delivery` / 重连后重放订阅（当前只订 `system.broadcast.plugin.state`）；**不含 `station/trigger`**——功能调用一律走 REST | 目前没有 WS 侧站点客户端 |
| 新增 `lib/io/frame_router.dart` | 把 `station_delivery` 的 topic 分发到现有 UI 处理函数（`message`/`tool_start`/…） | 领域帧改由插件发出后，UI 侧只需换收口，不改渲染 |
| `lib/ui/services/theme_service.dart`、`font_service.dart`、`text_scale_service.dart` | 不变（本地 prefs） | 主题/字体本就属于 UI |
| `lib/ui/widgets/right_panel_host.dart`、`file_viewer/*` | 不变 | 应用内窗口不依赖核心 |
| `lib/ui/services/plugin_ui_registry.dart` 等 | 在批次 E 删除 | 旧面板协议退场 |

**不改渲染层。** 改造集中在"连接、订阅、启动"三个入口，避免 UI 大面积重写。

---

## 5. 分阶段与验收

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| **U1 附着化** | 去掉自 spawn；缺失 env 时明确报错；开发模式支持 `flutter run --dart-define=TREE_CORE_URL=...` | 手动拉起核心后 UI 能连上；不启动第二个核心 |
| **U2 打包** | `tool/package_ui_plugin.dart` 产出插件 zip（含 `plugin.json`）；本地以插件方式安装 | 从插件面板安装后能启动；卸载后文件被清空且条目保留 `enabled:false` |
| **U3 身份** | 连上即发 `ui.hello`；`/api/meta` 能看到自己 | `/api/meta.ui` 出现本插件；不声明 `plugin.manage` 时引导页仍开 |
| **U4 站点客户端** | 订阅插件生命周期广播站（`system.broadcast.plugin.state`）；心跳继续由 WS 服务发；`closed` / 断线在主页顶部给出可见横幅 | 断开重连后订阅自动恢复；核心发 `closed` 时 UI 显示"服务下线"而不是静默卡住 |
| **U5 帧收口** | 领域帧改由 `frame_router` 接收（批次 G 之后） | 消息流、工具卡片、agent 状态与改造前功能等价 |
| **U6 清理** | 删除旧 `plugin_ui_*` 引用与槽位接线 | `grep plugin_ui` 为空；flutter 测试全绿 |

**U1–U4 可在批次 D 后立即进行；U5 必须等批次 G；U6 属于批次 E。**

> 2026-10-25 本仓实测：打包后的 `tree_ui.exe` 由核心 `UiHost` 拉起后可附着并完成
> `ui.hello`，`/api/meta.ui` 返回 `tree.ui.default`（connections=3，
> capabilities=[plugin.manage]，can_manage_plugins=true）；U1/U3 通过。
> U4 的订阅/重连/`closed` 语义由 `test/station_client_test.dart` 覆盖（无真实核心）。
> **U2 的"从面板安装"未验证**：本仓核心只有发布仓库安装流程，没有本地 zip 安装端点。
> `requires.api` 的核心侧启用前校验已在 2026-10-25 补齐（不再是遗留项）。

---

## 6. 版本与兼容

- UI 插件版本独立于核心版本；两者只靠 `requires.api` 约束。
- 每个 UI 插件发布前必须记录"实测兼容的核心区间"，写进 release notes。
- 向后兼容责任在插件：核心的 `/api/meta` 是唯一探测入口，插件不得假设路径之外的能力。

---

## 7. 与核心批次的依赖顺序

```
D（runtime:ui + UiHost） → U1 → U2 → U3 → U4 ─┬─ E（删旧面板协议）→ U6
                                          └─ G（agent 交接） → U5
```

E 与 U5 顺序可互换，但 **U6 必须在 E 之后**，否则删了协议而 UI 还没接新帧，中间会黑屏。

---

## 8. 后续：多窗口与悬浮球（不在本次）

单类型下没有 `main/aux` 区分，所以：

- **多窗口**：同一 UI 插件内用 `desktop_multi_window`（Win10 已确认可用）开子窗口，每个子窗口建自己的 WS 连接、订自己的 topic。核心无感。
- **悬浮球**：另一个 `runtime: ui` 插件，`capabilities` 不声明 `plugin.manage`（因此引导页仍会开）。窗口置顶/无边框/点击穿透全由它自己实现。
- 两者可同时启用；`/api/meta` 只报连接与能力，不做"谁是主界面"的判断。

---

## 9. 测试

| 层 | 用例 |
| --- | --- |
| 打包 | zip 内容白名单（`tree_ui.exe` + `plugin.json`，无 pdb / `tree_core.exe`）；`plugin.json` 形状校验；`requires.api` 声明了但核心不满足时启用被拒（未声明 = 不要求） |
| 安装 | **本仓无本地 zip 安装端点**；安装流程依赖 tree-plugins 发布仓库，此处只验证产物形状与 `UiHost` 拉起 |
| 附着 | 无 env 直接退出并给可读错误；有 env 不 spawn 核心 |
| 握手 | `ui.hello` 后 `meta.ui` 出现；id 与清单不符被拒 |
| 订阅 | 断线重连恢复订阅；`closed` 帧触发 UI 提示 |
| 帧 | 改造前后同一会话的回放结果逐条一致（golden 对比） |
| 卸载 | 卸载时进程先被杀（Windows 文件锁），文件删除彻底，条目保留 `enabled:false` |

---

## 10. 风险与回退

| 风险 | 缓解 |
| --- | --- |
| UI 不再能独立启动，开发体验变差 | 保留 `--dart-define` 附着模式；提供 `tool/dev_run.ps1` 先起核心再跑 UI |
| Flutter 产物体积大，安装慢 | zip 压缩 + 增量覆盖安装；不重复下载未变动的 DLL |
| 旧帧与 topic 双轨期混乱 | U5 前 UI 同时接受两路，按 `topic` 去重；G+1 只留一路 |
| 卸载时 DLL 被占用 | 复用核心既有卸载四段顺序（先停进程再删），不新增机制 |
