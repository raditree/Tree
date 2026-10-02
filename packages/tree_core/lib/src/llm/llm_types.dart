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

import '../util/tokens.dart';

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

  /// 从线协议恢复（**有损单向的逆**：插件改写请求体时用，见 [LlmRequest.tryFromWire]）。
  ///
  /// 结构不对返回 null——调用方一律**放行原请求**（fail-open），绝不拿半成品投 LLM。
  static LlmToolCall? tryFromWire(Object? raw) {
    if (raw is! Map) return null;
    final Object? fn = raw['function'];
    final Map<dynamic, dynamic> body = fn is Map ? fn : raw;
    final String name = (body['name'] ?? '').toString();
    if (name.trim().isEmpty) return null;
    return LlmToolCall(
      id: (raw['id'] ?? '').toString(),
      name: name,
      arguments: (body['arguments'] ?? '').toString(),
    );
  }
}

/// 一条消息里的**内容块**（OpenAI 兼容 `content` 数组的元素）。
///
/// 为什么需要它：图像这类二进制内容塞不进 `content: String`。本仓库采用
/// DeepSeek 的口径——**先把文件上传到端点拿到 `file_id`，再在请求里引用**
/// （见 `vision_files.dart`）：base64 内联会把编码后的图片直接放进请求体，
/// 受 48 MiB 请求体 / 32 MiB 单图限制；Files API 单文件可到 64 MiB。
///
/// 目前只用到两型：`text`（正文）与 `file`（端点文件引用）。
class LlmContentPart {
  /// 正文块。
  const LlmContentPart.text(this.text) : type = 'text', fileId = '';

  /// 端点文件引用块（`file_id` 来自 Files API 上传响应）。
  const LlmContentPart.file(this.fileId) : type = 'file', text = '';

  /// 线协议类型：`text` / `file`。
  final String type;

  /// 正文（[type] == `text` 时有值）。
  final String text;

  /// 端点文件 id（[type] == `file` 时有值）。
  final String fileId;

  /// 线协议形状：**`file_id` 是内容块的同级字段，不再套一层 `file` 对象**。
  ///
  /// 实测（2026-10-01，真实端点 + 真图，逐形状探针）：
  /// - `{"type":"file","file":{"file_id":…}}` ⇒ **400**：
  ///   `file must have a file_id or file_data`（外层 `file` 对象被判成"没有 file_id"）；
  /// - `{"type":"file","file_id":…}` ⇒ **200**，且模型**真的看得见图**
  ///   （让它转写图中文字，逐字正确）。
  ///
  /// 也就是说 OpenAI 那套「`file` 里再放 `file_id`」的嵌套在 DeepSeek 端点是**错的**；
  /// 之前"upload 成功但 chat 一直 400"的根因就在这里——与密钥、上传、缓存都无关。
  Map<String, dynamic> toWire() => type == 'file'
      ? <String, dynamic>{'type': 'file', 'file_id': fileId}
      : <String, dynamic>{'type': 'text', 'text': text};

  /// 从线协议恢复；未知类型返回 null（调用方放行原请求）。
  static LlmContentPart? tryFromWire(Object? raw) {
    if (raw is! Map) return null;
    final String type = (raw['type'] ?? 'text').toString();
    return switch (type) {
      'file' => LlmContentPart.file((raw['file_id'] ?? '').toString()),
      'text' => LlmContentPart.text((raw['text'] ?? '').toString()),
      _ => null,
    };
  }
}

/// 一条对话消息。
class LlmMessage {
  const LlmMessage({
    required this.role,
    this.content = '',
    this.toolCalls = const <LlmToolCall>[],
    this.toolCallId,
    this.name,
    this.reasoningContent = '',
    this.contentParts = const <LlmContentPart>[],
  });

  /// 便捷构造。
  const LlmMessage.system(this.content)
    : role = LlmRole.system,
      toolCalls = const <LlmToolCall>[],
      toolCallId = null,
      name = null,
      reasoningContent = '',
      contentParts = const <LlmContentPart>[];

  /// 便捷构造。
  const LlmMessage.user(this.content)
    : role = LlmRole.user,
      toolCalls = const <LlmToolCall>[],
      toolCallId = null,
      name = null,
      reasoningContent = '',
      contentParts = const <LlmContentPart>[];

  /// 便捷构造（[reasoningContent] 只在"回传思考"开启时才有值，见 [toWire]）。
  const LlmMessage.assistant(this.content, {this.reasoningContent = ''})
    : role = LlmRole.assistant,
      toolCalls = const <LlmToolCall>[],
      toolCallId = null,
      name = null,
      contentParts = const <LlmContentPart>[];

