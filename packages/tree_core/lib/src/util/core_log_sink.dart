import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../store/atomic_file.dart';
import '../store/tree_paths.dart';
import '../store/write_queue.dart';
import 'log_timestamp.dart';

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
    final String stamp = logLineTimestamp(_clock());
    // 文件行带时间戳与 pid：同一数据根可能同时有"App 的核心"与"开发期自起的核心"在写。
    _queue.enqueue(logFile, () => _append('$stamp pid=$_pid $line'));
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
      // 日志 API 的 DELETE 会在队列外把当前份改名成 `.1.log`；缓存的 `_bytes` 这时
      // 已经失真。只在"即将轮转"这个真正会造成破坏的关口重新核对实际大小：
      // 否则会拿旧的大小把刚清空的小文件又轮转一次，连带覆盖掉备份。
      if (_bytes != null &&
          maxBytes > 0 &&
          bytes > 0 &&
          bytes + pending > maxBytes) {
        bytes = file.existsSync() ? file.lengthSync() : 0;
      }
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

/// 插件日志的**源注册与尾部读**（原日志 API 已于 2026-11-08 删除，保留给内部排查与测试）。
///
/// 合法源只有两种：
/// - `core` → `<数据根>/logs/core.log`（与 [CoreLogSink] 同一份）；
/// - `plugin:<id>` → `<数据根>/logs/plugins/<id>.log`。
///
/// 插件源只列**已配置**（由 [pluginIds] 提供）或**已存在日志文件**的插件：不存在的
/// 源不凭空出现在枚举里，读它按非法源回 400（不泄露"这个插件有没有日志"）。
class LogSourceRegistry {
  LogSourceRegistry({required this.paths, List<String> Function()? pluginIds})
    : _pluginIds = pluginIds ?? (() => const <String>[]);

  /// 路径布局（只有这一个来源）。
  final TreePaths paths;

  /// 已配置的插件 id（核心启动时由插件总线注入；不启动插件也能枚举）。
  final List<String> Function() _pluginIds;

  /// 核心源 id。
  static const String coreSourceId = 'core';

  /// 插件源前缀。
  static const String pluginSourcePrefix = 'plugin:';

  /// 尾部读的默认行数。
  static const int defaultTailLines = 200;

  /// 尾部读允许的最大行数（查询参数再大也按这个截断）。
  static const int maxTailLines = 5000;

  /// 单次响应承载的**原始行字节**硬上限（1 MiB）。
  ///
  /// 超限只返回最后一页并 `truncated:true`，绝不整块载入大日志。
  static const int maxResponseBytes = 1024 * 1024;

  /// 从文件尾部倒读时的分块大小（64 KiB），保证内存只与"这一页"有关。
  static const int _chunkBytes = 64 * 1024;

  /// 枚举当前可见的日志源（core 在前，插件按 id 排序）。
  ///
  /// 回包形状按设计 §3.1：`{sources:[{id, kind, size?, modified?}]}`；文件不存在时
  /// 不写 `size`/`modified`（已配置但还没产出日志的插件也要能出现在列表里）。
  Future<List<Map<String, dynamic>>> sources() async {
    final Set<String> ids = <String>{coreSourceId};
    for (final String pluginId in _pluginIds()) {
      final String trimmed = pluginId.trim();
      if (trimmed.isEmpty) continue;
      try {
        TreePaths.safeSegment(trimmed);
      } on ArgumentError {
        // 配置里的 id 不安全 ⇒ 不可能有合法落点，跳过（不让枚举成为路径注入面）。
        continue;
      }
      ids.add('$pluginSourcePrefix$trimmed');
    }
    // 已存在但配置里没有的插件日志（例如刚卸载的插件留下的文件）：仍可作为源读。
    for (final String id in await _existingPluginIds()) {
      ids.add('$pluginSourcePrefix$id');
    }
    final List<String> sorted = ids.toList()
      ..sort((String a, String b) {
        if (a == coreSourceId) return -1;
        if (b == coreSourceId) return 1;
        return a.compareTo(b);
      });
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
    for (final String id in sorted) {
      final String? path = _resolve(id);
      if (path == null) continue;
      final File file = File(path);
      final bool exists = await file.exists();
      final Map<String, dynamic> row = <String, dynamic>{
        'id': id,
        'kind': id == coreSourceId ? 'core' : 'plugin',
      };
      if (exists) {
        final FileStat stat = await file.stat();
        row['size'] = stat.size;
        row['modified'] = stat.modified.toUtc().toIso8601String();
      }
      rows.add(row);
    }
    return rows;
  }

