/// **站点 → 订阅者**的投递通道抽象（片 B）。
///
/// 站点运行时只关心「把 [StationRequest] 交给订阅者」；具体怎么交，随订阅者
/// 的形态不同：
/// - stdio 插件：走既有 `PluginHost.requestStation`（请求/回包关联，行为逐字不变）；
/// - WS（UI 插件）：单向推送 `station_delivery` 帧，立即回 [StationReply.ok]。
///
/// 抽成接口而不是在站点里堆 if：站点实例不应该知道传输层；以后再加一种订阅者
/// （例如进程内嵌入）只需实现本接口。
library;

import 'dart:async';

import 'package:tree_protocol/tree_protocol.dart' as protocol;

import 'station_scope.dart';
import 'station_runtime.dart';

/// 站点 → 订阅者的投递通道。
abstract interface class StationSubscriberChannel {
  /// 连接维度（stdio 为空串；WS 为连接 id）。
  ///
  /// 它与 `StationSubscriber.channelId` 同值，用来把「订阅身份键」与
  /// 「投递通道」对上号。
  String get channelId;

  /// 投递一次请求。广播站把回包仅当送达确认。
  Future<StationReply> deliver(StationRequest request);
}

/// stdio 插件通道：**完全复用**既有的请求/回包通道。
///
/// 这里只做一层薄包装（把闭包适配成接口），不改变任何缓冲、超时、错误文本
/// 或重试语义——旧插件看到的行为与片 B 之前逐字一致。
class StdioStationSubscriberChannel implements StationSubscriberChannel {
  const StdioStationSubscriberChannel(this._deliver);

  final Future<StationReply> Function(StationRequest request) _deliver;

  @override
  String get channelId => '';

  @override
  Future<StationReply> deliver(StationRequest request) => _deliver(request);
}

/// WS（UI 插件）通道：把请求映射为 `station_delivery` 帧。
///
/// **seq 口径**：`seq` 按「每连接 × 每站点订阅」各自从 1 递增（不是全局序号、
/// 不跨订阅共享）。为什么选这个口径：一个订阅就是一条独立水流，UI 只需要在
/// 自己这条订阅上按序消费；同一 topic 在这条订阅内天然单调（被 `topics`
/// 过滤掉的帧不占号）。插件重启 / 重新订阅时从 1 重新开始，桥会先发 `reset`
/// （见 [emitReset]）让 UI 清空本地水位。
///
/// **背压**：同一条连接的所有订阅共用一个**有界队列**（默认 1024 帧）。溢出时
/// 清掉尚未发出的帧，并为每条受影响订阅插入 `lagged`（`from_seq` = 该订阅
/// 最早被丢掉的 data 帧序号），绝不静默丢帧。`closed` 是终止态，直接下发并
/// 摘掉该订阅自己的待发帧（不影响同连接的其他订阅）。
class WsStationSubscriberChannel implements StationSubscriberChannel {
  WsStationSubscriberChannel({
    required this.channelId,
    required this.pluginId,
    required this.stationId,
    required this.point,
    required this.scope,
    Iterable<String> topics = const <String>[],
    required void Function(Map<String, dynamic> frame) sink,
    WsConnectionOutbox? outbox,
    this.queueCapacity = WsConnectionOutbox.defaultQueueCapacity,
    this.autoDrain = true,
  }) : topics = List<String>.unmodifiable(<String>[...topics]),
       _outbox =
           outbox ??
           WsConnectionOutbox(
             sink: sink,
             capacity: queueCapacity,
             autoDrain: autoDrain,
           );

  /// 每条连接默认的有界队列长度（设计建议值）。
  static const int defaultQueueCapacity = WsConnectionOutbox.defaultQueueCapacity;

  @override
  final String channelId;

  /// 订阅方插件 id（归属 / 自环判定用）。
  final String pluginId;

  /// 站点全局 id。
  final String stationId;

  /// 内置点位 id；自建站为空串。
  final String point;

  final StationScope scope;

  /// topic 白名单；空 = 不过滤。
  final List<String> topics;

  final int queueCapacity;

  /// 是否自动异步排水（生产为 true；单元测试可关掉以构造溢出）。
  final bool autoDrain;

  final WsConnectionOutbox _outbox;

