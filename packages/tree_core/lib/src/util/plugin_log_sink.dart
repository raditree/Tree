import 'dart:convert';
import 'dart:io';

import '../store/atomic_file.dart';
import '../store/tree_paths.dart';
import '../store/write_queue.dart';
import 'log_timestamp.dart';

/// 插件运行日志的**落盘出口**（`<数据根>/logs/plugins/<id>.log`）。
///
/// 为什么需要它：片 F 的日志 API（`/api/logs/plugin:<id>`）只**读**这个文件，
/// 而此前没有任何写入者——插件 stderr 只留在 `PluginHost.stderrTail` 的内存里，
/// `log` 通知只被转成前端帧。结果是"日志 API 能列出源，却永远读不到插件自己
/// 写的东西"：A1 的验收（空插件上线后日志可从日志 API 查到）根本不可能通过。
///
/// 口径与 `CoreLogSink` 一致：write-behind 队列（同一文件串行）、按大小轮转、
/// 失败只报一次并降级（日志出口不能成为核心功能的故障源）。差别只有两点：
/// - 按 `plugin_id` 分文件（每个插件一份，互不串味）；
/// - 每行带来源标记（`stderr` / `notify:<level>`），把"插件打印"与"插件主动
///   上报"分开——排障时这两种话的可信度不同。
///
/// 写入顺序要求：**插件拉起前接线**（`PluginBus.bindPluginLog`）。晚绑定期间
/// 产生的行只会留在 stderr 与内存里（本类不做历史回放，避免再养一份无界缓冲）。
class PluginLogSink {
  PluginLogSink(
    this.paths, {
    this.maxBytes = defaultMaxBytes,
    this.maxFiles = defaultMaxFiles,
    DateTime Function()? clock,
    void Function(String message)? failureLog,
  }) : _clock = clock ?? DateTime.now,
       _failureLog = failureLog ?? ((String message) => stderr.writeln(message));

  /// 默认单份上限：8 MiB（与核心日志同口径）。
  static const int defaultMaxBytes = 8 * 1024 * 1024;

  /// 默认总份数：当前份 + 4 份历史。
  static const int defaultMaxFiles = 5;

  /// 路径布局（唯一的落点来源）。
  final TreePaths paths;

  /// 单份上限（字节）。<= 0 表示不轮转。
  final int maxBytes;

  /// 总份数（含当前那份）。<= 1 表示轮转时不保留历史份。
  final int maxFiles;

  final DateTime Function() _clock;
  final void Function(String message) _failureLog;

  /// 所有插件共用一个写队列：`WriteQueue` 按 key（文件路径）串行，
  /// 不同插件之间仍可并行。
  final WriteQueue _queue = WriteQueue();

  /// 每个插件当前日志文件的已知字节数（懒探测）。
  final Map<String, int> _bytes = <String, int>{};

  /// 已因落盘失败降级的插件（一旦为真，本次运行不再尝试写它的文件）。
  final Set<String> _degraded = <String>{};

  /// 已降级的插件 id（自检 / 测试观察用）。
  Set<String> get degradedPlugins => Set<String>.unmodifiable(_degraded);

  /// 写一行：**永不抛异常**（磁盘满 / 目录不可写只降级并报一次）。
  ///
  /// [channel] 是来源标记：`stderr`（插件进程的输出）或 `notify:<level>`
  /// （插件经 `log` 通知主动上报）。
  void write(String pluginId, String line, {String channel = 'stderr'}) {
    final String id = pluginId.trim();
    if (id.isEmpty || _degraded.contains(id)) return;
    try {
      TreePaths.safeSegment(id);
    } on ArgumentError {
      // 非法 id 不可能有合法落点（也不能让日志出口变成路径注入面）。
      return;
    }
    final String text = line.trimRight();
    if (text.isEmpty) return;
    final String entry =
        '${logLineTimestamp(_clock())} plugin=$id [$channel] $text';
    _queue.enqueue(paths.pluginLogFile(id), () => _append(id, entry));
  }

  /// 等待全部在途落盘任务（关停 / 测试必须调用）。
  Future<void> flush() => _queue.flush();

  /// 关闭：等同于 [flush]（保留接口，避免调用方依赖"队列"这个实现细节）。
  Future<void> close() => flush();

  Future<void> _append(String id, String entry) async {
    if (_degraded.contains(id)) return;
    final String path = paths.pluginLogFile(id);
    final File file = File(path);
    try {
      final int pending = utf8.encode(entry).length + 1; // + '\n'
      int bytes = _bytes[id] ?? (file.existsSync() ? file.lengthSync() : 0);
      // 日志 API 的 DELETE 会在队列外把当前份改名成 `.1.log`；缓存的字节数这时
      // 已经失真。只在"即将轮转"这个真正会造成破坏的关口重新核对实际大小。
      if (_bytes.containsKey(id) &&
          maxBytes > 0 &&
          bytes > 0 &&
          bytes + pending > maxBytes) {
        bytes = file.existsSync() ? file.lengthSync() : 0;
      }
      if (maxBytes > 0 && bytes > 0 && bytes + pending > maxBytes) {
        await _rotate(id);
        bytes = 0;
      }
      await AtomicFile.appendLine(path, entry);
      _bytes[id] = bytes + pending;
    } catch (error) {
      _degrade(id, error);
    }
  }

  /// 轮转：`<id>.N-2.log → <id>.N-1.log`（最旧那份被覆盖），`<id>.log → <id>.1.log`。
  ///
  /// 只在写队列的任务里调用 ⇒ 与追加互斥，不会出现"改名后仍写旧句柄"。
  Future<void> _rotate(String id) async {
    if (maxFiles <= 1) {
      final File current = File(paths.pluginLogFile(id));
      if (current.existsSync()) await current.delete();
      return;
    }
    final File oldest = File(paths.pluginLogFileAt(id, maxFiles - 1));
    if (oldest.existsSync()) await oldest.delete();
    for (int index = maxFiles - 2; index >= 1; index--) {
      final File from = File(paths.pluginLogFileAt(id, index));
      if (!from.existsSync()) continue;
      final File to = File(paths.pluginLogFileAt(id, index + 1));
      if (to.existsSync()) await to.delete();
      await from.rename(to.path);
    }
    final File current = File(paths.pluginLogFile(id));
    if (current.existsSync()) {
      final File first = File(paths.pluginLogFileAt(id, 1));
      if (first.existsSync()) await first.delete();
      await current.rename(first.path);
    }
  }

  /// 落盘失败：**每个插件只报一次**，然后该插件降级为"不落盘"（stderr 照旧）。
  void _degrade(String id, Object error) {
    if (!_degraded.add(id)) return;
    try {
      _failureLog(
        '[tree] 警告：插件 $id 的日志落盘失败，本次运行已跳过它的日志文件'
        '（不影响任何功能）：${paths.pluginLogFile(id)}：$error',
      );
    } catch (_) {
      // 连提示都写不出去（stderr 也没了）：放弃提示，不影响核心。
    }
  }
}
