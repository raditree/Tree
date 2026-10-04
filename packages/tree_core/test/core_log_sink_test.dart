import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// [CoreLogSink] 的行为测试：**双写**（stderr 逐字 + 文件带时间戳与 pid）、轮转、
/// 失败降级、以及"绝不抛异常 / 绝不阻塞调用方"这三条硬约束。
///
/// 为什么值得单独测：日志出口是"核心功能之外的旁路"，它坏掉必须**不影响核心**
/// （磁盘满、目录只读都发生过）；同时它又是唯一的事后取证手段（发布版看不到
/// stderr），所以"到底有没有落盘、轮转对不对、落盘行的时间戳是不是真的"必须可验证。
///
/// 期望的落盘行首时间戳由 [expectedStamp] **独立算**（不走实现那条路），
/// 且偏移不写死 —— 换台机器 / 换个时区跑依然成立。
String expectedStamp(DateTime at) {
  // 先从注入时刻的 UTC 表示出发，再单独把 `timeZoneOffset` 加回去还原本地墙钟：
  // 与实现（直接读本地 DateTime 的分量）是**两条不同的推导路径**，
  // 这样"偏移算错""本地/UTC 混用""毫秒没补零"都会被抓住。
  final DateTime utcWall = at.toUtc();
  final Duration offset = at.toLocal().timeZoneOffset;
  final DateTime local = DateTime.utc(
    utcWall.year,
    utcWall.month,
    utcWall.day,
    utcWall.hour,
    utcWall.minute,
    utcWall.second,
    utcWall.millisecond,
  ).add(offset);
  String two(int value) => value.toString().padLeft(2, '0');
  final int offsetMinutes = offset.inMinutes.abs();
  return '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-${two(local.day)}'
      'T${two(local.hour)}:${two(local.minute)}:${two(local.second)}'
      '.${local.millisecond.toString().padLeft(3, '0')}'
      '${offset.isNegative ? '-' : '+'}${two(offsetMinutes ~/ 60)}:${two(offsetMinutes % 60)}';
}

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
    DateTime Function()? clock,
  }) => CoreLogSink(
    paths,
    maxBytes: maxBytes ?? CoreLogSink.defaultMaxBytes,
    maxFiles: maxFiles ?? CoreLogSink.defaultMaxFiles,
    processId: processId,
    stderrSink: stderrLines.add,
    failureLog: failures.add,
    clock: clock,
  );

  test('路径布局：日志落 <数据根>/logs/core.log，且随 ensureLayout 一起建目录', () async {
    expect(paths.logsDir, p.join(tempDir.path, 'logs'));
    expect(paths.coreLogFile, p.join(tempDir.path, 'logs', 'core.log'));
    expect(paths.coreLogFileAt(2), p.join(tempDir.path, 'logs', 'core.2.log'));
    await paths.ensureLayout();
    expect(Directory(paths.logsDir).existsSync(), isTrue);
  });

  test('双写：stderr 逐字保持原样，文件行带时间戳与 pid', () async {
    final DateTime fake = DateTime(2026, 10, 5, 7, 24, 31, 123);
    final CoreLogSink log = sink(clock: () => fake);
    final void Function(String) compact = log.forPrefix('core:compact');

    compact('开始压缩 agent=agt_1');
    compact('已接管：plugin=compact_plugin');
    await log.flush();

    expect(stderrLines, <String>[
      '[core:compact] 开始压缩 agent=agt_1',
      '[core:compact] 已接管：plugin=compact_plugin',
    ], reason: 'stderr 是原地行为：格式、前缀、顺序都不能变（也不带时间戳）');
    final List<String> fileLines = File(
      paths.coreLogFile,
    ).readAsLinesSync().where((String line) => line.isNotEmpty).toList();
    expect(fileLines, <String>[
      '${expectedStamp(fake)} pid=4242 [core:compact] 开始压缩 agent=agt_1',
      '${expectedStamp(fake)} pid=4242 [core:compact] 已接管：plugin=compact_plugin',
    ], reason: '文件行 = 行首时间戳 + pid + 原行：时间是"何时"、pid 是"哪个核心进程写的"');
  });

  test('落盘行首时间戳：本地时间、毫秒 3 位、显式时区偏移；stderr 不含它', () async {
    final DateTime fake = DateTime(2026, 10, 5, 7, 24, 31, 123);
    final CoreLogSink log = sink(clock: () => fake);

    log.forPrefix('core:meta')('形状用例');
    await log.flush();

    final List<String> fileLines = File(paths.coreLogFile)
        .readAsLinesSync()
        .where((String line) => line.isNotEmpty)
        .toList();
    expect(fileLines, hasLength(1));
    expect(
      fileLines.single,
      '${expectedStamp(fake)} pid=4242 [core:meta] 形状用例',
      reason: '落盘行 = `<ISO8601 带时区> pid=<pid> <原行>`；偏移由 DateTime 自算（不写死 +08:00）',
    );
    // 形状钉子：`YYYY-MM-DDTHH:MM:SS.mmm±HH:MM`（本地墙钟分量由假时钟唯一决定）
    expect(
      fileLines.single,
      matches(
        RegExp(
          r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2} '
          r'pid=4242 \[core:meta\] 形状用例$',
        ),
      ),
      reason: '毫秒恰好 3 位、偏移是 ±HH:MM（不是 Z），且不出现别的东西',
    );
    expect(
      fileLines.single,
      startsWith('2026-10-05T07:24:31.123'),
      reason: '假时钟的本地墙钟分量必须原样出现',
    );

    expect(
      stderrLines,
      <String>['[core:meta] 形状用例'],
      reason: 'stderr 那一份**逐字不变**：既不加时间戳、也不加 pid',
    );
    expect(stderrLines.single, isNot(contains('2026-10-05')));
    expect(stderrLines.single, isNot(contains('pid=')));
  });

  test('时间戳在 write() 当下取：write-behind 不能等到落盘时才取时刻', () async {
    int calls = 0;
    final CoreLogSink log = sink(
      clock: () => DateTime(2026, 10, 5, 7, 24, 31, 123 + calls++),
    );

    // 两行都还没落盘，时钟已经往前走了：各行的行首时刻必须是它**入队那一刻**的值。
    log.write('[core:boot] a');
    log.write('[core:boot] b');
    await log.flush();

    final List<String> lines = File(paths.coreLogFile)
        .readAsLinesSync()
        .where((String line) => line.isNotEmpty)
        .toList();
    expect(lines, <String>[
      '${expectedStamp(DateTime(2026, 10, 5, 7, 24, 31, 123))} pid=4242 [core:boot] a',
      '${expectedStamp(DateTime(2026, 10, 5, 7, 24, 31, 124))} pid=4242 [core:boot] b',
    ], reason: '入队是 write-behind：时刻若在落盘时才取，这里两行会同岁、与真实时刻漂移');
  });

  test('懒打开：只构造不写，不碰磁盘', () async {
    sink();
    expect(Directory(paths.logsDir).existsSync(), isFalse);
    expect(File(paths.coreLogFile).existsSync(), isFalse);
  });

  test('不阻塞：write 同步返回，flush 后内容才保证完整', () async {
    final DateTime fake = DateTime(2026, 10, 5, 7, 24, 31, 123);
    final CoreLogSink log = sink(clock: () => fake);
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
    expect(lines.first, '${expectedStamp(fake)} pid=4242 [core:boot] 第 0 行');
    expect(lines.last, '${expectedStamp(fake)} pid=4242 [core:boot] 第 49 行');
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
    // 单份不超过上限（允许超出一行：判断发生在写该行之前）。
    // 上界 = maxBytes + 最长一行（含 \n）：行首时间戳 29 字符 + 空格 1
    //      + `pid=4242 [core:compact] 第 29 行 payload 0123456789`（53 + \n = 54）
    //      = 84 ⇒ 120 + 84 = 204。（加时间戳之前是 120 + 64：每行多了 30 字节。）
    expect(
      current.lengthSync(),
      lessThan(120 + 84),
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
