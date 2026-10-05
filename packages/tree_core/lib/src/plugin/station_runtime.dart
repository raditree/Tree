/// 站点运行时类型（M9 §3）：订阅者、请求/回包、活性探针、投递结果、分类计数。
///
/// 「触发 = 实例的一个方法」：这些类型只描述**一次触发**的输入输出，站点实例
/// （station_instance.dart）持有它们并负责投递/汇聚/部分结果语义。
library;

import 'dart:async';

import 'station_schema.dart';
import 'station_scope.dart';

/// 订阅者身份 = **plugin_id + scope 四元组**（用户定稿）。
///
/// 同一插件在不同 scope 上是不同订阅者；持久化只存身份与时间，
/// 回包函数（StationResponder）是运行时的，不落盘。
class StationSubscriber {
  const StationSubscriber({
    required this.pluginId,
    required this.scope,
    this.subscribedAt = 0,
  });

  /// 插件 id（下线时由总线按此注销其全部订阅）。
  final String pluginId;

  /// 订阅声明 scope（可**更细**于消息 scope，但不得放大；见 StationIsolation）。
  final StationScope scope;

  /// 订阅时间（epoch 秒）。
  final int subscribedAt;

  /// 订阅键位（同一站内唯一）。
  String get key => '$pluginId|${scope.key}';

  /// 序列化（落盘）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'plugin_id': pluginId,
    'scope': scope.toJson(),
    'subscribed_at': subscribedAt,
  };

  /// 宽容解析（缺 plugin_id / 非 Map 时返回 null）。
  static StationSubscriber? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final String pluginId = (raw['plugin_id'] ?? '').toString().trim();
    if (pluginId.isEmpty) return null;
    final StationScope scope = StationScope.parse(raw['scope']);
    final Object? at = raw['subscribed_at'];
    return StationSubscriber(
      pluginId: pluginId,
      scope: scope,
      subscribedAt: at is num ? at.toInt() : 0,
    );
  }

  /// 前端快照形状（与既有 PluginStationSub 的宽容解析对齐）。
  Map<String, dynamic> describe() => <String, dynamic>{
    'subscriber': key,
    'plugin_id': pluginId,
    'granularity': _granularity,
    'scope': scope.toJson(),
  };

  String get _granularity {
    if (scope.sessionId.isNotEmpty) return 'session';
    if (scope.agentId.isNotEmpty) return 'agent';
    return 'team';
  }
}

/// 订阅者回包函数：站点把请求投给订阅者，订阅者回 StationReply。
///
/// 实现可以是进程内闭包（测试 / 假总线），也可以是经插件宿主 stdio 通道的
/// JSON-RPC 往返（生产路径）。
typedef StationResponder = Future<StationReply> Function(
  StationRequest request,
);

/// 站点请求（站 → 订阅者；也会被序列化后经 stdio 推给插件进程）。
class StationRequest {
  const StationRequest({
    required this.requestId,
    required this.stationId,
    required this.kind,
    required this.scope,
    this.payload,
    this.meta = const <String, dynamic>{},
    this.schema,
  });

  /// 请求 id（回包关联用；插件应原样回传）。
  final String requestId;

  /// 站点实例 id。
  final String stationId;

  /// 站点类型。
  final StationKind kind;

  /// 消息 scope 四元组（隔离校验的唯一依据）。
  final StationScope scope;

  /// 请求体：
  /// - 广播站 = 广播载荷；
  /// - 中转站 = 待处理数据（回包即回填）；
  /// - 收集站 = 采集请求（可空；schema 才是产出格式的权威）。
  final Object? payload;

  /// 附带信息（收集站的「站点 --（附带信息，可选）--> 订阅者」）。
  final Map<String, dynamic> meta;

  /// 收集站 schema（订阅者必须按它产出；其它站为 null）。
  final StationSchema? schema;

  /// 序列化（stdio 报文 / 日志）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'request_id': requestId,
    'station_id': stationId,
    'kind': kind.wire,
    'scope': scope.toJson(),
    'payload': payload,
    if (meta.isNotEmpty) 'meta': meta,
    if (schema != null) 'schema': schema!.toJson(),
  };
}

