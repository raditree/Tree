// 在途段（正在流式的思考/正文、正在跑的工具卡）**跨 agent 切换存活**的回归测试
// （用户 2026-10-11 报告：核心正在推送工具调用/思考，重切 agent 后该事件消失）。
//
// 根因口径：核心"段关闭即落库"（endSegment 里 msg_end 广播在前、persistSegment 在
// 后），在途段**不在 store 里**；旧实现在切走时把窗口里的在途对象直接丢弃，重切回来
// 从历史页重渲染自然没有它们，后续 msg_chunk 又被当"孤立增量"丢弃。
// 修复：_clearWindow 前把未封口消息摘进在途缓冲（按 agent::会话），增量帧按全局唯一
// id 继续写回缓冲对象，末尾页落地时把仍在途的接回窗口（见 message_panel 的
// _captureInFlight / _detachedById / _restoreInFlight）。
//
// 骨架与 `test/message_panel_agent_switch_test.dart` 同一套路：真 socket + 假核心
// （本机 HttpServer，含 WS 升级，且能向客户端**推送**帧）+ 摘掉 flutter_test 的
// HttpOverrides + `tester.runAsync` 让真 I/O 跑起来。
//
// 运行（项目根目录；PATH 上的 flutter 太旧）：
//   D:\app\flutter-sdk-3.47.5\flutter\bin\flutter.bat test test/message_panel_inflight_resume_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/io/api_service.dart';
import 'package:tree/io/websocket_service.dart';
import 'package:tree/ui/models/agent.dart';
import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/widgets/message_list.dart';
import 'package:tree/ui/widgets/message_panel.dart';

/// 假核心：会话列表 + 历史分页 + WS（升级后留住连接，测试可向客户端推帧）。
class _FakeCore {
  _FakeCore._(this._http);

  final HttpServer _http;

  /// 会话一共多少条（真机规模：几千条）
  int total = 3000;

  /// 一页多少条（= 面板的窗口半径 51）
  int pageSize = 51;

  final List<WebSocket> _sockets = <WebSocket>[];

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

  /// 向所有已连接的客户端广播一帧（真核心的 hub 口径）。
  void send(Map<String, dynamic> frame) {
    final String encoded = jsonEncode(frame);
    for (final WebSocket socket in _sockets) {
      socket.add(encoded);
    }
  }

  static Map<String, dynamic> _message(int index) => <String, dynamic>{
        'id': 'm$index',
        'role': 'agent',
        'content': '第 $index 条',
        'timestamp': DateTime(2026, 1, 1).millisecondsSinceEpoch,
      };

