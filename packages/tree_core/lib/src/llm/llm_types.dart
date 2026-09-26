/// LLM 层的**与厂商无关**的数据类型：消息、工具声明、请求、流式事件。
///
/// 为什么自己定义而不用 `openai_dart` 的模型（M3 spike 结论）：
/// 1. 核心进程要保持依赖极简（当前仅 path/yaml 两个 Dart 官方包），
///    `openai_dart` 会引入一整套 HTTP/模型依赖；
/// 2. 我们需要**精确控制**流式增量语义：tool_call 参数是按 index 分片到达的
///    字符串片段、thinking 的字段名各厂商不同（`reasoning_content` /
///    `reasoning`）、usage 只在最后一帧出现；第三方封装往往只暴露"最终的
///    工具调用对象"，会丢掉增量与中间态；
/// 3. 目标是"任意 OpenAI 兼容端点"（OpenAI / DeepSeek / 本地 vLLM / Ollama…），
///    自己拼请求体反而更稳。
///
/// 结论：**手写 SSE 传输**（见 sse_transport.dart），并把与厂商相关的部分全部
/// 收敛在 [OpenAiCodec]（请求体构造 + 流式分片解码）。若将来需要换成
/// `openai_dart`，只需再实现一个 [LlmTransport]。
library;

/// 对话消息角色。
enum LlmRole {
  system,
  user,
  assistant,
  tool;

  /// 发往端点的 `role` 字面量。
  String get wire => name;
}

/// 一次工具调用（模型请求调用、参数是 JSON 字符串）。
class LlmToolCall {
  const LlmToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  /// 端点给的调用 id（回填 `role: tool` 消息时必须原样带回）。
  final String id;

  /// 函数名。
  final String name;

  /// 参数的 JSON 文本（可能为空串或坏 JSON，由上层容错）。
  final String arguments;

  Map<String, dynamic> toWire() => <String, dynamic>{
    'id': id,
    'type': 'function',
    'function': <String, dynamic>{'name': name, 'arguments': arguments},
  };
}

/// 一条对话消息。
class LlmMessage {
  const LlmMessage({
    required this.role,
    this.content = '',
    this.toolCalls = const <LlmToolCall>[],
    this.toolCallId,
    this.name,
  });

  /// 便捷构造。
  const LlmMessage.system(this.content)
    : role = LlmRole.system,
      toolCalls = const <LlmToolCall>[],
      toolCallId = null,
      name = null;

  /// 便捷构造。
  const LlmMessage.user(this.content)
    : role = LlmRole.user,
      toolCalls = const <LlmToolCall>[],
      toolCallId = null,
      name = null;

  /// 便捷构造。
  const LlmMessage.assistant(this.content)
    : role = LlmRole.assistant,
      toolCalls = const <LlmToolCall>[],
      toolCallId = null,
      name = null;

  /// 便捷构造（工具执行结果）。
  const LlmMessage.toolResult({
    required this.content,
    required String this.toolCallId,
  }) : role = LlmRole.tool,
       toolCalls = const <LlmToolCall>[],
       name = null;

  final LlmRole role;
  final String content;
  final List<LlmToolCall> toolCalls;
  final String? toolCallId;
  final String? name;

  /// 是否为工具结果消息。
  bool get isToolResult => role == LlmRole.tool;

  /// 发往端点的形态（OpenAI chat/completions）。
  Map<String, dynamic> toWire() {
    final Map<String, dynamic> out = <String, dynamic>{'role': role.wire};
    switch (role) {
      case LlmRole.tool:
        out['content'] = content;
        out['tool_call_id'] = toolCallId ?? '';
        return out;
      case LlmRole.assistant:
        // 纯工具调用轮次里 content 可能为空串，端点要求显式给 null 或空串
        out['content'] = content.isEmpty ? null : content;
        if (toolCalls.isNotEmpty) {
          out['tool_calls'] = toolCalls
              .map((LlmToolCall c) => c.toWire())
              .toList();
        }
        return out;
      case LlmRole.system:
      case LlmRole.user:
        out['content'] = content;
        if (name != null) out['name'] = name;
        return out;
    }
  }

