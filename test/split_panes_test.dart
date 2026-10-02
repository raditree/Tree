import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/widgets/split_panes.dart';

/// 二分窗格的几何：比例、拖拽、太窄降级——以及文件面板那侧的接线源钉。
void main() {
  const Key firstKey = Key('first-pane');
  const Key secondKey = Key('second-pane');

  /// 摆一个可交互的分屏（父级跟真实调用方一样，接住回调并重建）
  Future<void> pumpSplit(
    WidgetTester tester, {
    required Axis axis,
    double width = 800,
    double height = 600,
    List<double>? ratios,
    Widget? degraded,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            height: height,
            child: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
                final double ratio = ratios?.isEmpty ?? true ? 0.5 : ratios!.last;
                return SplitPanes(
                  axis: axis,
                  ratio: ratio,
                  onRatioChanged: (double next) {
                    ratios?.add(next);
                    setState(() {});
                  },
                  // 用会铺满的容器当窗格：真实窗格是 FileViewer（内部 Expanded 撑满），
                  // 拿 Text 当窗格只会量到文字自己的尺寸
                  first: Container(
                    key: firstKey,
                    width: double.infinity,
                    height: double.infinity,
                    color: const Color(0xFF112233),
                  ),
                  second: Container(
                    key: secondKey,
                    width: double.infinity,
                    height: double.infinity,
                    color: const Color(0xFF223311),
                  ),
                  degraded: degraded,
                );
              },
            ),
          ),
        ),
      ),
    ));
  }

  testWidgets('左右分屏：两个窗格都在，比例决定第一格宽度',
      (WidgetTester tester) async {
    await pumpSplit(tester, axis: Axis.horizontal);

    expect(find.byKey(firstKey), findsOneWidget);
    expect(find.byKey(secondKey), findsOneWidget);
    // 800 - 7(分隔条) = 793；0.5 → 396.5
    expect(tester.getSize(find.byKey(firstKey)).width, closeTo(396.5, 0.5));
    expect(tester.getSize(find.byKey(secondKey)).width, closeTo(396.5, 0.5));
    expect(tester.getSize(find.byKey(firstKey)).height, 600);
  });

  testWidgets('上下分屏：按高度分，宽度都铺满', (WidgetTester tester) async {
    await pumpSplit(tester, axis: Axis.vertical);

    expect(tester.getSize(find.byKey(firstKey)).height, closeTo(296.5, 0.5));
    expect(tester.getSize(find.byKey(firstKey)).width, 800);
    expect(tester.getSize(find.byKey(secondKey)).width, 800);
  });

  testWidgets('拖分隔条：比例按增量累加地变大', (WidgetTester tester) async {
    final List<double> ratios = <double>[];
    await pumpSplit(tester, axis: Axis.horizontal, ratios: ratios);

    // touchSlop 归零：否则前 20px 被当成拖拽阈值吃掉，量到的比例偏小
    await tester.drag(
      find.byType(GestureDetector),
      const Offset(100, 0),
      touchSlopX: 0,
      touchSlopY: 0,
    );
    await tester.pump();

    expect(ratios, isNotEmpty);
    // 0.5 + 100/793 ≈ 0.626
    expect(ratios.last, closeTo(0.626, 0.02));
    expect(tester.getSize(find.byKey(firstKey)).width,
        greaterThan(400));
  });

  testWidgets('拖到两端会被夹住（不会把一个窗格拖没）',
      (WidgetTester tester) async {
    final List<double> ratios = <double>[];
    await pumpSplit(tester, axis: Axis.horizontal, ratios: ratios);

    await tester.drag(
      find.byType(GestureDetector),
      const Offset(-4000, 0),
      touchSlopX: 0,
      touchSlopY: 0,
    );
    await tester.pump();

    expect(ratios.last, greaterThanOrEqualTo(0.2));
    expect(tester.getSize(find.byKey(firstKey)).width, greaterThanOrEqualTo(120));
  });

  testWidgets('太窄就降级成单窗格（两个 120px 谁也用不了）',
      (WidgetTester tester) async {
    await pumpSplit(
      tester,
      axis: Axis.horizontal,
      width: 200,
      degraded: const Text('单个窗格'),
    );

    expect(find.text('单个窗格'), findsOneWidget);
    expect(find.byKey(firstKey), findsNothing);
    expect(find.byKey(secondKey), findsNothing);
  });

  testWidgets('给不出降级控件时仍然排两个窗格（不静默丢一个）',
      (WidgetTester tester) async {
    await pumpSplit(tester, axis: Axis.horizontal, width: 200);

    expect(find.byKey(firstKey), findsOneWidget);
    expect(find.byKey(secondKey), findsOneWidget);
    expect(tester.getSize(find.byKey(firstKey)).width, greaterThan(0));
  });

  group('文件面板的分屏接线（源钉）', () {
    final String panel =
        File('lib/ui/widgets/file_panel.dart').readAsStringSync();

    test('窗格状态、动作与 SplitPanes 都在', () {
      expect(panel.contains('final List<String> _viewerPaths'), isTrue);
      expect(panel.contains('final List<EditorBuffer> _viewerBuffers'), isTrue);
      expect(panel.contains('void _splitViewer()'), isTrue);
      expect(panel.contains('Future<void> _closePane(int index)'), isTrue);
      expect(panel.contains('Future<void> _closeViewer()'), isTrue);
      expect(panel.contains('bool _isDuplicatePane(int index)'), isTrue);
      expect(panel.contains('return SplitPanes('), isTrue);
    });

    test('换文件 / 关窗格前先处理未保存内容；同文件双开共享同一份缓冲', () {
      expect(panel.contains('await _confirmLeave(index)'), isTrue);
      // 同文件双开：新窗格复用**同一个** EditorBuffer 实例，而不是又开一份
      expect(
        panel.contains('_viewerBuffers.add(_viewerBuffers[_activePane])'),
        isTrue,
      );
      expect(panel.contains('buffer: _viewerBuffers[index]'), isTrue);
      expect(panel.contains('readOnly: duplicated'), isFalse,
          reason: '同文件双开不再是只读的理由（旧口径已被推翻）');
      expect(
        panel.contains('同一文件已在另一窗格打开：两侧共享同一份缓冲'),
        isTrue,
        reason: '要如实说明是共享一份缓冲，而不是不能编辑',
      );
      expect(
        panel.contains('void _releaseBuffer(EditorBuffer buffer)'),
        isTrue,
        reason: '没有窗格再引用才释放，不能把另一个窗格在用的控制器 dispose 掉',
      );
    });
  });
}
