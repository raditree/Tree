import '../agent/compaction_service.dart';
import '../settings/core_settings.dart';
import '../store/records.dart';
import '../store/usage_log.dart';
import '../util/tokens.dart';
import 'llm_agent_engine.dart';
import 'llm_transport.dart';
import 'llm_types.dart';

/// 用 agent 绑定的模型做一次"总结"补全（M7d-4 上下文压缩的生产实现）。
///
/// 刻意**不带工具**、只发一条 user 消息：总结请求若能调工具，就可能递归触发一整套
/// 工具循环（甚至再次压缩），压缩会变成不可控的放大器。
class LlmSummarizer implements ContextSummarizer {
  LlmSummarizer({
    required this.resolveModel,
    this.transportFactory,
    this.agentOverrides,
    this.log,
    this.usageSink,
  });

  /// 按 model_id 解析模型配置（与 [LlmAgentEngine] 共用同一解析器）。
  final ModelResolver resolveModel;

  /// 传输层工厂（测试注入假传输）；空则用 [HttpSseTransport]。
  final TransportFactory? transportFactory;

  /// 成员级模型参数覆盖（与引擎同源，否则总结与对话用的参数会不一致）。
  final Map<String, Object?> Function(String agentId)? agentOverrides;

  final void Function(String message)? log;

  /// **逐调用用量回调**（可注入、**可写字段**）：一次总结补全 = 一次 LLM 调用，
  /// 落 `source=compact`。
  ///
  /// 为什么是可注入回调而不是自己写文件：总结器不认识数据根，也不该认识。
  /// 为什么是**可写字段**：[summarize] 的签名里只有 agent、会话由调用点
  /// （`CompactionService` 拿到 `CoreSession` 之后）知道。范式同
  /// `LlmAgentEngine.toolTurnCompactor`：谁先建好谁接上。
  ///
  /// **生产走的是 [summarize] 的 `usageSink` 参数**（按次传入，理由见
  /// [ContextSummarizer.summarize] 的说明：不同会话可以同时压缩，共享字段会串账）；
  /// 这个字段是兜底与单测用的默认值。
  ///
  /// 端点没给 usage 时用**本地估算**并标 `estimated: true`（估算与对话共用
  /// `util/tokens.dart` 的同一个函数，不另造一套口径）。
  UsageSink? usageSink;

  final Map<String, LlmTransport> _transports = <String, LlmTransport>{};

  @override
  Future<String> summarize(
    CoreAgent agent,
    String prompt, {
    void Function(String notice)? onNotice,
    UsageSink? usageSink,
  }) async {
    final CoreModelConfig? resolved = resolveModel(agent.modelId);
    final CoreModelConfig? config = resolved?.withOverrides(
      agentOverrides?.call(agent.id) ?? const <String, Object?>{},
    );
    if (config == null) {
      throw StateError(
        agent.modelId.isEmpty
            ? '该 agent 尚未指定模型，无法总结上下文'
            : '模型配置不存在：${agent.modelId}',
      );
    }
    final _SummaryAttempt attempt = await _attempt(
      config,
      prompt,
      _summaryOutputTokens(config),
      onNotice,
    );
    // 一次总结 = 一次 LLM 调用：**成败都记账**（请求确实发出去了）。放在这里而不是
    // 返回处，是因为下面几条分支都会 return/throw，而账要在所有分支上都落。
    // [usageSink]（按次传入，优先于可写字段）由压缩服务绑定本会话。
    _recordUsage(agent, config, prompt, attempt, usageSink: usageSink);
    if (attempt.text.isNotEmpty) return attempt.text;
    // 传输层已经报错（HTTP 4xx/5xx、链路失活、取消）：原样如实上报。
    if (attempt.failure != null) throw StateError(attempt.failure!);
    // 调用"成功"但正文为空：把"到底发生了什么"（思考多少字、finish_reason、预算）
    // 写进错误，否则用户只能看到一句"模型没有返回总结内容"而无法自查。
    //
    // 这里**不做降档重试**：总结要保持 agent 原本的思考模式（思考是它产出要点的
    // 方式），压低思考等于用一个更弱的总结器替换它。预算也已经**完全复用对话用的
    // 输出长度**（见 [_summaryOutputTokens]），没有可再抬的空间。
    throw StateError('模型没有返回总结内容（${attempt.describe()}）');
  }

