import 'dart:convert';

import 'package:tree_local_exec/tree_local_exec.dart';

import '../agent/agent_engine.dart';
import '../settings/core_settings.dart';
import '../tool/tool_runner.dart';
import '../tool/workspace_tool_runner.dart';
import 'llm_session.dart';
import 'llm_transport.dart';
import 'llm_types.dart';

/// 按 model_id 解析模型配置（由调用方提供：设置/模型池）。
typedef ModelResolver = CoreModelConfig? Function(String modelId);

/// 传输层工厂（测试注入假传输；生产走 [HttpSseTransport]）。
typedef TransportFactory = LlmTransport Function(CoreModelConfig config);

/// 工具循环内压缩钩子（Q1-③）。
///
/// 返回**重建后的运行上下文**（摘要 / 水位线 / 历史都已刷新），null = 这次没压。
/// 为什么返回上下文而不是布尔值：压缩改的是存储里的摘要与水位线，只回一个"压过了"
/// 引擎没法重新装配请求，那等于没压。
typedef ToolTurnCompactor = Future<AgentRunContext?> Function(
  String agentId,
  String sessionId, {
  required bool force,
});

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
///    - 结果缺失的工具调用补一句占位结果（例如上一轮生成中途崩了）；
/// 3. **超长工具结果门控**（Q1-②）：历史里的超大结果在翻译时同样过一遍门控，
///    与工具循环共用同一个 [ToolResultGate]；
/// 4. **token_scale 学习**（Q1-①）：端点回真实 usage 时，把该模型的
///    字符/token 比例刷新回 `models/<id>.yaml`（无 usage 的端点只读不写）；
/// 5. **传输缓存**：同一 (base_url, api_key) 复用 HttpClient，避免每次请求建连。
class LlmAgentEngine implements AgentEngine {
  LlmAgentEngine({
    required this.resolveModel,
    this.toolRunner = const EmptyToolRunner(),
    this.transportFactory,
    this.agentOverrides,
    this.sessionStatusText,
    this.resultRedirectWriter,
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

  /// 超长工具结果的重定向写入器（Q1-②）。
  ///
  /// 为空时按 [toolRunner] 自动取工作空间 IO（见 [_workspaceWriter]）；显式注入可
  /// 换用别的通道（例如文件服务），签名里的 agentId 由引擎绑定。
  final ResultRedirectWriter? resultRedirectWriter;

  /// 工具循环内压缩钩子（Q1-③）：由会话层（ConversationService）接线。
  ///
  /// 为什么是可写字段而不是构造参数：会话服务由核心进程构造、引擎由调用方（CLI）
  /// 构造，两边在构造期互不可见；留一个显式接线点，谁先建好谁接上。
  ToolTurnCompactor? toolTurnCompactor;

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

    // 门控实例与一次 run 同生命周期：历史翻译与工具循环共用它，重定向序号才连续。
    final ToolResultGate gate = ToolResultGate(
      agentId: context.agentId,
      tokenScale: config.tokenScale,
      writer: resultRedirectWriter ?? _workspaceWriter(),
      log: log,
    );
    final List<LlmMessage> messages = await _buildMessages(context, gate);
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
      tokenScale: config.tokenScale,
      resultGate: gate,
      statusText: sessionStatusText == null
          ? null
          : () => sessionStatusText!(context.agentId, context.sessionId),
      compactContext: ({required bool force}) =>
          _rebuiltContext(context, gate, force: force),
      log: log,
    );
    // usage 事件要**过一手**：真实 usage 里夹带着"本次上下文字符数"，学习完之后
    // 必须剥掉再上行，否则内部字段会流进前端帧与落库。
    await for (final AgentEvent event in session.run(
      messages: messages,
      agentId: context.agentId,
      sessionId: context.sessionId,
      isCancelled: isCancelled,
    )) {
      if (event is AgentUsage) {
        _learnTokenScale(resolved, event.usage);
        yield AgentUsage(_publicUsage(event.usage));
        continue;
      }
      yield event;
    }
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

  /// 工具循环内压缩（Q1-③）：压完把**重建后的上下文**交回会话。
  ///
  /// 没接线（[toolTurnCompactor] 为空）或这次没压动时返回 null，会话保持原上下文。
  Future<List<LlmMessage>?> _rebuiltContext(
    AgentRunContext context,
    ToolResultGate gate, {
    required bool force,
  }) async {
    final ToolTurnCompactor? compact = toolTurnCompactor;
    if (compact == null) return null;
    final AgentRunContext? refreshed = await compact(
      context.agentId,
      context.sessionId,
      force: force,
    );
    if (refreshed == null) return null;
    return _buildMessages(refreshed, gate);
  }

  /// 学习令牌比例 + 记录水位线（Q1-①）；失败只记日志，绝不影响本轮生成。
  ///
  /// 学在**解析出来的原对象**上（不是成员覆盖后的副本）：token_scale 是模型的
  /// 持久属性，写回也走模型自己的落盘回调。
  void _learnTokenScale(CoreModelConfig? model, Map<String, dynamic> usage) {
    if (model == null) return;
    final Object? chars = usage[LlmSession.contextCharsKey];
    final Object? prompt = usage['prompt_tokens'];
    if (chars is! int || prompt is! int) return;
    try {
      if (model.learnTokenScale(contextChars: chars, promptTokens: prompt)) {
        log?.call(
          'token_scale 已刷新：${model.modelId} → ${model.tokenScale}'
          '（真实 prompt $prompt token / 上下文 $chars 字符）',
        );
      }
    } catch (error) {
      log?.call('token_scale 学习失败（已忽略）：$error');
    }
  }

  /// 剥掉内部学习字段，保证上行 usage 与既有前端契约一字不差。
  static Map<String, dynamic> _publicUsage(Map<String, dynamic> usage) {
    if (!usage.containsKey(LlmSession.contextCharsKey)) return usage;
    return Map<String, dynamic>.of(usage)..remove(LlmSession.contextCharsKey);
  }

  /// 没显式注入写入器时，从工具执行器取**同一份**工作空间 IO。
  ///
  /// 为什么用工具层的 WorkspaceIO 而不是别的写通道：它就是工具自己读写的那个 IO
  /// （自带父目录创建、路径边界，本地与 SSH 统一），重定向文件的落点因此与工具
  /// 看到的 `.self` 完全一致；换通道用 [resultRedirectWriter] 注入即可。
  /// 工具执行器不是工作空间实现（假执行器 / 空执行器）时返回 null，门控退化为截断。
  ResultRedirectWriter? _workspaceWriter() {
    final ToolRunner runner = toolRunner;
    if (runner is! WorkspaceToolRunner) return null;
    return (String agentId, String relativePath, String content) async {
      final WorkspaceIO? io = await runner.ioFor(agentId);
      if (io == null) {
        throw StateError('agent $agentId 的工作空间不可用');
      }
      await io.writeFile(relativePath, content);
    };
  }

  /// 把会话历史翻译成端点消息序列。
  ///
  /// [gate] 只替换工具结果**送给模型的那一份**：历史里的超长结果同样要过门控
  /// （Q1-②：每次构造上下文都要过一遍，历史重载同样生效）。
  Future<List<LlmMessage>> _buildMessages(
    AgentRunContext context,
    ToolResultGate gate,
  ) async {
    final List<LlmMessage> out = <LlmMessage>[];
    if (context.systemPrompt.trim().isNotEmpty) {
      out.add(LlmMessage.system(context.systemPrompt));
    }
    // 上下文压缩摘要（M7d-4）：紧跟系统提示词，替代已被总结的历史前缀
    if (context.contextSummary.trim().isNotEmpty) {
      out.add(LlmMessage.system(context.contextSummary));
    }
    final List<CoreMessageRef> toolBatch = <CoreMessageRef>[];

    Future<void> flushTools() async {
      if (toolBatch.isEmpty) return;
      final List<LlmToolCall> calls = <LlmToolCall>[];
      final List<LlmMessage> results = <LlmMessage>[];
      for (int i = 0; i < toolBatch.length; i++) {
        final CoreMessageRef ref = toolBatch[i];
        final String name = ref.toolName ?? 'unknown_tool';
        final String callId =
            (ref.toolCallId != null && ref.toolCallId!.isNotEmpty)
            ? ref.toolCallId!
            : 'tool_result_${context.sessionId}_${i}_${ref.timestamp}';
        calls.add(
          LlmToolCall(
            id: callId,
            name: name,
            arguments: jsonEncode(
              ref.toolArguments ?? const <String, dynamic>{},
            ),
          ),
        );
        results.add(
          LlmMessage.toolResult(
            // 上一轮中途中断时可能没有结果：补占位，避免 tool_calls 悬空
            content: await gate.apply(
              name,
              ref.toolResult.isEmpty ? '(该工具调用未完成，没有结果)' : ref.toolResult,
            ),
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

    // 已压缩的前缀不再翻译：它的内容已经由摘要代表，再发一遍等于没压缩
    final List<CoreMessageRef> visible = context.compactedMessageCount > 0
        ? context.history
              .skip(context.compactedMessageCount)
              .toList(growable: false)
        : context.history;
    for (final CoreMessageRef ref in visible) {
      if (ref.isTool) {
        toolBatch.add(ref);
        continue;
      }
      await flushTools();
      // 推理内容不回灌：思考过程不是对话上下文
      if (ref.isThinking) continue;
      if (ref.content.trim().isEmpty) continue;
      out.add(
        ref.isUser
            ? LlmMessage.user(ref.content)
            : LlmMessage.assistant(ref.content),
      );
    }
    await flushTools();
    return out;
  }
}
