import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/io/api_service.dart';
import 'package:tree/ui/widgets/file_tree.dart';

import 'fake_tree_core.dart';

/// 放行挂在控件上的真实 IO/网络：假时钟里一次请求要走好几步（建连 → 请求 → 读响应），
/// 一圈只推进一步。与 test/file_editor_test.dart 同一套写法。
Future<void> settleIo(WidgetTester tester, {int rounds = 12}) async {
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
      // 条件成立那一刻的回调多半只 setState 了：再推一帧让重建落地，
      // 免得断言紧接着去看"旧的那一帧"
      await tester.pump();
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump();
  }
}

/// VS Code 型资源管理器（文件面板的目录树）。
///
/// 真起假核心 HTTP 服务：断言的既有"控件长什么样"，也有"打到哪个端点、body 是什么"。
void main() {
  late FakeTreeCore core;
  final List<String> opened = <String>[];
  final List<String> scopes = <String>[];
  final List<(String, String)> renamed = <(String, String)>[];
  final List<String> deleted = <String>[];
  final List<(String, bool)> downloads = <(String, bool)>[];

  setUpAll(() {
    // flutter_test 默认给进程装了 HttpOverrides：请求会被拦成 400、不真发出去
    HttpOverrides.global = null;
  });

  setUp(() async {
    core = await FakeTreeCore.start();
    ApiService.baseUrl = core.baseUrl;
    ApiService.setToken('test-token');
    opened.clear();
    scopes.clear();
    renamed.clear();
    deleted.clear();
    downloads.clear();
    core.dirs[''] = <Map<String, dynamic>>[
      FakeTreeCore.dir('bad', 'bad'),
      FakeTreeCore.dir('empty', 'empty'),
      FakeTreeCore.dir('src', 'src'),
      FakeTreeCore.file('a.txt', 'a.txt', size: 3800),
      FakeTreeCore.file('b.md', 'b.md'),
    ];
    core.dirs['src'] = <Map<String, dynamic>>[
      FakeTreeCore.dir('src/lib', 'lib'),
      FakeTreeCore.file('src/main.dart', 'main.dart'),
    ];
    core.dirs['src/lib'] = <Map<String, dynamic>>[
      FakeTreeCore.file('src/lib/deep.dart', 'deep.dart'),
    ];
    core.dirs['empty'] = <Map<String, dynamic>>[];
    core.failingDirs.add('bad');
  });

  tearDown(() async {
    await core.close();
  });

  Future<void> pumpTree(
    WidgetTester tester, {
    int refreshTrigger = 0,
    bool settle = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            height: 360,
            child: FileTree(
              workspaceId: 'ws1',
              teamId: 'ws1',
              refreshTrigger: refreshTrigger,
              onFileSelected: opened.add,
              onPathChanged: scopes.add,
              onPathRenamed: (String from, String to) =>
                  renamed.add((from, to)),
              onPathDeleted: deleted.add,
              onDownload: (String path, bool isDirectory) =>
                  downloads.add((path, isDirectory)),
            ),
          ),
        ),
      ),
    );
    if (settle) await settleIo(tester);
  }

  Color rowColor(WidgetTester tester, String path) => tester
      .widget<ColoredBox>(find.byKey(FileTree.rowBackgroundKey(path)))
      .color;

  ColorScheme schemeAt(WidgetTester tester, String path) =>
      Theme.of(tester.element(find.byKey(FileTree.rowKey(path)))).colorScheme;

  Tooltip tooltipOf(WidgetTester tester, String path) => tester.widget<Tooltip>(
    find.ancestor(
      of: find.byKey(FileTree.rowKey(path)),
      matching: find.byType(Tooltip),
    ),
  );

  Future<void> openRowMenu(WidgetTester tester, String path) async {
    await tester.tap(
      find.byKey(FileTree.rowKey(path)),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
  }

  group('外观：VS Code 型资源管理器', () {
    testWidgets('行高 22–24、字号 13、行内左右 padding 6–8、超长名省略号', (
      WidgetTester tester,
    ) async {
      await pumpTree(tester);
      expect(kFileTreeRowHeight, inInclusiveRange(22, 24));
      expect(kFileTreeFontSize, 13);
      expect(kFileTreeEdgePadding, inInclusiveRange(6, 8));

      expect(
        tester.getSize(find.byKey(FileTree.rowKey('a.txt'))).height,
        kFileTreeRowHeight,
      );
      final Text name = tester.widget<Text>(find.descendant(of: find.byKey(FileTree.rowKey('a.txt')), matching: find.text('a.txt')));
      expect(name.style?.fontSize, 13);
      expect(name.maxLines, 1);
      expect(name.overflow, TextOverflow.ellipsis);
    });

    testWidgets('不再渲染「大小 / 修改时间」两列（它们只在悬停 tooltip 里）', (
      WidgetTester tester,
    ) async {
      await pumpTree(tester);
      expect(find.text('3.7 KB'), findsNothing);
      expect(find.textContaining('KB'), findsNothing);
      expect(find.textContaining('2026-10-02'), findsNothing);
    });

    testWidgets('悬停 tooltip：全名 + 类型 · 大小 · 修改时间', (
      WidgetTester tester,
    ) async {
      await pumpTree(tester);
      final String? message = tooltipOf(tester, 'a.txt').message;
      expect(message, startsWith('a.txt\n'), reason: '第一行是全名（截断时靠它看全）');
      expect(message, contains('文本'));
      expect(message, contains('3.7 KB'));
      expect(message, contains('2026-10-02 11:31'));
    });

    testWidgets('目录 tooltip：展开过才有「N 项」，没展开就只给时间（不编数字）', (
      WidgetTester tester,
    ) async {
      await pumpTree(tester);
      expect(tooltipOf(tester, 'src').message, contains('文件夹'));
      expect(tooltipOf(tester, 'src').message, contains('2026-10-02 11:31'));
      expect(
        tooltipOf(tester, 'src').message,
        isNot(contains('项')),
        reason: '还没展开 ⇒ 不知道有几项',
      );

      await tester.tap(find.byKey(FileTree.rowKey('src')));
      await settleIo(tester);
      expect(tooltipOf(tester, 'src').message, contains('2 项'));
    });
  });

  group('类型图标 / 箭头 / 缩进引导线', () {
    testWidgets('目录与文件都用中性图标（跟主题走）：类型靠形状、颜色只留给 git 状态', (
      WidgetTester tester,
    ) async {
      await pumpTree(tester);
      final Color neutral = schemeAt(tester, 'a.txt').onSurfaceVariant;
      final Icon dirIcon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(FileTree.rowKey('src')),
          matching: find.byIcon(Icons.folder_outlined),
        ),
      );
      expect(dirIcon.color, neutral, reason: '描边文件夹 + 主题中性色（用户看图定稿）');

      final Icon mdIcon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(FileTree.rowKey('b.md')),
          matching: find.byIcon(Icons.description_outlined),
        ),
      );
      expect(mdIcon.color, neutral, reason: '类型不再有自己的颜色');

      final Icon txtIcon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(FileTree.rowKey('a.txt')),
          matching: find.byIcon(Icons.text_snippet_outlined),
        ),
      );
      expect(txtIcon.color, neutral);
    });

    testWidgets('箭头只在目录上；展开时顺时针转 90°（图标形状不变，与 VS Code 一致）', (
      WidgetTester tester,
    ) async {
      await pumpTree(tester);
      expect(find.byKey(FileTree.arrowKey('src')), findsOneWidget);
      expect(
        find.byKey(FileTree.arrowKey('a.txt')),
        findsNothing,
        reason: '文件行不画箭头（但留了等宽空槽，见对齐用例）',
      );

      AnimatedRotation rotation() => tester.widget<AnimatedRotation>(
        find.descendant(
          of: find.byKey(FileTree.rowKey('src')),
          matching: find.byType(AnimatedRotation),
        ),
      );
      expect(rotation().turns, 0.0);

      await tester.tap(find.byKey(FileTree.rowKey('src')));
      await settleIo(tester);
      expect(rotation().turns, 0.25, reason: '展开 = 顺时针 90°（0.25 圈）');
      expect(
        find.descendant(
          of: find.byKey(FileTree.rowKey('src')),
          matching: find.byIcon(Icons.folder_outlined),
        ),
        findsOneWidget,
        reason: '展开只转箭头，文件夹图标形状不变（VS Code 口径；用户 2026-10-04）',
      );
    });

    testWidgets('同级文件与目录名字对齐；子项右移一层缩进', (
      WidgetTester tester,
    ) async {
      await pumpTree(tester);
      final double dirNameLeft = tester.getTopLeft(find.text('src')).dx;
      final double fileNameLeft = tester.getTopLeft(find.text('a.txt')).dx;
      expect(fileNameLeft, dirNameLeft, reason: '文件行与目录行必须对齐');

      await tester.tap(find.byKey(FileTree.rowKey('src')));
      await settleIo(tester);
      final double childLeft = tester.getTopLeft(find.text('main.dart')).dx;
      expect(childLeft - dirNameLeft, kFileTreeIndentWidth);
    });

    testWidgets('缩进引导线随层级数量变化，且真的是 1px 竖线', (
      WidgetTester tester,
    ) async {
      await pumpTree(tester);
      expect(
        find.byKey(FileTree.indentGuideKey('src', 0)),
        findsNothing,
        reason: '根层没有引导线',
      );

      await tester.tap(find.byKey(FileTree.rowKey('src')));
      await settleIo(tester);
      expect(
        find.byKey(FileTree.indentGuideKey('src/main.dart', 0)),
        findsOneWidget,
        reason: '一层缩进 = 一条引导线',
      );
      expect(
        find.byKey(FileTree.indentGuideKey('src/main.dart', 1)),
        findsNothing,
      );

      await tester.tap(find.byKey(FileTree.rowKey('src/lib')));
      await settleIo(tester);
      expect(
        find.byKey(FileTree.indentGuideKey('src/lib/deep.dart', 0)),
        findsOneWidget,
      );
      expect(
        find.byKey(FileTree.indentGuideKey('src/lib/deep.dart', 1)),
        findsOneWidget,
      );
      expect(
        find.byKey(FileTree.indentGuideKey('src/lib/deep.dart', 2)),
        findsNothing,
        reason: '两层缩进 = 两条引导线（数量随层级变化）',
      );

      final Finder line = find.descendant(
        of: find.byKey(FileTree.indentGuideKey('src/lib/deep.dart', 1)),
        matching: find.byType(Container),
      );
      expect(tester.getSize(line).width, 1.0);
      expect(tester.widget<Container>(line).color, isNotNull);
    });
  });

  group('悬停 / 选中 / 键盘', () {
    testWidgets('整行悬停浅底（只有悬停那一行）', (WidgetTester tester) async {
      await pumpTree(tester);
      expect(rowColor(tester, 'a.txt'), Colors.transparent);

      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(
        tester.getCenter(find.byKey(FileTree.rowKey('a.txt'))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(rowColor(tester, 'a.txt'), isNot(Colors.transparent));
      expect(rowColor(tester, 'b.md'), Colors.transparent);
    });

    testWidgets('选中整行更重的底 + 左侧 2px 主色条；点文件仍回调打开', (
      WidgetTester tester,
    ) async {
      await pumpTree(tester);
      await tester.tap(find.byKey(FileTree.rowKey('a.txt')));
      await settleIo(tester);

      final Color selected = rowColor(tester, 'a.txt');
      expect(selected, isNot(Colors.transparent));
      expect(
        selected,
        schemeAt(tester, 'a.txt').primary.withValues(alpha: 0.16),
      );
      expect(
        tester.getSize(find.byKey(FileTree.selectionBarKey('a.txt'))).width,
        2.0,
      );
      expect(rowColor(tester, 'b.md'), Colors.transparent);
      expect(opened, <String>['a.txt'], reason: '点文件仍要交给父组件打开查看器');
    });

    testWidgets('键盘 ↑/↓ 在树里移动选中，→ 展开目录', (WidgetTester tester) async {
      await pumpTree(tester);
      // 可见顺序：bad / empty / src / a.txt / b.md（目录在前，同类按名字）
      await tester.tap(find.byKey(FileTree.rowKey('a.txt')));
      await settleIo(tester);
      expect(rowColor(tester, 'a.txt'), isNot(Colors.transparent));

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(rowColor(tester, 'b.md'), isNot(Colors.transparent));
      expect(rowColor(tester, 'a.txt'), Colors.transparent);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(rowColor(tester, 'src'), isNot(Colors.transparent));
      expect(scopes.last, 'src', reason: '选中目录 ⇒ 同步作用域就是它');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settleIo(tester);
      expect(find.text('main.dart'), findsOneWidget, reason: '→ 展开目录');
    });
  });

  group('展开 / 折叠 / 各档状态提示', () {
    testWidgets('点目录就地展开（按需拉那一层）再点折叠', (WidgetTester tester) async {
      await pumpTree(tester);
      expect(find.text('main.dart'), findsNothing);

      await tester.tap(find.byKey(FileTree.rowKey('src')));
      await settleIo(tester);
      expect(find.text('main.dart'), findsOneWidget);
      expect(
        core.called('GET', '/api/files/ws1', queryContains: 'path=src'),
        isTrue,
        reason: '展开时才拉这一层（惰性加载）',
      );

      await tester.tap(find.byKey(FileTree.rowKey('src')));
      await tester.pump();
      expect(find.text('main.dart'), findsNothing);
    });

    testWidgets('展开状态跨刷新保持（重拉之后不塌，内容却是新的）', (
      WidgetTester tester,
    ) async {
      await pumpTree(tester);
      await tester.tap(find.byKey(FileTree.rowKey('src')));
      await settleIo(tester);
      expect(find.text('main.dart'), findsOneWidget);

      core.dirs['src'] = <Map<String, dynamic>>[
        FakeTreeCore.file('src/added.dart', 'added.dart'),
        ...core.dirs['src']!,
      ];
      await pumpTree(tester, refreshTrigger: 1);

      expect(find.text('added.dart'), findsOneWidget, reason: '刷新要拿到新内容');
      expect(find.text('main.dart'), findsOneWidget);
      final AnimatedRotation rotation = tester.widget<AnimatedRotation>(
        find.descendant(
          of: find.byKey(FileTree.rowKey('src')),
          matching: find.byType(AnimatedRotation),
        ),
      );
      expect(rotation.turns, 0.25, reason: '刷新后展开状态不许塌');
    });

    testWidgets('空目录 / 加载失败都给可见提示', (WidgetTester tester) async {
      await pumpTree(tester);
      await tester.tap(find.byKey(FileTree.rowKey('empty')));
      await settleIo(tester);
      expect(find.text('空文件夹'), findsOneWidget);

      await tester.tap(find.byKey(FileTree.rowKey('bad')));
      await settleIo(tester);
      expect(find.textContaining('加载失败'), findsOneWidget);
      expect(find.textContaining('目录不存在'), findsOneWidget);
    });

    testWidgets('根加载失败：整块错误提示，不白屏', (WidgetTester tester) async {
      core.failingDirs.add('');
      await pumpTree(tester);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.textContaining('目录不存在'), findsOneWidget);
    });

    testWidgets('根为空：居中「空文件夹」', (WidgetTester tester) async {
      core.dirs[''] = <Map<String, dynamic>>[];
      await pumpTree(tester);
      expect(find.text('空文件夹'), findsOneWidget);
    });

    testWidgets('超大目录被核心截断：显式给一行提示（不再丢 truncated）', (
      WidgetTester tester,
    ) async {
      core.truncatedRoot = true;
      await pumpTree(tester);
      expect(find.textContaining('已截断'), findsOneWidget);
      expect(find.textContaining('仅显示前 5 项'), findsOneWidget);
    });

    testWidgets('首帧显示加载中，拉完换成树', (WidgetTester tester) async {
      await pumpTree(tester, settle: false);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await settleIo(tester);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('a.txt'), findsOneWidget);
    });
  });

  group('git 状态着色（VS Code 口径）', () {
    testWidgets('文件按状态染名字 + 行尾字母；目录聚合子项状态；一次请求就够', (
      WidgetTester tester,
    ) async {
      core.gitStatus = <String, dynamic>{
        'is_repo': true,
        'entries': <dynamic>[
          <String, dynamic>{'path': 'src/main.dart', 'status': 'M'},
          <String, dynamic>{'path': 'a.txt', 'status': 'U'},
        ],
      };
      await pumpTree(tester);

      final Text untracked = tester.widget<Text>(find.descendant(of: find.byKey(FileTree.rowKey('a.txt')), matching: find.text('a.txt')));
      expect(untracked.style?.color, const Color(0xFF73C991));
      expect(
        find.descendant(
          of: find.byKey(FileTree.rowKey('a.txt')),
          matching: find.text('U'),
        ),
        findsOneWidget,
      );

      final Text dir = tester.widget<Text>(find.descendant(of: find.byKey(FileTree.rowKey('src')), matching: find.text('src')));
      expect(
        dir.style?.color,
        const Color(0xFFE2A03F),
        reason: '目录聚合：子项改了 ⇒ 目录也带色',
      );
      expect(
        find.descendant(
          of: find.byKey(FileTree.rowKey('src')),
          matching: find.text('M'),
        ),
        findsOneWidget,
      );

      final Text clean = tester.widget<Text>(find.descendant(of: find.byKey(FileTree.rowKey('b.md')), matching: find.text('b.md')));
      expect(clean.style?.color, schemeAt(tester, 'b.md').onSurface);
      expect(
        core.gitStatusRequests,
        1,
        reason: '一帧一次请求就够，不要塞进每一行的重建路径',
      );
    });

    testWidgets('不是仓库（is_repo=false）⇒ 一行都不上色', (WidgetTester tester) async {
      await pumpTree(tester);
      expect(
        tester.widget<Text>(find.descendant(of: find.byKey(FileTree.rowKey('a.txt')), matching: find.text('a.txt'))).style?.color,
        schemeAt(tester, 'a.txt').onSurface,
      );
      expect(find.text('U'), findsNothing);
      expect(find.text('M'), findsNothing);
    });

    testWidgets('核心还没这个端点（404）⇒ 静默不着色，树照常可用', (
      WidgetTester tester,
    ) async {
      core.gitStatusStatus = 404;
      await pumpTree(tester);
      expect(find.text('a.txt'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsNothing);
      expect(
        tester.widget<Text>(find.descendant(of: find.byKey(FileTree.rowKey('a.txt')), matching: find.text('a.txt'))).style?.color,
        schemeAt(tester, 'a.txt').onSurface,
      );
    });

    testWidgets('改名 / 删除之后 git 状态会重拉（着色不滞后）', (
      WidgetTester tester,
    ) async {
      core.gitStatus = <String, dynamic>{
        'is_repo': true,
        'entries': <dynamic>[
          <String, dynamic>{'path': 'a.txt', 'status': 'M'},
        ],
      };
      await pumpTree(tester);
      final int before = core.gitStatusRequests;

      await openRowMenu(tester, 'a.txt');
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await pumpUntil(tester, () => core.gitStatusRequests > before);

      expect(core.gitStatusRequests, greaterThan(before));
    });
  });

  group('右键菜单与条目动作', () {
    testWidgets('全部折叠：把展开的目录（含嵌套）收回去，并滚回顶部', (
      WidgetTester tester,
    ) async {
      await pumpTree(tester);
      await tester.tap(find.byKey(FileTree.rowKey('src')));
      await settleIo(tester);
      expect(find.text('lib'), findsOneWidget, reason: 'src 展开后应出现子目录');

      await tester.tap(find.byKey(FileTree.rowKey('src/lib')));
      await settleIo(tester);
      expect(find.text('deep.dart'), findsOneWidget, reason: '嵌套一层也展开');

      // 头部那颗「全部折叠」
      await tester.tap(find.byTooltip('全部折叠'));
      await tester.pumpAndSettle();
      expect(find.text('lib'), findsNothing, reason: '嵌套的子目录也要收回去');
      expect(find.text('deep.dart'), findsNothing);
      expect(
        find.byKey(FileTree.rowKey('src')),
        findsOneWidget,
        reason: '收的是展开状态，根层条目照旧',
      );
      expect(
        tester.widget<AnimatedRotation>(
          find.descendant(
            of: find.byKey(FileTree.rowKey('src')),
            matching: find.byType(AnimatedRotation),
          ),
        ).turns,
        0.0,
        reason: '箭头回到收起方向',
      );
    });

    testWidgets('全部折叠：没有展开项时置灰并说明原因（不是"点了没反应"）', (
      WidgetTester tester,
    ) async {
      await pumpTree(tester);
      // 一棵还没展开过的树：这颗键不该可点，tooltip 也要说清为什么
      final Finder byTooltip = find.byTooltip('没有展开的目录（都收着呢）');
      expect(byTooltip, findsOneWidget);
      expect(
        tester.widget<IconButton>(
          find.ancestor(of: byTooltip, matching: find.byType(IconButton)),
        ).onPressed,
        isNull,
        reason: '没有可收的目录 ⇒ 置灰，而不是点了没反应',
      );

      // 展开一层之后就该可点了
      await tester.tap(find.byKey(FileTree.rowKey('src')));
      await settleIo(tester);
      final Finder enabled = find.byTooltip('全部折叠');
      expect(enabled, findsOneWidget);
      expect(
        tester.widget<IconButton>(
          find.ancestor(of: enabled, matching: find.byType(IconButton)),
        ).onPressed,
        isNotNull,
      );
    });

    testWidgets('菜单项齐备：打开 / 新建 / 重命名 / 删除 / 在文件夹中显示 / 复制路径 / 下载 / 刷新', (
      WidgetTester tester,
    ) async {
      await pumpTree(tester);
      await openRowMenu(tester, 'a.txt');
      for (final String label in <String>[
        '打开',
        '新建文件',
        '新建文件夹',
        '重命名',
        '删除',
        '在文件夹中显示',
        '复制路径',
        '下载',
        '刷新',
        '全部折叠',
      ]) {
        expect(find.text(label), findsOneWidget, reason: '菜单缺：$label');
      }
    });

    testWidgets('空白处右键：只给通用动作（没有条目动作）', (WidgetTester tester) async {
      await pumpTree(tester);
      // 5 行 = 110px，面板高 360 ⇒ y=320 是列表下方的空白
      await tester.tapAt(const Offset(40, 320), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('新建文件'), findsOneWidget);
      expect(find.text('刷新'), findsOneWidget);
      expect(find.text('全部折叠'), findsOneWidget);
      expect(find.text('重命名'), findsNothing);
      expect(find.text('删除'), findsNothing);
      expect(find.text('复制路径'), findsNothing);
    });

    testWidgets('复制路径：写剪贴板（相对路径）+ 可见提示', (WidgetTester tester) async {
      final List<MethodCall> calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await pumpTree(tester);
      await openRowMenu(tester, 'a.txt');
      await tester.tap(find.text('复制路径'));
      await settleIo(tester);

      final MethodCall setData = calls.firstWhere(
        (MethodCall call) => call.method == 'Clipboard.setData',
      );
      expect((setData.arguments as Map<dynamic, dynamic>)['text'], 'a.txt');
      expect(find.textContaining('已复制相对路径：a.txt'), findsOneWidget);
    });

    testWidgets('下载：沿用既有回调（文件 / 目录都带上"是不是目录"）', (
      WidgetTester tester,
    ) async {
      await pumpTree(tester);
      await openRowMenu(tester, 'src');
      await tester.tap(find.text('下载'));
      await settleIo(tester);
      expect(downloads, <(String, bool)>[('src', true)]);
    });

    testWidgets('在文件夹中显示：算不出本地绝对路径时给可读原因，不假装成功', (
      WidgetTester tester,
    ) async {
      await pumpTree(tester);
      await openRowMenu(tester, 'a.txt');
      await tester.tap(find.text('在文件夹中显示'));
      await settleIo(tester);
      // 假核心没有 agent 配置 ⇒ 前端算不出绝对路径，只能如实说
      expect(find.textContaining('没有显式配置本地工作目录'), findsOneWidget);
    });
  });

  group('新建 / 重命名 / 删除', () {
    testWidgets('新建文件：走 PUT content（空内容），落盘后树里出现', (
      WidgetTester tester,
    ) async {
      await pumpTree(tester);
      await tester.tap(find.byTooltip('新建文件'));
      await tester.pumpAndSettle();
      expect(find.text('位置：工作空间根目录'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'hello.txt');
      await tester.tap(find.text('创建'));
      await settleIo(tester);

      expect(core.writes, hasLength(1));
      expect(core.writes.single.path, 'hello.txt');
      expect(core.writes.single.content, '');
      // 等目录重拉把新文件带回来
      await pumpUntil(
        tester,
        () => find.byKey(FileTree.rowKey('hello.txt')).evaluate().isNotEmpty,
      );
      // 用行 key 限定：对话框正在退场时它的 EditableText 也匹配 find.text
      expect(
        find.descendant(
          of: find.byKey(FileTree.rowKey('hello.txt')),
          matching: find.text('hello.txt'),
        ),
        findsOneWidget,
      );
      // 建完还要重拉目录 + 重拉 git 状态，提示是最后一步：等它真的出现
      await pumpUntil(
        tester,
        () => find.textContaining('新建文件：hello.txt').evaluate().isNotEmpty,
      );
      expect(find.textContaining('新建文件：hello.txt'), findsOneWidget);
    });

    testWidgets('新建文件：同名已存在就报错，**不覆盖**', (WidgetTester tester) async {
      await pumpTree(tester);
      await tester.tap(find.byTooltip('新建文件'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'a.txt');
      await tester.tap(find.text('创建'));
      await settleIo(tester);

      expect(core.writes, isEmpty, reason: '核对的 PUT 没有"仅新建"语义，前端必须拦');
      expect(find.textContaining('同名条目已存在，未创建'), findsOneWidget);
    });

    testWidgets('新建文件的对话框里非法名字给红字且不关框', (WidgetTester tester) async {
      await pumpTree(tester);
      await tester.tap(find.byTooltip('新建文件'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'bad/name.txt');
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      expect(find.textContaining('路径分隔符'), findsOneWidget);
      expect(find.text('创建'), findsOneWidget, reason: '校验不过 ⇒ 对话框不关');
      expect(core.writes, isEmpty);
    });

    testWidgets('新建文件夹：POST mkdir；核心 409 时原样显示可读原因', (
      WidgetTester tester,
    ) async {
      core.mkdirStatus = 409;
      core.mkdirDetail = '目标已存在：src2';
      await pumpTree(tester);
      await tester.tap(find.byTooltip('新建文件夹'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'src2');
      await tester.tap(find.text('创建'));
      await pumpUntil(
        tester,
        () => find.textContaining('目标已存在：src2').evaluate().isNotEmpty,
      );

      expect(core.called('POST', '/api/files/ws1/mkdir'), isTrue);
      expect(find.textContaining('目标已存在：src2'), findsOneWidget);
    });

    testWidgets('行内重命名：回车确认，行里换成新名字并回调父组件', (
      WidgetTester tester,
    ) async {
      await pumpTree(tester);
      await openRowMenu(tester, 'a.txt');
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      expect(find.byKey(FileTree.renameFieldKey), findsOneWidget);

      await tester.enterText(find.byKey(FileTree.renameFieldKey), 'renamed.txt');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await pumpUntil(tester, () => renamed.isNotEmpty);
      // 改名之后父目录会重拉：等新名字的那一行真的回来
      await pumpUntil(
        tester,
        () => find.byKey(FileTree.rowKey('renamed.txt')).evaluate().isNotEmpty,
      );

      expect(core.called('POST', '/api/files/ws1/rename'), isTrue);
      expect(renamed, <(String, String)>[('a.txt', 'renamed.txt')]);
      expect(find.text('renamed.txt'), findsOneWidget);
      expect(find.byKey(FileTree.renameFieldKey), findsNothing);
    });

    testWidgets('行内重命名：重名给行内红字、不提交；Esc 取消', (
      WidgetTester tester,
    ) async {
      await pumpTree(tester);
      await openRowMenu(tester, 'b.md');
      await tester.tap(find.text('重命名'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(FileTree.renameFieldKey), 'a.txt');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settleIo(tester);

      expect(find.textContaining('同名条目已存在'), findsOneWidget);
      expect(renamed, isEmpty);
      expect(find.byKey(FileTree.renameFieldKey), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byKey(FileTree.renameFieldKey), findsNothing);
      expect(find.text('b.md'), findsOneWidget);
    });

    testWidgets('删除：确认框写明名字与类型，目录额外警告"一起删除"；递归参数显式带上', (
      WidgetTester tester,
    ) async {
      await pumpTree(tester);
      await openRowMenu(tester, 'src');
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('删除文件夹'), findsOneWidget);
      expect(find.textContaining('一起删除'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await pumpUntil(tester, () => deleted.isNotEmpty);
      await pumpUntil(
        tester,
        () => find.byKey(FileTree.rowKey('src')).evaluate().isEmpty,
      );

      expect(
        core.called(
          'DELETE',
          '/api/files/ws1',
          queryContains: 'path=src',
        ),
        isTrue,
      );
      expect(
        core.called(
          'DELETE',
          '/api/files/ws1',
          queryContains: 'recursive=1',
        ),
        isTrue,
        reason: '目录递归删除必须显式：不静默递归、也不做半截',
      );
      expect(deleted, <String>['src']);
      expect(find.byKey(FileTree.rowKey('src')), findsNothing);
    });

    testWidgets('删除文件：不警告递归，取消则什么都不发生', (
      WidgetTester tester,
    ) async {
      await pumpTree(tester);
      await openRowMenu(tester, 'a.txt');
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('删除文件'), findsOneWidget);
      expect(find.textContaining('一起删除'), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await settleIo(tester);
      expect(deleted, isEmpty);
      expect(find.text('a.txt'), findsOneWidget);
    });

    test('前端也拦住"删除工作空间根"：不发请求就给可读错误', () async {
      await expectLater(
        ApiService.deletePath('ws1', ''),
        throwsA(
          predicate(
            (Object e) => e.toString().contains('不能删除工作空间根目录'),
          ),
        ),
      );
      expect(core.called('DELETE', '/api/files/ws1'), isFalse);
    });
  });
}
