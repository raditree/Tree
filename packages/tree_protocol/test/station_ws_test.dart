import 'package:test/test.dart';
import 'package:tree_protocol/tree_protocol.dart';

void main() {
  group('StationWsFrames', () {
    test('帧名与设计文档一致，且都已在上下行枚举里登记', () {
      expect(StationWsFrames.uiHello, 'ui.hello');
      expect(StationWsFrames.subscribe, 'station/subscribe');
      expect(StationWsFrames.unsubscribe, 'station/unsubscribe');
      expect(StationWsFrames.register, 'station/register');
      expect(StationWsFrames.unregister, 'station/unregister');
      expect(StationWsFrames.trigger, 'station/trigger');
      expect(StationWsFrames.delivery, 'station_delivery');
      expect(StationWsFrames.ack, 'station_ack');

      expect(WsInboundType.all, containsAll(StationWsFrames.inbound));
      expect(WsOutboundType.all, containsAll(StationWsFrames.outbound));
      expect(StationWsFrames.inbound, hasLength(6));
      expect(StationWsFrames.outbound, hasLength(2));
      expect(StationWsFrames.all, hasLength(8));
    });

    test('上行与下行站点帧不重叠', () {
      expect(
        StationWsFrames.inbound.intersection(StationWsFrames.outbound),
        isEmpty,
      );
    });
  });

  group('StationAck（协议 1.1）', () {
    test('成功回执平铺解码；失败带稳定码与可读文案', () {
      final StationAck ok = StationAck.fromFrame(<String, dynamic>{
        'type': 'station_ack',
        'request': 'subscribe',
        'station_id': 'plugin.tree.agent.broadcast.events',
        'ok': true,
      })!;
      expect(ok.request, StationRequestName.subscribe);
      expect(ok.stationId, 'plugin.tree.agent.broadcast.events');
      expect(ok.ok, isTrue);
      expect(ok.code, isEmpty);
      expect(ok.toFrame(), <String, dynamic>{
        'type': 'station_ack',
        'request': 'subscribe',
        'station_id': 'plugin.tree.agent.broadcast.events',
        'ok': true,
      });

      final StationAck failed = StationAck.fromFrame(<String, dynamic>{
        'type': 'station_ack',
        'data': <String, dynamic>{
          'request': 'subscribe',
          'station_id': 'plugin.tree.agent.broadcast.events',
          'ok': false,
          'code': StationErrorCodes.stationNotFound,
          'message': '站点不存在',
        },
      })!;
      expect(failed.ok, isFalse);
      expect(failed.code, 'station_not_found');
      expect(failed.message, '站点不存在');
      expect(
        StationAck.fromFrame(<String, dynamic>{'type': 'station_delivery'}),
        isNull,
      );
    });

    test('动作名与错误码集合稳定（客户端按码决策，不匹配文案）', () {
      expect(StationRequestName.all, <String>{
        'subscribe',
        'unsubscribe',
        'register',
        'unregister',
        'trigger',
      });
      expect(StationErrorCodes.all, <String>{
        'identity_required',
        'identity_queue_overflow',
        'identity_conflict',
        'station_not_found',
        'not_broadcast',
        'scope_invalid',
        'not_owner',
        'invalid_request',
        'subscribe_rejected',
        'broadcast_rejected',
      });
    });
  });

  group('StationDeliveryState', () {
    test('四态齐全且线格式与文档一致', () {
      expect(StationDeliveryState.all, <String>{
        'data',
        'closed',
        'lagged',
        'reset',
      });
      expect(
        StationDeliveryState.values
            .map((StationDeliveryState s) => s.wire)
            .toList(),
        <String>['data', 'closed', 'lagged', 'reset'],
      );
    });

    test('宽容解析：已知值可用，缺失 / 未知返回 null', () {
      expect(StationDeliveryState.tryParse('data'), StationDeliveryState.data);
      expect(
        StationDeliveryState.tryParse('closed'),
        StationDeliveryState.closed,
      );
      expect(
        StationDeliveryState.tryParse('lagged'),
        StationDeliveryState.lagged,
      );
      expect(
        StationDeliveryState.tryParse(' reset '),
        StationDeliveryState.reset,
      );
      expect(StationDeliveryState.tryParse('bogus'), isNull);
      expect(StationDeliveryState.tryParse(null), isNull);
    });
  });

  group('StationDelivery 编解码', () {
    test('data 态全字段往返（seq 0 也必须保留）', () {
      const StationDelivery delivery = StationDelivery(
        stationId: 'plugin.tree.agent.download',
        point: 'system.broadcast',
        topic: 'tree.agent.s123.chunk',
        payload: <String, dynamic>{
          'chunks': <String>['a', 'b'],
        },
        scope: <String, dynamic>{
          'team_id': 't1',
          'agent_id': 'a1',
          'session_id': 's123',
          'mode_key': 'local',
        },
        originPluginId: 'tree.agent',
        state: StationDeliveryState.data,
        seq: 0,
      );

      final Map<String, dynamic> json = delivery.toJson();
      expect(json['state'], 'data');
      expect(json['seq'], 0);

      final StationDelivery decoded = StationDelivery.fromJson(json);
      expect(decoded.stationId, 'plugin.tree.agent.download');
      expect(decoded.point, 'system.broadcast');
      expect(decoded.topic, 'tree.agent.s123.chunk');
      expect(decoded.payload, <String, dynamic>{
        'chunks': <String>['a', 'b'],
      });
      expect(decoded.scope, delivery.scope);
      expect(decoded.originPluginId, 'tree.agent');
      expect(decoded.state, StationDeliveryState.data);
      expect(decoded.seq, 0);
      expect(decoded.reason, isNull);
      expect(decoded.fromSeq, isNull);
      expect(decoded.toJson(), json);
    });

    test('closed 态带 reason，可省略 seq', () {
      const StationDelivery delivery = StationDelivery(
        stationId: 'plugin.tree.agent.download',
        point: 'system.broadcast',
        state: StationDeliveryState.closed,
        reason: '插件下线',
      );
      final Map<String, dynamic> json = delivery.toJson();
      expect(json.containsKey('seq'), isFalse);
      expect(json['reason'], '插件下线');

      final StationDelivery decoded = StationDelivery.fromJson(json);
      expect(decoded.state, StationDeliveryState.closed);
      expect(decoded.reason, '插件下线');
      expect(decoded.seq, isNull);
    });

    test('lagged 态带 from_seq（背压起点）', () {
      const StationDelivery delivery = StationDelivery(
        stationId: 'plugin.tree.agent.download',
        point: 'system.broadcast',
        state: StationDeliveryState.lagged,
        seq: 120,
        fromSeq: 80,
        reason: '单连接队列溢出',
      );
      final StationDelivery decoded = StationDelivery.fromJson(
        delivery.toJson(),
      );
      expect(decoded.state, StationDeliveryState.lagged);
      expect(decoded.seq, 120);
      expect(decoded.fromSeq, 80);
      expect(decoded.reason, '单连接队列溢出');
    });

    test('reset 态：插件重启后序号归零', () {
      const StationDelivery delivery = StationDelivery(
        stationId: 'plugin.tree.agent.download',
        point: 'system.broadcast',
        state: StationDeliveryState.reset,
        seq: 0,
      );
      final StationDelivery decoded = StationDelivery.fromJson(
        delivery.toJson(),
      );
      expect(decoded.state, StationDeliveryState.reset);
      expect(decoded.seq, 0);
    });

    test('未知字段忽略；未知 state 回退 data；缺失 scope 归空 Map', () {
      final StationDelivery decoded = StationDelivery.fromJson(
        <String, dynamic>{
          'station_id': 'system.broadcast',
          'point': 'system.broadcast',
          'state': 'something_new',
          'payload': <String>[],
          'future_field': 'ignored',
        },
      );
      expect(decoded.state, StationDeliveryState.data);
      expect(decoded.scope, isEmpty);
      expect(decoded.topic, isNull);
      expect(decoded.toJson().containsKey('future_field'), isFalse);
    });

    test('完整帧往返（平铺）', () {
      const StationDelivery delivery = StationDelivery(
        stationId: 'plugin.demo.radio',
        point: 'plugin.demo.radio',
        topic: 'demo.radio.s9.track',
        payload: <String, dynamic>{'title': 'Song'},
        originPluginId: 'demo.radio',
        seq: 3,
      );
      final Map<String, dynamic> frame = delivery.toFrame();
      expect(frame['type'], 'station_delivery');

      final StationDelivery? decoded = StationDelivery.fromFrame(frame);
      expect(decoded, isNotNull);
      expect(decoded!.toJson(), delivery.toJson());
    });

    test('fromFrame 拒绝其它帧；也兼容 data 包裹', () {
      expect(
        StationDelivery.fromFrame(<String, dynamic>{'type': 'heartbeat'}),
        isNull,
      );

      final StationDelivery? wrapped = StationDelivery.fromFrame(
        <String, dynamic>{
          'type': 'station_delivery',
          'data': <String, dynamic>{
            'station_id': 'system.broadcast',
            'point': 'system.broadcast',
            'seq': 7,
          },
        },
      );
      expect(wrapped, isNotNull);
      expect(wrapped!.stationId, 'system.broadcast');
      expect(wrapped.seq, 7);
    });
  });

  group('StationTopic', () {
    test('拼接 <plugin_id>.<session_id>.<kind>', () {
      expect(
        StationTopic.join(
          pluginId: 'tree.agent',
          sessionId: 's123',
          kind: 'chunk',
        ),
        'tree.agent.s123.chunk',
      );
    });

    test('从右往左解析：plugin_id 自身可含点', () {
      final StationTopicParts? parts = StationTopic.parse(
        'tree.agent.s123.chunk',
      );
      expect(parts, isNotNull);
      expect(parts!.pluginId, 'tree.agent');
      expect(parts.sessionId, 's123');
      expect(parts.kind, 'chunk');
      expect(parts.toString(), 'tree.agent.s123.chunk');
    });

    test('三段时从右切分（plugin_id 可能是单段）；不足三段或空段返回 null', () {
      final StationTopicParts? three = StationTopic.parse('tree.agent.chunk');
      expect(three, isNotNull);
      expect(three!.pluginId, 'tree');
      expect(three.sessionId, 'agent');
      expect(three.kind, 'chunk');

      expect(StationTopic.parse('tree.chunk'), isNull);
      expect(StationTopic.parse('tree.agent..chunk'), isNull);
      expect(StationTopic.parse(''), isNull);
      expect(StationTopic.parse('.s1.chunk'), isNull);
      expect(StationTopic.parse('tree.s1.'), isNull);
    });

    test('拼接时任一段为空直接拒绝', () {
      expect(
        () => StationTopic.join(pluginId: '', sessionId: 's1', kind: 'chunk'),
        throwsArgumentError,
      );
      expect(
        () => StationTopic.join(pluginId: 'p', sessionId: '  ', kind: 'chunk'),
        throwsArgumentError,
      );
      expect(
        () => StationTopic.join(pluginId: 'p', sessionId: 's1', kind: ''),
        throwsArgumentError,
      );
    });
  });
}