/// 站点回包（订阅者 → 站）。
///
/// - 收集站：payload = **目标数据**（按 schema 产出；站点校验）；
/// - 中转站：payload = str 时回填（替换原数据），null 时「不改动」放行原数据；
/// - 广播站：payload 仅作为送达确认（多数订阅者回空即可）。
class StationReply {
  const StationReply.ok([this.payload, this.reason = '']) : error = '';

  const StationReply.failed(this.error) : payload = null, reason = '';

  /// 回包内容（语义随站点类型）。
  final Object? payload;

  /// 失败原因（可读中文；成功时为空串）。
  final String error;

  /// **"我为什么这么回"的可读原因**（可选；纯增量字段）。
  ///
  /// 语义：`payload == null`（= 不改动、原数据放行）时用它说明**为什么没接管**——
  /// 核心会把它写进日志与压缩结论（`relay_skip_reason` / 会话提示）。没有它，
  /// "插件白跑一次、核心悄悄兜底"就是事后无法诊断的黑洞。
  final String reason;

  /// 是否失败。
  bool get isFailed => error.isNotEmpty;

  /// 宽容解析插件回包（stdio 形状：`{ok, payload}` / `{error}` / 可选 `reason`）。
  static StationReply fromJson(Object? raw) {
    if (raw is! Map) {
      return const StationReply.failed('回包不是对象（键值映射）');
    }
    final String error = (raw['error'] ?? '').toString();
    if (error.isNotEmpty) return StationReply.failed(error);
    return StationReply.ok(raw['payload'], (raw['reason'] ?? '').toString());
  }
}

/// 订阅者活性状态（心跳判活对站点的投影）。
class StationLivenessState {
  const StationLivenessState({
    required this.known,
    required this.alive,
    this.detail = '',
  });

  /// 无活性信息（例如订阅者是进程内假实现）：站点退回「活性窗口」兜底。
  const StationLivenessState.unknown()
    : known = false,
      alive = false,
      detail = '';

  /// 心跳正常。
  const StationLivenessState.alive() : known = true, alive = true, detail = '';

  /// 心跳丢失 / 已下线。
  const StationLivenessState.lost(String reason)
    : known = true,
      alive = false,
      detail = reason;

  /// 是否有活性信息。
  final bool known;

  /// 是否活着。
  final bool alive;

  /// 说明（可读中文）。
  final String detail;
}

/// 活性探针：按插件 id 查询心跳判活结果。
typedef StationLivenessProbe = StationLivenessState Function(String pluginId);

/// 一次订阅的结果（先到先得 / 上限拒绝 / 显式替换都从这里回报）。
class StationSubResult {
  const StationSubResult.accepted({this.replacedPluginId = ''})
    : ok = true,
      error = '',
      code = '';

  const StationSubResult.rejected(this.error, {this.code = ''})
    : ok = false,
      replacedPluginId = '';

  /// 是否订阅成功。
  final bool ok;

  /// 拒绝原因（可读中文）。
  final String error;

  /// 机器可读的拒绝码（subscription_limit / key_conflict / not_subscribable / ...）。
  final String code;

  /// 被替换掉的旧订阅插件 id（先到先得 + 显式 replace 时非空）。
  final String replacedPluginId;

  /// 订阅结果的可读描述（回报调用方 / 日志）。
  String describe(String stationId) => ok
      ? '订阅成功：$stationId'
            '${replacedPluginId.isEmpty ? '' : '（已替换原订阅者 $replacedPluginId）'}'
      : '订阅被拒：$stationId —— $error';
}

/// 单次投递的结论（广播站 / 收集站共用）。
class StationDelivery {
  const StationDelivery({
    required this.subscriber,
    required this.ok,
    this.error = '',
    this.payload,
  });

  /// 目标订阅者。
  final StationSubscriber subscriber;

  /// 是否送达成功。
  final bool ok;

  /// 失败原因（可读中文）。
  final String error;

  /// 订阅者回包内容（成功时）。
  final Object? payload;

  /// 目标插件 id。
  String get pluginId => subscriber.pluginId;

  /// 可读描述。
  String describe() => ok ? '$pluginId 已送达' : '$pluginId 投递失败：$error';
}

