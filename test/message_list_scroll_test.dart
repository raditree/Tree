import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/widgets/message_list.dart';

/// MessageList 跟随/阅读模式行为测试
///
/// 列表为常规（非反转）布局：offset 0 = 顶部（最旧），maxScrollExtent = 底部。
/// 两种模式（由「与底部距离」判定）：
/// - 跟随模式：与底部距离 ≤1px，内容变化时本帧同步钉底；
/// - 阅读模式：一旦离开底部即进入，视口锁定、不做任何补偿（零漂移）。
///
/// 覆盖：
/// - 贴底时新增消息保持贴底、回底按钮隐藏；
/// - 用户上滚进入阅读后，内容更新既不移动已渲染内容、也不改变 offset（核心回归）；
/// - 只有**完全**回到底部才恢复跟随；
/// - 「回到底部」按钮：显隐 / 点击回底 / 回底动画被拖拽打断后不拽回；
/// - 历史整批重载直达底部并恢复跟随；
/// - 定位跳转进入阅读模式。
void main() {
  // 取第一个 Scrollable（即外层 ListView 的），消息气泡内 EditableText 亦含 Scrollable
  ScrollPosition positionOf(WidgetTester tester) => tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position;

  double offsetOf(WidgetTester tester) => positionOf(tester).pixels;

  /// 与底部的距离（0 = 完全压到底部）
  double distanceFromBottom(WidgetTester tester) {
    final ScrollPosition p = positionOf(tester);
    return p.maxScrollExtent - p.pixels;
  }

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
    expect(distanceFromBottom(tester), lessThanOrEqualTo(1));

    key.currentState!.addMessage();
    await tester.pumpAndSettle();

    expect(distanceFromBottom(tester), lessThanOrEqualTo(1));
    expect(buttonOpacity(tester), 0);
  });

  testWidgets('上滚进入阅读后：内容更新不移动视口、offset 零漂移（核心回归）',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> key = await pumpList(tester);

    // 向下拖动 = 看更旧内容 → 进入阅读模式
    await tester.dragFrom(blankPoint, const Offset(0, 260));
    await tester.pumpAndSettle();
    final double off1 = offsetOf(tester);
    expect(distanceFromBottom(tester), greaterThan(150));
    expect(buttonOpacity(tester), 1); // 阅读模式：按钮出现

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

    // 关键回归：offset 完全不变（零漂移），且未被拽回底部
    expect((offsetOf(tester) - off1).abs(), lessThan(0.5),
        reason: '阅读模式下属视口锁定，offset 不应发生任何漂移');
    expect(distanceFromBottom(tester), greaterThan(100));

    final double dy2 = tester.getTopLeft(find.text(anchor!).first).dy;
    expect((dy2 - anchorDy!).abs(), lessThan(1));
  });

  testWidgets('鼠标滚轮上滚进入阅读后：新消息推送不把视口拽回底部（滚轮场景）',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> key = await pumpList(tester);

    // 桌面端典型操作：鼠标滚轮 / 拖动滚动条。以 position.jumpTo 模拟该形态
    final ScrollPosition pos = positionOf(tester);
    pos.jumpTo(pos.maxScrollExtent - 400);
    await tester.pumpAndSettle();

    expect(distanceFromBottom(tester), greaterThan(1));
    expect(buttonOpacity(tester), 1);

    final double off1 = offsetOf(tester);
    key.currentState!.addMessage();
    await tester.pumpAndSettle();

    expect((offsetOf(tester) - off1).abs(), lessThan(0.5));
    expect(buttonOpacity(tester), 1);
  });

  testWidgets('只有完全压到底部才恢复跟随（差一点仍是阅读模式）',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> key = await pumpList(tester);

    final ScrollPosition pos = positionOf(tester);
    pos.jumpTo(pos.maxScrollExtent - 400);
    await tester.pumpAndSettle();
    expect(buttonOpacity(tester), 1);

    // 距底部 8px：未完全贴底 → 仍是阅读模式
    pos.jumpTo(pos.maxScrollExtent - 8);
    await tester.pumpAndSettle();
    expect(buttonOpacity(tester), 1);

    // 完全贴底 → 恢复跟随
    pos.jumpTo(pos.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(buttonOpacity(tester), 0);

    key.currentState!.addMessage();
    await tester.pumpAndSettle();
    expect(distanceFromBottom(tester), lessThanOrEqualTo(1)); // 继续跟随
  });

  testWidgets('回底动画被拖拽打断后：后续滚动与恢复功能仍正常',
      (WidgetTester tester) async {
    final GlobalKey<_HarnessState> key = await pumpList(tester);

    // 进入阅读，再点回底启动动画后用拖拽打断
    await tester.dragFrom(blankPoint, const Offset(0, 260));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_downward));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.dragFrom(blankPoint, const Offset(0, 220));
    await tester.pumpAndSettle();
    expect(distanceFromBottom(tester), greaterThan(80));

    // 完全滚回底部 → 恢复跟随
    final ScrollPosition pos = positionOf(tester);
    pos.jumpTo(pos.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(buttonOpacity(tester), 0);

    key.currentState!.addMessage();
    await tester.pumpAndSettle();
    expect(distanceFromBottom(tester), lessThanOrEqualTo(1));
  });

  testWidgets('回底动画进行中组件被移除：dispose 安全（无未处理异常）',
      (WidgetTester tester) async {
    await pumpList(tester);

    // 制造真实动画：进入阅读 → 点击回底（动画进行中）
    await tester.dragFrom(blankPoint, const Offset(0, 260));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_downward));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40)); // 动画进行中

    // 动画未完成即移除组件：future 在 dispose 后完成，回调不得抛异常
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('点击「回到底部」按钮：平滑回底并恢复跟随', (WidgetTester tester) async {
    await pumpList(tester);
    await tester.dragFrom(blankPoint, const Offset(0, 260));
    await tester.pumpAndSettle();
    expect(buttonOpacity(tester), 1);

    await tester.tap(find.byIcon(Icons.arrow_downward));
    await tester.pumpAndSettle();

    expect(distanceFromBottom(tester), lessThanOrEqualTo(1));
    expect(buttonOpacity(tester), 0);
  });

  testWidgets('回底动画被拖拽打断后不再拽回底部', (WidgetTester tester) async {
    await pumpList(tester);
    await tester.dragFrom(blankPoint, const Offset(0, 260));
    await tester.pumpAndSettle();

    // 点击回底 → 动画启动
    await tester.tap(find.byIcon(Icons.arrow_downward));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    // 用户改主意：继续向上翻历史（打断动画）
    await tester.dragFrom(blankPoint, const Offset(0, 220));
    await tester.pumpAndSettle();

    // 关键回归：不得被无条件拉回底部
    expect(distanceFromBottom(tester), greaterThan(80));
  });

  testWidgets('拖拽回到底部：自动恢复跟随', (WidgetTester tester) async {
    final GlobalKey<_HarnessState> key = await pumpList(tester);
    await tester.dragFrom(blankPoint, const Offset(0, 260));
    await tester.pumpAndSettle();
    expect(buttonOpacity(tester), 1);

    // 反向拖回底部
    await tester.dragFrom(blankPoint, const Offset(0, -320));
    await tester.pumpAndSettle();
    expect(distanceFromBottom(tester), lessThanOrEqualTo(1));
    expect(buttonOpacity(tester), 0); // 已恢复跟随

    key.currentState!.addMessage();
    await tester.pumpAndSettle();
    expect(distanceFromBottom(tester), lessThanOrEqualTo(1)); // 继续跟随
  });

  testWidgets('历史整批重载：直达底部并恢复跟随', (WidgetTester tester) async {
    final GlobalKey<_HarnessState> key = await pumpList(tester);
    await tester.dragFrom(blankPoint, const Offset(0, 260));
    await tester.pumpAndSettle();
    expect(buttonOpacity(tester), 1);

    key.currentState!.reload();
    await tester.pumpAndSettle();

    expect(distanceFromBottom(tester), lessThanOrEqualTo(1));
    expect(buttonOpacity(tester), 0);
  });

  testWidgets('定位到历史消息后进入阅读模式', (WidgetTester tester) async {
    final GlobalKey<_HarnessState> key = await pumpList(tester);

    key.currentState!.locate('m5');
    await tester.pumpAndSettle();

    expect(distanceFromBottom(tester), greaterThan(100)); // 已离开底部
    expect(buttonOpacity(tester), 1); // 进入阅读模式
    expect(find.text('消息内容 5'), findsWidgets); // 目标消息已构建
  });

  group('懒加载分页（长会话只加载末尾一段）', () {
    testWidgets('还有更早的一页：顶部给入口，点它就往回翻', (WidgetTester tester) async {
      final GlobalKey<_HarnessState> key = await pumpList(tester);
      expect(find.text('加载更早的消息'), findsNothing, reason: '默认没有更早的');

      // 先滚到顶（此时还没有更早的一页 ⇒ 不会触发自动翻页），再打开分页：
      // 贴底时列表顶部不在视口内（懒构建不会建它），入口必须滚到顶才看得见
      final ScrollPosition pos = positionOf(tester);
      pos.jumpTo(pos.minScrollExtent);
      await tester.pumpAndSettle();

      key.currentState!.setPaging(hasEarlier: true);
      await tester.pumpAndSettle();
      expect(find.text('加载更早的消息'), findsOneWidget);

      await tester.tap(find.text('加载更早的消息'));
      await tester.pumpAndSettle();
      expect(key.currentState!.loadEarlierCalls, 1, reason: '点入口要真的去翻页');
    });

    testWidgets('正在加载：入口禁用并显示进度', (WidgetTester tester) async {
      final GlobalKey<_HarnessState> key = await pumpList(tester);
      final ScrollPosition pos = positionOf(tester);
      pos.jumpTo(pos.minScrollExtent);
      await tester.pumpAndSettle();
      key.currentState!.setPaging(hasEarlier: true, loadingEarlier: true);
      // 入口里的进度圈是**无限动画**：pumpAndSettle 会一直等下去，这里按帧泵
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('正在加载更早的消息…'), findsOneWidget);
      await tester.tap(find.text('正在加载更早的消息…'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      expect(key.currentState!.loadEarlierCalls, 0, reason: '加载中不许重复触发');
    });

    testWidgets('前插补偿：往前面插内容后，原本看的那一段不会被推走', (WidgetTester tester) async {
      final GlobalKey<_HarnessState> key = await pumpList(tester);
      final ScrollPosition pos = positionOf(tester);
      pos.jumpTo(pos.maxScrollExtent / 2);
      await tester.pumpAndSettle();
      final double before = pos.pixels;
      final double beforeMax = pos.maxScrollExtent;

      key.currentState!.prepend(5);
      await tester.pumpAndSettle();

      final double delta = pos.maxScrollExtent - beforeMax;
      expect(delta, greaterThan(0), reason: '前面插了内容，总高度必须变大');
      expect(
        pos.pixels - before,
        closeTo(delta, 1),
        reason: 'offset 要跟着长高的那一段走，视口才钉在同一段内容上',
      );
    });

    testWidgets('滚到顶：自动往回翻一页', (WidgetTester tester) async {
      final GlobalKey<_HarnessState> key = await pumpList(tester);
      key.currentState!.setPaging(hasEarlier: true);
      await tester.pumpAndSettle();

      final ScrollPosition pos = positionOf(tester);
      pos.jumpTo(pos.minScrollExtent);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(key.currentState!.loadEarlierCalls, greaterThanOrEqualTo(1));
    });

    testWidgets('长列表 + 无动画直达底部：真的贴到最底（不是估算位置）', (WidgetTester tester) async {
      await tester.pumpWidget(const _LongHarness());
      await tester.pumpAndSettle();
      // "连续贴底"是靠逐帧复查收敛的：多泵几帧把懒构建补齐的高度贴完
      for (int i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final ScrollPosition pos = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      expect(
        pos.maxScrollExtent - pos.pixels,
        lessThanOrEqualTo(1),
        reason: '历史整批重载要直达底部：懒构建列表的 maxScrollExtent 是估算值，'
            '只贴一帧会停在半路',
      );
    });
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

  /// 懒加载分页（用户 2026-10-04）：还有更早的一页 / 正在拉 / 拉过几次
  bool hasEarlier = false;
  bool loadingEarlier = false;
  int loadEarlierCalls = 0;

  /// 打开/关闭分页入口的状态（测试从外面驱动；`setState` 是受保护成员，只能在
  /// State 内部调，所以在宿主里留一个方法）。
  void setPaging({bool? hasEarlier, bool? loadingEarlier}) {
    setState(() {
      if (hasEarlier != null) this.hasEarlier = hasEarlier;
      if (loadingEarlier != null) this.loadingEarlier = loadingEarlier;
    });
  }

  /// 模拟"往回翻一页"拿到更早的消息：前插进列表
  void prepend(int count) {
    setState(() {
      for (int i = 0; i < count; i++) {
        _messages.insert(
          0,
          ChatMessage(
            id: 'old$i',
            role: 'user',
            content: '更早的消息 $i ' * 3,
            timestamp: DateTime(2026, 1, 1, 11, i % 60),
          ),
        );
      }
      hasEarlier = false;
    });
  }

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
          // 与生产同口径：面板每次 build 都传一份**新的**列表（visibleStreamMessages），
          // 前插补偿靠"新旧两份列表内容不同"来判定
          messages: List<ChatMessage>.of(_messages),
          revision: _revision,
          scrollToMessageId: _locateId,
          scrollToRevision: _locateRevision,
          bottomJump: _bottomJump,
          hasEarlier: hasEarlier,
          loadingEarlier: loadingEarlier,
          // 只记账，不真的前插：不然"点了就翻页"的用例还没断言，入口就自己消失了
          onLoadEarlier: () => loadEarlierCalls++,
        ),
      ),
    );
  }
}

/// 长会话（几百条、长短不一）整批重载：验证"直达底部"真的到最底。
class _LongHarness extends StatefulWidget {
  const _LongHarness();

  @override
  State<_LongHarness> createState() => _LongHarnessState();
}

class _LongHarnessState extends State<_LongHarness> {
  final List<ChatMessage> _messages = <ChatMessage>[
    for (int i = 0; i < 400; i++)
      ChatMessage(
        id: 'long$i',
        role: i.isEven ? 'agent' : 'user',
        // 长短不一：让懒构建的高度估算与实际不符（真机就是这样）
        content: '消息 $i ' * (i % 40 + 1),
        timestamp: DateTime(2026, 1, 1, 12, i % 60),
      ),
  ];

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: MessageList(messages: _messages, revision: 1, bottomJump: true),
      ),
    );
  }
}
