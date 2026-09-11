import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/widgets/message_list.dart';

/// 消息文本选择与复制能力测试
///
/// 验证改造后：
/// - 助手消息 markdown 段落/代码块可框选复制（Ctrl+C 写入剪贴板）；
/// - 用户消息 SelectableText 可框选复制；
/// - 助手消息 hover 显示「复制全文」按钮，点击复制完整 markdown 原文并提示；
/// - 流式输出中不显示复制按钮。
void main() {
  const String mdContent = '第一段文字内容AAAA用于选择测试。\n\n第二段文字内容BBBB用于选择测试。';
  const String mdCode = '普通段落文字DDDD。\n\n```dart\nfinal int codeAAA = 1;\n```\n\n结尾段落EEEE。';
  const String userContent = '用户消息内容XYZ用于选择测试。';

  String? clipboardText;

  setUp(() {
    clipboardText = null;
  });

  /// 桌面平台测试包装：`debugDefaultTargetPlatformOverride` 必须在测试体
  /// 结束前重置（框架对 foundation debug 变量的校验早于 tearDown 执行）。
  void desktopTest(String description, Future<void> Function(WidgetTester) body) {
    testWidgets(description, (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  /// 拦截剪贴板写入调用
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

  /// 匹配包含指定文本的渲染组件（EditableText / RichText / Text）
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

  /// 鼠标拖选（模拟真实拖拽选词）
  Future<void> dragSelect(WidgetTester tester, Offset start, Offset end) async {
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

  /// 鼠标悬停到目标组件上
  Future<TestGesture> hoverOn(WidgetTester tester, Finder target) async {
    final TestGesture g =
        await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: Offset.zero);
    await tester.pump();
    await g.moveTo(tester.getCenter(target));
    await tester.pumpAndSettle();
    return g;
  }

  ChatMessage agentMsg(String content, {bool streaming = false}) => ChatMessage(
        id: 'a1',
        role: 'agent',
        content: content,
        timestamp: DateTime(2026, 1, 1),
        isStreaming: streaming,
      );

  ChatMessage userMsg(String content) => ChatMessage(
        id: 'u1',
        role: 'user',
        content: content,
        timestamp: DateTime(2026, 1, 1),
      );

  Widget listOf(List<ChatMessage> msgs) => MaterialApp(
        home: Scaffold(
          body: MessageList(messages: msgs, revision: 0),
        ),
      );

  desktopTest('助手消息：markdown 段落可框选复制（Ctrl+C）', (WidgetTester tester) async {
    installClipboardMock(tester);
    await tester.pumpWidget(listOf(<ChatMessage>[agentMsg(mdContent)]));
    await tester.pumpAndSettle();

    final Rect r = tester.getRect(textWith('第一段').first);
    await dragSelect(
        tester, r.topLeft + const Offset(2, 4), r.topLeft + const Offset(140, 4));
    await pressCtrlC(tester);

    expect(clipboardText, isNotNull, reason: '拖选后 Ctrl+C 应写入剪贴板');
    expect(clipboardText, contains('第一段'));
  });

  desktopTest('助手消息：代码块可框选复制（Ctrl+C）', (WidgetTester tester) async {
    installClipboardMock(tester);
    await tester.pumpWidget(listOf(<ChatMessage>[agentMsg(mdCode)]));
    await tester.pumpAndSettle();

    final Rect rc = tester.getRect(textWith('codeAAA').first);
    await dragSelect(tester, rc.topLeft + const Offset(2, 2),
        rc.bottomRight - const Offset(2, 2));
    await pressCtrlC(tester);

    expect(clipboardText, isNotNull, reason: '拖选代码块后 Ctrl+C 应写入剪贴板');
    expect(clipboardText, contains('codeAAA'));
  });

  desktopTest('用户消息：可框选复制（Ctrl+C）', (WidgetTester tester) async {
    installClipboardMock(tester);
    await tester.pumpWidget(listOf(<ChatMessage>[userMsg(userContent)]));
    await tester.pumpAndSettle();

    final Rect r = tester.getRect(textWith('用户消息内容').first);
    await dragSelect(
        tester, r.topLeft + const Offset(2, 4), r.topLeft + const Offset(160, 4));
    await pressCtrlC(tester);

    expect(clipboardText, isNotNull, reason: '用户消息拖选后 Ctrl+C 应写入剪贴板');
    expect(clipboardText, contains('用户消息内容'));
  });

  desktopTest('助手消息：hover 显示「复制全文」按钮，点击复制完整原文', (WidgetTester tester) async {
    installClipboardMock(tester);
    await tester.pumpWidget(listOf(<ChatMessage>[agentMsg(mdContent)]));
    await tester.pumpAndSettle();

    // 未 hover：按钮不显示
    expect(find.text('复制'), findsNothing);

    final TestGesture g = await hoverOn(tester, textWith('第一段').first);
    expect(find.text('复制'), findsOneWidget, reason: 'hover 后应显示复制按钮');

    await tester.tap(find.text('复制'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(clipboardText, mdContent, reason: '应复制完整 markdown 原文');
    expect(find.text('已复制全文'), findsOneWidget, reason: '应提示已复制');

    await g.removePointer();
    await tester.pumpAndSettle(); // 等 SnackBar 计时结束，避免遗留 timer
  });

  desktopTest('流式输出中不显示「复制全文」按钮', (WidgetTester tester) async {
    installClipboardMock(tester);
    await tester
        .pumpWidget(listOf(<ChatMessage>[agentMsg(mdContent, streaming: true)]));
    await tester.pumpAndSettle();

    final TestGesture g = await hoverOn(tester, textWith('第一段').first);
    expect(find.text('复制'), findsNothing, reason: '流式输出中不应显示复制按钮');

    await g.removePointer();
    await tester.pumpAndSettle();
  });
}
