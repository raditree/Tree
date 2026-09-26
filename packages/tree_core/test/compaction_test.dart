import 'dart:async';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 假总结器：记录提示词，可配置返回值 / 失败 / 闸门（模拟慢总结）。
class _FakeSummarizer implements ContextSummarizer {
  _FakeSummarizer({this.error, this.gate});

  final Object? error;
  final Completer<void>? gate;
  final List<String> prompts = <String>[];
  bool closed = false;

  @override
  Future<String> summarize(CoreAgent agent, String prompt) async {
    prompts.add(prompt);
    if (gate != null) await gate!.future;
    if (error != null) throw StateError('$error');
    return '总结正文';
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  late MemoryStore store;
  late CoreAgent agent;
  late CoreSession session;
  late CoreSettings settings;
  late _FakeSummarizer summarizer;
  late CompactionService service;
  int clock = 0;

  setUp(() {
    clock = 0;
    store = MemoryStore();
    agent = store.createAgent(name: '压缩用例', modelId: 'demo');
    agent.systemPrompt = '你是助手';
    agent.compressThreshold = 0.5;
    store.putAgent(agent);
    settings = CoreSettings()
      ..putModel(
        CoreModelConfig(
          modelId: 'demo',
          name: '演示',
          baseUrl: 'https://api.example.com/v1',
          apiKey: 'sk-test',
          maxSeqlen: 1000,
        ),
      );
    session = store.session(agent.id, TreeStore.defaultSessionId)!;
    summarizer = _FakeSummarizer();
    service = CompactionService(
      store: store,
      settings: settings,
      summarizer: summarizer,
      keepRecentUserMessages: 2,
      keepTailLength: 2,
      minSummarizeMessages: 4,
    );
  });

  void add(
    String role,
    String content, {
    String kind = 'text',
    String? toolName,
    String toolResult = '',
  }) {
    store.appendMessage(
      CoreMessage(
        id: CoreIds.next('m'),
        agentId: agent.id,
        sessionId: session.sessionId,
        role: role,
        content: content,
        timestamp: ++clock,
        kind: kind,
        toolName: toolName,
        toolResult: toolResult,
        toolCallId: toolName == null ? null : 'call_$toolName',
      ),
    );
  }

  /// 简易重复拼接（Dart 没有字符串乘法）。
  String repeated(String text, int times) =>
      List<String>.filled(times, text).join();

  void addTurn(String tag) {
    add('user', '需求$tag');
    add('agent', '回答$tag');
  }

  /// 直接取该会话的全部消息（构造 buildPlan 的输入）。
  List<CoreMessage> messages() => store.messages(agent.id, session.sessionId);

  group('切点计算（纯函数）', () {
    test('保留最近 N 条用户要求及其之后，其余是前缀', () {
      addTurn('一');
      addTurn('二');
      addTurn('三');
      final KeepPlan plan = service.buildPlan(messages());
      expect(plan.cut, 2, reason: '前两条消息（需求一/回答一）进总结');
      expect(
        plan.summarize.map((CoreMessage m) => m.content).toList(),
        <String>['需求一', '回答一'],
      );
      expect(plan.keep.map((CoreMessage m) => m.content).toList(), <String>[
        '需求二',
        '回答二',
        '需求三',
        '回答三',
      ]);
      // 不变量：被总结的永远是前缀
      expect(plan.summarize, messages().sublist(0, plan.cut));
      expect(plan.keep, messages().sublist(plan.cut));
    });

    test('保留区可以是工具卡片开头：引擎会把 tool_calls 补回来', () {
      add('user', 'u1');
      add('agent', 'a1');
      add('agent', 'a2');
      add('agent', '', kind: 'tool', toolName: 'read', toolResult: '工具结果');
      add('agent', '', kind: 'tool', toolName: 'grep', toolResult: '匹配');
      final CompactionService tight = CompactionService(
        store: store,
        settings: settings,
        summarizer: summarizer,
        keepRecentUserMessages: 1,
        keepTailLength: 1,
        minSummarizeMessages: 2,
      );
      final KeepPlan plan = tight.buildPlan(messages());
      expect(plan.cut, 4, reason: '尾部 1 条 + 单轮退化规则');
      expect(plan.keep, hasLength(1));
      expect(plan.keep.single.isTool, isTrue);
      expect(plan.keep, messages().sublist(plan.cut));
    });

    test('单轮超长：用户消息很少也要能压（退化为只保留尾部）', () {
      add('user', '一个很大的任务');
      for (int i = 0; i < 12; i++) {
        add('agent', '', kind: 'tool', toolName: 'read', toolResult: '结果$i');
      }
      final KeepPlan plan = service.buildPlan(messages());
      expect(plan.cut, greaterThan(0), reason: '否则这种会话永远压不动');
      expect(plan.keep.length, lessThanOrEqualTo(8));
    });
  });

  group('手动压缩', () {
    test('总结写回会话 + 水位线推进 + context_size 反映新上下文', () async {
      addTurn('一');
      addTurn('二');
      addTurn('三');
      final CompactionResult result = await service.compact(
        agent.id,
        session.sessionId,
      );
      expect(result.error, isEmpty);
      expect(result.compressed, isTrue);
      expect(result.summarizedMessages, 2);
      expect(result.contextSize, 5, reason: '1 条摘要 + 保留 4 条');
      final CoreSession after = store.session(agent.id, session.sessionId)!;
      expect(after.compacted, isTrue);
      expect(after.compactedMessageCount, 2);
      expect(after.compactedSummary, contains('总结正文'));
      // 提示词里必须带上被总结的内容，且不该包含保留区的内容
      expect(summarizer.prompts.single, contains('需求一'));
      expect(summarizer.prompts.single, contains('用户目标与约束'));
      expect(summarizer.prompts.single, isNot(contains('需求三')));
    });

    test('再次压缩会把上一次的摘要并入新摘要，且水位线继续前进', () async {
      addTurn('一');
      addTurn('二');
      addTurn('三');
      await service.compact(agent.id, session.sessionId);
      addTurn('四');
      addTurn('五');
      addTurn('六');
      final CompactionResult second = await service.compact(
        agent.id,
        session.sessionId,
      );
      expect(second.compressed, isTrue);
      expect(summarizer.prompts, hasLength(2));
      expect(
        summarizer.prompts[1],
        contains('此前已经总结过的内容'),
        reason: '旧摘要要参与新总结，否则多次压缩会丢掉早期内容',
      );
      final CoreSession after = store.session(agent.id, session.sessionId)!;
      expect(after.compactedMessageCount, greaterThan(2));
    });

    test('原因判定：会话不存在 / 对话太少 / 都在保留窗口内 / 无总结器', () async {
      expect(
        (await service.compact(agent.id, 'ses_missing')).reason,
        'no_active_session',
      );
      expect(
        (await service.compact(agent.id, session.sessionId)).reason,
        'too_few_messages',
        reason: '一条消息都没有',
      );
      addTurn('一');
      expect(
        (await service.compact(agent.id, session.sessionId)).reason,
        'nothing_to_summarize',
        reason: '只有一轮对话：保留窗口已覆盖，没必要压',
      );
      // 四轮对话 + 保留窗口 2 条：前两轮确实在窗口之外，应当能压
      addTurn('二');
      addTurn('三');
      addTurn('四');
      expect(
        (await service.compact(agent.id, session.sessionId)).compressed,
        isTrue,
        reason: '保留窗口只覆盖最近两条用户要求',
      );
      final CompactionService bare = CompactionService(
        store: store,
        settings: settings,
      );
      expect(
        (await bare.compact(agent.id, session.sessionId)).reason,
        'no_summarizer',
      );
    });

    test('压缩中重复触发 -> already_compacting（防双击，慢总结也不并发）', () async {
      final Completer<void> gate = Completer<void>();
      final CompactionService slow = CompactionService(
        store: store,
        settings: settings,
        summarizer: _FakeSummarizer(gate: gate),
      );
      addTurn('一');
      addTurn('二');
      addTurn('三');
      final Future<CompactionResult> first = slow.compact(
        agent.id,
        session.sessionId,
      );
      expect(slow.isCompacting(agent.id, session.sessionId), isTrue);
      expect(
        (await slow.compact(agent.id, session.sessionId)).reason,
        'already_compacting',
      );
      gate.complete();
      expect((await first).compressed, isTrue);
      expect(slow.isCompacting(agent.id, session.sessionId), isFalse);
    });

    test('总结失败回退到截断摘要：压缩照样成功，不把上下文丢掉', () async {
      final CompactionService broken = CompactionService(
        store: store,
        settings: settings,
        summarizer: _FakeSummarizer(error: '端点 500'),
        keepRecentUserMessages: 2,
        keepTailLength: 2,
      );
      addTurn('一');
      addTurn('二');
      addTurn('三');
      final CompactionResult result = await broken.compact(
        agent.id,
        session.sessionId,
      );
      expect(result.compressed, isTrue);
      expect(result.summary, contains('历史要点'));
      expect(store.session(agent.id, session.sessionId)!.compacted, isTrue);
    });
  });

  group('自动压缩与估算', () {
    test('低于阈值不动，超过阈值才压', () async {
      addTurn('一');
      addTurn('二');
      expect(await service.autoCompact(agent, session), isNull);
      // 填到明显超过 0.5 × 1000 token
      for (int i = 0; i < 40; i++) {
        add('user', '需求$i ${repeated('内容', 30)}');
        add('agent', '回答$i ${repeated('内容', 30)}');
      }
      expect(
        service.estimateContextTokens(agent, session),
        greaterThan((1000 * service.thresholdFor(agent)).round()),
      );
      final CompactionResult? result = await service.autoCompact(
        agent,
        session,
      );
      expect(result, isNotNull);
      expect(result!.compressed, isTrue);
    });

    test('阈值为 agent 级覆盖并夹在 0.1~0.95', () {
      expect(service.thresholdFor(agent), 0.5);
      agent.compressThreshold = 5;
      expect(service.thresholdFor(agent), 0.95);
      agent.compressThreshold = 0.01;
      expect(service.thresholdFor(agent), 0.1);
      agent.compressThreshold = 0;
      expect(service.thresholdFor(agent), 0.8, reason: '0 = 未覆盖，用默认值');
    });

    test('估算口径 = 系统提示词 + 摘要 + 未压缩历史', () async {
      addTurn('一');
      addTurn('二');
      addTurn('三');
      await service.compact(agent.id, session.sessionId);
      final CoreSession after = store.session(agent.id, session.sessionId)!;
      final int expected =
          estimateTokens(agent.systemPrompt) +
          estimateTokens(after.compactedSummary) +
          store
              .messages(agent.id, session.sessionId)
              .skip(after.compactedMessageCount)
              .fold<int>(
                0,
                (int sum, CoreMessage m) => sum + estimateTokens(m.content),
              );
      expect(service.estimateContextTokens(agent, after), expected);
    });

    test('dispose 转交总结器', () async {
      await service.dispose();
      expect(summarizer.closed, isTrue);
    });
  });
}
