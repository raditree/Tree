import 'dart:convert';
import 'dart:math';

import '../llm/llm_result_gate.dart';
import '../settings/core_settings.dart';
import '../store/tree_store.dart';
import '../util/tokens.dart';
import 'workspace_prompt.dart';

/// 上下文压缩（M7d-4）。
///
/// 问题：桌面端每轮请求都要把**整段会话历史**发给端点，长程任务必然撞上上下文
/// 上限（现在的兜底是 [LlmSession] 的"按 user 边界硬裁"，裁掉就是永久丢失）。
///
/// 做法（与旧后端同口径，面向长程任务设计）：
/// - 系统提示词（agent 的 system prompt）不进压缩，永远保留；
/// - **优先保留用户输入**：保留最近 [keepRecentUserMessages] 条用户消息及其之后的
///   全部消息；
/// - 若当前活动轮次的尾部比这还长，则只保留最后 [keepTailLength] 条消息——
///   避免单轮超长工具轨迹把上下文撑爆（这正是旧后端 `KEEP_TAIL_LENGTH` 的用意）；
/// - 两条规则取**更靠前**的切点：切点之后原样保留，切点之前交给模型总结成
///   一条摘要，之后每轮只带「摘要 + 未压缩的近期消息」。
///
/// 与旧后端的一个差异（有意为之）：旧后端会把"保留的用户消息"提到摘要后面
/// **重排**上下文；桌面端的历史同时是界面历史，重排会让"界面顺序"与"模型看到的
/// 顺序"不一致，因此这里只做**前缀切分**——切点之前的都进摘要，之后都原样保留。
///
/// 不变量（测试覆盖）：
/// - 压缩**不删除任何消息**：`messages.jsonl` 是全文，界面照旧能回看；压缩只
///   推进会话上的"已总结前缀长度"（[CoreSession.compactedMessageCount]）——这也
///   正是旧后端 `agent_context` 归档表想做的事，桌面端用"不删"自然得到归档；
/// - 被总结的永远是历史的一个**前缀**，水位线因此可以用"条数"表达；
/// - 再次压缩会把上一次的摘要并进新摘要（只留一条，不会越压越多）。
class CompactionService {
  CompactionService({
    required this.store,
    required this.settings,
    this.summarizer,
    this.keepRecentUserMessages = 3,
    this.keepTailLength = 8,
    this.minSummarizeMessages = 4,
    this.summarizeCharLimit = 12000,
    this.defaultThreshold = 0.8,
    this.log,
  });

  final TreeStore store;
  final CoreSettings settings;

  /// 总结器（生产用 LlmSummarizer，测试注入假实现）；null = 不具备压缩能力。
  final ContextSummarizer? summarizer;

  /// 保留最近多少条用户消息原文。
  final int keepRecentUserMessages;

  /// 额外保留当前活动轮次尾部多少条消息。
  final int keepTailLength;

  /// "单轮超长"退化规则的生效门槛：只有尾部之外**至少**有这么多条消息时，才允许
  /// 把最后一条用户消息也压进摘要（否则两三条消息的会话会被无意义地压一次）。
  final int minSummarizeMessages;

  /// 送进总结提示词的字符上限（超出按字符截断，避免总结请求本身超长）。
  final int summarizeCharLimit;

  /// 未单独配置 `compress_threshold` 时的默认阈值。
  final double defaultThreshold;

  final void Function(String message)? log;

  /// 正在压缩的「agent::session」（防双击 + 自动/手动互斥）。
  final Set<String> _compacting = <String>{};

  static String _key(String agentId, String sessionId) =>
      '$agentId::$sessionId';

  /// 该会话是否正在压缩。
  bool isCompacting(String agentId, String sessionId) =>
      _compacting.contains(_key(agentId, sessionId));

  /// 压缩阈值（0.1~0.95）：agent 级覆盖优先，否则 [defaultThreshold]。
  double thresholdFor(CoreAgent agent) {
    final double value = agent.compressThreshold > 0
        ? agent.compressThreshold
        : defaultThreshold;
    return value.clamp(0.1, 0.95);
  }

