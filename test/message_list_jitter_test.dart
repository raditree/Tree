// 中栏消息列表「滚动抖动 / 懒加载后更明显」的回归测试（用户 2026-10-03 真机报告）。
//
// 背景与根因（详见 `.self/recon-midlist-jitter.md` §2）：
//   上方补页的**补偿量取错了对象**——旧实现用
//     `delta = maxScrollExtent - lastMaxExtent`
//   当"视口上方长高了的高度"。但 `ListView.builder` 没到底时，
//   `maxScrollExtent` 是**外推值**（SDK `RenderSliverList.estimateMaxScrollOffset`：
//   `trailingScrollOffset + 平均子项高 × 剩余条数`），误差 **∝ 剩余条数**：
//   真机会话几千条、视口在中段 ⇒ 单帧 delta 轻松上千像素，而"上方真正长高的高度"
//   最多几百像素（只有 cache extent 内那几行会被布局）⇒ 补偿量被噪声主导，
//   视口被随机搬走上千像素。而 `shiftAbove` 只在补页帧置位 ⇒
//   噪声恰好只在懒加载那一帧被施加 ⇒ "触发一次懒加载后抖动非常厉害"。
//
// 为什么既有用例挡不住：`test/message_list_scroll_test.dart` 的补页用例跑在
// `total = 40` 的槽位表上（`reachedEnd` 立刻为真 ⇒ 估算=精确 ⇒ delta 恰好正确）。
// 本文件所有用例都建在**长会话中段**（视口下方还留着上千条未构建的占位槽），
// 这才是真机规模：估算=外推，噪声才会出现。
//
// 本文件只做断言，不改动任何既有测试文件。

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/widgets/message_list.dart';

/// 视口尺寸（px）：补偿量的兜底限额是"视口高 × 2"，断言里要用到。
const double _viewportHeight = 600;

