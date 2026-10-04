import 'dart:async';

import 'local_workspace_io.dart';

/// 链路被判失活（心跳连续丢失）时抛出的错误（M9 1.1）。
///
/// 单独一个类型是为了让调用方能把"心跳丢了"与"这个文件读不到"分开处理：
/// 前者要如实上抛（整轮操作已经没有意义），后者通常跳过即可（grep 就是这么做的）。
class SshLinkStaleException extends WorkspaceIoException {
  SshLinkStaleException(super.message);
}

/// SSH 链路的**活性**（M9 1.1 判据修正：判"心跳丢了"，不判"总时长超了"）。
///
/// 用户口径：命令/传输**没有静态总时长上限**——只要心跳还在回，跑多久都不算超时
/// （这正是为了避开"心跳还在、只是总时间长了就被丢掉"）；反过来，连续 [maxMisses]
/// 次心跳窗口内都没有回包，就判链路失活，让**在途**的 run / SFTP 操作以显式错误
/// 失败：既不永久挂起，也不静默。
///
/// 为什么要有"心跳窗口"：dartssh2 的 ping 内部是 await 一个 keepalive 全局请求的
/// 回包（成功与失败回包都算回），对端真的失联时它永远不完成——所以给每次心跳一个
/// [interval] 量级的 window，窗口内没完成就记一次丢失。这个窗口是**单次心跳的
/// deadline**，与"任务总共跑了多久"是两回事。
///
/// 只做标记与唤醒，**不关连接、也不自己重连**：链路可能只是慢/抖动，届时任何一次成功
/// 心跳（或任何一次成功的读/写响应）都会 [recordBeat] 清零丢失计数、自动解除失活；
/// 但一条**已经断掉的 TCP 连接不会自己活回来**（现场 2026-10-05：连续 1325 拍丢失、
/// 远端经过实测可达，应用却再没恢复过），所以判失活的那一瞬间通过 [onStale] 通知传输层
/// 去**重建连接**（见 `ssh_reconnect.dart` 的 `SshReconnectPump`：单飞 + 退避，
/// 不引入任何静态时长上限——判死判据仍然只看心跳丢失）。
class SshLiveness {
  SshLiveness({
    this.interval = defaultInterval,
    this.maxMisses = defaultMaxMisses,
    DateTime Function()? clock,
    this.onStale,
  }) : _clock = clock ?? DateTime.now;

  /// **刚判失活**那一瞬间的通知（跨过 [maxMisses] 阈值的那一次调用）。
  ///
  /// 挂载点是传输层：`DartSshTransport` 用它启动**后台重连**（见 `ssh_reconnect.dart`
  /// 的 `SshReconnectPump`，调用点 `DartSshTransport._handleStale`）。本类自己**不做**重连、
  /// 也**不关**连接：一条已经断掉的 TCP 连接不会因为"再等一拍"活回来，重建是传输层的事，
  /// 这里只负责"说一声"。
  ///
  /// 触发时机：同一次失活**只通知一次**（连续丢失不重复）；[recordBeat] / [reset]
  /// 清零之后再次跨过阈值会再通知一次。可在建好后重新赋值（`connect()` 里挂载）。
  void Function()? onStale;

  /// I：心跳间隔，同时也是**单次心跳窗口**的长度（可配）。
  static const Duration defaultInterval = Duration(seconds: 10);

  /// N：连续多少次心跳没回包即判失活（可配）。
  static const int defaultMaxMisses = 3;

  /// 心跳间隔 / 单次心跳窗口。
  final Duration interval;

  /// 连续丢失多少次判失活。
  final int maxMisses;

  final DateTime Function() _clock;

  DateTime? _lastBeatAt;
  int _missed = 0;
  final Set<Completer<void>> _staleWaiters = <Completer<void>>{};

  /// 最近一次成功心跳（或成功读/写响应）的时间；从未成功过为 null。
  DateTime? get lastBeatAt => _lastBeatAt;

