import 'dart:async';

/// 链路被判失活（心跳连续丢失）时抛出的**显式错误**（M9 规约 1.1）。
///
/// 单独一个类型是为了让调用方能把「心跳丢了」与「这次操作本身失败」分开处理：
/// 前者说明**整条链路**已经没有意义（该重连 / 该重试 / 该提示用户），后者往往只是
/// 一次请求的局部问题。所有文案都同时含「心跳丢失」与「链路失活」，日志、UI 与
/// 测试都可以靠这两句话识别，不需要依赖具体实现。
class LivenessLostException implements Exception {
  LivenessLostException(
    this.message, {
    this.label = '链路',
    this.missedCount = 0,
    this.interval = LivenessTracker.defaultInterval,
    this.maxMisses = LivenessTracker.defaultMaxMisses,
  });

  /// 可直接给用户 / 模型看的中文错误文案。
  final String message;

  /// 被判定失活的对象名（如 MCP 服务 filesystem、WS 连接）。
  final String label;

  /// 判死时的连续丢失次数。
  final int missedCount;

  /// 心跳间隔 I。
  final Duration interval;

  /// 允许连续丢失的次数 N。
  final int maxMisses;

  /// 供上层做分支用的显式标志（等价于 is LivenessLostException，但更适合被包装进
  /// 别的错误类型之后再判断）。
  bool get livenessLost => true;

  @override
  String toString() => message;
}

