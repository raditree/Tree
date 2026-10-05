import 'dart:async';
import 'dart:convert';

import '../settings/core_settings.dart';
import '../store/usage_log.dart';
import '../util/tokens.dart';
import 'llm_agent_engine.dart' show TransportFactory;
import 'llm_session.dart';
import 'llm_transport.dart';
import 'llm_types.dart';

/// 模型解析器（与 [LlmAgentEngine.resolveModel] 同一口径）。
typedef JsonCallModelResolver = CoreModelConfig? Function(String modelId);

/// `llm.call`（执行站命令）的落点：一次性 LLM 调用，**缺省硬设 JSON 返回形式**。
///
/// 用户定稿语义（2026-10-01；2026-10-04 增补 text 覆盖）：
/// - **缺省**在站点处硬设 `response_format = {"type":"json_object"}`；插件拿到的就是
///   JSON 形式，端点不支持时**如实失败**（不静默去掉再试一次）；
/// - **显式 `responseFormat: 'text'`** 时**不发** `response_format`：实测
///   `{"type":"json_object"}` 会让端点**改写提示词**（同一批 messages 恒定 +22 token，
///   且改写落在 messages 区域之前/其中），于是"逐字复用对话前缀"的调用命中率从
///   `384/492` 掉到 **0**；要省这笔钱（长会话压缩的输入动辄 15 万~60 万 token）就必须
///   走 text 形态，见 `docs/known-issues.md` #27。
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
    this.requestRegistrar,
    this.log,
    this.usageSink,
  });

  /// 按 modelId 解析模型配置。
  final JsonCallModelResolver resolveModel;

  /// 成员级模型参数覆盖（与对话引擎同一份口径）。
  final Map<String, Object?> Function(String agentId)? agentOverrides;

  /// 传输层工厂；为空时按 (base_url, api_key) 建 [HttpSseTransport] 并缓存。
  final TransportFactory? transportFactory;

  /// **软超时**（用户 2026-10-03 定夺）：到点**不中止**这次调用，只记一行日志说明
  /// "已运行 N 秒仍未结束"，回包照旧等下去（**结果不丢**）。`Duration.zero` / 负值 = **永不软超时**。
  ///
  /// 为什么是软的：全仓断言是"**没有任何硬超时**；限制只有两类——①心跳丢失 ②软超时；
  /// **软超时后只允许显式关闭**"。此前这里是 `.timeout(120s, onTimeout: 已中止)`——
  /// 一刀切中止插件的一次性调用（压缩插件走的就是它），与断言直接冲突。
  /// 悬挂的调用该由显式入口收手（`tool_runs action=close` / 右栏「正在执行的 tool」），
  /// 而不是被定时器杀掉。
  final Duration timeout;

  /// 「运行中的 `llm.call`」的登记落点（见 `LlmRequestRegistrar`，可选注入）：
  /// **软超时到点才登记**（正常快调用不进表，不打扰右栏与 `query_status`）；
  /// 登记后**可被显式关闭**（用户右栏 / 插件 `tool.close` / agent `tool_runs action=close`
  /// —— 与工具那套**同一个实现**）⇒ 关闭即取消本流并释放连接。
  ///
  /// 为什么要它：`timeout` 现在是**软的**（不中止），若没有这条兜底，一个真挂住的
  /// `llm.call` 就是"无界等待且无人能收手"——正是全仓断言要避免的形态。
  LlmRequestRegistrar? requestRegistrar;

  final void Function(String message)? log;

  /// **逐调用用量回调**（可注入、**可写字段**）：一次 `llm.call` = 一次 LLM 调用，
  /// 落 `source=llm.call`（压缩插件走的就是这条路，以前它**完全不计账**）。
  ///
  /// 与回包里给插件的 `usage` 是**两件事**：回包只给插件看，这个回调才让核心侧
  /// 有机会落一份"事后可核对"的账。
  ///
  /// 为什么是**可写字段**而不是 final：[call] 原来的签名里**只有 agentId、没有会话**
  /// （`StationLlmCaller` 的既有契约），所以"这笔账落到哪个会话"只有站点调用点
  /// （`execute_mounts` 里有 `scope.sessionId`）知道。范式同
  /// `LlmAgentEngine.toolTurnCompactor`：谁先建好谁接上。
  ///
  /// **生产走的是 [call] 的 `usageSink` 参数**（按调用传入、零共享状态，理由见那里的
  /// 说明：两个插件可以并发 `llm.call`，共享字段会让账落到别人的会话上）；
  /// 这个字段只是兜底与单测用的默认值。
  ///
  /// 端点没给 usage 时用**本地估算**并标 `estimated: true`，估算与对话共用
  /// `util/tokens.dart` 的同一个函数。
  UsageSink? usageSink;

  final Map<String, LlmTransport> _transports = <String, LlmTransport>{};
  int _seq = 0;

  /// 发一次调用。
  ///
  /// [model] 非空 = 显式覆盖模型名；[messages] / [prompt] 二选一（都没有则报错）。
  /// [tools] = OpenAI 形状的工具声明数组（原样透传；压缩插件靠它对齐对话前缀）。
  /// [usageSink] = **这一次调用**的用量回调；给了就优先于构造期/可写字段的那个。
  ///
  /// 为什么要"按调用传"而不是只靠共享的可写字段：站点调用点是**并发**的（两个插件
  /// 可以同时 `llm.call`），而可写字段是**一个实例一份状态**——A 设置了 sink 之后、
  /// 它的回包回来之前，B 又设置一次，A 的账就会落到 B 的会话上。按调用传入 ⇒ 每次
  /// 绑定自己的会话，零共享状态。
  /// 返回 `{ok: true, json, text, model, usage}` 或 `{error: 可读原因}`。
  ///
  /// [responseFormat] = `'text'` 时**不发** `response_format`（请求体与对话那一轮同形态，
  /// 前缀缓存才可能命中）；`null` 或其它值 = 站点缺省的 **JSON 返回形式**。
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
    String? responseFormat,
    UsageSink? usageSink,
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
      // 返回形式（**站点口径**：调用方只能在 text / json 之间选，塞不进别的值）：
      // - 缺省（含 `null`）= **硬设 JSON**，与引入 text 分支前逐字一致；
      // - `'text'` = **不发**该字段 ⇒ 请求体与对话那一轮同形态，前缀缓存才可复用
      //   （实测：只加 `{"type":"json_object"}` 就让同一 492 token 前缀的命中从
      //   384/256 掉到 0；见 docs/known-issues.md #27）。
      extra: responseFormat == 'text'
          ? const <String, dynamic>{}
          : const <String, dynamic>{
              'response_format': <String, dynamic>{'type': 'json_object'},
            },
    );
    final StringBuffer text = StringBuffer();
    LlmUsage usage = const LlmUsage();
    String failure = '';
    final Stopwatch clock = Stopwatch()..start();
    try {
      final LlmTransport transport = _transportFor(config);
      // **软超时 + 显式取消兜底**（用户 2026-10-03 定夺 (a)，与全仓断言同口径）：
      // - 到点**不中止**：只留痕 + （有登记落点时）把这次调用登记成"可关闭的运行"；
      // - 登记后被**显式关闭**（用户右栏 / 插件 `tool.close` / agent `tool_runs action=close`）
      //   ⇒ 立刻以取消收尾，并 `cancel()` 底层订阅（HTTP/SSE 连接随之释放）。
      //   为什么不能只靠 `isCancelled`：零事件时没人去问它（挂住的 socket 恰恰没有事件）。
      bool closed = false;
      final Duration limit = timeout;
      final StreamController<LlmStreamEvent> watched =
          StreamController<LlmStreamEvent>();
      StreamSubscription<LlmStreamEvent>? sub;
      LlmRequestGuard? guard;
      Timer? softClock;
      Timer? closeClock;
      bool done = false;
      void settle() {
        softClock?.cancel();
        closeClock?.cancel();
        guard?.finish();
      }

      watched.onListen = () {
        if (limit > Duration.zero) {
          softClock = Timer(limit, () {
            if (done) return;
            guard ??= requestRegistrar?.call(
              agentId: agentId,
              // `llm.call` 的既有契约里没有会话（只有 agentId）——空串如实表达"不归属某会话"。
              sessionId: '',
              model: effectiveModel,
              turn: 0,
            );
            log?.call(
              'llm.call 已运行 ${limit.inSeconds} 秒仍未结束（软超时：**不中止**，继续等回包）'
              '${guard == null ? '' : '；已登记为可关闭运行 ${guard!.handle}'
                  '（tool_runs / 右栏可显式关闭）'}',
            );
          });
        }
        // 关闭探测间隔**由软超时派生**（带上限）：生产 2s；测试用很短的阈值时自动变快。
        final Duration closeEvery = Duration(
          milliseconds: limit.inMilliseconds <= 0
              ? 2000
              : (limit.inMilliseconds ~/ 4).clamp(10, 2000),
        );
        closeClock = Timer.periodic(closeEvery, (Timer _) {
          final LlmRequestGuard? current = guard;
          if (done || current == null || !current.closed) return;
          done = true;
          closed = true;
          log?.call('llm.call ${current.handle} 已被显式关闭 ⇒ 取消这次调用');
          if (!watched.isClosed) {
            watched.add(
              const LlmFailureEvent(
                '这次 llm.call 已被显式关闭（用户 / 插件 / agent）',
                cancelled: true,
              ),
            );
          }
          unawaited(sub?.cancel());
          settle();
          if (!watched.isClosed) unawaited(watched.close());
        });
        sub = transport
            .stream(request, isCancelled: () => closed)
            .listen(
              (LlmStreamEvent event) {
                if (done || watched.isClosed) return;
                watched.add(event);
              },
              onError: (Object error, StackTrace stack) {
                if (done || watched.isClosed) return;
                watched.addError(error, stack);
              },
              onDone: () {
                if (!done) {
                  done = true;
                  settle();
                }
                if (!watched.isClosed) unawaited(watched.close());
              },
              cancelOnError: false,
            );
      };
      watched.onCancel = () async {
        done = true;
        settle();
        await sub?.cancel();
      };
      try {
        await for (final LlmStreamEvent event in watched.stream) {
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
      } finally {
        // 计时器只负责留痕与关闭探测：无论正常结束还是异常，都要收掉它们。
        done = true;
        settle();
      }
    } catch (error) {
      failure = 'llm.call 调用异常：$error';
    }
    clock.stop();
    // 逐调用账目（**每次 `llm.call` 一笔**，成败都算：请求确实发出去了）。
    _recordUsage(
      agentId: agentId,
      config: config,
      model: effectiveModel,
      request: request,
      text: text.toString(),
      usage: usage,
      durationMs: clock.elapsedMilliseconds,
      sink: usageSink,
    );
    if (failure.isNotEmpty) {
      log?.call('llm.call 失败（agent=$agentId model=$effectiveModel）：$failure');
      return <String, dynamic>{'error': failure, 'model': effectiveModel};
    }
    final String raw = text.toString();
    final Object? parsed = _tryParseJson(raw);
    if (parsed == null) {
      // **解析失败 ≠ 整笔白花**：这里必须把"能诊断 + 能自愈"的东西完整带出去。
      // - `text` 原样带回 ⇒ 插件可做本地修复，或发一次小的"判断 + 修 JSON"调用；
      // - `truncated_suspect` = 末尾不是 `}`/`]`，或括号/引号不配平（疑似被截断）；
      // - 落一条核心日志：本分支此前**一条日志都没有**，事故现场只看到"插件回 null"，
      //   事后无从诊断（现场：734k prompt ≈100% 命中的总结调用因正文非法 JSON 被整包
      //   弃用、回退内置压缩；见 docs/known-issues.md #31）。
      final bool truncated = _looksTruncated(raw);
      log?.call(
        'llm.call 回包不是合法 JSON（agent=$agentId model=$effectiveModel '
        'response_format=${responseFormat ?? 'json_object'} 正文 ${raw.length} 字'
        '${truncated ? '，疑似被截断' : ''}）：${_rawPreview(raw)}'
        // 首尾预览看不出"坏在哪儿"时，解析器的原话（含 offset）是最短的线索：
        // 真机两次事故都只留下了"正文 9380 字"这类信息，定位不到具体坏点。
        '${_lastDecodeError.isEmpty ? '' : '；解析错误：$_lastDecodeError'}',
      );
      return <String, dynamic>{
        'error': responseFormat == 'text'
            // text 形态下**根本没发** response_format（为保住对话前缀缓存），
            // 旧文案"站点处硬设了 json_object"在这条路上是错的、会把人带偏。
            ? '模型正文不是合法 JSON（本次按 text 形态发送：未发 response_format，'
                  '端点不会为它强制 JSON 形式 —— 模型偶发夹解释、或被输出上限截断）'
            : '模型没有返回合法 JSON（站点处硬设了 response_format=json_object；'
                  '若该端点不支持该参数，请换用支持的模型）',
        'error_kind': 'json_parse',
        'text': raw,
        'text_length': raw.length,
        'truncated_suspect': truncated,
        'model': effectiveModel,
        'response_format': responseFormat ?? 'json_object',
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

  /// 记一笔 `source=llm.call` 的逐调用用量（未接线时什么都不做）。
  ///
  /// [sink] = **本次调用**专有的回调（优先）；为空才退到可写字段 [usageSink]。
  ///
  /// 口径：端点给了 usage 用**真值**（`estimated: false`）；没给（或这次失败没有
  /// 回包）用**本地估算**并标 `estimated: true`——prompt 按本次请求的
  /// `estimatedPromptTokens`、completion 按返回正文的 `estimateTokens`，与对话
  /// **共用** `util/tokens.dart` 的唯一口径。`cached_tokens` 拿不到就留空（不编造 0）。
  void _recordUsage({
    required String agentId,
    required CoreModelConfig config,
    required String model,
    required LlmRequest request,
    required String text,
    required LlmUsage usage,
    required int durationMs,
    UsageSink? sink,
  }) {
    final UsageSink? target = sink ?? usageSink;
    if (target == null) return;
    final bool estimated = usage.isEmpty;
    target(
      agentId,
      UsageCall(
        at: DateTime.now(),
        source: UsageSource.llmCall,
        model: model,
        promptTokens: estimated
            ? request.estimatedPromptTokens(scale: config.tokenScale)
            : usage.promptTokens,
        cachedTokens: estimated || usage.cachedTokens <= 0
            ? null
            : usage.cachedTokens,
        completionTokens: estimated
            ? estimateTokens(text, scale: config.tokenScale)
            : usage.completionTokens,
        estimated: estimated,
        durationMs: durationMs,
      ),
    );
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

  /// 最近一次解析失败的**原因原话**（`FormatException` 的 message，含 offset）。
  ///
  /// 只服务日志：`truncated_suspect` 只能判"像不像被截断"，判不出"坏在哪个字符"。
  /// 每次 `_tryParseJson` 入口清空，失败分支立刻读——不给调用方新增返回值。
  static String _lastDecodeError = '';

  /// 解析 JSON：模型可能包 ```json 代码块或前后带解释，这里做**最小容错**。
  static Object? _tryParseJson(String raw) {
    final String text = raw.trim();
    _lastDecodeError = '';
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
    } catch (error) {
      _lastDecodeError = '$error';
      return null;
    }
  }

  /// 疑似「输出被截断」的廉价判据（**不下结论，只给插件一个提示位**）。
  ///
  /// 判据：末尾不是 `}` / `]`；或走一遍极简状态机后括号 / 引号不配平。
  ///
  /// 为什么**不在这里补齐**：补齐会产出语义残缺的摘要（钱保住了、信息丢了）。
  /// 完整性判断交给插件那次显式的"判断 + 修 JSON"小调用，并由它如实标注
  /// （用户 2026-10-05 定案）。
  static bool _looksTruncated(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) return false;
    final String last = text[text.length - 1];
    if (last != '}' && last != ']') return true;
    int braces = 0;
    int brackets = 0;
    bool inString = false;
    bool escaped = false;
    for (final int unit in text.codeUnits) {
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (unit == 0x5C /* \ */) {
          escaped = true;
        } else if (unit == 0x22 /* " */) {
          inString = false;
        }
        continue;
      }
      if (unit == 0x22) {
        inString = true;
      } else if (unit == 0x7B /* { */) {
        braces++;
      } else if (unit == 0x7D /* } */) {
        braces--;
      } else if (unit == 0x5B /* [ */) {
        brackets++;
      } else if (unit == 0x5D /* ] */) {
        brackets--;
      }
    }
    return braces != 0 || brackets != 0 || inString;
  }

  /// 正文预览（**首 200 + 末 100 字**）：够定位"夹了解释 / 截断在哪儿"，
  /// 又不至于把整段模型输出灌进日志。
  static String _rawPreview(String raw) {
    final String text = raw.trim();
    const int head = 200;
    const int tail = 100;
    if (text.length <= head + tail) return text;
    return '${text.substring(0, head)}……[省略 ${text.length - head - tail} 字]……'
        '${text.substring(text.length - tail)}';
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
