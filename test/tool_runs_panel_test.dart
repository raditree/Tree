// 右栏「正在执行的 tool」面板：把"哪个工具正卡着"从"只能猜"变成"看得见 + 关得掉"。
//
// 覆盖三块：
// ① 纯数据（`ToolRun.fromJson` / 命令摘要压行截断 / 已执行时间文案）——脏数据不抛异常；
// ② 面板本身（列表 + 超阈值高亮、点关闭发出**正确 handle** 的请求并刷新、
//    关闭失败给**可读原因**、空态、加载失败态 + 重试、refreshTrigger 变化重拉）；
// ③ 接线：右栏第 6 个内置页签「正在执行的 tool」（切过去才建面板）。
//
// 为什么用"假核心 + 真 socket"（与 test/message_panel_usage_calls_test.dart 同一套路）：
// 面板是静态 `ApiService` 直连核心的，只有让它真发一次请求，才能验证"打到的是哪个端点、
// body 里的 handle 对不对"——这正是不一致时最先坏掉的地方。
//
// 运行方式（项目根目录，PATH 上的 flutter 是 3.7.12，跑不了本工程）：
//   D:\app\flutter-sdk-3.47.5\flutter\bin\flutter.bat test test/tool_runs_panel_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tree/io/api_service.dart';
import 'package:tree/ui/models/tool_run.dart';
import 'package:tree/ui/widgets/file_panel.dart';
import 'package:tree/ui/widgets/tool_runs_panel.dart';

/// 假核心：只实现「正在执行的工具」用得上的两个端点，其余路径一律 200 + `{success:true}`
/// （右栏其它页签懒建，不会被拉起来，但 FilePanel 自己的文件树 / git 状态会打几发）。
class _FakeToolsCore {
  _FakeToolsCore._(this._http);

  final HttpServer _http;

  /// `GET /api/tools/running` 要回的 runs（测试直接改它模拟登记表变化）。
  List<Map<String, dynamic>> runs = <Map<String, dynamic>>[];

  /// `GET /api/tools/running` 的脚本化失败。
  int runningStatus = 200;
  String runningDetail = '';

  /// `POST /api/tools/close` 的脚本化失败（默认成功）。
  int closeStatus = 200;
  String closeDetail = '';

  /// 假核心收到的关闭句柄（顺序保留：钉"发的是正确的那一个"）。
  final List<String> closeCalls = <String>[];

  /// runs 被拉了几次（钉"关闭成功后刷新了"）。
  int runningRequests = 0;

  static Future<_FakeToolsCore> start() async {
    final HttpServer http = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _FakeToolsCore core = _FakeToolsCore._(http);
    http.listen(core._handle);
    return core;
  }

  String get baseUrl => 'http://127.0.0.1:${_http.port}';

  Future<void> close() => _http.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final String path = request.uri.path;
    Map<String, dynamic> payload = <String, dynamic>{'success': true};
    int status = 200;

    if (request.method == 'GET' && path.endsWith('/api/tools/running')) {
      runningRequests++;
      if (runningStatus != 200) {
        status = runningStatus;
        payload = <String, dynamic>{'detail': runningDetail};
      } else {
        payload = <String, dynamic>{'runs': runs};
      }
    } else if (request.method == 'POST' &&
        path.endsWith('/close') &&
        path.contains('/api/tools/running/')) {
      // 关闭的 handle 在**路径**里（协议 `ApiPaths.toolsRunningClose` =
      // `/api/tools/running/{handle}/close`，**无请求体**）——这里照着核心的路由口径解析
      final String handle = Uri.decodeComponent(
        path.substring(
          '/api/tools/running/'.length,
          path.length - '/close'.length,
        ),
      );
      closeCalls.add(handle);
      if (closeStatus != 200) {
        status = closeStatus;
        payload = <String, dynamic>{'detail': closeDetail};
      } else {
        // 真核心关闭成功 = 登记表里那一条消失
        runs.removeWhere((Map<String, dynamic> r) => r['handle'] == handle);
        payload = <String, dynamic>{
          'closed': true,
          'tool': 'terminal',
          'elapsed_ms': 1000,
          'note': '',
        };
      }
    }

    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(payload));
    await request.response.close();
  }
}

