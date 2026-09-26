import 'dart:async';
import 'dart:io';

import 'package:tree_protocol/tree_protocol.dart';

import '../util/liveness.dart';
import '../ws/ws_hub.dart';

/// 带**发送活性**与**待补发队列**的 WS 连接（M9 规约 1.1）。
///
/// 发送口径（用户已确认）：**不做静态超时**——`send` 就是"写出去"，不等确认、
/// 不设 TTL；判活看**连接心跳**：收到任意入站帧（前端每 30s 一次的 heartbeat 就是
/// 最典型的一拍）即续期；连续 [LivenessTracker.maxMisses] 拍什么都没收到 ⇒ 判失活。
///
/// 判活之后**不静默丢帧**：链路判死（或 socket 已断）时，帧转入本连接的待补发
/// 队列，等心跳恢复或前端重连后补发；队列有上限，超出时**计数**丢弃（可见的丢弃，
/// 不是静默丢弃）。
class LivenessWsConnection extends WsConnection {
  LivenessWsConnection({
    required super.socket,
    LivenessTracker? liveness,
    this.maxPendingFrames = 256,
    this.onBeat,
  }) : liveness = liveness ?? LivenessTracker(label: 'WS 连接');

  /// 连接活性台账（心跳 = 收到任意入站帧）。
  final LivenessTracker liveness;

  /// 待补发队列上限（超出丢最旧并计数）。
  final int maxPendingFrames;

  /// 收到一次心跳时的回调（hub 用来维护"全体连接"级别的活性）。
  final void Function()? onBeat;

  final List<Map<String, dynamic>> _pendingResend = <Map<String, dynamic>>[];

  bool _beatSinceTick = false;
  bool _staleReported = false;

  /// 累计"因为链路不活 / 写不出去"而转入待补发的帧数。
  int framesQueuedForResend = 0;

  /// 累计补发出去的帧数。
  int framesResent = 0;

  /// 因队列满而显式丢弃的帧数（有计数 = 不是静默丢弃）。
  int framesDroppedOverflow = 0;

  /// 当前待补发帧数。
  int get pendingResendCount => _pendingResend.length;

  /// 取走待补发帧（连接注销时交给 hub 队列，等重连后补发）。
  List<Map<String, dynamic>> takePendingResend() {
    final List<Map<String, dynamic>> out = List<Map<String, dynamic>>.of(
      _pendingResend,
    );
    _pendingResend.clear();
    return out;
  }

  /// 发送一个业务帧。
  ///
  /// **没有静态超时**：写就写、不等 ack；但**不静默丢**——链路已判死或 socket 已断
  /// 时转入待补发队列（[takePendingResend] / [flushPendingResend]）。
  @override
  void send(Map<String, dynamic> frame) {
    if (!isOpen || liveness.isStale) {
      _enqueue(frame);
      return;
    }
    super.send(frame);
    // 写 socket 抛错时基类会把连接标记为已关闭：这一帧没送出去 ⇒ 登记补发
    if (!isOpen) _enqueue(frame);
  }

  void _enqueue(Map<String, dynamic> frame) {
    framesQueuedForResend++;
    if (_pendingResend.length >= maxPendingFrames) {
      _pendingResend.removeAt(0);
      framesDroppedOverflow++;
    }
    _pendingResend.add(frame);
  }

  /// 收到任意入站帧：链路还在 ⇒ 续期（清除失活标记）。
  void recordBeat([DateTime? at]) {
    _beatSinceTick = true;
    _staleReported = false;
    liveness.recordBeat(at);
    onBeat?.call();
  }

  /// 一拍心跳结算（由 hub 的保活定时器驱动）。
  ///
  /// 本拍收到过任意帧 ⇒ 清零；否则记一次丢失。返回**本拍是否刚刚判死**
  /// （true 只会出现一次，用于日志与触发重连）。
  bool tickHeartbeat() {
    if (_beatSinceTick) {
      _beatSinceTick = false;
      return false;
    }
    final bool staleNow = liveness.recordMiss();
    if (staleNow && !_staleReported) {
      _staleReported = true;
      return true;
    }
    return false;
  }

