import 'package:flutter/material.dart';

import '../models/message.dart';
import 'thinking_card.dart';
import 'tool_call_card.dart';

/// 临时员工（subagent）的**过程列表**：它自己的文本 / 思考 / 工具调用 / 完成报告。
///
/// 两处共用同一份渲染口径（不重复实现，免得两边漂）：
/// - `subagent` 工具调用的**详情页**（就地看这次调用召来的员工干了什么）；
/// - 临时员工的**工作进度页**（[SubagentViewPage]，与 teammates 窗口同一层级的入口）。
class SubagentProcessList extends StatelessWidget {
  const SubagentProcessList({
    super.key,
    required this.messages,
    this.emptyHint = '还没有过程消息。',
  });

  final List<ChatMessage> messages;

  /// 一条过程都没有时的说明（两处场景不同：详情页可能是"还没跑完"，独立页是"真的没有"）。
  final String emptyHint;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    if (messages.isEmpty) {
      return Text(
        emptyHint,
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.4),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final ChatMessage message in messages) ...<Widget>[
          _row(context, message),
          const SizedBox(height: 6),
        ],
      ],
    );
  }

  Widget _row(BuildContext context, ChatMessage message) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    switch (message.kind) {
      case 'subagent_task':
        // 任务在调用参数里已经写了（详情页）/ 页面头部也标了，不再重复一遍
        return const SizedBox.shrink();
      case 'tool':
        return ToolCallCard(message: message);
      case 'thinking':
        return Text(
          '思考 · ${thinkingSummary(message.content)}',
          style: TextStyle(
            fontSize: 12,
            color: cs.onSurfaceVariant,
            height: 1.35,
          ),
        );
      case 'subagent_report':
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: cs.surfaceContainerLowest,
            border: Border.all(color: cs.primary.withValues(alpha: 0.35)),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '完成报告',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: cs.primary,
                ),
              ),
              const SizedBox(height: 4),
              SelectableText(
                message.content,
                style: const TextStyle(fontSize: 12, height: 1.45),
              ),
            ],
          ),
        );
      default:
        return SelectableText(
          message.content,
          style: const TextStyle(fontSize: 12, height: 1.45),
        );
    }
  }
}

/// 临时员工过程里"最后一条带 usage 的消息"给的**它自己的上下文用量**（没有则 null）。
///
/// 用户 2026-10-04：「临时员工的 LLM 调用上下文长度统计不能污染主 agent 的」——所以这个数字
/// 只在临时员工自己的视图里显示，绝不并进主 agent 那条读数。
String? subagentUsageLine(List<ChatMessage> transcript) {
  for (final ChatMessage message in transcript.reversed) {
    final Map<String, dynamic>? usage = message.usage;
    if (usage == null || usage.isEmpty) continue;
    final int prompt = (usage['prompt_tokens'] as num?)?.toInt() ?? 0;
    final int max = (usage['max_tokens'] as num?)?.toInt() ?? 0;
    if (prompt <= 0 && max <= 0) continue;
    return max > 0
        ? '它的上下文：$prompt / $max tokens（不并进主 agent 的统计）'
        : '它的上下文：$prompt tokens（不并进主 agent 的统计）';
  }
  return null;
}