/// 广播站一次发布的结果。
class StationPublishResult {
  const StationPublishResult({
    required this.topic,
    required this.boardSeq,
    this.deliveries = const <StationDelivery>[],
    this.skipped = const <String>[],
  });

  /// 主题。
  final String topic;

  /// 公告板序号（持久公告板；0 = 未入板）。
  final int boardSeq;

  /// 各订阅者的投递结果。
  final List<StationDelivery> deliveries;

  /// 因隔离校验被跳过（fail-closed）的可读原因；空 = 没有被跳过。
  final List<String> skipped;

  /// 成功送达的订阅者数。
  int get delivered => deliveries.where((StationDelivery d) => d.ok).length;

  /// 可读摘要。
  String describe() {
    final StringBuffer out = StringBuffer('广播 $topic：送达 $delivered 个订阅者');
    if (boardSeq > 0) out.write('（公告板 #$boardSeq）');
    for (final StationDelivery d in deliveries) {
      if (!d.ok) out.write('；${d.describe()}');
    }
    for (final String reason in skipped) {
      out.write('；$reason');
    }
    return out.toString();
  }
}

/// 执行站命令处理器：挂载位置实现（前端执行器 / 插件 / 系统内置皆可挂载）。
typedef StationCommandHandler = Future<StationCommandOutcome> Function(
  StationCommandContext context,
);

/// 执行站命令的调用上下文。
class StationCommandContext {
  const StationCommandContext({
    required this.command,
    required this.arguments,
    required this.scope,
    required this.stationId,
    this.sourcePluginId = '',
  });

  /// 命令名（白名单内，如 fs.read / ui.push）。
  final String command;

  /// 命令参数（插件给的原始 JSON 对象）。
  final Map<String, dynamic> arguments;

  /// 消息 scope 四元组（已通过隔离校验）。
  final StationScope scope;

  /// 站点实例 id。
  final String stationId;

  /// 下命令的插件 id（空 = 系统内置调用；ui.push 的卡片归属靠它）。
  final String sourcePluginId;
}

/// 挂载位置的执行结果。
class StationCommandOutcome {
  const StationCommandOutcome.ok([this.payload]) : error = '';

  const StationCommandOutcome.failed(this.error) : payload = null;

  /// **失败，但把载荷一起带回去**：用于"命令确实跑起来了、只是产出不可用"的情形
  /// （典型：`llm.call` 拿到 200、模型正文却解析不出 JSON）。
  ///
  /// [payload] 里放**诊断 + 自愈所需**的原始产出（模型正文、长度、疑似截断标记…）：
  /// 只回一句 `error` 等于把那次**已经付过钱**的调用彻底丢掉——现场就是一次 734k
  /// prompt（≈100% 命中缓存）的总结解析失败后整包被弃、回退内置压缩
  /// （见 `docs/known-issues.md` #31）。
  const StationCommandOutcome.failedWith(this.error, this.payload);

  /// 结果载荷（回给下命令的插件）。
  final Object? payload;

  /// 失败原因（可读中文）。
  final String error;

  /// 是否失败。
  bool get isFailed => error.isNotEmpty;
}

/// 执行站一次命令的结果（**不订阅、不触发插件**：这里只有挂载位置的执行结论）。
class StationCommandResult {
  const StationCommandResult({
    required this.command,
    required this.ok,
    this.mountId = '',
    this.payload,
    this.error = '',
  });

  /// 命令名。
  final String command;

  /// 是否执行成功。
  final bool ok;

  /// 实际执行该命令的挂载位置（空 = 未挂载）。
  final String mountId;

  /// 挂载位置返回的结果。
  ///
  /// **失败时也可能非空**：`StationCommandOutcome.failedWith(error, payload)`
  /// 的载荷会原样带到这里再回给插件（"命令没跑成 ≠ 产出没价值"）。
  final Object? payload;

  /// 拒绝 / 失败原因（可读中文）。
  final String error;

  /// 可读摘要。
  String describe() =>
      ok ? '命令 $command 已由挂载位置 $mountId 执行' : '命令 $command 被拒/失败：$error';
}

