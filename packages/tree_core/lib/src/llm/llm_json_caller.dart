import 'dart:async';
import 'dart:convert';

import '../settings/core_settings.dart';
import 'llm_agent_engine.dart' show TransportFactory;
import 'llm_transport.dart';
import 'llm_types.dart';

/// 模型解析器（与 [LlmAgentEngine.resolveModel] 同一口径）。
typedef JsonCallModelResolver = CoreModelConfig? Function(String modelId);

/// `llm.call`（执行站命令）的落点：**硬设 JSON 返回形式**的一次性 LLM 调用。
///
/// 用户定稿语义（2026-10-01）：
/// - **站点处硬设** `response_format = {"type":"json_object"}`——不是可选参数，
///   插件拿到的就是 JSON 形式；端点不支持时**如实失败**（不静默去掉再试一次）；
/// - **复用对应 agent 的模型**：由调用方按 agent 解析 modelId（成员级覆盖照旧生效），
///   [model] 参数只作显式覆盖；
/// - 这是一次**独立**的调用：不进任何中转站点位、不计入该 agent 的对话用量
///   （usage 随回包交给插件），也不写会话历史。
///
/// 与 [LlmSummarizer] 的差别：那个是"内部工具"（固定提示词、无 JSON 要求、失败回退），
/// 这个是"给插件用的通用能力"（插件给消息、核心保证 JSON 形式、失败如实回报）。
class LlmJsonCaller {
  LlmJsonCaller({
    required this.resolveModel,
    this.agentOverrides,
    this.transportFactory,
    this.timeout = const Duration(seconds: 120),
    this.log,
  });

  /// 按 modelId 解析模型配置。
  final JsonCallModelResolver resolveModel;

  /// 成员级模型参数覆盖（与对话引擎同一份口径）。
  final Map<String, Object?> Function(String agentId)? agentOverrides;

  /// 传输层工厂；为空时按 (base_url, api_key) 建 [HttpSseTransport] 并缓存。
  final TransportFactory? transportFactory;

  /// 静态超时：这是插件的一次**工具性调用**（不是对话），必须有界——插件等不到
  /// 回包会拿到可读错误，而不是永远悬着。
  final Duration timeout;

  final void Function(String message)? log;

  final Map<String, LlmTransport> _transports = <String, LlmTransport>{};
  int _seq = 0;

