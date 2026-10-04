import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/widgets/message_list.dart';

/// 提问卡片的多问题口径（用户 2026-10-04）：
/// - **多问**：一张卡片问 N 题，逐题作答（选项点选或自由输入），底部「提交全部回答」
///   **一次性**回传（未作答的题传空串 ⇒ 核心算「未作答」）；
/// - **单问**：保持老行为——点选项立刻作答、输入后发送。
void main() {
  ChatMessage askMessage({
    required List<AskQuestionItem> questions,
    List<String> answers = const <String>[],
    bool answered = false,
  }) => ChatMessage(
    id: 'q_1',
    role: 'agent',
    content: questions.first.question,
    timestamp: DateTime(2026, 10, 4, 9),
    kind: 'ask_user_question',
    options: questions.first.options,
    questions: questions,
    answers: answers,
    answered: answered,
  );

  Future<List<List<String>>> pumpCard(
    WidgetTester tester,
    ChatMessage message,
  ) async {
    final List<List<String>> submitted = <List<String>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 520,
            height: 760,
            child: MessageList(
              slots: <ChatMessage?>[message],
              onAskAnswer: (String id, List<String> answers) {
                submitted.add(answers);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return submitted;
  }

  final List<AskQuestionItem> twoQuestions = <AskQuestionItem>[
    AskQuestionItem(question: '部署到哪台？', options: <String>['A 机', 'B 机']),
    AskQuestionItem(question: '要不要回滚预案？'),
  ];

  testWidgets('多问题：逐题作答后一次交齐', (WidgetTester tester) async {
    final List<List<String>> submitted = await pumpCard(
      tester,
      askMessage(questions: twoQuestions),
    );

    expect(find.text('Agent 需要你的输入（共 2 题）'), findsOneWidget);
    expect(find.text('1. 部署到哪台？'), findsOneWidget);
    expect(find.text('2. 要不要回滚预案？'), findsOneWidget);
    expect(find.text('还有 2 题未作答'), findsOneWidget);

    // 第一题点选项（多问：只选中，不提交）
    await tester.tap(find.text('B 机'));
    await tester.pumpAndSettle();
    expect(submitted, isEmpty, reason: '多问点选项只是选中，等「提交全部回答」');
    expect(find.text('还有 1 题未作答'), findsOneWidget);

    // 第二题自由输入
    await tester.enterText(find.byType(TextField).at(1), '要，先准备回滚脚本');
    await tester.pumpAndSettle();
    expect(find.text('已全部作答'), findsOneWidget);

    await tester.tap(find.text('提交全部回答'));
    await tester.pumpAndSettle();
    expect(submitted, <List<String>>[
      <String>['B 机', '要，先准备回滚脚本'],
    ]);
  });

  testWidgets('多问题：未答完也能提交（未答项按空串）', (WidgetTester tester) async {
    final List<List<String>> submitted = await pumpCard(
      tester,
      askMessage(questions: twoQuestions),
    );
    await tester.tap(find.text('A 机'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('提交全部回答'));
    await tester.pumpAndSettle();
    expect(submitted, <List<String>>[
      <String>['A 机', ''],
    ], reason: '第二题没答 ⇒ 空串 ⇒ 核心显示「未作答」');
  });

  testWidgets('单问题：点选项立刻作答（老行为），问题正文照旧渲染', (WidgetTester tester) async {
    final List<List<String>> submitted = await pumpCard(
      tester,
      askMessage(
        questions: <AskQuestionItem>[
          AskQuestionItem(question: '选 A 还是 B？', options: <String>['A', 'B']),
        ],
      ),
    );
    expect(find.text('Agent 需要你的输入'), findsOneWidget);
    expect(find.text('选 A 还是 B？'), findsOneWidget);
    expect(find.text('提交全部回答'), findsNothing, reason: '单问不出现批量提交键');

    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    expect(submitted, <List<String>>[
      <String>['B'],
    ]);
  });

  testWidgets('已作答的卡片：逐题列出答案，不再显示输入框', (WidgetTester tester) async {
    await pumpCard(
      tester,
      askMessage(
        questions: twoQuestions,
        answers: <String>['B 机', ''],
        answered: true,
      ),
    );
    expect(find.text('已提交你的选择'), findsOneWidget);
    expect(find.text('第 1 题：B 机'), findsOneWidget);
    expect(find.text('第 2 题：（未作答）'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });
}
