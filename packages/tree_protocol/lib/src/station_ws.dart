/// UI 插件 ⇄ 核心的 **WS 站点协议**（设计见
/// `docs/pluginization/ui-pluginization.md` §3.2 / §6.7）。
///
/// 本文件只放**常量与值对象**（纯 Dart，不依赖 IO / Flutter）：
/// - [StationWsFrames]：WS 侧站点帧名（值复用 `WsInboundType` /
///   `WsOutboundType` 的**别名**，不重复字面量）；
/// - [StationDeliveryState]：`station_delivery.state` 的四态；
/// - [StationDelivery]：`station_delivery` 帧的值对象与编解码；
/// - [StationTopic]：`<plugin_id>.<session_id>.<kind>` 的拼接 / 解析。
///
/// 方向口径（§6.4 总纲）：UI 能做的事只有两类——**订阅广播站**接收推送
/// （[StationWsFrames.subscribe]）与**调用委派端点**做功能调用（REST）。
/// `station/trigger` 在 UI 侧只允许发布自己注册的自建广播站。
library;

import 'ws_inbound.dart';
import 'ws_outbound.dart';

/// WS 侧站点帧名。
///
/// 上行六条的值与 `WsInboundType` 完全一致（本类只做「按用途取名」的别名），
/// 下行一条同理。**不要在别处再写字面量**：帧名漂移会让 UI 静默收不到推送。
abstract final class StationWsFrames {
  /// UI 连接自我声明（上行）。
  static const String uiHello = WsInboundType.uiHello;

  /// 订阅站点（上行；仅广播站，可选 `topics[]` 过滤）。
  static const String subscribe = WsInboundType.stationSubscribe;

  /// 退订站点（上行）。
  static const String unsubscribe = WsInboundType.stationUnsubscribe;

  /// 注册自建站（上行；只允许广播类型）。
  static const String register = WsInboundType.stationRegister;

  /// 注销自建站（上行）。
  static const String unregister = WsInboundType.stationUnregister;

  /// 向自己注册的自建广播站发布事件（上行）。
  static const String trigger = WsInboundType.stationTrigger;

  /// 站点投递（下行）。
  static const String delivery = WsOutboundType.stationDelivery;

  /// 全部 WS 站点帧名。
  static const Set<String> all = <String>{
    uiHello,
    subscribe,
    unsubscribe,
    register,
    unregister,
    trigger,
    delivery,
  };

  /// 上行（UI → 核心）。
  static const Set<String> inbound = <String>{
    uiHello,
    subscribe,
    unsubscribe,
    register,
    unregister,
    trigger,
  };

  /// 下行（核心 → UI）。
  static const Set<String> outbound = <String>{delivery};
}

/// `station_delivery.state` 的取值（§6.7 / 不变量 32）。
///
/// 四态各自的事故语义：
/// - [data]：正常增量事件；
/// - [closed]：站点注销或插件下线，**终止订阅**（带 `reason`，不得静默失效）；
/// - [lagged]：单连接队列溢出（带 `from_seq`，UI 需重新拉快照，禁止静默丢帧）；
/// - [reset]：插件重启后 `seq` 归零，UI 需重置本地水位。
enum StationDeliveryState {
  /// 正常增量事件。
  data('data'),

  /// 站点注销 / 插件下线（订阅终止）。
  closed('closed'),

  /// 队列溢出（背压）。
  lagged('lagged'),

  /// 插件重启后序号归零。
  reset('reset');

  const StationDeliveryState(this.wire);

  /// 线格式取值。
  final String wire;

  /// 宽容解析：缺失 / 未知取值返回 null（由调用方决定容错方向）。
  static StationDeliveryState? tryParse(Object? raw) {
    final String value = raw == null ? '' : raw.toString().trim();
    for (final StationDeliveryState state in values) {
      if (state.wire == value) {
        return state;
      }
    }
    return null;
  }

