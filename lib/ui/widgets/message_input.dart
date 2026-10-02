import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'attachment_preview.dart';
import 'input_style.dart';

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
/// 形状是一张圆角卡片（与 DSH 的输入框同一套排布）：附件预览在最上、文本域在中间、
/// 底部一行左边「+」（添加文件 / 展开输入框），右边**只有**圆形发送键。
/// - Enter 发送，Shift+Enter 换行，Esc 收起展开态
/// - 输入为空且无附件时发送键置灰不可点
/// - 发送后清空输入框与附件列表，并作废该 team+session 的草稿缓存
/// - Ctrl+V 依次尝试：剪贴板文件列表（可多个）→ 剪贴板位图 → 文件路径文本 → 文本
/// - 附件以**可预览**的形态展示（见 [AttachmentTile]）：图片给缩略图、其它给图标+名称+大小，
///   点开是本机文件的预览对话框（发送前附件还没上传，读的就是本机路径）
/// - 「展开」只把文本域变高（长文本写起来舒服），不改草稿与附件
/// - [cacheKey] 非空时按 team+session 缓存草稿，切走再切回来内容还在
class MessageInput extends StatefulWidget {
  /// 发送回调，参数为文本内容与附件文件路径列表。
  ///
  /// **返回 `false` = 没发出去**（例如附件上传失败、核心不可达）：调用方据此保留
  /// 输入框里的文本与附件——让用户重写一遍是他最不想要的结果。返回 `true` 才清空。
  final Future<bool> Function(String text, List<String> filePaths) onSend;

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

  /// 文本域自己的焦点节点：展开/收起后要能立刻继续打字（焦点不能落在按钮上），
  /// 边框高亮也看它。**键位拦截在 [_keyFocus] 上**——按键从主焦点向上冒泡，
  /// 两个节点各管一件事。
  final FocusNode _fieldFocus = FocusNode();

  /// 包裹文本域的焦点节点，只用来拦 Enter / Ctrl+V / Esc
  final FocusNode _keyFocus = FocusNode();

  /// 是否处于展开态（文本域变高，方便写长文本）
  bool _expanded = false;

  /// 已选择的文件路径列表
  final List<String> _filePaths = [];

  /// 是否正在回填草稿：回填会改 controller 并同步触发监听，但这不是用户编辑，
  /// 不能写回缓存（否则会把上一个键的文本/附件写进刚切过去的新键）
  bool _restoringDraft = false;

  /// 是否正在拖拽文件经过输入框区域
  bool _isDragging = false;

