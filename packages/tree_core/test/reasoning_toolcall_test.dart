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

  /// 更强的一条：**整份请求里**每条带 `tool_calls` 的 assistant 都要有 reasoning。
  /// 第二种 400 现场恰恰输在"批被切出来的后半批"上——只查最后一条会漏掉它。
  void expectEveryToolCallerHasReasoning(List<LlmMessage> sent) {
    for (final LlmMessage m in sent) {
      if (m.role != LlmRole.assistant || m.toolCalls.isEmpty) continue;
      expect(
        m.reasoningContent,
        isNotEmpty,
        reason: '带 tool_calls 的 assistant 必须带 reasoning_content（否则下一跳 400）',
      );
    }
  }

  /// 一条工具卡（历史里的落库形态）。
  CoreMessageRef tool(String name, String callId, String result, {int ts = 1}) =>
      CoreMessageRef(
        role: 'agent',
        content: '',
        kind: 'tool',
        toolName: name,
        toolArguments: <String, dynamic>{'x': 1},
        toolResult: result,
        toolCallId: callId,
        timestamp: ts,
      );

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

    test('思考 → 正文 → 工具卡：正文与 tool_calls 合成同一条（= 实发那一份）', () async {
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
      final LlmMessage caller = sent.lastWhere(
        (LlmMessage m) =>
            m.role == LlmRole.assistant && m.toolCalls.isNotEmpty,
      );
      // 实发那一跳里，"本轮正文"与 tool_calls 就是**同一条** assistant 的
      // content + tool_calls；重建若把它拆成"正文一条 + tool_calls 一条"，
      // 从这条起消息序列就与实发的不同，端点前缀缓存整段落空。
      expect(caller.content, '好，我读一下。', reason: '本轮正文属于这条 assistant');
      expect(caller.reasoningContent, '我先看一眼');
      expect(
        sent.where(
          (LlmMessage m) =>
              m.role == LlmRole.assistant && m.toolCalls.isEmpty,
        ),
        isEmpty,
        reason: '正文不再单拆一条（拆开 = 换了一份前缀）',
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

  /// 第二种真机 400 现场（2026-10-02 18:14，member 跑在**远端 SSH** 上）：
  /// 一条 assistant 带了 3 个工具调用（terminal hook + 两次 write），三次结果是**逐条**
  /// 落库的；第 3 次 write 走同一条 SSH、晚了 ~20s 才回来，hook 的完成提示
  /// （`kind == 'notice'`）正好落在第 2、3 条结果之间。旧实现就地把它发成 user 消息，
  /// 这一批被切出一个"没有 reasoning_content 的后半批"⇒ 请求以 tool 结果收尾、前面那条
  /// `tool_calls` 没有 reasoning ⇒ 端点 400
  /// `The reasoning_content in the thinking mode must be passed back to the API.`
  ///
  /// 修法：**工具批是原子的**——批中途落进来的 user / notice 一律推迟到这一批的结果之后。
  /// 这同时也修掉了结构上的非法形态（user 消息不能插在 assistant(tool_calls) 与它自己的
  /// tool 结果之间），并让重建出来的消息序列与"当初实发的那一份"重新对齐。
  group('工具批是原子的：批中途的注入不得切开它', () {
    test('hook 完成提示卡在第 2、3 条结果之间：批不切开，提示排在批之后', () async {
      final List<LlmMessage> sent = await build(<CoreMessageRef>[
        const CoreMessageRef(role: 'user', content: '起后台任务，顺便写两个文件'),
        const CoreMessageRef(role: 'agent', content: '先起后台任务', kind: 'thinking'),
        const CoreMessageRef(role: 'agent', content: '好，我这就办。'),
        tool('terminal', 'call_00', 'hook 已在后台启动', ts: 1),
        tool('write', 'call_01', '已写入 a.py', ts: 2),
        const CoreMessageRef(
          role: 'agent',
          content: '[terminal hook] 后台命令已结束：rc=1',
          kind: 'notice',
        ),
        tool('write', 'call_02', '已写入 b.py', ts: 3),
      ]);

      final List<LlmMessage> callers = sent
          .where(
            (LlmMessage m) =>
                m.role == LlmRole.assistant && m.toolCalls.isNotEmpty,
          )
          .toList();
      expect(
        callers,
        hasLength(1),
        reason: '这一批只能有一条 assistant：切开就是线上那次 400 的形态',
      );
      expect(
        callers.single.toolCalls.map((LlmToolCall c) => c.id).toList(),
        <String>['call_00', 'call_01', 'call_02'],
        reason: '三个调用要合回同一条 assistant（= 当初实发的那一份）',
      );
      expect(callers.single.reasoningContent, '先起后台任务');
      expect(callers.single.content, '好，我这就办。');
      expectEveryToolCallerHasReasoning(sent);

      // 三条结果紧跟在它后面，中间不许插东西
      final int at = sent.indexOf(callers.single);
      expect(
        sent.sublist(at + 1, at + 4).map((LlmMessage m) => m.role).toList(),
        <LlmRole>[LlmRole.tool, LlmRole.tool, LlmRole.tool],
      );
      // 提示照旧进上下文（按 user 发出），位置在批之后
      final LlmMessage notice = sent.last;
      expect(notice.role, LlmRole.user);
      expect(notice.content, contains('后台命令已结束'));
      expect(
        sent.where((LlmMessage m) => m.role == LlmRole.tool),
        hasLength(3),
        reason: '工具结果一条不少、一条不多',
      );
    });

    test('用户插话卡在批中间（打断的竞态）：同样推迟，且不以 tool 收尾', () async {
      final List<LlmMessage> sent = await build(<CoreMessageRef>[
        const CoreMessageRef(role: 'user', content: '跑两条命令'),
        const CoreMessageRef(role: 'agent', content: '先跑第一条', kind: 'thinking'),
        tool('terminal', 'call_a', '第一条结果', ts: 1),
        const CoreMessageRef(role: 'user', content: '等一下，先别跑第二条'),
        tool('terminal', 'call_b', '第二条结果', ts: 2),
      ]);

      final List<LlmMessage> callers = sent
          .where(
            (LlmMessage m) =>
                m.role == LlmRole.assistant && m.toolCalls.isNotEmpty,
          )
          .toList();
      expect(callers, hasLength(1));
      expect(
        callers.single.toolCalls.map((LlmToolCall c) => c.id).toList(),
        <String>['call_a', 'call_b'],
      );
      expect(callers.single.reasoningContent, '先跑第一条');
      expectEveryToolCallerHasReasoning(sent);

      final LlmMessage last = sent.last;
      expect(last.role, LlmRole.user);
      expect(
        last.content,
        '等一下，先别跑第二条',
        reason: '用户的新话必须还在上下文里（只是排到批的结果之后）',
      );
    });

    test('两个批：落在第一批中间的提示排在第一批之后、第二批之前', () async {
      final List<LlmMessage> sent = await build(<CoreMessageRef>[
        const CoreMessageRef(role: 'user', content: '两轮工具'),
        const CoreMessageRef(role: 'agent', content: '第一轮思考', kind: 'thinking'),
        tool('read', 'c1', 'r1', ts: 1),
        const CoreMessageRef(
          role: 'agent',
          content: '[terminal hook] 后台命令已结束',
          kind: 'notice',
        ),
        tool('read', 'c2', 'r2', ts: 2),
        const CoreMessageRef(role: 'agent', content: '第二轮思考', kind: 'thinking'),
        tool('grep', 'c3', 'r3', ts: 3),
      ]);

      final List<LlmMessage> callers = sent
          .where(
            (LlmMessage m) =>
                m.role == LlmRole.assistant && m.toolCalls.isNotEmpty,
          )
          .toList();
      expect(callers, hasLength(2));
      expect(
        callers[0].toolCalls.map((LlmToolCall c) => c.id).toList(),
        <String>['c1', 'c2'],
      );
      expect(callers[0].reasoningContent, '第一轮思考');
      expect(
        callers[1].toolCalls.map((LlmToolCall c) => c.id).toList(),
        <String>['c3'],
      );
      expect(callers[1].reasoningContent, '第二轮思考');
      expectEveryToolCallerHasReasoning(sent);

      final int noticeAt = sent.indexWhere(
        (LlmMessage m) =>
            m.role == LlmRole.user && m.content.contains('后台命令已结束'),
      );
      expect(noticeAt, greaterThan(0), reason: '提示仍要进上下文');
      expect(sent[noticeAt - 1].role, LlmRole.tool, reason: '提示排在批的结果之后');
      expect(sent[noticeAt + 1].role, LlmRole.assistant, reason: '提示之后才是下一轮');
    });
  });
}