  /// 发一次调用。
  ///
  /// [model] 非空 = 显式覆盖模型名；[messages] / [prompt] 二选一（都没有则报错）。
  /// [tools] = OpenAI 形状的工具声明数组（原样透传；压缩插件靠它对齐对话前缀）。
  /// 返回 `{ok: true, json, text, model, usage}` 或 `{error: 可读原因}`。
  Future<Map<String, dynamic>> call({
    required String agentId,
    required String modelId,
    List<Object?>? messages,
    String? prompt,
    String? system,
    String? model,
    double? temperature,
    int? maxTokens,
    List<Object?>? tools,
  }) async {
    final CoreModelConfig? resolved = resolveModel(modelId);
    final CoreModelConfig? config = resolved?.withOverrides(
      agentOverrides?.call(agentId) ?? const <String, Object?>{},
    );
    if (config == null) {
      return <String, dynamic>{
        'error': modelId.isEmpty
            ? 'agent $agentId 尚未指定模型：llm.call 需要该 agent 的模型'
            : '模型配置不存在：$modelId（可能已被删除）',
      };
    }
    if (config.baseUrl.trim().isEmpty || config.apiKey.trim().isEmpty) {
      return <String, dynamic>{
        'error': '模型「${config.name.isEmpty ? config.modelId : config.name}」'
            '缺少 base_url 或 api_key',
      };
    }
    final String effectiveModel = (model ?? '').trim().isEmpty
        ? config.modelId
        : model!.trim();
    final List<LlmMessage> built = _buildMessages(
      messages: messages,
      prompt: prompt,
      system: system,
    );
    if (built.isEmpty) {
      return const <String, dynamic>{
        'error': 'llm.call 需要 messages（数组）或 prompt（字符串）',
      };
    }
    // 工具声明：**原样透传**，不解析成 spec 再重建——插件给自己的前缀要与对话
    // 逐字一致，中间做一次"解析 + 重编码"就可能改变字段顺序/形态而丢掉缓存命中。
    final List<Map<String, dynamic>> rawTools = <Map<String, dynamic>>[];
    if (tools != null) {
      for (final Object? item in tools) {
        if (item is! Map) {
          return const <String, dynamic>{
            'error': 'llm.call 的 tools 里有非对象元素（应为 OpenAI 工具声明）',
          };
        }
        rawTools.add(
          item.map(
            (dynamic key, dynamic value) => MapEntry<String, dynamic>(
              key.toString(),
              value,
            ),
          ),
        );
      }
    }
    final LlmRequest request = LlmRequest(
      model: effectiveModel,
      messages: built,
      tools: <LlmToolSpec>[
        for (final Map<String, dynamic> item in rawTools)
          if (LlmToolSpec.tryFromWire(item) case final LlmToolSpec spec) spec,
      ],
      maxOutputTokens: maxTokens != null && maxTokens > 0 ? maxTokens : null,
      temperature: temperature,
      // **站点处硬设**：JSON 返回形式由这里统一加上，插件不需要也无法关掉它。
      extra: const <String, dynamic>{
        'response_format': <String, dynamic>{'type': 'json_object'},
      },
    );
    final StringBuffer text = StringBuffer();
    LlmUsage usage = const LlmUsage();
    String failure = '';
    try {
      final LlmTransport transport = _transportFor(config);
      await for (final LlmStreamEvent event in transport
          .stream(request, isCancelled: () => false)
          .timeout(timeout, onTimeout: (EventSink<LlmStreamEvent> sink) {
            sink.add(
              LlmFailureEvent('llm.call 超过 ${timeout.inSeconds}s 未完成，已中止'),
            );
            sink.close();
          })) {
        if (event is LlmTextDelta) {
          text.write(event.text);
        } else if (event is LlmThinkingDelta) {
          // 思考正文不进 JSON 结果：它是过程，不是产出
          continue;
        } else if (event is LlmUsageEvent) {
          usage = event.usage;
        } else if (event is LlmFailureEvent) {
          failure = event.message;
          break;
        }
      }
    } catch (error) {
      failure = 'llm.call 调用异常：$error';
    }
    if (failure.isNotEmpty) {
      log?.call('llm.call 失败（agent=$agentId model=$effectiveModel）：$failure');
      return <String, dynamic>{'error': failure, 'model': effectiveModel};
    }
    final String raw = text.toString();
    final Object? parsed = _tryParseJson(raw);
    if (parsed == null) {
      return <String, dynamic>{
        'error':
            '模型没有返回合法 JSON（站点处硬设了 response_format=json_object；'
            '若该端点不支持该参数，请换用支持的模型）',
        'text': raw,
        'model': effectiveModel,
      };
    }
    return <String, dynamic>{
      'ok': true,
      'json': parsed,
      'text': raw,
      'model': effectiveModel,
      'usage': <String, dynamic>{
        'prompt_tokens': usage.promptTokens,
        'completion_tokens': usage.completionTokens,
        'total_tokens': usage.totalTokens,
        'cached_tokens': usage.cachedTokens,
      },
    };
  }

  /// 组装消息：`messages`（OpenAI 形状）优先，否则用 `prompt` 拼一条 user 消息。
  static List<LlmMessage> _buildMessages({
    List<Object?>? messages,
    String? prompt,
    String? system,
  }) {
    final List<LlmMessage> out = <LlmMessage>[];
    final String systemText = (system ?? '').trim();
    if (systemText.isNotEmpty) out.add(LlmMessage.system(systemText));
    if (messages != null && messages.isNotEmpty) {
      for (final Object? item in messages) {
        final LlmMessage? message = LlmMessage.tryFromWire(item);
        if (message == null) continue;
        out.add(message);
      }
      return out;
    }
    final String text = (prompt ?? '').trim();
    if (text.isNotEmpty) out.add(LlmMessage.user(text));
    return out;
  }

  /// 解析 JSON：模型可能包 ```json 代码块或前后带解释，这里做**最小容错**。
  static Object? _tryParseJson(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) return null;
    Object? decoded = _decode(text);
    if (decoded != null) return decoded;
    final int start = text.indexOf('{');
    final int end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      decoded = _decode(text.substring(start, end + 1));
      if (decoded != null) return decoded;
    }
    return null;
  }

  static Object? _decode(String text) {
    try {
      final Object? value = jsonDecode(text);
      // JSON 形式要求"一个对象"；数组 / 标量也接受（由插件决定怎么用），
      // 但 null 视为没解出来
      return value;
    } catch (_) {
      return null;
    }
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

  /// 关闭缓存的传输（核心退出时调用；幂等）。
  Future<void> close() async {
    for (final LlmTransport transport in _transports.values) {
      await transport.close();
    }
    _transports.clear();
  }

  /// 供日志用的调用序号（同一进程内递增，便于对上插件的调用与核心日志）。
  int nextSeq() => ++_seq;
}
