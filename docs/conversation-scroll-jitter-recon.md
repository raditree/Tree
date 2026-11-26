# 侦查：默认 UI 对话页滚动抖动 / 跳动 / 滚不动的因素清单（P0~P5）

> 状态：**只收集、不修改**（2026-11-26；同日按真机视频取证补记 6 条，见 §9）。范围：`plugins/tree.ui.default` 中栏对话页
> （`message_list.dart` / `message_feed.dart` / `message_panel.dart` / `message_scrollbar.dart`
> / `message_cards.dart` / `markdown_view.dart` / `scroll_damping_service.dart`）
> 与它依赖的帧路径（`websocket_service.dart` / `frame_router.dart`）。
> 与滚动模型重写方案的关系：本文只登记**现行实现**里仍可能出问题的点，
> 不改 `docs/scroll-model-rewrite-recon.md` 的不变量；每条都标了它触碰哪条不变量。
>
> 分级口径：
> - **P0** 必现且严重到不可用（丢数据/彻底卡死）
> - **P1** 高概率、用户明显可感（每次会话都能遇到）
> - **P2** 常见但不严重，或只在特定操作组合下出现
> - **P3** 特定条件（长会话/大折叠/特定设备）才出现
> - **P4** 理论风险 / 缺证据
> - **P5** 代码异味，暂未见用户可感后果
>
> 症状标记：**A=抖动**（来回/反复重排）、**B=跳动**（内容突移、位置丢失）、
> **C=滚不动**（撞墙/空转/无法继续）、**D=贴底/跟随不准**。

---

## 0. 先给结论：五个"结构性"来源

1. **`following` 与"程序化跳转"是两套状态机**：只有用户滚动通知会改 `following`，
   滑块拖拽/点击、落点校正、定位全是 `_jumpTo`（`_programmaticJump` 早退），
   于是"用户在中间读、模型以为在跟尾"⇒ 新消息一插就顶走内容（P1，§1-01）。
2. **全局下标可能被打出空洞**：`MessageFeed.appendTail` 的 `_nextGlobal` 取
   `max(serverTotal, 窗口最新+1)`，服务端总数领先时新行的下标会跳格 ⇒
   滑块映射、`localOfGlobal`、定位全部按错映射算（P1，§1-02）。
3. **行高在"数据不变"时也会变**：折叠豁免集合随 `working`/`revision` 重算、
   流式 Markdown 全文重解析、末尾页重对齐替换对象、字体/字号/主题 —— 每一种都会
   让已布局行改变高度（反向列表里 = 上方内容整体位移）（P1~P2，§1-03、§3-01、§2-02）。
4. **贴底判据依赖"总数"，而总数会被替换/补齐**：`atTailIgnoringBuffer` 一旦长期为假，
   跟随永不恢复、缓冲永不合并（P1，§4-01）。
5. **"插入"本身就是一次位移，而且没有任何过渡**：反向列表贴底时新行插在底部 ⇒ 既有
   内容在**同一帧**整体上移一行的量；滚轮路径又不做任何按帧插值（§5-07）⇒ 掉帧直接
   变成台阶。内容不足一屏时，补白还会把这一次位移变成**两帧回弹**（§1-14）。

> **2026-11-26 视频取证后补记**：新增 §1-13 / §1-14 / §1-15 / §1-16 / §4-05 / §5-07
> 六条（其中 4 条 P1），并在 §9 落了取证数据。P0 判定不变（不丢数据、不彻底卡死），
> 但视频里"每次上滚都被推回""每次插卡都弹两帧"已属**必现可感**，别再按"偶发"排期。

---

## 1. 反向窗口模型与列表（`message_feed.dart` / `message_list.dart`）

