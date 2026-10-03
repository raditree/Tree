import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/message.dart';
import '../services/detail_selection.dart';

/// 一次工具调用的**一行**：图标 + 中文标签 + 关键参数（等宽），行尾给增量 / 转圈 / 箭头。
///
/// 为什么从卡片改成一行：一轮任务里工具调用动辄几十条，"边框 + 两行 + 展开箭头"
/// 会把消息流切成一大堆盒子，用户看不出这一轮到底读了哪些文件、跑了什么命令。
/// 一行之后整轮动作像一份清单，扫一眼就知道发生了什么。
///
/// 完整内容（参数表 + 完整结果）不在中栏展开，而是点这一行 → 右栏「详情」页，
/// 中栏因此永远保持紧凑；悬停有底色与图标提亮作为"这里可以点"的呼应。
class ToolCallCard extends StatefulWidget {
  final ChatMessage message;

  const ToolCallCard({super.key, required this.message});

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  /// 鼠标是否停在这一行上（提亮用；底色由 InkWell 自己画）
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final ChatMessage m = widget.message;
    final ToolStyle style = toolStyleOf(m.toolName ?? '');
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool running = m.toolRunning;
    final String value = toolLineValue(m);
    final String? diff = toolDiffStat(m.toolName ?? '', m.toolArguments);

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
                      style.icon,
                      size: 15,
                      color: _hover || isSelected
                          ? style.color
                          : style.color.withValues(alpha: 0.75),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      toolLabel(m.toolName ?? ''),
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontFamily: 'Consolas',
                          fontFamilyFallback: const <String>[
                            'Cascadia Mono',
                            'monospace',
                          ],
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                    if (diff != null) ...<Widget>[
                      const SizedBox(width: 8),
                      Text(
                        diff,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontFamily: 'Consolas',
                          color: cs.tertiary,
                        ),
                      ),
                    ],
                    const SizedBox(width: 6),
                    if (running)
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: style.color,
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

/// 工具的中文短名：一行行首的标签（也是详情页标题）
String toolLabel(String name) {
  switch (name) {
    case 'read':
      return '读取';
    case 'grep':
      return '搜索';
    case 'write':
      return '写入';
    case 'edit':
      return '编辑';
    case 'terminal':
      return '运行命令';
    case 'set':
      return '设置';
    case 'set_todo_list':
      return '待办';
    case 'team':
      return '团队';
    case 'subagent':
      // 用户定稿口径：召一个**临时员工**（会话内、继承配置、可复用、可再派发）
      return '临时员工';
    case 'mcp':
      return 'MCP';
    case 'embed_search':
      return '语义搜索';
    case 'ask_user_question':
      return '提问';
    case 'help':
      return '帮助';
    case 'refresh':
      return '刷新';
    default:
      return name.isEmpty ? '工具' : name;
  }
}

/// 一行的正文：这条工具调用最关键的那个参数（路径 / 命令 / 查询词…）。
///
/// 取不到关键参数时退回结果的一句话——宁可显示"改了什么"，也别留一行空白。
String toolLineValue(ChatMessage m) {
  final String name = m.toolName ?? '';
  final Map<String, dynamic> args = m.toolArguments ?? <String, dynamic>{};
  String arg(String key) => (args[key] ?? '').toString();

  switch (name) {
    case 'read':
    case 'write':
    case 'edit':
      // 核心 schema 的键名是 file_path（不是 path），见 builtin_tools.dart 的 read/write/edit
      return arg('file_path');
    case 'grep': {
      final String pattern = arg('pattern');
      final String path = arg('path');
      if (pattern.isEmpty) return path;
      return path.isEmpty ? pattern : '$pattern  ·  $path';
    }
    case 'terminal':
      final String cmd = arg('cmd').isEmpty ? arg('command') : arg('cmd');
      return cmd;
    case 'set':
      final String key = arg('key').isEmpty ? arg('param') : arg('key');
      return key;
    case 'set_todo_list':
      return arg('content').isEmpty ? arg('action') : arg('content');
    case 'team':
      return arg('description').isEmpty ? arg('action') : arg('description');
    case 'mcp': {
      final String tool = arg('tool_name').isEmpty ? arg('tool') : arg('tool_name');
      final Map<String, dynamic> nested =
          (args['arguments'] as Map<String, dynamic>?)?.cast<String, dynamic>() ??
              <String, dynamic>{};
      final String inner = (nested['cmd'] ??
              nested['command'] ??
              nested['path'] ??
              nested['query'] ??
              '')
          .toString();
      return inner.isEmpty ? tool : '$tool  ·  $inner';
    }
    case 'subagent': {
      // 一行要能看出"谁在干、是不是复用、是不是后台"；task 太长时由行本身省略号收尾。
      final String task = arg('task');
      final String reuse = arg('subagent_id');
      final String head = <String>[
        if (reuse.isNotEmpty) '复用 $reuse',
        if (args['background'] == true) '后台',
      ].join(' · ');
      if (task.isEmpty) return head;
      return head.isEmpty ? task : '$head · $task';
    }
    case 'ask_user_question':
      return arg('question');
    case 'embed_search':
      return arg('query');
    default:
      // 通用工具：第一个参数当正文，没有就给结果摘要
      if (args.isNotEmpty) {
        final dynamic first = args.values.first;
        final String text = first?.toString() ?? '';
        if (text.isNotEmpty) return text;
      }
      return toolResultPreview(m.toolResult);
  }
}

