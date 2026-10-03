import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../io/api_service.dart';
import '../models/message.dart';
import '../services/code_highlight.dart';
import '../services/code_highlight_lines.dart';
import '../services/detail_selection.dart';
import '../services/subagent_transcript.dart';
import '../services/tool_change_view.dart';
import '../services/conversation_view.dart';
import 'subagent_process_list.dart';

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
              // 点一下选中、再点一下取消（见 DetailSelection.toggle）
        onTap: () => DetailSelection.instance.toggle(m),
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

/// 详情页里"内容 / diff"那几段的等宽样式（与源码视图同一套字体回退）。
const TextStyle _codeStyle = TextStyle(
  fontFamily: 'Consolas',
  fontFamilyFallback: <String>['Cascadia Mono', 'monospace'],
  fontSize: 11.5,
  height: 1.35,
);

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

/// 工具详情的正文：参数表 + **变更**（write 的内容 / edit 的 diff）+ **完整**执行结果
/// （右栏「详情」页用）。
///
/// 不在这里做高度截断：详情页整体可滚动，截断是"中栏一行 + 想细看"的路由要解决的
/// 问题，一个专门的详情页不该再把内容藏起来。
///
/// 「变更」这一段（用户 2026-10-04：「写入的具体内容呢？编辑做成 diff 的输出格式（最好带少量
/// 几行上下文方便用户阅读）」）：
/// - `write`：内容直接摊开（[buildWriteContent]，太长时截断并如实标注）；
/// - `edit`：**带上下文的变更块**（[buildEditDiff]）——`-` 旧行 / `+` 新行 / 无前缀是上下文，
///   上下文是去**当前磁盘内容**里按这次调用的 `new_text` 定位后取的（所以是"这次改动在文件里
///   长什么样"，不是把两段原文并排贴出来）；定位不到就如实说明并退回参数视图。
class ToolDetail extends StatefulWidget {
  const ToolDetail({
    super.key,
    required this.message,
    this.workspaceId = '',
    this.teamId = '',
  });

  final ChatMessage message;

  /// 工作空间 id / 团队 id：`edit` 要读一次当前文件才能给出带上下文的 diff。
  /// 空 = 不去读（直接走参数视图；测试与无上下文场景用）。
  final String workspaceId;
  final String teamId;

  @override
  State<ToolDetail> createState() => _ToolDetailState();
}

class _ToolDetailState extends State<ToolDetail> {
  /// 当前磁盘内容（只有 `edit` 会去读；null = 没读 / 还没读完）。
  String? _fileText;

  /// 正在读文件。
  bool _loading = false;

  /// 读不到文件的可读原因（读失败才非空）。
  String? _loadError;

  String get _name => widget.message.toolName ?? '';

  @override
  void initState() {
    super.initState();
    unawaited(_loadFileForDiff());
  }

  @override
  void didUpdateWidget(covariant ToolDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 详情页跟着中栏的选中项走：换了一条（或同一条从"执行中"变成"完成"）就重算
    if (oldWidget.message.id != widget.message.id) {
      _fileText = null;
      _loadError = null;
      unawaited(_loadFileForDiff());
    }
  }

  /// `edit`：读一次当前文件内容，好把这次替换放回上下文里显示。
  Future<void> _loadFileForDiff() async {
    if (_name != 'edit') return;
    final Map<String, dynamic> args = widget.message.toolArguments ?? const <String, dynamic>{};
    final String path = (args['file_path'] ?? '').toString();
    if (widget.workspaceId.isEmpty || path.isEmpty) return;
    setState(() => _loading = true);
    try {
      final String text = await ApiService.getFileContent(
        widget.workspaceId,
        path,
        teamId: widget.teamId,
      );
      if (!mounted) return;
      setState(() {
        _fileText = text;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = '读不到这个文件（可能已改名 / 删除，或工作空间不可用）：$error';
        _loading = false;
      });
    }
  }

