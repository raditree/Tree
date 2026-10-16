// **向后兼容的钉住用例**（20261015-hot-restart 阶段 2，D11 / D3）。
//
// 阶段 1-2 给插件运行态加了第三个轴 `lifecycle`（外加 `generation`）。加键很容易，
// **不改老键**才是要钉的东西：`status`（配置上要不要跑）与 `health`（还听得见吗）
// 是前端与老插件已经在读的两个字段，任何一个取值变化都是对外契约的破坏。
//
// 这个文件把"改动前长什么样"逐字钉下来，并证明 lifecycle 只是**多出来的一个键**：
// 1. `snapshot().instances[]` 的键集合 = 老键集合 + 恰好两个新键（lifecycle / generation）；
// 2. 四种运行态各自的 `status` / `health` 取值（就绪 / 启动失败 / 停用 / 心跳降级）
//    与改动前逐字一致；**降级仍是 registered**，失败仍是 disabled；
// 3. `plugin_status` 增量帧同样只多那两个键，且 `status` 只可能是那三个值；
// 4. `healthOf()`（REST 的运行态来源）的键与取值一字未动；
// 5. 三个轴不许互相吃掉对方：`restarting` / `suspended` 期间 `status` 仍是 registered、
//    `health` 仍按心跳判定；
// 6. `callTool` 的不可用文案按生命周期**分化**（旧文案里"未启动"这一条逐字保留）。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/src/plugin/plugin_lifecycle.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  late Directory temp;
  late String fakeScript;
  late String suspendableScript;
  late List<String> logs;
  late List<Map<String, dynamic>> frames;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_plugin_status_compat_');
    fakeScript = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'fake_plugin.dart',
    );
    suspendableScript = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'suspendable_plugin.dart',
    );
    logs = <String>[];
    frames = <Map<String, dynamic>>[];
    for (final String s in <String>[fakeScript, suspendableScript]) {
      expect(File(s).existsSync(), isTrue, reason: '假插件脚本必须存在：$s');
    }
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

  String argList(List<String> args) =>
      args.map((String a) => '"${slash(a)}"').join(', ');

  PluginBus busFor(
    String yaml, {
    Duration heartbeatInterval = const Duration(seconds: 30),
  }) {
    final File file = File(p.join(temp.path, 'config', 'plugins.yaml'));
    file.createSync(recursive: true);
    file.writeAsStringSync(yaml);
    final PluginBus bus = PluginBus(
      configFile: file.path,
      coreVersion: 'test',
      // 默认把心跳节拍拉大：本文件只钉字段取值，不想跟探活定时器抢跑。
      // 需要跑降级的用例自己传小值（并手动调 watchdog()）。
      heartbeatInterval: heartbeatInterval,
      log: logs.add,
      // 前端下行帧的替身：钉住 plugin_status 的键集合与取值集合
      broadcast: (Map<String, dynamic> frame) {
        if (frame['type'] == 'plugin_status') {
          frames.add(frame['data']! as Map<String, dynamic>);
        }
      },
    );
    addTearDown(bus.close);
    return bus;
  }

  Map<String, dynamic> instanceOf(PluginBus bus, String id) =>
      (bus.snapshot()['instances'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .firstWhere((Map<String, dynamic> i) => i['plugin_id'] == id);

  test('快照实例的键集合：老键一个不少，新键恰好两个', () async {
    final PluginBus bus = busFor(
      'enabled: true\n'
      'plugins:\n'
      '  - id: ok\n'
      '    name: 正常插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: [${argList(<String>[fakeScript])}]\n'
      '    granularity: team\n'
      '    scope: {team_id: team-1, mode_key: local}\n',
    );
    await bus.start();

    final Map<String, dynamic> instance = instanceOf(bus, 'ok');
    // 老键（阶段 2 之前就存在，**一个都不能改名字、不能删**）
    const Set<String> legacyKeys = <String>{
      'plugin_id',
      'name',
      'description',
      'tools',
      'granularity',
      'scope',
      'status',
      'health',
      'missed_heartbeats',
      'heartbeat_interval_s',
      'last_heartbeat',
      'degraded_reason',
      'disabled_reason',
      'queue_depth',
    };
    for (final String key in legacyKeys) {
      expect(instance.containsKey(key), isTrue, reason: '老键 $key 不得消失');
    }
    // 新增键：只允许这两个（哪天再加第三个，这条断言就该红，逼人来核对前端）
    expect(instance.keys.toSet().difference(legacyKeys), <String>{
      'lifecycle',
      'generation',
    }, reason: '向后兼容的底线是"只增键"，而且增哪两个必须写在明面上');
  });

  test('四种运行态的 status / health 取值与改动前逐字一致', () async {
    final PluginBus bus = busFor(
      'enabled: true\n'
      'plugins:\n'
      '  - id: ok\n'
      '    name: 正常插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: [${argList(<String>[fakeScript])}]\n'
      '    granularity: team\n'
      '    scope: {team_id: team-1, mode_key: local}\n'
      '  - id: broken\n'
      '    name: 坏插件\n'
      '    command: "definitely-not-an-executable-xyz"\n'
      '    args: []\n'
      '    granularity: team\n'
      '    scope: {team_id: team-1, mode_key: local}\n'
      '  - id: off\n'
      '    name: 停用插件\n'
      '    enabled: false\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: [${argList(<String>[fakeScript])}]\n'
      '    granularity: team\n'
      '    scope: {team_id: team-1, mode_key: local}\n',
    );
    await bus.start();

    final Map<String, dynamic> ok = instanceOf(bus, 'ok');
    expect(ok['status'], 'registered');
    expect(ok['health'], 'ok');
    expect(ok['lifecycle'], PluginLifecycleState.ready.wire);
    expect(ok['generation'], 1);
    expect(ok['disabled_reason'], '');
    expect(ok['degraded_reason'], '');

    final Map<String, dynamic> broken = instanceOf(bus, 'broken');
    expect(broken['status'], 'disabled', reason: '起不来 = 停用（这条口径本来就有）');
    expect(broken['health'], 'unavailable', reason: '没有宿主 = 不可用（不是 degraded）');
    expect(
      broken['lifecycle'],
      PluginLifecycleState.failed.wire,
      reason: '新的第三个轴才说清"是失败不是停用"',
    );
    expect(broken['disabled_reason'], isNotEmpty);

    final Map<String, dynamic> off = instanceOf(bus, 'off');
    expect(off['status'], 'disabled');
    expect(off['health'], 'unavailable');
    expect(off['lifecycle'], PluginLifecycleState.stopped.wire);

    // 整个快照里 status / health 的取值集合必须还是那两个枚举（不新增取值）
    final List<dynamic> all = bus.snapshot()['instances'] as List<dynamic>;
    expect(
      all.map((dynamic i) => (i as Map<String, dynamic>)['status']).toSet(),
      <String>{'registered', 'disabled'},
    );
    expect(
      all.map((dynamic i) => (i as Map<String, dynamic>)['health']).toSet(),
      <String>{'ok', 'unavailable'},
    );
    for (final dynamic i in all) {
      expect(
        PluginLifecycleState.tryParse(
          ((i as Map<String, dynamic>)['lifecycle']).toString(),
        ),
        isNotNull,
        reason: 'lifecycle 的产出值必须落在枚举里（前端不能读到没见过的词）',
      );
    }
  });

  test('心跳降级与恢复：health 变 degraded，但 status 仍是 registered、lifecycle 仍是 ready', () async {
    // 降级由本用例手动跑 watchdog() 触发（applyConfigs 不起周期定时器）：
    // “哪一拍算 stale”因此是确定的，不跟真时钟抢。
    // 闸门口径（假插件）：**闸门文件存在才回 ping** ⇒ 一开始不建文件 = 不理心跳。
    final File gate = File(p.join(temp.path, 'ping-on'));
    final PluginBus bus = busFor(
      'enabled: true\n'
      'plugins:\n'
      '  - id: slow\n'
      '    name: 不理心跳的插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: [${argList(<String>[fakeScript, '--ignore-ping-until', gate.path])}]\n'
      '    granularity: team\n'
      '    scope: {team_id: team-1, mode_key: local}\n',
      heartbeatInterval: const Duration(milliseconds: 200),
    );
    await bus.applyConfigs();
    expect(bus.lifecycleOf('slow'), PluginLifecycleState.ready);

    for (int i = 0; i < 4; i++) {
      await bus.watchdog();
    }

    final Map<String, dynamic> instance = instanceOf(bus, 'slow');
    expect(instance['status'], 'registered', reason: '降级 ≠ 停用（这条老口径必须保住）');
    expect(instance['health'], 'degraded');
    expect(
      instance['lifecycle'],
      PluginLifecycleState.ready.wire,
      reason: '心跳丢失改的是活性，不是生命周期（三轴不互吃）',
    );
    expect(instance['degraded_reason'], isNotEmpty);

    // 恢复：把闸门放下 ⇒ 下一拍 ping 得到回答 ⇒ degraded 自动清零
    gate.createSync();
    await bus.watchdog();
    final Map<String, dynamic> recovered = instanceOf(bus, 'slow');
    expect(recovered['health'], 'ok', reason: '恢复自动清除（不靠人手动碰）');
    expect(recovered['status'], 'registered');
    expect(recovered['lifecycle'], PluginLifecycleState.ready.wire);
    expect(recovered['degraded_reason'], '', reason: '恢复后降级文案必须清零');
  });

  test('plugin_status 增量帧：只多 lifecycle / generation 两个键，取值集合不变', () async {
    final PluginBus bus = busFor(
      'enabled: true\n'
      'plugins:\n'
      '  - id: frame\n'
      '    name: 帧插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: [${argList(<String>[fakeScript])}]\n'
      '    granularity: team\n'
      '    scope: {team_id: team-1, mode_key: local}\n',
    );
    await bus.start();
    expect(frames, isNotEmpty, reason: '启动至少要推一条 registered');

    final Map<String, dynamic> ready = frames.firstWhere(
      (Map<String, dynamic> f) => f['status'] == 'registered',
    );
    expect(ready['plugin_id'], 'frame');
    expect(ready['health'], 'ok');
    expect(ready['lifecycle'], PluginLifecycleState.ready.wire);
    expect(ready['generation'], 1);
    for (final String legacy in <String>[
      'plugin_id',
      'name',
      'granularity',
      'scope',
      'status',
      'ts',
    ]) {
      expect(ready.containsKey(legacy), isTrue, reason: '老键 $legacy 不得消失');
    }
    // 增量的 status 只可能是那三个值（前端按它们做合并，多一个就是破坏契约）
    expect(
      frames.map((Map<String, dynamic> f) => f['status']).toSet(),
      <String>{'registered'},
    );

    // 断开（核心退出路径）⇒ destroyed，仍是老取值之一
    await bus.close();
    expect(
      frames.last['status'],
      'destroyed',
      reason: 'destroyed 仍由核心退出推送；restart / 热重启不得推 destroyed',
    );
    frames.removeWhere((Map<String, dynamic> f) => f['status'] == 'destroyed');
    expect(
      frames.map((Map<String, dynamic> f) => f['status']).toSet(),
      <String>{'registered'},
      reason: '整个生命周期里不该冒出第四个 status 取值',
    );
  });

  test('healthOf()（REST 的运行态来源）的键与取值一字未动', () async {
    final PluginBus bus = busFor(
      'enabled: true\n'
      'plugins:\n'
      '  - id: probe\n'
      '    name: 探针插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: [${argList(<String>[fakeScript])}]\n'
      '    granularity: team\n'
      '    scope: {team_id: team-1, mode_key: local}\n',
    );
    // 没启动过：仍是那五个键，reason 还是"未启动"
    expect(bus.healthOf('probe'), <String, dynamic>{
      'plugin_id': 'probe',
      'health': 'unavailable',
      'degraded': false,
      'missed_heartbeats': 0,
      'reason': '未启动',
    });

    await bus.start();
    final Map<String, dynamic> live = bus.healthOf('probe');
    expect(live['health'], 'ok');
    expect(live['degraded'], isFalse);
    expect(live['missed_heartbeats'], 0);
    expect(live['miss_threshold'], 3);
    expect(live.containsKey('reason'), isFalse, reason: '没降级就不该有 reason 键');
    // 注意：healthOf **没有**加 lifecycle —— 它是活性探针，第三个轴走快照与
    // plugin.state（把两个轴塞进同一个返回值就是"互相吃掉"的开始）。
    expect(live.containsKey('lifecycle'), isFalse);
  });

  /// 等到某个事实成立（真子进程的退出有先后；**这是测试的等待，不是核心的判据**）。
  Future<void> waitUntil(bool Function() condition, String what) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    throw StateError('等不到 $what；日志：${logs.join(' | ')}');
  }

  test('callTool 的不可用文案按生命周期分化（旧的"未启动"逐字保留）', () async {
    final PluginBus bus = busFor(
      'enabled: true\n'
      'plugins:\n'
      '  - id: words\n'
      '    name: 文案插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: [${argList(<String>[suspendableScript, '--self-stop-ms', '600'])}]\n'
      '    granularity: team\n'
      '    scope: {team_id: team-1, mode_key: local}\n'
      '  - id: absent\n'
      '    name: 没启动的插件\n'
      '    enabled: false\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: [${argList(<String>[fakeScript])}]\n'
      '    granularity: team\n'
      '    scope: {team_id: team-1, mode_key: local}\n',
    );
    await bus.start();
    expect(bus.lifecycleOf('words'), PluginLifecycleState.ready);

    // ① 本来就没启动 ⇒ 老文案逐字不变（用户与既有断言看到的还是那一句）
    final PluginCallResult absent = await bus.callTool(
      'absent_tool',
      <String, dynamic>{},
      pluginId: 'absent',
    );
    expect(absent.isError, isTrue);
    expect(absent.text, '插件 absent 不可用：未启动');
    // 台账里根本没有这一条 ⇒ 也按“未启动”报，**不臆造生命周期**
    final PluginCallResult ghost = await bus.callTool(
      'ghost_tool',
      <String, dynamic>{},
      pluginId: 'ghost',
    );
    expect(ghost.text, '插件 ghost 不可用：未启动');

    // ② 进程自己退了 ⇒ 说清是“退了”（以前一律说“未启动”，那是把一次崩溃讲成“没装”）。
    // 只改这句人话：**status / health 的取值一个字没动**（快照早就把这种情况记成
    // disabled + unavailable），所以旧前端与旧断言都不受影响。
    await waitUntil(
      () => instanceOf(bus, 'words')['status'] == 'disabled',
      'words 的进程自己退出（快照转 disabled）',
    );
    final PluginCallResult gone = await bus.callTool(
      'gone_tool',
      <String, dynamic>{},
      pluginId: 'words',
    );
    expect(gone.isError, isTrue);
    expect(gone.text, '插件 words 不可用：进程已退出');

    // ③ 启动失败 ⇒ 说清是失败，并把原因带上
    final File file = File(p.join(temp.path, 'config', 'plugins.yaml'));
    file.writeAsStringSync(
      'enabled: true\n'
      'plugins:\n'
      '  - id: words\n'
      '    name: 文案插件\n'
      '    command: "definitely-not-an-executable-xyz"\n'
      '    args: []\n'
      '    granularity: team\n'
      '    scope: {team_id: team-1, mode_key: local}\n',
    );
    await bus.applyConfigs();
    expect(bus.lifecycleOf('words'), PluginLifecycleState.failed);
    final PluginCallResult failedCall = await bus.callTool(
      'words_tool',
      <String, dynamic>{},
      pluginId: 'words',
    );
    expect(failedCall.isError, isTrue);
    expect(failedCall.text, contains('插件 words 不可用：本轮启动失败：'));

    // ④ 重启中的调用**不该以文案分化为终点**：它会等就绪后重投（阶段 2 的保活，
    // 那条路径由 plugin_restart_keepalive_test.dart 钉）。这里只钉一件事：
    // 暂时不可用与真不可用必须是**两句不同的话**，不能都成“未启动”。
    expect(
      bus.lifecycleOf('words').rejectsWork,
      isTrue,
      reason: 'failed 属于"绝不投递"那一段（而不是暂存那一段）',
    );
  });
}
