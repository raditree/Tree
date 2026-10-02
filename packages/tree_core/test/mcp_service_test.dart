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
  final LivenessTracker liveness = LivenessTracker(label: '假 MCP 服务');

  @override
  bool get isDegraded => liveness.isStale;

  @override
  int get degradeCount => 0;

  @override
  Future<List<McpToolInfo>> listTools() async {
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
    Map<String, dynamic> arguments,
  ) async {
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

  /// 本次测试期内的假客户端实例（按服务名），用于模拟"服务崩了"（closed=true）。
  late Map<String, _FakeMcpClient> fakes;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_mcp_');
    connected = <McpServerConfig>[];
    fakes = <String, _FakeMcpClient>{};
    service = McpService(
      configFile: '${temp.path}/config/mcp.yaml',
      clientFactory: (McpServerConfig config) async {
        connected.add(config);
        final _FakeMcpClient client = _FakeMcpClient(config);
        fakes[config.name] = client;
        return client;
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

  group('懒注册（真机反馈："点注册很久没反应、提示推了一次又一次"）', () {
    test('register 只连它自己：不再把其它已连服务全量重连一遍', () async {
      await service.register(<String, dynamic>{'name': 'a', 'command': 'node'});
      await service.register(<String, dynamic>{'name': 'b', 'command': 'node'});
      expect(service.isConnected('a'), isTrue);
      expect(service.isConnected('b'), isTrue);
      final LivenessTracker? aBefore = service.livenessOf('a');
      final LivenessTracker? bBefore = service.livenessOf('b');
      connected.clear();

      await service.register(<String, dynamic>{'name': 'c', 'command': 'node'});

      expect(
        connected.map((McpServerConfig c) => c.name).toList(),
        <String>['c'],
        reason: '注册 c 的代价不该包含 a / b（旧实现 refresh(force: true) 会重连所有人）',
      );
      expect(
        identical(service.livenessOf('a'), aBefore),
        isTrue,
        reason: 'a 的连接实例没被换掉（没被重连）',
      );
      expect(identical(service.livenessOf('b'), bBefore), isTrue);
      expect(service.isConnected('c'), isTrue);
      expect(service.toolsOf('c').map((McpToolInfo t) => t.name), <String>['echo']);
    });

    test('懒连接：连接掉了的服务在"调用它的工具"时才补连，且不惊动别的服务', () async {
      await service.register(<String, dynamic>{'name': 'a', 'command': 'node'});
      await service.register(<String, dynamic>{'name': 'b', 'command': 'node'});
      // 模拟 a 的服务崩了（客户端已关闭）
      fakes['a']!.closed = true;
      expect(service.isConnected('a'), isFalse);
      connected.clear();

      final McpCallResult result = await service.callTool(
        'mcp__a__echo',
        <String, dynamic>{'text': 'x'},
      );

      expect(result.isError, isFalse, reason: '懒连接成功后正常调用');
      expect(result.text, 'echo: x');
      expect(
        connected.map((McpServerConfig c) => c.name).toList(),
        <String>['a'],
        reason: '只补连 a：懒连接不该顺带连 b',
      );
      expect(service.isConnected('b'), isTrue, reason: 'b 的连接没被动过');
    });

    test('懒连接失败：给可读错误 + 记录原因，并在退避窗口内不反复重试', () async {
      await service.register(<String, dynamic>{
        'name': 'bad',
        'command': 'node',
      });
      // 让它下次连接必失败
      fakes.remove('bad');
      service = McpService(
        configFile: '${temp.path}/config/mcp.yaml',
        clientFactory: (McpServerConfig config) async {
          connected.add(config);
          return _FakeMcpClient(config, failConnect: true);
        },
      );
      service.load();
      await service.refresh(force: true);
      expect(service.isConnected('bad'), isFalse);
      expect(service.errorOf('bad'), isNotNull);

      connected.clear();
      final McpCallResult result = await service.callTool(
        'mcp__bad__echo',
        <String, dynamic>{'text': 'x'},
      );
      expect(result.isError, isTrue);
      expect(result.text, contains('不可用'));
      expect(
        connected,
        isEmpty,
        reason: '刚失败过（退避窗口内）不再重试：连接尝试本身就要等满心跳窗口，反复重试就是"又卡住了"',
      );
    });

    test('transport/http 的注册校验：要 url、不要 command；stdio 仍要 command', () async {
      expect(
        (await service.register(<String, dynamic>{
          'name': 'h1',
          'transport': 'http',
        })).toString(),
        contains('需要合法 url'),
      );
      expect(
        (await service.register(<String, dynamic>{
          'name': 'h2',
          'transport': 'http',
          'url': 'ftp://example.com/mcp',
        })).toString(),
        contains('需要合法 url'),
      );
      expect(
        (await service.register(<String, dynamic>{
          'name': 'h3',
          'transport': 'websocket',
          'command': 'node',
        })).toString(),
        contains('transport 只支持'),
      );
      // 旧形态（无 transport）行为不变：仍要求 command
      expect(
        (await service.register(<String, dynamic>{'name': 's1'})).toString(),
        contains('缺少 command'),
      );
    });
  });
}
