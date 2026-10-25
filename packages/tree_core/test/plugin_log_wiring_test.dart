import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 插件日志的**写入 → 读出**端到端用例。
///
/// 片 F 的日志 API 只读文件，而此前没有任何写入者（测试都是手工种文件）——
/// 于是"插件自己的日志能从 `/api/logs/plugin:<id>` 查到"这件事从未被真跑过。
/// 这里用真插件进程（test/fixtures/fake_plugin.dart）钉两路来源：
/// - 插件 **stderr** → `[stderr]` 行；
/// - 插件 **log 通知** → `[notify:<level>]` 行。
void main() {
  late Directory temp;
  late String script;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_plugin_log_wiring_');
    script = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'fake_plugin.dart',
    );
    expect(File(script).existsSync(), isTrue, reason: '假插件脚本必须存在');
  });

  tearDown(() async {
    for (int i = 0; i < 10; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
    }
  });

  String yamlFor() =>
      'enabled: true\n'
      'plugins:\n'
      '  - id: sample\n'
      '    name: sample\n'
      '    command: "${Platform.resolvedExecutable.replaceAll('\\', '/')}"\n'
      '    args: ['
      '"${script.replaceAll('\\', '/')}"'
      ', "--stderr-line", "启动横幅"'
      ']\n'
      '    granularity: team\n'
      '    scope: {team_id: team-1, mode_key: local}\n';

  test('插件 stderr 与 log 通知都落进 plugin:sample，且可按源/尾部读出', () async {
    final File config = File(p.join(temp.path, 'config', 'plugins.yaml'));
    config.createSync(recursive: true);
    config.writeAsStringSync(yamlFor());

    final PluginBus bus = PluginBus(
      configFile: config.path,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
    );
    final CoreServer server = await CoreServer.start(
      pluginBus: bus,
      dataDir: temp.path,
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
    );
    addTearDown(() async {
      await server.close();
      await bus.close();
    });

    // 生产顺序：核心先起（绑定日志落盘），插件后起。
    await bus.start();
    await bus.ensureToolTableFresh();

    // 触发一条 log 通知：总线事件 → 假插件回 "收到事件 ..." 的 log 通知。
    expect(
      bus.dispatch(<String, dynamic>{
        'type': 'test.event',
        'team_id': 'team-1',
      }),
      1,
      reason: '假插件应在总线里（否则后面等不到 log 通知）',
    );

    final String text = await _waitForLog(
      server,
      'plugin:sample',
      (String body) => body.contains('收到事件 test.event'),
    );
    expect(text, contains('[stderr] 启动横幅'), reason: 'stderr 那一行必须落盘');
    expect(text, contains('[notify:info] 收到事件 test.event'));
    expect(
      File(p.join(temp.path, 'logs', 'plugins', 'sample.log')).existsSync(),
      isTrue,
      reason: '日志 API 与落盘必须同一个文件',
    );
    expect(
      server.logSources.isKnownSource('plugin:sample'),
      isTrue,
      reason: '已配置插件即使日志文件还没产出也要在源列表里',
    );
  });
}

/// 轮询日志源的尾部，直到 [ready] 为真或超时；返回最后一次读到的全文。
Future<String> _waitForLog(
  CoreServer server,
  String source,
  bool Function(String text) ready, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  String text = '';
  while (DateTime.now().isBefore(deadline)) {
    final Map<String, dynamic> page = await server.logSources.readTail(
      source,
      tail: 200,
    );
    text = (page['lines'] as List<dynamic>).join('\n');
    if (ready(text)) return text;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return text;
}
