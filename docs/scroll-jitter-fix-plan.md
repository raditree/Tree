# 中栏对话页滚动问题根治计划（SCROLL-FIX，S1~S7 分期）

> 状态：**计划定稿，待逐期实施**（2026-11-26）。本期**只出计划，零代码改动**。
> 2026-11-26 二次核对（工作区又前进 `96a04a3` / `51d603d` 两步，后者动过
> `message_list.dart` / `message_panel.dart`）：**S1 未开工**、既有因素全部仍成立、
> 坐标已按当前工作区刷新（§附），并**新增 1 条因素 2-11 + TC-SC-17**（见 §10）。
> 上游：因素清单 [conversation-scroll-jitter-recon.md](conversation-scroll-jitter-recon.md)
> （P0~P5，40+ 条，含 2026-11-26 视频取证补记）与滚动模型方案
> [scroll-model-rewrite-recon.md](scroll-model-rewrite-recon.md)（I-1~I-8）。
> 用户口径（2026-11-26）：「**都得修，但要慢慢来，分期，本期出计划文档，尽量考虑根治，
> 少频繁补丁**」。

---

## 0. 一句话结论

今天的抖动**不是"补偿公式还不够准"**，而是**位置有三个真值、六条腿各走各的**：

| 真值 | 谁在写 | 出问题的方式 |
| --- | --- | --- |
| `ScrollPosition.pixels` | 滚轮（`pointerScroll` 当场改）、`jumpTo`（13 处）、`correctPixels`（折叠锚点）、`ensureVisible`（定位 300ms 动画） | 谁写谁说了算，互不相让 |
| 窗口下标（`MessageFeed.globalIndex` / `coordinate`） | 追加、补页、裁剪、`replacePersisted`、`trimOlder` | 算术映射（`first - g`），一对不上就整段偏 |
| 行高（布局） | 折叠豁免重算、流式全文重解析、落库对象替换、字体/宽度 | 数据没变高度也变，反向列表里 = 上方内容整体位移 |

于是六个补偿点各自猜一次（`_armAnchor`+`correctPixels`、`assertPixels` 帧后 `jumpTo`、
`_bottomFill` 帧后 `setState`、`_jumpTo`+3 次 seek 校正、`mergeBuffered`→跳底、面板
`ensureVisible`），**谁晚一帧就是一次可见位移**；而滚轮路径又完全不插值
（清单 §5-07），所以每一次位移都只能整级跳。

**根治 = 两梁 + 三删**：

- **梁 1｜视口锚点事务（`AnchorTransaction`）**：任何改布局的动作都在事务里跑，
  位置由事务统一收敛 ⇒ 补偿从"六处特例"变成"一条机制"。
- **梁 2｜目标制滚动推进器（`ScrollDriver`）**：改 `pixels` 只有这一个入口，
  目标值逐帧追赶 ⇒ 掉帧只影响速度，不再产生台阶。
- **删 1｜补白的帧后猜**：`_bottomFill` 改成布局期一次算定（1-14 的根）。
- **删 2｜sticky 跳底布尔**：`bottomJump`/`_programmaticJump`/`_userDetached`
  → 位置语义 + 一次性 token（4-05 / 4-02 / 1-01 的根）。
- **删 3｜`maxScrollExtent` 当判据**：补白、补页、贴底一律改看"原因量"
  （内容实测高 / 距最新端像素距离）（1-15 / 2-06 / 4-04 的根）。

做完七期，代码里**只允许一条**改 `pixels` 的路，且**没有一处**"帧后猜位置"。

---

## 1. 先定尺：改前基线 → 改后门槛

改前基线（真机视频 `卡顿、跳动、甚至滚到一半没法继续滚了。mp4`，10.63s / 30fps /
319 帧，逐步测量见因素清单 §9）：

| 指标 | 改前实测 |
| --- | --- |
| 画面变化次数 | **25 次**（≈0.4 次/秒） |
| 连续位移帧（相邻帧位移 < 8px） | **4 帧（1.6%）**，且全挤在 0.13s 里 |
| 单帧最大位移 | **469px**；常见台阶 150px（重复 9 次） |
| 静止 > 0.5s 的次数 | **3 次**（最长 1.37s） |
| 插一张工具卡（内容≈一屏） | **两帧回弹 ~150px**（探针 P1/P2） |
| 上滚 249px | **被复位回原状态，两次**（−249px ×2，前后帧逐像素相同） |
| 工具密集会话可滚高度 | **249px**（折叠行吃光） |

