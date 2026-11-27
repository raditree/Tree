# 消息渲染重写计划（纯文本 / 自研 Markdown / 自研 LaTeX）

> 用户 2026-11-26 提出。目标：**取消工具卡片与内容卡片**，中栏改成一套自研的
> "纯文本 + 轻交互"渲染；Markdown 与 LaTeX 都由本仓自研（不再走
> `flutter_markdown_plus`），并要求**跨行框选**可用。
>
> 本文件是执行依据。每期独立提交、独立出安装包真机验收（沿用 SCROLL-FIX 的 D4）。

## 1. 用户拍板（2026-11-26）

| # | 决定 |
| --- | --- |
| R-D1 | 工具行 = 「工具**标识** 工具名 关键内容 >」（对标现在的工具卡片，不是厂商品牌）；行首标识保留图标 + 中文短名 |
| R-D2 | **用户消息保留轻量底色**（与 agent 区分）；**代码块保留浅底 + 等宽**，只去掉「复制」按钮与卡片边框 |
| R-D3 | 自研 Markdown **先换中栏对话**（消息 / 思考 / 提问 / 系统提示）；**文件预览下一期**再换，届时才删 `flutter_markdown_plus` |
| R-D4 | LaTeX 首批：**上下标 + 希腊字母 + 分式 + 根号 + 求和/积分**；行内塞小字、块级单独一行；代码块内不渲染 |
| R-D5 | 折叠行文案沿用现有中文短名（读取 / 写入 / 编辑 / 运行命令 / 提问 …）；**思考不参与类别归并**，固定以 `思考×n` 追加在末尾 |
| R-D6 | 「系统提示」= 现有 `kind=notice`；「半途消息」= 工具组之间的 assistant 文本段（**不显示气泡**，只作时间线文本） |
| R-D7 | **视觉优先**：行内公式可以用 `WidgetSpan` 做上下标排版，接受它本身不可选 |
| R-D8 | 节奏沿用 SCROLL-FIX：M1 引擎/纯文本/折叠行 → M2 交互 → M3 LaTeX → M4 表格与链接，**每期一个安装包** |

## 2. 目标形态（用户给的样子）

折叠组收起：

```
运行命令×12 · 编辑×8 · 读取×3 · 思考×13 >
```

点开（向下展开、行尾 `>` 变 `V`，组员带一条竖线缩进）：

```
运行命令×12 · 编辑×8 · 读取×3 · 思考×13 V
│ read  docs/scroll-jitter-fix-plan.md >
│ bash  flutter test -r compact >
│ 思考 为什么探针要逐帧采样… >
```

完整时间线（用户示例的骨架）：

```
<用户输入>
│ 运行命令×12 · 编辑×8 · 读取×3 · 思考×13 >
│ <半途消息：assistant 文本段，无气泡>
│ 运行命令×12 · 编辑×8 · 读取×3 · 思考×13 >
│ 系统提示 V
│ │ <content>
│ 运行命令×22 · 编辑×18 · 读取×53 · 思考×113 >
│ 请回答 n 个问题 V
│ │ 1. <Q1 content> V
│ │ │ <Option A>
│ │ │ <Option B>
│ │ │ 输入：
│ │ 2. …
│ 运行命令×1 · 编辑×1 · 读取×3 · 思考×1 V
│ │ read  docs/…  >
│ <最终消息>
```

口径要点：
- 竖线 `│` 是**层级缩进**（视觉时间线），不是 markdown 引用；只画在当前层的左侧；
- 每行行尾 `>` = 可点开（进右栏详情），`V` = 已展开（就地摊开子项）；
- 悬停整行高亮（`hoverColor`），不加底色块、不加边框。

## 3. 现状与要改的文件

