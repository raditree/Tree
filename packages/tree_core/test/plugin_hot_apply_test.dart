// 插件配置热应用（M9 §4.2「开关立刻有用」）的核心用例：**真子进程假插件** + 真
// plugins.yaml，验证 PluginBus.applyConfigs 的配置对账口径。
//
// 锁住的行为（凡"有没有重启"一律用假插件的启动日志计数证明，不靠"看起来成功"）：
// 1. 新增条目且 enabled ⇒ 立刻启动，工具表与站点订阅随之更新；
// 2. 启动参数未变 ⇒ **不重启**（启动次数不增加）、也不无谓触发工具定义收集；
// 3. 改启动参数（args / scope）⇒ 断开后用新参数重启（新进程 marker 变了，工具表跟着变）；
// 4. enabled=false ⇒ 断开、从实例列表消失，配置条目**仍在**（面板显示"已停用"），
//    工具定义与站点订阅一并注销；再打开即恢复；
// 5. 条目被删除 ⇒ 断开并忘掉（配置与实例都没有了，且不会阴魂不散）；
// 6. 单个插件启动失败（命令不存在）⇒ 只进 failed + 可读原因，其它插件照常运行；
// 7. 顶层总开关关闭 ⇒ 只断不启；
// 8. 清单被手改坏 ⇒ 不执行对账，运行实例保持原样（一次拼写错误不等于全量停机）。
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  late Directory temp;
  late String script;
  late String configFile;
  late List<PluginBus> buses;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_plugin_hot_');
    script = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'hot_plugin.dart',
    );
    expect(File(script).existsSync(), isTrue, reason: '假插件脚本必须存在');
    configFile = p.join(temp.path, 'config', 'plugins.yaml');
    buses = <PluginBus>[];
  });

  tearDown(() async {
    for (final PluginBus bus in buses) {
      try {
        await bus.close();
      } catch (_) {
        // 关停失败不该让用例的断言结果被盖掉
      }
    }
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

  /// 假插件的启动日志（**每次进程启动一行**；测试靠它数启动次数）。
  String startLogOf(String id) => p.join(temp.path, '$id.starts.jsonl');

  int startCount(String id) {
    final File file = File(startLogOf(id));
    if (!file.existsSync()) return 0;
    return file
        .readAsLinesSync()
        .where((String line) => line.trim().isNotEmpty)
        .length;
  }

  /// 历次启动带的 marker（证明"这次起来的是新参数"）。
  List<String> markersOf(String id) {
    final File file = File(startLogOf(id));
    if (!file.existsSync()) return const <String>[];
    return <String>[
      for (final String line in file.readAsLinesSync())
        if (line.trim().isNotEmpty)
          (jsonDecode(line) as Map<String, dynamic>)['marker'].toString(),
    ];
  }

  /// 落盘一份 plugins.yaml（= 前端保存后的磁盘状态）。
  void writeConfigs(List<String> entries, {bool total = true}) {
    final File file = File(configFile);
    file.createSync(recursive: true);
    file.writeAsStringSync(
      <String>['enabled: $total', 'plugins:', ...entries, ''].join('\n'),
    );
  }

  /// 一条插件条目（真跑 hot_plugin.dart 子进程）。
  List<String> pluginEntry(
    String id, {
    String marker = 'v1',
    bool enabled = true,
    String granularity = 'team',
    String teamId = 'team-1',
    String? command,
    List<String>? args,
    String name = '',
  }) {
    final List<String> effectiveArgs =
        args ??
        <String>[
          script,
          '--id',
          id,
          '--marker',
          marker,
          '--start-log',
          startLogOf(id),
        ];
    final String commandLine = (command ?? Platform.resolvedExecutable)
        .replaceAll('\\', '/');
    return <String>[
      '  - id: $id',
      '    name: ${name.isEmpty ? '$id 插件' : name}',
      '    command: "$commandLine"',
      '    args: [${effectiveArgs.map((String a) => '"${a.replaceAll('\\', '/')}"').join(', ')}]',
      '    enabled: $enabled',
      '    granularity: $granularity',
      '    scope: {team_id: $teamId}',
    ];
  }

  PluginBus newBus() {
    final PluginBus bus = PluginBus(
      configFile: configFile,
      coreVersion: 'test',
      // 心跳节拍拉长：这些用例只关心配置对账，不要探活定时器插进来
      heartbeatInterval: const Duration(seconds: 30),
    );
    buses.add(bus);
    return bus;
  }

  List<String> ids(List<PluginReconcileAction> actions) => <String>[
    for (final PluginReconcileAction action in actions) action.pluginId,
  ];

  List<String> instanceIds(PluginBus bus) => <String>[
    for (final ({String pluginId, PluginHost host}) entry in bus.instances())
      entry.pluginId,
  ];

  List<String> tableToolNames(PluginBus bus) => <String>[
    for (final ({String pluginId, PluginToolInfo tool}) entry
        in bus.toolTable())
      entry.tool.name,
  ];

  /// 某插件当前挂在哪些站点上（跨全部站点查订阅）。
  List<String> subscribedStations(PluginBus bus, String pluginId) {
    final List<String> out = <String>[];
    for (final dynamic raw in bus.snapshot()['stations'] as List<dynamic>) {
      final Map<String, dynamic> station = raw as Map<String, dynamic>;
      for (final dynamic sub in station['subscriptions'] as List<dynamic>) {
        if ((sub as Map<String, dynamic>)['plugin_id'] == pluginId) {
          out.add(station['station_id'].toString());
        }
      }
    }
    return out;
  }

  // ── 用例 ───────────────────────────────────────────────────────────────

  test('对账：新增条目 ⇒ 立刻启动，工具表与站点订阅随之更新', () async {
    writeConfigs(const <String>[]);
    final PluginBus bus = newBus();
    await bus.start();
    expect(instanceIds(bus), isEmpty, reason: '清单是空的');
    expect(bus.allTools(), isEmpty);

    // 前端新增一条并落盘（等价于 POST /api/plugin/configs 写盘后的那一刻）
    writeConfigs(pluginEntry('alpha'));
    final PluginReconcileResult report = await bus.applyConfigs();

    expect(report.error, isEmpty);
    expect(report.hasChanges, isTrue);
    expect(ids(report.started), <String>['alpha']);
    expect(report.actionOf('alpha')!.kind, PluginReconcileKind.started);
    expect(report.actionOf('alpha')!.reason, isNotEmpty);
    expect(ids(report.failed), isEmpty);
    expect(report.describe(), contains('启动 1 个'));

    expect(startCount('alpha'), 1, reason: '进程真的起来了');
    expect(instanceIds(bus), <String>['alpha']);
    expect(bus.errorOf('alpha'), isNull);
    // 工具表：收集站收到插件申报的定义
    expect(bus.toolsOf('alpha').map((PluginToolInfo t) => t.name), <String>[
      'marker',
    ]);
    expect(bus.definitionOf('plugin__alpha__marker'), isNotNull);
    expect(tableToolNames(bus), contains('marker'));
    expect(bus.toolTableDirty, isFalse, reason: '对账后按既有机制补了一次收集');
    // 站点订阅：插件上线 ⇒ 收集站挂上它
    expect(subscribedStations(bus, 'alpha'), hasLength(1));
  });

  test('对账：启动参数未变 ⇒ 不重启（启动次数不增加）', () async {
    writeConfigs(pluginEntry('alpha'));
    final PluginBus bus = newBus();
    await bus.start();
    expect(startCount('alpha'), 1, reason: '核心启动时拉起一次');

    // 反复对账：包括"把一模一样的内容再写一遍盘"（前端每次保存都会发生）
    for (int i = 0; i < 3; i++) {
      writeConfigs(pluginEntry('alpha'));
      final PluginReconcileResult report = await bus.applyConfigs();
      expect(ids(report.restarted), isEmpty, reason: '参数没变就不该重启');
      expect(ids(report.started), isEmpty);
      expect(ids(report.unchanged), <String>['alpha']);
      expect(report.hasChanges, isFalse);
    }
    expect(startCount('alpha'), 1, reason: '三次对账，一次都没重启（这是本用例的核心）');
    expect(markersOf('alpha'), <String>['v1']);
    expect(instanceIds(bus), <String>['alpha'], reason: '还是原来那个实例，没被换掉');
    expect(bus.toolTableDirty, isFalse, reason: '没变化就不触发收集，不白打扰插件');

    // 只改显示名（name）：不是启动参数 ⇒ 同样不重启
    writeConfigs(pluginEntry('alpha', name: '改了个名字'));
    final PluginReconcileResult renamed = await bus.applyConfigs();
    expect(ids(renamed.unchanged), <String>['alpha']);
    expect(startCount('alpha'), 1, reason: 'name 只是显示名，改它不需要重启');
  });

  test('对账：启动参数变化 ⇒ 断开后用新参数重启（工具表随之更新）', () async {
    writeConfigs(pluginEntry('alpha', marker: 'v1'));
    final PluginBus bus = newBus();
    await bus.start();
    expect(
      (await bus.callTool(
        'plugin__alpha__marker',
        const <String, dynamic>{},
      )).text,
      'marker=v1',
    );

    // ① 改 args（marker 是启动参数的一部分）
    writeConfigs(pluginEntry('alpha', marker: 'v2'));
    final PluginReconcileResult byArgs = await bus.applyConfigs();
    expect(ids(byArgs.restarted), <String>['alpha']);
    expect(byArgs.actionOf('alpha')!.reason, contains('args'));
    expect(startCount('alpha'), 2);
    expect(markersOf('alpha'), <String>['v1', 'v2'], reason: '新进程真的带上了新参数');
    expect(
      (await bus.callTool(
        'plugin__alpha__marker',
        const <String, dynamic>{},
      )).text,
      'marker=v2',
    );
    expect(
      bus.toolsOf('alpha').single.description,
      contains('v2'),
      reason: '工具定义随重启重新收集',
    );
    expect(instanceIds(bus), <String>['alpha']);

    // ② 改 scope（团队归属）：同样是启动参数 ⇒ 重启，订阅挪到**同一个全局收集站**上，
    // 只是订阅声明的 team 变了（站点不再随 team 复制）。
    writeConfigs(pluginEntry('alpha', marker: 'v2', teamId: 'team-2'));
    final PluginReconcileResult byScope = await bus.applyConfigs();
    expect(ids(byScope.restarted), <String>['alpha']);
    expect(byScope.actionOf('alpha')!.reason, contains('scope'));
    expect(startCount('alpha'), 3);
    expect(subscribedStations(bus, 'alpha'), <String>[StationHubIds.collect]);
    final Map<String, dynamic> collectStation = (bus.snapshot()['stations'] as List<dynamic>)
        .firstWhere(
          (dynamic s) => (s as Map<String, dynamic>)['kind'] == 'collect',
        ) as Map<String, dynamic>;
    expect(
      collectStation['subscribers_by_team'],
      <String, dynamic>{
        'team-2': <String, dynamic>{
          'count': 1,
          'plugin_ids': <String>['alpha'],
        },
      },
      reason: '团队归属在订阅声明上：重启后只剩 team-2 这一条（旧订阅已注销）',
    );
    expect(
      bus.snapshot()['stations'],
      hasLength(18),
      reason: '收集站全局唯一：换团队不产生新站；快照恒为 17 个内置点位 + 收集站',
    );
  });

  test('对账：enabled=false ⇒ 断开且从实例列表消失，配置条目仍在', () async {
    writeConfigs(pluginEntry('alpha'));
    final PluginBus bus = newBus();
    await bus.start();
    expect(subscribedStations(bus, 'alpha'), hasLength(1));

    writeConfigs(pluginEntry('alpha', enabled: false));
    final PluginReconcileResult report = await bus.applyConfigs();

    expect(ids(report.stopped), <String>['alpha']);
    expect(report.actionOf('alpha')!.reason, contains('条目已停用'));
    expect(report.hasChanges, isTrue);
    expect(instanceIds(bus), isEmpty, reason: '实例列表里不再有它');
    expect(bus.healthOf('alpha')['health'], 'unavailable');
    // 配置条目保留：面板要显示"已停用"而不是让这一项消失
    expect(bus.config('alpha'), isNotNull);
    expect(bus.config('alpha')!.enabled, isFalse);
    // 工具定义与站点订阅一并注销（否则模型还能调用一个已经不在的插件）
    expect(bus.toolsOf('alpha'), isEmpty);
    expect(bus.definitionOf('plugin__alpha__marker'), isNull);
    expect(tableToolNames(bus), isEmpty);
    expect(subscribedStations(bus, 'alpha'), isEmpty);

    // 再打开：同一个 id 恢复（新进程）
    writeConfigs(pluginEntry('alpha'));
    final PluginReconcileResult reopened = await bus.applyConfigs();
    expect(ids(reopened.started), <String>['alpha']);
    expect(startCount('alpha'), 2);
    expect(bus.toolsOf('alpha'), hasLength(1));
    expect(subscribedStations(bus, 'alpha'), hasLength(1));
  });

  test('对账：条目被删除 ⇒ 断开并忘掉（配置与实例都没了）', () async {
    writeConfigs(pluginEntry('alpha'));
    final PluginBus bus = newBus();
    await bus.start();

    writeConfigs(const <String>[]);
    final PluginReconcileResult report = await bus.applyConfigs();
    expect(ids(report.stopped), <String>['alpha']);
    expect(report.actionOf('alpha')!.reason, contains('已删除'));
    expect(instanceIds(bus), isEmpty);
    expect(bus.config('alpha'), isNull, reason: '内存里也不该再留着它');
    expect(bus.toolsOf('alpha'), isEmpty);
    expect(subscribedStations(bus, 'alpha'), isEmpty);

    // 再对账一次：没有任何动作（删掉的条目不会阴魂不散）
    final PluginReconcileResult again = await bus.applyConfigs();
    expect(again.all, isEmpty);
    expect(again.hasChanges, isFalse);
    expect(startCount('alpha'), 1, reason: '删掉之后不会再被拉起来');
  });

  test('对账：单个插件启动失败只记 failed，其它插件照常运行', () async {
    writeConfigs(<String>[
      ...pluginEntry('alpha'),
      ...pluginEntry('broken', command: 'definitely-not-an-executable-xyz'),
      ...pluginEntry('beta', marker: 'b1'),
    ]);
    final PluginBus bus = newBus();
    await bus.start();

    // 启动阶段就已经按老口径隔离过了：坏的不可用，好的照常在跑
    expect(instanceIds(bus), containsAll(<String>['alpha', 'beta']));
    expect(instanceIds(bus), isNot(contains('broken')));
    expect(bus.errorOf('broken'), isNotEmpty);

    final int betaStarts = startCount('beta');
    final PluginReconcileResult report = await bus.applyConfigs();
    expect(ids(report.failed), <String>['broken']);
    expect(report.actionOf('broken')!.reason, isNotEmpty);
    expect(ids(report.unchanged), containsAll(<String>['alpha', 'beta']));
    expect(ids(report.started), isEmpty);
    expect(
      instanceIds(bus),
      containsAll(<String>['alpha', 'beta']),
      reason: '一个插件起不来不影响别人',
    );
    expect(startCount('beta'), betaStarts, reason: '好的插件也不会被牵连重启');
    expect(bus.toolsOf('alpha'), hasLength(1));
    expect(bus.toolsOf('beta'), hasLength(1));
    expect(bus.toolsOf('broken'), isEmpty);

    // 把坏的改成好命令（等价于用户在前端改好 command 再保存）⇒ 下一次对账就好
    writeConfigs(<String>[
      ...pluginEntry('alpha'),
      ...pluginEntry('broken'),
      ...pluginEntry('beta', marker: 'b1'),
    ]);
    final PluginReconcileResult fixed = await bus.applyConfigs();
    expect(ids(fixed.started), <String>['broken']);
    expect(ids(fixed.failed), isEmpty);
    expect(instanceIds(bus), containsAll(<String>['alpha', 'beta', 'broken']));
  });

  test('对账：顶层总开关关闭 ⇒ 只断不启；再打开即恢复', () async {
    writeConfigs(pluginEntry('alpha'));
    final PluginBus bus = newBus();
    await bus.start();
    expect(instanceIds(bus), <String>['alpha']);

    writeConfigs(pluginEntry('alpha'), total: false);
    final PluginReconcileResult off = await bus.applyConfigs();
    expect(off.totalEnabled, isFalse);
    expect(ids(off.stopped), <String>['alpha']);
    expect(off.actionOf('alpha')!.reason, contains('总开关'));
    expect(instanceIds(bus), isEmpty);
    expect(bus.config('alpha'), isNotNull, reason: '条目与总开关是两层，条目不该被删');

    writeConfigs(pluginEntry('alpha'));
    final PluginReconcileResult on = await bus.applyConfigs();
    expect(on.totalEnabled, isTrue);
    expect(ids(on.started), <String>['alpha']);
    expect(startCount('alpha'), 2);
  });

  test('对账：清单被手改坏 ⇒ 不执行对账，运行实例保持原样（不因拼写错误全停）', () async {
    writeConfigs(pluginEntry('alpha'));
    final PluginBus bus = newBus();
    await bus.start();

    File(configFile).writeAsStringSync(
      'enabled: true\nplugins:\n  - id: alpha\n    args: ["unclosed\n',
    );
    final PluginReconcileResult report = await bus.applyConfigs();
    expect(report.error, isNotEmpty, reason: '读不出来要如实回报，不能当成"没有插件"');
    expect(report.describe(), contains('未执行'));
    expect(report.hasChanges, isFalse);
    expect(instanceIds(bus), <String>['alpha'], reason: '在跑的插件不许被牵连');
    expect(startCount('alpha'), 1);

    // 文件改回正常：配置没变 ⇒ 依然不重启
    writeConfigs(pluginEntry('alpha'));
    final PluginReconcileResult healed = await bus.applyConfigs();
    expect(ids(healed.unchanged), <String>['alpha']);
    expect(startCount('alpha'), 1);
  });
}
