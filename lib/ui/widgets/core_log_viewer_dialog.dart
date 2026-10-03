import 'package:flutter/material.dart';

import '../../app_version.dart';
import '../services/core_log_files.dart';

/// 「看最近 N 行核心日志」弹窗（设置页「核心日志」卡片调起）。
///
/// 范式与既有只读弹窗一致：一个固定尺寸的只读文本区 + 「刷新」「打开日志目录」
/// 「关闭」。刻意**不做**实时跟随（tail -f）：日志是事后取证用的，自动滚动反而
/// 让人看不清；要看新的按「刷新」即可。
Future<void> showCoreLogDialog(
  BuildContext context, {
  required String logFile,
  int lines = CoreLogFiles.defaultLines,
}) => showDialog<void>(
  context: context,
  builder: (BuildContext context) =>
      CoreLogViewerDialog(logFile: logFile, lines: lines),
);

/// 核心日志查看弹窗。
class CoreLogViewerDialog extends StatefulWidget {
  const CoreLogViewerDialog({
    super.key,
    required this.logFile,
    this.lines = CoreLogFiles.defaultLines,
  });

  /// 要读的日志文件（`<数据根>/logs/core.log`）。
  final String logFile;

  /// 读取行数上限（只读尾部）。
  final int lines;

  @override
  State<CoreLogViewerDialog> createState() => _CoreLogViewerDialogState();
}

class _CoreLogViewerDialogState extends State<CoreLogViewerDialog> {
  final ScrollController _scroll = ScrollController();

  bool _loading = true;

  /// 尾部日志文本；文件不存在时为 null（另一种可读状态，不是错误）。
  String? _text;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final String? text = await CoreLogFiles.readTail(
        widget.logFile,
        lines: widget.lines,
      );
      if (!mounted) return;
      setState(() {
        _text = text;
        _loading = false;
      });
      _scrollToBottom();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '读取核心日志失败：$error';
        _loading = false;
      });
    }
  }

  /// 读完跳到末尾：用户要看的几乎总是**最后**发生的事。
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _openLogDir() async {
    final String? error = await PluginDocs.openPath(
      CoreLogFiles.logDirOf(widget.logFile),
    );
    if (!mounted || error == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error), duration: const Duration(seconds: 4)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Row(
        children: <Widget>[
          const Expanded(child: Text('核心日志（最近 N 行）')),
          TextButton.icon(
            key: const Key('core-log-refresh'),
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('刷新'),
          ),
        ],
      ),
      content: SizedBox(
        width: 820,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SelectableText(
              widget.logFile,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            Expanded(child: _buildBody(cs)),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton.icon(
          key: const Key('core-log-dialog-open-dir'),
          onPressed: _openLogDir,
          icon: const Icon(Icons.folder_open_outlined, size: 16),
          label: const Text('打开日志目录'),
        ),
        TextButton(
          key: const Key('core-log-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  Widget _buildBody(ColorScheme cs) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final String? error = _error;
    if (error != null) {
      return SelectableText(error, style: const TextStyle(fontSize: 12));
    }
    final String? text = _text;
    if (text == null) {
      // 文件还不存在：给原因，不给空框（核心刚启动时是常态）
      return SingleChildScrollView(
        child: SelectableText(
          CoreLogFiles.missingReason(widget.logFile),
          style: const TextStyle(fontSize: 12),
        ),
      );
    }
    if (text.trim().isEmpty) {
      return const Text('日志文件是空的（核心还没有写过一行）');
    }
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(4),
      ),
      padding: const EdgeInsets.all(8),
      child: Scrollbar(
        controller: _scroll,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _scroll,
          child: SelectableText(
            text,
            style: const TextStyle(
              fontSize: 12,
              height: 1.35,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ),
    );
  }
}