  /// 全部线格式取值（完备性测试与文档用）。
  static Set<String> get all =>
      values.map((StationDeliveryState s) => s.wire).toSet();
}

/// `station_delivery` 帧的值对象（核心 → WS 订阅者）。
///
/// 线格式（设计文档 §3.2，**平铺**在帧顶层，与 `msg_chunk` 等下行帧同构）：
/// ```json
/// {
///   "type": "station_delivery",
///   "station_id": "plugin.tree.agent.download",
///   "point": "system.broadcast",
///   "topic": "tree.agent.s123.chunk",
///   "payload": { "chunks": ["..."] },
///   "scope": { "team_id": "t1", "agent_id": "a1",
///              "session_id": "s123", "mode_key": "local" },
///   "origin_plugin_id": "tree.agent",
///   "state": "data",
///   "seq": 12
/// }
/// ```
/// `closed` 带 `reason`；`lagged` 带 `from_seq`；`reset` 通常带新的起始 `seq`。
/// 未知字段在解析时忽略，`toJson()` 只回吐本协议字段。
class StationDelivery {
  const StationDelivery({
    required this.stationId,
    required this.point,
    this.topic,
    this.payload,
    this.scope = const <String, dynamic>{},
    this.originPluginId = '',
    this.state = StationDeliveryState.data,
    this.seq,
    this.reason,
    this.fromSeq,
  });

  /// 站点全局 id（订阅时用的那个串）。
  final String stationId;

  /// 点位 id / 别名（内置站点由核心点位表给出；自建站可为空）。
  final String point;

  /// 事件 topic（`<plugin_id>.<session_id>.<kind>`，见 [StationTopic]）。
  final String? topic;

  /// 原样透传的载荷（核心不解析、不重组、不缓存语义）。
  final Object? payload;

  /// 消息信封的隔离四元组（原样透传；空字段 = 该维不限定）。
  ///
  /// 协议包不依赖核心的 `StationScope`，因此这里保留线格式 Map。
  final Map<String, dynamic> scope;

  /// 发布方插件 id（同一插件的其他窗口据此判断自环）。
  final String originPluginId;

  /// 投递状态（[StationDeliveryState]）。
  final StationDeliveryState state;

  /// 该 topic 内的单调序号（非 `data` 态可缺省）。
  final int? seq;

  /// 可读原因（`closed` 等终止态必带）。
  final String? reason;

  /// 背压起点：队列溢出时 UI 应从这个序号之后重新拉快照。
  final int? fromSeq;

  /// 从 `data` 载荷解析（缺失字段归一化，未知字段忽略）。
  ///
  /// 未知 `state` **回退为 [StationDeliveryState.data]**：与前端既有
  /// 「未知枚举回退默认」口径一致，避免一个新增状态把整帧丢掉。
  factory StationDelivery.fromJson(Map<String, dynamic> json) {
    final Object? rawTopic = json['topic'];
    final Object? rawScope = json['scope'];
    final Object? rawSeq = json['seq'];
    final Object? rawReason = json['reason'];
    final Object? rawFromSeq = json['from_seq'];
    return StationDelivery(
      stationId: _asString(json['station_id']),
      point: _asString(json['point']),
      topic: rawTopic?.toString(),
      payload: json['payload'],
      scope: rawScope is Map
          ? Map<String, dynamic>.from(rawScope)
          : const <String, dynamic>{},
      originPluginId: _asString(json['origin_plugin_id']),
      state:
          StationDeliveryState.tryParse(json['state']) ??
          StationDeliveryState.data,
      seq: _asInt(rawSeq),
      reason: rawReason?.toString(),
      fromSeq: _asInt(rawFromSeq),
    );
  }

