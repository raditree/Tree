import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// **零依赖 UI 的黑盒一致性套件**（MIG-UI-2 / S8）。
///
/// UI 迁入插件仓后**自持一份手写契约**（`protocol_contract.dart`），不再 import
/// 协议包。于是「核心与协议包一起改名」这种改动会让编译期门禁全绿、界面却坏了。
/// 这里补回运行时一致性：本文件把 UI 用到的线格式**一律写成字面量**，站在第三方
/// 客户端的位置驱动真核心 + 真插件进程，钉住五条链路：
///
/// 1. 流式：站点投递的 `seq` 单调、`payload` 原样、`origin_plugin_id` 可查；
/// 2. 工具卡：`tool_start` / `tool_end` 的 payload 不被核心改写（只按 topic 认帧名）；
/// 3. 终端：会话 REST 路径 / body 形状 + 输出帧走站点投递；
/// 4. 站点重连：重订必回 `reset`、`seq` 从 1 重计，另一窗口投递接续；
/// 5. 插件面板：`plugin/snapshot` / `plugin/configs` / `meta` 的字段与归属。
///
/// **本文件不得引用协议包的常量类**（最后一条用例会扫描源码钉住这一点）——
/// 否则核心改名时套件会跟着变绿，就失去意义了。
void main() {
  late Directory temp;
  late PluginBus bus;
  late CoreServer server;
  late _Client client;
  final List<_WsClient> sockets = <_WsClient>[];

  /// UI 插件的自建广播站 id（`plugin.<plugin_id>.broadcast.<name>`）。
  const String uiPluginId = 'ui.default';
  const String eventsStation = 'plugin.ui.default.broadcast.events';

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tree_ui_contract_');
    final String dartExe = Platform.resolvedExecutable.replaceAll('\\', '/');
    final String script = p
        .join(Directory.current.path, 'test', 'fixtures', 'fake_plugin.dart')
        .replaceAll('\\', '/');
    final File config = File(p.join(temp.path, 'plugins.yaml'));
    config.writeAsStringSync('''
enabled: true
plugins:
  - id: $uiPluginId
    name: 默认界面
    command: "$dartExe"
    runtime: ui
    enabled: false
  - id: tree.agent
    name: 代理插件
    command: "$dartExe"
    args:
      - "$script"
      - "--api-route"
      - "GET:/api/agents/{agentId}/messages"
      - "--api-route"
      - "POST:/api/terminal/local/sessions"
      - "--api-route"
      - "POST:/api/terminal/local/sessions/{sessionId}/input"
      - "--api-route"
      - "DELETE:/api/terminal/local/sessions/{sessionId}"
    granularity: team
    scope: {team_id: team-1, mode_key: local}
''');
    bus = PluginBus(
      configFile: config.path,
      coreVersion: 'ui-contract-e2e',
      heartbeatInterval: const Duration(seconds: 30),
    );
    await bus.start();
    server = await CoreServer.start(
      pluginBus: bus,
      dataDir: temp.path,
      enableHeartbeat: false,
    );
    // 插件启动后才申报的委派路由要刷新一趟归属表才进路由。
    await bus.ensureToolTableFresh();
    client = _Client(server);
  });

  tearDown(() async {
    for (final _WsClient socket in sockets) {
      await socket.close();
    }
    sockets.clear();
    client.close();
    await server.close();
    await bus.close();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<_WsClient> connect() async {
    final WebSocket socket = await WebSocket.connect(
      '${server.handshake.wsBaseUrl}${CoreServer.wsPath}?token=${server.token}',
    );
    final _WsClient ws = _WsClient(socket);
    sockets.add(ws);
    return ws;
  }

  void hello(_WsClient ws, {String windowId = ''}) {
    ws.send(<String, dynamic>{
      'type': 'ui.hello',
      'data': <String, dynamic>{
        'plugin_id': uiPluginId,
        'version': '1.0.0',
        'capabilities': <String>['plugin.manage'],
        if (windowId.isNotEmpty) 'window_id': windowId,
      },
    });
  }

  void subscribe(_WsClient ws, String stationId) {
    ws.send(<String, dynamic>{
      'type': 'station/subscribe',
      'data': <String, dynamic>{
        'station_id': stationId,
        'scope': <String, dynamic>{},
      },
    });
  }

  void register(_WsClient ws) {
    ws.send(<String, dynamic>{
      'type': 'station/register',
      'data': <String, dynamic>{
        'kind': 'broadcast',
        'name': 'events',
        'readme': '黑盒套件：模拟代理插件的领域事件站',
      },
    });
  }

  void trigger(_WsClient ws, String topic, Map<String, dynamic> payload) {
    ws.send(<String, dynamic>{
      'type': 'station/trigger',
      'data': <String, dynamic>{
        'station_id': eventsStation,
        'topic': topic,
        'scope': <String, dynamic>{'team_id': 'team-1', 'mode_key': 'local'},
        'payload': payload,
      },
    });
  }

  Map<String, dynamic> delivery(
    _WsClient ws,
    String state, {
    String? topic,
  }) => ws.frames.firstWhere(
    (Map<String, dynamic> frame) =>
        frame['type'] == 'station_delivery' &&
        frame['station_id'] == eventsStation &&
        frame['state'] == state &&
        (topic == null || frame['topic'] == topic),
  );

  Future<void> awaitDelivery(
    _WsClient ws,
    String state, {
    String? topic,
  }) => ws.until(
    (Map<String, dynamic> frame) =>
        frame['type'] == 'station_delivery' &&
        frame['station_id'] == eventsStation &&
        frame['state'] == state &&
        (topic == null || frame['topic'] == topic),
    reason: '$eventsStation 的 $state 帧',
  );

  /// 注册成功没有确认帧：用发现面（`meta.stations`）轮询，顺带验了面板那条路。
  Future<void> awaitStationRegistered() async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final _Res meta = await client.send('GET', '/api/meta');
      final List<dynamic> stations =
          (meta.json['stations'] as List<dynamic>?) ?? <dynamic>[];
      if (stations.any(
        (dynamic row) =>
            (row as Map<String, dynamic>)['station_id'] == eventsStation,
      )) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('自建广播站没有出现在 /api/meta.stations：$eventsStation');
  }

  test('流式：站点投递 seq 单调、payload 原样、origin 可查', () async {
    final _WsClient ws = await connect();
    hello(ws);
    register(ws);
    await awaitStationRegistered();
    subscribe(ws, eventsStation);
    // 订阅成功必回一帧点名本站的 reset（UI 靠它清旧水位）。
    await awaitDelivery(ws, 'reset');

    trigger(ws, 'tree.agent.sess-1.msg_chunk', <String, dynamic>{
      'seq': 1,
      'message_id': 'm1',
      'text': '你',
    });
    await awaitDelivery(ws, 'data', topic: 'tree.agent.sess-1.msg_chunk');
    trigger(ws, 'tree.agent.sess-1.msg_chunk', <String, dynamic>{
      'seq': 2,
      'message_id': 'm1',
      'text': '好',
    });
    await ws.until(
      (Map<String, dynamic> frame) =>
          frame['type'] == 'station_delivery' &&
          frame['state'] == 'data' &&
          frame['topic'] == 'tree.agent.sess-1.msg_chunk' &&
          (frame['payload'] as Map)['seq'] == 2,
      reason: '第二段流式增量（按载荷 seq 等，不能只等 topic）',
    );

    final List<Map<String, dynamic>> data = ws.frames
        .where(
          (Map<String, dynamic> frame) =>
              frame['type'] == 'station_delivery' &&
              frame['station_id'] == eventsStation &&
              frame['state'] == 'data',
        )
        .toList();
    expect(data, hasLength(2));
    expect(
      data.map((Map<String, dynamic> f) => f['seq']).toList(),
      <int>[1, 2],
      reason: '通道 seq 必须单调递增（UI 按它判重 / 判跳号）',
    );
    expect(
      data.every((Map<String, dynamic> f) => f['origin_plugin_id'] == uiPluginId),
      isTrue,
      reason: '投递必须带 origin_plugin_id（自环与插件来源都靠它）',
    );
    expect(
      data
          .map((Map<String, dynamic> f) => (f['payload'] as Map)['seq'])
          .toList(),
      <int>[1, 2],
      reason: '载荷里的流式序号是插件产出的，核心不得改写',
    );
    expect(
      (data.first['payload'] as Map<String, dynamic>)['text'],
      '你',
      reason: 'payload 原样透传',
    );
  });

  test('工具卡：tool_start / tool_end 的载荷原样透传（核心只按 topic 认帧名）', () async {
    final _WsClient ws = await connect();
    hello(ws);
    register(ws);
    await awaitStationRegistered();
    subscribe(ws, eventsStation);
    await awaitDelivery(ws, 'reset');

    final Map<String, dynamic> start = <String, dynamic>{
      'seq': 1,
      'tool_call_id': 'call-1',
      'tool': 'echo',
      'arguments': <String, dynamic>{'text': '你好', 'nested': <String, dynamic>{'k': 1}},
    };
    final Map<String, dynamic> end = <String, dynamic>{
      'seq': 2,
      'tool_call_id': 'call-1',
      'tool': 'echo',
      'result': 'plugin-echo: 你好',
      'is_error': false,
    };
    trigger(ws, 'tree.agent.sess-1.tool_start', start);
    await awaitDelivery(ws, 'data', topic: 'tree.agent.sess-1.tool_start');
    trigger(ws, 'tree.agent.sess-1.tool_end', end);
    await awaitDelivery(ws, 'data', topic: 'tree.agent.sess-1.tool_end');

    expect(
      delivery(ws, 'data', topic: 'tree.agent.sess-1.tool_start')['payload'],
      start,
      reason: '工具卡开始帧：字段一个都不许改（UI 直接拿它渲染）',
    );
    expect(
      delivery(ws, 'data', topic: 'tree.agent.sess-1.tool_end')['payload'],
      end,
      reason: '工具卡结束帧：result / is_error 必须原样到达',
    );
  });

  test('终端：REST 会话路径与 body 形状 + 输出帧走站点投递', () async {
    // ① 建会话：UI 的 CoreTerminalTransport 走这条 REST（query 带 agent_id）。
    final _Res open = await client.send(
      'POST',
      '/api/terminal/local/sessions?agent_id=ag1&workspace_dir=${Uri.encodeQueryComponent(p.join(temp.path, 'ws'))}',
      body: <String, dynamic>{
        'session_id': 'sess-1',
        'columns': 120,
        'rows': 32,
      },
    );
    expect(open.status, 200, reason: open.text);
    final Map<String, dynamic> envelope =
        jsonDecode(open.text) as Map<String, dynamic>;
    expect(envelope['method'], 'POST');
    expect(envelope['path'], '/api/terminal/local/sessions');
    expect(envelope['agent_id'], 'ag1', reason: 'UI 用它把租约 / 工作目录交给执行器');
    expect(
      (envelope['query'] as Map<String, dynamic>)['agent_id'],
      'ag1',
    );
    expect(
      jsonDecode(envelope['body'] as String),
      <String, dynamic>{'session_id': 'sess-1', 'columns': 120, 'rows': 32},
      reason: '会话字段名与形状是 UI ⇄ 执行器的契约',
    );

    // ② 键盘输入：bytes 是 base64，路径带 sessionId。
    final _Res input = await client.send(
      'POST',
      '/api/terminal/local/sessions/sess-1/input',
      body: <String, dynamic>{'bytes': base64Encode(<int>[104, 105])},
    );
    expect(input.status, 200, reason: input.text);
    final Map<String, dynamic> inputEnvelope =
        jsonDecode(input.text) as Map<String, dynamic>;
    expect(inputEnvelope['params'], <String, dynamic>{'sessionId': 'sess-1'});
    expect(
      jsonDecode(inputEnvelope['body'] as String),
      <String, dynamic>{'bytes': 'aGk='},
      reason: '终端输入固定 base64，避免二进制走 JSON 的编码漂移',
    );

    // ③ 输出帧：执行器自建广播站按 topic `terminal.<session>.<kind>` 推。
    final _WsClient ws = await connect();
    hello(ws);
    register(ws);
    await awaitStationRegistered();
    subscribe(ws, eventsStation);
    await awaitDelivery(ws, 'reset');
    final Map<String, dynamic> output = <String, dynamic>{
      'terminal_id': 'sess-1',
      'bytes': base64Encode(<int>[104, 105]),
    };
    trigger(ws, 'terminal.sess-1.output', output);
    await awaitDelivery(ws, 'data', topic: 'terminal.sess-1.output');
    expect(
      delivery(ws, 'data', topic: 'terminal.sess-1.output')['payload'],
      output,
      reason: 'terminal_id + bytes 原样到达（UI 用它过滤旧会话的迟到帧）',
    );

    // ④ 关闭会话：DELETE 同一条路径。
    final _Res close = await client.send(
      'DELETE',
      '/api/terminal/local/sessions/sess-1',
    );
    expect(close.status, 200, reason: close.text);
    expect(
      (jsonDecode(close.text) as Map<String, dynamic>)['params'],
      <String, dynamic>{'sessionId': 'sess-1'},
    );
  });

  test('站点重连：重订收到 reset、seq 从 1 重计，另一窗口投递接续', () async {
    // 窗口 1 常驻（持有站点归属）；窗口 2 用来模拟断线重连。
    final _WsClient w1 = await connect();
    hello(w1, windowId: 'w1');
    register(w1);
    await awaitStationRegistered();
    subscribe(w1, eventsStation);
    await awaitDelivery(w1, 'reset');

    final _WsClient w2 = await connect();
    hello(w2, windowId: 'w2');
    subscribe(w2, eventsStation);
    await awaitDelivery(w2, 'reset');
    trigger(w1, 'tree.agent.sess-1.msg_chunk', <String, dynamic>{'seq': 1});
    await awaitDelivery(w2, 'data', topic: 'tree.agent.sess-1.msg_chunk');

    // 断线：站点不能随之销毁（窗口 1 还连着）。
    await w2.close();
    sockets.remove(w2);

    final _WsClient w3 = await connect();
    hello(w3, windowId: 'w3');
    subscribe(w3, eventsStation);
    await awaitDelivery(w3, 'reset');
    expect(
      w3.frames
          .where(
            (Map<String, dynamic> f) =>
                f['type'] == 'station_delivery' && f['state'] == 'data',
          )
          .length,
      0,
      reason: '新通道从 reset 起步，不能带旧水位的残留 data',
    );

    trigger(w1, 'tree.agent.sess-1.msg_chunk', <String, dynamic>{'seq': 1});
    await awaitDelivery(w3, 'data', topic: 'tree.agent.sess-1.msg_chunk');
    expect(
      delivery(w3, 'data', topic: 'tree.agent.sess-1.msg_chunk')['seq'],
      1,
      reason: '重连后新通道的 seq 必须从 1 重计（UI 靠 reset 清水位）',
    );
  });

  test('插件面板：snapshot / configs / meta 的字段与归属', () async {
    final _WsClient ws = await connect();
    hello(ws);
    register(ws);
    await awaitStationRegistered();

    // ① 快照：面板列表 / 详情页的数据源。
    final _Res snapshot = await client.send('GET', '/api/plugin/snapshot');
    expect(snapshot.status, 200, reason: snapshot.text);
    final List<dynamic> instances =
        snapshot.json['instances'] as List<dynamic>;
    final Map<String, dynamic> agent = instances
        .cast<Map<String, dynamic>>()
        .firstWhere((Map<String, dynamic> row) => row['plugin_id'] == 'tree.agent');
    expect(agent['status'], 'registered');
    final List<dynamic> tools = agent['tools'] as List<dynamic>;
    expect(
      tools.any(
        (dynamic tool) => (tool as Map<String, dynamic>)['name'] == 'echo',
      ),
      isTrue,
      reason: '详情页按 tools 展示插件能力',
    );
    expect(
      instances.any(
        (dynamic row) =>
            (row as Map<String, dynamic>)['plugin_id'] == uiPluginId,
      ),
      isTrue,
      reason: 'UI 自己也应出现在面板里',
    );

    // ② 配置清单：编辑 / 启停页的读入口。
    final _Res configs = await client.send('GET', '/api/plugin/configs');
    expect(configs.status, 200, reason: configs.text);
    final List<dynamic> rows = configs.json['configs'] as List<dynamic>;
    expect(
      rows.map((dynamic row) => (row as Map<String, dynamic>)['id']).toSet(),
      containsAll(<String>[uiPluginId, 'tree.agent']),
    );

    // ③ 发现面：契约版本 + 插件申报的路由归属（UI 不做静态路由表）。
    final _Res meta = await client.send('GET', '/api/meta');
    expect(meta.status, 200, reason: meta.text);
    expect(
      meta.json['ui_contract'],
      '1.1',
      reason:
          'UI 自持契约的版本号：只增不改；改了这里就等于换了 UI 的编译期契约',
    );
    final List<dynamic> routes =
        (meta.json['routes'] as List<dynamic>?) ?? <dynamic>[];
    expect(
      routes,
      contains(
        allOf(
          containsPair('method', 'GET'),
          containsPair('pattern', '/api/agents/{agentId}/messages'),
          containsPair('owner', 'tree.agent'),
        ),
      ),
      reason: '插件申报的路由必须能在发现面按归属查到',
    );
    final List<dynamic> ui = (meta.json['ui'] as List<dynamic>?) ?? <dynamic>[];
    expect(
      ui.any(
        (dynamic row) =>
            (row as Map<String, dynamic>)['plugin_id'] == uiPluginId,
      ),
      isTrue,
      reason: '连接后 ui 聚合必须有当前界面',
    );
    final List<dynamic> stations =
        (meta.json['stations'] as List<dynamic>?) ?? <dynamic>[];
    expect(
      stations.any(
        (dynamic row) =>
            (row as Map<String, dynamic>)['station_id'] == eventsStation,
      ),
      isTrue,
      reason: '自建广播站必须出现在可订阅清单里',
    );
  });

  test('套件自身不含协议包常量（防止核心改名时门禁跟着变绿）', () {
    final File source = File(
      p.join(Directory.current.path, 'test', 'ui_contract_blackbox_test.dart'),
    );
    expect(source.existsSync(), isTrue, reason: '找不到本套件源码');
    final String src = source.readAsStringSync();
    // 拆开写：这些记号本身不能出现在本文件里（含注释），否则这条自检自己失败。
    final List<String> forbidden = <String>[
      'Api' 'Paths',
      'Ws' 'InboundType',
      'Ws' 'OutboundType',
      'Station' 'DeliveryState',
      'package:' 'tree_protocol',
    ];
    for (final String token in forbidden) {
      expect(
        src.contains(token),
        isFalse,
        reason: '黑盒套件引用了 $token：核心改名会让套件一起变绿，失去一致性保障',
      );
    }
  });
}

