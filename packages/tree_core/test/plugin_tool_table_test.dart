import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 工具表刷新点 + 运行期四元组（M9 Wave 3-I）。
///
/// 验证三件事：
/// 1. **工具表刷新处**（WorkspaceToolRunner.specsFor，模型每轮生成前都会走）会按需
///    触发收集站：插件**上线 / 下线后模型工具表随之变化**；
/// 2. **缓存 + 失效点**：同一份工具表连续取用不会每次都全量收集（收集次数不增长）；
/// 3. **运行期四元组**：team 取 agent 归属、mode_key 取 agent 的工作空间模式，
///    工具表按 team 过滤（跨 team 的插件工具不进这张表）；无 team 归属的插件仍走
///    旧的 tools/list 路径（行为不变）。
void main() {
  late Directory temp;
  late String script;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_tool_table_');
    script = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'fake_plugin.dart',
    );
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

  /// 配置一个插件：withScope = 有 team 归属（走收集站），否则走旧 tools/list 路径。
  File configFile({String team = 'team-1', bool withScope = true}) {
    final File file = File('${temp.path}/config/plugins.yaml');
    file.createSync(recursive: true);
    file.writeAsStringSync(
      'enabled: true\n'
      'plugins:\n'
      '  - id: sample\n'
      '    name: 样例插件\n'
      '    command: "${Platform.resolvedExecutable.replaceAll('\\', '/')}"\n'
      '    args: ["${script.replaceAll('\\', '/')}", "--station-tools"]\n'
      '    granularity: team\n'
      '${withScope ? '    scope: {team_id: $team, mode_key: local}\n' : ''}',
    );
    return file;
  }

  List<String> specNames(
    WorkspaceToolRunner runner, {
    String agent = 'agt_1',
  }) => runner
      .specsFor(agentId: agent, sessionId: 'ses_1')
      .map((ToolSpec s) => s.name)
      .toList();

  test('插件上线 / 下线后模型工具表随之变化；缓存命中的取用不再全量收集', () async {
    final PluginBus bus = PluginBus(
      configFile: configFile().path,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
    );
    final WorkspaceToolRunner runner = WorkspaceToolRunner(
      resolveWorkspaceDir: (String _) => '',
      pluginBus: bus,
    );
    addTearDown(() async {
      await runner.close();
      await bus.close();
    });

    await bus.start();
    expect(specNames(runner), contains('plugin__sample__echo'));
    expect(specNames(runner), contains('plugin__sample__alias'));

    // **缓存**：连续取用同一份工具表不会重复触发收集站（"每次工具调用都全量收集"
    // 正是要避免的）
    final int refreshes = bus.toolTableRefreshCount;
    expect(refreshes, greaterThan(0), reason: '启动时收集过一次');
    for (int i = 0; i < 5; i++) {
      specNames(runner);
    }
    expect(bus.toolTableRefreshCount, refreshes, reason: '缓存命中 ⇒ 不再触发收集站');

    // **插件下线**：模型工具表立刻不再包含它的工具（失效点 + 定义表同步移除）
    await bus.close();
    expect(
      specNames(runner),
      isNot(contains('plugin__sample__echo')),
      reason: '插件下线后模型工具表必须随之变化',
    );

    // **插件再上线**：刷新点重新收集（ensureToolTableFresh 让测试有确定性）
    await bus.start();
    final StationScope scope = bus.runtimeScopeFor(
      agentId: 'agt_1',
      sessionId: 'ses_1',
    );
    await bus.ensureToolTableFresh(scope: scope);
    expect(
      specNames(runner),
      contains('plugin__sample__echo'),
      reason: '插件上线后模型工具表必须随之变化',
    );
  });

  test('运行期四元组：team 取 agent 归属、mode_key 取工作空间模式', () async {
    final PluginBus bus = PluginBus(
      configFile: configFile(team: 'team-1').path,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
    );
    addTearDown(bus.close);
    bus.agentModeKeyResolver = (String agentId) =>
        agentId == 'ssh_agent' ? StationModeKey.ssh : StationModeKey.local;
    bus.callSiteContext = (String agentId, String sessionId) =>
        StationScopeContext(
          teamId: agentId == 'ssh_agent' ? 'team-1' : 'team-2',
          agentId: agentId,
          sessionId: sessionId,
        );

    final StationScope sshScope = bus.runtimeScopeFor(
      agentId: 'ssh_agent',
      sessionId: 'ses_1',
    );
    expect(sshScope.teamId, 'team-1', reason: 'team 取调用点上下文');
    expect(sshScope.agentId, 'ssh_agent');
    expect(sshScope.sessionId, 'ses_1');
    expect(
      sshScope.modeKey,
      StationModeKey.ssh,
      reason: 'mode 取 agent 的工作空间模式',
    );

    await bus.start();
    // 按运行期四元组触发收集：SSH agent 的收集站是 @team-1@ssh（不是本地实例）
    final ToolDefinitionRefresh refresh = await bus.refreshToolDefinitions(
      scope: sshScope,
      context: StationScopeContext(
        teamId: sshScope.teamId,
        agentId: sshScope.agentId,
        sessionId: sshScope.sessionId,
        modeKey: sshScope.modeKey,
      ),
    );
    expect(refresh.complete, isTrue, reason: refresh.describe());
    expect(
      refresh.stationIds.single,
      contains('@team-1@ssh'),
      reason: 'mode_key 来自 agent 的工作空间模式',
    );

    // 工具表按 team 过滤：team-2 的调用点看不到 team-1 的插件工具
    final StationScope otherTeam = bus.runtimeScopeFor(
      agentId: 'local_agent',
      sessionId: 'ses_1',
    );
    expect(otherTeam.teamId, 'team-2');
    expect(
      PluginTool.dynamicSpecs(bus, scope: otherTeam),
      isEmpty,
      reason: '跨 team 的插件工具不进模型工具表',
    );
    expect(
      PluginTool.dynamicSpecs(bus, scope: sshScope).map((ToolSpec s) => s.name),
      contains('plugin__sample__echo'),
    );
  });

  test('stationScopeResolver 可注入完整运行期四元组（含声明里没有的 team）', () async {
    final PluginBus bus = PluginBus(
      configFile: configFile(withScope: false).path,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
    );
    addTearDown(bus.close);
    bus.stationScopeResolver =
        (PluginConfig config, StationScopeContext context) => StationScope(
          teamId: context.teamId,
          agentId: context.agentId,
          sessionId: context.sessionId,
          modeKey: StationModeKey.local,
        );
    bus.callSiteContext = (String agentId, String sessionId) =>
        StationScopeContext(
          teamId: 'team-ctx',
          agentId: agentId,
          sessionId: sessionId,
        );

    await bus.start();
    // 无 team 归属时走旧路径（tools/list 直接申报）
    expect(bus.toolsOf('sample').map((PluginToolInfo t) => t.name), <String>[
      'echo',
      'slow',
    ]);
    // 注入解析器后：按调用点上下文进站点体系（team 来自上下文）
    final StationScope scope = bus.runtimeScopeFor(
      agentId: 'agt_1',
      sessionId: 'ses_1',
    );
    final ToolDefinitionRefresh refresh = await bus.refreshToolDefinitions(
      scope: scope,
      context: StationScopeContext(
        teamId: scope.teamId,
        agentId: scope.agentId,
        sessionId: scope.sessionId,
        modeKey: scope.modeKey,
      ),
    );
    expect(refresh.complete, isTrue, reason: refresh.describe());
    expect(refresh.stationIds.single, contains('@team-ctx@local'));
    expect(
      PluginTool.dynamicSpecs(bus, scope: scope).map((ToolSpec s) => s.name),
      containsAll(<String>['plugin__sample__echo', 'plugin__sample__alias']),
    );
  });

  test('无 team 归属的插件仍走旧 tools/list 路径（不破坏既有行为）', () async {
    final PluginBus bus = PluginBus(
      configFile: configFile(withScope: false).path,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
    );
    addTearDown(bus.close);
    await bus.start();
    // 没有 team 上下文：不做站点收集，但工具照旧可用
    final ToolDefinitionRefresh refresh = await bus.refreshToolDefinitions();
    expect(refresh.stationIds, isEmpty, reason: '无 team 归属 ⇒ 不进站点体系');
    expect(bus.toolsOf('sample').map((PluginToolInfo t) => t.name), <String>[
      'echo',
      'slow',
    ]);
    final WorkspaceToolRunner runner = WorkspaceToolRunner(
      resolveWorkspaceDir: (String _) => '',
      pluginBus: bus,
    );
    addTearDown(runner.close);
    expect(specNames(runner), contains('plugin__sample__echo'));
  });
}
