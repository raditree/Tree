import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 消息输入框组件
///
/// 包含多行输入框、文件上传按钮与发送按钮。
/// - Enter 发送，Shift+Enter 换行
/// - 输入为空且无附件时禁用发送按钮
/// - 发送后清空输入框与附件列表
class MessageInput extends StatefulWidget {
  /// 发送回调，参数为文本内容与附件文件路径列表
  final void Function(String text, List<String> filePaths) onSend;

  const MessageInput({
    super.key,
    required this.onSend,
  });

  @override
  State<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<MessageInput> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  /// 已选择的文件路径列表
  final List<String> _filePaths = [];

  /// 是否正在拖拽文件经过输入框区域
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 是否可以发送（有文本或附件）
  bool get _canSend =>
      _controller.text.trim().isNotEmpty || _filePaths.isNotEmpty;

  /// 处理发送
  ///
  /// 先通过回调发出消息，再清空输入框与附件列表。
  void _handleSend() {
    final String text = _controller.text.trim();
    if (text.isEmpty && _filePaths.isEmpty) return;
    widget.onSend(text, List<String>.from(_filePaths));
    _controller.clear();
    setState(() {
      _filePaths.clear();
    });
  }

  /// 处理键盘事件：Enter 发送，Shift+Enter 换行
  ///
  /// 返回 [KeyEventResult.handled] 拦截 Enter 键，避免多行输入框插入换行；
  /// Shift+Enter 时返回 [KeyEventResult.ignored]，交由 TextField 处理换行。
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.enter) {
      return KeyEventResult.ignored;
    }
    if (RawKeyboard.instance.keysPressed.contains(LogicalKeyboardKey.shiftLeft) ||
        RawKeyboard.instance.keysPressed.contains(LogicalKeyboardKey.shiftRight)) {
      return KeyEventResult.ignored;
    }
    _handleSend();
    return KeyEventResult.handled;
  }

  /// 处理文件选择
  Future<void> _pickFile() async {
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
      );
      if (result != null && result.paths.isNotEmpty) {
        setState(() {
          _filePaths.addAll(
            result.paths.whereType<String>(),
          );
        });
      }
    } catch (e) {
      // 忽略文件选择异常
    }
  }

  /// 从路径中提取文件名（兼容 / 与 \）
  String _basename(String path) {
    final String replaced = path.replaceAll('\\', '/');
    final int idx = replaced.lastIndexOf('/');
    return idx >= 0 ? replaced.substring(idx + 1) : replaced;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DropTarget(
      onDragDone: _onDragDone,
      onDragEntered: (_) => setState(() => _isDragging = true),
      onDragExited: (_) => setState(() => _isDragging = false),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border(
            top: BorderSide(
              color: _isDragging ? cs.primary : Theme.of(context).dividerColor,
              width: _isDragging ? 2 : 1,
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isDragging)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: cs.primary.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: cs.primary.withOpacity(0.3),
                    width: 1.5,
                    strokeAlign: BorderSide.strokeAlignInside,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.cloud_upload_outlined,
                        size: 20, color: cs.primary),
                    const SizedBox(width: 8),
                    Text(
                      '松开以上传文件',
                      style: TextStyle(
                        color: cs.primary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            if (_filePaths.isNotEmpty) _buildFileList(),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  icon: const Icon(Icons.attach_file),
                  onPressed: _pickFile,
                  color: cs.onSurfaceVariant,
                  tooltip: '上传文件',
                ),
                Expanded(
                  child: Focus(
                    focusNode: _focusNode,
                    onKeyEvent: _handleKeyEvent,
                    child: TextField(
                      controller: _controller,
                      maxLines: 5,
                      minLines: 1,
                      style: const TextStyle(fontSize: 14),
                      decoration: InputDecoration(
                        hintText: '输入消息...',
                        hintStyle: TextStyle(
                          color: cs.onSurfaceVariant,
                          fontSize: 14,
                        ),
                        filled: true,
                        fillColor: cs.surface,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: Theme.of(context).dividerColor,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: Theme.of(context).dividerColor,
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(
                            color: cs.primary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _canSend ? _handleSend : null,
                  color: cs.primary,
                  disabledColor: cs.outline,
                  tooltip: '发送',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 处理文件拖拽完成
  void _onDragDone(DropDoneDetails details) {
    setState(() {
      _isDragging = false;
      for (final xfile in details.files) {
        final String? path = xfile.path;
        if (path != null && path.isNotEmpty) {
          _filePaths.add(path);
        }
      }
    });
  }

  /// 构建已选文件列表（Chip 形式，可删除）
  Widget _buildFileList() {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: _filePaths.map((String path) {
          return Chip(
            label: Text(
              _basename(path),
              style: const TextStyle(fontSize: 12),
            ),
            deleteIcon: const Icon(Icons.close, size: 16),
            onDeleted: () {
              setState(() {
                _filePaths.remove(path);
              });
            },
          );
        }).toList(),
      ),
    );
  }
}
