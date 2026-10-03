import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree/ui/services/core_log_files.dart';
import 'package:tree/ui/widgets/core_log_card.dart';
import 'package:tree/ui/widgets/core_log_viewer_dialog.dart';

/// 核心日志入口的应用侧测试：**尾部读取**与「拿不到数据根就退回没有入口」。
///
/// 为什么值得测：这条链路是用户唯一的取证手段，而它有两个"静默失败"的坑——
/// 读到空、路径猜错。两处都必须给出可读状态而不是空白弹窗。
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('tree_app_core_log_');
  });

  tearDown(() {
    // 目录里可能有正在被读的文件（Windows 会拒绝删除）：清理失败不该让测试红
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  String writeLog(List<String> lines) {
    final String path = '${tempDir.path}${Platform.pathSeparator}core.log';
    File(path).writeAsStringSync('${lines.join('\n')}\n');
    return path;
  }

  /// 让"弹窗 + 真文件 IO"都能跑完。
  ///
  /// widget 测试默认跑在 fake async 里：真实文件 IO 的 Future **不会**自己完成，
  /// 必须借 [WidgetTester.runAsync] 把真实事件循环让出去；而 IO 链上的每个 await
  /// 又要靠 `pump()` 冲一次微任务。所以交替来回几轮，直到读取链走完。
  Future<void> settleWithIo(WidgetTester tester) async {
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await tester.pump();
  }

  group('CoreLogFiles.readTail', () {
    test('只取尾部 N 行（日志单份可达 8 MiB，不能整份读进来）', () async {
      final String path = writeLog(<String>[
        for (int i = 0; i < 500; i++) 'pid=1 [core:compact] 第 $i 行',
      ]);
      final String? tail = await CoreLogFiles.readTail(path, lines: 3);
      expect(tail!.split('\n'), <String>[
        'pid=1 [core:compact] 第 497 行',
        'pid=1 [core:compact] 第 498 行',
        'pid=1 [core:compact] 第 499 行',
      ]);
    });

    test('行数不足时全给；空文件给空串', () async {
      final String short = writeLog(<String>['pid=1 a', 'pid=1 b']);
      expect(await CoreLogFiles.readTail(short, lines: 50), 'pid=1 a\npid=1 b');
      final String empty = '${tempDir.path}${Platform.pathSeparator}empty.log';
      File(empty).writeAsStringSync('');
      expect(await CoreLogFiles.readTail(empty), '');
    });

    test('文件不存在 ⇒ null（区别于空文件，弹窗据此给原因而不是空框）', () async {
      final String missing =
          '${tempDir.path}${Platform.pathSeparator}nope-core.log';
      expect(await CoreLogFiles.readTail(missing), isNull);
      expect(CoreLogFiles.missingReason(missing), contains(missing));
    });

    test('日志目录取自日志文件所在目录（用于「打开日志目录」）', () async {
      final String path = writeLog(<String>['x']);
      expect(CoreLogFiles.logDirOf(path), tempDir.path);
    });
  });

  group('CoreLogCard', () {
    testWidgets('拿不到数据根：两个入口都禁用，并说明原因（不猜 %APPDATA%）', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: CoreLogCard(logFile: ''))),
      );
      expect(find.text('核心日志'), findsOneWidget);
      final FilledButton tail = tester.widget<FilledButton>(
        find.byKey(const Key('core-log-tail')),
      );
      final OutlinedButton openDir = tester.widget<OutlinedButton>(
        find.byKey(const Key('core-log-open-dir')),
      );
      expect(tail.onPressed, isNull);
      expect(openDir.onPressed, isNull);
      expect(find.textContaining('没有提供数据根'), findsOneWidget);
    });

    testWidgets('有数据根：入口可用，路径原样显示', (WidgetTester tester) async {
      final String path = writeLog(<String>['pid=1 [core:boot] 已就绪']);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: CoreLogCard(logFile: path))),
      );
      final FilledButton tail = tester.widget<FilledButton>(
        find.byKey(const Key('core-log-tail')),
      );
      expect(tail.onPressed, isNotNull);
      expect(find.text(path), findsOneWidget);
    });

    testWidgets('点开弹窗：看到的就是日志尾部（含 pid 行）', (WidgetTester tester) async {
      final String path = writeLog(<String>[
        'pid=1 [core:compact] 开始压缩',
        'pid=1 [core:compact] 已接管：plugin=compact_plugin',
      ]);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: CoreLogCard(logFile: path))),
      );
      await tester.tap(find.byKey(const Key('core-log-tail')));
      await settleWithIo(tester);
      expect(
        find.textContaining('pid=1 [core:compact] 已接管'),
        findsOneWidget,
      );
    });
  });

  group('CoreLogViewerDialog', () {
    testWidgets('文件不存在：给出可读原因而不是空框', (WidgetTester tester) async {
      final String missing = '${tempDir.path}${Platform.pathSeparator}nope.log';
      await tester.pumpWidget(
        MaterialApp(home: CoreLogViewerDialog(logFile: missing)),
      );
      await settleWithIo(tester);
      expect(find.textContaining('还没有核心日志文件'), findsOneWidget);
      expect(find.textContaining(missing), findsWidgets);
    });
  });
}
