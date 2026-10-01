import 'dart:collection';
import 'dart:convert';

import '../agent/agent_engine.dart';
import '../settings/core_settings.dart';
import '../tool/tool_runner.dart';
import '../util/ids.dart';
import '../util/tokens.dart';
import 'llm_result_gate.dart';
import 'llm_transport.dart';
import 'llm_types.dart';

// 门控是会话语义的一部分（送模型的那一份在工具循环里就被替换），使用方
// （引擎 / 测试）从本文件即可拿到它，不必额外认识一个内部文件。
export 'llm_result_gate.dart';

/// 一轮**完整的 LLM 会话**：上下文 → 流式生成 → 工具执行 → 回灌 → 继续，
/// 直到模型给出最终文本（或出错/被取消）。
///
/// 职责边界：
/// - 本类只管 **LLM 协议语义**：工具调用增量的拼接、usage 累计、上下文裁剪、
///   超长工具结果门控、工具循环终止条件；
/// - "历史消息怎么来"（存储 → 消息）由 [LlmAgentEngine] 负责；
/// - "事件怎么变成 WS 帧"由 ConversationService 负责。
///
/// 工具循环：模型可以连续多轮请求工具（每轮把工具结果作为 `role: tool` 回灌）。
/// **M9/Q8 起不再有轮次上限**：终止条件只有取消、出错、模型给出最终文本；要限制
/// "模型与工具互相踢皮球"由插件监视轮次后经执行站的 `agent.stop` 发停止信号，
/// 那是编排策略，不该硬编码在会话里。
///
/// 工具循环内还会做两件与上下文有关的事（Q1-③）：
/// - 每轮 API 调用前调用 [compactContext]（长任务里上下文是一轮轮长起来的）；
/// - 端点报上下文超限时，强制压缩一次并重试该轮（仅一次）。
class LlmSession {
  LlmSession({
    required this.transport,
    required this.model,
    this.tools = const <ToolSpec>[],
    this.toolRunner = const EmptyToolRunner(),
    this.maxSeqlen = CoreSettings.fallbackMaxSeqlen,
    this.maxOutputTokens,
    this.reasoningEffort,
    this.temperature,
    this.tokenScale = defaultTokenScale,
    this.resultGate,
    this.statusText,
    this.compactContext,
    this.log,
  });

  /// 传输层（
  final LlmTransport transport;

  /// 发往端点的模型名。
  final String model;

  /// 可用工具声明。
  final List<ToolSpec> tools;

  /// 工具执行器。
  final ToolRunner toolRunner;

  /// 模型上下文长度（用于裁剪与 usage 分母）。
  ///
  /// 默认值只服务"直接构造会话"（测试/自检）；生产路径由引擎传模型配置里的值，
  /// 压缩判断另走 [CoreSettings.fallbackMaxSeqlen] 那条会提示用户补配置的路径。
  final int maxSeqlen;

  /// 单轮最大输出 token。
  final int? maxOutputTokens;

  /// 思考强度（low/high/max；空则不发送）。
  final String? reasoningEffort;

  /// 采样温度（null 则用端点默认）。
  final double? temperature;

  /// 逐模型 token_scale（见 util/tokens.dart）：裁剪预算、usage 兜底与
  /// token_scale 学习口径都必须用它，否则估算点之间会互相打架。
  final double tokenScale;

  /// 超长工具结果门控（Q1-②）；null = 不做门控（无工作空间的测试场景）。
  ///
  /// 门控只替换**送给模型的那一份**：`AgentToolEnd` 照旧带完整结果，前端卡片与
  /// 落库因此都还能看到原文。
  final ToolResultGate? resultGate;

  /// 每次工具结果前要拼上的"会话状态"（todo + 已选 Spec）；null = 不拼。
  ///
  /// 每次调用实时取：模型可能在工具循环中途改 todo 或挂 Spec，状态必须是当下的。
  final String Function()? statusText;

