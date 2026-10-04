import 'dart:convert';
import 'dart:io';

import '../store/atomic_file.dart';
import '../store/tree_paths.dart';
import '../store/write_queue.dart';

/// 核心进程的**日志出口**：同一个出口**同时**写 stderr 与 `<数据根>/logs/core.log`。
///
/// 为什么需要它（2026-10-03 用户报"压缩到底跑了几次"时无从取证）：
/// 核心进程此前**零文件日志**——所有 `[core:xxx]` 都只进 stderr，而 stderr 只有
/// 拉起它的父进程能转发（发布版 = 用户看不到、事后也查不到）。用户要核对的恰恰是
/// "服务端账单里那三次调用是哪来的"，没有落盘就只能猜。
///
/// 设计取舍（逐条都有理由，改之前先读）：
/// - **tee 而不是替换**：stderr 逐字保持原样（开发期 `flutter run` / `--verbose`
///   照旧看得到，`packages/tree_core_cli/test/cli_serve_test.dart` 也按 stderr 断言），
///   文件是**副本**。落盘失败时 stderr 照旧 ⇒ 核心功能永不因此受损。
/// - **行首带时间戳与 pid**（`2026-10-05T07:24:31.123+08:00 pid=1234 [core:compact] …`）：
///   只加在**文件**行上，不动 stderr。
///   时间戳是**本地时间**（毫秒 3 位 + 显式时区偏移），回答"这件事是什么时候发生的"；
///   pid 则回答"是哪个核心进程写的"——开发期的标准姿势是"App 的核心"与"自己单独起的
///   `tree_core.exe --data-dir …`"同时写同一个数据根，两进程的内容混在一个文件里无法归因，
///   pid 是唯一现成的身份。
/// - **懒打开**：构造函数不碰磁盘（`--print-paths` / `--help` / 测试里构造都零副作用），
///   第一次 [write] 才入队；目录与文件由 [AtomicFile.appendLine] 按需创建。
/// - **按大小轮转**：默认 8 MiB × 5 份（[defaultMaxBytes] / [defaultMaxFiles]）。
///   轮转与追加**在同一个 [WriteQueue] 队列里**串行执行——否则会出现"刚轮转完又
///   追加到旧句柄"的错乱（`rename` 与 `append` 分属两条异步路径时必然发生）。
/// - **绝不抛异常、绝不阻塞生成**：写入全部经 [WriteQueue]（write-behind，调用方
///   入队即返回）；失败**只报一次**（[failureLog]）并永久降级为纯 stderr。
/// - **关停必须 [flush]**：队列在硬杀时会丢在途任务（见 [WriteQueue] 的类注释），
///   关停是唯一能保证尾部完整的时机。
class CoreLogSink {
  /// [paths] 提供数据根与日志布局；其余参数都是**测试接缝**（生产用默认值）。
  ///
  /// [maxBytes] 单份上限，[maxFiles] 总份数（含当前那份）；
  /// [processId] 默认取当前进程 pid；
  /// [stderrSink] 默认 `stderr.writeln`（这是"保持现状"的那条出口）；
  /// [failureLog] 落盘失败时的唯一一次提示出口（默认同样走 stderr）。
  /// [clock] 取**当前时刻**的接缝（默认 [DateTime.now]）——测试注入假时钟即可对
  /// 落盘行首的时间戳做精确断言；它只在 [write] 里被调用，构造仍不碰磁盘。
  CoreLogSink(
    this.paths, {
    this.maxBytes = defaultMaxBytes,
    this.maxFiles = defaultMaxFiles,
    int? processId,
    void Function(String line)? stderrSink,
    void Function(String message)? failureLog,
    DateTime Function()? clock,
  }) : _pid = processId ?? pid,
       _stderr = stderrSink ?? ((String line) => stderr.writeln(line)),
       _failureLog = failureLog ?? ((String message) => stderr.writeln(message)),
       _clock = clock ?? DateTime.now;

  /// 默认单份上限：8 MiB。
  static const int defaultMaxBytes = 8 * 1024 * 1024;

  /// 默认总份数（`core.log` + `core.1.log` … `core.4.log`）。
  static const int defaultMaxFiles = 5;

  /// 数据根与日志布局（路径只有一个来源，见 [TreePaths]）。
  final TreePaths paths;

  /// 单份上限（字节）。<= 0 表示不轮转。
  final int maxBytes;

  /// 总份数（含当前那份）。<= 1 表示轮转时不保留历史份。
  final int maxFiles;

  final int _pid;
  final void Function(String line) _stderr;
  final void Function(String message) _failureLog;
  final DateTime Function() _clock;

  final WriteQueue _queue = WriteQueue();

  /// 当前 `core.log` 的已知字节数；null = 还没探测过（懒）。
  int? _bytes;

  /// 是否已因落盘失败降级为"纯 stderr"（一旦为真，本次运行不再尝试写文件）。
  bool _degraded = false;

  /// 当前日志文件路径（`<数据根>/logs/core.log`）。
  String get logFile => paths.coreLogFile;

  /// 日志目录（`<数据根>/logs`）。
  String get logDir => paths.logsDir;

  /// 是否已降级为纯 stderr（写失败后为真；测试与关停自检用）。
  bool get degraded => _degraded;

