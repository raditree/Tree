import 'dart:async';

/// **重连的节拍器**：单飞 + 退避 + 可停止，**与 dartssh2 无关**（因此可以单测）。
///
/// 为什么非要单独抽这一层：真链路的建连没法在本机单测（本仓库没有可连的 sshd，
/// 也不能凭空造一个 `SSHClient`），而"什么时候该重试、会不会叠出第二个循环、
/// 关停之后还试不试、并发调用会不会打两次"**全是纯策略**——把它抽出来，就能用
/// 假 `attempt` / 假 `sleep` 把这几条钉死（[DartSshTransport] 只剩"换会话"那几行）。
///
/// 口径（M9 1.1，**不许破**）：
/// - [backoff] 是"两次尝试之间的**节奏**"，**不是**静态时长上限：判死判据仍然只看
///   "连续 N 拍心跳丢失"，重连是判死**之后**的动作，单次尝试本身不设超时；
/// - 退避走完就一直用最后一拍（默认 60s）继续试，直到成功 / [stop] /
///   [stillNeeded] 说"不用了"（例如失活标记已被别处清掉）。
class SshReconnectPump {
  SshReconnectPump({
    required this.attempt,
    List<Duration>? backoff,
    Future<void> Function(Duration duration)? sleep,
    this.stillNeeded,
    this.onEvent,
  })  : backoff = (backoff == null || backoff.isEmpty)
            ? const <Duration>[Duration.zero]
            : backoff,
        _sleep = sleep ?? Future<void>.delayed;

  /// 真正的"重建一次"（失败必须抛：节拍器据此决定要不要再试）。
  final Future<void> Function() attempt;

  /// 退避节奏（首拍就等它；走完一直用最后一拍）。
  final List<Duration> backoff;

  /// "还需要重连吗"（生产 = 未关停 **且** 链路仍失活）；null = 一直需要。
  final bool Function()? stillNeeded;

  /// 可观测出口（生产接到核心日志）：成功 / 每次失败都报一句。
  final void Function(String message)? onEvent;

  final Future<void> Function(Duration duration) _sleep;

  Future<void>? _inFlight;
  Future<void>? _loop;
  bool _stopped = false;
  int _attempts = 0;

  /// 已经发起过多少次重建尝试（成功或失败都算）。
  int get attempts => _attempts;

  /// 是否已 [stop]。
  bool get stopped => _stopped;

  /// 当前有一次重建在途（单飞的可见面：测试据此断言"没有叠第二个"）。
  bool get inFlight => _inFlight != null;

  /// 后台循环是否在跑。
  bool get running => _loop != null;

  /// **显式**重建一次（核心的「重连」入口走这条）：await 到底，失败原样抛给调用方。
  ///
  /// 单飞：已经有重建在途时**复用同一次**（不会因为用户连点 / 与后台循环撞车而打两次）。
  Future<void> retryNow() {
    if (_stopped) {
      return Future<void>.error(StateError('重连节拍器已停止，无法再重建'));
    }
    final Future<void>? running = _inFlight;
    if (running != null) return running;
    _attempts++;
    final Future<void> attemptFuture = attempt();
    _inFlight = attemptFuture;
    return attemptFuture.whenComplete(() {
      if (identical(_inFlight, attemptFuture)) _inFlight = null;
    });
  }

  /// 起**后台**循环（判失活那一瞬间调；同一条链路只允许一个）。
  ///
  /// 返回的 future 在循环结束时完成（测试据此等待；生产不 await）。
  Future<void> start() {
    if (_stopped) return Future<void>.value();
    return _loop ??= _runLoop().whenComplete(() {
      _loop = null;
    });
  }

  /// 停止：循环醒来即退出，之后 [retryNow] 直接拒绝。
  void stop() {
    _stopped = true;
  }

  Future<void> _runLoop() async {
    int index = 0;
    while (!_stopped && _needed) {
      final Duration wait = backoff[index < backoff.length
          ? index
          : backoff.length - 1];
      await _sleep(wait);
      if (_stopped || !_needed) return;
      index++;
      try {
        await retryNow();
        onEvent?.call('成功（第 $index 次尝试）');
        return;
      } catch (error) {
        onEvent?.call(
          '第 $index 次失败（${wait.inSeconds > 0 ? '${wait.inSeconds}s 后再试' : '立刻再试'}）：'
          '$error',
        );
      }
    }
  }

  bool get _needed => stillNeeded?.call() ?? true;
}
