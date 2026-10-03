import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/widgets/message_scrollbar.dart';

/// 右侧那条滑块的**几何与交互**（用户 2026-10-04：「右侧滑块位置按全局长度算，
/// 滑到哪加载哪」）。
///
/// 为什么不用自带 [Scrollbar]：它的几何来自"已构建内容"的滚动范围，而窗口化列表
/// 的范围是估算的（取回来的按真实高度、占位槽按占位高度），跟着它走滑块会来回跳。
/// 这里只认**全局下标**：位置 = 视口第一条 / 全局条数；长度 = 看得见的条数 / 全局条数。
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
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 1000,
          width: 14,
          child: MessageScrollbar(
            total: 100,
            firstVisible: 0,
            lastVisible: 9,
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
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 400,
          width: 14,
          child: MessageScrollbar(
            total: 8,
            firstVisible: 0,
            lastVisible: 7,
            onSeek: seeks.add,
          ),
        ),
      ),
    ));
    await tester.dragFrom(tester.getCenter(find.byType(MessageScrollbar)),
        const Offset(0, 200));
    expect(seeks, isEmpty);
  });
}