  /// 工具循环内压缩钩子（Q1-③）；由引擎接线到会话层的 CompactionService。
  ///
  /// 返回**重建后的基础上下文**（摘要 + 未压缩历史）：压缩改的是存储里的水位线
  /// 与摘要，在途的基础上下文不重新装配就等于没压。null = 没压缩/不需要重建。
  /// [force] 为真表示端点已经报上下文超限，此时必须压（本地估算可能偏小）。
  final Future<List<LlmMessage>?> Function({required bool force})?
  compactContext;

  /// 可读日志（上下文裁剪、工具异常等）。
  final void Function(String message)? log;

  /// 真实 usage 里夹带"本次请求上下文字符数"的内部键（见 [run]）。
  ///
  /// 用下划线前缀标明它是**内部字段**：引擎读完即剥掉，不会流到前端帧或落库。
  static const String contextCharsKey = '_context_chars';

  /// 跑完一轮会话。
  ///
  /// [messages] 必须**已包含 system 与本次用户消息**（顺序即发送顺序）。
  Stream<AgentEvent> run({
    required List<LlmMessage> messages,
    required String agentId,
    required String sessionId,
    required bool Function() isCancelled,
  }) async* {
    int trimmed = 0;
    // 基础上下文（system + 摘要 + 未压缩历史）与本轮工具轨迹**分开持有**：
    // 工具循环内压缩会重建前者，而在途的工具轨迹还没落库、重建时读不到，必须
    // 原样接回去，否则模型会以为自己上一轮什么都没干。
    List<LlmMessage> base = _fitContext(
      messages,
      onTrimmed: (int dropped) {
        trimmed += dropped;
        log?.call('上下文超出预算，已裁掉最早的 $dropped 条历史消息');
      },
    );
    final List<LlmMessage> inFlight = <LlmMessage>[];
    List<LlmMessage> current() => <LlmMessage>[...base, ...inFlight];
    // 端点超限的重试**整轮只给一次**（Q1-③）：压缩每次都"成功"但端点每次都说超限
    // 时，按轮重置会变成死循环；"仅一次，再失败如实报错"必须能保证收敛。
    bool overflowRetried = false;
    final List<LlmToolSpec> toolSpecs = tools
        .map(
          (ToolSpec t) => LlmToolSpec(
            name: t.name,
            description: t.description,
            parameters: t.parameters,
          ),
        )
        .toList();

    // 累计用量：prompt 取**最后一轮**（= 当前上下文长度），completion 为全轮累加
    int lastPromptTokens = 0;
    int completionTokens = 0;
    int cachedTokens = 0;
    bool sawEndpointUsage = false;

    // **无轮次上限**（Q8）：只有取消 / 出错 / 模型给出最终文本才会结束。
    for (int turn = 0; ; turn++) {
      if (isCancelled()) {
        yield const AgentDone(cancelled: true);
        return;
      }
      // 本轮的思考正文：必须原样挂回"带 tool_calls 的那条 assistant 消息"上。
      // 实测（recon.md）：带 tools 的请求**以 `tool` 结果收尾**时（= 工具循环的
      // 下一跳），前一条带 `tool_calls` 的 assistant 缺 `reasoning_content` 会 400
      // `The reasoning_content in the thinking mode must be passed back to the API.`
      // ——这不是用户开关能关掉的东西：端点刚把这段推理发回来，它属于那条消息。
      final StringBuffer turnReasoning = StringBuffer();
      // 工具循环内压缩（Q1-③，照旧后端 llm.py:976-982 在每轮 API 调用前调
      // _compress_context）：长任务里上下文是一轮轮长起来的，只在生成前检查一次
      // 的话，任务跑到一半就已经超过 max_seqlen 了。
      final List<LlmMessage>? compacted = await _compactBeforeTurn(
        force: false,
      );
      if (compacted != null) base = compacted;
      final LlmRequest request = LlmRequest(
        model: model,
        messages: List<LlmMessage>.unmodifiable(current()),
        tools: toolSpecs,
        maxOutputTokens: maxOutputTokens,
        reasoningEffort: reasoningEffort,
        temperature: temperature,
      );
      final SplayTreeMap<int, _ToolCallDraft> drafts =
          SplayTreeMap<int, _ToolCallDraft>();
      final StringBuffer text = StringBuffer();
      LlmUsage? turnUsage;
      String finishReason = '';
      bool failed = false;
      bool cancelled = false;
      bool overflow = false;
      String failure = '';

      await for (final LlmStreamEvent event in transport.stream(
        request,
        isCancelled: isCancelled,
      )) {
        if (event is LlmTextDelta) {
          text.write(event.text);
          yield AgentText(event.text);
        } else if (event is LlmThinkingDelta) {
          turnReasoning.write(event.text);
          yield AgentThinking(event.text);
        } else if (event is LlmToolCallDelta) {
          drafts.putIfAbsent(event.index, _ToolCallDraft.new).accept(event);
        } else if (event is LlmUsageEvent) {
          turnUsage = event.usage;
        } else if (event is LlmFinishEvent) {
          finishReason = event.reason;
        } else if (event is LlmFailureEvent) {
          if (event.cancelled) {
            cancelled = true;
          } else {
            failed = true;
            failure = event.message;
            // 先不当成错误抛出去：万一只是上下文超限，下面压缩后会重试同一轮
            overflow = looksLikeContextOverflow(event.message);
          }
          break;
        }
        if (isCancelled()) {
          cancelled = true;
          break;
        }
      }

      if (turnUsage != null && !turnUsage.isEmpty) {
        sawEndpointUsage = true;
        lastPromptTokens = turnUsage.promptTokens;
        completionTokens += turnUsage.completionTokens;
        cachedTokens = turnUsage.cachedTokens;
        final Map<String, dynamic> usage = _usage(
          promptTokens: lastPromptTokens,
          completionTokens: completionTokens,
          cachedTokens: cachedTokens,
          trimmed: trimmed,
        );
        // token_scale 的学习口径（Q1-①）：把本次请求的**上下文字符数**夹带在真实
        // usage 里上行，引擎据此决定要不要刷新该模型的 token_scale 记录。端点没给
        // usage 的分支不会带这个键——"无 usage 的端点只读不写"。
        usage[contextCharsKey] = request.contextChars();
        yield AgentUsage(usage);
      }

      if (failed) {
        // 端点报上下文超限（Q1-③）：本地估算可能偏小（token_scale 还在学习），
        // 强制压缩一次再重试**同一轮**；没有可压的历史就如实报错。
        if (overflow && !overflowRetried) {
          overflowRetried = true;
          log?.call('端点报告上下文超限，压缩后重试本轮：$failure');
          final List<LlmMessage>? rebuilt = await _compactBeforeTurn(
            force: true,
          );
          if (rebuilt != null) {
            base = rebuilt;
            continue;
          }
          yield AgentError(
            '$failure（本地没有可压缩的历史，无法自动收缩上下文；'
            '可在会话里手动压缩，或到设置页确认该模型的 max_seqlen）',
          );
          yield const AgentDone();
          return;
        }
        yield AgentError(failure);
        yield const AgentDone();
        return;
      }
      if (cancelled) {
        yield const AgentDone(cancelled: true);
        return;
      }

      final List<LlmToolCall> calls = <LlmToolCall>[
        for (final _ToolCallDraft draft in drafts.values)
          if (draft.name.isNotEmpty)
            LlmToolCall(
              id: draft.id.isEmpty ? CoreIds.next('call') : draft.id,
              name: draft.name,
              arguments: draft.arguments.toString(),
            ),
      ];
      if (calls.isEmpty) {
        if (!sawEndpointUsage) {
          // 端点没给 usage：用本地估算兜底，并显式标注 estimated
          yield AgentUsage(
            _usage(
              promptTokens: request.estimatedPromptTokens(scale: tokenScale),
              completionTokens: estimateTokens(
                text.toString(),
                scale: tokenScale,
              ),
              estimated: true,
              trimmed: trimmed,
            ),
          );
        }
        yield AgentDone(finishReason: finishReason);
        return;
      }

      // 把"模型的工具调用意图"追加进上下文，再逐个执行并回灌结果。
      // 思考正文一并带上（见 turnReasoning 的注释）：漏了它，下一跳请求就会以
      // "tool 结果收尾 + 前一条 tool_calls 消息没有 reasoning"的形态被端点 400。
      inFlight.add(
        LlmMessage(
          role: LlmRole.assistant,
          content: text.toString(),
          toolCalls: calls,
          reasoningContent: turnReasoning.toString(),
        ),
      );
      for (final LlmToolCall call in calls) {
        if (isCancelled()) {
          yield const AgentDone(cancelled: true);
          return;
        }
        final Map<String, dynamic> arguments = _parseArguments(call.arguments);
        if (arguments.isEmpty && call.arguments.trim().isNotEmpty) {
          log?.call('工具 ${call.name} 的参数不是合法 JSON：${call.arguments}');
        }
        final String toolId = CoreIds.next('tool');
        yield AgentToolStart(
          id: toolId,
          callId: call.id,
          name: call.name,
          arguments: arguments,
        );
        ToolOutcome outcome;
        try {
          outcome = await toolRunner.run(
            ToolInvocation(
              id: toolId,
              name: call.name,
              arguments: arguments,
              rawArguments: call.arguments,
              agentId: agentId,
              sessionId: sessionId,
            ),
            isCancelled: isCancelled,
          );
        } catch (error) {
          outcome = ToolOutcome('工具执行异常：$error', isError: true);
        }
        // UI 与落库都拿**完整结果**（AgentToolEnd）；只有送模型的那一份要过门控
        yield AgentToolEnd(
          id: toolId,
          name: call.name,
          result: outcome.content,
        );
        final String status = statusText?.call() ?? '';
        final String forModel = await _gateResult(call.name, outcome.content);
        inFlight.add(
          LlmMessage.toolResult(
            // 状态只进模型上下文；UI 的工具卡片仍显示原始结果（AgentToolEnd）
            content: status.isEmpty ? forModel : '$status$forModel',
            toolCallId: call.id,
          ),
        );
      }
    }
  }

