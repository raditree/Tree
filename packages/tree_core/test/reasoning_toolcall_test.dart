import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

import 'fake_transport.dart';

/// 思考模式 + tools 的两条**必 400**形态与修法（真端点实测见
/// `.self/plan/20261001-thinking-400-and-interrupt/recon.md`）：
///
/// | 形态 | 结果 |
/// |---|---|
/// | 请求以没有 reasoning 的 assistant 收尾（D6） | 400 |
/// | 请求以 `tool` 结果收尾，前一条 `tool_calls` 消息没有 reasoning（G1/G3） | 400 |
/// | 上面两种带上 reasoning（F1 / G2 / G4） | 200 |
///
/// 因此：**本轮的思考必须挂在"带 tool_calls 的那条 assistant 消息"上**（没有工具
/// 调用时才挂正文那条）；工具循环的下一跳由 [LlmSession] 自己带上当轮的思考。
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

  /// 跑一轮，取出发给端点的消息序列。
  Future<List<LlmMessage>> build(
    List<CoreMessageRef> history, {
    bool thinking = true,
  }) async {
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      textScript('好'),
    ]);
    final LlmAgentEngine engine = LlmAgentEngine(
      resolveModel: (String id) => config(thinking: thinking),
      transportFactory: (CoreModelConfig c) => transport,
    );
    await engine.run(context(history), isCancelled: () => false).toList();
    return transport.requests.single.messages;
  }

  /// 断言"以 tool 结果收尾"的请求里，发起工具调用的那条 assistant 带上了推理。
  void expectToolCallerHasReasoning(List<LlmMessage> sent) {
    expect(sent.last.role, LlmRole.tool, reason: '本用例就是"以 tool 结果收尾"');
    final LlmMessage caller = sent
        .where(
          (LlmMessage m) =>
              m.role == LlmRole.assistant && m.toolCalls.isNotEmpty,
        )
        .last;
    expect(
      caller.reasoningContent,
      isNotEmpty,
      reason: '带 tool_calls 的 assistant 必须带 reasoning_content（G1/G3 会 400）',
    );
    expect(caller.toWire()['reasoning_content'], isNotEmpty, reason: '真的上了线协议');
  }

  group('历史重放：以 tool 结果收尾', () {
    test('思考 → 工具卡：推理挂到带 tool_calls 的那条', () async {
      final List<LlmMessage> sent = await build(<CoreMessageRef>[
        const CoreMessageRef(role: 'user', content: '读一下 a.txt'),
        const CoreMessageRef(role: 'agent', content: '先看文件', kind: 'thinking'),
        const CoreMessageRef(
          role: 'agent',
          content: '',
          kind: 'tool',
          toolName: 'read',
          toolArguments: <String, dynamic>{'path': 'a.txt'},
          toolResult: '文件内容',
          toolCallId: 'call_1',
          timestamp: 1,
        ),
      ]);
      expectToolCallerHasReasoning(sent);
      expect(
        sent
            .where(
              (LlmMessage m) =>
                  m.role == LlmRole.assistant && m.toolCalls.isNotEmpty,
            )
            .last
            .reasoningContent,
        '先看文件',
      );
    });

    test('思考 → 正文 → 工具卡：推理归 tool_calls 那条（正文那条不重复挂）', () async {
      final List<LlmMessage> sent = await build(<CoreMessageRef>[
        const CoreMessageRef(role: 'user', content: '读一下 a.txt'),
        const CoreMessageRef(role: 'agent', content: '我先看一眼', kind: 'thinking'),
        const CoreMessageRef(role: 'agent', content: '好，我读一下。'),
        const CoreMessageRef(
          role: 'agent',
          content: '',
          kind: 'tool',
          toolName: 'read',
          toolArguments: <String, dynamic>{'path': 'a.txt'},
          toolResult: '文件内容',
          toolCallId: 'call_1',
          timestamp: 1,
        ),
      ]);
      expectToolCallerHasReasoning(sent);
      final LlmMessage textAssistant = sent.firstWhere(
        (LlmMessage m) => m.role == LlmRole.assistant && m.toolCalls.isEmpty,
      );
      expect(textAssistant.content, '好，我读一下。', reason: '正文顺序不变');
      expect(
        textAssistant.reasoningContent,
        isEmpty,
        reason: '推理不重复挂（同一轮的推理只属于那条 tool_calls 消息）',
      );
    });

    test('多轮工具：每一轮的推理各归自己那条 tool_calls 消息', () async {
      final List<LlmMessage> sent = await build(<CoreMessageRef>[
        const CoreMessageRef(role: 'user', content: '两轮工具'),
        const CoreMessageRef(role: 'agent', content: '第一轮思考', kind: 'thinking'),
        const CoreMessageRef(
          role: 'agent',
          content: '',
          kind: 'tool',
          toolName: 'read',
          toolResult: 'r1',
          toolCallId: 'c1',
          timestamp: 1,
        ),
        const CoreMessageRef(role: 'agent', content: '第二轮思考', kind: 'thinking'),
        const CoreMessageRef(
          role: 'agent',
          content: '',
          kind: 'tool',
          toolName: 'grep',
          toolResult: 'r2',
          toolCallId: 'c2',
          timestamp: 2,
        ),
      ]);
      final List<LlmMessage> callers = sent
          .where(
            (LlmMessage m) =>
                m.role == LlmRole.assistant && m.toolCalls.isNotEmpty,
          )
          .toList();
      expect(callers, hasLength(2));
      expect(callers[0].reasoningContent, '第一轮思考');
      expect(callers[1].reasoningContent, '第二轮思考');
      expect(sent.last.role, LlmRole.tool);
    });

    test('纯正文轮（无工具）：推理仍挂在正文那条（F1/D6 形态）', () async {
      final List<LlmMessage> sent = await build(<CoreMessageRef>[
        const CoreMessageRef(role: 'user', content: '问一句'),
        const CoreMessageRef(role: 'agent', content: '想了想', kind: 'thinking'),
        const CoreMessageRef(role: 'agent', content: '答一句'),
      ]);
      final LlmMessage last = sent.last;
      expect(last.role, LlmRole.assistant);
      expect(last.reasoningContent, '想了想');
    });

    test('回传开关关闭：一律不带 reasoning（既有行为不回归）', () async {
      final List<LlmMessage> sent = await build(<CoreMessageRef>[
        const CoreMessageRef(role: 'user', content: '读一下 a.txt'),
        const CoreMessageRef(role: 'agent', content: '先看文件', kind: 'thinking'),
        const CoreMessageRef(
          role: 'agent',
          content: '',
          kind: 'tool',
          toolName: 'read',
          toolResult: '文件内容',
          toolCallId: 'call_1',
          timestamp: 1,
        ),
      ], thinking: false);
      expect(
        sent.where(
          (LlmMessage m) => m.toWire().containsKey('reasoning_content'),
        ),
        isEmpty,
      );
    });
  });

  group('工具循环的下一跳（LlmSession 自己带当轮思考）', () {
    test('第 1 跳返回"思考 + 工具调用" → 第 2 跳请求里那条 assistant 带 reasoning', () async {
      final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
        <LlmStreamEvent>[
          const LlmThinkingDelta('我想先读文件'),
          const LlmToolCallDelta(index: 0, id: 'call_1', name: 'read'),
          const LlmToolCallDelta(index: 0, argumentsDelta: '{"path":"a.txt"}'),
          const LlmFinishEvent('tool_calls'),
        ],
        textScript('读完了'),
      ]);
      final FakeTransport toolTransport = transport;
      final LlmAgentEngine engine = LlmAgentEngine(
        resolveModel: (String id) => config(),
        transportFactory: (CoreModelConfig c) => toolTransport,
        toolRunner: FakeToolRunner(),
      );
      addTearDown(engine.close);

      await engine
          .run(
            context(const <CoreMessageRef>[
              CoreMessageRef(role: 'user', content: '读一下 a.txt'),
            ]),
            isCancelled: () => false,
          )
          .toList();

      expect(transport.requests, hasLength(2));
      final List<LlmMessage> second = transport.requests[1].messages;
      expect(second.last.role, LlmRole.tool, reason: '第 2 跳以工具结果收尾');
      final LlmMessage caller = second.firstWhere(
        (LlmMessage m) => m.role == LlmRole.assistant && m.toolCalls.isNotEmpty,
      );
      expect(caller.reasoningContent, '我想先读文件');
      expect(caller.toWire()['reasoning_content'], '我想先读文件');
    });
  });
}