  /// 与 `StationSubscriber.key` 同构的订阅键位（退订时按它销账）。
  String get subscriberKey => '$pluginId|${scope.key}|channel_id=$channelId';

  int _seq = 0;
  bool _closed = false;

  /// 当前订阅上已发出的最大序号（终止态帧也带它，便于 UI 记录水位）。
  int get lastSeq => _seq;

  /// 待发队列长度（诊断 / 测试）。
  int get pendingCount => _outbox.pendingCount;

  /// 是否已被终止（`closed`）。
  bool get isClosed => _closed;

  @override
  Future<StationReply> deliver(StationRequest request) async {
    if (_closed) {
      // 终止后迟到的帧按“已处理”回执，避免广播发布方把 normal 的关闭
      // 误报成 handler_error。
      return const StationReply.ok();
    }
    final String? topic = request.topic ?? request.meta['topic']?.toString();
    if (topics.isNotEmpty && (topic == null || !topics.contains(topic))) {
      // 过滤发生在投递时（而不是订阅时）：订阅只登记一次，UI 可在同一订阅
      // 上收到多个 topic 的报文，白名单之外的不占 seq。
      return const StationReply.ok();
    }
    _seq += 1;
    _outbox.enqueue(
      owner: this,
      frame: _buildFrame(
        state: protocol.StationDeliveryState.data,
        seq: _seq,
        topic: topic,
        payload: request.payload,
        originPluginId: request.originPluginId,
        // `scope` 原样透传的是**消息信封**，不是订阅声明（订阅声明只决定过滤）。
        messageScope: request.scope,
      ),
      seq: _seq,
      isData: true,
    );
    return const StationReply.ok();
  }

  /// 重新订阅时重置本地水位（`reset` 态，`seq` = 0）。
  void emitReset() {
    if (_closed) return;
    _outbox.enqueue(
      owner: this,
      frame: _buildFrame(
        state: protocol.StationDeliveryState.reset,
        seq: 0,
      ),
      seq: 0,
      isData: false,
    );
  }

  /// 终止订阅：下发 `closed` + 可读原因。
  void close(String reason) {
    if (_closed) return;
    _closed = true;
    _outbox.closeChannel(this, _buildFrame(
      state: protocol.StationDeliveryState.closed,
      seq: _seq == 0 ? null : _seq,
      reason: reason,
    ));
  }

  /// 连接关闭时静默释放：没有对端可通知，不发 `closed`。
  void dispose() {
    _closed = true;
    _outbox.removeChannel(this);
  }

  /// 立即排水（`autoDrain = false` 的测试用；生产由微任务自动排水）。
  void drainNow() => _outbox.drainNow();

  /// 构造一帧 `station_delivery`（本文件内共享；不暴露给桥）。
  Map<String, dynamic> _buildFrame({
    required protocol.StationDeliveryState state,
    int? seq,
    String? topic,
    Object? payload,
    String originPluginId = '',
    String? reason,
    int? fromSeq,
    StationScope? messageScope,
  }) => protocol.StationDelivery(
    stationId: stationId,
    point: point,
    topic: topic,
    payload: payload,
    scope: (messageScope ?? scope).toJson(),
    originPluginId: originPluginId,
    state: state,
    seq: seq,
    reason: reason,
    fromSeq: fromSeq,
  ).toFrame();

  /// 溢出时由 outbox 回调：给出「该订阅最早被丢掉的 data 帧序号」。
  Map<String, dynamic> buildLaggedFrame({
    required int seq,
    required int? fromSeq,
    required int capacity,
  }) => _buildFrame(
    state: protocol.StationDeliveryState.lagged,
    seq: seq,
    fromSeq: fromSeq,
    reason: '单连接投递队列溢出（上限 $capacity 帧）',
  );
}

/// 一条 WS 连接的**有界投递队列**（同连接的多个订阅共享）。
///
/// 队列帧都带 [owner]，因此溢出时能按订阅分别给出 `from_seq`，而不是笼统丢一
/// 整条连接（那会让 UI 不知道哪个站的数据断了）。
class WsConnectionOutbox {
  WsConnectionOutbox({
    required this.sink,
    this.capacity = defaultQueueCapacity,
    this.autoDrain = true,
  });

