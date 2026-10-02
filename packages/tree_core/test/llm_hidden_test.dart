import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

import 'fake_transport.dart';

/// 回归：**`llm_hidden` 的消息照常落库、照常下发，但不插进模型提示词**。
///
/// 用它的两类东西：
/// 1. **系统发言**——失败提示、"已停止本轮生成。"：模型读到那句错误只会把它当成
///    "新的排查任务"（用户实测反馈）；
/// 2. **过程提示**——重试进度（"第 2/5 次重试"）：说给用户听的，不是对话内容。
///
/// 同时钉住反面：`kind == 'notice'`（hook 唤醒）是**新的输入**，必须按 user 进上下文
/// ——不能"一刀切把所有系统消息都过滤掉"。
class _RecordingHub extends WsHub {
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
  @override
  void broadcast(Map<String, dynamic> frame) => frames.add(frame);
}

const String _failure =
    '读取模型响应失败：HttpException: Connection closed while receiving data, '
    'uri = https://api.deepseek.com/chat/completions';

void main() {
  group('引擎翻译', () {
    CoreModelConfig config() => CoreModelConfig(
      modelId: 'demo',
      name: '演示',
      baseUrl: 'https://api.deepseek.com',
      apiKey: 'sk-test',
      maxSeqlen: 64000,
    );

    Future<List<LlmMessage>> build(List<CoreMessageRef> history) async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        textScript('好'),
      ]);
      final LlmAgentEngine engine = LlmAgentEngine(
        resolveModel: (String id) => config(),
        transportFactory: (CoreModelConfig c) => transport,
      );
      await engine
          .run(
            AgentRunContext(
              agentId: 'agt_1',
              sessionId: 'ses_1',
              modelId: 'demo',
              systemPrompt: '系统提示',
              userContent: '',
              history: history,
            ),
            isCancelled: () => false,
          )
          .toList();
      return transport.requests.single.messages;
    }

    test('llm_hidden 的消息不进请求，用户消息一条不少', () async {
      final List<LlmMessage> sent = await build(<CoreMessageRef>[
        const CoreMessageRef(role: 'user', content: '任务一'),
        const CoreMessageRef(
          role: 'agent',
          content: _failure,
          llmHidden: true,
        ),
        const CoreMessageRef(role: 'user', content: '任务二'),
      ]);

      expect(
        sent.any((LlmMessage m) => m.content.contains('Connection closed')),
        isFalse,
        reason: '打了 llm_hidden 的消息不该出现在请求里',
      );
      expect(
        sent
            .where((LlmMessage m) => m.role == LlmRole.user)
            .map((LlmMessage m) => m.content),
        <String>['任务一', '任务二'],
      );
    });

    test('notice（hook 唤醒）仍按 user 进请求：不能一刀切过滤系统消息', () async {
      final List<LlmMessage> sent = await build(<CoreMessageRef>[
        const CoreMessageRef(role: 'user', content: '任务一'),
        const CoreMessageRef(
          role: 'agent',
          content: '[terminal hook] 后台命令已结束：npm test',
          kind: 'notice',
        ),
      ]);
      expect(sent.last.role, LlmRole.user);
      expect(sent.last.content, contains('后台命令已结束'));
    });
  });

  group('会话层（真实落库）', () {
    late CoreSettings settings;
    late MemoryStore store;
    late _RecordingHub hub;
    late ConversationService service;
    late CoreAgent agent;
    const String sid = TreeStore.defaultSessionId;

    void build(FakeTransport transport) {
      settings = CoreSettings();
      settings.createModel(<String, dynamic>{
        'model_id': 'demo',
        'name': '演示',
        'base_url': 'https://api.deepseek.com',
        'api_key': 'sk-test',
        'max_seqlen': 64000,
      });
      store = MemoryStore();
      hub = _RecordingHub();
      service = ConversationService(
        store: store,
        hub: hub,
        settings: settings,
        engine: LlmAgentEngine(
          resolveModel: settings.model,
          transportFactory: (CoreModelConfig c) => transport,
        ),
        pacingEnabled: false,
      );
      agent = store.createAgent(name: '用例', modelId: 'demo');
    }

    Future<void> say(String text) => service.handleUserMessage(<String, dynamic>{
      'agent_id': agent.id,
      'content': text,
      'session_id': sid,
    });

    test('失败提示落库带 llm_hidden：用户看得到，下一轮请求里没有它', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        <LlmStreamEvent>[const LlmFailureEvent(_failure)],
        textScript('接着干'),
      ]);
      build(transport);

      await say('任务一');

      // ① 用户可见：error 帧 + 一条落库消息（前端只忽略 error 帧），kind 照常是 text
      expect(
        hub.frames.any(
          (Map<String, dynamic> f) => f['type'] == WsOutboundType.error,
        ),
        isTrue,
      );
      final CoreMessage notice = store.messages(agent.id, sid).last;
      expect(notice.llmHidden, isTrue);
      expect(notice.kind, 'text', reason: '照常发：kind 不变，前端当普通气泡渲染');
      expect(notice.content, contains('Connection closed'));
      expect(notice.role, 'agent', reason: 'UI 仍按 agent 气泡渲染');
      // 落盘也带标记（重启后仍然不进上下文）
      expect(CoreMessage.fromJson(notice.toJson()).llmHidden, isTrue);

      // ② 模型不可见：下一轮请求里没有这句失败
      await say('任务二');
      final LlmRequest second = transport.requests[1];
      expect(
        second.messages.any(
          (LlmMessage m) => m.content.contains('Connection closed'),
        ),
        isFalse,
      );
      expect(second.messages.last.role, LlmRole.user);
      expect(second.messages.last.content, '任务二');
    });

    test('重试进度作为系统发言落库（llm_hidden），且不占本轮正文', () async {
      const String retryText =
          '模型端点调用失败（第 1/5 次重试，5s 后重试）：读取模型响应失败：'
          'HttpException: Connection closed while receiving data';
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        <LlmStreamEvent>[
          const LlmRetryNotice(retryText, attempt: 1, total: 5),
          const LlmTextDelta('接着干'),
          const LlmFinishEvent('stop'),
        ],
      ]);
      build(transport);

      await say('任务一');

      // 消息照常发：一条完整 message 帧 + 一条落库消息，内容就是那句进度
      final Map<String, dynamic> frame = hub.frames.lastWhere(
        (Map<String, dynamic> f) => f['type'] == WsOutboundType.message,
      );
      expect(frame['llm_hidden'], isTrue);
      final List<CoreMessage> stored = store.messages(agent.id, sid);
      final CoreMessage notice = stored.firstWhere(
        (CoreMessage m) => m.content.contains('第 1/5 次重试'),
      );
      expect(notice.llmHidden, isTrue);
      expect(notice.content, contains('Connection closed'));
      // 它不是模型输出：本轮正文只有模型真正吐的那一句
      expect(
        stored
            .where((CoreMessage m) => !m.llmHidden && m.role == 'agent')
            .map((CoreMessage m) => m.content)
            .join(),
        '接着干',
      );
    });
  });
}
