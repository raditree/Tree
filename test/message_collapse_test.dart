import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/widgets/collapsed_run_row.dart';
import 'package:tree/ui/widgets/message_list.dart';
import 'package:tree/ui/widgets/thinking_card.dart';
import 'package:tree/ui/widgets/tool_call_card.dart';

/// F4 折叠组（规格 §3.2/§6 Q4「有就折叠」口径）。
///
/// TC-COLLAPSE-01（三轮点名）：100 条混杂消息滚到第 50 条处——展开后/收起后，
/// **折叠行上方的内容像素 top 两次采样零位移**。
final DateTime _base = DateTime(2026, 11, 1, 10);

ChatMessage _text(int i, {bool user = false}) => ChatMessage(
  id: 'm$i',
  role: user ? 'user' : 'agent',
  content: '正文消息 $i',
  timestamp: _base.add(Duration(milliseconds: i)),
);

ChatMessage _tool(int i, String name, {bool running = false}) => ChatMessage(
  id: 'm$i',
  role: 'agent',
  content: '',
  timestamp: _base.add(Duration(milliseconds: i)),
  kind: 'tool',
  toolName: name,
  toolRunning: running,
  preview: '参数 $i',
);

ChatMessage _thinking(int i) => ChatMessage(
  id: 'm$i',
  role: 'agent',
  content: '思考内容 $i',
  timestamp: _base.add(Duration(milliseconds: i)),
  kind: 'thinking',
);

/// 渲染树采样：这一趟真被布局过的子项 → 顶边（内容坐标）。
///
/// 与 message_list.dart 的 `_builtTopsFromRenderTree` 同一口径
/// （`SliverMultiBoxAdaptorParentData.layoutOffset` 实测值，不读 `.size`）。
Map<int, double> _builtTops(WidgetTester tester) {
  final RenderObject root = tester.renderObject(find.byType(ListView).first);
  RenderSliverList? found;
  void visit(RenderObject node) {
    if (found != null) return;
    if (node is RenderSliverList) {
      found = node;
      return;
    }
    node.visitChildren(visit);
  }

  if (root is RenderSliverList) {
    found = root;
  } else {
    root.visitChildren(visit);
  }
  final RenderSliverList list = found!;
  final Map<int, double> out = <int, double>{};
  RenderBox? item = list.firstChild;
  while (item != null) {
    final double? top = list.childScrollOffset(item);
    final ParentData? data = item.parentData;
    if (top != null &&
        data is SliverMultiBoxAdaptorParentData &&
        data.index != null) {
      out[data.index!] = top;
    }
    item = list.childAfter(item);
  }
  return out;
}

Widget _app(
  List<ChatMessage?> slots, {
  String? scrollTo,
  int scrollRev = 0,
  int revision = 1,
}) {
  return MaterialApp(
    home: Scaffold(
      body: MessageList(
        slots: slots,
        revision: revision,
        scrollToMessageId: scrollTo,
        scrollToRevision: scrollRev,
      ),
    ),
  );
}

/// 断言：`above` 之下（内容坐标更小）的所有行，前后两次采样 top 逐行零位移。
void _expectNoShiftAbove(
  Map<int, double> before,
  Map<int, double> after,
  double aboveTop,
) {
  before.forEach((int index, double top) {
    if (top >= aboveTop - 0.5) return;
    final double? later = after[index];
    if (later == null) return;
    expect(
      (later - top).abs(),
      lessThan(0.01),
      reason: '第 $index 行（折叠行上方）展开/收起后 top 位移 '
          '${later - top}',
    );
  });
}

