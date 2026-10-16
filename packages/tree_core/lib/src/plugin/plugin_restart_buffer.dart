import 'dart:async';
import 'dart:convert';

import 'station_runtime.dart' show StationReply, StationRequest;

/// 站点请求的**投递动作**（拿到就绪的宿主之后真正发出去的那一步）。
typedef StationDeliverer = Future<StationReply> Function(
  StationRequest request,
);

/// 重启窗口里被拦下的一条站点请求。
///
/// 为什么连 [deliver] 一起存：请求本身是**不可重放的事实**（payload / scope /
/// request_id 都是触发那一刻的），而"怎么投"由订阅那一刻的闭包决定（延迟解析宿主）。
/// 只存请求不存投递动作，重放时就得重新找一遍订阅者——那是第二套投递逻辑，会漂移。
class QueuedStationRequest {
  QueuedStationRequest({
    required this.request,
    required this.deliver,
    required this.bytes,
    DateTime? queuedAt,
    this.pluginId = '',
  }) : queuedAt = queuedAt ?? DateTime.now();

  final StationRequest request;
  final StationDeliverer deliver;
  final int bytes;
  final DateTime queuedAt;
  final String pluginId;

  /// 等待投递结果的那只 future（调用方一直挂着 = 对外"插件正常"的关键）。
  final Completer<StationReply> outcome = Completer<StationReply>();

  /// 已经被结过账（重放完 / 被丢掉），队列里不必再算它一份。
  bool settled = false;
}

/// **重启期保活的有界暂存队列**（20261015-hot-restart 阶段 2）。
///
/// 解决的问题：插件热重启的那几百毫秒里，站点请求要么撞上"实例不在"当场失败
/// （用户看到的是"装了插件却偶尔掉一次"），要么无界堆积（重启风暴把内存撑爆）。
/// 这里的口径是**两者都不选**：有界暂存 + ready 后 FIFO 重放，溢出走既有 fail-open。
///
/// 为什么溢出选 fail-open 而不是"排队等着"或"报错"：每个接入点本来就有"插件没接管
/// 时系统自己怎么干"的兜底（中转站放行原数据 / SSH 回退内置 dartssh2 / 收集站退回
/// tools/list）。把"没接住"变成一句错误只会让会话多一次失败重试；放行原数据
/// 才是既有语义。代价要说清楚：**兜底那次的数据不会再被这个插件看到**，所以每次
/// 溢出都写进日志与 `droppedCount`，不静默（不变量 6）。
///
/// 为什么不设"最多等多久"：那是时长判死（不变量 4 / D8 同一口径）。这里的两个界都是
/// **数量与字节**，收尾靠**事件**：ready ⇒ 重放；failed/stopped/核心退出 ⇒ 以可读失败收尾。
class PluginRestartBuffer {
  PluginRestartBuffer({
    this.maxPerPlugin = 32,
    this.maxTotalBytes = 1 << 20,
    this.log,
  });

  /// 单个插件的在队上限（条数）。32 条的来源：一次重启窗口通常只有一两个点位在触发，
  /// 32 足够覆盖"会话连着几跳 + 工具改写 + 广播"，再多就说明这个插件已经不该被等下去了。
  final int maxPerPlugin;

  /// 全部插件的在队字节上限（估算值：`jsonEncode` 的长度）。
  final int maxTotalBytes;

  void Function(String message)? log;

  final Map<String, List<QueuedStationRequest>> _queues =
      <String, List<QueuedStationRequest>>{};

  int _totalBytes = 0;
  int _queuedCount = 0;
  int _replayedCount = 0;
  int _droppedCount = 0;
  int _overflowCount = 0;

  /// 累计入队 / 重放 / 丢掉 / 溢出拒收的条数（用例与面板都靠这些数说话）。
  int get queuedCount => _queuedCount;
  int get replayedCount => _replayedCount;
  int get droppedCount => _droppedCount;
  int get overflowCount => _overflowCount;

  /// 当前在队的总字节（估算）。
  int get totalBytes => _totalBytes;

  /// 某插件当前在队的条数（不含已结账的）。
  int lengthOf(String pluginId) =>
      (_queues[pluginId] ?? const <QueuedStationRequest>[]).length;

  /// 队列里是否还有东西（任何一个插件）。
  bool get isEmpty =>
      _queues.values.every((List<QueuedStationRequest> q) => q.isEmpty);

  /// **入队**并返回"最终投递结果"的 future。
  ///
  /// 溢出时**不排队**：立即回一个 [StationReply.failed]（带可读原因），调用方据此
  /// 走既有 fail-open。这就是"绝不无界堆积"与"绝不静默"两条的合流点。
  Future<StationReply> push(
    String pluginId,
    StationRequest request,
    StationDeliverer deliver,
  ) async {
    final int bytes = _estimateBytes(request);
    final List<QueuedStationRequest> queue = _queues.putIfAbsent(
      pluginId,
      () => <QueuedStationRequest>[],
    );
    if (queue.length >= maxPerPlugin) {
      return _overflow(pluginId, request, '在队 $maxPerPlugin 条（每插件上限）');
    }
    if (_totalBytes + bytes > maxTotalBytes) {
      return _overflow(
        pluginId,
        request,
        '全局在队 $_totalBytes + 本条 $bytes 超出上限 $maxTotalBytes 字节',
      );
    }
    final QueuedStationRequest item = QueuedStationRequest(
      request: request,
      deliver: deliver,
      bytes: bytes,
      pluginId: pluginId,
    );
    queue.add(item);
    _totalBytes += bytes;
    _queuedCount++;
    return item.outcome.future;
  }