  /// 是否正在发送（含附件上传）：期间禁用发送按钮，避免重复提交导致附件重复上传
  bool _sending = false;

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
    // 聚焦时描边转主色（卡片式输入框的唯一焦点提示）
    _fieldFocus.addListener(() {
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
    _fieldFocus.dispose();
    _keyFocus.dispose();
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
  /// 等待 [MessageInput.onSend] 的结果：**成功才清空**输入框与附件，并作废该
  /// team+session 的草稿（否则切走再切回来会看到已发出的内容又回来了）；失败
  /// （例如附件上传失败）原样保留，用户改一改就能重发。
  Future<void> _handleSend() async {
    if (_sending) return;
    final String text = _controller.text.trim();
    if (text.isEmpty && _filePaths.isEmpty) return;
    setState(() {
      _sending = true;
    });
    bool sent = false;
    try {
      sent = await widget.onSend(text, List<String>.from(_filePaths));
    } catch (_) {
      // 回调本身的异常不该让输入框卡在"发送中"：一律按"没发出去"处理
      sent = false;
    }
    if (!mounted) return;
    setState(() {
      _sending = false;
    });
    if (!sent) return;
    _controller.clear();
    setState(() {
      _filePaths.clear();
    });
    final String? key = widget.cacheKey;
    if (key != null) MessageDraftCache.instance.clear(key);
  }

  /// 处理键盘事件：Enter 发送，Shift+Enter 换行，Esc 收起展开态
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
    // Esc 收起展开态：展开后文本域很高，得有个不用鼠标的退路
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (!_expanded) return KeyEventResult.ignored;
      _toggleExpand();
      return KeyEventResult.handled;
    }
    if (event.logicalKey != LogicalKeyboardKey.enter) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftLeft) ||
        HardwareKeyboard.instance.logicalKeysPressed.contains(LogicalKeyboardKey.shiftRight)) {
      return KeyEventResult.ignored;
    }
    // 发送是异步的（附件要先上传），这里不等结果：清空与否由 _handleSend 内部按
    // 回调返回值处理。
    unawaited(_handleSend());
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
  ///
  /// 一张圆角卡片：附件预览在上、文本域在中、底部一行左边「+」右边「展开 + 发送」。
  /// 聚焦或拖拽进来时描边转主色——卡片式输入框没有别的焦点提示了。
  Widget _buildInputBody(ColorScheme cs) {
    final Color divider = Theme.of(context).dividerColor;
    final Color borderColor = _isDragging
        ? cs.primary
        : (_fieldFocus.hasFocus ? cs.primary.withValues(alpha: 0.55) : divider);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (_isDragging) _buildDropHint(cs),
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: borderColor, width: _isDragging ? 2 : 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (_filePaths.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                    child: _buildAttachmentStrip(),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                  child: Focus(
                    focusNode: _keyFocus,
                    onKeyEvent: _handleKeyEvent,
                    // 展开态靠一个固定高度的盒子：maxLines 置空让文本域自己滚动，
                    // 而且盒子高度变化不会换掉 TextField 这个 widget——展开/收起时
                    // 焦点与光标位置都不丢。
                    child: SizedBox(
                      height: _expanded ? _expandedFieldHeight(context) : null,
                      child: _buildField(cs),
                    ),
                  ),
                ),
                Row(
                  children: <Widget>[
                    // 发送键左边刻意留空：那里只有发送键，别的入口都收进「+」
                    _buildAddMenu(cs),
                    const Spacer(),
                    _buildSendButton(cs),
                    const SizedBox(width: 4),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 文本域本体：无边框（边框由外层卡片画），随内容长高
  Widget _buildField(ColorScheme cs) {
    return TextField(
      controller: _controller,
      focusNode: _fieldFocus,
      minLines: _expanded ? null : 1,
      maxLines: _expanded ? null : 8,
      keyboardType: TextInputType.multiline,
      style: const TextStyle(fontSize: 14, height: 1.4),
      // 边框由外层卡片画（见 _buildInputBody 的 Container），文本域自己不许再画一圈：
      // 全局 inputDecorationTheme 给了 enabled/focused 边框，只写 border: none 压不住它
      // （解析顺序 focusedBorder → enabledBorder → border，见 input_style.dart）。
      decoration: kBorderlessInput.copyWith(
        isDense: true,
        hintText: '输入消息…',
        hintStyle: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
        contentPadding: EdgeInsets.zero,
      ),
    );
  }

  /// 展开态文本域的高度。
  ///
  /// 为什么按窗口高换算：输入框在面板的 Column 里是"非弹性子项"，父级给它的是
  /// **无界**高度，拿不到"还剩下多少地方"；按窗口高取一个夹住的区间最稳。
  double _expandedFieldHeight(BuildContext context) =>
      (MediaQuery.sizeOf(context).height * 0.4).clamp(140.0, 360.0);

  /// 展开 / 收起（只改文本域高度，不动草稿与附件）
  void _toggleExpand() {
    setState(() {
      _expanded = !_expanded;
    });
    // 点按钮会把焦点交给按钮，这里抢回文本域：展开就是为了接着写
    _fieldFocus.requestFocus();
  }

  /// 「+」菜单：添加文件与展开/收起输入框。
  ///
  /// 为什么收进菜单而不是各占一个按钮：卡片底部那行只需要一个明确的"加东西"入口，
  /// 展开是低频操作（快捷键也行），摆成第二个按钮会让发送键不突出。
  Widget _buildAddMenu(ColorScheme cs) {
    return PopupMenuButton<String>(
      tooltip: '添加附件 / 展开输入框',
      icon: Icon(Icons.add, color: cs.onSurfaceVariant),
      onSelected: (String value) {
        if (value == 'file') {
          unawaited(_pickFile());
        } else {
          _toggleExpand();
        }
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        _menuItem('file', Icons.attach_file, '添加文件…'),
        _menuItem(
          'expand',
          _expanded ? Icons.close_fullscreen : Icons.open_in_full,
          _expanded ? '收起输入框' : '展开输入框（长文本）',
        ),
      ],
    );
  }

  PopupMenuItem<String> _menuItem(String value, IconData icon, String label) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return PopupMenuItem<String>(
      value: value,
      height: 36,
      child: Row(
        children: <Widget>[
          Icon(icon, size: 16, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  /// 圆形发送键：可发送时实心主色，不可发送时置灰
  Widget _buildSendButton(ColorScheme cs) {
    final bool enabled = _canSend && !_sending;
    return Tooltip(
      message: _sending ? '正在发送（附件上传中）…' : '发送（Enter）',
      child: Material(
        color: enabled ? cs.primary : cs.surfaceContainerHighest,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? _handleSend : null,
          child: SizedBox(
            width: 34,
            height: 34,
            child: Center(
              child: _sending
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: cs.onSurfaceVariant,
                      ),
                    )
                  : Icon(
                      Icons.arrow_upward,
                      size: 18,
                      color: enabled ? cs.onPrimary : cs.onSurfaceVariant,
                    ),
            ),
          ),
        ),
      ),
    );
  }

  /// 拖拽经过时的提示条
  Widget _buildDropHint(ColorScheme cs) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: cs.primary.withValues(alpha: 0.3),
          width: 1.5,
          strokeAlign: BorderSide.strokeAlignInside,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(Icons.cloud_upload_outlined, size: 18, color: cs.primary),
          const SizedBox(width: 8),
          Text(
            '松开以添加附件',
            style: TextStyle(
              color: cs.primary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  /// 已选附件：图片给缩略图、其它给图标+名称+大小，点开预览、角标移除
  Widget _buildAttachmentStrip() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _filePaths
          .map((String path) => AttachmentTile(
                path: path,
                onRemove: () => _removeFile(path),
              ))
          .toList(),
    );
  }

  /// 处理文件拖拽完成
  void _onDragDone(DropDoneDetails details) {
    setState(() {
      _isDragging = false;
    });
    _addFiles(details.files.map((dynamic f) => f.path as String));
  }
}
