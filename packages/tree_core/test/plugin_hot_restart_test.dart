// 插件**热重启**主链路的钉住用例（20261015-hot-restart 阶段 1，D2/D4/D8/D3/D11）。
//
// 跑的是**真子进程 + 真执行站接线**（CoreServer 生产那条），所有结论都来自
// 插件自己写下的事件日志与核心侧的计数读数——不靠"看起来重启成功了"。
//
// 钉住的八件事（逐条对应 plan 第 2 天的验收口径）：
// 1. 热重启真的换了一世：进程启动两次、第二世的 hello 参数里带上了第一世的 `dump_id`；
// 2. 快照**真的被取回**：第二世的 `plugin.stateFetch` 拿到第一世写下的 payload；
// 3. `plugin.stateDump` 次数 = 1、字节数 > 0（转储不是空转，也没被重复收）；
// 4. 慢转储不被打断：`suspend` 后先等 400ms 才递快照，核心照样等到、照样续跑
//    （这条同时钉住"在途转储不会被 close 自己关掉"——拆两阶段的原因）；
// 5. 没声明 `suspension: keep` 的插件 ⇒ **冷重启**且原因可读（D3 默认不可挂起）；
// 6. `status` / `health` 的产出值与改动前逐字一致，`lifecycle` / `generation` 只是新增键（D11）；
// 7. **零磁盘转储**：整场跑完，数据根下除了插件自己写的事件日志，不多一个文件（D4）；
// 8. 失败隔离：一个插件的重启失败不牵连别人，且原因留在可读位置（不变量 10）。
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/src/plugin/plugin_lifecycle.dart';
import 'package:tree_core/src/plugin/plugin_state_pool.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

