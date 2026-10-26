import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// 本轮片 B 的 UI 站点总线测试：
/// - 订阅通道抽象（topic 过滤 / seq / 溢出 lagged）；
/// - `ui.hello` 身份、广播站白名单、四态投递；
/// - UI 自建站生命周期与 `/api/meta` 发现面。
///
/// 只覆盖片 B 语义：routes 一律为空，不测 REST 委派（片 C）。
void main() {
  group('WS 站点通道（单元）', () {
    test('topics 过滤发生在投递时；空数组不过滤；seq 只给真正投递的帧', () async {
      final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
      final WsConnectionOutbox outbox = WsConnectionOutbox(
        sink: frames.add,
        autoDrain: false,
      );
      final WsStationSubscriberChannel channel = WsStationSubscriberChannel(
        channelId: 'conn-1',
        pluginId: 'ui.alpha',
        stationId: 'system.broadcast',
        point: 'system.broadcast',
        scope: StationScope.parse(<String, dynamic>{}),
        topics: <String>['ping'],
        sink: frames.add,
        outbox: outbox,
      );

      await channel.deliver(_broadcastRequest('pong', 1));
      expect(channel.pendingCount, 0, reason: 'topic 不在白名单内应被过滤掉');
      await channel.deliver(_broadcastRequest('ping', 2));
      await channel.deliver(_broadcastRequest('ping', 3));
      expect(channel.lastSeq, 2);
      channel.drainNow();
      expect(frames.length, 2);
      expect(frames[0]['type'], WsOutboundType.stationDelivery);
      expect(frames[0]['state'], StationDeliveryState.data.wire);
      expect(frames[0]['seq'], 1);
      expect(frames[1]['seq'], 2);

      final WsStationSubscriberChannel wildcard = WsStationSubscriberChannel(
        channelId: 'conn-2',
        pluginId: 'ui.alpha',
        stationId: 'system.broadcast',
        point: 'system.broadcast',
        scope: StationScope.parse(<String, dynamic>{}),
        sink: frames.add,
        autoDrain: false,
      );
      await wildcard.deliver(_broadcastRequest('anything', 4));
      expect(wildcard.pendingCount, 1, reason: '空 topics 表示不过滤');
    });

    test('队列溢出发 lagged + from_seq，不静默丢帧', () async {
      final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
      final WsStationSubscriberChannel channel = WsStationSubscriberChannel(
        channelId: 'conn-1',
        pluginId: 'ui.alpha',
        stationId: 'system.broadcast',
        point: 'system.broadcast',
        scope: StationScope.parse(<String, dynamic>{}),
        sink: frames.add,
        queueCapacity: 2,
        autoDrain: false,
      );
      for (int i = 1; i <= 5; i++) {
        await channel.deliver(_broadcastRequest('ping', i));
      }
      channel.drainNow();
      final List<Map<String, dynamic>> lagged = frames
          .where(
            (Map<String, dynamic> f) =>
                f['state'] == StationDeliveryState.lagged.wire,
          )
          .toList();
      expect(lagged, isNotEmpty, reason: '溢出必须有可诊断的 lagged 帧');
      final Map<String, dynamic> first = lagged.first;
      expect(first['from_seq'], 1, reason: 'from_seq 必须等于最早被丢掉的 data 帧序号');
      expect((first['reason'] as String).trim(), isNotEmpty);
      expect(
        frames.any(
          (Map<String, dynamic> f) =>
              f['state'] == StationDeliveryState.data.wire,
        ),
        isTrue,
        reason: '溢出后当前帧仍应继续投递（不静默丢弃）',
      );
    });
  });

  group('UI 站点总线（集成）', () {
    late Directory temp;
    late PluginBus bus;
    late CoreServer server;
    late _Client client;
    final List<_WsClient> sockets = <_WsClient>[];

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('tree_ui_station_');
      final File config = File('${temp.path}/plugins.yaml');
      await config.writeAsString('''
enabled: true
plugins:
  - id: ui.alpha
    name: Alpha UI
    command: dart
    runtime: ui
    enabled: false
  - id: ui.beta
    name: Beta UI
    command: dart
    runtime: ui
    enabled: false
  - id: headless.one
    name: Headless
    command: dart
    runtime: node
    enabled: false
  - id: legacy.binary
    name: Legacy Binary
    command: dart
    runtime: binary
    enabled: false
  - id: legacy.python
    name: Legacy Python
    command: dart
    runtime: python
    enabled: false
  - id: no.runtime
    name: No Runtime
    command: dart
    enabled: false
''');
      bus = PluginBus(
        configFile: config.path,
        log: (_) {},
      );
      server = await CoreServer.start(
          enableHeartbeat: false,
        pluginBus: bus,
      );
      client = _Client(server);
    });

    tearDown(() async {
      for (final _WsClient socket in sockets) {
        await socket.close();
      }
      sockets.clear();
      client.close();
      await server.close();
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 40));

    test('订阅广播站收到 data；topics 过滤；空 scope 通配', () async {
      final _WsClient ws = await _connect(server);
      sockets.add(ws);
      ws.send(_hello('ui.alpha'));

      ws.send(<String, dynamic>{
        'type': WsInboundType.stationSubscribe,
        'data': <String, dynamic>{
          'station_id': 'system.broadcast',
          'scope': <String, dynamic>{},
          'topics': <String>['ping'],
        },
      });
      await settle();

      // 每条新通道订阅成功都先发 reset（seq 从 1 重新计数）：断线重连后 UI 靠它
      // 清掉旧水位，否则会把重放的首批帧当"重复"丢掉（E2E-04 丢帧根因）。
      // 用 until 等帧（固定 sleep 在满负载跑全量时会不够）。
      await ws.until(
        (Map<String, dynamic> f) =>
            f['type'] == WsOutboundType.stationDelivery &&
            f['state'] == StationDeliveryState.reset.wire,
        reason: '首次订阅也要 reset',
      );

      final BroadcastStation station =
          bus.stations.pointFor('system.broadcast')! as BroadcastStation;
      await station.publish(
        topic: 'pong',
        scope: StationScope.parse(<String, dynamic>{
          'team_id': 'team-1',
          'mode_key': 'local',
        }),
        payload: <String, dynamic>{'n': 1},
        sourcePluginId: 'headless.one',
      );
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(
        ws.frames.where(
          (Map<String, dynamic> f) =>
              f['type'] == WsOutboundType.stationDelivery &&
              f['state'] == StationDeliveryState.data.wire,
        ),
        isEmpty,
        reason: 'topic 不在白名单内不应投递（订阅时的 reset 不算 data）',
      );

      await station.publish(
        topic: 'ping',
        scope: StationScope.parse(<String, dynamic>{
          'team_id': 'team-1',
          'mode_key': 'local',
        }),
        payload: <String, dynamic>{'n': 2},
        sourcePluginId: 'headless.one',
      );
      await ws.until(
        (Map<String, dynamic> f) =>
            f['type'] == WsOutboundType.stationDelivery &&
            f['state'] == StationDeliveryState.data.wire,
        reason: '广播 data 帧',
      );
      final Map<String, dynamic> data = ws.frames.firstWhere(
        (Map<String, dynamic> f) =>
            f['type'] == WsOutboundType.stationDelivery &&
            f['state'] == StationDeliveryState.data.wire,
      );
      expect(data['station_id'], 'system.broadcast');
      expect(data['point'], 'system.broadcast');
      expect(data['topic'], 'ping');
      expect(data['origin_plugin_id'], 'headless.one');
      expect((data['payload'] as Map<String, dynamic>)['n'], 2);
      expect(data['seq'], 1);
      expect((data['scope'] as Map<String, dynamic>)['team_id'], 'team-1');
    });

    test('订中转 / 执行 / 收集站被拒；未 ui.hello 被拒；未知 plugin_id 被拒', () async {
      final _WsClient ws = await _connect(server);
      sockets.add(ws);

      // 未 hello：可读拒绝。
      ws.send(<String, dynamic>{
        'type': WsInboundType.stationSubscribe,
        'data': <String, dynamic>{'station_id': 'system.broadcast'},
      });
      await ws.until(
        (Map<String, dynamic> f) =>
            f['type'] == WsOutboundType.error &&
            ((f['data'] as Map<String, dynamic>)['error'] as String).contains('ui.hello'),
        reason: '未握手拒绝',
      );
      // 未握手同样不允许注册自建站（同一身份闸门）。
      ws.send(<String, dynamic>{
        'type': WsInboundType.stationRegister,
        'data': <String, dynamic>{'kind': 'broadcast', 'name': 'nope', 'readme': 'x'},
      });
      await ws.until(
        (Map<String, dynamic> f) =>
            f['type'] == WsOutboundType.error &&
            ws.frames.where((Map<String, dynamic> x) => x['type'] == WsOutboundType.error).length >= 2,
        reason: '未握手不能注册',
      );

      ws.send(_hello('ui.alpha'));
      await settle();

      for (final String stationId in <String>[
        StationHubIds.relayToolPre,
        StationHubIds.executeTool,
        StationHubIds.collect,
      ]) {
        ws.send(<String, dynamic>{
          'type': WsInboundType.stationSubscribe,
          'data': <String, dynamic>{'station_id': stationId, 'scope': <String, dynamic>{}},
        });
        // 逐站等待**点名本站**的拒绝：只等「错误数达到 N」会与前面两条未握手
        // 拒绝提前凑数，导致本轮第三条拒绝还没到就断言（竞态）。
        await ws.until(
          (Map<String, dynamic> f) =>
              f['type'] == WsOutboundType.error &&
              ((f['data'] as Map<String, dynamic>)['error'] as String)
                  .contains(stationId),
          reason: '$stationId 拒绝',
        );
      }
      final List<String> errors = ws.frames
          .where((Map<String, dynamic> f) => f['type'] == WsOutboundType.error)
          .map((Map<String, dynamic> f) => (f['data'] as Map<String, dynamic>)['error'] as String)
          .toList();
      expect(errors.where((String e) => e.contains('广播站')).length, 3);
      expect(errors.every((String e) => e.trim().isNotEmpty), isTrue);

      // 未知 plugin_id：error 后关闭连接。
      final _WsClient ghost = await _connect(server);
      sockets.add(ghost);
      ghost.send(_hello('ui.ghost'));
      await ghost.until(
        (Map<String, dynamic> f) =>
            f['type'] == WsOutboundType.error &&
            ((f['data'] as Map<String, dynamic>)['error'] as String).contains('plugins.yaml'),
        reason: '未知 plugin_id 拒绝',
      );
      expect(
        ((ghost.frames.first['data'] as Map<String, dynamic>)['error'] as String).trim(),
        isNotEmpty,
      );
      await ghost.closed;
    });

    test('片 D：只有归一化 ui 能连；binary/python/未知/空 runtime 一律拒绝', () async {
      for (final String pluginId in <String>[
        'legacy.binary',
        'legacy.python',
        'headless.one',
        'no.runtime',
      ]) {
        final _WsClient ws = await _connect(server);
        sockets.add(ws);
        ws.send(_hello(pluginId));
        await ws.until(
          (Map<String, dynamic> f) =>
              f['type'] == WsOutboundType.error &&
              ((f['data'] as Map<String, dynamic>)['error'] as String).contains(
                '不是 ui',
              ),
          reason: '$pluginId 不是 ui，必须拒绝',
        );
        await ws.closed;
      }
    });

    test('站点注销 / 插件下线 → closed + reason', () async {
      // 插件自建站（模拟无头插件注册后下线；站点保留但订阅必须收到 closed）。
      final String stationId = 'plugin.headless.one.broadcast.notice';
      bus.stations.register(
        BroadcastStation(
          id: stationId,
          description: '无头插件通知',
          readme: '测试用自建广播站',
        ),
      );
      final _WsClient ws = await _connect(server);
      sockets.add(ws);
      ws.send(_hello('ui.alpha'));
      ws.send(<String, dynamic>{
        'type': WsInboundType.stationSubscribe,
        'data': <String, dynamic>{'station_id': stationId, 'scope': <String, dynamic>{}},
      });
      await settle();

      bus.onPluginOffline?.call('headless.one');
      await ws.until(
        (Map<String, dynamic> f) =>
            f['type'] == WsOutboundType.stationDelivery &&
            f['state'] == StationDeliveryState.closed.wire,
        reason: '插件下线 closed',
      );
      final Map<String, dynamic> closed = ws.frames.firstWhere(
        (Map<String, dynamic> f) =>
            f['type'] == WsOutboundType.stationDelivery &&
            f['state'] == StationDeliveryState.closed.wire,
      );
      expect((closed['reason'] as String).trim(), isNotEmpty);

      // 显式注销同样补 closed。
      final String builtId = 'plugin.headless.one.broadcast.other';
      bus.stations.register(
        BroadcastStation(
          id: builtId,
          description: '注销测试',
          readme: '注销测试',
        ),
      );
      ws.send(<String, dynamic>{
        'type': WsInboundType.stationSubscribe,
        'data': <String, dynamic>{'station_id': builtId, 'scope': <String, dynamic>{}},
      });
      await settle();
      bus.stations.unregister(builtId);
      await ws.until(
        (Map<String, dynamic> f) =>
            f['type'] == WsOutboundType.stationDelivery &&
            f['station_id'] == builtId &&
            f['state'] == StationDeliveryState.closed.wire,
        reason: '站点注销 closed',
      );
    });

    test('同插件两个窗口订阅同站，各自收到投递（seq 各自从 1 开始）', () async {
      final _WsClient a = await _connect(server);
      final _WsClient b = await _connect(server);
      sockets.addAll(<_WsClient>[a, b]);
      final List<String> windows = <String>['w1', 'w2'];
      for (int i = 0; i < windows.length; i++) {
        final _WsClient ws = i == 0 ? a : b;
        // 多窗口：`ui.hello.window_id` 让连接与窗口对上（核心只记录、不做路由）。
        ws.send(_hello('ui.alpha', windowId: windows[i]));
        ws.send(<String, dynamic>{
          'type': WsInboundType.stationSubscribe,
          'data': <String, dynamic>{'station_id': 'system.broadcast', 'scope': <String, dynamic>{}},
        });
      }
      await settle();
      final BroadcastStation station =
          bus.stations.pointFor('system.broadcast')! as BroadcastStation;
      await station.publish(
        topic: 'broadcast',
        scope: StationScope.parse(<String, dynamic>{
          'team_id': 'team-1',
          'mode_key': 'local',
        }),
        payload: <String, dynamic>{'once': true},
        sourcePluginId: 'headless.one',
      );
      for (final _WsClient ws in <_WsClient>[a, b]) {
        await ws.until(
          (Map<String, dynamic> f) =>
              f['type'] == WsOutboundType.stationDelivery &&
              f['state'] == StationDeliveryState.data.wire,
          reason: '两个窗口都应收到',
        );
        final Map<String, dynamic> data = ws.frames.firstWhere(
          (Map<String, dynamic> f) =>
              f['type'] == WsOutboundType.stationDelivery &&
              f['state'] == StationDeliveryState.data.wire,
        );
        expect(data['seq'], 1);
      }
    });

    test('自建站：注册广播成功、注册收集/执行被拒、最后连接断开注销、关一个窗口不销毁、自环带 origin', () async {
      final _WsClient a = await _connect(server);
      final _WsClient b = await _connect(server);
      sockets.addAll(<_WsClient>[a, b]);
      a.send(_hello('ui.alpha'));
      b.send(_hello('ui.alpha'));
      await settle();

      a.send(<String, dynamic>{
        'type': WsInboundType.stationRegister,
        'data': <String, dynamic>{
          'kind': 'broadcast',
          'name': 'notice',
          'readme': '主窗口通知其它窗口',
        },
      });
      await settle();
      final String stationId = 'plugin.ui.alpha.broadcast.notice';
      expect(bus.stations.station(stationId), isNotNull, reason: '广播自建站应注册成功');

      // 收集 / 执行：WS 侧不允许。
      for (final String kind in <String>['collect', 'execute', 'relay']) {
        a.send(<String, dynamic>{
          'type': WsInboundType.stationRegister,
          'data': <String, dynamic>{'kind': kind, 'name': 'bad-$kind', 'readme': 'x'},
        });
      }
      await a.until(
        (Map<String, dynamic> f) =>
            f['type'] == WsOutboundType.error &&
            a.frames.where((Map<String, dynamic> x) => x['type'] == WsOutboundType.error).length >= 3,
        reason: '非广播 kind 拒绝',
      );

      // 两窗口都订阅；a 触发，自己与 b 都收到，且 origin = ui.alpha（自环可见）。
      for (final _WsClient ws in <_WsClient>[a, b]) {
        ws.send(<String, dynamic>{
          'type': WsInboundType.stationSubscribe,
          'data': <String, dynamic>{'station_id': stationId, 'scope': <String, dynamic>{}},
        });
      }
      await settle();
      a.send(<String, dynamic>{
        'type': WsInboundType.stationTrigger,
        'data': <String, dynamic>{
          'station_id': stationId,
          'topic': 'notice',
          'scope': <String, dynamic>{'team_id': 'team-1', 'mode_key': 'local'},
          'payload': <String, dynamic>{'text': 'hello'},
        },
      });
      for (final _WsClient ws in <_WsClient>[a, b]) {
        await ws.until(
          (Map<String, dynamic> f) =>
              f['type'] == WsOutboundType.stationDelivery &&
              f['state'] == StationDeliveryState.data.wire,
          reason: '自建站投递',
        );
        final Map<String, dynamic> data = ws.frames.firstWhere(
          (Map<String, dynamic> f) =>
              f['type'] == WsOutboundType.stationDelivery &&
              f['state'] == StationDeliveryState.data.wire,
        );
        expect(data['origin_plugin_id'], 'ui.alpha');
        expect((data['payload'] as Map<String, dynamic>)['text'], 'hello');
      }

      // 关一个窗口：站还在（最后一个连接才销毁）。
      await a.close();
      sockets.remove(a);
      await settle();
      expect(bus.stations.station(stationId), isNotNull, reason: '还有一条连接时不能注销自建站');

      // 最后一个窗口关：站点注销，其它订阅者（无）不会留残。
      await b.close();
      sockets.remove(b);
      await settle();
      expect(bus.stations.station(stationId), isNull, reason: '最后一条连接断开应注销自建站');
    });

    test('/api/meta：版本、ui 聚合、can_manage_plugins、广播站与空 routes', () async {
      final _Res before = await client.send('GET', ApiPaths.meta);
      expect(before.status, 200);
      expect(before.json['core_version'], server.version);
      expect(before.json['api_version'], CoreServer.apiVersion);
      expect(before.json['routes'], isEmpty, reason: '片 B 没有委派路由，不得编造静态清单');
      expect(before.json['can_manage_plugins'], isFalse);
      expect(before.json['ui'], isEmpty);
      final List<dynamic> stations = before.json['stations'] as List<dynamic>;
      expect(
        stations.any((dynamic s) => (s as Map<String, dynamic>)['station_id'] == 'system.broadcast'),
        isTrue,
      );

      final _WsClient a = await _connect(server);
      final _WsClient b = await _connect(server);
      sockets.addAll(<_WsClient>[a, b]);
      a.send(_hello('ui.alpha', capabilities: <Object?>['plugin.manage', 'ui.custom']));
      b.send(_hello('ui.alpha', version: '9.9.9', capabilities: <Object?>['ui.custom', <String, dynamic>{'x': 1}]));
      await settle();

      final _Res after = await client.send('GET', ApiPaths.meta);
      expect(after.json['can_manage_plugins'], isTrue, reason: '存在声明 plugin.manage 的活连接');
      final List<dynamic> ui = after.json['ui'] as List<dynamic>;
      final Map<String, dynamic> alpha = ui
          .cast<Map<String, dynamic>>()
          .firstWhere((Map<String, dynamic> row) => row['plugin_id'] == 'ui.alpha');
      expect(alpha['connections'], 2);
      expect(alpha['capabilities'], contains('plugin.manage'));
      expect(alpha['capabilities'], contains('ui.custom'));
      final List<dynamic> capabilities = after.json['capabilities'] as List<dynamic>;
      expect(capabilities, contains('ui.custom'));
      expect(
        capabilities.any((dynamic c) => c is Map && c['x'] == 1),
        isTrue,
        reason: '未知 capability 原样透传（不解释、不强制转字符串）',
      );

      // 站点发现面只允许广播站：内置中转 / 执行 / 收集都不得出现。
      final List<String> ids = (after.json['stations'] as List<dynamic>)
          .map((dynamic s) => (s as Map<String, dynamic>)['station_id'] as String)
          .toList();
      expect(ids, contains('system.broadcast'));
      expect(ids, isNot(contains(StationHubIds.relayToolPre)));
      expect(ids, isNot(contains(StationHubIds.executeTool)));
      expect(ids, isNot(contains(StationHubIds.collect)));
    });

    test('trigger 只能发布自己注册的自建广播站', () async {
      final _WsClient beta = await _connect(server);
      sockets.add(beta);
      beta.send(_hello('ui.beta'));
      await settle();
      beta.send(<String, dynamic>{
        'type': WsInboundType.stationRegister,
        'data': <String, dynamic>{'kind': 'broadcast', 'name': 'beta', 'readme': 'beta 的自建站'},
      });
      await settle();

      final _WsClient alpha = await _connect(server);
      sockets.add(alpha);
      alpha.send(_hello('ui.alpha'));
      await settle();
      alpha.send(<String, dynamic>{
        'type': WsInboundType.stationTrigger,
        'data': <String, dynamic>{
          'station_id': 'plugin.ui.beta.broadcast.beta',
          'topic': 'x',
          'scope': <String, dynamic>{'team_id': 't', 'mode_key': 'local'},
          'payload': <String, dynamic>{},
        },
      });
      await alpha.until(
        (Map<String, dynamic> f) =>
            f['type'] == WsOutboundType.error &&
            ((f['data'] as Map<String, dynamic>)['error'] as String).contains('不是插件 ui.alpha'),
        reason: '不能触发别人的自建站',
      );
    });
  });
}

