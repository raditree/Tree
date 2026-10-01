import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

import 'fake_transport.dart';
import 'ws_harness.dart';

/// 端到端（真实 HTTP + 真实 WebSocket，只有 LLM 传输层是假的）：
/// 前端把附件上传到工作空间后发 `user_message`（attachments = 工作空间相对路径），
/// 核心要**落库**并把这些路径**写进发给模型的提示词**。
///
/// 这是本功能的验收口径：光"UI 上有卡片"不算生效，模型必须在请求里看到路径。
void main() {
  late CoreServer server;
  late String agentId;

  Future<void> startWith(FakeTransport transport) async {
    final CoreSettings settings = CoreSettings();
    settings.createModel(<String, dynamic>{
      'model_id': 'demo',
      'name': '演示模型',
      'base_url': 'https://api.example.com/v1',
      'api_key': 'sk-test',
      'max_seqlen': 64000,
    });
    server = await CoreServer.start(
      streamChunkDelay: Duration.zero,
      enableHeartbeat: false,
      settings: settings,
      engine: LlmAgentEngine(
        resolveModel: settings.model,
        toolRunner: const EmptyToolRunner(),
        transportFactory: (CoreModelConfig config) => transport,
      ),
    );
    agentId = server.store
        .createAgent(name: '附件端到端', systemPrompt: '你是助手', modelId: 'demo')
        .id;
  }

  tearDown(() async {
    await server.close();
  });

  Future<TestWs> send(Object? attachments, {String content = '看这张图'}) async {
    final TestWs ws = await TestWs.connect(server);
    ws.record();
    addTearDown(ws.close);
    ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': agentId,
      'content': content,
      'session_id': TreeStore.defaultSessionId,
      'attachments': attachments,
    });
    await waitIdle(ws);
    return ws;
  }

  test('带附件的消息：落库保留路径，且请求体里告诉模型附件在哪', () async {
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      textScript('好的'),
    ]);
    await startWith(transport);

    await send(<dynamic>[
      <String, dynamic>{
        'name': '图片.png',
        'path': '.input/20261001/图片.png',
        'size': 2048,
        'type': 'png',
      },
    ]);

    // ① 落库：附件元数据完整保留（重启后 UI 与上下文都还在）
    final CoreMessage userMessage = server.store
        .messages(agentId, TreeStore.defaultSessionId)
        .firstWhere((CoreMessage m) => m.role == 'user');
    expect(userMessage.attachments, hasLength(1));
    expect(userMessage.attachments!.single['path'], '.input/20261001/图片.png');

    // ② 发给模型的请求：路径与说明段都在（这就是"附件真正生效"的判据）
    final LlmMessage sent = transport.requests.single.messages.last;
    expect(sent.role, LlmRole.user);
    expect(sent.content, contains('看这张图'));
    expect(sent.content, contains('.input/20261001/图片.png'));
    expect(sent.content, contains('相对工作空间根'));
  });

  test('只有附件、正文为空：消息照样到模型（不被整条丢掉）', () async {
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      textScript('我看到你发的文件了'),
    ]);
    await startWith(transport);

    await send(<dynamic>[
      <String, dynamic>{'name': 'b.txt', 'path': '.input/20261001/b.txt'},
    ], content: '');

    expect(
      transport.requests.single.messages.where(
        (LlmMessage m) => m.role == LlmRole.user,
      ),
      hasLength(1),
    );
    expect(
      transport.requests.single.messages.last.content,
      contains('.input/20261001/b.txt'),
    );
  });

  test('没有附件：请求体与改动前一致（不注入附件段）', () async {
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      textScript('好的'),
    ]);
    await startWith(transport);

    await send(null, content: '普通消息');

    expect(transport.requests.single.messages.last.content, '普通消息');
  });
}
