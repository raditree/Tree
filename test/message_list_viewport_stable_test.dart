import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/widgets/message_list.dart';

/// 回归测试：用户上滚进入阅读模式后，底部推送新工具卡片，
/// 视口内容必须保持稳定（不滚回底部、也不发生任何漂移）。
void main() {
  testWidgets('阅读模式推送工具卡片：视口内容位置不变', (WidgetTester tester) async {
    // 30 条历史文本消息，内容唯一（user 角色：SelectableText 渲染，
    // find.text 可直接匹配，且单行高度恒定）
    final List<ChatMessage> initial = <ChatMessage>[
      for (int i = 1; i <= 30; i++)
        ChatMessage(
          id: 'm$i',
          role: 'user',
          content: 'msg-$i',
          timestamp: DateTime(2026, 1, 1),
        ),
    ];

    Widget buildList(List<ChatMessage> messages, int revision) {
      return MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: MessageList(
              messages: messages,
              revision: revision,
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(buildList(initial, 0));
    await tester.pumpAndSettle();

    // 向下拖动 = 看更旧内容 → 进入阅读模式（列表为常规布局）
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle();

    // 选择一条当前可见的历史消息作为锚点
    final Finder anchor = find.text('msg-20');
    expect(anchor, findsOneWidget);
    final double beforeDy = tester.getTopLeft(anchor).dy;

    // 推送一个工具调用卡片：末尾新增一条消息 + revision 递增
    final List<ChatMessage> updated = List<ChatMessage>.from(initial)
      ..add(ChatMessage(
        id: 'tool-1',
        role: 'agent',
        content: '',
        timestamp: DateTime(2026, 1, 1),
        kind: 'tool',
        toolName: 'read',
        toolArguments: <String, dynamic>{'path': 'lib/main.dart'},
      ));
    await tester.pumpWidget(buildList(updated, 1));
    await tester.pumpAndSettle();

    // 锚点消息仍在视口内，且屏幕位置不变（无被动下滚、无漂移）
    expect(anchor, findsOneWidget);
    final double afterDy = tester.getTopLeft(anchor).dy;
    expect(
      (afterDy - beforeDy).abs(),
      lessThan(1.0),
      reason: '推送工具卡片后视口内容发生偏移：before=$beforeDy after=$afterDy',
    );
  });
}