/// 通用**心跳活性台账**（M9 规约 1.1：取消静态时间超时，改「心跳丢失」判超时）。
///
/// 用户口径：静态时间超时**全部取消**——任务跑到多久都不因「总时长」失败
/// （要避开的正是「心跳还在、只是总时间长了就被丢掉」）；但仍然要能判死——
/// 判据换成**心跳丢失**：连续 [maxMisses] 次（默认 N=3）心跳窗口内都没有任何心跳，
/// 就判链路失活，让**在途操作以显式错误失败**（既不静默，也不永久挂起）。
///
/// 本类只做「记心跳 / 记丢失 / 唤醒在途操作」，**不主动中断、不关连接**：
/// - 心跳来源由各子系统自己决定：SSH 用 keepalive ping 回包（见 tree_local_exec 的
///   SshLiveness），LLM 用「收到任意字节」，MCP 用 ping 回包或任意一次成功请求 /
///   通知，WS 用「收到任意入站帧 / 服务端 ack」；
/// - 判据只看 [missedCount] 与 [lastBeatAt]，**不看任务跑了多久**——心跳只要还在，
///   跑多久都算活着（[staleWindow] 是「多久没有心跳」，不是「总共跑了多久」）；
/// - 心跳恢复（[recordBeat] / [reset]）后失活标记**自动清除**，在途操作随即重新可用。
///
/// 用法（三个动作）：
/// 1. 心跳侧：每次拿到心跳证据调 [recordBeat]；每过一拍没有证据调 [recordMiss]；
/// 2. 操作侧：[guard] 包住在途操作——失活即以 [LivenessLostException] 显式失败
///    （三分支：已失活立即失败、在途遇失活失败、成功则记一次心跳）；
/// 3. 观测侧：[isAlive] / [missedCount] / [lastBeatAt] 供重连决策与 UI 展示。
class LivenessTracker {
  LivenessTracker({
    this.label = '链路',
    this.interval = defaultInterval,
    this.maxMisses = defaultMaxMisses,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// I：心跳间隔（好心跳的节奏），同时是**单次心跳窗口**的长度（可配）。
  ///
  /// 注意它**不是**任务总时长：窗口只用来衡量「这一拍有没有心跳」，
  /// 每来一次心跳窗口就重新开始。
  static const Duration defaultInterval = Duration(seconds: 10);

  /// N：连续多少次心跳未达即判失活（可配）。
  ///
  /// N ≤ 0 = **不判活**（等价于关闭活性判定）：用于"只想观测心跳、不想因为心跳
  /// 丢失而失败"的场景。
  static const int defaultMaxMisses = 3;

  /// 被观测对象的名字（只用于文案：日志 / UI / 异常信息）。
  final String label;

  /// 心跳间隔 I（= 单拍窗口）。
  final Duration interval;

  /// 连续丢失多少次判失活（N）。
  final int maxMisses;

  final DateTime Function() _clock;

  DateTime? _lastBeatAt;
  int _missed = 0;
  final Set<Completer<void>> _staleWaiters = <Completer<void>>{};

  /// 最近一次成功心跳的时间；从未成功过为 null。
  DateTime? get lastBeatAt => _lastBeatAt;

  /// 连续未成功的次数（成功一次即清零）。
  int get missedCount => _missed;

  /// 是否已判失活：连续 [maxMisses] 次心跳都没到（[maxMisses] ≤ 0 时永不判失活）。
  bool get isStale => maxMisses > 0 && _missed >= maxMisses;

  /// 链路是否可用（= 未失活）。失活期间**不会**主动中断底层连接。
  bool get isAlive => !isStale;

  /// 判活窗口 = I × N（「这么久没有心跳就判死」）。
  ///
  /// 再次强调：它**不是**任务总时长上限——只要心跳还在，窗口就一直往后滚。
  Duration get staleWindow => interval * (maxMisses < 1 ? 1 : maxMisses);

  /// 失活原因（给上层 / UI 的可读文本，异常信息里也用它）。
  String get staleMessage {
    final String beat = formatDuration(interval);
    final String window = formatDuration(staleWindow);
    return '$label 心跳丢失（链路失活）：连续 $_missed 次心跳未达'
        '（心跳间隔 $beat，阈值 $maxMisses 次，判活窗口 $window）；'
        '不主动中断，心跳恢复后自动清除';
  }

  /// 收到一次心跳（或任何「链路还活着」的证据：成功响应 / 服务端通知 / 收到的帧）。
  ///
  /// 成功响应同样算心跳：数据还在流动就说明链路活着，不该因为「恰好错过几拍探活」
  /// 被判失活。重连成功后调它即可清除失活标记。
  void recordBeat([DateTime? at]) {
    _lastBeatAt = at ?? _clock();
    _missed = 0;
  }

  /// 一个心跳窗口内没有任何证据：累计丢失；达到阈值即唤醒在途操作。
  ///
  /// 返回是否**已判失活**（调用方做日志 / 展示用）。
  bool recordMiss() {
    _missed++;
    if (isStale) _wakeWaiters();
    return isStale;
  }

  /// 清除失活标记与心跳时间（重连成功、换新链路后调用）。
  void reset() {
    _missed = 0;
    _lastBeatAt = null;
  }

  /// 失活则立刻抛显式错误——不再往一条判死的链路上发新东西。
  void ensureAlive() {
    if (isStale) throw _lost();
  }

  /// 把一次异步操作包上活性守卫：
  /// - 开始前已失活 → 立刻显式失败（连操作都不发起）；
  /// - 在途时被判失活 → 以 [LivenessLostException] 失败，而不是永远等下去；
  /// - 操作成功 → [recordBeat]（成功的响应也是链路活着的证据）。
  ///
  /// 被放弃的那个操作**不会被取消**（底层往往也没法从这一侧掐断），它只是不再被
  /// 等待：这是「上层不再等待」与「进程 / 连接不被杀」的两面。
  Future<T> guard<T>(Future<T> Function() operation) async {
    ensureAlive();
    final Completer<void> stale = watchStale();
    try {
      final T result = await Future.any<T>(<Future<T>>[
        operation(),
        stale.future.then<T>((void _) => throw _lost()),
      ]);
      recordBeat();
      return result;
    } finally {
      unwatchStale(stale);
    }
  }

  /// 登记一个「链路被判失活时完成」的信号。
  ///
  /// 流式读取 / 自己管并发的场景没法包进 [guard]（它返回的是 Stream 或另有回调），
  /// 所以单独暴露给调用方自己跟信号赛跑。用完必须 [unwatchStale]。
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

  LivenessLostException _lost() => LivenessLostException(
    staleMessage,
    label: label,
    missedCount: _missed,
    interval: interval,
    maxMisses: maxMisses,
  );

  /// 人类可读的时长（不足 1s 用毫秒，避免出现「0s」）。
  static String formatDuration(Duration value) => value.inSeconds >= 1
      ? '${value.inSeconds}s'
      : '${value.inMilliseconds}ms';
}
