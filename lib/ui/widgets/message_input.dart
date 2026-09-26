import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 一条未发送完的输入草稿（M9 Q6）。
///
/// 文本与附件列表**一起**存：只恢复文本会让用户以为附件还在。
class MessageDraft {
  const MessageDraft({required this.text, required this.filePaths});

  final String text;
  final List<String> filePaths;
}

/// 输入框草稿缓存（M9 Q6）：键 = team + session（见 [MessageInput.cacheKey]）。
///
/// 为什么只放内存、不落盘：草稿是"切过去看一眼再切回来"的临时状态，重启后为空
/// 才是预期；落盘会让用户下次启动看到上次的残留内容。
/// 为什么由输入框自己管：草稿（文本 + 附件）就是输入控件的内部状态，面板只负责
/// 把当前 team/session 拼成键传进来。
class MessageDraftCache {
  MessageDraftCache._();

  /// 全局单例：输入框会随 agent/会话切换重建，缓存不能跟着丢。
  static final MessageDraftCache instance = MessageDraftCache._();

  final Map<String, MessageDraft> _drafts = <String, MessageDraft>{};

  /// 读草稿；无缓存返回 null（调用方据此清空输入框）。
  MessageDraft? read(String key) => _drafts[key];

  /// 写回草稿；文本与附件都为空时删除该键，不留空条目。
  void write(String key, String text, List<String> filePaths) {
    if (text.isEmpty && filePaths.isEmpty) {
      _drafts.remove(key);
      return;
    }
    _drafts[key] = MessageDraft(
      text: text,
      filePaths: List<String>.from(filePaths),
    );
  }

  /// 清空某个键的草稿（发送成功后调用）。
  void clear(String key) => _drafts.remove(key);

  /// 清空全部草稿（测试与整体重置用）。
  void clearAll() => _drafts.clear();
}

/// 消息输入框组件
///
/// 包含多行输入框、文件上传按钮与发送按钮。
/// - Enter 发送，Shift+Enter 换行
/// - 输入为空且无附件时禁用发送按钮
/// - 发送后清空输入框与附件列表，并作废该 team+session 的草稿缓存
/// - Ctrl+V 依次尝试：剪贴板文件列表（可多个）→ 剪贴板位图 → 文件路径文本 → 文本
/// - [cacheKey] 非空时按 team+session 缓存草稿，切走再切回来内容还在
class MessageInput extends StatefulWidget {
  /// 发送回调，参数为文本内容与附件文件路径列表
  final void Function(String text, List<String> filePaths) onSend;

  /// 草稿缓存键（调用方用 team + session 拼接）。
  ///
  /// 为 null 表示不缓存——复用方（如 teammates 窗口）不传时行为与旧版一致。
  final String? cacheKey;

  const MessageInput({
    super.key,
    required this.onSend,
    this.cacheKey,
  });

