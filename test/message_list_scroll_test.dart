import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/widgets/message_list.dart';
import 'package:tree/ui/widgets/message_scrollbar.dart';

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

  Future<GlobalKey<_HarnessState>> pumpList(
    WidgetTester tester, {
    VoidCallback? reloadTail,
  }) async {
    final GlobalKey<_HarnessState> k = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: k, reloadTail: reloadTail));
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

  group('窗口化懒加载（滑到哪加载哪、限制缓存长度）', () {
    testWidgets('没加载的那一段画成占位槽，并把视口区间帧后报给面板',
        (WidgetTester tester) async {
      final GlobalKey<_HarnessState> key = await pumpList(tester);
      key.currentState!.trimToTail(10);
      await tester.pumpAndSettle();

      expect(find.text('消息内容 0'), findsNothing,
          reason: '没加载的槽位不画真消息（画的是等高占位槽）');
      // 报上来的是"构建到哪"（含视口上下各一段缓存），贴着末尾那几条
      expect(key.currentState!.windowFirst, greaterThanOrEqualTo(25),
          reason: '帧后要把构建到的下标区间报给面板（补页 / 淘汰都以它为准）');
    });

    testWidgets('滚到顶：把顶部的下标区间报上去（滑到哪加载哪）',
        (WidgetTester tester) async {
      final GlobalKey<_HarnessState> key = await pumpList(tester);
      key.currentState!.trimToTail(10);
      await tester.pumpAndSettle();

      final ScrollPosition pos = positionOf(tester);
      pos.jumpTo(pos.minScrollExtent);
      await tester.pump();
      await tester.pump();

      // 滚到顶 = 把顶部那一段报上去（补页就以它为准）。允许差几条：懒构建列表在
      // 大跨度跳转后，RenderSliverList 会按已建子项的估算位置校正一次 offset
      expect(key.currentState!.windowFirst, lessThan(5),
          reason: '滚到顶却没把顶部区间报上来');
      expect(key.currentState!.windowLast, lessThan(20),
          reason: '报上来的是顶部那一段，不是原来贴底时的 28..39');
    });

    testWidgets('面板在视口上方补页：视口钉在同一段内容上（不会被推走）',
        (WidgetTester tester) async {
      final GlobalKey<_HarnessState> key = await pumpList(tester);
      key.currentState!.trimToTail(10);
      await tester.pumpAndSettle();

      // 停在已加载那一段里：先找一条可见的锚点消息
      final ScrollPosition pos = positionOf(tester);
      pos.jumpTo(pos.maxScrollExtent - 240);
      await tester.pumpAndSettle();
      String? anchor;
      double? anchorDy;
      for (int i = 39; i >= 0; i--) {
        final Finder f = find.text('消息内容 $i');
        if (f.evaluate().isEmpty) continue;
        final double dy = tester.getTopLeft(f.first).dy;
        if (dy > 40 && dy < 500) {
          anchor = '消息内容 $i';
          anchorDy = dy;
          break;
        }
      }
      expect(anchor, isNotNull, reason: '测试前提：视口里有已加载的消息');
      final double before = pos.pixels;

      // 面板在**视口上方**补了几条（占位槽 → 真消息，高度变了）
      key.currentState!.fillAbove(4);
      await tester.pumpAndSettle();

      expect(pos.pixels, greaterThan(before),
          reason: '上方补页长高了，offset 要跟着走才钉得住');
      final double afterDy = tester.getTopLeft(find.text(anchor!).first).dy;
      expect((afterDy - anchorDy!).abs(), lessThan(1.0),
          reason: '视口被推走了：before=$anchorDy after=$afterDy');
    });

    testWidgets('拖右侧滑块：按落点把那一带的下标报上去（滑到哪加载哪）',
        (WidgetTester tester) async {
      final GlobalKey<_HarnessState> key = await pumpList(tester);
      key.currentState!.setTotal(600);
      await tester.pumpAndSettle();

      final Finder bar = find.byType(MessageScrollbar);
      expect(bar, findsOneWidget, reason: '槽位表比视口长得多，就该有滑块');
      final Rect rect = tester.getRect(bar);
      // 往上拖：滑块 → 更早的下标
      await tester.dragFrom(
        rect.center.translate(0, -rect.height * 0.25),
        const Offset(0, -220),
      );
      await tester.pump();
      await tester.pump();

      expect(key.currentState!.windowFirst, lessThan(400),
          reason: '拖到中段就该把中段的下标报上来');
    });

    testWidgets('「回到底部」= 重载末尾一段（不在估算高度里自己滚）',
        (WidgetTester tester) async {
      final GlobalKey<_HarnessState> key = GlobalKey<_HarnessState>();
      int reloads = 0;
      await tester.pumpWidget(_Harness(
        key: key,
        reloadTail: () {
          reloads++;
          key.currentState!.reloadTail();
        },
      ));
      await tester.pumpAndSettle();

      key.currentState!.setTotal(600);
      await tester.pumpAndSettle();
      final ScrollPosition pos = positionOf(tester);
      pos.jumpTo(pos.maxScrollExtent / 2);
      await tester.pumpAndSettle();
      expect(buttonOpacity(tester), 1);

      await tester.tap(find.byIcon(Icons.arrow_downward));
      await tester.pumpAndSettle();

      expect(reloads, 1, reason: '点回底 = 请面板重载末尾一段');
      expect(key.currentState!.total, 40, reason: '重载后窗口就是那一份末尾页');
      expect(buttonOpacity(tester), 0, reason: '重载后回到最新（恢复跟随）');
    });

    testWidgets('长列表 + 无动画直达底部：真的贴到最底（不是估算位置）',
        (WidgetTester tester) async {
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
        reason: '历史整批重载要直达底部：列表的 maxScrollExtent 是估算值，'
            '只贴一帧会停在半路',
      );
    });
  });
}

