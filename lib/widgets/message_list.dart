import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../models/message.dart';

/// 消息列表组件（StatelessWidget）
///
/// 渲染中栏消息列表。用户消息右对齐（蓝色气泡），agent 消息左对齐
/// （白色气泡 + 灰色边框）。流式消息在内容末尾显示闪烁光标。
/// 附件以卡片形式展示。消息更新时自动滚动到底部。
///
/// 内部通过私有 StatefulWidget [_MessageListView] 管理滚动控制器，
/// 以实现自动滚动；通过 [_MessageBubble] 管理光标闪烁定时器。
class MessageList extends StatelessWidget {
  /// 待渲染的消息列表
  final List<ChatMessage> messages;

  /// 消息版本号：每次消息列表发生结构性变化（新增/清空重载）时递增，
  /// 用于触发滚动到底部。由于 [messages] 是同一个可变列表引用，
  /// 无法通过长度/引用比较检测变化，故使用版本号信号。
  final int revision;

  const MessageList({
    super.key,
    required this.messages,
    this.revision = 0,
  });

  @override
  Widget build(BuildContext context) {
    return _MessageListView(messages: messages, revision: revision);
  }
}

/// 内部带滚动控制的状态视图
///
/// 维护 [ScrollController]，在 [revision] 变化时自动滚动到底部
/// （覆盖新增消息、切换 agent 重载历史、流式追加等场景）。
class _MessageListView extends StatefulWidget {
  final List<ChatMessage> messages;
  final int revision;

  const _MessageListView({required this.messages, this.revision = 0});

  @override
  State<_MessageListView> createState() => _MessageListViewState();
}

