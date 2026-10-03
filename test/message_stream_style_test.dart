import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/widgets/message_list.dart';

/// 消息流的排版口径（[lib/README.md](../lib/README.md) 不变量 11）：
/// 模型消息是**高亮块**（左侧主色竖条 + 极淡同色底，没有整圈边框），
/// 用户消息仍是主色气泡；工具调用 / 思考各占一行（见 tool_row_detail_test.dart）。
ChatMessage textMessage({
  required String id,
  required String role,
  required String content,
  bool streaming = false,
}) =>
    ChatMessage(
      id: id,
      role: role,
      content: content,
      timestamp: DateTime(2026, 10, 2, 21, 39),
      isStreaming: streaming,
    );

Future<void> pumpList(WidgetTester tester, List<ChatMessage> messages) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: MessageList(slots: messages)),
  ));
  await tester.pump();
}

/// 所有容器里那个「只画了左边框」的装饰（= 模型消息的高亮块）
BoxDecoration? assistantHighlight(WidgetTester tester) {
  for (final Container c in tester.widgetList<Container>(find.byType(Container))) {
    final Decoration? d = c.decoration;
    if (d is! BoxDecoration) continue;
    final BoxBorder? border = d.border;
    if (border is Border && border.left.width == 3) return d;
  }
  return null;
}

void main() {
  testWidgets('模型消息用左侧高亮条，不套整圈边框', (WidgetTester tester) async {
    await pumpList(tester, <ChatMessage>[
      textMessage(id: 'a1', role: 'agent', content: '这就是模型说的话'),
    ]);

    final BoxDecoration? decoration = assistantHighlight(tester);
    expect(decoration, isNotNull, reason: '模型消息要有高亮块');
    final Border border = decoration!.border! as Border;
    expect(border.left.width, 3);
    expect(border.top, BorderSide.none, reason: '只有左边一条竖线，不是整圈盒子');
    expect(border.right, BorderSide.none);
    expect(border.bottom, BorderSide.none);
    expect(decoration.color, isNotNull, reason: '极淡的同色底');
    expect(find.text('这就是模型说的话'), findsOneWidget);
  });

  testWidgets('用户消息仍是气泡：主色底 + 圆角，没有竖条',
      (WidgetTester tester) async {
    await pumpList(tester, <ChatMessage>[
      textMessage(id: 'u1', role: 'user', content: '这是我说的'),
    ]);

    expect(assistantHighlight(tester), isNull, reason: '用户消息不该有高亮竖条');
    final Color primary =
        Theme.of(tester.element(find.byType(MessageList))).colorScheme.primary;
    final bool hasPrimaryBubble = tester
        .widgetList<Container>(find.byType(Container))
        .any((Container c) =>
            (c.decoration as BoxDecoration?)?.color == primary);
    expect(hasPrimaryBubble, isTrue, reason: '用户消息仍是主色气泡');
    expect(find.text('这是我说的'), findsOneWidget);
  });

  testWidgets('模型消息按 markdown 渲染（正文用 w500 与更大行距）',
      (WidgetTester tester) async {
    await pumpList(tester, <ChatMessage>[
      textMessage(id: 'a2', role: 'agent', content: '**加粗** 的一段 \n 第二行'),
    ]);

    expect(find.textContaining('加粗', findRichText: true), findsOneWidget);
  });
}