void main() {
  late Directory temp;
  late String workspace;
  late MemoryStore store;
  late CoreAgent agent;
  late PluginBus bus;
  late CoreServer server;
  late String script;
  late List<Map<String, dynamic>> statusFrames;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tree_hot_restart_');
    workspace = p.join(temp.path, 'ws');
    Directory(workspace).createSync(recursive: true);
    store = MemoryStore();
    agent = store.createAgent(name: '甲', modelId: 'demo');
    agent.teamId = 'team-1';
    agent.workspaceDir = workspace;
    store.putAgent(agent);
    script = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'suspendable_plugin.dart',
    );
    expect(File(script).existsSync(), isTrue, reason: '假插件脚本必须存在');
    statusFrames = <Map<String, dynamic>>[];

    final File file = File(p.join(temp.path, 'config', 'plugins.yaml'));
    file.createSync(recursive: true);
    file.writeAsStringSync('enabled: true\nplugins: []\n');
    bus = PluginBus(
      configFile: file.path,
      coreVersion: 'test',
      // 心跳节拍拉长：本文件只关心转储/取回，不要探活定时器插进来
      //（"慢退出会不会被收尸"是 plugin_close_no_hard_timeout_test.dart 的题）
      heartbeatInterval: const Duration(seconds: 30),
      // 前端下行帧的替身：只收 plugin_status 增量，用来钉 status/health 的取值集合
      broadcast: (Map<String, dynamic> frame) {
        if (frame['type'] == 'plugin_status') {
          statusFrames.add(frame['data'] as Map<String, dynamic>);
        }
      },
    );
    server = await CoreServer.start(
      store: store,
      pluginBus: bus,
      specIoFor: (String agentId) async =>
          agentId == agent.id ? LocalWorkspaceIO(workspace) : null,
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
    );
  });

  tearDown(() async {
    await server.close();
    await bus.close();
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  // ── 夹具 ───────────────────────────────────────────────────────────────

  String eventLogOf(String id) => p.join(temp.path, '$id.events.jsonl');

  List<Map<String, dynamic>> events(String id) {
    final File file = File(eventLogOf(id));
    if (!file.existsSync()) return const <Map<String, dynamic>>[];
    return <Map<String, dynamic>>[
      for (final String line in file.readAsLinesSync())
        if (line.trim().isNotEmpty)
          jsonDecode(line) as Map<String, dynamic>,
    ];
  }

  List<Map<String, dynamic>> eventsOf(String id, String kind) => events(
    id,
  ).where((Map<String, dynamic> e) => e['kind'] == kind).toList();

  /// 等到某类事件出现为止（真子进程，落盘有先后；**这是测试的等待，不是核心的判据**）。
  Future<List<Map<String, dynamic>>> waitForEvents(
    String id,
    String kind,
    int atLeast,
  ) async {
    for (int i = 0; i < 200; i++) {
      final List<Map<String, dynamic>> hit = eventsOf(id, kind);
      if (hit.length >= atLeast) return hit;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    throw StateError(
      '等 $id 的「$kind」事件等到第 200 轮仍不足 $atLeast 条；'
      '当前事件日志：${events(id)}',
    );
  }

  /// 一条插件条目（假插件 + 可选 `suspension: keep`）。
  List<String> entry(
    String id, {
    bool suspension = true,
    List<String> extraArgs = const <String>[],
    bool enabled = true,
    String? command,
  }) {
    final List<String> args = (command == null)
        ? <String>[
            script,
            '--id',
            id,
            '--event-log',
            eventLogOf(id),
            ...extraArgs,
          ]
        : const <String>[];
    final String executable = (command ?? Platform.resolvedExecutable)
        .replaceAll('\\', '/');
    return <String>[
      '  - id: $id',
      '    name: $id 插件',
      '    command: "$executable"',
      '    args: [${args.map((String a) => '"${a.replaceAll('\\', '/')}"').join(', ')}]',
      '    enabled: $enabled',
      '    granularity: team',
      if (suspension) '    suspension: keep',
      '    scope: {team_id: team-1}',
    ];
  }

  void writePlugins(List<String> entries) {
    File(bus.configFile).writeAsStringSync(
      <String>['enabled: true', 'plugins:', ...entries, ''].join('\n'),
    );
  }

  List<String> idsOf(List<PluginReconcileAction> actions) => <String>[
    for (final PluginReconcileAction action in actions) action.pluginId,
  ];

  /// 数据根下的全部文件（相对路径集合；用来证明"没多落一个文件"）。
  Set<String> filesInRoot() => <String>{
    for (final FileSystemEntity entity in temp.listSync(recursive: true))
      p.relative(entity.path, from: temp.path),
  };

  // ── 用例 ───────────────────────────────────────────────────────────────

  test('热重启：换一世、带上 dump_id、第二世真的取回第一世的快照', () async {
    writePlugins(entry('alpha'));
    await bus.start();
    expect(bus.instances(), hasLength(1));
    expect(bus.generationOf('alpha'), 1);
    // 第一世就绪后自己问过一句"有没有我的快照" ⇒ 答案必须是"没有"（冷启动）
    final List<Map<String, dynamic>> firstFetch = await waitForEvents(
      'alpha',
      'fetch',
      1,
    );
    expect(firstFetch.single['has_snapshot'], isFalse);
    expect(firstFetch.single['payload'], isNull);

    final PluginHotRestartResult result = await bus.hotRestart('alpha');

    expect(result.ok, isTrue, reason: result.reason);
    expect(result.resumed, isTrue, reason: result.reason);
    expect(result.dumpId, 'alpha#1');
    expect(result.generation, 2);
    expect(result.lifecycle, 'ready');

    // 1) 真的起了第二个进程（数启动事件，不看返回值）
    expect(eventsOf('alpha', 'start'), hasLength(2));
    // 2) 转储恰好一次，且字节数 > 0（不是空转）
    final List<Map<String, dynamic>> dumps = await waitForEvents(
      'alpha',
      'dump',
      1,
    );
    expect(dumps, hasLength(1), reason: '一份可续跑状态只递一次');
    expect(dumps.single['dump_id'], 'alpha#1');
    expect(dumps.single['bytes'], isA<int>());
    expect((dumps.single['bytes'] as int), greaterThan(0));
    // 3) 第二世的 hello 参数里带上了第一世的 dump_id
    final List<Map<String, dynamic>> hellos = await waitForEvents(
      'alpha',
      'hello',
      2,
    );
    expect(hellos[0]['resume_dump_id'], '');
    expect(hellos[1]['resume_dump_id'], 'alpha#1');
    // 4) 第二世真的取回了第一世写下的 payload
    final List<Map<String, dynamic>> fetches = await waitForEvents(
      'alpha',
      'fetch',
      2,
    );
    expect(fetches[1]['has_snapshot'], isTrue);
    final Map<String, dynamic> payload =
        fetches[1]['payload'] as Map<String, dynamic>;
    expect(payload['era_pid'], eventsOf('alpha', 'start')[0]['pid']);
    expect(payload['alive_ms'], isA<int>());
    // 两个进程确实是不同的 pid（"换了世"而不是"同一个进程装了一下"）
    expect(
      eventsOf('alpha', 'start')[0]['pid'],
      isNot(eventsOf('alpha', 'start')[1]['pid']),
    );
    // 5) 池里的快照已被消费（一份快照只喂一世）
    expect(bus.statePool.length, 0);
    expect(bus.statePool.putCount, 1);
    expect(bus.generationOf('alpha'), 2);
    expect(bus.lifecycleOf('alpha'), PluginLifecycleState.ready);
  });

  test('慢转储不被打断：suspend 后 400ms 才递快照，核心照样等到并续跑', () async {
    writePlugins(entry('alpha', extraArgs: <String>['--dump-delay-ms', '400']));
    await bus.start();
    await waitForEvents('alpha', 'fetch', 1);

    final Stopwatch elapsed = Stopwatch()..start();
    final PluginHotRestartResult result = await bus.hotRestart('alpha');
    elapsed.stop();

    // 400ms 的慢转储**必须**被等到（这条同时钉住两件事：不时长判死（D8）、
    // 在途转储不会被 close 自己误杀（拆两阶段的原因））
    expect(result.ok, isTrue, reason: result.reason);
    expect(result.resumed, isTrue, reason: '慢转储被当成没有转储 = D8 回退');
    expect(result.dumpId, 'alpha#1');
    expect(elapsed.elapsed.inMilliseconds, greaterThanOrEqualTo(380));
    expect(eventsOf('alpha', 'dump'), hasLength(1));
    final List<Map<String, dynamic>> fetches = await waitForEvents(
      'alpha',
      'fetch',
      2,
    );
    expect(fetches[1]['has_snapshot'], isTrue);
    // 没有任何进程被强杀（D8：慢不是杀人的理由）
    final Map<String, dynamic> state = await bus.handlePluginCommand(
      command: 'plugin.state',
      pluginId: 'alpha',
      sourcePluginId: '',
    );
    expect(state['kill_reason'], '');
  });

  test('没声明 suspension 的插件 ⇒ 冷重启，且降级原因是人话（D3）', () async {
    writePlugins(entry('alpha', suspension: false));
    await bus.start();
    await waitForEvents('alpha', 'fetch', 1);

    final PluginHotRestartResult result = await bus.hotRestart('alpha');

    expect(result.ok, isTrue, reason: result.reason);
    expect(result.resumed, isFalse, reason: '不可挂起的插件本来就该冷启动');
    expect(result.dumpId, isEmpty);
    expect(result.reason, contains('suspension'));
    // 冷重启**真的**换了进程（不是只在返回值上宣布重启）
    expect(eventsOf('alpha', 'start'), hasLength(2));
    // 但没有转储，也没有取到东西
    expect(eventsOf('alpha', 'dump'), isEmpty);
    final List<Map<String, dynamic>> fetches = await waitForEvents(
      'alpha',
      'fetch',
      2,
    );
    expect(fetches[1]['has_snapshot'], isFalse);
    expect(bus.statePool.putCount, 0);
  });

  test('快照只在内存里：整场跑完，数据根下不多一个文件（D4 零落盘）', () async {
    writePlugins(entry('alpha'));
    await bus.start();
    await waitForEvents('alpha', 'fetch', 1);
    // 起点：config/plugins.yaml + config/stations.yaml + 假插件自己的事件日志
    final Set<String> before = filesInRoot();

    await bus.hotRestart('alpha');
    await waitForEvents('alpha', 'fetch', 2);
    await bus.handlePluginCommand(
      command: 'plugin.state',
      pluginId: 'alpha',
      sourcePluginId: '',
    );

    expect(
      filesInRoot().difference(before),
      isEmpty,
      reason: '热重启全程不得在数据根下多落一个文件（D4：转储只进核心进程内存）',
    );
    // 快照此刻已被第二世取走 ⇒ 内存池里也不该留档
    expect(bus.statePool.length, 0);
  });

  test('只增键不破值：status / health 的取值与升级前逐字一致（D11/D3）', () async {
    writePlugins(entry('alpha'));
    await bus.start();
    await waitForEvents('alpha', 'fetch', 1);

    final Map<String, dynamic> running =
        (bus.snapshot()['instances'] as List<dynamic>).single
            as Map<String, dynamic>;
    expect(running['status'], 'registered', reason: '这个词的取值集合不许改');
    expect(running['health'], 'ok', reason: '这个词的取值集合不许改');
    // 新增的可选读数
    expect(running['lifecycle'], 'ready');
    expect(running['generation'], 1);

    statusFrames.clear();
    await bus.hotRestart('alpha');
    await waitForEvents('alpha', 'fetch', 2);

    // 增量帧里的 status / health 仍然只会是既有那几个词
    expect(statusFrames, isNotEmpty);
    for (final Map<String, dynamic> data in statusFrames) {
      expect(
        <String>['registered', 'disabled', 'destroyed'],
        contains(data['status']),
        reason: '$data',
      );
      if (data.containsKey('health')) {
        expect(
          <String>['ok', 'degraded', 'unavailable'],
          contains(data['health']),
          reason: '$data',
        );
      }
      expect(data.containsKey('lifecycle'), isTrue, reason: '$data');
    }
    final Map<String, dynamic> last = statusFrames.last;
    expect(last['status'], 'registered');
    expect(last['lifecycle'], 'ready');
    expect(last['generation'], 2);
  });

  test('失败隔离：一个插件重启失败不牵连别人，原因留在可读位置（不变量 10）', () async {
    writePlugins(<List<String>>[entry('alpha'), entry('beta')].expand(
      (List<String> e) => e,
    ).toList());
    await bus.start();
    await waitForEvents('alpha', 'fetch', 1);
    await waitForEvents('beta', 'fetch', 1);
    expect(bus.lifecycleOf('beta'), PluginLifecycleState.ready);

    // 只把 alpha 的启动命令换成不存在的东西：对账要把它弄成 failed，
    // 而 beta 必须照常就绪（启动参数没变 ⇒ 一个字节都不动）
    writePlugins(<List<String>>[
      entry('alpha', command: 'definitely-not-a-real-command-xyz'),
      entry('beta'),
    ].expand((List<String> e) => e).toList());

    final PluginReconcileResult report = await bus.applyConfigs();

    expect(idsOf(report.failed), <String>['alpha'], reason: report.error);
    expect(bus.lifecycleOf('alpha'), PluginLifecycleState.failed);
    expect(bus.lifecycleOf('beta'), PluginLifecycleState.ready);
    expect(idsOf(report.unchanged), contains('beta'));
    // 失败原因可读（不是"看起来失败了"）
    expect(
      (bus.snapshot()['instances'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .firstWhere((Map<String, dynamic> i) => i['plugin_id'] == 'alpha')
          ['disabled_reason'],
      isNotEmpty,
    );
  });

  test('hotRestart 对没在跑的插件 = 直接冷启动，并说清"无得可转储"', () async {
    writePlugins(entry('alpha'));
    final PluginHotRestartResult result = await bus.hotRestart('alpha');
    expect(result.ok, isTrue, reason: result.reason);
    expect(result.resumed, isFalse);
    expect(result.reason, contains('本来不在跑'));
    expect(bus.generationOf('alpha'), 1);
  });

  test('未知插件 id ⇒ 显式拒绝并给原因（不静默成功）', () async {
    final PluginHotRestartResult result = await bus.hotRestart('nope');
    expect(result.ok, isFalse);
    expect(result.reason, contains('没有插件条目'));
  });

  test('一份快照只喂一世：第二次 stateFetch 拿到 has_snapshot=false 且给原因', () async {
    writePlugins(entry('alpha'));
    await bus.start();
    await waitForEvents('alpha', 'fetch', 1);
    await bus.hotRestart('alpha');
    // 第二世已经把 alpha#1 取走并消费了
    await waitForEvents('alpha', 'fetch', 2);

    final Map<String, dynamic> again = await bus.handlePluginCommand(
      command: 'plugin.stateFetch',
      pluginId: 'alpha',
      sourcePluginId: 'alpha',
    );
    expect(again['ok'], isTrue);
    expect(again['has_snapshot'], isFalse, reason: '一份快照只喂一世');
    expect(again['reason'], contains('冷启动'));
  });

  test('转储载荷落进内存池：put 收一次、水位读数只有内存字段', () async {
    writePlugins(entry('alpha'));
    await bus.start();
    await waitForEvents('alpha', 'fetch', 1);
    final PluginHotRestartResult result = await bus.hotRestart('alpha');
    expect(result.resumed, isTrue, reason: result.reason);

    // 池里的读数是**内存字段**（dump_id / 字节 / 年龄 / 消费位），没有路径、没有文件句柄
    final List<PluginStateReading> readings = bus.statePool.readings();
    expect(readings, hasLength(1));
    expect(readings.single.dumpId, 'alpha#1');
    expect(readings.single.consumed, isTrue, reason: '已被第二世取走');
    expect(readings.single.pluginId, 'alpha');
    expect(readings.single.generation, 1);
  });

  test('JSON 序列化：热重启结果与池读数都能原样端给前端（键名是契约）', () async {
    writePlugins(entry('alpha'));
    await bus.start();
    await waitForEvents('alpha', 'fetch', 1);
    final PluginHotRestartResult result = await bus.hotRestart('alpha');

    expect(jsonDecode(jsonEncode(result.toJson())), <String, dynamic>{
      'ok': true,
      'plugin_id': 'alpha',
      'resumed': true,
      'dump_id': 'alpha#1',
      'generation': 2,
      'lifecycle': 'ready',
      'reason': result.reason,
    });
    expect(jsonEncode(result.toJson()), contains('热重启'));
  });
}
