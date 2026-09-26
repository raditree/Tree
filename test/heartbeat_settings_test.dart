// 心跳判活参数（M9 规约 1.1 收尾）：前端 API 往返 + 设置页两个数字输入。
//
// 用一个假的"核心进程"（本机 HttpServer）验证三件事：
// 1. ApiService 打到的是协议声明的路径，且是**部分更新**语义（只发改到的字段）；
// 2. 设置页把后端返回的值 / 区间 / 判活窗口显示出来，点「应用」时两个字段**一起**
//    提交（I×N 是一个整体，分两次写会经过非法中间态）；
// 3. 前端与后端同口径预夹取：判活窗口 I×N 必须严格大于前端固定的 10s WS 心跳
//    （lib/io/websocket_service.dart，本页不可调），不足时抬高 I 并给出可读原因。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tree/io/api_service.dart';
import 'package:tree/ui/pages/settings_page.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// 假核心：只实现心跳判活端点，记录收到的全部请求。
///
/// 其它路径一律 404 —— 设置页的其它卡片（模型列表、消息切入）会因此走到"加载失败"
/// 分支，但那些分支都自带兜底，不影响本文件要断言的控件。
class _FakeCore {
  _FakeCore._(this._http);

  final HttpServer _http;

  /// 收到的请求（方法 / 路径 / 请求体），按时间顺序。
  final List<({String method, String path, Map<String, dynamic> body})>
  requests = <({String method, String path, Map<String, dynamic> body})>[];

  int interval = 10;
  int limit = 3;

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

  Future<void> _handle(HttpRequest request) async {
    final String raw = await utf8.decoder.bind(request).join();
    final Map<String, dynamic> body = raw.trim().isEmpty
        ? <String, dynamic>{}
        : jsonDecode(raw) as Map<String, dynamic>;
    requests.add((method: request.method, path: request.uri.path, body: body));

    if (request.uri.path != ApiPaths.settingsHeartbeatInterval) {
      request.response.statusCode = 404;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(<String, dynamic>{'detail': '未知接口'}));
      await request.response.close();
      return;
    }
    if (request.method != 'GET') {
      interval = (body['heartbeat_interval'] as num?)?.toInt() ?? interval;
      limit = (body['missed_heartbeat_limit'] as num?)?.toInt() ?? limit;
    }
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode(<String, dynamic>{
        'heartbeat_interval': interval,
        'missed_heartbeat_limit': limit,
        'min': 1,
        'max': 600,
        'heartbeat_interval_min': 1,
        'heartbeat_interval_max': 600,
        'missed_heartbeat_limit_min': 1,
        'missed_heartbeat_limit_max': 60,
        'window_seconds': interval * limit,
        'min_window_seconds': 10,
        'live_interval_seconds': interval,
        'live_miss_limit': limit,
      }),
    );
    await request.response.close();
  }
}

