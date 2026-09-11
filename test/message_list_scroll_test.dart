import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/widgets/message_list.dart';

/// MessageList 滚动跟随行为测试
///
/// 覆盖：
/// - 贴底时新增消息保持贴底、回底按钮隐藏；
/// - 用户上滚脱离后，内容更新不把视口拽回底部（核心回归）；
/// - 「回到底部」按钮：显隐 / 点击回底 / 回底动画被拖拽打断后不回拽；
/// - 滚回底部附近自动恢复跟随；
/// - 历史整批重载直达底部并恢复跟随；
/// - 定位跳转进入脱离态。
void main() {
  // 取第一个 Scrollable（即外层 ListView 的），消息气泡内 EditableText 亦含 Scrollable
  double offsetOf(WidgetTester tester) => tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position
      .pixels;

  /// 获取「回到底部」按钮的显隐透明度（0=隐藏 / 1=显示）
  double buttonOpacity(WidgetTester tester) {
    final Finder f = find.ancestor(
      of: find.byIcon(Icons.arrow_downward),
      matching: find.byType(AnimatedOpacity),
    );
    return tester.widget<AnimatedOpacity>(f).opacity;
  }

  Future<GlobalKey<_HarnessState>> pumpList(WidgetTester tester) async {
    final GlobalKey<_HarnessState> k = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: k));
    await tester.pumpAndSettle();
    return k;
  }

  /// 从列表右侧空白区拖动，避免与文本选择手势竞争
  const Offset blankPoint = Offset(720, 300);

  testWidgets('贴底时新增消息保持贴底，回底按钮隐藏', (WidgetTester tester) async {
    final GlobalKey<_HarnessState> key = await pumpList(tester);
    expect(offsetOf(tester), 0);

    key.currentState!.addMessage();
    await tester.pumpAndSettle();

    expect(offsetOf(tester), lessThanOrEqualTo(1));
    expect(buttonOpacity(tester), 0);
  });

  testWidgets('用户上滚脱离后，内容更新不把视口拽回底部（核心回归）',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> key = await pumpList(tester);

    // 向上翻历史（反转列表：向下拖动 = 看更旧内容）
    await tester.dragFrom(blankPoint, const Offset(0, 260));
    await tester.pumpAndSettle();
    final double off1 = offsetOf(tester);
    expect(off1, greaterThan(150));
    expect(buttonOpacity(tester), 1); // 脱离态：按钮出现

    // 记录一条可见锚点消息的 y 坐标（用于验证视口锁定）
    String? anchor;
    double? anchorDy;
    for (int i = 39; i >= 0; i--) {
      final Finder f = find.text('消息内容 $i');
      if (f.evaluate().isEmpty) continue;
      final double dy = tester.getTopLeft(f.first).dy;
      if (dy > 60 && dy < 520) {
        anchor = '消息内容 $i';
        anchorDy = dy;
        break;
      }
    }
    expect(anchor, isNotNull);

    // 多次内容更新（新消息 / 流式增量触发的 revision 变化）
    key.currentState!.addMessage();
    key.currentState!.touch();
    await tester.pumpAndSettle();

    final double off2 = offsetOf(tester);
    expect(off2, greaterThan(100)); // 未被拽回底部
    expect(off2, greaterThanOrEqualTo(off1 - 1)); // 不回退

    final double dy2 = tester.getTopLeft(find.text(anchor!).first).dy;
    expect((dy2 - anchorDy!).abs(), lessThan(4)); // 视口锁定：锚点消息不动
  });

  testWidgets('点击「回到底部」按钮：平滑回底并恢复跟随', (WidgetTester tester) async {
    await pumpList(tester);
    await tester.dragFrom(blankPoint, const Offset(0, 260));
    await tester.pumpAndSettle();
    expect(buttonOpacity(tester), 1);

    await tester.tap(find.byIcon(Icons.arrow_downward));
    await tester.pumpAndSettle();

    expect(offsetOf(tester), lessThanOrEqualTo(1));
    expect(buttonOpacity(tester), 0);
  });

  testWidgets('回底动画被拖拽打断后不再拽回底部', (WidgetTester tester) async {
    await pumpList(tester);
    await tester.dragFrom(blankPoint, const Offset(0, 260));
    await tester.pumpAndSettle();

    // 点击回底 → 动画启动（260 → 0，200ms）
    await tester.tap(find.byIcon(Icons.arrow_downward));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    // 用户改主意：继续向上翻历史（打断动画）
    await tester.dragFrom(blankPoint, const Offset(0, 220));
    await tester.pumpAndSettle();

    // 关键回归：不得被无条件 jumpTo(0) 拽回底部
    expect(offsetOf(tester), greaterThan(80));
  });

  testWidgets('滚回底部附近自动恢复跟随', (WidgetTester tester) async {
    final GlobalKey<_HarnessState> key = await pumpList(tester);
    await tester.dragFrom(blankPoint, const Offset(0, 260));
    await tester.pumpAndSettle();
    expect(buttonOpacity(tester), 1);

    // 反向拖回底部
    await tester.dragFrom(blankPoint, const Offset(0, -320));
    await tester.pumpAndSettle();
    expect(offsetOf(tester), lessThanOrEqualTo(1));
    expect(buttonOpacity(tester), 0); // 已恢复跟随

    key.currentState!.addMessage();
    await tester.pumpAndSettle();
    expect(offsetOf(tester), lessThanOrEqualTo(1)); // 继续跟随
  });

  testWidgets('历史整批重载：直达底部并恢复跟随', (WidgetTester tester) async {
    final GlobalKey<_HarnessState> key = await pumpList(tester);
    await tester.dragFrom(blankPoint, const Offset(0, 260));
    await tester.pumpAndSettle();
    expect(buttonOpacity(tester), 1);

    key.currentState!.reload();
    await tester.pumpAndSettle();

    expect(offsetOf(tester), 0);
    expect(buttonOpacity(tester), 0);
  });

  testWidgets('定位到历史消息后进入脱离态', (WidgetTester tester) async {
    final GlobalKey<_HarnessState> key = await pumpList(tester);

    key.currentState!.locate('m5');
    await tester.pumpAndSettle();

    expect(offsetOf(tester), greaterThan(100)); // 已离开底部
    expect(buttonOpacity(tester), 1); // 进入脱离态
    expect(find.text('消息内容 5'), findsWidgets); // 目标消息已构建
  });
}