/// 测试用宿主：持有消息槽位表并驱动 MessageList 的 revision / 窗口回调
class _Harness extends StatefulWidget {
  const _Harness({super.key, this.reloadTail});

  /// 面板的「重载末尾一段」（null = 不接：列表退回旧的平滑回底行为）
  final VoidCallback? reloadTail;

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

  /// 槽位表长度（= 整份会话多少条；> 已加载条数时，其余是**占位槽**）
  int total = 40;

  /// 已加载那一段在全局下标里的起点
  int offset = 0;

  /// 视口上方补过页的次数（列表据此补偿滚动位置）
  int padAboveStamp = 0;

  /// 帧后报上来的视口区间（-1 = 还没报过）
  int windowFirst = -1;
  int windowLast = -1;

  /// 只热末尾 [n] 条：前面全是占位槽（模拟长会话"仅加载末尾一段"）
  void trimToTail(int n) {
    setState(() {
      offset = total - n;
      if (_messages.length > n) {
        _messages.removeRange(0, _messages.length - n);
      }
    });
  }

  /// 造一个长会话：[n] 条，只有末尾那几十条是热的
  void setTotal(int n) {
    setState(() {
      total = n;
      offset = n - _messages.length;
    });
  }

  /// 面板在**视口上方**补页：占位槽换成真消息（高度变了）+ 递增补偿标记
  void fillAbove(int n) {
    setState(() {
      for (int i = 0; i < n; i++) {
        _messages.insert(
          0,
          ChatMessage(
            id: 'fill$i',
            role: 'user',
            content: '补页消息 $i ' * 20,
            timestamp: DateTime(2026, 1, 1, 10, i % 60),
          ),
        );
      }
      offset -= n;
      if (offset < 0) offset = 0;
      padAboveStamp++;
    });
  }

  /// 模拟面板的「重载末尾一段」：窗口换成一份末尾页并直达底部
  void reloadTail() {
    setState(() {
      total = 40;
      offset = 0;
      if (_messages.length > 40) {
        _messages.removeRange(0, _messages.length - 40);
      }
      _revision++;
      _bottomJump = true;
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
      total += 1;
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

  /// 槽位表：长度 [total]，已加载的那一段在 [offset] 起
  List<ChatMessage?> _slots() {
    final List<ChatMessage?> out = List<ChatMessage?>.filled(total, null);
    for (int i = 0; i < _messages.length; i++) {
      final int at = offset + i;
      if (at >= 0 && at < total) out[at] = _messages[i];
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: MessageList(
          // 槽位表：null = 还没加载（占位槽）
          slots: _slots(),
          revision: _revision,
          scrollToMessageId: _locateId,
          scrollToRevision: _locateRevision,
          bottomJump: _bottomJump,
          padAboveStamp: padAboveStamp,
          // 只记账：真面板会按这个区间去核心补页 / 淘汰离得远的槽位
          onWindowChanged: (int first, int last) {
            windowFirst = first;
            windowLast = last;
          },
          onReloadTail: widget.reloadTail,
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
        body: MessageList(slots: _messages, revision: 1, bottomJump: true),
      ),
    );
  }
}
