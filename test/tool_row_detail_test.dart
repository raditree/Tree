import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/services/detail_selection.dart';
import 'package:tree/ui/widgets/detail_panel.dart';
import 'package:tree/ui/widgets/thinking_card.dart';
import 'package:tree/ui/widgets/tool_call_card.dart';

/// 消息流的两行式排版 + 右栏「详情」页。
///
/// 口径（[lib/README.md](../lib/README.md) 不变量 11）：工具调用与思考默认各占**一行**
/// （中文标签 + 关键参数），完整内容不在中栏就地展开，而是点这一行 → 右栏「详情」页；
/// 悬停要有呼应（图标提亮 + 底色）。
ChatMessage toolMessage({
  String id = 't1',
  String name = 'read',
  // 参数键名按核心工具 schema 写（builtin_tools.dart 的 read/write/edit 都用
  // file_path，不是 path）——臆想的键名取不到参数，行正文与行尾增量都会是空的。
  Map<String, dynamic> args =
      const <String, dynamic>{'file_path': 'lib/main.dart'},
  String result = '',
  bool running = false,
}) =>
    ChatMessage(
      id: id,
      role: 'assistant',
      content: '',
      timestamp: DateTime(2026, 10, 2, 21, 39),
      kind: 'tool',
      toolName: name,
      toolArguments: args,
      toolResult: result,
      toolRunning: running,
    );

ChatMessage thinkingMessage({
  String id = 'k1',
  String text = '先看看 team 的字段，再决定怎么改',
  bool streaming = false,
}) =>
    ChatMessage(
      id: id,
      role: 'assistant',
      content: text,
      timestamp: DateTime(2026, 10, 2, 21, 39),
      kind: 'thinking',
      isStreaming: streaming,
    );

Widget rowOf(ChatMessage m) =>
    m.kind == 'tool' ? ToolCallCard(message: m) : ThinkingCard(message: m);

Future<void> pumpRow(WidgetTester tester, ChatMessage m) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: ListView(children: <Widget>[rowOf(m)])),
  ));
}

/// 一边是中栏的行、一边是右栏的详情页（真实布局就是这个关系）
Future<void> pumpRowWithDetail(WidgetTester tester, ChatMessage m) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Row(
        children: <Widget>[
          Expanded(child: rowOf(m)),
          const SizedBox(width: 320, child: DetailPanel()),
        ],
      ),
    ),
  ));
}

/// 详情页里出现过的某段可选文本
/// 某段文本出现在可选文本里（纯文本与富文本都要认：详情页的变更块着色后走 textSpan）。
bool hasSelectableText(WidgetTester tester, String expected) => tester
    .widgetList<SelectableText>(find.byType(SelectableText))
    .any(
      (SelectableText t) => (t.data ?? t.textSpan?.toPlainText()) == expected,
    );