/// 中转站一次回填的结果（fail-open：任何异常路径都放行原数据）。
class StationRelayResult {
  const StationRelayResult({
    required this.data,
    required this.handled,
    this.pluginId = '',
    this.reason = '',
    this.requestId = '',
  });

  /// 最终数据：回填成功 = 订阅者给的新数据；其余情况 = **原数据放行**。
  final Object? data;

  /// 是否真的被订阅者处理并回填。
  final bool handled;

  /// 处理者插件 id（未处理时为空串）。
  final String pluginId;

  /// 未处理原因（可读中文；成功时为空串）。
  final String reason;

  /// 这次投递的请求 id（插件在 `station/stream` 里用它关联**流式回填**）。
  ///
  /// 只有真的投出去过（有订阅者、走到了请求构造）才非空。
  final String requestId;

  /// 可读摘要。
  String describe() => handled ? '中转 $pluginId 已回填' : '中转未处理（原数据放行）：$reason';
}

/// 收集站收到的一条合格产出（= 触发方后续处理的输入）。
class StationCollectedItem {
  const StationCollectedItem({required this.subscriber, required this.payload});

  /// 产出方。
  final StationSubscriber subscriber;

  /// 目标数据（已通过 schema 校验）。
  final Object? payload;

  /// 来源插件 id（**按来源 plugin_id 路由**的依据）。
  String get pluginId => subscriber.pluginId;
}

/// 收集站的一个未响应者（**显式列出，不静默**）。
class StationUnresponsive {
  const StationUnresponsive({required this.subscriber, required this.reason});

  /// 未响应的订阅者。
  final StationSubscriber subscriber;

  /// 未响应原因（心跳丢失 / 窗口内无回 / schema 校验失败 / 回包报错）。
  final String reason;

  /// 插件 id。
  String get pluginId => subscriber.pluginId;
}

/// 收集站一次采集的结果：**部分结果 + 未响应者清单**（不静默、不阻塞、不整体失败）。
class StationCollectResult {
  const StationCollectResult({
    this.items = const <StationCollectedItem>[],
    this.unresponsive = const <StationUnresponsive>[],
    this.skipped = const <String>[],
  });

  /// 已收集到的合格产出。
  final List<StationCollectedItem> items;

  /// 未响应者（含可读原因）。
  final List<StationUnresponsive> unresponsive;

  /// 因隔离校验被跳过（fail-closed）的可读原因。
  final List<String> skipped;

  /// 是否全部订阅者都给了合格产出。
  bool get complete => unresponsive.isEmpty;

  /// 是否收到了至少一条产出。
  bool get hasItems => items.isNotEmpty;

  /// 可读摘要（触发方可以直接回给模型 / 写日志）。
  String describe() {
    final StringBuffer out = StringBuffer('收集到 ${items.length} 条');
    if (unresponsive.isNotEmpty) {
      out.write('；未响应 ${unresponsive.length} 个：');
      out.write(
        unresponsive
            .map((StationUnresponsive u) => '${u.pluginId}（${u.reason}）')
            .join('、'),
      );
    }
    for (final String reason in skipped) {
      out.write('；$reason');
    }
    return out.toString();
  }
}

/// 站点分类计数（对齐旧后端的计数键；前端面板只白名单展示其中一部分）。
class StationCounters {
  /// 计数键白名单（同时是「合法键」清单，未知键也会被记录但前端不展示）。
  static const List<String> known = <String>[
    'requests',
    'responded',
    'timeout',
    'cancelled',
    'no_subscriber',
    'overflow',
    'handler_error',
    'invalid_response',
    'rejected_conflict',
    'unsubscribed',
    'skipped_scope',
    'delivered',
  ];

  final Map<String, int> _values = <String, int>{};

  /// 取值（不存在的键为 0）。
  int operator [](String key) => _values[key] ?? 0;

  /// 累加一次。
  void bump(String key, [int delta = 1]) {
    _values[key] = (_values[key] ?? 0) + delta;
  }

  /// 快照（前端面板读 counts）。
  Map<String, dynamic> describe() => <String, dynamic>{..._values};

  /// 清空（测试 / 重置用）。
  void clear() => _values.clear();
}