改后门槛（S4 结束即可量，S7 结束后复量）：

- 连续位移帧占比 **≥ 60%**；单帧最大位移 **≤ 8px**（滚轮 / 插入推进 / 跳底全部）；
- 静止 > 0.5s 的次数 = **0**（唯一例外：无输入的等待，用"有无输入事件"区分）；
- 插入 / 折叠 / 裁剪 / 补页 / 换字体 / 换宽度：**锚点行屏幕位置位移 ≤ 0.5px**
  （唯一允许的位移是"贴底推进"，见 P-6）；
- 上滚后任何结构变化：位移 ≤ 0.5px、**零复位**；
- 工具密集会话的补页不再靠"折叠了多少行"决定，按像素触发。

---

## 2. 不变量（本计划冻结 7 条，实施期按编号核对）

与既有 I-1~I-8 的关系：**不改 I-1~I-7**；S2 落地时把 **I-8「补偿只允许两处」
升级为 P-3「补偿只允许一处（事务）」**，并同步修订
[scroll-model-rewrite-recon.md](scroll-model-rewrite-recon.md) 的 I-8 与 README 索引行。

- **P-1 位置真值只读**：帧后只读三元组 `(anchorMessageId, anchorDyInViewport, pixels)`；
  任何模块**不得自行估算**位置（禁 `_pixelsForTopOf` 这类"累加平均行高"的估算再用于落点）。
- **P-2 单写入口**：改 `pixels` 只经 `ScrollDriver.setTarget(...)`；**禁止**直接
  `jumpTo` / `correctPixels` / `ensureVisible`（含新代码）。
- **P-3 事务化布局变更**：任何会改行高或子项数的操作必须在 `AnchorTransaction` 内跑：
  `begin()` 快照 → 变更 → 布局 → `end()` 收敛；同一帧内完成，跨帧变更自动入队。
- **P-4 意图是一次性 token**：跨帧的"跳底 / 定位 / 交还用户"一律用 `jumpRequest++`
  或 `once` 对象，**消费即清**；禁止再用"面板里手工置 false 的布尔"。
- **P-5 判据只看原因量**：补白 / 补页 / 贴底按"内容实测高"与"距最新端像素距离"判定，
  **禁止用 `maxScrollExtent` 当判据**（I-7 的扩展，原文只禁了滑块）。
- **P-6 位移允许清单**：只承认三种位移——① 用户输入（滚轮/拖拽/键盘）、
  ② 事务收敛（保持锚点，净位移 0）、③ 贴底推进（新内容进入视口）。
  测试里出现第四种 = 回归。
- **P-7 每期可独立回滚**：每期一个提交序列 + 一个内部开关（`kScrollModelV2`，默认开）；
  回滚 = 关开关 + revert，不动数据、不动协议。

---

## 3. 七期：范围 / 根因 / 做法 / 验收 / 风险

顺序原则：**先有尺（S1）→ 先治"位置没人管"（S2、S3）→ 再治"怎么过去"（S4）→
再治"谁说了算"（S5）→ 再治"补页与窗口"（S6）→ 最后治"行高与渲染成本"（S7）**。
每期独立可发布、可回滚，且**不依赖后期**。

### S1 度量与门禁（零行为改动）

- **根因指向**：没有尺，任何"修好了"都是主观判断；上一轮的"命中 P0 未发现"就是缺尺。
- **做法**：
  1. 把 2026-11-26 的探针沉淀成可复用 harness
     `test/scroll_probe.dart`：逐帧采样 `pixels` / 锚点屏幕 y / `viewportDimension` /
     `maxScrollExtent`，输出"位移序列"饼（谁动了、动多少、几帧）；
  2. 把 §2 的 P-1…P-7 与 §4 的 TC-SC-01~16 写成 `test/scroll_invariants_test.dart`，
     **先在现行实现上跑成红**（红的就是基线，逐期转绿）；
  3. 把用户报的三症状各落一条可复现用例：①插卡回弹 ②上滚被复位 ③滚轮台阶。
