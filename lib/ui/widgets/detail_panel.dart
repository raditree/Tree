import 'package:flutter/material.dart';

import '../models/message.dart';
import '../services/detail_selection.dart';
import 'thinking_card.dart';
import 'tool_call_card.dart';

/// 右栏「详情」页：把中栏点到的那条工具调用 / 思考**完整**摊开。
///
/// 为什么单开一页而不是在中栏就地展开：中栏是"读消息"的地方，就地展开会把时间线
/// 顶散；右栏本来就是详情区（文件 / MCP 配置 / 模型信息 / 问题回复），完整内容放
/// 这里既不打断阅读，又能跟消息流并排对照着看。
class DetailPanel extends StatelessWidget {
  const DetailPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: DetailSelection.instance,
      builder: (BuildContext context, Widget? child) {
        final ChatMessage? message = DetailSelection.instance.message;
        if (message == null) return _buildEmpty(cs);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _buildHeader(cs, message),
            Divider(height: 1, color: Theme.of(context).dividerColor),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                child: _buildBody(message),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildBody(ChatMessage message) {
    switch (message.kind) {
      case 'tool':
        return ToolDetail(message: message);
      case 'thinking':
        return ThinkingDetail(message: message);
      default:
        return SelectableText(
          message.content,
          style: const TextStyle(fontSize: 13, height: 1.6),
        );
    }
  }

  /// 头部：类型图标 + 中文标题 + 时间 + 关闭
  Widget _buildHeader(ColorScheme cs, ChatMessage message) {
    final bool isTool = message.kind == 'tool';
    final ToolStyle style = toolStyleOf(message.toolName ?? '');
    final String title = isTool ? toolLabel(message.toolName ?? '') : '思考';
    final String time = _formatTime(message.timestamp);
    final String subtitle = !isTool
        ? time
        : (message.toolRunning ? '执行中 · $time' : '完成 · $time');
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      child: Row(
        children: <Widget>[
          Icon(
            isTool ? style.icon : Icons.psychology_outlined,
            size: 16,
            color: isTool ? style.color : cs.tertiary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '关闭详情',
            icon: const Icon(Icons.close, size: 16),
            color: cs.onSurfaceVariant,
            onPressed: DetailSelection.instance.clear,
          ),
        ],
      ),
    );
  }

  /// 空态：告诉用户这一页怎么用（不然一片空白像个坏掉的页签）
  Widget _buildEmpty(ColorScheme cs) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.ads_click, size: 26, color: cs.outline),
            const SizedBox(height: 10),
            Text(
              '点中栏的工具调用或思考',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            Text(
              '完整参数与结果会显示在这里',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: cs.outline),
            ),
          ],
        ),
      ),
    );
  }

  /// 时间戳（MM-dd HH:mm）
  String _formatTime(DateTime t) {
    final String mm = t.month.toString().padLeft(2, '0');
    final String dd = t.day.toString().padLeft(2, '0');
    final String hh = t.hour.toString().padLeft(2, '0');
    final String mi = t.minute.toString().padLeft(2, '0');
    return '$mm-$dd $hh:$mi';
  }
}
