import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

import 'fake_transport.dart';

/// **思考回合的 `reasoning_content` 键**（真端点对照实验 2026-10-03，表见
/// [LlmMessage.thinkingTurn]）：
///
/// 端点只检查这个键**在不在**，不检查内容——`reasoning_content: ""` 是 **200**，
/// **整个键不给**才是 **400**
/// `The reasoning_content in the thinking mode must be passed back to the API.`
///
/// 真机现场（会话 `ses_1790927742041_b5d93d_72`，2026-10-03 10:10:41）：模型最后
/// 一段正文那一跳**没有产出思考**（没有思考卡），而队友的插话正好落在它前面 ——
/// 重建出来的请求以这条没有 reasoning 的 assistant 收尾 ⇒ 整个会话卡在 400
/// （`docs/known-issues.md` #4）。
///
/// 修法：思考模型的**每条** assistant 都带这个键（没有思考正文就空串）。位置无关，
/// 前缀缓存因此也不会因为"同一条消息这次在末尾、下次在中间"而变字节。
void main() {
  CoreModelConfig config({bool thinking = true}) => CoreModelConfig(
    modelId: 'demo',
    name: '演示',
    baseUrl: 'https://api.deepseek.com',
    apiKey: 'sk-test',
    maxSeqlen: 64000,
    thinking: thinking,
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
    bool thinking = true,
    List<String>? logs,
  }) async {
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      textScript('好'),
    ]);
    final LlmAgentEngine engine = LlmAgentEngine(
      resolveModel: (String id) => config(thinking: thinking),
      transportFactory: (CoreModelConfig c) => transport,
      log: logs?.add,
    );
    await engine.run(context(history), isCancelled: () => false).toList();
    return transport.requests.single.messages;
  }

  CoreMessageRef tool(String callId, {int ts = 1}) => CoreMessageRef(
    role: 'agent',
    content: '',
    kind: 'tool',
    toolName: 'read',
    toolArguments: <String, dynamic>{'path': 'a.txt'},
    toolResult: '结果',
    toolCallId: callId,
    timestamp: ts,
  );

  group('线协议', () {
    test('思考回合的 assistant：没有思考正文也必须带键（空串）', () {
      const LlmMessage message = LlmMessage(
        role: LlmRole.assistant,
        content: '答一句',
        thinkingTurn: true,
      );
      final Map<String, dynamic> wire = message.toWire();
      expect(wire.containsKey('reasoning_content'), isTrue, reason: '省略键 = 400（H3）');
      expect(wire['reasoning_content'], '', reason: '空串就够（H1/H2 实测 200）');
    });

    test('非思考回合：不多发这个键（与改动前的报文逐字一致）', () {
      const LlmMessage message = LlmMessage(
        role: LlmRole.assistant,
        content: '答一句',
      );
      expect(message.toWire().containsKey('reasoning_content'), isFalse);
    });

    test('有思考正文时照旧发正文', () {
      const LlmMessage message = LlmMessage(
        role: LlmRole.assistant,
        content: '答一句',
        reasoningContent: '先想一想',
        thinkingTurn: true,
      );
      expect(message.toWire()['reasoning_content'], '先想一想');
    });

    test('线协议往返保住"必须带键"这件事（插件改写请求体不能把它弄丢）', () {
      final LlmMessage? empty = LlmMessage.tryFromWire(<String, dynamic>{
        'role': 'assistant',
        'content': '答一句',
        'reasoning_content': '',
      });
      expect(empty, isNotNull);
      expect(empty!.thinkingTurn, isTrue, reason: '键在 = 它属于思考回合');
      expect(empty.toWire().containsKey('reasoning_content'), isTrue);

      final LlmMessage? plain = LlmMessage.tryFromWire(<String, dynamic>{
        'role': 'assistant',
        'content': '答一句',
      });
      expect(plain, isNotNull);
      expect(plain!.thinkingTurn, isFalse);
      expect(plain.toWire().containsKey('reasoning_content'), isFalse);
    });
  });

  group('历史翻译：思考模型的每条 assistant 都带键', () {
    test('真机现场：末尾是没有思考正文的 assistant（契门 10:10:41）', () async {
      final List<String> logs = <String>[];
      final List<LlmMessage> sent = await build(<CoreMessageRef>[
        const CoreMessageRef(role: 'user', content: '开工'),
        tool('call_1'),
        // 队友插话：它落在"被打断那一轮的收尾正文"**之前**（现场就是这样）
        const CoreMessageRef(
          role: 'user',
          content: '[来自 凌川] ①②③④ 已全部落进 M4_REPORT.md',
        ),
        // 被打断的收尾正文：这一跳模型**没有产出思考** ⇒ 历史里没有思考卡
        const CoreMessageRef(role: 'agent', content: '## 汇报：第三方独立复核通过（4/4）'),
      ], logs: logs);

      final LlmMessage last = sent.last;
      expect(last.role, LlmRole.assistant, reason: '现场正是"以 assistant 收尾"（D6 形态）');
      expect(last.reasoningContent, isEmpty, reason: '这一跳真的没有思考');
      expect(
        last.toWire()['reasoning_content'],
        '',
        reason: '真端点实测：空串 200，整个键不给才 400',
      );
      expect(logs.join('\n'), contains('空串'), reason: '留痕，便于日后排查');
    });

    test('工具循环下一跳：带 tool_calls 的那条即使没思考也带键（G1/G3 形态）', () async {
      final List<LlmMessage> sent = await build(<CoreMessageRef>[
        const CoreMessageRef(role: 'user', content: '读一下 a.txt'),
        tool('call_1'),
      ]);

      expect(sent.last.role, LlmRole.tool, reason: '本用例就是"以 tool 结果收尾"');
      final LlmMessage caller = sent.lastWhere(
        (LlmMessage m) => m.role == LlmRole.assistant && m.toolCalls.isNotEmpty,
      );
      expect(caller.reasoningContent, isEmpty);
      expect(caller.toWire()['reasoning_content'], '');
    });

    test('有思考卡时照旧把正文挂到带 tool_calls 的那条上', () async {
      final List<LlmMessage> sent = await build(<CoreMessageRef>[
        const CoreMessageRef(role: 'user', content: '读一下 a.txt'),
        const CoreMessageRef(role: 'agent', content: '先看看文件', kind: 'thinking'),
        tool('call_1'),
      ]);
      final LlmMessage caller = sent.lastWhere(
        (LlmMessage m) => m.role == LlmRole.assistant && m.toolCalls.isNotEmpty,
      );
      expect(caller.toWire()['reasoning_content'], '先看看文件');
    });

    test('非思考模型（thinking: false）：一个键都不发（报文与改动前一致）', () async {
      final List<LlmMessage> sent = await build(<CoreMessageRef>[
        const CoreMessageRef(role: 'user', content: '开工'),
        tool('call_1'),
        const CoreMessageRef(role: 'agent', content: '收尾正文'),
      ], thinking: false);

      for (final LlmMessage m in sent) {
        expect(
          m.toWire().containsKey('reasoning_content'),
          isFalse,
          reason: '非思考端点（OpenAI 系）会拒绝不认识的字段',
        );
      }
    });
  });

  group('会话在途那一跳（LlmSession）', () {
    test('模型这一跳没产出思考：下一跳请求仍带键', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        toolCallScript(name: 'read', arguments: '{"path":"a.txt"}'),
        textScript('好了'),
      ]);
      final LlmSession session = LlmSession(
        transport: transport,
        model: 'demo',
        tools: const <ToolSpec>[
          ToolSpec(name: 'read', description: '读文件'),
        ],
        toolRunner: FakeToolRunner(),
        thinkingTurn: true,
        tokenScale: 2.0,
      );
      await session
          .run(
            messages: <LlmMessage>[
              LlmMessage.system('系统'),
              LlmMessage.user('读一下 a.txt'),
            ],
            agentId: 'agt_1',
            sessionId: 'ses_1',
            isCancelled: () => false,
          )
          .toList();

      expect(transport.requests.length, 2, reason: '工具循环跑了两跳');
      final LlmMessage caller = transport.requests[1].messages.lastWhere(
        (LlmMessage m) => m.role == LlmRole.assistant && m.toolCalls.isNotEmpty,
      );
      expect(caller.reasoningContent, isEmpty, reason: '脚本里没有 thinking 增量');
      expect(
        caller.toWire()['reasoning_content'],
        '',
        reason: '在途这条也必须带键，否则工具循环的下一跳直接 400',
      );
    });
  });
}
