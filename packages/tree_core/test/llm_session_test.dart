import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

import 'fake_transport.dart';

void main() {
  LlmSession session(
    FakeTransport transport, {
    ToolRunner? tools,
    int maxSeqlen = 128000,
    int? maxOutputTokens,
    int maxToolTurns = 24,
  }) => LlmSession(
    transport: transport,
    model: 'demo',
    toolRunner: tools ?? const EmptyToolRunner(),
    maxSeqlen: maxSeqlen,
    maxOutputTokens: maxOutputTokens,
    maxToolTurns: maxToolTurns,
  );

  Future<List<AgentEvent>> collect(Stream<AgentEvent> stream) =>
      stream.toList();

  group('纯文本生成', () {
    test('正文增量按序产出，最后以 finish_reason 结束', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('你好，世界！'),
      ]);
      final List<AgentEvent> events = await collect(
        session(transport).run(
          messages: <LlmMessage>[const LlmMessage.user('hi')],
          agentId: 'a',
          sessionId: 's',
          isCancelled: () => false,
        ),
      );
      final String text = events
          .whereType<AgentText>()
          .map((AgentText e) => e.delta)
          .join();
      expect(text, '你好，世界！');
      expect(events.whereType<AgentUsage>(), hasLength(1));
      expect((events.last as AgentDone).finishReason, 'stop');
      expect((events.last as AgentDone).cancelled, isFalse);
      expect(transport.turnsUsed, 1);
    });

    test('usage 映射符合前端口径（prompt=上下文长度，completion=累计）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('abc'),
      ]);
      final List<AgentEvent> events = await collect(
        session(transport).run(
          messages: <LlmMessage>[const LlmMessage.user('hi')],
          agentId: 'a',
          sessionId: 's',
          isCancelled: () => false,
        ),
      );
      final Map<String, dynamic> usage =
          (events.whereType<AgentUsage>().first).usage;
      expect(usage['prompt_tokens'], 100);
      expect(usage['completion_tokens'], 7);
      expect(usage['total_tokens'], 107);
      expect(usage['max_tokens'], 128000);
      expect(usage.containsKey('estimated'), isFalse);
    });

    test('端点没给 usage 时用本地估算并标注 estimated', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('你好你好', withUsage: false),
      ]);
      final List<AgentEvent> events = await collect(
        session(transport).run(
          messages: <LlmMessage>[const LlmMessage.user('你好吗')],
          agentId: 'a',
          sessionId: 's',
          isCancelled: () => false,
        ),
      );
      final Map<String, dynamic> usage =
          (events.whereType<AgentUsage>().first).usage;
      expect(usage['estimated'], isTrue);
      expect(usage['prompt_tokens'], greaterThan(0));
      expect(usage['completion_tokens'], greaterThan(0));
    });
  });

  group('工具循环', () {
    test('分片的工具调用被拼接、解析、执行并回灌', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        toolCallScript(
          name: 'read_file',
          arguments: '{"path":"a/b.txt","n":2}',
        ),
        textScript('读到了'),
      ]);
      final FakeToolRunner tools = FakeToolRunner(
        specs: const <ToolSpec>[
          ToolSpec(name: 'read_file', description: '读文件'),
        ],
        result: '文件内容',
      );
      final List<AgentEvent> events = await collect(
        session(transport, tools: tools).run(
          messages: <LlmMessage>[const LlmMessage.user('读 a/b.txt')],
          agentId: 'agt',
          sessionId: 'ses',
          isCancelled: () => false,
        ),
      );

      final AgentToolStart start = events.whereType<AgentToolStart>().single;
      expect(start.name, 'read_file');
      expect(start.arguments, <String, dynamic>{'path': 'a/b.txt', 'n': 2});
      expect(start.callId, 'call_1');
      final AgentToolEnd end = events.whereType<AgentToolEnd>().single;
      expect(end.result, '文件内容');
      expect(end.id, start.id);
      expect(
        events.whereType<AgentText>().map((AgentText e) => e.delta).join(),
        '读到了',
        reason: '工具跑完还要继续生成最终回答',
      );

      // 第二次请求必须带上 assistant 的 tool_calls 与配对的 tool 结果
      final List<LlmMessage> second = transport.requests[1].messages;
      final LlmMessage assistant = second.firstWhere(
        (LlmMessage m) => m.toolCalls.isNotEmpty,
      );
      expect(assistant.toolCalls.single.name, 'read_file');
      expect(assistant.toolCalls.single.id, 'call_1');
      final LlmMessage result = second.firstWhere(
        (LlmMessage m) => m.isToolResult,
      );
      expect(result.toolCallId, 'call_1');
      expect(result.content, '文件内容');

      // 工具收到的调用上下文
      expect(tools.invocations.single.agentId, 'agt');
      expect(tools.invocations.single.sessionId, 'ses');
      expect(tools.invocations.single.rawArguments, '{"path":"a/b.txt","n":2}');
      expect(events.last, isA<AgentDone>());
    });

    test('工具抛异常不中断本轮：回灌错误结果后继续', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        toolCallScript(name: 'boom', arguments: '{}'),
        textScript('兜住了'),
      ]);
      final List<AgentEvent> events = await collect(
        session(transport, tools: FakeToolRunner(shouldThrow: true)).run(
          messages: <LlmMessage>[const LlmMessage.user('x')],
          agentId: 'a',
          sessionId: 's',
          isCancelled: () => false,
        ),
      );
      expect(
        events.whereType<AgentToolEnd>().single.result,
        contains('工具执行异常'),
      );
      expect(
        events.whereType<AgentText>().map((AgentText e) => e.delta).join(),
        '兜住了',
      );
    });

    test('参数不是合法 JSON 时仍发卡片，arguments 为空 Map 且保留原文', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        toolCallScript(name: 'bad', arguments: '{不是 json'),
        textScript('ok'),
      ]);
      final FakeToolRunner tools = FakeToolRunner();
      final List<AgentEvent> events = await collect(
        session(transport, tools: tools).run(
          messages: <LlmMessage>[const LlmMessage.user('x')],
          agentId: 'a',
          sessionId: 's',
          isCancelled: () => false,
        ),
      );
      expect(events.whereType<AgentToolStart>().single.arguments, isEmpty);
      expect(tools.invocations.single.rawArguments, '{不是 json');
    });

    test('模型一直要工具时在轮次上限处中止并报错', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        for (int i = 0; i < 5; i++)
          toolCallScript(name: 'loop', arguments: '{}', callId: 'call_$i'),
      ]);
      final List<AgentEvent> events = await collect(
        session(
          transport,
          tools: FakeToolRunner(
            specs: const <ToolSpec>[ToolSpec(name: 'loop', description: 'l')],
          ),
          maxToolTurns: 3,
        ).run(
          messages: <LlmMessage>[const LlmMessage.user('x')],
          agentId: 'a',
          sessionId: 's',
          isCancelled: () => false,
        ),
      );
      expect(events.whereType<AgentToolStart>(), hasLength(3));
      expect(
        (events.whereType<AgentError>().single).message,
        contains('轮次超过上限'),
      );
      expect(events.last, isA<AgentDone>());
    });
  });

  group('失败与取消', () {
    test('传输失败 → AgentError + AgentDone（不再继续请求）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        <LlmStreamEvent>[
          const LlmTextDelta('半截'),
          const LlmFailureEvent(
            '模型端点返回 HTTP 401：invalid api key',
            statusCode: 401,
          ),
        ],
      ]);
      final List<AgentEvent> events = await collect(
        session(transport).run(
          messages: <LlmMessage>[const LlmMessage.user('x')],
          agentId: 'a',
          sessionId: 's',
          isCancelled: () => false,
        ),
      );
      expect((events.whereType<AgentError>().single).message, contains('401'));
      expect(events.last, isA<AgentDone>());
      expect(transport.turnsUsed, 1);
    });

    test('取消 → AgentDone(cancelled: true) 且不再产生请求', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('不会到这里'),
      ]);
      final List<AgentEvent> events = await collect(
        session(transport).run(
          messages: <LlmMessage>[const LlmMessage.user('x')],
          agentId: 'a',
          sessionId: 's',
          isCancelled: () => true,
        ),
      );
      expect(events, hasLength(1));
      expect((events.single as AgentDone).cancelled, isTrue);
      expect(transport.requests, isEmpty);
    });
  });

  group('上下文裁剪', () {
    test('超预算时按 user 边界裁掉最早的历史，并保证 tool 配对不被拆散', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('ok'),
      ]);
      final String longText = 'x' * 3000; // 约 750 token
      final List<LlmMessage> messages = <LlmMessage>[
        const LlmMessage.system('系统提示'),
        LlmMessage.user(longText),
        const LlmMessage.assistant('第一轮回答'),
        // 一组"工具调用 + 结果"（应与所属 user 轮一起被裁掉）
        const LlmMessage(
          role: LlmRole.assistant,
          toolCalls: <LlmToolCall>[
            LlmToolCall(id: 'call_x', name: 'read', arguments: '{}'),
          ],
        ),
        const LlmMessage.toolResult(content: '结果', toolCallId: 'call_x'),
        const LlmMessage.user('最后一轮问题'),
      ];
      final List<AgentEvent> events = await collect(
        session(transport, maxSeqlen: 1200, maxOutputTokens: 200).run(
          messages: messages,
          agentId: 'a',
          sessionId: 's',
          isCancelled: () => false,
        ),
      );
      final List<LlmMessage> sent = transport.requests.single.messages;
      expect(sent.first.role, LlmRole.system, reason: 'system 永不裁剪');
      expect(sent.last.content, '最后一轮问题', reason: '最新一轮永不裁剪');
      expect(sent.any((LlmMessage m) => m.content == longText), isFalse);
      expect(
        sent.any((LlmMessage m) => m.toolCalls.isNotEmpty),
        isFalse,
        reason: 'tool_calls 与其结果必须同进同出',
      );
      expect(sent.any((LlmMessage m) => m.isToolResult), isFalse);
      expect(
        (events.whereType<AgentUsage>().single).usage['trimmed_messages'],
        greaterThan(0),
      );
    });

    test('预算足够时不裁剪', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('ok'),
      ]);
      await collect(
        session(transport).run(
          messages: <LlmMessage>[
            const LlmMessage.user('短'),
            const LlmMessage.assistant('也短'),
            const LlmMessage.user('最后'),
          ],
          agentId: 'a',
          sessionId: 's',
          isCancelled: () => false,
        ),
      );
      expect(transport.requests.single.messages, hasLength(3));
    });
  });
}
