import 'dart:convert';

import '../agent/agent_engine.dart';
import '../settings/core_settings.dart';
import '../tool/tool_runner.dart';
import 'llm_session.dart';
import 'llm_transport.dart';
import 'llm_types.dart';

/// 按 model_id 解析模型配置（由调用方提供：设置/模型池）。
typedef ModelResolver = CoreModelConfig? Function(String modelId);

/// 传输层工厂（测试注入假传输；生产走 [HttpSseTransport]）。
typedef TransportFactory = LlmTransport Function(CoreModelConfig config);

/// 真实 LLM 引擎：把"存储里的会话历史 + agent 配置"翻译成 LLM 请求，
/// 交给 [LlmSession] 跑工具循环，产出 [AgentEvent]。
///
/// 职责：
/// 1. **模型解析**：按 `model_id` 找到 base_url / api_key / 上下文长度；
///    未配置时给出**可操作**的中文报错（而不是一句"失败"）；
/// 2. **历史翻译**：`CoreMessageRef` → `LlmMessage`，其中
///    - 推理（thinking）消息**不回灌**（避免把思考内容当成对话上下文）；
///    - 连续的 tool 消息合并成"一条 assistant 的多个 tool_calls + 多条 tool 结果"，
///      保证 tool_calls 与 tool 结果严格配对（否则端点直接 400）；
///    - 结果缺失的工具调用补一句占位结果（例如上一轮生成中途崩了）。
/// 3. **传输缓存**：同一 (base_url, api_key) 复用 HttpClient，避免每次请求建连。
class LlmAgentEngine implements AgentEngine {
  LlmAgentEngine({
    required this.resolveModel,
    this.toolRunner = const EmptyToolRunner(),
    this.transportFactory,
    this.agentOverrides,
    this.sessionStatusText,
    this.log,
  });

  /// 模型配置解析器。
  final ModelResolver resolveModel;

  /// 工具执行器（M4 接入真实实现）。
  final ToolRunner toolRunner;

  /// 传输层工厂；为空时用 [HttpSseTransport] 并按 (base_url, api_key) 缓存。
  final TransportFactory? transportFactory;

  /// 成员级模型参数覆盖（M5b）：按 agentId 取覆盖并叠加到解析出的模型配置上。
  ///
  /// 为什么不放在 `resolveModel` 里：解析器只认识 model_id，而覆盖是**成员**属性。
  final Map<String, Object?> Function(String agentId)? agentOverrides;

  /// 每次工具结果前拼上的会话状态（todo + 已选 Spec）；null = 不拼。
  final String Function(String agentId, String sessionId)? sessionStatusText;

  /// 可读日志。
  final void Function(String message)? log;

  final Map<String, LlmTransport> _transports = <String, LlmTransport>{};

  @override
  Stream<AgentEvent> run(
    AgentRunContext context, {
    required bool Function() isCancelled,
  }) async* {
    final CoreModelConfig? resolved = resolveModel(context.modelId);
    final CoreModelConfig? config = resolved?.withOverrides(
      agentOverrides?.call(context.agentId) ?? const <String, Object?>{},
    );
    if (config == null) {
      yield AgentError(
        context.modelId.isEmpty
            ? '该 agent 尚未指定模型：请在右栏「模型信息」选择模型，'
                  '或在「设置 → 自定义模型」中新增模型'
            : '模型配置不存在：${context.modelId}（可能已被删除，请重新指定）',
      );
      yield const AgentDone();
      return;
    }
    if (config.baseUrl.trim().isEmpty || config.apiKey.trim().isEmpty) {
      yield AgentError(
        '模型「${config.name.isEmpty ? config.modelId : config.name}」缺少 '
        'base_url 或 api_key：请到「设置 → 自定义模型」补全',
      );
      yield const AgentDone();
      return;
    }

    final List<LlmMessage> messages = _buildMessages(context);
    final LlmSession session = LlmSession(
      transport: _transportFor(config),
      model: config.modelId,
      tools: toolRunner.specsFor(
        agentId: context.agentId,
        sessionId: context.sessionId,
      ),
      toolRunner: toolRunner,
      maxSeqlen: config.effectiveMaxSeqlen,
      maxOutputTokens: config.maxOutputTokens > 0
          ? config.maxOutputTokens
          : null,
      reasoningEffort: config.reasoningEffort,
      statusText: sessionStatusText == null
          ? null
          : () => sessionStatusText!(context.agentId, context.sessionId),
      log: log,
    );
    yield* session.run(
      messages: messages,
      agentId: context.agentId,
      sessionId: context.sessionId,
      isCancelled: isCancelled,
    );
  }

  @override
  Future<void> close() async {
    for (final LlmTransport transport in _transports.values) {
      await transport.close();
    }
    _transports.clear();
  }

  LlmTransport _transportFor(CoreModelConfig config) {
    final String key = '${config.baseUrl}|${config.apiKey}';
    final LlmTransport? existing = _transports[key];
    if (existing != null) return existing;
    // 工厂创建的传输同样入缓存：close() 必须能把它关掉（否则连接池泄漏）
    final TransportFactory? factory = transportFactory;
    final LlmTransport created = factory != null
        ? factory(config)
        : HttpSseTransport(baseUrl: config.baseUrl, apiKey: config.apiKey);
    _transports[key] = created;
    return created;
  }

  /// 把会话历史翻译成端点消息序列。
  List<LlmMessage> _buildMessages(AgentRunContext context) {
    final List<LlmMessage> out = <LlmMessage>[];
    if (context.systemPrompt.trim().isNotEmpty) {
      out.add(LlmMessage.system(context.systemPrompt));
    }
    final List<CoreMessageRef> toolBatch = <CoreMessageRef>[];

    void flushTools() {
      if (toolBatch.isEmpty) return;
      final List<LlmToolCall> calls = <LlmToolCall>[];
      final List<LlmMessage> results = <LlmMessage>[];
      for (int i = 0; i < toolBatch.length; i++) {
        final CoreMessageRef ref = toolBatch[i];
        final String callId =
            (ref.toolCallId != null && ref.toolCallId!.isNotEmpty)
            ? ref.toolCallId!
            : 'tool_result_${context.sessionId}_${i}_${ref.timestamp}';
        calls.add(
          LlmToolCall(
            id: callId,
            name: ref.toolName ?? 'unknown_tool',
            arguments: jsonEncode(
              ref.toolArguments ?? const <String, dynamic>{},
            ),
          ),
        );
        results.add(
          LlmMessage.toolResult(
            // 上一轮中途中断时可能没有结果：补占位，避免 tool_calls 悬空
            content: ref.toolResult.isEmpty
                ? '(该工具调用未完成，没有结果)'
                : ref.toolResult,
            toolCallId: callId,
          ),
        );
      }
      out.add(
        LlmMessage(role: LlmRole.assistant, content: '', toolCalls: calls),
      );
      out.addAll(results);
      toolBatch.clear();
    }

    for (final CoreMessageRef ref in context.history) {
      if (ref.isTool) {
        toolBatch.add(ref);
        continue;
      }
      flushTools();
      // 推理内容不回灌：思考过程不是对话上下文
      if (ref.isThinking) continue;
      if (ref.content.trim().isEmpty) continue;
      out.add(
        ref.isUser
            ? LlmMessage.user(ref.content)
            : LlmMessage.assistant(ref.content),
      );
    }
    flushTools();
    return out;
  }
}