void main() {
  testWidgets('TC-COLLAPSE-01：展开/收起后折叠行上方内容零位移', (
    WidgetTester tester,
  ) async {
    // 100 条混杂：文本/思考/工具交错；49-57 是目标 run（1 段思考 + 8 次工具调用）
    final List<ChatMessage?> slots = <ChatMessage?>[];
    slots.add(_text(0, user: true));
    for (int i = 1; i <= 47; i++) {
      switch (i % 5) {
        case 1:
          slots.add(_text(i));
        case 2:
          slots.add(_thinking(i));
        case 3:
          slots.add(_tool(i, 'read'));
        case 4:
          slots.add(_tool(i, 'grep'));
        default:
          slots.add(_text(i));
      }
    }
    slots.add(_text(48));
    slots.add(_thinking(49));
    slots.add(_tool(50, 'read'));
    slots.add(_tool(51, 'read'));
    slots.add(_tool(52, 'read'));
    slots.add(_tool(53, 'grep'));
    slots.add(_tool(54, 'grep'));
    slots.add(_tool(55, 'edit'));
    slots.add(_tool(56, 'edit'));
    slots.add(_tool(57, 'terminal'));
    slots.add(_text(58));
    slots.add(_text(59));
    slots.add(_text(60));
    for (int i = 61; i < 100; i++) {
      slots.add(i % 3 == 0 ? _thinking(i) : _tool(i, 'write'));
    }

    await tester.pumpWidget(_app(slots));
    await tester.pumpAndSettle();
    // 定位到 m60：折叠行（组首 49）进视口可点，其上方内容在视口里。
    await tester.pumpWidget(_app(slots, scrollTo: 'm60', scrollRev: 1));
    await tester.pumpAndSettle();

    final Finder collapseRow = find.byKey(
      const ValueKey<String>('collapsed-run-m49'),
    );
    expect(collapseRow, findsOneWidget);
    expect(
      find.textContaining('折叠 8 次工具调用（读取×3 · 搜索×2 · 编辑×2 · 运行命令×1）· 含 1 段思考，点击展开 ›'),
      findsOneWidget,
    );

    final Map<int, double> tops0 = _builtTops(tester);
    final double collapseTop = tops0[49]!;

    // ① 展开
    await tester.tap(collapseRow);
    await tester.pumpAndSettle();
    final Map<int, double> tops1 = _builtTops(tester);
    _expectNoShiftAbove(tops0, tops1, collapseTop);
    expect((tops1[49]! - collapseTop).abs(), lessThan(0.01));
    // 展开态：组内行摊开（组员可能超出视口，按渲染树 top 判定而非计数），
    // 文案换成「点击收起」。
    expect(tops1.containsKey(50) && tops1.containsKey(57), isTrue);
    expect(tops1[50]!, greaterThan(tops1[49]!));
    expect(tops1[57]! - tops1[50]!, greaterThan(100));
    expect(find.textContaining('点击收起 ›'), findsOneWidget);

    // ② 收起
    await tester.tap(collapseRow);
    await tester.pumpAndSettle();
    final Map<int, double> tops2 = _builtTops(tester);
    _expectNoShiftAbove(tops0, tops2, collapseTop);
    expect((tops2[49]! - collapseTop).abs(), lessThan(0.01));
    expect(find.textContaining('折叠 8 次工具调用'), findsOneWidget);
  });

  testWidgets('跑着的工具不折叠；完成即折叠', (WidgetTester tester) async {
    final List<ChatMessage?> slots = <ChatMessage?>[
      _text(0, user: true),
      _tool(1, 'read', running: true),
      _text(2),
    ];
    await tester.pumpWidget(_app(slots));
    // 跑着的工具带转圈动画，pumpAndSettle 永不收敛：只推固定帧数
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(CollapsedRunRow), findsNothing);
    expect(find.byType(ToolCallCard), findsOneWidget);

    // 跑完（原地翻标志位 + revision）→ 折叠
    slots[1] = _tool(1, 'read');
    await tester.pumpWidget(_app(slots, revision: 2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(CollapsedRunRow), findsOneWidget);
    expect(find.textContaining('折叠 1 次工具调用（读取×1）'), findsOneWidget);
  });

  testWidgets('纯思考组也折叠（「折叠 m 段思考」）', (WidgetTester tester) async {
    final List<ChatMessage?> slots = <ChatMessage?>[
      _text(0),
      _thinking(1),
      _thinking(2),
      _text(3),
    ];
    await tester.pumpWidget(_app(slots));
    await tester.pumpAndSettle();
    expect(find.textContaining('折叠 2 段思考，点击展开 ›'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('collapsed-run-m1')));
    await tester.pumpAndSettle();
    expect(find.byType(ThinkingCard), findsNWidgets(2));
  });

  testWidgets('提问是分隔标志；全局同时只展开一个组', (WidgetTester tester) async {
    final List<ChatMessage?> slots = <ChatMessage?>[
      _tool(1, 'read'),
      ChatMessage(
        id: 'ask',
        role: 'agent',
        content: '问题？',
        timestamp: _base,
        kind: 'ask_user_question',
      ),
      _tool(3, 'write'),
    ];
    await tester.pumpWidget(_app(slots));
    await tester.pumpAndSettle();
    // 提问把两侧工具切成两个 run（各自「有就折叠」）
    expect(find.byType(CollapsedRunRow), findsNWidgets(2));

    await tester.tap(find.byKey(const ValueKey<String>('collapsed-run-m1')));
    await tester.pumpAndSettle();
    expect(find.byType(ToolCallCard), findsNWidgets(1));

    // 点开第二组：第一组自动收起（Q5）
    await tester.tap(find.byKey(const ValueKey<String>('collapsed-run-m3')));
    await tester.pumpAndSettle();
    expect(find.textContaining('点击收起 ›'), findsOneWidget);
    expect(find.textContaining('点击展开 ›'), findsOneWidget);
  });
}