  /// 手动压缩（`compact` 按钮）。返回值直接喂前端文案（`reason` 是契约的一部分）。
  Future<CompactionResult> compact(String agentId, String sessionId) async {
    final CoreAgent? agent = store.agent(agentId);
    if (agent == null) {
      return CompactionResult(error: 'agent 不存在：$agentId', status: 404);
    }
    final CoreSession? session = _sessionOf(agentId, sessionId);
    if (session == null) {
      return const CompactionResult(reason: 'no_active_session');
    }
    if (summarizer == null) {
      return const CompactionResult(reason: 'no_summarizer');
    }
    if (isCompacting(agentId, session.sessionId)) {
      return CompactionResult(
        reason: 'already_compacting',
        sessionId: session.sessionId,
      );
    }
    _compacting.add(_key(agentId, session.sessionId));
    try {
      return await _compact(agent, session);
    } finally {
      _compacting.remove(_key(agentId, session.sessionId));
    }
  }

  /// 自动压缩：估算上下文超过「threshold × max_seqlen」才动，否则返回 null。
  ///
  /// 由会话服务在**每轮生成前**与**工具循环的每一轮 API 调用前**调用（相当于旧
  /// 后端 llm.py 里的 `_compress_context`）。自动压缩失败不影响本轮生成：调用方
  /// 负责把失败**显示给用户**（只记日志等于没发生，用户只会看到"怎么还是超"）。
  ///
  /// [force] 为真 = 端点已经报了上下文超限，此时**跳过阈值判断**强制压一次：
  /// 本地估算偏小（token_scale 还在学习）时，阈值判断恰恰会说"没超"。
  Future<CompactionResult?> autoCompact(
    CoreAgent agent,
    CoreSession session, {
    bool force = false,
  }) async {
    if (summarizer == null || isCompacting(agent.id, session.sessionId)) {
      return null;
    }
    final MaxSeqlenBudget budget = maxSeqlenFor(agent);
    final int limit = (budget.value * thresholdFor(agent)).round();
    final int used = estimateContextTokens(agent, session);
    if (!force && used <= limit) return null;
    log?.call(
      force
          ? '端点报上下文超限，强制压缩：估算 $used tokens（阈值 $limit）'
          : '上下文估算 $used tokens 超过阈值 $limit'
                '（${thresholdFor(agent)} × ${budget.value}），先压缩再生成',
    );
    if (budget.fallback) {
      log?.call(
        '模型 ${agent.modelId} 未配置 max_seqlen，'
        '上面的阈值用的是兜底值 ${CoreSettings.fallbackMaxSeqlen}；'
        '请到「设置 → 自定义模型」补上该模型的上下文长度',
      );
    }
    return compact(agent.id, session.sessionId);
  }

  /// 该 agent 的上下文长度预算（Q1-③）。
  ///
  /// 取不到配置时**不再默默兜 128000**：照样返回兜底值让压缩判断继续工作，
  /// 但 [MaxSeqlenBudget.fallback] 为真，调用方据此在日志与前端显式提示
  /// "去设置页补模型配置"。成员级覆盖优先于模型默认值——引擎按覆盖后的值发请求，
  /// 压缩若按模型默认值判断，就会出现"压了还是超"。
  MaxSeqlenBudget maxSeqlenFor(CoreAgent agent) {
    if (agent.maxSeqlenOverride > 0) {
      return MaxSeqlenBudget(agent.maxSeqlenOverride);
    }
    final int configured = settings.model(agent.modelId)?.maxSeqlen ?? 0;
    if (configured > 0) return MaxSeqlenBudget(configured);
    return const MaxSeqlenBudget(
      CoreSettings.fallbackMaxSeqlen,
      fallback: true,
    );
  }