| # | 等级 | 症状 | 机制 | 证据 |
| --- | --- | --- | --- | --- |
| 1-01 | **P1** | B | **程序化跳转后 `following` 仍可能为 true**。`_onScrollNotification` 在 `_programmaticJump` 时直接 `return`，不更新 `_setUserDetached`；而滑块点击/拖拽落点、`_beginSeekCorrection` 全部走 `_jumpTo`。用户拖到中段后只是阅读、不再滚动 ⇒ `feed.following == true` ⇒ 新消息 `appendTail` 插到局部下标 0 ⇒ 所有更旧行 `s_i` 增大 ⇒ 屏幕内容整体上移（一次位移 = 新行高度）。触碰 I-5。 | `message_list.dart:701-731`（`_programmaticJump` 早退）、`:904-911`（`_seekToGlobal` 只 `_jumpTo`）、`:969-1000`（落点校正）、`message_feed.dart` `appendTail` |
| 1-02 | **P1** | A/B/D | **全局下标空洞**。`_nextGlobal = max(serverTotal, baseGlobal) + buffered.length`：当服务端已落库但 UI 没收到帧（漏帧 / 只在末尾页出现的系统消息 / `replacePersisted` 把 total 抬大），新追加的行下标会一次跳好几格，窗口不再是连续区间。`localOfGlobal` 是"首行下标 − g"的算术，空洞后整段映射偏一格以上；滑块位置、拖拽反解、`onSeekOutsideWindow` 判断全跟着错。触碰 I-2。 | `message_feed.dart` `_nextGlobal` / `_insertNewest` / `localOfGlobal` / `total`；`message_list.dart:1040-1060`（坐标换算） |
| 1-03 | **P1** | B | **折叠豁免集合随工作状态重算 ⇒ 行高自己变**。`kWorkingTailExempt=5`：agent 工作中"最近 5 张工具/思考卡不折叠"，第 6 张到来时最早那张**从展开塌成折叠**（高度从整卡变成一条控制条）；`_rebuildWorkingTailExempt` 在 `didUpdateWidget` 里对 `working` **和** `revision` 变化都重算（即每个流式/工具帧），豁免行的身份会随插到 0 位的新行整体平移。反向列表里这等于"上方内容高度变了"。 | `message_list.dart:352-360`、`:604-620`、`:1170-1210`（`_buildItem` 里 `run.collapsed && local != run.tail` 返回零高度） |
| 1-04 | **P1** | B | **`_visibleFirstLocal` 落后一帧**。冻结判据用的是**上一帧帧后**测出的首个可见行；快速滚动/大块增量时它可能是旧值，于是"视口下方"的行先长高、下一帧才被判定为应冻结 —— 每帧位移 = 该行增量高度（连续几帧就是可见的"顶一下"）。触碰 I-5。 | `message_feed.dart` `appendChunk` / `setVisibleFirstLocal`；`message_list.dart:477-500`（`_flushCoordinate` 里 `_feed.setVisibleFirstLocal(firstLocal)` 在帧后） |
| 1-05 | **P2** | A | **每帧三次全子项遍历 + 冻结合并 O(整窗)**。`_flushCoordinate` 每帧依次 `_measureBuiltHeights`、`_visibleLocalRangeFromRenderTree`、`_updateBottomFill`（各走一遍 `firstChild→childAfter`）；`setVisibleFirstLocal` 变化时 `_applyPendingFrom` 从首个可见行**遍历到窗口最旧**（2000 行上限）。流式 + 上滚时每帧 O(N)，表现为掉帧/不跟手。 | `message_list.dart:477-500`、`:620-700`；`message_feed.dart` `_applyPendingFrom` |
| 1-06 | **P2** | A | **落点校正连跳 2~3 次**。`MessageSeekCorrection` 松手后最多 3 次 `_jumpTo`（每次一帧），判据是 `at.first`（视口最旧可见下标）与容差 3 行 —— 用户看到的是"松手后位置又挪了三次"，且可能停在高目标 3 行处。 | `message_feed.dart` `MessageSeekCorrection`；`message_list.dart:1005-1030`（`_pumpSeekCorrection`） |
| 1-07 | **P2** | A | **`_runAt` 每行向两侧扫描整段**：`_buildItem` 对每个可折叠行调用 `_runAt`，它用 `while (_groupableAt(head-1))` 一路扩到整段边界。长工具轮（几百张卡）时每帧成本 = 可见行数 × 段长；滚动到该段即掉帧。 | `message_list.dart:592-650`（`_runAt` / `_groupableAt`） |
| 1-08 | **P2** | B | **`_updateBottomFill` 的"补满一屏"会在内容跨过一屏时整段切换**：内容短于视口时 `fill = 外框高 − 内容高`（每次流式增长都 `setState` 重排）；一旦发生折叠/字体变化让内容超过一屏，`fill` 从 Npx 直接归零 ⇒ 列表可视高度突变 ⇒ 已渲染行位置整体位移。 | `message_list.dart:590-618` |
| 1-09 | **P3** | A | **`build` 里写状态**：`_buildItem` 直接改 `_builtFirst/_builtLast` 并调 `_scheduleCoordinateFlush`（build 期间排帧后回调）。任何额外重建（主题/滚动条/父级 setState）都会多排一次坐标刷新，和滚动通知的刷新叠加。 | `message_list.dart:1176-1186` |
| 1-10 | **P3** | D | **零高度行参与下标**：`visible(m) == false`（临时员工消息）与折叠组员都返回 `SizedBox.shrink()`，但 `_visibleLocalRangeFromRenderTree` 用 `extent > 0.5` 过滤掉它们后才算 `rendered`。一旦某帧所有可见行都是零高度（极端：全折叠）会返回 null → 坐标退回 `_builtLocalRangeFromRenderTree`（含零高度行）⇒ 滑块长度/位置在同一次滚动里换口径。 | `message_list.dart:505-560`、`:1080-1130` |
| 1-11 | **P3** | C | **`_itemKeys` 只增不清**（>2000 才清一次），`_itemKeys.putIfAbsent(message.id, GlobalKey.new)` 在每帧每条可见行执行；`_pruneItemKeys` 用 `Set` 重建整窗 id 集合（O(N)）。长会话里是可测的常驻成本，不是跳动主因。 | `message_list.dart:1040-1050`、`:1190-1210` |
| 1-12 | **P4** | B | **`MessageFeed.trimOlder` 与 `_expandedRunsKeep` 可能差一帧**：展开组区间由列表在 build 期间报给面板（`onExpandedRunsChanged`），面板在帧后裁剪时用的可能是上一帧的区间；若这一帧刚好收起/换组，裁剪点会落在组内 ⇒ 组边界被切掉、展开态丢失（视觉上整组塌陷）。 | `message_panel.dart:1358-1378`；`message_list.dart:660-700` |
| 1-13 | **P1** | B | **插一条新行 = 既有内容在同一帧整体上移一行的量，零过渡（"卡片从底部冒出来 + 内容被顶一下"）**。`reverse: true` 且贴底（`pixels == 0`）时，新行落在列表**底部**（leading edge），所有既有子项的 `scrollOffset` 当帧全体 +h。探针实测（长会话贴底、插一张 30px 工具卡）：`pixels` 始终 0，`maxScrollExtent` 1824.9 → 1794.6，锚点 y `233.0 → 203.0`，**单帧到位后不再动**。对比：气泡正文有 reveal ticker（`_MessageBubble`）做逐帧追赶，卡片这一侧**没有任何过渡**，所以位移只能是整级跳。 | 探针 `.self/probe/insert_probe_test.dart` P4；`message_feed.dart` `appendTail`→`_insertNewest`；`message_list.dart:1128`、`:1132` |
| 1-14 | **P1** | A/B | **`_updateBottomFill` 与"能滚就清 0"守卫互相打架 ⇒ 插一条工具卡弹两帧（~150px 量级）**。内容不足一屏时 `fill = 外框高 − 内容高`；新行进来后 `maxScrollExtent` 先变正 ⇒ 下一帧走 `if (pos.maxScrollExtent > 0.5) → fill = 0` ⇒ 内容贴到底（下移 fill）；再下一帧重新算出更小的 fill ⇒ 又被推回上方。探针实测（`working` 开/关都复现）：`viewportDimension` 448 → **600** → 478，锚点 y `134.0 → 104.0(−30) → 256.0(+152) → 134.0(−122)`，两帧回弹 150px 量级后才收敛。触发条件是"内容正好在一屏上下"（P3 里内容明显不足一屏、连插 4 张都没跨过 ⇒ 一次都没弹）。**这条正是用户报的"工具调用卡片新增时从底部飞上来"**：回弹期间卡片先掉到列表底边、再被推上来。 | 探针 P1/P2（复现）与 P3（反例）；`message_list.dart:626-651`（`_updateBottomFill`）、`:653`（`_setBottomFill`） |
| 1-15 | **P2** | C | **折叠行把"可滚高度"吃光**：`_buildItem` 对折叠组员返回零高度，一屏十几行里真正有高度的只有 2~3 行 ⇒ 窗口内容的 `maxScrollExtent` 只剩几百像素（真机视频里正好 **249px**）⇒ 上滑哨兵一滚就撞上 ⇒ 补页/重锚/跳底循环——"滚到一半没法继续"的几何前提。 | 视频实测（§9）；`message_list.dart:1128`、`:1132` |
| 1-16 | **P3** | A | **`assertPixels` 的帧后 `jumpTo` 会再排一帧**：`_flushCoordinate` 帧后核对锚点补偿，不一致就 `jumpTo` ⇒ 多一次布局；与 `_setBottomFill` 的 `setState` 叠加时，一次插入可能连排 3 帧。 | `message_list.dart:449-460`（`_flushCoordinate`）、`:295`（`assertPixels` 赋值） |

