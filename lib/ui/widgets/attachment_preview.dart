import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../io/attachment_upload_service.dart';
import '../services/file_reveal.dart';

/// 附件预览（本机文件）。
///
/// 为什么需要它：输入框里的附件在**发送前**是这台机器上的路径（发送时才由
/// [AttachmentUploadService] 上传进工作空间），所以预览只能读本地文件——文件面板的
/// FileViewer 走的是核心 REST + 工作空间相对路径，这里用不了。
///
/// 三档呈现：图片按原图缩放、文本/源码直接读内容（最多 [kPreviewTextLimit] 字节，
/// 超出只显示前一段并明确标注已截断）、其它给文件信息 + 「在文件夹中显示」。
///
/// 两条判定口径：
/// - **是不是图片看扩展名**（[kPreviewImageExtensions]）——解码失败由 errorBuilder 兜底；
/// - **是不是文本一律看字节**：前 4 KB 里出现 NUL 就按二进制，扩展名说了不算。这样
///   没扩展名的 Makefile / .env 能直接读（比"一律二进制"实用），而扩展名骗人的文件
///   不会被渲染成乱码。
const Set<String> kPreviewImageExtensions = <String>{
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'bmp',
  'ico',
  'tif',
  'tiff',
};

/// 能当文本读的扩展名（源码 / 配置 / 日志 / 标记语言）
const Set<String> kPreviewTextExtensions = <String>{
  'txt',
  'md',
  'markdown',
  'rst',
  'json',
  'jsonl',
  'yaml',
  'yml',
  'toml',
  'ini',
  'cfg',
  'conf',
  'env',
  'csv',
  'tsv',
  'log',
  'dart',
  'py',
  'js',
  'mjs',
  'ts',
  'tsx',
  'jsx',
  'c',
  'h',
  'cc',
  'cpp',
  'hpp',
  'cs',
  'java',
  'kt',
  'go',
  'rs',
  'rb',
  'php',
  'swift',
  'lua',
  'pl',
  'sh',
  'bash',
  'zsh',
  'ps1',
  'bat',
  'cmd',
  'sql',
  'html',
  'htm',
  'css',
  'scss',
  'xml',
  'svg',
  'gradle',
  'properties',
  'patch',
  'diff',
  'gitignore',
};

/// 文本预览一次最多读这么多字节（超出不读，界面标注已截断）
const int kPreviewTextLimit = 256 * 1024;

/// 是不是能当图片预览的路径
bool attachmentIsImage(String path) =>
    kPreviewImageExtensions.contains(_extensionOf(path));

/// 是不是已知的文本类路径（源码 / 配置 / 日志…）。
///
/// 只用于挑图标与文案提示——**是否按文本读由字节决定**（见 [AttachmentPreviewData.read]）。
bool attachmentIsText(String path) =>
    kPreviewTextExtensions.contains(_extensionOf(path));

/// 附件显示名（最后一个分隔符之后；兼容 / 与 \\）
String attachmentName(String path) => AttachmentUploadService.baseNameOf(path);

/// 按扩展名挑一个图标（纯视觉区分，不参与任何判定）
IconData attachmentIcon(String path) {
  final String ext = _extensionOf(path);
  if (kPreviewImageExtensions.contains(ext)) return Icons.image_outlined;
  if (kPreviewTextExtensions.contains(ext)) return Icons.description_outlined;
  if (ext == 'pdf') return Icons.picture_as_pdf_outlined;
  if (const <String>{'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz'}.contains(ext)) {
    return Icons.folder_zip_outlined;
  }
  return Icons.insert_drive_file_outlined;
}