  /// 逐模型 token_scale（Q1-①）：模型未登记时用全局初值。
  double tokenScaleFor(CoreAgent agent) =>
      settings.model(agent.modelId)?.tokenScale ?? defaultTokenScale;

  /// 是否把历史思考（DeepSeek 的 `reasoning_content`）回传端点：与引擎同一判据
  /// —— **agent 级覆盖优先，否则模型的 `thinking`**（见 [LlmAgentEngine._buildMessages]
  /// 与 `agentOverrides` 的接线）。
  ///
  /// 它决定思考**算不算上下文**：开启回传就要计入估算与总结输入，关闭（默认）就必须
  /// 排除。实测教训：一个会话里思考正文 456,747 字符（≈173k token）被算进估算，
  /// 而引擎压根不发它——估算 411k 触发压缩时，真实上下文只有约 1/3。
  bool passBackReasoningFor(CoreAgent agent) =>
      agent.thinkingOverride ??
      settings.model(agent.modelId)?.thinking ??
      false;

  /// 估算"引擎实际会看到"的上下文 token 数（系统提示词 + 摘要 + 未压缩历史）。
  ///
  /// 比例用该模型的 token_scale（Q1-①）：全系统只有 util/tokens.dart 一个换算
  /// 函数，压缩阈值与进度条才不会各说各话。
  int estimateContextTokens(CoreAgent agent, CoreSession session) {
    final double scale = tokenScaleFor(agent);
    final bool passBack = passBackReasoningFor(agent);
    // 估算必须按"引擎真正发给模型的那一份"算：两处口径一分叉，就会出现
    // "估算说超了、端点说没超"（或反向），压缩时机整个错位。
    // 这里用的门控只为了判定阈值，不落盘也不需要 writer。
    final ToolResultGate gate = ToolResultGate(
      agentId: agent.id,
      tokenScale: scale,
    );
    final List<CoreMessage> all = store.messages(agent.id, session.sessionId);
    final int frozen = session.compactedMessageCount.clamp(0, all.length);
    int total =
        estimateTokens(
          // 与 ConversationService._contextOf 逐字同口径：⑧ 已选 Spec 全文
          // 同样是会话级的，估算漏掉它，压缩阈值就会偏小
          systemPromptWithWorkspace(agent, sessionId: session.sessionId),
          scale: scale,
        ) +
        estimateTokens(session.compactedSummary, scale: scale);
    for (final CoreMessage message in all.sublist(frozen)) {
      total += _messageTokens(message, scale, gate, passBack);
    }
    return total;
  }

  /// 释放资源（幂等；转交总结器）。
  Future<void> dispose() async => summarizer?.close();

  // ── 内部实现 ─────────────────────────────────────────────────────────

  CoreSession? _sessionOf(String agentId, String sessionId) {
    final String id = sessionId.trim().isEmpty
        ? TreeStore.defaultSessionId
        : sessionId.trim();
    return store.session(agentId, id);
  }

