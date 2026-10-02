/// 回复引擎产出的**会话级事件**（与 WS 帧一一对应，但仍是与传输无关的抽象）。
///
/// 会话服务（ConversationService）只认这些事件并把它们翻成 WS 帧：
/// - [AgentText] / [AgentThinking] → msg_start + msg_chunk…（kind = text / thinking）；
/// - [AgentToolStart] / [AgentToolEnd] → tool_start / tool_end 卡片；
/// - [AgentUsage] → msg_usage（工具循环中每轮都会推进）；
/// - [AgentDone] / [AgentError] → msg_end / error。
///
/// 把"引擎事件"与"WS 帧"分成两层，是为了让 LLM 会话可以脱离 WS 单测
/// （假传输喂事件即可），也让 M5 的成员编排复用同一套事件。
sealed class AgentEvent {
  const AgentEvent();
}

/// 正文增量。
final class AgentText extends AgentEvent {
  const AgentText(this.delta);

  final String delta;
}

/// 推理增量。
final class AgentThinking extends AgentEvent {
  const AgentThinking(this.delta);

  final String delta;
}

/// 工具调用开始（UI 先立卡片，再等结果）。
final class AgentToolStart extends AgentEvent {
  const AgentToolStart({
    required this.id,
    required this.name,
    required this.arguments,
    this.callId = '',
    this.rawArguments = '',
  });

  /// UI/落库用的消息 id（本地生成）。
  final String id;

  /// **端点给的** tool_call id：回灌 `role: tool` 消息时必须原样带回，
  /// 因此需要随消息一起持久化（`tool_call_id`）。
  final String callId;

  final String name;
  final Map<String, dynamic> arguments;

  /// **模型原始的参数串**（流式拼出来的那一份）。落库后历史回灌要逐字复用它，
  /// 否则 `jsonEncode(arguments)` 的规范化形态会与实发的不一致（见
  /// [CoreMessage.toolArgumentsRaw]）。空串 = 生产者没给（老路径/测试）。
  final String rawArguments;
}

/// 工具调用结束。
final class AgentToolEnd extends AgentEvent {
  const AgentToolEnd({
    required this.id,
    required this.name,
    required this.result,
    this.modelContent = '',
  });

  final String id;
  final String name;

  /// 完整结果（前端卡片与落库口径，永远是全文）。
  final String result;

  /// **送模型那一份**（会话状态前缀 + 超长门控之后）。落库后重建历史时原样取用，
  /// 空串 = 与 [result] 相同（生产者没给）。
  final String modelContent;
}

/// 用量推进（工具循环中每轮都会发一次）。
final class AgentUsage extends AgentEvent {
  const AgentUsage(this.usage);

  final Map<String, dynamic> usage;
}

/// 本轮失败（已在文案里给出可读原因）。
final class AgentError extends AgentEvent {
  const AgentError(this.message);

  final String message;
}

/// 本轮结束。
final class AgentDone extends AgentEvent {
  const AgentDone({this.cancelled = false, this.finishReason = ''});

  /// 是否被用户取消（UI 不应当成错误）。
  final bool cancelled;

  /// 端点给出的 finish_reason（stop / length / tool_calls …）。
  final String finishReason;
}

/// 引擎看到的**历史消息视图**（只保留 LLM 关心的字段）。
///
/// 刻意不让引擎直接依赖存储层的 `CoreMessage`：这样引擎可脱离存储单测，
/// 也避免"引擎误改历史"这类耦合。
class CoreMessageRef {
  const CoreMessageRef({
    required this.role,
    required this.content,
    this.kind = 'text',
    this.toolName,
    this.toolArguments,
    this.toolResult = '',
    this.toolCallId,
    this.toolArgumentsRaw = '',
    this.toolResultForModel = '',
    this.timestamp = 0,
    this.attachments,
  });

  /// `user` / `agent`（存储层口径）。
  final String role;

  /// 正文。
  final String content;

  /// `text` / `thinking` / `tool`。
  final String kind;

  /// 工具名（kind == tool）。
  final String? toolName;

  /// 工具参数（kind == tool）。
  final Map<String, dynamic>? toolArguments;

  /// 工具结果文本（kind == tool）。
  final String toolResult;

  /// 工具调用 id（回灌 `role: tool` 消息时需要与 assistant 的 tool_calls 对应）。
  final String? toolCallId;

  /// 模型原始参数串（空串 = 老数据，回退 `jsonEncode(toolArguments)`）。
  final String toolArgumentsRaw;

  /// 送模型那一份工具结果（空串 = 老数据，回退当场过门控）。
  final String toolResultForModel;

  /// 消息时间戳（毫秒；引擎排序/日志用）。
  final int timestamp;

