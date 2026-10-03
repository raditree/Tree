// 「本轮调用列表」接进中栏（MessagePanel）的**接线**测试。
//
// 现成件（`UsageCallsPanel` / `UsageCallView` / `UsageLogFiles`）各自已有单测；这里
// 只钉接线本身的四件事——这四处正是"接上去"和"没接上"的唯一区别：
// ① 实时帧（`msg_usage` / `msg_end` 的 `usage`）进来后，面板里出现对应行
//    （来源 / 输入 / 输出 / 耗时 / `估算` 标记）；
// ② 历史账本 `usage.jsonl` 读**成功**（真临时文件）与读**失败**（文件不存在 ⇒ 可读空态，
//    且不抛、不红）两种；
// ③ 切换会话后这份列表被清空（旧会话的行不许留在新会话里）；
// ④ 折叠态默认**不渲染正文**（用量是"需要才查"的信息，不该默认占版面）。
//
// 为什么用"假核心 + 真 socket"：面板是静态 `ApiService` 直连核心的，WS 帧要真的从
// 连接上进来才算数（与 test/message_panel_window_work_test.dart 同一套路）：本机
// `HttpServer`（含 WS 升级）+ 摘掉 flutter_test 的 `HttpOverrides` + `tester.runAsync`
// 让真 I/O 跑起来，再 `pump` 看帧。
//
// 账本路径在测试里拿不到数据根（握手私有无 setter），故用
// `MessagePanel.debugUsageFileOverride`（生产恒为 null，见该字段注释）。
//
// 运行方式（项目根目录，PATH 上的 flutter 是 3.7.12，跑不了本工程）：
//   D:\app\flutter-sdk-3.47.5\flutter\bin\flutter.bat test test/message_panel_usage_calls_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/io/api_service.dart';
import 'package:tree/io/websocket_service.dart';
import 'package:tree/ui/models/agent.dart';
import 'package:tree/ui/widgets/message_panel.dart';
import 'package:tree/ui/widgets/session_picker.dart';

/// 假核心：会话列表 + 空的会话历史 + WS 升级（并记住连接，供测试往里推帧）。
class _FakeCore {
  _FakeCore._(this._http);

  final HttpServer _http;

  /// 已连上来的 WS（面板自己的那一条）。
  final List<WebSocket> sockets = <WebSocket>[];

  /// `GET /api/agents/{id}/sessions` 要回的会话列表。
  List<Map<String, dynamic>> sessions = <Map<String, dynamic>>[
    <String, dynamic>{
      'session_id': 'session_default',
      'title': '默认会话',
      'message_count': 1,
    },
  ];

  static Future<_FakeCore> start() async {
    final HttpServer http = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _FakeCore core = _FakeCore._(http);
    http.listen(core._handle);
    return core;
  }

  String get baseUrl => 'http://127.0.0.1:${_http.port}';

  Future<void> close() => _http.close(force: true);

  /// 往每条已连上来的连接推一帧（面板据此走 `_handleIncomingMessage`）。
  void push(Map<String, dynamic> frame) {
    final String text = jsonEncode(frame);
    for (final WebSocket socket in sockets) {
      socket.add(text);
    }
  }

  Future<void> _handle(HttpRequest request) async {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      final WebSocket socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen(
        (dynamic _) {},
        onError: (Object _) {},
        cancelOnError: true,
      );
      return;
    }
    final String path = Uri.decodeComponent(request.uri.path);
    Map<String, dynamic> payload = <String, dynamic>{'success': true};
    if (path.endsWith('/sessions')) {
      payload = <String, dynamic>{'agent_id': 'a1', 'sessions': sessions};
    } else if (path.contains('/conversations/')) {
      // 一页空历史：本测试只关心用量列表，不需要消息（窗口逻辑另有专项测试）
      payload = <String, dynamic>{
        'agent_id': 'a1',
        'session_id':
            request.uri.queryParameters['session_id'] ?? 'session_default',
        'messages': <Map<String, dynamic>>[],
        'total': 0,
        'offset': 0,
        'has_more': false,
      };
    }
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(payload));
    await request.response.close();
  }
}

