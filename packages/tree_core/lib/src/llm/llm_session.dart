import 'dart:collection';
import 'dart:convert';

import '../agent/agent_engine.dart';
import '../tool/tool_runner.dart';
import '../util/ids.dart';
import 'llm_transport.dart';
import 'llm_types.dart';

/// 一轮**完整的 LLM 会话**：上下文 → 流式生成 → 工具执行 → 回灌 → 继续，
/// 直到模型给出最终文本（或达到轮次上限/出错/被取消）。
///
/// 职责边界：
/// - 本类只管 **LLM 协议语义**：工具调用增量的拼接、usage 累计、上下文裁剪、
///   工具循环终止条件；
/// - "历史消息怎么来"（存储 → 消息）由 [LlmAgentEngine] 负责；
/// - "事件怎么变成 WS 帧"由 ConversationService 负责。
///
/// 工具循环：模型可以连续多轮请求工具（每轮把工具结果作为 `role: tool` 回灌），
/// 上限 [maxToolTurns] 轮——防止模型与工具互相"踢皮球"导致无限循环。
class LlmSession {
  LlmSession({
    required this.transport,
    required this.model,
    this.tools = const <ToolSpec>[],
    this.toolRunner = const EmptyToolRunner(),
    this.maxSeqlen = 128000,
    this.maxOutputTokens,
    this.reasoningEffort,
    this.temperature,
    this.maxToolTurns = 24,
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
  final int maxSeqlen;

  /// 单轮最大输出 token。
  final int? maxOutputTokens;

  /// 思考强度（low/high/max；空则不发送）。
  final String? reasoningEffort;

  /// 采样温度（null 则用端点默认）。
  final double? temperature;

  /// 工具循环最大轮次。
  final int maxToolTurns;

  /// 可读日志（上下文裁剪、工具异常等）。
  final void Function(String message)? log;

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
    final List<LlmMessage> working = _fitContext(
      messages,
      onTrimmed: (int dropped) {
        trimmed += dropped;
        log?.call('上下文超出预算，已裁掉最早的 $dropped 条历史消息');
      },
    );
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

    for (int turn = 0; turn < maxToolTurns; turn++) {
      if (isCancelled()) {
        yield const AgentDone(cancelled: true);
        return;
      }
      final LlmRequest request = LlmRequest(
        model: model,
        messages: List<LlmMessage>.unmodifiable(working),
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

      await for (final LlmStreamEvent event in transport.stream(
        request,
        isCancelled: isCancelled,
      )) {
        if (event is LlmTextDelta) {
          text.write(event.text);
          yield AgentText(event.text);
        } else if (event is LlmThinkingDelta) {
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
            yield AgentError(event.message);
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
        yield AgentUsage(
          _usage(
            promptTokens: lastPromptTokens,
            completionTokens: completionTokens,
            cachedTokens: cachedTokens,
            trimmed: trimmed,
          ),
        );
      }

      if (failed) {
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
              promptTokens: request.estimatedPromptTokens(),
              completionTokens: _estimateCompletion(text.toString()),
              estimated: true,
              trimmed: trimmed,
            ),
          );
        }
        yield AgentDone(finishReason: finishReason);
        return;
      }

      // 把"模型的工具调用意图"追加进上下文，再逐个执行并回灌结果
      working.add(
        LlmMessage(
          role: LlmRole.assistant,
          content: text.toString(),
          toolCalls: calls,
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
        yield AgentToolEnd(
          id: toolId,
          name: call.name,
          result: outcome.content,
        );
        working.add(
          LlmMessage.toolResult(content: outcome.content, toolCallId: call.id),
        );
      }
    }

    yield AgentError('工具调用轮次超过上限（$maxToolTurns 轮），已中止本轮');
    yield const AgentDone();
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
    maxTokens: maxSeqlen > 0 ? maxSeqlen : 128000,
    cachedTokens: cachedTokens,
    estimated: estimated,
    trimmedMessages: trimmed,
  );

  /// 粗估输出 token（端点未返回 usage 时的兜底）。
  static int _estimateCompletion(String text) {
    int cjk = 0;
    int other = 0;
    for (final int rune in text.runes) {
      if ((rune >= 0x2E80 && rune <= 0x9FFF) ||
          (rune >= 0xF900 && rune <= 0xFAFF)) {
        cjk++;
      } else {
        other++;
      }
    }
    return cjk + (other + 3) ~/ 4;
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
      (int sum, LlmMessage m) => sum + m.estimatedTokens(),
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
        total -= result[i].estimatedTokens();
      }
      dropped += boundary - head;
      result.removeRange(head, boundary);
    }
    if (dropped > 0) onTrimmed(dropped);
    return result;
  }
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