  /// 把待补发帧重新写出去；返回本次补发条数。
  ///
  /// **没有时间上限**：攒了多久都还会补发（不存在"过期作废"），只有队列上限。
  int flushPendingResend() {
    if (_pendingResend.isEmpty || !isOpen || liveness.isStale) return 0;
    final List<Map<String, dynamic>> queued = takePendingResend();
    int sent = 0;
    while (sent < queued.length) {
      super.send(queued[sent]);
      sent++;
      framesResent++;
      if (!isOpen) break; // 又断了：剩下的继续排队，等下次
    }
    if (sent < queued.length) {
      for (final Map<String, dynamic> frame in queued.skip(sent)) {
        _enqueue(frame);
      }
    }
    return sent;
  }
}

/// WS 连接注册表 + 保活 / 活性判定 + 跨连接补发队列（M9 规约 1.1）。
///
/// 与基类 [WsHub] 的关系（只动发送与心跳，不动任何业务路由）：
/// - 保活定时器除了照旧下发 heartbeat 帧，还负责给每条连接**结算一拍心跳**；
///   连续 N 拍没有任何入站帧 ⇒ 判失活，**显式**上报并把连接关掉（关闭会触发前端
///   的自动重连，这就是"触发重连"；待补发帧在注销时转入 hub 队列，重连后补发）；
/// - [linkLiveness] 是"全体连接"级别的活性（任意连接收到任意帧即续期），供**消息
///   派发 / 发送路径**判活：心跳丢失时派发侧显式报错并登记补发，而不是静默丢弃。
///
/// 两个刻意的取舍（都写进了交付报告）：
/// 1. 前端自己的心跳节奏是 30s（lib/io/websocket_service.dart），所以 WS 侧的
///    判活窗口默认取 30s × 3 = 90s 而不是 10s × 3 = 30s——后者与前端心跳等长，
///    边界抖动会把"在线但空闲"的连接误判失活。前端心跳改成 I=10s 后，这里把
///    [interval] 换成 [LivenessTracker.defaultInterval] 即可回到全局默认口径；
/// 2. **没有连接时不累计丢失**（没人在听 ≠ 心跳丢了），但**已有的失活标记保留**：
///    最后一个前端连接断开即把链路记为失活（[unregister]），断开期间广播的帧因此会
///    进补发队列、重连后补发；而从未有过连接的场景（headless CLI）永远不会判失活，
///    不会卡住消息派发。
class LivenessWsHub extends WsHub {
  LivenessWsHub({
    this.interval = const Duration(seconds: 30),
    int maxMisses = LivenessTracker.defaultMaxMisses,
    this.maxPendingFrames = 512,
  }) : linkLiveness = LivenessTracker(
         label: 'WS 连接（全部）',
         interval: interval,
         maxMisses: maxMisses,
       );

  /// 判活窗口的节拍 I（默认 30s，与前端心跳节奏对齐，见类文档）。
  final Duration interval;

  /// 待补发队列上限。
  final int maxPendingFrames;

  /// 全体连接级别的活性台账（派发 / 发送路径判活用）。
  final LivenessTracker linkLiveness;

  /// 判死回调（日志 / UI / 触发重连），由核心接线。
  void Function(String connectionId, LivenessTracker liveness)? onStale;

  /// 心跳恢复回调（把派发侧登记的待补发消息补出去），由核心接线。
  void Function()? onLinkRecovered;

  final List<Map<String, dynamic>> _pendingResend = <Map<String, dynamic>>[];
  Timer? _probeTimer;
  bool _anyBeatSinceTick = false;
  bool _linkStaleReported = false;

  /// 累计因心跳丢失被判死的连接数。
  int staleConnectionCount = 0;

  /// 累计补发出去的帧数（hub 队列部分）。
  int framesResent = 0;