| 文件 | 现在 | 改造 |
| --- | --- | --- |
| `lib/ui/widgets/message_cards.dart`(917) | `_MessageBubble`（卡片底 + 揭示时钟）+ `_AgentTurnHeader` + `_AskQuestionCard` | 去卡片底；正文换自研 markdown；揭示时钟保留 |
| `lib/ui/widgets/tool_call_card.dart`(1195) | 一行式 `ToolCallCard` + `ToolStyle` + 右侧 `ToolDetail` | 行渲染改纯文本口径；`ToolDetail`（右栏）**行为不变** |
| `lib/ui/widgets/thinking_card.dart`(304) | 一行式 `ThinkingCard` + `ThinkingDetail`（分块定居） | 行渲染改纯文本；`ThinkingDetail` 换自研 markdown（分块定居逻辑保留） |
| `lib/ui/widgets/collapsed_run_row.dart`(98) | 「折叠 n 次工具调用（…），点击展开 ›」 | 改成 `运行命令×12 · 编辑×8 · 读取×3 · 思考×13 >` |
| `lib/ui/widgets/message_list.dart`(1281) | `_buildItem` 按 kind 分派 + 折叠组 run 计算 | 分派改成"时间线行"；组内行加竖线缩进 |
| `lib/ui/widgets/markdown_view.dart`(561) | `flutter_markdown_plus` + 路径语法 + 代码块卡 | **新增自研引擎**；本文件先给中栏用（M1），文件预览暂留旧实现（M4 后删） |
| `lib/ui/widgets/hook_notice_card.dart` | 通知卡 | 改「系统提示 V」可折叠块 |
| 新增 `lib/ui/text/` | — | 自研引擎：block/inline 解析、RichText 渲染、LaTeX（M3） |

依赖：`flutter_markdown_plus` / `markdown` 在 M4 之后才能从 `pubspec.yaml` 删。

## 4. 自研 Markdown 引擎（M1）

### 4.1 结构

```
lib/ui/text/markdown/
  ast.dart        // MdDocument / MdBlock / MdInline（不可变、可 == 比较，便于 memo）
  block_parser.dart // 行扫描 → 块序列；主题无关、纯函数、可单测
  inline_parser.dart// 行内 → 内联序列（`code`、**strong**、*em*、~~del~~、[text](href)、$latex$）
  render.dart     // MdBlock → Widget（Text.rich / Table / 代码块）
  styles.dart     // 每份 ThemeData 一套样式（沿用 markdown_view.dart 的 Expando 缓存口径）
```

### 4.2 首批块（用户点名的 9 项）

| # | 语法 | M1 | 说明 |
| --- | --- | --- | --- |
| 1 | ` ``` ` 围栏代码块 | ✅ | 等宽 + 浅底 + 语言标签，**无复制按钮**（R-D2） |
| 2 | `` ` `` 行内代码 | ✅ | `TextSpan` + 浅底（可选中） |
| 3 | 行首 `>` 引用 | ✅ | 左侧一条竖线 + 弱化色 |
| 4 | `#`~`######` 标题 | ✅ | 六级字号阶梯，上间距收一档 |
| 5 | `-` / `*` 无序列表 | ✅ | 支持一层缩进嵌套（最多 2 层） |
| 6 | `1.` 有序列表 | ✅ | 序号按块重算 |
| 7 | `---` 分隔线 | ✅ | 1px `outlineVariant` |
| 8 | `[](file_path)` 链接 | **M4** | M1 先按普通文本 + 弱色显示，不点击 |
| 9 | 表格 | **M4** | M1 按段落原样显示（管道符保留） |

额外（不在 9 项里、但模型输出天天用，M1 一并做）：`**strong**`、`*em*`、
`~~del~~`、`![alt](src)`（M1 只显示 alt 文本，不加载图片——媒体插入本期不做）。

### 4.3 红线（渲染层）

1. **不许在 `build` 里跑全文正则**：解析结果按 `(text, 主题键)` 记忆（`Expando` /
   `TextEditingDiff` 式增量），`message_list` 每帧重建不能变成每帧全文解析；
