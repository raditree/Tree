import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

import 'fake_transport.dart';

/// 回归哨兵：**请求不能以"没有 reasoning_content 的 assistant 消息"收尾**。
///
/// 实测证据（`.self/plan/20261001-thinking-400-and-interrupt/recon.md`，对
/// `https://api.deepseek.com` 的对照实验）：
/// - 带 `tools` 的请求：末尾是 assistant 且无 `reasoning_content` → **HTTP 400**
///   `The reasoning_content in the thinking mode must be passed back to the API.`
/// - 中间消息缺 reasoning、末尾是 user、末尾 assistant 带 reasoning → 全部 200
///
/// 触发过线上 400 的形态就是 hook 提示（`kind == 'notice'`，落库为 agent 角色）
/// 被追加到历史末尾 —— 因此引擎必须把它按 **user** 消息发出。
void main() {
  CoreModelConfig config() => CoreModelConfig(
    modelId: 'demo',
    name: '演示',
    baseUrl: 'https://api.deepseek.com',
    apiKey: 'sk-test',
    maxSeqlen: 64000,
    thinking: true,
  );

  AgentRunContext context(List<CoreMessageRef> history) => AgentRunContext(
    agentId: 'agt_1',
    sessionId: 'ses_1',
    modelId: 'demo',
    systemPrompt: '系统提示',
    userContent: '',
    history: history,
  );

  Future<List<LlmMessage>> build(
    List<CoreMessageRef> history, {
    List<String>? logs,
  }) async {
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      textScript('好'),
    ]);
    final LlmAgentEngine engine = LlmAgentEngine(
      resolveModel: (String id) => config(),
      transportFactory: (CoreModelConfig c) => transport,
      log: logs?.add,
    );
    await engine.run(context(history), isCancelled: () => false).toList();
    return transport.requests.single.messages;
  }

  group('notice（hook / 系统提示）的翻译', () {
    test('notice 按 user 发出：请求不再以无 reasoning 的 assistant 收尾', () async {
      final List<LlmMessage> sent = await build(<CoreMessageRef>[
        const CoreMessageRef(role: 'user', content: '第一条'),
        const CoreMessageRef(role: 'agent', content: '我做完了一件事'),
        const CoreMessageRef(
          role: 'agent',
          content: '[terminal hook] 后台命令已结束：npm test',
          kind: 'notice',
        ),
      ]);

      final LlmMessage last = sent.last;
      expect(last.role, LlmRole.user, reason: '末尾必须是 user（DeepSeek 硬要求）');
      expect(last.content, contains('[terminal hook] 后台命令已结束'));
      // 前端渲染不受影响（UI 仍按 role=agent 显示），这里只管发给端点的形态
      expect(
        sent.where((LlmMessage m) => m.role == LlmRole.assistant).length,
        1,
        reason: '原来那条 agent 文本仍是 assistant',
      );
    });

    test('notice 不注入附件段（它没有附件，也不该借用附件文案）', () async {
      final List<LlmMessage> sent = await build(<CoreMessageRef>[
        const CoreMessageRef(role: 'user', content: '起个后台命令'),
        const CoreMessageRef(
          role: 'agent',
          content: '[terminal hook] 已结束',
          kind: 'notice',
        ),
      ]);
      expect(sent.last.content, '[terminal hook] 已结束');
      expect(sent.last.content, isNot(contains('用户上传的附件')));
    });

    test('防御哨兵：真以"无 reasoning 的 assistant"收尾时留日志（不改请求）', () async {
      final List<String> logs = <String>[];
      final List<LlmMessage> sent = await build(<CoreMessageRef>[
        const CoreMessageRef(role: 'user', content: '问一句'),
        const CoreMessageRef(role: 'agent', content: '答一句'),
      ], logs: logs);

      expect(sent.last.role, LlmRole.assistant, reason: '这是不该出现的形态');
      expect(logs.join('\n'), contains('没有 reasoning_content'));
      expect(logs.join('\n'), contains('400'));
    });

    test('末尾 assistant 带 reasoning 时不告警（正常收尾形态）', () async {
      final List<String> logs = <String>[];
      await build(<CoreMessageRef>[
        const CoreMessageRef(role: 'user', content: '问一句'),
        const CoreMessageRef(role: 'agent', content: '思考', kind: 'thinking'),
        const CoreMessageRef(role: 'agent', content: '答一句'),
      ], logs: logs);
      expect(logs, isEmpty);
    });
  });

  group('会话层：wake 的 hook 提示', () {
    test('落库 kind=notice，且这一轮请求以 user 收尾（修掉 400 的现场）', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('好的'),
      ]);
      final CoreServer server = await CoreServer.start(
        streamChunkDelay: Duration.zero,
        enableHeartbeat: false,
        settings: CoreSettings(),
        engine: LlmAgentEngine(
          resolveModel: (String id) => config(),
          transportFactory: (CoreModelConfig c) => transport,
        ),
      );
      addTearDown(server.close);

      final CoreAgent agent = server.store.createAgent(
        name: '钩子测试',
        systemPrompt: '你是助手',
        modelId: 'demo',
      );
      await server.conversation.wake(
        agentId: agent.id,
        sessionId: TreeStore.defaultSessionId,
        notice: '[terminal hook] 后台命令已结束：npm test',
      );

      final CoreMessage notice = server.store
          .messages(agent.id, TreeStore.defaultSessionId)
          .firstWhere((CoreMessage m) => m.content.contains('terminal hook'));
      expect(notice.kind, 'notice');
      expect(notice.isNotice, isTrue);
      expect(notice.role, 'agent', reason: 'UI 仍按 agent 消息渲染');
      expect(notice.toJson()['kind'], 'notice', reason: 'kind 要能持久化');

      final LlmMessage last = transport.requests.single.messages.last;
      expect(last.role, LlmRole.user);
      expect(last.content, contains('后台命令已结束'));
    });
  });
}