  Future<CompactionResult> _compact(
    CoreAgent agent,
    CoreSession session,
  ) async {
    final List<CoreMessage> all = store.messages(agent.id, session.sessionId);
    final int frozen = session.compactedMessageCount.clamp(0, all.length);
    final List<CoreMessage> visible = all.sublist(frozen);
    if (visible.length <= 1) {
      return CompactionResult(
        reason: 'too_few_messages',
        contextSize: visible.length + (frozen > 0 ? 1 : 0),
        sessionId: session.sessionId,
      );
    }
    final KeepPlan plan = buildPlan(visible);
    if (plan.summarize.isEmpty) {
      // 区分"对话本来就短"与"近期对话都在保留窗口内"：前端文案不同
      final bool tooFew =
          visible.where((CoreMessage m) => !m.isTool).length <= 1;
      return CompactionResult(
        reason: tooFew ? 'too_few_messages' : 'nothing_to_summarize',
        contextSize: 1 + plan.keep.length,
        sessionId: session.sessionId,
      );
    }
    final SummaryText summarized = await _summarize(
      agent,
      session,
      plan.summarize,
    );
    // 水位线 = 已冻结前缀 + 本次总结掉的条数（被总结的永远是前缀，见类注释）
    store.setCompacted(
      agent.id,
      session.sessionId,
      summary: summarized.text,
      messageCount: frozen + plan.summarize.length,
    );
    log?.call(
      '上下文已压缩：总结 ${plan.summarize.length} 条，'
      '保留 ${plan.keep.length} 条（agent=${agent.id}）',
    );
    return CompactionResult(
      compressed: true,
      contextSize: 1 + plan.keep.length,
      summarizedMessages: plan.summarize.length,
      summary: summarized.text,
      sessionId: session.sessionId,
      // 总结模型调用失败、退化成截断摘要：压缩本身成功了，但要点可能不全，
      // 调用方要把这件事显示给用户（Q1-③：压缩失败必须可见）。
      // 失败原因一并带出：只报"总结失败"用户无从判断是密钥、限流还是网络。
      degraded: summarized.degraded,
      degradedReason: summarized.degradedReason,
    );
  }

  /// 计算切点：`[0, cut)` 进总结，`[cut, end)` 原样保留。
  ///
  /// 纯函数，单独暴露给测试：保留区的形状是压缩语义的核心，必须能脱离 LLM 断言。
  /// "被总结的永远是前缀"这条不变量由本函数保证——水位线是一个条数，挖空中间
  /// 那种表示法会让水位线失真。
  KeepPlan buildPlan(List<CoreMessage> visible) {
    if (visible.isEmpty) {
      return const KeepPlan(keep: <CoreMessage>[], summarize: <CoreMessage>[]);
    }
    final List<int> userIndices = <int>[
      for (int i = 0; i < visible.length; i++)
        if (!visible[i].isTool && visible[i].role == 'user') i,
    ];
    if (userIndices.isEmpty) {
      return _split(visible, max(0, visible.length - keepTailLength));
    }
    // 最近 N 条用户消息的起点：这里及其之后都保留
    final int from =
        userIndices[max(0, userIndices.length - keepRecentUserMessages)];
    // 当前轮次尾部：至少保留最后一条用户消息及其之后，最多留 keepTailLength 条
    final int tail = max(userIndices.last + 1, visible.length - keepTailLength);
    int cut = min(from, tail);
    // 单轮超长（用户消息很少但工具轨迹极多）：两条规则都指向 0 时退一步只保留
    // 尾部，否则这种会话永远压不动。用户要求会经摘要保留（提示词里明确要求保留
    // 目标与约束），且不做"提到最前"的重排——原因见类注释。
    if (cut == 0 && tail >= minSummarizeMessages) cut = tail;
    return _split(visible, cut);
  }

  /// 按切点切分。切点**允许**落在工具卡片上：保留区若以工具消息开头，引擎会用
  /// 工具卡片里的名称/参数把 assistant 的 tool_calls 补回来（见 LlmAgentEngine），
  /// 因此这里不需要为了"边界好看"往回退——退了反而会让单轮超长的会话压不动。
  static KeepPlan _split(List<CoreMessage> visible, int cut) => KeepPlan(
    cut: cut,
    summarize: visible.sublist(0, cut),
    keep: visible.sublist(cut),
  );

