import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

import 'fake_transport.dart';

/// 成员级模型参数覆盖（M5b）：用户为某个成员设置的参数必须真的作用到请求上。
///
/// 这是"不静默撒谎"的守门测试：模型配置页能设置、成员 yaml 里有值，就必须有
/// 消费者；否则用户以为生效了，实际请求还是 TOP 的参数。
void main() {
  CoreSettings settingsWithModel() {
    final CoreSettings settings = CoreSettings();
    settings.createModel(<String, dynamic>{
      'model_id': 'demo',
      'name': '演示模型',
      'base_url': 'https://api.example.com/v1',
      'api_key': 'sk-test',
      'max_seqlen': 64000,
      'max_output_tokens': 4096,
      'reasoning_effort': 'low',
    });
    return settings;
  }

  test('withOverrides：只覆盖传入项，且不改原对象', () {
    final CoreSettings settings = settingsWithModel();
    final CoreModelConfig base = settings.model('demo')!;
    final CoreModelConfig merged = base.withOverrides(<String, Object?>{
      'reasoning_effort': 'high',
      'max_seqlen': 32000,
    });
    expect(merged.reasoningEffort, 'high');
    expect(merged.maxSeqlen, 32000);
    expect(merged.effectiveMaxSeqlen, 32000);
    expect(merged.maxOutputTokens, 4096, reason: '未覆盖的保留模型默认');
    expect(base.reasoningEffort, 'low', reason: '原对象不被修改');
    expect(base.withOverrides(<String, Object?>{}), same(base));
  });

  test('引擎把成员覆盖作用到实际请求（reasoning_effort / max_output_tokens）', () async {
    final CoreSettings settings = settingsWithModel();
    final MemoryStore store = MemoryStore();
    final CoreAgent member = store.createAgent(name: '成员', modelId: 'demo');
    member
      ..reasoningEffort = 'high'
      ..maxOutputTokens = 2048
      ..maxSeqlenOverride = 32000;
    store.putAgent(member);

    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      textScript('好'),
    ]);
    final LlmAgentEngine engine = LlmAgentEngine(
      resolveModel: settings.model,
      toolRunner: const EmptyToolRunner(),
      transportFactory: (CoreModelConfig _) => transport,
      agentOverrides: (String agentId) {
        final CoreAgent? agent = store.agent(agentId);
        if (agent == null) return const <String, Object?>{};
        return <String, Object?>{
          if (agent.reasoningEffort.trim().isNotEmpty)
            'reasoning_effort': agent.reasoningEffort,
          if (agent.maxSeqlenOverride > 0)
            'max_seqlen': agent.maxSeqlenOverride,
          if (agent.maxOutputTokens > 0)
            'max_output_tokens': agent.maxOutputTokens,
        };
      },
    );
    final List<AgentEvent> events = await engine
        .run(
          AgentRunContext(
            agentId: member.id,
            sessionId: TreeStore.defaultSessionId,
            systemPrompt: '你是助手',
            userContent: '你好',
            modelId: 'demo',
            history: <CoreMessageRef>[
              const CoreMessageRef(role: 'user', content: '你好'),
            ],
          ),
          isCancelled: () => false,
        )
        .toList();
    expect(events.whereType<AgentError>(), isEmpty);
    expect(transport.requests, hasLength(1));
    final LlmRequest request = transport.requests.single;
    expect(request.reasoningEffort, 'high');
    expect(request.maxOutputTokens, 2048);
    await engine.close();
  });

  test('没有覆盖时请求沿用模型配置（不回归）', () async {
    final CoreSettings settings = settingsWithModel();
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      textScript('好'),
    ]);
    final LlmAgentEngine engine = LlmAgentEngine(
      resolveModel: settings.model,
      transportFactory: (CoreModelConfig _) => transport,
      agentOverrides: (String _) => const <String, Object?>{},
    );
    await engine
        .run(
          AgentRunContext(
            agentId: 'agt_x',
            sessionId: TreeStore.defaultSessionId,
            systemPrompt: '',
            userContent: '你好',
            modelId: 'demo',
            history: <CoreMessageRef>[
              const CoreMessageRef(role: 'user', content: '你好'),
            ],
          ),
          isCancelled: () => false,
        )
        .toList();
    expect(transport.requests.single.reasoningEffort, 'low');
    expect(transport.requests.single.maxOutputTokens, 4096);
    await engine.close();
  });
}
