// 切 agent 的三个实测症状（用户 2026-10-03 口径）的回归测试：
//
// ① **不许闪"默认背景"空态**：切换/首载期间，历史还没回来时不许渲染欢迎空态
//    （空态的 §TREE§ 字标 +「你好，欢迎使用」，见 WelcomeMark）；只有"确实加载完
//    且真的没有消息"才显示空态。
//    切换期间窗口里也不许出现内容——尤其**不许把上一个 agent 的响应塞进新窗口**
//    （各个 agent 的默认会话 id 都是 `session_default`，只比 session 是挡不住的）。
// ② **首帧即底部**：历史到位后**第一个含内容的帧**就已经是完整的末尾一页、且已经在
//    底部；不许"先装进零碎几格/别人的页，再在下一帧跳到底"（用户看得见那一下滚动）。
// ③ **两跳 HTTP 并发**：会话列表（`GET /api/agents/{id}/sessions`）与历史页
//    （`GET /api/conversations/{id}?limit=…`）必须并发发出——历史请求要在**会话响应
//    回来之前**就已经上路（旧实现是串行：历史只能等会话列表回来）。
// ④ **旁路读数延后**：切 agent 的关键路径只有那两跳 HTTP；账本（`usage.jsonl`）这类
//    "需要才查"的读数不许抢在历史页之前（观测钩子见 `MessagePanel.debugUsageReadObserver`）。
//
// 骨架与 `test/message_panel_window_work_test.dart` 同一套路：真 socket + 假核心
// （本机 HttpServer，含 WS 升级）+ 摘掉 flutter_test 的 HttpOverrides +
// `tester.runAsync` 让真 I/O 跑起来，再 `pump` 看帧。两个端点各有**闸门**
// （sessions / history），这样"请求到达顺序"与"哪一帧落地"由测试说了算。
//
// 运行（项目根目录；PATH 上的 flutter 太旧）：
//   D:\app\flutter-sdk-3.47.5\flutter\bin\flutter.bat test test/message_panel_agent_switch_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/io/api_service.dart';
import 'package:tree/io/websocket_service.dart';
import 'package:tree/ui/models/agent.dart';
import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/widgets/message_list.dart';
import 'package:tree/ui/widgets/message_panel.dart';
import 'package:tree/ui/widgets/welcome_mark.dart';

/// 假核心：会话列表 + 历史分页（两跳各有闸门）+ WS 升级。
class _FakeCore {
  _FakeCore._(this._http);

  final HttpServer _http;

  /// 会话一共多少条（真机规模：几千条）
  int total = 3000;

  /// 一页多少条（= 面板的 `_historyPageSize`）
  /// 假核心的一页大小 = 面板的窗口半径（51）：请求带的 limit 优先，这里只做兜底/上限。
  int pageSize = 51;

  /// **到达顺序**的请求日志（`req sessions a2` / `resp history a2` …）
  final List<String> log = <String>[];

  /// 历史请求的查询串（按到达顺序）
  final List<String> historyQueries = <String>[];

  bool _sessionsGateOpen = true;
  bool _historyGateOpen = true;
  final List<Completer<void>> _sessionsWaiters = <Completer<void>>[];
  final List<Completer<void>> _historyWaiters = <Completer<void>>[];

  void closeSessionsGate() => _sessionsGateOpen = false;