- **文件**：`plugins/tree.ui.default/test/scroll_probe.dart`、`scroll_invariants_test.dart`
  （新增），不动 `lib/`。
- **验收**：`flutter test` 有 16 条 TC，红绿数量记录下来；CI 允许"已知红清单"，但
  **只许减不许增**。
- **风险**：探针本身可能测错 → 每条 TC 先用手工构造的已知位移自校验（例如人为
  `jumpTo(30)`，探针必须测出 30）。
- **规模**：约 400 行测试，0 行产品代码。**1 天。**

### S2 视口锚点事务（梁 1）

- **根因指向**：清单 1-16 / 3-03 / 3-04 / 2-07 —— 补偿分散在
  `_armAnchor`+`resolveAnchorDelta`+`correctPixels`（只在折叠点击布防）、
  `assertPixels` 帧后 `jumpTo`、面板 `ensureVisible`；**任何没布防的高度变化都不补偿**。
- **做法**：
  1. 新增 `ViewportAnchor`（`{id, dyInViewport}`）+ `AnchorTransaction`；
     `begin()` 在帧后量锚点（取视口内**最高**那条有 id 的行，避开零高度行），
     `end()` 用新布局反解 `targetPixels = s_anchor_new - dyInViewport`，交给 driver；
  2. 折叠、`replacePersisted`、字体/字号、窗口宽度、裁剪、补页全部包进事务
     （面板侧只调 `_runAnchorTransaction(() { ...setState... })`）；
  3. **删掉** `_armAnchor` / `resolveAnchorDelta` / `anchorBasePixels` / `assertPixels`
     四个字段与 `applyContentDimensions` 里的 `correctPixels` 分支（净删代码）。
- **验收**：TC-SC-03（折叠零位移）、TC-SC-06（字号）、TC-SC-07（宽度）、TC-SC-05（裁剪）。
- **风险**：事务在"布局中途"反解可能拿到未收敛的尺寸 → 只在 `end()`（帧后）反解，
  必要时追加一帧收敛；**不允许**在 `applyContentDimensions` 里重跑布局（旧手法，删掉）。
- **规模**：`message_list.dart` 约 −120/+200，`message_panel.dart` 约 +60。**2~3 天。**

### S3 底部补白一次算定（删 1｜直接命中用户报的"卡片从底部飞上来"）

- **根因指向**：清单 1-14 —— `_bottomFill` 由"帧后量 + `setState`"维护，而清理守卫用
  `maxScrollExtent > 0.5`；插一条卡先让 `max` 变正 ⇒ 清 0 ⇒ 下一帧重算 ⇒ **两帧回弹
  ~150px**（探针 P1/P2 复现、P3 为反例：不跨屏就不弹）。
- **做法**：
  1. 把"内容不足一屏时钉在顶部、向下生长"改成**布局期一次算定**：`LayoutBuilder` 里
     用已测量的内容高（sliver 的 `paintExtent` 累计，来源是布局结果而非帧后回调）
     算 `leadPadding = max(0, viewport - content)`，作为 `SliverPadding`/`Padding` 的
     **确定值**参与布局 —— 同一帧里只有一次解法；
  2. 判据换成**原因量**（P-5）：`contentHeight >= viewportHeight` 才算"能滚"，
     不再看 `maxScrollExtent`；
  3. 删掉 `_setBottomFill` 的 `setState` 与"能滚就清 0"分支（净删代码）。
- **验收**：探针 P1/P2 的 `viewportDimension` **逐帧恒定**、锚点 y 单调（≤1 次变化）；
  P3 反例仍不动；TC-SC-01/02。
- **风险**：`SliverPadding` 在反向列表里的前后语义容易搞反（"bottom" = leading edge）
  → 先用 S1 的探针把"视觉上顶对齐"钉死，再改。
- **规模**：`message_list.dart` 约 −60/+80。**1~2 天。**

### S4 目标制滚动推进器（梁 2）

- **根因指向**：清单 5-07（滚轮零插值/零合并）、1-13（插入同帧顶掉一行）、
  5-02/5-06（拖拽/点击跳变）——**位移量对，过程没有**。
