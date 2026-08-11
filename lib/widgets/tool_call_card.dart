import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/message.dart';

/// 工具调用卡片
///
/// 展示一次工具调用的进度与结果，默认折叠，点击可展开查看：
/// - 工具调用参数（请求）
/// - 工具执行结果（如果尚未完成，显示执行中的动画）
///
/// 为内置工具（help / set / refresh / mcp / team / ask_user_question）与
/// 工作空间工具（read / write / edit / terminal / embed_search）定制了
/// 图标、配色与标题，其余工具使用通用样式。
class ToolCallCard extends StatefulWidget {
  final ChatMessage message;

  const ToolCallCard({super.key, required this.message});

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final ToolStyle style = _toolStyle(widget.message.toolName ?? '');
    final cs = Theme.of(context).colorScheme;
    final bool running = widget.message.toolRunning;

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 560),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: style.color.withOpacity(0.4)),
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
                        color: style.color.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Icon(style.icon, size: 17, color: style.color),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            style.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            running
                                ? '执行中…'
                                : _resultPreview(widget.message.toolResult),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: running
                                  ? style.color
                                  : cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (running)
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: style.color,
                        ),
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
            if (_expanded) _buildBody(context),
          ],
        ),
      ),
    );
  }

  /// 展开后的正文：参数 + 结果
  Widget _buildBody(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ChatMessage m = widget.message;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withOpacity(0.35),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _sectionLabel('工具调用参数'),
          const SizedBox(height: 4),
          _codeBlock(m.toolArguments == null
              ? '{}'
              : _prettyJson(m.toolArguments!)),
          const SizedBox(height: 10),
          _sectionLabel('执行结果'),
          const SizedBox(height: 4),
          if (m.toolRunning)
            Row(
              children: <Widget>[
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text(
                  '工具执行中，请稍候…',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            )
          else
            SelectableText(
              m.toolResult.isEmpty ? '（无输出）' : m.toolResult,
              style: const TextStyle(fontSize: 12, height: 1.4),
            ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _codeBlock(String text) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: SelectableText(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontFamily: 'monospace',
          height: 1.4,
        ),
      ),
    );
  }

  /// 结果预览（单行截断）：尝试提取简短输出
  String _resultPreview(String result) {
    final String trimmed = result.trim();
    if (trimmed.isEmpty) return '完成';
    final String singleLine = trimmed.replaceAll(RegExp(r'\s+'), ' ');
    return singleLine.length > 60
        ? '${singleLine.substring(0, 60)}…'
        : singleLine;
  }

  String _prettyJson(Map<String, dynamic> map) {
    try {
      return const JsonEncoder.withIndent('  ').convert(map);
    } catch (_) {
      return map.toString();
    }
  }
}

/// 工具样式描述
class ToolStyle {
  final IconData icon;
  final Color color;
  final String title;

  const ToolStyle(this.icon, this.color, this.title);
}

const Color _blue = Color(0xFF2563EB);
const Color _green = Color(0xFF16A34A);
const Color _orange = Color(0xFFEA580C);
const Color _purple = Color(0xFF7C3AED);
const Color _teal = Color(0xFF0D9488);
const Color _pink = Color(0xFFDB2777);
const Color _grey = Color(0xFF64748B);

/// 按工具名返回定制样式
ToolStyle _toolStyle(String name) {
  switch (name) {
    case 'help':
      return const ToolStyle(Icons.help_outline, _blue, 'help · 工具帮助');
    case 'set':
      return const ToolStyle(Icons.tune, _orange, 'set · 参数配置');
    case 'refresh':
      return const ToolStyle(Icons.refresh, _green, 'refresh · 刷新工具');
    case 'mcp':
      return const ToolStyle(Icons.extension, _purple, 'mcp · 调用 MCP 工具');
    case 'team':
      return const ToolStyle(Icons.groups, _teal, 'team · 团队管理');
    case 'ask_user_question':
      return const ToolStyle(
          Icons.question_answer, _pink, 'ask_user_question · 向用户提问');
    case 'read':
      return const ToolStyle(Icons.description, _blue, 'read · 读取文件');
    case 'write':
      return const ToolStyle(Icons.note_add, _green, 'write · 写入文件');
    case 'edit':
      return const ToolStyle(Icons.edit, _green, 'edit · 编辑文件');
    case 'terminal':
      return const ToolStyle(Icons.terminal, _grey, 'terminal · 执行命令');
    case 'embed_search':
      return const ToolStyle(Icons.search, _teal, 'embed_search · 语义搜索');
    default:
      return const ToolStyle(Icons.build, _grey, '$name · 工具调用');
  }
}