  /// 用户随该消息上传的附件（工作空间相对路径等元数据）。
  ///
  /// 为什么放在引擎视图里：附件不是"存储层才知道的事"——引擎必须把它们的路径
  /// 写进发给模型的提示词（用户上传的图/文件在哪、叫什么），否则模型看不到任何
  /// 附件信息（只有 UI 上一张空壳卡片）。估算与摘要同样按这一份算，口径一致。
  final List<Map<String, dynamic>>? attachments;

  bool get isTool => kind == 'tool';

  bool get isThinking => kind == 'thinking';

  /// 是否是"系统/hook 提示"（`kind == 'notice'`）：翻译时按 **user** 消息发出。
  bool get isNotice => kind == 'notice';

  bool get isUser => role == 'user';
}

/// 一次生成的输入。
class AgentRunContext {
  const AgentRunContext({
    required this.agentId,
    required this.sessionId,
    required this.systemPrompt,
    required this.userContent,
    required this.history,
    this.modelId = '',
    this.contextSummary = '',
    this.compactedMessageCount = 0,
    this.compactedContext = const <Map<String, dynamic>>[],
  });

  final String agentId;
  final String sessionId;

  /// 该 agent 绑定的模型 id（空 = 未配置，真实引擎会给出可读报错）。
  final String modelId;

  /// agent 的系统提示词。
  final String systemPrompt;

  /// 本次触发的用户输入（**已包含在 [history] 的最后一条**）。
  final String userContent;

  /// 完整会话历史（按时间顺序，已含本次用户消息）。
  final List<CoreMessageRef> history;

  /// 上下文压缩摘要（M7d-4）：非空时引擎会把它作为一条 system 消息插在系统
  /// 提示词之后，替代 [compactedMessageCount] 条已总结的历史。
  final String contextSummary;

  /// 历史开头多少条已被 [contextSummary] 覆盖（引擎翻译时跳过它们）。
  final int compactedMessageCount;

  /// **中转站产出的整份上下文**（点位化 `system.relay.context.compact`），OpenAI 线
  /// 形态的消息数组。
  ///
  /// 非空时它是引擎的**基底**：引擎原样使用这份列表（**不再自己拼 system / 摘要**），
  /// 再从 [history] 第 [compactedMessageCount] 条之后继续翻译追加。为空时走内置路径
  /// （[systemPrompt] + [contextSummary] + 跳过后缀的历史）。
  ///
  /// 用线形态的 Map 而不是 `LlmMessage`：这一层（agent）不认识具体 LLM 类型，
  /// 解析由真实引擎负责（见 `LlmAgentEngine._buildMessages`）。
  final List<Map<String, dynamic>> compactedContext;
}

/// 回复引擎：给定一次 [AgentRunContext]，流式产出 [AgentEvent]。
///
/// 实现：
/// - `ScriptedAgent`：固定回显，用于打通 WS/存储链路与快速测试；
/// - `LlmAgentEngine`（M3 起）：真实 LLM（见 llm/llm_agent_engine.dart）。
abstract interface class AgentEngine {
  /// 生成一轮回复。
  ///
  /// 调用方已把本次用户消息**落库后再调用**，因此 [AgentRunContext.history]
  /// 的最后一条就是本次用户消息——生成失败也不会丢用户输入。
  Stream<AgentEvent> run(
    AgentRunContext context, {
    required bool Function() isCancelled,
  });

  /// 释放资源（幂等）。
  Future<void> close();
}

/// 组装一份**前端用量口径**的 usage 映射。
///
/// 字段与既有后端一致（前端 `_recordUsage`/`ChatMessage.usage` 直接消费）：
/// `prompt_tokens`（当前上下文长度）/ `completion_tokens`（本轮累计生成）/
/// `total_tokens` / `max_tokens`（进度条分母 = 模型 max_seqlen）。
/// 额外字段：
/// - `cached_tokens`：命中前缀缓存的输入 token（> 0 时才带）；
/// - `estimated: true`：端点没给 usage，数值是本地估算（**不要当计费依据**）；
/// - `trimmed_messages`：为塞进上下文而裁掉的历史消息数（> 0 时才带）。
Map<String, dynamic> agentUsageMap({
  required int promptTokens,
  required int completionTokens,
  required int maxTokens,
  int cachedTokens = 0,
  bool estimated = false,
  int trimmedMessages = 0,
}) => <String, dynamic>{
  'prompt_tokens': promptTokens,
  'completion_tokens': completionTokens,
  'total_tokens': promptTokens + completionTokens,
  'max_tokens': maxTokens,
  if (cachedTokens > 0) 'cached_tokens': cachedTokens,
  if (estimated) 'estimated': true,
  if (trimmedMessages > 0) 'trimmed_messages': trimmedMessages,
};