void main() {
  ScrollPosition positionOf(WidgetTester tester) => tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position;

  /// 列表内部那个 [RenderSliverList]（懒构建子项都挂在它下面）
  RenderSliverList? sliverOf(WidgetTester tester) {
    for (final RenderSliverList sliver
        in tester.allRenderObjects.whereType<RenderSliverList>()) {
      return sliver;
    }
    return null;
  }

  /// 从渲染树读"这一趟真正布局过的子项"：全局下标 → 内容坐标里的顶边。
  ///
  /// 渲染树里 `SliverMultiBoxAdaptorParentData.layoutOffset` 才是真值——
  /// 它由**实测子项高度**逐个累加得来，不是外推估算（`maxScrollExtent` 才是估算）。
  /// `childScrollOffset == null` 的是被 `AutomaticKeepAlive` 留在树里的屏外子项。
  Map<int, double> laidOutTops(WidgetTester tester) {
    final Map<int, double> out = <int, double>{};
    final RenderSliverList? sliver = sliverOf(tester);
    if (sliver == null) return out;
    RenderBox? child = sliver.firstChild;
    while (child != null) {
      final double? top = sliver.childScrollOffset(child);
      final ParentData? data = child.parentData;
      if (top != null &&
          data is SliverMultiBoxAdaptorParentData &&
          data.index != null) {
        out[data.index!] = top;
      }
      child = sliver.childAfter(child);
    }
    return out;
  }

  /// 某个已布局子项的**底边**（内容坐标）；不在这一趟布局里返回 null。
  ///
  /// 与实现同口径：补偿量 = 锚点子项**底边**的实测位移（顶边差 + 它自己的高度变化）。
  double? laidOutBottom(WidgetTester tester, int index) {
    final RenderSliverList? sliver = sliverOf(tester);
    if (sliver == null) return null;
    RenderBox? child = sliver.firstChild;
    while (child != null) {
      final ParentData? data = child.parentData;
      if (data is SliverMultiBoxAdaptorParentData && data.index == index) {
        final double? top = sliver.childScrollOffset(child);
        return top == null ? null : top + child.size.height;
      }
      child = sliver.childAfter(child);
    }
    return null;
  }

  /// 视口顶在这一趟布局里的内容坐标（sliver 自己的坐标系，已扣掉列表内边距）
  double viewportTopOf(WidgetTester tester) =>
      sliverOf(tester)!.constraints.scrollOffset;

  /// 视口顶落在的那个已布局子项的下标
  int pivotIndex(WidgetTester tester) {
    final RenderSliverList? sliver = sliverOf(tester);
    expect(sliver, isNotNull, reason: '测试前提：列表已布局');
    final double viewportTop = sliver!.constraints.scrollOffset;
    int? pivot;
    double? best;
    RenderBox? child = sliver.firstChild;
    while (child != null) {
      final double? top = sliver.childScrollOffset(child);
      final ParentData? data = child.parentData;
      if (top != null &&
          data is SliverMultiBoxAdaptorParentData &&
          data.index != null &&
          top <= viewportTop + 0.01 &&
          (best == null || top > best)) {
        best = top;
        pivot = data.index;
      }
      child = sliver.childAfter(child);
    }
    expect(pivot, isNotNull, reason: '测试前提：视口顶落在某个已布局子项上');
    return pivot!;
  }

  /// 与实现**同口径**的补偿锚点：
  /// ① 视口顶之下的第一条已布局**真消息**；② 没有就取视口顶之上的最后一条已布局真消息。
  int anchorIndex(WidgetTester tester, _JitterHarnessState state) {
    final Map<int, double> tops = laidOutTops(tester);
    final double viewportTop = viewportTopOf(tester);
    int? below;
    double? belowTop;
    int? above;
    double? aboveTop;
    tops.forEach((int index, double top) {
      if (!state.isLoaded(index)) return;
      if (top >= viewportTop - 0.01) {
        if (belowTop == null || top < belowTop!) {
          belowTop = top;
          below = index;
        }
      } else {
        if (aboveTop == null || top > aboveTop!) {
          aboveTop = top;
          above = index;
        }
      }
    });
    if (below != null) return below!;
    expect(above, isNotNull,
        reason: '测试前提：视口附近的 cache 区里有真消息（现在只有占位槽）');
    return above!;
  }

  /// 视口**上方**、这一趟已被布局的**占位槽**——真机补页正是把这一段换成真消息。
  List<int> placeholdersAboveViewport(
      WidgetTester tester, _JitterHarnessState state) {
    final double viewportTop = viewportTopOf(tester);
    final List<int> out = laidOutTops(tester)
        .entries
        .where((MapEntry<int, double> e) =>
            e.value < viewportTop - 0.01 && !state.isLoaded(e.key))
        .map((MapEntry<int, double> e) => e.key)
        .toList()
      ..sort();
    return out;
  }

  String textOf(int index) => '消息 $index';

  /// 造一个**长会话中段**的现场（真机规模）：
  /// - `total = 3000`（视口下方还留着上千条未构建的占位槽 ⇒ `maxScrollExtent` 是外推值）；
  /// - 视口停在中段（离末尾约 1500 条）；
  /// - 视口顶那一条**已加载成真消息**（模拟面板已经把这一段补回来）。
  Future<GlobalKey<_JitterHarnessState>> pumpMidList(WidgetTester tester) async {
    final GlobalKey<_JitterHarnessState> key = GlobalKey<_JitterHarnessState>();
    await tester.pumpWidget(_JitterHarness(key: key));
    await tester.pumpAndSettle();
    final ScrollPosition pos = positionOf(tester);
    pos.jumpTo(pos.maxScrollExtent / 2);
    await tester.pumpAndSettle();
    final int pivot = pivotIndex(tester);
    key.currentState!.load(pivot, 8);
    await tester.pumpAndSettle();
    expect(key.currentState!.windowFirst, greaterThan(200),
        reason: '测试前提：视口确实停在中段（下方还有上千条未构建）');
    expect(key.currentState!.total - key.currentState!.windowLast,
        greaterThan(200),
        reason: '测试前提：视口下方还有上千条未构建 ⇒ maxScrollExtent 是外推值');
    return key;
  }

  /// 造一个"**补页横跨视口顶**"的现场（A3）：
  /// 视口顶那一格是**缺口（占位槽）**，缺口下面接着已加载的真消息
  /// （= 用户正在读的那一段）——这正是面板 `splitGapAtViewportTop` 的
  /// `[first, gap.to)` 那一份落地后的形状。
  Future<GlobalKey<_JitterHarnessState>> pumpMidListWithGap(
    WidgetTester tester, {
    required int gap,
  }) async {
    final GlobalKey<_JitterHarnessState> key = GlobalKey<_JitterHarnessState>();
    await tester.pumpWidget(_JitterHarness(key: key));
    await tester.pumpAndSettle();
    final ScrollPosition pos = positionOf(tester);
    pos.jumpTo(pos.maxScrollExtent / 2);
    await tester.pumpAndSettle();
    // 视口顶落在 pivot 这一格上 ⇒ [pivot, pivot+gap) 留成缺口，再往下才是真消息
    final int pivot = pivotIndex(tester);
    key.currentState!.load(pivot + gap, 8);
    await tester.pumpAndSettle();
    expect(key.currentState!.windowFirst, greaterThan(200),
        reason: '测试前提：视口确实停在中段（下方还有上千条未构建）');
    return key;
  }

  group('长会话中段补页（maxScrollExtent 是外推值）', () {
    testWidgets('N1 视口上方补页：视口内锚点屏幕位置不变，且补偿量=锚点实测位移',
        (WidgetTester tester) async {
      final GlobalKey<_JitterHarnessState> key = await pumpMidList(tester);
      final _JitterHarnessState state = key.currentState!;
      final ScrollPosition pos = positionOf(tester);

      final int anchor = anchorIndex(tester, state);
      final String anchorText = textOf(anchor);
      expect(find.text(anchorText).evaluate(), isNotEmpty,
          reason: '测试前提：锚点消息在视口里');
      final double dyBefore = tester.getTopLeft(find.text(anchorText).first).dy;
      final double pixelsBefore = pos.pixels;
      final double bottomBefore = laidOutBottom(tester, anchor)!;

      // 面板在**视口上方**补页：cache 区里那几格占位槽换成真消息（比占位槽高）
      final List<int> targets = placeholdersAboveViewport(tester, state);
      expect(targets, isNotEmpty,
          reason: '测试前提：视口上方 cache 区内有占位槽（真机补页补的就是这一段）');
      state.fill(targets);
      await tester.pumpAndSettle();

      // ① 视口内的锚点：屏幕位置不变（≤1px）
      expect(find.text(anchorText).evaluate(), isNotEmpty,
          reason: '补页后锚点被搬出了视口 —— 正是真机看到的"抖"');
      final double dyAfter = tester.getTopLeft(find.text(anchorText).first).dy;
      expect((dyAfter - dyBefore).abs(), lessThanOrEqualTo(1.0),
          reason: '补页后视口被推走了：锚点 before=$dyBefore after=$dyAfter '
              '（补偿量取 maxScrollExtent 差时，这里会随机跳上千像素）');

      // ② 补偿量 == 锚点在内容坐标里的**实测**位移（不是外推噪声）
      final double? bottomAfter = laidOutBottom(tester, anchor);
      expect(bottomAfter, isNotNull, reason: '补页后锚点应仍在布局范围内');
      final double moved = pos.pixels - pixelsBefore;
      expect((moved - (bottomAfter! - bottomBefore)).abs(),
          lessThanOrEqualTo(1.0),
          reason: '补偿量应等于锚点的实测位移 '
              '${(bottomAfter - bottomBefore).toStringAsFixed(1)}，'
              '实际补了 ${moved.toStringAsFixed(1)}');

      // ③ 方向与真实增长一致，且远小于"上千像素"
      expect(moved, greaterThan(0),
          reason: '上方长高了，offset 要跟着往下走才钉得住同一段内容');
      expect(moved.abs(), lessThanOrEqualTo(_viewportHeight * 2),
          reason: '单帧补偿不得超过两屏（超过就是外推噪声，宁可不补也别错补）');
    });

    testWidgets('N2 连续多帧「滚动 + 补页」：相邻帧位移不出现符号翻转',
        (WidgetTester tester) async {
      final GlobalKey<_JitterHarnessState> key = await pumpMidList(tester);
      final _JitterHarnessState state = key.currentState!;
      final ScrollPosition pos = positionOf(tester);

      // 逐帧：用户继续上滚 120px（新占位槽进入视口上方的 cache 区）+ 面板补一格
      const double scrollStep = -120;
      final List<double> samples = <double>[pos.pixels];
      for (int frame = 0; frame < 6; frame++) {
        pos.jumpTo(pos.pixels + scrollStep);
        await tester.pumpAndSettle();
        final List<int> targets = placeholdersAboveViewport(tester, state);
        expect(targets, isNotEmpty,
            reason: '测试前提（第 $frame 帧）：视口上方 cache 区里有占位槽');
        state.fill(<int>[targets.last]);
        samples.add(pos.pixels);
      }

      final List<double> deltas = <double>[];
      for (int i = 1; i < samples.length; i++) {
        deltas.add(samples[i] - samples[i - 1]);
      }
      // 抖动 = 位移方向反复翻转（每次补页都往随机方向跳一段）
      int flips = 0;
      int? lastSign;
      for (final double d in deltas) {
        if (d.abs() < 0.5) continue;
        final int sign = d > 0 ? 1 : -1;
        if (lastSign != null && sign != lastSign) flips++;
        lastSign = sign;
      }
      expect(flips, lessThanOrEqualTo(1),
          reason: '相邻帧位移出现 $flips 次符号翻转（抖动）：'
              'deltas=${deltas.map((double d) => d.toStringAsFixed(1)).toList()}');
      // 单帧位移不许出现"几千像素"级别的乱跳
      for (final double d in deltas) {
        expect(d.abs(), lessThanOrEqualTo(_viewportHeight * 2 + scrollStep.abs()),
            reason: '单帧位移 ${d.toStringAsFixed(1)}px 远超滚动步进 + 两屏 —— '
                '补偿量取的是外推总高差（噪声 ∝ 剩余条数）：'
                'deltas=${deltas.map((double d) => d.toStringAsFixed(1)).toList()}');
      }
    });

    testWidgets('N3 补页前后：同一条消息不换元素身份、状态不串',
        (WidgetTester tester) async {
      final GlobalKey<_JitterHarnessState> key = await pumpMidList(tester);
      final _JitterHarnessState state = key.currentState!;

      final int anchor = anchorIndex(tester, state);
      final String anchorText = textOf(anchor);
      final Element? itemBefore = _itemElement(tester, anchorText);
      expect(itemBefore, isNotNull,
          reason: '测试前提：锚点消息（含定位 key 的槽位元素）在视口里');
      final Key? keyBefore = (itemBefore!.widget as KeyedSubtree).key;

      final List<int> targets = placeholdersAboveViewport(tester, state);
      expect(targets, isNotEmpty, reason: '测试前提：视口上方 cache 区里有占位槽');
      state.fill(targets);
      await tester.pumpAndSettle();

      final Element? itemAfter = _itemElement(tester, anchorText);
      expect(itemAfter, isNotNull,
          reason: '补页后找不到锚点消息的槽位元素（视口被搬走了 / 元素被换掉）');
      expect(identical(itemBefore, itemAfter), isTrue,
          reason: '同一条消息（id 不变、全局下标不变）的 Element 被重建了 ⇒ '
              '它的 State（选中态 / 展开态 / 滚动位置）会丢，甚至串到别的消息上');
      expect(identical(keyBefore, (itemAfter!.widget as KeyedSubtree).key), isTrue,
          reason: '同一条消息的定位 key 被换成了新实例 ⇒ 定位 / 高亮会指错元素');
    });

    testWidgets('N4 视口内（视口顶以下）占位换真消息：视口顶那一条不动',
        (WidgetTester tester) async {
      final GlobalKey<_JitterHarnessState> key = await pumpMidList(tester);
      final _JitterHarnessState state = key.currentState!;
      final ScrollPosition pos = positionOf(tester);

      final int anchor = anchorIndex(tester, state);
      final String anchorText = textOf(anchor);
      final double dyBefore = tester.getTopLeft(find.text(anchorText).first).dy;
      final double pixelsBefore = pos.pixels;

      // 这一段没有任何补页标记（A3 的 contentShiftStamp 由面板负责发）：
      // 列表侧就不该补偿、更不该自己算错量
      final double viewportTop = viewportTopOf(tester);
      final List<int> inside = laidOutTops(tester)
          .entries
          .where((MapEntry<int, double> e) =>
              e.value >= viewportTop && !state.isLoaded(e.key))
          .map((MapEntry<int, double> e) => e.key)
          .toList()
        ..sort();
      expect(inside, isNotEmpty,
          reason: '测试前提：视口内（视口顶以下）还有占位槽');
      state.fill(<int>[inside.first], padAbove: false);
      await tester.pumpAndSettle();

      expect((pos.pixels - pixelsBefore).abs(), lessThanOrEqualTo(1.0),
          reason: '没有补页标记就不该动 offset（补偿只由面板的信号触发）');
      final double dyAfter = tester.getTopLeft(find.text(anchorText).first).dy;
      expect((dyAfter - dyBefore).abs(), lessThanOrEqualTo(1.0),
          reason: '视口顶那一条被推走了：before=$dyBefore after=$dyAfter');
    });

    testWidgets('N5 补页横跨视口顶（A3）：视口顶那条真消息**以下**整段不动',
        (WidgetTester tester) async {
      // 现场：视口顶那一格是**缺口（占位槽）**，缺口下面才接着已加载的真消息
      // —— 这正是面板 `splitGapAtViewportTop` 的 `[first, gap.to)` 那一份落地的形状。
      const int gap = 6;
      final GlobalKey<_JitterHarnessState> key =
          await pumpMidListWithGap(tester, gap: gap);
      final _JitterHarnessState state = key.currentState!;
      final ScrollPosition pos = positionOf(tester);

      // 用户正在读的那一段：缺口下面的第一条真消息
      final int anchor = anchorIndex(tester, state);
      final String anchorText = textOf(anchor);
      // 再往下的那一条（"整段不动"的第二根探针）
      final String deepText = textOf(anchor + 1);
      expect(find.text(anchorText).evaluate(), isNotEmpty,
          reason: '测试前提：缺口下面那条真消息在视口里（它才是用户正在读的）');
      final double dyBefore = tester.getTopLeft(find.text(anchorText).first).dy;
      final double deepDyBefore =
          tester.getTopLeft(find.text(deepText).first).dy;
      final double pixelsBefore = pos.pixels;
      final double topBefore = laidOutTops(tester)[anchor]!;

      // 面板补这一段缺口：横跨视口顶 ⇒ 走 contentShiftStamp（不是 padAboveStamp）
      final int pivot = pivotIndex(tester);
      final List<int> gapSlots = <int>[
        for (int i = 0; i < gap; i++)
          if (!state.isLoaded(pivot + i)) pivot + i,
      ];
      expect(gapSlots, isNotEmpty,
          reason: '测试前提：视口顶那一段是缺口（占位槽）');
      state.fill(gapSlots, padAbove: false, contentShift: true);
      await tester.pumpAndSettle();

      // ① 视口顶那条真消息：屏幕位置不变（≤1px）
      expect(find.text(anchorText).evaluate(), isNotEmpty,
          reason: '补页后锚点被搬出了视口');
      final double dyAfter = tester.getTopLeft(find.text(anchorText).first).dy;
      expect((dyAfter - dyBefore).abs(), lessThanOrEqualTo(1.0),
          reason: '补页横跨视口顶后，用户正在读的那一条被推走了：'
              'before=$dyBefore after=$dyAfter');

      // ② "以下整段不动"：offset 的补偿量 == 锚点顶边的实测位移
      //    （等号成立 ⇒ 锚点以下的内容在屏幕上的位置也没变）
      final double? topAfter = laidOutTops(tester)[anchor];
      expect(topAfter, isNotNull, reason: '补页后锚点应仍在布局范围内');
      final double moved = pos.pixels - pixelsBefore;
      expect((moved - (topAfter! - topBefore)).abs(), lessThanOrEqualTo(1.0),
          reason: '补偿量应等于锚点实测位移 '
              '${(topAfter - topBefore).toStringAsFixed(1)}，'
              '实际补了 ${moved.toStringAsFixed(1)}'
              '（差额就是"下方整段下移"的量）');

      // ③ 更靠下的真消息：屏幕位置同样不变 —— 整段都没被推走
      final double deepDyAfter = tester.getTopLeft(find.text(deepText).first).dy;
      expect((deepDyAfter - deepDyBefore).abs(), lessThanOrEqualTo(1.0),
          reason: '锚点下面那条也被推走了：before=$deepDyBefore '
              'after=$deepDyAfter');
    });

    testWidgets('N7a 淘汰视口上方的槽位（对照）：面板不发信号时，视口顶那条会被推走',
        (WidgetTester tester) async {
      const int gap = 6;
      final GlobalKey<_JitterHarnessState> key =
          await pumpMidListWithGap(tester, gap: gap);
      final _JitterHarnessState state = key.currentState!;
      final int pivot = pivotIndex(tester);
      // 视口**上方**那几格放成真消息：淘汰它们会让"上面的高度"变
      state.load(pivot - 4, 4);
      await tester.pumpAndSettle();

      final int anchor = anchorIndex(tester, state);
      final String anchorText = textOf(anchor);
      expect(find.text(anchorText).evaluate(), isNotEmpty,
          reason: '测试前提：视口里有真消息（用户正在读的那一段）');
      final double dyBefore = tester.getTopLeft(find.text(anchorText).first).dy;

      // **不发**补偿信号：列表不该自己动 ⇒ 上面缩短了多少，视口就被推走多少
      state.evict(<int>[pivot - 4, pivot - 3, pivot - 2, pivot - 1],
          signal: false);
      await tester.pumpAndSettle();
      final double dyAfter = tester.getTopLeft(find.text(anchorText).first).dy;
      expect((dyAfter - dyBefore).abs(), greaterThan(1.0),
          reason: '没有信号时列表不会补偿 —— 这正是"面板必须在淘汰那一帧发信号"的理由'
              '（before=$dyBefore after=$dyAfter）');
    });

    testWidgets('N7b 淘汰视口上方的槽位：面板发了信号 ⇒ 视口顶那条真消息不动',
        (WidgetTester tester) async {
      const int gap = 6;
      final GlobalKey<_JitterHarnessState> key =
          await pumpMidListWithGap(tester, gap: gap);
      final _JitterHarnessState state = key.currentState!;
      final ScrollPosition pos = positionOf(tester);
      final int pivot = pivotIndex(tester);
      state.load(pivot - 4, 4);
      await tester.pumpAndSettle();

      final int anchor = anchorIndex(tester, state);
      final String anchorText = textOf(anchor);
      final double dyBefore = tester.getTopLeft(find.text(anchorText).first).dy;
      final double pixelsBefore = pos.pixels;
      final double bottomBefore = laidOutBottom(tester, anchor)!;

      // 面板在淘汰那一帧发 contentShiftStamp（A2）：列表按实测位移补回来
      state.evict(<int>[pivot - 4, pivot - 3, pivot - 2, pivot - 1]);
      await tester.pumpAndSettle();

      final double dyAfter = tester.getTopLeft(find.text(anchorText).first).dy;
      expect((dyAfter - dyBefore).abs(), lessThanOrEqualTo(1.0),
          reason: '淘汰把"用户正在读的那一段"顶走了：before=$dyBefore '
              'after=$dyAfter');
      // 补偿量 = 锚点底边的实测位移（淘汰让上面缩短 ⇒ 补偿量是负的）
      final double? bottomAfter = laidOutBottom(tester, anchor);
      expect(bottomAfter, isNotNull, reason: '淘汰后锚点应仍在布局范围内');
      final double moved = pos.pixels - pixelsBefore;
      expect((moved - (bottomAfter! - bottomBefore)).abs(),
          lessThanOrEqualTo(1.0),
          reason: '补偿量应等于锚点底边的实测位移 '
              '${(bottomAfter - bottomBefore).toStringAsFixed(1)}，'
              '实际补了 ${moved.toStringAsFixed(1)}');
    });

    testWidgets('N6 补页在视口下方（A3）：视口不动、也不产生虚假补偿',
        (WidgetTester tester) async {
      final GlobalKey<_JitterHarnessState> key = await pumpMidList(tester);
      final _JitterHarnessState state = key.currentState!;
      final ScrollPosition pos = positionOf(tester);

      final int anchor = anchorIndex(tester, state);
      final String anchorText = textOf(anchor);
      final double dyBefore = tester.getTopLeft(find.text(anchorText).first).dy;
      final double pixelsBefore = pos.pixels;

      // 视口**底**之下的已布局占位槽（面板向下滚时补的就是这一段）
      final double viewportBottom = viewportTopOf(tester) + _viewportHeight;
      final List<int> below = laidOutTops(tester)
          .entries
          .where((MapEntry<int, double> e) =>
              e.value > viewportBottom && !state.isLoaded(e.key))
          .map((MapEntry<int, double> e) => e.key)
          .toList()
        ..sort();
      expect(below, isNotEmpty,
          reason: '测试前提：视口下方 cache 区里有占位槽');
      state.fill(<int>[below.first], padAbove: false, contentShift: true);
      await tester.pumpAndSettle();

      expect((pos.pixels - pixelsBefore).abs(), lessThanOrEqualTo(1.0),
          reason: '视口上方没长高 ⇒ 不该补（补了就是"虚假补偿"，又是一次抖动源）');
      final double dyAfter = tester.getTopLeft(find.text(anchorText).first).dy;
      expect((dyAfter - dyBefore).abs(), lessThanOrEqualTo(1.0),
          reason: '视口顶那一条被推走了：before=$dyBefore after=$dyAfter');
    });
  });
}

