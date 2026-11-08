# 侦查落档：UI 设置页改 IDE 式左右布局 + 中性配色（去绿底）

> 状态：**本期只做侦查与落档，不实施**。文档落档即本期交付物。
> 日期：2026-11-08。适用版本：UI 插件 `1.0.5+1`（实施后随 UI 版本 `1.0.6+1` 发布）。
> 改动范围：**只改 UI 插件仓** `plugins/tree.ui.default/`（核心与协议零改动，不涉及路由基线）。
> 执行依据：本文档 §5 切片；每条切片的文件、函数与测试影响已逐条落到行号。

用户原话（需求锚点，逐字）：

1. 「目前 UI 的插件设置页是一整页的条目排开，应该改成左侧目录栏，右侧才是具体选项，这样就符合现代 IDE 的设置布局。」
2. 「目前背景带了一点绿，导致绿元素太多，有点视觉疲劳。考虑将背景改为普通 IDE 的黑色、深灰色或者白色，然后只有一些标志性的地方，以及一些特殊文字，用绿色。」
3. 「一起中性化。还有右栏窗口允许打开时根据具体的内容调整窗口的大小（如拉大右栏）。但保证用户主动缩小后仍可用。」

第 3 条落地为两条口径：**D4（消息流一起中性化）确认执行**；新增 **§3.5 右栏窗口按内容自适应宽度**（SET-UI-4）。

---

## 0. 结论速览