/// 一条 `GET /api/tools/running` 的 runs 项（形状按计划 §4 步骤 4 冻结）。
Map<String, dynamic> runJson(
  String handle, {
  String tool = 'terminal',
  String command = 'sleep 300',
  int elapsedMs = 1830,
  bool over = false,
}) => <String, dynamic>{
  'handle': handle,
  'agent_id': 'a1',
  'session_id': 'session_default',
  'tool': tool,
  'command_preview': command,
  'started_at': '2026-10-03T20:00:00.000Z',
  'elapsed_ms': elapsedMs,
  'over_threshold': over,
};

void main() {
  late _FakeToolsCore core;

  setUpAll(() {
    // flutter_test 默认装了 HttpOverrides（请求被拦成 400）：这里要真打本机假核心
    HttpOverrides.global = null;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    core = await _FakeToolsCore.start();
    ApiService.baseUrl = core.baseUrl;
    ApiService.setToken('test-token');
  });

  tearDown(() async {
    await core.close();
    ApiService.setToken(null);
    ApiService.baseUrl = 'http://127.0.0.1:0';
  });

  /// 让真 socket 上的请求飞完（fake async 不会推进真实 I/O），并各推进一帧。
  ///
  /// 每帧带 30ms：切页签靠 `TabController` 的动画，零时长的 `pump()` 推不动它。
  Future<void> flyIO(WidgetTester tester, {int rounds = 12}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  Future<void> pumpPanel(WidgetTester tester, {int refreshTrigger = 0}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 700,
            height: 600,
            child: ToolRunsPanel(refreshTrigger: refreshTrigger),
          ),
        ),
      ),
    );
    await flyIO(tester);
  }

  // ══ 纯数据 ═══════════════════════════════════════════════════════════════

  group('ToolRun.fromJson', () {
    test('完整字段逐项读出来', () {
      final ToolRun run = ToolRun.fromJson(runJson('toolrun_1', over: true));
      expect(run.handle, 'toolrun_1');
      expect(run.agentId, 'a1');
      expect(run.sessionId, 'session_default');
      expect(run.tool, 'terminal');
      expect(run.commandPreview, 'sleep 300');
      expect(run.elapsedMs, 1830);
      expect(run.overThreshold, isTrue);
      expect(run.startedAt, DateTime.utc(2026, 10, 3, 20, 0, 0));
    });

    test('脏数据不抛异常：类型不对一律退默认值', () {
      final ToolRun run = ToolRun.fromJson(<String, dynamic>{
        'handle': 7,
        'agent_id': null,
        'tool': <String>[],
        'command_preview': '',
        'elapsed_ms': 'abc',
        'started_at': 'not-a-date',
        'over_threshold': 'maybe',
      });
      expect(run.handle, '');
      expect(run.agentId, '');
      expect(run.tool, '');
      expect(run.commandPreview, '');
      expect(run.elapsedMs, 0);
      expect(run.startedAt, isNull);
      expect(run.overThreshold, isFalse);
    });

    test('elapsed_ms 给字符串数字也能读；over_threshold 缺失 = false', () {
      final ToolRun run = ToolRun.fromJson(<String, dynamic>{
        'handle': 'h',
        'elapsed_ms': '120000',
      });
      expect(run.elapsedMs, 120000);
      expect(
        run.overThreshold,
        isFalse,
        reason: '阈值口径只有一个：以核心的 over_threshold 为准，前端不自己算',
      );
    });

    test('elapsed_ms 允许 num（JSON 解出来可能是 double）', () {
      expect(
        ToolRun.fromJson(<String, dynamic>{'elapsed_ms': 1500.0}).elapsedMs,
        1500,
      );
    });
  });

  group('toolCommandPreview', () {
    test('压空白：多行 / 连续空格折成一行', () {
      expect(
        toolCommandPreview('find /mnt\n  -maxdepth 1 \\\n  -name x'),
        'find /mnt -maxdepth 1 \\ -name x',
      );
    });

    test('阈值内原样返回（只是去首尾空白）', () {
      expect(toolCommandPreview('  lsof -p 1  '), 'lsof -p 1');
      expect(toolCommandPreview(''), '');
    });

    test('超长截断到 maxLength + 省略号（别把整条命令塞进一行）', () {
      expect(toolCommandPreview('abcdefghijklmno', maxLength: 10), 'abcdefghij…');
      expect(toolCommandPreview('abcdefghij', maxLength: 10), 'abcdefghij');
      final String long = List<String>.filled(400, 'x').join();
      final String preview = toolCommandPreview(long);
      expect(preview.length, 121, reason: '120 字 + 一个省略号');
      expect(preview.endsWith('…'), isTrue);
    });
  });

  group('toolElapsedLabel', () {
    test('毫秒 / 秒（一位小数）/ 分钟，负数与 0 都按 0 算', () {
      expect(toolElapsedLabel(0), '0ms');
      expect(toolElapsedLabel(999), '999ms');
      expect(toolElapsedLabel(1830), '1.8s');
      expect(toolElapsedLabel(59000), '59.0s');
      expect(toolElapsedLabel(60000), '1m0s');
      expect(toolElapsedLabel(61500), '1m1s');
      expect(toolElapsedLabel(300000), '5m0s');
      expect(toolElapsedLabel(-1), '0ms');
    });
  });

  // ══ 面板 ════════════════════════════════════════════════════════════════

  group('ToolRunsPanel', () {
    final String longCommand = 'find /mnt/space ${List<String>.filled(400, 'x').join()}';

    testWidgets('列表：工具名 / 命令摘要截断 / 已执行时间 / 超阈值高亮', (
      WidgetTester tester,
    ) async {
      core.runs = <Map<String, dynamic>>[
        runJson('toolrun_1'),
        runJson(
          'toolrun_2',
          tool: 'find',
          command: longCommand,
          elapsedMs: 300000,
          over: true,
        ),
      ];
      await pumpPanel(tester);

      expect(find.text('terminal'), findsOneWidget);
      expect(find.text('find'), findsOneWidget);
      expect(find.text('1.8s'), findsOneWidget);
      expect(find.text('5m0s'), findsOneWidget);

      // 命令摘要：压成一行并截断，整条命令不进树
      expect(find.text(longCommand), findsNothing);
      expect(find.textContaining('find /mnt/space'), findsOneWidget);
      expect(find.textContaining('…'), findsOneWidget);

      // 超阈值高亮：只有 over 的那一行有底色 + 「已超时」标记
      expect(find.byKey(const Key('tool-run-over-toolrun_2')), findsOneWidget);
      expect(find.byKey(const Key('tool-run-over-toolrun_1')), findsNothing);
      final Container over = tester.widget<Container>(
        find.byKey(const Key('tool-run-row-toolrun_2')),
      );
      final Container normal = tester.widget<Container>(
        find.byKey(const Key('tool-run-row-toolrun_1')),
      );
      expect((over.decoration as BoxDecoration?)?.color, isNotNull);
      expect(normal.decoration, isNull, reason: '没超阈值就不该着色');
    });

    testWidgets('点关闭：发出正确 handle 的请求，成功后刷新列表', (
      WidgetTester tester,
    ) async {
      core.runs = <Map<String, dynamic>>[
        runJson('toolrun_1'),
        runJson('toolrun_2', tool: 'find'),
      ];
      await pumpPanel(tester);
      expect(core.runningRequests, 1, reason: '首帧拉一次');

      await tester.tap(find.byKey(const Key('tool-run-close-toolrun_2')));
      await flyIO(tester);

      expect(core.closeCalls, <String>['toolrun_2'], reason: '发的是这一行的 handle');
      expect(core.runningRequests, greaterThanOrEqualTo(2), reason: '关掉后要刷新');
      expect(find.text('find'), findsNothing);
      expect(find.text('terminal'), findsOneWidget);
    });

    testWidgets('关闭失败：显示可读原因，且列表不被清空', (WidgetTester tester) async {
      core.runs = <Map<String, dynamic>>[runJson('toolrun_1')];
      core.closeStatus = 404;
      core.closeDetail = '句柄已失效：toolrun_1（核心可能已重启）';
      await pumpPanel(tester);

      await tester.tap(find.byKey(const Key('tool-run-close-toolrun_1')));
      await flyIO(tester);

      expect(core.closeCalls, <String>['toolrun_1']);
      expect(find.textContaining('句柄已失效：toolrun_1'), findsOneWidget);
      expect(find.text('terminal'), findsOneWidget, reason: '失败 ≠ 工具已结束');
    });

    testWidgets('空态：一句话说清没有正在执行的工具', (WidgetTester tester) async {
      core.runs = <Map<String, dynamic>>[];
      await pumpPanel(tester);
      expect(find.text('当前没有正在执行的工具'), findsOneWidget);
    });

    testWidgets('加载失败：给可读原因 + 重试能恢复', (WidgetTester tester) async {
      core.runningStatus = 500;
      core.runningDetail = '登记表不可用（脚本化）';
      await pumpPanel(tester);

      expect(find.textContaining('登记表不可用（脚本化）'), findsOneWidget);
      expect(find.text('当前没有正在执行的工具'), findsNothing);

      core.runningStatus = 200;
      core.runs = <Map<String, dynamic>>[runJson('toolrun_9')];
      await tester.tap(find.byKey(const Key('tool-runs-retry')));
      await flyIO(tester);

      expect(find.textContaining('登记表不可用'), findsNothing);
      expect(find.text('terminal'), findsOneWidget);
    });

    testWidgets('refreshTrigger 变化 ⇒ 重拉（右栏按 WorkspaceArea 增量刷新）', (
      WidgetTester tester,
    ) async {
      core.runs = <Map<String, dynamic>>[runJson('toolrun_1')];
      await pumpPanel(tester);
      expect(core.runningRequests, 1);

      core.runs = <Map<String, dynamic>>[
        runJson('toolrun_1'),
        runJson('toolrun_2', tool: 'find'),
      ];
      await pumpPanel(tester, refreshTrigger: 1);

      expect(core.runningRequests, 2);
      expect(find.text('find'), findsOneWidget);
    });
  });

  // ══ 接线：右栏第 6 个内置页签 ═════════════════════════════════════════════

  group('右栏第 6 个内置页签', () {
    testWidgets('页签「正在执行的 tool」在详情之前，切过去才按需拉数据', (
      WidgetTester tester,
    ) async {
      core.runs = <Map<String, dynamic>>[runJson('toolrun_1')];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 760,
              height: 600,
              child: FilePanel(workspaceId: 'ws1', teamId: 'ws1'),
            ),
          ),
        ),
      );
      await flyIO(tester, rounds: 20);

      expect(find.text('正在执行的 tool'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('正在执行的 tool')).dx,
        lessThan(tester.getTopLeft(find.text('详情')).dx),
        reason: '内置顺序：… 问题回复 / 正在执行的 tool / 详情',
      );
      expect(find.text('terminal'), findsNothing, reason: '没切过去不建面板');
      expect(
        core.runningRequests,
        0,
        reason: '页签没被选中时一次都不该拉（TabBarView 懒建 + initState 才拉）',
      );

      await tester.tap(find.text('正在执行的 tool'));
      await flyIO(tester, rounds: 20);

      expect(core.runningRequests, 1, reason: '切过去才拉一次快照');
      expect(find.text('terminal'), findsOneWidget);
      expect(find.text('1.8s'), findsOneWidget);

      // 端到端再走一遍**关闭**：路径口径与核心路由一致（handle 在路径里）
      core.closeStatus = 404;
      core.closeDetail = '句柄已失效：toolrun_1（核心可能已重启）';
      await tester.tap(find.byKey(const Key('tool-run-close-toolrun_1')));
      await flyIO(tester, rounds: 20);
      expect(core.closeCalls, <String>['toolrun_1']);
      expect(find.textContaining('句柄已失效：toolrun_1'), findsOneWidget);
    });
  });
}
