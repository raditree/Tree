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
    String contextSummary = '',
    int compactedMessageCount = 0,
  }) => AgentRunContext(
    agentId: 'agt_1',
    sessionId: 'ses_1',
    modelId: modelId,
    systemPrompt: systemPrompt,
    userContent: userContent,
    history: history,
    contextSummary: contextSummary,
    compactedMessageCount: compactedMessageCount,
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

    test('回传思考（thinking 开关开启）：历史思考挂到对应 assistant 消息上', () async {
      final CoreModelConfig thinkingModel = CoreModelConfig(
        modelId: 'demo',
        name: '思考模型',
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'sk-test',
        maxSeqlen: 64000,
        thinking: true,
      );
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('ok'),
      ]);
      await engine(transport, model: thinkingModel)
          .run(
            context(
              history: const <CoreMessageRef>[
                CoreMessageRef(
                  role: 'agent',
                  content: '先想一步',
                  kind: 'thinking',
                ),
                CoreMessageRef(role: 'agent', content: '上轮回答'),
                CoreMessageRef(
                  role: 'agent',
                  content: '再想一步',
                  kind: 'thinking',
                ),
                CoreMessageRef(
                  role: 'agent',
                  content: '',
                  kind: 'tool',
                  toolName: 'read_file',
                  toolArguments: <String, dynamic>{'path': 'a.txt'},
                  toolResult: 'A 的内容',
                  toolCallId: 'call_a',
                ),
              ],
            ),
            isCancelled: () => false,
          )
          .toList();
      final List<LlmMessage> sent = transport.requests.single.messages;
      // 普通 assistant 消息：reasoning_content 与 content 同级挂在它身上
      final LlmMessage answer = sent.firstWhere(
        (LlmMessage m) => m.content == '上轮回答',
      );
      expect(answer.reasoningContent, '先想一步');
      expect(answer.toWire()['reasoning_content'], '先想一步');
      expect(answer.toWire()['content'], '上轮回答');
      // 带 tool_calls 的那条 assistant 消息是引擎现拼的，也必须有它的思考
      final LlmMessage toolTurn = sent.firstWhere(
        (LlmMessage m) => m.toolCalls.isNotEmpty,
      );
      expect(
        toolTurn.reasoningContent,
        '再想一步',
        reason: 'DeepSeek 要求带 tools 的轮次原样回传 reasoning_content，缺失会 400',
      );
      expect(toolTurn.toWire()['reasoning_content'], '再想一步');
    });

    test('回传思考默认关闭：历史思考不出现在请求里', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('ok'),
      ]);
      await engine(transport)
          .run(
            context(
              history: const <CoreMessageRef>[
                CoreMessageRef(
                  role: 'agent',
                  content: '先想一步',
                  kind: 'thinking',
                ),
                CoreMessageRef(role: 'agent', content: '上轮回答'),
              ],
            ),
            isCancelled: () => false,
          )
          .toList();
      final List<LlmMessage> sent = transport.requests.single.messages;
      expect(sent.map((LlmMessage m) => m.reasoningContent), everyElement(''));
      expect(
        sent.every(
          (LlmMessage m) => !m.toWire().containsKey('reasoning_content'),
        ),
        isTrue,
        reason: '开关关闭时请求体里不该出现 reasoning_content',
      );
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

    test('压缩摘要作为第二条 system 消息注入，被总结的前缀不再发送', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('ok'),
      ]);
      await engine(transport)
          .run(
            context(
              history: const <CoreMessageRef>[
                CoreMessageRef(role: 'user', content: '早期需求'),
                CoreMessageRef(role: 'agent', content: '早期回答'),
                CoreMessageRef(role: 'user', content: '本轮问题'),
              ],
              contextSummary: '以下是此前对话的总结：用户想要 X',
              compactedMessageCount: 2,
            ),
            isCancelled: () => false,
          )
          .toList();
      final List<LlmMessage> sent = transport.requests.single.messages;
      expect(sent.first.content, '系统提示');
      expect(sent[1].role, LlmRole.system);
      expect(sent[1].content, contains('用户想要 X'));
      expect(sent.map((LlmMessage m) => m.content), isNot(contains('早期需求')));
      expect(sent.last.content, '本轮问题');
    });

    test('切点落在工具卡片上时，引擎把 tool_calls 补回来（序列依然合法）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('ok'),
      ]);
      await engine(transport)
          .run(
            context(
              history: const <CoreMessageRef>[
                CoreMessageRef(role: 'user', content: '早期需求'),
                CoreMessageRef(role: 'agent', content: '早期回答'),
                CoreMessageRef(
                  role: 'agent',
                  content: '',
                  kind: 'tool',
                  toolName: 'read_file',
                  toolArguments: <String, dynamic>{'path': 'a.txt'},
                  toolResult: 'A 的内容',
                  toolCallId: 'call_a',
                ),
                CoreMessageRef(role: 'user', content: '本轮问题'),
              ],
              contextSummary: '摘要：读过 a.txt',
              compactedMessageCount: 2,
            ),
            isCancelled: () => false,
          )
          .toList();
      final List<LlmMessage> sent = transport.requests.single.messages;
      final LlmMessage assistant = sent.firstWhere(
        (LlmMessage m) => m.toolCalls.isNotEmpty,
      );
      expect(assistant.toolCalls.single.name, 'read_file');
      expect(assistant.toolCalls.single.id, 'call_a');
      final LlmMessage result = sent.firstWhere(
        (LlmMessage m) => m.isToolResult,
      );
      expect(result.content, 'A 的内容');
      expect(result.toolCallId, 'call_a');
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

  group('工具结果门控与 token_scale 学习（Q1-①②）', () {
    test('历史里的超长工具结果在翻译时被门控（原文交给写入器）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('ok'),
      ]);
      final String huge = 'h' * 40000; // 20000 token > 8000 阈值
      final List<String> writes = <String>[];
      final LlmAgentEngine agentEngine = LlmAgentEngine(
        resolveModel: (String id) => id == config.modelId ? config : null,
        transportFactory: (CoreModelConfig c) => transport,
        resultRedirectWriter: (
          String agentId,
          String relativePath,
          String content,
        ) async => writes.add('$agentId|$relativePath|${content.length}'),
      );
      await agentEngine
          .run(
            context(
              history: <CoreMessageRef>[
                const CoreMessageRef(role: 'user', content: '读大文件'),
                CoreMessageRef(
                  role: 'agent',
                  content: '',
                  kind: 'tool',
                  toolName: 'read',
                  toolArguments: <String, dynamic>{'file_path': 'big.txt'},
                  toolResult: huge,
                  toolCallId: 'call_big',
                ),
                const CoreMessageRef(role: 'user', content: '继续'),
              ],
            ),
            isCancelled: () => false,
          )
          .toList();
      final LlmMessage forModel = transport.requests.single.messages.firstWhere(
        (LlmMessage m) => m.isToolResult,
      );
      expect(forModel.content, contains('[工具结果已重定向]'));
      expect(forModel.content, contains('40000 字符'));
      expect(forModel.content.length, lessThan(1000));
      expect(writes.single, startsWith('agt_1|.self/results/'));
      expect(writes.single, endsWith('|40000'));
      // tool_calls 与 tool 结果仍然严格配对
      expect(forModel.toolCallId, 'call_big');
    });

    test('真实 usage 学习 token_scale；内部字符数字段不上行', () async {
      final CoreModelConfig model = CoreModelConfig(
        modelId: 'demo',
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'sk-test',
        maxSeqlen: 64000,
      );
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        <LlmStreamEvent>[
          const LlmUsageEvent(
            LlmUsage(
              promptTokens: 2000,
              completionTokens: 5,
              totalTokens: 2005,
            ),
          ),
          const LlmFinishEvent('stop'),
        ],
      ]);
      final LlmAgentEngine agentEngine = LlmAgentEngine(
        resolveModel: (String id) => id == 'demo' ? model : null,
        transportFactory: (CoreModelConfig c) => transport,
      );
      final List<AgentEvent> events = await agentEngine
          .run(
            context(
              modelId: 'demo',
              systemPrompt: '',
              history: <CoreMessageRef>[
                CoreMessageRef(role: 'user', content: 'x' * 6000),
              ],
            ),
            isCancelled: () => false,
          )
          .toList();
      // 6000 字符 / 2000 token = 3.00
      expect(model.tokenScale, 3.0);
      expect(model.longestSessionTokens, 2000);
      final Map<String, dynamic> usage = events
          .whereType<AgentUsage>()
          .single
          .usage;
      expect(
        usage.containsKey(LlmSession.contextCharsKey),
        isFalse,
        reason: '内部学习字段必须剥掉，前端契约不变',
      );
      expect(usage['prompt_tokens'], 2000);
    });

    test('端点没给 usage：只读不写，不学习', () async {
      final CoreModelConfig model = CoreModelConfig(
        modelId: 'demo',
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'sk-test',
        maxSeqlen: 64000,
      );
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        <LlmStreamEvent>[
          const LlmTextDelta('ok'),
          const LlmFinishEvent('stop'),
        ],
      ]);
      final LlmAgentEngine agentEngine = LlmAgentEngine(
        resolveModel: (String id) => id == 'demo' ? model : null,
        transportFactory: (CoreModelConfig c) => transport,
      );
      final List<AgentEvent> events = await agentEngine
          .run(
            context(
              modelId: 'demo',
              history: <CoreMessageRef>[
                CoreMessageRef(role: 'user', content: 'x' * 6000),
              ],
            ),
            isCancelled: () => false,
          )
          .toList();
      expect(model.tokenScale, defaultTokenScale);
      expect(model.longestSessionTokens, 0);
      expect(
        (events.whereType<AgentUsage>().single).usage['estimated'],
        isTrue,
      );
    });
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