  Map<String, dynamic> _usage({
    required int promptTokens,
    required int completionTokens,
    int cachedTokens = 0,
    bool estimated = false,
    int trimmed = 0,
  }) => agentUsageMap(
    promptTokens: promptTokens,
    completionTokens: completionTokens,
    maxTokens: maxSeqlen > 0 ? maxSeqlen : CoreSettings.fallbackMaxSeqlen,
    cachedTokens: cachedTokens,
    estimated: estimated,
    trimmedMessages: trimmed,
  );

  /// 工具循环内压缩（Q1-③）：把重建后的基础上下文取回来。
  ///
  /// 压缩改的是存储里的水位线与摘要，在途的 working 列表不重新装配就等于没压，
  /// 所以这里必须拿到**引擎重新装配过**的上下文，而不是一个布尔值。
  Future<List<LlmMessage>?> _compactBeforeTurn({required bool force}) async {
    final Future<List<LlmMessage>?> Function({required bool force})? hook =
        compactContext;
    if (hook == null) return null;
    return hook(force: force);
  }

  /// 超长工具结果门控（Q1-②）：返回**送给模型的那一份**。
  Future<String> _gateResult(String toolName, String text) async {
    final ToolResultGate? gate = resultGate;
    if (gate == null) return text;
    return gate.apply(toolName, text);
  }