  /// 便捷构造（工具执行结果）。
  const LlmMessage.toolResult({
    required this.content,
    required String this.toolCallId,
  }) : role = LlmRole.tool,
       toolCalls = const <LlmToolCall>[],
       name = null,
       reasoningContent = '',
       contentParts = const <LlmContentPart>[];

  final LlmRole role;
  final String content;
  final List<LlmToolCall> toolCalls;
  final String? toolCallId;
  final String? name;

  /// 正文之外的**内容块**（当前只有"已上传到端点的文件引用"）。
  ///
  /// 非空时 [toWire] 把 `content` 输出成**数组**（`[{type:text},{type:file}...]`），
  /// 这是 OpenAI 兼容端点表达多模态内容的方式；空（默认）时仍是字符串，与改动前
  /// 逐字一致。**只对 user / system 生效**（两者共用同一条线形态）：assistant 与
  /// tool 恒为字符串——assistant 回灌的是历史正文，tool 回灌的是工具结果文本。
  ///
  /// 这些块**不计入** [charCount] / [estimatedTokens]：图片占多少 token 没有官方
  /// 口径（DeepSeek 未公布），凭空加一个常数只会让"本地估算"与真实 usage 打架。
  final List<LlmContentPart> contentParts;

  /// 思考（推理）正文：DeepSeek 的 `reasoning_content`，与 `content` **同级**
  /// 放在 assistant 消息上。
  ///
  /// **只有"回传思考"开启（模型配置的 `thinking`）时才有值**：官方文档与实测都表明
  /// 请求带 `tools` 时历史中的 `reasoning_content` 必须原样回传，否则同会话后续请求
  /// 会持续 400；参考实现（`server/llm/llm.py`）也是这么写的。关闭时留空 = 不回传
  /// （部分网关容忍缺失，且能显著省输入 token）。
  final String reasoningContent;

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
        // DeepSeek 思考模式：带 tools 的请求必须回传历史 reasoning_content，
        // 且字段就在 assistant 消息顶层、与 content 同级（不能嵌套）
        if (reasoningContent.isNotEmpty) {
          out['reasoning_content'] = reasoningContent;
        }
        if (toolCalls.isNotEmpty) {
          out['tool_calls'] = toolCalls
              .map((LlmToolCall c) => c.toWire())
              .toList();
        }
        return out;
      case LlmRole.system:
      case LlmRole.user:
        // 有内容块时 `content` 变成数组（多模态表达）；没有时保持字符串——
        // 这是"不开启视觉时请求体与改动前逐字一致"的关键。
        // 首块固定是正文（若有），其后按附件顺序排列，端点是按顺序解释的。
        out['content'] = contentParts.isEmpty
            ? content
            : <Map<String, dynamic>>[
                if (content.isNotEmpty)
                  <String, dynamic>{'type': 'text', 'text': content},
                ...contentParts.map(
                  (LlmContentPart part) => part.toWire(),
                ),
              ];
        if (name != null) out['name'] = name;
        return out;
    }
  }

  /// 该消息的**字符数**（token 换算与 token_scale 学习共用同一口径）。
  ///
  /// 只算正文与工具调用的名字/参数：JSON 外壳、role 之类的固定开销由端点侧承担，
  /// 本地估算刻意不去模拟它们（真要精确就该以端点 usage 为准）。
  int get charCount =>
      content.length +
      reasoningContent.length +
      toolCalls.fold<int>(
        0,
        (int sum, LlmToolCall call) =>
            sum + call.name.length + call.arguments.length,
      );

  /// 估算该消息占用的 token（口径见 util/tokens.dart：`ceil(字符数 / scale)`）。
  ///
  /// 工具调用额外加 8 token 的协议外壳（id/type/function 这些字段本身要约 20~30
  /// 字符，按 2.0 的比例折算即可）。
  int estimatedTokens({double scale = defaultTokenScale}) {
    int tokens =
        estimateTokens(content, scale: scale) +
        estimateTokens(reasoningContent, scale: scale);
    for (final LlmToolCall call in toolCalls) {
      tokens += 8 + estimateTokens(call.name + call.arguments, scale: scale);
    }
    return tokens;
  }

  /// 从线协议恢复一条消息（**有损单向的逆**；插件改写请求体时用）。
  ///
  /// **有损之处（必须知道）**：
  /// - `content` 在线协议里可能是数组（多模态）：这里把文本块拼回 [content]、
  ///   文件块还原成 [contentParts]——与 [toWire] 的分块顺序一致，往返不丢信息；
  /// - `role` 认不出返回 null（调用方放行原请求）；
  /// - assistant 的 `content: null` 还原成空串（与 [toWire] 的"空串 ⇄ null"对称）。
  static LlmMessage? tryFromWire(Object? raw) {
    if (raw is! Map) return null;
    final String role = (raw['role'] ?? '').toString();
    final LlmRole? parsed = switch (role) {
      'system' => LlmRole.system,
      'user' => LlmRole.user,
      'assistant' => LlmRole.assistant,
      'tool' => LlmRole.tool,
      _ => null,
    };
    if (parsed == null) return null;
    String content = '';
    final List<LlmContentPart> parts = <LlmContentPart>[];
    final Object? rawContent = raw['content'];
    if (rawContent is String) {
      content = rawContent;
    } else if (rawContent is List) {
      final StringBuffer text = StringBuffer();
      for (final Object? item in rawContent) {
        final LlmContentPart? part = LlmContentPart.tryFromWire(item);
        if (part == null) return null;
        if (part.type == 'file') {
          parts.add(part);
        } else {
          text.write(part.text);
        }
      }
      content = text.toString();
    } else if (rawContent != null) {
      return null;
    }
    final List<LlmToolCall> calls = <LlmToolCall>[];
    final Object? rawCalls = raw['tool_calls'];
    if (rawCalls is List) {
      for (final Object? item in rawCalls) {
        final LlmToolCall? call = LlmToolCall.tryFromWire(item);
        if (call == null) return null;
        calls.add(call);
      }
    }
    return LlmMessage(
      role: parsed,
      content: content,
      toolCalls: calls,
      toolCallId: raw['tool_call_id']?.toString(),
      name: raw['name']?.toString(),
      reasoningContent: (raw['reasoning_content'] ?? '').toString(),
      contentParts: parts,
    );
  }
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

  /// 从线协议恢复（插件改写请求体时用）；结构不对返回 null（调用方放行原请求）。
  static LlmToolSpec? tryFromWire(Object? raw) {
    if (raw is! Map) return null;
    final Object? fn = raw['function'];
    final Map<dynamic, dynamic> body = fn is Map ? fn : raw;
    final String name = (body['name'] ?? '').toString();
    if (name.trim().isEmpty) return null;
    final Object? parameters = body['parameters'];
    return LlmToolSpec(
      name: name,
      description: (body['description'] ?? '').toString(),
      parameters: parameters is Map
          ? parameters.map(
              (dynamic k, dynamic v) => MapEntry(k.toString(), v),
            )
          : const <String, dynamic>{},
    );
  }
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
  ///
  /// [scale] 是逐模型 token_scale：估算点必须用**同一个**比例，否则进度条、
  /// 裁剪预算与压缩阈值会互相打架（见 util/tokens.dart）。
  int estimatedPromptTokens({double scale = defaultTokenScale}) =>
      messages.fold<int>(
        0,
        (int sum, LlmMessage m) => sum + m.estimatedTokens(scale: scale),
      );

  /// 本次请求上下文的**字符数**（token_scale 学习的分子口径：见 [LlmMessage.charCount]；
  /// 分母是端点回的真实 prompt_tokens）。
  int contextChars() =>
      messages.fold<int>(0, (int sum, LlmMessage m) => sum + m.charCount);

  /// 发往端点的**请求体形状**（`extra` 平铺，与 [OpenAiCodec.requestBody] 同口径）。
  ///
  /// 中转站「投入 LLM 前」把这个交给插件改写；`extra` 也一并给出（插件能改
  /// `response_format` 这类厂商专用字段）。
  Map<String, dynamic> toWire({bool stream = false}) => <String, dynamic>{
    'model': model,
    'messages': messages.map((LlmMessage m) => m.toWire()).toList(),
    if (tools.isNotEmpty)
      'tools': tools.map((LlmToolSpec t) => t.toWire()).toList(),
    if (maxOutputTokens != null) 'max_tokens': maxOutputTokens,
    if (reasoningEffort != null) 'reasoning_effort': reasoningEffort,
    if (temperature != null) 'temperature': temperature,
    ...extra,
    'stream': stream,
  };

  /// 从线协议恢复一个请求（**有损单向的逆**；插件改写请求体后重建用）。
  ///
  /// 解析规则（任何一处结构不对就返回 null ⇒ 调用方**放行原请求**）：
  /// - `model` 必须非空（它决定打哪个端点模型）；
  /// - `messages` 必须是数组且每条都能还原（见 [LlmMessage.tryFromWire]）；
  /// - `tools` 可选；`max_tokens` / `reasoning_effort` / `temperature` 可选；
  /// - **未识别的字段进 [extra]**（例如插件加的 `response_format`）——不静默丢弃，
  ///   否则"插件改了但没生效"会变成最难查的一类问题。
  static LlmRequest? tryFromWire(Object? raw) {
    if (raw is! Map) return null;
    final String model = (raw['model'] ?? '').toString().trim();
    if (model.isEmpty) return null;
    final Object? rawMessages = raw['messages'];
    if (rawMessages is! List) return null;
    final List<LlmMessage> messages = <LlmMessage>[];
    for (final Object? item in rawMessages) {
      final LlmMessage? message = LlmMessage.tryFromWire(item);
      if (message == null) return null;
      messages.add(message);
    }
    if (messages.isEmpty) return null;
    final List<LlmToolSpec> tools = <LlmToolSpec>[];
    final Object? rawTools = raw['tools'];
    if (rawTools is List) {
      for (final Object? item in rawTools) {
        final LlmToolSpec? spec = LlmToolSpec.tryFromWire(item);
        if (spec == null) return null;
        tools.add(spec);
      }
    }
    num? number(Object? value) =>
        value is num ? value : num.tryParse(value?.toString() ?? '');
    final num? maxTokens = number(raw['max_tokens']);
    final num? temperature = number(raw['temperature']);
    final String reasoning = (raw['reasoning_effort'] ?? '').toString().trim();
    const Set<String> known = <String>{
      'model',
      'messages',
      'tools',
      'max_tokens',
      'temperature',
      'reasoning_effort',
      'stream',
      'stream_options',
    };
    final Map<String, dynamic> extra = <String, dynamic>{
      for (final MapEntry<dynamic, dynamic> entry in raw.entries)
        if (!known.contains(entry.key.toString()))
          entry.key.toString(): entry.value,
    };
    return LlmRequest(
      model: model,
      messages: messages,
      tools: tools,
      maxOutputTokens: maxTokens?.toInt(),
      reasoningEffort: reasoning.isEmpty ? null : reasoning,
      temperature: temperature?.toDouble(),
      extra: extra,
    );
  }
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