- **做法**：
  1. 新增 `ScrollDriver`：持 `targetPixels`，`Ticker` 每帧按
     `easeOutCubic`（或临界阻尼）逼近，收敛即停表（**没目标绝不占帧**，与气泡
     reveal ticker 同一纪律）；
  2. `pointerScroll` 不再直接改 `pixels`，而是**累加 target**（多事件合并，
     掉帧自然变成"追得更快"而不是"跳一级"）；
  3. 事务收敛、跳底、定位、滑块 seek 全部走 driver（`setTarget(..., duration:)`）；
  4. 删 `_scheduleJumpToBottom` / `_jumpTo` / `_pumpSeekCorrection` 的直接写入口。
- **验收**：TC-SC-09/10/11/15；门槛"单帧最大位移 ≤ 8px、静止 >0.5s 次数 0"。
- **风险**：与 `ClampingScrollPhysics` 的夹取冲突（到边界时 driver 要认输，不能对抗）→
  边界一帧内直接 `setTarget(clamp)`；其次是与流式增量抢帧 → driver 与 reveal ticker
  共用"有活才排帧"的判据。
- **规模**：新增 `scroll_driver.dart` 约 150 行，`message_list.dart` 约 −80/+60。
  **2~3 天。**

### S5 跟随语义 token 化（删 2）

- **根因指向**：清单 4-05（`bottomJump` 跨事件残留，上滚时把视口拽回底部）、
  4-02（回底与用户滚动同帧竞争）、1-01（`following` 与程序化跳转两套状态机）。
- **做法**：
  1. 删 `bottomJump`（面板 19 处赋值）、`_programmaticJump`、`_userDetached` 三个布尔；
  2. `following` 不再是"状态"，而是**由位置推导的只读量**：
     `following == (distanceToNewest <= 1px)`；
  3. "跳底"变成一次性 token：`feed.jumpRequest++`，driver 消费后回 0；
  4. 滑块/定位/自愈统一走"设新锚点 + 事务收敛"，不再有"我先 jumpTo 再算"。
- **验收**：TC-SC-08（上滚 300px 后任意结构变化 ≤0.5px、零复位）、TC-SC-04、4-01 回归。
- **风险**：`following` 从可写变只读会牵动面板与 feed 的 30+ 处读写 → 用 S1 的门禁
  逐条转绿，**不许**保留"兼容布尔"。
- **规模**：`message_panel.dart` 约 −120/+60，`message_feed.dart` 约 −40/+30，
  `message_list.dart` 约 −100/+50。**3 天。**

### S6 窗口填充按像素 + 下标显式区间（删 3）

- **根因指向**：清单 1-15（折叠行吃光可滚高度 ⇒ 一滚撞墙）、2-06（前瞻用算术下标 ⇒
  失效）、2-03（加载中丢坐标）、4-04（`exhausted` 只看"空页"）、1-02（下标空洞毒化映射）、
  2-01（补页接不上就整窗重载 + 跳底）。
- **做法**：
  1. 补页判据换成**像素**：`可滚余量 < N 屏`（N 初值 1.5）就预取下一页，哨兵只负责
     "显示加载中"，不再负责触发；
  2. 窗口下标从"首行下标 − g 的算术"改成**显式区间表**（`[oldest, newest]` +
     稀疏 `id → global`），空洞不再是毒；
  3. 补页失败**不再整窗重载**：保留当前窗口，在缺口处插一行"缺页占位"并退避重试
     （数据层根治，替掉 `_olderAnchorHealed` 的自愈 + `_reloadTail`）；
  4. `exhausted` 由服务端显式信号（`has_more=false`）决定，不由"返回空页"猜。
- **验收**：TC-SC-12（工具密集会话可滚 <300px 仍能连续补页）、TC-SC-13（补页失败不跳底）、
  TC-SC-14（`total` 领先 3 时映射不偏）。
- **风险**：预取变积极 ⇒ 请求量上升（用"每屏最多 1 次 + 200ms 合并"兜住）；
  缺口占位是新 UI 元素，需要一次视觉确认。
- **规模**：`message_feed.dart` 约 −80/+150，`message_panel.dart` 约 −150/+120。
  **3~4 天。**

### S7 行高稳定与渲染成本（最后做）

