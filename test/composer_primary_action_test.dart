import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/widgets/message_input.dart';
import 'package:tree/ui/widgets/stop_button.dart';

/// 右下角那个键的**两态切换**（用户 2026-10-04）：
/// 「停止键占原本的发送键；一旦输入了文字就换回发送键——发送本身就意味着中止并
/// 另起一轮」。所以：**该 agent 在生成 + 输入为空** → 停止；开始打字 → 发送。
void main() {
  late int stops;
  late List<String> sent;

  Future<void> pump(
    WidgetTester tester, {
    required bool busy,
    bool withStop = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageInput(
            busy: busy,
            onStop: withStop ? () => stops++ : null,
            onSend: (String text, List<String> files) async {
              sent.add(text);
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() {
    stops = 0;
    sent = <String>[];
  });

  testWidgets('生成中且输入为空：那个位置是停止键，点它就停', (WidgetTester tester) async {
    await pump(tester, busy: true);
    expect(find.byType(StopButton), findsOneWidget);
    await tester.tap(find.byType(StopButton));
    await tester.pumpAndSettle();
    expect(stops, 1);
    expect(sent, isEmpty, reason: '点的是停止，不该发消息');
  });

  testWidgets('一开始打字就换回发送键（发送 = 中止并另起一轮）', (WidgetTester tester) async {
    await pump(tester, busy: true);
    await tester.enterText(find.byType(TextField), '换个方向做');
    await tester.pumpAndSettle();

    expect(find.byType(StopButton), findsNothing, reason: '有输入内容时不再显示停止键');
    // 发送键：圆形 + 向上箭头
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();
    expect(sent, <String>['换个方向做']);
    expect(stops, 0);
  });

  testWidgets('空转回：删掉文字又变回停止键', (WidgetTester tester) async {
    await pump(tester, busy: true);
    await tester.enterText(find.byType(TextField), 'a');
    await tester.pumpAndSettle();
    expect(find.byType(StopButton), findsNothing);

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.byType(StopButton), findsOneWidget);
  });

  testWidgets('不在生成中：任何时候都是发送键', (WidgetTester tester) async {
    await pump(tester, busy: false);
    expect(find.byType(StopButton), findsNothing);
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
  });

  testWidgets('没接停止回调（null）就不显示停止键，别给一个点了没反应的键', (WidgetTester tester) async {
    await pump(tester, busy: true, withStop: false);
    expect(find.byType(StopButton), findsNothing);
  });
}