  Future<void> _handle(HttpRequest request) async {
    final String path = Uri.decodeComponent(request.uri.path);
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      final WebSocket socket = await WebSocketTransformer.upgrade(request);
      _sockets.add(socket);
      socket.listen(
        (dynamic _) {},
        onError: (Object _) {},
        onDone: () => _sockets.remove(socket),
        cancelOnError: true,
      );
      return;
    }
    final Map<String, String> q = request.uri.queryParameters;
    Map<String, dynamic> payload = <String, dynamic>{'success': true};
    if (path.endsWith('/sessions')) {
      final String agentId = path.split('/')[3];
      payload = <String, dynamic>{
        'agent_id': agentId,
        'sessions': <Map<String, dynamic>>[
          <String, dynamic>{
            'session_id': 'session_default',
            'title': '默认会话',
            'message_count': total,
          },
        ],
      };
    } else if (path.contains('/conversations/')) {
      final String agentId = path.split('/').last;
      final int limit = int.tryParse(q['limit'] ?? '') ?? pageSize;
      final int? from = int.tryParse(q['from'] ?? '');
      final int start = (from ?? (total - limit)).clamp(0, total);
      final int count = limit.clamp(0, total - start);
      payload = <String, dynamic>{
        'agent_id': agentId,
        'session_id': q['session_id'] ?? 'session_default',
        'messages': <Map<String, dynamic>>[
          for (int i = 0; i < count; i++) _message(start + i),
        ],
        'total': total,
        'offset': start,
        'has_more': start > 0,
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
    WebSocketService.baseUrl = core.baseUrl.replaceFirst('http://', 'ws://');
    tempDir = Directory.systemTemp.createTempSync('tree_inflight_resume_');
    final File ledger = File(
      '${tempDir.path}${Platform.pathSeparator}usage.jsonl',
    );
    ledger.writeAsStringSync('');
    MessagePanel.debugUsageFileOverride = ledger.path;
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

  Agent agent(String id) =>
      Agent(id: id, name: id, type: 'normal', lastMessage: '');

  Widget panel(String agentId) =>
      MaterialApp(home: Scaffold(body: MessagePanel(selectedAgent: agent(agentId))));

  /// 让真 socket 上的请求/帧飞完，并各推进一帧。
  Future<void> flyIO(WidgetTester tester, {int rounds = 8}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
  }

  Future<void> closePanel(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  }

  MessageList listOf(WidgetTester tester) =>
      tester.widget<MessageList>(find.byType(MessageList));

  /// 按 id 在当前窗口的槽位表里找消息（找不到 = null）。
  ChatMessage? slotById(WidgetTester tester, String id) {
    for (final ChatMessage? m in listOf(tester).slots) {
      if (m?.id == id) return m;
    }
    return null;
  }

  Map<String, dynamic> envelope(String type, Map<String, dynamic> rest) =>
      <String, dynamic>{
        'type': type,
        'agent_id': 'a1',
        'session_id': 'session_default',
        ...rest,
      };

  testWidgets('在途段跨切换存活：流式思考与运行中工具卡重切回来后不消失、增量不丢',
      (WidgetTester tester) async {
    await tester.pumpWidget(panel('a1'));
    await flyIO(tester, rounds: 10);
    expect(slotById(tester, 'm2999'), isNotNull, reason: 'a1 的末尾页没到位');

    // ① a1 视角下：开一段流式思考 + 一张运行中的工具卡（核心只发帧、**不落库**）
    core.send(envelope('msg_start', <String, dynamic>{'id': 'live1', 'kind': 'thinking'}));
    core.send(envelope('msg_chunk', <String, dynamic>{'id': 'live1', 'chunk': 'A'}));
    core.send(envelope('tool_start', <String, dynamic>{
      'id': 'live2',
      'name': 'read',
      'arguments': <String, dynamic>{},
    }));
    await flyIO(tester);
    expect(slotById(tester, 'live1')?.isStreaming, isTrue,
        reason: '流式思考段应当已挂进窗口');
    expect(slotById(tester, 'live1')?.content, 'A');
    expect(slotById(tester, 'live2')?.toolRunning, isTrue,
        reason: '运行中的工具卡应当已挂进窗口');

    // ② 切去 a2：窗口清空，在途段被摘进缓冲（a2 的窗口里不许有 a1 的消息）
    await tester.pumpWidget(panel('a2'));
    await flyIO(tester, rounds: 10);
    expect(slotById(tester, 'live1'), isNull);
    expect(slotById(tester, 'live2'), isNull);

    // ③ 切走期间增量照写：a1 的 msg_chunk 不许因"当前在看 a2"被当孤立帧丢弃
    core.send(envelope('msg_chunk', <String, dynamic>{'id': 'live1', 'chunk': 'B'}));
    await flyIO(tester);

    // ④ 重切回 a1：末尾页落地后，在途段接回窗口末尾，正文连续、状态仍在
    await tester.pumpWidget(panel('a1'));
    await flyIO(tester, rounds: 12);
    final ChatMessage? back1 = slotById(tester, 'live1');
    expect(back1, isNotNull,
        reason: '流式思考段在重切回来后消失（用户 2026-10-11 报告的症状）');
    expect(back1!.content, 'AB', reason: '切换期间的增量被丢了');
    expect(back1.isStreaming, isTrue);
    final ChatMessage? back2 = slotById(tester, 'live2');
    expect(back2, isNotNull, reason: '运行中的工具卡在重切回来后消失');
    expect(back2!.toolRunning, isTrue);
    // 接回的位置：在末尾页（total=3000）之后——在途段就是最新的一截
    final List<ChatMessage?> slots = listOf(tester).slots;
    expect(slots.indexWhere((ChatMessage? m) => m?.id == 'live1'),
        greaterThan(slots.indexWhere((ChatMessage? m) => m?.id == 'm2999')));

    // ⑤ 收尾帧打进**窗口里的原对象**：封口 / 结果回填都落在界面上那条
    core.send(envelope('msg_end', <String, dynamic>{'id': 'live1'}));
    await flyIO(tester);
    expect(slotById(tester, 'live1')?.isStreaming, isFalse);
    core.send(envelope('tool_end', <String, dynamic>{
      'id': 'live2',
      'name': 'read',
      'result': 'ok',
    }));
    await flyIO(tester);
    expect(slotById(tester, 'live2')?.toolRunning, isFalse);
    expect(slotById(tester, 'live2')?.toolResult, 'ok');

    await closePanel(tester);
  });

  testWidgets('在途段在切走期间收尾：重切回来以历史页为准，缓冲不复活旧副本',
      (WidgetTester tester) async {
    await tester.pumpWidget(panel('a1'));
    await flyIO(tester, rounds: 10);

    core.send(envelope('msg_start', <String, dynamic>{'id': 'live3', 'kind': 'text'}));
    core.send(envelope('msg_chunk', <String, dynamic>{'id': 'live3', 'chunk': 'X'}));
    await flyIO(tester);
    expect(slotById(tester, 'live3')?.isStreaming, isTrue);

    // 切走 → 该段在切走期间收尾（真实核心此时已把它落库；假核心的历史页不含它，
    // 这里只验"收尾后不再被接回"的口径：对象状态正确、窗口不长出幽灵气泡）
    await tester.pumpWidget(panel('a2'));
    await flyIO(tester, rounds: 10);
    core.send(envelope('msg_end', <String, dynamic>{'id': 'live3'}));
    await flyIO(tester);

    await tester.pumpWidget(panel('a1'));
    await flyIO(tester, rounds: 12);
    expect(slotById(tester, 'live3'), isNull,
        reason: '已收尾的段以核心落库的历史页为准，不该从缓冲复活');
    expect(slotById(tester, 'm2999'), isNotNull, reason: '末尾页应正常到位');
    await closePanel(tester);
  });
}
