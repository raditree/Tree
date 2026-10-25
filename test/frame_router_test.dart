import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tree_protocol/tree_protocol.dart';
import 'package:tree/io/frame_router.dart';
import 'package:tree/io/legacy_frame_bus.dart';
import 'package:tree/io/station_client.dart';

/// A4/U3：站点投递 → 旧帧名。
///
/// 钉住三件事（改一处就会让聊天渲染静默失效）：
/// 1. `topic` 的 kind 覆盖/填充 `type`；
/// 2. 缺 `session_id` 时用 topic 那一段补（`_` 表示无会话，不补）；
/// 3. 非 `data` 态不转投（可见性由 StationClient 负责）。
void main() {
  StationDelivery delivery({
    required String topic,
    required Object? payload,
    StationDeliveryState state = StationDeliveryState.data,
  }) => StationDelivery(
    stationId: 'plugin.tree.agent.broadcast.events',
    point: 'plugin.tree.agent.broadcast.events',
    topic: topic,
    payload: payload,
    state: state,
  );

  test('topic 的 kind 成为帧名，payload 字段原样保留', () {
    final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
    final FrameRouter router = FrameRouter(
      deliveries: const Stream<StationDelivery>.empty(),
      dispatch: frames.add,
    );

    router.handleDelivery(
      delivery(
        topic: 'tree.agent.s1.msg_chunk',
        payload: <String, dynamic>{
          'id': 'm1',
          'chunk': '你好',
          'seq': 3,
          'session_id': 's1',
          'agent_id': 'agt',
        },
      ),
    );

    expect(frames, hasLength(1));
    expect(frames.single['type'], 'msg_chunk');
    expect(frames.single['chunk'], '你好');
    expect(frames.single['session_id'], 's1');
    expect(frames.single['seq'], 3);
    expect(router.routed, 1);
  });

  test('缺 session_id 时用 topic 补；topic 的 `_` 不补', () {
    final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
    final FrameRouter router = FrameRouter(
      deliveries: const Stream<StationDelivery>.empty(),
      dispatch: frames.add,
    );

    router.handleDelivery(
      delivery(
        topic: 'tree.agent.s9.agent_status',
        payload: <String, dynamic>{'status': 'working'},
      ),
    );
    router.handleDelivery(
      delivery(
        topic: 'tree.agent._.agent_done',
        payload: <String, dynamic>{},
      ),
    );

    expect(frames[0]['session_id'], 's9');
    expect(frames[0]['type'], 'agent_status');
    expect(frames[1].containsKey('session_id'), isFalse);
    expect(frames[1]['type'], 'agent_done');
  });

  test('closed / lagged / reset 不转投；topic 非法或 payload 非对象也跳过', () {
    final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
    final FrameRouter router = FrameRouter(
      deliveries: const Stream<StationDelivery>.empty(),
      dispatch: frames.add,
    );

    for (final StationDeliveryState state in <StationDeliveryState>[
      StationDeliveryState.closed,
      StationDeliveryState.lagged,
      StationDeliveryState.reset,
    ]) {
      router.handleDelivery(
        delivery(
          topic: 'tree.agent.s1.agent_done',
          payload: <String, dynamic>{'type': 'agent_done'},
          state: state,
        ),
      );
    }
    router.handleDelivery(
      delivery(topic: 'bad-topic', payload: <String, dynamic>{}),
    );
    router.handleDelivery(
      delivery(topic: 'tree.agent.s1.msg_chunk', payload: 'text'),
    );

    expect(frames, isEmpty);
    expect(router.routed, 0);
  });

  test('seq 水位：重复/回退丢弃，跳号记账，reset 清零', () async {
    final StationClient client = StationClient();
    final List<StationDelivery> got = <StationDelivery>[];
    final StreamSubscription<StationDelivery> sub = client.deliveries.listen(
      got.add,
    );

    void data(int seq, {String topic = 'tree.agent.s1.msg_chunk'}) {
      client.handleFrame(
        StationDelivery(
          stationId: 'plugin.tree.agent.broadcast.events',
          point: 'plugin.tree.agent.broadcast.events',
          topic: topic,
          payload: <String, dynamic>{'n': seq},
          seq: seq,
        ).toFrame(),
      );
    }

    data(1);
    data(1); // 重复 ⇒ 丢
    data(2);
    data(4); // 跳号 ⇒ 收下但记一次 gap
    data(3); // 回退 ⇒ 丢
    await Future<void>.delayed(Duration.zero);

    expect(got.map((StationDelivery d) => d.seq), <int?>[1, 2, 4]);
    expect(client.lastSeqFor('tree.agent.s1.msg_chunk'), 4);
    expect(client.seqGaps, 1);

    client.handleFrame(
      StationDelivery(
        stationId: 'plugin.tree.agent.broadcast.events',
        point: 'plugin.tree.agent.broadcast.events',
        state: StationDeliveryState.reset,
      ).toFrame(),
    );
    data(1); // reset 后重新从 1 开始 ⇒ 必须接受
    await Future<void>.delayed(Duration.zero);

    expect(got.last.seq, 1);
    await sub.cancel();
  });

  test('LegacyFrameBus 只投给注册过的订阅者，注销后不再收到', () {
    final List<Map<String, dynamic>> got = <Map<String, dynamic>>[];
    void sink(Map<String, dynamic> frame) => got.add(frame);

    final int before = LegacyFrameBus.sinkCount;
    LegacyFrameBus.add(sink);
    expect(LegacyFrameBus.sinkCount, before + 1);
    LegacyFrameBus.emit(<String, dynamic>{'type': 'agent_status'});
    LegacyFrameBus.remove(sink);
    expect(LegacyFrameBus.sinkCount, before);
    LegacyFrameBus.emit(<String, dynamic>{'type': 'agent_done'});

    expect(got, hasLength(1));
    expect(got.single['type'], 'agent_status');
  });
}