- **根因指向**：清单 1-03（豁免集合随插入平移 ⇒ 行高自己变）、1-05/1-07（每帧三次全子项
  遍历 + `_runAt` 扫整段）、3-01（流式全文重解析）、2-04/2-05（工具帧整面板重建）、
  6-01（合并窗口与长消息不联动）。
- **做法**：
  1. 折叠豁免从"最新 N 个**局部下标**"改成"锚在 run 上的**标记**"，插入不再平移；
  2. `_runAt` 结果按 `(revision, 段首 id)` 缓存，滚出视口即失效；
  3. Markdown 按块增量渲染（块级缓存 + 只重解析最后一个未闭合块），彻底去掉 O(n²)；
  4. `msg_start`/`msg_end`/`tool_*` 由"整面板 setState"改成"定位到行 + 局部通知"。
- **验收**：TC-SC-16（2000 行窗口、200 张工具卡，滚动帧 p95 ≤ 8ms）；1-03 的位移归零。
- **风险**：Markdown 增量渲染是最大的改动面（渲染正确性），必须带"全量 vs 增量"
  等价性测试（同一条消息，两种路径渲染出的字符/块数一致）。
- **规模**：`message_list.dart` 约 −150/+150，`message_cards.dart`/`markdown_view.dart`
  约 −200/+400，`message_panel.dart` 约 −80/+80。**5~7 天。**

---

## 4. 验收用例（TC-SC-01~16）

| # | 场景 | 判据 | 转绿期 |
| --- | --- | --- | --- |
| 01 | 阅读态（pixels>0）插一张工具卡 | 锚点行位移 ≤ 0.5px | S2/S3 |
| 02 | 贴底、内容≈一屏，插一张卡 | `viewportDimension` 恒定，锚点 y 单调（不再 152→0→122） | S3 |
| 03 | 折叠组展开/收起 | 锚点零位移（TC-COLLAPSE-01 新模型口径） | S2 |
| 04 | 向上补页 | 像素与锚点零位移（既有 N1/N2） | 已绿，S5 不得回退 |
| 05 | 旧侧裁剪 | 像素与锚点零位移（既有 N7） | 已绿，S2 不得回退 |
| 06 | 换字号 / 字体 | 锚点零位移 | S2 |
| 07 | 拖分栏改宽度 | 锚点零位移（现在是"内容跟着跑"） | S2 |
| 08 | 上滚 300px 后来了工具帧/裁剪/轮询 | 位移 ≤ 0.5px、**零复位** | S5 |
| 09 | 贴底时新消息到达 | 位移连续，单帧 ≤ 8px | S4 |
| 10 | 连续滚轮 20 格 | 无 >8px 台阶；停手 100ms 内静止（不常驻排帧） | S4 |
| 11 | 滑块拖拽 | 指针不脱手，拇指几何与报出的下标同源 | S4 |
| 12 | 工具密集会话（可滚 <300px） | 能连续补页，不再"一滚撞墙" | S6 |
| 13 | 补页失败 | 不整窗重载、不跳底，保留窗口 + 占位 | S6 |
| 14 | `total` 领先窗口 3 | 滑块/定位/裁剪映射不偏 | S6 |
| 15 | 定位到某条（at=） | 一次收敛（无 300ms 动画 + 校正叠加） | S4 |
| 16 | 2000 行 + 200 张工具卡滚动 | 帧 p95 ≤ 8ms | S7 |
| 17 | UI 热重启（挂起续跑）时人在历史深处 | 落回**原阅读位置**、锚点位移 ≤ 0.5px、**无动画滚动**；贴底时 `following` 为真、新消息照常进视口（见 §10 / 因素 2-11） | S5 |

---

## 5. 补丁红线（每期合并前逐条自查）

1. **不许新增** `jumpTo` / `correctPixels` / `ensureVisible` 调用点；现有调用点每期只许减少。
2. **不许用 `setState` 做位置修正**；位置只经事务与 driver。
3. **不许新增跨帧布尔**；跨帧意图必须是计数器或一次性对象（消费即清）。
4. **不许用 `maxScrollExtent` 当判据**（补白/补页/贴底一律看原因量）。
5. **每期只动一类机制**；跨类改动拆期，不许"顺手一起修"。
6. **没有 TC 的修复不合并**；红了要写进"已知红清单"并给期号，不许 `skip`。
7. **不许为绕过一个症状加一层补偿**（本仓历史上 `padAboveStamp`/`contentShiftStamp`
   就是这么长出来的，最终整套删掉 —— 别再来一次）。