/// 取某条消息所在的槽位元素（`_buildItem` 给每条消息挂 `KeyedSubtree(key: itemKey)`）
Element? _itemElement(WidgetTester tester, String text) {
  for (final Element element in find
      .ancestor(of: find.text(text), matching: find.byType(KeyedSubtree))
      .evaluate()) {
    final Widget widget = element.widget;
    if (widget is KeyedSubtree && widget.key is GlobalKey) return element;
  }
  return null;
}

/// 测试宿主：槽位表按**全局下标**寻址（null = 还没加载的占位槽），
/// 与真机一致地长时间保持"长会话中段"的形态。
class _JitterHarness extends StatefulWidget {
  const _JitterHarness({super.key});

  @override
  State<_JitterHarness> createState() => _JitterHarnessState();
}

class _JitterHarnessState extends State<_JitterHarness> {
  final Map<int, ChatMessage> _loaded = <int, ChatMessage>{};

  /// 整份会话多少条（真机：几千条）
  int total = 3000;

  /// 面板"在视口上方补了页"的标记（列表据此补偿一次滚动位置）
  int padAboveStamp = 0;

  /// 面板"在视口里/视口下方补了页"的标记（A3：横跨视口顶的那一份）
  int contentShiftStamp = 0;

  /// 帧后报上来的视口区间（-1 = 还没报过）
  int windowFirst = -1;
  int windowLast = -1;

