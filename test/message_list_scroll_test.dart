import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/widgets/message_list.dart';

/// 构造一条消息：[lines] 行文本决定气泡高度（1 行=短消息，多行=长消息），
/// [content] 可覆盖默认文本（用于验证渲染顺序）
ChatMessage _msg(String id, {int lines = 1, String? content}) {
  return ChatMessage(
    id: id,
    role: 'user',
    content: content ??
        List<String>.filled(lines, 'line content for height').join('\n'),
    timestamp: DateTime(2026, 1, 1),
  );
}

/// 不均匀超长会话：前 [shortCount] 条短消息 + 后 [longCount] 条高消息。
///
/// 关键：前面的短消息决定了首帧「平均高度外推」的 maxScrollExtent 严重偏小，
/// 只有迭代校正（每帧复查 extent 并继续 jump）才能到达真实底部——
/// 正是「超长会话一次 animateTo 到不了底」的复现场景。
List<ChatMessage> _longSession({
  int shortCount = 250,
  int longCount = 50,
  int longLines = 60,
}) {
  return <ChatMessage>[
    for (int i = 0; i < shortCount; i++) _msg('short_$i'),
    for (int i = 0; i < longCount; i++) _msg('long_$i', lines: longLines),
  ];
}

Widget _wrap(
  List<ChatMessage> messages, {
  int revision = 0,
  bool bottomJump = true,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 400,
        height: 600,
        child: MessageList(
          messages: messages,
          revision: revision,
          bottomJump: bottomJump,
        ),
      ),
    ),
  );
}

/// 读取列表滚动位置（controller 由 MessageList 内部持有，经 ListView.widget 读取）
ScrollPosition _position(WidgetTester tester) {
  final ListView list = tester.widget<ListView>(find.byType(ListView));
  return list.controller!.position;
}

/// 推进若干帧，让滚动动画/重载后的 post-frame 回调跑完
Future<void> _settleJump(WidgetTester tester) async {
  for (int i = 0; i < 90; i++) {
    await tester.pump();
  }
}

void main() {
  testWidgets('反转列表视觉顺序：最新消息在底部、最旧在顶部', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(<ChatMessage>[
      _msg('oldest', content: 'oldest message'),
      _msg('middle', content: 'middle message'),
      _msg('newest', content: 'newest message'),
    ]));

    final Finder oldest = find.textContaining('oldest message');
    final Finder newest = find.textContaining('newest message');
    expect(oldest, findsOneWidget);
    expect(newest, findsOneWidget);
    // 反转列表 + 反向索引：视觉上「顶→底 = 旧→新」，
    // 最新消息 y 坐标最大（在底部），最旧消息在顶部
    expect(tester.getTopLeft(newest).dy,
        greaterThan(tester.getTopLeft(oldest).dy));
  });

  testWidgets('超长会话初始进入即直接渲染在底部（反转列表 offset 0）',
      (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(_longSession()));
    await tester.pump(); // 首帧

    final ScrollPosition pos = _position(tester);
    expect(pos.maxScrollExtent, greaterThan(0), reason: '列表应有可滚动内容');
    // 反转列表：offset 0 即视觉底部，首帧即贴底
    // （无「顶部闪一下再滑到底部」，也无「到不了真实底部」问题）
    expect(pos.pixels, closeTo(0, 1), reason: '初始位置应直接落在底部');
  });

  testWidgets('历史整批重载（bottomJump=true）后直达底部', (WidgetTester tester) async {
    // 首次：短会话
    await tester.pumpWidget(_wrap(<ChatMessage>[_msg('a')], revision: 1));
    await _settleJump(tester);

    // 同位置重建（State 保留，触发 didUpdateWidget）：revision 变化 + 超长列表
    await tester.pumpWidget(_wrap(_longSession(), revision: 2));
    await _settleJump(tester);

    final ScrollPosition pos = _position(tester);
    expect(pos.maxScrollExtent, greaterThan(0));
    expect(pos.pixels, closeTo(0, 1),
        reason: '历史重载应直达底部而非下滑动画');
  });

  testWidgets('流式追加（bottomJump=false）平滑跟随到新底部', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(_longSession(), revision: 1));
    await _settleJump(tester);

    // 底部追加一条新消息：bottomJump=false → 平滑动画滚动 + 完成后校正
    final List<ChatMessage> more =
        <ChatMessage>[..._longSession(), _msg('new')];
    await tester.pumpWidget(_wrap(more, revision: 2, bottomJump: false));
    await tester.pumpAndSettle();

    final ScrollPosition pos = _position(tester);
    expect(pos.pixels, closeTo(0, 1),
        reason: '流式追加后应跟随到新底部');
  });
}