void main() {
  late _FakeCore core;
  late Directory tempDir;

  setUp(() async {
    // flutter_test 默认装了 HttpOverrides（请求被拦成 400）：这里要真打本机假核心
    HttpOverrides.global = null;
    core = await _FakeCore.start();
    ApiService.baseUrl = core.baseUrl;
    ApiService.setToken('test-token');
    // 面板的 WS 走 WebSocketService 自己的 baseUrl（main.dart 里由握手设置）
    WebSocketService.baseUrl = core.baseUrl.replaceFirst('http://', 'ws://');
    tempDir = Directory.systemTemp.createTempSync('tree_usage_panel_');
  });

  tearDown(() async {
    MessagePanel.debugUsageFileOverride = null;
    await core.close();
    ApiService.setToken(null);
    ApiService.baseUrl = 'http://127.0.0.1:0';
    WebSocketService.baseUrl = 'ws://127.0.0.1:0';
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Agent agent() => Agent(id: 'a1', name: 'A1', type: 'normal', lastMessage: '');

  /// 让真 socket 上的请求飞完（fake async 不会推进真实 I/O），并各推进一帧。
  Future<void> flyIO(WidgetTester tester, {int rounds = 8}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
  }

  Future<void> pumpPanel(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MessagePanel(selectedAgent: agent())),
      ),
    );
    // 会话列表 + 一页历史 + 一次账本读取：多飞几轮再断言
    await flyIO(tester, rounds: 10);
  }

  /// 收尾：烧掉面板里 5s 兜底 / 心跳之类的定时器，再摘掉组件（不留 pending timer）。
  Future<void> closePanel(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  }

  /// 实时帧形态的 `usage`（没有 source / at / duration_ms —— 这是核心的帧口径）。
  Map<String, dynamic> usageFrame({String? sessionId, bool estimated = true}) =>
      <String, dynamic>{
        'type': 'msg_usage',
        'agent_id': 'a1',
        'session_id': sessionId ?? 'session_default',
        // 工具循环里推的 usage 常常没有对应文本消息（id 是工具卡片）
        'id': 'tool_1',
        'usage': <String, dynamic>{
          'prompt_tokens': 1024,
          'completion_tokens': 512,
          'total_tokens': 1536,
          'max_tokens': 8192,
          'cached_tokens': 256,
          'estimated': estimated,
          'trimmed_messages': 0,
        },
      };

  /// 账本的一行（`usage.jsonl` 的固定 8 键）。
  String usageLine({
    required String at,
    required String source,
    String model = 'claude-opus-4.7',
    int prompt = 0,
    int? cached,
    int completion = 0,
    bool estimated = false,
    int? durationMs,
  }) => jsonEncode(<String, dynamic>{
    'at': at,
    'source': source,
    'model': model,
    'prompt_tokens': prompt,
    'cached_tokens': cached,
    'completion_tokens': completion,
    'estimated': estimated,
    'duration_ms': durationMs,
  });

  /// 写一份真账本到临时目录（`readRecent` 走真文件 I/O）。
  String writeUsageFile(List<String> lines) {
    final String path = '${tempDir.path}${Platform.pathSeparator}usage.jsonl';
    File(path).writeAsStringSync('${lines.join('\n')}\n');
    return path;
  }

  /// 展开「本轮调用列表」（点标题那一行）。
  Future<void> expand(WidgetTester tester) async {
    await tester.tap(find.textContaining('本轮调用列表'));
    await tester.pumpAndSettle();
  }

  testWidgets('① 实时帧 → 列表出现对应行（来源/输入/输出/耗时/估算）', (WidgetTester tester) async {
    await pumpPanel(tester);

    // 前置事实：还没调用过，折叠头显示 0 次
    expect(find.text('本轮调用列表（0 次）'), findsOneWidget);

    core.push(usageFrame());
    await flyIO(tester);

    // 计数更新（这一轮这条将近乎实时地反映出来）
    expect(find.text('本轮调用列表（1 次）'), findsOneWidget);

    await expand(tester);

    // 来源（实时帧没有 source ⇒ 对话）/ 输入 / 缓存命中 / 输出
    expect(find.text('对话'), findsOneWidget);
    expect(find.text('1,024'), findsOneWidget);
    expect(find.text('256'), findsOneWidget);
    expect(find.text('512'), findsOneWidget);
    // 实时帧没有 duration_ms ⇒ `—`（不是 0）
    expect(find.text('—'), findsOneWidget);
    // `estimated: true` ⇒ 明确标"估算"，别把估算值当实测
    expect(find.text('估算'), findsOneWidget);

    await closePanel(tester);
  });

  testWidgets('④ 折叠态默认不渲染正文（来了实时帧也不自动展开）', (WidgetTester tester) async {
    await pumpPanel(tester);
    core.push(usageFrame());
    await flyIO(tester);

    // 标题在、正文不在：面板折叠时不建子树
    expect(find.text('本轮调用列表（1 次）'), findsOneWidget);
    expect(find.text('来源'), findsNothing);
    expect(find.text('1,024'), findsNothing);
    expect(find.text('暂无调用记录'), findsNothing);

    // 点一下才出现
    await expand(tester);
    expect(find.text('来源'), findsOneWidget);

    await closePanel(tester);
  });

  testWidgets('② 历史读成功：账本里的调用补进列表（来源/耗时/估算都在）', (WidgetTester tester) async {
    final String path = writeUsageFile(<String>[
      usageLine(
        at: '2026-10-03T10:00:00Z',
        source: 'compact',
        prompt: 12000,
        cached: null,
        completion: 800,
        durationMs: 1830,
      ),
      usageLine(
        at: '2026-10-03T10:05:00Z',
        source: 'turn',
        prompt: 4096,
        cached: 1024,
        completion: 128,
        estimated: true,
        durationMs: 832,
      ),
    ]);
    MessagePanel.debugUsageFileOverride = path;

    await pumpPanel(tester);

    expect(find.text('本轮调用列表（2 次）'), findsOneWidget);
    // 读到了账本 ⇒ 不该出现"读不到"的说明行
    expect(find.textContaining('还没有 usage.jsonl'), findsNothing);

    await expand(tester);
    expect(find.text('内置压缩'), findsOneWidget);
    expect(find.text('12,000'), findsOneWidget);
    expect(find.text('1.8s'), findsOneWidget);
    expect(find.text('对话'), findsOneWidget);
    expect(find.text('4,096'), findsOneWidget);
    expect(find.text('832ms'), findsOneWidget);
    // 第一条 cached_tokens 显式 null ⇒ `—`（不是 0）；第二条的耗时也有值
    expect(find.text('—'), findsOneWidget);
    expect(find.text('估算'), findsOneWidget);

    await closePanel(tester);
  });

  testWidgets('② 历史读失败：给可读空态（不是"暂无调用记录"），且不抛', (WidgetTester tester) async {
    MessagePanel.debugUsageFileOverride =
        '${tempDir.path}${Platform.pathSeparator}nope-usage.jsonl';

    await pumpPanel(tester);

    // 一条调用都没有 ⇒ 折叠头 0 次 + 一句人话说明为什么读不到
    expect(find.text('本轮调用列表（0 次）'), findsOneWidget);
    expect(find.textContaining('还没有 usage.jsonl'), findsOneWidget);
    expect(find.textContaining('nope-usage.jsonl'), findsOneWidget);
    // 说明行与面板标题同时在场：读不到 ≠ 没调用过
    expect(find.text('本轮调用列表（0 次）'), findsOneWidget);

    await closePanel(tester);
  });

  testWidgets('③ 切换会话：逐调用列表清空（旧会话的行不许留下）', (WidgetTester tester) async {
    core.sessions = <Map<String, dynamic>>[
      <String, dynamic>{
        'session_id': 'session_default',
        'title': '默认会话',
        'message_count': 1,
      },
      <String, dynamic>{
        'session_id': 'session_two',
        'title': '第二个会话',
        'message_count': 0,
      },
    ];
    // 新会话的账本不存在：切过去之后列表必须是空的（而不是把旧行留着）
    MessagePanel.debugUsageFileOverride =
        '${tempDir.path}${Platform.pathSeparator}nope-usage.jsonl';

    await pumpPanel(tester);
    core.push(usageFrame());
    await flyIO(tester);
    await expand(tester);
    expect(find.text('1,024'), findsOneWidget, reason: '前置事实：当前会话已有 1 行');

    // 经会话选择器真正切到另一个会话（走 _handleSelectSession）
    await tester.tap(find.byType(SessionPicker));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第二个会话'));
    await flyIO(tester, rounds: 6);

    expect(find.text('本轮调用列表（0 次）'), findsOneWidget);
    expect(find.text('1,024'), findsNothing, reason: '旧会话的行必须被清掉');
    expect(find.text('暂无调用记录'), findsOneWidget, reason: '展开状态保持，但内容已空');

    await closePanel(tester);
  });

  testWidgets('⑤ 同一次调用的两份读数（msg_usage + msg_end）只算一次', (
    WidgetTester tester,
  ) async {
    await pumpPanel(tester);

    // 工具循环里先来一条没有对应文本消息的 msg_usage（会话粒度推进）
    core.push(usageFrame());
    await flyIO(tester);
    // 再来一段文本消息，它的 msg_end 里带着**同一份** usage
    core.push(<String, dynamic>{
      'type': 'msg_start',
      'id': 'm1',
      'agent_id': 'a1',
      'session_id': 'session_default',
      'kind': 'text',
    });
    await flyIO(tester);
    core.push(<String, dynamic>{
      'type': 'msg_end',
      'id': 'm1',
      'agent_id': 'a1',
      'session_id': 'session_default',
      'usage': usageFrame()['usage'],
    });
    await flyIO(tester);

    expect(
      find.text('本轮调用列表（1 次）'),
      findsOneWidget,
      reason: '两份读数描述的是同一次调用，不该数成两次',
    );
    await expand(tester);
    expect(find.text('来源'), findsOneWidget);

    await closePanel(tester);
  });

  testWidgets('⑥ 实时帧与账本孪生 ⇒ 合成一行，并补全账本才有的耗时', (WidgetTester tester) async {
    // 账本里已经有这次调用（带 at / duration_ms），随后这条帧又被重播回来
    final String path = writeUsageFile(<String>[
      usageLine(
        at: '2026-10-03T10:00:00Z',
        source: 'turn',
        model: 'claude-opus-4.7',
        prompt: 1024,
        cached: 256,
        completion: 512,
        durationMs: 832,
      ),
    ]);
    MessagePanel.debugUsageFileOverride = path;

    await pumpPanel(tester);
    expect(find.text('本轮调用列表（1 次）'), findsOneWidget);

    core.push(usageFrame());
    await flyIO(tester);

    expect(
      find.text('本轮调用列表（1 次）'),
      findsOneWidget,
      reason: '账本行 + 同一次调用的实时帧 = 一行（实时帧没有 at，靠来源/输入/输出认孪生）',
    );
    await expand(tester);
    expect(find.text('832ms'), findsOneWidget, reason: '耗时从账本那份补上（实时帧没有）');
    expect(find.text('—'), findsNothing);

    await closePanel(tester);
  });
}