---

## 6. 依赖与排期（粗估，不含真机验收往返）

```
S1 度量 ──┬─ S2 锚点事务 ──┬─ S3 补白（可并行，互不依赖）
          │                ├─ S5 跟随语义
          └─ S4 推进器 ────┘        └─ S6 窗口填充 ── S7 行高与渲染
```

| 期 | 依赖 | 粗估 | 可独立发布 |
| --- | --- | --- | --- |
| S1 | — | 1 天 | 是（只有测试） |
| S2 | S1 | 2~3 天 | 是 |
| S3 | S1 | 1~2 天 | 是（**优先做**：用户当下最烦的插卡回弹就这条） |
| S4 | S1（可与 S2/S3 并行，不同文件为主） | 2~3 天 | 是 |
| S5 | S2 | 3 天 | 是 |
| S6 | S5 | 3~4 天 | 是 |
| S7 | S6 | 5~7 天 | 是 |

合计约 **17~23 人日**（不含真机验收与热修往返）。每期结束出一个安装包做真机验收。

---

## 7. 明确不做（避免计划膨胀）

- 不换渲染框架、不回退成正序列表（I-1 已拍板）、不改服务端分页协议（本计划零协议改动）；
- 不做"行高缓存 / 字体度量预计算"（S7 只做块级缓存，度量仍实测）；
- 不动 `tree.ui.feishu` 侧边车与终端面板的滚动（只共享 `ScrollDampingService`）；
- 不顺手改 UI 视觉（除 S6 的缺口占位一处，需单独确认）。

---

## 8. 风险与回滚

| 风险 | 触发迹象 | 处置 |
| --- | --- | --- |
| 事务与布局收敛打环（帧内反复求值） | 单帧布局次数 > 2 | 事务 `end()` 只允许一帧内一次反解；超一帧改为下一帧用 driver 收敛 |
| driver 与 physics 夹取打架 | 到边界时抖动 | 边界直接 `setTarget(clamp)`，不做对抗 |
| `following` 只读化波及面大 | 面板 30+ 处编译错 | 分两次提交：先加只读量+兼容写，再删布尔（同一期内） |
| Markdown 增量渲染不等价 | 渲染差异 | 等价性测试（全量 vs 增量逐块比对），不绿不合并 |

回滚单位 = **一期 + 一个开关**（`kScrollModelV2`）；S6 之后回滚只需关开关，
不改数据、不改协议、不需要重建安装包以外的操作。

---

## 9. 待拍板（实施前需要用户定）

- **D1 贴底推进的观感**：新内容进入视口要走"80~120ms 缓动推进"（推荐，配合 S4），
  还是保持立刻到位？前者更顺，后者更"稳"。
- **D2 滚轮插值曲线**：`easeOut`（跟手、尾巴快）还是临界阻尼（更像原生）？二选一，S4 定。
- **D3 "可滚高度被吃光"的取向**：A「按像素补页」（本计划，纯行为，不改视觉，推荐）／
  B「折叠组给最小高度」（看得见但改视觉）／C「窗口常驻 N 屏」（内存换稳定）。
- **D4 期节奏**：每期一个安装包做真机验收，还是攒 2~3 期一起？
- **D5 S5 是否同意删掉 3 个跨帧布尔**（会动面板 **17 处**赋值，虽然净删代码）。

---

## 10. 二次核对（2026-11-26，只读，未动代码）

计划落档后仓库又前进两步：`96a04a3`（随包 UI 插件改 archive 分发，不动代码）与
`51d603d`（**UI 插件热重启改挂起续跑**，动了 `message_list.dart` / `message_panel.dart`）。
开工前按当前工作区核了一遍：

1. **S1 仍未开工**：`plugins/tree.ui.default/test/` 里没有 `scroll_probe.dart` /
   `scroll_invariants_test.dart`；TC-SC-01~17 一条都还没落。
