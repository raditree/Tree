import 'dart:convert';

import 'package:tree_local_exec/tree_local_exec.dart';

import '../agent/agent_engine.dart';
import '../agent/attachment_prompt.dart';
import '../settings/core_settings.dart';
import '../store/usage_log.dart';
import '../tool/tool_runner.dart';
import '../tool/workspace_tool_runner.dart';
import 'llm_session.dart';
import 'llm_transport.dart';
import 'llm_types.dart';
import 'vision_files.dart';

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

/// 「系统提示词构造过程」的中转点钩子（中转站点位 `system.relay.prompt.system`）。
///
/// [defaultPrompt] = 内置拼装结果（`workspace_prompt.systemPromptWithWorkspace`）。
/// 返回 null = 用默认；返回字符串 = **整体替换**（空串 = 明确要求不带系统提示词）；
/// 抛异常 = 用默认（fail-open）。
///
/// 为什么在这里拦而不是改 `systemPromptWithWorkspace`：那是**同步**函数，改成
/// `Future` 会牵连同步的 token 估算（`CompactionService.estimateContextTokens`）；
/// 而 `_buildMessages` 本来就是异步的，且"每轮生成"与"压缩后重建"两条路径都经过它。
typedef SystemPromptRelayHook =
    Future<String?> Function({
      required AgentRunContext context,
      required String defaultPrompt,
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
    this.visionResolver,
    this.awaitReady,
    this.usageLog,
    this.log,
  });

  /// 模型配置解析器。
  final ModelResolver resolveModel;

  /// 工具执行器（M4 接入真实实现）。
  final ToolRunner toolRunner;

  /// 传输层工厂；为空时用 [HttpSseTransport] 并按 (base_url, api_key) 缓存。
  final TransportFactory? transportFactory;

  /// 图像附件的 `file_id` 解析器（`if_vision` 的**唯一**实现入口）。
  ///
  /// 为空时永不外发图片字节：即便模型配了 `if_vision=true`，请求里也只有附件的
  /// 路径文本（安全默认——没接线就不上传）。生产接线见 `tree_core_cli`。
  final VisionFileResolver? visionResolver;

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

  /// **「LLM 处理」接管钩子**（中转站点位 `system.relay.llm.handle`）；null = 未接线。
  ///
  /// 与 [toolTurnCompactor] 同范式：可写字段，由接线方（`CoreServer._wirePluginStations`）
  /// 在拿到 PluginBus 之后赋值——引擎与 [LlmSession] 都不认识插件总线。
  LlmTurnHandler? llmTurnHandler;

  /// **「投入 LLM 前」请求改写钩子**（中转站点位 `system.relay.llm.request`）。
  LlmRequestRewriter? llmRequestRewriter;

  /// **「系统提示词构造过程」钩子**（中转站点位 `system.relay.prompt.system`）。
  SystemPromptRelayHook? systemPromptRelay;

  /// 外设就绪闸门（可选）：**每轮生成前**在这里有界地等一下 MCP/插件预热。
  ///
  /// 为什么要它：为了让界面秒开，核心进程把 `mcp.refresh()` / `plugins.start()`
  /// 搬出了握手路径、改成握手之后并行预热（见 tree_core_cli 与
  /// server/boot_warmup.dart）。但**工具表**是从插件/MCP 现取的
  /// （`toolRunner.specsFor`），若某一轮在预热完成前就开始，那一轮就会**悄悄**
  /// 少掉这些工具。这里等一手即可保住旧行为：正常预热在百毫秒级完成 ⇒ 等待几乎
  /// 为零；外设真慢 ⇒ 闸门自带预算（CLI 传的是预热 future 本身），不会拖住对话。
  final Future<void> Function()? awaitReady;

  /// 可读日志。
  final void Function(String message)? log;

  /// **逐调用用量账本**（`<会话目录>/usage.jsonl`）；null = 不落账。
  ///
  /// 为什么落在这里而不是会话层：引擎是**唯一**同时知道"这是这一轮的第几跳、
  /// 耗时多少、端点给没给 usage"的地方（工具循环在 [LlmSession] 里），而会话层
  /// 只收到剥好内部键的公开 usage（那是"全轮累计"的前端口径，做不了逐调用账）。
  /// 写失败只落在 [UsageLog.lastError]，绝不打断生成。
  ///
  /// 接线一行：`LlmAgentEngine(..., usageLog: UsageLog(paths))`。
  final UsageLog? usageLog;

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

    /// 「这个模型是思考模型吗」：**模型级**配置（agent 覆盖只决定"要不要回传思考
    /// 正文"）。思考模型的端点在带 tools 的请求里要求每条 assistant 带
    /// `reasoning_content` 键——没有正文时给**空串**（实测见
    /// [LlmMessage.thinkingTurn]）。
    final bool thinkingModel = resolved?.thinking ?? config.thinking;

    // 外设就绪闸门：把「本轮工具表是否已包含插件/MCP 工具」的时序问题收在这里
    // （见 [awaitReady] 的文档）。闸门自带预算，且任何异常都不该拦住这一轮。
    final Future<void> Function()? ready = awaitReady;
    if (ready != null) {
      try {
        await ready();
      } catch (error) {
        log?.call('外设就绪闸门异常（已忽略，照常生成）：$error');
      }
    }

    // 门控实例与一次 run 同生命周期：历史翻译与工具循环共用它，重定向序号才连续。
    final ToolResultGate gate = ToolResultGate(
      agentId: context.agentId,
      tokenScale: config.tokenScale,
      writer: resultRedirectWriter ?? _workspaceWriter(),
      log: log,
    );
    final List<LlmMessage> messages = await _buildMessages(
      context,
      gate,
      config: config,
      // 视觉链路只在模型配了 `if_vision` 时启用；关着的时候连"要不要上传"都不
      // 判断，请求体与改动前**逐字一致**（见 llm_types.dart 的 LlmMessage.toWire）
      vision: config.ifVision ? visionResolver : null,
      passBackReasoning: config.thinking,
      // 「思考模型」是**模型自己的属性**（不受 agent 级「回传思考」覆盖影响）：
      // 端点要的是"这条 assistant 带 reasoning_content 键"，与"要不要重发思考正文"
      // 是两件事（实测表见 LlmMessage.thinkingTurn）。
      thinkingTurn: thinkingModel,
    );
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
      thinkingTurn: thinkingModel,
      resultGate: gate,
      statusText: sessionStatusText == null
          ? null
          : () => sessionStatusText!(context.agentId, context.sessionId),
      compactContext: ({required bool force}) => _rebuiltContext(
        context,
        gate,
        config: config,
        vision: config.ifVision ? visionResolver : null,
        force: force,
        // 重建上下文必须与首轮同口径：否则压一次之后思考就"消失"了
        passBackReasoning: config.thinking,
        thinkingTurn: thinkingModel,
      ),
      llmHandler: llmTurnHandler,
      llmRequestRewriter: llmRequestRewriter,
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
        _recordCallUsage(context, config, event.usage);
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
    // 视觉上传器持有自己的连接池，同样要关（幂等）
    await visionResolver?.close();
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
    required CoreModelConfig config,
    VisionFileResolver? vision,
    bool passBackReasoning = false,
    bool thinkingTurn = false,
  }) async {
    final ToolTurnCompactor? compact = toolTurnCompactor;
    if (compact == null) return null;
    final AgentRunContext? refreshed = await compact(
      context.agentId,
      context.sessionId,
      force: force,
    );
    if (refreshed == null) return null;
    return _buildMessages(
      refreshed,
      gate,
      config: config,
      vision: vision,
      passBackReasoning: passBackReasoning,
      thinkingTurn: thinkingTurn,
    );
  }

  /// 把这一跳的**逐调用读数**落进 `usage.jsonl`（未接线时什么都不做）。
  ///
  /// 读数取自 [LlmSession.callUsageKey]（内部键，见那里的说明）；落完这一笔它就会被
  /// [_publicUsage] 剥掉，所以前端帧与 `messages.jsonl` 的 `usage` **逐字不变**。
  ///
  /// 来源（`source`）在这一层定：会话在读数里标了"这一跳被插件整体接管"
  /// （`llm.handle`）⇒ `plugin`，否则是对话本身的一跳 ⇒ `turn`。压缩 / `llm.call`
  /// 那两类各有自己的落账口（`LlmSummarizer` / `LlmJsonCaller` 的用量回调）。
  void _recordCallUsage(
    AgentRunContext context,
    CoreModelConfig config,
    Map<String, dynamic> usage,
  ) {
    final UsageLog? sink = usageLog;
    if (sink == null) return;
    final Object? raw = usage[LlmSession.callUsageKey];
    final bool pluginHandled = raw is Map && raw['plugin'] == true;
    final UsageCall? call = UsageCall.tryFromCallUsage(
      raw,
      source: pluginHandled ? UsageSource.plugin : UsageSource.turn,
      // 落的是**实际请求**的模型 id（成员级覆盖之后解析出来的那一个）
      model: config.modelId,
    );
    if (call == null) return;
    sink.record(context.agentId, context.sessionId, call);
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

  /// **内部键**集合：夹带"学习用的上下文字符数"与"逐调用读数"，两类都不许上行。
  static const Set<String> _internalUsageKeys = <String>{
    LlmSession.contextCharsKey,
    LlmSession.callUsageKey,
  };

  /// 剥掉内部字段，保证上行 usage 与既有前端契约**逐字**一致。
  ///
  /// 吃这一份的是：`msg_usage` / `msg_end` 帧与 `messages.jsonl` 的 `usage` 字段
  /// （`endSegment(usage: …)` 落的就是它）——所以"逐调用用量"绝不能走公开键。
  static Map<String, dynamic> _publicUsage(Map<String, dynamic> usage) {
    if (!_internalUsageKeys.any((String key) => usage.containsKey(key))) {
      return usage;
    }
    return Map<String, dynamic>.of(usage)
      ..removeWhere(
        (String key, Object? value) => _internalUsageKeys.contains(key),
      );
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

  /// **系统提示词构造过程的中转点**（`system.relay.prompt.system`）。
  ///
  /// 无订阅者 / 未回填 / 异常 ⇒ 返回内置构造结果（fail-open，逐字与接线前一致）。
  /// 注意副作用：压缩阈值估算读的是**未改写**的提示词（`CompactionService` 直接调
  /// `systemPromptWithWorkspace`），插件改写后压缩口径会有偏差——这是刻意的取舍
  /// （要一致就得在 (agent, session) 上缓存改写结果，多一层状态）。
  Future<String> _relayedSystemPrompt(AgentRunContext context) async {
    final String builtin = context.systemPrompt;
    if (builtin.trim().isEmpty) return builtin;
    final SystemPromptRelayHook? relay = systemPromptRelay;
    if (relay == null) return builtin;
    try {
      final String? replaced = await relay(
        context: context,
        defaultPrompt: builtin,
      );
      // null = 不改动；空串 = 插件明确要求"不带系统提示词"（不是"没改"）
      return replaced ?? builtin;
    } catch (error) {
      log?.call('系统提示词中转点异常（已用内置构造结果）：$error');
      return builtin;
    }
  }

  /// 复制一条消息、只换正文（[LlmMessage] 是不可变的；刷新提示词槽位时用）。
  static LlmMessage _replacingContent(LlmMessage message, String content) =>
      LlmMessage(
        role: message.role,
        content: content,
        toolCalls: message.toolCalls,
        toolCallId: message.toolCallId,
        name: message.name,
        reasoningContent: message.reasoningContent,
        thinkingTurn: message.thinkingTurn,
        contentParts: message.contentParts,
      );

  /// **当前上下文的线形请求**（预先压缩态）——给压缩插件复用前缀。
  ///
  /// 为什么需要它：压缩插件要在自己的 `llm.call` 里吃**端点前缀缓存**，就必须交出
  /// **与对话同一条前缀**（逐字一致才有缓存单元可命中）。而这条前缀只有引擎拼得出来
  /// ——历史怎么翻译、工具卡怎么配对、思考要不要回灌、超长结果怎么门控，全是引擎口径。
  ///
  /// 口径与 [run] 即将发出的那一份一致，只有两处刻意不同：
  /// - **不做视觉上传**（`if_vision` 开着时图片块会缺，这部分前缀因此不命中缓存；
  ///   上传是有副作用的远端动作，不能因为"只是想拿前缀"就触发）；
  /// - `stream` 恒为 `false`（它是报文参数，与 messages 前缀无关）。
  ///
  /// 取不到（模型没配 / 没密钥 / 拼接异常）时返回 null：插件据此退回"自己渲染历史"
  /// 的模式（功能一样，只是没有缓存收益）。
  Future<Map<String, dynamic>?> wireRequestFor(AgentRunContext context) async {
    final CoreModelConfig? resolved = resolveModel(context.modelId);
    final CoreModelConfig? config = resolved?.withOverrides(
      agentOverrides?.call(context.agentId) ?? const <String, Object?>{},
    );
    if (config == null) return null;
    if (config.baseUrl.trim().isEmpty || config.apiKey.trim().isEmpty) {
      return null;
    }
    try {
      final ToolResultGate gate = ToolResultGate(
        agentId: context.agentId,
        tokenScale: config.tokenScale,
        writer: resultRedirectWriter ?? _workspaceWriter(),
        log: log,
      );
      final List<LlmMessage> built = await _buildMessages(
        context,
        gate,
        config: config,
        vision: null,
        passBackReasoning: config.thinking,
        // 与实发同一份前缀：少一个"必须带的键"就是整段不命中缓存
        thinkingTurn: resolved?.thinking ?? config.thinking,
      );
      // **预算硬裁也要过一遍**（与 `LlmSession.run` 同一份 `fitContextToBudget`）：
      // 只有"引擎会给的那份" = "真会发出去的那份"，压缩插件的前缀才与端点缓存单元
      // 逐字一致，也才不会把已经被裁掉的内容再喂给总结模型。
      final List<LlmMessage> messages = fitContextToBudget(
        built,
        maxSeqlen: config.effectiveMaxSeqlen,
        maxOutputTokens: config.maxOutputTokens > 0
            ? config.maxOutputTokens
            : null,
        tokenScale: config.tokenScale,
        onTrimmed: (int dropped) => log?.call(
          '压缩前缀按预算硬裁了 $dropped 条（与实发请求同口径）',
        ),
      );
      final LlmRequest request = LlmRequest(
        model: config.modelId,
        messages: messages,
        // 与 `LlmSession` 同一条转换（工具层 ToolSpec → 线形态 LlmToolSpec）：
        // 前缀要逐字对齐，声明少一个字段都会整段不命中缓存。
        tools: <LlmToolSpec>[
          for (final ToolSpec spec in toolRunner.specsFor(
            agentId: context.agentId,
            sessionId: context.sessionId,
          ))
            LlmToolSpec(
              name: spec.name,
              description: spec.description,
              parameters: spec.parameters,
            ),
        ],
        maxOutputTokens: config.maxOutputTokens > 0
            ? config.maxOutputTokens
            : null,
        reasoningEffort: config.reasoningEffort.trim().isEmpty
            ? null
            : config.reasoningEffort,
      );
      return request.toWire();
    } catch (error) {
      log?.call('拼"压缩可复用的前缀"失败（插件退回自渲染模式）：$error');
      return null;
    }
  }

  /// 把会话历史翻译成端点消息序列。
  ///
  /// **不变量（前缀缓存）**：这里拼出来的每一条历史消息，必须与"当初真正发给模型的
  /// 那一份"**逐字一致**。端点的前缀缓存只在字节完全相同的公共前缀上命中——少一个
  /// 空格（参数串被重新编码）、多一句状态前缀、换一个重定向文件名，缓存就从那条消息
  /// 起全部落空（真机表现：373k 上下文只命中 ~12k，正好是 system + 摘要）。
  /// 因此凡是"实发时才算得出来"的东西（模型原始参数串、状态前缀、门控后的结果），
  /// 都由落库那份记录原样带回来，而不是在这里重新推导。
  ///
  /// [gate] 只替换工具结果**送给模型的那一份**：历史里的超长结果同样要过门控
  /// （Q1-②：每次构造上下文都要过一遍，历史重载同样生效）；但**有落库的
  /// "送模型那一份"时优先用它**，门控只是老数据的回退路径。
  ///
  /// **不变量（工具批是原子的）**：一条 assistant 的 `tool_calls` 与它的**全部**
  /// tool 结果必须相邻成一块——中间不得插进任何 user / notice 消息。落在批中途的
  /// "有人说话"（hook 完成提示、用户插话）一律**推迟到这一批的结果之后**再发：就地发
  /// 会把批切成两半，后半批没有可挂的 `reasoning_content`，请求随即变成"以 tool 结果
  /// 收尾、前面那条 tool_calls 没有 reasoning"⇒ 思考模式端点 400（真机现场见
  /// `.self/plan/20261001-thinking-400-and-interrupt/recon-addendum.md`）。
  ///
  /// [passBackReasoning] = 模型配置里的 `thinking` 开关：开启时把历史思考挂回
  /// 对应的 assistant 消息（DeepSeek 的 `reasoning_content`，带 tools 时必须回传，
  /// 否则同会话后续请求持续 400）；关闭时维持原行为（思考不回灌）。
  Future<List<LlmMessage>> _buildMessages(
    AgentRunContext context,
    ToolResultGate gate, {
    required CoreModelConfig config,
    VisionFileResolver? vision,
    bool passBackReasoning = false,
    bool thinkingTurn = false,
  }) async {
    final List<LlmMessage> out = <LlmMessage>[];
    final List<LlmMessage> seeded = <LlmMessage>[
      for (final Map<String, dynamic> raw in context.compactedContext)
        if (LlmMessage.tryFromWire(raw) case final LlmMessage message) message,
    ];
    if (seeded.isNotEmpty) {
      // ① 中转站产出的整份上下文（点位化）：它是**基底**（摘要 / 必读文件 / todo
      //    段原样保留），但**系统提示词槽位由核心每轮刷新**——不然列表里那条永远
      //    是"压缩那一刻的快照"，`spec select` 挂上的规范全文、工作空间提示词、
      //    Spec 索引这些会话级内容在两次压缩之间就再也进不了上下文了。
      //
      //    规则（与 `docs/plugin-development.md` §5.3 的契约一致）：
      //    - 首条是 system ⇒ 覆盖它的正文（插件放的是槽位，不是最终值）；
      //    - 首条不是 system ⇒ 在最前插一条；
      //    - 最新提示词为空串（`prompt.system` 明确要求"不带系统提示词"）⇒ 删掉槽位，
      //      而不是把过期的那份留下。
      final String fresh = await _relayedSystemPrompt(context);
      final bool slotAtHead = seeded.first.role == LlmRole.system;
      if (fresh.trim().isNotEmpty) {
        if (slotAtHead) {
          if (seeded.first.content != fresh) {
            log?.call(
              '中转站上下文的系统提示词已刷新'
              '（${seeded.first.content.length} 字 → ${fresh.length} 字）',
            );
          }
          seeded[0] = _replacingContent(seeded.first, fresh);
        } else {
          seeded.insert(0, LlmMessage.system(fresh));
        }
      } else if (slotAtHead) {
        seeded.removeAt(0);
      }
      out.addAll(seeded);
    } else {
      // ② 内置路径：系统提示词 + 压缩摘要 + 跳过后缀的历史
      //    （也兜"中转站列表整份解析不出来"的极端情况：退化成纯提示词 + 历史）
      final String systemPrompt = await _relayedSystemPrompt(context);
      if (systemPrompt.trim().isNotEmpty) {
        out.add(LlmMessage.system(systemPrompt));
      }
      // 上下文压缩摘要（M7d-4）：紧跟系统提示词，替代已被总结的历史前缀
      if (context.contextSummary.trim().isNotEmpty) {
        out.add(LlmMessage.system(context.contextSummary));
      }
    }
    final List<CoreMessageRef> toolBatch = <CoreMessageRef>[];
    // 本轮的正文段（0~多条）：**延后到"轮末"再落地**——"推理挂哪条消息"取决于本轮
    // 有没有工具调用（见 flushRound），所以不能遇到正文就立刻发出去。
    final List<CoreMessageRef> pendingText = <CoreMessageRef>[];
    // 本轮的思考正文：挂到本轮的**那一条** assistant 消息上（有工具调用 → 带
    // tool_calls 的那条；没有 → 正文那条）。DeepSeek 思考模式的硬要求见 flushRound。
    final List<String> pendingReasoning = <String>[];
    // 落在工具批**中间**的"有人说话"（hook 提示 / 用户插话）：先攒着，等这一批的工具
    // 结果**全部**落地之后再按顺序发出去。
    //
    // 为什么必须推迟（真机 400 现场，2026-10-02 18:14，member 跑在远端 SSH 上）：
    // 一条 assistant 消息可以带多个工具调用，但它们的**结果是逐条落库**的——第 3 个
    // write 走同一条 SSH、比前两个晚 ~20s 才回来，期间 hook 的完成提示（notice）
    // 正好卡在第 2、3 条之间。旧实现就地把它发成 user 消息，这一批被切成两半：前半批
    // 带着本轮的 reasoning，**后半批没有**——而 reasoning_content 只能挂在"带
    // tool_calls 的那条"上，于是请求变成"以 tool 结果收尾、前面那条 tool_calls 没有
    // reasoning_content"，端点直接 400
    // `The reasoning_content in the thinking mode must be passed back to the API.`
    // （recon-addendum.md 记着这条现场）。结构上也如此：user 消息不能插在
    // assistant(tool_calls) 与它自己的 tool 结果之间。
    final List<CoreMessageRef> deferredInputs = <CoreMessageRef>[];

    /// 把一条"有人对模型说话"的记录发成 `user` 消息（用户消息 / hook 提示同一条路）。
    ///
    /// 批中途落进来的那些由 [flushRound] 在批**之后**调用它——同一条函数才能保证
    /// "就地发"与"推迟发"出去的字面完全一致（附件说明段与像素块两段口径都在这里）。
    Future<void> emitUser(CoreMessageRef ref) async {
      // 用户上传的附件：路径必须写进提示词（附件已由前端上传到工作空间），否则
      // 模型对"用户发了图/文件"这件事一无所知 —— 只有 UI 气泡上的一张卡片。
      // 附件说明段与压缩估算共用同一个纯函数，两处口径逐字一致。
      final String content = ref.isUser
          ? '${ref.content}${attachmentsPromptSuffix(ref.attachments)}'
          : ref.content;
      // 空内容跳过：**只有附件、没有正文**的消息不能算空——它带着附件路径，
      // 整条丢掉等于用户什么都没发（修复前的行为）。
      if (content.trim().isEmpty) return;
      // 图像附件的**像素**：`if_vision` 打开时先在端点上传拿到 file_id，再把
      // 引用作为内容块挂在同一条 user 消息上（模型才真的"看得见"图）。解析失败
      // 只是少一个块——正文里的路径说明段还在，模型仍知道去哪读。
      final List<LlmContentPart> parts = ref.isUser
          ? await _visionParts(vision, config, context.agentId, ref.attachments)
          : const <LlmContentPart>[];
      out.add(
        LlmMessage(role: LlmRole.user, content: content, contentParts: parts),
      );
    }

    /// 一轮 = (思考*) (正文?) (工具卡*)，把这一轮落地成端点消息。
    ///
    /// **推理挂哪一条：实测依据**（`.self/plan/20261001-thinking-400-and-interrupt/recon.md`）：
    /// - 带 tools 的请求**以 `tool` 结果收尾**时（= 工具循环的下一跳），前一条带
    ///   `tool_calls` 的 assistant **必须带 `reasoning_content`**，否则 400
    ///   （G1/G3 复现；G2/G4 带上就 200）；
    /// - 请求**以没有 reasoning 的 assistant 收尾**同样 400（D6）。
    /// 结论：有工具调用 → 推理挂"带 tool_calls 的那条"；没有 → 挂正文那条。
    /// 两条都挂是重复，两条都不挂就 400。
    Future<void> flushRound() async {
      final bool roundHasTools = toolBatch.isNotEmpty;
      // 思考**逐字保留、逐字相接**：工具循环那一跳发出去的就是"本跳 thinking 增量
      // 直接拼起来"的那一串。这里若 trim / 插分隔符，重建出来的 assistant 就与实发
      // 的不是同一串字节——端点前缀缓存从这条起整段落空（见 _buildMessages 顶部说明）。
      final String reasoning = pendingReasoning.join();
      // 本轮正文：实发时它是**与 tool_calls 同一条** assistant 的 content；
      // 重建时必须还原成同一条（拆成"正文一条 + tool_calls 一条"会让前缀错位）。
      final StringBuffer roundBody = StringBuffer();
      for (final CoreMessageRef ref in pendingText) {
        roundBody.write(ref.content);
      }
      pendingText.clear();
      if (roundHasTools) {
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
              // 参数串优先用**模型原文**（落库时存下来的那一份）：jsonEncode 的规范
              // 形态与原文常常不同（空格 / 转义），差一个字节就等于换了前缀。
              arguments: ref.toolArgumentsRaw.isNotEmpty
                  ? ref.toolArgumentsRaw
                  : jsonEncode(ref.toolArguments ?? const <String, dynamic>{}),
            ),
          );
          results.add(
            LlmMessage.toolResult(
              // 「送模型那一份」以落库的为准（会话状态前缀 + 超长门控都已定稿）；
              // 空串 = 老数据，当场补一次门控（上一轮中途中断时的占位同理）
              content: ref.toolResultForModel.isNotEmpty
                  ? ref.toolResultForModel
                  : await gate.apply(
                      name,
                      ref.toolResult.isEmpty
                          ? '(该工具调用未完成，没有结果)'
                          : ref.toolResult,
                    ),
              toolCallId: callId,
            ),
          );
        }
        out.add(
          LlmMessage(
            role: LlmRole.assistant,
            content: roundBody.toString(),
            toolCalls: calls,
            reasoningContent: reasoning,
            thinkingTurn: thinkingTurn,
          ),
        );
        out.addAll(results);
      } else {
        final String body = roundBody.toString();
        // 空正文跳过（只有附件、没有正文的消息在 asUser 分支里已带上了路径段）
        if (body.trim().isNotEmpty) {
          out.add(
            LlmMessage.assistant(
              body,
              reasoningContent: reasoning,
              thinkingTurn: thinkingTurn,
            ),
          );
        }
      }
      toolBatch.clear();
      // 推理只属于它所在的那一轮（已经挂出去了）
      pendingReasoning.clear();
      // 批（assistant + 它的**全部** tool 结果，相邻）已经落地，现在才轮到批中途
      // 插进来的那些话——顺序与它们落库的先后一致。
      while (deferredInputs.isNotEmpty) {
        await emitUser(deferredInputs.removeAt(0));
      }
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
      // `llm_hidden`（系统发言 / 重试进度）**不进请求**：它们是系统说给用户听的，
      // 喂给模型只会被当成"新的排查任务"（用户实测反馈）。落库与 UI 显示不受影响。
      if (ref.llmHidden) continue;
      // 推理内容：默认不回灌（思考过程不是对话上下文）；"回传思考"开启时攒起来，
      // 由 flushRound 挂到本轮的 assistant 消息上（DeepSeek 思考模式的硬要求）。
      if (ref.isThinking) {
        // 新的一拍思考 = 上一轮已经结束（本轮已有正文或工具卡时先落地）
        if (pendingText.isNotEmpty || toolBatch.isNotEmpty) await flushRound();
        if (passBackReasoning && ref.content.trim().isNotEmpty) {
          // 逐字保留（**不 trim**）：实发那一跳用的是端点原样回传的 thinking，
          // 这里动一个空白字符，重建前缀就与实发的对不上。
          pendingReasoning.add(ref.content);
        }
        continue;
      }
      // hook/系统提示（`kind == 'notice'`）按 **user** 发出，而不是 assistant：
      // 它既不是模型说的话，也不该装成模型说的话；而且实测（recon.md）表明带 tools
      // 的思考模式端点不允许请求**以"没有 reasoning_content 的 assistant 消息"收尾**，
      // 而这类提示恰恰总是被追加到历史末尾（`wake`）——之前正是它导致连续 400。
      // 第二批现场（recon-addendum.md）：它也可能落在**工具批中间**（批的结果是逐条
      // 落库的），那就推迟到批之后——就地发会把批切出一个没有 reasoning 的后半批。
      final bool asUser = ref.isUser || ref.isNotice;
      // 用户消息 / hook 提示之前先把上一轮的 assistant 段落落地（顺序不能变）；
      // 但**工具批还没走完时不能落地**：就地发出去会把这一批切成两半，后半批没有
      // 可挂的 reasoning（见 deferredInputs 的现场）。推迟到批的结果之后再说。
      if (asUser) {
        // 这一轮**还在飞**时的插话必须排在它之后。两种"在飞"都要拦：
        // - 已有工具结果：批不能被切开（否则后半批没有可挂的 reasoning）；
        // - **只有思考**（这一跳的 assistant 还没落地：工具卡 / 正文还在后面）：
        //   就地 `flushRound()` 会**什么也不发**却把 `pendingReasoning` 清空 ——
        //   那段 CoT 就此丢失，紧接着的工具卡批会以"没有 reasoning"的形态收尾
        //   ⇒ 端点 400。真机可达：插话落在**工具执行期间**（思考已落库、工具卡还没回来，
        //   远端 SSH 上的慢工具窗口尤其大）。
        if (toolBatch.isNotEmpty || pendingReasoning.isNotEmpty) {
          deferredInputs.add(ref);
          log?.call(
            '工具批中途落进一条${ref.isNotice ? 'hook 提示' : '用户消息'}'
            '（该批已有 ${toolBatch.length} 条工具结果'
            '${pendingReasoning.isNotEmpty ? '、本跳思考已落库' : ''}）：推迟到这一批的'
            '结果之后——批不能被切开，否则带 tool_calls 的 assistant 会缺 '
            'reasoning_content（思考模式端点会 400）',
          );
          continue;
        }
        await flushRound();
        await emitUser(ref);
        continue;
      }
      // 普通 assistant 正文段：并入本轮（工具卡之后又来正文 = 新的一轮）
      if (ref.content.trim().isEmpty) continue;
      if (toolBatch.isNotEmpty) await flushRound();
      pendingText.add(ref);
    }
    await flushRound();
    _noteTrailingAssistantWithoutReasoning(out);
    return out;
  }

  /// 请求以"**没有思考正文的 assistant**"收尾时留一条日志。
  ///
  /// 这不再是错误：端点只查 `reasoning_content` **键在不在**，空串照样 200
  /// （真端点实测见 [LlmMessage.thinkingTurn]）——引擎给思考模型的每条 assistant
  /// 都打了这个键。留日志是因为"模型这一跳没产出思考"是排查 400 与前缀缓存时
  /// 最值得知道的一件事。
  void _noteTrailingAssistantWithoutReasoning(List<LlmMessage> messages) {
    if (messages.length < 2) return;
    final LlmMessage last = messages.last;
    if (last.role != LlmRole.assistant) return;
    if (last.reasoningContent.isNotEmpty || !last.thinkingTurn) return;
    log?.call(
      '请求以没有思考正文的 assistant 收尾：已按实测带上 reasoning_content 空串'
      '（端点只查键在不在；省略整个键才会 400）。',
    );
  }

  /// 把该条用户消息里的**图像附件**逐个解析成端点的 file 内容块。
  ///
  /// [vision] 为空（`if_vision` 关闭或未接线）时**直接返回空**：这条链路对
  /// "没开视觉的模型"完全无感，连字节都不读。非图片附件（pdf/txt…）同样跳过：
  /// DeepSeek 的 file 内容块口径就是图像。
  Future<List<LlmContentPart>> _visionParts(
    VisionFileResolver? vision,
    CoreModelConfig config,
    String agentId,
    List<Map<String, dynamic>>? attachments,
  ) async {
    if (vision == null || attachments == null || attachments.isEmpty) {
      return const <LlmContentPart>[];
    }
    final List<LlmContentPart> parts = <LlmContentPart>[];
    for (final Map<String, dynamic> attachment in attachments) {
      if (!isVisionImageAttachment(attachment)) continue;
      final String? fileId = await vision.resolve(
        config: config,
        agentId: agentId,
        attachment: attachment,
      );
      if (fileId == null || fileId.isEmpty) continue;
      parts.add(LlmContentPart.file(fileId));
    }
    return parts;
  }
}