- **设置页只有一条长列表**：[settings_page.dart](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/lib/ui/pages/settings_page.dart#L580-L658) 的 `build()` 把 14 个分区顺序塞进一个 `ListView`，没有任何导航结构；承载在右栏「设置」窗口里（默认宽 340、最小 240、窗口窄于 1120 时右栏还会自动折叠），所以当前形态既不像 IDE、也不便定位。
- **绿不是点缀，而是整套中性色阶**：深色主题的背景 `#030705`、卡片 `#0A1A10`、抬升面 `#14251B`、正文 `#E6F3EC`、次要文字 `#A9C9B6`，分割线/描边/卡片边框/输入框边框**全部由主题色派生**（≈ `#2B7A4B` 绿线）。结果是"满屏绿底 + 满屏绿线"，与用户描述的视觉疲劳一致。
- **中性化的主战场只有两个 `ThemeData`**（[main.dart](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/lib/main.dart#L174-L315)）：组件几乎全部走 `Theme.of(context).colorScheme` / `dividerColor` / `cardTheme`，改 token 全量生效；真正需要单独处理的硬编码只有终端 16 色里的 0/7/8 号与消息流气泡。
- **右栏宽度是 `MainPage` 的单一状态**（`_rightWidth`，默认 340 / 下限 240 / 预算由 `_dragCouple` 与 `_fitSideWidths` 管），窗口宿主 `RightPanelHost` 目前**完全不参与宽度**。自适应宽度只需给 `RightPanelEntry` 加一个"期望宽度"字段 + 一个打开回调，不必改布局算法；"用户缩过就不再放宽"用一个会话级开关即可保证不被抢。
- **布局改造只动 `settings_page.dart` 一个文件 + 5 个设置页测试**；主题改造只动 `main.dart`（抽出 `ui/app_theme.dart`）+ 1 个诊断探针测试；消息流去绿另算一片（§4.4，决策 D4 已确认）；右栏自适应宽度动 `right_panel_host.dart` + `main_page.dart` 两个文件。

---

## 1. 设置页现状

### 1.1 结构（单列 14 节）

`build()` 按固定顺序拼 `_buildSectionTitle(标题) + 卡片 + SizedBox(24)`，全部在同一 `ListView` 内滚动：

| # | 分区标题 | 构建函数 | 位置 | 关键控件 / Key | 数据来源 |
|---|---|---|---|---|---|
| 1 | 流式帧率 | `_buildTokenRateCard` / `_buildFrameRateCard` | L1144 / L1243 | 滑块 + 数字输入 | `ApiService.getTokenRate` / `getFrameRate` |
| 2 | 心跳判活 | `_buildHeartbeatCard` | L1341 | `heartbeat-interval-input`、`heartbeat-limit-input`、`heartbeat-apply` | 设置端点（在线/落盘双值） |
| 3 | 自定义模型 | `_buildCustomModelCard` / `_buildModelRow` | L1511 / L1591 | 模型 CRUD、`_ModelEditorDialog`（L2026） | `ApiService.getModels` |
| 4 | 主题管理 | `_buildThemeCard` / `_buildThemeOption` | L1961 / L2004 | 浅色/深色/跟随系统 | `ThemeService` |
| 5 | 主题色 | `_AccentColorCard`（L2336）/ `_buildAccentOption`（L2486） | L2382 / L2486 | `accent-option-*`、`accent-custom-field`、`accent-custom-apply` | `ThemeService` |
| 6 | 文字大小 | `_buildTextScaleCard` | L1806 | `text-scale-slider` | `TextScaleService` |
| 7 | 界面字体 | `_buildFontCard` | L1881 | `ui-font-family-*`、`ui-font-weight-*` | `FontService` |
| 8 | 窗口与托盘 | `_buildTrayCard` | L1728 | `close_to_tray_switch`、`quit_tree_button` | `TrayService` |
| 9 | 编辑器 | `_buildEditorCard` | L697 | 语法高亮 / 失焦保存开关 | `EditorSettings` |
| 10 | 插件开发 | `_buildPluginDevCard` | L956 | `plugin-docs-open`、`plugin-docs-reveal` | `ApiService.getPluginSnapshot` |
| 11 | 插件发布源 | `_buildPluginReleaseCard` | L765 | `plugin-release-order-*`、token 两框、`plugin-release-save/test` | 设置端点 |
| 12 | 核心日志 | `CoreLogCard` | [core_log_card.dart](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/lib/ui/widgets/core_log_card.dart) | — | 日志目录 |
| 13 | 新手引导 | `_buildOnboardingCard` | L665 | `settings-replay-onboarding` | 回调 / `pop(true)` |
| 14 | 版本信息 | `_buildVersionCard` | L1059 | `version-copy`、`version-build-warning` | `VersionInfo` |

初始化时一次性拉 6 路数据（[L148-L159](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/lib/ui/pages/settings_page.dart#L148-L159)）：token 帧率、推送帧率、心跳、发布源、模型列表、插件清单路径。

`focusModels`（新手引导第 1 步「带我过去」）靠 `GlobalKey` + `Scrollable.ensureVisible` 滚到第 3 节（[L142-L182](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/lib/ui/pages/settings_page.dart#L142-L182)）；改成分页后应替换为「直接选中『模型』分类」，不再需要滚动锚点。

### 1.2 承载位置与可用宽度

| 入口 | 位置 | 形态 |
|---|---|---|
| 桌面右栏「设置」窗 | [main_page.dart L1662-L1671](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/lib/ui/pages/main_page.dart#L1662-L1671) `SettingsPage(embedded: true)` | 无 Scaffold/AppBar，标题由窗口 chip 承担；窗口用 `IndexedStack` 常挂（[right_panel_host.dart L400-L419](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/lib/ui/widgets/right_panel_host.dart#L400-L419)），切窗不重建 |
| 移动端 AppBar 齿轮 | [main_page.dart L728-L738](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/lib/ui/pages/main_page.dart#L728-L738) `SettingsPage()` | `Navigator.push` 全屏页 |
| 右栏窗口宽度 | [main_page.dart L41-L57](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/lib/ui/pages/main_page.dart#L41-L57) | 初始 **340**、最小 **240**、可拖拽；窗口宽 <1120 时右栏自动折叠（L170-L172） |

**结论**：桌面主路径下设置页通常只有 **240~400px** 可用宽。直接做「176px 目录 + 内容」会在默认宽度下把内容压成 ~160px，不可用。因此必须**响应式降级**（§3.2）；拖宽右栏或折叠中栏后仍能获得完整 IDE 双栏形态。

### 1.3 现有测试对"单列可滚动"的依赖

| 测试 | 依赖方式 | 改造影响 |
|---|---|---|
| [theme_accent_test.dart](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/test/theme_accent_test.dart#L156-L202) | 视口 1200×4000，直接 `find.text('主题色')` / `accent-option-*` | 默认分类含「外观」即可不改；需实跑确认 |
| [settings_font_test.dart](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/test/settings_font_test.dart#L48-L93) | 同上，找「界面字体 / 字体族 / 字重」 | 属「外观」组，默认可见 |
| [settings_text_scale_test.dart](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/test/settings_text_scale_test.dart#L48-L91) | 同上，找 `text-scale-slider` | 属「外观」组，默认可见 |
| [heartbeat_settings_test.dart](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/test/heartbeat_settings_test.dart#L170-L219) | 视口 1200×2600，直接找 `heartbeat-*` | **需先点 `settings-nav-runtime`** |
| [plugin_release_sources_settings_test.dart](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/test/plugin_release_sources_settings_test.dart#L152-L159) | `tester.scrollUntilVisible(..., scrollable: find.byType(Scrollable).first)` | **需先点 `settings-nav-plugins`**，且滚动目标改成内容列表的 Key（目录列表也是 `Scrollable`，`.first` 会指错） |
| [message_stream_style_test.dart](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/test/message_stream_style_test.dart#L60-L75) | 断言用户气泡底色 == `colorScheme.primary` | 仅当采纳 D4（消息流去绿）时改 |

---

## 2. 配色现状

### 2.1 主题入口

- 品牌常量：[main.dart L153-L165](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/lib/main.dart#L153-L165)（`brandBright #00FF8C` / `brandBlack #030705` / `brandCard #0A1A10` / `brandDivider #2B7A4B`）。
- 浅色主题：[main.dart L174-L243](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/lib/main.dart#L174-L243)。
- 深色主题：[main.dart L249-L315](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/lib/main.dart#L249-L315)。
- 两个兜底 App（核心启动失败 / 已在运行）各自复制了一份深色 `ThemeData`：[L527-L590](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/lib/main.dart#L527-L590)、[L598-L660](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/lib/main.dart#L598-L660)。
- 派生色函数：[theme_service.dart L98-L161](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/lib/ui/theme_service.dart#L98-L161)。**全部调用点只在 `main.dart`**（外加欢迎字标用 `deriveDeep/deriveMidGreen`），所以中性化不需要改任何业务组件。

### 2.2 绿系 token（现状与问题）

深色：

| token | 现值 | 观感问题 |
|---|---|---|
| `scaffoldBackgroundColor` | `#030705` | 近黑但偏绿，整窗泛绿底 |
| `surface` / AppBar 底色 | `#030705` | 与背景同色，没有 IDE 的层次 |
| `cardColor` | `#0A1A10` | 深绿卡片 |
| `surfaceContainerHighest` | `#14251B` | 绿灰抬升面（右栏路由格、选中底等 30 处引用） |
| `onSurface` | `#E6F3EC` | 正文是"绿白"，长时间阅读发绿 |
| `onSurfaceVariant` | `#A9C9B6` | 次要文字绿灰 |
| `dividerColor` / `DividerTheme` / AppBar 下边框 | `deriveDivider` ≈ `#2B7A4B` | **所有分割线是饱和绿** |
| `outline` | `deriveOutlineDark` ≈ `#5E8E71` | 卡片/条目默认描边是绿 |
| 卡片/对话框 `side` | `deriveDivider` | 每张卡片一圈绿边 → "满屏绿框" |
| 输入框 `enabledBorder` | `deriveLine` ≈ `#00522C` | 深绿描边 |

浅色：

| token | 现值 | 问题 |
|---|---|---|
| `scaffoldBackgroundColor` | `#F4FAF6` | 白里透绿 |
| `onSurface` | `#1A2E21` | 墨绿正文 |
| `onSurfaceVariant` | `#44584C` | 绿灰次要文字 |
| `surfaceContainerHighest` | `#DCEAE1` | 浅绿抬升面 |
| 分割线 / AppBar 下边框 / 卡片边框 / 输入框边框 | `deriveDividerLight` / `deriveInputBorderLight` | 浅绿线 |

**结论**：绿同时占了「背景、层次、边框、正文」四层；必须把**中性色阶整体去绿**，只保留主色用于强调。

### 2.3 硬编码色盘点

| 位置 | 色值 | 处理 |
|---|---|---|
| [terminal_panel.dart L1011-L1029](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/lib/ui/widgets/terminal_panel.dart#L1011-L1029) | ANSI 0 `#1B1F1C`、7 `#E6F3EC`、8 `#5E8E71` | **改中性**（`#1E1E1E` / `#E6E6E6` / `#6B6B6B`）；2/10 号绿是 ANSI 语义，保留 |
| [code_highlight.dart L605-L614](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/lib/ui/services/code_highlight.dart#L605-L614) | 关键字 `#7FD1A6`、注释 `#5E8E71` | **本期保留**（语义着色，面积小）；如需彻底中性化另立片 |
| `Colors.green` 状态点（plugin_panel / question_panel / todo_panel / mode_switch 等） | 语义绿 | 保留（"在线 / 完成 / 成功"） |
| `welcome_mark.dart` 主色渐变、`ActivityBarItem` 选中条、主按钮 | `cs.primary` | 保留（标志性） |
| `_buildSectionTitle`（settings_page L1711-L1721） | 硬编码 `#94A3B8` | 改 `cs.onSurfaceVariant`，随主题中性化 |

### 2.4 消息流的大面积绿（本轮最大单块）

[message_list.dart L1596-L1636](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/lib/ui/widgets/message_list.dart#L1596-L1636)：

- **用户消息**：整块 `cs.primary` 满色底（深色下 = 荧光绿 `#00FF8C`），文字用 `onPrimary`。
- **模型消息**：`cs.primary` 5% 底 + 60% 主色 3px 左竖条。
- 每条消息都带绿 → 与"背景去绿"叠加后，绿色仍然最多。处理口径见 §4.4 / 决策 D4。

---

## 3. 目标布局（设置页）

### 3.1 左目录分组

7 个分类，顺序固定（用户口径之外的排序不做）：

| 分类 id | 目录名 | 图标 | 包含分区（§1.1 序号） | 备注 |
|---|---|---|---|---|
| `appearance` | 外观 | `Icons.palette_outlined` | 主题管理、主题色、文字大小、界面字体（4–7） | **默认选中** |
| `editor` | 编辑器 | `Icons.code` | 编辑器（9） | |
| `model` | 模型 | `Icons.memory` | 自定义模型（3） | `focusModels` 落这里 |
| `runtime` | 运行与链路 | `Icons.speed` | 流式帧率、心跳判活（1–2） | |
| `plugins` | 插件 | `Icons.extension_outlined` | 插件发布源、插件开发（10–11） | |
| `window` | 窗口与托盘 | `Icons.window_outlined` | 窗口与托盘（8） | |
| `about` | 关于 | `Icons.info_outline` | 版本信息、核心日志、新手引导（12–14） | |

右侧内容沿用现有卡片与分区小标题（卡片内控件零改动），只在分组层面重排顺序。

### 3.2 响应式断点（按设置页自身可用宽）

| 可用宽度 | 形态 | 目录宽 |
|---|---|---|
| ≥ 620 | 文字目录 + 右侧内容（完整 IDE 形态） | 176 |
| 420 ~ 619 | 图标栏（`Tooltip` 显示名称 + 2px 选中条） | 44 |
| < 420 | 顶部一行横向分类 chip（可横向滚动） | 高 40 |

依据：右栏默认 340 / 最小 240（§1.2），默认宽度落进"图标栏"档，内容宽度与今天基本一致（不劣化）；用户把右栏拖宽到 620+ 或折叠中栏后即为完整双栏。

### 3.3 结构与状态（实现规格）

在 `settings_page.dart` 内新增（不新建页面文件）：

1. `_SettingsCategory`：`id / label / icon / List<Widget Function()> sections`；`static const List<_SettingsCategory> _categories`。
2. `_SettingsPageState._category`（默认 `appearance`），`_selectCategory(String id)`。
3. `build()` 改为：
   - `LayoutBuilder` 取宽 → `_buildNav(cs, width)` + `Expanded(_buildContent(cs))`；
   - `embedded == false` 时仍套 `Scaffold + AppBar(title: '设置')`；
   - `embedded == true` 保持 `Container(color: scaffoldBackgroundColor)`。
4. 内容区：`IndexedStack(index, children: [for (cat) _buildCategoryContent(cat)])`，每个分类一个 `ListView`。
   - **必须用 IndexedStack 而不是按需重建**：切分类不丢滚动位置，也不丢 `_AccentColorCard` 的自定义色号草稿（该卡片是独立 StatefulWidget，销毁即清空输入）。
   - 不需要 `PageStorageKey`：IndexedStack 常挂即保留滚动位置。
   - 每个 `ListView` 加 `key: Key('settings-content-scroll-<id>')`，供测试直接定位内容滚动视图（避免 `find.byType(Scrollable).first` 命中目录列表）。
5. 目录项：
   - 文字/图标两种形态共用 `InkWell`，`key: Key('settings-nav-<id>')`；
   - 选中态 = 2px 主色左条 + `primary@12%` 底 + 主色文字/图标（与 `ActivityBarItem` 观感一致，但需文字，**不复用**该控件）；
   - chip 形态 `key: Key('settings-nav-chip-<id>')`。
6. `focusModels`：`initState` / `didUpdateWidget` 改为 `_selectCategory('model')`；删除 `_modelsSectionKey`、`_scheduleScrollToModels`、`Scrollable.ensureVisible`。
7. `_buildSectionTitle` 颜色改 `cs.onSurfaceVariant`；分区标题仍保留（内容区内的二级标题）。

### 3.4 不做

- 不加搜索框、不加设置项收藏/最近访问（用户未要求；避免过度设计）。
- 不改任何设置项的控件、键名与保存逻辑；不做"设置迁移"。
- 不改窗口 chip 顺序与「+」路由页布局（宽度请求只加在宿主，§3.5）。

### 3.5 右栏窗口按内容自适应宽度（用户第 3 条需求）

#### 现状

- 宽度是 `MainPage` 的唯一状态：`_rightWidth` 初始 340、下限 240（[main_page.dart L113-L124](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/lib/ui/pages/main_page.dart#L113-L124)），上限只由"中栏留 360"的预算决定（`_sideBudgetFor` / `_dragCouple` / `_fitSideWidths`，L1094-L1139 / L1164-L1195）。
- `RightPanelHost` 只管开关窗口与 chip，**不认识宽度**（[right_panel_host.dart L159-L197](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/lib/ui/widgets/right_panel_host.dart#L159-L197)）。
- 打开窗口的三个入口：`_openWindow`（picker 点格子 / 外部 `openRequestId`）、`_focusWindow`（点 chip）、初始化时按 `openByDefault` 挂载。设置窗另有活动栏入口 `_openSettings`（[main_page.dart L1500-L1513](file:///e:/programs/Tree/desktop/plugins/tree.ui.default/lib/ui/pages/main_page.dart#L1500-L1513)）与引导入口 `_requestRightWindow`（L1490-L1498），二者都通过 `openRequestRevision` 落到宿主的 `_openWindow`。
- 用户拖拽结束走 `_endSideDrag`（L1256-L1260）；左右两根分隔条共用同一个回调，目前**区分不了拖的是哪一侧**。

#### 目标口径

1. **窗口可声明期望宽度**：`RightPanelEntry` 增加 `final double? preferredWidth`（null = 不请求，默认行为不变）。
2. **只在"用户主动打开/聚焦"时请求**，初始化 `openByDefault` 不请求（避免启动就把右栏拉宽）。
3. **只放宽、不缩窄**：目标宽 = `preferredWidth` 与当前 `_rightWidth` 取大；已经更宽就不动。
4. **不越预算**：复用 `_dragCouple(available, target, 左栏当前宽, draggedLeft: false)`，从左右两侧按既有规则借空间（中栏保底 360、左栏最低 200）；预算不足时取允许的最大值，不溢出。
5. **用户缩过就尊重**：任一次**右栏分隔条**拖拽结束（`_beginSideDrag` 传入「哪一侧」以区分）后置 `_rightWidthUserOverride = true`，本次会话内忽略所有 `preferredWidth`。此后窗口内容靠 §3.2 的响应式降级保证可用（设置页在 240px 仍有 chip 导航），不会出现"缩不动 / 又被拉回去"。
6. **中栏折叠时不参与**：`_rightAbsorbs` 为真时右栏由父级决定宽度，直接跳过。
7. **不能同步 `setState`**：`openRequestId` 走的是子组件 `didUpdateWidget` → `_openWindow`，在那里直接回调父级 `setState` 会触发 "setState() called during build"。宿主回调由 `MainPage` 用 `WidgetsBinding.instance.addPostFrameCallback` 延后一帧执行。

#### 期望宽度表（只列需要放宽的窗口）

| 窗口 id | preferredWidth | 理由 |
|---|---|---|
| `settings` | 720 | 左目录 176 + 内容 ~544，正好是 §3.2 的完整双栏 |
| `files` | 560 | 长行 / 宽表格 / 分屏 |
| `mcp` | 520 | JSON 配置编辑 |
| `modelInfo` | 480 | 模型参数表 |
| `detail` | 460 | 工具参数与结果正文 |
| `toolRuns` | 460 | 命令行摘要 |
| `questions` / `todo` | 400 | 列表为主，不需过宽 |

> 插件槽位窗口（`panel:<slotKey>`）本期不声明 `preferredWidth`（保持 null），机制留好，后续可由插件面板自行申报。

#### 实现点

| 文件 | 改动 |
|---|---|
| `right_panel_host.dart` | `RightPanelEntry` 加 `preferredWidth`；`RightPanelHost` 加 `onWindowActivated: ValueChanged<RightPanelEntry>?`，在 `_openWindow`（picker / 外部请求）与 `_focusWindow` 末尾调用；`initState` 不调用 |
| `main_page.dart` | 新增 `_onRightWindowActivated(entry)`（帧后执行 + 预算夹取 + 只放宽）；`_beginSideDrag` 增 `side` 参数，`_endSideDrag` 仅右栏拖拽时置 `_rightWidthUserOverride`；`_rightPanelEntries()` 按上表填 `preferredWidth` |

---

## 4. 目标配色（中性化）

### 4.1 原则

背景、表面、层次、边框、正文一律中性；**绿色只出现在 5 类位置**：

1. 品牌标志：TREE 字标、托盘/窗口图标、欢迎页主色渐变；
2. 选中/激活：活动栏指示条、窗口 chip、设置目录选中、agent 选中、当前会话；
3. 主操作：发送、保存、新建、安装等 `FilledButton`/主图标按钮；
4. 焦点与链接：输入框聚焦环、可点击文字、`TextButton`；
5. 状态语义：成功/在线/完成小圆点。

### 4.2 深色 token 对照（目标）

| token | 现值 | 目标值 |
|---|---|---|
| `scaffoldBackgroundColor` | `#030705` | `#1E1E1E` |
| `surface` / AppBar 底色 | `#030705` | `#252526` |
| `cardColor` | `#0A1A10` | `#252526` |
| `surfaceContainerHighest` | `#14251B` | `#2D2D2D` |
| `dividerColor` / `DividerTheme` / AppBar 下边框 | `deriveDivider` | `#333333` |
| `outline`（默认描边） | `deriveOutlineDark` | `#3C3C3C` |
| 卡片/对话框 `side` | `deriveDivider` | `#333333` |
| 输入框 `enabledBorder` | `deriveLine` | `#3C3C3C` |
| 输入框 `focusedBorder` | `accent` | **不变**（主色） |
| `onSurface` | `#E6F3EC` | `#E6E6E6` |
| `onSurfaceVariant` | `#A9C9B6` | `#9E9E9E` |
| AppBar 前景 | `deriveAppBarForeground` | `#E6E6E6` |
| `primary` / `onPrimary` | `accent` / `deriveOnBright` | **不变** |
| `primaryContainer` / `onPrimaryContainer` | `deriveContainerDark/Light` | **不变**（选中态仍带主色） |
| `textSelectionTheme` | `#4DD0E1` | 不变 |

### 4.3 浅色 token 对照（目标）

| token | 现值 | 目标值 |
|---|---|---|
| `scaffoldBackgroundColor` | `#F4FAF6` | `#F3F3F3` |
| `surface` / `cardColor` | `#FFFFFF` | 不变 |
| `onSurface` | `#1A2E21` | `#1F1F1F` |
| `onSurfaceVariant` | `#44584C` | `#616161` |
| `surfaceContainerHighest` | `#DCEAE1` | `#E4E4E4` |
| 分割线 / AppBar 下边框 / 卡片边框 | `deriveDividerLight` | `#E0E0E0` |
| `outline` | `deriveDivider` | `#D4D4D4` |
| 输入框 `enabledBorder` | `deriveInputBorderLight` | `#D4D4D4` |
| `primary`（深绿 `deriveDeep`）/ `primaryContainer` | 派生绿 | **不变** |
| `textSelectionTheme.selectionColor` | `deriveContainerLight` | 可改 `#D6E8DC` 或保留 |

### 4.4 消息流去绿（决策 D4，**已确认执行**）

| 元素 | 现状 | 目标 |
|---|---|---|
| 用户消息气泡 | `cs.primary` 满色底 + `onPrimary` 文字 | `#2D2D2D`（浅色 `#EEEEEE`）底 + 1px 中性边框 + `cs.onSurface` 文字；圆角/内边距不变 |
| 模型消息高亮块 | `primary@5%` 底 + `primary@60%` 3px 左条 | 无底色 + `#3C3C3C` 3px 左条；悬停/选中才转 `cs.primary` |
| 工具/思考行 | 悬停/选中 `cs.primary` 描边 | **不变**（交互态绿，属"选中"类） |
| 发送按钮 / 输入框聚焦环 | 主色 | **不变** |

### 4.5 主题代码组织（为可测性做的小重构）

新建 `lib/ui/app_theme.dart`：

```dart
class AppTheme {
  static const Color neutralBg = Color(0xFF1E1E1E);
  static const Color neutralSurface = Color(0xFF252526);
  static const Color neutralOverlay = Color(0xFF2D2D2D);
  static const Color neutralBorder = Color(0xFF333333);
  static const Color neutralOutline = Color(0xFF3C3C3C);
  static const Color neutralText = Color(0xFFE6E6E6);
  static const Color neutralTextMuted = Color(0xFF9E9E9E);

  static ThemeData light(Color accent) { ... }   // 由 main.dart _buildLightTheme 平移
  static ThemeData dark(Color accent) { ... }    // 由 main.dart _buildDarkTheme 平移
}
```

- `main.dart` 的 `_buildLightTheme/_buildDarkTheme` 改为转调 `AppTheme.light/dark`，`_withUiFont` 逻辑保留在 `main.dart`（字体是运行期偏好）。
- 两个兜底 App 改用 `AppTheme.dark(brandBright)`，删除重复 `ThemeData`。
- `brandBlack/brandCard/brandDivider` 不再使用则删除；只留 `brandBright`（品牌主亮绿）。
- `ThemeService.derive*` **全部保留不删**（欢迎字标仍用 `deriveDeep/deriveMidGreen`；`theme_accent_test` 的派生色断言继续有效）。只把主题构建里的 divider/outline/正文引用替换为中性常量。

---

## 5. 执行切片（下次可直接照此推）

版本线：UI 插件 `1.0.5+1` → 实施后 `1.0.6+1`（`plugins/tree.ui.default/pubspec.yaml`；`plugin.json.version` 由打包脚本生成，不手改）。
门禁（每片都跑，cwd = `plugins/tree.ui.default`）：`flutter analyze lib test` 零告警 → `flutter test` 全绿。UI 插件零 path 依赖，不触发核心/协议闸门。

### S1 设置页左目录 + 响应式

- 文件：`lib/ui/pages/settings_page.dart`（唯一业务文件）。
- 动作：§3.3 全部 1–7 项；`_buildSectionTitle` 改 `cs.onSurfaceVariant`。
- 测试：
  - 新增 `test/settings_nav_test.dart`：默认 `appearance`；点 `settings-nav-*` 切分类且内容不串台；`focusModels` 自动选中 `model`；宽 1200 → 目录 176；宽 500 → 图标栏；宽 360 → chip 行；切换分类后返回，`_AccentColorCard` 自定义输入草稿仍在。
  - 改 `heartbeat_settings_test.dart`：开头 `tester.tap(find.byKey(Key('settings-nav-runtime')))`。
  - 改 `plugin_release_sources_settings_test.dart`：先 tap `settings-nav-plugins`；`_scrollTo` 的 `scrollable` 改 `find.byKey(Key('settings-content-scroll-plugins'))`。
  - `theme_accent_test / settings_font_test / settings_text_scale_test`：预期不改（默认分类含目标分区），实跑确认。
- 手动：右栏 340 宽默认 → 图标栏；拖宽 620+ → 文字目录；设置窗最窄 240 → chip 行；每档都不横向溢出。

### S2 中性化深/浅主题

- 文件：新增 `lib/ui/app_theme.dart`；改 `lib/main.dart`（转调 + 删重复主题）；改 `terminal_panel.dart` 的 0/7/8 号色。
- 动作：§4.2 / §4.3 / §4.5 全部；`scaffoldBackgroundColor`、`surface`、`cardColor`、`surfaceContainerHighest`、`dividerColor/DividerTheme`、`outline`、`onSurface`、`onSurfaceVariant`、卡片/对话框边、输入框常态边、AppBar 底色/前景。
- 测试：
  - 新增 `test/theme_neutral_test.dart`：`AppTheme.dark/light` 的上述 token 均为中性（R==G==B）、`dividerColor != ThemeService.deriveDivider(accent)`、`colorScheme.primary == accent`、聚焦边框仍为 `accent`。
  - `theme_color_probe_test.dart` 只是 print 探针 → 按新 token 更新或删除（不保留过时色值）。
  - `welcome_mark_test.dart` 不变（只用 primary）。
- 手动：深/浅两套逐屏扫（中栏、左栏、右栏、文件树、终端、插件面板、对话框），确认没有残留绿底/绿框。

### S3 消息流去绿（D4 已确认，必做）

- 文件：`lib/ui/widgets/message_list.dart`（L1596-L1636 与附件卡 L1802-L1821 的 `isUser` 取色）。
- 动作：§4.4；用户气泡与模型高亮块改中性，附件卡跟随气泡文字色。
- 测试：改 `test/message_stream_style_test.dart` 的用户气泡断言（不再等于 `primary`，改断言中性底 + 圆角）；模型高亮块断言颜色为中性或只断言几何。
- 文档：`plugins/tree.ui.default/lib/README.md` 不变量 11（模型消息高亮块 / 用户气泡口径）同步改。

### S4 右栏窗口按内容自适应宽度

- 文件：`lib/ui/widgets/right_panel_host.dart`、`lib/ui/pages/main_page.dart`（§3.5 实现点）。
- 动作：
  - `RightPanelEntry.preferredWidth` + `RightPanelHost.onWindowActivated`；
  - `MainPage._onRightWindowActivated`（帧后执行、`_dragCouple` 夹取、只放宽、`_rightWidthUserOverride` / `_rightAbsorbs` 两处早退）；
  - `_beginSideDrag(side)` 区分左右；`_endSideDrag` 仅在拖右栏时置用户覆盖；
  - `_rightPanelEntries()` 按 §3.5 表填 `preferredWidth`（设置 720 / 文件 560 / MCP 520 / 模型信息 480 / 详情与 toolRuns 460 / questions 与 todo 400）。
- 测试：
  - 改 `test/right_panel_host_test.dart`：点 picker 格子 / 点 chip 会触发 `onWindowActivated`，初始化不触发。
  - 新增 `test/main_page_window_width_test.dart`（沿用 `main_page_sidebar_width_test.dart` 的 2000×1000 视口与宽度探针）：
    1. 点活动栏「设置」→ 右栏宽 ≈ 720，中栏 ≥ 360，左栏 ≥ 200；
    2. 窗口缩到 1100 再开设置 → 右栏取预算允许的最大值，无 overflow；
    3. 先把右栏拖窄（记 `_rightWidthUserOverride`）再开设置 → 宽度不再变化，设置页仍渲染（窄态 chip 导航可见）；
    4. 中栏折叠时打开窗口 → 右栏宽度不由该请求改写。
- 手动：默认窗口打开设置 → 右栏一次拉宽到双栏形态；手动拖窄后切走再切回 → 保持用户宽度，设置页自动降级为图标栏/chip。

### S5 收尾

- `lib/README.md`：补设置页「左目录 + 内容」与「窗口打开可请求期望宽度、用户缩过不再放宽」两条不变量与新测试钉子；改不变量 11（消息流口径）。
- `docs/README.md` 已在本片落档时加索引；`docs/work-log.md` 每片完成各加一行。
- UI `pubspec.yaml` 版本 → `1.0.6+1`；发布索引与资产按发版车道 D 处理（不在本车道内 push/tag）。

---

## 6. 验收清单

手动（真机 Windows，UI 插件开发模式）：

1. 右栏「设置」窗：默认 340 宽 → 44px 图标栏；Tooltip 显示分类名；点图标切分类有主色选中条。
2. 拖宽右栏到 ≥620 → 176px 文字目录；再缩回 → 降级不溢出。
3. 窄窗（240）→ 顶部 chip 行可横向滚动，选中项高亮。
4. 切分类再切回：「外观」里的自定义色号输入草稿、各列表滚动位置都保留。
5. 新手引导第 1 步「带我过去」→ 自动落在「模型」分类，且模型列表已加载。
6. 深色：背景/侧栏/卡片是黑-深灰层次，无绿底、无绿框、正文为中性灰白；绿色只剩 §4.1 五类位置。
7. 浅色：白/浅灰层次，无浅绿底与浅绿框。
8. 终端：黑底中性、白字中性，ANSI 绿仍正常。
9. 用户气泡为中性块，模型消息只剩中性竖条；悬停工具/思考行仍有主色反馈。
10. 自定义主题色（如 `#3B82F6`）→ 主按钮、选中条、聚焦环跟着变；背景不再被染色。
11. 默认窗口从活动栏打开「设置」→ 右栏一次拉宽（≈720），设置页直接呈现左目录 + 内容双栏，中栏不被压破。
12. 把右栏拖窄到 300 → 设置页降级为图标栏且可正常操作；切到别的窗口再切回设置 → **保持 300**，不再被拉宽。
13. 窄窗口（1100）下打开设置 → 右栏只到预算允许的最大值，页面不溢出；中栏折叠时打开窗口不改变右栏宽度。

自动化：`flutter analyze lib test` 零告警；`flutter test` 全绿（含新增 `settings_nav_test` / `theme_neutral_test` / `main_page_window_width_test`）。

---

## 7. 风险与回滚

| 风险 | 说明 | 处置 |
|---|---|---|
| 测试大面积改断言 | 设置页 5 个测试依赖"一屏都能找到" | S1 单独提交；只改导航前置与滚动目标，不改设置项自身断言 |
| 右栏窄宽下内容仍局促 | 240px 时内容 ~196px | 这是现状问题；chip 形态至少让分类可达。彻底解决需改承载方式（见 D1），不在本期 |
| 中性化削弱"随主题色整套调色板" | divider/outline 不再随 accent 变 | 属于本次目标；欢迎字标、选中态、按钮仍随主色，`theme_accent_test` 的派生函数不变 |
| 对比度 | `#9E9E9E` on `#1E1E1E` ≈ 6.2:1，`#E6E6E6` ≈ 13:1 | 达标；浅色 `#616161` on `#F3F3F3` ≈ 5.9:1 |
| 消息流改动影响既有观感 | 用户气泡从绿改中性是 UX 决策 | 已确认执行（S3）；单独切片，可独立回滚 |
| 自适应宽度"抢用户的手" | 打开窗口就把右栏拉宽，可能覆盖用户刚调好的宽度 | 只放宽不缩窄；右栏拖过一次后本会话内完全停止自动放宽；预算夹取保证中栏 ≥360、不溢出 |
| 打开窗口时 `setState` 时序 | `openRequestId` 走子组件 `didUpdateWidget`，同步改父级状态会报 build 期错误 | 宿主回调由 `MainPage` 用 post-frame 执行（§3.5 第 7 条），用例覆盖 |
| 回滚 | 每片一个 commit | S1 / S2 / S3 / S4 互不依赖，按片 revert 即可 |

---

## 8. 待拍板（附推荐默认，实施时按"默认口径"直接推；用户另行指示则以其为准）

| # | 决策 | 口径 | 备选 |
|---|---|---|---|
| D1 | 设置页承载方式 | **留在右栏「设置」窗 + 响应式降级**（改动最小、可回滚） | 全屏 `Navigator.push` 大页 / 弹出独立大窗 |
| D2 | 响应式断点 | 620 / 420（§3.2） | 其他阈值 |
| D3 | 深色底色 | **`#1E1E1E` 底 + `#252526` 面 + `#2D2D2D` 抬升** | 纯黑 `#000000` + `#111111` |
| D4 | 消息流是否同步去绿 | **已确认：是（S3 必做）** | — |
| D5 | 浅色底色 | **`#F3F3F3` 底 + 白面** | 纯白底 + 浅灰面 |
| D6 | 设置页搜索框 | **不做** | 后续按需加 |
| D7 | 自适应宽度的用户覆盖范围 | **会话级全局**：右栏被手动拖过一次后，本会话不再自动放宽任何窗口 | 按窗口分别记忆用户宽度 |
| D8 | 各窗口 `preferredWidth` | §3.5 表（设置 720 / 文件 560 / …） | 只给设置 720，其余保持 null |

---

## 9. 关键文件地图（实施只碰这些）

| 文件 | 改动 |
|---|---|
| `plugins/tree.ui.default/lib/ui/pages/settings_page.dart` | S1：目录 + 响应式 + `focusModels` 改选分类 + 标题色 |
| `plugins/tree.ui.default/lib/ui/app_theme.dart` | S2：新增，浅/深主题与中性常量 |
| `plugins/tree.ui.default/lib/main.dart` | S2：转调 `AppTheme`、兜底 App 去重、删无用品牌常量 |
| `plugins/tree.ui.default/lib/ui/widgets/terminal_panel.dart` | S2：ANSI 0/7/8 中性化 |
| `plugins/tree.ui.default/lib/ui/widgets/message_list.dart` | S3：气泡与高亮块去绿 |
| `plugins/tree.ui.default/lib/ui/widgets/right_panel_host.dart` | S4：`preferredWidth` + `onWindowActivated` |
| `plugins/tree.ui.default/lib/ui/pages/main_page.dart` | S4：帧后放宽 + 用户覆盖开关 + 拖拽侧别 + 各窗口期望宽度 |
| `plugins/tree.ui.default/lib/README.md` | S3/S5：不变量与测试钉子 |
| `plugins/tree.ui.default/test/` | 新增 `settings_nav_test.dart`、`theme_neutral_test.dart`、`main_page_window_width_test.dart`；改 5 个既有设置/消息测试 + `right_panel_host_test.dart` |
| `plugins/tree.ui.default/pubspec.yaml` | S5：`1.0.6+1` |