2. **既有因素全部仍成立**（逐条按代码复核，行为未变）：4-05 的 `_clearWindow`（`:834`）
   与 `trimOlder` 后 `_scrollRevision++`（`:1422`）**仍然不复位 `_bottomJump`**；
   1-14 的 `_updateBottomFill` 仍以 `maxScrollExtent > 0.5` 为守卫（`:635`）；
   5-07 仍零插值（`:275`）；5-01 的 `_thumb` 传 `visibleCount`（`:244`）而 `_seek`
   不传（`:436-454`）。
3. **新增 1 条因素 2-11（P2）+ 验收用例 TC-SC-17**：挂起续跑的快照锚点是
   `feed.loadedList.first.id`（窗口**最新**那一行，不是视口首个可见行），`following`
   存了但没人读；恢复时先跳底、再用 `ensureVisible(300ms)` 定位 ⇒ 阅读位置丢失 +
   动画叠加 + `following` 落成假导致新消息进缓冲不显示。详见因素清单 §2-11。
   **归期建议**：并入 S5（跟随语义 token 化）——它和 4-01/4-02 是同一族问题，
   S5 的"`following` 由位置推导"一旦落地，这条自动收口；只额外需要
   "续跑锚点取视口首个可见行 + 恢复不带动画"两小步。
4. **计划引用的探针源已不在工作区**：`.self/probe/insert_probe_test.dart` 不存在
   （`.self/probe/` 现有的是 `sliver_seek_probe_test.dart` 等），S1 需按因素清单
   §9.1 的表格**重建**，别按"复用现成文件"排期。
5. **坐标已按当前工作区刷新**（见下方附录），面板侧漂移最大（`_clearWindow`
   定义从 :3615 区移到 :834）。

---

## 附：本档引用的代码坐标（按 2026-11-26 二次核对后的工作区）

- 列表与位置：[message_list.dart](../plugins/tree.ui.default/lib/ui/widgets/message_list.dart)
  —— `:275` `pointerScroll`、`:281` `applyContentDimensions`（`correctPixels` 分支）、
  `:398` `didUpdateWidget`（`bottomJump` 判据）、`:426` `_scheduleJumpToBottom`、
  `:449` `_flushCoordinate`（`assertPixels`）、`:626` `_updateBottomFill`、
  `:635` 补白守卫（`maxScrollExtent > 0.5`）、`:653` `_setBottomFill`、
  `:702` `_pixelsForTopOf`、`:715` `_onScrollNotification`、`:750` `_jumpTo`、
  `:892` `_armAnchor`、`:978` `ensureVisible`、`:1117`/`:1129` 折叠组员零高度。
- 窗口模型：[message_feed.dart](../plugins/tree.ui.default/lib/ui/services/message_feed.dart)
  —— `_nextGlobal` / `localOfGlobal` / `atTailIgnoringBuffer` / `trimOlder` / `mergeBuffered`；
  `:223` `following`、`:232` `jumpStamp`（跳底意图的既有计数器，S5 可直接承接）。
- 面板：[message_panel.dart](../plugins/tree.ui.default/lib/ui/widgets/message_panel.dart)
  —— `:189` `_bottomJump` 字段、`:834` `_clearWindow`（**不复位 `_bottomJump`**）、
  `:1402`/`:1410` `_trimFeed`、`:1422` `trimOlder` 后 `_scrollRevision++`、
  `:3469` `_reconcileTail` / `:3493` `replacePersisted`、
  `:2262`/`:3648`/`:3673`/`:3778` `_clearWindow` 调用点、
  `:354`/`:1085-1105` 热重启续跑锚点（`:3870-3886` 快照、`:3877` 未消费的 `following`）。
- 输入与阻尼：[scroll_damping_service.dart](../plugins/tree.ui.default/lib/ui/scroll_damping_service.dart)、
  [message_scrollbar.dart](../plugins/tree.ui.default/lib/ui/widgets/message_scrollbar.dart)
  —— `:244` `_thumb`（传 `visibleCount`）、`:436-454` `_seek`（**漏传** `visibleCount`）、
  `:265` `_smoothTop`。
- 因素清单与取证：
  [conversation-scroll-jitter-recon.md](conversation-scroll-jitter-recon.md)（§9 视频取证、§9.1 探针、
  §10 二次核对与坐标对照）；探针源 `.self/probe/insert_probe_test.dart`（**当前工作区已不存在，S1 需重建**）。

