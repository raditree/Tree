import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/widgets/message_list.dart';
import 'package:tree/ui/services/message_window.dart';
import 'package:tree/ui/widgets/message_scrollbar.dart';

/// 右侧那条滑块的**几何与交互**（用户 2026-10-04：「右侧滑块位置按全局长度算，
/// 滑到哪加载哪」）。
///
/// 为什么不用自带 [Scrollbar]：它的几何来自"已构建内容"的滚动范围，而窗口化列表
/// 的范围是估算的（取回来的按真实高度、占位槽按占位高度），跟着它走滑块会来回跳。
/// 这里只认**全局下标**：位置 = 视口第一条 / 全局条数；长度 = 看得见的条数 / 全局条数。
///
/// 另有一半用例钉"用户 2026-10-03 看到的乱跳"：桌面平台下**不关掉原生 `Scrollbar`** 时，
/// 它会跟自绘这条叠在同一条窄带里一起跳（见 `_MirrorBar` 与「桌面平台」那条）；
/// 拖拽则必须"抓哪儿是哪儿"——反解严格互逆 + 拖拽期间几何输入与拇指位置都钉住。
void main() {
  test('位置按下标比：视口越靠后，滑块越靠下；看到最后一条时贴到轨道底', () {
    const double track = 1000;
    final ScrollbarThumb a = messageScrollbarThumb(
      track: track,
      total: 100,
      firstVisible: 0,
      lastVisible: 9,
    );
    final ScrollbarThumb b = messageScrollbarThumb(
      track: track,
      total: 100,
      firstVisible: 50,
      lastVisible: 59,
    );
    final ScrollbarThumb c = messageScrollbarThumb(
      track: track,
      total: 100,
      firstVisible: 90,
      lastVisible: 99,
    );
    expect(a.top, 0);
    expect(b.top, greaterThan(a.top));
    expect(c.top, greaterThan(b.top));
    expect(c.top + c.length, closeTo(track, 0.001), reason: '看到最后一条 = 滑块贴底');
  });

  test('长度 = 看得见的条数 / 全局条数，并有抓得住的下限', () {
    final ScrollbarThumb t = messageScrollbarThumb(
      track: 1000,
      total: 100,
      firstVisible: 0,
      lastVisible: 19,
    );
    expect(t.length, closeTo(200, 0.001));

    final ScrollbarThumb tiny = messageScrollbarThumb(
      track: 1000,
      total: 100000,
      firstVisible: 0,
      lastVisible: 9,
    );
    expect(tiny.length, closeTo(1000 * kMessageScrollbarMinFraction, 0.001));
  });

  test('装得下整份会话就不画（没得滚）；还没量出视口也不画', () {
    expect(
      messageScrollbarVisible(total: 10, firstVisible: 0, lastVisible: 9),
      isFalse,
    );
    expect(
      messageScrollbarVisible(total: 11, firstVisible: 0, lastVisible: 9),
      isTrue,
    );
    expect(
      messageScrollbarVisible(total: 100, firstVisible: -1, lastVisible: -1),
      isFalse,
    );
    expect(
      messageScrollbarVisible(total: 0, firstVisible: 0, lastVisible: 0),
      isFalse,
    );
  });

  testWidgets('拖滑块：按落点换算成全局下标回调出去（面板据此补那一段）',
      (WidgetTester tester) async {
    final List<int> seeks = <int>[];
    // 几何口径没变，只是输入从"三个数"变成一个**坐标**（用户 2026-10-03）
    final ValueNotifier<MessageWindowCoordinate> coord =
        ValueNotifier<MessageWindowCoordinate>(
      const MessageWindowCoordinate(first: 0, last: 9, total: 100),
    );
    addTearDown(coord.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 1000,
          width: 14,
          child: MessageScrollbar(
            coordinate: coord,
            onSeek: seeks.add,
          ),
        ),
      ),
    ));
    final Finder bar = find.byType(MessageScrollbar);
    expect(bar, findsOneWidget);

    // 从轨道中间往下拖：过程中必然经过中段（100 条里的 30..80）
    await tester.dragFrom(tester.getCenter(bar), const Offset(0, 400));
    expect(seeks, isNotEmpty, reason: '拖动必须真的回调出去');
    expect(
      seeks.any((int i) => i > 30 && i < 80),
      isTrue,
      reason: '落点换算成全局下标：跟着指针走，路过中段\n实际：$seeks',
    );
    expect(seeks.last, greaterThan(seeks.first), reason: '往下拖 = 看更新的消息');
    expect(seeks.last, inInclusiveRange(0, 99));
  });

  testWidgets('不画的时候不拦手势（内容装得下时右侧那一竖条不该吃掉点击）',
      (WidgetTester tester) async {
    final List<int> seeks = <int>[];
    final ValueNotifier<MessageWindowCoordinate> coord =
        ValueNotifier<MessageWindowCoordinate>(
      const MessageWindowCoordinate(first: 0, last: 7, total: 8),
    );
    addTearDown(coord.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 400,
          width: 14,
          child: MessageScrollbar(
            coordinate: coord,
            onSeek: seeks.add,
          ),
        ),
      ),
    ));
    await tester.dragFrom(tester.getCenter(find.byType(MessageScrollbar)),
        const Offset(0, 200));
    expect(seeks, isEmpty);
  });

  test('反解是绘制的严格逆：抓着拇指顶端、底端不动，反解出来的下标等于它现在指的那一条', () {
    const double track = 600;
    // 覆盖：长会话（下限 6% 生效）、中会话、短会话（看得见的占比很大 = 旧口径偏差最大）
    for (final (int total, int visible, int first) in <(int, int, int)>[
      (100000, 8, 0),
      (100000, 8, 99991),
      (1000, 10, 500),
      (100, 10, 0),
      (100, 10, 45),
      (100, 10, 90),
      (100, 25, 25),
      (100, 25, 75),
      (60, 50, 5),
    ]) {
      final int last = first + visible - 1;
      final String at = 'total=$total visible=$visible first=$first';
      final ScrollbarThumb t = messageScrollbarThumb(
        track: track,
        total: total,
        firstVisible: first,
        lastVisible: last,
      );
      int atTop(double top) => messageScrollbarIndexAt(
            track: track,
            total: total,
            firstVisible: first,
            lastVisible: last,
            top: top,
          );
      expect(atTop(t.top), first, reason: '抓拇指顶端不该把它自己挪走：$at');
      expect(atTop(0), 0, reason: '推到轨道顶 = 最旧那条：$at');
      expect(atTop(track - t.length), total - visible,
          reason: '推到底 = 最后一条正好落在视口底（滑块贴底那条语义）：$at');
    }
  });

  test('反解单调不减：轨道上越往下，下标越大（拖拽才有方向感）', () {
    const double track = 600;
    const int total = 1000;
    const int visible = 12;
    const int first = 400;
    final ScrollbarThumb t = messageScrollbarThumb(
      track: track,
      total: total,
      firstVisible: first,
      lastVisible: first + visible - 1,
    );
    final double room = track - t.length;
    int previous = -1;
    for (int i = 0; i <= 20; i++) {
      final int index = messageScrollbarIndexAt(
        track: track,
        total: total,
        firstVisible: first,
        lastVisible: first + visible - 1,
        top: room * i / 20,
      );
      expect(index, greaterThanOrEqualTo(previous),
          reason: '第 $i 步反解出 $index < 上一步 $previous');
      previous = index;
    }
  });

  testWidgets('拖滑块：拇指一路跟着指针走（面板把回填的下标当真值也一样）',
      (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(height: 400, width: 14, child: _MirrorBar()),
        ),
      ),
    ));
    await tester.pump();

    const double track = 400;
    final Finder thumb = find.byKey(messageScrollbarThumbKey);
    final double barTop =
        tester.getRect(find.byType(MessageScrollbar)).top;
    final ScrollbarThumb t0 = messageScrollbarThumb(
      track: track,
      total: _MirrorBar.total,
      firstVisible: _MirrorBar.first,
      lastVisible: _MirrorBar.first + _MirrorBar.visible - 1,
    );
    expect(tester.getRect(thumb).top - barTop, closeTo(t0.top, 0.5),
        reason: '没在拖的时候，拇指按真实下标画');
    final double barRight = tester.getRect(find.byType(MessageScrollbar)).right;

    // 抓在拇指中间，往下拖 4 次 × 25px（鼠标指针：真机就是这个设备，
    // 它的识别滑动量才 1px；触摸的 18px 由"先走一步识别"那下吃掉）
    final TestGesture gesture = await tester.startGesture(
      Offset(barRight - 7, barTop + t0.top + t0.length / 2),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveBy(const Offset(0, 10));
    await tester.pump();
    final double before = tester.getRect(thumb).top;
    for (int i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(0, 25));
      await tester.pump();
    }
    final double after = tester.getRect(thumb).top;
    expect(after - before, closeTo(100, 1.0),
        reason: '指针走了 100px，拇指也必须走 100px。旧口径按 total/(total-visible) 放大'
            '（这里 100/75 ≈ 1.33），拇指会被自己反解出来的下标甩到指针前面 —— 就是用户看到的「乱跳」');
    await gesture.up();
    await tester.pump();
  });

  testWidgets('桌面平台：中栏列表只留自绘那一条滑块（原生 Scrollbar 必须关掉），且还能滚',
      (WidgetTester tester) async {
    // 桌面 ScrollBehavior 会给每个竖向 Scrollable 自动包一条原生 Scrollbar：它的几何来自
    // "已构建内容"的估算范围，窗口化列表里必然乱跳（用户 2026-10-03 报「滑块乱跳」：
    // 截图里两条拇指落在同一条 14px 窄带内、位置不同）。中栏必须显式关掉它。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final List<ChatMessage?> slots = <ChatMessage?>[
        for (int i = 0; i < 60; i++)
          ChatMessage(
            id: 'm$i',
            role: 'agent',
            content: '消息内容 $i',
            timestamp: DateTime(2026, 1, 1),
          ),
      ];
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 600,
            child: MessageList(slots: slots, revision: 0),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(MessageScrollbar), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byType(Viewport).first,
          matching: find.byType(Scrollbar),
        ),
        findsNothing,
        reason: '中栏列表上不允许再有原生 Scrollbar：它按估算范围画拇指，'
            '补页/淘汰时就在自绘那条旁边乱跳',
      );

      // 关掉原生滑块不许把滚动一起关掉
      final ScrollPosition position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      final double before = position.pixels;
      await tester.dragFrom(const Offset(700, 300), const Offset(0, 150));
      await tester.pumpAndSettle();
      expect(position.pixels, isNot(before),
          reason: '中栏还得能滚：拖空白区应该把视口挪走');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

