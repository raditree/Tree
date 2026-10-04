// 文件面板根错误块上的「重连」按钮：SSH 心跳判失活之后的**显式恢复入口**。
//
// 覆盖三块（全部真点击、真起假核心 HttpServer）：
// ① 根加载失败 ⇒ 错误块出现「重连」按钮；
// ② 点它 ⇒ 假核心收到 `POST /api/agents/<真 agentId>/ssh/reconnect`（断言路径里是 agentId、
//    不是 `ws_…`），成功后文件树**就地重拉**（假核心此时回正常列表）；
// ③ 失败（500 + error.detail）⇒ 页面出现该 detail 文案，且**既有内容不清空**。
//
// 为什么用"假核心 + 真 socket"（与 test/file_tree_explorer_test.dart 同一套路）：
// ApiService 是静态的、直连核心，只有让它真发一次请求，才能验证"打到的是哪个端点、
// 路径里的 agentId 对不对"——这正是不一致时最先坏掉的地方。
//
// 运行方式（项目根目录，PATH 上的 flutter 不是本工程用的版本）：
//   D:\app\flutter-sdk-3.47.5\flutter\bin\flutter.bat test test/file_tree_reconnect_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/io/api_service.dart';
import 'package:tree/ui/widgets/file_tree.dart';

import 'fake_tree_core.dart';

/// 让真 socket 上的请求飞完（fake async 不会推进真实 I/O），并各推进一帧。
Future<void> flyIO(WidgetTester tester, {int rounds = 16}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// 等到条件成立（真实事件循环 + pump）：比"数固定帧数"稳，重负载下也不飘。
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() ready, {
  int rounds = 80,
}) async {
  for (int i = 0; i < rounds; i++) {
    if (ready()) {
      await tester.pump();
      return;
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  late FakeTreeCore core;

  /// 测试里的真 agentId（**必须**与 workspaceId 区分开，才能钉"路径里是 agentId"）。
  const String agentId = 'agent-1';
  const String workspaceId = 'ws1';

  setUpAll(() {
    // flutter_test 默认给进程装了 HttpOverrides：请求会被拦成 400、不真发出去
    HttpOverrides.global = null;
  });

  setUp(() async {
    core = await FakeTreeCore.start();
    ApiService.baseUrl = core.baseUrl;
    ApiService.setToken('test-token');
  });

  tearDown(() async {
    await core.close();
    ApiService.setToken(null);
    ApiService.baseUrl = 'http://127.0.0.1:0';
  });

  Future<void> pumpTree(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            height: 360,
            child: FileTree(workspaceId: workspaceId, teamId: agentId),
          ),
        ),
      ),
    );
    await flyIO(tester);
  }

  final Finder reconnectButton = find.byKey(
    const Key('file-tree-reconnect'),
  );

  /// 假核心收到的 `/ssh/reconnect` 请求（路径已解码）。
  List<String> reconnectPaths() => core.calls
      .where((c) => c.method == 'POST' && c.path.endsWith('/ssh/reconnect'))
      .map((c) => c.path)
      .toList();

  testWidgets('① 根加载失败 ⇒ 错误块出现「重连」按钮', (WidgetTester tester) async {
    core.failingDirs.add(''); // 根目录列举 404

    await pumpTree(tester);

    // 根错误块在：出错提示 + 一颗「重连」按钮
    expect(find.textContaining('目录不存在'), findsOneWidget);
    expect(reconnectButton, findsOneWidget);
    expect(find.text('重连'), findsOneWidget);
    // 没点之前不该发重连请求
    expect(reconnectPaths(), isEmpty);
  });

  testWidgets('② 点重连 ⇒ 打到真 agentId 端点，成功后文件树重拉', (
    WidgetTester tester,
  ) async {
    core.failingDirs.add('');
    await pumpTree(tester);
    expect(reconnectButton, findsOneWidget);

    // 远端已恢复：核心此时能正常回根列表（点击后重拉应看到它）
    core.failingDirs.remove('');
    core.dirs[''] = <Map<String, dynamic>>[
      FakeTreeCore.file('a.txt', 'a.txt'),
    ];

    await tester.tap(reconnectButton);
    await pumpUntil(tester, () => tester.any(find.text('a.txt')) || reconnectPaths().isNotEmpty);
    await flyIO(tester);

    // 路径里是**真 agentId**，而不是 `ws_…`
    expect(reconnectPaths(), <String>['/api/agents/$agentId/ssh/reconnect']);
    expect(
      reconnectPaths().any((p) => p.contains(workspaceId)),
      isFalse,
      reason: '不该把 workspaceId（ws_…）当 agentId 用',
    );
    // 成功后：文件树就地重拉（新条目出现），错误块消失，并给了「已重连」提示
    expect(find.text('a.txt'), findsOneWidget);
    expect(reconnectButton, findsNothing);
    expect(find.text('已重连'), findsOneWidget);
  });

  testWidgets('③ 重连失败 ⇒ 显示可读 detail，且既有内容不清空', (
    WidgetTester tester,
  ) async {
    core.failingDirs.add('');
    await pumpTree(tester);

    final String rootError = tester
        .widget<Text>(find.textContaining('目录不存在'))
        .data!;

    // 核心回 500 + error.detail：可读原因必须原样显示出来
    core.reconnectStatus = 500;
    core.reconnectDetail = '重连被拒：远端主机不可达';

    await tester.tap(reconnectButton);
    await pumpUntil(
      tester,
      () => tester.any(find.textContaining('重连被拒')),
    );
    await flyIO(tester);

    expect(find.textContaining('重连被拒：远端主机不可达'), findsOneWidget);
    // 既有内容（根错误块）没被清空、没白屏：文字与按钮都还在
    expect(find.text(rootError), findsOneWidget);
    expect(reconnectButton, findsOneWidget);
  });
}