  /// 估算该消息占用的 token（粗估：CJK 1 token，其余 4 字符 1 token）。
  int estimatedTokens() {
    int tokens = 0;
    for (final int rune in content.runes) {
      tokens += _isCjk(rune) ? 1 : 0;
    }
    final int ascii = content.runes.where((int r) => !_isCjk(r)).length;
    tokens += (ascii + 3) ~/ 4;
    for (final LlmToolCall call in toolCalls) {
      tokens += call.name.length ~/ 4 + call.arguments.runes.length ~/ 4 + 8;
    }
    return tokens;
  }

  static bool _isCjk(int rune) =>
      (rune >= 0x2E80 && rune <= 0x9FFF) ||
      (rune >= 0xF900 && rune <= 0xFAFF) ||
      (rune >= 0xFF00 && rune <= 0xFFEF);
}

/// 工具声明（M4 提供具体工具；M3 只负责把它发给端点并回灌结果）。
class LlmToolSpec {
  const LlmToolSpec({
    required this.name,
    required this.description,
    this.parameters = const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
  });

  final String name;
  final String description;

  /// JSON Schema。
  final Map<String, dynamic> parameters;

  Map<String, dynamic> toWire() => <String, dynamic>{
    'type': 'function',
    'function': <String, dynamic>{
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };
}

/// 一次补全请求（与厂商无关；由 codec 转成具体请求体）。
class LlmRequest {
  const LlmRequest({
    required this.model,
    required this.messages,
    this.tools = const <LlmToolSpec>[],
    this.maxOutputTokens,
    this.reasoningEffort,
    this.temperature,
    this.extra = const <String, dynamic>{},
  });

  final String model;
  final List<LlmMessage> messages;
  final List<LlmToolSpec> tools;
  final int? maxOutputTokens;
  final String? reasoningEffort;
  final double? temperature;

  /// 透传端点自定义字段（如厂商专用开关）。
  final Map<String, dynamic> extra;

  /// 估算输入 token（用于上下文裁剪与 usage 兜底）。
  int estimatedPromptTokens() => messages.fold<int>(
    0,
    (int sum, LlmMessage m) => sum + m.estimatedTokens(),
  );
}

/// token 用量（端点返回；缺失时上层用估算值兜底）。
class LlmUsage {
  const LlmUsage({
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.totalTokens = 0,
    this.cachedTokens = 0,
  });

  final int promptTokens;
  final int completionTokens;
  final int totalTokens;

  /// 命中前缀缓存的输入 token（部分厂商提供，仅作展示）。
  final int cachedTokens;

  bool get isEmpty =>
      promptTokens == 0 && completionTokens == 0 && totalTokens == 0;
}

/// 传输层流式事件。
sealed class LlmStreamEvent {
  const LlmStreamEvent();
}

/// 正文增量。
final class LlmTextDelta extends LlmStreamEvent {
  const LlmTextDelta(this.text);

  final String text;
}

/// 推理（thinking）增量。
final class LlmThinkingDelta extends LlmStreamEvent {
  const LlmThinkingDelta(this.text);

  final String text;
}

/// 工具调用增量：同一 [index] 的分片需要按到达顺序拼接。
final class LlmToolCallDelta extends LlmStreamEvent {
  const LlmToolCallDelta({
    required this.index,
    this.id,
    this.name,
    this.argumentsDelta = '',
  });

  final int index;
  final String? id;
  final String? name;
  final String argumentsDelta;
}

/// 用量（通常只在最后一帧出现）。
final class LlmUsageEvent extends LlmStreamEvent {
  const LlmUsageEvent(this.usage);

  final LlmUsage usage;
}

/// 本轮流结束（`finish_reason`）。
final class LlmFinishEvent extends LlmStreamEvent {
  const LlmFinishEvent(this.reason);

  final String reason;
}

/// 失败（HTTP 错误、流中错误帧、网络异常、超时、取消）。
final class LlmFailureEvent extends LlmStreamEvent {
  const LlmFailureEvent(
    this.message, {
    this.statusCode,
    this.cancelled = false,
  });

  final String message;
  final int? statusCode;

  /// 是否因用户取消而中断（不算错误，UI 不报错）。
  final bool cancelled;
}
