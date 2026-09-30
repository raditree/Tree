import '../agent/compaction_service.dart';
import '../settings/core_settings.dart';
import '../store/records.dart';
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
  });

  /// 按 model_id 解析模型配置（与 [LlmAgentEngine] 共用同一解析器）。
  final ModelResolver resolveModel;

  /// 传输层工厂（测试注入假传输）；空则用 [HttpSseTransport]。
  final TransportFactory? transportFactory;

  /// 成员级模型参数覆盖（与引擎同源，否则总结与对话用的参数会不一致）。
  final Map<String, Object?> Function(String agentId)? agentOverrides;

  final void Function(String message)? log;

  final Map<String, LlmTransport> _transports = <String, LlmTransport>{};

  @override
  Future<String> summarize(CoreAgent agent, String prompt) async {
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
    );
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
  ) async {
    final StringBuffer text = StringBuffer();
    int thinkingChars = 0;
    String finishReason = '';
    String? failure;
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
      } else if (event is LlmFinishEvent) {
        finishReason = event.reason;
      } else if (event is LlmFailureEvent) {
        failure = event.cancelled ? '总结请求被取消' : event.message;
        break;
      }
    }
    return _SummaryAttempt(
      text: text.toString().trim(),
      thinkingChars: thinkingChars,
      finishReason: finishReason,
      budget: budget,
      failure: failure,
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