  /// 把源 id 解析成磁盘文件；非法 / 未知 / 越界一律返回 null（调用方回 400）。
  String? _resolve(String source) {
    if (source == coreSourceId) return paths.coreLogFile;
    if (!source.startsWith(pluginSourcePrefix)) return null;
    final String pluginId = source.substring(pluginSourcePrefix.length).trim();
    if (pluginId.isEmpty) return null;
    try {
      TreePaths.safeSegment(pluginId);
    } on ArgumentError {
      return null;
    }
    final bool configured = _pluginIds().any(
      (String id) => id.trim() == pluginId,
    );
    if (!configured) {
      // 未配置时只认已经存在的日志文件（不能凭一个 id 就读到任意路径）。
      final File file = File(paths.pluginLogFile(pluginId));
      if (!file.existsSync()) return null;
    }
    return paths.pluginLogFile(pluginId);
  }

  /// 源是否合法（供 HTTP 层在任何磁盘动作前给出 400）。
  bool isKnownSource(String source) => _resolve(source) != null;

  /// 尾部读（`GET /api/logs/{source}?tail=&since=`）。
  ///
  /// `since` 的口径 = **行号（1 起）**：从第 `since` 行开始返回；不传则读文件尾部。
  /// 返回 `next_since`（下一次传 `since` 的值）。单次原始行字节超过
  /// [maxResponseBytes] 时只回最后一页并 `truncated:true`。
  Future<Map<String, dynamic>> readTail(
    String source, {
    int tail = defaultTailLines,
    int? since,
  }) async {
    final String? path = _resolve(source);
    if (path == null) {
      throw ArgumentError.value(source, 'source', '未知日志源');
    }
    if (since != null && since < 1) {
      throw ArgumentError.value(since, 'since', 'since 必须是 >= 1 的行号');
    }
    final int limit = tail.clamp(1, maxTailLines);
    final File file = File(path);
    if (!await file.exists()) {
      return <String, dynamic>{
        'source': source,
        'lines': const <String>[],
        // 文件不存在（还没写 / 刚被清空轮转）⇒ 从新文件第 1 行重新开始，
        // 不能沿用旧文件的 since，否则会跳过清空后新写入的日志。
        'next_since': 1,
        'tail': limit,
        'truncated': false,
        'size': 0,
      };
    }
    final FileStat stat = await file.stat();
    final _LogPage page = since == null
        ? await _tailFromEnd(file, limit)
        : await _tailSince(file, since, limit);
    return <String, dynamic>{
      'source': source,
      'lines': page.lines,
      'next_since': page.nextSince,
      'tail': limit,
      'truncated': page.truncated,
      'size': stat.size,
      if (stat.size > 0)
        'modified': stat.modified.toUtc().toIso8601String(),
    };
  }

  /// 清空并轮转（`DELETE /api/logs/{source}`）：当前份 → `<name>.1.log`（覆盖旧备份）。
  ///
  /// 返回清理掉的字节数与备份路径；文件不存在时 cleared_bytes 为 0、backup_path 为 null。
  Future<Map<String, dynamic>> clear(String source) async {
    final String? path = _resolve(source);
    if (path == null) {
      throw ArgumentError.value(source, 'source', '未知日志源');
    }
    final File file = File(path);
    if (!await file.exists()) {
      return <String, dynamic>{
        'source': source,
        'cleared_bytes': 0,
        'backup_path': null,
      };
    }
    final int size = await file.length();
    final String backup = source == coreSourceId
        ? paths.coreLogFileAt(1)
        : paths.pluginLogFileAt(
            source.substring(pluginSourcePrefix.length),
            1,
          );
    final File backupFile = File(backup);
    if (await backupFile.exists()) await backupFile.delete();
    await file.rename(backup);
    return <String, dynamic>{
      'source': source,
      'cleared_bytes': size,
      'backup_path': backup,
    };
  }

  // ── 内部实现 ─────────────────────────────────────────────────────────