  /// 总结：把待压缩消息（含上一次的摘要）交给模型；失败回退到截断摘要。
  ///
  /// [SummaryText.degraded] 标记"总结模型没跑成功"，由调用方决定怎么提示用户——
  /// 静默回退会让用户以为压缩过后的上下文还带着完整要点。
  Future<SummaryText> _summarize(
    CoreAgent agent,
    CoreSession session,
    List<CoreMessage> messages,
  ) async {
    final StringBuffer raw = StringBuffer();
    if (session.compacted) {
      raw.writeln('【此前已经总结过的内容】');
      raw.writeln(session.compactedSummary);
      raw.writeln();
    }
    final bool passBack = passBackReasoningFor(agent);
    for (final CoreMessage message in messages) {
      // 关闭回传时思考不在上下文里：把它写进摘要等于把 CoT 从后门塞回去
      if (message.isThinking && !passBack) continue;
      raw.writeln('- ${_line(message)}');
    }
    String body = raw.toString();
    if (body.length > summarizeCharLimit) {
      body = '${body.substring(0, summarizeCharLimit)}\n…[截断]';
    }
    try {
      final String text = await summarizer!.summarize(
        agent,
        '$summarizeInstruction\n\n$body',
      );
      return SummaryText('$summaryHeader\n$text');
    } catch (error) {
      log?.call('LLM 总结失败，回退到截断摘要：$error');
      return SummaryText(
        '$fallbackHeader\n${_digest(messages, passBackReasoning: passBack)}',
        degraded: true,
        degradedReason: '$error',
      );
    }
  }

  static const String summarizeInstruction =
      '请把下面这段早先的对话（含工具调用轨迹）总结成后续对话可用的要点：\n'
      '- 保留：用户目标与约束、已完成的改动与结论、未解决的问题、关键文件/命令/标识符；\n'
      '- 丢弃：客套话、重复内容、已被推翻的中间尝试；\n'
      '- 只输出总结正文，不要复述本提示词，也不要调用任何工具。';

  static const String summaryHeader =
      '以下是此前对话的总结（上下文已被压缩，当前任务目标与最新要求已保留在最近对话中）:';

  static const String fallbackHeader = '以下是此前的对话记录（上下文已被压缩，以下为历史要点）:';

  /// 单条消息的紧凑表示（工具卡片带上名称/参数/结果摘要）。
  static String _line(CoreMessage message) {
    if (message.isTool) {
      final String name = message.toolName ?? 'tool';
      final String args = jsonEncode(
        message.toolArguments ?? const <String, dynamic>{},
      );
      return '[工具 $name] 参数 ${_clip(args, 200)} '
          '结果 ${_clip(message.toolResult, 300)}';
    }
    final String role = message.role == 'user' ? '用户' : '助手';
    return '[$role] ${_clip(message.content, 400)}';
  }

  static String _digest(
    List<CoreMessage> messages, {
    required bool passBackReasoning,
  }) => _clip(
    messages
        .where((CoreMessage m) => !m.isThinking || passBackReasoning)
        .map(_line)
        .join('\n'),
    2000,
  );

  static String _clip(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}…';

  /// 单条消息的 token 估算：口径必须与 [LlmAgentEngine] **实际发出的那一份**一致。
  ///
  /// - 思考：只有开启回传时才算（关闭时引擎根本不发它）；
  /// - 工具结果：按**门控后**的字符数算（超长结果送模型的只有预览 + 提示那一份）。
  static int _messageTokens(
    CoreMessage message,
    double scale,
    ToolResultGate gate,
    bool passBackReasoning,
  ) {
    if (message.isThinking) {
      return passBackReasoning
          ? estimateTokens(message.content, scale: scale)
          : 0;
    }
    int tokens = estimateTokens(message.content, scale: scale);
    if (message.isTool) {
      tokens += estimateTokensFromChars(
        gate.forModelChars(message.toolResult),
        scale: scale,
      );
      tokens += estimateTokens(message.toolName ?? '', scale: scale);
      tokens += estimateTokens(
        jsonEncode(message.toolArguments ?? const <String, dynamic>{}),
        scale: scale,
      );
      tokens += 8;
    }
    return tokens;
  }
}

/// 总结器抽象：桌面核心的压缩依赖一次"非流式语义"的补全调用。
///
/// 放在这里而不是 llm/ 里，是为了让压缩逻辑可以脱离 HTTP 单测
/// （生产实现见 llm/llm_summarizer.dart 的 LlmSummarizer）。
abstract interface class ContextSummarizer {
  /// 用该 agent 绑定的模型总结 [prompt]；失败抛异常（调用方回退到截断摘要）。
  Future<String> summarize(CoreAgent agent, String prompt);

