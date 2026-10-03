import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/services/conversation_view.dart';
import 'package:tree/ui/services/subagent_transcript.dart';
import 'package:tree/ui/widgets/subagent_view_switcher.dart';

/// 临时员工视角（用户 2026-10-04 的两条硬要求）：
/// - **不新开窗口**：借父 agent 的窗口，把"对话数据 + 上下文长度条"换成它的；
/// - **切换组件放输入框右下（发送键左侧）**，样式与会话切换同族；
/// - 进入后**锁定会话切换**（那是 [SessionPicker] 的 locked，见 message_panel 的接线）。
///
/// 页面级渲染（中栏换列表 + 锁输入框）在 message_panel 里，用这里的纯口径与这个
/// 切换器组件拼起来——所以测试盯住这两层：口径 + 组件。
void main() {
  ChatMessage sub(
    String id, {
    String name = '数值复核',
    int level = 1,
    String parent = 'agt_1',
    Map<String, dynamic>? usage,
  }) => ChatMessage(
    id: '${id}_$name',
    role: 'agent',
    content: '过程 $name',
    timestamp: DateTime(2026, 10, 4),
    subagentId: id,
    subagentName: name,
    subagentParentId: parent,
    subagentLevel: level,
    usage: usage,
  );

  ChatMessage mainMessage(String text) => ChatMessage(
    id: 'm_$text',
    role: 'agent',
    content: text,
    timestamp: DateTime(2026, 10, 4),
  );

  group('视图口径（纯函数）：换的是数据与读数，会话没变', () {
    final List<ChatMessage> stream = <ChatMessage>[
      mainMessage('主 agent 说话'),
      sub('sub_a'),
      mainMessage('主 agent 又说'),
    ];
    final List<ChatMessage> transcript = <ChatMessage>[sub('sub_a')];

    test('主会话：只显示主 agent 的（排掉临时员工标记的）', () {
      final List<ChatMessage> shown = viewMessages(
        subagentId: '',
        stream: stream,
        transcript: transcript,
      );
      expect(shown.map((ChatMessage m) => m.content), <String>['主 agent 说话', '主 agent 又说']);
    });

    test('临时员工视角：显示它的完整过程', () {
      final List<ChatMessage> shown = viewMessages(
        subagentId: 'sub_a',
        stream: stream,
        transcript: transcript,
      );
      expect(shown, hasLength(1));
      expect(shown.single.subagentId, 'sub_a');
    });

    test('上下文读数各看各的：临时员工的绝不并进主 agent 那条', () {
      final ContextReading? mainReading = viewContext(
        subagentId: '',
        mainUsage: <String, dynamic>{'prompt_tokens': 689581, 'max_tokens': 1024000},
        transcript: transcript,
      );
      expect(mainReading!.promptTokens, 689581);

      final List<ChatMessage> withUsage = <ChatMessage>[
        sub('sub_a', usage: <String, dynamic>{'prompt_tokens': 1200, 'max_tokens': 64000}),
      ];
      final ContextReading? subReading = viewContext(
        subagentId: 'sub_a',
        // 主会话那条读数喂进来也不该被用
        mainUsage: <String, dynamic>{'prompt_tokens': 689581, 'max_tokens': 1024000},
        transcript: withUsage,
      );
      expect(subReading!.promptTokens, 1200, reason: '临时员工视角看它自己的');
      expect(subReading.maxTokens, 64000);
    });

    test('没有读数的临时员工：返回 null（那一行不显示，也不显示 0）', () {
      expect(
        viewContext(subagentId: 'sub_a', mainUsage: null, transcript: transcript),
        isNull,
      );
    });

    test('标题与副标题：谁召来的 + 层数（措辞与团队的"层级"分开）', () {
      final List<ChatMessage> nested = <ChatMessage>[
        sub('sub_b', name: '脚本小工', level: 2, parent: 'sub_a'),
      ];
      expect(
        viewTitle(subagentId: '', agentName: '契门', transcript: const <ChatMessage>[]),
        '契门',
      );
      expect(
        viewTitle(subagentId: 'sub_b', agentName: '契门', transcript: nested),
        '临时员工「脚本小工」',
      );
      expect(
        viewSubtitle(callerName: '数值复核', transcript: nested),
        '由「数值复核」召来 · 第 2 层',
      );
      expect(
        viewSubtitle(callerName: '', transcript: nested),
        contains('（未知调用方）'),
      );
    });

    test('usage 那一行：明确写出"不并进主 agent 的统计"', () {
      final List<ChatMessage> withUsage = <ChatMessage>[
        sub('sub_a', usage: <String, dynamic>{'prompt_tokens': 1200, 'max_tokens': 64000}),
      ];
      expect(subagentUsageLine(withUsage), contains('1200 / 64000'));
      expect(subagentUsageLine(withUsage), contains('不并进主 agent 的统计'));
      expect(subagentUsageLine(const <ChatMessage>[]), isNull);
    });
  });

  group('切换器组件（输入框右下那个）', () {
    tearDown(SubagentTranscript.instance.clear);

    Future<void> pump(
      WidgetTester tester, {
      required List<ChatMessage> messages,
      required String current,
      required List<String> selections,
    }) async {
      SubagentTranscript.instance.sync(messages);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: <Widget>[
                SubagentViewSwitcher(
                  ownerAgentId: 'agt_1',
                  ownerName: '契门',
                  currentSubagentId: current,
                  onSelect: selections.add,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('没有临时员工、也没在视角里：不占位置', (WidgetTester tester) async {
      await pump(
        tester,
        messages: <ChatMessage>[mainMessage('只有主 agent')],
        current: '',
        selections: <String>[],
      );
      expect(find.byType(PopupMenuButton<String>), findsNothing);
    });

    testWidgets('有临时员工：显示"主会话"并列出每一个（谁召来的 + 层数）', (WidgetTester tester) async {
      final List<String> selections = <String>[];
      await pump(
        tester,
        messages: <ChatMessage>[mainMessage('主'), sub('sub_a'), sub('sub_b', name: '脚本小工')],
        current: '',
        selections: selections,
      );
      expect(find.text('主会话'), findsOneWidget);

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.textContaining('临时员工「数值复核」'), findsOneWidget);
      expect(find.textContaining('第 1 层'), findsWidgets);

      await tester.tap(find.textContaining('临时员工「脚本小工」'));
      await tester.pumpAndSettle();
      expect(selections, <String>['sub_b']);
    });

    testWidgets('在视角里：标签变成它，且能切回主会话', (WidgetTester tester) async {
      final List<String> selections = <String>[];
      await pump(
        tester,
        messages: <ChatMessage>[mainMessage('主'), sub('sub_a')],
        current: 'sub_a',
        selections: selections,
      );
      expect(find.text('临时员工「数值复核」'), findsOneWidget);

      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('主会话'));
      await tester.pumpAndSettle();
      expect(selections, <String>[''], reason: '空串 = 回主会话');
    });
  });
}