/// 测试用宿主：持有消息列表并驱动 MessageList 的 revision/bottomJump 更新
class _Harness extends StatefulWidget {
  const _Harness({super.key});

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final List<ChatMessage> _messages = <ChatMessage>[
    for (int i = 0; i < 40; i++)
      ChatMessage(
        id: 'm$i',
        role: 'agent',
        content: '消息内容 $i',
        timestamp: DateTime(2026, 1, 1, 12, i % 60),
      ),
  ];
  int _revision = 0;
  bool _bottomJump = false;
  String? _locateId;
  int _locateRevision = 0;
  int _live = 0;

  /// 模拟新增消息（流式 msg_start / 新消息到达）
  void addMessage() {
    final int n = _live++;
    setState(() {
      _messages.add(ChatMessage(
        id: 'live$n',
        role: 'agent',
        content: '新消息 $n',
        timestamp: DateTime(2026, 1, 1, 13, 0),
      ));
      _revision++;
      _bottomJump = false;
    });
  }

  /// 模拟 revision 变化但无新消息（如 msg_end / tool 卡片更新）
  void touch() {
    setState(() {
      _revision++;
      _bottomJump = false;
    });
  }

  /// 模拟历史整批重载（切会话 / 切 agent）
  void reload() {
    setState(() {
      _revision++;
      _bottomJump = true;
    });
  }

  /// 模拟定位跳转到指定消息
  void locate(String id) {
    setState(() {
      _locateId = id;
      _locateRevision++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: MessageList(
          messages: _messages,
          revision: _revision,
          scrollToMessageId: _locateId,
          scrollToRevision: _locateRevision,
          bottomJump: _bottomJump,
        ),
      ),
    );
  }
}
