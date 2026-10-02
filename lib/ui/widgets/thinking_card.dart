import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../models/message.dart';
import '../services/detail_selection.dart';

/// 一次推理的**一行**：图标 + 「思考」 + 首行摘要。
///
/// 与工具行同一套排版：默认只占一行，完整推理内容去右栏「详情」页看（点这一行）。
/// 理由同工具行——一轮任务里思考与工具交替出现几十次，卡片会把消息流撑散；
/// 一行之后"想了什么、做了什么"排在一起，像一条时间线。
class ThinkingCard extends StatefulWidget {
  final ChatMessage message;

  const ThinkingCard({super.key, required this.message});

  @override
  State<ThinkingCard> createState() => _ThinkingCardState();
}

class _ThinkingCardState extends State<ThinkingCard> {
  /// 鼠标是否停在这一行上（图标与箭头提亮；底色由 InkWell 画）
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ChatMessage m = widget.message;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool running = m.isStreaming;
    final String text = m.content.trim();
    final String summary = text.isEmpty ? '正在分析问题…' : thinkingSummary(text);

    return ListenableBuilder(
      listenable: DetailSelection.instance,
      builder: (BuildContext context, Widget? child) {
        final bool isSelected = DetailSelection.instance.selectedId == m.id;
        return MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: Material(
            color: isSelected
                ? cs.primary.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              hoverColor: cs.primary.withValues(alpha: 0.07),
              onTap: () => DetailSelection.instance.select(m),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(
                  children: <Widget>[
                    Icon(
                      running ? Icons.psychology : Icons.psychology_outlined,
                      size: 15,
                      color: _hover || isSelected
                          ? cs.tertiary
                          : cs.tertiary.withValues(alpha: 0.75),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      running ? '思考中' : '思考',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        summary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: cs.onSurfaceVariant,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (running)
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: cs.tertiary,
                        ),
                      )
                    else
                      Icon(
                        Icons.chevron_right,
                        size: 14,
                        color: _hover || isSelected ? cs.primary : cs.outline,
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 折叠成一行时的摘要：取第一段非空内容，去掉 markdown 标记与多余空白，截断 80 字
String thinkingSummary(String text) {
  final String line = text
      .split('\n')
      .firstWhere(
        (String l) => l.trim().isNotEmpty,
        orElse: () => text,
      )
      .trim();
  // 去掉 markdown 标记后**还要再 trim 一次**：『## 标题』去掉 # 会留下前导空格
  final String cleaned = line
      .replaceAll(RegExp(r'[#*`>|-]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return cleaned.length > 80 ? '${cleaned.substring(0, 80)}…' : cleaned;
}

/// 完整推理内容（右栏「详情」页用）：markdown 渲染 + 可选中
class ThinkingDetail extends StatelessWidget {
  const ThinkingDetail({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool running = message.isStreaming;
    final String text = message.content.trim();
    if (text.isEmpty) {
      return Row(
        children: <Widget>[
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(
            '思考中…',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (running)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '思考中…（内容还在追加）',
              style: TextStyle(fontSize: 11, color: cs.tertiary),
            ),
          ),
        MarkdownBody(
          data: text,
          selectable: true,
          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
            p: TextStyle(fontSize: 13, height: 1.6, color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
