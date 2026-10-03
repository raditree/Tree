import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// [CoreLogSink] 的行为测试：**双写**（stderr 逐字 + 文件带 pid）、轮转、
/// 失败降级、以及"绝不抛异常 / 绝不阻塞调用方"这三条硬约束。
///
/// 为什么值得单独测：日志出口是"核心功能之外的旁路"，它坏掉必须**不影响核心**
/// （磁盘满、目录只读都发生过）；同时它又是唯一的事后取证手段（发布版看不到
/// stderr），所以"到底有没有落盘、轮转对不对"必须可验证。
void main() {
  late Directory tempDir;
  late TreePaths paths;
  late List<String> stderrLines;
  late List<String> failures;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('tree_core_log_');
    paths = TreePaths(tempDir.path);
    stderrLines = <String>[];
    failures = <String>[];
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  CoreLogSink sink({
    int? maxBytes,
    int? maxFiles,
    int processId = 4242,
  }) => CoreLogSink(
    paths,
    maxBytes: maxBytes ?? CoreLogSink.defaultMaxBytes,
    maxFiles: maxFiles ?? CoreLogSink.defaultMaxFiles,
    processId: processId,
    stderrSink: stderrLines.add,
    failureLog: failures.add,
  );

  test('路径布局：日志落 <数据根>/logs/core.log，且随 ensureLayout 一起建目录', () async {
    expect(paths.logsDir, p.join(tempDir.path, 'logs'));
    expect(paths.coreLogFile, p.join(tempDir.path, 'logs', 'core.log'));
    expect(paths.coreLogFileAt(2), p.join(tempDir.path, 'logs', 'core.2.log'));
    await paths.ensureLayout();
    expect(Directory(paths.logsDir).existsSync(), isTrue);
  });

  test('双写：stderr 逐字保持原样，文件行带 pid', () async {
    final CoreLogSink log = sink();
    final void Function(String) compact = log.forPrefix('core:compact');

    compact('开始压缩 agent=agt_1');
    compact('已接管：plugin=compact_plugin');
    await log.flush();

    expect(stderrLines, <String>[
      '[core:compact] 开始压缩 agent=agt_1',
      '[core:compact] 已接管：plugin=compact_plugin',
    ], reason: 'stderr 是原地行为：格式、前缀、顺序都不能变');
    final List<String> fileLines = File(
      paths.coreLogFile,
    ).readAsLinesSync().where((String line) => line.isNotEmpty).toList();
    expect(fileLines, <String>[
      'pid=4242 [core:compact] 开始压缩 agent=agt_1',
      'pid=4242 [core:compact] 已接管：plugin=compact_plugin',
    ], reason: '同一数据根可能有两个核心进程在写：文件行必须带 pid 才能归因');
  });

  test('懒打开：只构造不写，不碰磁盘', () async {
    sink();
    expect(Directory(paths.logsDir).existsSync(), isFalse);
    expect(File(paths.coreLogFile).existsSync(), isFalse);
  });

  test('不阻塞：write 同步返回，flush 后内容才保证完整', () async {
    final CoreLogSink log = sink();
    for (int i = 0; i < 50; i++) {
      log.write('[core:boot] 第 $i 行');
    }
    // 立刻读可能还没写完（write-behind 是刻意的：日志不能拖慢生成）；
    // flush 之后必须一行不少、顺序不乱。
    await log.flush();
    final List<String> lines = File(paths.coreLogFile)
        .readAsLinesSync()
        .where((String line) => line.isNotEmpty)
        .toList();
    expect(lines, hasLength(50));
    expect(lines.first, 'pid=4242 [core:boot] 第 0 行');
    expect(lines.last, 'pid=4242 [core:boot] 第 49 行');
    expect(log.degraded, isFalse);
  });

  test('按大小轮转：只保留 maxFiles 份，最旧那份被丢弃', () async {
    // 每行约 40 字节 ⇒ maxBytes=120 时每份装 3 行左右
    final CoreLogSink log = sink(maxBytes: 120, maxFiles: 3);
    for (int i = 0; i < 30; i++) {
      log.write('[core:compact] 第 $i 行 payload 0123456789');
    }
    await log.flush();

    final File current = File(paths.coreLogFile);
    expect(current.existsSync(), isTrue);
    expect(File(paths.coreLogFileAt(1)).existsSync(), isTrue);
    expect(File(paths.coreLogFileAt(2)).existsSync(), isTrue);
    expect(
      File(paths.coreLogFileAt(3)).existsSync(),
      isFalse,
      reason: 'maxFiles=3 ⇒ 最多 core.log + core.1.log + core.2.log',
    );
    // 最新一行必须还在当前那份里（轮转不能把自己刚写的丢掉）
    final List<String> currentLines = current
        .readAsLinesSync()
        .where((String line) => line.isNotEmpty)
        .toList();
    expect(currentLines.last, contains('第 29 行'));
    // 单份不超过上限（允许超出一行：判断发生在写该行之前）
    expect(
      current.lengthSync(),
      lessThan(120 + 64),
      reason: '单份大小必须被阈值兜住，否则磁盘会无限增长',
    );
    // 覆盖整整一轮：轮转多轮之后份数仍受控，且旧内容被真丢弃
    for (int i = 0; i < 60; i++) {
      log.write('[core:compact] 第二轮 $i');
    }
    await log.flush();
    expect(File(paths.coreLogFileAt(3)).existsSync(), isFalse);
    expect(
      File(paths.coreLogFile).readAsLinesSync().join('\n'),
      contains('第二轮'),
    );
  });

  test('落盘失败：只提示一次、降级为纯 stderr、绝不抛异常也不丢 stderr', () async {
    // 造一个必然写不成的落点：把 `core.log` 这个**路径**先占成目录
    final Directory blocker = Directory(paths.coreLogFile);
    blocker.createSync(recursive: true);
    final CoreLogSink log = sink();

    log.write('[core:meta] 第一次');
    await log.flush();
    log.write('[core:meta] 第二次');
    log.write('[core:meta] 第三次');
    await log.flush(); // 不允许抛

    expect(log.degraded, isTrue, reason: '写失败必须降级，而不是反复重试拖慢核心');
    expect(failures, hasLength(1), reason: '失败只报一次，不刷屏');
    expect(failures.single, contains('核心日志落盘失败'));
    expect(stderrLines, <String>[
      '[core:meta] 第一次',
      '[core:meta] 第二次',
      '[core:meta] 第三次',
    ], reason: '落盘坏掉时 stderr 那份必须照旧完整');
  });

  test('失败后再次 flush / write 仍是安全的空操作', () async {
    Directory(paths.coreLogFile).createSync(recursive: true);
    final CoreLogSink log = sink();
    log.write('a');
    await log.flush();
    expect(log.degraded, isTrue);
    log.write('b');
    await log.flush();
    await log.flush();
    expect(failures, hasLength(1));
    expect(stderrLines, <String>['a', 'b']);
  });

  test('maxFiles=1：轮转时只清空当前那份', () async {
    final CoreLogSink log = sink(maxBytes: 60, maxFiles: 1);
    for (int i = 0; i < 20; i++) {
      log.write('[core:x] 行 $i 0123456789012345678901234567890');
    }
    await log.flush();
    expect(File(paths.coreLogFileAt(1)).existsSync(), isFalse);
    expect(File(paths.coreLogFile).readAsLinesSync().last, contains('行 19'));
  });

  test('默认轮转参数就是"8 MiB × 5 份"', () {
    expect(CoreLogSink.defaultMaxBytes, 8 * 1024 * 1024);
    expect(CoreLogSink.defaultMaxFiles, 5);
    final CoreLogSink log = sink();
    expect(log.maxBytes, CoreLogSink.defaultMaxBytes);
    expect(log.maxFiles, CoreLogSink.defaultMaxFiles);
    expect(log.logFile, paths.coreLogFile);
    expect(log.logDir, paths.logsDir);
  });
}
