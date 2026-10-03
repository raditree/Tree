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

// 上下文读数的口径（含 subagentUsageLine）统一在 services/conversation_view.dart：
// 中栏的上下文长度条与这里的详情页**必须同源**，否则两处会漂。
