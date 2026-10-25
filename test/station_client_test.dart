import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tree/io/core_attachment.dart';
import 'package:tree/io/station_client.dart';
import 'package:tree/io/websocket_service.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// 记录型假连接：不建 socket，只记录上行帧并手动驱动连接事件。
class _FakeWs extends WebSocketService {
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  String? connectedToken;
  int disconnectCalls = 0;

  @override
  void connect(String token) {
    connectedToken = token;
    // 与真实现一致：建连返回即乐观置 true（订阅在这一刻发出）。
    onConnectionChange?.call(true);
  }

  @override
  void send(Map<String, dynamic> message) {
    sent.add(message);
  }

  @override
  void disconnect() {
    disconnectCalls += 1;
  }
}

Map<String, dynamic> delivery({
  required String state,
  String stationId = StationClient.pluginStateStation,
  String? reason,
  Object? payload,
}) {
  final Map<String, dynamic> frame = <String, dynamic>{
    'type': 'station_delivery',
    'station_id': stationId,
    'point': 'system.broadcast.plugin.state',
    'topic': 'tree.ui.default.s1.state',
    'payload': payload,
    'scope': <String, dynamic>{},
    'origin_plugin_id': 'tree.core',
    'state': state,
    'seq': 1,
  };
  if (reason != null) frame['reason'] = reason;
  return frame;
}

void main() {
  late _FakeWs ws;
  late StationClient client;

  setUp(() {
    CoreAttachment.instance.token = 'tok-test';
    ws = _FakeWs();
    client = StationClient(connectionFactory: () => ws);
  });

  tearDown(() {
    client.stop();
    CoreAttachment.instance.token = '';
  });

  test('启动即订阅插件生命周期广播站，且只发 station/subscribe', () {
    client.start();

    expect(ws.connectedToken, 'tok-test');
    final List<Map<String, dynamic>> subscribes = ws.sent
        .where((Map<String, dynamic> f) => f['type'] == 'station/subscribe')
        .toList();
    expect(subscribes, hasLength(1));
    final Map<String, dynamic> data =
        subscribes.single['data'] as Map<String, dynamic>;
    expect(data['station_id'], StationClient.pluginStateStation);
    expect(data['scope'], isEmpty);
    // U4 明确不发 trigger：功能调用一律走 REST。
    expect(ws.sent.any((Map<String, dynamic> f) => f['type'] == 'station/trigger'),
        isFalse);
  });

  test('重连后自动重放订阅（订阅次数 +1，站点集合不变）', () {
    client.start();
    final int first = client.subscribePasses;
    final int sentBefore = ws.sent.length;

    // 真实现里自动重连会再次调用 connect → onConnectionChange(true)。
    ws.connect('tok-test');

    expect(client.subscribePasses, first + 1);
    expect(ws.sent.length, sentBefore + 1);
    expect(client.stations, StationClient.defaultStations);
  });

  test('closed 帧 → 可见「服务下线」，并沿投递流透传', () async {
    client.start();
    final Future<StationDelivery> next = client.deliveries.first;

    client.handleFrame(
      delivery(state: 'closed', reason: '插件 tree.ui.default 已下线'),
    );

    expect(client.isOffline, isTrue);
    expect(client.offlineReason.value, contains('服务下线'));
    expect(client.offlineReason.value, contains('已下线'));
    final StationDelivery got = await next;
    expect(got.state, StationDeliveryState.closed);
  });

  test('会话确认清空离线提示；连接断开重新置为可读原因', () {
    client.start();
    client.handleFrame(delivery(state: 'closed', reason: 'x'));
    expect(client.isOffline, isTrue);

    ws.onSessionReady?.call();
    expect(client.offlineReason.value, isNull);

    ws.onConnectionChange?.call(false);
    expect(client.offlineReason.value, contains('断开'));
  });

  test('data 帧按增量投递；非 station_delivery 帧一律忽略', () async {
    client.start();
    final List<StationDelivery> seen = <StationDelivery>[];
    final StreamSubscription<StationDelivery> sub =
        client.deliveries.listen(seen.add);
    addTearDown(sub.cancel);

    client.handleFrame(<String, dynamic>{'type': 'msg_chunk', 'content': 'x'});
    await Future<void>.delayed(Duration.zero);
    expect(seen, isEmpty);

    client.handleFrame(delivery(state: 'data', payload: <String, dynamic>{'a': 1}));
    await Future<void>.delayed(Duration.zero);
    expect(seen, hasLength(1));
    expect(seen.single.state, StationDeliveryState.data);
    expect((seen.single.payload as Map<String, dynamic>)['a'], 1);
    expect(client.isOffline, isFalse);
  });
}