Map<String, dynamic> _hello(
  String pluginId, {
  String version = '1.0.0',
  List<Object?> capabilities = const <Object?>[],
  String windowId = '',
}) => <String, dynamic>{
  'type': WsInboundType.uiHello,
  'data': <String, dynamic>{
    'plugin_id': pluginId,
    'version': version,
    'capabilities': capabilities,
    if (windowId.isNotEmpty) 'window_id': windowId,
  },
};

StationRequest _broadcastRequest(String topic, int value) => StationRequest(
  requestId: 'req-$value',
  stationId: 'system.broadcast',
  kind: StationKind.broadcast,
  scope: StationScope.parse(<String, dynamic>{'team_id': 'team-1', 'mode_key': 'local'}),
  payload: <String, dynamic>{'value': value},
  topic: topic,
  originPluginId: 'headless.one',
);

Future<_WsClient> _connect(CoreServer server) async {
  final WebSocket socket = await WebSocket.connect(
    '${server.handshake.wsBaseUrl}${CoreServer.wsPath}?token=${server.token}',
  );
  return _WsClient(socket);
}

class _Client {
  _Client(this._server) : _http = HttpClient();

  final CoreServer _server;
  final HttpClient _http;

  Future<_Res> send(String method, String path) async {
    final HttpClientRequest request = await _http.openUrl(
      method,
      Uri.parse('${_server.handshake.httpBaseUrl}$path'),
    );
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${_server.token}',
    );
    final HttpClientResponse response = await request.close();
    final String text = await utf8.decoder.bind(response).join();
    return _Res(
      response.statusCode,
      text.trim().isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>,
    );
  }

  void close() => _http.close(force: true);
}

class _Res {
  const _Res(this.status, this.json);

  final int status;
  final Map<String, dynamic> json;
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
      '超时等待${reason ?? '帧'}；已收到：${frames.map((Map<String, dynamic> f) => f['type']).toList()}',
    );
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _socket.close();
  }
}
