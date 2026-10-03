import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree/io/api_service.dart';
import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/pages/main_page.dart';
import 'package:tree/ui/widgets/message_list.dart';
import 'package:tree/ui/widgets/message_panel.dart';

/// 三栏布局的侧栏宽度回归测试。
///
/// 背景：左右栏原先各有一个**写死的像素上限**（左 400 / 右 500），拖拽被卡住，
/// 阅读文件（长行 / 宽表格 / 宽 PDF）时右侧根本展不开。现在：
/// - 两侧都只有下限（左 200 / 右 240）；上限只由"中栏最小 360 + 对侧下限"决定；
/// - 两栏**合计**只能用 `中栏可用宽度 - 360`：拖一侧时中栏先被吃（还有富余就
///   只吃富余），中栏到 360 后从对侧借空间（对侧主动缩到自己的下限为止）。
///
/// 测试窗口取 2000×1000：布局可用宽度恰好 2000，于是
/// 中栏可用宽度 = 2000 - 48(活动栏) - 12(两个分隔条) = 1940、
/// 两栏合计预算 = 1940 - 360 = 1580，断言可以取精确值。
///
/// 注意：一次手势位移会被手势 slop 吃掉约 20px，且指针不能拖出窗口（会被截断），
/// 所以这里用"分步移动"并选择不会撞到窗口边缘的位移量。
void main() {
  const Size desktop = Size(2000, 1000);

  /// 与 `_MainPageState` 同口径的常量
  const double centerMin = 360;
  const double leftMin = 200;
  const double rightMin = 240;

  /// 中栏可用宽度（活动栏 48 + 两个分隔条 2×6 = 60）
  const double room = 2000 - 60;

  /// 两栏合计预算
  const double sideBudget = room - centerMin;

  const double slack = 20;

  Widget host() => const MaterialApp(home: MainPage());

  double sidebarWidth(WidgetTester tester, String which) =>
      tester.getSize(find.byKey(ValueKey<String>('main-$which-sidebar'))).width;

  double leftWidth(WidgetTester tester) => sidebarWidth(tester, 'left');
  double rightWidth(WidgetTester tester) => sidebarWidth(tester, 'right');

  double centerWidth(WidgetTester tester) =>
      tester.getSize(find.byType(MessagePanel)).width;

  Finder divider(int index) => find.byType(DraggableDivider).at(index);

  /// 拖某个分隔条：`dx` 为总位移，分步移动并每步泵一帧（比 `timedDrag`
  /// 更可控，累计位移不受手势 slop 的批次影响）
  Future<void> dragDivider(
    WidgetTester tester,
    int index,
    double dx, {
    int steps = 20,
  }) async {
    final TestGesture g =
        await tester.startGesture(tester.getCenter(divider(index)));
    await tester.pump(const Duration(milliseconds: 16));
    for (int i = 0; i < steps; i++) {
      await g.moveBy(Offset(dx / steps, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
  }

  setUp(() {
    ApiService.baseUrl = 'http://127.0.0.1:0';
  });

  Future<void> pumpMainPage(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    await tester.pump();
  }

  testWidgets('初始布局与常量口径一致（测试自身的前置校验）',
      (WidgetTester tester) async {
    await pumpMainPage(tester, desktop);

    expect(tester.takeException(), isNull);
    expect(leftWidth(tester), 260);
    expect(rightWidth(tester), 340);
    expect(centerWidth(tester), sideBudget - 260 - 340 + centerMin);
    expect(find.text('请先在左侧选择或创建一个 Agent'), findsOneWidget,
        reason: '右栏面板已挂载');
  });

  testWidgets('右栏可拖到超过原 500px 硬上限（文件阅读需要更宽）',
      (WidgetTester tester) async {
    await pumpMainPage(tester, desktop);

    // 右栏分隔条＝两个分隔条里的第二个；向左拖 = 右栏变宽。
    // 拖 1200：右栏想吃 340+1200=1540，被"合计预算 1580 - 左栏下限 200"封在 1380
    expect(find.byType(DraggableDivider), findsNWidgets(2));
    await dragDivider(tester, 1, -1200);

    expect(rightWidth(tester), greaterThan(500), reason: '旧实现被卡在 500');
    expect(rightWidth(tester), closeTo(sideBudget - leftMin, 1));
    expect(leftWidth(tester), leftMin, reason: '左栏被让到下限');
    expect(centerWidth(tester), closeTo(centerMin, 1));
    expect(tester.takeException(), isNull, reason: '不应有溢出异常');
  });

  testWidgets('左栏可拖到超过原 400px 硬上限', (WidgetTester tester) async {
    await pumpMainPage(tester, desktop);

    expect(leftWidth(tester), 260, reason: '初始宽度 260');
    // 拖 600：左栏 260+600=860（旧实现 400 就封顶），中栏还有富余，右栏不动
    await dragDivider(tester, 0, 600);

    expect(leftWidth(tester), greaterThan(400), reason: '旧实现被卡在 400');
    expect(leftWidth(tester), closeTo(260 + 600 - slack, 20));
    expect(rightWidth(tester), 340, reason: '两栏合计仍在上限内，右栏不动');
    expect(centerWidth(tester), closeTo(room - leftWidth(tester) - 340, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('中栏还有富余时不动对侧；富余吃完后对侧主动缩',
      (WidgetTester tester) async {
    await pumpMainPage(tester, desktop);

    // 拖 300：左栏 260+300=560 仍在"合计预算 1580"内 → 只吃中栏，右栏不动
    await dragDivider(tester, 0, 300);
    expect(leftWidth(tester), closeTo(260 + 300 - slack, 20));
    expect(rightWidth(tester), 340, reason: '中栏消化得了，不该动右栏');
    expect(centerWidth(tester),
        closeTo(room - leftWidth(tester) - 340, 1));
    expect(centerWidth(tester), greaterThan(centerMin));

    // 再拖 1200：左栏会被封在"合计预算 - 右栏下限"=1340，右栏被让到下限
    await dragDivider(tester, 0, 1200);
    expect(leftWidth(tester), closeTo(sideBudget - rightMin, 1));
    expect(rightWidth(tester), rightMin, reason: '右栏主动缩到自己的下限');
    expect(centerWidth(tester), closeTo(centerMin, 1), reason: '中栏保持底线');
    expect(leftWidth(tester), greaterThan(640), reason: '远超旧上限 400');
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖右栏变宽时左栏主动缩小（对侧让位）',
      (WidgetTester tester) async {
    await pumpMainPage(tester, desktop);

    // 右栏拖 600：右栏 340+600=940 仍在合计预算内 → 只吃中栏，左栏不动
    await dragDivider(tester, 1, -600);
    expect(rightWidth(tester), closeTo(340 + 600 - slack, 20));
    expect(leftWidth(tester), 260, reason: '中栏消化得了，不该动左栏');

    // 再拖 1200：右栏封顶 1380，左栏被让到下限 200
    await dragDivider(tester, 1, -1200);
    expect(rightWidth(tester), closeTo(sideBudget - leftMin, 1));
    expect(leftWidth(tester), leftMin, reason: '左栏主动缩到自己的下限');
    expect(centerWidth(tester), closeTo(centerMin, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('拖到极限中栏也不会被压破（两栏合计受约束）',
      (WidgetTester tester) async {
    await pumpMainPage(tester, desktop);

    await dragDivider(tester, 1, -1200); // 右栏封顶
    await dragDivider(tester, 0, 1200); // 再拖左栏

    expect(tester.takeException(), isNull, reason: '不能出现 RenderFlex overflow');
    expect(centerWidth(tester), greaterThanOrEqualTo(centerMin - 1));
    expect(leftWidth(tester) + rightWidth(tester),
        lessThanOrEqualTo(sideBudget + 1));
  });

  testWidgets('窗口缩小后按新预算收敛，且中栏不被压破',
      (WidgetTester tester) async {
    await pumpMainPage(tester, desktop);

    // 先把右栏拖到很宽（左栏在下限），再缩小窗口
    await dragDivider(tester, 1, -1200);
    expect(tester.takeException(), isNull);

    // 收敛走"帧后回调"（与真机同一路径），但**渲染宽度必须当帧生效**：
    // 侧栏宽度不做补间，否则缩回过程会持续若干帧、把中栏挤到 0
    // （旧实现用 AnimatedContainer 补间，正是这样溢出的）。
    tester.view.physicalSize = const Size(1200, 900);
    await tester.pump();
    expect(tester.takeException(), isNull, reason: '缩小窗口的那一帧不应溢出');
    expect(centerWidth(tester), greaterThanOrEqualTo(centerMin - 1),
        reason: '当帧就要落进新预算');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(centerWidth(tester), greaterThanOrEqualTo(centerMin - 1));
    expect(leftWidth(tester) + rightWidth(tester),
        lessThanOrEqualTo(1200 - 60 - centerMin + 1));
  });

  testWidgets('下限仍然生效：向反方向拖到底不小于各自最小宽度',
      (WidgetTester tester) async {
    await pumpMainPage(tester, desktop);

    // 左栏向左拖（越过下限）、右栏向右拖（越过下限）
    await dragDivider(tester, 0, -400);
    await dragDivider(tester, 1, 400);

    expect(leftWidth(tester), leftMin, reason: '左栏下限 200');
    expect(rightWidth(tester), rightMin, reason: '右栏下限 240');
    expect(tester.takeException(), isNull);
  });

  testWidgets('中栏被拖窄时，消息气泡跟着可用宽度走（不再只剩 70%）',
      (WidgetTester tester) async {
    // 中栏的最小宽度是 360：旧实现气泡被压到 360×70% ≈ 252，右侧空一大片
    const double narrow = centerMin;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: narrow,
          height: 600,
          child: MessageList(
            slots: <ChatMessage>[
              ChatMessage(
                id: 'm1',
                role: 'user',
                content: '这是一条足够长的用户消息，用来确认气泡宽度会跟着中栏一起变宽，'
                    '而不是被固定比例压到右边空出一大片。',
                timestamp: DateTime(2026, 1, 1, 12),
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    // 消息列表左右各留 16px 内边距，气泡再取可用宽度的 93%
    // 用气泡里的正文宽度间接量：气泡宽 = 正文宽 + 左右各 12px 内边距。
    // 73% 上限时正文只有 ~224px，93% 时 ~304px，250 这条线能明确区分。
    final double textWidth =
        tester.getSize(find.byType(SelectableText)).width;
    final double bubbleWidth = textWidth + 24; // Container 的左右 padding
    expect(textWidth, greaterThan(250), reason: '旧实现只有 70%%，正文会被压到 ~224');
    expect(bubbleWidth, closeTo(narrow - 32, 60),
        reason: '气泡应基本铺满可用宽度（只留 7%）');
  });
}
