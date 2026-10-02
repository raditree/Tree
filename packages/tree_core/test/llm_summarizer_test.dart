import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

import 'fake_transport.dart';

/// 生产总结器（M7d-4）：把流式补全收成一段总结文本。
///
/// 这里只验"请求形状 + 收敛/报错语义"：HTTP/SSE 层由
/// http_sse_transport_test.dart 覆盖，压缩策略由 compaction_test.dart 覆盖。
void main() {
  final CoreModelConfig config = CoreModelConfig(
    modelId: 'demo',
    name: '演示',
    baseUrl: 'https://api.example.com/v1',
    apiKey: 'sk-test',
    maxSeqlen: 1000,
  );

  CoreAgent agent({String modelId = 'demo', int maxOutputTokens = 0}) {
    final CoreAgent created = CoreAgent(
      id: 'agt_1',
      name: 'a',
      createdAt: 0,
      updatedAt: 0,
    );
    created.modelId = modelId;
    created.maxOutputTokens = maxOutputTokens;
    return created;
  }

  test('把流式文本拼成总结：单条 user 消息、不带工具、温度固定', () async {
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      textScript('要点一；要点二'),
    ]);
    final LlmSummarizer summarizer = LlmSummarizer(
      resolveModel: (String id) => id == 'demo' ? config : null,
      transportFactory: (CoreModelConfig _) => transport,
    );
    expect(await summarizer.summarize(agent(), '请总结'), '要点一；要点二');
    final LlmRequest request = transport.requests.single;
    expect(request.messages, hasLength(1));
    expect(request.messages.single.role, LlmRole.user);
    expect(request.messages.single.content, '请总结');
    expect(request.tools, isEmpty, reason: '总结请求带工具就可能递归触发工具循环');
    expect(
      request.maxOutputTokens,
      isNull,
      reason: '复用模型输出长度：模型没配 max_output_tokens 就不发送（与对话引擎同口径）',
    );
    expect(request.temperature, 0.2);
    expect(request.reasoningEffort, isNull, reason: '模型/成员都没声明思考档位时不额外发送');
  });

  test('重试进度转发给上层：总结器自己没有会话可渲染', () async {
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      <LlmStreamEvent>[
        const LlmRetryNotice(
          '模型端点调用失败（第 1/5 次重试，5s 后重试）：链路断了',
          attempt: 1,
          total: 5,
        ),
        ...textScript('要点一'),
      ],
    ]);
    final List<String> logs = <String>[];
    final LlmSummarizer summarizer = LlmSummarizer(
      resolveModel: (String id) => id == 'demo' ? config : null,
      transportFactory: (CoreModelConfig _) => transport,
      log: logs.add,
    );

    final List<String> notices = <String>[];
    final String text = await summarizer.summarize(
      agent(),
      '请总结',
      onNotice: notices.add,
    );

    expect(text, '要点一', reason: '提示不占正文、也不改变总结结果');
    expect(notices.single, contains('第 1/5 次重试'));
    expect(logs.single, contains('第 1/5 次重试'), reason: '同时留一行日志');
  });

  test('成员级 max_output_tokens 直接复用（总结不再另设上限），成员覆盖回调被调用', () async {
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      textScript('ok'),
    ]);
    final List<String> overrideCalls = <String>[];
    final LlmSummarizer summarizer = LlmSummarizer(
      resolveModel: (String id) => id == 'demo' ? config : null,
      transportFactory: (CoreModelConfig _) => transport,
      agentOverrides: (String agentId) {
        overrideCalls.add(agentId);
        return <String, Object?>{'max_output_tokens': 111};
      },
    );
    await summarizer.summarize(agent(maxOutputTokens: 111), '请总结');
    expect(overrideCalls, <String>['agt_1']);
    expect(
      transport.requests.single.maxOutputTokens,
      111,
      reason: '成员配置的输出长度原样复用，不被"总结该短"之类的独立口径改写',
    );
  });

  test('模型配置了 max_output_tokens 时同样原样复用（与对话引擎同口径）', () async {
    final CoreModelConfig capped = CoreModelConfig(
      modelId: 'demo',
      name: '演示',
      baseUrl: 'https://api.example.com/v1',
      apiKey: 'sk-test',
      maxSeqlen: 65536,
      maxOutputTokens: 65536,
    );
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      textScript('ok'),
    ]);
    final LlmSummarizer summarizer = LlmSummarizer(
      resolveModel: (String id) => id == 'demo' ? capped : null,
      transportFactory: (CoreModelConfig _) => transport,
    );
    await summarizer.summarize(agent(), '请总结');
    expect(
      transport.requests.single.maxOutputTokens,
      65536,
      reason: '思考 + 正文都要落在这个预算里；2048 那种"总结该短"的口径会被思考吃满',
    );
  });

  test('同一端点复用传输（两次总结只建一次连接池）', () async {
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      textScript('第一次'),
      textScript('第二次'),
    ]);
    int created = 0;
    final LlmSummarizer summarizer = LlmSummarizer(
      resolveModel: (String id) => id == 'demo' ? config : null,
      transportFactory: (CoreModelConfig _) {
        created++;
        return transport;
      },
    );
    await summarizer.summarize(agent(), '一');
    await summarizer.summarize(agent(), '二');
    expect(created, 1);
    expect(transport.requests, hasLength(2));
  });

  test('错误必须可读：未指定模型 / 配置不存在 / 流中失败 / 空总结', () async {
    final LlmSummarizer bare = LlmSummarizer(
      resolveModel: (String id) => id == 'demo' ? config : null,
      transportFactory: (CoreModelConfig _) =>
          FakeTransport(<List<LlmStreamEvent>>[]),
    );
    await expectLater(
      bare.summarize(agent(modelId: ''), 'x'),
      throwsA(
        isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          contains('尚未指定模型'),
        ),
      ),
    );
    await expectLater(
      bare.summarize(agent(modelId: 'gone'), 'x'),
      throwsA(
        isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          contains('模型配置不存在'),
        ),
      ),
    );

    final LlmSummarizer failing = LlmSummarizer(
      resolveModel: (String id) => id == 'demo' ? config : null,
      transportFactory: (CoreModelConfig _) =>
          FakeTransport(<List<LlmStreamEvent>>[
            <LlmStreamEvent>[const LlmFailureEvent('端点 500')],
          ]),
    );
    await expectLater(
      failing.summarize(agent(), 'x'),
      throwsA(
        isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          contains('端点 500'),
        ),
      ),
    );

    final LlmSummarizer empty = LlmSummarizer(
      resolveModel: (String id) => id == 'demo' ? config : null,
      transportFactory: (CoreModelConfig _) =>
          FakeTransport(<List<LlmStreamEvent>>[
            <LlmStreamEvent>[const LlmFinishEvent('stop')],
          ]),
    );
    await expectLater(
      empty.summarize(agent(), 'x'),
      throwsA(
        isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          contains('没有返回总结内容'),
        ),
      ),
    );
  });

  test('只有思考、没有正文：不降档也不重试，错误里带 finish_reason 与思考字数', () async {
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      // 实测形态：finish_reason=length（预算被思考吃满）、正文 0 字
      <LlmStreamEvent>[
        LlmThinkingDelta('想' * 40),
        const LlmFinishEvent('length'),
      ],
      textScript('不该被用到'),
    ]);
    final LlmSummarizer summarizer = LlmSummarizer(
      resolveModel: (String id) => id == 'demo' ? config : null,
      transportFactory: (CoreModelConfig _) => transport,
    );
    await expectLater(
      summarizer.summarize(agent(), '请总结'),
      throwsA(
        isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          allOf(
            contains('没有返回总结内容'),
            contains('finish_reason=length'),
            contains('思考 40 字'),
          ),
        ),
      ),
    );
    expect(
      transport.requests,
      hasLength(1),
      reason: '总结保持 agent 的思考档位：压低思考换来的是更弱的总结器，不靠降档补救',
    );
  });

  test('总结沿用 agent 的思考档位（含成员级覆盖），不自行降档', () async {
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      textScript('ok'),
    ]);
    final LlmSummarizer summarizer = LlmSummarizer(
      resolveModel: (String id) => id == 'demo' ? config : null,
      transportFactory: (CoreModelConfig _) => transport,
      agentOverrides: (String _) => <String, Object?>{
        'reasoning_effort': 'high',
      },
    );
    await summarizer.summarize(agent(), '请总结');
    expect(
      transport.requests.single.reasoningEffort,
      'high',
      reason: '与对话引擎同档位，否则摘要质量与对话时不一致',
    );
  });

  test('传输层失败不重试：原样上报端点错误', () async {
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      <LlmStreamEvent>[const LlmFailureEvent('端点 503')],
      textScript('不该被用到'),
    ]);
    final LlmSummarizer summarizer = LlmSummarizer(
      resolveModel: (String id) => id == 'demo' ? config : null,
      transportFactory: (CoreModelConfig _) => transport,
    );
    await expectLater(
      summarizer.summarize(agent(), '请总结'),
      throwsA(
        isA<StateError>().having(
          (StateError e) => e.message,
          'message',
          contains('端点 503'),
        ),
      ),
    );
    expect(transport.requests, hasLength(1), reason: '端点不通时重试只会浪费一次调用');
  });

  test('close() 关闭自己建的传输', () async {
    final _TrackingTransport transport = _TrackingTransport();
    final LlmSummarizer summarizer = LlmSummarizer(
      resolveModel: (String id) => id == 'demo' ? config : null,
      transportFactory: (CoreModelConfig _) => transport,
    );
    await summarizer.summarize(agent(), 'x');
    expect(transport.closed, isFalse);
    await summarizer.close();
    expect(transport.closed, isTrue);
  });
}

class _TrackingTransport implements LlmTransport {
  bool closed = false;

  @override
  Stream<LlmStreamEvent> stream(
    LlmRequest request, {
    bool Function()? isCancelled,
  }) async* {
    yield const LlmTextDelta('总结');
    yield const LlmFinishEvent('stop');
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