  /// 从完整 WS 帧解析（`type` 不匹配返回 null）。
  ///
  /// 兼容两种承载：帧顶层平铺（本协议采用）与 `data` 包裹（与 `ui.hello`
  /// 等点号帧同风格）；解析只做宽容读取，不影响 [toFrame] 的产出形状。
  static StationDelivery? fromFrame(Map<String, dynamic> frame) {
    if (frame['type'] != StationWsFrames.delivery) {
      return null;
    }
    final Object? data = frame['data'];
    return StationDelivery.fromJson(
      data is Map ? Map<String, dynamic>.from(data) : frame,
    );
  }

  /// 载荷 JSON（可选字段缺省时省略，避免用空串伪造「有值」）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'station_id': stationId,
    'point': point,
    if (topic != null) 'topic': topic,
    'payload': payload,
    'scope': scope,
    'origin_plugin_id': originPluginId,
    'state': state.wire,
    if (seq != null) 'seq': seq,
    if (reason != null) 'reason': reason,
    if (fromSeq != null) 'from_seq': fromSeq,
  };

  /// 完整 WS 帧（平铺，与 `msg_chunk` 等下行帧同构）。
  Map<String, dynamic> toFrame() => <String, dynamic>{
    'type': StationWsFrames.delivery,
    ...toJson(),
  };

  @override
  String toString() =>
      'StationDelivery(${stationId.toString()}, state=${state.wire}, '
      'topic=${topic ?? '-'}, seq=${seq ?? '-'})';
}

/// **topic 约定**：`<plugin_id>.<session_id>.<kind>`（设计文档 §6.7）。
///
/// 例：`tree.agent.s123.chunk`。核心不解析 topic 的语义，只按订阅过滤与
/// 原样透传；本类只提供两侧都要用的拼接口径，避免 UI 与插件各写一套。
///
/// **解析方向刻意从右往左**：`plugin_id` 自身可以带点（`tree.agent`），
/// 因此不能简单按三段落取；约定 `kind` 与 `session_id` 都不含点，
/// 从右侧切两刀后剩下的整体才是 `plugin_id`。
abstract final class StationTopic {
  /// 拼接三段（任一段为空 ⇒ [ArgumentError]，空 topic 无法被订阅匹配）。
  static String join({
    required String pluginId,
    required String sessionId,
    required String kind,
  }) {
    final String p = pluginId.trim();
    final String s = sessionId.trim();
    final String k = kind.trim();
    if (p.isEmpty || s.isEmpty || k.isEmpty) {
      throw ArgumentError.value(
        '$p.$s.$k',
        'topic',
        'plugin_id / session_id / kind 三段都不能为空',
      );
    }
    return '$p.$s.$k';
  }

  /// 解析三段；不足三段或任一段为空返回 null（宽容，调用方跳过该帧）。
  static StationTopicParts? parse(String topic) {
    final List<String> parts = topic.trim().split('.');
    if (parts.length < 3) {
      return null;
    }
    final String kind = parts.last.trim();
    final String sessionId = parts[parts.length - 2].trim();
    final String pluginId = parts.sublist(0, parts.length - 2).join('.').trim();
    if (pluginId.isEmpty || sessionId.isEmpty || kind.isEmpty) {
      return null;
    }
    return StationTopicParts(
      pluginId: pluginId,
      sessionId: sessionId,
      kind: kind,
    );
  }
}

/// [StationTopic.parse] 的结果。
class StationTopicParts {
  const StationTopicParts({
    required this.pluginId,
    required this.sessionId,
    required this.kind,
  });

  /// 发布方插件 id（可含点）。
  final String pluginId;

  /// 会话 id。
  final String sessionId;

  /// 事件种类（如 `chunk` / `tool_start`）。
  final String kind;

  @override
  String toString() => '$pluginId.$sessionId.$kind';
}

/// 字符串归一（缺失 ⇒ 空串）。
String _asString(Object? value) => value == null ? '' : value.toString();

/// 整数归一（非数值 ⇒ null；`0` 是合法序号，不能用真假值判断）。
int? _asInt(Object? value) => value is num ? value.toInt() : null;