2. **不许新增 `SelectableText`**：跨行框选靠外层 `SelectionArea`，每个块都用
   `Text.rich`（`TextSpan`）参与同一棵选择树；行内公式允许 `WidgetSpan`（R-D7）；
3. **不许引入第三方渲染依赖**（不含 `flutter_markdown_plus`、`flutter_math_fork`）；
4. 代码块/表格横向滚动用 `SingleChildScrollView` + `Scrollbar`，**不挂原生滚动条**；
5. 行高必须是**可预测的**：同一段文本在不同帧解析出的块数、行数一致（滚动计划的
   探针与补白都依赖它，见 §6）。

### 4.4 性能口径（沿用现有两条经验）

- 巨型 thinking（10 万+ 字）：保留 `ThinkingDetail` 的 **6000 字定居分块**，块内解析
  只在尾块发生；
- 流式正文：`contentVersion` 增量只重建本行；解析按"已定居前缀 + 尾块"两段做，
  不对全文重解析。

## 5. 分期与验收

| 期 | 内容 | 验收 | 出包 |
| --- | --- | --- | --- |
| **M1** | 自研引擎（§4）+ 中栏纯文本化（agent 消息无卡片底、用户消息轻底）+ 工具/思考行纯文本口径 + 折叠行新文案 | `flutter analyze` 0 + 全量绿 + 新增 `test/markdown_parse_test.dart`（块/行内各 1 条 TC）+ `test/message_render_test.dart`（无 `Card`/`Container` 底色断言、折叠行文案、竖线缩进） | ✅ |
| **M2** | 交互：折叠组展开树形（`V` / `│` 缩进）、系统提示折叠块、提问块嵌套（题 → 选项）、半途消息无气泡 | `test/message_render_interaction_test.dart`（展开零位移、层级缩进、点击右栏详情不变） | ✅ |
| **M3** | 自研 LaTeX：`$…$` 行内、`$$…$$` 块级；上下标 / 希腊字母 / 分式 / 根号 / 求和积分 | `test/latex_parse_test.dart` + `test/latex_layout_test.dart`（AST 结构、行内不换行、块级居中、代码块内不渲染） | ✅ |
| **M4** | 表格渲染 + `[](path)` 可点链接 + 代码块语言标签着色；文件预览切到新引擎并删 `flutter_markdown_plus` | 表格 TC（对齐/表头底色/横向滚动）、链接 TC（工作区路径 → 右栏）、`pubspec` 删依赖后全量绿 | ✅ |

每期完成后**必须**跑一遍滚动门禁（`test/scroll_invariants_test.dart`）：行高与
块结构变化会直接改变补白/锚点，红一条就要在当期为它补 TC。

## 6. 与 SCROLL-FIX 的关系

- 行高变化 ⇒ `_measuredHeights` 缓存全部失效、补白重算：M1 落地后要重跑
  `scroll_invariants`（TC-SC-02/03/04 尤其敏感）；
- 渲染层**不许**再引入"帧后 setState 改布局"的写法（SCROLL-FIX 红线）；
- S3（底部补白一次算定）与本期独立：先做哪个都行，但同期内只动一类机制。

## 7. 已知风险

| 风险 | 处置 |
| --- | --- |
| 自研解析在长文本上比 `markdown` 包慢 | 解析结果记忆 + 定居分块；`test/markdown_parse_test.dart` 里放一条 200KB 文本的耗时基线（只记录不设门禁，口径同 TC-SC-16） |
| 表格/代码块的横向滚动与中栏纵向列表打架 | 横向滚动手势用 `SingleChildScrollView(scrollDirection: horizontal)`，不吃纵向；真机验收重点看 |
| `WidgetSpan` 破坏跨行框选（行内公式） | 已拍板视觉优先（R-D7）；选择行为退化写进本期"已知限制" |
| 移除卡片底后层级感丢失 | 用竖线 `│` + 间距 + 弱化色重建层级，M1 出包时必须真机看图 |
