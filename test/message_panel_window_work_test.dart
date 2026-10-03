// 中栏面板的「补页 / 淘汰」帧级约束（A2 + A3 的**面板侧**证据）。
//
// ① **A2：补页与淘汰不背靠背同帧**
//    两者都会改内容高度（补页让视口上方/视口里长高；淘汰把远处的真消息换回
//    88px 占位槽）。挤在同一帧里，列表侧只能看到"净变化"，一次补偿里混进两种信号，
//    而且淘汰可能把补偿锚点那一格换走（实测退化成估算）。⇒ 淘汰推到补页之后的下一帧。
//    面板侧只钉「必须发出的信号」；帧级收益（淘汰独占一帧）由列表侧 N7 钉住。
//    （本文件里不做帧级观察：`_window.slots` 是原地改的，测试读到的永远是"当前内容"
//     而不是"某一帧构建时的内容"，帧归属会读成一样的。）
//
// ② **A3：补页落在视口里/视口下方时也要发补偿信号**
//    面板故意先补横跨视口顶的 `[first, gap.to)`：紧贴视口顶的那一格往往**自身就是**
//    被换掉的那一格 ⇒ 它下面已经加载的内容会被整段推走。⇒ 发 `contentShiftStamp`，
//    列表侧用实测锚点补回来（列表侧断言在 test/message_list_jitter_test.dart N5/N7）。
//
// 面板是静态 ApiService 直连核心的：这里起一个**假核心**（本机 HttpServer，含 WS 升级），
// 摘掉 flutter_test 的 HttpOverrides 让请求真发出去（与 test/file_editor_test.dart 同一套路）。
// 真 socket ⇒ 要用 `tester.runAsync` 让 I/O 真的跑起来，再 `pump` 看帧。
// 历史响应还带一道**闸门**（`closeGate`/`openGate`），这样"补页落地哪一帧"是测试说了算，
// 帧级断言不靠运气。

import 'dart:async';
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

/// 假核心：会话列表 + 历史分页（可闸门）+ WS 升级（其余端点一律 `{success:true}`）。
class _FakeCore {
  _FakeCore._(this._http);

  final HttpServer _http;

  /// 会话一共多少条（真机规模：几千条）
  int total = 3000;

  /// 一页多少条（= 面板的 `_historyPageSize`）
  int pageSize = 200;

  /// 收到的历史请求查询串（按到达顺序）
  final List<String> queries = <String>[];

  /// 历史响应闸门：关着时请求悬着，直到 [openGate]
  bool _gateOpen = true;
  final List<Completer<void>> _gateWaiters = <Completer<void>>[];

  void closeGate() => _gateOpen = false;

  void openGate() {
    _gateOpen = true;
    for (final Completer<void> waiter in _gateWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _gateWaiters.clear();
  }

  Future<void> _throughGate() async {
    if (_gateOpen) return;
    final Completer<void> waiter = Completer<void>();
    _gateWaiters.add(waiter);
    await waiter.future;
  }

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

  static Map<String, dynamic> _message(int index) => <String, dynamic>{
        'id': 'm$index',
        'role': 'agent',
        'content': '第 $index 条',
        'timestamp': DateTime(2026, 1, 1).millisecondsSinceEpoch,
      };

  Future<void> _handle(HttpRequest request) async {
    final String path = Uri.decodeComponent(request.uri.path);
    // WS：面板会连上来（连不上会走重连定时器，测试里没必要）
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      final WebSocket socket = await WebSocketTransformer.upgrade(request);
      socket.listen((dynamic _) {}, onError: (Object _) {}, cancelOnError: true);
      return;
    }
    final Map<String, String> q = request.uri.queryParameters;
    Map<String, dynamic> payload = <String, dynamic>{'success': true};
    if (path.endsWith('/sessions')) {
      payload = <String, dynamic>{
        'sessions': <Map<String, dynamic>>[
          <String, dynamic>{
            'session_id': 'session_default',
            'title': '默认会话',
            'message_count': total,
          },
        ],
      };
    } else if (path.contains('/conversations/')) {
      queries.add(request.uri.query);
      await _throughGate();
      final int limit = int.tryParse(q['limit'] ?? '') ?? pageSize;
      final int? from = int.tryParse(q['from'] ?? '');
      final int start = (from ?? (total - limit)).clamp(0, total);
      final int count = limit.clamp(0, total - start);
      payload = <String, dynamic>{
        'agent_id': 'a1',
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

  setUp(() async {
    // flutter_test 默认装了 HttpOverrides（请求被拦成 400）；这里要真打本机假核心
    HttpOverrides.global = null;
    core = await _FakeCore.start();
    ApiService.baseUrl = core.baseUrl;
    ApiService.setToken('test-token');
    // 面板的 WS 走 WebSocketService 自己的 baseUrl（main.dart 里由握手设置）
    WebSocketService.baseUrl = core.baseUrl.replaceFirst('http://', 'ws://');
  });

  tearDown(() async {
    await core.close();
    ApiService.setToken(null);
    ApiService.baseUrl = 'http://127.0.0.1:0';
    WebSocketService.baseUrl = 'ws://127.0.0.1:0';
  });

  Agent agent() => Agent(id: 'a1', name: 'A1', type: 'normal', lastMessage: '');

  /// 让真 socket 上的请求飞完（fake async 不会推进真实 I/O），并各推进一帧。
  Future<void> flyIO(WidgetTester tester, {int rounds = 6}) async {
    for (int i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump();
    }
  }

  /// 收尾：把面板里 5s 超时兜底之类的定时器烧掉，再摘掉组件（不留 pending timer）
  Future<void> closePanel(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  }

  MessageList listOf(WidgetTester tester) =>
      tester.widget<MessageList>(find.byType(MessageList));

  /// 这一帧槽位表里已加载的下标集合（补页会 +，淘汰会 -）
  Set<int> loadedOf(WidgetTester tester) {
    final List<ChatMessage?> slots = listOf(tester).slots;
    return <int>{
      for (int i = 0; i < slots.length; i++)
        if (slots[i] != null) i,
    };
  }

  ScrollPosition positionOf(WidgetTester tester) {
    final Finder list = find
        .descendant(
          of: find.byType(MessageList),
          matching: find.byType(ListView),
        )
        .first;
    return tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)).first,
        )
        .position;
  }