  /// 每条连接默认的队列长度。
  static const int defaultQueueCapacity = 1024;

  final void Function(Map<String, dynamic> frame) sink;
  final int capacity;
  final bool autoDrain;

  final List<_QueuedFrame> _pending = <_QueuedFrame>[];
  final Set<WsStationSubscriberChannel> _closedChannels =
      <WsStationSubscriberChannel>{};
  bool _draining = false;
  bool _disposed = false;

  /// 待发队列长度。
  int get pendingCount => _pending.length;

  /// 入队一帧；`isData` 为 false 表示 reset 等控制帧。
  void enqueue({
    required WsStationSubscriberChannel owner,
    required Map<String, dynamic> frame,
    required int seq,
    required bool isData,
  }) {
    if (_disposed || _closedChannels.contains(owner)) return;
    if (_pending.length >= capacity) {
      _overflow(current: owner, currentSeq: seq, currentIsData: isData);
    }
    _pending.add(_QueuedFrame(owner, frame, seq, isData));
    if (autoDrain) {
      // 微任务排水：同一事件循环里连续到达的爆发不会立刻写出去，队列才有机会
      // 体现「有界 + 溢出可诊断」；单帧场景下延迟不可感知。
      scheduleMicrotask(drainNow);
    }
  }

  /// 摘掉某订阅的待发帧并直接写 `closed`（终止态不排队）。
  void closeChannel(
    WsStationSubscriberChannel owner,
    Map<String, dynamic> closedFrame,
  ) {
    if (_disposed) return;
    _pending.removeWhere((_QueuedFrame item) => item.owner == owner);
    _closedChannels.add(owner);
    _write(closedFrame);
  }

  /// 连接关闭时摘掉某订阅的待发帧（不发帧）。
  void removeChannel(WsStationSubscriberChannel owner) {
    _pending.removeWhere((_QueuedFrame item) => item.owner == owner);
    _closedChannels.add(owner);
  }

  /// 连接销毁：清空所有待发帧。
  void dispose() {
    _disposed = true;
    _pending.clear();
  }

  /// 立即排水（测试用；生产由微任务自动排水）。
  void drainNow() {
    if (_draining || _disposed) return;
    _draining = true;
    try {
      while (_pending.isNotEmpty) {
        final _QueuedFrame item = _pending.removeAt(0);
        if (_closedChannels.contains(item.owner)) continue;
        _write(item.frame);
      }
    } finally {
      _draining = false;
    }
  }

  /// 溢出：按订阅收集最早被丢的 data 序号 → **直接发** lagged（不进队列，
  /// 否则下一次溢出会把上一次的 lagged 也清掉，等于静默丢诊断）→ 当前帧再入队。
  void _overflow({
    required WsStationSubscriberChannel current,
    required int currentSeq,
    required bool currentIsData,
  }) {
    final Map<WsStationSubscriberChannel, int> firstDropped =
        <WsStationSubscriberChannel, int>{};
    for (final _QueuedFrame item in _pending) {
      if (!item.isData) continue;
      firstDropped.putIfAbsent(item.owner, () => item.seq);
    }
    _pending.clear();
    for (final MapEntry<WsStationSubscriberChannel, int> entry
        in firstDropped.entries) {
      _write(
        entry.key.buildLaggedFrame(
          seq: entry.key.lastSeq,
          fromSeq: entry.value,
          capacity: capacity,
        ),
      );
    }
    if (currentIsData && !firstDropped.containsKey(current)) {
      // 队列里没有当前订阅的旧帧（刚订阅就溢出）：从当前序号之后重拉。
      _write(
        current.buildLaggedFrame(
          seq: currentSeq,
          fromSeq: currentSeq,
          capacity: capacity,
        ),
      );
    }
  }

  void _write(Map<String, dynamic> frame) {
    try {
      sink(frame);
    } catch (_) {
      // 连接已断：后续帧没有接收方，吞掉异常即可（清理路径会 removeChannel）。
    }
  }
}

class _QueuedFrame {
  const _QueuedFrame(this.owner, this.frame, this.seq, this.isData);

  final WsStationSubscriberChannel owner;
  final Map<String, dynamic> frame;
  final int seq;
  final bool isData;
}