  static Map<String, dynamic> _parseArguments(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) return <String, dynamic>{};
    try {
      final Object? decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) {
        return decoded.map((dynamic k, dynamic v) => MapEntry('$k', v));
      }
      return <String, dynamic>{'value': decoded};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// 把上下文裁到预算内。
  ///
  /// 预算 = max_seqlen − 期望输出 − 512 余量。裁剪**只在 user 消息边界**进行，
  /// 因此绝不会把 assistant 的 tool_calls 与其 tool 结果拆散（那会让端点直接
  /// 报 400）。system 与最后一轮永不裁剪。
  List<LlmMessage> _fitContext(
    List<LlmMessage> messages, {
    required void Function(int dropped) onTrimmed,
  }) {
    final int budget = maxSeqlen - (maxOutputTokens ?? 4096) - 512;
    if (budget <= 0 || messages.isEmpty) return messages;
    int total = messages.fold<int>(
      0,
      (int sum, LlmMessage m) => sum + m.estimatedTokens(scale: tokenScale),
    );
    if (total <= budget) return messages;

    final List<LlmMessage> result = List<LlmMessage>.of(messages);
    final int head = result.first.role == LlmRole.system && result.length > 1
        ? 1
        : 0;
    int dropped = 0;
    while (total > budget) {
      int boundary = -1;
      for (int i = head + 1; i < result.length; i++) {
        if (result[i].role == LlmRole.user) {
          boundary = i;
          break;
        }
      }
      // 找不到下一个 user 边界（只剩最后一轮）就不裁，宁可让端点去报超长
      if (boundary < 0) break;
      for (int i = head; i < boundary; i++) {
        total -= result[i].estimatedTokens(scale: tokenScale);
      }
      dropped += boundary - head;
      result.removeRange(head, boundary);
    }
    if (dropped > 0) onTrimmed(dropped);
    return result;
  }
}