---

## 2. 面板 / 数据流（`message_panel.dart`）

| # | 等级 | 症状 | 机制 | 证据 |
| --- | --- | --- | --- | --- |
| 2-01 | **P1** | B/C | **`_loadOlder` 接不上时的自愈会移动视口**：连续性校验失败 ⇒ `resetAround(at=最旧id)` + `_scrollToMessage(oldestId)`（`ensureVisible` 300ms 动画）；再失败就 `_reloadTail()`（整窗换末尾页 + 跳底）。用户正在往上读时，这条路径是"跳一下/被甩回底部"的直接来源。每次失败链只自愈一次（`_olderAnchorHealed`），但下一次上滑又会重来。 | `message_panel.dart:1214-1300`、`:1029-1062`（`_applyTailPage`）、`:1074-1100`（`_reloadTail`） |
| 2-02 | **P2** | B | **末尾页重对齐替换对象**：`_reconcileTail` 用 `replacePersisted` 把**同 id 的对象换成落库版本**（`setState` + `revision++`，但 `bottomJump=false`），并 `sealAll` 那一批 id。已核实的边界：agent 侧正文/工具段是**段结束时**才落库（`persistSegment`），所以在跑的段不在末尾页里、不会被误封口；风险集中在"落库版本与本地卡片渲染高度不同"（工具结果格式化、折叠判定）⇒ 替换后行高变而视口不补位移。12s 兜底轮询与"重启/缺口自愈"都会调它。 | `message_panel.dart:3395-3440`；`message_feed.dart` `replacePersisted`；`plugins/tree.agent/lib/src/agent/conversation_service.dart:1285-1320`（`persistSegment` 时机） |
| 2-03 | **P2** | C | **`_historyLoading` 期间坐标被丢弃**：`_onWindowChanged` 在加载中直接 `return`，`_visibleOldest` 保持旧值；加载完成后的第一帧坐标既可能触发补页、又可能触发裁剪，且这期间用户滚动不会请求更旧的页（表现为"滑到头了不动"）。 | `message_panel.dart:1119-1145` |
| 2-04 | **P2** | A | **`msg_start` / `msg_end` / `tool_*` 仍整面板 `setState`**：R7 只把 `msg_chunk` 改成局部重建，段开始/结束与每次工具事件仍 `setState` + `revision++` ⇒ `MessageList` 全可见子树重建（每条气泡各重解析一次 Markdown）。工具密集轮次里是周期性的整帧重建，滚动中表现为"一顿一顿"。 | `message_panel.dart:1556-1563`、`:1636-1650`、`:1698-1710`、`:1848-1860` |
| 2-05 | **P2** | A/D | **12s 兜底轮询与用户滚动竞争**：`_pollRunning` 每次状态变化就 `_reconcileTail()`（内部 `setState`）；同时 `_syncRunningState` 也会 `setState`。轮询撞上滚动帧时，`revision++` 会让列表多一次坐标刷新/裁剪，偶发"滚到一半停一下"。 | `message_panel.dart:3340-3375`、`:3380-3395` |
| 2-06 | **P2** | C | **补页前瞻用"已加载最旧行"的全局下标**：`first - _feed.oldestIndex < kMessageWindowRadius` 才预取。若出现 §1-02 的空洞/下标偏移，`first - oldestIndex` 会被算大（或为负），前瞻失效 ⇒ 用户撞到 `ClampingScrollPhysics` 的墙才发请求（"滚到一半没法继续"的经典形态）。 | `message_panel.dart:1140-1150` |
| 2-07 | **P2** | B | **裁剪后 `revision++` 让列表重建，但 `_armAnchor` 只在折叠点击时布防**：裁剪本身设计为零位移（只删视口上方），可一旦 `keepRows` 计算被 `_expandedRunsKeep` 拉大/缩小的那一帧与用户滚动同帧，`pixels` 可能被框架夹到新范围（贴到上边界时）⇒ 位置被动下移。 | `message_panel.dart:1351-1378`；`message_list.dart:776-812` |
| 2-08 | **P3** | A | **`_detachedById` / `_captureInFlight` / `_restoreInFlight` 的整窗作废路径**：切换会话/重锚/自愈时把在途段摘出来再接回；接回时按 id 插回窗口，若这一页不含该段，它留在缓冲并继续收 chunk，用户切回时可能一次补齐很长一段（高度突增）。 | `message_panel.dart:1039-1060`、`:1258-1280` |
| 2-09 | **P3** | C | **`_loadOlder` 的 `finally` 里 `setState`**：每次补页结束都重建面板；若用户连续上滑触发多轮（`_loadingOlder` 只为当前轮守卫），`revision` 连增，配合 §1-05 的遍历成本会放大掉帧。 | `message_panel.dart:1290-1305` |
| 2-10 | **P4** | B | **`_scrollToMessage` 用 `ensureVisible(duration: 300ms)`**：定位到消息时有一个动画滚动；若同一帧用户也在滚动，两个滚动源叠加（`ScrollPosition` 的 ballistic 活动与用户拖拽竞争）⇒ 短促抖动。 | `message_list.dart:1032-1050` |

