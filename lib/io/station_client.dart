import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier, debugPrint;
import 'package:tree_protocol/tree_protocol.dart';

import 'core_attachment.dart';
import 'websocket_service.dart';

/// UI 插件的 **WS 站点客户端**（U4）。
///
/// 职责只有三件，刻意不做第四件：
/// 1. **订阅广播站**（`station/subscribe`，目前只订插件生命周期）；
/// 2. 把 `station_delivery` 按 state 分发（`data` 增量、`closed` 终止、`lagged`
///    背压、`reset` 水位归零）；
/// 3. **断线重连后自动重放订阅**，并把"服务下线 / 正在重连"显示成可见状态。
///
/// **不发 `station/trigger`**：功能调用一律走 REST 委派端点；这里没有"从 UI 反向
/// 触发别的插件"的通道。
class StationClient {
  StationClient({WebSocketService Function()? connectionFactory})
    : _connectionFactory = connectionFactory ?? WebSocketService.new;

  /// 应用级单例（一条独立连接，只承载站点订阅）。
  static final StationClient instance = StationClient();

  /// 插件生命周期广播站：载荷 = `{plugin_id, lifecycle, generation, ...}`。
  ///
  /// 与旧 `plugin_status` 帧不是一条通道：这是站点化后的"核心推给你"，
  /// 插件面板继续用既有 `plugin_status` 帧（同一条 WS 连接照常可达）。
  static const String pluginStateStation = 'system.broadcast.plugin.state';

  /// 默认订阅集合。
  static const Set<String> defaultStations = <String>{pluginStateStation};

  final WebSocketService Function() _connectionFactory;

  final Set<String> _stations = <String>{};
  final StreamController<StationDelivery> _deliveries =
      StreamController<StationDelivery>.broadcast();

  /// 可见的离线状态：null = 正常；非 null = 给用户看的可读原因。
  ///
  /// `closed` 帧与连接断开都会写入；连接确认（宽限期无错误）后清空。
  final ValueNotifier<String?> offlineReason = ValueNotifier<String?>(null);

  /// 重放订阅的次数（诊断 / 测试用：重连后必须 +1）。
  int subscribePasses = 0;

  WebSocketService? _ws;
  bool _started = false;

  /// 已订阅的站点（只读视图）。
  Set<String> get stations => Set<String>.unmodifiable(_stations);

  /// 站点投递流（data / closed / lagged / reset 都会到达，调用方按 state 处理）。
  Stream<StationDelivery> get deliveries => _deliveries.stream;

  bool get isOffline => offlineReason.value != null;

  /// 开始站点连接并订阅；重复调用无副作用。
  ///
  /// [stations] 为空时用 [defaultStations]；[connectionFactory] 仅测试注入。
  void start({
    Iterable<String>? stations,
    WebSocketService Function()? connectionFactory,
  }) {
    if (_started) return;
    _started = true;
    _stations.addAll(stations ?? defaultStations);

    final WebSocketService ws =
        (connectionFactory ?? _connectionFactory)();
    _ws = ws;
    ws.onMessage = handleFrame;
    ws.onConnectionChange = (bool connected) {
      if (connected) {
        // WebSocketChannel.connect 是惰性的：此刻只是"发起建连"，但写入会缓冲，
        // 因此订阅可以立即发出；真正的"确认在线"由 onSessionReady 给出。
        _subscribeAll(ws);
      } else {
        offlineReason.value = '与核心的连接已断开，正在重连…';
      }
    };
    ws.onSessionReady = () {
      // 宽限期无错误 = 本次连接可用：清掉离线提示（closed 若仍在会再次写入）。
      offlineReason.value = null;
    };
    ws.connect(CoreAttachment.instance.token);
  }

  /// 停止（主要给测试与登出场景用）。
  void stop() {
    _ws?.disconnect();
    _ws = null;
    _started = false;
    offlineReason.value = null;
  }

  /// 订阅所有已登记站点。重连时由 [WebSocketService.onConnectionChange] 再次调用。
  void _subscribeAll(WebSocketService ws) {
    if (_stations.isEmpty) return;
    subscribePasses += 1;
    for (final String stationId in _stations) {
      ws.send(<String, dynamic>{
        'type': WsInboundType.stationSubscribe,
        'data': <String, dynamic>{
          'station_id': stationId,
          // 通配：UI 不按团队 / 员工隔离收件，由核心按发布方归属过滤。
          'scope': <String, dynamic>{},
        },
      });
    }
  }

  /// 处理一帧下行消息（非 `station_delivery` 一律忽略）。
  ///
  /// 公开可见是为了让测试在不起真实 socket 的情况下验证四态语义。
  void handleFrame(Map<String, dynamic> frame) {
    final StationDelivery? delivery = StationDelivery.fromFrame(frame);
    if (delivery == null) return;
    switch (delivery.state) {
      case StationDeliveryState.data:
        _deliveries.add(delivery);
      case StationDeliveryState.closed:
        // 终止订阅：必须先让用户看见，不能静默失效。
        offlineReason.value = '服务下线：${delivery.reason ?? delivery.stationId}';
        _deliveries.add(delivery);
      case StationDeliveryState.lagged:
        // 背压：帧丢了，调用方需要重新拉快照（这里只透传，不猜快照端点）。
        debugPrint('[Station] 队列溢出，需重新拉快照：${delivery.stationId}');
        _deliveries.add(delivery);
      case StationDeliveryState.reset:
        // 插件重启后 seq 归零：调用方重置本地水位。
        _deliveries.add(delivery);
    }
  }
}
