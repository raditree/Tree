/// 中栏"正在看谁的对话"的口径。
///
/// 用户 2026-10-04：「进入对应 subagent 视角**不新开窗口**（借父 agent 窗口，但把对话数据、
/// 上下文长度条换成 subagent 的）」——所以"看谁"是中栏的一个**视图状态**，不是新页面：
///
/// - **主会话**：主 agent 自己的消息（排掉带临时员工标记的，见 [visibleStreamMessages]）
///   + 主会话自己的上下文读数；
/// - **临时员工视角**：它的完整过程（文本 / 思考 / 工具调用 / 完成报告）+ **它自己的**
///   上下文读数——绝不并进主 agent 那条读数（同一用户的另一条硬要求）。
///
/// 这个文件只放**纯函数**：面板持有状态、负责渲染，口径在这里，单测钉在口径上。
library;

import '../models/message.dart';
import 'subagent_transcript.dart';

/// 一条"上下文读数"（上下文长度条的输入）。
class ContextReading {
  const ContextReading({required this.promptTokens, required this.maxTokens});

  /// 最近一次请求的输入 token（= 当时上下文长度）。
  final int promptTokens;

  /// 该模型的上限；0 = 端点没给（读数只显示绝对值）。
  final int maxTokens;

  bool get isEmpty => promptTokens <= 0 && maxTokens <= 0;
}

/// 中栏该显示的消息。
///
/// [subagentId] 为空 = 主会话：可见流（去掉临时员工的消息）；非空 = 那个临时员工的完整过程。
List<ChatMessage> viewMessages({
  required String subagentId,
  required List<ChatMessage> stream,
  required List<ChatMessage> transcript,
}) =>
    subagentId.isEmpty ? visibleStreamMessages(stream) : transcript;

/// 中栏"上下文"读数：**各看各的**。
///
/// 主会话用主 agent 那条 usage；临时员工视角用它自己最后一条带 usage 的过程消息。
/// 两者永不互相污染（用户硬要求："临时员工的 LLM 调用上下文长度统计不能污染主 agent 的"）。
ContextReading? viewContext({
  required String subagentId,
  required Map<String, dynamic>? mainUsage,
  required List<ChatMessage> transcript,
}) {
  if (subagentId.isNotEmpty) return subagentContext(transcript);
  if (mainUsage == null) return null;
  final ContextReading reading = ContextReading(
    promptTokens: (mainUsage['prompt_tokens'] as num?)?.toInt() ?? 0,
    maxTokens: (mainUsage['max_tokens'] as num?)?.toInt() ?? 0,
  );
  return reading.isEmpty ? null : reading;
}

/// 临时员工自己的上下文读数（取它**最后一条**带 usage 的过程消息）。
ContextReading? subagentContext(List<ChatMessage> transcript) {
  for (final ChatMessage message in transcript.reversed) {
    final Map<String, dynamic>? usage = message.usage;
    if (usage == null || usage.isEmpty) continue;
    final ContextReading reading = ContextReading(
      promptTokens: (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
      maxTokens: (usage['max_tokens'] as num?)?.toInt() ?? 0,
    );
    if (!reading.isEmpty) return reading;
  }
  return null;
}

/// 临时员工视图里"它自己的上下文"那一行（给人看的措辞，明确不并进主 agent）。
///
/// 没有读数时返回 null（调用方据此不显示这一行）——与旧的同名 helper 同契约。
String? subagentUsageLine(List<ChatMessage> transcript) {
  final ContextReading? reading = subagentContext(transcript);
  if (reading == null) return null;
  return reading.maxTokens > 0
      ? '它的上下文：${reading.promptTokens} / ${reading.maxTokens} tokens'
            '（不并进主 agent 的统计）'
      : '它的上下文：${reading.promptTokens} tokens（不并进主 agent 的统计）';
}

/// 临时员工的显示名（过程里拿不到就退回 [fallback]，再不行「未命名」）。
String subagentName(List<ChatMessage> transcript, {String fallback = ''}) {
  for (final ChatMessage message in transcript) {
    if (message.subagentName.isNotEmpty) return message.subagentName;
  }
  return fallback.isEmpty ? '未命名' : fallback;
}

/// 它在会话内树里的层数（真实 agent 的直属临时员工 = 1；拿不到时给 1）。
int subagentLevel(List<ChatMessage> transcript) {
  for (final ChatMessage message in transcript) {
    if (message.subagentLevel > 0) return message.subagentLevel;
  }
  return 1;
}

/// 中栏标题：主会话 = agent 名；临时员工视角 = 「临时员工「名字」」。
String viewTitle({
  required String subagentId,
  required String agentName,
  required List<ChatMessage> transcript,
}) =>
    subagentId.isEmpty
    ? agentName
    : '临时员工「${subagentName(transcript)}」';

/// 临时员工视角的副标题：**谁召来的** + 层数（措辞与 teammates 刻意分开：这里不是团队层级）。
String viewSubtitle({
  required String callerName,
  required List<ChatMessage> transcript,
}) =>
    '由「${callerName.isEmpty ? '（未知调用方）' : callerName}」召来'
    ' · 第 ${subagentLevel(transcript)} 层';
