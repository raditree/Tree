import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

import 'ws_harness.dart';

/// 插件 WS 增量（M6c）：`plugin_status` / `plugin_event` 必须真的推到前端。
///
/// 前端 `PluginMonitorService` 的策略是"快照为准 + WS 增量尽力而为"，因此这里
/// 验证的是增量本身：注册成功、心跳失败被标记、插件主动通知被转成事件。
void main() {
  late Directory temp;
  late String script;
  late String eventsFile;
  late PluginBus bus;
  late CoreServer server;
  late TestWs ws;
  late List<Map<String, dynamic>> frames;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tree_plugin_ws_');
    script = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'fake_plugin.dart',
    );
    eventsFile = p.join(temp.path, 'events.jsonl');
    final File config = File('${temp.path}/config/plugins.yaml');
    config.createSync(recursive: true);
    config.writeAsStringSync(
      'enabled: true\n'
      'plugins:\n'
      '  - id: sample\n'
      '    name: 样例插件\n'
      '    command: "${Platform.resolvedExecutable.replaceAll('\\', '/')}"\n'
      '    args: ["${script.replaceAll('\\', '/')}", "--events-file", "${eventsFile.replaceAll('\\', '/')}"]\n'
      '    granularity: team\n'
      '    scope: {team_id: team-1}\n'
      '  - id: deaf\n'
      '    name: 聋插件\n'
      '    command: "${Platform.resolvedExecutable.replaceAll('\\', '/')}"\n'
      '    args: ["${script.replaceAll('\\', '/')}", "--ignore-ping"]\n'
      '    scope: {team_id: team-2}\n',
    );
    frames = <Map<String, dynamic>>[];
    // 广播目标要等核心起监听后才知道：可后置绑定的槽
    void Function(Map<String, dynamic> frame)? sink;
    bus = PluginBus(
      configFile: config.path,
      coreVersion: 'test',
      watchdogInterval: const Duration(seconds: 30),
      broadcast: (Map<String, dynamic> frame) {
        frames.add(frame);
        sink?.call(frame);
      },
    );
    server = await CoreServer.start(
      pluginBus: bus,
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
    );
    sink = server.hub.broadcast;
    ws = await TestWs.connect(server);
    ws.record();
  });

  tearDown(() async {
    await ws.close();
    await server.close();
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  test('插件启动 → plugin_status(registered) → 事件 → plugin_event', () async {
    await bus.start();
    await ws.until(
      (Map<String, dynamic> f) =>
          f['type'] == WsOutboundType.pluginStatus &&
          ((f['data'] as Map<String, dynamic>)['status'] == 'registered'),
      reason: 'plugin_status(registered)',
    );
    final Map<String, dynamic> registered = ws.frames.firstWhere(
      (Map<String, dynamic> f) =>
          f['type'] == WsOutboundType.pluginStatus &&
          ((f['data'] as Map<String, dynamic>)['status'] == 'registered'),
    );
    final Map<String, dynamic> data =
        registered['data'] as Map<String, dynamic>;
    expect(data['plugin_id'], 'sample');
    expect(data['granularity'], 'team');
    expect((data['scope'] as Map<String, dynamic>)['team_id'], 'team-1');
    expect(data['ts'], isA<int>());

    // 事件分发 → 插件主动 log 通知 → plugin_event 帧。
    // scope 过滤：sample 限定 team-1、deaf 限定 team-2（见上方配置）
    expect(
      bus.dispatch(<String, dynamic>{'type': 'task', 'team_id': 'team-1'}),
      1,
    );
    expect(
      bus.dispatch(<String, dynamic>{'type': 'task', 'team_id': 'team-9'}),
      0,
    );
    await ws.until(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.pluginEvent,
      reason: 'plugin_event',
    );
    final Map<String, dynamic> event =
        ws.frames.firstWhere(
              (Map<String, dynamic> f) =>
                  f['type'] == WsOutboundType.pluginEvent,
            )['data']
            as Map<String, dynamic>;
    expect(event['plugin_id'], 'sample');
    expect(event['method'], 'log');
    expect(
      (event['params'] as Map<String, dynamic>)['message'],
      contains('task'),
    );
    // 插件也真的收到了事件（落文件）
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(File(eventsFile).readAsStringSync(), contains('task'));
  });

  test('看门狗判定死亡 → plugin_status(disabled) 带原因', () async {
    await bus.start();
    await bus.watchdog();
    await ws.until(
      (Map<String, dynamic> f) =>
          f['type'] == WsOutboundType.pluginStatus &&
          ((f['data'] as Map<String, dynamic>)['plugin_id'] == 'deaf') &&
          ((f['data'] as Map<String, dynamic>)['status'] == 'disabled'),
      reason: 'plugin_status(disabled)',
    );
    final Map<String, dynamic> data =
        ws.frames.firstWhere(
              (Map<String, dynamic> f) =>
                  f['type'] == WsOutboundType.pluginStatus &&
                  ((f['data'] as Map<String, dynamic>)['plugin_id'] ==
                      'deaf') &&
                  ((f['data'] as Map<String, dynamic>)['status'] == 'disabled'),
            )['data']
            as Map<String, dynamic>;
    expect(data['reason'], contains('心跳失败'));
    expect(bus.errorOf('deaf'), contains('心跳失败'));
    // 另一个插件不受影响
    expect(bus.errorOf('sample'), isNull);
  });
}