  /// 因队列满而显式丢弃的帧数。
  int framesDroppedOverflow = 0;

  /// 广播时"一个连接都没有"的帧数：没有连接本身不算失败（没人在听），
  /// 但如果链路已判失活（前端刚断开），这些帧会进补发队列而不是消失。
  int framesWithoutListener = 0;

  /// 当前待补发帧数（断开期间攒下的）。
  int get pendingResendCount => _pendingResend.length;

  /// 已判失活但还没注销的连接 id（观测 / 测试用）。
  List<String> staleConnectionIds() => connections()
      .where(
        (WsConnection c) => c is LivenessWsConnection && c.liveness.isStale,
      )
      .map((WsConnection c) => c.id)
      .toList(growable: false);

  /// 全部补发帧数（各连接 + hub 队列）。
  int totalFramesResent() {
    int total = framesResent;
    for (final WsConnection connection in connections()) {
      if (connection is LivenessWsConnection) total += connection.framesResent;
    }
    return total;
  }

  /// 建一条带活性观测的连接（**不注册**：注册仍走 [register]，与既有调用方一致）。
  LivenessWsConnection createConnection(WebSocket socket) =>
      LivenessWsConnection(
        socket: socket,
        liveness: LivenessTracker(
          label: 'WS 连接',
          interval: interval,
          maxMisses: linkLiveness.maxMisses,
        ),
        maxPendingFrames: maxPendingFrames,
        onBeat: _onConnectionBeat,
      );

  @override
  void register(WsConnection connection) {
    super.register(connection);
    // 新连接 = 有客户端在听（比任何一帧都硬的心跳证据）：清除失活并触发补发
    final bool wasStale = linkLiveness.isStale;
    _anyBeatSinceTick = true;
    _linkStaleReported = false;
    linkLiveness.recordBeat();
    if (wasStale) onLinkRecovered?.call();
  }

  @override
  void unregister(String connectionId) {
    for (final WsConnection connection in connections()) {
      if (connection.id != connectionId) continue;
      if (connection is LivenessWsConnection) {
        // 断开时把"没送出去"的帧收进 hub 队列：重连后补发（不静默丢）
        _pendingResend.addAll(connection.takePendingResend());
        _trimPending();
      }
      break;
    }
    super.unregister(connectionId);
    if (connectionCount == 0) _markLinkLost();
  }

  @override
  void broadcast(Map<String, dynamic> frame) {
    if (connectionCount == 0) {
      framesWithoutListener++;
      // 断开期间（链路已判失活）的帧**登记补发**：不然前端重连后再也看不到它们，
      // 那就是静默丢弃。补发队列没有时间上限，重连时原样写出。
      if (linkLiveness.isStale) _enqueuePending(frame);
      return;
    }
    super.broadcast(frame);
  }

  /// 启动保活 + 活性判定：每 [interval] 一拍。
  ///
  /// 间隔非正 = 关闭（等价于原来的 enableHeartbeat: false，行为与旧版一致：
  /// 不下发保活帧，也不判活）。
  @override
  void startHeartbeat({Duration? interval}) {
    stopHeartbeat();
    final Duration cadence = interval ?? this.interval;
    if (cadence <= Duration.zero) return;
    _probeTimer = Timer.periodic(cadence, (Timer _) => _tick());
  }

  @override
  void stopHeartbeat() {
    _probeTimer?.cancel();
    _probeTimer = null;
    super.stopHeartbeat();
  }

  @override
  Future<void> closeAll() async {
    stopHeartbeat();
    // 关服务不是"链路丢了"：这一批帧没有补发对象，清掉（也不算静默丢弃——
    // 核心自己在关闭，前端重连后会走 REST 重新拉全量）
    _pendingResend.clear();
    await super.closeAll();
  }