/// **重试进度**：这次尝试失败了、即将退避重试（说给用户听的一句话）。
///
/// 它不是模型输出，也**不影响**"这一跳是否已经产出内容"的判定——传输层在它之后
/// 照样可以重试（它被排除在"已交给上层的事件"之外，见 HttpSseTransport.stream）；
/// 上层（LlmSession）把它翻成 `AgentNotice`，落库时带 `llm_hidden`。
final class LlmRetryNotice extends LlmStreamEvent {
  const LlmRetryNotice(
    this.message, {
    required this.attempt,
    required this.total,
  });

  /// 可读文案（含失败原因与等待时长）。
  final String message;

  /// 这是第几次重试（从 1 起）。
  final int attempt;

  /// 一共允许几次重试。
  final int total;
}

/// 失败（HTTP 错误、流中错误帧、网络异常、超时、取消）。
final class LlmFailureEvent extends LlmStreamEvent {
  const LlmFailureEvent(
    this.message, {
    this.statusCode,
    this.cancelled = false,
    this.livenessLost = false,
    this.retryable = true,
  });

  final String message;
  final int? statusCode;

  /// 是否因用户取消而中断（不算错误，UI 不报错）。
  final bool cancelled;

  /// 是否因**心跳丢失（链路失活）**而失败。
  ///
  /// 与普通端点错误区分开：这一类的正确反应是**重连 / 提示用户链路已断**，而不是
  /// 让用户去改模型配置。判据见 HttpSseTransport（连续 N 次心跳未达，与总耗时无关）。
  final bool livenessLost;

  /// 是否【值得重试】（默认 true；口径见 HttpSseTransport 的「重试口径」一节）。
  ///
  /// 传输层按它 + [statusCode] 一起判定。显式置 false 的是【端点已经把话说完了】
  /// 的那一类：流中 error 帧（HTTP 200 但正文是错误对象，例如余额不足、密钥无效）
  /// ——重试只是把同一句拒绝听 5 遍，白花 5 次配额与几分钟等待。
  final bool retryable;
}
