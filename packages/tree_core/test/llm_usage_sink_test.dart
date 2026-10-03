import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

import 'fake_transport.dart';

/// **内置压缩（`LlmSummarizer`）与执行站 `llm.call`（`LlmJsonCaller`）的逐调用用量**。
///
/// 这两条路以前**完全不产生 usage**（总结器直接丢掉 `LlmUsageEvent`；`llm.call` 只把
/// usage 塞进回包给插件），于是"压缩到底花了多少 / 缓存命中多少"永远算不出来。
/// 现在各自有一个**可注入**的用量回调：端点给了用真值，没给就用本地估算并标
/// `estimated`（估算与对话**共用** `util/tokens.dart` 的同一个函数）。
void main() {
  final CoreModelConfig config = CoreModelConfig(
    modelId: 'demo',
    name: '演示',
    baseUrl: 'https://api.example.com/v1',
    apiKey: 'sk-test',
    maxSeqlen: 64000,
  );

  CoreAgent agent() {
    final CoreAgent created = CoreAgent(
      id: 'agt_1',
      name: 'a',
      createdAt: 0,
      updatedAt: 0,
    );
    created.modelId = 'demo';
    return created;
  }

  group('LlmSummarizer（内置压缩）', () {
    test('端点给 usage ⇒ 记真值，source=compact', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        <LlmStreamEvent>[
          const LlmTextDelta('要点一；要点二'),
          const LlmUsageEvent(
            LlmUsage(
              promptTokens: 400,
              completionTokens: 60,
              totalTokens: 460,
              cachedTokens: 128,
            ),
          ),
          const LlmFinishEvent('stop'),
        ],
      ]);
      final List<UsageCall> recorded = <UsageCall>[];
      final LlmSummarizer summarizer = LlmSummarizer(
        resolveModel: (String id) => id == 'demo' ? config : null,
        transportFactory: (CoreModelConfig _) => transport,
        usageSink: (String agentId, UsageCall call) => recorded.add(call),
      );

      expect(await summarizer.summarize(agent(), '请总结'), '要点一；要点二');
      expect(recorded, hasLength(1), reason: '一次总结 = 一次 LLM 调用 = 一笔账');
      final UsageCall call = recorded.single;
      expect(call.source, UsageSource.compact);
      expect(call.model, 'demo');
      expect(call.promptTokens, 400);
      expect(call.cachedTokens, 128);
      expect(call.completionTokens, 60);
      expect(call.estimated, isFalse);
      expect(call.durationMs, greaterThanOrEqualTo(0));
    });

    test('端点不回 usage ⇒ 本地估算并标 estimated；cached 留空', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('要点一', withUsage: false),
      ]);
      final List<UsageCall> recorded = <UsageCall>[];
      final LlmSummarizer summarizer = LlmSummarizer(
        resolveModel: (String id) => id == 'demo' ? config : null,
        transportFactory: (CoreModelConfig _) => transport,
        usageSink: (String agentId, UsageCall call) => recorded.add(call),
      );

      await summarizer.summarize(agent(), '请总结');
      final UsageCall call = recorded.single;
      expect(call.estimated, isTrue);
      expect(call.promptTokens, greaterThan(0), reason: '估算与对话共用同一个换算');
      expect(call.completionTokens, greaterThan(0));
      expect(call.cachedTokens, isNull, reason: '端点没给这个字段 ⇒ 留空，不编造 0');
    });

    test('总结失败（真错误）也记账：这一次调用确实发出去了', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        <LlmStreamEvent>[const LlmFailureEvent('端点 500')],
      ]);
      final List<UsageCall> recorded = <UsageCall>[];
      final LlmSummarizer summarizer = LlmSummarizer(
        resolveModel: (String id) => id == 'demo' ? config : null,
        transportFactory: (CoreModelConfig _) => transport,
        usageSink: (String agentId, UsageCall call) => recorded.add(call),
      );

      await expectLater(
        summarizer.summarize(agent(), '请总结'),
        throwsA(isA<StateError>()),
      );
      expect(recorded, hasLength(1));
      expect(recorded.single.estimated, isTrue);
      expect(recorded.single.source, UsageSource.compact);
    });

    test('模型没配好（根本没发请求）⇒ 不记账', () async {
      final List<UsageCall> recorded = <UsageCall>[];
      final LlmSummarizer summarizer = LlmSummarizer(
        resolveModel: (String id) => null,
        usageSink: (String agentId, UsageCall call) => recorded.add(call),
      );
      await expectLater(
        summarizer.summarize(agent(), '请总结'),
        throwsA(isA<StateError>()),
      );
      expect(recorded, isEmpty, reason: '没有发出去的调用不该有账');
    });

    test('没接回调时照常工作（可注入，不强制）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('要点'),
      ]);
      final LlmSummarizer summarizer = LlmSummarizer(
        resolveModel: (String id) => id == 'demo' ? config : null,
        transportFactory: (CoreModelConfig _) => transport,
      );
      expect(await summarizer.summarize(agent(), '请总结'), '要点');
    });

    test('可写字段：接线方（拿到会话之后）再接上也能落账', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('要点'),
      ]);
      final LlmSummarizer summarizer = LlmSummarizer(
        resolveModel: (String id) => id == 'demo' ? config : null,
        transportFactory: (CoreModelConfig _) => transport,
      );
      // 模拟 CompactionService：构造期拿不到会话，压缩前才把 sink 接上
      final List<UsageCall> recorded = <UsageCall>[];
      summarizer.usageSink = (String agentId, UsageCall call) =>
          recorded.add(call);
      await summarizer.summarize(agent(), '请总结');
      expect(recorded, hasLength(1));
      expect(recorded.single.source, UsageSource.compact);
    });
  });

  group('LlmJsonCaller（执行站 llm.call）', () {
    test('端点给 usage ⇒ 记真值，source=llm.call', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        <LlmStreamEvent>[
          const LlmTextDelta('{"ok":true}'),
          const LlmUsageEvent(
            LlmUsage(
              promptTokens: 321,
              completionTokens: 45,
              totalTokens: 366,
              cachedTokens: 12,
            ),
          ),
          const LlmFinishEvent('stop'),
        ],
      ]);
      final List<UsageCall> recorded = <UsageCall>[];
      final LlmJsonCaller caller = LlmJsonCaller(
        resolveModel: (String id) => id == 'demo' ? config : null,
        transportFactory: (CoreModelConfig _) => transport,
        usageSink: (String agentId, UsageCall call) => recorded.add(call),
      );

      final Map<String, dynamic> reply = await caller.call(
        agentId: 'agt_1',
        modelId: 'demo',
        prompt: '帮我压缩',
      );
      expect(reply['ok'], isTrue);
      // 回包给插件的那份 usage 照旧（这是插件的既有契约，不动）
      expect(
        (reply['usage'] as Map<String, dynamic>)['prompt_tokens'],
        321,
      );
      expect(recorded, hasLength(1));
      final UsageCall call = recorded.single;
      expect(call.source, UsageSource.llmCall);
      expect(call.model, 'demo');
      expect(call.promptTokens, 321);
      expect(call.cachedTokens, 12);
      expect(call.completionTokens, 45);
      expect(call.estimated, isFalse);
    });

    test('端点不回 usage ⇒ 本地估算并标 estimated', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('{"ok":true}', withUsage: false),
      ]);
      final List<UsageCall> recorded = <UsageCall>[];
      final LlmJsonCaller caller = LlmJsonCaller(
        resolveModel: (String id) => id == 'demo' ? config : null,
        transportFactory: (CoreModelConfig _) => transport,
        usageSink: (String agentId, UsageCall call) => recorded.add(call),
      );

      await caller.call(agentId: 'agt_1', modelId: 'demo', prompt: '帮我压缩');
      final UsageCall call = recorded.single;
      expect(call.estimated, isTrue);
      expect(call.promptTokens, greaterThan(0));
      expect(call.completionTokens, greaterThan(0));
      expect(call.cachedTokens, isNull);
    });

    test('调用失败也记账；模型不存在（没发请求）不记账', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        <LlmStreamEvent>[const LlmFailureEvent('端点 502')],
      ]);
      final List<UsageCall> recorded = <UsageCall>[];
      final LlmJsonCaller caller = LlmJsonCaller(
        resolveModel: (String id) => id == 'demo' ? config : null,
        transportFactory: (CoreModelConfig _) => transport,
        usageSink: (String agentId, UsageCall call) => recorded.add(call),
      );
      final Map<String, dynamic> reply = await caller.call(
        agentId: 'agt_1',
        modelId: 'demo',
        prompt: '帮我压缩',
      );
      expect(reply['error'], contains('502'));
      expect(recorded, hasLength(1));
      expect(recorded.single.estimated, isTrue);

      final List<UsageCall> none = <UsageCall>[];
      final LlmJsonCaller broken = LlmJsonCaller(
        resolveModel: (String id) => null,
        usageSink: (String agentId, UsageCall call) => none.add(call),
      );
      await broken.call(agentId: 'agt_1', modelId: '', prompt: 'x');
      expect(none, isEmpty);
    });
  });
}
