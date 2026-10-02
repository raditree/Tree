import 'dart:async';

/// 一次启动期外设预热任务。
///
/// [name] 只用于日志（写用户能看懂的中文名，例如「MCP 服务」「插件」）；
/// [run] 的失败由本模块兜底：只记日志，**绝不外抛**。
typedef WarmUpTask = ({String name, Future<void> Function() run});

/// 预热结果（日志、自检与测试的读数点）。
class WarmUpReport {
  WarmUpReport({
    required this.elapsedMillis,
    required this.settled,
    required this.pending,
    required this.failures,
  });

  /// 从开跑到返回的总耗时（含被 [warmUpPeripherals] 的预算截断的情形）。
  final int elapsedMillis;

  /// 在预算内结束的任务名（**成功或失败都算结束**）。
  final List<String> settled;

  /// 超预算仍在后台跑的任务名。
  final List<String> pending;

  /// 失败任务 → 可读原因。
  final Map<String, String> failures;

  /// 全部任务都在预算内结束。
  bool get complete => pending.isEmpty;

  @override
  String toString() =>
      'WarmUpReport(${elapsedMillis}ms, settled=$settled, '
      'pending=$pending, failures=$failures)';
}

/// 预热外设（MCP / 插件）：**并行 + 有界 + 绝不抛**。
///
/// 为什么需要它（2026-10-03 定夺，见 docs/known-issues.md #13）：
/// 核心进程的 stdout 首行握手是**进程间协议**，界面拿到它才算「核心可用」。此前
/// `mcp.refresh()`（首次连接没有超时参数，见 McpClient 的类文档）与
/// `plugins.start()`（逐家**串行**、每家 20s 超时）都排在握手**之前**，
/// 于是任何一家外设卡住，界面就只能等到 25s 握手超时，并显示「核心进程未能启动」。
/// 现在把外设预热整体搬出握手路径，三件事在这里收口：
/// - **并行**：总时长从「各任务求和」变成「取最大」；
/// - **有界**：超过 [budget] 立即返回；未结束的任务**继续在后台跑**，各自结束时
///   照常打自己的日志——调用方因此永远不会被外设无限拖住；
/// - **绝不抛**：任何一家失败都只记日志（坏插件/坏 MCP 不该拦住核心，与既有约定一致）。
///
/// [budget] 还是「对话那一轮最多等外设多久」的依据：CLI 把返回的 future 接到
/// `LlmAgentEngine.awaitReady` 上当闸门，正常预热在百毫秒级完成，闸门几乎不花时间。
Future<WarmUpReport> warmUpPeripherals(
  List<WarmUpTask> tasks, {
  Duration budget = const Duration(seconds: 3),
  void Function(String message)? log,
}) async {
  final Stopwatch total = Stopwatch()..start();
  final List<String> settled = <String>[];
  final List<String> pending = <String>[
    for (final WarmUpTask task in tasks) task.name,
  ];
  final Map<String, String> failures = <String, String>{};

  Future<void> guarded(WarmUpTask task) async {
    final Stopwatch sw = Stopwatch()..start();
    try {
      await task.run();
      log?.call('${task.name} 就绪（${sw.elapsedMilliseconds}ms）');
    } catch (error) {
      failures[task.name] = '$error';
      log?.call(
        '${task.name} 预热失败（${sw.elapsedMilliseconds}ms，核心照常可用）：$error',
      );
    } finally {
      settled.add(task.name);
      pending.remove(task.name);
    }
  }

  final List<Future<void>> running = <Future<void>>[
    for (final WarmUpTask task in tasks) guarded(task),
  ];
  if (running.isNotEmpty && budget > Duration.zero) {
    try {
      await Future.wait(running).timeout(budget);
    } on TimeoutException {
      // 超预算：未结束的任务继续在后台跑（它们的日志会在结束时照常打出来），
      // 这里只负责「不再等」。
    }
  } else if (running.isNotEmpty) {
    await Future.wait(running);
  }
  total.stop();
  if (pending.isNotEmpty) {
    log?.call(
      '外设预热超过 ${budget.inMilliseconds}ms 预算，仍在后台启动：'
      '${pending.join('、')}（本轮对话暂不带它们的工具，启动完成后自动补上）',
    );
  }
  return WarmUpReport(
    elapsedMillis: total.elapsedMilliseconds,
    settled: settled,
    pending: pending,
    failures: failures,
  );
}
