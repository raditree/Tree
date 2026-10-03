import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/services/subagent_transcript.dart';
import 'package:tree/ui/widgets/subagent_view_page.dart';
import 'package:tree/ui/widgets/tool_call_card.dart';

/// 临时员工的两个"看它干活"的入口（用户 2026-10-04）：
///
/// 1. **调用它的那次 `subagent` 工具调用的详情页**（就地看）；
/// 2. **它自己的工作进度页**（独立一页）——**与发出这次调用的 agent 同级**、
///    不是与 teammates 同级（用户随后更正）；深度叫「第 N 层」（临时员工套娃），
///    与团队成员的 `level` 用词刻意分开。
void main() {
  ChatMessage tagged(
    String id, {
    String subId = 'sub_1',
    String name = '甲',
    String parentId = 'agt_1',
    int level = 1,
    String kind = 'text',
    String content = '',
    String toolName = '',
    Map<String, dynamic>? toolArguments,
    Map<String, dynamic>? usage,
  }) =>
      ChatMessage(
        id: id,
        role: 'agent',
        content: content,
        timestamp: DateTime(2026, 10, 4, 9),
        kind: kind,
        toolName: toolName.isEmpty ? null : toolName,
        toolArguments: toolArguments,
        usage: usage,
        subagentId: subId,
        subagentName: name,
        subagentParentId: parentId,
        subagentLevel: level,
      );

  ChatMessage subagentCall({String result = ''}) => ChatMessage(
    id: 'call1',
    role: 'assistant',
    content: '',
    timestamp: DateTime(2026, 10, 4, 9),
    kind: 'tool',
    toolName: 'subagent',
    toolArguments: const <String, dynamic>{
      'task': '把 a.dart 的旧 API 换掉',
      'name': '甲',
    },
    toolResult: result,
  );

  setUp(SubagentTranscript.instance.clear);

  test('callerNameOf：第一层是会话主人，嵌套的是上级临时员工', () {
    SubagentTranscript.instance.sync(<ChatMessage>[
      tagged('s1', subId: 'sub_1', name: '甲', parentId: 'agt_1', level: 1),
      tagged('s2', subId: 'sub_2', name: '乙', parentId: 'sub_1', level: 2),
    ]);
    expect(
      SubagentTranscript.instance.callerNameOf(
        'sub_1',
        ownerAgentId: 'agt_1',
        ownerName: '凌川',
      ),
      '凌川',
      reason: '第一层就是会话主人自己召的',
    );
    expect(
      SubagentTranscript.instance.callerNameOf(
        'sub_2',
        ownerAgentId: 'agt_1',
        ownerName: '凌川',
      ),
      '甲',
      reason: '嵌套的是上级临时员工召的',
    );
    expect(
      SubagentTranscript.instance.callerNameOf(
        'sub_1',
        ownerAgentId: 'agt_9',
        ownerName: '别人',
      ),
      isEmpty,
      reason: '父 id 既不是传进来的主人、也不在任何已知过程里 ⇒ 如实给空（不许编名字）',
    );
    expect(
      SubagentTranscript.instance.callerNameOf(
        'sub_nope',
        ownerAgentId: 'agt_1',
        ownerName: '凌川',
      ),
      isEmpty,
    );
  });

  testWidgets('工作进度页：头部写清"由谁召来 + 第几层"，过程按顺序摊开', (
    WidgetTester tester,
  ) async {
    SubagentTranscript.instance.sync(<ChatMessage>[
      tagged(
        's1',
        kind: 'subagent_task',
        content: '把 a.dart 的旧 API 换掉',
      ),
      tagged('s2', content: '先读文件'),
      tagged(
        's3',
        kind: 'tool',
        toolName: 'read',
        toolArguments: const <String, dynamic>{'file_path': 'a.dart'},
      ),
      tagged(
        's4',
        kind: 'subagent_report',
        content: '改完了：3 处替换',
        usage: const <String, dynamic>{'prompt_tokens': 1200, 'max_tokens': 64000},
      ),
    ]);

    await tester.pumpWidget(
      const MaterialApp(
        home: SubagentViewPage(
          subagentId: 'sub_1',
          agentId: 'agt_1',
          sessionId: 'session_default',
          ownerName: '凌川',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('临时员工「甲」'), findsOneWidget);
    expect(find.textContaining('由「凌川」召来'), findsOneWidget);
    expect(find.textContaining('第 1 层'), findsOneWidget);
    expect(find.textContaining('与它的调用方同级'), findsOneWidget, reason: '语义对齐');
    expect(find.textContaining('它的上下文：1200 / 64000 tokens'), findsOneWidget);
    expect(find.textContaining('不并进主 agent 的统计'), findsOneWidget);
    // 过程：文本 + 工具行（读取）+ 完成报告
    expect(find.text('先读文件'), findsOneWidget);
    expect(find.text('读取'), findsOneWidget);
    expect(find.text('完成报告'), findsOneWidget);
    expect(find.text('改完了：3 处替换'), findsOneWidget);
  });

  testWidgets('工作进度页：还没有过程消息时给可读说明（不是空白）', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SubagentViewPage(
          subagentId: 'sub_x',
          agentId: 'agt_1',
          sessionId: 'session_default',
          fallbackName: '丙',
          ownerName: '凌川',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('临时员工「丙」'), findsOneWidget, reason: '用带进来的名字兜底');
    expect(find.textContaining('还没有收到它的过程消息'), findsOneWidget);
  });

  testWidgets('subagent 工具详情：就地显示它召来的员工干了什么', (
    WidgetTester tester,
  ) async {
    SubagentTranscript.instance.sync(<ChatMessage>[
      tagged('s1', kind: 'subagent_task', content: '把 a.dart 的旧 API 换掉'),
      tagged(
        's2',
        kind: 'tool',
        toolName: 'read',
        toolArguments: const <String, dynamic>{'file_path': 'a.dart'},
      ),
      tagged('s3', kind: 'subagent_report', content: '改完了'),
    ]);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ToolDetail(
              message: subagentCall(
                result: '【临时员工「甲」】（id=sub_1，层级 1，本次=新召；复用入口 subagent_id=sub_1）\n改完了',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('这次调用召来的临时员工'), findsOneWidget);
    expect(find.textContaining('临时员工「甲」'), findsWidgets);
    expect(find.textContaining('第 1 层'), findsOneWidget);
    expect(find.text('读取'), findsOneWidget, reason: '它的工具调用就在这条详情里');
    expect(find.text('完成报告'), findsOneWidget);
  });
}
