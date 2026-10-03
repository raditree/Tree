import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/io/api_service.dart';
import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/widgets/tool_call_card.dart';

import 'fake_tree_core.dart';

/// `edit` 的「变更」一段要**读一次当前文件**才能给出带上下文的 diff（用户 2026-10-04
/// 「编辑做成 diff 的输出格式（最好带少量几行上下文方便用户阅读）」）。
///
/// 这里走真 HTTP（假核心）把"读文件 → 定位 → 带上下文渲染"整条链路钉住：
/// 上下文取自磁盘当前内容，`-` 旧行 / `+` 新行，拿不到就如实说明（另一条用例覆盖）。
void main() {
  late FakeTreeCore core;

  setUpAll(() {
    HttpOverrides.global = null;
  });

  setUp(() async {
    core = await FakeTreeCore.start();
    ApiService.baseUrl = core.baseUrl;
    ApiService.setToken('test-token');
  });

  tearDown(() async {
    await core.close();
  });

  Future<void> settle(WidgetTester tester, {int rounds = 16}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump();
    }
  }

  /// 详情页里出现过的某段可选文本（与工具行用例同一口径）
  /// 某段文本出现在可选文本里（**纯文本与富文本都要认**：着色之后正文走 textSpan）。
  bool hasSelectableText(WidgetTester tester, String expected) => tester
      .widgetList<SelectableText>(find.byType(SelectableText))
      .any(
        (SelectableText t) =>
            (t.data ?? t.textSpan?.toPlainText()) == expected,
      );

  ChatMessage editMessage({
    String oldText = '旧的一行',
    String newText = '新的一行',
    String filePath = 'a.dart',
  }) =>
      ChatMessage(
        id: 't1',
        role: 'assistant',
        content: '',
        timestamp: DateTime(2026, 10, 4, 9),
        kind: 'tool',
        toolName: 'edit',
        toolArguments: <String, dynamic>{
          'file_path': filePath,
          'old_text': oldText,
          'new_text': newText,
        },
        toolResult: '已替换 1 处：$filePath（文件现为 66 字节）',
      );

  Future<void> pumpDetail(WidgetTester tester, ChatMessage message) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ToolDetail(message: message, workspaceId: 'ws1'),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  testWidgets('edit：给出带上下文的 diff（上下文是磁盘上当前文件的行）', (
    WidgetTester tester,
  ) async {
    core.content = <String>[
      'line1',
      'line2',
      'line3',
      '新的一行',
      'tail1',
      'tail2',
      'tail3',
    ].join('\n');
    core.contentSize = core.content.length;

    await pumpDetail(tester, editMessage());

    expect(find.text('变更'), findsOneWidget);
    expect(find.text('调用参数'), findsOneWidget);
    expect(
      find.textContaining('@@ -1,1 +1,1 @@'),
      findsOneWidget,
      reason: '变更块头：旧/新行数与起始行',
    );
    expect(hasSelectableText(tester, '旧的一行'), isTrue, reason: '旧行（-）');
    expect(hasSelectableText(tester, '新的一行'), isTrue, reason: '新行（+）');
    expect(hasSelectableText(tester, 'line3'), isTrue, reason: '上面的上下文');
    expect(hasSelectableText(tester, 'tail1'), isTrue, reason: '下面的上下文');
    expect(find.text('-'), findsOneWidget, reason: '一行 - 标记');
    expect(find.text('+'), findsOneWidget, reason: '一行 + 标记');
    expect(
      find.textContaining('下面只显示调用参数'),
      findsNothing,
      reason: '拿到了真 diff，不该再退回参数视图',
    );
    expect(
      find.textContaining('- 1 行 · + 1 行'),
      findsOneWidget,
      reason: '行数小结',
    );
  });

  testWidgets('edit：文件里找不到这段（翻历史）⇒ 仍给 -/+ 变更块，并如实标"无上下文"', (
    WidgetTester tester,
  ) async {
    core.content = '完全另一份内容';
    core.contentSize = core.content.length;

    await pumpDetail(tester, editMessage());

    expect(
      find.textContaining('上下文不可得'),
      findsOneWidget,
      reason: '如实说明：上下文没被存下来（用户 2026-10-04 的追问）',
    );
    expect(
      find.textContaining('无上下文'),
      findsOneWidget,
      reason: '变更块头部也要写明',
    );
    expect(hasSelectableText(tester, '旧的一行'), isTrue, reason: '旧行（-）');
    expect(hasSelectableText(tester, '新的一行'), isTrue, reason: '新行（+）');
    expect(find.text('-'), findsOneWidget);
    expect(find.text('+'), findsOneWidget);
  });

  testWidgets('diff 与写入内容都**按源码着色**（不是一色到底）', (
    WidgetTester tester,
  ) async {
    core.content = <String>[
      '// 说明',
      'final int x = 1;',
      'final int y = 2;',
    ].join('\n');
    core.contentSize = core.content.length;

    await pumpDetail(
      tester,
      editMessage(oldText: 'final int x = 1;', newText: 'final int y = 2;'),
    );

    // 走 [SelectableText.rich]：正文被切成若干带色 span，而不是一整块单色
    final SelectableText line = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .firstWhere(
          (SelectableText t) =>
              t.textSpan != null && t.textSpan!.toPlainText() == 'final int y = 2;',
        );
    final Set<Color> colors = <Color>{};
    void walk(InlineSpan span) {
      final Color? color = span.style?.color;
      if (color != null) colors.add(color);
      if (span is TextSpan && span.children != null) {
        for (final InlineSpan child in span.children!) {
          walk(child);
        }
      }
    }

    walk(line.textSpan!);
    expect(
      colors.length,
      greaterThan(1),
      reason: '关键字 / 数字 / 普通文本应当有不同颜色（用户：为什么没按源码渲染）',
    );
  });

  testWidgets('edit：读不到文件（核心报错）⇒ 可读原因，不是空白', (
    WidgetTester tester,
  ) async {
    core.failContent = true;

    await pumpDetail(tester, editMessage(filePath: 'missing.dart'));

    expect(
      find.textContaining('读不到这个文件'),
      findsOneWidget,
      reason: '读失败要说清可能的原因',
    );
  });
}
