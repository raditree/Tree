import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

import 'fake_transport.dart';
import 'ws_harness.dart';

/// M4 验收：**真实文件系统**上的工具循环。
///
/// 只有 LLM 传输层是假的（脚本说"先调 read，再给最终回答"），工具执行、
/// 工作空间解析、文件读写、结果回灌、落库全部是真的。
void main() {
  late Directory dataDir;
  late Directory workspace;
  late CoreServer server;
  late CoreSettings settings;
  late String agentId;
  late FakeTransport transport;

  Future<void> start({
    required List<List<LlmStreamEvent>> script,
    String? workspaceDir,
  }) async {
    transport = FakeTransport(script);
    settings = CoreSettings();
    settings.createModel(<String, dynamic>{
      'model_id': 'demo',
      'base_url': 'https://api.example.com/v1',
      'api_key': 'sk-test',
      'max_seqlen': 64000,
    });
    final WorkspaceToolRunner tools = WorkspaceToolRunner(
      resolveWorkspaceDir: (String id) {
        final String configured = server.store.agent(id)?.workspaceDir ?? '';
        return configured.isNotEmpty ? configured : workspace.path;
      },
    );
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
    final CoreAgent agent = server.store.createAgent(
      name: '工具用例',
      systemPrompt: '你是助手',
      modelId: 'demo',
    );
    agentId = agent.id;
    if (workspaceDir != null) {
      server.store.agent(agentId)!.workspaceDir = workspaceDir;
    }
  }

  setUp(() {
    dataDir = Directory.systemTemp.createTempSync('tree_tool_loop_');
    workspace = Directory(p.join(dataDir.path, 'workspace'))
      ..createSync(recursive: true);
    final File notes = File(p.join(workspace.path, 'notes', 'hello.txt'));
    notes.parent.createSync(recursive: true);
    notes.writeAsStringSync('M4 工具层已接通\n第二行');
  });

  tearDown(() async {
    await server.close();
    if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
  });

  test('模型请求 read → 核心真实读文件 → 结果回灌 → 第二轮给出回答', () async {
    await start(
      script: <List<LlmStreamEvent>>[
        toolCallScript(
          name: 'read',
          arguments: '{"file_path":"notes/hello.txt"}',
        ),
        textScript('文件内容是：M4 工具层已接通'),
      ],
    );
    final TestWs ws = await TestWs.connect(server);
    ws.record();
    addTearDown(ws.close);

    ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': agentId,
      'content': '看看 notes/hello.txt',
      'session_id': TreeStore.defaultSessionId,
    });
    await waitIdle(ws);

    final Map<String, dynamic> toolStart = ws.frames.firstWhere(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.toolStart,
    );
    expect(toolStart['name'], 'read');
    expect(
      (toolStart['arguments'] as Map<String, dynamic>)['file_path'],
      'notes/hello.txt',
    );
    final Map<String, dynamic> toolEnd = ws.frames.firstWhere(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.toolEnd,
    );
    expect(toolEnd['result'], contains('M4 工具层已接通'));
    expect(toolEnd['result'], contains('第二行'));

    final String textId =
        ws.frames.firstWhere(
              (Map<String, dynamic> f) =>
                  f['type'] == WsOutboundType.msgStart && f['kind'] == 'text',
            )['id']
            as String;
    final String text = ws.frames
        .where(
          (Map<String, dynamic> f) =>
              f['type'] == WsOutboundType.msgChunk && f['id'] == textId,
        )
        .map((Map<String, dynamic> f) => f['chunk'] as String)
        .join();
    expect(text, '文件内容是：M4 工具层已接通');

    // 第二次请求带上了真实文件内容（工具结果回灌）
    final List<LlmMessage> second = transport.requests[1].messages;
    final LlmMessage result = second.firstWhere(
      (LlmMessage m) => m.isToolResult,
    );
    expect(result.content, contains('M4 工具层已接通'));
    expect(result.toolCallId, 'call_1');

    // 落库：user → tool 卡片（带结果与 call id）→ 最终文本
    final List<CoreMessage> stored = server.store.messages(
      agentId,
      TreeStore.defaultSessionId,
    );
    expect(stored.map((CoreMessage m) => m.kind).toList(), <String>[
      'text',
      'tool',
      'text',
    ]);
    expect(stored[1].toolName, 'read');
    expect(stored[1].toolResult, contains('第二行'));
    expect(stored[1].toolCallId, 'call_1');
    expect(stored[2].content, '文件内容是：M4 工具层已接通');
  });

  test('模型给的工作空间外路径：工具回报错误但不崩，模型据此纠正', () async {
    await start(
      script: <List<LlmStreamEvent>>[
        toolCallScript(
          name: 'read',
          arguments: '{"file_path":"../../etc/passwd"}',
        ),
        textScript('路径被拒绝了，我改用相对路径'),
      ],
    );
    final TestWs ws = await TestWs.connect(server);
    ws.record();
    addTearDown(ws.close);
    ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': agentId,
      'content': '读一下系统文件',
      'session_id': TreeStore.defaultSessionId,
    });
    await waitIdle(ws);

    final Map<String, dynamic> toolEnd = ws.frames.firstWhere(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.toolEnd,
    );
    expect(toolEnd['result'], contains('路径不合法'));
    final List<LlmMessage> second = transport.requests[1].messages;
    expect(
      second.firstWhere((LlmMessage m) => m.isToolResult).content,
      contains('路径不合法'),
    );
  });

  test('agent 配置的 workspace_dir 生效（工具在指定目录里干活）', () async {
    final Directory custom = Directory(p.join(dataDir.path, 'my-project'))
      ..createSync(recursive: true);
    File(p.join(custom.path, 'README.md')).writeAsStringSync('项目说明');
    await start(
      script: <List<LlmStreamEvent>>[
        toolCallScript(name: 'read', arguments: '{"file_path":"README.md"}'),
        textScript('读到了'),
      ],
      workspaceDir: custom.path,
    );
    final TestWs ws = await TestWs.connect(server);
    ws.record();
    addTearDown(ws.close);
    ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': agentId,
      'content': '读 README',
      'session_id': TreeStore.defaultSessionId,
    });
    await waitIdle(ws);

    final Map<String, dynamic> toolEnd = ws.frames.firstWhere(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.toolEnd,
    );
    expect(
      toolEnd['result'],
      contains('项目说明'),
      reason: '应读 workspace_dir（my-project）而不是默认工作空间',
    );
  });

  test('超长工具结果：完整结果落 .self/results，送模型的是提示，落库仍是全文', () async {
    final String big = 'x' * 20000; // 20000 字符 = 10000 token > 8000 阈值
    File(p.join(workspace.path, 'big.txt')).writeAsStringSync(big);
    await start(
      script: <List<LlmStreamEvent>>[
        toolCallScript(name: 'read', arguments: '{"file_path":"big.txt"}'),
        textScript('读完了'),
      ],
    );
    final TestWs ws = await TestWs.connect(server);
    ws.record();
    addTearDown(ws.close);
    ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': agentId,
      'content': '看看 big.txt',
      'session_id': TreeStore.defaultSessionId,
    });
    await waitIdle(ws);

    // 前端卡片拿到的仍是完整结果（门控只替换送模型的那一份）
    final Map<String, dynamic> toolEnd = ws.frames.firstWhere(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.toolEnd,
    );
    expect((toolEnd['result'] as String).length, greaterThan(16000));

    // 送模型的那一份：重定向提示 + 工作空间相对路径
    final LlmMessage forModel = transport.requests[1].messages.firstWhere(
      (LlmMessage m) => m.isToolResult,
    );
    expect(forModel.content, contains('[工具结果已重定向]'));
    final RegExpMatch? match = RegExp(
      r'\.self/results/read_[0-9a-f]{16}\.result',
    ).firstMatch(forModel.content);
    expect(match, isNotNull, reason: '提示里必须带上重定向文件的相对路径');

    // 工作空间里真的有这份文件（**按 agent 分栏**：`.self/…` → `.tree/<agent_id>/.self/…`），
    // 且内容完整。
    final String diskRelative = match!.group(0)!.replaceFirst(
      '.self/',
      '.tree/$agentId/.self/',
    );
    final File redirect = File(
      p.joinAll(<String>[workspace.path, ...diskRelative.split('/')]),
    );
    expect(redirect.existsSync(), isTrue, reason: '重定向文件必须真写进工作空间');
    expect(redirect.readAsStringSync(), contains(big));

    // 落库同样保留全文
    final List<CoreMessage> stored = server.store.messages(
      agentId,
      TreeStore.defaultSessionId,
    );
    expect(stored[1].toolResult.length, greaterThan(16000));
  });
}