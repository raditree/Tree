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

  /// 非空时在总结过程中回调一次 `onNotice`（模拟"压缩也在重试"）。
  String? noticeText;

  @override
  Future<String> summarize(
    CoreAgent agent,
    String prompt, {
    void Function(String notice)? onNotice,
  }) async {
    prompts.add(prompt);
    if (noticeText != null) onNotice?.call(noticeText!);
    if (gate != null) await gate!.future;
    if (error != null) throw StateError('$error');
    return '总结正文';
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

/// 中转点入参收集器：把 `system.relay.context.compact` 那一跳收到的原料原样留证。
///
/// 参数表必须与 [CompactionRelayHook] 逐字一致——核心改了契约这里就编译不过，
/// 比"运行时断言字段存在"更早一步发现破约。默认"接管"，回一份两段上下文。
class _RelayCapture {
  _RelayCapture({
    this.context = const <Map<String, dynamic>>[
      <String, dynamic>{'role': 'system', 'content': '插件产出的上下文'},
    ],
    this.covered = -1, // -1 = 覆盖全部原文（由 hook 自己算）
    this.error,
  });

  /// 回给核心的整份上下文。
  final List<Map<String, dynamic>> context;

  /// 回传的覆盖条数；负数 = 覆盖全部。
  final int covered;

  /// 非空则抛出（验 fail-open 回退内置）。
  final Object? error;

  int calls = 0;
  String systemPrompt = '';
  int frozen = -1;
  int total = -1;
  String existingSummary = '';
  Map<String, dynamic>? wireRequest;

  CompactionRelayHook get hook =>
      ({
        required CoreAgent agent,
        required CoreSession session,
        required String systemPrompt,
        required int totalMessageCount,
        required int compactedMessageCount,
        required String existingSummary,
        required Map<String, dynamic>? wireRequest,
      }) async {
        calls++;
        this.systemPrompt = systemPrompt;
        total = totalMessageCount;
        frozen = compactedMessageCount;
        this.existingSummary = existingSummary;
        this.wireRequest = wireRequest;
        if (error != null) throw StateError('$error');
        return CompactionRelayReply(
          messages: context,
          coveredMessageCount: covered < 0 ? totalMessageCount : covered,
        );
      };
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
    List<Map<String, dynamic>>? attachments,
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
        attachments: attachments,
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
      expect(result.degraded, isTrue, reason: '总结失败必须对调用方可见（Q1-③：压缩失败必须前端可见）');
      expect(result.toJson()['degraded'], isTrue);
      // 失败原因必须带出来：只报"总结失败"用户无法判断是密钥 / 限流 / 网络
      expect(result.degradedReason, contains('端点 500'));
      expect(
        result.toJson()['degraded_reason'],
        contains('端点 500'),
        reason: '降级原因要随 REST 响应一起回给前端',
      );
    });

    test('总结成功不标记降级', () async {
      addTurn('一');
      addTurn('二');
      addTurn('三');
      final CompactionResult result = await service.compact(
        agent.id,
        session.sessionId,
      );
      expect(result.compressed, isTrue);
      expect(result.degraded, isFalse);
      expect(result.toJson().containsKey('degraded'), isFalse);
    });
  });

  group('自动压缩与估算', () {
    test('低于阈值不动，超过阈值才压', () async {
      addTurn('一');
      addTurn('二');
      // 估算里含**系统提示词**（它随产品演进变长）⇒ 预算按"当前估算"给，别假设提示词有多小：
      // 先给 4 倍（阈值 0.5 ⇒ 上限 = 当前估算 × 2），"低于阈值"这一前提才是自证的。
      final int base = service.estimateContextTokens(agent, session);
      agent.maxSeqlenOverride = base * 4;
      store.putAgent(agent);
      final int limit =
          (service.maxSeqlenFor(agent).value * service.thresholdFor(agent))
              .round();
      expect(service.estimateContextTokens(agent, session), lessThan(limit));
      expect(await service.autoCompact(agent, session), isNull);

      // 自适应填到明显超过阈值（不再写死条数：写死的条数会在提示词变长时失真）
      int i = 0;
      while (service.estimateContextTokens(agent, session) <= limit &&
          i < 500) {
        add('user', '需求$i ${repeated('内容', 30)}');
        add('agent', '回答$i ${repeated('内容', 30)}');
        i++;
      }
      expect(
        service.estimateContextTokens(agent, session),
        greaterThan(limit),
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

    test('估算口径 = 系统提示词（含工作空间软约束）+ 摘要 + 未压缩历史', () async {
      addTurn('一');
      addTurn('二');
      addTurn('三');
      await service.compact(agent.id, session.sessionId);
      final CoreSession after = store.session(agent.id, session.sessionId)!;
      final int expected =
          estimateTokens(systemPromptWithWorkspace(agent)) +
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

    test('估算口径 = 实际发送：思考只在"回传思考"开启时计入', () async {
      final String thinking = repeated('思考内容', 300); // 2400 字符
      add('agent', thinking, kind: 'thinking');
      add('user', '需求');
      add('agent', '回答');
      final int off = service.estimateContextTokens(agent, session);
      expect(
        off,
        lessThan(estimateTokens(thinking)),
        reason: '关闭回传时引擎根本不发思考，估算不能把它算进上下文（曾因此提前压缩）',
      );

      settings.model('demo')!.thinking = true; // 与引擎同一判据
      final int on = service.estimateContextTokens(agent, session);
      expect(
        on - off,
        estimateTokens(thinking),
        reason: '开启回传后思考就是上下文的一部分，必须计入',
      );

      // agent 级覆盖优先于模型默认（右栏「回传思考」三态）
      agent.thinkingOverride = false;
      expect(
        service.estimateContextTokens(agent, session),
        off,
        reason: '本 Agent 显式关掉时，即使模型默认开启也不能把思考算进上下文',
      );
      agent.thinkingOverride = null;
      expect(service.estimateContextTokens(agent, session), on);
    });

    test('估算口径 = 实际发送：超长工具结果按门控后的预览计，不按全文', () async {
      final String huge = repeated('日志行', 20000); // 60000 字符，远超 8000 token 阈值
      final double scale = service.tokenScaleFor(agent);
      final ToolResultGate gate = ToolResultGate(
        agentId: agent.id,
        tokenScale: scale,
      );
      add('user', '跑一下');
      final int before = service.estimateContextTokens(agent, session);
      add('agent', '', kind: 'tool', toolName: 'terminal', toolResult: huge);
      final int after = service.estimateContextTokens(agent, session);
      final int expected =
          estimateTokensFromChars(gate.forModelChars(huge), scale: scale) +
          estimateTokens('terminal', scale: scale) +
          estimateTokens('{}', scale: scale) +
          8;
      expect(after - before, expected, reason: '估算必须与引擎送出的那一份（预览 + 提示）同口径');
      expect(
        after - before,
        lessThan(estimateTokens(huge) ~/ 10),
        reason: '按全文估算会让压缩阈值提前触发（实测一个会话多算了 11 万 token）',
      );
    });

    test('dispose 转交总结器', () async {
      await service.dispose();
      expect(summarizer.closed, isTrue);
    });
  });

  group('预算来源与轮内压缩（Q1-③）', () {
    test('模型没配 max_seqlen：预算走兜底值并显式标注', () {
      final CompactionService bare = CompactionService(
        store: store,
        settings: CoreSettings(),
        summarizer: summarizer,
      );
      final MaxSeqlenBudget budget = bare.maxSeqlenFor(agent);
      expect(budget.fallback, isTrue, reason: '没配置就要标注，不能默默兜底');
      expect(budget.value, CoreSettings.fallbackMaxSeqlen);
      final MaxSeqlenBudget configured = service.maxSeqlenFor(agent);
      expect(configured.fallback, isFalse);
      expect(configured.value, 1000);
    });

    test('成员级 max_seqlen 覆盖优先于模型默认（与引擎发请求同口径）', () {
      agent.maxSeqlenOverride = 4000;
      store.putAgent(agent);
      expect(service.maxSeqlenFor(agent).value, 4000);
      expect(service.maxSeqlenFor(agent).fallback, isFalse);
    });

    test('force：端点已报超限时跳过阈值判断强制压一次', () async {
      addTurn('一');
      addTurn('二');
      addTurn('三');
      // 估算含系统提示词 ⇒ 预算按当前估算给足，"远低于阈值"这一前提才成立
      agent.maxSeqlenOverride = service.estimateContextTokens(agent, session) * 4;
      store.putAgent(agent);
      expect(
        await service.autoCompact(agent, session),
        isNull,
        reason: '估算远低于阈值，正常判断不动',
      );
      final CompactionResult? forced = await service.autoCompact(
        agent,
        session,
        force: true,
      );
      expect(forced, isNotNull);
      expect(forced!.compressed, isTrue);
      expect(summarizer.prompts, hasLength(1));
    });

    test('估算口径跟随逐模型 token_scale（Q1-①）', () {
      add('user', '内容' * 500);
      final int atDefault = service.estimateContextTokens(agent, session);
      settings.model('demo')!.tokenScale = 1;
      final int atOne = service.estimateContextTokens(agent, session);
      expect(atOne, greaterThan(atDefault));
      settings.model('demo')!.tokenScale = 4;
      expect(
        service.estimateContextTokens(agent, session),
        lessThan(atDefault),
      );
    });
  });

  group('会话服务的压缩接线（Q1-③）', () {
    test('构造会话服务时把轮内压缩钩子接到 LLM 引擎上', () {
      final LlmAgentEngine engine = LlmAgentEngine(
        resolveModel: (String id) => null,
      );
      expect(engine.toolTurnCompactor, isNull, reason: '引擎自己是不认识存储的');
      ConversationService(
        store: store,
        hub: WsHub(),
        settings: settings,
        compaction: service,
        engine: engine,
      );
      expect(engine.toolTurnCompactor, isNotNull);
    });

    test('钩子回调真的压缩，并交回刷新过的上下文快照', () async {
      addTurn('一');
      addTurn('二');
      addTurn('三');
      final LlmAgentEngine engine = LlmAgentEngine(
        resolveModel: (String id) => null,
      );
      ConversationService(
        store: store,
        hub: WsHub(),
        settings: settings,
        compaction: service,
        engine: engine,
      );
      final AgentRunContext? refreshed = await engine.toolTurnCompactor!(
        agent.id,
        session.sessionId,
        force: true,
      );
      expect(refreshed, isNotNull);
      expect(
        refreshed!.contextSummary,
        isNotEmpty,
        reason: '摘要必须刷新进上下文，否则"压了等于没压"',
      );
      expect(refreshed.compactedMessageCount, greaterThan(0));
      expect(refreshed.history.last.content, '回答三');
      expect(summarizer.prompts, hasLength(1));
    });

    test('压缩时的重试进度落成 llm_hidden 提示：用户看得见、模型看不到', () async {
      addTurn('一');
      addTurn('二');
      addTurn('三');
      summarizer.noticeText =
          '模型端点调用失败（第 1/5 次重试，5s 后重试）：读取模型响应失败';
      final LlmAgentEngine engine = LlmAgentEngine(
        resolveModel: (String id) => null,
      );
      ConversationService(
        store: store,
        hub: WsHub(),
        settings: settings,
        compaction: service,
        engine: engine,
      );

      final AgentRunContext? refreshed = await engine.toolTurnCompactor!(
        agent.id,
        session.sessionId,
        force: true,
      );

      expect(refreshed, isNotNull, reason: '提示不影响压缩本身');
      final CoreMessage notice = store
          .messages(agent.id, session.sessionId)
          .lastWhere(
            (CoreMessage m) => m.content.contains('第 1/5 次重试'),
          );
      expect(notice.llmHidden, isTrue, reason: '压缩进度不给模型看');
      expect(notice.kind, 'text', reason: '照常发：前端当普通气泡渲染');
      expect(notice.role, 'agent');
    });

    test('没到阈值时钩子返回 null（引擎保持原上下文）', () async {
      addTurn('一');
      final LlmAgentEngine engine = LlmAgentEngine(
        resolveModel: (String id) => null,
      );
      ConversationService(
        store: store,
        hub: WsHub(),
        settings: settings,
        compaction: service,
        engine: engine,
      );
      expect(
        await engine.toolTurnCompactor!(
          agent.id,
          session.sessionId,
          force: false,
        ),
        isNull,
      );
    });
  });

  group('用户上传的附件：估算与摘要共同口径', () {
    const List<Map<String, dynamic>> attachments = <Map<String, dynamic>>[
      <String, dynamic>{'name': '图片.png', 'path': '.input/20261001/图片.png'},
    ];

    test('附件段计入估算（引擎实际发出的那一份）', () {
      add('user', '看这张图', attachments: attachments);
      final int expected =
          estimateTokens(systemPromptWithWorkspace(agent)) +
          estimateTokens('看这张图') +
          estimateTokens(attachmentsPromptSuffix(attachments));
      expect(service.estimateContextTokens(agent, session), expected);
    });

    test('没有附件的消息不凭空多算', () {
      add('user', '看这张图');
      final int expected =
          estimateTokens(systemPromptWithWorkspace(agent)) +
          estimateTokens('看这张图');
      expect(service.estimateContextTokens(agent, session), expected);
    });

    test('摘要输入保留附件路径：压缩后模型仍知道用户发过哪些文件', () async {
      add('user', '看这张图', attachments: attachments);
      add('agent', '好的');
      addTurn('二');
      addTurn('三');
      addTurn('四');
      final CompactionResult result = await service.compact(
        agent.id,
        session.sessionId,
      );
      expect(result.compressed, isTrue);
      expect(summarizer.prompts, hasLength(1));
      expect(summarizer.prompts.single, contains('.input/20261001/图片.png'));
    });
  });

  group('压缩中转点：原料只有"引擎真会发的那份"，回包是整份上下文', () {
    test('接管：拿到总量/水位线/线形前缀，落库为 compactedContext，内置摘要器不参与', () async {
      addTurn('一');
      addTurn('二');
      addTurn('三');
      final _RelayCapture seen = _RelayCapture(
        context: const <Map<String, dynamic>>[
          <String, dynamic>{'role': 'system', 'content': '插件定的系统提示词'},
          <String, dynamic>{'role': 'user', 'content': '插件压出来的历史'},
        ],
        covered: 4,
      );
      service.relayHook = seen.hook;
      // 线形前缀由引擎提供（这里用假货验"服务只是转发，自己不认识线形态"）
      service.wireRequestProvider = (CoreAgent agent, CoreSession session) async =>
          <String, dynamic>{
            'model': 'demo',
            'messages': <Map<String, dynamic>>[
              <String, dynamic>{'role': 'system', 'content': '引擎的提示词'},
              <String, dynamic>{'role': 'user', 'content': '引擎看到的历史'},
            ],
            'tools': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'function',
                'function': <String, dynamic>{'name': 'read'},
              },
            ],
          };
      final CompactionResult result = await service.compact(
        agent.id,
        session.sessionId,
      );

      expect(result.compressed, isTrue);
      expect(result.source, compactionSourceRelay);
      expect(result.summary, isEmpty, reason: '中转站路径产出的是列表，不是摘要文本');
      expect(result.summarizedMessages, 4, reason: '本次新覆盖 4 条');
      expect(result.contextSize, 2 + (6 - 4), reason: '列表 2 条 + 水位线之后 2 条原文');
      expect(summarizer.prompts, isEmpty, reason: '接管了就不该再调内置摘要器');

      // 入参：系统提示词 + 总量 + 水位线 + 引擎口径的线形前缀
      expect(
        seen.systemPrompt,
        systemPromptWithWorkspace(agent, sessionId: session.sessionId),
      );
      expect(seen.total, 6, reason: '原文总条数（covered 的合法上界）');
      expect(seen.frozen, 0);
      expect(seen.existingSummary, isEmpty);
      expect(seen.wireRequest, isNotNull);
      expect(
        (seen.wireRequest!['messages'] as List<dynamic>).length,
        2,
        reason: '线形前缀原样转发给插件',
      );

      // 落库：列表是权威，摘要被清空；水位线按回包的 covered_message_count
      final CoreSession after = store.session(agent.id, session.sessionId)!;
      expect(after.compactedContext, hasLength(2));
      expect(after.compactedContext.first['content'], '插件定的系统提示词');
      expect(after.compactedSummary, isEmpty, reason: '两条路径互斥：列表接管即清摘要');
      expect(after.compactedMessageCount, 4);
      expect(after.compacted, isTrue);
    });

    test('前缀提供者缺失或抛异常 ⇒ 插件拿不到 request，但压缩流程照走（fail-open）', () async {
      addTurn('一');
      addTurn('二');
      addTurn('三');
      final _RelayCapture seen = _RelayCapture(covered: 4);
      service.relayHook = seen.hook;
      service.wireRequestProvider = (CoreAgent agent, CoreSession session) async =>
          throw StateError('引擎拼不出来');
      final CompactionResult result = await service.compact(
        agent.id,
        session.sessionId,
      );
      expect(result.compressed, isTrue);
      expect(seen.wireRequest, isNull, reason: '拼不出来就给 null（插件据此不接管）');
    });

    test('内置规则说"没得压"时中转站照样接管（证明核心没做规划）', () async {
      addTurn('一');
      // 只有一轮对话：内置路径会判 nothing_to_summarize/too_few_messages
      addTurn('二');
      final _RelayCapture seen = _RelayCapture(covered: 4);
      service.relayHook = seen.hook;
      final CompactionResult result = await service.compact(
        agent.id,
        session.sessionId,
      );
      expect(seen.calls, 1, reason: '中转站先拿到整份原料，核心不预判"没得压"');
      expect(result.compressed, isTrue);
      expect(result.source, compactionSourceRelay);
    });

    test('回包越界 / 抛异常 / 回 null ⇒ 一律回退内置 compact，绝不猜水位线', () async {
      // ① 越界：covered 超过原文总条数（只有一轮对话，内置也因此压不动）
      addTurn('一');
      final List<String> logs = <String>[];
      final CompactionService withLog = CompactionService(
        store: store,
        settings: settings,
        summarizer: summarizer,
        keepRecentUserMessages: 2,
        keepTailLength: 2,
        minSummarizeMessages: 4,
        log: logs.add,
      );
      withLog.relayHook = _RelayCapture(covered: 99).hook;
      final CompactionResult overflow = await withLog.compact(
        agent.id,
        session.sessionId,
      );
      expect(
        overflow.compressed,
        isFalse,
        reason: '越界 ⇒ 不接管；内置也判"没得压" ⇒ 如实返回原因',
      );
      expect(
        logs.any((String l) => l.contains('covered_message_count')),
        isTrue,
        reason: '越界必须留下可读日志',
      );
      expect(
        store.session(agent.id, session.sessionId)!.compactedContext,
        isEmpty,
      );

      // ①b 水位线**不许倒退**：covered < 当前 compactedMessageCount 同样按不接管处理
      //     （否则"下一轮从哪继续"会往回走，已压掉的内容被重复发送）
      addTurn('二');
      addTurn('三');
      addTurn('四');
      await service.compact(agent.id, session.sessionId); // 先内置压一次
      final int watermark = store
          .session(agent.id, session.sessionId)!
          .compactedMessageCount;
      expect(watermark, greaterThan(0));
      final List<String> backLogs = <String>[];
      final CompactionService backwards = CompactionService(
        store: store,
        settings: settings,
        summarizer: summarizer,
        keepRecentUserMessages: 2,
        keepTailLength: 2,
        minSummarizeMessages: 4,
        log: backLogs.add,
      )..relayHook = _RelayCapture(covered: watermark - 1).hook;
      addTurn('五');
      final CompactionResult regressed = await backwards.compact(
        agent.id,
        session.sessionId,
      );
      expect(
        backLogs.any((String l) => l.contains('covered_message_count')),
        isTrue,
        reason: '水位线倒退必须留下可读日志',
      );
      expect(
        store.session(agent.id, session.sessionId)!.compactedMessageCount,
        greaterThanOrEqualTo(watermark),
        reason: '无论谁接管，水位线都只能前进',
      );
      expect(
        regressed.source == compactionSourceRelay,
        isFalse,
        reason: '倒退的回包不该被采纳（要么内置接管、要么如实说没得压）',
      );

      // ② 抛异常：同样回退内置（fail-open），不把异常抛给调用方
      addTurn('二');
      addTurn('三');
      addTurn('四');
      final CompactionService throwing = CompactionService(
        store: store,
        settings: settings,
        summarizer: summarizer,
        keepRecentUserMessages: 2,
        keepTailLength: 2,
        minSummarizeMessages: 4,
      );
      throwing.relayHook = _RelayCapture(error: '插件炸了').hook;
      final CompactionResult afterThrow = await throwing.compact(
        agent.id,
        session.sessionId,
      );
      expect(afterThrow.compressed, isTrue);
      expect(afterThrow.source, compactionSourceBuiltin);
      expect(
        store.session(agent.id, session.sessionId)!.compactedSummary,
        isNotEmpty,
      );

      // ③ 显式不接管（回 null）：把列表清空、摘要写回（互斥的另一半）
      addTurn('五');
      addTurn('六');
      addTurn('七');
      final CompactionService declining = CompactionService(
        store: store,
        settings: settings,
        summarizer: summarizer,
        keepRecentUserMessages: 2,
        keepTailLength: 2,
        minSummarizeMessages: 4,
      );
      declining.relayHook =
          ({
            required CoreAgent agent,
            required CoreSession session,
            required String systemPrompt,
            required int totalMessageCount,
            required int compactedMessageCount,
            required String existingSummary,
            required Map<String, dynamic>? wireRequest,
          }) async => null;
      final CompactionResult viaBuiltin = await declining.compact(
        agent.id,
        session.sessionId,
      );
      expect(viaBuiltin.source, compactionSourceBuiltin);
      final CoreSession afterBuiltin = store.session(
        agent.id,
        session.sessionId,
      )!;
      expect(afterBuiltin.compactedSummary, isNotEmpty);
      expect(
        afterBuiltin.compactedContext,
        isEmpty,
        reason: '互斥：内置摘要接管时清掉中转站的列表',
      );
    });

    test('无中转点接线时行为逐字不变（canCompact 只认内置摘要器）', () async {
      addTurn('一');
      addTurn('二');
      addTurn('三');
      expect(service.relayHook, isNull);
      final CompactionResult result = await service.compact(
        agent.id,
        session.sessionId,
      );
      expect(result.compressed, isTrue);
      expect(result.source, compactionSourceBuiltin);
      expect(result.summary, contains('总结正文'));
      final CoreSession after = store.session(agent.id, session.sessionId)!;
      expect(after.compactedContext, isEmpty);
      expect(after.compactedSummary, contains('总结正文'));
    });
  });
}
