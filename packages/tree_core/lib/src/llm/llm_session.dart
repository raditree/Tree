import 'dart:async';
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

/// 「LLM 处理」**接管钩子**（中转站点位 `system.relay.llm.handle`）。
///
/// 返回非 null = 这一跳交给插件：会话消费这条流而**不调用** [LlmSession.transport]；
/// 返回 null = 不接管（走系统 LLM）。插件侧的错误/取消用 [LlmFailureEvent] 表达，
/// 与传输层同一个出口——超限重试、取消、报错的路径因此完全一致。
///
/// [isCancelled] 交给钩子实现：插件流可能是"长时间无事件"的，只有它能决定何时
/// 停流（并顺手向插件下发取消通知）；会话本身只会在收到事件后检查取消。
typedef LlmTurnHandler =
    Future<Stream<LlmStreamEvent>?> Function({
      required LlmRequest request,
      required String agentId,
      required String sessionId,
      required int turn,
      required bool Function() isCancelled,
    });

/// 「投入 LLM 前」**请求改写钩子**（中转站点位 `system.relay.llm.request`）。
///
/// 返回 null = 不改（走原请求）；返回新请求 = 用它的报文投给模型。
/// **只在未被接管时调用**（不投 LLM 就没有"投入前"可言）。
typedef LlmRequestRewriter =
    Future<LlmRequest?> Function({
      required LlmRequest request,
      required String agentId,
      required String sessionId,
      required int turn,
    });

/// 「这次工具调用的结果其实**已经落库**了吗」的**探针**（会话不认识存储层，只认这个签名——
/// 与 [LlmTurnHandler] / `LlmAgentEngine.toolResultRepair` 同一个注入范式）。
///
/// 用途：工具调用 `await` 长时间不返回时**对账** —— 存储里若已有这次调用（`toolCallId` 命中）
/// 的**真实结果**，就采用它让批收尾；返回 null = 存储里还没有 ⇒ **继续等显式取消**。
/// **绝不注入合成结果**：探针只能交出"已经存在的那一份"。
typedef ToolResultProbe =
    Future<String?> Function({
      required String agentId,
      required String sessionId,
      required String toolCallId,
    });

/// 工具调用看门狗的默认检查间隔（探针 + 留痕）：
/// 与登记表的 warning 阈值同量级，但更密一点——**先留痕、再等到阈值才 warning**，
/// 这样"卡住"这件事在会话出事之前就已经在 `core.log` 里。
const Duration defaultToolWatchdogInterval = Duration(seconds: 60);

/// 「一个**运行中的 LLM 请求**」在登记表里的句柄（见 [LlmRequestRegistrar]）。
///
/// 为什么要它：传输层的重试**有界**（5 次退避），但**插件接管的流没有上限**——而会话
/// "只会在收到事件后检查取消"（见类文档），插件挂了 / 不返回时就是**零事件** ⇒
/// 既无日志、也无从取消。把它登记进**与工具同一张表**，"看得见 + 关得掉"就都有了。
abstract interface class LlmRequestGuard {
  /// 登记表里的句柄（UI / 日志用）。
  String get handle;

  /// 是否**已被显式关闭**（用户右栏 / 插件 / agent `tool_runs action=close`）。
  /// 实现口径：登记项已从表里消失（`close` 会移除它）⇒ 视为已关闭。
  bool get closed;

  /// 收尾（幂等）。
  void finish();
}

/// 把"运行中的 LLM 请求"登记进登记表（**可选注入**；null = 不登记，行为与从前完全一致）。
typedef LlmRequestRegistrar =
    LlmRequestGuard Function({
      required String agentId,
      required String sessionId,
      required String model,
      required int turn,
    });

/// **沉默多久**才把这次请求登记成"可关闭的运行"（默认 300 s，与全仓阈值同值）。
///
/// 口径刻意是"**连续多久没有事件**"而不是"总共跑了多久"：推理模型正常跑十分钟
/// 也不该被登记成异常；只有**零事件**才是"卡住"的证据。
const Duration defaultRequestSilenceTimeout = Duration(seconds: 300);

/// 沉默检查的轮询间隔（便宜：只比时间戳）。
const Duration _requestSilenceTick = Duration(seconds: 5);

