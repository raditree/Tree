# 侦查落档：UI 视觉效果升级（更多圆角化）

> 状态：**侦查 + 已实施**（S1~S4 与 §3.5.1/§3.5.2 追加，UI 插件提交 `f208763`）；本文档保留口径与站点清单，供发版验收。
> 日期：2026-11-10。适用版本：UI 插件源码（版本号仍随车道 D 的发版窗口升，本仓未 bump）。
> 改动范围：**只改 UI 插件仓** `plugins/tree.ui.default/`（核心与协议零改动，不涉及路由基线）。
> 执行依据：本文档 §4 切片；每条切片的文件、站点与测试影响已逐条落到行号。

用户原话（需求锚点，逐字）：

1. 「视觉效果升级（UI）：更多的圆角化。本期先侦查并出侦察文档」

拆成两条口径：**① 把已有的圆角做得更圆、更统一**（§3.1 / §3.2）；**② 把目前还是直角的交互面补上圆角**（§3.5）。
不是全量"圆角化"：窗口骨架、文件 tab、圆形控件保持现状（§3.6）。

---

## 0. 结论速览

- **圆角没有令牌，全是散落字面值**：`lib/` 下 **108 行**圆角相关代码，**84 处 `BorderRadius.circular(...)`**，共 **10 种数字字面值**（2/3/4/5/6/8/9/10/12/14），另有 2 处比例表达式（`height/2`、`size*0.09`）与 1 处常量 `_radius = 12`，横跨 **36 个文件**。同语义元素不同值：卡片 8 与 12 并存，输入 4/6/8/14 并存，徽标 4/9/10 并存。[§1.1](#11-数量与分布)
- **全局主题只覆盖三处**：卡片 8、对话框 8、输入框边框只给了颜色（半径吃 `OutlineInputBorder` 默认 **4**）。按钮、菜单、SnackBar、Tooltip、Checkbox、Scrollbar **完全没有主题级口径**，全部吃 Material 2 默认值——`useMaterial3: false` 下这些默认值是 **1~4px**，这正是"看起来方"的主因。[§1.2](#12-主题层全局只覆盖三处) [§1.3](#13-material-2-默认值本仓-usematerial3-false)
- **圆角是成对硬编码**：`Material` + `InkWell` 各写一遍（右栏 chip 6/6、复制键 6/6、工具行 6/6），改一处不同步改另一处，水波纹会溢出圆角。[§2](#2-诊断)
- **仍有 3 类交互面是直角**：文件树行 hover/选中（整行 `ColoredBox`）、Agent 列表选中底色（整行 + 4px 左色条）、活动栏项（只有 2px 指示条，没有圆角底）。这三处是"更多圆角"最可见的增量。[§1.5](#15-仍是直角的交互面)
- **两条例外口径**：文件 tab **项**仍是扁平矩形（`lib/README.md` 不变量 16 ⑪，用户 2026-10-19 明确否决圆角胶囊），只允许 tab 条本身 2px 收边；发送/停止/回底/状态点等圆形控件与欢迎字标 HUD 线不应再改。[§1.6](#16-已锁定的例外口径)
- **实施面可控**：主题层集中在 [app_theme.dart](../../plugins/tree.ui.default/lib/ui/app_theme.dart) 一个文件；全仓 36 个文件按 §3.2 的"容器 16 / 控件 8 / 微件 6 / 栏面 2 / 胶囊"五档机械映射即可；测试只有 2 处圆角断言（均只断言 `isNotNull`），但 [file_tree_explorer_test.dart:122](../../plugins/tree.ui.default/test/file_tree_explorer_test.dart#L122) 直接按类型取 `ColoredBox`，文件树改造必须保留该控件类型。
- **建议四片交付**：S1 令牌 + 主题层 → S2 组件层机械迁移 → S3 新增加圆角面 → S4 收尾与不变量。每片独立提交、可单独回滚。[§4](#4-执行切片)

---

## 1. 现状盘点

### 1.1 数量与分布

统计口径：`plugins/tree.ui.default/lib/**/*.dart`，匹配 `BorderRadius|Radius.circular|CircleBorder|StadiumBorder|BoxShape.circle|RoundedRectangleBorder`。

| 指标 | 数量 |
|---|---|
| 命中行 | 108 |
| `BorderRadius.circular(...)` | 84 |
| `CircleBorder` / `StadiumBorder` / `BoxShape.circle` | 13 |
| `RoundedRectangleBorder(...)` | 9 |
| 涉及文件 | 36 |

`BorderRadius.circular` 的字面值分布（合计 84）：

| 值 | 2 | 3 | 4 | 5 | 6 | 8 | 9 | 10 | 12 | 14 | `height/2` | `size*0.09` | `_radius`(=12) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 处数 | 2 | 2 | 11 | 1 | 24 | 25 | 2 | 8 | 4 | 2 | 1 | 1 | 1 |

**读法**：6 与 8 是事实上的两档主值（49 处），但 4/10/12 各有成规模的独立用法，且 2/3/5/9/14 这些"孤值"说明没有统一尺子。
其中 `_radius = 12` 只在 [message_list.dart:1456](../../plugins/tree.ui.default/lib/ui/widgets/message_list.dart#L1456) 定义、[:1613](../../plugins/tree.ui.default/lib/ui/widgets/message_list.dart#L1613) 使用（用户气泡）；`height/2` 是欢迎字标的 HUD 线；`size*0.09` 是停止键内的方块。

### 1.2 主题层：全局只覆盖三处

唯一主题入口是 [app_theme.dart](../../plugins/tree.ui.default/lib/ui/app_theme.dart)（`AppTheme.light` / `AppTheme.dark`；除 `lib/demo/agent_list_demo.dart` 的独立演示壳外没有第二份 `ThemeData`，`main.dart` 的两个兜底 App 也已转调它）：

| 主题块 | 行号 | 现值 | 说明 |
|---|---|---|---|
| `inputDecorationTheme.enabledBorder/focusedBorder` | 浅 [97-104](../../plugins/tree.ui.default/lib/ui/app_theme.dart#L97-L104)、深 [169-176](../../plugins/tree.ui.default/lib/ui/app_theme.dart#L169-L176) | 只给 `BorderSide`，**未给 `borderRadius`** | 吃 `OutlineInputBorder` 默认 **4** |
| `cardTheme.shape` | 浅 [106-112](../../plugins/tree.ui.default/lib/ui/app_theme.dart#L106-L112)、深 [177-183](../../plugins/tree.ui.default/lib/ui/app_theme.dart#L177-L183) | `RoundedRectangleBorder(8)` | 21 个 `Card(` 共用；4 处自写 shape 覆盖 |
| `dialogTheme.shape` | 浅 [113-119](../../plugins/tree.ui.default/lib/ui/app_theme.dart#L113-L119)、深 [184-190](../../plugins/tree.ui.default/lib/ui/app_theme.dart#L184-L190) | `RoundedRectangleBorder(8)` | 23 个 `AlertDialog(` + 25 处 `showDialog` 共用 |
| 其他 | — | **没有** `elevatedButtonTheme` / `textButtonTheme` / `outlinedButtonTheme` / `popupMenuTheme` / `snackBarTheme` / `tooltipTheme` / `checkboxTheme` / `chipTheme` / `scrollbarTheme` | 全部吃 M2 默认 |

`ThemeData.useMaterial3: false` 在浅 [125](../../plugins/tree.ui.default/lib/ui/app_theme.dart#L125)、深 [196](../../plugins/tree.ui.default/lib/ui/app_theme.dart#L196)。

### 1.3 Material 2 默认值（本仓 useMaterial3: false）

以本机 Flutter SDK（3.47.5）源码核对，未改主题时各控件的实际圆角：

| 控件 | 默认 shape / 半径 | 本仓使用量 |
|---|---|---|
| `ElevatedButton` / `OutlinedButton` / `TextButton` | `RoundedRectangleBorder(4)` | 4 / 9 / 63 |
| `FilledButton` | `StadiumBorder`（**已经是胶囊**） | 17 |
| `IconButton` | 圆形水波纹 | 59 |
| `Chip` | `StadiumBorder`（已经是胶囊） | 1（另有大量自绘 pill 容器，见 §9） |
| `PopupMenuButton` | `RoundedRectangleBorder(4)` | 7 |
| `SnackBar` | `RoundedRectangleBorder(4)` | 67 构造 / 121 处 `showSnackBar` |
| `Tooltip` | `RoundedRectangleBorder(4)` | 16 |
| `Checkbox` | `RoundedRectangleBorder(1)` | 1 |
| `Switch` | `StadiumBorder` | 4 |
| `Scrollbar` | `Radius.circular(8)` | 7（1 处显式 `radius: 2`；另有自绘滚动条 3） |
| `TextField` / `TextFormField` | 走 `inputDecorationTheme` → 4 | 51 / 13 |

**关键结论**：`FilledButton`、`Chip`、`Switch`、`IconButton` 已经是最圆形态，**不要再改**；真正"方"的是三翼按钮、菜单、提示、输入框和复选框。

### 1.4 组件层清单（按表面分类）

| 类别 | 站点（文件:行 → 现值） |
|---|---|
| 卡片 | `Card` 主题 8（21 处 `Card(` 共用）；覆盖：[onboarding_guide.dart:52](../../plugins/tree.ui.default/lib/ui/widgets/onboarding_guide.dart#L52) 12、[question_panel.dart:397](../../plugins/tree.ui.default/lib/ui/widgets/question_panel.dart#L397) 8、[spec_panel.dart:225](../../plugins/tree.ui.default/lib/ui/widgets/spec_panel.dart#L225) 12、[teammates_window_page.dart:344](../../plugins/tree.ui.default/lib/ui/widgets/teammates_window_page.dart#L344) 12 |
| 对话框 / 浮层 | `dialogTheme` 8（23 个 `AlertDialog` 共用）；`onboarding_guide` 12；`spec_panel` 12 |
| 输入 | 全局边框 4；[create_agent_dialog.dart:334](../../plugins/tree.ui.default/lib/ui/widgets/create_agent_dialog.dart#L334) 6；[plugin_panel.dart:1094](../../plugins/tree.ui.default/lib/ui/widgets/plugin_panel.dart#L1094) 8；[message_input.dart:535](../../plugins/tree.ui.default/lib/ui/widgets/message_input.dart#L535) 14（composer 大卡）；[core_log_viewer_dialog.dart:174](../../plugins/tree.ui.default/lib/ui/widgets/core_log_viewer_dialog.dart#L174) 4 |
| 消息流 | 用户气泡 12（[:1613](../../plugins/tree.ui.default/lib/ui/widgets/message_list.dart#L1613)）；高亮定位 10（[:1202](../../plugins/tree.ui.default/lib/ui/widgets/message_list.dart#L1202)）；内联提问卡 12（[:1965](../../plugins/tree.ui.default/lib/ui/widgets/message_list.dart#L1965)）；附件条 6（[:1824](../../plugins/tree.ui.default/lib/ui/widgets/message_list.dart#L1824)）；复制键 6/6（[:1754-1756](../../plugins/tree.ui.default/lib/ui/widgets/message_list.dart#L1754-L1756)）；工具/思考/折叠行 6（[tool_call_card.dart:57-59](../../plugins/tree.ui.default/lib/ui/widgets/tool_call_card.dart#L57-L59)、[thinking_card.dart:48-50](../../plugins/tree.ui.default/lib/ui/widgets/thinking_card.dart#L48-L50)、[collapsed_run_row.dart:73-75](../../plugins/tree.ui.default/lib/ui/widgets/collapsed_run_row.dart#L73-L75)）；代码/结果块 6（[tool_call_card.dart:876](../../plugins/tree.ui.default/lib/ui/widgets/tool_call_card.dart#L876)、[:1199](../../plugins/tree.ui.default/lib/ui/widgets/tool_call_card.dart#L1199)）；骨架 10（[message_list.dart:1320](../../plugins/tree.ui.default/lib/ui/widgets/message_list.dart#L1320)）；占位 5（[:1009](../../plugins/tree.ui.default/lib/ui/widgets/message_list.dart#L1009)） |
| 右栏 | 窗口 chip 6/6（[right_panel_host.dart:374-377](../../plugins/tree.ui.default/lib/ui/widgets/right_panel_host.dart#L374-L377)）、关闭键 4（[:404](../../plugins/tree.ui.default/lib/ui/widgets/right_panel_host.dart#L404)）、picker 格 8/8（[:511-514](../../plugins/tree.ui.default/lib/ui/widgets/right_panel_host.dart#L511-L514)）、chip 行滚动条 2（[:292](../../plugins/tree.ui.default/lib/ui/widgets/right_panel_host.dart#L292)）；模型信息卡 8（[model_info_panel.dart:872](../../plugins/tree.ui.default/lib/ui/widgets/model_info_panel.dart#L872)）；会话下拉 8（[session_picker.dart:260](../../plugins/tree.ui.default/lib/ui/widgets/session_picker.dart#L260)）、行 6（[:391](../../plugins/tree.ui.default/lib/ui/widgets/session_picker.dart#L391)） |
| 插件面板 | 页签 8（[plugin_panel.dart:1025](../../plugins/tree.ui.default/lib/ui/widgets/plugin_panel.dart#L1025)）；搜索框 8（[:1094](../../plugins/tree.ui.default/lib/ui/widgets/plugin_panel.dart#L1094)）；各类卡片/条目 8×7（[:1107](../../plugins/tree.ui.default/lib/ui/widgets/plugin_panel.dart#L1107)、[:1255](../../plugins/tree.ui.default/lib/ui/widgets/plugin_panel.dart#L1255)、[:1623](../../plugins/tree.ui.default/lib/ui/widgets/plugin_panel.dart#L1623)、[:1726](../../plugins/tree.ui.default/lib/ui/widgets/plugin_panel.dart#L1726)、[:1992](../../plugins/tree.ui.default/lib/ui/widgets/plugin_panel.dart#L1992)）；pill 10（[:2111](../../plugins/tree.ui.default/lib/ui/widgets/plugin_panel.dart#L2111)）；详情页容器 8（[plugin_detail_page.dart:111](../../plugins/tree.ui.default/lib/ui/widgets/plugin_detail_page.dart#L111)）；编辑器提示 6（[plugin_editor_dialog.dart:497](../../plugins/tree.ui.default/lib/ui/widgets/plugin_editor_dialog.dart#L497)） |
| 文件 | tab 关闭键 9（[file_panel.dart:735](../../plugins/tree.ui.default/lib/ui/widgets/file_panel.dart#L735)）；Markdown/SVG/不支持预览 6×3（[file_viewer.dart:1241](../../plugins/tree.ui.default/lib/ui/widgets/file_viewer.dart#L1241)、[:1270](../../plugins/tree.ui.default/lib/ui/widgets/file_viewer.dart#L1270)、[:1379](../../plugins/tree.ui.default/lib/ui/widgets/file_viewer.dart#L1379)）；附件缩略图/文件卡 8（[attachment_preview.dart:219](../../plugins/tree.ui.default/lib/ui/widgets/attachment_preview.dart#L219)、[:236](../../plugins/tree.ui.default/lib/ui/widgets/attachment_preview.dart#L236)、[:302](../../plugins/tree.ui.default/lib/ui/widgets/attachment_preview.dart#L302)） |
| 设置页 | 类型徽标 4（[settings_page.dart:1847](../../plugins/tree.ui.default/lib/ui/pages/settings_page.dart#L1847)）；色板 4（[:2969](../../plugins/tree.ui.default/lib/ui/pages/settings_page.dart#L2969)） |
| 其他面板 | 终端回滚胶囊 10/10（[terminal_panel.dart:903-909](../../plugins/tree.ui.default/lib/ui/widgets/terminal_panel.dart#L903-L909)）；hook 通知 6/10/4/6（[hook_notice_card.dart:104](../../plugins/tree.ui.default/lib/ui/widgets/hook_notice_card.dart#L104)、[:202](../../plugins/tree.ui.default/lib/ui/widgets/hook_notice_card.dart#L202)、[:228](../../plugins/tree.ui.default/lib/ui/widgets/hook_notice_card.dart#L228)、[:251](../../plugins/tree.ui.default/lib/ui/widgets/hook_notice_card.dart#L251)）；MCP 表单/卡片 8×2、代码块 4（[mcp_config_panel.dart:443](../../plugins/tree.ui.default/lib/ui/widgets/mcp_config_panel.dart#L443)、[:606](../../plugins/tree.ui.default/lib/ui/widgets/mcp_config_panel.dart#L606)、[:641](../../plugins/tree.ui.default/lib/ui/widgets/mcp_config_panel.dart#L641)）；团队页 8/10/12/8（[teammates_window_page.dart:238](../../plugins/tree.ui.default/lib/ui/widgets/teammates_window_page.dart#L238)、[:287](../../plugins/tree.ui.default/lib/ui/widgets/teammates_window_page.dart#L287)、[:344](../../plugins/tree.ui.default/lib/ui/widgets/teammates_window_page.dart#L344)、[:976](../../plugins/tree.ui.default/lib/ui/widgets/teammates_window_page.dart#L976)）；工具运行行 6/6、超时徽标 4（[tool_runs_panel.dart:386](../../plugins/tree.ui.default/lib/ui/widgets/tool_runs_panel.dart#L386)、[:394](../../plugins/tree.ui.default/lib/ui/widgets/tool_runs_panel.dart#L394)、[:438](../../plugins/tree.ui.default/lib/ui/widgets/tool_runs_panel.dart#L438)）；用量估算徽标 4（[usage_calls_panel.dart:347](../../plugins/tree.ui.default/lib/ui/widgets/usage_calls_panel.dart#L347)）；下载进度条 2（[download_panel.dart:199](../../plugins/tree.ui.default/lib/ui/widgets/download_panel.dart#L199)）；子任务行 6（[subagent_process_list.dart:68](../../plugins/tree.ui.default/lib/ui/widgets/subagent_process_list.dart#L68)）；子 agent 切换器 14（[subagent_view_switcher.dart:114](../../plugins/tree.ui.default/lib/ui/widgets/subagent_view_switcher.dart#L114)）；上下文条 2（[message_panel.dart:2464](../../plugins/tree.ui.default/lib/ui/widgets/message_panel.dart#L2464)）；自绘滚动条 3（[message_scrollbar.dart:314](../../plugins/tree.ui.default/lib/ui/widgets/message_scrollbar.dart#L314)、[:329](../../plugins/tree.ui.default/lib/ui/widgets/message_scrollbar.dart#L329)）；兜底错误框 8（[main.dart:444](../../plugins/tree.ui.default/lib/main.dart#L444)） |
| 圆形（不改） | 发送键 [message_input.dart:707-709](../../plugins/tree.ui.default/lib/ui/widgets/message_input.dart#L707-L709)；停止键 [stop_button.dart:32-34](../../plugins/tree.ui.default/lib/ui/widgets/stop_button.dart#L32-L34)；回底键 [message_list.dart:1339-1341](../../plugins/tree.ui.default/lib/ui/widgets/message_list.dart#L1339-L1341)；附件删除徽标 [attachment_preview.dart:279-282](../../plugins/tree.ui.default/lib/ui/widgets/attachment_preview.dart#L279-L282)；状态点/头像 [teammates_window_page.dart:418](../../plugins/tree.ui.default/lib/ui/widgets/teammates_window_page.dart#L418)、[:913](../../plugins/tree.ui.default/lib/ui/widgets/teammates_window_page.dart#L913)、[plugin_panel.dart:906](../../plugins/tree.ui.default/lib/ui/widgets/plugin_panel.dart#L906)、[message_panel.dart:3084](../../plugins/tree.ui.default/lib/ui/widgets/message_panel.dart#L3084)、[subagent_view_switcher.dart:203](../../plugins/tree.ui.default/lib/ui/widgets/subagent_view_switcher.dart#L203)；欢迎 HUD 线 [welcome_mark.dart:103](../../plugins/tree.ui.default/lib/ui/widgets/welcome_mark.dart#L103)；停止键内方块 [stop_button.dart:45](../../plugins/tree.ui.default/lib/ui/widgets/stop_button.dart#L45) |

### 1.5 仍是直角的交互面

| 表面 | 现状（证据） | 为什么算"缺圆角" |
|---|---|---|
| 文件树行 hover/选中 | 整行 `Positioned.fill → ColoredBox`，无圆角、左右贴边（[file_tree.dart:804-812](../../plugins/tree.ui.default/lib/ui/widgets/file_tree.dart#L804-L812)） | 最常用的导航区，整行色块在圆角界面里最扎眼 |
| Agent 列表选中行 | `Container` 整行底色 + 4px 左色条，无圆角（[agent_list_item.dart:42-48](../../plugins/tree.ui.default/lib/ui/widgets/agent_list_item.dart#L42-L48)） | 选中底是矩形，与卡片/气泡的圆角语言不一致 |
| 活动栏项 | 只有 2px 指示条，hover 是 `InkWell` 默认方形水波纹（[activity_bar_item.dart:39-62](../../plugins/tree.ui.default/lib/ui/widgets/activity_bar_item.dart#L39-L62)） | 桌面端最左侧的常驻交互面 |
| 窗口骨架 | 左右栏、分栏、终端体、文件树体、tab 条均为直角 | **改 2px 微圆角**（见 §3.2.1）；只收边，不做大圆角 |

### 1.6 已锁定的例外口径

1. **文件 tab 项必须是扁平矩形**：[lib/README.md:324](../../plugins/tree.ui.default/lib/README.md#L324) 不变量 16 ⑪ 写明"不再是圆角胶囊"，依据是用户 2026-10-19 的原话。本次**不改 tab 项外形**；tab 条底 2px 收边，关闭键水波纹 6px。
2. **圆形控件保持圆**：发送、停止、回底、删除徽标、状态点、头像已经是 `CircleBorder` / `BoxShape.circle`，改半径没有意义，反而会破坏形状语义。
3. **窗口外壳不在 Flutter 内**：`windows/runner` 只设置了深色标题栏（`DWMWA_USE_IMMERSIVE_DARK_MODE`），圆角由 Windows 11 DWM 决定；App 内不做无边框自绘，本期不碰。

---

## 2. 诊断

| # | 问题 | 证据 | 后果 |
|---|---|---|---|
| P1 | 没有圆角令牌 | 10 种数字字面值 + 2 处表达式，最大 14、最小 2 | 每次新控件都靠"看着像"选值，漂移不可控 |
| P2 | 同语义不同值 | 卡片 8 vs 12；输入 4/6/8/14；徽标 4/9/10 | 同一屏里圆角语言不统一 |
| P3 | 主题层覆盖太窄 | 只配了 Card/Dialog/输入边框 | 按钮 4、菜单 4、SnackBar 4、Tooltip 4、Checkbox 1 全靠默认值，观感"方" |
| P4 | 圆角成对硬编码 | `Material`/`InkWell` 各写一遍（右栏 chip 6/6、复制键 6/6、工具行 6/6） | 改一处漏一处 → 水波纹溢出圆角 |
| P5 | 小尺寸件用了非胶囊值 | 进度条 2（高 3px）、上下文条 2、滚动条 2/3、徽标 4/9 | 小件看起来仍是方角，"不精致" |
| P6 | 常用导航面没有圆角 | 文件树行、Agent 行、活动栏 | 大面积直角与卡片圆角冲突，是"圆角化"最可见的缺口 |
| P7 | 无视觉回归基线 | 全仓无 golden 测试，只有 2 处 `borderRadius isNotNull` 断言 | 只能靠手动矩阵验收；改造时要避免换控件类型 |

---

## 3. 目标方案

### 3.1 圆角令牌（5 档）

新增 `lib/ui/app_radius.dart`（纯常量、不依赖 Flutter；组件层只 import 这一行，避免把 `theme_service` 拖进 34 个 widget；`theme_radius_test.dart` 可直接断言）：

```dart
/// 圆角尺子：数值只在这里出现，组件层一律引用语义名。
/// 口径（2026-11-10 用户定稿）：2 / 6 / 8 / 16 / 999。
class AppRadius {
  const AppRadius._();
  static const double xxs = 2;           // 栏级表面：侧栏列、条、终端底、文件 tab 条（只收边）
  static const double xs = 6;            // 微件：关闭键、小徽标、行 hover
  static const double sm = 8;            // 控件：输入框、按钮、菜单、工具行、代码块、面板 chip
  static const double md = 16;           // 容器：卡片、对话框、picker 格、附件卡、气泡、composer
  static const double pill = 999;        // 胶囊：状态徽标、pill、进度条、滚动条、开关
}
```

选择 2/6/8/16：2px 只给栏级表面收边（用户 2026-11-10：原先打算不做圆角的那些改为 2px 微圆角，不再留 0）；6/8 给微件与控件；16 给卡片、对话框、气泡等容器。右栏最窄 240px、文件树行高约 24px，再大就会被 Flutter 夹成胶囊。改这 5 个常量即可全量换档（D7）。

### 3.2 表面 → 令牌映射

| 表面 | 现值 | 目标 | 理由 |
|---|---|---|---|
| 栏级表面 / 分隔条 / 文件 tab 条本身 | 0 | `xxs` 2 | 只收边，不切内容；逐项代码定位见 §3.2.1 |
| `Card` | 8（theme）/ 8 / 12 | `md` 16 | 卡片是"容器"，统一一档 |
| `AlertDialog` / 自定义对话框 / 引导浮层 | 8 / 12 | `md` 16 | 与容器同档 |
| 输入框（`OutlineInputBorder`） | 4 | `sm` 8 | 与按钮/菜单同档 |
| composer 大卡 | 14 | `md` 16 | 已是最大件，跟随容器 |
| `FilledButton` | `StadiumBorder` | **不变** | 已经是胶囊，改 8 反而变方 |
| `ElevatedButton` / `OutlinedButton` / `TextButton` | 4 | `sm` 8 | 桌面观感，不做全胶囊 |
| `PopupMenu` / `SnackBar` / `Tooltip` | 4 | `sm` 8 | 浮层控件统一 |
| `Checkbox` | 1 | `xs` 6 | 小控件，不要胶囊 |
| `Chip` / `Switch` | `StadiumBorder` | **不变** | 已最圆 |
| 状态/计数/超时/估算徽标 | 4 / 9 | `pill` | 小件胶囊化是"更多圆角"的主要观感来源 |
| 面板 chip（右栏窗口） | 6 | `sm` 8 | 与按钮同档 |
| picker 格 / 服务卡 / 插件条目 / 团队卡 | 8 / 10 | `md` 16 | 与卡片同档 |
| 工具行 / 思考行 / 折叠行 / 代码块 / 结果块 / 预览块 / 子任务行 | 6 | `sm` 8 | 密集列表内不叠加过大半径 |
| 附件缩略图 / 文件卡 / 消息高亮块 | 8 / 10 | `md` 16 | 内容容器 |
| 用户气泡 / 内联提问卡 | 12 | `md` 16 | 消息流主视觉 |
| 右栏 pill / 终端回滚胶囊 / 子 agent 切换器 | 10 / 14 | `pill` | 语义就是胶囊 |
| 进度条 / 上下文条 / 滚动条 | 2 / 3 / 8 | `pill` | 高 3~6px，只有胶囊才不会露出方角 |
| 骨架屏占位块 | 5 / 10 | `md` 16 | 与卡片一致 |
| 圆形控件 / 欢迎 HUD 线 / 停止键内方块 | circle / `height/2` / `size*0.09` | **不变** | 形状本身不是圆角问题 |

#### 3.2.1 D2「2px 微圆角」到底指哪些控件（代码定位）

上一轮 D2 的措辞（侧栏/分栏/终端体/文件树体/tab 条）是口语化的，容易和"栏内卡片"混淆。逐项钉到代码：

| D2 里的词 | 具体对象 | 代码定位 | 2px 口径 |
|---|---|---|---|
| 侧栏 | 活动栏列背景（48px 常驻列） | [main_page.dart:1380-1383](../../plugins/tree.ui.default/lib/ui/pages/main_page.dart#L1380-L1383) | 列背景 `xxs` 2；**栏内的项/卡片仍各自圆角** |
| | 左 / 中 / 右栏的列容器 | [main_page.dart:1314-1350](../../plugins/tree.ui.default/lib/ui/pages/main_page.dart#L1314-L1350)（`_buildSidebar`）、[right_panel_host.dart:251-262](../../plugins/tree.ui.default/lib/ui/widgets/right_panel_host.dart#L251-L262) | 列底 `xxs` 2；不改 `ClipRect` 裁剪结构 |
| | 折叠后的 40px 窄条 | [main_page.dart:1866](../../plugins/tree.ui.default/lib/ui/pages/main_page.dart#L1866)、[:1923](../../plugins/tree.ui.default/lib/ui/pages/main_page.dart#L1923) | 窄条底 `xxs` 2 |
| 分栏 | 主三栏的可拖分隔条（6px 命中区、1px 线） | [main_page.dart:2013-2086](../../plugins/tree.ui.default/lib/ui/pages/main_page.dart#L2013-L2086)（`Container(width: 6)` 在 [:2083](../../plugins/tree.ui.default/lib/ui/pages/main_page.dart#L2083)） | 线容器 `xxs` 2；1px 线视觉上等价于线 |
| | 文件查看器左右分屏的分隔条（7px 命中区、1px 线） | [split_panes.dart:60-77](../../plugins/tree.ui.default/lib/ui/widgets/split_panes.dart#L60-L77)、[:109-118](../../plugins/tree.ui.default/lib/ui/widgets/split_panes.dart#L109-L118) | 同上 |
| 终端体 | 终端面板根容器（整块面板底） | [terminal_panel.dart:749-750](../../plugins/tree.ui.default/lib/ui/widgets/terminal_panel.dart#L749-L750)（`Container(color: cs.surface)`） | 面板底 `xxs` 2 |
| 文件树体 | 文件树**内容区**（根 `Column` + 行列表） | [file_tree.dart:539-545](../../plugins/tree.ui.default/lib/ui/widgets/file_tree.dart#L539-L545)、[:656-693](../../plugins/tree.ui.default/lib/ui/widgets/file_tree.dart#L656-L693) | 它**没有自绘背景容器**；行背景按 §3.5 用 `xs` 6 |
| tab 条 | 查看器上方的 tab 条（不再横跨目录） | [file_panel.dart:493-576](../../plugins/tree.ui.default/lib/ui/widgets/file_panel.dart#L493-L576)（`height: 28`）、tab 项 [:647-750](../../plugins/tree.ui.default/lib/ui/widgets/file_panel.dart#L647-L750) | 不铺底色；**tab 项仍保持扁平矩形**（不变量 16 ⑪） |
| | 右栏窗口 chip 行（条本身） | [right_panel_host.dart:274-335](../../plugins/tree.ui.default/lib/ui/widgets/right_panel_host.dart#L274-L335)（`height: 34`） | 保留 surface，圆角 8；**条内 chip 照常 6→8**（§3.2） |

一句话：D2 的"2px"只给**整栏/整条的底色**收边，不切内容；栏内的卡片、chip、输入框、消息气泡一律按 §3.2 变圆（容器 16 / 控件 8 / 微件 6）。文件树是唯一例外——它的"体"没有背景，新增圆角落在**行背景**上（§3.5）。

### 3.3 主题级改动（一处改、全量生效）

文件：[app_theme.dart](../../plugins/tree.ui.default/lib/ui/app_theme.dart) 的 `light()` 与 `dark()` 两份并改。

| 主题块 | 行号 | 改动 |
|---|---|---|
| `inputDecorationTheme` | 浅 97-104 / 深 169-176 | `enabledBorder` / `focusedBorder` 的 `OutlineInputBorder` 补 `borderRadius: BorderRadius.circular(AppRadius.sm)` |
| `cardTheme` | 浅 106-112 / 深 177-183 | 8 → `AppRadius.md` |
| `dialogTheme` | 浅 113-119 / 深 184-190 | 8 → `AppRadius.md` |
| 新增 `elevatedButtonTheme` / `outlinedButtonTheme` / `textButtonTheme` | — | `shape: RoundedRectangleBorder(AppRadius.sm)`；**不配 `filledButtonTheme`**（保持胶囊） |
| 新增 `popupMenuTheme` | — | `shape: RoundedRectangleBorder(AppRadius.sm)` |
| 新增 `snackBarTheme` | — | `shape: RoundedRectangleBorder(AppRadius.sm)`；`behavior` 不动 |
| 新增 `tooltipTheme` | — | `decoration: BoxDecoration(color: Colors.grey[700], borderRadius: AppRadius.sm)`；只补圆角，颜色沿用 M2 默认灰 |
| 新增 `checkboxTheme` | — | `shape: RoundedRectangleBorder(AppRadius.xs)` |
| 新增 `scrollbarTheme` | — | `radius: Radius.circular(AppRadius.pill)`（`ScrollbarThemeData.radius` 在 3.47.5 可用） |
| `chipTheme` | — | 显式 `shape: StadiumBorder()`（与现默认一致，防未来切 M3 漂移） |

注意：`ThemeData` 里新增 button/menu/snackbar 主题时，浅深两份必须成对加，否则切换主题会"一半圆一半方"。`useMaterial3` 保持 `false`。

### 3.4 组件层迁移（机械替换）

按 §3.2 替换 36 个文件里的字面值；**成对出现的 `Material`/`InkWell` 必须同时替换**。优先顺序（按可见度）：

1. 高频骨架面：`message_list.dart`（18 处）、`right_panel_host.dart`（11 处）、`plugin_panel.dart`（18 处）、`message_input.dart`（6 处）。
2. 设置/插件/文件：`settings_page.dart`（4 处）、`plugin_detail_page.dart`、`file_viewer.dart`、`file_panel.dart`、`mcp_config_panel.dart`。
3. 其余面板按 §9 附录逐文件替换。

`ClipRRect` 站点（[attachment_preview.dart:235](../../plugins/tree.ui.default/lib/ui/widgets/attachment_preview.dart#L235)、[download_panel.dart:198](../../plugins/tree.ui.default/lib/ui/widgets/download_panel.dart#L198)、[message_panel.dart:2463](../../plugins/tree.ui.default/lib/ui/widgets/message_panel.dart#L2463)）只用于裁内容，半径必须与外部容器一致；不要给带 `elevation` 的卡片套 `ClipRRect`（会裁掉阴影）。

### 3.5 新增圆角面（"更多" 的增量）

| 表面 | 实现口径 | 风险 |
|---|---|---|
| 文件树行 hover/选中 | **保留 `ColoredBox` 类型**，外面套 `Padding(horizontal: 4) → ClipRRect(AppRadius.xs) → ColoredBox(key: rowBackgroundKey)`；行高不变 | 测试按 `ColoredBox` 类型取 widget（[file_tree_explorer_test.dart:122](../../plugins/tree.ui.default/test/file_tree_explorer_test.dart#L122)），换类型会红 |
| Agent 列表选中行 | 外边距 `EdgeInsets.symmetric(horizontal: 4, vertical: 2)` + `AppRadius.sm`；4px 团队色条保留为行首子块（不再用 `border.left`，避免被圆角切角） | 测试未断言 decoration 类型，安全 |
| 活动栏项 | `InkWell(borderRadius: AppRadius.sm)` + 左右 3px 内缩；2px 选中指示条保留 | 只影响水波纹与 hover，无逻辑改动 |
| 下载 / 用量行 hover | 有 hover 底色的行统一 `AppRadius.xs` | 低 |

### 3.5.1 文件面板三层头部紧凑化（2026-11-10 追加）

用户截图反馈：「这一块占高太多且全是矩形，视觉效果不佳」。该区域是右侧「文件」窗口的三层头部，
原合计 **44 + 32 + 30 = 106px**。压紧到 **34 + 28 + 26 = 88px**，并去掉两条整条底色：

| 行 | 原高 | 现高 | 底色 / 圆角 |
|---|---|---|---|
| 右栏窗口 chip 行（`right_panel_host.dart`） | 44 | **34** | 保留 `surface`，整条圆角 8；chip 垂直内边距 6→4 |
| 查看器 tab 条（`file_panel.dart`） | 32 | **28** | 只在右侧查看器上方（不横跨目录）；不铺底色；tab 项仍扁平 |
| 根目录头部（`file_tree.dart`） | 30 | **26** | **去掉整条底色**；与顶栏共用表面 |
| 头部图标键 | 26×26 / 内边距 4 | **22×22 / 内边距 2** | 文件树与查看器工具条同口径 |

效果：少两条横贯全宽的矩形带，头部高度 −18px；窗口 chip 行成为唯一有底色的条。
测试：`right_panel_host_test`、`file_editor_test`、`file_tree_explorer_test`、`file_tree_viewer_sync_test`、
`main_page_sidebar_width_test` 全绿；`flutter analyze lib` 零告警。

### 3.5.2 tab 归属编辑器组（2026-11-10 追加）

用户：「IDE 的 tab 一般不会放到目录那行上」。据此把 tab 从**面板级顶栏**搬到**查看器上方**：

| 位置 | 之前 | 现在 |
|---|---|---|
| 文件 tab 条 | 横跨整块面板（树 + 查看器） | **只在右格查看器上方**（`_buildViewerArea`） |
| 目录树头部 | 被 tab 条压住 | 独立「根目录」头（26px），始终在左格顶部 |
| 面板级全宽顶栏 | 28px，装 tab + 全部动作 | **删除** |
| 工作空间动作（重置提示词 / Spec、同步） | 面板顶栏 | 目录树头部右侧（`FileTree.trailingActions`，22×22） |
| 视图动作（收起目录 / 分屏 / 关闭查看器） | 面板顶栏 | 查看器 tab 条右侧 |

文件打开时的头部结构：窗口 chip 行 34 → 左格 `根目录` 头 26 + 树；右格 tab 条 28 + 查看器。
文件 tab 仍是扁平矩形（不变量 16 ⑪）；`file-tab-*` / `关闭查看器` / `收起文件树` 等 key 与 tooltip 不变。

**tab 溢出（2026-11-10 追加）**：tab 条底部常显滑块（`file-tab-scrollbar`，thickness 4、胶囊），
滚轮落在 tab 条上把竖直增量转成横向滚动；打开 / 切到远处的 tab 用 `Scrollable.ensureVisible`
自动滚入视野（`duration: Duration.zero`，不做额外动画）。回归测试：`file_editor_test`
的「tab 多到装不下：底部常显滑块，新 tab 自动滚进视野」。
测试：`file_editor_test`、`file_tree_viewer_sync_test`、`file_tree_explorer_test`、`right_panel_host_test`、
`main_page_sidebar_width_test` 全绿。

### 3.6 不做

- 栏级表面、分隔条与文件 tab 条本身**只给 2px 收边**（逐项代码定位见 §3.2.1），不做大圆角；栏内卡片/控件照常变圆，文件树行背景是例外（§3.5）。
- 不改文件 tab **项**的外形（§1.6 ①）。
- 不改圆形控件与欢迎字标 HUD 线。
- 不加阴影、不加描边宽度、不改配色、不做动画（圆角是纯几何变化）。
- 不引入第三方圆角/主题包；不切 `useMaterial3`。
- 不做 golden 测试（本期只做常量与主题断言 + 手动矩阵，见 D9）。

---

## 4. 执行切片

版本线：UI 插件 `1.0.6+1` → 实施后 `1.0.7+1`（`plugins/tree.ui.default/pubspec.yaml`；`plugin.json.version` 由打包脚本生成，不手改）。
门禁（每片都跑，cwd = `plugins/tree.ui.default`）：`flutter analyze lib test` 零告警 → `flutter test` 全绿。UI 插件零 path 依赖，不触发核心/协议闸门。

### S1 令牌 + 主题层

- 文件：新增 `lib/ui/app_radius.dart`（`AppRadius` 五档）、[app_theme.dart](../../plugins/tree.ui.default/lib/ui/app_theme.dart)（改 Card/Dialog/Input；新增按钮/菜单/SnackBar/Tooltip/Checkbox/Scrollbar/Chip 主题）、[main.dart:444](../../plugins/tree.ui.default/lib/main.dart#L444)（兜底框 16）。
- 测试：新增 `test/theme_radius_test.dart`：
  1. `AppRadius` 五档数值固定（2/6/8/16/999）；
  2. 深浅两套的 `cardTheme.shape` / `dialogTheme.shape` / `inputDecorationTheme.enabledBorder.borderRadius` / 三翼按钮 shape / `popupMenuTheme.shape` / `snackBarTheme.shape` / `checkboxTheme.shape` / `scrollbarTheme.radius` 均等于对应常量；
  3. `filledButtonTheme` 为空（保持 `StadiumBorder`），`chipTheme.shape is StadiumBorder`。
- 手动：打开设置页、任意对话框、输入框、菜单、SnackBar、Tooltip，确认圆角变大且深浅一致。

### S2 组件层机械迁移

- 文件：§9 附录中除 `app_theme.dart` / `main.dart` 外的全部站点。
- 动作：按 §3.2 替换；`Material` + `InkWell` 成对改；`ClipRRect` 与容器同步；`pill` 站点统一用 `BorderRadius.circular(AppRadius.pill)`。
- 测试：既有测试应全绿（唯一圆角断言是 [message_stream_style_test.dart:94](../../plugins/tree.ui.default/test/message_stream_style_test.dart#L94) 的 `isNotNull` 与 [welcome_mark_test.dart:70](../../plugins/tree.ui.default/test/welcome_mark_test.dart#L70)）；顺手把气泡断言收紧为 `AppRadius.md`。
- 手动：消息流、右栏 12 个窗口、插件面板/详情、文件查看器、团队页、MCP、终端各扫一遍。

### S3 新增圆角面

- 文件：[file_tree.dart](../../plugins/tree.ui.default/lib/ui/widgets/file_tree.dart#L804-L812)、[agent_list_item.dart](../../plugins/tree.ui.default/lib/ui/widgets/agent_list_item.dart#L42-L48)、[activity_bar_item.dart](../../plugins/tree.ui.default/lib/ui/widgets/activity_bar_item.dart#L39-L62)。
- 动作：§3.5 全部；文件树必须保留 `ColoredBox` 作为被 key 命中的控件。
- 测试：`file_tree_explorer_test.dart` 预期不改（按 key 取 `ColoredBox` 仍成立）；若有 hover 位置断言，需要按新内缩修正坐标。
- 手动：文件树 hover/选中、Agent 列表切换、活动栏 hover，确认圆角底不越界、不抖行高。

### S4 收尾

- `lib/README.md`：补一条"圆角尺子"不变量（2/6/8/16/999、哪些面只 2px、文件 tab 项与圆形控件例外）；同步不变量 11 的气泡圆角描述。
- `docs/README.md` 索引：本片落档时已加；`docs/work-log.md` 每片完成各加一行。
- 版本号**本期不 bump**：车道 D 正待发布 `1.0.6`（产物已出），先动源码版本会让资产与源码错位；下一次发版窗口统一按车道 D 的口径升版。

---

## 5. 验收清单

手动（真机 Windows，UI 插件开发模式；深/浅两套各一遍）：

1. 设置页：卡片、输入框、对话框圆角一致；色板小方块为微圆角。
2. 消息流：用户气泡 16、模型高亮块 16、内联提问卡 16；工具/思考行 8；骨架屏与卡片同档。
3. composer：大卡 16；发送键仍是圆；拖拽提示 16；展开/收起不出现裁切。
4. 右栏：窗口 chip 8、picker 格 16、窗口内卡片 16；右栏从 720 拖到 240、再折叠中栏，均不横向溢出。
5. 插件面板/详情/编辑器：页签 8、搜索框 8、条目 16、pill 全胶囊。
6. 文件：预览块 8、附件卡 16、tab 项仍是**扁平矩形**、tab 关闭键水波纹不溢出。
7. 文件树：hover/选中为 6 圆角、左右 4px 内缩；行高与文字基线不动；长路径省略号不裁切。
8. Agent 列表：选中底 8 圆角，4px 团队色条仍在行首；悬停/选中切换不抖动。
9. 活动栏：hover 与选中为 8 圆角底，2px 指示条保留。
10. 对话框：`AlertDialog` 16、引导浮层 16、Spec 卡 16；贴边内容不被圆角裁掉。
11. 菜单 / SnackBar / Tooltip / Checkbox / Scrollbar：分别为 8 / 8 / 8 / 6 / 胶囊；滚动条在 4px 厚下是胶囊。
12. 徽标类（未读、待处理、超时、估算、状态）全部胶囊，不被文字撑破。
13. 进度条/上下文条为胶囊；3px 高度下无方角。
14. 窄窗口（1100、右栏 240）与文字缩放 80%~150%：无 overflow、无双层圆角错位。
15. 深/浅两套无"一半圆一半方"；切主题后所有新增主题块都生效。
16. 骨架面（侧栏列底、分隔条、终端底、文件 tab 条）为 **2px 微圆角**，贴窗口边缘不露底、不切内容；圆形控件仍为圆。
17. 右侧「文件」窗口：窗口 chip 行 34；文件打开时左格「根目录」头 26、右格 tab 条 28；**tab 不横跨目录**；工作空间动作在目录头右侧；面板级全宽顶栏已不存在。
18. tab 多到装不下时底部有常显滑块，滚轮可横向翻，新打开 / 切到的 tab 自动滚入视野。

自动化：`flutter analyze lib test` 零告警；`flutter test` 全绿（含新增 `theme_radius_test.dart`）。

---

## 6. 风险与回滚

| 风险 | 说明 | 处置 |
|---|---|---|
| 圆角过大伤信息密度 | 卡片/对话框 16 在 240px 右栏/小对话框里可能显胖 | 半径只加在表面，不额外加内外边距；S1 先看真机，必要时只改 `AppRadius.md` 一个常量降档 |
| 水波纹溢出 | `Material`/`InkWell` 半径不同步 | 成对替换；验收第 6/8/9 条逐一手点 |
| `ClipRRect` 裁阴影/裁内容 | 带 `elevation` 的卡片套 `ClipRRect` 会丢阴影 | 卡片用 `shape`，`ClipRRect` 只包图片/进度条/纯色底 |
| 文件树测试撞类型 | 测试按 `ColoredBox` 取 widget | 保留 `ColoredBox`，外层套 `Padding + ClipRRect`（§3.5） |
| 文件 tab 口径冲突 | README 不变量 16 ⑪ 明确"不再是圆角胶囊" | tab **项**保持扁平；只给 tab 条底 2px、关闭键水波纹 6 |
| `FilledButton` 被误改方 | 它默认是 `StadiumBorder` | 不配 `filledButtonTheme`；S1 测试显式断言 |
| 主题块漏配 | 只配深色或只配浅色 | 测试对 `AppTheme.light/dark` 双份断言 |
| 无 golden 测试 | 视觉回归不可自动化 | 手动矩阵（§5 16 条）+ 单元断言半径取值 |
| 回滚 | — | S1~S4 各自独立提交，按片 revert；S1 单独回滚即恢复全部主题默认值 |

---

## 7. 待拍板（附推荐默认，实施时按"默认口径"直接推；用户另行指示则以其为准）

| # | 决策 | 推荐口径 | 备选 |
|---|---|---|---|
| D1 | 令牌归属 | **新建 `lib/ui/app_radius.dart`**（纯常量；34 个 widget 只依赖令牌文件） | 并入 `app_theme.dart`（少一个文件，但 widget 需 import 主题/`theme_service`） |
| D2 | 骨架面圆角 | **2px 微圆角**（`xxs`）：活动栏列背景、左/中/右栏列容器、折叠窄条、三栏与分屏分隔条、终端面板底、文件 tab 条与右栏 chip 行条本身（逐项定位见 §3.2.1）；活动栏项、栏内卡片、文件树行背景仍按 §3.2/§3.5 变圆 | 保持 0（用户 2026-11-10 已否决）/ 整体大圆角（裁切与密度风险高） |
| D3 | 三档主值 | **卡片 16 / 对话框 16 / 输入 8** | 卡片 12 / 对话框 12 / 输入 6（更保守） |
| D4 | 按钮 | **`FilledButton` 保持胶囊；三翼按钮 8** | 全部 8（会把胶囊改方）/ 全部胶囊（偏离桌面观感） |
| D5 | 徽标/进度条/滚动条 | **全部胶囊（999）** | 徽标 6、进度条 4 |
| D6 | 是否新增圆角面 | **做**：文件树行、Agent 行、活动栏（§3.5） | 只改已有圆角，不新增 |
| D7 | 五档数值 | **2 / 6 / 8 / 16 / 999**（2026-11-10 用户定稿） | 6 / 8 / 12 / 16 / 999（骨架仍留直角）/ 8 / 12 / 16 / 20 / 999（更激进） |
| D8 | 迁移范围 | **一次性全量 36 文件**（机械替换 + 手动矩阵） | 只改主题层与高频面，其余后续 |
| D9 | 视觉回归方式 | **本期不做 golden**（单元断言 + 手动矩阵） | 引入 golden 测试（需先解决字体/缩放稳定性） |

---

## 8. 关键文件地图（实施只碰这些）

| 文件 | 改动 |
|---|---|
| `plugins/tree.ui.default/lib/ui/app_radius.dart` | S1：新增，五档常量 |
| `plugins/tree.ui.default/lib/ui/app_theme.dart` | S1：Card/Dialog/Input + 新增 7 个主题块 |
| `plugins/tree.ui.default/lib/main.dart` | S1：兜底错误框 8 → 16 |
| `plugins/tree.ui.default/lib/ui/widgets/message_list.dart` | S2：气泡/高亮/提问卡/骨架 16、附件/工具行 8、滚动条胶囊 |
| `plugins/tree.ui.default/lib/ui/widgets/message_input.dart` | S2：composer 16、拖拽提示 16 |
| `plugins/tree.ui.default/lib/ui/widgets/right_panel_host.dart` | S2：chip 8 / 关闭键 6 / picker 16 / 滚动条胶囊 |
| `plugins/tree.ui.default/lib/ui/widgets/plugin_panel.dart`、`plugin_detail_page.dart`、`plugin_editor_dialog.dart` | S2：页签/搜索 8、卡片 16、pill 胶囊 |
| `plugins/tree.ui.default/lib/ui/widgets/file_viewer.dart`、`file_panel.dart`、`attachment_preview.dart`、`download_panel.dart` | S2：预览 8、附件 16、tab 关闭键 6、进度条胶囊 |
| `plugins/tree.ui.default/lib/ui/pages/settings_page.dart` | S2：徽标胶囊、色板 6 |
| `plugins/tree.ui.default/lib/ui/widgets/{teammates_window_page,mcp_config_panel,model_info_panel,session_picker,terminal_panel,hook_notice_card,tool_call_card,thinking_card,collapsed_run_row,tool_runs_panel,usage_calls_panel,subagent_process_list,subagent_view_switcher,question_panel,spec_panel,onboarding_guide,core_log_viewer_dialog,create_agent_dialog}.dart` | S2：按 §3.2 映射 |
| `plugins/tree.ui.default/lib/ui/widgets/file_tree.dart`、`agent_list_item.dart`、`activity_bar_item.dart` | S3：新增圆角面 |
| `plugins/tree.ui.default/lib/README.md` | S4：圆角尺子不变量 + 不变量 11 气泡描述 |
| `plugins/tree.ui.default/test/theme_radius_test.dart` | S1：新增 |
| `plugins/tree.ui.default/pubspec.yaml` | S4：`1.0.7+1` |

---

## 9. 附录：全量站点（按文件，供实施勾选）

> 口径：`BorderRadius.circular` 的现行值与目标档；`Circle` 表示圆形控件（不改）。

| 文件 | 站点（行 → 组件） | 现值 → 目标 |
|---|---|---|
| `ui/app_theme.dart` | 108-112 / 179-183（Card 深浅）；115-119 / 186-190（Dialog 深浅） | Card 8 → 16；Dialog 8 → 16 |
| `main.dart` | 444（兜底错误框） | 8 → 16 |
| `ui/pages/settings_page.dart` | 1847（类型徽标）；2969（色板） | 4 → pill；4 → xs |
| `ui/widgets/agent_list_item.dart` | 117（计数徽标） | 9 → pill |
| `ui/widgets/attachment_preview.dart` | 219 / 236 / 302（缩略图/裁切/文件卡）；279/282 | 8 → 16；Circle |
| `ui/widgets/collapsed_run_row.dart` | 73 / 75（行 + hover） | 6 → 8 |
| `ui/widgets/core_log_viewer_dialog.dart` | 174（日志体） | 4 → 8 |
| `ui/widgets/create_agent_dialog.dart` | 334（模型下拉） | 6 → 8 |
| `ui/widgets/download_panel.dart` | 199（进度条 ClipRRect） | 2 → pill |
| `ui/widgets/file_panel.dart` | 735（tab 关闭键水波纹） | 9 → xs |
| `ui/widgets/file_viewer.dart` | 1241 / 1270 / 1379（Markdown/SVG/不支持） | 6 → 8 |
| `ui/widgets/hook_notice_card.dart` | 104 / 202 / 228 / 251（卡/壳/复制/代码） | 6→8；10→16；4→xs；6→8 |
| `ui/widgets/mcp_config_panel.dart` | 443 / 606 / 641（表单/服务卡/代码） | 8→16；8→16；4→8 |
| `ui/widgets/message_input.dart` | 535（composer）；743（拖拽提示）；707/709 | 14→16；10→16；Circle |
| `ui/widgets/message_list.dart` | 1009（占位）；1202（高亮）；1320（骨架）；1613（气泡）；1754/1756（复制）；1824（附件）；1965（提问卡）；1339/1341 | 5→16；10→16；10→16；12→16；6→8；6→16；12→16；Circle |
| `ui/widgets/message_panel.dart` | 2464（上下文条）；2997（子 agent 视图）；3084 | 2→pill；8→16；Circle |
| `ui/widgets/message_scrollbar.dart` | 314 / 329（滚动条） | 3 → pill |
| `ui/widgets/model_info_panel.dart` | 872（信息卡） | 8 → 16 |
| `ui/widgets/onboarding_guide.dart` | 51-52（引导浮层） | 12 → 16 |
| `ui/widgets/plugin_detail_page.dart` | 111（详情容器） | 8 → 16 |
| `ui/widgets/plugin_editor_dialog.dart` | 497（提示块） | 6 → 8 |
| `ui/widgets/plugin_panel.dart` | 1025（页签）；1094（搜索）；1107/1255/1623/1726/1992（卡片）；2111（pill）；906 | 8→8；8→8；8→16；10→pill；Circle |
| `ui/widgets/question_panel.dart` | 396-397（提问卡）；505（状态徽标） | 8 → 16；4 → pill |
| `ui/widgets/right_panel_host.dart` | 292（滚动条）；374/377（chip）；404（关闭键）；511/514（picker） | 2→pill；6→8；4→xs；8→16 |
| `ui/widgets/session_picker.dart` | 260（下拉浮层）；391（行） | 8 → 16；6 → 8 |
| `ui/widgets/spec_panel.dart` | 224-225（Spec 卡）；257 / 395（小徽标）；438（容器） | 12→16；4→pill；8→16 |
| `ui/widgets/stop_button.dart` | 32/34（圆）；45（内方块） | Circle；不变 |
| `ui/widgets/subagent_process_list.dart` | 68（行） | 6 → 8 |
| `ui/widgets/subagent_view_switcher.dart` | 114（切换器）；203 | 14 → pill；Circle |
| `ui/widgets/teammates_window_page.dart` | 238（提示条）；287（Leader）；343-344（成员卡）；976（模型页容器）；418/913 | 8→16；10→16；12→16；8→16；Circle |
| `ui/widgets/terminal_panel.dart` | 903 / 909（回滚胶囊） | 10 → pill |
| `ui/widgets/thinking_card.dart` | 48 / 50（行 + hover） | 6 → 8 |
| `ui/widgets/tool_call_card.dart` | 57/59（行）；876（结果）；1199（代码） | 6 → 8 |
| `ui/widgets/tool_runs_panel.dart` | 386/394（行）；438（超时徽标） | 6→8；4→pill |
| `ui/widgets/usage_calls_panel.dart` | 347（估算徽标） | 4 → pill |
| `ui/widgets/welcome_mark.dart` | 103（HUD 线） | `height/2` 不变 |

> 合计 36 文件、108 行、84 处 `BorderRadius.circular`；实施时按上表逐行勾选，避免漏改成对半径。
