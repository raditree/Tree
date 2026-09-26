import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 假 MCP 客户端：不启进程，只回放脚本化工具与调用结果。
class _FakeMcpClient implements McpClient {
  _FakeMcpClient(this.config, {this.failConnect = false});

  final McpServerConfig config;
  final bool failConnect;
  bool closed = false;
  int callCount = 0;

  @override
  Map<String, dynamic> get serverInfo => <String, dynamic>{'name': config.name};

  @override
  String get protocolVersion => '2024-11-05';

  @override
  String get stderrTail => '';

  @override
  bool get isClosed => closed;

  @override
  Future<List<McpToolInfo>> listTools({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (failConnect) throw McpException('连接失败（假）');
    return <McpToolInfo>[
      McpToolInfo(
        name: 'echo',
        description: '回显',
        inputSchema: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'text': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['text'],
        },
      ),
    ];
  }

  @override
  Future<McpCallResult> callTool(
    String toolName,
    Map<String, dynamic> arguments, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    callCount++;
    if (toolName != 'echo') {
      return McpCallResult(text: '未知工具 $toolName', isError: true);
    }
    return McpCallResult(text: 'echo: ${arguments['text']}');
  }

  @override
  Future<void> close() async => closed = true;
}

/// MCP 管理（M6a）：配置落盘、连接缓存、命名空间调用与工具层。
void main() {
  late Directory temp;
  late McpService service;
  late List<McpServerConfig> connected;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_mcp_');
    connected = <McpServerConfig>[];
    service = McpService(
      configFile: '${temp.path}/config/mcp.yaml',
      clientFactory: (McpServerConfig config) async {
        connected.add(config);
        return _FakeMcpClient(config);
      },
    );
  });

  tearDown(() async {
    await service.close();
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  test('register：校验必填、落盘 yaml、可被新实例读回', () async {
    expect(
      (await service.register(<String, dynamic>{})).containsKey('error'),
      isTrue,
    );
    expect(
      (await service.register(<String, dynamic>{'name': 'x'}))
          .containsKey('error'),
      isTrue,
    );
    expect(
      (await service.register(<String, dynamic>{
        'name': 'bad name',
        'command': 'node',
      })).containsKey('error'),
      isTrue,
      reason: 'name 只允许安全字符（避免配置注入）',
    );

    final Map<String, dynamic> result = await service.register(
      <String, dynamic>{
        'name': 'fs',
        'command': 'npx',
        'args': <String>['-y', 'server-fs'],
        'env': <String, String>{'K': 'V'},
      },
    );
    expect(result['success'], isTrue);
    expect(result['tools'], <String>['echo'], reason: '注册后立刻连接并拉工具');

    final File file = File('${temp.path}/config/mcp.yaml');
    expect(file.existsSync(), isTrue);
    final String yaml = file.readAsStringSync();
    expect(yaml, contains('npx'));
    expect(yaml, contains('server-fs'));

    final McpService reloaded = McpService(
      configFile: file.path,
      clientFactory: (McpServerConfig config) async => _FakeMcpClient(config),
    );
    reloaded.load();
    expect(reloaded.servers().single.name, 'fs');
    expect(reloaded.servers().single.args, <String>['-y', 'server-fs']);
    expect(reloaded.servers().single.env['K'], 'V');
    await reloaded.close();
  });

  test('refresh + 命名空间调用：工具聚合与按名寻址', () async {
    await service.register(<String, dynamic>{'name': 'fs', 'command': 'npx'});
    await service.refresh();
    expect(service.toolsOf('fs').single.name, 'echo');
    expect(service.allTools().single.service, 'fs');
    expect(service.errorOf('fs'), isNull);

    final McpCallResult byNamespace = await service.callTool(
      'mcp__fs__echo',
      <String, dynamic>{'text': 'A'},
    );
    expect(byNamespace.text, 'echo: A');
    final McpCallResult bare = await service.callTool('echo', <String, dynamic>{
      'text': 'B',
    });
    expect(bare.text, 'echo: B', reason: '裸工具名也能从缓存里找到服务');
    expect(
      (await service.callTool('mcp__ghost__echo', <String, dynamic>{})).isError,
      isTrue,
    );
    expect(
      (await service.callTool(
        'echo',
        <String, dynamic>{},
        service: 'ghost',
      )).isError,
      isTrue,
    );
  });

  test('坏服务只影响自己：错误可读、核心不抛异常、禁用即断开', () async {
    final McpService broken = McpService(
      configFile: '${temp.path}/config/mcp.yaml',
      clientFactory: (McpServerConfig config) async =>
          _FakeMcpClient(config, failConnect: true),
    );
    // 注册本身应当成功（配置要落盘），"连不上"只体现在错误信息与空工具上——
    // 这正是"坏插件不拦住核心"的语义。
    final Map<String, dynamic> registered = await broken.register(
      <String, dynamic>{'name': 'bad', 'command': 'npx'},
    );
    expect(registered['success'], isTrue);
    expect(registered['tools'], isEmpty);
    expect(broken.errorOf('bad'), contains('连接失败'));
    expect(broken.toolsOf('bad'), isEmpty);

    // 调用失败返回**可读结果**而不是抛异常（模型要能读到原因）
    final McpCallResult failed = await broken.callTool(
      'mcp__bad__echo',
      <String, dynamic>{},
    );
    expect(failed.isError, isTrue);
    expect(failed.text, contains('不可用'));
    await broken.close();
  });

  test('remove：内置拒绝删除；普通服务删除后配置同步', () async {
    await service.register(<String, dynamic>{
      'name': 'builtin-fs',
      'command': 'npx',
      'builtin': true,
    });
    final Map<String, dynamic> refused = await service.remove('builtin-fs');
    expect(refused['error'], contains('内置 MCP 服务不可删除'));
    expect(service.servers(), hasLength(1));

    await service.register(<String, dynamic>{'name': 'mine', 'command': 'npx'});
    expect((await service.remove('mine'))['success'], isTrue);
    expect(
      service.servers().map((McpServerConfig s) => s.name),
      isNot(contains('mine')),
    );
    expect((await service.remove('ghost'))['error'], contains('不存在'));
  });

  group('工具层', () {
    test('mcp 工具 schema 与 handles；动态声明来自已就绪工具', () async {
      expect(McpTool.handles('mcp'), isTrue);
      expect(McpTool.handles('mcp__fs__echo'), isTrue);
      expect(McpTool.handles('read'), isFalse);
      final ToolSpec spec = McpTool.spec();
      final Map<String, dynamic> properties =
          spec.parameters['properties'] as Map<String, dynamic>;
      expect((properties['action'] as Map<String, dynamic>)['enum'], <String>[
        'help',
        'call',
      ]);

      await service.register(<String, dynamic>{'name': 'fs', 'command': 'npx'});
      final List<ToolSpec> dynamicSpecs = McpTool.dynamicSpecs(service);
      expect(dynamicSpecs.single.name, 'mcp__fs__echo');
      expect(dynamicSpecs.single.description, contains('[MCP fs]'));
      expect(dynamicSpecs.single.parameters['required'], <String>[
        'text',
      ], reason: 'inputSchema 原样透传');
    });

    test('help 列出工具；call 转发参数；未知 action 可读报错', () async {
      ToolInvocation call(Map<String, dynamic> args) => ToolInvocation(
        id: 't',
        name: 'mcp',
        arguments: args,
        agentId: 'agt_1',
        sessionId: 'ses_1',
      );
      final ToolOutcome empty = await McpTool.run(
        call(<String, dynamic>{'action': 'help'}),
        service,
      );
      expect(empty.content, contains('没有可用的 MCP 工具'));

      await service.register(<String, dynamic>{'name': 'fs', 'command': 'npx'});
      final ToolOutcome help = await McpTool.run(
        call(<String, dynamic>{'action': 'help'}),
        service,
      );
      expect(help.content, contains('mcp__fs__echo'));
      expect(help.content, contains('回显'));

      final ToolOutcome called = await McpTool.run(
        call(<String, dynamic>{
          'action': 'call',
          'tool_name': 'mcp__fs__echo',
          'arguments': <String, dynamic>{'text': 'Z'},
        }),
        service,
      );
      expect(called.content, 'echo: Z');

      expect(
        (await McpTool.run(
          call(<String, dynamic>{'action': 'call'}),
          service,
        )).isError,
        isTrue,
      );
      expect(
        (await McpTool.run(
          call(<String, dynamic>{'action': 'nope'}),
          service,
        )).isError,
        isTrue,
      );
    });

    test('运行器：命名空间工具可直接调用，且不需要工作空间', () async {
      await service.register(<String, dynamic>{'name': 'fs', 'command': 'npx'});
      final WorkspaceToolRunner runner = WorkspaceToolRunner(
        resolveWorkspaceDir: (String _) => '',
        mcpService: service,
      );
      final List<String> names = runner
          .specsFor(agentId: 'agt_1', sessionId: 'ses_1')
          .map((ToolSpec s) => s.name)
          .toList();
      expect(names, contains('mcp'));
      expect(names, contains('mcp__fs__echo'));

      final ToolOutcome outcome = await runner.run(
        ToolInvocation(
          id: 't',
          name: 'mcp__fs__echo',
          arguments: <String, dynamic>{'text': 'Y'},
          agentId: 'agt_1',
          sessionId: 'ses_1',
        ),
      );
      expect(outcome.isError, isFalse);
      expect(outcome.content, 'echo: Y');
      await runner.close();
    });
  });
}
