import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

import 'fake_transport.dart';
import 'ws_harness.dart';

/// 工具表**按"发消息"刷新**：MCP / 插件工具是运行期才就绪的（服务连上、插件启用、
/// 站点接线完成），发下一条消息时必须已经可用。
///
/// 它与"系统提示词按会话钉住"是同一条前缀策略的两面：
/// - 工具表在请求体的 **tools 字段**里，不参与消息前缀 ⇒ 每次刷新不伤缓存；
/// - 系统提示词在**第 0 条消息**里 ⇒ 一旦中途变样，整条前缀缓存作废（见 #8）。
///
/// 真实路径：`LlmAgentEngine.run` 每次都调 `toolRunner.specsFor(...)`，而
/// `WorkspaceToolRunner.specsFor` 现取 `mcpService` / `pluginBus` 的**运行态**
/// （`McpService.allTools()` / 插件工具表），所以新工具天然是"下一次发消息可见"。
/// 这个用例用"按次增长"的替身把这条不变量钉住：谁把工具表缓存/并入钉住的上下文，它就红。
class _GrowingToolRunner implements ToolRunner {
  int specsCalls = 0;

  @override
  List<ToolSpec> specsFor({
    required String agentId,
    required String sessionId,
  }) {
    specsCalls++;
    return <ToolSpec>[
      const ToolSpec(name: 'read', description: '读文件'),
      // 第二次取时"服务就绪了"：新工具必须立刻可见
      if (specsCalls > 1)
        const ToolSpec(
          name: 'mcp__demo__ping',
          description: '中途就绪的 MCP / 插件工具',
        ),
    ];
  }

  @override
  Future<ToolOutcome> run(
    ToolInvocation invocation, {
    bool Function()? isCancelled,
  }) async => const ToolOutcome('（本用例不执行工具）');

  @override
  Future<void> close() async {}
}

void main() {
  late Directory dataDir;
  late CoreServer server;
  late CoreSettings settings;
  late String agentId;
  late FakeTransport transport;
  late _GrowingToolRunner tools;

  setUp(() async {
    dataDir = Directory.systemTemp.createTempSync('tree_tools_refresh_');
    transport = FakeTransport(<List<LlmStreamEvent>>[
      textScript('第一轮回答'),
      textScript('第二轮回答'),
    ]);
    settings = CoreSettings();
    settings.createModel(<String, dynamic>{
      'model_id': 'demo',
      'base_url': 'https://api.example.com/v1',
      'api_key': 'sk-test',
      'max_seqlen': 128000,
      'thinking': true,
    });
    tools = _GrowingToolRunner();
    server = await CoreServer.start(
      streamChunkDelay: Duration.zero,
      enableHeartbeat: false,
      settings: settings,
      engine: LlmAgentEngine(
        resolveModel: settings.model,
        toolRunner: tools,
        transportFactory: (CoreModelConfig config) => transport,
      ),
    );
    agentId = server.store
        .createAgent(name: '工具表刷新用例', systemPrompt: '你是助手', modelId: 'demo')
        .id;
  });

  tearDown(() async {
    await server.close();
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  Future<void> sendTurn(TestWs ws, String content, int statusCount) async {
    ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': agentId,
      'content': content,
      'session_id': TreeStore.defaultSessionId,
    });
    await ws.untilCount('agent_status', statusCount);
  }

  List<String> toolNames(LlmRequest request) => request.tools
      .map((LlmToolSpec spec) => spec.name)
      .toList(growable: false);

  test('每次发消息都重新取工具表：中途就绪的 MCP/插件工具下一轮立即可见', () async {
    final TestWs ws = await TestWs.connect(server);
    ws.record();
    addTearDown(ws.close);

    await sendTurn(ws, '第一轮', 2);
    expect(transport.requests.length, 1);
    expect(toolNames(transport.requests[0]), <String>['read']);
    final String firstPrompt = transport.requests[0].messages.first.content;

    await sendTurn(ws, '第二轮', 4);
    expect(transport.requests.length, 2);
    expect(
      toolNames(transport.requests[1]),
      contains('mcp__demo__ping'),
      reason: '工具表必须每次发消息重新取（不能被缓存/钉住）',
    );
    expect(
      tools.specsCalls,
      greaterThanOrEqualTo(2),
      reason: '每一轮都要真的问一次 ToolRunner',
    );
    expect(
      transport.requests[1].messages.first.content,
      firstPrompt,
      reason: '同时：系统提示词不中途重建',
    );
  });
}
