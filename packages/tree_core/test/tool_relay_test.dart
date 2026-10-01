import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// **工具调用前/后各一次中转站**（本轮新增）：
///
/// 需求口径（用户定稿）：「把完整 tool_call 传给插件，改什么甚至不改动由插件内部
/// 决定」。因此这里跑的是**真插件进程 + 真中转站 + 真工作空间 IO**：
/// - 插件启动后主动 `station/subscribe`（relay）⇒ 点位化后**一次订两个点位**
///   （`system.relay.tool.pre` / `system.relay.tool.post`），各成唯一订阅者；
/// - 每次工具调用，工具层在**入/出口各触发一次**对应点位：
///   pre ⇒ 插件可改写 `arguments`（测试里把 `write` 的 content 换掉）；
///   post ⇒ 插件可改写 `result`（测试里给结果加前缀）；
/// - **fail-open**：无订阅者 / 插件不响应 / 回包非法 / 未接线时，工具行为必须与
///   改动前**完全一致**（原参数、原结果），且不因中转失败而报错。
void main() {
  late Directory temp;
  late String script;
  late String workspace;

  const String team = 'team-1';
  const String agent = 'agt_1';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_tool_relay_');
    script = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'fake_plugin.dart',
    );
    workspace = p.join(temp.path, 'ws');
    Directory(workspace).createSync(recursive: true);
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

  /// 订阅中转站、并按要求改写 pre（参数）/ post（结果）的插件。
  String relayPluginYaml({String rewrite = 'REWRITTEN'}) =>
      'enabled: true\n'
      'plugins:\n'
      '  - id: relay\n'
      '    name: 中转插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: ["${slash(script)}", "--relay-subscribe", '
      '"--relay-rewrite", "$rewrite"]\n'
      '    granularity: team\n'
      '    scope: {team_id: $team}\n';

  /// 只声明、不订阅中转站的插件（对照组：工具行为必须与改动前一致）。
  String idlePluginYaml() =>
      'enabled: true\n'
      'plugins:\n'
      '  - id: idle\n'
      '    name: 旁观插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: ["${slash(script)}"]\n'
      '    granularity: team\n'
      '    scope: {team_id: $team}\n';

  Future<PluginBus> startBus(String yaml, {List<String> logs = const []}) async {
    final File file = File(p.join(temp.path, 'config', 'plugins.yaml'));
    file.createSync(recursive: true);
    file.writeAsStringSync(yaml);
    final PluginBus bus = PluginBus(
      configFile: file.path,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
      log: logs.isEmpty ? null : logs.add,
    );
    addTearDown(bus.close);
    // 复刻生产接线（CoreServer._wirePluginStations）：team / mode 按 agent 真实归属。
    bus.callSiteContext = (String agentId, String sessionId) =>
        StationScopeContext(
          teamId: agentId == agent ? team : '',
          agentId: agentId,
          sessionId: sessionId,
        );
    bus.agentModeKeyResolver = (String agentId) =>
        agentId == agent ? StationModeKey.local : '';
    await bus.start();
    return bus;
  }

  WorkspaceToolRunner runnerFor(PluginBus bus) {
    final WorkspaceToolRunner runner = WorkspaceToolRunner(
      resolveWorkspaceDir: (String agentId) => workspace,
      pluginBus: bus,
    );
    addTearDown(runner.close);
    return runner;
  }

  ToolInvocation writeInvocation(String content) => ToolInvocation(
    id: 'tool-1',
    name: 'write',
    arguments: <String, dynamic>{'file_path': 'notes/a.txt', 'content': content},
    agentId: agent,
    sessionId: 'sess-1',
  );

  test('订阅中转站的插件：pre 改写参数（真落盘内容变）、post 改写结果', () async {
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(relayPluginYaml(), logs: logs);
    final WorkspaceToolRunner runner = runnerFor(bus);

    // 等订阅成立（插件起进程后主动 subscribe，最多等 10s；失败则测试可读地报错）。
    // 点位化：`station: 'relay'`（不带 point）= 一次订**工具前 + 工具后两个点位**，
    // 两个都要等到（各自唯一订阅者）。
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
    RelayStation? relayPre;
    RelayStation? relayPost;
    while (DateTime.now().isBefore(deadline)) {
      relayPre =
          bus.stations.station(StationHubIds.relayToolPre) as RelayStation?;
      relayPost =
          bus.stations.station(StationHubIds.relayToolPost) as RelayStation?;
      if ((relayPre?.subscribers.isNotEmpty ?? false) &&
          (relayPost?.subscribers.isNotEmpty ?? false)) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(
      relayPre?.subscribers,
      isNotEmpty,
      reason: '插件必须订阅上「工具调用前」点位；日志：${logs.join(' | ')}',
    );
    expect(
      relayPost?.subscribers,
      isNotEmpty,
      reason: '插件必须订阅上「工具调用后」点位；日志：${logs.join(' | ')}',
    );
    // 站点不绑 team：team 视角在**订阅声明的 scope** 上；
    // 两处都有同一个订阅者（这正是「工具前/后各一次中转」的实现方式）。
    for (final RelayStation point in <RelayStation>[relayPre!, relayPost!]) {
      expect(point.subscribers.single.pluginId, 'relay');
      expect(point.subscribers.single.scope.teamId, team);
    }

    final ToolOutcome outcome = await runner.run(
      writeInvocation('模型原始内容'),
    );

    // ① pre：插件把 content 改成了 REWRITTEN ⇒ 真正写进盘的是改写后的内容
    expect(
      File(p.join(workspace, 'notes', 'a.txt')).readAsStringSync(),
      'REWRITTEN',
      reason: '工具执行必须用**改写后**的参数（这是 pre 中转的意义）',
    );
    // ② post：插件给结果加了前缀 ⇒ 返回给上层的结果是改写后的
    expect(outcome.content, startsWith('[改写]'), reason: outcome.content);
    expect(outcome.isError, isFalse);
  });

  test('无订阅者：工具行为与改动前完全一致（fail-open，原参数原结果）', () async {
    final List<String> logs = <String>[];
    final PluginBus bus = await startBus(idlePluginYaml(), logs: logs);
    final WorkspaceToolRunner runner = runnerFor(bus);

    final ToolOutcome outcome = await runner.run(writeInvocation('原样内容'));
    expect(
      File(p.join(workspace, 'notes', 'a.txt')).readAsStringSync(),
      '原样内容',
      reason: '没人订阅时参数绝不能被改动',
    );
    expect(outcome.content, isNot(startsWith('[改写]')));
    expect(outcome.isError, isFalse);
    expect(
      logs.where((String l) => l.contains('工具中转')).toList(),
      isEmpty,
      reason: '无订阅者走快路径，不该产生任何中转日志',
    );
  });

  test('未接入插件总线：工具调用零改动（原路径）', () async {
    final WorkspaceToolRunner runner = WorkspaceToolRunner(
      resolveWorkspaceDir: (String agentId) => workspace,
    );
    addTearDown(runner.close);
    final ToolOutcome outcome = await runner.run(writeInvocation('无总线'));
    expect(
      File(p.join(workspace, 'notes', 'a.txt')).readAsStringSync(),
      '无总线',
    );
    expect(outcome.isError, isFalse);
  });
}