  @override
  State<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<MessageInput> {
  /// 剪贴板读取通道（Windows 原生实现于 flutter_window.cpp）：
  /// readImage 取单张位图，readFiles 取文件列表（可多个）。
  static const MethodChannel _clipboardChannel =
      MethodChannel('tree/clipboard');

  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  /// 已选择的文件路径列表
  final List<String> _filePaths = [];

  /// 是否正在回填草稿：回填会改 controller 并同步触发监听，但这不是用户编辑，
  /// 不能写回缓存（否则会把上一个键的文本/附件写进刚切过去的新键）
  bool _restoringDraft = false;

  /// 是否正在拖拽文件经过输入框区域
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    // 先回填草稿再挂监听：回填本身会改 controller.value，若监听已挂上，
    // 就会在 initState 里触发一次多余的 setState。
    _restoreDraft();
    _controller.addListener(() {
      _saveDraft();
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant MessageInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切换 team/session：旧键的草稿在每次编辑时已写回，这里只需取新键的草稿
    // （无缓存则清空输入框与附件），避免把上一个会话没发完的内容发到新会话
    if (oldWidget.cacheKey != widget.cacheKey) {
      _restoreDraft();
      setState(() {});
    }
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

  /// 把当前文本 + 附件写回当前键（编辑即写，切换时无需再补存）
  void _saveDraft() {
    if (_restoringDraft) return;
    final String? key = widget.cacheKey;
    if (key == null) return;
    MessageDraftCache.instance.write(key, _controller.text, _filePaths);
  }

  /// 取当前键的草稿回填输入框与附件（无缓存则清空）
  void _restoreDraft() {
    final String? key = widget.cacheKey;
    final MessageDraft? draft =
        key == null ? null : MessageDraftCache.instance.read(key);
    final String text = draft?.text ?? '';
    // 先换附件再改文本：文本赋值会同步通知监听者，附件必须是新键的那一份
    _restoringDraft = true;
    _filePaths
      ..clear()
      ..addAll(draft?.filePaths ?? const <String>[]);
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _restoringDraft = false;
  }

  /// 追加附件（统一入口：改完立即写回草稿，避免漏掉某个入口导致附件丢失）
  void _addFiles(Iterable<String> paths) {
    final List<String> added = paths.where((String p) => p.isNotEmpty).toList();
    if (added.isEmpty) return;
    setState(() {
      _filePaths.addAll(added);
    });
    _saveDraft();
  }

  /// 移除附件（同步写回草稿）
  void _removeFile(String path) {
    setState(() {
      _filePaths.remove(path);
    });
    _saveDraft();
  }

  /// 处理发送
  ///
  /// 先通过回调发出消息（同步回调返回即视为发送成功），再清空输入框与附件，
  /// 并作废该 team+session 的草稿——否则切走再切回来会看到已发出的内容又回来了。
  void _handleSend() {
    final String text = _controller.text.trim();
    if (text.isEmpty && _filePaths.isEmpty) return;
    widget.onSend(text, List<String>.from(_filePaths));
    _controller.clear();
    setState(() {
      _filePaths.clear();
    });
    final String? key = widget.cacheKey;
    if (key != null) MessageDraftCache.instance.clear(key);
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
        (HardwareKeyboard.instance.logicalKeysPressed
                .contains(LogicalKeyboardKey.controlLeft) ||
            HardwareKeyboard.instance.logicalKeysPressed
                .contains(LogicalKeyboardKey.controlRight))) {
      _handlePaste();
      return KeyEventResult.handled;
    }
    if (event.logicalKey != LogicalKeyboardKey.enter) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftLeft) ||
        HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftRight)) {
      return KeyEventResult.ignored;
    }
    _handleSend();
    return KeyEventResult.handled;
  }

  /// 处理文件选择
  Future<void> _pickFile() async {
    try {
      final List<PlatformFile> picked = await FilePicker.pickFiles();
      _addFiles(picked.map((PlatformFile f) => f.path).whereType<String>());
    } catch (e) {
      // 忽略文件选择异常
    }
  }

  /// 处理粘贴上传（Ctrl+V）：
  /// 1) 剪贴板**文件列表**（CF_HDROP，资源管理器里多选文件复制）→ 全部加入附件；
  /// 2) 剪贴板位图（截图工具）→ 存为临时文件后加入附件；
  /// 3) 复制的文件路径文本（一个或多个）→ 加入附件；
  /// 4) 普通文本 → 手动插入输入框当前光标处。
  ///
  /// 文件列表必须排在位图之前：Windows 剪贴板一次只放得下一张位图，多选文件
  /// 复制只以 CF_HDROP 形式出现；若先取位图，多选文件会被误判成"一张图片"。
  Future<void> _handlePaste() async {
    // 1) 剪贴板文件列表（可多个）
    final (List<String> files, bool channelMissing) =
        await _readClipboardFiles();
    if (files.isNotEmpty) {
      if (!mounted) return;
      _addFiles(files);
      return;
    }
    // 2) 剪贴板位图
    final String? imagePath = await _readClipboardImage();
    if (imagePath != null) {
      if (!mounted) return;
      _addFiles(<String>[imagePath]);
      return;
    }
    // 3) 剪贴板文本
    ClipboardData? data;
    String text;
    try {
      data = await Clipboard.getData(Clipboard.kTextPlain);
      text = data?.text ?? '';
    } catch (_) {
      text = '';
    }
    if (text.trim().isEmpty) {
      // 四条路都空：如果原因是原生通道缺 readFiles（旧二进制 / 热重载未重建
      // C++），必须说出来——否则表现就是「Ctrl+V 毫无反应」。
      if (channelMissing) {
        _notifyPasteProblem(
          '剪贴板文件读取不可用：当前客户端缺少原生 readFiles。'
          'C++ 改动不会被热重载应用，请重新构建并重启 Windows 客户端。',
        );
      }
      return;
    }
    final List<String> paths = _extractFilePaths(text);
    if (paths.isNotEmpty) {
      if (!mounted) return;
      _addFiles(paths);
      return;
    }
    // 4) 普通文本：手动插入（已拦截默认粘贴，需自行插入）
    if (!mounted) return;
    _insertText(text);
  }

  /// 读取剪贴板文件列表（Windows 原生 CF_HDROP，可多个）。
  ///
  /// 返回 (文件列表, 通道是否缺失)。**必须把「通道缺失」与「剪贴板里确实没有
  /// 文件」分开**：前者（跑着旧二进制、或只热重载了 Dart 而 C++ 改动未重建）
  /// 会让 Ctrl+V 完全没有反应，用户无从判断；后者才是正常情况。通道缺失时由
  /// [_handlePaste] 给出可见提示。
  Future<(List<String>, bool)> _readClipboardFiles() async {
    try {
      final List<dynamic>? result = await _clipboardChannel
          .invokeMethod<List<dynamic>>('readFiles');
      if (result == null) return (const <String>[], false);
      return (
        result
            .map((dynamic e) => e.toString())
            .where((String p) => p.isNotEmpty)
            .toList(),
        false,
      );
    } on MissingPluginException {
      return (const <String>[], true);
    } catch (_) {
      return (const <String>[], false);
    }
  }

  /// 粘贴拿不到任何内容时给出可见原因（不静默）。
  void _notifyPasteProblem(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
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
                  color: cs.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: cs.primary.withValues(alpha: 0.3),
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
                  tooltip: '上传文件（或直接 Ctrl+V 粘贴图片/文件，支持一次粘多个）',
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
    });
    _addFiles(details.files.map((dynamic f) => f.path as String));
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
            onDeleted: () => _removeFile(path),
          );
        }).toList(),
      ),
    );
  }
}
