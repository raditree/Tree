# 侦查落档：中栏消息列表滚动模型重写（反向列表 + 向上分页 + 锚点保持）

> 状态：**方案定稿，按切片实施**（用户 2026-11-22 拍板「按路线 2 来」）。
> 日期：2026-11-22。范围：UI 插件仓 `plugins/tree.ui.default`（中栏 `MessageList` / `MessagePanel` /
> `MessageScrollbar`），**不改核心、不改协议、不加 pub 依赖**。
> 本档替代 [conversation-sembast-and-collapse-recon.md](conversation-sembast-and-collapse-recon.md) 里
> 由「槽位表 + 全局估算」承接的那部分滚动口径；折叠（§3.2）与显示/详细两分保持原样。
> 相关不变量：[lib/README.md](../plugins/tree.ui.default/lib/README.md) 不变量 19（本档实施后重写）。

用户原话（需求锚点）：
- 2026-10-04：「上滑过程中右侧滑块跳来跳去……滑到哪加载哪，限制缓存长度，仅缓存窗口附近的消息」
- 2026-11-22：「现在不丝滑」→ 拍板路线 2：**反向 ListView + 向上分页 + 锚点保持**。

---

## 1. 现状侦查：为什么"不丝滑"

### 1.1 现行机制的七个零件

