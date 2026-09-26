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
    expect(request.maxOutputTokens, 2048);
    expect(request.temperature, 0.2);
  });

  test('成员级 max_output_tokens 作为上限生效，成员覆盖回调被调用', () async {
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
    expect(transport.requests.single.maxOutputTokens, 111);
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