  /// 连续未成功的次数（成功一次即清零）。
  int get missedCount => _missed;

  /// 是否已判失活：连续 [maxMisses] 次心跳都没回。
  bool get isStale => _missed >= maxMisses;

  /// 链路是否可用（= 未失活）。失活期间**不会**主动关闭连接。
  bool get isAlive => !isStale;

  /// 失活原因（给上层/UI 的可读文本，错误信息里也用它）。
  ///
  /// 文案要说**真话**：旧实现写的是「连接未关闭，心跳恢复后自动恢复」，但一条已经断掉的
  /// TCP 连接**不会**自己恢复（现场：连续 1325 拍丢失、远端其实可达，用户只能重启应用）。
  /// 现在失活瞬间会触发传输层的后台重连（[onStale]），所以这里如实写"已判死 + 会重连 + 可手动"。
  String get staleMessage =>
      'SSH 链路失活：连续 $_missed 次心跳丢失（心跳间隔 ${interval.inSeconds}s，'
      '阈值 $maxMisses 次）；旧连接已判死、不会自行恢复（核心会按退避自动重连，'
      '也可用「重连」立即重建）';

  /// 收到一次心跳，或一次成功的读/写响应。
  ///
  /// 成功响应同样算心跳：数据还在流动就说明链路活着，不该因为"恰好错过几拍
  /// keepalive"被判失活。重连成功后调它即可清除失活标记。
  void recordBeat([DateTime? at]) {
    _lastBeatAt = at ?? _clock();
    _missed = 0;
  }

  /// 一个心跳窗口内没有回包：累计丢失；达到阈值即唤醒在途操作。
  ///
  /// 返回是否已判失活（调用方只做日志/展示用）。
  bool recordMiss() {
    final bool wasStale = isStale;
    _missed++;
    if (isStale) {
      // 「刚判失活」的那一拍通知一次（传输层据此开始重建连接）。
      if (!wasStale) onStale?.call();
      _wakeWaiters();
    }
    return isStale;
  }

  /// 重连成功后清除失活标记（新连接也可以直接换一个新的 [SshLiveness] 实例）。
  void reset() {
    _missed = 0;
    _lastBeatAt = null;
  }

  /// 失活则立刻抛显式错误——不再往一条判死的链路上发新东西。
  void ensureAlive() {
    if (isStale) throw SshLinkStaleException(staleMessage);
  }

  /// 把一次异步操作包上活性守卫：
  /// - 开始前已失活 → 立刻显式失败；
  /// - 在途时链路被判失活 → 以 [staleMessage] 失败，而不是永远等下去；
  /// - 成功 → [recordBeat]（成功的读/写响应也是链路活着的证据）。
  ///
  /// 被放弃的那个操作**不会被取消**（SSH 通道没法从这一侧掐断），它只是不再被
  /// 等待：这是"上层不再等待时进程与连接不被杀"的另一面。
  Future<T> guard<T>(Future<T> Function() operation) async {
    ensureAlive();
    final Completer<void> stale = watchStale();
    try {
      final T result = await Future.any<T>(<Future<T>>[
        operation(),
        stale.future.then<T>(
          (void _) => throw SshLinkStaleException(staleMessage),
        ),
      ]);
      recordBeat();
      return result;
    } finally {
      unwatchStale(stale);
    }
  }

  /// 登记一个"链路被判失活时完成"的信号。
  ///
  /// 流式读取没法包进 [guard]（它返回的是 Stream），所以单独暴露给
  /// SshWorkspaceIO 自己跟信号赛跑。用完必须 [unwatchStale]。
  Completer<void> watchStale() {
    final Completer<void> waiter = Completer<void>();
    _staleWaiters.add(waiter);
    return waiter;
  }

  /// 注销信号。
  void unwatchStale(Completer<void> waiter) => _staleWaiters.remove(waiter);

  void _wakeWaiters() {
    for (final Completer<void> waiter in _staleWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _staleWaiters.clear();
  }
}