/// 反复 pump 直到条件成立。
///
/// 页面里的加载 / 保存是**真实 HTTP 往返**：pumpAndSettle 可能在响应到达之前就
/// 返回（那一刻没有待调度的帧），所以这里显式轮询。
Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  String reason = '条件',
}) async {
  for (int i = 0; i < 300; i++) {
    if (done()) return;
    // testWidgets 默认把测试体跑在 FakeAsync 区里：**真实 socket 事件不会被送达**，
    // 光 pump 只会推进假时间。所以每次让出一小段真实时间（runAsync）把 HTTP 往返
    // 跑完，再 pump 一帧把 setState 画出来。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  fail('等待$reason 超时');
}

String _textOf(WidgetTester tester, Key key) {
  final Finder finder = find.byKey(key);
  if (finder.evaluate().isEmpty) return '';
  final TextField field = tester.widget<TextField>(finder);
  return field.controller?.text ?? '';
}

void main() {
  late _FakeCore core;

  setUp(() async {
    // flutter_test 默认给整个测试进程装了一个 HttpOverrides：任何 HTTP 请求都被
    // 拦成 400、不真的发出去。本文件要打**本机假核心**（真 socket 往返），所以这里
    // 摘掉它——否则测的就不是"前端真的会怎么发请求"了。
    HttpOverrides.global = null;
    core = await _FakeCore.start();
    ApiService.baseUrl = core.baseUrl;
    ApiService.setToken('test-token');
  });

  tearDown(() async {
    await core.close();
    ApiService.setToken(null);
    ApiService.baseUrl = 'http://127.0.0.1:0';
  });

  test('ApiService：GET 读回生效值，PATCH 只发被修改的字段', () async {
    final Map<String, dynamic> data =
        await ApiService.getHeartbeatLivenessSettings();
    expect(core.requests.single.method, 'GET');
    expect(core.requests.single.path, ApiPaths.settingsHeartbeatInterval);
    expect(data['heartbeat_interval'], 10);
    expect(data['missed_heartbeat_limit'], 3);
    expect(data['window_seconds'], 30);
    expect(data['min_window_seconds'], 10);

    final Map<String, dynamic> saved =
        await ApiService.setHeartbeatLivenessSettings(
          heartbeatIntervalSeconds: 20,
          missedHeartbeatLimit: 5,
        );
    expect(core.requests.last.method, 'PATCH');
    expect(core.requests.last.path, ApiPaths.settingsHeartbeatInterval);
    expect(core.requests.last.body, <String, dynamic>{
      'heartbeat_interval': 20,
      'missed_heartbeat_limit': 5,
    });
    expect(saved['heartbeat_interval'], 20);
    expect(saved['missed_heartbeat_limit'], 5);

    // 部分更新：只给一个字段时请求体里只有那一个键（另一个保持原值）
    await ApiService.setHeartbeatLivenessSettings(missedHeartbeatLimit: 4);
    expect(core.requests.last.body, <String, dynamic>{
      'missed_heartbeat_limit': 4,
    });
  });

  testWidgets('设置页：两个数字输入显示权威值，应用时一起提交，夹取原因可见', (WidgetTester tester) async {
    // 设置页是长列表：默认 800×600 的测试视口里"心跳判活"卡片在折叠线以下不会被
    // 构建，finder 找不到控件。把视口放大到一屏能装下整页。
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pump();

    // 权威值来自后端（默认 10s / 3 次）：等页面加载完成
    await _pumpUntil(
      tester,
      () => _textOf(tester, const Key('heartbeat-interval-input')) == '10',
      reason: '心跳参数加载',
    );
    expect(find.text('心跳判活参数'), findsOneWidget);
    expect(_textOf(tester, const Key('heartbeat-limit-input')), '3');
    expect(find.textContaining('判活窗口 30s'), findsOneWidget);

    // 5s × 2 次 = 10s ≤ 前端固定 10s 心跳 ⇒ 前端按同口径把间隔抬到 6s 再提交
    await tester.enterText(
      find.byKey(const Key('heartbeat-interval-input')),
      '5',
    );
    await tester.enterText(find.byKey(const Key('heartbeat-limit-input')), '2');
    await tester.tap(find.byKey(const Key('heartbeat-apply')));
    await _pumpUntil(
      tester,
      () => core.requests.where((r) => r.method == 'PATCH').isNotEmpty,
      reason: '保存请求',
    );
    final ({String method, String path, Map<String, dynamic> body}) patch = core
        .requests
        .lastWhere((r) => r.method == 'PATCH');
    expect(patch.path, ApiPaths.settingsHeartbeatInterval);
    expect(patch.body, <String, dynamic>{
      'heartbeat_interval': 6,
      'missed_heartbeat_limit': 2,
    }, reason: '两个字段一起写 + 窗口不足时抬高 I（与后端同口径）');
    await _pumpUntil(
      tester,
      () => find.textContaining('已按安全下限夹取').evaluate().isNotEmpty,
      reason: '夹取原因显示',
    );

    // 换成合法组合：说明消失，输入框回填后端生效值
    await tester.enterText(
      find.byKey(const Key('heartbeat-interval-input')),
      '4',
    );
    await tester.enterText(find.byKey(const Key('heartbeat-limit-input')), '5');
    await tester.tap(find.byKey(const Key('heartbeat-apply')));
    await _pumpUntil(
      tester,
      () =>
          core.requests.where((r) => r.method == 'PATCH').length >= 2 &&
          _textOf(tester, const Key('heartbeat-interval-input')) == '4',
      reason: '第二次保存',
    );
    expect(core.requests.last.body, <String, dynamic>{
      'heartbeat_interval': 4,
      'missed_heartbeat_limit': 5,
    });
    expect(find.textContaining('已按安全下限夹取'), findsNothing);
    expect(find.textContaining('判活窗口 20s'), findsOneWidget);
  });
}