  /// ready 后**按 FIFO 重放**（调用方不许再自己排一次序：Map/List 的顺序就是入队顺序）。
  ///
  /// [stillValid] 逐条复查——重放不是无条件的事：
  /// ① 已被取消的 request_id 按"迟到无害"丢弃（与 `station/cancel` 同一口径）；
  /// ② scope 与这个插件当前的归属不再一致 ⇒ 丢（fail-closed：宁可放行原数据，
  ///    也不把 A 工作面的请求递到 B 工作面上）。
  /// 复查查不出问题时才真的投递。
  Future<void> replay(
    String pluginId, {
    required StationDeliverer deliver,
    bool Function(QueuedStationRequest item)? stillValid,
    String invalidReason = '这条请求在重启窗口里已经失效（取消或归属变了）',
  }) async {
    final List<QueuedStationRequest> pending = List<QueuedStationRequest>.from(
      _queues[pluginId] ?? const <QueuedStationRequest>[],
    );
    if (pending.isEmpty) return;
    _queues[pluginId]!.removeWhere(
      (QueuedStationRequest e) => pending.contains(e),
    );
    for (final QueuedStationRequest item in pending) {
      _totalBytes -= item.bytes;
      final StationReply? invalid = _validate(item, stillValid, invalidReason);
      if (invalid != null) {
        // 复查丢掉的也算“没接住”：不计进 dropped 的话，面板上会看起来“一条都没丢”，
        // 而实际上有一条请求被重放规则筛掉了（不变量 6：发生过的事必须看得见）。
        _droppedCount++;
        _settle(item, invalid);
        continue;
      }
      // 重放用的是**新一世的投递闭包**（旧闭包握着的是已经退掉的那个宿主）
      try {
        _settle(item, await deliver(item.request));
        _replayedCount++;
      } catch (error) {
        _settle(item, StationReply.failed('重启后重放失败：$error'));
      }
    }
  }

  /// 以可读失败收尾（重启失败 / 插件被停用 / 核心退出 / 心跳判死）。
  ///
  /// 返回值 = 被结掉的条数。这里的每一处都写日志：**"我等的东西没等到"必须是能查到的事**。
  int abandon(String pluginId, String reason) {
    final List<QueuedStationRequest> queue =
        _queues.remove(pluginId) ?? <QueuedStationRequest>[];
    for (final QueuedStationRequest item in queue) {
      _totalBytes -= item.bytes;
      _droppedCount++;
      _settle(item, StationReply.failed(reason));
    }
    if (queue.isNotEmpty) {
      log?.call('丢弃插件 $pluginId 的 ${queue.length} 条暂存站点请求：$reason');
    }
    return queue.length;
  }

  /// 全部插件一并收尾（核心退出路径；不留永不完成的 future）。
  int abandonAll(String reason) {
    int dropped = 0;
    for (final String pluginId in _queues.keys.toList(growable: false)) {
      dropped += abandon(pluginId, reason);
    }
    return dropped;
  }

  /// 只读水位（面板 / 广播载荷用；不回 payload 内容）。
  Map<String, dynamic> readings() => <String, dynamic>{
    'queued': _queues.values.fold<int>(
      0,
      (int s, List<QueuedStationRequest> q) => s + q.length,
    ),
    'bytes': _totalBytes,
    'max_per_plugin': maxPerPlugin,
    'max_total_bytes': maxTotalBytes,
    'per_plugin': <String, int>{
      for (final MapEntry<String, List<QueuedStationRequest>> e
          in _queues.entries)
        if (e.value.isNotEmpty) e.key: e.value.length,
    },
    'replayed': _replayedCount,
    'dropped': _droppedCount,
    'overflowed': _overflowCount,
  };

  StationReply? _validate(
    QueuedStationRequest item,
    bool Function(QueuedStationRequest item)? stillValid,
    String invalidReason,
  ) {
    if (stillValid != null && !stillValid(item)) {
      return StationReply.failed(invalidReason);
    }
    return null;
  }

  void _settle(QueuedStationRequest item, StationReply reply) {
    if (item.settled) return;
    item.settled = true;
    if (!item.outcome.isCompleted) item.outcome.complete(reply);
  }

  Future<StationReply> _overflow(
    String pluginId,
    StationRequest request,
    String why,
  ) {
    final String reason =
        '插件 $pluginId 重启窗口里暂存队列已满：$why ⇒ 这条 '
        '${request.stationId} 请求不再等待，按 fail-open 放行原数据/回退内置';
    log?.call(reason);
    _overflowCount++;
    _droppedCount++;
    return Future<StationReply>.value(StationReply.failed(reason));
  }

  /// 字节估算是**估算**：payload 里可能有不可 jsonEncode 的对象，估不出来就按 0 计，
  /// 绝不让一条遥测把投递路径炸掉（与用量账本同一 fail-open 口径）。
  int _estimateBytes(StationRequest request) {
    try {
      return jsonEncode(request.toJson()).length;
    } catch (_) {
      return 0;
    }
  }
}