/// 关闭检查的轮询间隔（比沉默检查更密：关闭要**尽快**生效）。
const Duration _requestClosePollInterval = Duration(seconds: 2);

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
///
/// **站点接入点（2026-10-01 点位化）**：本类不认识插件总线，只暴露两个可设钩子
/// （[llmHandler] / [llmRequestRewriter]），由核心在接线处注入——与 [compactContext]
/// 同一个范式。**红线**：所有钩子的 await 都在 SSE 消费循环**之外**；流内 await
/// 会阻塞读取、把传输层的活性看门狗（默认 30s）假触发成"心跳丢失"。
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
    this.thinkingTurn = false,
    this.resultGate,
    this.statusText,
    this.compactContext,
    this.llmHandler,
    this.llmRequestRewriter,
    this.toolResultProbe,
    this.toolWatchdogInterval = defaultToolWatchdogInterval,
    this.llmRequestRegistrar,
    this.requestSilenceTimeout = defaultRequestSilenceTimeout,
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

  /// **这个模型是思考模型**：在途拼出来的 assistant 消息必须带
  /// `reasoning_content` 键（没有思考正文时给空串）。
  ///
  /// 与 [LlmMessage.thinkingTurn] 同一件事，只是这里管的是"工具循环里现拼的那条"
  /// （历史那批由引擎翻译时打标）。少了它，模型某一跳**没产出思考**时下一跳请求就是
  /// "以 tool 结果收尾、前一条 tool_calls 没有 reasoning"⇒ 端点 400
  /// （真机现场 2026-10-03，见 docs/known-issues.md #4）。
  final bool thinkingTurn;

  /// 超长工具结果门控（Q1-②）；null = 不做门控（无工作空间的测试场景）。
  ///
  /// 门控只替换**送给模型的那一份**：`AgentToolEnd` 照旧带完整结果，前端卡片与
  /// 落库因此都还能看到原文。
  final ToolResultGate? resultGate;

  /// 每次工具结果前要拼上的"会话状态"（todo + 已选 Spec）；null = 不拼。
  ///
  /// 每次调用实时取：模型可能在工具循环中途改 todo 或挂 Spec，状态必须是当下的。
  final String Function()? statusText;

  /// 工具结果的**探针**（见 [ToolResultProbe]）：工具调用久不返回时用它**对账**——
  /// 存储里已有真实结果就采用它让批收尾。null = 不对账（只留痕、继续等显式取消）。
  final ToolResultProbe? toolResultProbe;

  /// 工具调用看门狗的检查间隔（测试可注入更短的值）。
  final Duration toolWatchdogInterval;

  /// 「运行中的 LLM 请求」的登记落点（见 [LlmRequestRegistrar]）；null = 不登记。
  ///
  /// 登记口径：**连续 [requestSilenceTimeout] 无任何事件**才登记（正常长生成不登记、
  /// 不 warning）；登记后被显式关闭 ⇒ 这一跳立刻以取消收尾，并掐掉底层订阅。
  final LlmRequestRegistrar? llmRequestRegistrar;

  /// 连续多久无事件就把请求登记成可关闭的运行（测试可注入更短的值）。
  final Duration requestSilenceTimeout;

  /// 工具循环内压缩钩子（Q1-③）；由引擎接线到会话层的 CompactionService。
  ///
  /// 返回**重建后的基础上下文**（摘要 + 未压缩历史）：压缩改的是存储里的水位线
  /// 与摘要，在途的基础上下文不重新装配就等于没压。null = 没压缩/不需要重建。
  /// [force] 为真表示端点已经报上下文超限，此时必须压（本地估算可能偏小）。
  final Future<List<LlmMessage>?> Function({required bool force})?
  compactContext;

  /// 「LLM 处理」接管钩子（中转站点位 `system.relay.llm.handle`）；null = 未接线。
  final LlmTurnHandler? llmHandler;

  /// 「投入 LLM 前」请求改写钩子（中转站点位 `system.relay.llm.request`）；null = 未接线。
  final LlmRequestRewriter? llmRequestRewriter;

  /// 可读日志（上下文裁剪、工具异常等）。
  final void Function(String message)? log;

  /// 真实 usage 里夹带"本次请求上下文字符数"的内部键（见 [run]）。
  ///
  /// 用下划线前缀标明它是**内部字段**：引擎读完即剥掉，不会流到前端帧或落库。
  static const String contextCharsKey = '_context_chars';

  /// usage 里夹带"**本次调用**读数"（逐调用口径）的内部键（见 [run]）。
  ///
  /// 为什么不直接在既有 usage map 上加**公开**键：那份 map 是**已入帧、已落库**的
  /// 契约（`messages.jsonl` 的 `usage` 字段），加键就改变了行形状。逐调用账目改由
  /// 本键承载（`{prompt_tokens, cached_tokens?, completion_tokens, estimated,
  /// duration_ms}`）：引擎读完即剥掉（`LlmAgentEngine._publicUsage`）、落进
  /// `<会话目录>/usage.jsonl`（见 `store/usage_log.dart`）⇒ 对外契约逐字不变。
  static const String callUsageKey = '_call';

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
      LlmRequest request = LlmRequest(
        model: model,
        messages: List<LlmMessage>.unmodifiable(current()),
        tools: toolSpecs,
        maxOutputTokens: maxOutputTokens,
        reasoningEffort: reasoningEffort,
        temperature: temperature,
      );
      // 中转站点位「LLM 处理」：插件可以**整体接管**这一跳（无订阅者 / 未回填 ⇒
      // 走系统 LLM）。请求已经是最终形态（含本轮工具轨迹），插件回什么就消费什么。
      Stream<LlmStreamEvent>? pluginStream;
      final LlmTurnHandler? handler = llmHandler;
      if (handler != null) {
        try {
          pluginStream = await handler(
            request: request,
            agentId: agentId,
            sessionId: sessionId,
            turn: turn,
            isCancelled: isCancelled,
          );
        } catch (error) {
          // 接管点自身异常绝不打断生成：如实记日志，走系统 LLM（fail-open）
          log?.call('LLM 处理接管点异常（已回退系统 LLM）：$error');
          pluginStream = null;
        }
      }
      if (pluginStream == null) {
        // 中转站点位「投入 LLM 前」：**只在未被接管时**才谈得上"投入前"。
        final LlmRequestRewriter? rewriter = llmRequestRewriter;
        if (rewriter != null) {
          try {
            final LlmRequest? rewritten = await rewriter(
              request: request,
              agentId: agentId,
              sessionId: sessionId,
              turn: turn,
            );
            if (rewritten != null) request = rewritten;
          } catch (error) {
            log?.call('投入 LLM 前改写点异常（已放行原请求）：$error');
          }
        }
      }
      final SplayTreeMap<int, _ToolCallDraft> drafts =
          SplayTreeMap<int, _ToolCallDraft>();
      final StringBuffer text = StringBuffer();
      LlmUsage? turnUsage;
      String finishReason = '';
      bool failed = false;
      bool cancelled = false;
      bool overflow = false;
      String failure = '';

      // 这一跳的耗时（逐调用账目用它）：从发出请求到收流结束。
      final Stopwatch hopClock = Stopwatch()..start();
      // 生命周期留痕（C′）：请求**已发出**这件事必须有日志——今天查一次"会话失声"
      // 花了两轮，就是因为"请求发出去了、然后什么都没有"在日志里完全不可见。
      log?.call(
        '请求已发出：turn=$turn model=$model 上下文消息=${request.messages.length}'
        ' 工具=${toolSpecs.length}${pluginStream != null ? '（插件接管）' : ''}',
      );
      final Stream<LlmStreamEvent> events = _watchRequest(
        pluginStream ?? transport.stream(request, isCancelled: isCancelled),
        turn: turn,
        agentId: agentId,
        sessionId: sessionId,
      );
      bool firstEventLogged = false;
      await for (final LlmStreamEvent event in events) {
        if (!firstEventLogged) {
          firstEventLogged = true;
          log?.call('首个事件（等待 ${hopClock.elapsedMilliseconds}ms）：${event.runtimeType}');
        }
        if (event is LlmTextDelta) {
          text.write(event.text);
          yield AgentText(event.text);
        } else if (event is LlmThinkingDelta) {
          turnReasoning.write(event.text);
          yield AgentThinking(event.text);
        } else if (event is LlmToolCallDelta) {
          drafts.putIfAbsent(event.index, _ToolCallDraft.new).accept(event);
        } else if (event is LlmRetryNotice) {
          // 重试进度是**说给用户听的**（不是对话内容，也不属于模型输出）：
          // 日志留痕 + 交给上层落一条 llm_hidden 的消息；不打断这一轮的继续重试。
          log?.call(event.message);
          yield AgentNotice(event.message);
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
      hopClock.stop();

      final LlmUsage? endpointUsage = turnUsage != null && !turnUsage.isEmpty
          ? turnUsage
          : null;
      if (endpointUsage != null) {
        lastPromptTokens = endpointUsage.promptTokens;
        completionTokens += endpointUsage.completionTokens;
        cachedTokens = endpointUsage.cachedTokens;
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
        // 逐调用账目（**内部键**，引擎读完剥掉；见 [callUsageKey]）：这一跳用
        // **本次调用的真值**，而不是上面那份"全轮累计"的前端口径。
        usage[callUsageKey] = _callUsage(
          promptTokens: endpointUsage.promptTokens,
          cachedTokens: endpointUsage.cachedTokens,
          completionTokens: endpointUsage.completionTokens,
          estimated: false,
          durationMs: hopClock.elapsedMilliseconds,
          pluginHandled: pluginStream != null,
        );
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
      if (endpointUsage == null) {
        // 端点这一跳没给 usage：本地估算兜底，并显式标注 estimated。
        //
        // **每一跳都发**（不再像旧实现那样嵌在 `calls.isEmpty` 里、还要看"整轮有没有
        // 见过端点 usage"）：工具循环里"带工具调用 + 端点不回 usage"的跳以前一条账
        // 都没有，而它恰恰是最常见的形态——"每次 LLM 调用都有账"必须每跳一条。
        final int estimatedPrompt = request.estimatedPromptTokens(
          scale: tokenScale,
        );
        // completion 要把**这一跳生成的工具调用参数**算进去：工具跳通常一个字正文
        // 都没有（scenario：模型直接给 tool_calls），只看正文会得出 0——那不是"没有
        // 用量"，而是"用量都在 tool_calls 里"。
        final int estimatedCompletion =
            estimateTokens(text.toString(), scale: tokenScale) +
            calls.fold<int>(
              0,
              (int sum, LlmToolCall call) =>
                  sum +
                  estimateTokens('${call.name}${call.arguments}', scale: tokenScale),
            );
        yield AgentUsage(
          _usage(
            promptTokens: estimatedPrompt,
            // 与"全轮累计"的前端契约一致（端点分支也是累计口径）：这一跳没真值，
            // 就把本跳的估算**加到累计上**，而不是把累计清零成"本跳"。
            // 注意 `completionTokens` 这个累加器只吃**端点真值**（既有语义不动）：
            // 估算不进累计，否则一条估算会把后面每一跳的公开读数都带偏。
            completionTokens: completionTokens + estimatedCompletion,
            estimated: true,
            trimmed: trimmed,
          )..[callUsageKey] = _callUsage(
            promptTokens: estimatedPrompt,
            completionTokens: estimatedCompletion,
            estimated: true,
            durationMs: hopClock.elapsedMilliseconds,
            pluginHandled: pluginStream != null,
          ),
        );
      }
      if (calls.isEmpty) {
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
          // 这一跳**没有**思考正文时也必须给键（空串）——端点只查键在不在，
          // 而"模型这一跳没思考"真会发生（真机现场）。
          thinkingTurn: thinkingTurn,
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
          // 模型原始参数串随事件带出：落库后历史回灌要逐字复用它（缓存前缀）
          rawArguments: call.arguments,
        );
        ToolOutcome outcome;
        try {
          outcome = await _runToolWithWatchdog(
            call: call,
            toolId: toolId,
            arguments: arguments,
            agentId: agentId,
            sessionId: sessionId,
            isCancelled: isCancelled,
          );
        } catch (error) {
          outcome = ToolOutcome('工具执行异常：$error', isError: true);
        }
        // 状态前缀与门控都属于"送模型那一份"：先算出来，再随事件一起交出去
        // （落库要存的就是这一份——它同时是**下一轮重建历史时的唯一权威**，
        // 逐字复现才有可能命中端点前缀缓存）。
        final String status = statusText?.call() ?? '';
        final String forModel = await _gateResult(call.name, outcome.content);
        final String modelContent = status.isEmpty ? forModel : '$status$forModel';
        // UI 与落库的"完整结果"口径不变（AgentToolEnd.result）；送模型的那一份过门控
        yield AgentToolEnd(
          id: toolId,
          name: call.name,
          result: outcome.content,
          modelContent: modelContent,
        );
        inFlight.add(
          LlmMessage.toolResult(
            // 状态只进模型上下文；UI 的工具卡片仍显示原始结果（AgentToolEnd）
            content: modelContent,
            toolCallId: call.id,
          ),
        );
      }
    }
  }

  /// 把"这一跳 LLM 请求"包一层**可关闭的活性看护**（用户 2026-10-03：「沉默就登记、关闭即取消」）。
  ///
  /// 为什么必须**主动轮询**：传输层的重试有界（5 次退避 + 30s 心跳判死），但**插件接管的流
  /// 没有上限**，而会话"只会在收到事件后检查取消"（见类文档）⇒ 插件挂了 / 不返回时是**零事件**，
  /// 于是既没有日志、也无从取消（凌川那份现场）。这里补两件事，都不改既有语义：
  ///
  /// 1. **沉默登记**：连续 [requestSilenceTimeout] **无任何事件** ⇒ 把这次请求登记进登记表
  ///    （`tool: 'llm.request'`）⇒ 右栏「正在执行的 tool」/ `query_status.stuck_tools` /
  ///    广播站都能看见它。**正常的长生成不会被登记**（事件一直在流 ⇒ 永不登记、永不 warning）；
  /// 2. **关闭穿透**：登记后被**显式关闭**（用户右栏 / 插件 `tool.close` / agent
  ///    `tool_runs action=close`，同一实现）⇒ 立刻以 [LlmFailureEvent]（`cancelled: true`）
  ///    结束这一跳，并 `cancel()` 底层订阅（HTTP/SSH 连接随之释放、插件侧据此收到取消通知）。
  ///
  /// 未接线（[llmRequestRegistrar] 为 null）⇒ **原样返回**，行为与从前完全一致。
  Stream<LlmStreamEvent> _watchRequest(
    Stream<LlmStreamEvent> source, {
    required int turn,
    required String agentId,
    required String sessionId,
  }) {
    final LlmRequestRegistrar? registrar = llmRequestRegistrar;
    if (registrar == null) return source;
    // 轮询间隔**由沉默阈值派生**（带上限）：生产仍是 5s / 2s；测试注入很短的阈值时
    // 自动跟着变短，不必再暴露第二个"测试专用"开关。
    final int quarter = requestSilenceTimeout.inMilliseconds ~/ 4;
    final Duration tickEvery = Duration(
      milliseconds: quarter.clamp(10, _requestSilenceTick.inMilliseconds),
    );
    final Duration pollEvery = Duration(
      milliseconds: quarter.clamp(10, _requestClosePollInterval.inMilliseconds),
    );
    final StreamController<LlmStreamEvent> out =
        StreamController<LlmStreamEvent>();
    StreamSubscription<LlmStreamEvent>? sub;
    Timer? silenceTick;
    Timer? closeTick;
    LlmRequestGuard? guard;
    bool done = false;
    int lastEventMs = DateTime.now().millisecondsSinceEpoch;
    void settle() {
      silenceTick?.cancel();
      closeTick?.cancel();
      guard?.finish();
    }

    void register() {
      guard ??= registrar(
        agentId: agentId,
        sessionId: sessionId,
        model: model,
        turn: turn,
      );
      log?.call(
        'LLM 请求已沉默 ${requestSilenceTimeout.inSeconds} 秒（零事件）'
        '⇒ 登记为可关闭运行 ${guard!.handle}（右栏 / tool_runs 可见，关闭即取消这一跳）',
      );
      closeTick ??= Timer.periodic(pollEvery, (Timer _) {
        if (done) return;
        final LlmRequestGuard? current = guard;
        if (current == null || !current.closed) return;
        done = true;
        log?.call('LLM 请求 ${current.handle} 已被显式关闭 ⇒ 结束这一跳（取消）');
        if (!out.isClosed) {
          out.add(
            const LlmFailureEvent(
              '这一轮 LLM 请求已被显式关闭（用户 / 插件 / agent）',
              cancelled: true,
            ),
          );
        }
        unawaited(sub?.cancel());
        settle();
        if (!out.isClosed) unawaited(out.close());
      });
    }

    out.onListen = () {
      silenceTick = Timer.periodic(tickEvery, (Timer _) {
        if (done || guard != null) return;
        final int now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastEventMs >= requestSilenceTimeout.inMilliseconds) {
          register();
        }
      });
      sub = source.listen(
        (LlmStreamEvent event) {
          if (done) return;
          lastEventMs = DateTime.now().millisecondsSinceEpoch;
          if (!out.isClosed) out.add(event);
        },
        onError: (Object error, StackTrace stack) {
          if (done || out.isClosed) return;
          out.addError(error, stack);
        },
        onDone: () {
          if (done) return;
          done = true;
          settle();
          if (!out.isClosed) unawaited(out.close());
        },
        cancelOnError: false,
      );
    };
    out.onCancel = () async {
      done = true;
      settle();
      await sub?.cancel();
    };
    return out.stream;
  }

  /// 执行一次工具调用，带**看门狗**（用户 2026-10-03：「批收敛兜底」那一条）。
  ///
  /// 为什么需要：工具**没有静态上限**（本地活性 = 进程存活，SSH 侧 = 心跳），一条不返回的
  /// 调用会让整个批永不结束；而批中途进来的消息一律**推迟到批结果之后**（这是**保留**的
  /// 语义，不切开批、不让消息插队）⇒ 会话就此"消息只能进不能出"，且此前**一行日志都没有**。
  ///
  /// 看门狗只做两件事，**都不改语义**：
  /// 1. **留痕**：每 [toolWatchdogInterval] 记一行"已等待 N 秒"（连着叫它可见、可诊断）；
  /// 2. **对账**：问一次 [toolResultProbe] —— 存储里若已有这次调用（`toolCallId` 命中）的
  ///    **真实结果**，就采用它让批收尾（**绝不注入合成结果**）；探针为 null / 返回 null
  ///    ⇒ **继续等**，直到工具自己返回、或被**显式取消**（用户右栏 / 插件 `tool.close` /
  ///    agent `tool_runs action=close` —— 关闭会让在途调用收敛，本 await 随之正常返回）。
  Future<ToolOutcome> _runToolWithWatchdog({
    required LlmToolCall call,
    required String toolId,
    required Map<String, dynamic> arguments,
    required String agentId,
    required String sessionId,
    required bool Function() isCancelled,
  }) async {
    final Future<ToolOutcome> pending = toolRunner.run(
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
    // 对账命中的那一份（真实结果）；非 null 即让竞速收尾。
    String? reconciled;
    final Completer<void> reconciledDone = Completer<void>();
    int waitedSeconds = 0;
    final Duration interval = toolWatchdogInterval;
    final Timer timer = Timer.periodic(interval, (Timer _) {
      waitedSeconds += interval.inSeconds;
      final String waited = waitedSeconds <= 0
          ? interval.inMilliseconds.toString()
          : waitedSeconds.toString();
      final ToolResultProbe? probe = toolResultProbe;
      if (probe == null) {
        log?.call(
          '工具 ${call.name} 已等待 $waited 秒仍未返回'
          '（没有对账探针；可由 tool_runs / 右栏查看并显式关闭）',
        );
        return;
      }
      unawaited(() async {
        try {
          final String? stored = await probe(
            agentId: agentId,
            sessionId: sessionId,
            toolCallId: call.id,
          );
          if (stored == null) {
            log?.call(
              '工具 ${call.name} 已等待 $waited 秒仍未返回'
              '（存储里还没有它的结果 ⇒ 继续等显式取消）',
            );
            return;
          }
          log?.call(
            '工具 ${call.name} 已等待 $waited 秒仍未返回，'
            '但存储里已有它的结果 ⇒ 对账采用（真实结果，批收尾）',
          );
          reconciled = stored;
          if (!reconciledDone.isCompleted) reconciledDone.complete();
        } catch (error) {
          log?.call('工具结果对账失败（忽略，继续等）：$error');
        }
      }());
    });
    try {
      return await Future.any(<Future<ToolOutcome>>[
        pending,
        reconciledDone.future.then(
          (_) => ToolOutcome(reconciled ?? '', isError: false),
        ),
      ]);
    } finally {
      timer.cancel();
      if (!reconciledDone.isCompleted) reconciledDone.complete();
      // 工具最终返回时（多半是被显式关闭之后）结果照旧走正常路径；
      // 这里兜住它的异常，避免变成无人处理的错误。
      unawaited(pending.then<void>((ToolOutcome _) {}, onError: (Object _) {}));
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

  /// **逐调用**读数的内部载体（见 [callUsageKey]）：只用来落 `usage.jsonl`。
  ///
  /// 口径与 [_usage]（前端进度条口径）刻意不同：这里是"这一次调用花了多少"，
  /// 不累计、不带 `max_tokens`（那是模型属性不是本次用量）。
  /// [cachedTokens] 为 0 或缺省 ⇒ **不写键**（端点没给这个字段，绝不编造 0）。
  /// [pluginHandled] = 这一跳是被插件**整体接管**的（`llm.handle`）：引擎据此把
  /// 账目归到 `source=plugin`，而不是 `turn`。**只有会话知道这件事**（接管是它这
  /// 一层发生的），所以标记必须由这里随读数一起交出去。
  Map<String, dynamic> _callUsage({
    required int promptTokens,
    required int completionTokens,
    required bool estimated,
    required int durationMs,
    int? cachedTokens,
    bool pluginHandled = false,
  }) => <String, dynamic>{
    'prompt_tokens': promptTokens,
    if (cachedTokens != null && cachedTokens > 0) 'cached_tokens': cachedTokens,
    'completion_tokens': completionTokens,
    'estimated': estimated,
    'duration_ms': durationMs,
    if (pluginHandled) 'plugin': true,
  };

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

  /// 把上下文裁到预算内（**预算硬裁**；实现在 [fitContextToBudget]）。
  List<LlmMessage> _fitContext(
    List<LlmMessage> messages, {
    required void Function(int dropped) onTrimmed,
  }) => fitContextToBudget(
    messages,
    maxSeqlen: maxSeqlen,
    maxOutputTokens: maxOutputTokens,
    tokenScale: tokenScale,
    onTrimmed: onTrimmed,
  );
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

/// 把上下文裁到预算内（**预算硬裁**）。
///
/// 预算 = `maxSeqlen − 期望输出 − 512` 余量。裁剪**只在 user 消息边界**进行，
/// 因此绝不会把 assistant 的 tool_calls 与其 tool 结果拆散（那会让端点直接报 400）。
/// system 与最后一轮永不裁剪；找不到下一个 user 边界就停手，宁可让端点去报超长。
///
/// **为什么是顶层函数而不是 `LlmSession` 的私有方法**：引擎拼"压缩可复用前缀"
/// （`LlmAgentEngine.wireRequestFor`）时必须过**同一份**修剪——只有"引擎会给的那份"
/// 与"真会发出去的那份"逐字一致，压缩插件的 `llm.call` 才可能命中端点前缀缓存、
/// 也才不会把已经被裁掉的内容再喂给总结模型。
List<LlmMessage> fitContextToBudget(
  List<LlmMessage> messages, {
  required int maxSeqlen,
  required int? maxOutputTokens,
  required double tokenScale,
  void Function(int dropped)? onTrimmed,
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
    if (boundary < 0) break;
    for (int i = head; i < boundary; i++) {
      total -= result[i].estimatedTokens(scale: tokenScale);
    }
    dropped += boundary - head;
    result.removeRange(head, boundary);
  }
  if (dropped > 0) onTrimmed?.call(dropped);
  return result;
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