  @override
  Future<void> close() async {
    for (final LlmTransport transport in _transports.values) {
      await transport.close();
    }
    _transports.clear();
  }

  /// 跑一次总结补全，把**正文、思考长度、finish_reason** 都收回来。
  ///
  /// 收 thinking 与 finish_reason 不是为了消费它们，而是为了在"正文为空"这种最容易
  /// 被误报成"模型没返回内容"的情形里，能说清到底是端点安静、还是思考吃满了预算。
  Future<_SummaryAttempt> _attempt(
    CoreModelConfig config,
    String prompt,
    int? budget,
    void Function(String notice)? onNotice,
  ) async {
    final StringBuffer text = StringBuffer();
    int thinkingChars = 0;
    String finishReason = '';
    String? failure;
    // 端点可能不返回 usage（本地 llama.cpp / vLLM 常常没有）——那时由 [_recordUsage]
    // 用本地估算兜底，所以这里"收得到就收、收不到也不影响调用本身"。
    LlmUsage? usage;
    final Stopwatch clock = Stopwatch()..start();
    await for (final LlmStreamEvent event in _transportFor(config).stream(
      LlmRequest(
        model: config.modelId,
        messages: <LlmMessage>[LlmMessage.user(prompt)],
        // 与对话引擎**完全同口径**：模型/成员配置的 max_output_tokens 是多少就是多少
        maxOutputTokens: budget,
        temperature: 0.2,
        // 与对话引擎**同一个思考档位**（含成员级覆盖）：总结是 loop 的延续，
        // 换一个档位就等于换了一个总结器，摘要质量会与对话时不一致。
        reasoningEffort: config.reasoningEffort.trim().isEmpty
            ? null
            : config.reasoningEffort.trim(),
      ),
    )) {
      if (event is LlmTextDelta) {
        text.write(event.text);
      } else if (event is LlmThinkingDelta) {
        thinkingChars += event.text.length;
      } else if (event is LlmUsageEvent) {
        // 以前这里没有这一支：端点回的 usage 被直接丢掉 ⇒ 内置压缩"永远没有账"。
        usage = event.usage;
      } else if (event is LlmFinishEvent) {
        finishReason = event.reason;
      } else if (event is LlmRetryNotice) {
        // 压缩跟生成走**同一套**传输层重试；但总结器没有会话/事件流可渲染，
        // 于是把进度交回上层（CompactionService.noticeSink → 一条 llm_hidden 消息），
        // 否则用户只会看到"卡住了"。
        log?.call(event.message);
        onNotice?.call(event.message);
      } else if (event is LlmFailureEvent) {
        failure = event.cancelled ? '总结请求被取消' : event.message;
        break;
      }
    }
    clock.stop();
    return _SummaryAttempt(
      text: text.toString().trim(),
      thinkingChars: thinkingChars,
      finishReason: finishReason,
      budget: budget,
      failure: failure,
      usage: usage,
      durationMs: clock.elapsedMilliseconds,
    );
  }