  Future<void> pumpPanel(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: MessagePanel(selectedAgent: agent()))),
    );
    // 会话列表 + 末尾一页历史 = 两趟真 I/O，多飞几轮再断言
    await flyIO(tester, rounds: 10);
  }

  testWidgets('前置事实：首屏只加载末尾一页（窗口化懒加载）',
      (WidgetTester tester) async {
    await pumpPanel(tester);
    final Set<int> loaded = loadedOf(tester);
    expect(loaded.length, greaterThanOrEqualTo(core.pageSize),
        reason: '首屏至少要把末尾一页拉回来，实际 ${loaded.length} 条');
    expect(loaded.contains(core.total - 1), isTrue, reason: '末尾那一条在窗口里');
    expect(core.queries.first, contains('limit=200'),
        reason: '首屏请求形状：只带 limit');
    expect(core.queries.first, isNot(contains('from=')),
        reason: '首屏问的是"末尾一页"（不带 from）');
    core.closeGate();
    await closePanel(tester);
  });

  testWidgets('A3：补页落在视口里/视口下方时，面板要发补偿信号',
      (WidgetTester tester) async {
    await pumpPanel(tester);
    core.closeGate();
    final ScrollPosition pos = positionOf(tester);

    // 视口搬到中段：缺口横跨视口顶 ⇒ 面板会补 `[first, gap.to)`（**落在视口里**）。
    pos.jumpTo(pos.maxScrollExtent * 0.7);
    await tester.pump();
    await flyIO(tester, rounds: 2);
    core.openGate();

    // 逐帧看：**补页那一帧**（有新槽位进来）里 contentShiftStamp 有没有动。
    // 只认"同一帧里既补了页、又发了这个信号"——这样把它和"淘汰帧自带的那次信号"区分开。
    bool anyAdded = false;
    bool fillWithSignal = false;
    final List<String> log = <String>[];
    Set<int> prev = loadedOf(tester);
    for (int frame = 0; frame < 8; frame++) {
      final int shiftAtStart = listOf(tester).contentShiftStamp;
      await flyIO(tester, rounds: 1);
      final Set<int> now = loadedOf(tester);
      final int added = now.difference(prev).length;
      final MessageList w = listOf(tester);
      log.add('f$frame +$added loaded=${now.length} '
          'pad=${w.padAboveStamp} shift=${w.contentShiftStamp}');
      if (added > 0) anyAdded = true;
      if (added > 0 && w.contentShiftStamp != shiftAtStart) fillWithSignal = true;
      prev = now;
    }
    // ignore: avoid_print
    print('PANEL A3 逐帧: ${log.join(' | ')}');
    expect(anyAdded, isTrue, reason: '测试前提：这一趟确实补了页：$log');
    expect(fillWithSignal, isTrue,
        reason: '补页落在视口里/视口下方的那一帧没有 contentShiftStamp 变化 ⇒ '
            '用户正在读的那一段会被整段推走（A3）：$log');

    await closePanel(tester);
  });

}