/// 编辑类工具的行尾增量（+39 -0）。
///
/// 数据来源只有一个：**assistant 这次工具调用的参数**里的新旧两段文本。核心 `edit`
/// 的结果只有「已替换 N 处」，没有行数，不能当行数来源（也不必去解析结果文本）。
///
/// 参数键名以核心工具 schema 为准（packages/tree_core/lib/src/tool/builtin_tools.dart：
/// write 在 162-169 行、edit 在 176-194 行）：
/// - `edit`：`file_path` / `old_text`（详情页标签「查找」）/ `new_text`（「替换」）
/// - `write`：`file_path` / `content`
/// 这里曾经写成 `path` / `old_string` / `new_string`（别的生态的键名），于是每次
/// 编辑都取不到参数、行尾恒显示 `+0 -0`——键名必须与核心对齐。
///
/// 行数口径见 [countTextLines]（与核心 `_write` 用的 `LineSplitter` 一致）。
///
/// 取不到必要参数（历史消息里的旧格式、非编辑类工具、参数被模型截断）时返回 null：
/// 行尾宁可什么都不显示，也不显示误导的 `+0 -0`。只拿到一侧时只报告能确定的
/// 那一侧——只有 `old_text` ⇒ `-3`、只有 `new_text` ⇒ `+2`。
String? toolDiffStat(String name, Map<String, dynamic>? args) {
  final Map<String, dynamic> a = args ?? <String, dynamic>{};

  switch (name) {
    case 'edit': {
      final String oldText = _argText(a, 'old_text');
      final String newText = _argText(a, 'new_text');
      // 空 old_text 不可能是真的「查找」（核心要求唯一匹配），按"没给"处理；
      // new_text 故意允许空串——那是删除整段，是有效的一次编辑。
      final bool hasOld = oldText.isNotEmpty;
      final bool hasNew = a.containsKey('new_text');
      if (!hasOld && !hasNew) return null;
      final int removed = hasOld ? countTextLines(oldText) : 0;
      final int added = hasNew ? countTextLines(newText) : 0;
      if (added == 0 && removed == 0) return null;
      if (!hasNew) return '-$removed';
      if (!hasOld) return '+$added';
      return '+$added -$removed';
    }
    case 'write': {
      if (!a.containsKey('content')) return null;
      final int added = countTextLines(_argText(a, 'content'));
      return added == 0 ? null : '+$added';
    }
    default:
      return null;
  }
}

/// 文本的行数口径——与核心 `_write` 的 `LineSplitter` 完全一致。
///
/// - 空串 = 0 行；
/// - **末尾换行符不算多一行**：`"a"` 与 `"a\n"` 都是 1 行；
/// - 空行照算：`"a\n\nb"` = 3 行；
/// - LF / CRLF / CR 同权：`"a\r\nb\r\n"` = 2 行。
///
/// 为什么不用 `split('\n').length`：那会把末尾的 `\n` 算成多一个空行，于是"写入
/// 3 行文本（末尾带换行）"会显示 `+4`，与核心结果里的「已写入 …（N 字节，3 行）」
/// 对不上。
int countTextLines(String text) {
  if (text.isEmpty) return 0;
  int lines = 1;
  for (int i = 0; i < text.length; i++) {
    final int c = text.codeUnitAt(i);
    if (c == 0x0A) {
      lines++;
    } else if (c == 0x0D) {
      lines++;
      if (i + 1 < text.length && text.codeUnitAt(i + 1) == 0x0A) i++;
    }
  }
  final int last = text.codeUnitAt(text.length - 1);
  if (last == 0x0A || last == 0x0D) lines--;
  return lines;
}

/// 参数里的字符串值；键不存在时给空串（"没给"要另外判 `containsKey`）。
String _argText(Map<String, dynamic> args, String key) {
  final dynamic value = args[key];
  return value == null ? '' : value.toString();
}

