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
  Map<String, dynamic> args = const <String, dynamic>{'path': 'lib/main.dart'},
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
bool hasSelectableText(WidgetTester tester, String expected) => tester
    .widgetList<SelectableText>(find.byType(SelectableText))
    .any((SelectableText t) => t.data == expected);

void main() {
  setUp(DetailSelection.instance.clear);

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

    testWidgets('编辑类工具行尾给行数增量', (WidgetTester tester) async {
      await pumpRow(
        tester,
        toolMessage(
          name: 'edit',
          args: const <String, dynamic>{
            'path': 'a.dart',
            'old_string': 'old1\nold2',
            'new_string': 'new1\nnew2\nnew3',
          },
        ),
      );

      expect(find.text('编辑'), findsOneWidget);
      expect(find.text('+3 -2'), findsOneWidget);
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
            'path': 'lib/team/team_service.dart',
            'old_string': '旧的一段',
            'new_string': '新的一段',
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
      expect(hasSelectableText(tester, 'lib/team/team_service.dart'), isTrue);
      expect(hasSelectableText(tester, '新的一段'), isTrue);
      expect(hasSelectableText(tester, '改完了，共 1 处'), isTrue,
          reason: '结果要走可读字段，不是原始 JSON');
      expect(DetailSelection.instance.selectedId, 't1');
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

    test('一行正文取最关键参数，grep 把搜索词与路径都带上', () {
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

    test('增量只给编辑/写入，且按行数算', () {
      expect(
        toolDiffStat('edit', <String, dynamic>{'old_string': 'a', 'new_string': 'b\nc'}),
        '+2 -1',
      );
      expect(toolDiffStat('write', <String, dynamic>{'content': 'a\nb'}), '+2');
      expect(toolDiffStat('write', <String, dynamic>{'content': ''}), isNull);
      expect(toolDiffStat('read', <String, dynamic>{'path': 'x'}), isNull);
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

    test('FilePanel 多出第 5 个内置页签「详情」', () {
      expect(panel.contains('static const int _builtinTabCount = 5;'), isTrue);
      expect(panel.contains("const Tab(text: '详情')"), isTrue);
      expect(panel.contains('const DetailPanel()'), isTrue);
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