---

## 3. 渲染与行高（`message_cards.dart` / `markdown_view.dart` / 折叠）

| # | 等级 | 症状 | 机制 | 证据 |
| --- | --- | --- | --- | --- |
| 3-01 | **P1** | A | **流式长消息每帧全文重解析**：`ChatMessage.contentVersion` 每次 `appendChunk` 通知 → `_MessageBubble` `setState` → `MarkdownView`（Stateless）→ `MarkdownBody(data: 全文)` 重新解析整条消息；代码块再走一次语法高亮（`_CodeBlockCard` 每次重建）。成本 O(消息长度) 每帧、总成本 O(n²)。长回答后段明显掉帧，跟随贴底时表现为"文字一顿一顿地跳着长"。 | `message_cards.dart:203-230`、`:474-500`；`markdown_view.dart:65-100`、`:310-430` |
| 3-02 | **P2** | A | **`SelectionArea` + 每块 `SelectableText`**：流式重建时选择树跟随重建；用户正在选字时被增量打断（选区丢失/闪一下）。 | `message_cards.dart:440-470`；`markdown_view.dart:101-104` |
| 3-03 | **P2** | B | **折叠控制条挂在组尾**：展开/收起只在点击时布防一次锚点（`_armAnchor(run.tail)`）；若布局在该帧被别的原因再触发一次（主题/裁剪/坐标刷新），`resolveAnchorDelta` 已在首次布局被取走（置 null），第二次布局不再补偿 ⇒ 上方内容残留位移。 | `message_list.dart:252-292`（`applyContentDimensions` 里 `resolveAnchorDelta = null`）、`:814-860`（`_armAnchor`） |
| 3-04 | **P3** | B | **异步内容改变行高**：内联图片/附件预览/代码块折叠等完成后高度变化，但没有"锚点补偿"（只有折叠点击有）。滚动中图片解码完成 = 上方内容突移。 | `message_cards.dart`（附件/图片卡片）、`markdown_view.dart`（`_CodeBlockCard` 展开） |
| 3-05 | **P3** | B | **字号 / 字重 / 字体切换**：`TextScaleService` / `FontService` 变化触发 `MaterialApp` 重建 ⇒ 全表行高变化，滚动位置按 `pixels` 保留（内容变了、像素没变）⇒ 视口落到别的消息上。 | `main.dart:288-330`；`text_scale_service.dart`、`font_service.dart` |
| 3-06 | **P4** | A | **光标闪烁动画**：流式气泡末尾的光标（若有 `AnimatedOpacity`/`Ticker`）每帧重绘该行；若该行在视口外仍被 ticker 驱动，会带来无谓的帧调度。 | 待验证：`message_cards.dart` 内 `isStreaming` 分支 |