  /// 写一行日志：**stderr 立即写**（保持原样），文件追加按序入队（不阻塞调用方）。
  ///
  /// 本方法**永不抛异常**：stderr 已关闭、磁盘满、目录不可写等一律吞掉并（至多一次）
  /// 在 stderr 里说明——日志出口不能成为核心功能的故障源。
  void write(String line) {
    try {
      _stderr(line);
    } catch (_) {
      // stderr 已关闭（父进程不接管、管道断裂）：日志无处可去，但绝不影响调用方。
    }
    if (_degraded) return;
    // 时间戳**在调用当下取**：入队是 write-behind，等到队列里（甚至等到真正落盘）
    // 再取就与"这件事发生的时刻"漂移了——磁盘慢、前面积压时尤其明显，
    // 而"用户截图那一刻核心在干什么"恰恰是这行时间戳要回答的问题。
    final String stamp = _timestamp(_clock());
    // 文件行带时间戳与 pid：同一数据根可能同时有"App 的核心"与"开发期自起的核心"在写。
    _queue.enqueue(logFile, () => _append('$stamp pid=$_pid $line'));
  }

  /// 落盘行的**行首时间戳**：`<本地时间 ISO8601（毫秒 3 位）><显式时区偏移>`，
  /// 例如 `2026-10-05T07:24:31.123+08:00`；本机为 UTC 时是 `+00:00`（不写 `Z`）。
  ///
  /// 为什么自己拼而不直接用 `DateTime.toIso8601String()`：
  /// 1. 本地时间的 `toIso8601String()` **不带偏移**（`2026-10-05T07:24:31.123`）——
  ///    这份日志会被拷到别的机器/别的时区去看，没有偏移就无法换算回真实时刻；
  /// 2. 带微秒时它输出 **6 位**小数，与"毫秒 3 位"的固定口径不符。
  static String _timestamp(DateTime at) {
    final DateTime local = at.toLocal();
    final Duration offset = local.timeZoneOffset;
    final int offsetMinutes = offset.inMinutes.abs();
    final String sign = offset.isNegative ? '-' : '+';
    final String date =
        '${local.year.toString().padLeft(4, '0')}'
        '-${local.month.toString().padLeft(2, '0')}'
        '-${local.day.toString().padLeft(2, '0')}';
    final String time =
        '${local.hour.toString().padLeft(2, '0')}'
        ':${local.minute.toString().padLeft(2, '0')}'
        ':${local.second.toString().padLeft(2, '0')}'
        '.${local.millisecond.toString().padLeft(3, '0')}';
    final String zone =
        '$sign'
        '${(offsetMinutes ~/ 60).toString().padLeft(2, '0')}'
        ':${(offsetMinutes % 60).toString().padLeft(2, '0')}';
    return '$date' 'T' '$time$zone';
  }

  /// 取一个**固定前缀**的日志函数：`forPrefix('core:compact')` 等价于原来的
  /// `(m) => stderr.writeln('[core:compact] $m')`，但多了一份落盘副本。
  void Function(String message) forPrefix(String prefix) =>
      (String message) => write('[$prefix] $message');

  /// 等待全部在途落盘任务完成（**关停路径必须调用**）。
  Future<void> flush() => _queue.flush();

  // ── 内部实现 ─────────────────────────────────────────────────────────

  Future<void> _append(String entry) async {
    if (_degraded) return;
    final File file = File(logFile);
    try {
      final int pending = utf8.encode(entry).length + 1; // + '\n'
      int bytes = _bytes ?? (file.existsSync() ? file.lengthSync() : 0);
      if (maxBytes > 0 && bytes > 0 && bytes + pending > maxBytes) {
        await _rotate();
        bytes = 0;
      }
      await AtomicFile.appendLine(logFile, entry);
      _bytes = bytes + pending;
    } catch (error) {
      _degrade(error);
    }
  }

  /// 轮转：`core.N-2.log → core.N-1.log`（最旧那份被覆盖），`core.log → core.1.log`。
  ///
  /// 只在本队列的任务里被调用 ⇒ 与追加互斥，不会出现"改名后仍写旧句柄"。
  Future<void> _rotate() async {
    if (maxFiles <= 1) {
      // 不保留历史：直接清空当前那份（用删除而不是截断，避免留下半份）。
      final File current = File(paths.coreLogFile);
      if (current.existsSync()) await current.delete();
      return;
    }
    final File oldest = File(paths.coreLogFileAt(maxFiles - 1));
    if (oldest.existsSync()) await oldest.delete();
    for (int index = maxFiles - 2; index >= 1; index--) {
      final File from = File(paths.coreLogFileAt(index));
      if (!from.existsSync()) continue;
      final File to = File(paths.coreLogFileAt(index + 1));
      if (to.existsSync()) await to.delete();
      await from.rename(to.path);
    }
    final File current = File(paths.coreLogFile);
    if (current.existsSync()) {
      final File first = File(paths.coreLogFileAt(1));
      if (first.existsSync()) await first.delete();
      await current.rename(first.path);
    }
  }

  /// 落盘失败：**只报一次**，然后降级为纯 stderr（stderr 那份照旧，核心照旧跑）。
  void _degrade(Object error) {
    if (_degraded) return;
    _degraded = true;
    try {
      _failureLog(
        '[tree] 警告：核心日志落盘失败，本次运行已降级为纯 stderr'
        '（不影响任何功能）：$logFile：$error',
      );
    } catch (_) {
      // 连提示都写不出去（stderr 也没了）：放弃提示，不影响核心。
    }
  }
}