/// 人类可读的文件大小。
///
/// 负数 = **没读到**（文件已被删 / 无权限），显示「大小未知」；0 是真的空文件，
/// 就该显示 0 B——把两者混成一个值会让人以为附件是空的。
String formatFileSize(int bytes) {
  if (bytes < 0) return '大小未知';
  const List<String> units = <String>['B', 'KB', 'MB', 'GB'];
  double size = bytes.toDouble();
  int unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  final String digits =
      size >= 10 || unit == 0 ? size.toStringAsFixed(0) : size.toStringAsFixed(1);
  return '$digits ${units[unit]}';
}

String _extensionOf(String path) =>
    AttachmentUploadService.extensionOf(attachmentName(path));

/// 单个附件的呈现：图片给缩略图、其它给"图标 + 名称 + 大小"卡片，点开预览。
///
/// 大小是**异步**读的（`File.length()` 在 build 里同步读会卡住首帧），
/// 没读到之前显示占位，读到再刷新；文件已经被删掉时按「大小未知」显示，
/// 缩略图交给 errorBuilder 兜底——附件在列表里显示不出来，不该变成一次崩溃。
class AttachmentTile extends StatefulWidget {
  const AttachmentTile({super.key, required this.path, this.onRemove});

  /// 本机绝对路径
  final String path;

  /// 移除回调；为 null 时不显示移除键
  final VoidCallback? onRemove;

  @override
  State<AttachmentTile> createState() => _AttachmentTileState();
}

class _AttachmentTileState extends State<AttachmentTile> {
  /// 已读到的字节数；null = 读不到（文件已被删 / 无权限）
  int? _size;

  /// 是否已经读完（区分"还在读"与"读不到"）
  bool _sizeLoaded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSize());
  }

  @override
  void didUpdateWidget(covariant AttachmentTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 同一个槽位换了另一个附件（列表增删后）：必须重新读，否则会显示上一个的大小
    if (oldWidget.path != widget.path) {
      _size = null;
      _sizeLoaded = false;
      unawaited(_loadSize());
    }
  }

  Future<void> _loadSize() async {
    int? size;
    if (!kIsWeb) {
      try {
        size = await File(widget.path).length();
      } catch (_) {
        size = null;
      }
    }
    if (!mounted) return;
    setState(() {
      _size = size;
      // 网页端读不到本机文件：直接落成"读不到"，不一直转"读取中…"
      _sizeLoaded = true;
    });
  }

  String get _sizeLabel =>
      _sizeLoaded ? formatFileSize(_size ?? -1) : '读取中…';

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String name = attachmentName(widget.path);
    final Widget tile = attachmentIsImage(widget.path)
        ? _buildImageTile(cs, name)
        : _buildFileCard(cs, name);
    return Tooltip(
      message: widget.path,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => unawaited(showAttachmentPreview(context, widget.path)),
        child: tile,
      ),
    );
  }

  /// 图片：72x72 缩略图 + 右上角移除角标
  Widget _buildImageTile(ColorScheme cs, String name) {
    return SizedBox(
      width: 72,
      height: 72,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(
                File(widget.path),
                fit: BoxFit.cover,
                cacheWidth: 144,
                // 解码失败 / 文件已被移走：给一个看得懂的占位而不是红屏
                errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
                    _buildBrokenThumb(cs, name),
              ),
            ),
          ),
          if (widget.onRemove != null)
            Positioned(top: -6, right: -6, child: _buildRemoveBadge(cs)),
        ],
      ),
    );
  }

  Widget _buildBrokenThumb(ColorScheme cs, String name) {
    return Container(
      color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(Icons.broken_image_outlined, size: 18, color: cs.onSurfaceVariant),
          const SizedBox(height: 2),
          Text(
            name,
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 9, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildRemoveBadge(ColorScheme cs) {
    return Material(
      color: cs.surface,
      shape: const CircleBorder(),
      elevation: 1,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: widget.onRemove,
        child: Tooltip(
          message: '移除附件',
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Icon(Icons.close, size: 12, color: cs.onSurfaceVariant),
          ),
        ),
      ),
    );
  }

  /// 非图片：图标 + 名称 + 大小
  Widget _buildFileCard(ColorScheme cs, String name) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(attachmentIcon(widget.path), size: 18, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                ),
                Text(
                  _sizeLabel,
                  style: TextStyle(fontSize: 10, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (widget.onRemove != null)
            IconButton(
              icon: const Icon(Icons.close, size: 14),
              onPressed: widget.onRemove,
              tooltip: '移除附件',
              color: cs.onSurfaceVariant,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            ),
        ],
      ),
    );
  }
}