---

## 4. 跟随 / 贴底（`message_feed.dart` + `message_list.dart`）

| # | 等级 | 症状 | 机制 | 证据 |
| --- | --- | --- | --- | --- |
| 4-01 | **P1** | D | **贴底判据同时依赖"像素"与"总数"**：`atBottom = pixels <= 1 && _feed.atTailIgnoringBuffer`，而后者用 `newestIndex >= total - 1 - bufferedCount`。任一环节让 `total` 比窗口最新下标大（漏帧、`replacePersisted` 抬 total、§1-02 空洞），该判据永久为假 ⇒ 用户滚到底也不恢复 `following` ⇒ `mergeBuffered` 不触发 ⇒ 缓冲越积越多、界面停在旧内容（"贴底没做好"）。 | `message_feed.dart` `atTail` / `atTailIgnoringBuffer` / `total`；`message_list.dart:733-760` |
| 4-02 | **P2** | D | **回到底部与用户滚动同帧竞争**：`_setUserDetached(false)` 在滚动通知里 `mergeBuffered()` + `setState` + `_scheduleJumpToBottom()`；下一帧 `jumpTo(0)` 被标成程序化跳转，若用户这时又上滚，通知会被早退吞掉 ⇒ `following` 与真实位置不同步。 | `message_list.dart:733-775` |
| 4-03 | **P2** | D | **`mergeBuffered` 一次性插入全部缓冲**：脱离跟随期间积压 N 条，回到底部时一次 `insertAll(0, ...)` + 跳底。若 N 很大（长时间阅读），这一帧要构建 N 行（虽然只有可见的被布局，但 `itemCount` 与下标换算全变）⇒ 回到底部瞬间掉帧。 | `message_feed.dart` `mergeBuffered`；`message_list.dart:745-755` |
| 4-04 | **P3** | C | **`hasOlder` 与 `exhausted` 的判定只由页返回决定**：`appendOlder` 在 `messages.isEmpty` 时置 `exhausted`；若服务端因字节预算返回"空但不代表到底"（或 `before=` 页被截成 0 条），会永久停止补页 ⇒ 上滑到底后不再加载（"滚到一半没法继续"）。 | `message_feed.dart` `appendOlder`；`message_panel.dart:1225-1240` |
| 4-05 | **P1** | B/D | **`bottomJump` 是跨事件残留的 sticky 标记，能把视口整体拽回底部**。`MessageList.didUpdateWidget` 的判据是"`revision` 变了 **且** `bottomJump`" ⇒ `_scheduleJumpToBottom()`；而 `bottomJump` 由面板靠**十几处 `setState` 手工置 false** 维持，`_onWindowChanged` 里的 `trimOlder`（:1414）与 `_clearWindow`（:3615 / :3638 / :3743）三处**没有复位**。只要有一次 `revision++` 带着残留的 `true`，用户上滚读历史时就会被 `jumpTo(0)` 拽回底部，位移量恰好等于他滚上去的那一段。真机视频里就是这条形态：t=6.33s 与 8.07s 各一次 **−249px**（朝最新端），且复位前 f189 与复位后 f241、f190 与 f242 **逐像素相同**（同一状态被复位两次）。 | `message_list.dart:398-410`；`message_panel.dart:189`（字段）、`:1414`、`:3462`、`:3615`；视频实测 §9 |

