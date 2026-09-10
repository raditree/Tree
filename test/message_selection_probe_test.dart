import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

/// probe v2：选择能力矩阵 + 对照组
///
/// 证据检查：拖选 → Ctrl+C → 拦截 Clipboard.setData 读取复制内容。
/// 注意：测试体结束前必须重置 debugDefaultTargetPlatformOverride。
void main() {
  const String md1 = '第一段文字内容AAAA用于选择测试。\n\n第二段文字内容BBBB用于选择测试。';
  const String md2 = '第三条消息文字内容CCCC用于选择测试。';
  const String mdCode = '普通段落文字DDDD。\n\n```dart\nfinal int codeAAA = 1;\n```\n\n结尾段落EEEE。';

  String? clipboardText;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    clipboardText = null;
  });

  void installClipboardMock(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText =
              ((call.arguments as Map<dynamic, dynamic>)['text']) as String?;
        }
        return null;
      },
    );
  }

  Future<void> dragSelect(
    WidgetTester tester,
    Offset start,
    Offset end,
  ) async {
    final TestGesture gesture =
        await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    const int steps = 30;
    for (int i = 1; i <= steps; i++) {
      await gesture.moveTo(Offset.lerp(start, end, i / steps)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  Future<void> pressCtrlC(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  Future<void> pressCtrlA(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  Finder textWith(String s) {
    return find.byWidgetPredicate((Widget w) {
      if (w is RichText) return w.text.toPlainText().contains(s);
      if (w is EditableText) return w.controller.text.contains(s);
      if (w is Text) {
        return (w.data ?? w.textSpan?.toPlainText() ?? '').contains(s);
      }
      return false;
    });
  }

  void dumpEditables(WidgetTester tester, String tag) {
    final List<String> parts = <String>[];
    for (final Element e in find.byType(EditableText).evaluate()) {
      final EditableText w = e.widget as EditableText;
      parts.add('"${w.controller.text}" sel=${w.controller.selection}');
    }
    // ignore: avoid_print
    print('[$tag] editables(${parts.length}): ${parts.join(' || ')}');
  }

  String clip() => clipboardText == null ? '(never set)' : '"$clipboardText"';

  Widget wrap(Widget child) => MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 500, height: 600, child: child),
        ),
      );

  testWidgets('A1 现状: SelectionArea + selectable:false', (tester) async {
    installClipboardMock(tester);
    await tester.pumpWidget(
      wrap(SelectionArea(child: MarkdownBody(data: md1))),
    );
    await tester.pumpAndSettle();

    final Offset start =
        tester.getTopLeft(textWith('第一段').first) + const Offset(2, 4);
    final Offset end =
        tester.getBottomRight(textWith('第二段').first) - const Offset(2, 4);
    await dragSelect(tester, start, end);
    await pressCtrlC(tester);
    // ignore: avoid_print
    print('[A1] drag+C copy = ${clip()}; richTexts='
        '${find.byType(RichText).evaluate().length} '
        'editable=${find.byType(EditableText).evaluate().length}');

    clipboardText = null;
    await pressCtrlA(tester);
    await pressCtrlC(tester);
    // ignore: avoid_print
    print('[A1] Ctrl+A+C copy = ${clip()}');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('E1 对照: SelectionArea + 纯 Text', (tester) async {
    installClipboardMock(tester);
    await tester.pumpWidget(
      wrap(SelectionArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const <Widget>[
            Text('第一段文字内容AAAA用于选择测试。'),
            Text('第二段文字内容BBBB用于选择测试。'),
          ],
        ),
      )),
    );
    await tester.pumpAndSettle();

    final Offset start =
        tester.getTopLeft(textWith('第一段').first) + const Offset(2, 4);
    final Offset end =
        tester.getBottomRight(textWith('第二段').first) - const Offset(2, 4);
    await dragSelect(tester, start, end);
    await pressCtrlC(tester);
    // ignore: avoid_print
    print('[E1] drag+C copy = ${clip()}');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('E2 对照: SelectionArea + 纯 RichText', (tester) async {
    installClipboardMock(tester);
    await tester.pumpWidget(
      wrap(SelectionArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            RichText(
                text: const TextSpan(
                    text: '第一段文字内容AAAA用于选择测试。',
                    style: TextStyle(color: Colors.black))),
            RichText(
                text: const TextSpan(
                    text: '第二段文字内容BBBB用于选择测试。',
                    style: TextStyle(color: Colors.black))),
          ],
        ),
      )),
    );
    await tester.pumpAndSettle();

    final Offset start =
        tester.getTopLeft(textWith('第一段').first) + const Offset(2, 4);
    final Offset end =
        tester.getBottomRight(textWith('第二段').first) - const Offset(2, 4);
    await dragSelect(tester, start, end);
    await pressCtrlC(tester);
    // ignore: avoid_print
    print('[E2] drag+C copy = ${clip()}');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('B2: selectable:true 段内局部拖选', (tester) async {
    installClipboardMock(tester);
    await tester.pumpWidget(
      wrap(const MarkdownBody(data: md1, selectable: true)),
    );
    await tester.pumpAndSettle();

    final Rect r1 = tester.getRect(textWith('第一段').first);
    // 同一段内从行首拖到中部（覆盖“第一段文字内容”若干字）
    await dragSelect(tester, r1.topLeft + const Offset(2, 4),
        r1.topLeft + const Offset(120, 4));
    await pressCtrlC(tester);
    dumpEditables(tester, 'B2');
    // ignore: avoid_print
    print('[B2] 段内局部 copy = ${clip()}');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('B3: selectable:true 跨段拖选（细慢）', (tester) async {
    installClipboardMock(tester);
    await tester.pumpWidget(
      wrap(const MarkdownBody(data: md1, selectable: true)),
    );
    await tester.pumpAndSettle();

    final Rect r1 = tester.getRect(textWith('第一段').first);
    final Rect r2 = tester.getRect(textWith('第二段').first);
    await dragSelect(tester, r1.topLeft + const Offset(2, 4),
        r2.bottomRight - const Offset(2, 4));
    await pressCtrlC(tester);
    dumpEditables(tester, 'B3');
    // ignore: avoid_print
    print('[B3] 跨段 drag+C copy = ${clip()}');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('B4: selectable:true 第二段独立拖选', (tester) async {
    installClipboardMock(tester);
    await tester.pumpWidget(
      wrap(const MarkdownBody(data: md1, selectable: true)),
    );
    await tester.pumpAndSettle();

    final Rect r2 = tester.getRect(textWith('第二段').first);
    await dragSelect(tester, r2.topLeft + const Offset(2, 4),
        r2.bottomRight - const Offset(2, 4));
    await pressCtrlC(tester);
    // ignore: avoid_print
    print('[B4] 第二段 drag+C copy = ${clip()}');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('F: selectable:true + 代码块', (tester) async {
    installClipboardMock(tester);
    await tester.pumpWidget(
      wrap(const MarkdownBody(data: mdCode, selectable: true)),
    );
    await tester.pumpAndSettle();
    dumpEditables(tester, 'F-initial');

    final Rect rTop = tester.getRect(textWith('普通段落').first);
    final Rect rEnd = tester.getRect(textWith('结尾段落').first);
    await dragSelect(tester, rTop.topLeft + const Offset(2, 4),
        rEnd.bottomRight - const Offset(2, 4));
    await pressCtrlC(tester);
    dumpEditables(tester, 'F-afterdrag');
    // ignore: avoid_print
    print('[F] 全范围 drag+C copy = ${clip()}');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('D2: SelectionArea + selectable:true 列表跨消息', (tester) async {
    installClipboardMock(tester);
    await tester.pumpWidget(
      wrap(
        SelectionArea(
          child: ListView(
            children: const <Widget>[
              MarkdownBody(data: md1, selectable: true),
              MarkdownBody(data: md2, selectable: true),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Rect r1 = tester.getRect(textWith('第一段').first);
    final Rect r3 = tester.getRect(textWith('CCCC').first);
    await dragSelect(tester, r1.topLeft + const Offset(2, 4),
        r3.bottomRight - const Offset(2, 4));
    await pressCtrlC(tester);
    // ignore: avoid_print
    print('[D2] 跨消息 drag+C copy = ${clip()}');
    debugDefaultTargetPlatformOverride = null;
  });
}