/// 端点报错文案是否在说"上下文超限"（Q1-③）。
///
/// 各家措辞差异极大（OpenAI 的 "maximum context length"、vLLM 的 max_model_len、
/// llama.cpp 的 "exceeds the available context size"、中文网关的"上下文超长"…），
/// 这里只认**明确的超限信号**：宁可漏判（后果是按原样如实报错），也不要把普通
/// 400（例如参数非法）当成超限去压缩重试——那会白压一次还多打一次请求。
bool looksLikeContextOverflow(String message) {
  final String text = message.toLowerCase();
  const List<String> markers = <String>[
    'context length',
    'context_length',
    'context window',
    'context_window',
    'maximum context',
    'max context',
    'max_seq_len',
    'max_seqlen',
    'max_model_len',
    'sequence length',
    'too many tokens',
    'reduce the length',
    'input is too long',
    'prompt is too long',
    '上下文超',
    '上下文过长',
    '上下文长度',
    '超过最大长度',
  ];
  for (final String marker in markers) {
    if (text.contains(marker)) return true;
  }
  final bool overflowWord =
      text.contains('exceed') ||
      text.contains('too long') ||
      text.contains('超过') ||
      text.contains('超出');
  if (!overflowWord) return false;
  final bool contextWord = text.contains('context') || text.contains('上下文');
  if (contextWord) return true;
  final bool inputWord =
      text.contains('input') ||
      text.contains('prompt') ||
      text.contains('messages') ||
      text.contains('请求');
  return inputWord && text.contains('token');
}

/// 工具调用增量拼接缓冲：同一 index 的 id/name 只取首次出现的非空值，
/// arguments 按到达顺序拼接（端点会把 JSON 字符串切成任意片段）。
class _ToolCallDraft {
  String id = '';
  String name = '';
  final StringBuffer arguments = StringBuffer();

  void accept(LlmToolCallDelta delta) {
    if (delta.id != null && delta.id!.isNotEmpty && id.isEmpty) {
      id = delta.id!;
    }
    if (delta.name != null && delta.name!.isNotEmpty && name.isEmpty) {
      name = delta.name!;
    }
    if (delta.argumentsDelta.isNotEmpty) {
      arguments.write(delta.argumentsDelta);
    }
  }
}