/// 结果的单行摘要（把换行压成空格）
String toolResultPreview(String result) {
  final String trimmed = extractReadableResult(result).trim();
  if (trimmed.isEmpty) return '';
  return trimmed.replaceAll(RegExp(r'\s+'), ' ');
}

/// 从工具结果字符串里提取人类可读内容。
///
/// 核心的 str(result) 可能是 JSON、Python dict 字符串或纯文本；提取
/// content / output / result / message / text 之一，解析失败就原样返回。
String extractReadableResult(String raw) {
  final Map<String, dynamic>? parsed = tryDecodeMap(raw);
  if (parsed == null) return raw;
  for (final String key in <String>[
    'content',
    'output',
    'result',
    'message',
    'text',
  ]) {
    final dynamic value = parsed[key];
    if (value != null && value.toString().isNotEmpty) return value.toString();
  }
  final dynamic err = parsed['error'];
  if (err != null) return '错误: $err';
  return raw;
}

/// 把工具结果解析成 map（兼容 JSON 与 Python dict 字符串）
Map<String, dynamic>? tryDecodeMap(String raw) {
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
  } catch (_) {
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

/// 工具样式（图标 + 配色）。
///
/// 配色是"分类提示"而不是装饰：读取偏蓝、写入/编辑偏绿、命令偏灰、提问偏粉——
/// 一行行扫过去时靠颜色就能分出这一轮是在读、在改还是在跑命令。
class ToolStyle {
  final IconData icon;
  final Color color;

  const ToolStyle(this.icon, this.color);
}

const Color _blue = Color(0xFF2563EB);
const Color _green = Color(0xFF16A34A);
const Color _orange = Color(0xFFEA580C);
const Color _purple = Color(0xFF7C3AED);
const Color _teal = Color(0xFF0D9488);
const Color _pink = Color(0xFFDB2777);
const Color _grey = Color(0xFF64748B);

/// 按工具名返回定制样式（认不出来给通用扳手）
ToolStyle toolStyleOf(String name) {
  switch (name) {
    case 'help':
      return const ToolStyle(Icons.help_outline, _blue);
    case 'set':
      return const ToolStyle(Icons.tune, _orange);
    case 'refresh':
      return const ToolStyle(Icons.refresh, _green);
    case 'mcp':
      return const ToolStyle(Icons.extension, _purple);
    case 'team':
      return const ToolStyle(Icons.groups, _teal);
    case 'set_todo_list':
      return const ToolStyle(Icons.checklist, _teal);
    case 'ask_user_question':
      return const ToolStyle(Icons.question_answer, _pink);
    case 'read':
      return const ToolStyle(Icons.description_outlined, _blue);
    case 'grep':
      return const ToolStyle(Icons.manage_search, _teal);
    case 'write':
      return const ToolStyle(Icons.note_add_outlined, _green);
    case 'edit':
      return const ToolStyle(Icons.edit_outlined, _green);
    case 'terminal':
      return const ToolStyle(Icons.terminal, _grey);
    case 'embed_search':
      return const ToolStyle(Icons.search, _teal);
    default:
      return const ToolStyle(Icons.build_outlined, _grey);
  }
}

/// 工具详情的正文：参数表 + **完整**执行结果（右栏「详情」页用）。
///
/// 不在这里做高度截断：详情页整体可滚动，截断是"中栏一行 + 想细看"的路由要解决的
/// 问题，一个专门的详情页不该再把内容藏起来。
class ToolDetail extends StatelessWidget {
  const ToolDetail({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final ChatMessage m = message;
    final String name = m.toolName ?? '';
    final List<Widget> params = _buildParams(context, name, m.toolArguments);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (params.isNotEmpty) ...<Widget>[
          _sectionLabel(context, '调用参数'),
          const SizedBox(height: 6),
          ...params,
          const SizedBox(height: 16),
        ],
        _sectionLabel(context, '执行结果'),
        const SizedBox(height: 6),
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
          _buildResult(context, name, m.toolResult),
      ],
    );
  }

  /// 按工具类型构建参数展示（人类可读，非原始 JSON）
  List<Widget> _buildParams(
    BuildContext context,
    String name,
    Map<String, dynamic>? rawArgs,
  ) {
    final Map<String, dynamic> args = rawArgs ?? <String, dynamic>{};
    String arg(String key) => (args[key] ?? '').toString();
    switch (name) {
      case 'read':
        return <Widget>[_paramRow(context, '文件', arg('file_path'))];
      case 'write':
        final int length = arg('content').length;
        return <Widget>[
          _paramRow(context, '文件', arg('file_path')),
          _paramRow(context, '内容长度', '$length 字符'),
        ];
      case 'edit':
        // 键名与核心 edit schema 对齐（builtin_tools.dart:176-194）
        return <Widget>[
          _paramRow(context, '文件', arg('file_path')),
          _paramRow(context, '查找', _truncate(arg('old_text'), 400)),
          _paramRow(context, '替换', _truncate(arg('new_text'), 400)),
        ];
      case 'terminal':
        final String cmd = arg('cmd').isEmpty ? arg('command') : arg('cmd');
        return <Widget>[_paramRow(context, '命令', cmd)];
      case 'set':
        final String key = arg('key').isEmpty ? arg('param') : arg('key');
        return <Widget>[
          _paramRow(context, '参数', key),
          _paramRow(context, '值', arg('value')),
        ];
      case 'set_todo_list':
        final List<Widget> rows = <Widget>[
          _paramRow(context, '操作', arg('action')),
        ];
        final List<dynamic>? todos = args['todos'] as List<dynamic>?;
        if (todos != null && todos.isNotEmpty) {
          rows.add(_paramRow(context, '任务项数', todos.length.toString()));
        }
        if (arg('action') == 'update') {
          rows.add(_paramRow(context, '目标 id', arg('todo_id')));
        }
        return rows;
      case 'team':
        final List<Widget> rows = <Widget>[
          _paramRow(context, '操作', arg('action')),
        ];
        if (arg('member_id').isNotEmpty) {
          rows.add(_paramRow(context, '成员', arg('member_id')));
        }
        if (arg('description').isNotEmpty) {
          rows.add(_paramRow(context, '描述', _truncate(arg('description'), 400)));
        }
        return rows;
      case 'mcp':
        final String toolName =
            arg('tool_name').isEmpty ? arg('tool') : arg('tool_name');
        final Map<String, dynamic> nested =
            (args['arguments'] as Map<String, dynamic>?)?.cast<String, dynamic>() ??
                <String, dynamic>{};
        final List<Widget> rows = <Widget>[_paramRow(context, 'MCP 工具', toolName)];
        for (final MapEntry<String, dynamic> e in nested.entries) {
          rows.add(_paramRow(context, e.key, _truncate(e.value.toString(), 400)));
        }
        return rows;
      case 'ask_user_question':
        final List<Widget> rows = <Widget>[
          _paramRow(context, '问题', arg('question')),
        ];
        final List<dynamic>? options = args['options'] as List<dynamic>?;
        if (options != null && options.isNotEmpty) {
          rows.add(_paramRow(context, '选项', options.join(' / ')));
        }
        return rows;
      case 'embed_search':
        return <Widget>[_paramRow(context, '查询', arg('query'))];
      default:
        if (args.isEmpty) return <Widget>[];
        return args.entries
            .map((MapEntry<String, dynamic> e) =>
                _paramRow(context, e.key, _truncate(e.value.toString(), 400)))
            .toList();
    }
  }

  /// 按工具类型构建结果展示
  Widget _buildResult(BuildContext context, String name, String result) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    if (result.isEmpty) {
      return Text(
        '（无输出）',
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      );
    }

    // 待办清单：把 todos 渲染成 id + 内容 + 状态
    if (name == 'set_todo_list') {
      final List<dynamic>? todos =
          tryDecodeMap(result)?['todos'] as List<dynamic>?;
      if (todos != null && todos.isNotEmpty) {
        final List<Widget> rows = <Widget>[];
        for (final dynamic t in todos) {
          if (t is! Map<String, dynamic>) continue;
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
                    (t['id'] ?? '').toString(),
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'Consolas',
                      color: cs.primary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Expanded(
                  child: Text(
                    (t['content'] ?? '').toString(),
                    style: const TextStyle(fontSize: 12, height: 1.4),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '$status $progress',
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
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

    // 结果被重定向到工作空间：只留一句指向文件的提示
    if (result.startsWith('工具调用结果已保存到')) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.save_alt, size: 14, color: cs.primary),
          const SizedBox(width: 6),
          Expanded(
            child: SelectableText(
              result,
              style: TextStyle(fontSize: 12, color: cs.primary),
            ),
          ),
        ],
      );
    }

    final String display = extractReadableResult(result);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: SelectableText(
        display,
        style: const TextStyle(
          fontSize: 11.5,
          fontFamily: 'Consolas',
          fontFamilyFallback: <String>['Cascadia Mono', 'monospace'],
          height: 1.5,
        ),
      ),
    );
  }

  /// 参数行：标签 + 值
  Widget _paramRow(BuildContext context, String label, String value) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: SelectableText(
              value.isEmpty ? '-' : value,
              style: const TextStyle(fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';

  Widget _sectionLabel(BuildContext context, String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
