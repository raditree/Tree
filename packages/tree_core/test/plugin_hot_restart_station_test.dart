// 执行站 `plugin.*` 命令表的钉住用例（20261015-hot-restart 阶段 1，D10/D9）。
//
// 这一条链是 D10「A+B 混合」的全部落点：**不新增 RPC method**，转储/取回走已有的
// `station/command`；代价是命令表、白名单、归属口径必须自己钉牢，因为再也没有
// "method 不存在"这一层天然护栏。
//
// 钉住的六件事：
// 1. 新点位 `system.execute.plugin` 在 `StationHubIds.all` 里（漏了这一条 ⇒ 插件订阅
//    会被当成别人的自建站拒掉，是 plan 风险表里"新点位静默失效"那格）；
// 2. 内置点位总数 20 → **21**（派生计数，加点位必须同时改这里）；
// 3. 六条命令都挂到了这个点位上（挂载位置由点位表的 commands 驱动，不是硬编码）；
// 4. 未知命令被显式拒绝并回整张白名单（不"看起来执行了"）；
// 5. 归属口径分两套：控制面四条要求 `scope.team_id`（证明不了就拒），快照两条要求
//    **发起者就是插件本人且只能动自己的键**；
// 6. `plugin.stateDump` / `plugin.stateFetch` **不暴露给 agent tool**（D9），并且
//    `pluginManager` 没接线时显式报「未接线」而不是静默成功。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  late Directory temp;
  late String configFile;
  late PluginBus bus;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_plugin_commands_');
    configFile = p.join(temp.path, 'config', 'plugins.yaml');
    Directory(p.dirname(configFile)).createSync(recursive: true);
    // 两条**不同 team** 的条目：归属口径的用例要靠它们区分（写在第一次 load 之前，
    // 否则 load() 的幂等会让新条目进不了内存 —— 这正是 applyConfigs 存在的理由）。
    File(configFile).writeAsStringSync(<String>[
      'enabled: true',
      'plugins:',
      '  - id: alpha',
      '    name: 甲插件',
      '    command: "definitely-not-a-real-command-xyz"',
      '    args: []',
      '    enabled: true',
      '    granularity: team',
      '    suspension: keep',
      '    scope: {team_id: team-1}',
      '  - id: beta',
      '    name: 乙插件',
      '    command: "definitely-not-a-real-command-xyz"',
      '    args: []',
      '    enabled: true',
      '    granularity: team',
      '    scope: {team_id: team-2}',
      '',
    ].join('\n'));
    bus = PluginBus(
      configFile: configFile,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
    );
    // 把 plugin.* 的挂载位置接上（生产由 CoreServer 注入，这里注入的是同一个实现）。
    final ExecuteStationMounts mounts = ExecuteStationMounts.forStore(
      store: MemoryStore(),
      ioFor: (String agentId) async => null,
      pluginManager: bus.handlePluginCommand,
    );
    expect(bus.mountExecuteStations(mounts), isNull, reason: '挂载必须全成功');
  });

  tearDown(() async {
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

  /// 走**执行站**下一条命令（不绕过去直接调 bus：这一条链的白名单与归属校验
  /// 都在站点和挂载位置上，绕过就等于没测到它们）。
  Future<StationCommandResult> run(
    String command, {
    Map<String, dynamic> arguments = const <String, dynamic>{},
    StationScope scope = const StationScope(teamId: 'team-1'),
    String sourcePluginId = '',
  }) async {
    final ExecuteStation? station = bus.stations.executeForCommand(command);
    expect(station, isNotNull, reason: '$command 没有所属点位');
    return station!.execute(
      command: command,
      scope: scope,
      arguments: arguments,
      sourcePluginId: sourcePluginId,
    );
  }

  Map<String, dynamic> payloadOf(StationCommandResult result) =>
      (result.payload ?? const <String, dynamic>{}) as Map<String, dynamic>;

  // ── 1/2/3：点位登记与挂载 ─────────────────────────────────────────────
  test('新点位进了 StationHubIds.all，且内置点位总数是 21', () {
    expect(
      StationHubIds.all,
      contains(StationHubIds.executePlugin),
      reason: '漏进 all ⇒ 插件订阅被当成别人的自建站拒掉（静默失效）',
    );
    expect(StationPoints.all.length, 21);
    expect(StationHubIds.all.length, StationPoints.all.length);
    expect(
      StationPoints.byId(StationHubIds.executePlugin),
      isNotNull,
      reason: '常量与点位表必须成对出现',
    );
  });

  test('插件点位的六条命令都真的挂上了挂载位置（表驱动，不是硬编码）', () {
    final StationPointSpec spec =
        StationPoints.byId(StationHubIds.executePlugin)!;
    expect(spec.alias, 'plugin');
    expect(spec.label, '插件管理');
    expect(spec.readme, isNotEmpty, reason: '内置点位必须有介绍（面板详情页读它）');
    expect(spec.commands, <String>[
      'plugin.list',
      'plugin.restart',
      'plugin.suspend',
      'plugin.state',
      'plugin.stateDump',
      'plugin.stateFetch',
    ]);

    final ExecuteStation station =
        bus.stations.executePointFor(StationHubIds.executePlugin)!;
    final Set<String> mounted = station
        .mounts()
        .map((StationCommandMount m) => m.command)
        .toSet();
    expect(mounted, spec.commands.toSet(), reason: '点位表说有的，挂载位置就得有');
  });

  test('每条 plugin.* 命令的 owner 都是插件点位（命令 → 点位唯一）', () {
    for (final String command in StationPoints.byId(
      StationHubIds.executePlugin,
    )!
        .commands) {
      expect(
        StationPoints.ownerOfCommand(command)?.id,
        StationHubIds.executePlugin,
        reason: command,
      );
    }
  });

  // ── 4：未知命令 ───────────────────────────────────────────────────────
  test('未知命令被拒：白名单里没有的 plugin.* 一律显式失败并回清单', () async {
    // 1) 点位表层面：根本认不出这个命令属于哪个点位
    expect(StationPoints.ownerOfCommand('plugin.bogus'), isNull);
    expect(StationPoints.ownerOfCommand('plugin.stateDumpX'), isNull);

    // 2) 站点层面：直接拿插件点位执行它 ⇒ 拒并把本点位允许的六条全列出来
    final ExecuteStation station =
        bus.stations.executePointFor(StationHubIds.executePlugin)!;
    final StationCommandResult denied = await station.execute(
      command: 'plugin.bogus',
      scope: const StationScope(teamId: 'team-1'),
      arguments: const <String, dynamic>{},
    );
    expect(denied.ok, isFalse);
    expect(denied.error, contains('plugin.bogus'));
    expect(denied.error, contains('不属于点位'));
    for (final String allowed in station.commands) {
      expect(denied.error, contains(allowed), reason: '回包必须把允许的清单端完');
    }

    // 3) 实现层面：即使有人绕过站点直接调进来，也得给“没有实现”而不是静默成功
    final Map<String, dynamic> inner = await bus.handlePluginCommand(
      command: 'plugin.bogus',
      pluginId: 'alpha',
      sourcePluginId: 'alpha',
    );
    expect(inner['ok'], isFalse);
    expect(inner['error'], contains('没有实现'));
  });

  // ── 5：两套归属口径 ───────────────────────────────────────────────────
  test('控制面四条：scope 没有 team_id ⇒ 证明不了归属就拒（fail-closed）', () async {
    for (final String command in PluginToolSurface.agentToolCommands) {
      final StationCommandResult denied = await run(
        command,
        scope: const StationScope(), // team 留空
        arguments: const <String, dynamic>{'plugin_id': 'alpha'},
      );
      expect(denied.ok, isFalse, reason: command);
      expect(denied.error, contains('team_id'), reason: command);
    }
  });

  test('控制面四条：要指名 plugin_id（plugin.list 除外）', () async {
    for (final String command in <String>[
      'plugin.restart',
      'plugin.suspend',
      'plugin.state',
    ]) {
      final StationCommandResult denied = await run(command);
      expect(denied.ok, isFalse, reason: command);
      expect(denied.error, contains('plugin_id'), reason: command);
    }
    // plugin.list 不需要目标 id：它就是"看全部"
    final StationCommandResult list = await run('plugin.list');
    expect(list.ok, isTrue, reason: list.error);
  });

  test('快照两条：必须由插件身份下达，且不许写别人的键', () async {
    for (final String command in PluginToolSurface.lifecycleOnlyCommands) {
      // 没有 source_plugin_id ⇒ 证明不了快照归谁
      final StationCommandResult anonymous = await run(
        command,
        arguments: const <String, dynamic>{'payload': <String, dynamic>{'a': 1}},
      );
      expect(anonymous.ok, isFalse, reason: command);
      expect(anonymous.error, contains('插件身份'), reason: command);

      // 以 alpha 的身份去动 beta 的快照 ⇒ 拒（这一条即使 scope 是空的也该拒）
      final StationCommandResult cross = await run(
        command,
        scope: const StationScope(),
        sourcePluginId: 'alpha',
        arguments: const <String, dynamic>{
          'plugin_id': 'beta',
          'payload': <String, dynamic>{'a': 1},
        },
      );
      expect(cross.ok, isFalse, reason: command);
      expect(cross.error, contains('只能操作自己的快照'), reason: command);
    }
  });

  test('快照两条：没有配置条目 / 还没有一世 ⇒ 拒收并给原因', () async {
    // 键由核心拼（pluginId#generation），代际 = 0 意味着"这一世还不存在"
    final StationCommandResult noEra = await run(
      'plugin.stateDump',
      sourcePluginId: 'alpha',
      arguments: const <String, dynamic>{'payload': <String, dynamic>{'k': 1}},
    );
    expect(noEra.ok, isFalse, reason: '进程还没起来过就收快照 ⇒ 快照没有主人');
    expect(payloadOf(noEra), isEmpty);
    expect(noEra.error, contains('还没有任何一世'));

    // 配置里根本没有这个 id（绕过挂载位置直接调实现，验的是实现自己的第二道校验）
    final Map<String, dynamic> unknown = await bus.handlePluginCommand(
      command: 'plugin.stateDump',
      pluginId: 'ghost',
      sourcePluginId: 'ghost',
      arguments: const <String, dynamic>{'payload': <String, dynamic>{'k': 1}},
    );
    expect(unknown['ok'], isFalse);
    expect(unknown['error'], contains('没有插件条目'));
  });

  // ── 6：不暴露给 agent tool + 未接线 ──────────────────────────────────
  test('stateDump / stateFetch 不暴露给 agent tool（D9）', () {
    // 两套命令必须**正好覆盖**点位表里的六条，且互不相交：漏一条或重一条都算没定稿
    expect(
      PluginToolSurface.agentToolCommands.union(
        PluginToolSurface.lifecycleOnlyCommands,
      ),
      StationPoints.byId(StationHubIds.executePlugin)!.commands.toSet(),
    );
    expect(
      PluginToolSurface.agentToolCommands.intersection(
        PluginToolSurface.lifecycleOnlyCommands,
      ),
      isEmpty,
    );
    // 工具表里永远不会出现快照两条（它们不是能力，是生命周期原语）
    for (final String command in PluginToolSurface.lifecycleOnlyCommands) {
      expect(bus.definitionOf(command), isNull, reason: command);
      expect(
        bus.allTools().any(
          (({String pluginId, PluginToolInfo tool}) entry) =>
              entry.tool.name.contains(command.split('.').last),
        ),
        isFalse,
        reason: command,
      );
    }
  });

  test('pluginManager 没接线 ⇒ 显式报「未接线」，不静默成功', () async {
    final PluginBus bare = PluginBus(
      configFile: configFile,
      heartbeatInterval: const Duration(seconds: 30),
    );
    // 只挂 fs 那一族常用的解析器，**不给** pluginManager
    final ExecuteStationMounts noManager = ExecuteStationMounts.forStore(
      store: MemoryStore(),
      ioFor: (String agentId) async => null,
    );
    expect(bare.mountExecuteStations(noManager), isNull);

    final ExecuteStation station =
        bare.stations.executePointFor(StationHubIds.executePlugin)!;
    final StationCommandResult denied = await station.execute(
      command: 'plugin.list',
      scope: const StationScope(teamId: 'team-1'),
      arguments: const <String, dynamic>{},
    );
    expect(denied.ok, isFalse);
    expect(denied.error, contains('未接线'));
    await bare.close();
  });

  test('命令结论的形状：成功是 {ok:true, ...}，被拒是 ok=false + 可读 error', () async {
    final StationCommandResult list = await run('plugin.list');
    expect(list.ok, isTrue, reason: list.error);
    final Map<String, dynamic> payload = payloadOf(list);
    expect(payload['ok'], isTrue);
    final List<dynamic> plugins = payload['plugins'] as List<dynamic>;
    expect(plugins, hasLength(2));
    final Map<String, dynamic> alpha = plugins
        .cast<Map<String, dynamic>>()
        .firstWhere((Map<String, dynamic> e) => e['plugin_id'] == 'alpha');
    // 每条都带这三个读数（面板与 agent 都靠它们说话）
    expect(alpha['lifecycle'], isA<String>());
    expect(alpha['generation'], isA<int>());
    expect(alpha['suspendable'], isTrue, reason: 'alpha 声明了 suspension: keep');
    final Map<String, dynamic> beta = plugins
        .cast<Map<String, dynamic>>()
        .firstWhere((Map<String, dynamic> e) => e['plugin_id'] == 'beta');
    expect(beta['suspendable'], isFalse, reason: 'beta 没声明 ⇒ 默认不可挂起（D3）');
  });
}
