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
      heartbeatInterval: const Duration(milliseconds: 50),
      missThreshold: 3,
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
    //
    // **轮询而不是睡固定时长**：这里等的是另一个进程的落盘，并行满负载（16 路
    // 同时跑用例、还要起子进程）时 200ms 是睡出来的假期限，实测会假失败。
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (File(eventsFile).existsSync() &&
          File(eventsFile).readAsStringSync().contains('task')) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    expect(File(eventsFile).readAsStringSync(), contains('task'));
  });
  test('心跳丢失 → plugin_status(health: degraded) 且插件不被终止', () async {
    await bus.start();
    bus.pauseHeartbeat(); // 手动控制每一拍（定时器会叠加丢失计数）
    // I=50ms / N=3：三拍未达即 degraded（只标健康度，不杀进程）。
    //
    // 但**单拍窗口就是 I=50ms**：并行满负载时活着的子进程也可能来不及在这一拍里
    // 回 pong（那是"这一拍没心跳"的正常语义，恢复后会自动清除，见 PluginBus 的
    // 恢复分支）。所以这里**轮询到 deaf 掉线**，再确认 sample 仍然/重新 ok——
    // 断言点是"两个插件互不影响"，不是"50ms 内必须回包"。
    for (int i = 0; i < 40 && bus.healthOf('deaf')['health'] != 'degraded'; i++) {
      await bus.watchdog();
    }
    expect(bus.healthOf('deaf')['health'], 'degraded');
    expect(bus.instances(), hasLength(2), reason: '两个插件都还在跑');
    await ws.until(
      (Map<String, dynamic> f) =>
          f['type'] == WsOutboundType.pluginStatus &&
          ((f['data'] as Map<String, dynamic>)['plugin_id'] == 'deaf') &&
          ((f['data'] as Map<String, dynamic>)['health'] == 'degraded'),
      reason: 'plugin_status(degraded)',
    );
    final Map<String, dynamic> data =
        ws.frames.firstWhere(
              (Map<String, dynamic> f) =>
                  f['type'] == WsOutboundType.pluginStatus &&
                  ((f['data'] as Map<String, dynamic>)['plugin_id'] ==
                      'deaf') &&
                  ((f['data'] as Map<String, dynamic>)['health'] == 'degraded'),
            )['data']
            as Map<String, dynamic>;
    expect(data['reason'], contains('心跳丢失'));
    expect(data['status'], 'registered', reason: '插件活着，状态不是 disabled');
    // 另一个插件不受影响：真掉过一拍也会在下一拍恢复（degraded 自动清除）
    for (int i = 0; i < 40 && bus.healthOf('sample')['health'] != 'ok'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await bus.watchdog();
    }
    expect(bus.errorOf('sample'), isNull);
    expect(bus.healthOf('sample')['health'], 'ok');
  });

  test('插件进程退出 → plugin_status(disabled)（前端据此注销它的卡片/面板）', () async {
    // 只留一个"调用 slow 就退出进程"的插件（夹具的 --exit-on-slow）
    File('${temp.path}/config/plugins.yaml').writeAsStringSync(
      'enabled: true\n'
      'plugins:\n'
      '  - id: dying\n'
      '    name: 会退出的插件\n'
      '    command: "${Platform.resolvedExecutable.replaceAll('\\', '/')}"\n'
      '    args: ["${script.replaceAll('\\', '/')}", "--exit-on-slow"]\n'
      '    granularity: team\n'
      '    scope: {team_id: team-1}\n',
    );
    await bus.start();
    bus.pauseHeartbeat(); // 手动控制每一拍（定时器会叠加丢失计数）
    await ws.until(
      (Map<String, dynamic> f) =>
          f['type'] == WsOutboundType.pluginStatus &&
          ((f['data'] as Map<String, dynamic>)['plugin_id'] == 'dying') &&
          ((f['data'] as Map<String, dynamic>)['status'] == 'registered'),
      reason: 'plugin_status(registered)',
    );

    // 真让进程退出：夹具收到 slow 调用即 exit
    await bus.callTool('slow', <String, dynamic>{}, pluginId: 'dying');

    List<Map<String, dynamic>> disabledFrames() => ws.frames
        .where(
          (Map<String, dynamic> f) =>
              f['type'] == WsOutboundType.pluginStatus &&
              ((f['data'] as Map<String, dynamic>)['plugin_id'] == 'dying') &&
              ((f['data'] as Map<String, dynamic>)['status'] == 'disabled'),
        )
        .toList();

    // 心跳巡检发现"进程已退出" ⇒ 补推 disabled（快照口径本来就把 isClosed 记成 disabled）
    //
    // 预算放宽到 10s：并行满负载时"子进程真的退出 + 巡检往返"可能远超原来的
    // 40×25ms=1s（那是睡出来的假期限，不是行为契约）。这里是 polling，快就快过。
    for (int i = 0; i < 400 && disabledFrames().isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await bus.watchdog();
    }
    final List<Map<String, dynamic>> disabled = disabledFrames();
    expect(
      disabled,
      hasLength(1),
      reason: '进程退出要如实推一次 disabled：不推前端就留着孤儿卡片与面板',
    );
    expect(
      (disabled.single['data'] as Map<String, dynamic>)['reason'],
      contains('进程已退出'),
    );

    // 再跑几拍：**不重复推**（巡检每拍都跑，重复推会让前端反复注销）
    await bus.watchdog();
    await bus.watchdog();
    expect(disabledFrames(), hasLength(1));
  });
}
