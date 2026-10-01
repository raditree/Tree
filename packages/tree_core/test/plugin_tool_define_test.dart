import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 插件定义 tool（M9 §3 收集站的首个接入点，**真插件进程**）。
///
/// 数据流：收集站（plugin.tool.define）按 schema 向订阅插件采集工具定义 →
/// 触发方（工具表刷新处，这里显式调用 PluginTool.refreshToolDefinitions）
/// 注册成动态工具 → 调用时**按来源 plugin_id 路由**到声明它的插件执行。
void main() {
  late Directory temp;
  late String script;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_plugin_define_');
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

  Future<PluginBus> startBus({List<String> extra = const <String>[]}) async {
    final File file = File('${temp.path}/config/plugins.yaml');
    file.createSync(recursive: true);
    final String args = <String>[
      '"${script.replaceAll('\\', '/')}"',
      ...extra.map((String e) => '"$e"'),
    ].join(', ');
    file.writeAsStringSync(
      'enabled: true\n'
      'plugins:\n'
      '  - id: sample\n'
      '    name: 样例插件\n'
      '    command: "${Platform.resolvedExecutable.replaceAll('\\', '/')}"\n'
      '    args: [$args]\n'
      '    granularity: team\n'
      '    scope: {team_id: team-1, mode_key: local}\n',
    );
    final PluginBus bus = PluginBus(
      configFile: file.path,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
    );
    await bus.start();
    return bus;
  }

  test('收集站收集插件工具定义 → 触发方注册成动态工具 → 按来源 plugin_id 路由', () async {
    final PluginBus bus = await startBus(extra: <String>['--station-tools']);
    addTearDown(bus.close);

    // 1) 插件启动即触发过一次收集（start ⇒ refresh），工具已注册
    expect(bus.toolsOf('sample').map((PluginToolInfo t) => t.name), <String>[
      'alias',
      'echo',
    ]);
    expect(bus.definitionOf('plugin__sample__alias'), isNotNull);
    expect(
      bus.definitionOf('plugin__sample__alias')!.resolvedExecutionName,
      'echo',
      reason: '执行方式来自站点收集到的定义（工具名 ≠ 执行名）',
    );

    // 2) 触发方可以再触发（时机由调用方决定）：全量替换、可读摘要
    final ToolDefinitionRefresh refresh =
        await PluginTool.refreshToolDefinitions(bus);
    expect(refresh.complete, isTrue, reason: '唯一订阅者已响应');
    expect(refresh.unresponsive, isEmpty);
    expect(refresh.registered, contains('plugin__sample__echo'));
    expect(refresh.registered, contains('plugin__sample__alias'));
    expect(refresh.describe(), contains('注册'));

    // 3) 动态工具声明（模型工具表）来自同一张表
    final List<ToolSpec> specs = PluginTool.dynamicSpecs(bus);
    expect(
      specs.map((ToolSpec s) => s.name),
      containsAll(<String>['plugin__sample__echo', 'plugin__sample__alias']),
    );

    // 4) 调用路由：按来源 plugin_id + 定义里的执行名打到插件
    final PluginCallResult alias = await bus.callTool(
      'plugin__sample__alias',
      <String, dynamic>{'text': 'R'},
    );
    expect(alias.isError, isFalse);
    expect(alias.text, 'plugin-echo: R');
    final PluginCallResult direct = await bus.callTool(
      'plugin__sample__echo',
      <String, dynamic>{'text': 'D'},
    );
    expect(direct.text, 'plugin-echo: D');

    // 5) 站点快照里能看到收集站、schema 与订阅者（站点全局唯一，快照恒四类站）
    final List<dynamic> stations = bus.snapshot()['stations'] as List<dynamic>;
    expect(stations, hasLength(4), reason: '三站内置 + 收集站');
    final Map<String, dynamic> station = stations.firstWhere(
      (dynamic s) => (s as Map<String, dynamic>)['kind'] == 'collect',
    ) as Map<String, dynamic>;
    expect(station['station_id'], StationHubIds.collect);
    expect(station['kind'], 'collect');
    expect(station['builtin'], isTrue);
    final Map<String, dynamic> schema =
        station['schema'] as Map<String, dynamic>;
    final List<dynamic> fields = schema['fields'] as List<dynamic>;
    expect((fields.single as Map<String, dynamic>)['name'], 'tools');
    final List<dynamic> itemFields =
        (fields.single as Map<String, dynamic>)['fields'] as List<dynamic>;
    expect(
      itemFields.map((dynamic f) => (f as Map<String, dynamic>)['name']),
      containsAll(<String>[
        'tool_name',
        'description',
        'parameters',
        'execution',
      ]),
    );
    expect(
      (station['subscriptions'] as List<dynamic>).single['plugin_id'],
      'sample',
    );
  });

  test('未实现收集站通道的老插件仍可用：退回 tools/list 申报（工具不丢）', () async {
    final PluginBus bus = await startBus();
    addTearDown(bus.close);
    expect(bus.toolsOf('sample').map((PluginToolInfo t) => t.name), <String>[
      'echo',
      'slow',
    ]);
    final PluginCallResult echo = await bus.callTool(
      'plugin__sample__echo',
      <String, dynamic>{'text': 'L'},
    );
    expect(echo.text, 'plugin-echo: L');
  });

  test('插件下线：注销站点订阅并移除其动态工具定义', () async {
    final PluginBus bus = await startBus(extra: <String>['--station-tools']);
    expect(bus.toolsOf('sample'), isNotEmpty);
    await bus.close();
    expect(bus.toolsOf('sample'), isEmpty, reason: '下线插件的工具定义一并移除');
    final List<dynamic> stations = bus.snapshot()['stations'] as List<dynamic>;
    final Map<String, dynamic> collectStation = stations.firstWhere(
      (dynamic s) => (s as Map<String, dynamic>)['kind'] == 'collect',
    ) as Map<String, dynamic>;
    expect(
      collectStation['subscriptions'],
      isEmpty,
      reason: '插件下线由总线注销其订阅',
    );
    expect(
      collectStation['subscribers_by_team'],
      isEmpty,
      reason: '订阅没了 ⇒ 面板的团队分组也空',
    );
    // 站点实例本身仍在（站点 = 持久化实例，重启后照旧可用）
    expect(
      File(p.join(temp.path, 'config', 'stations.yaml')).existsSync(),
      isTrue,
    );
  });
}
