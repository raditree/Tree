import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../models/message.dart';

/// 思考（Thinking）卡片
///
/// 展示模型的推理过程（``reasoning_content``），默认折叠：
/// - 思考中：显示"思考中…"动效 + 已产出内容首行摘要
/// - 已完成：显示"思考时长 + 首行摘要"
///
/// 点击可展开查看完整 markdown 推理内容。历史加载时（kind == 'thinking'）
/// 同样渲染为折叠卡片，可点击展开。
class ThinkingCard extends StatefulWidget {
  final ChatMessage message;

  const ThinkingCard({super.key, required this.message});

  @override
  State<ThinkingCard> createState() => _ThinkingCardState();
}

class _ThinkingCardState extends State<ThinkingCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final ChatMessage m = widget.message;
    final cs = Theme.of(context).colorScheme;
    final bool running = m.isStreaming;
    final String text = m.content.trim();

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        // 不再写死 560px：思考内容随中栏宽度铺开（与工具卡片同口径）
        constraints: const BoxConstraints(maxWidth: double.infinity),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: cs.tertiary.withValues(alpha: 0.35)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: cs.tertiary.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Icon(
                        running ? Icons.psychology : Icons.psychology_outlined,
                        size: 17,
                        color: cs.tertiary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            running ? '思考中…' : '思考过程',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            text.isEmpty ? '正在分析问题…' : _firstLine(text),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: running
                                  ? cs.tertiary
                                  : cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (running)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        _expanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 20,
                        color: cs.outline,
                      ),
                  ],
                ),
              ),
            ),
            if (_expanded)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
                  borderRadius:
                      const BorderRadius.vertical(bottom: Radius.circular(10)),
                ),
                child: text.isEmpty
                    ? Text(
                        '思考中…',
                        style: TextStyle(
                            fontSize: 12, color: cs.onSurfaceVariant),
                      )
                    : MarkdownBody(
                        data: text,
                        selectable: true,
                        styleSheet: MarkdownStyleSheet.fromTheme(
                          Theme.of(context),
                        ),
                      ),
              ),
          ],
        ),
      ),
    );
  }

  /// 取首行作为折叠态摘要（去除 markdown 标记，截断 60 字）
  String _firstLine(String text) {
    final String line = text
        .split('\n')
        .firstWhere(
          (String l) => l.trim().isNotEmpty,
          orElse: () => text,
        )
        .trim();
    final String cleaned =
        line.replaceAll(RegExp(r'[#*`>|-]'), '').replaceAll(RegExp(r'\s+'), ' ');
    return cleaned.length > 60 ? '${cleaned.substring(0, 60)}…' : cleaned;
  }
}
