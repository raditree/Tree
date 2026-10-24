import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 片 D：`runtime: ui` 走 [UiHost]（进程直连核心），`headless` 走原 stdio 宿主。
///
/// 这里钉住结构性差异：UI 不进 stdio 实例池 / 不注册工具 / 不实现 `tools/list`
/// 也能上线；UI 崩溃 = failed、正常停止 = stopped；全部停用后核心仍健康。
void main() {
  late Directory root;
  late String dartBin;
  late String probe;
  late String fakePlugin;

  setUpAll(() {
    dartBin = Platform.resolvedExecutable.replaceAll('\\', '/');
    probe = p
        .join(Directory.current.path, 'test', 'fixtures', 'ui_probe.dart')
        .replaceAll('\\', '/');
    fakePlugin = p
        .join(Directory.current.path, 'test', 'fixtures', 'fake_plugin.dart')
        .replaceAll('\\', '/');
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tree_ui_bus_');
  });

  tearDown(() async {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> waitFor(
    bool Function() predicate, {
    Duration timeout = const Duration(seconds: 10),
    String reason = '等待条件超时',
  }) async {
    final Stopwatch watch = Stopwatch()..start();
    while (!predicate()) {
      if (watch.elapsed > timeout) {
        fail('$reason（已等 ${watch.elapsed.inMilliseconds}ms）');
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  String uiEntry(String id, {String mode = 'hold', bool enabled = true}) =>
      '''
  - id: $id
    name: $id
    command: "$dartBin"
    args: ["$probe", "$mode"]
    runtime: ui
    enabled: $enabled''';

  ({PluginBus bus, File config, List<String> logs}) createBus({
    Duration uiHelloWindow = const Duration(milliseconds: 200),
  }) {
    final File config = File(p.join(root.path, 'plugins.yaml'));
    final List<String> logs = <String>[];
    final PluginBus bus = PluginBus(
      configFile: config.path,
      uiHelloWindow: uiHelloWindow,
      heartbeatInterval: const Duration(seconds: 30),
      log: logs.add,
    );
    // UI 插件必须知道连哪儿；生产由 CoreServer.start 注入。
    bus.bindCoreEndpoint(
      url: 'ws://127.0.0.1:12345',
      token: 'ui-test-token',
    );
    return (bus: bus, config: config, logs: logs);
  }

  Future<({PluginBus bus, File config, List<String> logs})> startBus(
    String yaml,
  ) async {
    final ({PluginBus bus, File config, List<String> logs}) ctx = createBus();
    ctx.config.writeAsStringSync(yaml);
    await ctx.bus.start();
    addTearDown(ctx.bus.close);
    return ctx;
  }

  Map<String, Map<String, dynamic>> snapshotInstances(PluginBus bus) =>
      <String, Map<String, dynamic>>{
        for (final Object? raw
            in bus.snapshot()['instances'] as List<dynamic>)
          (raw as Map<String, dynamic>)['plugin_id'] as String:
              raw.cast<String, dynamic>(),
      };

  test('UI 插件走 UiHost：不进 stdio 实例池、不注册工具、快照标明 runtime', () async {
    final ({PluginBus bus, File config, List<String> logs}) ctx = await startBus(
      'enabled: true\nplugins:\n${uiEntry('ui.one')}\n',
    );
    final PluginBus bus = ctx.bus;
    await waitFor(
      () => bus.healthOf('ui.one')['process_alive'] == true,
      reason: 'UI 进程应被拉起',
    );

    expect(
      bus.instances(),
      isEmpty,
      reason: 'UI 宿主不进 stdio 实例池（看门狗不该拿它做心跳判定）',
    );
    expect(bus.toolsOf('ui.one'), isEmpty, reason: 'UI 插件不注册工具');
    expect(bus.allTools(), isEmpty);

    final Map<String, dynamic> instance = snapshotInstances(bus)['ui.one']!;
    expect(instance['status'], 'registered');
    expect(instance['runtime'], 'ui');
    expect(instance['runtime_legacy'], isFalse);
    expect(instance['process_alive'], isTrue);
    expect(instance['pid'], isA<int>());
    expect(instance['ui_hello_seen'], isFalse);
  });

  test('ui.hello 连接窗口：超时只降级不杀进程；noteUiHello 后自动恢复', () async {
    final ({PluginBus bus, File config, List<String> logs}) ctx = await startBus(
      'enabled: true\nplugins:\n${uiEntry('ui.one')}\n',
    );
    final PluginBus bus = ctx.bus;
    final List<String> logs = ctx.logs;
    await waitFor(
      () => bus.healthOf('ui.one')['process_alive'] == true,
      reason: 'UI 进程应被拉起',
    );

    await waitFor(
      () => bus.healthOf('ui.one')['health'] == 'degraded',
      reason: '窗口内没有 ui.hello ⇒ degraded',
    );
    final Map<String, dynamic> degraded = bus.healthOf('ui.one');
    expect(degraded['process_alive'], isTrue, reason: '不杀进程');
    expect(degraded['reason'], contains('ui.hello'));
    expect(
      logs.any((String line) => line.contains('ui.hello')),
      isTrue,
      reason: '降级原因要可读、可查',
    );

    bus.noteUiHello('ui.one');
    final Map<String, dynamic> recovered = bus.healthOf('ui.one');
    expect(recovered['health'], 'ok');
    expect(recovered['ui_hello_seen'], isTrue);
    expect(recovered['process_alive'], isTrue);
  });

  test('多 UI 并存：停用其一不影响另一个；全部停用后核心仍健康', () async {
    final ({PluginBus bus, File config, List<String> logs}) ctx = await startBus(
      'enabled: true\nplugins:\n'
      '${uiEntry('ui.one')}\n${uiEntry('ui.two')}\n',
    );
    final PluginBus bus = ctx.bus;
    final File config = ctx.config;
    await waitFor(
      () =>
          bus.healthOf('ui.one')['process_alive'] == true &&
          bus.healthOf('ui.two')['process_alive'] == true,
      reason: '两个 UI 插件都应并存',
    );

    // 卸载 ui.one（条目从清单里整个消失）：另一个 UI 插件照常运行。
    config.writeAsStringSync(
      'enabled: true\nplugins:\n${uiEntry('ui.two')}\n',
    );
    await bus.applyConfigs();
    await waitFor(
      () => bus.lifecycleOf('ui.one').wire == 'stopped',
      reason: '卸载的 UI 插件应断开',
    );
    expect(snapshotInstances(bus).containsKey('ui.one'), isFalse);
    expect(bus.healthOf('ui.one')['process_alive'], isNot(true));
    await waitFor(
      () => bus.healthOf('ui.two')['process_alive'] == true,
      reason: '另一个 UI 插件不受影响',
    );
    expect(bus.healthOf('ui.two')['health'], isNot('unavailable'));

    // 全部停用：没有实例，但核心照常给快照（不是“挂了”）。
    config.writeAsStringSync(
      'enabled: true\nplugins:\n'
      '${uiEntry('ui.one', enabled: false)}\n'
      '${uiEntry('ui.two', enabled: false)}\n',
    );
    await bus.applyConfigs();
    await waitFor(
      () => bus.instances().isEmpty && bus.snapshot()['enabled'] == true,
      reason: '全部停用后仍应能取快照',
    );
    final Map<String, Map<String, dynamic>> instances = snapshotInstances(bus);
    expect(instances, hasLength(2), reason: '条目仍保留在清单里');
    expect(
      instances.values.map((Map<String, dynamic> i) => i['status']),
      everyElement('disabled'),
    );
    expect(
      instances.values.map((Map<String, dynamic> i) => i['process_alive']),
      everyElement(isNot(true)),
    );
  });

  test('UI 崩溃 ⇒ failed；用户显式强停 ⇒ stopped', () async {
    final ({PluginBus bus, File config, List<String> logs}) ctx = await startBus(
      'enabled: true\nplugins:\n'
      '${uiEntry('ui.crash', mode: 'crash')}\n'
      '${uiEntry('ui.hold')}\n',
    );
    final PluginBus bus = ctx.bus;
    await waitFor(
      () => bus.lifecycleOf('ui.crash').wire == 'failed',
      reason: '非零退出应判 failed',
    );
    final Map<String, Map<String, dynamic>> instances =
        snapshotInstances(bus);
    expect(instances['ui.crash']!['status'], 'disabled');
    expect(instances['ui.crash']!['health'], 'unavailable');
    expect(instances['ui.crash']!['disabled_reason'], contains('异常退出'));

    await waitFor(
      () => bus.healthOf('ui.hold')['process_alive'] == true,
      reason: '另一个 UI 插件应保持运行',
    );
    final Map<String, dynamic> stopped = await bus.forceStop('ui.hold');
    expect(stopped['ok'], isTrue);
    expect(stopped['exited'], isTrue);
    expect(bus.lifecycleOf('ui.hold').wire, 'stopped');
    expect(stopped['kill_reason'], contains('强制停止'));
  });

  test('未实现 tools/list 的 headless 插件照常上线：无占位工具、无专用日志', () async {
    final ({PluginBus bus, File config, List<String> logs}) ctx = await startBus(
      '''
enabled: true
plugins:
  - id: headless.no.tools
    name: 无工具插件
    command: "$dartBin"
    args: ["$fakePlugin", "--no-tools"]
    runtime: binary
''',
    );
    final PluginBus bus = ctx.bus;
    await waitFor(
      () => bus.instances().length == 1,
      reason: '缺 tools/list 不得阻断上线',
    );
    await waitFor(
      () => bus.lifecycleOf('headless.no.tools').wire == 'ready',
      reason: '取不到工具也应就绪',
    );
    expect(bus.errorOf('headless.no.tools'), isNull);
    expect(bus.toolsOf('headless.no.tools'), isEmpty);
    expect(bus.allTools(), isEmpty, reason: '不得生成占位能力');
    expect(
      ctx.logs.any((String line) => line.contains('tools/list')),
      isFalse,
      reason: '缺失可选能力不应写专用日志',
    );
    final Map<String, dynamic> instance =
        snapshotInstances(bus)['headless.no.tools']!;
    expect(instance['status'], 'registered');
    expect(instance['runtime'], 'headless');
    expect(instance['runtime_legacy'], isTrue);
  });
}