  bool isLoaded(int index) => _loaded.containsKey(index);

  /// 把 [from, from+count) 这一段放成真消息（占位槽 → 真消息）。
  ///
  /// [repeat] 追加长文本让这条消息明显**高于** 88px 的占位槽（真机就是这样：
  /// 占位槽恒 88px，真消息单行 ≈70px、长回答几百 px）。
  void load(int from, int count, {String prefix = '消息', int repeat = 0}) {
    setState(() {
      for (int i = 0; i < count; i++) {
        _loaded[from + i] = ChatMessage(
          id: '$prefix${from + i}',
          role: 'agent',
          content: '$prefix ${from + i}${' 补充内容' * repeat}',
          timestamp: DateTime(2026, 1, 1, 12, i % 60),
        );
      }
    });
  }

  /// 面板补页：把这几格占位槽换成真消息（真消息通常**高于** 88px 的占位槽）。
  ///
  /// [padAbove]：这一段是否整段都在视口上方（真机 `message_panel.dart` 只在
  /// 这种情况下 `padAboveStamp++`）。
  /// [contentShift]：这一段是否落在视口里/视口下方（真机传 `contentShiftStamp++`）。
  void fill(
    List<int> indices, {
    bool padAbove = true,
    bool contentShift = false,
    int repeat = 20,
  }) {
    for (final int index in indices) {
      load(index, 1, prefix: '补页消息', repeat: repeat);
    }
    if (padAbove) setState(() => padAboveStamp++);
    if (contentShift) setState(() => contentShiftStamp++);
  }

  /// 把这几格**淘汰**回占位槽（真消息 → 88px 占位），模拟面板 `_evictFarSlots`。
  ///
  /// [signal]：是否发 `contentShiftStamp`（面板在淘汰那一帧会发；这里用来做对照）。
  void evict(List<int> indices, {bool signal = true}) {
    setState(() {
      for (final int index in indices) {
        _loaded.remove(index);
      }
      if (signal) contentShiftStamp++;
    });
  }

  List<ChatMessage?> _slots() {
    final List<ChatMessage?> out = List<ChatMessage?>.filled(total, null);
    _loaded.forEach((int index, ChatMessage message) {
      if (index >= 0 && index < total) out[index] = message;
    });
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: MessageList(
          slots: _slots(),
          revision: 0,
          bottomJump: false,
          padAboveStamp: padAboveStamp,
          contentShiftStamp: contentShiftStamp,
          onWindowChanged: (int first, int last) {
            windowFirst = first;
            windowLast = last;
          },
        ),
      ),
    );
  }
}
