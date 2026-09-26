import 'dart:convert';

import 'llm_types.dart';

/// OpenAI 兼容协议的编解码（**所有与厂商相关的细节都收敛在这里**）。
///
/// 兼容面：
/// - 端点：`{base_url}/chat/completions`（`base_url` 已含该路径时不重复拼）；
/// - thinking 增量：同时认 `reasoning_content`（DeepSeek 系）与 `reasoning`；
/// - tool_calls：`delta.tool_calls[i]` 分片到达，参数是**字符串片段**；
/// - usage：开启 `stream_options.include_usage` 后最后一帧携带；
/// - 错误：HTTP 非 200 由传输层处理；流中 `{"error": {...}}` 在这里识别。
abstract final class OpenAiCodec {
  /// 拼出 chat/completions 端点。
  static String endpointFor(String baseUrl) {
    final String base = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) return '/chat/completions';
    if (base.endsWith('/chat/completions')) return base;
    // 端点常写成 ".../v1"，也有人写成 ".../v1/"，两种都要能拼对
    return '$base/chat/completions';
  }

  /// 构造请求体。
  static Map<String, dynamic> requestBody(
    LlmRequest request, {
    required bool stream,
  }) {
    final Map<String, dynamic> body = <String, dynamic>{
      'model': request.model,
      'messages': request.messages.map((LlmMessage m) => m.toWire()).toList(),
      'stream': stream,
      ...request.extra,
    };
    if (stream) {
      // 让端点把 usage 放在最后一帧（OpenAI 兼容端点普遍支持；不支持也只是少个字段）
      body['stream_options'] = <String, dynamic>{'include_usage': true};
    }
    if (request.tools.isNotEmpty) {
      body['tools'] = request.tools.map((LlmToolSpec t) => t.toWire()).toList();
    }
    if (request.maxOutputTokens != null && request.maxOutputTokens! > 0) {
      body['max_tokens'] = request.maxOutputTokens;
    }
    if (request.reasoningEffort != null &&
        request.reasoningEffort!.isNotEmpty) {
      body['reasoning_effort'] = request.reasoningEffort;
    }
    if (request.temperature != null) {
      body['temperature'] = request.temperature;
    }
    return body;
  }

  /// 解码一个流式分片（SSE `data:` 的 JSON 文本）。
  ///
  /// 返回空列表表示该分片没有可用事件（心跳、空 delta 等）。
  static List<LlmStreamEvent> decodeChunk(String payload) {
    if (payload.trim().isEmpty) return const <LlmStreamEvent>[];
    Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } catch (_) {
      // 单个坏分片不应中断整轮生成：上层只看到"这一段没内容"
      return const <LlmStreamEvent>[];
    }
    if (decoded is! Map<String, dynamic>) return const <LlmStreamEvent>[];
    final List<LlmStreamEvent> events = <LlmStreamEvent>[];

    // 流中错误帧：{"error": {"message": "..."}}
    final Object? error = decoded['error'];
    if (error is Map) {
      final String message =
          (error['message'] as String?) ??
          (error['type'] as String?) ??
          '端点返回错误';
      events.add(LlmFailureEvent(message));
      return events;
    }

    final Object? usage = decoded['usage'];
    if (usage is Map) {
      final LlmUsage parsed = decodeUsage(usage);
      if (!parsed.isEmpty) events.add(LlmUsageEvent(parsed));
    }

    final Object? choices = decoded['choices'];
    if (choices is List && choices.isNotEmpty) {
      final Object? first = choices.first;
      if (first is Map) {
        final Object? delta = first['delta'];
        if (delta is Map) {
          final Object? content = delta['content'];
          if (content is String && content.isNotEmpty) {
            events.add(LlmTextDelta(content));
          }
          // 不同厂商的思考字段名不同，两个都认
          for (final String key in <String>['reasoning_content', 'reasoning']) {
            final Object? thinking = delta[key];
            if (thinking is String && thinking.isNotEmpty) {
              events.add(LlmThinkingDelta(thinking));
              break;
            }
          }
          final Object? toolCalls = delta['tool_calls'];
          if (toolCalls is List) {
            for (final Object? raw in toolCalls) {
              if (raw is! Map) continue;
              final int index = (raw['index'] as num?)?.toInt() ?? 0;
              final Object? function = raw['function'];
              final String? name = function is Map
                  ? function['name'] as String?
                  : null;
              final String args = function is Map
                  ? (function['arguments'] as String? ?? '')
                  : '';
              events.add(
                LlmToolCallDelta(
                  index: index,
                  id: raw['id'] as String?,
                  name: (name != null && name.isNotEmpty) ? name : null,
                  argumentsDelta: args,
                ),
              );
            }
          }
        }
        final Object? finish = first['finish_reason'];
        if (finish is String && finish.isNotEmpty) {
          events.add(LlmFinishEvent(finish));
        }
      }
    }
    return events;
  }

  /// 解码 usage 字段。
  static LlmUsage decodeUsage(Map<dynamic, dynamic> usage) {
    int pick(List<String> keys) {
      for (final String key in keys) {
        final Object? value = usage[key];
        if (value is num) return value.toInt();
      }
      return 0;
    }

    final int prompt = pick(<String>['prompt_tokens', 'input_tokens']);
    final int completion = pick(<String>['completion_tokens', 'output_tokens']);
    final int total = pick(<String>['total_tokens']);
    int cached = pick(<String>['cached_tokens']);
    final Object? details = usage['prompt_tokens_details'];
    if (details is Map) {
      cached = (details['cached_tokens'] as num?)?.toInt() ?? cached;
    }
    return LlmUsage(
      promptTokens: prompt,
      completionTokens: completion,
      totalTokens: total == 0 ? prompt + completion : total,
      cachedTokens: cached,
    );
  }
}
