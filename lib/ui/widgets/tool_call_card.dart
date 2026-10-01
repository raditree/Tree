import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/message.dart';

/// 工具调用卡片
///
/// 展示一次工具调用的进度与结果，默认折叠，点击可展开查看：
/// - 工具调用参数（按工具类型格式化展示，非原始 JSON）
/// - 工具执行结果（如果尚未完成，显示执行中的动画）
///
/// 为内置工具（help / set / refresh / mcp / team / ask_user_question）与
/// 工作空间工具（read / grep / write / edit / terminal / embed_search）定制了
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
        // 不再写死 560px：中栏被拖宽时工具输出（命令、文件差异、表格）应当
        // 跟着铺满可用宽度，只留 Align 自带的一点点余量
        constraints: const BoxConstraints(maxWidth: double.infinity),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: style.color.withValues(alpha: 0.4)),
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
                        color: style.color.withValues(alpha: 0.15),
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
                            _collapsedTitle(widget.message),
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

  /// 折叠态标题：工具名 + 关键参数摘要
  String _collapsedTitle(ChatMessage m) {
    final String name = m.toolName ?? '';
    final Map<String, dynamic> args = m.toolArguments ?? <String, dynamic>{};
    switch (name) {
      case 'read':
        return '读取 ${args['path'] ?? ''}';
      case 'grep': {
        final String pattern = (args['pattern'] ?? '').toString();
        final String path = (args['path'] ?? '').toString();
        if (pattern.isEmpty) return '内容搜索';
        return path.isEmpty ? '搜索: $pattern' : '搜索 $path: $pattern';
      }
      case 'write':
        return '写入 ${args['path'] ?? ''}';
      case 'edit':
        return '编辑 ${args['path'] ?? ''}';
      case 'terminal':
        final String cmd = (args['cmd'] ?? args['command'] ?? '').toString();
        return cmd.isEmpty ? '终端命令' : '终端: $cmd';
      case 'set':
        final String? key = args['key']?.toString() ?? args['param']?.toString();
        return key != null ? '设置 $key' : '参数配置';
      case 'team':
        final String? action = args['action']?.toString();
        return action != null ? '团队: $action' : '团队管理';
      case 'mcp':
        final String? toolName = args['tool_name']?.toString() ?? args['tool']?.toString();
        // mcp 嵌套参数：arguments.cmd / arguments.path 等
        final Map<String, dynamic> nested =
            (args['arguments'] as Map<String, dynamic>?)?.cast<String, dynamic>() ??
                <String, dynamic>{};
        if (toolName == 'terminal') {
          final String cmd = (nested['cmd'] ?? nested['command'] ?? '').toString();
          return cmd.isEmpty ? 'MCP: terminal' : '终端: $cmd';
        }
        if (toolName == 'read') {
          return '读取 ${nested['path'] ?? ''}';
        }
        if (toolName == 'write') {
          return '写入 ${nested['path'] ?? ''}';
        }
        if (toolName == 'edit') {
          return '编辑 ${nested['path'] ?? ''}';
        }
        if (toolName == 'embed_search') {
          return '搜索: ${nested['query'] ?? ''}';
        }
        return toolName != null ? 'MCP: $toolName' : 'MCP 调用';
      case 'ask_user_question':
        return '向用户提问';
      case 'help':
        return '工具帮助';
      case 'refresh':
        return '刷新工具';
      case 'embed_search':
        final String? query = args['query']?.toString();
        return query != null ? '搜索: $query' : '语义搜索';
      default:
        return name.isEmpty ? '工具调用' : name;
    }
  }

  /// 展开后的正文：按工具类型定制
  Widget _buildBody(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ChatMessage m = widget.message;
    final String name = m.toolName ?? '';
    final Map<String, dynamic> args = m.toolArguments ?? <String, dynamic>{};
    final List<Widget> params = _buildParams(name, args);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ...params,
          if (params.isNotEmpty) const SizedBox(height: 10),
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
            _buildResult(name, m.toolResult, args),
        ],
      ),
    );
  }

  /// 按工具类型构建参数展示（人类可读，非 JSON）
  List<Widget> _buildParams(String name, Map<String, dynamic> args) {
    switch (name) {
      case 'read':
        return [_paramRow('文件', args['path']?.toString() ?? '')];
      case 'write':
        return [
          _paramRow('文件', args['path']?.toString() ?? ''),
          _paramRow('内容长度', '${(args['content']?.toString() ?? '').length} 字符'),
        ];
      case 'edit':
        return [
          _paramRow('文件', args['path']?.toString() ?? ''),
          _paramRow('查找', _truncate(args['old_string']?.toString() ?? '', 80)),
          _paramRow('替换', _truncate(args['new_string']?.toString() ?? '', 80)),
        ];
      case 'terminal':
        final String cmd = (args['cmd'] ?? args['command'] ?? '').toString();
        return [_paramRow('命令', cmd)];
      case 'set':
        final String key = args['key']?.toString() ?? args['param']?.toString() ?? '';
        final String value = args['value']?.toString() ?? '';
        return [
          _paramRow('参数', key),
          _paramRow('值', value),
        ];
      case 'set_todo_list':
        final String action = args['action']?.toString() ?? '';
        final List<Widget> widgets = <Widget>[_paramRow('操作', action)];
        if (action == 'set') {
          final List<dynamic>? todos = args['todos'] as List<dynamic>?;
          if (todos != null && todos.isNotEmpty) {
            widgets.add(_paramRow('任务项数', '${todos.length}'));
          }
        } else if (action == 'update') {
          widgets.add(_paramRow('目标 id', args['todo_id']?.toString() ?? ''));
        }
        return widgets;
      case 'team':
        final String action = args['action']?.toString() ?? '';
        final String? memberId = args['member_id']?.toString();
        final List<Widget> widgets = <Widget>[_paramRow('操作', action)];
        if (memberId != null && memberId.isNotEmpty) {
          widgets.add(_paramRow('成员', memberId));
        }
        final String? desc = args['description']?.toString();
        if (desc != null && desc.isNotEmpty) {
          widgets.add(_paramRow('描述', _truncate(desc, 120)));
        }
        return widgets;
      case 'mcp':
        final String toolName = args['tool_name']?.toString() ??
            args['tool']?.toString() ?? '';
        final Map<String, dynamic> nested =
            (args['arguments'] as Map<String, dynamic>?)?.cast<String, dynamic>() ??
                <String, dynamic>{};
        final List<Widget> widgets = <Widget>[_paramRow('MCP 工具', toolName)];
        // 展开嵌套参数为人类可读行
        for (final MapEntry<String, dynamic> e in nested.entries) {
          widgets.add(_paramRow(e.key, _truncate(e.value.toString(), 120)));
        }
        return widgets;
      case 'ask_user_question':
        final String question = args['question']?.toString() ?? '';
        final List<dynamic>? options = args['options'] as List<dynamic>?;
        final List<Widget> widgets = <Widget>[_paramRow('问题', question)];
        if (options != null && options.isNotEmpty) {
          widgets.add(_paramRow('选项', options.join(' / ')));
        }
        return widgets;
      case 'embed_search':
        return [_paramRow('查询', args['query']?.toString() ?? '')];
      default:
        // 通用：列出所有参数
        if (args.isEmpty) return <Widget>[];
        return args.entries.map((MapEntry<String, dynamic> e) {
          return _paramRow(e.key, _truncate(e.value.toString(), 100));
        }).toList();
    }
  }

  /// 按工具类型构建结果展示
  Widget _buildResult(String name, String result, Map<String, dynamic> args) {
    if (result.isEmpty) {
      return const Text('（无输出）',
          style: TextStyle(fontSize: 12, color: Colors.grey));
    }

    // set_todo_list 特殊展示：把 todos 数组渲染成 id+内容+状态列表
    if (name == 'set_todo_list') {
      final Map<String, dynamic>? parsed = _tryDecodeMap(result);
      final List<dynamic>? todos = parsed?['todos'] as List<dynamic>?;
      if (todos != null && todos.isNotEmpty) {
        final List<Widget> rows = <Widget>[];
        for (final dynamic t in todos) {
          if (t is! Map<String, dynamic>) continue;
          final String id = (t['id'] ?? '').toString();
          final String content = (t['content'] ?? '').toString();
          final String status = (t['status'] ?? '').toString();
          final String progress = (t['progress'] ?? '').toString();
          rows.add(Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: 120,
                  child: Text(
                    id,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Expanded(
                  child: Text(
                    content,
                    style: const TextStyle(fontSize: 12, height: 1.4),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '$status $progress',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        );
      }
    }
    // 如果结果是重定向提示
    if (result.startsWith('工具调用结果已保存到')) {
      return Row(
        children: <Widget>[
          Icon(Icons.save_alt, size: 14, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: SelectableText(
              result,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ],
      );
    }

    // 尝试从 Python dict 字符串或 JSON 中提取可读内容
    final String displayResult = _extractReadableResult(result);

    // 大输出：用可滚动容器
    if (displayResult.length > 200) {
      return Container(
        constraints: const BoxConstraints(maxHeight: 240),
        width: double.infinity,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: SingleChildScrollView(
          child: SelectableText(
            displayResult,
            style: const TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              height: 1.4,
            ),
          ),
        ),
      );
    }
    return SelectableText(
      displayResult,
      style: const TextStyle(fontSize: 12, height: 1.4),
    );
  }

  /// 从工具结果字符串中提取人类可读内容。
  ///
  /// 后端 `str(result)` 可能产生：
  /// - JSON 字符串：`{"content": "...", "tool_name": "read", ...}`
  /// - Python dict 字符串：`{'content': '...', 'tool_name': 'read', ...}`
  /// - 纯文本
  ///
  /// 提取 `content` / `output` / `result` / `message` 等关键字段；
  /// 若解析失败则返回原始字符串。
  String _extractReadableResult(String raw) {
    final Map<String, dynamic>? parsed = _tryDecodeMap(raw);
    if (parsed == null) return raw;

    // 提取可读字段
    for (final String key in <String>['content', 'output', 'result', 'message', 'text']) {
      final dynamic val = parsed[key];
      if (val != null && val.toString().isNotEmpty) {
        return val.toString();
      }
    }

    // 有 error 字段
    final dynamic err = parsed['error'];
    if (err != null) {
      return '错误: $err';
    }

    // 回退：返回原始 JSON
    return raw;
  }

  /// 尝试把工具结果字符串解析为 map。
  ///
  /// 兼容 JSON 与 Python dict 字符串（单引号、True/False/None）。
  /// 解析失败时返回 null。
  Map<String, dynamic>? _tryDecodeMap(String raw) {
    // 尝试 JSON 解析
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // 尝试修复 Python dict 字符串（单引号 -> 双引号）
      try {
        final String fixed = raw
            .replaceAll(RegExp(r"(?<!\\)'"), '"')
            .replaceAll(RegExp(r'\bTrue\b'), 'true')
            .replaceAll(RegExp(r'\bFalse\b'), 'false')
            .replaceAll(RegExp(r'\bNone\b'), 'null');
        final Object? decoded = jsonDecode(fixed);
        if (decoded is Map<String, dynamic>) return decoded;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// 参数行：标签 + 值
  Widget _paramRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 56,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value.isEmpty ? '-' : value,
              style: const TextStyle(fontSize: 12, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }

  String _truncate(String s, int max) {
    if (s.length <= max) return s;
    return '${s.substring(0, max)}…';
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

  /// 结果预览（单行截断）
  String _resultPreview(String result) {
    final String extracted = _extractReadableResult(result);
    final String trimmed = extracted.trim();
    if (trimmed.isEmpty) return '完成';
    final String singleLine = trimmed.replaceAll(RegExp(r'\s+'), ' ');
    return singleLine.length > 60
        ? '${singleLine.substring(0, 60)}…'
        : singleLine;
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
    case 'grep':
      return const ToolStyle(Icons.manage_search, _teal, 'grep · 内容搜索');
    case 'write':
      return const ToolStyle(Icons.note_add, _green, 'write · 写入文件');
    case 'edit':
      return const ToolStyle(Icons.edit, _green, 'edit · 编辑文件');
    case 'terminal':
      return const ToolStyle(Icons.terminal, _grey, 'terminal · 执行命令');
    case 'embed_search':
      return const ToolStyle(Icons.search, _teal, 'embed_search · 语义搜索');
    default:
      return ToolStyle(Icons.build, _grey, '$name · 工具调用');
  }
}
