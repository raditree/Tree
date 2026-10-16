// 广播站点位「插件生命周期」（`system.broadcast.plugin.state`）的钉住用例
// （20261015-hot-restart 阶段 2，D11 / 不变量 15）。
//
// 为什么"推"这件事必须有点位，而不是让前端去猜：重启窗口里插件对外仍是正常状态
// （站点请求被有界暂存后重放），于是"没回音"不再等于"挂了"。想知道"现在到哪个阶段
// 了"只能由核心把跃迁推出来。
//
// 观察方式：在核心里挂一个**进程内订阅者**（watcher）直接收下广播载荷——这样断言的
// 就是「真的投递到了订阅者」，而不是"计数器说发过了"。
//
// 钉住的六件事：
// 1. 点位登记齐全（进 `StationHubIds.all`、类型 = 广播、有别名与 readme）；
// 2. **每个跃迁恰好一条**广播（启动 = booting + ready；不重复也不漏）；
// 3. 载荷字段齐：`plugin_id` / `lifecycle` / `previous` / `generation` /
//    `missed_heartbeats` / `reason` / `buffer`；
// 4. 热重启补三条（restarting → booting → ready），`generation` 随之 +1；
// 5. 失活标记也广播一条，带 `missed_heartbeats`，而 **lifecycle 仍是 ready**
//    ——三个轴各管各的，活性判定不许把阶段改掉（D11）；
// 6. 证明不了归属的插件（声明里没 team）⇒ **显式跳过并写下原因**，不静默；
//    没人订阅时走快路径（零开销、也不算发过）。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/src/plugin/plugin_lifecycle.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  late Directory temp;
  late String script;
  late List<String> logs;
  late List<StationRequest> received;

  const String pluginId = 'life';
  const String team = 'team-1';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_plugin_state_broadcast_');
    script = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'fake_plugin.dart',
    );
    logs = <String>[];
    received = <StationRequest>[];
    expect(File(script).existsSync(), isTrue, reason: '假插件脚本必须存在');
  });

  tearDown(() async {
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  String slash(String path) => path.replaceAll(Platform.pathSeparator, '/');

  String yaml({
    String id = pluginId,
    String extraArgs = '',
    String scope = '{team_id: $team, mode_key: local}',
  }) =>
      'enabled: true\n'
      'plugins:\n'
      '  - id: $id\n'
      '    name: 生命周期插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: ["${slash(script)}"$extraArgs]\n'
      '    granularity: team\n'
      '    scope: $scope\n';

  /// 起一条总线，并在广播点位上挂好进程内订阅者（**先订阅再启动**，一条跃迁都不漏）。
  Future<PluginBus> startBus(
    String configYaml, {
    Duration heartbeatInterval = const Duration(seconds: 30),
    int missThreshold = 3,
  }) async {
    final File file = File(p.join(temp.path, 'config', 'plugins.yaml'));
    file.createSync(recursive: true);
    file.writeAsStringSync(configYaml);
    final PluginBus bus = PluginBus(
      configFile: file.path,
      coreVersion: 'test',
      heartbeatInterval: heartbeatInterval,
      missThreshold: missThreshold,
      log: logs.add,
    );
    addTearDown(bus.close);
    bus.stations.ensureBuiltinStations();
    final StationSubResult sub = bus.stations.subscribe(
      StationHubIds.broadcastPluginState,
      StationSubscriber(
        pluginId: 'watcher',
        // 通配订阅（team 留空 = 不设条件）：哪个 team 的插件跃迁都要收
        scope: const StationScope(),
        subscribedAt: 1,
      ),
      (StationRequest request) async {
        received.add(request);
        return StationReply.ok(<String, dynamic>{'acked': true});
      },
    );
    expect(sub.ok, isTrue, reason: '订阅观察者点位必须成功：${sub.error}');
    await bus.start();
    return bus;
  }

  List<String> transitions() => received
      .map((StationRequest r) {
        final Map<String, dynamic> body = r.payload! as Map<String, dynamic>;
        return '${body['previous']}→${body['lifecycle']}';
      })
      .toList(growable: false);

  Map<String, dynamic> payloadOf(StationRequest r) =>
      r.payload! as Map<String, dynamic>;

  test('点位登记齐全（常量、类型、别名、介绍缺一不可）', () {
    expect(
      StationHubIds.all,
      contains(StationHubIds.broadcastPluginState),
      reason: '漏进 all ⇒ 插件订阅会被当成别人的自建站拒掉（静默失效）',
    );
    final StationPointSpec? spec = StationPoints.byId(
      StationHubIds.broadcastPluginState,
    );
    expect(spec, isNotNull, reason: '常量与点位表必须成对出现');
    expect(spec!.kind, StationKind.broadcast);
    expect(spec.alias, 'plugin.state');
    expect(spec.label, '插件生命周期');
    expect(
      spec.readme,
      contains('活性看 `health`、启停看 `status`、阶段看 `lifecycle`'),
      reason: 'readme 必须把三轴纪律写给插件作者（这是本点位最容易混的地方）',
    );
    expect(StationPoints.ofKind(StationKind.broadcast), hasLength(5));
  });

  test('启动 = booting + ready 各一条广播，载荷字段齐全', () async {
    final PluginBus bus = await startBus(yaml());
    expect(transitions(), <String>[
      'stopped→booting',
      'booting→ready',
    ], reason: '每个跃迁恰好一条；日志：${logs.join(' | ')}');
    final Map<String, dynamic> ready = payloadOf(received.last);
    expect(ready['point'], StationHubIds.broadcastPluginState);
    expect(ready['plugin_id'], pluginId);
    expect(ready['lifecycle'], PluginLifecycleState.ready.wire);
    expect(ready['previous'], PluginLifecycleState.booting.wire);
    expect(ready['generation'], 1);
    expect(ready.containsKey('missed_heartbeats'), isTrue);
    expect(ready['buffer'], isA<Map<String, dynamic>>());
    expect((ready['buffer']! as Map<String, dynamic>)['queued'], 0);
    expect(received.last.stationId, StationHubIds.broadcastPluginState);
    expect(bus.pluginStateBroadcasts, 2);
  });

  test('热重启补三条跃迁，且 generation 随之 +1（一世一条不落）', () async {
    final PluginBus bus = await startBus(yaml());
    received.clear();

    final PluginHotRestartResult result = await bus.hotRestart(pluginId);
    expect(result.ok, isTrue, reason: result.reason);
    expect(transitions(), <String>[
      'ready→restarting',
      'restarting→booting',
      'booting→ready',
    ], reason: '重启窗口的三段都要推出去（前端据此显示「重启中」）；日志：${logs.join(' | ')}');
    expect(
      payloadOf(received.first)['generation'],
      1,
      reason: '进入 restarting 时还是上一世',
    );
    expect(payloadOf(received.last)['generation'], 2, reason: '回到 ready 已是新一世');
  });

  test('失活标记也广播一条：带 missed_heartbeats，而 lifecycle 仍是 ready（三轴不互吃）', () async {
    // 假插件故意不理 ping：连续 N 拍无心跳 ⇒ degraded。判据仍是 LivenessTracker，
    // 本用例只是手动跑几拍，不等真时钟（心跳间隔压到 20ms 也没必要：手动 watchdog()）。
    final PluginBus bus = await startBus(
      yaml(extraArgs: ', "--ignore-ping"'),
      // 心跳间隔故意留大：本用例手动跑 watchdog()，不让周期定时器抢在之前把
      // degraded 跃迁走完（那个跃迁只会发生一次，抢了就测不到了）。
      heartbeatInterval: const Duration(seconds: 5),
    );
    bus.pauseHeartbeat(); // 由本用例手动驱动看门狗，断言才是确定的
    received.clear();

    for (int i = 0; i < 4; i++) {
      await bus.watchdog();
    }

    final List<Map<String, dynamic>> notices = received
        .map(payloadOf)
        .where((Map<String, dynamic> p) => (p['missed_heartbeats'] ?? 0) is int)
        .where((Map<String, dynamic> p) => (p['missed_heartbeats'] as int) > 0)
        .toList();
    expect(
      notices,
      hasLength(1),
      reason: '失活只在**跃迁**时推一条；日志：${logs.join(' | ')}',
    );
    final Map<String, dynamic> notice = notices.single;
    expect(
      notice['lifecycle'],
      PluginLifecycleState.ready.wire,
      reason: '心跳丢失改的是 health，不是生命周期（三个轴各管各的）',
    );
    expect(notice['previous'], PluginLifecycleState.ready.wire);
    expect(notice['missed_heartbeats'], greaterThanOrEqualTo(3));
    expect((notice['reason'] ?? '').toString(), isNotEmpty);
    // 快照侧同一事实：health 变了，status / lifecycle 都没跟着变
    final Map<String, dynamic> instance =
        (bus.snapshot()['instances'] as List<dynamic>).single
            as Map<String, dynamic>;
    expect(instance['health'], 'degraded');
    expect(instance['status'], 'registered');
    expect(instance['lifecycle'], PluginLifecycleState.ready.wire);
  });

  test('证明不了归属的插件：广播被显式跳过并写下原因（fail-closed，不静默）', () async {
    final PluginBus bus = await startBus(yaml(id: 'noteam', scope: '{}'));
    expect(received, isEmpty, reason: '没有 team 归属 ⇒ 一条都不推');
    expect(
      logs.any((String l) => l.contains('插件生命周期广播跳过')),
      isTrue,
      reason: '为什么没发出去必须能查到；日志：${logs.join(' | ')}',
    );
    expect(
      logs.any((String l) => l.contains('不能证明归属')),
      isTrue,
      reason: '原因要说清是 fail-closed，不是坏了',
    );
    expect(bus.pluginStateBroadcasts, 0);
  });

  test('没人订阅时走快路径：不计数、不投递、也不报错', () async {
    final File file = File(p.join(temp.path, 'config', 'plugins.yaml'));
    file.createSync(recursive: true);
    file.writeAsStringSync(yaml());
    final PluginBus bus = PluginBus(
      configFile: file.path,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
      log: logs.add,
    );
    addTearDown(bus.close);
    await bus.start();
    expect(bus.lifecycleOf(pluginId), PluginLifecycleState.ready);
    expect(bus.pluginStateBroadcasts, 0, reason: '无订阅者 ⇒ 一次都不该发');
    expect(
      bus.stations.station(StationHubIds.broadcastPluginState),
      isNotNull,
      reason: '点位仍然在（懒创建 / 预建），只是没人听',
    );
  });
}
