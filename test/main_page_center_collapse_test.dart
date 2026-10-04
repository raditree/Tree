import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree/io/api_service.dart';
import 'package:tree/ui/pages/main_page.dart';
import 'package:tree/ui/widgets/message_panel.dart';

/// 中栏折叠的回归测试。
///
/// 用户 2026-10-04：「中间页支持折叠（右侧面板文件浏览时还是不够用）」。口径：
/// - 中栏折叠成 40px 窄条，**让出的宽度交给展开着的侧栏**——右栏优先（折叠中栏的
///   动机就是右栏读文件要地方），右栏也收着就给左栏，两侧都收着则留空；
/// - 承接侧的分隔条同时收起：那一侧的宽度此刻由窗口决定，拖它不会有任何位移；
/// - 中栏只是被 ClipRect 裁掉 + IgnorePointer，**没有卸载**：展开内容仍按"折叠前
///   的宽度"布局，所以会话、消息滚动位置、输入框草稿都还在。
///
/// 窗口取 2000×1000，常量口径与 main_page_sidebar_width_test.dart 一致：
/// 活动栏 48、分隔条 2×6、左栏 260、右栏 340、中栏下限 360。
void main() {
  const Size desktop = Size(2000, 1000);
  const double rail = 48;
  const double divider = 6;
  const double collapsed = 40;
  const double leftInit = 260;
  const double rightInit = 340;

  /// 初始中栏宽度：2000 - 48 - 6 - 260 - 6 - 340
  const double centerInit = 1340;

  /// 两栏合计预算（全部展开时）：2000 - 60 - 360
  const double sideBudget = 1580;

  Widget host() => const MaterialApp(home: MainPage());

  Future<void> pumpMainPage(WidgetTester tester) async {
    tester.view.physicalSize = desktop;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    ApiService.baseUrl = 'http://127.0.0.1:0';
    await tester.pumpWidget(host());
    await tester.pump();
  }

  Rect paneRect(WidgetTester tester, String which) =>
      tester.getRect(find.byKey(ValueKey<String>('main-$which-sidebar')));

  double paneWidth(WidgetTester tester, String which) =>
      paneRect(tester, which).width;

  /// 折叠中栏（标题栏最右端那颗键）
  Future<void> collapseCenter(WidgetTester tester) async {
    await tester.tap(find.byTooltip('折叠中栏'));
    await tester.pumpAndSettle();
  }

  /// 展开中栏（折叠窄条上的那颗键）
  Future<void> expandCenter(WidgetTester tester) async {
    await tester.tap(find.byTooltip('展开中栏'));
    await tester.pumpAndSettle();
  }

  /// 折叠右栏：未选 Agent 时右栏是占位，点它即可（与真机同一条路）
  Future<void> collapseRight(WidgetTester tester) async {
    await tester.tap(find.text('请先在左侧选择或创建一个 Agent'));
    await tester.pumpAndSettle();
  }

  /// 折叠左栏：点列表下方的空位折叠区
  Future<void> collapseLeft(WidgetTester tester) async {
    await tester.tap(find.text('点击空白处折叠左栏'));
    await tester.pumpAndSettle();
  }

  /// 拖某个分隔条（分步移动，避免一次位移被手势 slop 吃掉）
  Future<void> dragDivider(WidgetTester tester, int index, double dx) async {
    final TestGesture g = await tester.startGesture(
      tester.getCenter(find.byType(DraggableDivider).at(index)),
    );
    await tester.pump(const Duration(milliseconds: 16));
    for (int i = 0; i < 20; i++) {
      await g.moveBy(Offset(dx / 20, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
  }

  testWidgets('① 折叠中栏：只剩 40px 窄条，右栏接手全部宽度顶到窗口最右',
      (WidgetTester tester) async {
    await pumpMainPage(tester);

    // 前置事实（测试自身校验）
    expect(tester.takeException(), isNull);
    expect(paneWidth(tester, 'center'), centerInit);
    expect(paneWidth(tester, 'right'), rightInit);
    expect(find.byTooltip('折叠中栏'), findsOneWidget);

    await collapseCenter(tester);

    expect(tester.takeException(), isNull, reason: '折叠不该产生溢出异常');
    expect(paneWidth(tester, 'center'), collapsed, reason: '中栏收成窄条');
    expect(paneRect(tester, 'center').left, rail + leftInit + divider,
        reason: '窄条留在原位（左栏右边），不是跑到窗口边上');
    expect(paneWidth(tester, 'right'),
        2000 - rail - divider - leftInit - collapsed,
        reason: '右栏承接中栏让出的宽度（分隔条 2 已收起）');
    expect(paneRect(tester, 'right').right, 2000,
        reason: '右栏顶到窗口最右边，中间不留空');
    expect(find.byType(DraggableDivider), findsOneWidget,
        reason: '右栏承接时它的分隔条收起，只剩左栏那颗');
    expect(find.byType(MessagePanel), findsOneWidget,
        reason: '中栏只是被裁剪，没有卸载');
  });

  testWidgets('② 展开内容仍按折叠前的宽度布局（State 与滚动位置的保命机制）',
      (WidgetTester tester) async {
    await pumpMainPage(tester);
    final State before = tester.state(find.byType(MessagePanel));

    await collapseCenter(tester);

    // 关键：MessagePanel 的**渲染宽度**还是折叠前的宽度，只是在 40px 的
    // ClipRect 里被裁掉。若按 40px 重排，消息流的滚动位置会被夹回去。
    expect(tester.getSize(find.byType(MessagePanel)).width,
        closeTo(centerInit + divider, 1),
        reason: '折叠时中栏让出了分隔条 2 的宽度，内容按这个宽度布局');
    expect(identical(tester.state(find.byType(MessagePanel)), before), isTrue,
        reason: 'State 必须还是同一个（会话/草稿/滚动位置都在里面）');

    await expandCenter(tester);
    expect(identical(tester.state(find.byType(MessagePanel)), before), isTrue);
    expect(paneWidth(tester, 'center'), centerInit, reason: '展开后宽度原样回来');
    expect(paneWidth(tester, 'right'), rightInit);
    expect(find.byType(DraggableDivider), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('③ 右栏也收着时，中栏让出的宽度给左栏',
      (WidgetTester tester) async {
    await pumpMainPage(tester);
    await collapseRight(tester);
    expect(paneWidth(tester, 'right'), collapsed);

    await collapseCenter(tester);

    expect(tester.takeException(), isNull);
    expect(paneWidth(tester, 'center'), collapsed);
    expect(paneWidth(tester, 'left'), 2000 - rail - collapsed - collapsed,
        reason: '右栏收着 ⇒ 由左栏承接（两个分隔条都收起）');
    expect(paneRect(tester, 'left').left, rail);
    expect(find.byType(DraggableDivider), findsNothing);

    await expandCenter(tester);
    expect(paneWidth(tester, 'left'), leftInit, reason: '左栏宽度状态没被改掉');
    expect(paneWidth(tester, 'right'), collapsed, reason: '右栏仍是收着的');
  });

  testWidgets('④ 三栏都收着：不溢出，剩下的宽度留空（不留非法布局）',
      (WidgetTester tester) async {
    await pumpMainPage(tester);
    await collapseRight(tester);
    await collapseLeft(tester);
    expect(paneWidth(tester, 'left'), collapsed);

    await collapseCenter(tester);

    expect(tester.takeException(), isNull, reason: '没人承接也不能溢出');
    expect(paneWidth(tester, 'left'), collapsed);
    expect(paneWidth(tester, 'center'), collapsed);
    expect(paneWidth(tester, 'right'), collapsed);
    expect(paneRect(tester, 'left').left, rail,
        reason: '三根窄条依次贴在活动栏右边，不散开');
    expect(paneRect(tester, 'right').right, rail + collapsed * 3,
        reason: '右栏窄条紧跟在中间（右端那块空白由空占位吃掉）');
  });

  testWidgets('⑤ 折叠中栏后侧栏预算变大：左栏能拖到远超"中栏 360"时的上限',
      (WidgetTester tester) async {
    await pumpMainPage(tester);
    await collapseCenter(tester);

    // 全展开时左栏的封顶是 sideBudget - 右栏下限 = 1580 - 240 = 1340；
    // 中栏折叠后它只保底 40 ⇒ 封顶变成 (2000-54-40) - 240 = 1666。
    await dragDivider(tester, 0, 1400);

    expect(paneWidth(tester, 'left'), greaterThan(sideBudget - 240),
        reason: '超出全展开时的封顶，说明中栏确实只保底窄条宽');
    expect(tester.takeException(), isNull);
    expect(paneWidth(tester, 'right'), greaterThanOrEqualTo(240),
        reason: '右栏仍被保到自己的下限之上');

    // 展开中栏：两侧按预算收敛，中栏拿回 360 且不溢出
    await expandCenter(tester);
    expect(tester.takeException(), isNull);
    expect(paneWidth(tester, 'center'), greaterThanOrEqualTo(360 - 1));
    expect(paneWidth(tester, 'left') + paneWidth(tester, 'right'),
        lessThanOrEqualTo(sideBudget + 1));
  });

  testWidgets('⑥ 承接侧的分隔条收起：拖左栏不会偷偷改掉右栏宽度',
      (WidgetTester tester) async {
    await pumpMainPage(tester);
    await collapseCenter(tester);
    expect(find.byType(DraggableDivider), findsOneWidget);

    // 中栏折叠、右栏承接时拖左栏：右栏此刻的宽度由窗口决定，
    // 它的"宽度状态"不该被这次拖拽改掉——否则展开中栏后右栏会莫名变窄。
    await dragDivider(tester, 0, 200);
    await expandCenter(tester);

    expect(paneWidth(tester, 'right'), rightInit,
        reason: '右栏宽度状态原样保留');
    expect(tester.takeException(), isNull);
  });

  testWidgets('⑦ 单独使用 MessagePanel（无宿主）时没有折叠键：布局一字不变',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: MessagePanel())),
    );
    await tester.pump();

    expect(find.byTooltip('折叠中栏'), findsNothing,
        reason: '折叠键由宿主（三栏布局）注入，独立使用时不出现');
    expect(tester.takeException(), isNull);
  });
}