/// 打开附件预览对话框（本机路径）
Future<void> showAttachmentPreview(BuildContext context, String path) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) => AttachmentPreviewDialog(path: path),
  );
}

/// 预览对话的内容类型
enum AttachmentPreviewKind { image, text, binary, missing }

/// 预览读到的结果
class AttachmentPreviewData {
  const AttachmentPreviewData({
    required this.kind,
    required this.size,
    this.text = '',
    this.truncated = false,
    this.note = '',
  });

  final AttachmentPreviewKind kind;

  /// 字节数；未知为 0
  final int size;

  /// 文本/源码内容（kind = text 时有意义）
  final String text;

  /// 内容是否被 [kPreviewTextLimit] 截断
  final bool truncated;

  /// 兜底说明（目录、读不到、网页端…）
  final String note;

  /// 把本机文件读成可展示的结果（纯函数式：不碰 UI，便于单测）
  static Future<AttachmentPreviewData> read(String path) async {
    if (kIsWeb) {
      return const AttachmentPreviewData(
        kind: AttachmentPreviewKind.binary,
        size: 0,
        note: '网页端读不到本机文件',
      );
    }
    final File file = File(path);
    FileStat stat;
    try {
      stat = await file.stat();
    } catch (e) {
      return AttachmentPreviewData(
        kind: AttachmentPreviewKind.missing,
        size: 0,
        note: '读不到这个文件：$e',
      );
    }
    if (stat.type == FileSystemEntityType.notFound) {
      return const AttachmentPreviewData(
        kind: AttachmentPreviewKind.missing,
        size: 0,
        note: '文件不存在或已被移动',
      );
    }
    if (stat.type == FileSystemEntityType.directory) {
      return AttachmentPreviewData(
        kind: AttachmentPreviewKind.binary,
        size: 0,
        note: '这是一个文件夹，附件应该是文件',
      );
    }
    final int size = stat.size;
    if (attachmentIsImage(path)) {
      return AttachmentPreviewData(kind: AttachmentPreviewKind.image, size: size);
    }
    final Uint8List head = await _readHead(file, kPreviewTextLimit);
    // 是不是文本看字节，不看扩展名：头部有 NUL 一律当二进制（不渲染乱码）
    if (_looksBinary(head)) {
      return AttachmentPreviewData(kind: AttachmentPreviewKind.binary, size: size);
    }
    if (head.isEmpty) {
      if (size == 0) {
        return AttachmentPreviewData(kind: AttachmentPreviewKind.text, size: 0);
      }
      return AttachmentPreviewData(
        kind: AttachmentPreviewKind.binary,
        size: size,
        note: '读不出内容（权限或文件类型不支持）',
      );
    }
    return AttachmentPreviewData(
      kind: AttachmentPreviewKind.text,
      size: size,
      text: utf8.decode(head, allowMalformed: true),
      truncated: size > head.length,
    );
  }

  /// 读前 [limit] 个字节；读不到返回空
  static Future<Uint8List> _readHead(File file, int limit) async {
    RandomAccessFile raf;
    try {
      raf = await file.open();
    } catch (_) {
      return Uint8List(0);
    }
    try {
      final int length = await raf.length();
      final int count = length > limit ? limit : length;
      return await raf.read(count);
    } catch (_) {
      return Uint8List(0);
    } finally {
      try {
        await raf.close();
      } catch (_) {
        // 关不掉就算了：这是一次只读预览，不额外抛错
      }
    }
  }

