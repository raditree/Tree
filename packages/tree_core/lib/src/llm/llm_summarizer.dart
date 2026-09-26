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
    this.maxOutputTokens = 2048,
    this.log,
  });

  /// 按 model_id 解析模型配置（与 [LlmAgentEngine] 共用同一解析器）。
  final ModelResolver resolveModel;

  /// 传输层工厂（测试注入假传输）；空则用 [HttpSseTransport]。
  final TransportFactory? transportFactory;

  /// 成员级模型参数覆盖（与引擎同源，否则总结与对话用的参数会不一致）。
  final Map<String, Object?> Function(String agentId)? agentOverrides;

  /// 总结的最大输出 token（总结本来就该短）。
  final int maxOutputTokens;

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
            : '模型配置不存在：$agent.modelId',
      );
    }
    final StringBuffer text = StringBuffer();
    String? failure;
    await for (final LlmStreamEvent event in _transportFor(config).stream(
      LlmRequest(
        model: config.modelId,
        messages: <LlmMessage>[LlmMessage.user(prompt)],
        // 成员级 max_output_tokens 是**上限**：总结再长也不该超过它，
        // 但也不能超过本类自己的天花板（总结本来就该短）
        maxOutputTokens: _outputBudget(config),
        temperature: 0.2,
      ),
    )) {
      if (event is LlmTextDelta) {
        text.write(event.text);
      } else if (event is LlmFailureEvent) {
        failure = event.cancelled ? '总结请求被取消' : event.message;
        break;
      }
    }
    if (failure != null) throw StateError(failure);
    final String summary = text.toString().trim();
    if (summary.isEmpty) throw StateError('模型没有返回总结内容');
    return summary;
  }

  @override
  Future<void> close() async {
    for (final LlmTransport transport in _transports.values) {
      await transport.close();
    }
    _transports.clear();
  }

  /// 本次总结的最大输出 token：取「成员配置」与 [maxOutputTokens] 的较小值。
  int _outputBudget(CoreModelConfig config) {
    final int configured = config.maxOutputTokens;
    if (configured <= 0) return maxOutputTokens;
    return configured < maxOutputTokens ? configured : maxOutputTokens;
  }

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
