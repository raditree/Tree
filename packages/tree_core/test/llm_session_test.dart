import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

import 'fake_transport.dart';

void main() {
  LlmSession session(
    FakeTransport transport, {
    ToolRunner? tools,
    int maxSeqlen = 128000,
    int? maxOutputTokens,
    double tokenScale = defaultTokenScale,
    ToolResultGate? gate,
    Future<List<LlmMessage>?> Function({required bool force})? compact,
  }) => LlmSession(
    transport: transport,
    model: 'demo',
    toolRunner: tools ?? const EmptyToolRunner(),
    maxSeqlen: maxSeqlen,
    maxOutputTokens: maxOutputTokens,
    tokenScale: tokenScale,
    resultGate: gate,
    compactContext: compact,
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

    test('不再有轮次上限（Q8）：模型一直要工具就一直跑，直到给出最终文本', () async {
      const int rounds = 30;
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        for (int i = 0; i < rounds; i++)
          toolCallScript(name: 'loop', arguments: '{}', callId: 'call_$i'),
        textScript('终于收工'),
      ]);
      final List<AgentEvent> events = await collect(
        session(
          transport,
          tools: FakeToolRunner(
            specs: const <ToolSpec>[ToolSpec(name: 'loop', description: 'l')],
          ),
        ).run(
          messages: <LlmMessage>[const LlmMessage.user('x')],
          agentId: 'a',
          sessionId: 's',
          isCancelled: () => false,
        ),
      );
      expect(events.whereType<AgentToolStart>(), hasLength(rounds));
      expect(events.whereType<AgentError>(), isEmpty);
      expect(
        events.whereType<AgentText>().map((AgentText e) => e.delta).join(),
        '终于收工',
      );
      expect(transport.turnsUsed, rounds + 1);
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

  group('超长工具结果门控（Q1-②）', () {
    ToolResultGate gate({
      required Future<void> Function(
        String agentId,
        String path,
        String content,
      )
      write,
    }) => ToolResultGate(
      agentId: 'agt',
      thresholdTokens: 800,
      writer: write,
    );

    Future<List<AgentEvent>> runWith(
      FakeTransport transport, {
      required String result,
      required ToolResultGate resultGate,
    }) => collect(
      session(
        transport,
        tools: FakeToolRunner(result: result),
        gate: resultGate,
      ).run(
        messages: <LlmMessage>[const LlmMessage.user('x')],
        agentId: 'agt',
        sessionId: 's',
        isCancelled: () => false,
      ),
    );

    test('超阈值：完整结果落文件，卡片仍是全文，送模型的是提示', () async {
      final String huge = 'x' * 4000; // 4000 字符 @2.0 = 2000 token > 800
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        toolCallScript(name: 'read', arguments: '{}'),
        textScript('继续'),
      ]);
      final List<String> writes = <String>[];
      final List<AgentEvent> events = await runWith(
        transport,
        result: huge,
        resultGate: gate(
          write: (String agentId, String path, String content) async =>
              writes.add('$agentId|$path|${content.length}'),
        ),
      );
      // 界面/落库：完整结果（AgentToolEnd）
      expect(events.whereType<AgentToolEnd>().single.result, huge);
      // 文件：完整原文 + 约定路径
      final String path =
          '.self/results/read_${ToolResultGate.fingerprint('read', huge)}.result';
      expect(writes.single, 'agt|$path|4000');
      // 模型：提示 + 前 300 字符预览
      final LlmMessage forModel = transport.requests[1].messages.firstWhere(
        (LlmMessage m) => m.isToolResult,
      );
      expect(forModel.content, contains('[工具结果已重定向]'));
      expect(forModel.content, contains('4000 字符'));
      expect(forModel.content, contains(path));
      expect(forModel.content, contains(huge.substring(0, 300)));
      expect(forModel.content, contains('read'));
      expect(forModel.content.length, lessThan(1000));
    });

    test('未超阈值：模型拿到的仍是原文，也不落文件', () async {
      final String small = 'x' * 100;
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        toolCallScript(name: 'read', arguments: '{}'),
        textScript('继续'),
      ]);
      int writes = 0;
      await runWith(
        transport,
        result: small,
        resultGate: gate(
          write: (String a, String p, String c) async => writes++,
        ),
      );
      expect(writes, 0);
      expect(
        transport.requests[1].messages
            .firstWhere((LlmMessage m) => m.isToolResult)
            .content,
        small,
      );
    });

    test('写入失败 → 退化为按阈值截断（上下文必须有界）', () async {
      final String huge = 'y' * 4000;
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        toolCallScript(name: 'read', arguments: '{}'),
        textScript('继续'),
      ]);
      final List<AgentEvent> events = await runWith(
        transport,
        result: huge,
        resultGate: gate(
          write: (String a, String p, String c) async =>
              throw StateError('磁盘满了'),
        ),
      );
      expect(events.whereType<AgentToolEnd>().single.result, huge);
      final String forModel = transport.requests[1].messages
          .firstWhere((LlmMessage m) => m.isToolResult)
          .content;
      expect(
        forModel,
        startsWith('y' * 1600),
        reason: '800 token × 2.0 = 1600 字符',
      );
      expect(forModel, contains('已截断至'));
      expect(forModel.length, lessThan(huge.length));
    });
  });

  group('工具循环内压缩与超限重试（Q1-③）', () {
    test('每轮 API 调用前问一次压缩钩子；压动后重建的上下文不丢在途工具轨迹', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        toolCallScript(name: 'noop', arguments: '{}'),
        textScript('done'),
      ]);
      final List<bool> asks = <bool>[];
      int turn = 0;
      final List<AgentEvent> events = await collect(
        session(
          transport,
          tools: FakeToolRunner(
            specs: const <ToolSpec>[ToolSpec(name: 'noop', description: 'n')],
          ),
          compact: ({required bool force}) async {
            asks.add(force);
            turn++;
            // 第二轮才"压动"（模拟工具轨迹把上下文顶过阈值）：压完给一份新的基础上下文
            if (turn < 2) return null;
            return <LlmMessage>[const LlmMessage.system('摘要后的基础上下文')];
          },
        ).run(
          messages: <LlmMessage>[const LlmMessage.user('x')],
          agentId: 'a',
          sessionId: 's',
          isCancelled: () => false,
        ),
      );
      expect(asks, <bool>[false, false], reason: '每轮各问一次，都不是强制压缩');
      final List<LlmMessage> second = transport.requests[1].messages;
      expect(second.first.content, '摘要后的基础上下文');
      expect(
        second.any((LlmMessage m) => m.toolCalls.isNotEmpty),
        isTrue,
        reason: '在途的 tool_calls 不能因为重建上下文而丢',
      );
      expect(
        second.any((LlmMessage m) => m.isToolResult),
        isTrue,
        reason: '在途的工具结果不能因为重建上下文而丢',
      );
      expect(
        events.whereType<AgentText>().map((AgentText e) => e.delta).join(),
        'done',
      );
    });

    test('端点报上下文超限：强制压缩一次并重试该轮', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        <LlmStreamEvent>[
          const LlmFailureEvent(
            'maximum context length is 8192 tokens',
            statusCode: 400,
          ),
        ],
        textScript('压缩后成功'),
      ]);
      final List<bool> forces = <bool>[];
      final List<AgentEvent> events = await collect(
        session(
          transport,
          compact: ({required bool force}) async {
            forces.add(force);
            if (!force) return null;
            return <LlmMessage>[const LlmMessage.user('重建后的上下文')];
          },
        ).run(
          messages: <LlmMessage>[const LlmMessage.user('x')],
          agentId: 'a',
          sessionId: 's',
          isCancelled: () => false,
        ),
      );
      expect(forces.first, isFalse, reason: '轮首那次是常规检查，不是强制压缩');
      expect(
        forces.where((bool force) => force),
        hasLength(1),
        reason: '重试时强制压一次',
      );
      expect(events.whereType<AgentError>(), isEmpty, reason: '重试成功不该报错');
      expect(
        events.whereType<AgentText>().map((AgentText e) => e.delta).join(),
        '压缩后成功',
      );
      expect(transport.turnsUsed, 2);
      expect(transport.requests[1].messages.single.content, '重建后的上下文');
    });

    test('超限重试只给一次：再失败如实报错', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        for (int i = 0; i < 4; i++)
          <LlmStreamEvent>[
            const LlmFailureEvent('exceeds the available context size'),
          ],
      ]);
      final List<bool> forces = <bool>[];
      final List<AgentEvent> events = await collect(
        session(
          transport,
          compact: ({required bool force}) async {
            forces.add(force);
            if (!force) return null;
            return <LlmMessage>[const LlmMessage.user('重建后的上下文')];
          },
        ).run(
          messages: <LlmMessage>[const LlmMessage.user('x')],
          agentId: 'a',
          sessionId: 's',
          isCancelled: () => false,
        ),
      );
      expect(forces.where((bool f) => f).length, 1, reason: '整轮只强制压一次');
      expect(
        (events.whereType<AgentError>().single).message,
        contains('exceeds the available context size'),
      );
      expect(transport.turnsUsed, 2);
    });

    test('不是超限的失败不触发压缩重试', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        <LlmStreamEvent>[
          const LlmFailureEvent('invalid api key', statusCode: 401),
        ],
      ]);
      int asks = 0;
      final List<AgentEvent> events = await collect(
        session(
          transport,
          compact: ({required bool force}) async {
            asks++;
            return <LlmMessage>[const LlmMessage.user('不该重建')];
          },
        ).run(
          messages: <LlmMessage>[const LlmMessage.user('x')],
          agentId: 'a',
          sessionId: 's',
          isCancelled: () => false,
        ),
      );
      expect(asks, 1, reason: '只有轮首那一次检查，失败后不再压缩');
      expect(
        (events.whereType<AgentError>().single).message,
        contains('invalid api key'),
      );
      expect(transport.turnsUsed, 1);
    });
  });

  group('token_scale 学习口径（Q1-①）', () {
    test('真实 usage 夹带本次请求的上下文字符数', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('abc'),
      ]);
      final List<AgentEvent> events = await collect(
        session(transport).run(
          messages: <LlmMessage>[const LlmMessage.user('hello')],
          agentId: 'a',
          sessionId: 's',
          isCancelled: () => false,
        ),
      );
      final Map<String, dynamic> usage =
          (events.whereType<AgentUsage>().first).usage;
      expect(usage[LlmSession.contextCharsKey], 5);
    });

    test('没有 usage 的端点不带该键（只读不写）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('abc', withUsage: false),
      ]);
      final List<AgentEvent> events = await collect(
        session(transport).run(
          messages: <LlmMessage>[const LlmMessage.user('hello')],
          agentId: 'a',
          sessionId: 's',
          isCancelled: () => false,
        ),
      );
      final Map<String, dynamic> usage =
          (events.whereType<AgentUsage>().first).usage;
      expect(usage.containsKey(LlmSession.contextCharsKey), isFalse);
      expect(usage['estimated'], isTrue);
    });
  });
}