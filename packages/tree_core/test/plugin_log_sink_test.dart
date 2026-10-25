import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 插件日志落盘出口（`PluginLogSink`）的行为钉点。
///
/// 为什么要有这组用例：日志 API（`/api/logs/plugin:<id>`）只读文件，
/// 而片 F 之前**没有任何写入者**，测试都是手工种文件——于是"插件日志可读"
/// 这条验收其实从来没被真跑过。这里补的是写入侧的形状、分文件、轮转与降级。
void main() {
  late Directory temp;
  late TreePaths paths;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_plugin_log_');
    paths = TreePaths(temp.path);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  File current(String id) => File(paths.pluginLogFile(id));

  test('按插件分文件，行首带时间戳与来源标记', () async {
    int calls = 0;
    final PluginLogSink sink = PluginLogSink(
      paths,
      clock: () => DateTime(2026, 10, 25, 10, 0, 0, 123 + calls++),
    );
    sink.write('tree.agent', '已启动');
    sink.write('tree.agent', 'hello ok', channel: 'notify:info');
    sink.write('tree.ui.default', '[tree_ui] ready');
    await sink.flush();

    final List<String> agent = current('tree.agent').readAsLinesSync();
    expect(agent, hasLength(2));
    expect(
      agent[0],
      matches(
        r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2} '
        r'plugin=tree\.agent \[stderr\] 已启动$',
      ),
    );
    expect(agent[1], contains('plugin=tree.agent [notify:info] hello ok'));
    expect(
      current('tree.ui.default').readAsLinesSync().single,
      contains('plugin=tree.ui.default [stderr] [tree_ui] ready'),
    );
    // 不存在的插件不会凭空多出文件。
    expect(File(paths.pluginLogFile('tree.other')).existsSync(), isFalse);
  });

  test('非法插件 id 直接跳过（日志出口不能变成路径注入面）', () async {
    final PluginLogSink sink = PluginLogSink(paths);
    sink.write('..', 'x');
    sink.write('a/b', 'x');
    sink.write('', 'x');
    await sink.flush();
    expect(Directory(paths.pluginLogsDir).existsSync(), isFalse);
  });

  test('按大小轮转：当前份 → .1.log，最旧一份被覆盖', () async {
    final PluginLogSink sink = PluginLogSink(
      paths,
      maxBytes: 160,
      maxFiles: 3,
      clock: () => DateTime(2026, 10, 25, 10, 0, 0),
    );
    for (int i = 0; i < 10; i++) {
      sink.write('tree.agent', 'line-$i-${'x' * 30}');
    }
    await sink.flush();

    expect(current('tree.agent').existsSync(), isTrue);
    expect(File(paths.pluginLogFileAt('tree.agent', 1)).existsSync(), isTrue);
    expect(File(paths.pluginLogFileAt('tree.agent', 2)).existsSync(), isTrue);
    // maxFiles=3 ⇒ 只有当前份 + 两份历史，不出现 .3.log。
    expect(File(paths.pluginLogFileAt('tree.agent', 3)).existsSync(), isFalse);
    for (final File file in <File>[
      current('tree.agent'),
      File(paths.pluginLogFileAt('tree.agent', 1)),
    ]) {
      for (final String line in file.readAsLinesSync()) {
        expect(line, contains('plugin=tree.agent [stderr] line-'));
      }
    }
  });

  test('日志 API 清空（改名备份）后继续写：新行落在当前份，不追进备份', () async {
    final PluginLogSink sink = PluginLogSink(paths);
    sink.write('tree.agent', 'before-clear');
    await sink.flush();

    final LogSourceRegistry registry = LogSourceRegistry(
      paths: paths,
      pluginIds: () => <String>['tree.agent'],
    );
    final Map<String, dynamic> cleared = await registry.clear(
      'plugin:tree.agent',
    );
    expect(cleared['cleared_bytes'], greaterThan(0));

    sink.write('tree.agent', 'after-clear');
    await sink.flush();

    expect(current('tree.agent').readAsLinesSync().single, contains('after-clear'));
    expect(
      File(paths.pluginLogFileAt('tree.agent', 1)).readAsLinesSync().single,
      contains('before-clear'),
    );
  });
}