---

## 5. 滑块与输入设备（`message_scrollbar.dart` / `scroll_damping_service.dart`）

| # | 等级 | 症状 | 机制 | 证据 |
| --- | --- | --- | --- | --- |
| 5-01 | **P1** | A | **拖拽反解与绘制不同源**：`_thumb()` 传了 `visibleCount: _rendered`，`_seek()` 调 `messageScrollbarIndexAt` 时**没传**（退回按 `span` 算）。折叠组在视口内时 `rendered < span`，两条几何差一截 ⇒ 指针没动、报出去的下标却变了 ⇒ 内容窜。这正好违反文件头自己写的"绘制与反解必须严格互逆"。 | `message_scrollbar.dart:330-345`（`_thumb`）vs `:496-520`（`_seek`） |
| 5-02 | **P2** | A | **拖拽无节流**：`onVerticalDragUpdate` 每次事件都 `onSeek` → `_seekToGlobal` → `_jumpTo`（无动画、无合并）。一帧多次 `jumpTo` 会反复触发列表布局；同时拇指被 `_dragFraction` 钉在指针下，内容按估算落点跳 ⇒ 视觉上"拇指不动、内容乱窜"。 | `message_scrollbar.dart` `_seek`；`message_list.dart:890-905` |
| 5-03 | **P2** | A | **`_smoothTop` 的反向冻结在静止时仍生效**：`scrollDirection == 0`（补页/淘汰帧）时沿用 `_lastScrollDir`，任何反向修正都被冻结，累计超过 30px 才 `snap` ⇒ 滑块"卡住后突然跳"。 | `message_scrollbar.dart:300-330` |
| 5-04 | **P3** | C | **可见性判据与拇指长度口径不一致**：`messageScrollbarVisible` 用 `total > span`，拇指长度用 `rendered`（最小 6%）；折叠组让它"应该显示但很粗"或"span 大而实际只画一行"。 | `message_scrollbar.dart:60-70`、`_barMetrics` |
| 5-05 | **P3** | C | **滚轮阻尼按事件线性缩放**：`pointerScroll(delta * factor)`，默认 0.8；高精度触控板的小步滚动被同样缩放 ⇒ 同样手势走得更少（体感"滚不动"）。同时右键/键盘（PageUp/PageDown/Home/End）走 `ScrollAction`，**不经**阻尼 ⇒ 同一页里两种手感。 | `message_list.dart:250-262`；`scroll_damping_service.dart:36-60` |
| 5-06 | **P4** | A | **点击滑块 = seek + 校正两跳**：`onTapDown` 先 `onSeek`（跳到估算位置），紧接着 `onSeekSettled` 再校正 1~3 次 ⇒ 一次点击最多 4 次位置变化。 | `message_scrollbar.dart` `onTapDown`；`message_list.dart:1005-1030` |
| 5-07 | **P1** | A | **滚轮/触控板路径没有任何按帧插值或合并**：`pointerScroll` 只乘阻尼系数就交回框架，`ScrollPositionWithSingleContext.pointerScroll` 当场 `goIdle()` + 直接改 `pixels`（无 Ticker、无 ballistic、无事件合并）⇒ **掉一帧就是一级台阶**。用户说的"跳动"有一半是它，不是行高。真机视频实测：全片 25 次画面变化，除 4.70–4.83s 那 0.13s 有 4 帧连续位移（−15/−27/−16/−55）外，**其余全部是单帧台阶**（30/65/92/99/150px 重复出现，0 次 1~10px 级连续位移）。 | `message_list.dart:275-282`（`_MessageScrollPosition.pointerScroll`）；`scroll_damping_service.dart:1-16`；视频实测 §9 |

---

## 6. 帧路径与环境（`websocket_service.dart` / `frame_router.dart` / 平台）

