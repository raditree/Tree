import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 插件总线（M6b）：**真进程**验证宿主协议、总线、快照与工具层。
void main() {
  late Directory temp;
  late String script;
  late String eventsFile;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_plugin_');
    script = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'fake_plugin.dart',
    );
    eventsFile = p.join(temp.path, 'events.jsonl');
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

  PluginConfig config({
    String id = 'sample',
    List<String> extra = const <String>[],
    Map<String, dynamic>? scope,
    bool enabled = true,
  }) => PluginConfig(
    id: id,
    name: '样例插件',
    command: Platform.resolvedExecutable,
    args: <String>[
      script,
      if (extra.contains('--events')) ...<String>['--events-file', eventsFile],
      ...extra.where((String e) => e != '--events'),
    ],
    enabled: enabled,
    granularity: 'team',
    scope: scope ?? <String, dynamic>{'team_id': 'team-1'},
  );

  test('宿主：握手 + tools/list + tools/call（真子进程）', () async {
    final PluginHost host = await PluginHost.start(
      config(),
      coreVersion: 'test',
    );
    addTearDown(host.close);
    expect(host.pluginId, 'fake-plugin');
    expect(host.name, '假插件');
    expect(host.capabilities, contains('tools'));
    expect(host.isClosed, isFalse);

    final List<PluginToolInfo> tools = await host.listTools();
    expect(tools.map((PluginToolInfo t) => t.name), <String>['echo', 'slow']);
    expect(tools.first.description, '回显输入');

    final PluginCallResult echo = await host.callTool('echo', <String, dynamic>{
      'text': '你好',
    });
    expect(echo.isError, isFalse);
    expect(echo.text, 'plugin-echo: 你好');
    final PluginCallResult unknown = await host.callTool(
      'nope',
      <String, dynamic>{},
    );
    expect(unknown.isError, isTrue);
    expect(unknown.text, contains('未知工具'));
    expect(await host.ping(), isTrue);
  });

  test('宿主：工具超时与 command 为空都是可读错误', () async {
    final PluginHost host = await PluginHost.start(config());
    addTearDown(host.close);
    final PluginCallResult slow = await host.callTool(
      'slow',
      <String, dynamic>{},
      timeout: const Duration(milliseconds: 200),
    );
    expect(slow.isError, isTrue);
    expect(slow.text, contains('超时'));
    await expectLater(
      PluginHost.start(PluginConfig(id: 'x', command: '')),
      throwsA(isA<PluginException>()),
    );
  });

  test('总线：配置加载 → 启动 → 工具聚合 → 事件分发（真插件落文件）', () async {
    final File file = File('${temp.path}/config/plugins.yaml');
    file.createSync(recursive: true);
    file.writeAsStringSync(
      'enabled: true\n'
      'plugins:\n'
      '  - id: sample\n'
      '    name: 样例插件\n'
      '    command: "${Platform.resolvedExecutable.replaceAll('\\', '/')}"\n'
      '    args: ["${script.replaceAll('\\', '/')}", "--events-file", "${eventsFile.replaceAll('\\', '/')}"]\n'
      '    granularity: team\n'
      '    scope: {team_id: team-1}\n',
    );

    final PluginBus bus = PluginBus(
      configFile: file.path,
      coreVersion: 'test',
      watchdogInterval: const Duration(seconds: 30),
    );
    addTearDown(bus.close);
    expect(bus.configs().single.id, 'sample');
    await bus.start();
    expect(bus.instances(), hasLength(1));
    expect(bus.toolsOf('sample').map((PluginToolInfo t) => t.name), <String>[
      'echo',
      'slow',
    ]);
    expect(bus.allTools(), hasLength(2), reason: '每个工具一条');
    expect(bus.allTools().first.pluginId, 'sample');
    expect(bus.errorOf('sample'), isNull);

    // 事件分发：scope 匹配才投递（空字段 = 不限定）
    expect(
      bus.dispatch(<String, dynamic>{
        'type': 'task',
        'team_id': 'team-2',
        'payload': <String, dynamic>{'x': 1},
      }),
      0,
      reason: 'team 不匹配',
    );
    expect(
      bus.dispatch(<String, dynamic>{
        'type': 'task',
        'team_id': 'team-1',
        'payload': <String, dynamic>{'x': 2},
      }),
      1,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(File(eventsFile).existsSync(), isTrue, reason: '插件应收到事件');
    final List<String> lines = File(eventsFile)
        .readAsLinesSync()
        .where((String l) => l.trim().isNotEmpty)
        .toList();
    expect(lines, hasLength(1));
    expect(jsonDecode(lines.single), containsPair('type', 'task'));

    // 工具调用（命名空间名）
    final PluginCallResult called = await bus.callTool(
      'plugin__sample__echo',
      <String, dynamic>{'text': 'X'},
    );
    expect(called.text, 'plugin-echo: X');
    expect(
      (await bus.callTool('plugin__ghost__echo', <String, dynamic>{})).isError,
      isTrue,
    );
  });

  test('快照：契约字段齐全；不可用插件标记 disabled 且带原因', () async {
    // 用一个必然启动失败的插件：command 指向不存在的可执行文件
    final File file = File('${temp.path}/config/plugins.yaml');
    file.createSync(recursive: true);
    file.writeAsStringSync(
      'enabled: true\n'
      'plugins:\n'
      '  - id: broken\n'
      '    name: 坏插件\n'
      '    command: definitely-not-an-executable-xyz\n'
      '    granularity: agent\n'
      '    scope: {agent_id: agt_1}\n',
    );
    final PluginBus bus = PluginBus(configFile: file.path);
    addTearDown(bus.close);
    await bus.start();

    final Map<String, dynamic> snapshot = bus.snapshot();
    expect(snapshot['enabled'], isTrue);
    expect(snapshot['stations'], isEmpty);
    final Map<String, dynamic> watchdog =
        snapshot['watchdog'] as Map<String, dynamic>;
    expect(watchdog['interval_s'], 15);
    expect(watchdog['disabled_count'], 1);
    final Map<String, dynamic> instance =
        (snapshot['instances'] as List<dynamic>).single as Map<String, dynamic>;
    expect(instance['plugin_id'], 'broken');
    expect(instance['status'], 'disabled');
    expect(instance['disabled_reason'], isNotEmpty);
    expect(instance['granularity'], 'agent');
    expect((instance['scope'] as Map<String, dynamic>)['agent_id'], 'agt_1');

    // team_id 过滤：实例 scope 是 agent，不受 team 过滤影响
    expect(
      (bus.snapshot(teamId: 'team-x')['instances'] as List<dynamic>),
      hasLength(1),
    );
  });

  test('看门狗：忽略 ping 的插件被标记不可用', () async {
    final File file = File('${temp.path}/config/plugins.yaml');
    file.createSync(recursive: true);
    file.writeAsStringSync(
      'enabled: true\n'
      'plugins:\n'
      '  - id: deaf\n'
      '    command: "${Platform.resolvedExecutable.replaceAll('\\', '/')}"\n'
      '    args: ["${script.replaceAll('\\', '/')}", "--ignore-ping"]\n',
    );
    final PluginBus bus = PluginBus(
      configFile: file.path,
      watchdogInterval: const Duration(seconds: 30),
    );
    addTearDown(bus.close);
    await bus.start();
    expect(bus.instances(), hasLength(1));

    await bus.watchdog();
    expect(bus.instances(), isEmpty, reason: '心跳失败应断开并标记');
    expect(bus.errorOf('deaf'), contains('心跳失败'));
    final Map<String, dynamic> instance =
        (bus.snapshot()['instances'] as List<dynamic>).single
            as Map<String, dynamic>;
    expect(instance['status'], 'disabled');
  });

  group('工具层', () {
    test('plugin 工具 schema / handles / 动态声明 / help 与 call', () async {
      expect(PluginTool.handles('plugin'), isTrue);
      expect(PluginTool.handles('plugin__a__b'), isTrue);
      expect(PluginTool.handles('mcp__a__b'), isFalse);
      final ToolSpec spec = PluginTool.spec();
      final Map<String, dynamic> properties =
          spec.parameters['properties'] as Map<String, dynamic>;
      expect((properties['action'] as Map<String, dynamic>)['enum'], <String>[
        'help',
        'call',
      ]);

      final PluginBus bus = PluginBus(
        configFile: '${temp.path}/config/plugins.yaml',
        hostFactory: (PluginConfig c) => PluginHost.start(
          PluginConfig(
            id: c.id,
            name: c.name,
            command: Platform.resolvedExecutable,
            args: <String>[script],
            scope: c.scope,
          ),
        ),
      );
      addTearDown(bus.close);
      final File file = File('${temp.path}/config/plugins.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync(
        'enabled: true\nplugins:\n  - id: sample\n    command: x\n',
      );
      await bus.start();

      final List<ToolSpec> dynamicSpecs = PluginTool.dynamicSpecs(bus);
      expect(dynamicSpecs.map((ToolSpec s) => s.name), <String>[
        'plugin__sample__echo',
        'plugin__sample__slow',
      ]);
      expect(dynamicSpecs.first.parameters['required'], <String>['text']);

      ToolInvocation call(Map<String, dynamic> args) => ToolInvocation(
        id: 't',
        name: 'plugin',
        arguments: args,
        agentId: 'agt_1',
        sessionId: 'ses_1',
      );
      final ToolOutcome help = await PluginTool.run(
        call(<String, dynamic>{'action': 'help'}),
        bus,
      );
      expect(help.content, contains('plugin__sample__echo'));
      final ToolOutcome called = await PluginTool.run(
        call(<String, dynamic>{
          'action': 'call',
          'tool_name': 'plugin__sample__echo',
          'arguments': <String, dynamic>{'text': 'Q'},
        }),
        bus,
      );
      expect(called.content, 'plugin-echo: Q');
      expect(
        (await PluginTool.run(
          call(<String, dynamic>{'action': 'call'}),
          bus,
        )).isError,
        isTrue,
      );
      expect(
        (await PluginTool.run(
          call(<String, dynamic>{'action': 'nope'}),
          bus,
        )).isError,
        isTrue,
      );
    });

    test('运行器：插件命名空间工具可直接调用，且不需要工作空间', () async {
      final File file = File('${temp.path}/config/plugins.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync(
        'enabled: true\n'
        'plugins:\n'
        '  - id: sample\n'
        '    command: "${Platform.resolvedExecutable.replaceAll('\\', '/')}"\n'
        '    args: ["${script.replaceAll('\\', '/')}"]\n',
      );
      final PluginBus bus = PluginBus(configFile: file.path);
      addTearDown(bus.close);
      await bus.start();

      final WorkspaceToolRunner runner = WorkspaceToolRunner(
        resolveWorkspaceDir: (String _) => '',
        pluginBus: bus,
      );
      final List<String> names = runner
          .specsFor(agentId: 'agt_1', sessionId: 'ses_1')
          .map((ToolSpec s) => s.name)
          .toList();
      expect(names, contains('plugin'));
      expect(names, contains('plugin__sample__echo'));

      final ToolOutcome outcome = await runner.run(
        ToolInvocation(
          id: 't',
          name: 'plugin__sample__echo',
          arguments: <String, dynamic>{'text': 'W'},
          agentId: 'agt_1',
          sessionId: 'ses_1',
        ),
      );
      expect(outcome.isError, isFalse);
      expect(outcome.content, 'plugin-echo: W');
      await runner.close();
    });
  });
}