class _Client {
  _Client(this._server) : _http = HttpClient();

  final CoreServer _server;
  final HttpClient _http;

  Future<_Res> send(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final HttpClientRequest request = await _http.openUrl(
      method,
      Uri.parse('${_server.handshake.httpBaseUrl}$path'),
    );
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${_server.token}',
    );
    if (body != null) {
      final List<int> bytes = utf8.encode(jsonEncode(body));
      request.headers.contentType = ContentType.json;
      // 显式声明长度：否则走 chunked，核心按"长度未知"把 body 落盘（body_path），
      // 这里要验的是小请求的信封形状（内联 body）。
      request.contentLength = bytes.length;
      request.add(bytes);
    }
    final HttpClientResponse response = await request.close();
    final String text = await utf8.decoder.bind(response).join();
    return _Res(response.statusCode, text);
  }

  void close() => _http.close(force: true);
}

class _Res {
  const _Res(this.status, this.text);

  final int status;
  final String text;

  Map<String, dynamic> get json => text.trim().isEmpty
      ? <String, dynamic>{}
      : jsonDecode(text) as Map<String, dynamic>;
}

class _WsClient {
  _WsClient(this._socket) {
    _subscription = _socket.listen(
      (dynamic data) {
        final Object? decoded = jsonDecode(data.toString());
        if (decoded is Map<String, dynamic>) frames.add(decoded);
      },
      onDone: () {
        if (!_done.isCompleted) _done.complete();
      },
      onError: (Object _) {
        if (!_done.isCompleted) _done.complete();
      },
    );
  }

  final WebSocket _socket;
  late final StreamSubscription<dynamic> _subscription;
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
  final Completer<void> _done = Completer<void>();

  Future<void> get closed => _done.future;

  void send(Map<String, dynamic> frame) => _socket.add(jsonEncode(frame));

  Future<void> until(
    bool Function(Map<String, dynamic> frame) predicate, {
    Duration timeout = const Duration(seconds: 5),
    String? reason,
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (frames.any(predicate)) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw TimeoutException(
      '超时等待${reason ?? '帧'}；已收到：'
      '${frames.map((Map<String, dynamic> f) => '${f['type']}/${f['state'] ?? ''}').toList()}',
    );
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _socket.close();
  }
}
