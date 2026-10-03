import 'dart:convert';

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
    List<Map<String, dynamic>> compactedContext = const <Map<String, dynamic>>[],
  }) => AgentRunContext(
    agentId: 'agt_1',
    sessionId: 'ses_1',
    modelId: modelId,
    systemPrompt: systemPrompt,
    userContent: userContent,
    history: history,
    contextSummary: contextSummary,
    compactedMessageCount: compactedMessageCount,
    compactedContext: compactedContext,
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

  group('自动修复：结果永远拿不到的工具卡（把关处）', () {
    const String agentId = 'agt_1';
    const String sessionId = 'ses_1';

    /// 造一张"结果永远拿不到"的工具卡（取消 / 异常 / 重启时就是这种落库形态）。
    MemoryStore storeWithFailedTool({
      String toolResult = '',
      String toolCallId = 'call_x',
    }) {
      final MemoryStore store = MemoryStore();
      store.appendMessage(
        CoreMessage(
          id: 'tool_failed',
          agentId: agentId,
          sessionId: sessionId,
          role: 'agent',
          content: '',
          timestamp: 10,
          kind: 'tool',
          toolName: 'grep',
          toolCallId: toolCallId,
          toolArguments: <String, dynamic>{'pattern': 'x'},
          toolResult: toolResult,
          toolResultForModel: toolResult,
        ),
      );
      return store;
    }

    List<CoreMessageRef> historyWithFailedTool() => <CoreMessageRef>[
      const CoreMessageRef(role: 'user', content: '做点事'),
      const CoreMessageRef(
        role: 'agent',
        content: '',
        kind: 'tool',
        toolName: 'grep',
        toolCallId: 'call_x',
        toolArguments: <String, dynamic>{'pattern': 'x'},
      ),
      const CoreMessageRef(role: 'user', content: '本轮问题'),
    ];

    test('空结果 ⇒ 写回落库那份，并且本次请求用的就是失败信息', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('ok'),
      ]);
      final MemoryStore store = storeWithFailedTool();
      final List<String> asked = <String>[];
      final LlmAgentEngine e = engine(transport)
        ..toolResultRepair =
            ({
              required String agentId,
              required String sessionId,
              required String toolCallId,
              required String toolName,
              required String result,
            }) async {
              asked.add('$toolCallId|$toolName');
              return store.repairToolResult(
                agentId,
                sessionId,
                toolCallId,
                toolResult: result,
                toolResultForModel: result,
              );
            };

      await e
          .run(
            context(userContent: '本轮问题', history: historyWithFailedTool()),
            isCancelled: () => false,
          )
          .toList();

      expect(asked, <String>['call_x|grep']);
      expect(
        store.sessionMessages(agentId, sessionId).last.toolResult,
        contains('【自动修复】'),
        reason: '落库那份要真的被修好（不是只在送模型那份补一句）',
      );
      final LlmMessage tool = transport.requests.single.messages.firstWhere(
        (LlmMessage m) => m.role == LlmRole.tool,
      );
      expect(tool.content, contains('【自动修复】'));
      expect(
        tool.content,
        isNot(contains('(该工具调用未完成')),
        reason: '不再是以前那句临时占位',
      );
    });

    test('已有结果的卡不动；未接线时退回老占位（落库那份不动）', () async {
      // 已有结果：不该麻烦修复落点
      final FakeTransport withResult = FakeTransport(<List<LlmStreamEvent>>[
        textScript('ok'),
      ]);
      int calls = 0;
      final LlmAgentEngine e1 = engine(withResult)
        ..toolResultRepair =
            ({
              required String agentId,
              required String sessionId,
              required String toolCallId,
              required String toolName,
              required String result,
            }) async {
              calls++;
              return true;
            };
      await e1
          .run(
            context(
              userContent: '本轮问题',
              history: <CoreMessageRef>[
                const CoreMessageRef(
                  role: 'agent',
                  content: '',
                  kind: 'tool',
                  toolName: 'grep',
                  toolCallId: 'call_ok',
                  toolResult: '工具结果在此',
                  toolResultForModel: '工具结果在此',
                ),
                const CoreMessageRef(role: 'user', content: '本轮问题'),
              ],
            ),
            isCancelled: () => false,
          )
          .toList();
      expect(calls, 0);
      final LlmMessage ok = withResult.requests.single.messages.firstWhere(
        (LlmMessage m) => m.role == LlmRole.tool,
      );
      expect(ok.content, '工具结果在此');

      // 未接线：老行为——送模型那份给占位（落库那份没人改）
      final FakeTransport unwired = FakeTransport(<List<LlmStreamEvent>>[
        textScript('ok'),
      ]);
      await engine(unwired)
          .run(
            context(userContent: '本轮问题', history: historyWithFailedTool()),
            isCancelled: () => false,
          )
          .toList();
      final LlmMessage placeholder = unwired.requests.single.messages
          .firstWhere((LlmMessage m) => m.role == LlmRole.tool);
      expect(placeholder.content, contains('(该工具调用未完成'));
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

    test('wireRequestFor：与 run 真会发的那一份逐字一致（messages / tools / 参数）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('ok'),
      ]);
      final LlmAgentEngine instance = engine(
        transport,
        tools: FakeToolRunner(
          specs: const <ToolSpec>[
            ToolSpec(name: 'read_file', description: '读文件'),
          ],
        ),
      );
      final AgentRunContext ctx = context(
        history: const <CoreMessageRef>[
          CoreMessageRef(role: 'user', content: '第一轮要求'),
          CoreMessageRef(role: 'agent', content: '第一轮回答'),
          CoreMessageRef(role: 'user', content: '本轮问题'),
        ],
      );
      await instance.run(ctx, isCancelled: () => false).toList();
      final Map<String, dynamic> sent = transport.requests.single.toWire();
      final Map<String, dynamic>? wire = await instance.wireRequestFor(ctx);
      expect(wire, isNotNull);
      expect(
        wire!['messages'],
        sent['messages'],
        reason: '压缩前缀必须与对话那一轮逐字一致，否则端点缓存单元命中不了',
      );
      expect(wire['tools'], sent['tools'], reason: '工具声明是前缀对齐的另一半');
      expect(wire['model'], sent['model']);
      expect(wire['max_tokens'], sent['max_tokens']);
      expect(wire['reasoning_effort'], sent['reasoning_effort']);
    });

    test('wireRequestFor：模型没配 / 没密钥时返回 null（插件据此不接管）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[]);
      final LlmAgentEngine noModel = engine(transport, model: null);
      expect(
        await noModel.wireRequestFor(context(modelId: 'gone')),
        isNull,
      );
      final LlmAgentEngine noKey = engine(
        transport,
        model: CoreModelConfig(modelId: 'demo', name: '缺密钥'),
      );
      expect(await noKey.wireRequestFor(context()), isNull);
    });

    test('wireRequestFor：预算硬裁后仍与实发请求逐字一致（缓存前缀必须同口径）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('ok'),
      ]);
      // 窗口刻意调小，让"预算硬裁"真的动手（budget = 6000 − 256 − 512）
      final CoreModelConfig small = CoreModelConfig(
        modelId: 'demo',
        name: '小窗口',
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'sk-test',
        maxSeqlen: 6000,
        maxOutputTokens: 256,
      );
      final LlmAgentEngine instance = engine(transport, model: small);
      // 每条 2000 字符（≈1000 token @ token_scale 2.0）⇒ 总量必然超预算 5232
      final String filler = '冗' * 2000;
      final List<CoreMessageRef> history = <CoreMessageRef>[
        CoreMessageRef(role: 'user', content: '第一轮要求：$filler'),
        CoreMessageRef(role: 'agent', content: '第一轮回答：$filler'),
        CoreMessageRef(role: 'user', content: '第二轮要求：$filler'),
        CoreMessageRef(role: 'agent', content: '第二轮回答：$filler'),
        CoreMessageRef(role: 'user', content: '第三轮要求：$filler'),
        CoreMessageRef(role: 'agent', content: '第三轮回答：$filler'),
        CoreMessageRef(role: 'user', content: '本轮问题'),
      ];
      final AgentRunContext ctx = context(history: history);
      final List<AgentEvent> events = await instance
          .run(ctx, isCancelled: () => false)
          .toList();
      final AgentUsage usage = events.whereType<AgentUsage>().first;
      expect(
        usage.usage['trimmed_messages'],
        greaterThan(0),
        reason: '这个用例必须真的触发硬裁，否则断言的是"没裁也一样"',
      );

      final List<Object?> sent =
          transport.requests.single.toWire()['messages']! as List<Object?>;
      final Map<String, dynamic>? wire = await instance.wireRequestFor(ctx);
      expect(wire, isNotNull);
      expect(
        wire!['messages'],
        sent,
        reason: '硬裁路径上前缀也必须与实发请求逐字一致（否则那段缓存命中不了）',
      );
      expect(
        jsonEncode(sent),
        isNot(contains('第一轮要求')),
        reason: '最早那一轮确实被裁掉了（用例前提）',
      );
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

    test('中转站上下文是基底：摘要在内、水位线之后继续追加，首条提示词被刷新', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('ok'),
      ]);
      await engine(transport)
          .run(
            context(
              // 内置路径的两样东西即使都在，也必须被中转站的列表压过去
              contextSummary: '内置摘要：不该出现',
              compactedMessageCount: 2,
              history: const <CoreMessageRef>[
                CoreMessageRef(role: 'user', content: '早期需求'),
                CoreMessageRef(role: 'agent', content: '早期回答'),
                CoreMessageRef(role: 'user', content: '本轮问题'),
              ],
              compactedContext: const <Map<String, dynamic>>[
                <String, dynamic>{
                  'role': 'system',
                  'content': '插件压缩时的旧提示词（必须被刷新掉）',
                },
                <String, dynamic>{'role': 'system', 'content': '插件产出的摘要'},
                <String, dynamic>{'role': 'user', 'content': '插件保留的最近原文'},
              ],
            ),
            isCancelled: () => false,
          )
          .toList();
      final List<LlmMessage> sent = transport.requests.single.messages;
      final List<String> texts = sent
          .map((LlmMessage m) => m.content)
          .toList(growable: false);
      expect(
        texts.first,
        '系统提示',
        reason: '首条 system 是**提示词槽位**：核心用最新那份覆盖它',
      );
      expect(texts, isNot(contains('插件压缩时的旧提示词（必须被刷新掉）')));
      expect(texts[1], '插件产出的摘要', reason: '摘要段原样保留');
      expect(texts[2], '插件保留的最近原文');
      expect(texts, isNot(contains('内置摘要：不该出现')));
      expect(texts, isNot(contains('早期需求')), reason: '水位线之后的原文继续追加');
      expect(texts.last, '本轮问题');
    });

    test('中转站上下文：首条不是 system ⇒ 前置一条；prompt.system 中转照常生效', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('ok'),
      ]);
      final LlmAgentEngine instance = engine(transport);
      instance.systemPromptRelay =
          ({
            required AgentRunContext context,
            required String defaultPrompt,
          }) async => '插件改写后的系统提示词';
      await instance
          .run(
            context(
              compactedMessageCount: 1,
              history: const <CoreMessageRef>[
                CoreMessageRef(role: 'user', content: '旧'),
                CoreMessageRef(role: 'user', content: '本轮问题'),
              ],
              // 插件没放提示词槽位（列表以非 system 开头）⇒ 核心在最前补一条
              compactedContext: const <Map<String, dynamic>>[
                <String, dynamic>{'role': 'user', 'content': '插件保留的最近原文'},
              ],
            ),
            isCancelled: () => false,
          )
          .toList();
      final List<LlmMessage> sent = transport.requests.single.messages;
      expect(sent.first.role, LlmRole.system);
      expect(
        sent.first.content,
        '插件改写后的系统提示词',
        reason: '槽位刷新走的是 prompt.system 中转（不是内置拼装结果）',
      );
      expect(sent[1].content, '插件保留的最近原文');
      expect(sent.last.content, '本轮问题');
    });

    test('中转站上下文：prompt.system 回空串 ⇒ 删掉槽位（不留过期提示词）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('ok'),
      ]);
      final LlmAgentEngine instance = engine(transport);
      instance.systemPromptRelay =
          ({
            required AgentRunContext context,
            required String defaultPrompt,
          }) async => '';
      await instance
          .run(
            context(
              compactedMessageCount: 1,
              history: const <CoreMessageRef>[
                CoreMessageRef(role: 'user', content: '旧'),
                CoreMessageRef(role: 'user', content: '本轮问题'),
              ],
              compactedContext: const <Map<String, dynamic>>[
                <String, dynamic>{'role': 'system', 'content': '插件压缩时的旧提示词'},
                <String, dynamic>{'role': 'system', 'content': '插件产出的摘要'},
              ],
            ),
            isCancelled: () => false,
          )
          .toList();
      final List<LlmMessage> sent = transport.requests.single.messages;
      expect(
        sent.map((LlmMessage m) => m.content),
        isNot(contains('插件压缩时的旧提示词')),
      );
      expect(sent.first.content, '插件产出的摘要');
      expect(sent.first.role, LlmRole.system);
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
