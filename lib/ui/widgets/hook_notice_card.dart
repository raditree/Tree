import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/message.dart';

/// 「后台任务（terminal hook）完成」提示的**专用渲染**。
///
/// 为什么单独一张卡片：这类提示是核心注入的"系统发言"（`kind == 'notice'`），
/// 正文形态固定为：
/// ```
/// [terminal hook] 后台命令已结束：<命令>
/// task_id: <id>｜退出码 0
/// 日志文件：.output/xxx.log（用 read 查看完整输出）
/// --- 日志尾部 ---
/// <日志尾巴，含 hook 写的「结束：退出码 0，耗时 36s」>
/// ```
/// 当普通消息渲染就是"一大坨等宽文本"：哪条命令、成功没成功、最后一行说了什么，
/// 全埋在中间；长命令还会把气泡撑成一屏。这里拆成三层：
/// **状态头（成功/失败/已取消 + 命令）+ 一行日志摘要**（默认折叠）
/// **+ 可展开的日志尾部**（要看细节再展开）。
///
/// 兼容性：解析不出 hook 形态时（核心换了文案、或别的系统提示用了 `notice`）
/// 退化成"原文 + 复制"，**不会**丢信息。
class HookNoticeCard extends StatefulWidget {
  const HookNoticeCard({super.key, required this.message});

  final ChatMessage message;

  @override
  State<HookNoticeCard> createState() => _HookNoticeCardState();
}

class _HookNoticeCardState extends State<HookNoticeCard> {
  bool _expanded = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.message.content));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制全文'), duration: Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final HookNotice notice = parseHookNotice(widget.message.content);

    // 解析不出 hook 形态：老实显示原文（带复制），别把信息吃掉
    if (!notice.finished) {
      return _shell(
        accent: cs.outline,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.terminal, size: 14, color: cs.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '系统提示',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ),
                _copyButton(cs),
              ],
            ),
            const SizedBox(height: 6),
            _mono(widget.message.content, cs, maxLines: 12),
          ],
        ),
      );
    }

    final bool ok = notice.exitCode == null || notice.exitCode == 0;
    final Color accent = notice.cancelled
        ? cs.outline
        : (ok ? cs.primary : cs.error);
    final IconData icon = notice.cancelled
        ? Icons.cancel_outlined
        : (ok ? Icons.task_alt : Icons.error_outline);
    final String title = notice.cancelled
        ? '后台任务已取消'
        : (ok ? '后台任务已完成' : '后台任务失败');

    return _shell(
      accent: accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // 状态头（点击整行展开/折叠）
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Row(
              children: <Widget>[
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(icon, size: 15, color: accent),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        notice.exitCode == null
                            ? title
                            : '$title（退出码 ${notice.exitCode}）',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        notice.command,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: cs.outline,
                ),
              ],
            ),
          ),
          // 折叠态：只给一行摘要（通常是 hook 写的"结束：退出码 …，耗时 …s"）
          if (!_expanded)
            Padding(
              padding: const EdgeInsets.only(left: 36, top: 6),
              child: Text(
                notice.summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          // 展开态：命令全文 + 日志尾部 + task_id/日志路径
          if (_expanded) ...<Widget>[
            const SizedBox(height: 8),
            _label('命令', cs, trailing: _copyButton(cs)),
            const SizedBox(height: 4),
            _mono(notice.command, cs, maxLines: 6),
            if (notice.tail.trim().isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              _label('日志尾部', cs),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: SingleChildScrollView(child: _mono(notice.tail, cs)),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 2,
              children: <Widget>[
                if (notice.taskId.isNotEmpty)
                  _meta('task_id: ${notice.taskId}', cs),
                if (notice.logPath.isNotEmpty)
                  _meta('日志：${notice.logPath}', cs),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 卡片外壳（统一边框/圆角/最大宽度，与思考卡片同口径）。
  Widget _shell({required Color accent, required Widget child}) => Align(
    alignment: Alignment.centerLeft,
    child: Container(
      constraints: const BoxConstraints(maxWidth: 560),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accent.withValues(alpha: 0.35)),
      ),
      child: child,
    ),
  );

  Widget _label(String text, ColorScheme cs, {Widget? trailing}) => Row(
    children: <Widget>[
      Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: cs.onSurfaceVariant,
        ),
      ),
      if (trailing != null) ...<Widget>[const Spacer(), trailing],
    ],
  );

  Widget _meta(String text, ColorScheme cs) =>
      Text(text, style: TextStyle(fontSize: 11, color: cs.outline));

  Widget _copyButton(ColorScheme cs) => InkWell(
    onTap: _copy,
    borderRadius: BorderRadius.circular(4),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.copy, size: 12, color: cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            '复制',
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    ),
  );

  /// 等宽只读文本块（日志/命令都是机器输出，等宽更好读）。
  Widget _mono(String text, ColorScheme cs, {int maxLines = 0}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    decoration: BoxDecoration(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
    ),
    child: SelectableText(
      text,
      maxLines: maxLines > 0 ? maxLines : null,
      style: const TextStyle(
        fontSize: 11,
        fontFamily: 'monospace',
        height: 1.35,
      ),
    ),
  );
}

