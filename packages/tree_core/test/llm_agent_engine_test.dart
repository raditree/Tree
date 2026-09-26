import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

import 'fake_transport.dart';

void main() {
  final CoreModelConfig config = CoreModelConfig(
    modelId: 'demo',
    name: '演示',
    baseUrl: 'https://api.example.com/v1',
    apiKey: 'sk-test',
    maxSeqlen: 64000,
    maxOutputTokens: 512,
    reasoningEffort: 'high',
  );

  LlmAgentEngine engine(
    FakeTransport transport, {
    CoreModelConfig? model,
    ToolRunner? tools,
    List<String>? closedFlags,
  }) => LlmAgentEngine(
    resolveModel: (String id) =>
        id == (model?.modelId ?? config.modelId) ? (model ?? config) : null,
    toolRunner: tools ?? const EmptyToolRunner(),
    transportFactory: (CoreModelConfig c) => transport,
  );

  AgentRunContext context({
    String modelId = 'demo',
    String systemPrompt = '系统提示',
    String userContent = '你好',
    List<CoreMessageRef> history = const <CoreMessageRef>[
      CoreMessageRef(role: 'user', content: '你好'),
    ],
  }) => AgentRunContext(
    agentId: 'agt_1',
    sessionId: 'ses_1',
    modelId: modelId,
    systemPrompt: systemPrompt,
    userContent: userContent,
    history: history,
  );

  group('模型解析的报错必须可操作', () {
    test('未指定模型', () async {
      final List<AgentEvent> events = await engine(
        FakeTransport(<List<LlmStreamEvent>>[]),
      ).run(context(modelId: ''), isCancelled: () => false).toList();
      expect((events.first as AgentError).message, contains('尚未指定模型'));
      expect((events.first as AgentError).message, contains('设置'));
      expect(events.last, isA<AgentDone>());
    });

    test('模型配置不存在（例如被删了）', () async {
      final List<AgentEvent> events = await engine(
        FakeTransport(<List<LlmStreamEvent>>[]),
      ).run(context(modelId: 'gone'), isCancelled: () => false).toList();
      expect((events.first as AgentError).message, contains('模型配置不存在'));
    });

    test('缺少 base_url / api_key', () async {
      final List<AgentEvent> events = await engine(
        FakeTransport(<List<LlmStreamEvent>>[]),
        model: CoreModelConfig(modelId: 'demo', name: '缺密钥'),
      ).run(context(), isCancelled: () => false).toList();
      expect((events.first as AgentError).message, contains('base_url'));
    });
  });

  group('历史翻译', () {
    test('system 在最前，thinking 不回灌，空内容跳过', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('ok'),
      ]);
      await engine(transport)
          .run(
            context(
              history: const <CoreMessageRef>[
                CoreMessageRef(role: 'agent', content: '思考中', kind: 'thinking'),
                CoreMessageRef(role: 'user', content: '   '),
                CoreMessageRef(role: 'agent', content: '上轮回答'),
                CoreMessageRef(role: 'user', content: '本轮问题'),
              ],
            ),
            isCancelled: () => false,
          )
          .toList();
      final List<LlmMessage> sent = transport.requests.single.messages;
      expect(sent.first.role, LlmRole.system);
      expect(sent.first.content, '系统提示');
      expect(sent.map((LlmMessage m) => m.content).toList(), <String>[
        '系统提示',
        '上轮回答',
        '本轮问题',
      ]);
    });

    test('连续 tool 消息合并成一条 assistant(tool_calls) + 多条 tool 结果', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('ok'),
      ]);
      await engine(transport)
          .run(
            context(
              history: const <CoreMessageRef>[
                CoreMessageRef(role: 'user', content: '做两件事'),
                CoreMessageRef(
                  role: 'agent',
                  content: '',
                  kind: 'tool',
                  toolName: 'read_file',
                  toolArguments: <String, dynamic>{'path': 'a.txt'},
                  toolResult: 'A 的内容',
                  toolCallId: 'call_a',
                ),
                CoreMessageRef(
                  role: 'agent',
                  content: '',
                  kind: 'tool',
                  toolName: 'grep',
                  toolArguments: <String, dynamic>{'q': 'x'},
                  toolResult: '匹配 2 行',
                  toolCallId: 'call_b',
                ),
                CoreMessageRef(role: 'user', content: '继续'),
              ],
            ),
            isCancelled: () => false,
          )
          .toList();
      final List<LlmMessage> sent = transport.requests.single.messages;
      final LlmMessage assistant = sent.firstWhere(
        (LlmMessage m) => m.toolCalls.isNotEmpty,
      );
      expect(
        assistant.toolCalls.map((LlmToolCall c) => c.id).toList(),
        <String>['call_a', 'call_b'],
      );
      expect(assistant.toolCalls.first.name, 'read_file');
      expect(assistant.toolCalls.first.arguments, '{"path":"a.txt"}');
      final List<LlmMessage> results = sent
          .where((LlmMessage m) => m.isToolResult)
          .toList();
      expect(results.map((LlmMessage m) => m.toolCallId).toList(), <String>[
        'call_a',
        'call_b',
      ]);
      expect(results.map((LlmMessage m) => m.content).toList(), <String>[
        'A 的内容',
        '匹配 2 行',
      ]);
      // assistant 必须在对应 tool 结果之前
      expect(sent.indexOf(assistant), lessThan(sent.indexOf(results.first)));
    });

    test('结果缺失的工具调用补占位文本（避免 tool_calls 悬空导致端点 400）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('ok'),
      ]);
      await engine(transport)
          .run(
            context(
              history: const <CoreMessageRef>[
                CoreMessageRef(role: 'user', content: 'x'),
                CoreMessageRef(
                  role: 'agent',
                  content: '',
                  kind: 'tool',
                  toolName: 'read_file',
                  toolArguments: <String, dynamic>{'path': 'a.txt'},
                ),
              ],
            ),
            isCancelled: () => false,
          )
          .toList();
      final LlmMessage result = transport.requests.single.messages.firstWhere(
        (LlmMessage m) => m.isToolResult,
      );
      expect(result.content, contains('未完成'));
      expect(result.toolCallId, isNotEmpty);
    });

    test('模型参数被正确带进请求（max_tokens / reasoning_effort / 工具声明）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('ok'),
      ]);
      await engine(
        transport,
        tools: FakeToolRunner(
          specs: const <ToolSpec>[
            ToolSpec(name: 'read_file', description: '读文件'),
          ],
        ),
      ).run(context(), isCancelled: () => false).toList();
      final LlmRequest request = transport.requests.single;
      expect(request.model, 'demo');
      expect(request.maxOutputTokens, 512);
      expect(request.reasoningEffort, 'high');
      expect(request.tools.single.name, 'read_file');
      expect(request.tools.single.description, '读文件');
    });
  });

  test('close() 会关闭底层传输', () async {
    final _TrackingTransport transport = _TrackingTransport();
    final LlmAgentEngine agentEngine = LlmAgentEngine(
      resolveModel: (String id) => id == 'demo' ? config : null,
      transportFactory: (CoreModelConfig c) => transport,
    );
    await agentEngine.run(context(), isCancelled: () => false).toList();
    await agentEngine.close();
    expect(transport.closed, isTrue);
  });
}

/// 记录 close 的传输。
class _TrackingTransport implements LlmTransport {
  bool closed = false;

  @override
  Stream<LlmStreamEvent> stream(
    LlmRequest request, {
    bool Function()? isCancelled,
  }) async* {
    yield const LlmTextDelta('ok');
    yield const LlmFinishEvent('stop');
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