  void _tick() {
    final List<WsConnection> snapshot = connections();
    // 全体连接级别的活性（派发/发送路径判活用）
    if (snapshot.isEmpty) {
      // 没有连接：**不再累计丢失**（没人在听不等于"心跳丢了"），但也不清除已有的
      // 失活标记——断开期间广播的帧要能进补发队列，等重连后补（见 _markLinkLost）。
      _anyBeatSinceTick = false;
    } else if (_anyBeatSinceTick) {
      _anyBeatSinceTick = false;
    } else if (linkLiveness.recordMiss() && !_linkStaleReported) {
      _linkStaleReported = true;
      onLinkStale?.call(linkLiveness);
    }

    for (final WsConnection connection in snapshot) {
      if (connection is! LivenessWsConnection) {
        connection.send(<String, dynamic>{'type': WsOutboundType.heartbeat});
        continue;
      }
      if (connection.tickHeartbeat()) {
        // 刚判死：显式上报 + 关连接（前端会自动重连；待补发帧在 unregister 时入队）
        staleConnectionCount++;
        onStale?.call(connection.id, connection.liveness);
        unawaited(connection.close(4001, '心跳丢失（链路失活）'));
        continue;
      }
      if (!connection.liveness.isAlive) continue; // 已判死：不再往死链路写
      _flushPendingBroadcast(); // 重连补发：把断开期间攒下的帧广播给活连接
      connection.flushPendingResend();
      // 照旧下发保活帧（前端会过滤它；它同时是"核心还在"的证据）
      connection.send(<String, dynamic>{'type': WsOutboundType.heartbeat});
    }
  }

  /// 全体连接级别判死回调（默认无操作，由核心接线）。
  void Function(LivenessTracker liveness)? onLinkStale;

  /// 记一帧到 hub 级待补发队列（带上限；超出**计数**丢弃，不静默）。
  void _enqueuePending(Map<String, dynamic> frame) {
    _pendingResend.add(frame);
    _trimPending();
  }

  /// 最后一个前端连接断开：链路已经"没人接"了。
  ///
  /// 把全体连接台账直接判为失活，于是断开期间 broadcast 的帧会登记补发，消息派发侧
  /// 也会显式报错而不是假装送达；新连接注册即恢复（[register] 里记一次心跳）。
  ///
  /// 只在保活/活性判定开着时生效（`enableHeartbeat: false` 时行为与旧版完全一致）。
  void _markLinkLost() {
    if (_probeTimer == null) return;
    for (int i = 0; i < linkLiveness.maxMisses; i++) {
      linkLiveness.recordMiss();
    }
    if (_linkStaleReported) return;
    _linkStaleReported = true;
    onLinkStale?.call(linkLiveness);
  }

  void _onConnectionBeat() {
    final bool wasStale = linkLiveness.isStale;
    _anyBeatSinceTick = true;
    _linkStaleReported = false;
    linkLiveness.recordBeat();
    if (wasStale && linkLiveness.isAlive) onLinkRecovered?.call();
  }

  /// 把断开期间攒下的帧**广播**给当前活连接（重连补发）。
  ///
  /// 放在保活节拍里而不是 `register` 里：前端刚建好连接时它的接收侧可能还没装好，
  /// 立刻写出去反而会丢；等一拍（≤ I）再补，稳定且仍远快于用户感知。
  /// **没有时间上限**：攒了多久都还会补发。
  int _flushPendingBroadcast() {
    if (_pendingResend.isEmpty) return 0;
    final List<WsConnection> live = connections()
        .where(
          (WsConnection c) => c is! LivenessWsConnection || c.liveness.isAlive,
        )
        .toList(growable: false);
    if (live.isEmpty) return 0;
    final List<Map<String, dynamic>> queued = List<Map<String, dynamic>>.of(
      _pendingResend,
    );
    _pendingResend.clear();
    for (final Map<String, dynamic> frame in queued) {
      for (final WsConnection connection in live) {
        connection.send(frame);
      }
      framesResent++;
    }
    return queued.length;
  }

  void _trimPending() {
    while (_pendingResend.length > maxPendingFrames) {
      _pendingResend.removeAt(0);
      framesDroppedOverflow++;
    }
  }
}