  /// 释放资源（幂等）。
  Future<void> close();
}

/// 一次压缩的结论（直接映射成 REST 响应；reason 是前端文案的判定键）。
class CompactionResult {
  const CompactionResult({
    this.compressed = false,
    this.reason = '',
    this.contextSize = 0,
    this.summarizedMessages = 0,
    this.summary = '',
    this.sessionId = '',
    this.error = '',
    this.status = 200,
    this.degraded = false,
    this.degradedReason = '',
  });

  /// 是否真的执行了压缩。
  final bool compressed;

  /// 未压缩时的原因：no_active_session / too_few_messages /
  /// nothing_to_summarize / already_compacting / no_summarizer。
  final String reason;

  /// 压缩后的上下文条数（1 条摘要 + 保留的消息）。
  final int contextSize;

  /// 本次被总结掉的消息条数。
  final int summarizedMessages;

  /// 新摘要（已写回会话）。
  final String summary;

  final String sessionId;

  /// 压缩是否**降级**：总结模型调用失败，摘要其实是截断的历史要点。
  ///
  /// 压缩本身算成功（上下文确实收缩了），但要点可能不全——会话层据此给用户一条
  /// 可见提示，而不是让"压过了"这件事掩盖掉总结失败。
  final bool degraded;

  /// 降级的**可读原因**（总结失败时的异常文本；未降级时为空串）。
  ///
  /// 只报"总结失败"用户无从判断到底是密钥、限流、端点错误还是网络中断——
  /// 把端点原文带进提示，下一次失败用户与日志就能直接定位。
  final String degradedReason;

  /// 出错原因（非空时 REST 返回非 200）。
  final String error;

  /// 出错时的 HTTP 状态码。
  final int status;

  Map<String, dynamic> toJson() => error.isNotEmpty
      ? <String, dynamic>{'error': error, 'status': status}
      : <String, dynamic>{
          'success': true,
          'compressed': compressed,
          if (reason.isNotEmpty) 'reason': reason,
          'context_size': contextSize,
          'summarized_messages': summarizedMessages,
          if (sessionId.isNotEmpty) 'session_id': sessionId,
          if (degraded) 'degraded': true,
          if (degraded && degradedReason.isNotEmpty)
            'degraded_reason': degradedReason,
        };
}

/// 一次总结的产物：正文 + 是否降级（见 [CompactionResult.degraded]）。
class SummaryText {
  const SummaryText(
    this.text, {
    this.degraded = false,
    this.degradedReason = '',
  });

  final String text;
  final bool degraded;

  /// 降级的可读原因（见 [CompactionResult.degradedReason]）。
  final String degradedReason;
}

/// 上下文长度预算（[CompactionService.maxSeqlenFor] 的返回值）。
///
/// [fallback] 为真表示模型没配 `max_seqlen`、用的是 [CoreSettings.fallbackMaxSeqlen]：
/// 压缩照常判断，但调用方**必须**把这件事显示给用户（Q1-③：不再默默兜底）。
class MaxSeqlenBudget {
  const MaxSeqlenBudget(this.value, {this.fallback = false});

  /// 生效的上下文长度（token）。
  final int value;

  /// 是否来自兜底值（模型没配置）。
  final bool fallback;
}

/// 保留/总结的划分结果（[CompactionService.buildPlan] 的返回值，供测试断言形状）。
class KeepPlan {
  const KeepPlan({required this.keep, required this.summarize, this.cut = 0});

  /// 保留原文的消息（保持原顺序）。
  final List<CoreMessage> keep;

  /// 交给模型总结的消息（历史的一个前缀，长度即 [cut]）。
  final List<CoreMessage> summarize;

  /// 切点：`[0, cut)` 被总结，`[cut, end)` 保留。
  final int cut;
}
