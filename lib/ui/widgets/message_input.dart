import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

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
  /// 剪贴板图片读取通道（Windows 原生实现于 flutter_window.cpp）
  static const MethodChannel _clipboardChannel =
      MethodChannel('tree/clipboard');

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
    // Ctrl+V：拦截默认粘贴，优先处理"粘贴上传"（剪贴板图片 / 复制的文件路径），
    // 普通文本则在手动插入（见 _handlePaste），避免被默认粘贴重复插入。
    if (event.logicalKey == LogicalKeyboardKey.keyV &&
        (RawKeyboard.instance.keysPressed
                .contains(LogicalKeyboardKey.controlLeft) ||
            RawKeyboard.instance.keysPressed
                .contains(LogicalKeyboardKey.controlRight))) {
      _handlePaste();
      return KeyEventResult.handled;
    }
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

  /// 处理粘贴上传（Ctrl+V）：
  /// 1) 剪贴板图片 → 保存为临时文件并加入附件；
  /// 2) 复制的文件路径文本（一个或多个）→ 加入附件；
  /// 3) 普通文本 → 手动插入输入框当前光标处。
  Future<void> _handlePaste() async {
    // 1) 剪贴板图片
    final String? imagePath = await _readClipboardImage();
    if (imagePath != null) {
      if (!mounted) return;
      setState(() => _filePaths.add(imagePath));
      return;
    }
    // 2) 剪贴板文本
    ClipboardData? data;
    String text;
    try {
      data = await Clipboard.getData(Clipboard.kTextPlain);
      text = data?.text ?? '';
    } catch (_) {
      text = '';
    }
    if (text.trim().isEmpty) return;
    final List<String> paths = _extractFilePaths(text);
    if (paths.isNotEmpty) {
      if (!mounted) return;
      setState(() => _filePaths.addAll(paths));
      return;
    }
    // 3) 普通文本：手动插入（已拦截默认粘贴，需自行插入）
    if (!mounted) return;
    _insertText(text);
  }

  /// 读取剪贴板图片并保存为临时文件，无图片时返回 null
  Future<String?> _readClipboardImage() async {
    try {
      final Map<dynamic, dynamic>? result =
          await _clipboardChannel.invokeMethod<Map<dynamic, dynamic>>(
        'readImage',
      );
      if (result == null) return null;
      final String format = (result['format'] as String? ?? 'png').toString();
      final Uint8List? bytes = result['bytes'] as Uint8List?;
      if (bytes == null || bytes.isEmpty) return null;
      final Directory dir = await getTemporaryDirectory();
      final String ext = format == 'bmp' ? 'bmp' : 'png';
      final File file = File(
        '${dir.path}${Platform.pathSeparator}'
        'clipboard_paste_${DateTime.now().millisecondsSinceEpoch}.$ext',
      );
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// 从剪贴板文本识别文件路径。仅当所有非空行都是已存在的文件时才返回
  /// 文件列表（视为复制文件场景）；否则返回空（按普通文本处理）。
  List<String> _extractFilePaths(String text) {
    final List<String> lines = text
        .split(RegExp(r'[\r\n]+'))
        .map((String line) {
          String t = line.trim();
          // 兼容 file:// 前缀（如浏览器复制的本地文件地址）
          if (t.startsWith('file:///')) {
            t = t.substring('file:///'.length);
          } else if (t.startsWith('file://')) {
            t = t.substring('file://'.length);
          }
          if (t.startsWith('"') && t.endsWith('"') && t.length >= 2) {
            t = t.substring(1, t.length - 1);
          }
          return t;
        })
        .where((String l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return const [];
    for (final String l in lines) {
      if (!File(l).existsSync()) return const [];
    }
    return lines;
  }

  /// 在输入框当前选区处插入文本（替换选区）
  void _insertText(String text) {
    final TextEditingValue value = _controller.value;
    final TextSelection sel = value.selection;
    final int start = sel.isValid ? sel.start : value.text.length;
    final int end = sel.isValid ? sel.end : value.text.length;
    final String newText = value.text.replaceRange(start, end, text);
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
  }

  /// 从路径中提取文件名（兼容 / 与 \）
  String _basename(String path) {
    final String replaced = path.replaceAll('\\', '/');
    final int idx = replaced.lastIndexOf('/');
    return idx >= 0 ? replaced.substring(idx + 1) : replaced;
  }

  /// 是否桌面端（拖拽上传仅桌面支持，移动端跳过 DropTarget 避免崩溃）
  bool get _isDesktop =>
      !kIsWeb &&
      (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final Widget body = _buildInputBody(cs);
    // desktop_drop 的 DropTarget 仅支持桌面端（Windows/Linux/macOS）；
    // 移动端（Android/iOS）无拖拽能力，直接渲染输入区，
    // 避免注册不存在的平台通道导致 MissingPluginException 崩溃。
    if (!_isDesktop) return body;
    return DropTarget(
      onDragDone: _onDragDone,
      onDragEntered: (_) => setState(() => _isDragging = true),
      onDragExited: (_) => setState(() => _isDragging = false),
      child: body,
    );
  }

  /// 输入区主体（桌面端由 DropTarget 包裹支持文件拖拽）
  Widget _buildInputBody(ColorScheme cs) {
    return Container(
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
                  tooltip: '上传文件（或直接 Ctrl+V 粘贴图片/文件）',
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
    );
  }

  /// 处理文件拖拽完成
  void _onDragDone(DropDoneDetails details) {
    setState(() {
      _isDragging = false;
      for (final xfile in details.files) {
        final String path = xfile.path;
        if (path.isNotEmpty) {
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