  /// 前 4 KB 里有 NUL 就当二进制（文本文件里不该出现 NUL）
  static bool _looksBinary(Uint8List bytes) {
    final int n = bytes.length > 4096 ? 4096 : bytes.length;
    for (int i = 0; i < n; i++) {
      if (bytes[i] == 0) return true;
    }
    return false;
  }
}

/// 附件预览对话框：图片看大图、文本看内容、其它看信息。
///
/// 为什么不用文件面板的 FileViewer：那是给**工作空间**里的文件用的（经核心 REST），
/// 输入框里的附件还没上传，只有本机路径。
class AttachmentPreviewDialog extends StatefulWidget {
  const AttachmentPreviewDialog({super.key, required this.path});

  final String path;

  @override
  State<AttachmentPreviewDialog> createState() => _AttachmentPreviewDialogState();
}

class _AttachmentPreviewDialogState extends State<AttachmentPreviewDialog> {
  AttachmentPreviewData? _data;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final AttachmentPreviewData data = await AttachmentPreviewData.read(widget.path);
    if (!mounted) return;
    setState(() {
      _data = data;
    });
  }

  /// 在系统文件管理器里定位这个文件（失败原因弹提示，不静默）
  Future<void> _reveal() async {
    final String? problem = await FileReveal.reveal(widget.path);
    if (problem == null || !mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(problem)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final AttachmentPreviewData? data = _data;
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 880,
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _buildHeader(cs, data),
            Divider(height: 1, color: Theme.of(context).dividerColor),
            Flexible(child: _buildBody(cs, data)),
            Divider(height: 1, color: Theme.of(context).dividerColor),
            _buildFooter(cs, data),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ColorScheme cs, AttachmentPreviewData? data) {
    final String name = attachmentName(widget.path);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: <Widget>[
          Icon(attachmentIcon(widget.path), size: 20, color: cs.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Tooltip(
                  message: widget.path,
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  data == null
                      ? '读取中…'
                      : (data.kind == AttachmentPreviewKind.missing
                          ? '文件不存在'
                          : formatFileSize(data.size)),
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
            tooltip: '关闭',
            color: cs.onSurfaceVariant,
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme cs, AttachmentPreviewData? data) {
    if (data == null) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    switch (data.kind) {
      case AttachmentPreviewKind.image:
        return Padding(
          padding: const EdgeInsets.all(12),
          child: InteractiveViewer(
            maxScale: 8,
            child: Image.file(
              File(widget.path),
              fit: BoxFit.contain,
              errorBuilder: (BuildContext context, Object error, StackTrace? stack) =>
                  _buildNotice(cs, '图片解码失败或文件已被移动', widget.path),
            ),
          ),
        );
      case AttachmentPreviewKind.text:
        return SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (data.truncated)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '文件较大，只显示前 256 KB',
                    style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                  ),
                ),
              SelectableText(
                data.text,
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  fontFamily: 'Consolas',
                  fontFamilyFallback: <String>['Cascadia Mono', 'monospace'],
                ),
              ),
            ],
          ),
        );
      case AttachmentPreviewKind.binary:
        return _buildNotice(cs, data.note.isEmpty ? '这个文件不能在应用内预览' : data.note, widget.path);
      case AttachmentPreviewKind.missing:
        return _buildNotice(cs, data.note, widget.path);
    }
  }

  Widget _buildNotice(ColorScheme cs, String message, String path) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.info_outline, size: 28, color: cs.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          SelectableText(
            path,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(ColorScheme cs, AttachmentPreviewData? data) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          TextButton.icon(
            icon: const Icon(Icons.folder_open, size: 16),
            label: const Text('在文件夹中显示'),
            // 文件都不在了就别让人点了：explorer 对不存在的路径毫无反馈
            onPressed: data?.kind == AttachmentPreviewKind.missing ? null : _reveal,
          ),
          const SizedBox(width: 4),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