/// hook 提示的解析结果（纯数据，便于单测）。
class HookNotice {
  const HookNotice({
    required this.raw,
    required this.finished,
    this.command = '',
    this.taskId = '',
    this.exitCode,
    this.cancelled = false,
    this.logPath = '',
    this.tail = '',
  });

  /// 原始正文。
  final String raw;

  /// 是否识别成「后台命令已结束」形态。
  final bool finished;

  /// 完整命令行（含参数）。
  final String command;

  /// 后台任务 id（可点击 `hook_action=status/cancel` 用）。
  final String taskId;

  /// 退出码（解析不出为 null）。
  final int? exitCode;

  /// 是否被取消（hook 文案里的「（已取消）」）。
  final bool cancelled;

  /// 日志文件（工作空间相对路径）。
  final String logPath;

  /// 日志尾部正文（没有则为空串）。
  final String tail;

  /// 折叠态摘要：日志尾部最后一行非空内容；没有日志时退回命令行。
  String get summary {
    for (final String line in tail.split('\n').reversed) {
      final String trimmed = line.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return command;
  }
}

/// `[terminal hook] 后台命令已结束：<命令>`
final RegExp _hookHead = RegExp(r'^\[terminal hook\]\s*后台命令已结束[：:]\s*(.*)$');
final RegExp _tailMarker = RegExp(r'^-+\s*日志尾部\s*-+$');
final RegExp _exitCode = RegExp(r'退出码\s*(-?\d+)');
final RegExp _logLine = RegExp(r'^日志(?:文件)?[：:]\s*(.+)$');

/// 解析 hook 提示正文（宽容：任何一行不认就继续往下看，绝不抛）。
HookNotice parseHookNotice(String content) {
  final StringBuffer tail = StringBuffer();
  String command = '';
  String taskId = '';
  String logPath = '';
  int? exitCode;
  bool cancelled = false;
  bool finished = false;
  bool inTail = false;

  for (final String rawLine in content.split('\n')) {
    final String line = rawLine.replaceAll('\r', '');
    if (inTail) {
      tail.writeln(line);
      continue;
    }
    if (_tailMarker.hasMatch(line.trim())) {
      inTail = true;
      continue;
    }
    final RegExpMatch? head = _hookHead.firstMatch(line);
    if (head != null) {
      finished = true;
      command = (head.group(1) ?? '').trim();
      continue;
    }
    if (line.startsWith('task_id:')) {
      final String rest = line.substring('task_id:'.length);
      // 形如 `<id>｜退出码 0（已取消）`：id 取分隔符前，退出码/取消状态从整行里抓
      taskId = rest.split(RegExp('[｜|]')).first.trim();
      exitCode = int.tryParse(_exitCode.firstMatch(rest)?.group(1) ?? '');
      cancelled = rest.contains('已取消');
      continue;
    }
    final RegExpMatch? log = _logLine.firstMatch(line);
    if (log != null) {
      // 去掉「（用 read 查看完整输出）」这类说明，只留路径
      String value = log.group(1)!.trim();
      final int paren = value.indexOf('（');
      if (paren > 0) value = value.substring(0, paren).trim();
      logPath = value;
      continue;
    }
  }

  return HookNotice(
    raw: content,
    finished: finished,
    command: command,
    taskId: taskId,
    exitCode: exitCode,
    cancelled: cancelled,
    logPath: logPath,
    tail: tail.toString().trimRight(),
  );
}