  /// 这次 `edit` 的变更块（拿不到就是 null：读不到、定位不到、或不是 edit）。
  ToolDiffHunk? _hunk() {
    if (_name != 'edit' || _fileText == null) return null;
    final Map<String, dynamic> args = widget.message.toolArguments ?? const <String, dynamic>{};
    return buildEditDiff(
      fileText: _fileText!,
      oldText: (args['old_text'] ?? '').toString(),
      newText: (args['new_text'] ?? '').toString(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final ChatMessage m = widget.message;
    final String name = _name;
    final ToolDiffHunk? fileHunk = _hunk();
    // 翻历史：文件之后又被改过 ⇒ 读出来的当前内容里定位不到，退回"只用调用参数"的退化变更块
    ToolDiffHunk? argsHunk;
    if (name == 'edit' && fileHunk == null && !_loading) {
      final Map<String, dynamic> args =
          m.toolArguments ?? const <String, dynamic>{};
      argsHunk = buildEditDiffFromArgs(
        oldText: (args['old_text'] ?? '').toString(),
        newText: (args['new_text'] ?? '').toString(),
      );
    }
    final bool hasChange = fileHunk != null || argsHunk != null;
    final List<Widget> params = _buildParams(
      context,
      name,
      m.toolArguments,
      hasDiff: hasChange,
    );
    final Widget? change = _buildChange(context, name, fileHunk, argsHunk);
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
        if (change != null) ...<Widget>[
          _sectionLabel(context, '变更'),
          const SizedBox(height: 6),
          change,
          const SizedBox(height: 16),
        ],
        // 临时员工：它的过程**不进主消息流**，就在这里看（用户 2026-10-04：
        // 「subagent 的工具调用就在 subagent 的调用工具详情里看」）
        if (name == 'subagent') ...<Widget>[
          _sectionLabel(context, '这次调用召来的临时员工'),
          const SizedBox(height: 6),
          ListenableBuilder(
            listenable: SubagentTranscript.instance,
            builder: (BuildContext context, Widget? child) =>
                _buildSubagentTranscript(context, m),
          ),
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
    Map<String, dynamic>? rawArgs, {
    bool hasDiff = false,
  }) {
    final Map<String, dynamic> args = rawArgs ?? <String, dynamic>{};
    String arg(String key) => (args[key] ?? '').toString();
    switch (name) {
      case 'read':
        return <Widget>[_paramRow(context, '文件', arg('file_path'))];
      case 'write':
        // 内容本身在「变更」一段里摊开了，这里只留文件与体量摘要
        return <Widget>[
          _paramRow(context, '文件', arg('file_path')),
          _paramRow(context, '内容长度', '${arg('content').length} 字符'),
        ];
      case 'edit':
        // 键名与核心 edit schema 对齐（builtin_tools.dart:176-194）。
        // 有变更块时**不再并列「查找 / 替换」两段原文**（那是"两段碎片"，读不出它在文件哪儿）；
        // 定位不到（文件后来又被改过 / 读不到）才退回这两行，并如实说明。
        if (hasDiff) {
          return <Widget>[_paramRow(context, '文件', arg('file_path'))];
        }
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
      case 'subagent':
        // 详情里**不截断** `task`（用户 2026-10-03：「subagent 的工具调用详情的 task 过长会打省略号
        // （在现在的右侧查看详情的设计下，没必要省略了）」）：右侧详情视图本来就是"看全文"的地方，
        // `_paramRow` 用 `SelectableText` 会自己换行，长任务（含换行/分点的那种）能读全。
        // 折叠态的**摘要行**仍是另一回事：它靠整行省略号收尾（见 :219 一带的注释），不改。
        final List<Widget> rows = <Widget>[
          _paramRow(context, '任务', arg('task')),
        ];
        if (arg('subagent_id').isNotEmpty) {
          rows.add(_paramRow(context, '复用', arg('subagent_id')));
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

  // ── 临时员工（subagent）：这次调用召来的员工干了什么 ─────────────────

  /// 这条 `subagent` 调用对应的**临时员工过程**（它自己的文本 / 思考 / 工具调用）。
  ///
  /// 这些消息带着 `subagent_id` 混在会话流里，但**中栏不显示它们**（不跟主 agent 混）；
  /// 这里按 id 取出来（[SubagentTranscript]），按发生顺序摊开——点其中一个工具行会切到
  /// 那条工具自己的详情（drill-down），回主视角点中栏那一行即可。
  Widget _buildSubagentTranscript(BuildContext context, ChatMessage call) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Map<String, dynamic> args =
        call.toolArguments ?? const <String, dynamic>{};
    final String? id = _resolveSubagentId(call, args);
    if (id == null) {
      return Text(
        '没找到它的过程记录：这次调用可能还没跑完（后台运行时报告会随后回来），'
        '或者这条历史来自旧版本（那时过程消息不带标记）。',
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.4),
      );
    }
    final List<ChatMessage> transcript = SubagentTranscript.instance.of(id);
    if (transcript.isEmpty) {
      return Text(
        '还没有收到它的过程消息（正在跑或已结束但只有报告）。',
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
      );
    }
    final ChatMessage first = transcript.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(Icons.person_outline, size: 13, color: cs.onSurfaceVariant),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                '临时员工「${first.subagentName.isEmpty ? '未命名' : first.subagentName}」 · '
                '第 ${first.subagentLevel} 层 · ${transcript.length} 条过程（它是这次调用召来的）',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (subagentUsageLine(transcript) != null) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            subagentUsageLine(transcript)!,
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 8),
        // 与"临时员工工作进度页"共用同一份过程渲染（不重复实现）
        SubagentProcessList(
          messages: transcript,
          emptyHint: '还没有收到它的过程消息（正在跑或已结束但只有报告）。',
        ),
      ],
    );
  }

  /// 这条调用对应哪个临时员工：优先从**工具结果**里那个 `id=sub_…` 认（核心在结果头里回传），
  /// 认不出来再按 `name` 在已有过程里唯一匹配；都不行返回 null（界面如实说明）。
  String? _resolveSubagentId(ChatMessage call, Map<String, dynamic> args) {
    final RegExp match = RegExp(r'id=(sub_[A-Za-z0-9_]+)');
    final RegExpMatch? found = match.firstMatch(call.toolResult);
    if (found != null) return found.group(1);
    final String name = (args['name'] ?? '').toString().trim();
    if (name.isEmpty) return null;
    final List<String> hits = SubagentTranscript.instance.ids
        .where(
          (String id) =>
              SubagentTranscript.instance.of(id).first.subagentName == name,
        )
        .toList(growable: false);
    return hits.length == 1 ? hits.single : null;
  }

  // ── 「变更」一段：write 的内容 / edit 的带上下文 diff ─────────────────

  /// 按工具类型决定要不要给「变更」一段（返回 null = 这个工具没有变更可看）。
  Widget? _buildChange(
    BuildContext context,
    String name,
    ToolDiffHunk? fileHunk,
    ToolDiffHunk? argsHunk,
  ) {
    final Map<String, dynamic> args =
        widget.message.toolArguments ?? const <String, dynamic>{};
    final String path = (args['file_path'] ?? '').toString();
    if (name == 'write') {
      final String content = (args['content'] ?? '').toString();
      if (content.isEmpty) return null;
      return _buildWriteBlock(context, buildWriteContent(content), path);
    }
    if (name != 'edit') return null;
    if (_loading) {
      return Row(
        children: <Widget>[
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text(
            '正在读文件，准备带上下文的变更块…',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }
    if (fileHunk != null) return _buildDiffBlock(context, fileHunk, path);
    // 翻历史（文件之后又被改过 ⇒ 定位不到）时**也不能什么都不给**：退回"只用调用参数"的
    // 退化变更块（- 旧 / + 新，没有上下文），并如实标注——用户 2026-10-04：
    // 「翻历史的 edit 怎么全都找不到原始变更」。
    final String reason = _loadError ??
        '这份改动已不在当前文件里（之后又被改过）：上下文不可得，下面只按调用参数给出这次替换。';
    if (argsHunk == null) {
      return Text(
        reason,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          reason,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        _buildDiffBlock(context, argsHunk, path),
      ],
    );
  }

  /// write：把写进去的内容摊开（**按源码着色**；太长时截断并如实标注）。
  Widget _buildWriteBlock(
    BuildContext context,
    WriteContentView view,
    String path,
  ) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String note = view.truncated
        ? '（太长，下面只显示前面一段；全文去右栏「文件」页打开）'
        : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '${view.totalLines} 行 · ${view.totalChars} 字符$note',
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        _codeContainer(
          context,
          SelectableText.rich(
            // 与源码视图同一套着色（同一门语言表、同一份配色）
            buildCodeTextSpan(
              text: view.text,
              language: languageForPath(path),
              theme: CodeTheme.of(context),
              baseStyle: _codeStyle,
            ),
          ),
        ),
      ],
    );
  }

  /// edit：带上下文的变更块（`-` 旧 / `+` 新 / 无前缀是上下文），**按源码着色**。
  ///
  /// 着色来自**整段**源码的词法结果（[codeColorRuns]）再按行切片：块注释与多行字符串是
  /// 跨行的，逐行着色会在第二行起就掉色（用户 2026-10-04：「为什么没按源码渲染」）。
  Widget _buildDiffBlock(
    BuildContext context,
    ToolDiffHunk hunk,
    String path,
  ) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final CodeLanguage language = languageForPath(path);
    final CodeTheme theme = CodeTheme.of(context);
    final List<CodeColorRun> fileRuns = codeColorRuns(
      text: hunk.fileText,
      language: language,
      theme: theme,
    );
    final List<CodeColorRun> beforeRuns = codeColorRuns(
      text: hunk.beforeText,
      language: language,
      theme: theme,
    );
    final String note = hunk.truncated ? ' · 只显示前 ${hunk.lines.length} 行' : '';
    final String head = hunk.hasContext
        ? '${hunk.header}$note'
        : '这次替换（无上下文：文件之后又被改过，当时的上下文没有存下来）';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          head,
          style: TextStyle(
            fontSize: 11,
            color: cs.onSurfaceVariant,
            fontFamily: 'monospace',
          ),
        ),
        const SizedBox(height: 4),
        _codeContainer(
          context,
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final ToolDiffLine line in hunk.lines)
                _buildDiffRow(context, line, hunk, fileRuns, beforeRuns),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          hunk.hasContext
              ? '- ${hunk.removedCount} 行 · + ${hunk.addedCount} 行（上下文取自磁盘当前内容）'
              : '- ${hunk.removedCount} 行 · + ${hunk.addedCount} 行（来自这次调用的参数）',
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
        ),
      ],
    );
  }

  /// diff 的一行：行首 marker + **按源码着色**的正文；旧行红底、新行绿底、上下文跟随主题。
  Widget _buildDiffRow(
    BuildContext context,
    ToolDiffLine line,
    ToolDiffHunk hunk,
    List<CodeColorRun> fileRuns,
    List<CodeColorRun> beforeRuns,
  ) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final (Color fg, Color? bg) = switch (line.kind) {
      ToolDiffKind.removed => (
        const Color(0xFFE05252),
        const Color(0x14E05252),
      ),
      ToolDiffKind.added => (
        const Color(0xFF3FB950),
        const Color(0x143FB950),
      ),
      ToolDiffKind.context => (cs.onSurfaceVariant, null),
    };
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 10,
            child: Text(
              line.marker,
              style: _codeStyle.copyWith(color: fg),
            ),
          ),
          Expanded(
            child: line.sourceStart < 0 || line.sourceEnd < 0
                ? SelectableText(
                    line.text.isEmpty ? ' ' : line.text,
                    style: _codeStyle.copyWith(color: fg),
                  )
                : SelectableText.rich(
                    // 着色来自整段词法结果、按这一行的区间切片（块注释 / 多行字符串不断色）
                    codeSpanForRange(
                      text: line.kind == ToolDiffKind.removed
                          ? hunk.beforeText
                          : hunk.fileText,
                      runs: line.kind == ToolDiffKind.removed
                          ? beforeRuns
                          : fileRuns,
                      start: line.sourceStart,
                      end: line.sourceEnd,
                      // 基础色 = 该行的语义色（红 / 绿 / 灰），记号色覆盖在它上面
                      baseStyle: _codeStyle.copyWith(color: fg),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// 等宽内容块（write 的内容 / edit 的 diff 共用一层皮）
  Widget _codeContainer(BuildContext context, Widget child) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLowest,
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: child,
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