| # | 等级 | 症状 | 机制 | 证据 |
| --- | --- | --- | --- | --- |
| 6-01 | **P2** | A | **`msg_chunk` 合并后仍按帧刷新**：agent 侧按 `frameWindow` 合并增量（`conversation_service.dart:3184`），合并窗口越大、单帧正文越长 ⇒ 单帧重解析成本越高（§3-01）；窗口越小、帧越密 ⇒ 每帧都要重排。两端参数没有与"长消息"联动。 | `plugins/tree.agent/lib/src/agent/conversation_service.dart:3170-3200`；`message_cards.dart` 的 contentVersion 监听 |
| 6-02 | **P2** | C/D | **序号倒退/跳号的"重对齐"会请求重拉快照**：`StationClient._acceptSeq` 在序号倒退时按"新订阅"清空水位并投递一条 `lagged` → 上层按"重新拉快照"处理；若真值端点也返回旧页，会形成"拉快照 → 位置重排 → 再拉"的循环。 | `station_client.dart:380-440`；`message_panel.dart:1440-1470`（lagged/reset 分支） |
| 6-03 | **P3** | A | **`FrameRouter` 只认三段 topic 的历史遗留**：两段 topic 被丢过的修复（2026-11-22）之后，路由层仍对 topic 形状做字符串切分；新增点位若形状不同，会静默丢帧 ⇒ 帧序出现空洞（进一步触发 §1-02）。 | `frame_router.dart`（按 topic 切分与映射） |
| 6-04 | **P3** | A | **窗口 resize / 分栏拖拽**：中栏宽度变化让 Markdown 重新换行 ⇒ 所有已渲染行高度变 ⇒ 反向列表按 `pixels` 保持位置，视口落到别处（拖分栏时内容"跟着跑"）。 | `main_page.dart` 分栏宽度状态；`message_list.dart` `LayoutBuilder` |
| 6-05 | **P3** | C | **主题/字号变化后没有"重锚"**：见 §3-05，只有 `pixels` 不变，语义位置丢失。 | `main.dart:288-330` |
| 6-06 | **P4** | A | **Windows 的 `ClampingScrollPhysics`**：贴边时 `pixels` 被硬夹，任何"内容变短"的变化（裁剪/替换/折叠）都会立刻表现为位置跳变，而不是回弹过渡。模型层把这类夹取当成"框架自己的 correction"，只有折叠点击一条补偿路径。 | `message_list.dart`（未显式指定 physics，走平台默认） |
| 6-07 | **P4** | C | **帧率设置（核心 `settings/frame-rate`）与显示器刷新率不匹配**：采样变粗，滚动手势被离散化；UI 侧未对中栏做特殊处理。 | `packages/tree_core` 的 frameRate 端点；待验证 UI 是否读取 |

---

## 7. 交叉影响（组合起来最像"真机症状"的四条链）

1. **"上滑读历史 → 新消息顶走"**：1-01（following 未更新）+ 1-03（折叠豁免重算）+
   2-04（tool 帧整面板重建）⇒ 用户每次工具轮次都会被推一下。
2. **"滚到一半没法继续"**：6-02/1-02（帧空洞或序号重对齐）→ 2-06（前瞻失效）→
   2-01（补页接不上 → 自愈重锚/跳底）⇒ 用户看到"滑不动 → 突然跳走"。
   真机视频里 1-15（可滚高度只剩 249px）+ 4-05（sticky `bottomJump`）把这条链
   从"偶发"放大成"每次上滚必现"。
3. **"流式时一顿一顿"**：3-01（全文重解析）+ 6-01（合并窗口）+ 1-05（每帧多次遍历）
   ⇒ 帧预算被吃满，滚动采样丢失，视觉上就是抖动。
4. **"卡片从底部飞上来 / 位置被拽回去"**（用户 2026-11-26 报的插卡形态）：
   1-14（补白守卫两帧回弹，内容正好一屏上下时必现）+ 1-13（插入同帧顶掉一行，
   卡片本身零过渡）⇒ 观感就是"飞上来"；配合 5-07（滚轮零插值）与 4-05
   （被拽回底部），任何一次位移都只能整级跳。

---

## 8. 建议的验证顺序（不改代码也能验）

1. 用一条**长回答（>20k 字）+ 30 个工具调用**的会话复现：滚动中记录 `feed.following`、
   `feed.total`、`feed.newestIndex`、`_coordinate.value`（临时日志），确认 1-01/1-02。
2. 折叠组内放 20+ 工具卡，用滑块拖到该段中点：确认 5-01（同一手势下 `_seek` 报出的
   下标与拇指几何是否一致）。
3. 阅读态（`pixels > 0`）时让 agent 连续发消息：确认 1-01（内容是否上移）。
4. 人为让 `before=` 页返回 `offset + len != oldestIndex`（桩服务）：确认 2-01 的
   "自愈即跳走"路径与 `_olderAnchorHealed` 的一次性。