| 零件 | 坐标 | 作用 |
|---|---|---|
| 全局槽位表 `slots`（null = 88px 占位） | `message_window.dart`（已删除，替换为 `message_feed.dart`） | 按**全局下标**寻址整份会话；`place/evict/gapsFor` |
| 逐格估算 `maxScrollExtent` | [message_list.dart](../plugins/tree.ui.default/lib/ui/widgets/message_list.dart#L1535-L1606) | `_rebuildExtentPlan` + `_extentBelow` + `_measuredExtent` |
| 底部锚定控制器/位置 | [message_list.dart](../plugins/tree.ui.default/lib/ui/widgets/message_list.dart#L308-L559) | 布局期钉底、首帧贴底、`shiftAbove` 实测补偿、帧后重试 |
| 实测锚点补偿 | [message_list.dart](../plugins/tree.ui.default/lib/ui/widgets/message_list.dart#L1070-L1290) | `_builtTopsFromRenderTree` / `_resolveShiftAbove` / `_retryShift` / `_assertShiftTarget` |
| 视口坐标 → 滑块 | [message_list.dart](../plugins/tree.ui.default/lib/ui/widgets/message_list.dart#L958-L993)、[message_scrollbar.dart](../plugins/tree.ui.default/lib/ui/widgets/message_scrollbar.dart) | `rendered` 条数、`_smoothTop` 限速/反向死区 |
| 面板补页/淘汰 | [message_panel.dart](../plugins/tree.ui.default/lib/ui/widgets/message_panel.dart#L1151-L1336) | `_onWindowChanged` → `gapsFor` → `splitGapAtViewportTop` → `padAboveStamp`/`contentShiftStamp` |
| 折叠（渲染层） | 同上 `_rebuildExtentPlan` / `_runAt` / `_publishExpandedRuns` | 组员零高度，一组占多个全局下标 |

### 1.2 四个根因（不是"补偿公式还不够准"）

1. **流式路径整面板重建 + O(N) 估算**：每条 `msg_chunk` → `setState` 整个面板
   （[message_panel.dart L1519-L1554](../plugins/tree.ui.default/lib/ui/widgets/message_panel.dart#L1519-L1554)）
   → `MessageList.build` → `_rebuildExtentPlan` 对**全部槽位**分配两条长度数组并遍历
   （[L1896](../plugins/tree.ui.default/lib/ui/widgets/message_list.dart#L1896)）。N 是整份会话条数，与"这一帧变了几个字"毫无关系。
2. **`maxScrollExtent` 是外推值**：占位槽 88 + 已建段实测 + 剩余条数，估算误差 ∝ 剩余条数；
   框架在贴近边界时把 `pixels` 夹到新范围上 → 用户看到"滚到边界突然跳一下"。
3. **布局期两套真值互相抢**：框架自己的 `scrollOffsetCorrection`（`correctBy` 直改 `_pixels`）
   与我们 `correctPixels` + 帧后 `_retryShift` + `_assertShiftTarget` 叠加，必须靠
   "绝对目标 + 用户滚动量分离"来兜（[L346-L389](../plugins/tree.ui.default/lib/ui/widgets/message_list.dart#L346-L389)）。
4. **折叠破坏"下标 → 像素"线性**：组员零高度，一组占几十上百个全局下标，滑块要另算
   `rendered`，补页补偿的锚点要排除"这一帧高度变了的格子"（[L1105-L1165](../plugins/tree.ui.default/lib/ui/widgets/message_list.dart#L1105-L1165)）。

结论：这套机制每加一个场景就多一层补丁，复杂度已经超过它能带来的收益。
**EXTREME 合成滚动用例**已删除（插件仓 `3d87d8c`）——它在"假核心瞬时回包 + 固定 120px `jumpTo`"
的封闭序列里只能证明补偿公式自洽，不经过真实卡顿路径。

### 1.3 必须保住的既有价值

| # | 约束 | 新模型承接方式 |
|---|---|---|
| V1 | 滑块**长度稳定**，不随补页/淘汰跳动 | 几何只读"全局下标 + 服务器 `total`"（§2.8） |
| V2 | 跨未加载区**精确定位**（按 id / 按滑块位置，必要时先加载目标附近） | `at=` / `from=` 重锚 + 迭代落点校正（§2.7） |
| V3 | TC-COLLAPSE-01：展开/收起时**上方内容零位移** | 折叠点击的**单点**锚点校正（§2.9） |
| V4 | 首帧即底部、切 agent 不闪空、跟随/阅读两模式、回到底部 | 反向布局天然贴底（§2.3/§2.4） |
| V5 | 临时员工消息零高度、工作期底部 5 张豁免折叠、内联卡片 | 渲染层原样保留（§2.10） |
| V6 | 流式不打断阅读、阅读时不把用户拽回底部 | 脱离时冻结尾巴 + 新消息缓冲（§2.4） |

---

## 2. 新模型（路线 2）

### 2.1 不变量（实施期按编号核对）

- **I-1 单一主轴**：列表为 `ListView.builder(reverse: true)`，**局部下标 0 = 最新一条**，
  局部下标增大 = 更旧、在屏幕上更高。
- **I-2 连续窗口**：已渲染内容恒为一段**连续**的全局下标区间 `[oldest, newest]`，
  与服务器 `offset/total` 对齐；出现空洞 = 模型损坏，整窗重载自愈（不许"打洞"）。
- **I-3 向上分页零补偿**：更旧的页只追加在窗口**末尾**（tail）。追加不改变任何已布局子项的
  `childScrollOffset` ⇒ 视口像素**一个字节都不用改**。
- **I-4 跟随 = `pixels == minScrollExtent`**：反向列表的 `minScrollExtent` 恒为 0（最新端）。
  没有 `pinToBottom` / `firstFrameBottom` 这类一次性请求布尔。
- **I-5 脱离时冻结尾巴**：`pixels > 0` 期间，局部下标小于"首个可见下标"的一切变更
  （新消息、`msg_chunk`、工具进展）**不进渲染列表**，进缓冲；回到底部/点角标时一次性合并。
  可见区内部的变更照常（那是用户正看着的东西）。
- **I-6 容量上限**：已渲染行 ≤ `kMessageFeedMaxRows`（初值 2000，与显示缓存上限同源）。
  旧侧裁剪零补偿；新侧"落后裁剪"按**实测高度**精确补偿（§2.6）。
- **I-7 滑块不读 `maxScrollExtent`**：位置/长度只由全局下标与 `total` 决定。
- **I-8 补偿只允许两处**：① 折叠组展开/收起（用户点击，实测一次，§2.9）；
  ② 新侧落后裁剪（实测高度，§2.6）。分页、跟随、流式、首帧**一律不补偿**。

### 2.2 数据模型：`MessageFeed`（新文件）

```
lib/ui/services/message_feed.dart
```

职责（纯 Dart，不做 IO、不碰 Widget，单测可直接钉）：

| 成员 | 语义 |
|---|---|
| `List<ChatMessage> rows` | **最新在 0**；`rows[i].globalIndex` 连续递增 |
| `int oldestIndex / newestIndex` | 窗口两端的全局下标（含） |
| `int serverTotal` | 服务器 `total`（只随落库增长） |
| `int get total` | `serverTotal + buffered.length`（滑块用） |
| `bool atTail` | 窗口最新端 == 会话最新端（没有缺口） |
| `MessageRange get window` | `[oldestIndex, newestIndex+1)` |
| `appendOlder(page)` | 向上分页；校验 `page.offset + page.messages.length == oldestIndex`，失败返回 `false`（调用方整窗重载） |
| `trimOlder(n)` | 旧侧裁剪，返回 0（零补偿） |
| `trimNewerMeasured()` | 新侧落后裁剪，返回被裁段的实测高度和 `Δ`（调用方补偿 `pixels -= Δ`） |
| `bufferTail(message)` / `bufferChunk(id, chunk)` | 脱离期的尾巴缓冲 |
| `mergeBuffered()` | 回到尾部时合并，返回是否成功（顺序按 timestamp/seq 稳定） |
| `resetTail(page)` / `resetAround(page)` | 重载末尾 / 定位重锚 |
| `indexOfId(id)`、`globalIndexOfLocal(i)` | 寻址 |

**全局下标是显式的**（`ChatMessage` 旁挂 `int globalIndex`，或在 `MessageFeed` 里维护平表），
不再靠"槽位表下标"隐式表达——滑块与定位都读它。

### 2.3 布局：反向列表为什么天然不跳

设窗口内第 `i` 行高度 `h_i`（`i=0` 最新，向旧递增），`s_i = Σ_{j<i} h_j`，
视口像素 `p`（从最新端量起），屏幕顶坐标：

```
y_top(i) = H - (s_i + h_i - p)
```

- **向上补页**：在末尾追加行 ⇒ 已有行的 `s_i` 不变、`p` 不变 ⇒ `y_top` 不变（I-3）；
- **跟随**：`p = 0`，新消息插到 `i=0` ⇒ 其余行 `y_top` 不变，新行出现在底部并向上生长；
- **流式增长**：`i=0` 高度增加 ⇒ `s_0 = 0` 不变，`y_top(0)` 上移，其余行不动 ⇒ 底部始终是光标；
- **首帧即底**：`p` 初始就是 `minScrollExtent = 0`，不需要任何布局期校正（I-4）。

因此 `_BottomAnchorScrollController` / `_BottomAnchorScrollPosition` 的钉底与补偿分支、
`padAboveStamp` / `contentShiftStamp` 两个信号、面板的 `splitGapAtViewportTop` 全部删除。
只保留一个**极小的** `_DampedScrollController`：覆写 `pointerScroll` 乘
`ScrollDampingService.instance.factor`（用户 2026-11-22 的滚动阻尼设置必须保留）。

### 2.4 跟随 / 阅读与尾巴冻结（I-5）

- 进出：`pixels <= _bottomEpsilon` ⇒ 跟随；`pixels > _bottomEpsilon` ⇒ 阅读。
  反向列表里"离开底部"= 向上滚，判据只剩 `pixels`，没有 `maxScrollExtent - pixels` 的估算噪声。
- 阅读期间：
  - `msg_start` / `msg_chunk` / `tool_*` 更新 → `MessageFeed.bufferTail/bufferChunk`，**不 setState 列表**；
  - 「回到底部」按钮常显 + 角标（`n 条新消息`）；
  - 点按钮 = `mergeBuffered()` + `jumpTo(0)` + 恢复跟随；**不**重载网络（缓冲区里就是完整增量）。
- 跟随期间：直接更新 `rows[0]`（或插入新行），`pixels` 保持 0，零位移。
- 切 agent / 切会话：`resetTail(getConversationDisplayRows(...))`，`pixels = 0`，缓冲清空
  （沿用 `_windowEpoch` 代次闸）。

### 2.5 分页协议（服务端能力已够，零改动）

服务端口径见 [conversation_store.dart L50-L115](../plugins/tree.agent/lib/src/conversation_store.dart#L50-L115)，
UI 入口 [api_service.dart L629-L707](../plugins/tree.ui.default/lib/io/api_service.dart#L629-L707)：

| 场景 | 请求 | 说明 |
|---|---|---|
| 首屏 / 回到底部 | `getConversationDisplayRows`（`limit` + 多次 `before` 凑满 `kInitialDisplayRows=200`） | 现有实现原样复用 |
| 上滑补页 | `before = rows.last.id`，`limit = kMessageWindowRadius(51)` | 页尾字节预算丢行时 `offset` 前移、`has_more` 保持真，连续性校验用 `page.offset + len == oldestIndex` |
| 滑块拖到窗口外 | `from = targetIndex`，`limit = 51` | 重锚：窗口重置为 `[target, target+51)`，`target` 成为最旧端 |
| 按 id 定位（问题导航） | `at = id`，`limit = 51` | 窗口重置为含目标的页，目标居中 |

自愈规则：
- 连续性校验失败 / `page.messages` 为空但服务端说前面还有 → 整窗 `resetTail`（现有 `_reloadTail` 路径）；
- 一律受 `_windowEpoch` + `_currentSessionId` 双闸拦截（在途响应不落旧窗）。

### 2.6 淘汰与内存上限（I-6）

- **旧侧（视口上方）**：窗口行数超过 `kMessageFeedMaxRows` 时，从末尾整段裁剪。
  被裁行都在视口之上，`y_top` 不变 ⇒ `trimOlder` 返回 0，**无补偿**。
- **新侧（视口下方）**：只有当"用户已经在历史深处、窗口被旧侧撑到上限"时才裁。
  被裁行曾全部经过视口（懒构建按顺序布局过），高度**实测可得**（`heightById` 缓存）；
  `Δ = Σ 实测高度`，一次性 `pixels -= Δ` + `jumpTo`，同帧生效（不产生中间帧）。
  任何一行缺实测值 ⇒ 本段**不裁**（延后到该行重新量到），绝不用平均值硬补。
- 与旧模型的差别：旧模型淘汰回 88px 占位槽（"打洞"）；新模型**不做占位槽**，
  未加载段根本不在 `rows` 里。
- 流式消息、正在跑的工具卡片、临时员工消息、展开中的折叠组整段：永不被裁
  （沿用 `evict` 的保底口径与 `onExpandedRunsChanged` 钉住区间）。

### 2.7 定位与滑块 seek（V2）

1. **目标在窗口内**：本地下标已知 ⇒ 用 `MessageSeekCorrection`（保留，
   由 `message_window.dart` 移入 `message_feed.dart`）
   做"估算 → 跳跃 → 观测落点 → 割线修正"，≤3 次、容差 3 条。
   步长初值改为 `窗口实测平均高`（`总实测高 / 已量行数`），不再用 88px 占位。
2. **目标在窗口外（滑块拖拽松手 / 点击轨道）**：`from=` 取目标页 → `resetAround` →
   `jumpTo(maxScrollExtent)`（目标是最旧端 ⇒ 落在视口顶部）→ 帧后迭代校正到目标行。
3. **按 id 定位**：`at=` 取页 → `resetAround` → 帧后 `Scrollable.ensureVisible(alignment: 0.2)`
   （现有口径），并置阅读模式。
4. 用户一有新的滚动/拖拽/输入 ⇒ 丢弃进行中的校正（现有 `_cancelSeekCorrection` 口径）。

### 2.8 滑块几何（V1）

输入只剩三样（[message_scrollbar.dart](../plugins/tree.ui.default/lib/ui/widgets/message_scrollbar.dart)）：

- `total`：`MessageFeed.total`（服务器 `total` + 缓冲条数），**只增**；
- `firstGlobal / lastGlobal`：渲染树扫出的可见行（局部下标 → 全局下标），跳过零高行（折叠组员、临时员工）；
- `rendered`：真正画在屏幕上的行数（折叠感知，口径不变）。

几何不变：`fraction = rendered / total`（下限 6%），`top = firstGlobal / total`。
**删除**：`_smoothTop` 限速与反向死区（它们是为估算噪声服务的；源头稳定后不应再需要）、
`pixelOffsetForIndex`（锚点像素外推）、`kMessagePlaceholderExtent`（不再有占位槽）。
**保留**：拖拽期间钉住几何输入与拇指位置、松手对齐、`messageScrollbarIndexAt` 与绘制严格互逆。

### 2.9 折叠适配（V3）

- 分组算法不变（`_groupableAt` / `_runAt` / 工作期底部 5 张豁免 / 至多 2 组展开），
  只是遍历方向反过来（从最新往旧），组首 = 组内**最新**那条。
- 反向布局下，组员展开会让"更旧的行"整体上移（§2.3 公式里 `s_i` 变大）。为满足
  **TC-COLLAPSE-01（上方零位移）**：点击展开/收起时，记下**被点那一行的顶边**，
  布局后用实测差 `Δ = 更旧侧锚点子项 scrollOffset 的增量` 做一次 `pixels += Δ`
  （同帧、绘制前）。效果：被点行顶边固定、向下长出组员、上方内容零位移、下方内容下移 `Δ`。
- 量不到锚点（长正文/长组把视口占满）⇒ 帧后 `ensureVisible` 被点行兜底，只允许这一种降级；
  测试夹具里所有行都会布局，主路径必须走零位移。
- 裁剪与折叠的交互：旧侧裁剪不得切进展开组内部 —— `onExpandedRunsChanged` 上报的区间
  继续作为 `trimOlder` 的保留区。
- 滑块 `rendered` 条数、`_publishExpandedRuns`、`_workingTailExempt` 逻辑保留。

### 2.10 原样保留的渲染能力（V5）

- 临时员工消息（`visible` 谓词）→ 零高度行，不占版面、不打乱下标；
- `trailingCards` → 排在反向列表**最前**（视觉最底部），顺序在卡片之间再反转一次；
- 加载骨架 / 欢迎页 / 空态判定（`loading`）不变；
- 消息卡片（Markdown、工具卡、思考卡、内联提问、复制/选择）全部不动。

### 2.11 流式隔离（R7，本档独立切片）

目标：`msg_chunk` **不再 `setState` 整个面板**。

- `MessageFeed` 中的流式消息正文改为 `ValueNotifier<String>`（`ChatMessage` 旁新增
  `Listenable` 通道，或新增 `StreamingText`）；
- 流式卡片内部用 `ValueListenableBuilder` 只重建**那一张卡片**，并包 `RepaintBoundary`；
- 面板只在"新消息 / 封口 / 工具状态切换 / 窗口结构变化"时 `setState`；
- 验收：2k 字回复流式推进 200 帧，`MessageList.build` 调用次数与 `MessageFeed.rows.length` 无关，
  帧耗时 p95 < 16.7ms（用 §4 的真实轨迹夹具计）。

---

## 3. 保留 / 删除 / 新增清单

### 3.1 删除

| 对象 | 位置 |
|---|---|
| `MessageList.slots` / `visible` 的槽位语义、`revision` 驱动的整表重建 | message_list.dart |
| `_MessageChildDelegate.estimateMaxScrollOffset`、`_extentBelow` | L226-L248、L1592-L1606 |
| `_rebuildExtentPlan`、`_exactPrefix`、`_unknownExtent`、`_measuredExtent`、`_measureBuiltExtents` | L1535-L1629 |
| `_BottomAnchorScrollController` / `_BottomAnchorScrollPosition` 的钉底与补偿分支 | L308-L559 |
| `padAboveStamp` / `contentShiftStamp` 及 `_snapshotBuiltTops` / `_resolveShiftAbove` / `_retryShift` / `_assertShiftTarget` | L1088-L1290 |
| `firstFrameBottom` / `pinToBottom` / `_jumpToBottomSettling` / `_returnToBottom` | L317-L470、L827-L860 |
| `MessageWindow.slots/place/evict/gapsFor/resetTail`、`splitGapAtViewportTop`、`pixelOffsetForIndex`、`kMessagePlaceholderExtent` | message_window.dart、message_list.dart |
| `_smoothTop` 限速与反向死区 | message_scrollbar.dart |
| 面板 `_pendingWindow` / `_pumpWindowWork` / `_fillWindow` 的缺口式补页（改为 `before` 单链） | message_panel.dart L1151-L1291 |

### 3.2 保留

- `MessageRange`、`MessageWindowCoordinate`（字段口径改为全局下标）、`MessageSeekCorrection`、
  `kMessageWindowRadius = 51`、`kInitialDisplayRows = 200`；
- 分页 REST（`limit` / `before` / `from` / `at`）与 `getConversationDisplayRows`；
- 折叠全套渲染与展开态管理、工作期豁免、内联卡片、临时员工零高度；
- `ScrollDampingService` 设置与 `pointerScroll` 缩放；
- `_replayGuard`、`_detachedById` 在途段缓冲、`_windowEpoch` 代次闸、`_locateKeep` 语义（改为窗口 keep）。

### 3.3 新增

- `lib/ui/services/message_feed.dart`：连续窗口模型 + 全局下标 + 尾巴缓冲 + 裁剪；
- `message_list.dart` 的 `_ReverseMessageList` 视图：`ListView.builder(reverse: true)` + 末尾哨兵
  （哨兵进入视口即触发 `onNeedOlder`，不需要估算 `maxScrollExtent`）；
- 折叠点击的**单点**锚点校正（`_keepChildTopCorrector`，≈40 行）。

---

## 4. 切片与验收（每片独立提交，过既有门禁）

门禁顺序：`dart analyze` → 插件仓 UI 全量 `flutter test` → 桌面仓 `tree_protocol` 访问控制（本方案不触协议，可只跑一次）。

| 切片 | 内容 | 验收 |
|---|---|---|
| **R1 文档 + 基准夹具** | 本档；`test/fixtures/` 固定三份会话轨迹（7.5k / 2.4k / 200 条），只存显示行 JSON | 夹具能构造 `HistoryPage`；记录现状基线（打开到可交互的帧数、`MessageList.build` 次数、`_rebuildExtentPlan` 单次耗时） |
| **R2 反向只读 + 跟随** | `MessageFeed` 最小版（只装末尾页）+ `ListView.builder(reverse: true)` + 卡片复用；面板临时只走 `resetTail` | 首帧即底、`msg_start`/`msg_chunk` 在跟随下零 `pixels` 变化；切 agent 不闪空；`scroll_damping` 仍生效 |
| **R3 向上分页** | 末尾哨兵 + `before` 单链 + 连续性校验 + 帧后视口坐标上报 | 新用例 `reverse_paging_test`：连续上滑 5 页，**每页落地后已渲染行的 `childScrollOffset` 不变**（零补偿断言）；无重复/空洞 |
| **R4 淘汰与上限** | `trimOlder`（零补偿）+ `trimNewerMeasured`（实测 Δ）+ 展开组/流式/末尾保护 | `feed_test`：旧侧裁剪前后视口像素不变；新侧裁剪补偿误差 = 0（用固定高度夹具）；缺实测值时不裁 |
| **R5 定位与 seek** | `at=` / `from=` 重锚 + `MessageSeekCorrection` 改步长 + 滑块松手收口 | `seek_test`：窗口外目标落点 ≤3 条容差；按 id 定位落在 0.2 对齐；拖动中不抢用户滚动 |
| **R6 折叠与滑块** | 折叠反向遍历 + `pixels += Δ` 点击校正 + 滑块几何换输入、删限速 | **TC-COLLAPSE-01** 在新模型下重跑（100 条混杂，展开/收起各三次采样，上方像素差 0）；滑块长度只随 `total` 变 |
| **R7 流式隔离** | `ValueNotifier` 正文通道 + 卡片级重建 | 2k 字 × 200 帧：`MessageList.build` 次数为 O(1)；帧 p95 < 16.7ms |
| **R8 删除旧层** | §3.1 清空；重写 `lib/README.md` 不变量 19；更新文档索引与 work-log | 全量 UI 测试绿；`grep -n "padAboveStamp\|contentShiftStamp\|_extentBelow\|kMessagePlaceholderExtent"` 零命中 |

### 4.1 测试迁移

| 现有用例 | 处置 |
|---|---|
| `test/message_window_test.dart`（gapsFor / place / evict） | 删除，改写为 `test/message_feed_test.dart`（连续性 / 裁剪 / 缓冲合并） |
| `test/message_window_coordinate_test.dart` | 保留类，输入改"全局下标 + total"；删 `pixelOffsetForIndex` 用例 |
| `test/message_list_scroll_test.dart` | 保留场景，断言改反向（`pixels=0` = 底部） |
| `test/message_list_jitter_test.dart` | 保留"补页不位移"场景，删除补偿量断言，改为**零补偿**断言 |
| `test/message_list_viewport_stable_test.dart` | 保留，改读 `MessageFeed` |
| `test/message_collapse_test.dart` | 保留 TC-COLLAPSE-01 与工作期豁免，改反向遍历 |
| `test/message_scrollbar_test.dart` | 保留几何互逆；删平滑限速相关断言 |
| `test/message_panel_window_work_test.dart` | 改为 `before` 单链 + 尾巴冻结；删 `splitGapAtViewportTop` 用例 |

---

## 5. 风险与不变量核对

1. **反向列表的"新消息"方向**：跟随下插在 `i=0` 天然贴底；阅读下必须冻结（I-5），
   否则会顶走正在读的内容。这是**行为变化**（旧模型阅读时新消息直接出现在下方不可见处），
   需在 UI 上给出角标，避免用户以为"消息丢了"。
2. **`total` 的漂移**：服务器 `total` 只在落库时增长；在途段（尚未持久化）由本地缓冲补进 `total`。
   切会话/重载时以新 `page.total` 为准（沿用代次闸）。
3. **`session_id=all`**：合并会话按 agent 全局 `seq` 排序，新消息仍追加在末尾，全局下标稳定。
4. **窗口外定位的重锚**：`resetAround` 会丢掉原窗口（含末尾实时尾巴）。定位后必须置阅读模式，
   且 `_locateKeep` 保证目标页不被立刻裁掉；回到末尾由"回到底部"重载（现有行为）。
5. **折叠展开的补偿是唯一保留的测量校正**：实现里不得把它泛化成"所有内容变更都补偿"，
   否则又会回到 §1.2 的第 2/3 条。
6. **插件硬约束**：纯 Flutter，无新增 pub 依赖，不 import 核心包；分页只走既有 REST 委派；
   不新增协议字段，不改 `tree_protocol` 访问控制基线。
7. **并行会话冲突**：同一工作区可能有其它会话在改 `message_list.dart` / `message_panel.dart`；
   每个切片动手前先 `git status` / `git log`，按文件区域避让。

---

## 6. 拍板记录

- **2026-11-22 用户拍板路线 2**：反向 ListView + 向上分页 + 锚点保持；
  **取消**全局槽位表、全局 `maxScrollExtent` 估算、补偿层（`padAboveStamp` / `contentShiftStamp` /
  实测锚点 / 帧后重试）。EXTREME 合成滚动用例已退役（插件仓 `3d87d8c`）。
- **本期不动的既有能力**：折叠（含至多 2 组展开、工作期底部 5 张豁免）、显示/详细两分、
  临时员工零高度、滚动阻尼、内联卡片。

待拍板（实施 R2/R4 前确认，均有推荐项）：

| # | 问题 | 推荐 |
|---|---|---|
| D1 | 阅读模式下来新消息：缓冲 + 角标，还是立即插入并补偿？ | **缓冲 + 角标**（I-5；插值补偿会重新引入估算） |
| D2 | 已渲染窗口上限 `kMessageFeedMaxRows` | **2000**（与 F3 显示缓存同源；反向列表不会顺序布局全表，内存不是主风险） |
| D3 | 折叠展开的锚点 | **被点行顶边固定**（满足 TC-COLLAPSE-01；也是用户直觉） |

---

## 附：本档引用的关键代码坐标

- 现行估算与补偿：[message_list.dart L1535-L1606](../plugins/tree.ui.default/lib/ui/widgets/message_list.dart#L1535-L1606)、[L308-L559](../plugins/tree.ui.default/lib/ui/widgets/message_list.dart#L308-L559)、[L1070-L1290](../plugins/tree.ui.default/lib/ui/widgets/message_list.dart#L1070-L1290)
- 窗口模型：`message_window.dart`（已删除）→ [message_feed.dart](../plugins/tree.ui.default/lib/ui/services/message_feed.dart)
- 面板补页/淘汰/定位：[message_panel.dart L1112-L1380](../plugins/tree.ui.default/lib/ui/widgets/message_panel.dart#L1112-L1380)
- 滑块几何：[message_scrollbar.dart L80-L140](../plugins/tree.ui.default/lib/ui/widgets/message_scrollbar.dart#L80-L140)
- 分页服务端：[conversation_store.dart L50-L115](../plugins/tree.agent/lib/src/conversation_store.dart#L50-L115)
- 分页客户端：[api_service.dart L612-L707](../plugins/tree.ui.default/lib/io/api_service.dart#L612-L707)
- 折叠规格与 TC-COLLAPSE-01：[conversation-sembast-and-collapse-recon.md §3.2](conversation-sembast-and-collapse-recon.md)