/// 复刻面板的回填回路：滑块报出下标 → 面板当真值（列表真的跳到那儿、视口随之变化）。
///
/// 短会话（`total=100`、看得见 25 条）时旧口径的偏差最大：拇指位置 / 指针位置
/// = `total/(total-visible)` ≈ 1.33。
class _MirrorBar extends StatefulWidget {
  static const int total = 100;
  static const int visible = 25;
  static const int first = 25;

  @override
  State<_MirrorBar> createState() => _MirrorBarState();
}

class _MirrorBarState extends State<_MirrorBar> {
  int _first = _MirrorBar.first;

  late final ValueNotifier<MessageWindowCoordinate> _coordinate =
      ValueNotifier<MessageWindowCoordinate>(_coordinateFor(_first));

  static MessageWindowCoordinate _coordinateFor(int first) =>
      MessageWindowCoordinate(
        first: first,
        last: first + _MirrorBar.visible - 1,
        total: _MirrorBar.total,
      );

  @override
  void dispose() {
    _coordinate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MessageScrollbar(
      coordinate: _coordinate,
      onSeek: (int index) => setState(() {
        _first = index.clamp(0, _MirrorBar.total - _MirrorBar.visible);
        _coordinate.value = _coordinateFor(_first);
      }),
    );
  }
}
