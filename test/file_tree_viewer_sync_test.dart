import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tree/io/api_service.dart';
import 'package:tree/ui/services/editor_settings.dart';
import 'package:tree/ui/widgets/file_panel.dart';
import 'package:tree/ui/widgets/file_tree.dart';
import 'package:tree/ui/widgets/file_viewer.dart';
import 'package:tree/ui/widgets/split_panes.dart';

import 'fake_tree_core.dart';

/// 放行挂在控件上的真实 IO（与 test/file_editor_test.dart 同一套）
Future<void> settleIo(WidgetTester tester, {int rounds = 14}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump();
  }
}

/// 等到条件成立（真实事件循环 + pump）：比"数固定帧数"稳，重负载下也不飘。
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() ready, {
  int rounds = 60,
}) async {
  for (int i = 0; i < rounds; i++) {
    if (ready()) {
      await tester.pump();
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump();
  }
}

/// 端到端接线：**树与查看器同屏**（文件面板 2026-10-03 从覆盖层改成上下分栏）。
///
/// 这里全部是**真点击**：打开文件 → 树还在（上半格）→ 在树里右键改名 / 删除它 →
/// 查看器跟着走。覆盖层时代这三条只能靠直接调回调，同屏之后必须能点得到。
void main() {
  late FakeTreeCore core;

  setUpAll(() {
    HttpOverrides.global = null;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await EditorSettings.instance.setSaveOnBlur(true);
    await EditorSettings.instance.setHighlight(true);
    core = await FakeTreeCore.start();
    ApiService.baseUrl = core.baseUrl;
    ApiService.setToken('test-token');
    core.dirs[''] = <Map<String, dynamic>>[
      FakeTreeCore.dir('src', 'src'),
      FakeTreeCore.file('a.txt', 'a.txt', size: 5),
      FakeTreeCore.file('b.md', 'b.md', size: 5),
    ];
    core.dirs['src'] = <Map<String, dynamic>>[
      FakeTreeCore.file('src/inner.txt', 'inner.txt', size: 5),
    ];
    core.content = 'hello';
    core.contentSize = 5;
  });

  tearDown(() async {
    await core.close();
  });

  Future<void> pumpPanel(
    WidgetTester tester, {
    double width = 760,
    double height = 600,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: width,
            height: height,
            child: FilePanel(workspaceId: 'ws1', teamId: 'ws1'),
          ),
        ),
      ),
    );
    await settleIo(tester);
  }

  List<String> panePaths(WidgetTester tester) => tester
      .widgetList<FileViewer>(find.byType(FileViewer))
      .map((FileViewer viewer) => viewer.filePath)
      .toList();

  Future<void> openFile(WidgetTester tester, String path) async {
    await tester.tap(find.byKey(FileTree.rowKey(path)));
    await settleIo(tester);
  }

  Future<void> openTreeMenu(WidgetTester tester, String path) async {
    await tester.tap(
      find.byKey(FileTree.rowKey(path)),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('没打开文件时树独占；打开文件出现同屏分栏；关掉查看器回到树独占', (
    WidgetTester tester,
  ) async {
    await pumpPanel(tester);
    expect(find.byType(SplitPanes), findsNothing, reason: '没打开文件：树独占，不留空分栏');

    await openFile(tester, 'a.txt');
    expect(find.byType(SplitPanes), findsOneWidget, reason: '打开文件 ⇒ 上下同屏分栏');
    expect(find.byType(FileTree), findsOneWidget, reason: '查看器打开着，树也必须还在');
    expect(find.byType(FileViewer), findsOneWidget);
    expect(find.text('hello'), findsWidgets, reason: '内容真加载');

    // 分栏方向是上下（树在上、查看器在下）
    final Rect treeRect = tester.getRect(find.byType(FileTree));
    final Rect viewerRect = tester.getRect(find.byType(FileViewer));
    expect(treeRect.bottom, lessThanOrEqualTo(viewerRect.top));
    expect(
      treeRect.height,
      lessThan(viewerRect.height),
      reason: '默认比例 0.4：树那一格比查看器小',
    );

    // 查看器工具条上的「关闭查看器」⇒ 回到树独占
    await tester.tap(find.byTooltip('关闭查看器'));
    await settleIo(tester);
    expect(find.byType(FileViewer), findsNothing);
    expect(find.byType(SplitPanes), findsNothing);
    expect(find.byType(FileTree), findsOneWidget);
  });

  testWidgets('分屏后（查看器内部两格）在树里点另一个文件：落到**活动窗格**', (
    WidgetTester tester,
  ) async {
    await pumpPanel(tester);
    await openFile(tester, 'a.txt');

    await tester.tap(
      find.byTooltip('分屏：同一个文件再开一个窗格（两侧共享同一份缓冲）'),
    );
    await settleIo(tester);
    expect(panePaths(tester), <String>['a.txt', 'a.txt']);

    // 树在上半格且可点：换的是活动窗格（第二个），第一个不动
    await openFile(tester, 'b.md');
    expect(panePaths(tester), <String>['a.txt', 'b.md']);
  });

  testWidgets('打开文件后在树里**重命名**它：窗格路径跟着改并按新路径重拉', (
    WidgetTester tester,
  ) async {
    await pumpPanel(tester);
    await openFile(tester, 'a.txt');
    expect(panePaths(tester), <String>['a.txt']);

    await openTreeMenu(tester, 'a.txt');
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    expect(find.byKey(FileTree.renameFieldKey), findsOneWidget);

    await tester.enterText(find.byKey(FileTree.renameFieldKey), 'renamed.txt');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await pumpUntil(tester, () => panePaths(tester).first == 'renamed.txt');
    await pumpUntil(
      tester,
      () => core.called(
        'GET',
        '/api/files/ws1/content',
        queryContains: 'path=renamed.txt',
      ),
    );

    expect(panePaths(tester), <String>['renamed.txt']);
    expect(find.byType(FileViewer), findsOneWidget);
    expect(
      find.byKey(FileTree.rowKey('renamed.txt')),
      findsOneWidget,
      reason: '树里也换成新名字了',
    );
  });

  testWidgets('打开文件后在树里**删除**它：窗格自动关掉、给提示、回到树独占', (
    WidgetTester tester,
  ) async {
    await pumpPanel(tester);
    await openFile(tester, 'a.txt');
    expect(find.byType(FileViewer), findsOneWidget);

    await openTreeMenu(tester, 'a.txt');
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await pumpUntil(tester, () => find.byType(FileViewer).evaluate().isEmpty);
    await pumpUntil(tester, () => find.byType(SplitPanes).evaluate().isEmpty);

    expect(find.byType(FileViewer), findsNothing);
    expect(find.byType(SplitPanes), findsNothing, reason: '查看器关了 ⇒ 回到树独占');
    expect(find.textContaining('查看器已关闭'), findsOneWidget);
    expect(find.byKey(FileTree.rowKey('a.txt')), findsNothing);
  });

  testWidgets('打开 / 关闭查看器不丢树的展开状态（子树被搬而不是重建）', (
    WidgetTester tester,
  ) async {
    await pumpPanel(tester);
    await tester.tap(find.byKey(FileTree.rowKey('src')));
    await settleIo(tester);
    expect(find.text('inner.txt'), findsOneWidget);

    await openFile(tester, 'src/inner.txt');
    expect(find.byType(SplitPanes), findsOneWidget);
    expect(
      find.text('inner.txt'),
      findsWidgets,
      reason: '开着文件时树还展开着（上半格）',
    );

    await tester.tap(find.byTooltip('关闭查看器'));
    await settleIo(tester);
    expect(find.text('inner.txt'), findsOneWidget, reason: '关掉查看器后展开状态不塌');
  });

  testWidgets('分栏可拖：拖分隔条改变比例，且记在面板状态里', (WidgetTester tester) async {
    await pumpPanel(tester);
    await openFile(tester, 'a.txt');

    final double before = tester.getSize(find.byType(FileTree)).height;
    final double dividerY = tester.getRect(find.byType(FileTree)).bottom + 3;
    await tester.dragFrom(
      Offset(tester.getRect(find.byType(FileTree)).center.dx, dividerY),
      const Offset(0, 60),
    );
    await tester.pumpAndSettle();

    final double after = tester.getSize(find.byType(FileTree)).height;
    expect(after, greaterThan(before), reason: '往下拖 ⇒ 树那一格变高');
    // 比例记在面板状态：关掉查看器再打开，仍是刚才的比例（不是回到 0.4）
    await tester.tap(find.byTooltip('关闭查看器'));
    await settleIo(tester);
    await openFile(tester, 'a.txt');
    expect(
      tester.getSize(find.byType(FileTree)).height,
      closeTo(after, 1),
      reason: '比例存在面板状态里',
    );
  });

  testWidgets('面板太矮（可用高度 < 200）降级成一次只显示一个：只留查看器', (
    WidgetTester tester,
  ) async {
    await pumpPanel(tester, height: 250);
    expect(find.byType(FileTree), findsOneWidget);

    await openFile(tester, 'a.txt');
    expect(
      find.byType(FileTree),
      findsNothing,
      reason: '太矮 ⇒ 不挤两格，只显示查看器',
    );
    expect(find.byType(FileViewer), findsOneWidget);
    expect(find.byTooltip('关闭查看器'), findsOneWidget, reason: '一键回到树独占');

    await tester.tap(find.byTooltip('关闭查看器'));
    await settleIo(tester);
    expect(find.byType(FileTree), findsOneWidget);
    expect(find.byType(FileViewer), findsNothing);
  });
}
