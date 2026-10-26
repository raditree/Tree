import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:tree_protocol/tree_protocol.dart';

import 'legacy_frame_bus.dart';
import 'station_client.dart';

/// **站点帧 → 旧帧名**（U3 / L-08）。
///
/// 插件化后领域帧由插件经 `station_delivery` 发出（topic =
/// `<plugin_id>.<session_id>.<kind>`），而 UI 的渲染入口（消息面板 / 团队页）
/// 认的仍是 `msg_chunk` / `tool_start` / `agent_status` 这些旧帧名。
///
/// 这一层只做**换收口**：把 topic 里的 `kind` 与 payload 合并成旧帧，交给
/// [WebSocketService.emitFrame]，进入与 WS 下行完全相同的分发路径。渲染字段
/// 一个都不改，避免"迁移顺手改了 UI"。
///
/// 刻意**不**处理的历史包袱：
/// - 不做快照补拉（`lagged` 只记日志；水位与跳号由 [StationClient] 负责）；
/// - 不按 team / agent 过滤（UI 端本就按当前会话渲染）。
class FrameRouter {
  FrameRouter({
    Stream<StationDelivery>? deliveries,
    void Function(Map<String, dynamic> frame)? dispatch,
  }) : this._(deliveries, dispatch ?? LegacyFrameBus.emit);

  FrameRouter._(this._deliveries, this._dispatch);

  /// 应用级单例（与 `StationClient.instance` 配对）。
  static final FrameRouter instance = FrameRouter();

  final Stream<StationDelivery>? _deliveries;
  final void Function(Map<String, dynamic> frame) _dispatch;

  StreamSubscription<StationDelivery>? _subscription;
  bool _started = false;

  /// 已转投的帧数（诊断 / 测试用）。
  int routed = 0;

  /// 开始监听站点投递；重复调用无副作用。
  void start() {
    if (_started) return;
    _started = true;
    _subscription = (_deliveries ?? StationClient.instance.deliveries).listen(
      handleDelivery,
    );
  }

  /// 停止监听（测试 / 退出用）。
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _started = false;
  }

  /// 处理一条站点投递（公开可见：测试不必起真实连接）。
  void handleDelivery(StationDelivery delivery) {
    if (delivery.state != StationDeliveryState.data) {
      // `reset`（新通道 seq 归零）/ `lagged`（队列溢出丢帧）都意味着**本地状态可能
      // 缺口**：对领域事件站要通知 UI「先拉快照再对齐」（L-09 / E2E-04）。
      // 终端站的 reset 是每次开终端都正常的，不在这里触发重载。
      if (delivery.stationId == StationClient.agentEventsStation &&
          (delivery.state == StationDeliveryState.reset ||
              delivery.state == StationDeliveryState.lagged)) {
        _dispatch(<String, dynamic>{
          'type': 'station_resync',
          'station_id': delivery.stationId,
          'state': delivery.state.wire,
          if (delivery.reason != null) 'reason': delivery.reason,
        });
      }
      return;
    }
    final String? topic = delivery.topic;
    if (topic == null || topic.isEmpty) return;
    final StationTopicParts? parts = StationTopic.parse(topic);
    if (parts == null) {
      debugPrint('[FrameRouter] topic 形状非法，已跳过：$topic');
      return;
    }
    final Object? rawPayload = delivery.payload;
    if (rawPayload is! Map) {
      debugPrint('[FrameRouter] $topic 的 payload 不是对象，已跳过');
      return;
    }
    final Map<String, dynamic> frame = rawPayload.map(
      (dynamic key, dynamic value) => MapEntry(key.toString(), value),
    );
    // 帧名以 topic 为准（插件可能复用同一个 payload 发不同 kind）；
    // 缺 session_id 时用 topic 里的那一段补（`_` 是插件侧的"无会话"兜底）。
    frame['type'] = parts.kind;
    final String current = (frame['session_id'] ?? '').toString();
    if (current.isEmpty && parts.sessionId != '_') {
      frame['session_id'] = parts.sessionId;
    }
    routed += 1;
    _dispatch(frame);
  }
}