  /// 记一笔 `source=compact` 的逐调用用量。
  ///
  /// 口径（与 [LlmSession] 的逐调用账目一致）：
  /// - 端点给了 usage ⇒ 用**本次总结**的真值，`estimated: false`；
  /// - 端点没给（或这次失败没有回包）⇒ 本地估算并标 `estimated: true`：
  ///   prompt = 总结提示词的 `estimateTokens`，completion = 摘要正文的同一个换算
  ///   （**共用** `util/tokens.dart` 的唯一口径，不另造一套）；
  /// - `cached_tokens` 拿不到就留空（null），不编造 0。
  void _recordUsage(
    CoreAgent agent,
    CoreModelConfig config,
    String prompt,
    _SummaryAttempt attempt, {
    UsageSink? usageSink,
  }) {
    final UsageSink? sink = usageSink ?? this.usageSink;
    if (sink == null) return;
    final LlmUsage? real = attempt.usage;
    final bool estimated = real == null || real.isEmpty;
    sink(
      agent.id,
      UsageCall(
        at: DateTime.now(),
        source: UsageSource.compact,
        model: config.modelId,
        promptTokens: estimated
            ? estimateTokens(prompt, scale: config.tokenScale)
            : real.promptTokens,
        cachedTokens: estimated || real.cachedTokens <= 0
            ? null
            : real.cachedTokens,
        completionTokens: estimated
            ? estimateTokens(attempt.text, scale: config.tokenScale)
            : real.completionTokens,
        estimated: estimated,
        durationMs: attempt.durationMs,
      ),
    );
  }

  /// 本次总结的输出上限：**完全复用原模型的输出长度**，本类不再另立口径。
  ///
  /// - 模型/成员配置了 `max_output_tokens`（含成员级覆盖）→ 原样用它；
  /// - 配置为 0 → 返回 null（与对话引擎一致：不发送 `max_tokens`，听端点默认）。
  ///
  /// **为什么不能另定一个"总结就该短"的数**（2026-10-01 实测，deepseek-v4.1-flash，
  /// 12k 字总结输入）：`max_tokens` 是**思考 + 正文**的总预算，
  /// - `2048`：模型把 2048 全花在思考上，`finish_reason=length`、**正文一个字都没有**
  ///   ⇒ 上层只能报 "总结模型调用失败：模型没有返回总结内容"，压缩退化成截断摘要；
  ///   输入越长思考越久，所以长会话是**必然失败**，不是偶发。
  /// - 复用模型输出长度（线上 65536）：思考 + 正文都在预算内，一次通过。
  ///
  /// 上限本身不会让总结变长：模型答完即 `stop`（实测一次总结约 5k completion token）。
  int? _summaryOutputTokens(CoreModelConfig config) =>
      config.maxOutputTokens > 0 ? config.maxOutputTokens : null;

  LlmTransport _transportFor(CoreModelConfig config) {
    final String key = '${config.baseUrl}|${config.apiKey}';
    final LlmTransport? existing = _transports[key];
    if (existing != null) return existing;
    final TransportFactory? factory = transportFactory;
    final LlmTransport created = factory != null
        ? factory(config)
        : HttpSseTransport(baseUrl: config.baseUrl, apiKey: config.apiKey);
    _transports[key] = created;
    return created;
  }
}

/// 一次总结尝试的结果（正文 + 诊断读数）。
class _SummaryAttempt {
  const _SummaryAttempt({
    required this.text,
    required this.thinkingChars,
    required this.finishReason,
    required this.budget,
    this.failure,
    this.usage,
    this.durationMs = 0,
  });

  final String text;

  /// 本轮收到的思考（thinking）字符数：正文为空时它是主要线索。
  final int thinkingChars;

  /// 端点给的 `finish_reason`（空 = 没收到）。
  final String finishReason;

  /// 本轮实际发出的输出上限（token）；null = 未限定，听端点默认。
  final int? budget;

  /// 传输层失败原因（空 = 调用本身是成功的）。
  final String? failure;

  /// 端点回的真实 usage；null = 端点没给（逐调用账目据此改用本地估算）。
  final LlmUsage? usage;

  /// 这一跳从发出请求到收流的耗时（毫秒）。
  final int durationMs;

  /// 一句话说清这一轮的结果，可直接进错误文案。
  String describe() {
    if (failure != null) return failure!;
    return <String>[
      '正文 0 字',
      budget == null ? '输出上限未限定（端点默认）' : '输出上限 $budget token',
      if (thinkingChars > 0) '思考 $thinkingChars 字',
      if (finishReason.isNotEmpty) 'finish_reason=$finishReason',
    ].join('，');
  }
}
