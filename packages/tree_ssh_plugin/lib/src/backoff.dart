/// 重连的**退避节奏**：`1s → 2s → 4s → … → 封顶 60s/次`，且**累计等待时长上限 30 分钟**。
///
/// 两条口径（与协议 §2 的 `state` 取值对齐，也和 `tree_local_exec` 不变量 6 的"退避是节奏"
/// 一致，但这里**多了一条上限**——因为中转站退避耗尽要变成 `down` 让核心回退内置）：
///
/// - **它是节奏，不是单次超时**：每一次尝试本身不设时长上限（连不上就等它连）；
/// - **累计**（所有"等过的间隔"之和）超过 [maxTotal] ⇒ 不再重试：调用方据此把状态标成
///   `tunnel_down`，核心视其为"没有中转站"。
///
/// 刻意**不持有时钟**：本类只算"下一拍该等多久"，真等由调用方（`Tunnel` + 可注入的
/// [TimerFactory]）负责 —— 单测因此不用真等 30 分钟。
class Backoff {
  Backoff({
    this.base = const Duration(seconds: 1),
    this.cap = const Duration(seconds: 60),
    this.maxTotal = const Duration(minutes: 30),
  }) : assert(base.inMilliseconds > 0, 'base 必须是正的'),
       assert(cap.inMilliseconds >= base.inMilliseconds, 'cap 不能小于 base');

  /// 第一拍间隔（之后逐次翻倍）。
  final Duration base;

  /// 单拍上限（翻倍到这里就平住）。
  final Duration cap;

  /// **累计等待**上限；`0` 或负值 = 不设上限（本插件不用，留给测试/派生场景）。
  final Duration maxTotal;

  int _attempt = 0;
  Duration _spent = Duration.zero;

  /// 已经退避过几拍。
  int get attempt => _attempt;

  /// 累计等待时长。
  Duration get spent => _spent;

  /// 第 [attempt] 拍（0 基）的间隔：`base * 2^attempt`，到 [cap] 平住。
  Duration delayFor(int attempt) {
    if (attempt < 0) return Duration.zero;
    // 先按移位算，再和 cap 取小；移位位数先夹住，避免 attempt 很大时溢出。
    if (attempt >= 32) return cap;
    final int ms = base.inMilliseconds << attempt;
    if (ms <= 0) return cap;
    final Duration raw = Duration(milliseconds: ms);
    return raw > cap ? cap : raw;
  }

  /// 取下一拍：返回"该等多久"；返回 **null** = 再等一次会顶破 [maxTotal] ⇒ 退避耗尽。
  ///
  /// 调用即推进内部计数（成功一次就记一次账），所以"退避耗尽"这个判断与真实等待一致。
  Duration? take() {
    final Duration next = delayFor(_attempt);
    if (maxTotal > Duration.zero && _spent + next > maxTotal) return null;
    _attempt++;
    _spent += next;
    return next;
  }

  /// 清零（`tunnel.reconnect` / 一次成功连接之后都要调它）。
  void reset() {
    _attempt = 0;
    _spent = Duration.zero;
  }

  /// 可读形态（日志用）：`第 3 拍（累计 7s）`。
  String describe() => '第 $_attempt 拍（累计 ${spent.inSeconds}s）';

  @override
  String toString() =>
      'Backoff(attempt=$_attempt, spent=${_spent.inSeconds}s, cap=${cap.inSeconds}s, '
      'maxTotal=${maxTotal.inMinutes}min)';
}
