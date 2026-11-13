import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// UI **多窗口**：同一插件多个进程、多个 UI 插件并存。
///
/// 钉住三条语义边界：
/// 1. 窗口是**进程**：`w1` / `w2` 各自一个 pid，核心能列出来、能再拉起；
/// 2. **关一个窗口不等于插件下线**：还有别的窗口时不发 `closed`、不注销自建站、
///    插件状态仍是 registered；
/// 3. **最后一个窗口**退出才走插件级收尾（`onPluginOffline` 恰好一次）。
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

  setUp(() {
    root = Directory.systemTemp.createTempSync('tree_ui_windows_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> waitFor(
    bool Function() predicate, {
    Duration timeout = const Duration(seconds: 15),
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

  String uiEntry(String id, {bool enabled = true}) => '''
  - id: $id
    name: $id
    command: "$dartBin"
    args: ["$probe", "hold"]
    runtime: ui
    enabled: $enabled''';

  ({PluginBus bus, List<String> logs}) createBus({
    Duration uiExitGrace = const Duration(seconds: 1),
  }) {
    final File config = File(p.join(root.path, 'plugins.yaml'));
    final List<String> logs = <String>[];
    final PluginBus bus = PluginBus(
      configFile: config.path,
      uiHelloWindow: const Duration(seconds: 10),
      uiExitGrace: uiExitGrace,
      heartbeatInterval: const Duration(seconds: 30),
      log: logs.add,
    );
    bus.pluginLog = (String id, String line, String stream) => logs.add(line);
    bus.bindCoreEndpoint(url: 'ws://127.0.0.1:12345', token: 'ui-test-token');
    return (bus: bus, logs: logs);
  }

  Future<({PluginBus bus, List<String> logs})> startBus(
    String entries, {
    Duration uiExitGrace = const Duration(seconds: 1),
  }) async {
    final ({PluginBus bus, List<String> logs}) ctx = createBus(
      uiExitGrace: uiExitGrace,
    );
    File(
      p.join(root.path, 'plugins.yaml'),
    ).writeAsStringSync('enabled: true\nplugins:\n$entries\n');
    await ctx.bus.start();
    addTearDown(ctx.bus.close);
    return ctx;
  }

  Future<void> letExitGracePass() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  Map<String, Map<String, dynamic>> snapshotInstances(PluginBus bus) =>
      <String, Map<String, dynamic>>{
        for (final Object? raw
            in bus.snapshot()['instances'] as List<dynamic>)
          (raw as Map<String, dynamic>)['plugin_id'] as String:
              raw.cast<String, dynamic>(),
      };

  test('同一插件开第二个窗口：w1/w2 两个 pid、快照 windows=2、日志带窗口 id', () async {
    final ({PluginBus bus, List<String> logs}) ctx = await startBus(
      uiEntry('ui.multi'),
    );
    final PluginBus bus = ctx.bus;

    await waitFor(
      () => bus.uiWindows().length == 1,
      reason: '插件启动后应有 1 个窗口',
    );
    expect(bus.uiWindows().single['window_id'], 'w1');
    expect(bus.uiWindows().single['plugin_id'], 'ui.multi');
    await waitFor(
      () => ctx.logs.any((String line) => line.contains('TREE_UI_WINDOW_ID=w1')),
      reason: '核心应把窗口 id 注入进程环境',
    );

    final Map<String, dynamic> created = await bus.startUiWindow('ui.multi');
    expect(created['ok'], isTrue);
    expect(created['window_id'], 'w2');
    await waitFor(
      () => bus.uiWindows().length == 2,
      reason: 'startUiWindow 应拉起第二个进程',
    );
    final Set<Object?> pids = bus.uiWindows()
        .map((Map<String, dynamic> w) => w['pid'])
        .toSet();
    expect(pids.length, 2, reason: '两个窗口必须是两个进程');
    expect(snapshotInstances(bus)['ui.multi']!['windows'], 2);
    await waitFor(
      () => ctx.logs.any((String line) => line.contains('TREE_UI_WINDOW_ID=w2')),
      reason: '第二个窗口也要拿到自己的 id',
    );
  });

  test('关掉一个窗口：插件仍在线（不触发 onPluginOffline）；最后一个才下线', () async {
    final ({PluginBus bus, List<String> logs}) ctx = await startBus(
      uiEntry('ui.multi'),
    );
    final PluginBus bus = ctx.bus;
    final List<String> offline = <String>[];
    bus.onPluginOffline = offline.add;

    await waitFor(() => bus.uiWindows().length == 1);
    await bus.startUiWindow('ui.multi');
    await waitFor(() => bus.uiWindows().length == 2);

    final Map<String, dynamic> second = bus.uiWindows().firstWhere(
      (Map<String, dynamic> w) => w['window_id'] == 'w2',
    );
    Process.killPid(second['pid'] as int);
    await waitFor(
      () => bus.uiWindows().length == 1,
      reason: '被杀掉的窗口应从窗口表里摘掉',
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(offline, isEmpty, reason: '还有窗口在跑，插件没有下线');
    expect(snapshotInstances(bus)['ui.multi']!['status'], 'registered');
    expect(snapshotInstances(bus)['ui.multi']!['windows'], 1);

    final Map<String, dynamic> last = bus.uiWindows().single;
    Process.killPid(last['pid'] as int);
    await waitFor(
      () => bus.uiWindows().isEmpty,
      reason: '最后一个窗口退出后窗口表应为空',
    );
    await waitFor(
      () => offline.isNotEmpty,
      reason: '最后一个窗口退出才通知插件下线',
    );
    expect(offline, <String>['ui.multi']);
    expect(snapshotInstances(bus)['ui.multi']!['status'], 'disabled');
  });

  test('多个 UI 插件同时运行：各自一份窗口表；关掉一个不影响另一个', () async {
    final ({PluginBus bus, List<String> logs}) ctx = await startBus('''
${uiEntry('ui.one')}
${uiEntry('ui.two')}''');
    final PluginBus bus = ctx.bus;

    await waitFor(
      () => bus.uiWindows().length == 2,
      reason: '两个 UI 插件应同时在线（各自一个窗口）',
    );
    final Set<String> plugins = bus.uiWindows()
        .map((Map<String, dynamic> w) => w['plugin_id'] as String)
        .toSet();
    expect(plugins, <String>{'ui.one', 'ui.two'});

    await bus.closeAllUiWindows('ui.one');
    await waitFor(() => bus.uiWindows().length == 1);
    expect(bus.uiWindows().single['plugin_id'], 'ui.two');
    expect(snapshotInstances(bus)['ui.one']!['status'], 'disabled');
    expect(snapshotInstances(bus)['ui.two']!['status'], 'registered');
    expect(bus.lifecycleOf('ui.one').wire, 'stopped');
  });

  test('最后一个 UI 窗口退出：通知核心自动退出（只一次）', () async {
    final ({PluginBus bus, List<String> logs}) ctx = await startBus(
      uiEntry('ui.one'),
      uiExitGrace: const Duration(milliseconds: 80),
    );
    final List<String> exits = <String>[];
    ctx.bus.onAllUiExited = exits.add;

    await waitFor(() => ctx.bus.uiWindows().length == 1);
    ctx.bus.noteUiHello('ui.one');
    Process.killPid(ctx.bus.uiWindows().single['pid'] as int);
    await waitFor(
      () => exits.isNotEmpty,
      reason: '最后一个 UI 进程退出后应请求核心退出',
    );
    expect(exits, hasLength(1));
    await letExitGracePass();
    expect(exits, hasLength(1), reason: '一个核心进程只请求一次');
  });

  test('仍有其它 UI 窗口在跑：不请求核心退出', () async {
    final ({PluginBus bus, List<String> logs}) ctx = await startBus(
      '${uiEntry('ui.one')}\n${uiEntry('ui.two')}',
      uiExitGrace: const Duration(milliseconds: 80),
    );
    final List<String> exits = <String>[];
    ctx.bus.onAllUiExited = exits.add;

    await waitFor(() => ctx.bus.uiWindows().length == 2);
    ctx.bus.noteUiHello('ui.one');
    ctx.bus.noteUiHello('ui.two');
    final Map<String, dynamic> one = ctx.bus.uiWindows().firstWhere(
      (Map<String, dynamic> w) => w['plugin_id'] == 'ui.one',
    );
    Process.killPid(one['pid'] as int);
    await letExitGracePass();
    expect(exits, isEmpty);
    expect(ctx.bus.uiWindows(), hasLength(1));
  });

  test('UI 主动关闭全部窗口：最后一批退干净后才请求核心退出', () async {
    final ({PluginBus bus, List<String> logs}) ctx = await startBus(
      '${uiEntry('ui.one')}\n${uiEntry('ui.two')}',
      uiExitGrace: const Duration(milliseconds: 80),
    );
    final List<String> exits = <String>[];
    ctx.bus.onAllUiExited = exits.add;

    await waitFor(() => ctx.bus.uiWindows().length == 2);
    ctx.bus.noteUiHello('ui.one');
    ctx.bus.noteUiHello('ui.two');

    await ctx.bus.closeAllUiWindows('ui.one');
    await letExitGracePass();
    expect(exits, isEmpty, reason: '另一个 UI 插件的窗口还在跑');

    await ctx.bus.closeAllUiWindows('ui.two');
    await waitFor(
      () => exits.isNotEmpty,
      reason: '所有 UI 窗口都关闭后应请求核心退出',
    );
    expect(exits, hasLength(1));
  });

  test('UI 从未 ui.hello：窗口退出也不请求核心退出', () async {
    final ({PluginBus bus, List<String> logs}) ctx = await startBus(
      uiEntry('ui.one'),
      uiExitGrace: const Duration(milliseconds: 80),
    );
    final List<String> exits = <String>[];
    ctx.bus.onAllUiExited = exits.add;

    await waitFor(() => ctx.bus.uiWindows().length == 1);
    Process.killPid(ctx.bus.uiWindows().single['pid'] as int);
    await letExitGracePass();
    expect(exits, isEmpty, reason: '界面从未真正连上，核心要保留现场');
    expect(
      ctx.logs.any((String line) => line.contains('从未收到过 ui.hello')),
      isTrue,
    );
  });

  test('全部停用：关窗口是管理动作，不请求核心退出', () async {
    final ({PluginBus bus, List<String> logs}) ctx = await startBus(
      uiEntry('ui.one'),
      uiExitGrace: const Duration(milliseconds: 80),
    );
    final List<String> exits = <String>[];
    ctx.bus.onAllUiExited = exits.add;

    await waitFor(() => ctx.bus.uiWindows().length == 1);
    ctx.bus.noteUiHello('ui.one');
    File(p.join(root.path, 'plugins.yaml')).writeAsStringSync(
      'enabled: true\nplugins:\n${uiEntry('ui.one', enabled: false)}\n',
    );
    await ctx.bus.applyConfigs();
    await letExitGracePass();
    expect(exits, isEmpty, reason: '全部停用后核心要留着开引导页');
    expect(ctx.bus.uiWindows(), isEmpty);
  });

  test('重启 UI 插件：换窗口不等于退出应用', () async {
    final ({PluginBus bus, List<String> logs}) ctx = await startBus(
      uiEntry('ui.one'),
      uiExitGrace: const Duration(milliseconds: 80),
    );
    final List<String> exits = <String>[];
    ctx.bus.onAllUiExited = exits.add;

    await waitFor(() => ctx.bus.uiWindows().length == 1);
    ctx.bus.noteUiHello('ui.one');
    await ctx.bus.restart('ui.one');
    await waitFor(
      () => ctx.bus.uiWindows().length == 1,
      reason: '重启后应有一个新窗口',
    );
    await letExitGracePass();
    expect(exits, isEmpty);
  });

  test('核心自身 close：不会再请求一次核心退出', () async {
    final ({PluginBus bus, List<String> logs}) ctx = await startBus(
      uiEntry('ui.one'),
      uiExitGrace: const Duration(milliseconds: 80),
    );
    final List<String> exits = <String>[];
    ctx.bus.onAllUiExited = exits.add;

    await waitFor(() => ctx.bus.uiWindows().length == 1);
    ctx.bus.noteUiHello('ui.one');
    await ctx.bus.close();
    await letExitGracePass();
    expect(exits, isEmpty);
  });

  test('核心接线：UI 全部退出 → onShutdownRequested', () async {
    final ({PluginBus bus, List<String> logs}) ctx = await startBus(
      uiEntry('ui.one'),
      uiExitGrace: const Duration(milliseconds: 80),
    );
    final List<String> requests = <String>[];
    final CoreServer server = await CoreServer.start(
      pluginBus: ctx.bus,
      dataDir: root.path,
      enableHeartbeat: false,
    );
    addTearDown(server.close);
    server.onShutdownRequested = requests.add;

    await waitFor(() => ctx.bus.uiWindows().length == 1);
    ctx.bus.noteUiHello('ui.one');
    await ctx.bus.closeAllUiWindows('ui.one');
    await waitFor(
      () => requests.isNotEmpty,
      reason: '核心应收到生命周期退出请求',
    );
    expect(requests, hasLength(1));
    expect(requests.single, contains('UI 主动关闭全部窗口'));
  });

  test('窗口上限与非 UI 插件都给可读拒绝', () async {
    final ({PluginBus bus, List<String> logs}) ctx = await startBus(
      uiEntry('ui.multi'),
    );
    final PluginBus bus = ctx.bus;
    bus.maxUiWindowsPerPlugin = 2;
    await waitFor(() => bus.uiWindows().length == 1);
    await bus.startUiWindow('ui.multi');
    await waitFor(() => bus.uiWindows().length == 2);
    await expectLater(
      bus.startUiWindow('ui.multi'),
      throwsA(
        isA<PluginException>().having(
          (PluginException e) => '$e',
          'message',
          contains('上限'),
        ),
      ),
    );

    final PluginBus headless = pluginBusWithConfig('''
enabled: true
plugins:
  - id: headless.one
    name: headless.one
    command: "$dartBin"
    args: ["$fakePlugin"]
    runtime: headless
    enabled: true
''');
    await expectLater(
      headless.startUiWindow('headless.one'),
      throwsA(
        isA<PluginException>().having(
          (PluginException e) => '$e',
          'message',
          contains('不是 ui'),
        ),
      ),
    );
  });
}

/// 只读配置、不启动进程的总线（用来断言“非法目标”分支）。
PluginBus pluginBusWithConfig(String yaml) {
  final Directory dir = Directory.systemTemp.createTempSync('tree_ui_cfg_');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  final File config = File(p.join(dir.path, 'plugins.yaml'));
  config.writeAsStringSync(yaml);
  final PluginBus bus = PluginBus(
    configFile: config.path,
    heartbeatInterval: const Duration(seconds: 30),
  );
  bus.bindCoreEndpoint(url: 'ws://127.0.0.1:12345', token: 'ui-test-token');
  return bus;
}
