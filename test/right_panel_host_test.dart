import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree/ui/services/detail_selection.dart';
import 'package:tree/ui/widgets/detail_panel.dart';
import 'package:tree/ui/widgets/right_panel_host.dart';

/// 右栏「窗口宿主」的回归测试（用户 2026-10-18 定稿的窗口化）。
///
/// 钉住这几条不变量：
/// - 右栏**长期存在**：即使一个窗口都没开也还在（空态里能再叫出「+」路由页）；
/// - 默认按 [RightPanelEntry.openByDefault] 打开窗口；
/// - 「+」是**页内路由页**（不是全屏 Navigator 路由）：可用窗口 5 列排布，
///   超过 20 个分页；
/// - 点格子打开并聚焦窗口，chip 可关闭；
/// - 「详情」窗在中栏选中 / 注入详情时**自动打开**（插件卡片点进详情也走这条）；
/// - 已打开的窗口切走后仍常挂（[IndexedStack]），状态不丢。
void main() {
  setUp(() {
    // DetailSelection 是全局单例：用例之间必须清干净，避免串味
    DetailSelection.instance.clear();
  });

  tearDown(() {
    DetailSelection.instance.clear();
  });

  /// 一组窗口：files（默认打开）/ detail（选中自动打开）/ settings + [extra] 个填充窗。
  List<RightPanelEntry> entries({int extra = 0}) => <RightPanelEntry>[
        RightPanelEntry(
          id: 'files',
          label: '文件',
          icon: Icons.folder_outlined,
          openByDefault: true,
          bodyBuilder: (_) => const Center(child: Text('文件身体')),
        ),
        RightPanelEntry(
          id: 'detail',
          label: '详情',
          icon: Icons.article_outlined,
          autoOpenOnSelection: true,
          // 用真实 DetailPanel：它读 DetailSelection，注入的整页直接顶上来
          bodyBuilder: (_) => const DetailPanel(),
        ),
        RightPanelEntry(
          id: 'settings',
          label: '设置',
          icon: Icons.settings_outlined,
          bodyBuilder: (_) => const Center(child: Text('设置身体')),
        ),
        for (int i = 0; i < extra; i++)
          RightPanelEntry(
            id: 'extra$i',
            label: '窗口$i',
            icon: Icons.extension_outlined,
            bodyBuilder: (_) => Center(child: Text('extra$i 身体')),
          ),
      ];

  Widget host(List<RightPanelEntry> list) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            // 够高：5×4 路由页四行都进视口（GridView 懒建，屏外项不会被建出来）
            width: 1000,
            height: 1200,
            child: RightPanelHost(
              entries: list,
              onCollapse: () {},
            ),
          ),
        ),
      );

  Finder pick(String id) =>
      find.byKey(ValueKey<String>('right-panel-pick-$id'));
  Finder chip(String id) =>
      find.byKey(ValueKey<String>('right-panel-chip-$id'));

  /// 挂宿主：视图放到 1000×1200，5×4 路由页四行都进视口
  /// （GridView 懒建，屏外项根本不会被建出来）。
  Future<void> pumpHost(WidgetTester tester, List<RightPanelEntry> list) async {
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(list));
    await tester.pump();
  }

  Future<void> openPicker(WidgetTester tester) async {
    await tester.tap(
      find.byKey(const ValueKey<String>('right-panel-new-window')),
    );
    await tester.pump();
  }

  testWidgets('默认打开 openByDefault 的窗口，顶栏常驻「+」与折叠',
      (WidgetTester tester) async {
    await pumpHost(tester, entries());

    expect(chip('files'), findsOneWidget);
    expect(find.text('文件身体'), findsOneWidget);
    expect(chip('detail'), findsNothing, reason: '详情窗按需打开，不默认开');
    expect(
      find.byKey(const ValueKey<String>('right-panel-new-window')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('right-panel-collapse')),
      findsOneWidget,
    );
  });

  testWidgets('一个窗口都不剩时右栏仍长期存在（空态可再叫出路由页）',
      (WidgetTester tester) async {
    await pumpHost(tester, entries());

    await tester.tap(
      find.byKey(const ValueKey<String>('right-panel-chip-close-files')),
    );
    await tester.pump();

    expect(find.text('文件身体'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('right-panel-empty-new')),
      findsOneWidget,
      reason: '右栏不因没有窗口而消失',
    );
  });

  testWidgets('「+」路由页 5 列排布；超过 20 个分页', (WidgetTester tester) async {
    await pumpHost(tester, entries(extra: 25)); // 共 28 个窗口
    await openPicker(tester);

    final GridView grid = tester.widget<GridView>(
      find.byKey(const ValueKey<String>('right-panel-picker-grid')),
    );
    expect(
      (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
          .crossAxisCount,
      5,
      reason: '5 列',
    );
    expect(find.text('第 1 / 2 页'), findsOneWidget);
    // 第 1 页装前 20 个：files / detail / settings / extra0..extra16
    expect(pick('extra16'), findsOneWidget);
    expect(pick('extra17'), findsNothing);
    expect(pick('files'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('right-panel-page-next')),
    );
    await tester.pump();
    expect(find.text('第 2 / 2 页'), findsOneWidget);
    expect(pick('extra17'), findsOneWidget);
    expect(pick('extra24'), findsOneWidget);
    expect(pick('files'), findsNothing, reason: '第 1 页项不跨页出现');
  });

  testWidgets('点格子打开窗口，chip 可关闭', (WidgetTester tester) async {
    await pumpHost(tester, entries());
    await openPicker(tester);

    expect(find.text('设置身体'), findsNothing);
    await tester.tap(pick('settings'));
    await tester.pump();

    expect(find.text('设置身体'), findsOneWidget);
    expect(chip('settings'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('right-panel-chip-close-settings')),
    );
    await tester.pump();
    expect(find.text('设置身体'), findsNothing);
    expect(chip('settings'), findsNothing);
  });

  testWidgets('注入详情时「详情」窗自动打开并显示注入内容',
      (WidgetTester tester) async {
    await pumpHost(tester, entries());
    expect(chip('detail'), findsNothing);

    // 插件卡片点进详情 = DetailSelection.inject（右栏没有 agent 时也要能看到）
    DetailSelection.instance.inject(const Text('插件详情页'));
    await tester.pump();

    expect(chip('detail'), findsOneWidget);
    expect(find.text('插件详情页'), findsOneWidget);
  });

  testWidgets('已打开的窗口切走后仍常挂（IndexedStack）',
      (WidgetTester tester) async {
    await pumpHost(tester, entries());
    await openPicker(tester);
    await tester.tap(pick('settings'));
    await tester.pump();
    expect(find.text('设置身体'), findsOneWidget);

    // 切回「文件」窗：设置窗身体仍在树上（只是被 IndexedStack 隐藏）
    await tester.tap(chip('files'));
    await tester.pump();
    expect(find.text('文件身体'), findsOneWidget);
    expect(find.text('设置身体', skipOffstage: false), findsOneWidget);
  });

  // ── 用户 2026-10-19 反馈 ──────────────────────────────────────────────

  testWidgets('窗口标签过多时 chip 行常显滑动条，鼠标滚轮也能翻',
      (WidgetTester tester) async {
    // 12 个默认打开的窗口：1000 宽一定装不下
    final List<RightPanelEntry> many = <RightPanelEntry>[
      for (int i = 0; i < 12; i++)
        RightPanelEntry(
          id: 'w$i',
          label: '很长的窗口名$i',
          icon: Icons.circle_outlined,
          openByDefault: true,
          bodyBuilder: (_) => Center(child: Text('w$i 身体')),
        ),
    ];
    await pumpHost(tester, many);

    // 常显滑动条：不然标签被顶住时用户根本不知道还能往右翻
    final Scrollbar bar = tester.widget<Scrollbar>(
      find.byKey(const ValueKey<String>('right-panel-chip-scrollbar')),
    );
    expect(bar.thumbVisibility, isTrue, reason: '标签被挡住时要看得见滑动条');
    expect(bar.scrollbarOrientation, ScrollbarOrientation.bottom);

    final ScrollableState scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const ValueKey<String>('right-panel-chip-scrollbar')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scrollable.position.maxScrollExtent, greaterThan(0),
        reason: '标签确实溢出了，才有得滚');

    // 鼠标滚轮（竖直 scrollDelta）也要能横着翻：桌面端 Scrollable 对水平轴
    // 只认 dx，宿主里补了 dy → 横向这张映射
    final Offset at = tester.getCenter(
      find.byKey(const ValueKey<String>('right-panel-chip-scrollbar')),
    );
    await tester.sendEventToBinding(
      PointerScrollEvent(position: at, scrollDelta: const Offset(0, 200)),
    );
    await tester.pump();
    expect(scrollable.position.pixels, greaterThan(0),
        reason: '滚轮竖直增量被转成了横向滚动');
  });

  testWidgets('窗口 chip 字重跟随界面字重设置（不再写死 w400/w600）',
      (WidgetTester tester) async {
    // 模拟「界面字重」设置把 bodyMedium 抬到 w800
    final ThemeData base = ThemeData();
    final ThemeData theme = base.copyWith(
      textTheme: base.textTheme.copyWith(
        bodyMedium: base.textTheme.bodyMedium!
            .copyWith(fontWeight: FontWeight.w800),
      ),
    );
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: Scaffold(
        body: SizedBox(
          width: 600,
          height: 400,
          child: RightPanelHost(
            entries: <RightPanelEntry>[
              RightPanelEntry(
                id: 'a',
                label: '甲',
                icon: Icons.circle_outlined,
                openByDefault: true,
                bodyBuilder: (_) => const SizedBox.shrink(),
              ),
              RightPanelEntry(
                id: 'b',
                label: '乙',
                icon: Icons.circle_outlined,
                openByDefault: true,
                bodyBuilder: (_) => const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();

    // 未活动的那颗（乙）应**原样跟随**界面字重（w800），而不是被写死的 w400
    final Text label = tester.widget<Text>(
      find.descendant(of: chip('b'), matching: find.text('乙')),
    );
    expect(label.style?.fontWeight, FontWeight.w800,
        reason: '窗口文字粗细必须跟着「界面字重」设置走');
  });
}