5. 贴底后人为把 `total` 抬大 1：确认 4-01（following 是否再也回不来）。
6. **插卡两帧回弹**（§1-14）：内容短于视口时插一张工具卡，逐帧记录锚点屏幕 y
   与 `position.viewportDimension`；正常应是"一帧上移一行的量"，而现在会看到
   `134 → 104 → 256 → 134`（`viewportDimension` 448 → 600 → 478）。
   现成探针：`.self/probe/insert_probe_test.dart`（P1/P2 短内容、P4 长会话）；
   复跑方式：把它拷进 `plugins/tree.ui.default/test/` 后 `flutter test test/<名字>.dart`。

---

## 9. 真机视频取证（2026-11-26）

素材：`.input/20261126/卡顿、跳动、甚至滚到一半没法继续滚了。.mp4`（10.63s / 30fps /
319 帧 / 1016×1006）。方法：抽全帧 → 相邻帧均值差找"画面真的变了"的时刻 → 对每对
相邻帧做纵向模板匹配（8 条横带、各带独立求位移与 NCC），用来区分**整体滚动**
（各带位移一致、NCC≈1.00）与**重排**（各带位移不等、NCC 偏低）。

| 观测 | 数据 |
| --- | --- |
| 画面变化次数 | 全片 **25 次**，其余帧逐像素相同（`diff = 0.00`） |
| 帧间静止 | 最长 **1.37s**（7.70s 前）、0.97s（6.33s 前），另有多次 0.2–0.5s |
| 位移形态 | 除 4.70–4.83s 的 4 帧连续位移外，**全部是单帧台阶**：30 / 65 / 92 / 99 / **150**（重复 9 次）/ 308 / 329 / 469 px，最小 15px |
| 纯滚动 vs 重排 | t=3.47 / 3.50 / 3.77 / 3.83 / 4.23：**同一帧内各带位移不等**（+413/+301/+245/+133/−7/−91，NCC 0.4–0.75）⇒ 行高变化重排，对应 §1-03 / §1-08 / §3-03 |
| 复位 | t=6.33 与 8.07 各一次 **−249px**（朝最新端）；`f189≈f241`（差 0.08）、`f190≈f242`（差 0.11）逐像素相同；两次之间用户正好上滚 150+99 = **249px** |
| 结尾 | 8.10s 之后 2.5s 几乎不动（仅 ≤0.2 的局部小变化） |
| 画面内容（Windows OCR） | 整屏几乎全是"所 N 次工具调用…点击展开"折叠行，视口里正躺着一个 **45 次工具调用 / 23 段思考**的长段；会话处于"工作中" ⇒ ≈ §1-03 的豁免重算、§1-15 的可滚高度被吃光 |

**对原清单的修正**：原判"命中 P0 的项本次未发现"仍成立（不丢数据、不彻底卡死），
但 P1（必现且用户可感）从 7 条增加到 11 条（新增 1-13 / 1-14 / 4-05 / 5-07）；
且原清单把"跳动"整体归因于"帧预算被吃满"，视频证据显示更直接的原因是
**位移本来就不插值**（§5-07）与**插入/补白本身产生位移**（§1-13 / §1-14）。

### 9.1 插卡位移探针（widget 测试，用户 2026-11-26 报"卡片从底部飞上来"）

探针：`.self/probe/insert_probe_test.dart`（拷进 `plugins/tree.ui.default/test/`
后 `flutter test` 即可复跑）。每 16ms 一帧打印 `pixels` / 锚点正文屏幕 y /
`maxScrollExtent` / `viewportDimension`。

| 用例 | 场景 | 观测（锚点 y / viewportDimension） |
| --- | --- | --- |
| P1 | 工作中，内容≈一屏 | `134.0 → 104.0(−30) → 256.0(+152) → 134.0(−122)`；viewport `448 → 600 → 478` ⇒ **两帧回弹 ~150px** |
| P2 | 空闲（工具卡折叠成组），同上 | `134.0 → 104.0 → 376.0 → 134.0`；viewport `328 → 600 → 358` ⇒ 回弹 ~272px |
| P3 | 内容明显不足一屏，连插 4 张 | y 恒 `31.0`、viewport 恒 `312` ⇒ **不动**（不跨屏就不弹，是 P1/P2 的反例） |
| P4 | 长会话贴底，插 1 张 30px 工具卡 | `pixels` 恒 0、`max` `1824.9 → 1794.6`、y `233.0 → 203.0` **单帧到位** |
| P5 | 长会话贴底，同一张卡结果变长 | y 恒 `240.0` ⇒ 未观测到高度变化，"卡片长高再顶一次"**待验证** |

⇒ **P1/P2 就是"从底部飞上来"**：回弹期间卡片先掉到列表底边、再被推上来，两帧、
零过渡（`_updateBottomFill` 的清理守卫与重算互相打架，§1-14）；P4 说明长会话里
插入本身就是一次"整级上移"（§1-13），也不会被任何动画吃掉。

> 本文只登记因素，不含修复方案；修复取舍见 `docs/scroll-model-rewrite-recon.md` §4.2
> 与后续切片。