  /// 已存在的插件日志文件名 → 插件 id（排除 `.<n>.log` 历史份）。
  Future<List<String>> _existingPluginIds() async {
    final Directory dir = Directory(paths.pluginLogsDir);
    if (!await dir.exists()) return const <String>[];
    final List<String> ids = <String>[];
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is! File) continue;
      final String name = entity.uri.pathSegments.last;
      if (!name.endsWith('.log')) continue;
      final String stem = name.substring(0, name.length - 4);
      // `foo.1.log` 是轮转备份，不是源。
      if (RegExp(r'\.\d+$').hasMatch(stem)) continue;
      if (stem.isEmpty) continue;
      ids.add(stem);
    }
    return ids;
  }

  /// 从文件尾倒读最后 [tail] 行；只保留至多 [maxResponseBytes] 字节的尾部。
  Future<_LogPage> _tailFromEnd(File file, int tail) async {
    final RandomAccessFile handle = await file.open();
    try {
      final int length = await handle.length();
      if (length == 0) {
        return const _LogPage(
          lines: <String>[],
          nextSince: 1,
          truncated: false,
        );
      }
      int position = length;
      int newlines = 0;
      int collectedBytes = 0;
      int collectedStart = length;
      bool byteTruncated = false;
      final List<List<int>> chunks = <List<int>>[];
      while (position > 0) {
        final int size = position > _chunkBytes ? _chunkBytes : position;
        position -= size;
        await handle.setPosition(position);
        final List<int> chunk = await handle.read(size);
        for (final int byte in chunk) {
          if (byte == 0x0A) newlines++;
        }
        final int room = maxResponseBytes - collectedBytes;
        if (room <= 0) {
          byteTruncated = true;
          continue;
        }
        if (chunk.length <= room) {
          chunks.add(chunk);
          collectedBytes += chunk.length;
          collectedStart = position;
        } else {
          // 只收这一块尾部能放下的部分（起点因此落在块内）。
          chunks.add(chunk.sublist(chunk.length - room));
          collectedStart = position + (chunk.length - room);
          collectedBytes = maxResponseBytes;
          byteTruncated = true;
        }
      }
      // 文件是否以换行结尾，决定总行数（用于 next_since）。
      await handle.setPosition(length - 1);
      final List<int> lastByte = await handle.read(1);
      final bool endsWithNewline = lastByte.isNotEmpty && lastByte.first == 0x0A;
      final int totalLines = newlines + (endsWithNewline ? 0 : 1);

      final BytesBuilder builder = BytesBuilder(copy: false);
      for (int index = chunks.length - 1; index >= 0; index--) {
        builder.add(chunks[index]);
      }
      String text = utf8.decode(builder.takeBytes(), allowMalformed: true);
      List<String> lines = text
          .split('\n')
          .map(
            (String line) => line.endsWith('\r')
                ? line.substring(0, line.length - 1)
                : line,
          )
          .toList();
      if (text.endsWith('\n')) lines.removeLast();
      // 收集起点在文件中间 ⇒ 首行是半行，丢掉（与 AtomicFile.readTail 同口径）。
      if (collectedStart > 0 && lines.isNotEmpty) lines.removeAt(0);
      if (lines.length > tail) {
        lines = lines.sublist(lines.length - tail);
      }
      return _LogPage(
        lines: lines,
        nextSince: totalLines + 1,
        truncated: byteTruncated,
      );
    } finally {
      await handle.close();
    }
  }

  /// 从第 [since] 行（1 起）开始读，最多 [tail] 行；流式读、内存只保留本页。
  Future<_LogPage> _tailSince(File file, int since, int tail) async {
    final List<String> lines = <String>[];
    int bytes = 0;
    int lineNo = 0;
    bool byteTruncated = false;
    // 是否一直读到文件尾。提前 break（行数 / 字节上限）时 next_since 指向未读的那行。
    bool reachedEnd = true;
    final Stream<String> stream = file
        .openRead()
        // 插件日志可能混入非 UTF-8 字节：与尾部读同一口径，坏字节按 U+FFFD 顶替，
        // 不让一行坏输入把整个日志 API 变成 500。
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter());
    await for (final String line in stream) {
      lineNo++;
      if (lineNo < since) continue;
      if (lines.length >= tail) {
        reachedEnd = false;
        break;
      }
      final int lineBytes = utf8.encode(line).length + 1;
      if (bytes + lineBytes > maxResponseBytes) {
        byteTruncated = true;
        reachedEnd = false;
        break;
      }
      lines.add(line);
      bytes += lineBytes;
    }
    // 正常情况下 next_since = since + 本页行数；若 since 已越过当前 EOF（日志被清空
    // / 轮转后又从第 1 行写起），则回到 EOF+1，避免永久跳过新日志。
    final int nextSince = reachedEnd && lineNo < since
        ? lineNo + 1
        : since + lines.length;
    return _LogPage(
      lines: lines,
      nextSince: nextSince,
      truncated: byteTruncated,
    );
  }
}

/// 一页日志的内部结果（对外统一转成 JSON map）。
class _LogPage {
  const _LogPage({
    required this.lines,
    required this.nextSince,
    required this.truncated,
  });

  final List<String> lines;
  final int nextSince;
  final bool truncated;
}
