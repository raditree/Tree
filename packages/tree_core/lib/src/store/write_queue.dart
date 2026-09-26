import 'dart:async';

/// 每文件串行的后台写队列（write-behind）。
///
/// 用途：存储层的写操作先改内存缓存并立即返回结果，再把落盘任务排进本队列。
/// 这样 WS 流式对话不会被磁盘 IO 阻塞，而**同一路径的写入顺序仍与调用顺序
/// 一致**（不同路径可并行）。
///
/// [flush] 等待全部在途任务，关停与测试必须调用；进程被硬杀时未 flush 的
/// 任务会丢失——这是本设计明确接受的代价（详见 [TreeStore] 的写语义说明）。
class WriteQueue {
  final Map<String, Future<void>> _tails = <String, Future<void>>{};

  /// 已入队任务计数（用于让 flush 感知"等待期间新入队的任务"）。
  int _enqueued = 0;

  /// 最近一次落盘错误（不抛出，避免拖垮调用方；由 [flush] 的调用方检查）。
  Object? lastError;

  /// 当前是否有在途任务。
  bool get isIdle => _tails.isEmpty;

  /// 把 [task] 排到 [key] 队列末尾。
  void enqueue(String key, Future<void> Function() task) {
    _enqueued++;
    final Future<void> previous = _tails[key] ?? Future<void>.value();
    final Future<void> next = previous.then<void>((_) => task()).catchError((
      Object error,
    ) {
      lastError = error;
    });
    _tails[key] = next;
    unawaited(
      next.whenComplete(() {
        if (identical(_tails[key], next)) _tails.remove(key);
      }),
    );
  }

  /// 等待全部在途任务完成（含等待期间新入队的任务）。
  Future<void> flush() async {
    int seen = -1;
    while (seen != _enqueued || _tails.isNotEmpty) {
      seen = _enqueued;
      if (_tails.isNotEmpty) {
        await Future.wait(_tails.values.toList());
      }
    }
  }
}
