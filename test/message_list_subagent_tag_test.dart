import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/widgets/message_list.dart';

/// 临时员工（subagent）消息在中栏一行式消息流里的**标记**（用户 2026-10-04 之后的前端口径）：
///
/// 核心把临时员工的话与工具调用都写进**会话主人**的消息流（`agent_id` 仍是主人，
/// 前端过滤口径不变），只多带 `subagent_*` 四个字段。不打标就会看起来像主 agent 在说话。
/// 口径：同一个临时员工的**那一段只在开头标一次**（连续消息/工具不重复顶标签），
/// 换人或换回主 agent 再出现时重新标。
void main() {
  ChatMessage msg({
    required String id,
    String content = '',
    String subagentId = '',
    String subagentName = '',
    int level = 0,
    String kind = 'text',
  }) =>
      ChatMessage(
        id: id,
        role: 'agent',
        content: content,
        timestamp: DateTime(2026, 10, 4, 9),
        kind: kind,
        subagentId: subagentId,
        subagentName: subagentName,
        subagentLevel: level,
      );

  Future<void> pump(WidgetTester tester, List<ChatMessage> messages) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 500,
          height: 700,
          child: MessageList(slots: messages),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('临时员工的那一段只在开头标一次，主 agent 的消息不打标',
      (WidgetTester tester) async {
    await pump(tester, <ChatMessage>[
      msg(id: 'p1', content: '主 agent 的话'),
      msg(
        id: 's1',
        content: '临时员工第一段话',
        subagentId: 'sub_1',
        subagentName: '甲',
        level: 1,
      ),
      msg(
        id: 's2',
        content: '临时员工第二段话',
        subagentId: 'sub_1',
        subagentName: '甲',
        level: 1,
      ),
    ]);

    expect(find.text('临时员工「甲」 · 层级 1'), findsOneWidget);
    expect(find.text('临时员工第一段话'), findsOneWidget);
    expect(find.text('临时员工第二段话'), findsOneWidget);
  });

  testWidgets('换一个临时员工要重新标（层级也跟着它）', (WidgetTester tester) async {
    await pump(tester, <ChatMessage>[
      msg(
        id: 's1',
        content: '甲在干活',
        subagentId: 'sub_1',
        subagentName: '甲',
        level: 1,
      ),
      msg(
        id: 's2',
        content: '乙在干活',
        subagentId: 'sub_2',
        subagentName: '乙',
        level: 2,
      ),
    ]);

    expect(find.text('临时员工「甲」 · 层级 1'), findsOneWidget);
    expect(find.text('临时员工「乙」 · 层级 2'), findsOneWidget);
  });

  testWidgets('消息缺名字也不显示空白标签', (WidgetTester tester) async {
    await pump(tester, <ChatMessage>[
      msg(id: 's1', content: '说话', subagentId: 'sub_1', level: 1),
    ]);

    expect(find.text('临时员工「未命名」 · 层级 1'), findsOneWidget);
  });

  testWidgets('工具卡片也算同一个人的一段（不重复顶标签）',
      (WidgetTester tester) async {
    await pump(tester, <ChatMessage>[
      msg(
        id: 's1',
        content: '先读文件',
        subagentId: 'sub_1',
        subagentName: '甲',
        level: 1,
      ),
      ChatMessage(
        id: 't1',
        role: 'agent',
        content: '',
        timestamp: DateTime(2026, 10, 4, 9),
        kind: 'tool',
        toolName: 'read',
        toolArguments: const <String, dynamic>{'file_path': 'a.dart'},
        subagentId: 'sub_1',
        subagentName: '甲',
        subagentLevel: 1,
      ),
    ]);

    expect(find.text('临时员工「甲」 · 层级 1'), findsOneWidget);
  });
}