class _MessageListViewState extends State<_MessageListView> {
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  void didUpdateWidget(covariant _MessageListView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 版本号变化（新增消息/切换 agent 重载历史/流式追加）时滚动到底部
    if (oldWidget.revision != widget.revision) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  /// 滚动到底部
  void _scrollToBottom() {
    if (!_controller.hasClients) return;
    _controller.animateTo(
      _controller.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.messages.isEmpty) {
      return Center(
        child: Text(
          '暂无消息',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 14,
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _controller,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: widget.messages.length,
      itemBuilder: (BuildContext context, int index) {
        final ChatMessage message = widget.messages[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _MessageBubble(message: message),
        );
      },
    );
  }
}

/// 单条消息气泡
///
/// 用户消息：右对齐，蓝色背景（#2563EB），白色文字。
/// agent 消息：左对齐，白色背景，黑色文字，灰色边框。
/// 流式消息在内容末尾追加闪烁光标（"|" 与空格每 500ms 交替）。
/// 附件以小卡片形式展示在内容上方，含文件图标、文件名与大小。
class _MessageBubble extends StatefulWidget {
  final ChatMessage message;

  const _MessageBubble({required this.message});

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble> {
  /// 光标闪烁定时器
  Timer? _timer;

  /// 当前是否显示光标（"|" 与空格交替）
  bool _showCursor = true;

  /// 气泡圆角
  static const double _radius = 12;

  @override
  void initState() {
    super.initState();
    if (widget.message.isStreaming) {
      _startBlinking();
    }
  }

  @override
  void didUpdateWidget(covariant _MessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.message.isStreaming && !oldWidget.message.isStreaming) {
      _startBlinking();
    } else if (!widget.message.isStreaming &&
        oldWidget.message.isStreaming) {
      _stopBlinking();
    }
  }

  /// 启动光标闪烁（每 500ms 切换一次）
  void _startBlinking() {
    _stopBlinking();
    _timer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) {
        if (mounted) {
          setState(() {
            _showCursor = !_showCursor;
          });
        }
      },
    );
  }

  /// 停止光标闪烁
  void _stopBlinking() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stopBlinking();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ChatMessage message = widget.message;
    final bool isUser = message.isUser;
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 气泡最大宽度为父容器 70%
        final double maxBubbleWidth = constraints.maxWidth * 0.7;
        return Align(
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxBubbleWidth),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              decoration: BoxDecoration(
                color: isUser ? cs.primary : cs.surface,
                borderRadius: BorderRadius.circular(_radius),
                border: isUser
                    ? null
                    : Border.all(color: Theme.of(context).dividerColor),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.attachments != null &&
                      message.attachments!.isNotEmpty) ...<Widget>[
                    _buildAttachments(isUser),
                    const SizedBox(height: 6),
                  ],
                  _buildContent(message, isUser),
                  if (message.usage != null) ...[
                    const SizedBox(height: 4),
                    _buildUsage(message.usage!, isUser),
                  ],
                  const SizedBox(height: 4),
                  _buildTime(message, isUser),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 构建消息内容（流式时追加闪烁光标）
  Widget _buildContent(ChatMessage message, bool isUser) {
    final Color textColor =
        isUser ? Colors.white : Theme.of(context).colorScheme.onSurface;
    final String text = message.content;
    // 流式但尚无内容：仅显示闪烁光标
    if (message.isStreaming && text.isEmpty) {
      return Text(
        _showCursor ? '|' : ' ',
        style: TextStyle(
          color: textColor,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    if (message.isStreaming) {
      return RichText(
        text: TextSpan(
          children: <InlineSpan>[
            TextSpan(
              text: text,
              style: TextStyle(color: textColor, fontSize: 14, height: 1.4),
            ),
            TextSpan(
              text: _showCursor ? '|' : ' ',
              style: TextStyle(
                color: textColor,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }
    // 用户消息保持纯文本（可选中复制）
    if (isUser) {
      return SelectableText(
        text,
        style: TextStyle(color: textColor, fontSize: 14, height: 1.4),
      );
    }
    // agent 消息渲染 markdown（模型输出默认 markdown 格式）
    return MarkdownBody(
      data: text,
      selectable: true,
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)),
    );
  }

  /// 构建 token 用量统计（单位 k token），如 `1.2k / 64k`
  Widget _buildUsage(Map<String, dynamic> usage, bool isUser) {
    final int total = (usage['total_tokens'] as num?)?.toInt() ?? 0;
    final int maxTokens = (usage['max_tokens'] as num?)?.toInt() ?? 0;
    final Color color = isUser
        ? Colors.white60
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return Align(
      alignment: Alignment.centerRight,
      child: Text(
        '${_formatK(total)} / ${_formatK(maxTokens)}',
        style: TextStyle(fontSize: 10, color: color),
      ),
    );
  }

  /// 将 token 数格式化为 k 单位：`1234` -> `1.2k`，`65536` -> `64k`
  String _formatK(int value) {
    if (value <= 0) return '0k';
    final double k = value / 1000;
    return k >= 100 ? '${k.round()}k' : '${k.toStringAsFixed(1)}k';
  }

  /// 构建时间戳（小号灰色文字）
  Widget _buildTime(ChatMessage message, bool isUser) {
    final String hour =
        message.timestamp.hour.toString().padLeft(2, '0');
    final String minute =
        message.timestamp.minute.toString().padLeft(2, '0');
    final Color color = isUser
        ? Colors.white70
        : Theme.of(context).colorScheme.outline;
    return Text(
      '$hour:$minute',
      style: TextStyle(fontSize: 11, color: color),
    );
  }

  /// 构建附件卡片列表
  Widget _buildAttachments(bool isUser) {
    final List<Attachment> attachments = widget.message.attachments!;
    final cs = Theme.of(context).colorScheme;
    final Color textColor = isUser ? Colors.white : cs.onSurface;
    final Color subColor = isUser ? Colors.white70 : cs.onSurfaceVariant;
    final Color borderColor =
        isUser ? Colors.white24 : Theme.of(context).dividerColor;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: attachments.map((Attachment a) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: isUser ? Colors.white10 : cs.surface,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.insert_drive_file, size: 16, color: subColor),
              const SizedBox(width: 6),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      a.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: textColor,
                      ),
                    ),
                    Text(
                      _formatSize(a.size),
                      style: TextStyle(fontSize: 10, color: subColor),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  /// 格式化文件大小
  String _formatSize(int bytes) {
    if (bytes <= 0) return '';
    const List<String> units = <String>['B', 'KB', 'MB', 'GB'];
    double size = bytes.toDouble();
    int unitIdx = 0;
    while (size >= 1024 && unitIdx < units.length - 1) {
      size /= 1024;
      unitIdx++;
    }
    return '${size.toStringAsFixed(size >= 10 ? 0 : 1)} ${units[unitIdx]}';
  }
}