void main() {
  setUp(DetailSelection.instance.clear);

  group('临时员工（subagent）工具行', () {
    testWidgets('详情页摊开**完整 task**：长任务不再打省略号（右侧详情就是看全文的地方）',
        (WidgetTester tester) async {
      // 撑到 400 字以上（旧口径正好在那里截断加「…」），并保留真实 subagent 任务书里常见的换行
      final String longTask = List<String>.generate(
        12,
        (int i) =>
            '第 ${i + 1} 段：这一段是为了把 task 撑到 400 字以上，并保留真实任务书里常见的换行与分点，'
            '以便验证详情页确实摊开了全文而不是截断。',
      ).join('\n');
      expect(longTask.length, greaterThan(400),
          reason: '必须超过旧的截断线（400 字），否则这条用例测不到东西');
      await pumpRowWithDetail(
        tester,
        toolMessage(
          id: 'sub1',
          name: 'subagent',
          args: <String, dynamic>{
            'task': longTask,
            'subagent_id': 'sub_1791018557990_6bdd4c_6da',
          },
          // 注意：不能给 running: true —— 卡片在转圈，`pumpAndSettle` 永远不会 settle。
        ),
      );

      await tester.tap(find.byType(ToolCallCard));
      await tester.pumpAndSettle();

      expect(find.text('调用参数'), findsOneWidget);
      expect(hasSelectableText(tester, longTask), isTrue,
          reason: '详情页要给全文（用户 2026-10-03：「subagent 的工具调用详情的 task 过长会打省略号'
              '（在现在的右侧查看详情的设计下，没必要省略了）」）');
      expect(
        hasSelectableText(tester, '${longTask.substring(0, 400)}…'),
        isFalse,
        reason: '旧的"400 字 + 省略号"截断必须消失',
      );
      expect(
        hasSelectableText(tester, 'sub_1791018557990_6bdd4c_6da'),
        isTrue,
        reason: '复用的 subagent_id 照旧给出来',
      );
    });

    testWidgets('中文标签是「临时员工」，正文给 task；行尾不给增量',
        (WidgetTester tester) async {
      await pumpRow(
        tester,
        toolMessage(
          name: 'subagent',
          args: const <String, dynamic>{
            'task': '把 a.dart 里的旧 API 全部换成新 API',
          },
        ),
      );

      expect(find.text('临时员工'), findsOneWidget);
      expect(find.text('把 a.dart 里的旧 API 全部换成新 API'), findsOneWidget);
      expect(
        toolDiffStat('subagent', const <String, dynamic>{'task': 'x'}),
        isNull,
        reason: '不是编辑/写入类工具，行尾宁缺勿假（不给 +0 -0）',
      );
    });

    testWidgets('复用与后台在行里能一眼看出来', (WidgetTester tester) async {
      await pumpRow(
        tester,
        toolMessage(
          name: 'subagent',
          args: const <String, dynamic>{
            'subagent_id': 'sub_1790_ab_1',
            'background': true,
            'task': '接着把剩下的两个文件改完',
          },
        ),
      );

      expect(
        find.text('复用 sub_1790_ab_1 · 后台 · 接着把剩下的两个文件改完'),
        findsOneWidget,
      );
    });

    testWidgets('只有复用入口没有 task：行里只写复用入口，不留空行',
        (WidgetTester tester) async {
      await pumpRow(
        tester,
        toolMessage(
          name: 'subagent',
          args: const <String, dynamic>{'subagent_id': 'sub_9'},
        ),
      );

      expect(find.text('复用 sub_9'), findsOneWidget);
    });
  });

  group('工具行只占一行', () {
    testWidgets('中文标签 + 关键参数，不把参数表和结果铺开',
        (WidgetTester tester) async {
      await pumpRow(
        tester,
        toolMessage(result: '第一行\n第二行不该出现在行里'),
      );

      expect(find.text('读取'), findsOneWidget);
      expect(find.text('lib/main.dart'), findsOneWidget);
      expect(find.textContaining('第二行不该出现在行里'), findsNothing,
          reason: '一行只给关键参数，完整结果去详情页');
      expect(find.byType(SelectableText), findsNothing);
    });

    testWidgets('编辑类工具行尾给行数增量（键名按核心 schema）',
        (WidgetTester tester) async {
      await pumpRow(
        tester,
        toolMessage(
          name: 'edit',
          args: const <String, dynamic>{
            'file_path': 'a.dart',
            'old_text': 'old1\nold2',
            'new_text': 'new1\nnew2\nnew3',
          },
        ),
      );

      expect(find.text('编辑'), findsOneWidget);
      expect(find.text('a.dart'), findsOneWidget, reason: '行正文取 file_path');
      expect(find.text('+3 -2'), findsOneWidget);
    });

    testWidgets('edit 单行替换 ⇒ +1 -1', (WidgetTester tester) async {
      await pumpRow(
        tester,
        toolMessage(
          name: 'edit',
          args: const <String, dynamic>{
            'file_path': '.self/memory.md',
            'old_text': '旧的一行',
            'new_text': '新的一行',
          },
        ),
      );

      expect(find.text('+1 -1'), findsOneWidget);
    });

    testWidgets('write ⇒ +N（整段内容行数），行尾没有 - 一侧',
        (WidgetTester tester) async {
      await pumpRow(
        tester,
        toolMessage(
          name: 'write',
          args: const <String, dynamic>{
            'file_path': 'notes/todo.md',
            'content': '第一行\n第二行\n',
          },
        ),
      );

      expect(find.text('+2'), findsOneWidget);
      expect(find.textContaining('-'), findsNothing, reason: 'write 没有减号一侧');
    });

    testWidgets('取不到参数时行尾不显示 +0 -0（只显示能确定的一侧或什么都不显示）',
        (WidgetTester tester) async {
      // 参数缺失（老键名 / 被截断）：宁可什么都不显示
      await pumpRow(
        tester,
        toolMessage(
          name: 'edit',
          args: const <String, dynamic>{'file_path': 'a.dart'},
        ),
      );
      expect(find.text('+0 -0'), findsNothing);
      expect(find.textContaining('+0'), findsNothing);
      expect(find.textContaining('-0'), findsNothing);

      // 只拿到旧文本：只显示 -N
      await pumpRow(
        tester,
        toolMessage(
          name: 'edit',
          args: const <String, dynamic>{'old_text': 'l1\nl2\nl3'},
        ),
      );
      expect(find.text('-3'), findsOneWidget);
      expect(find.textContaining('+'), findsNothing);
    });

    testWidgets('运行中的工具行给进度圈', (WidgetTester tester) async {
      await pumpRow(tester, toolMessage(running: true));

      expect(
        find.descendant(
          of: find.byType(ToolCallCard),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });

    testWidgets('悬停有呼应：图标从半透明提亮到实色', (WidgetTester tester) async {
      await pumpRow(tester, toolMessage());
      Icon icon() =>
          tester.widget<Icon>(find.byIcon(Icons.description_outlined));
      final Color idle = icon().color!;

      final TestGesture gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.byType(ToolCallCard)));
      await tester.pump();

      expect(icon().color, isNot(idle), reason: '鼠标附上来要有变化');
    });
  });

  group('思考行', () {
    testWidgets('一行摘要（去掉 markdown 标记）', (WidgetTester tester) async {
      await pumpRow(
        tester,
        thinkingMessage(text: '## 先看字段\n后面还有一大段不该显示'),
      );

      expect(find.text('思考'), findsOneWidget);
      expect(find.text('先看字段'), findsOneWidget);
      expect(find.textContaining('后面还有一大段'), findsNothing);
    });

    testWidgets('思考中：标签变「思考中」并转圈', (WidgetTester tester) async {
      await pumpRow(tester, thinkingMessage(streaming: true));

      expect(find.text('思考中'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  group('点击 → 右栏详情页', () {
    testWidgets('工具：完整参数与完整结果都在详情页', (WidgetTester tester) async {
      await pumpRowWithDetail(
        tester,
        toolMessage(
          name: 'edit',
          args: const <String, dynamic>{
            'file_path': 'lib/team/team_service.dart',
            'old_text': '旧的一段',
            'new_text': '新的一段',
          },
          result: '{"content": "改完了，共 1 处"}',
        ),
      );

      // 点之前：详情页是空态，参数正文一个字都不在中栏
      expect(find.text('点中栏的工具调用或思考'), findsOneWidget);
      expect(find.text('调用参数'), findsNothing);

      await tester.tap(find.byType(ToolCallCard));
      await tester.pumpAndSettle();

      expect(find.text('调用参数'), findsOneWidget);
      expect(find.text('执行结果'), findsOneWidget);
      expect(hasSelectableText(tester, 'lib/team/team_service.dart'), isTrue,
          reason: '「文件」取 file_path');
      expect(hasSelectableText(tester, '旧的一段'), isTrue,
          reason: '「查找」取 old_text');
      expect(hasSelectableText(tester, '新的一段'), isTrue,
          reason: '「替换」取 new_text');
      expect(hasSelectableText(tester, '改完了，共 1 处'), isTrue,
          reason: '结果要走可读字段，不是原始 JSON');
      expect(DetailSelection.instance.selectedId, 't1');
    });

    testWidgets('写入：详情页摊开**内容本身**（不再只给"内容长度"）', (
      WidgetTester tester,
    ) async {
      await pumpRowWithDetail(
        tester,
        toolMessage(
          name: 'write',
          args: const <String, dynamic>{
            'file_path': 'lib/a.dart',
            'content': 'class A {\n  int x = 1;\n}\n',
          },
          result: '已写入 lib/a.dart（24 字节，3 行）',
        ),
      );

      await tester.tap(find.byType(ToolCallCard));
      await tester.pumpAndSettle();

      expect(find.text('变更'), findsOneWidget);
      expect(
        hasSelectableText(tester, 'class A {\n  int x = 1;\n}\n'),
        isTrue,
        reason: '写入的内容必须能看到（用户 2026-10-04：「写入的具体内容呢？」）',
      );
      expect(find.textContaining('3 行'), findsWidgets, reason: '行数摘要照旧给');
    });

    testWidgets('编辑：拿不到文件时如实说明，并退回「查找 / 替换」参数视图', (
      WidgetTester tester,
    ) async {
      // 这个夹具的 DetailPanel 没有工作空间 ⇒ 读不到文件 ⇒ 不许编一份像 diff 的东西
      await pumpRowWithDetail(
        tester,
        toolMessage(
          name: 'edit',
          args: const <String, dynamic>{
            'file_path': 'lib/a.dart',
            'old_text': 'old();',
            'new_text': 'new();',
          },
        ),
      );

      await tester.tap(find.byType(ToolCallCard));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('上下文不可得'),
        findsOneWidget,
        reason: '拿不到就直说，别让用户以为看到的是完整 diff',
      );
      expect(hasSelectableText(tester, 'old();'), isTrue, reason: '旧行（-）');
      expect(hasSelectableText(tester, 'new();'), isTrue, reason: '新行（+）');
      expect(find.text('-'), findsOneWidget);
      expect(find.text('+'), findsOneWidget);
    });

    testWidgets('再点一次同一条工具行 = 取消选中（不用去详情页点「关闭详情」）', (
      WidgetTester tester,
    ) async {
      await pumpRowWithDetail(tester, toolMessage(result: '结果'));

      await tester.tap(find.byType(ToolCallCard));
      await tester.pumpAndSettle();
      expect(DetailSelection.instance.selectedId, 't1');
      expect(find.text('调用参数'), findsOneWidget);

      // 再点一次同一条：取消（详情页回到空态，右键「关闭详情」那颗键都不用碰）
      await tester.tap(find.byType(ToolCallCard));
      await tester.pumpAndSettle();
      expect(DetailSelection.instance.message, isNull);
      expect(find.text('点中栏的工具调用或思考'), findsOneWidget);
      expect(find.text('调用参数'), findsNothing);
    });

    testWidgets('思考行同一口径：再点一次也取消', (WidgetTester tester) async {
      await pumpRowWithDetail(tester, thinkingMessage(text: '理由'));
      await tester.tap(find.byType(ThinkingCard));
      await tester.pumpAndSettle();
      expect(DetailSelection.instance.selectedId, 'k1');
      await tester.tap(find.byType(ThinkingCard));
      await tester.pumpAndSettle();
      expect(DetailSelection.instance.message, isNull);
    });

    testWidgets('思考：详情页给完整推理内容', (WidgetTester tester) async {
      await pumpRowWithDetail(
        tester,
        thinkingMessage(text: '第一段理由\n\n第二段理由（完整内容）'),
      );

      await tester.tap(find.byType(ThinkingCard));
      await tester.pumpAndSettle();

      expect(find.byType(ThinkingDetail), findsOneWidget);
      // 完整推理走 markdown：断言 MarkdownBody 拿到的原文，而不是屏幕上被
      // 折行 / 渲染后的碎片
      final MarkdownBody body = tester.widget<MarkdownBody>(find.descendant(
        of: find.byType(ThinkingDetail),
        matching: find.byType(MarkdownBody),
      ));
      expect(body.data, '第一段理由\n\n第二段理由（完整内容）');
    });

    testWidgets('关闭按钮清空选中，详情页回到空态', (WidgetTester tester) async {
      await pumpRowWithDetail(tester, toolMessage());
      await tester.tap(find.byType(ToolCallCard));
      await tester.pumpAndSettle();
      expect(find.text('调用参数'), findsOneWidget);

      await tester.tap(find.byTooltip('关闭详情'));
      await tester.pumpAndSettle();

      expect(DetailSelection.instance.message, isNull);
      expect(find.text('点中栏的工具调用或思考'), findsOneWidget);
    });

    testWidgets('选中的那一行有底色（选中态可见）', (WidgetTester tester) async {
      await pumpRowWithDetail(tester, toolMessage());
      Material materialOf() => tester.widget<Material>(find.descendant(
            of: find.byType(ToolCallCard),
            matching: find.byType(Material),
          ));
      expect(materialOf().color, Colors.transparent);

      await tester.tap(find.byType(ToolCallCard));
      await tester.pumpAndSettle();

      expect(materialOf().color, isNot(Colors.transparent));
    });
  });

  group('派生的显示文本（纯函数）', () {
    test('中文短名认不出工具时退回原名，空名给「工具」', () {
      expect(toolLabel('read'), '读取');
      expect(toolLabel('terminal'), '运行命令');
      expect(toolLabel('weird_tool'), 'weird_tool');
      expect(toolLabel(''), '工具');
    });

    test('一行正文取最关键参数（read/write/edit 用核心的 file_path），grep 带搜索词与路径',
        () {
      expect(
        toolLineValue(toolMessage(
          name: 'read',
          args: const <String, dynamic>{'file_path': 'lib/main.dart'},
        )),
        'lib/main.dart',
      );
      expect(
        toolLineValue(toolMessage(
          name: 'grep',
          args: const <String, dynamic>{'pattern': 'team_id', 'path': 'lib'},
        )),
        'team_id  ·  lib',
      );
      expect(
        toolLineValue(toolMessage(
          name: 'terminal',
          args: const <String, dynamic>{'cmd': 'flutter test'},
        )),
        'flutter test',
      );
      // 认不出的工具没有关键参数时，退回结果摘要（别留一行空白）
      expect(
        toolLineValue(toolMessage(name: 'weird', args: const {}, result: '{"content": "做完了"}')),
        '做完了',
      );
    });

    test('增量只给编辑/写入，并直接吃真实核心 schema 的键名', () {
      // 下面两个 map 就是核心 builtin_tools.dart 里 edit / write 的 invocation JSON：
      // edit 在 176-194 行（file_path / old_text / new_text / replace_all），
      // write 在 162-169 行（file_path / content）。
      const Map<String, dynamic> editInvocation = <String, dynamic>{
        'file_path': '.self/memory.md',
        'old_text': '第一行\n第二行',
        'new_text': '换成一行',
        'replace_all': false,
      };
      expect(toolDiffStat('edit', editInvocation), '+1 -2');

      const Map<String, dynamic> writeInvocation = <String, dynamic>{
        'file_path': 'notes/todo.md',
        'content': '第一行\n第二行\n',
      };
      expect(toolDiffStat('write', writeInvocation), '+2');

      // 臆想的键名（别的生态的 path/old_string/new_string）不是数据来源
      expect(
        toolDiffStat('edit', <String, dynamic>{
          'path': 'a.dart',
          'old_string': 'a',
          'new_string': 'b\nc',
        }),
        isNull,
      );
      expect(toolDiffStat('write', <String, dynamic>{'path': 'a'}), isNull);
      expect(toolDiffStat('read', <String, dynamic>{'file_path': 'x'}), isNull);
      expect(toolDiffStat('write', <String, dynamic>{'content': ''}), isNull);
    });

    test('edit 的加减两侧：单行 +1 -1，三行换两行 +2 -3', () {
      expect(
        toolDiffStat('edit', <String, dynamic>{
          'old_text': '同一行',
          'new_text': '也是同一行',
        }),
        '+1 -1',
      );
      expect(
        toolDiffStat('edit', <String, dynamic>{
          'old_text': 'l1\nl2\nl3',
          'new_text': 'n1\nn2',
        }),
        '+2 -3',
      );
      // 三行删成空串 = 有效编辑：+0 -3（两侧都给参数时保持 +A -B 格式）
      expect(
        toolDiffStat('edit', <String, dynamic>{
          'old_text': 'l1\nl2\nl3',
          'new_text': '',
        }),
        '+0 -3',
      );
    });

    test('缺参数时不给增量（不显示 +0 -0），只给一侧时只显示那一侧', () {
      expect(toolDiffStat('edit', null), isNull);
      expect(toolDiffStat('edit', const <String, dynamic>{}), isNull);
      expect(toolDiffStat('edit', const <String, dynamic>{'file_path': 'a.dart'}),
          isNull);
      expect(
        toolDiffStat('edit', const <String, dynamic>{'old_text': 'l1\nl2'}),
        '-2',
      );
      expect(toolDiffStat('edit', const <String, dynamic>{'new_text': 'n1'}), '+1');
      expect(
        toolDiffStat('edit',
            const <String, dynamic>{'old_text': '', 'new_text': ''}),
        isNull,
      );
      expect(toolDiffStat('write', const <String, dynamic>{'file_path': 'x'}), isNull);
      expect(toolDiffStat('write', null), isNull);
      expect(toolDiffStat('terminal', const <String, dynamic>{'cmd': 'ls'}), isNull);
    });

    test('行数口径与核心 LineSplitter 一致：末尾换行不多算、空行照算', () {
      expect(countTextLines(''), 0);
      expect(countTextLines('a'), 1);
      expect(countTextLines('a\n'), 1);
      expect(countTextLines('a\nb'), 2);
      expect(countTextLines('a\n\nb'), 3);
      expect(countTextLines('a\n\n'), 2);
      expect(countTextLines('\n'), 1);
      expect(countTextLines('a\r\nb\r\n'), 2);
      expect(countTextLines('a\rb'), 2);
      expect(countTextLines('a\r'), 1);
    });

    test('思考摘要：去 markdown 标记、压空白、超长截断', () {
      expect(thinkingSummary('## 标题\n正文'), '标题');
      expect(thinkingSummary('**加粗** 与 `代码`'), '加粗 与 代码');
      final String long = List<String>.filled(100, '字').join();
      expect(thinkingSummary(long).length, 81, reason: '80 字 + 省略号');
    });
  });

  group('右栏「详情」页的接线（源钉）', () {
    final String panel =
        File('lib/ui/widgets/file_panel.dart').readAsStringSync();
    final String page = File('lib/ui/pages/main_page.dart').readAsStringSync();

    test('FilePanel 多出第 6 个内置页签「详情」（新增「正在执行的 tool」后仍是最后一页）', () {
      expect(panel.contains('static const int _builtinTabCount = 6;'), isTrue);
      expect(panel.contains("const Tab(text: '正在执行的 tool')"), isTrue);
      expect(panel.contains("const Tab(text: '详情')"), isTrue);
      // 详情页要带上工作空间：edit 的「变更」得读一次当前文件才有上下文（用户 2026-10-04）
      expect(panel.contains('DetailPanel('), isTrue);
      expect(panel.contains('workspaceId: widget.workspaceId'), isTrue);
    });

    test('选中详情时自动切到该页签，并让右栏收着就展开', () {
      expect(
        panel.contains('DetailSelection.instance.addListener(_onDetailSelected)'),
        isTrue,
      );
      expect(panel.contains('_tabController.animateTo(_detailTabIndex)'), isTrue);
      expect(
        page.contains('DetailSelection.instance.addListener(_onDetailSelected)'),
        isTrue,
      );
      expect(page.contains('if (!_rightCollapsed) return;'), isTrue);
    });
  });
}