  void openSessionsGate() {
    _sessionsGateOpen = true;
    for (final Completer<void> waiter in _sessionsWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _sessionsWaiters.clear();
  }

  void closeHistoryGate() => _historyGateOpen = false;

  void openHistoryGate() {
    _historyGateOpen = true;
    for (final Completer<void> waiter in _historyWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _historyWaiters.clear();
  }

  Future<void> _through(bool open, List<Completer<void>> waiters) async {
    if (open) return;
    final Completer<void> waiter = Completer<void>();
    waiters.add(waiter);
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
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      final WebSocket socket = await WebSocketTransformer.upgrade(request);
      socket.listen((dynamic _) {}, onError: (Object _) {}, cancelOnError: true);
      return;
    }
    final Map<String, String> q = request.uri.queryParameters;
    Map<String, dynamic> payload = <String, dynamic>{'success': true};
    if (path.endsWith('/sessions')) {
      // /api/agents/{id}/sessions
      final String agentId = path.split('/')[3];
      log.add('req sessions $agentId');
      await _through(_sessionsGateOpen, _sessionsWaiters);
      log.add('resp sessions $agentId');
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
      log.add('req history $agentId');
      historyQueries.add(request.uri.query);
      await _through(_historyGateOpen, _historyWaiters);
      log.add('resp history $agentId');
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
    tempDir = Directory.systemTemp.createTempSync('tree_switch_panel_');
    // 账本口径：读到测试自己的临时文件（不许碰真实数据根；见 debugUsageFileOverride）
    final File ledger = File('${tempDir.path}${Platform.pathSeparator}usage.jsonl');
    ledger.writeAsStringSync(
      '${jsonEncode(<String, dynamic>{
        'agent_id': 'a2',
        'session_id': 'session_default',
        'source': 'agent',
        'input_tokens': 11,
        'output_tokens': 22,
        'at': '2026-10-03T10:00:00.000',
      })}\n',
    );
    MessagePanel.debugUsageFileOverride = ledger.path;
  });

  tearDown(() async {
    MessagePanel.debugUsageFileOverride = null;
    MessagePanel.debugUsageReadObserver = null;
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
    core.openSessionsGate();
    core.openHistoryGate();
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  }

  Future<void> pumpAgent(WidgetTester tester, String id, {int rounds = 10}) async {
    await tester.pumpWidget(panel(id));
    await flyIO(tester, rounds: rounds);
  }

  MessageList listOf(WidgetTester tester) =>
      tester.widget<MessageList>(find.byType(MessageList));

  bool welcomeShown(WidgetTester tester) =>
      find.byType(WelcomeMark).evaluate().isNotEmpty;

  Set<int> loadedOf(WidgetTester tester) {
    final List<ChatMessage?> slots = listOf(tester).slots;
    return <int>{
      for (int i = 0; i < slots.length; i++)
        if (slots[i] != null) i,
    };
  }

  ScrollPosition? positionOf(WidgetTester tester) {
    // 注意：**不能**先挂 `.first` 再判空——`_FirstFinderMixin` 在 evaluate() 时就取
    // 第一个，空集合会直接抛 StateError（加载态里本来就没有 ListView）。
    final Finder list = find.descendant(
      of: find.byType(MessageList),
      matching: find.byType(ListView),
    );
    if (list.evaluate().isEmpty) return null;
    final Finder scrollable =
        find.descendant(of: list, matching: find.byType(Scrollable));
    if (scrollable.evaluate().isEmpty) return null;
    return tester.state<ScrollableState>(scrollable.first).position;
  }

  /// 这一趟**真被布局过**的子项下标区间（渲染树里的权威口径）
  ({int first, int last})? laidOutRange(WidgetTester tester) {
    for (final RenderSliverList sliver
        in tester.allRenderObjects.whereType<RenderSliverList>()) {
      int? first;
      int? last;
      RenderBox? item = sliver.firstChild;
      while (item != null) {
        if (sliver.childScrollOffset(item) != null) {
          final ParentData? data = item.parentData;
          if (data is SliverMultiBoxAdaptorParentData && data.index != null) {
            first ??= data.index;
            last = data.index;
          }
        }
        item = sliver.childAfter(item);
      }
      if (first != null && last != null) return (first: first, last: last);
    }
    return null;
  }

  /// 逐帧记录（失败时的诊断材料）
  String frameLine(WidgetTester tester, int frame) {
    final Set<int> loaded = loadedOf(tester);
    final ScrollPosition? pos = positionOf(tester);
    final ({int first, int last})? range = laidOutRange(tester);
    return 'f$frame loaded=${loaded.length} '
        'win=[${loaded.isEmpty ? '-' : '${loaded.reduce((a, b) => a < b ? a : b)}..${loaded.reduce((a, b) => a > b ? a : b)}'}] '
        'slots=${listOf(tester).slots.length} '
        'pixels=${pos == null ? '-' : pos.pixels.toStringAsFixed(1)} '
        'max=${pos == null ? '-' : pos.maxScrollExtent.toStringAsFixed(1)} '
        'laidOut=${range == null ? '-' : '${range.first}..${range.last}'} '
        'welcome=${welcomeShown(tester)}';
  }

  /// 走一帧真 I/O + 一次 pump，返回这一帧的快照
  Future<String> step(WidgetTester tester, int frame) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
    return frameLine(tester, frame);
  }

  testWidgets('① 切 agent 期间不许闪"默认背景"空态，也不许把上一个 agent 的内容塞进来',
      (WidgetTester tester) async {
    await pumpAgent(tester, 'a1');
    expect(welcomeShown(tester), isFalse, reason: 'a1 载入后不该有空态');

    // 切到 a2：两跳都闸住（"历史响应还没回来"的那一段）
    core.closeSessionsGate();
    core.closeHistoryGate();
    await tester.pumpWidget(panel('a2'));
    final List<String> frames = <String>[];
    for (int frame = 0; frame < 4; frame++) {
      frames.add(await step(tester, frame));
      expect(welcomeShown(tester), isFalse,
          reason: '切换期间渲染了"默认背景"空态（用户 2026-10-03 症状 1）：\n'
              '${frames.join('\n')}');
      expect(loadedOf(tester), isEmpty,
          reason: '切换期间窗口里不许有内容——尤其不许把上一个 agent 的响应'
              '塞进新窗口（只比 session_id 挡不住：两边都是 session_default）：\n'
              '${frames.join('\n')}');
    }

    // 放开两跳：内容到位后既不许有空态，也不许停在加载态
    core.openSessionsGate();
    core.openHistoryGate();
    await flyIO(tester, rounds: 12);
    expect(loadedOf(tester).length, greaterThanOrEqualTo(core.pageSize),
        reason: '历史到位后窗口里应当是末尾一页：\n${frameLine(tester, 99)}');
    expect(welcomeShown(tester), isFalse, reason: '有内容时不该显示空态');
    expect(listOf(tester).loading, isFalse, reason: '内容到位后必须摘掉加载态');
    await closePanel(tester);
  });

  testWidgets('② 历史到位后第一个含内容的帧：完整末尾一页 + 已经在底部',
      (WidgetTester tester) async {
    await pumpAgent(tester, 'a1');

    core.closeSessionsGate();
    core.closeHistoryGate();
    await tester.pumpWidget(panel('a2'));
    await flyIO(tester, rounds: 4);

    // 放开两跳，逐帧找"第一个含内容的帧"
    core.openSessionsGate();
    core.openHistoryGate();
    final List<String> frames = <String>[];
    int? firstContent;
    for (int frame = 0; frame < 14 && firstContent == null; frame++) {
      frames.add(await step(tester, frame));
      if (loadedOf(tester).isNotEmpty) firstContent = frame;
    }
    expect(firstContent, isNotNull,
        reason: '历史一直没到位：\n${frames.join('\n')}');

    final Set<int> loaded = loadedOf(tester);
    final ScrollPosition? pos = positionOf(tester);
    // ① 内容必须是**完整的末尾一页**（不是零碎几格、也不是别人的页）
    expect(loaded.length, greaterThanOrEqualTo(core.pageSize),
        reason: '第一个含内容的帧里只装进了 ${loaded.length} 条（应当是末尾一页 '
            '${core.pageSize} 条）——用户会看到"先零碎铺一点，再跳到底"：\n'
            '${frames.join('\n')}');
    expect(loaded.contains(core.total - 1), isTrue,
        reason: '第一个含内容的帧里没有末尾那一条：\n${frames.join('\n')}');
    // ② 这一帧就已经在底部（不是"先在顶部再跳"）
    expect(pos, isNotNull, reason: '有内容却没有列表：\n${frames.join('\n')}');
    expect((pos!.pixels - pos.maxScrollExtent).abs(), lessThan(1.0),
        reason: '第一个含内容的帧不在底部（pixels=${pos.pixels} '
            'max=${pos.maxScrollExtent}）：\n${frames.join('\n')}');
    final ({int first, int last})? range = laidOutRange(tester);
    expect(range?.last, core.total - 1,
        reason: '转眼看到的不是末尾那一条：\n${frames.join('\n')}');

    // ③ 之后也不许再"整批换一次内容"（那会是一次可见的位移）
    for (int frame = 0; frame < 4; frame++) {
      frames.add(await step(tester, firstContent! + 1 + frame));
      final ScrollPosition? p = positionOf(tester);
      expect(p, isNotNull);
      expect((p!.pixels - p.maxScrollExtent).abs(), lessThan(1.0),
          reason: '内容到位后的后续帧离开了底部：\n${frames.join('\n')}');
    }
    await closePanel(tester);
  });

  testWidgets('③ 切 agent：会话列表与历史页两跳 HTTP 并发发出（历史不等会话）',
      (WidgetTester tester) async {
    await pumpAgent(tester, 'a1');
    core.log.clear();
    core.historyQueries.clear();

    // 只闸会话响应：历史请求若并发，它照样会上路
    core.closeSessionsGate();
    await tester.pumpWidget(panel('a2'));
    await flyIO(tester, rounds: 4);

    expect(core.log.contains('req sessions a2'), isTrue,
        reason: '切换后会话列表请求应当已发出：${core.log}');
    expect(core.log.contains('resp sessions a2'), isFalse,
        reason: '测试前提：会话响应还闸着：${core.log}');
    expect(core.historyQueries, isNotEmpty,
        reason: '历史页请求必须与会话列表**并发**发出（现在要等会话响应回来才发，'
            '于是切 agent 至少串行等两跳）：${core.log}');
    expect(core.log.any((String e) => e == 'req history a2'), isTrue,
        reason: '历史请求应当就是新 agent 的：${core.log}');

    // 放开后内容正常到位（并且**没有**多余的重复末尾页请求）
    core.openSessionsGate();
    await flyIO(tester, rounds: 12);
    expect(loadedOf(tester).length, greaterThanOrEqualTo(core.pageSize),
        reason: '放开闸门后历史没到位：${core.log}');
    final List<String> tailQueries = core.historyQueries
        .where((String q) => !q.contains('from=') && !q.contains('at='))
        .toList();
    expect(tailQueries.length, 1,
        reason: '同一份末尾页只该拉一次（并发预取到位的会话不该被重复拉；'
            '视口上方那条 from=… 的补页是正常的懒加载，不算重复）：'
            '${core.historyQueries}');
    await closePanel(tester);
  });

  testWidgets('④ 切 agent 时账本（usage.jsonl）读数不抢在历史页之前',
      (WidgetTester tester) async {
    final List<String> reads = <String>[];
    MessagePanel.debugUsageReadObserver = (String a, String s) {
      reads.add('read $a::$s');
    };
    await pumpAgent(tester, 'a1');
    reads.clear();
    core.log.clear();

    // 闸住历史：会话列表放行（否则连会话都没选出来）
    core.closeHistoryGate();
    await tester.pumpWidget(panel('a2'));
    await flyIO(tester, rounds: 4);
    expect(core.log.contains('resp history a2'), isFalse,
        reason: '测试前提：历史响应还闸着：${core.log}');
    expect(reads, isEmpty,
        reason: '历史页还没回来就先读了账本——这是抢在关键路径前面的旁路读数：$reads');

    core.openHistoryGate();
    await flyIO(tester, rounds: 10);
    expect(loadedOf(tester).length, greaterThanOrEqualTo(core.pageSize),
        reason: '历史没到位：${core.log}');
    expect(reads, isNotEmpty, reason: '末尾页落地后要把账本读数补上');
    await closePanel(tester);
  });
}
