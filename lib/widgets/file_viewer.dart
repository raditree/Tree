import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_service.dart';

/// 文本文件扩展名
const List<String> textExtensions = [
  '.txt', '.py', '.js', '.ts', '.json', '.yaml', '.yml', '.xml', '.csv',
  '.dart', '.go', '.rs', '.sh', '.bat', '.css', '.html', '.java', '.c',
  '.cpp', '.h', '.hpp', '.cs', '.rb', '.php', '.swift', '.kt', '.sql',
  '.toml', '.ini', '.cfg', '.conf', '.log', '.jsx', '.tsx', '.scss',
];

/// 图片扩展名
const List<String> imageExtensions = [
  '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp',
];

/// Markdown 扩展名
const List<String> mdExtensions = ['.md', '.markdown'];

/// SVG 扩展名
const List<String> svgExtensions = ['.svg'];

/// PDF 扩展名
const List<String> pdfExtensions = ['.pdf'];

/// Office 文档扩展名
const List<String> officeExtensions = [
  '.docx', '.doc', '.odt', '.rtf', '.pptx', '.xlsx', '.xls',
];

/// 文件查看器 - 支持多种文件格式的查看与预览
///
/// 根据文件扩展名自动选择合适的查看方式：
/// - 文本文件：等宽字体显示原始内容
/// - Markdown：源码 / 预览切换，预览支持基础语法渲染
/// - SVG：源码 / 预览切换（预览暂显示提示与源码）
/// - 图片：通过 base64 解码后用 Image.memory 显示
/// - PDF / Office：显示文件信息与提示，提供下载按钮
class FileViewer extends StatefulWidget {
  /// 工作空间 ID
  final String workspaceId;

  /// 文件相对路径
  final String filePath;

  /// 返回回调（用于关闭查看器）
  final VoidCallback? onClose;

  const FileViewer({
    super.key,
    required this.workspaceId,
    required this.filePath,
    this.onClose,
  });

  @override
  State<FileViewer> createState() => _FileViewerState();
}

/// 文件类型分类
enum _FileType { text, markdown, svg, image, pdf, office, unknown }

class _FileViewerState extends State<FileViewer> {
  /// 文件文本内容（文本 / Markdown / SVG）
  String _content = '';

  /// 图片解码后的字节数据
  Uint8List? _imageBytes;

  /// 是否正在加载
  bool _isLoading = true;

  /// 加载错误信息
  String? _error;

  /// 预览模式开关（Markdown / SVG 适用），true=预览，false=源码
  bool _showPreview = true;

  /// PDF 当前页图片字节
  Uint8List? _pdfPageBytes;

  /// PDF 当前页码（从 1 开始）
  int _currentPage = 1;

  /// PDF 总页数
  int _totalPages = 0;

  /// 是否正在加载 PDF 单页（翻页时）
  bool _isLoadingPage = false;

  @override
  void initState() {
    super.initState();
    // Office 为二进制格式，不支持预览，直接结束加载状态
    if (_fileType == _FileType.office) {
      _isLoading = false;
    } else if (_fileType == _FileType.pdf) {
      // PDF 通过 PyMuPDF 后端渲染为图片展示
      _loadPdf();
    } else {
      _loadContent();
    }
  }

  /// 从文件路径提取文件名
  String get _fileName {
    if (widget.filePath.isEmpty) return '未知文件';
    final int lastSlash = widget.filePath.lastIndexOf('/');
    if (lastSlash >= 0 && lastSlash < widget.filePath.length - 1) {
      return widget.filePath.substring(lastSlash + 1);
    }
    return widget.filePath;
  }

  /// 文件扩展名（小写，含点）
  String get _extension {
    final String name = _fileName;
    final int idx = name.lastIndexOf('.');
    if (idx < 0) return '';
    return name.substring(idx).toLowerCase();
  }

  /// 根据扩展名判断文件类型
  _FileType get _fileType {
    final String ext = _extension;
    if (mdExtensions.contains(ext)) return _FileType.markdown;
    if (svgExtensions.contains(ext)) return _FileType.svg;
    if (imageExtensions.contains(ext)) return _FileType.image;
    if (pdfExtensions.contains(ext)) return _FileType.pdf;
    if (officeExtensions.contains(ext)) return _FileType.office;
    if (textExtensions.contains(ext)) return _FileType.text;
    return _FileType.unknown;
  }

  /// 加载文件内容
  ///
  /// PDF / Office 为二进制格式，不通过文本接口获取，直接展示信息卡片。
  /// 图片文件通过 getFileContent 获取 base64 编码内容后本地解码。
  Future<void> _loadContent() async {
    final _FileType type = _fileType;
    // PDF 通过专用方法加载
    if (type == _FileType.pdf) {
      await _loadPdf();
      return;
    }
    // Office 不获取内容
    if (type == _FileType.office) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = null;
        });
      }
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final String content = await ApiService.getFileContent(
        widget.workspaceId,
        widget.filePath,
      );
      if (!mounted) return;
      if (type == _FileType.image) {
        // 图片内容按 base64 解码
        final Uint8List? bytes = _decodeBase64(content);
        if (bytes == null) {
          setState(() {
            _error = '图片解码失败，后端可能未返回 base64 编码内容';
            _isLoading = false;
          });
          return;
        }
        setState(() {
          _imageBytes = bytes;
          _content = content;
          _isLoading = false;
        });
      } else {
        setState(() {
          _content = content;
          _isLoading = false;
        });
      }
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  /// 加载 PDF：先获取文件信息（总页数），再加载第一页图片
  Future<void> _loadPdf() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> info = await ApiService.getPdfInfo(
        widget.workspaceId,
        widget.filePath,
      );
      if (!mounted) return;
      _totalPages = (info['total_pages'] as num?)?.toInt() ?? 0;
      _currentPage = 1;
      await _loadPdfPage(_currentPage);
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  /// 加载 PDF 指定页图片
  Future<void> _loadPdfPage(int page) async {
    setState(() {
      _isLoadingPage = true;
    });
    try {
      final Map<String, dynamic> data = await ApiService.getPdfPreview(
        widget.workspaceId,
        widget.filePath,
        page: page,
        scale: 2.0,
      );
      if (!mounted) return;
      final String imgB64 = data['image'] as String? ?? '';
      final Uint8List? bytes = _decodeBase64(imgB64);
      if (bytes == null) {
        throw Exception('PDF 页面图片解码失败');
      }
      setState(() {
        _pdfPageBytes = bytes;
        _currentPage = page;
        _totalPages = (data['total_pages'] as num?)?.toInt() ?? _totalPages;
        _isLoadingPage = false;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _isLoadingPage = false;
        _isLoading = false;
      });
    }
  }

  /// base64 解码，兼容 data URI 前缀与空白字符
  Uint8List? _decodeBase64(String raw) {
    String s = raw.trim();
    // 去除 data URI 前缀（如 data:image/png;base64,xxxx）
    final int commaIdx = s.indexOf(',');
    if (s.startsWith('data:') && commaIdx >= 0) {
      s = s.substring(commaIdx + 1);
    }
    // 去除所有空白字符
    s = s.replaceAll(RegExp(r'\s'), '');
    if (s.isEmpty) return null;
    try {
      return base64Decode(s);
    } catch (_) {
      return null;
    }
  }

  /// 复制文件内容到剪贴板
  Future<void> _copyContent() async {
    await Clipboard.setData(ClipboardData(text: _content));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已复制到剪贴板'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  /// 下载文件（下载单个文件而非同步整个目录）
  ///
  /// 调用 [ApiService.downloadFile] 获取文件字节，然后通过
  /// [FilePicker.platform.saveFile] 让用户选择保存位置并写入本地。
  Future<void> _downloadFile() async {
    // 提取文件名
    final String filename = widget.filePath.split('/').last;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) {
        return _DownloadProgressDialog(
          workspaceId: widget.workspaceId,
          filePath: widget.filePath,
          filename: filename,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          // 顶部标题栏
          _buildHeader(),
          Divider(
            height: 1,
            thickness: 1,
            color: Theme.of(context).dividerColor,
          ),
          // 内容区域
          Expanded(
            child: _buildBody(),
          ),
        ],
      ),
    );
  }

  /// 构建顶部标题栏
  ///
  /// 左侧：返回按钮 + 文件名（下行显示路径）；
  /// 右侧：预览/源码切换（如适用）+ 复制按钮 + 下载按钮 + 刷新按钮。
  Widget _buildHeader() {
    final _FileType type = _fileType;
    final cs = Theme.of(context).colorScheme;
    final bool canToggle =
        type == _FileType.markdown || type == _FileType.svg;
    final bool canCopy = !_isLoading && _error == null && _content.isNotEmpty;
    final bool canRefresh =
        type != _FileType.pdf && type != _FileType.office;
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          // 返回按钮
          if (widget.onClose != null)
            IconButton(
              icon: const Icon(Icons.arrow_back, size: 20),
              color: cs.onSurfaceVariant,
              tooltip: '返回',
              onPressed: widget.onClose,
            ),
          // 文件名与路径
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                if (widget.filePath.isNotEmpty)
                  Text(
                    widget.filePath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: cs.outline,
                    ),
                  ),
              ],
            ),
          ),
          // 预览 / 源码切换
          if (canToggle && !_isLoading && _error == null)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: _buildToggleButtons(),
            ),
          // 复制按钮
          if (canCopy)
            IconButton(
              icon: const Icon(Icons.copy, size: 18),
              color: cs.primary,
              tooltip: '复制',
              onPressed: _copyContent,
            ),
          // 下载按钮
          IconButton(
            icon: const Icon(Icons.download, size: 18),
            color: cs.onSurfaceVariant,
            tooltip: '下载',
            onPressed: _downloadFile,
          ),
          // 刷新按钮
          if (canRefresh)
            IconButton(
              icon: const Icon(Icons.refresh, size: 18),
              color: cs.onSurfaceVariant,
              tooltip: '刷新',
              onPressed: _isLoading ? null : _loadContent,
            ),
        ],
      ),
    );
  }

  /// 构建预览 / 源码切换按钮组
  Widget _buildToggleButtons() {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildToggleChip('预览', _showPreview, () {
            if (!_showPreview) setState(() => _showPreview = true);
          }),
          _buildToggleChip('源码', !_showPreview, () {
            if (_showPreview) setState(() => _showPreview = false);
          }),
        ],
      ),
    );
  }

  /// 构建单个切换标签
  Widget _buildToggleChip(String label, bool active, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: active ? cs.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: active ? cs.primary : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// 构建内容主体
  ///
  /// 根据加载状态与文件类型分别展示对应视图。
  Widget _buildBody() {
    final _FileType type = _fileType;
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _buildErrorView(_error!);
    }
    switch (type) {
      case _FileType.image:
        return _buildImageView();
      case _FileType.markdown:
        return _showPreview ? _buildMarkdownPreview() : _buildTextView();
      case _FileType.svg:
        return _showPreview ? _buildSvgPreview() : _buildTextView();
      case _FileType.pdf:
        return _buildPdfView();
      case _FileType.office:
        return _buildOfficeView();
      case _FileType.text:
      case _FileType.unknown:
      default:
        return _buildTextView();
    }
  }

  /// 错误视图（含重试按钮）
  Widget _buildErrorView(String message) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              size: 40,
              color: Color(0xFFEF4444),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: TextStyle(
                color: cs.outline,
                fontSize: 13,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _loadContent,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重试'),
              style: OutlinedButton.styleFrom(
                foregroundColor: cs.primary,
                side: BorderSide(color: cs.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 文本视图（等宽字体）
  Widget _buildTextView() {
    if (_content.isEmpty) {
      return Center(
        child: Text(
          '文件内容为空',
          style: TextStyle(
            color: Theme.of(context).colorScheme.outline,
            fontSize: 13,
          ),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: SelectableText(
        _content,
        style: TextStyle(
          fontSize: 13,
          height: 1.5,
          fontFamily: 'monospace',
          color: Theme.of(context).colorScheme.onSurface,
        ),
      ),
    );
  }

  /// 图片视图（支持缩放）
  Widget _buildImageView() {
    if (_imageBytes == null) {
      return _buildErrorView('图片数据为空');
    }
    return InteractiveViewer(
      child: Center(
        child: Image.memory(
          _imageBytes!,
          fit: BoxFit.contain,
          errorBuilder: (BuildContext ctx, Object error, StackTrace? stack) {
            return _buildErrorView('图片渲染失败：$error');
          },
        ),
      ),
    );
  }

  /// Markdown 预览视图
  Widget _buildMarkdownPreview() {
    if (_content.isEmpty) {
      return Center(
        child: Text(
          '文件内容为空',
          style: TextStyle(
            color: Theme.of(context).colorScheme.outline,
            fontSize: 13,
          ),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: _MarkdownRenderer(source: _content),
    );
  }

  /// SVG 预览视图（暂显示提示 + 源码）
  Widget _buildSvgPreview() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF3C7),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: const Color(0xFFF59E0B), width: 1),
            ),
            child: Row(
              children: const [
                Icon(Icons.info_outline, size: 16, color: Color(0xFFF59E0B)),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'SVG 预览需要 svg 包支持，当前显示源码',
                    style: TextStyle(fontSize: 12, color: Color(0xFF92400E)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SelectableText(
            _content,
            style: TextStyle(
              fontSize: 13,
              height: 1.5,
              fontFamily: 'monospace',
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  /// PDF 视图（页面图片 + 缩放 + 翻页导航）
  Widget _buildPdfView() {
    return Column(
      children: [
        // PDF 页面图片区域（支持缩放）
        Expanded(
          child: _isLoadingPage
              ? const Center(child: CircularProgressIndicator())
              : (_pdfPageBytes == null
                  ? _buildErrorView('PDF 页面数据为空')
                  : InteractiveViewer(
                      child: Center(
                        child: Image.memory(
                          _pdfPageBytes!,
                          fit: BoxFit.contain,
                          errorBuilder: (BuildContext ctx, Object error,
                              StackTrace? stack) {
                            return _buildErrorView('PDF 页面渲染失败：$error');
                          },
                        ),
                      ),
                    )),
        ),
        // 底部页码导航栏
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              top: BorderSide(color: Theme.of(context).dividerColor, width: 1),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left, size: 20),
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                tooltip: '上一页',
                onPressed: (_isLoadingPage || _currentPage <= 1)
                    ? null
                    : () => _loadPdfPage(_currentPage - 1),
              ),
              Text(
                _totalPages > 0
                    ? '$_currentPage / $_totalPages'
                    : '$_currentPage',
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right, size: 20),
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                tooltip: '下一页',
                onPressed: (_isLoadingPage || _currentPage >= _totalPages)
                    ? null
                    : () => _loadPdfPage(_currentPage + 1),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Office 视图（信息卡片 + 提示）
  Widget _buildOfficeView() {
    return _buildUnsupportedView(
      icon: Icons.description,
      tip: '此文件格式需要外部应用打开',
      typeLabel: 'Office 文档',
    );
  }

  /// 不支持直接查看的文件信息卡片
  Widget _buildUnsupportedView({
    required IconData icon,
    required String tip,
    required String typeLabel,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: cs.outline),
            const SizedBox(height: 12),
            Text(
              _fileName,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            _buildInfoRow('类型', typeLabel),
            _buildInfoRow('路径', widget.filePath),
            _buildInfoRow('扩展名', _extension.isEmpty ? '-' : _extension),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.info_outline, size: 16, color: cs.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      tip,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _downloadFile,
              icon: const Icon(Icons.download, size: 16),
              label: const Text('下载文件'),
              style: OutlinedButton.styleFrom(
                foregroundColor: cs.primary,
                side: BorderSide(color: cs.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 信息行（标签 + 值）
  Widget _buildInfoRow(String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label：',
            style: TextStyle(fontSize: 12, color: cs.outline),
          ),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: Text(
              value,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }
}

/// Markdown 简单渲染器
///
/// 解析以下 markdown 元素并渲染：
/// - `#` ~ `###`：标题（不同字号）
/// - `**text**`：加粗
/// - `*text*`：斜体
/// - `` `code` ``：行内代码（等宽字体 + 灰色背景）
/// - ` ``` `：代码块（等宽字体 + 灰色背景 + 圆角）
/// - `- `：无序列表
/// - `1. `：有序列表
/// - `[text](url)`：链接（蓝色文字 + 下划线）
/// - `> `：引用（左侧竖线 + 灰色背景）
///
/// 仅实现基础渲染，不做完美 Markdown 解析。
class _MarkdownRenderer extends StatelessWidget {
  /// Markdown 源码
  final String source;

  const _MarkdownRenderer({required this.source});

  @override
  Widget build(BuildContext context) {
    final List<String> lines = source.split('\n');
    final List<Widget> widgets = <Widget>[];
    bool inCodeBlock = false;
    final StringBuffer codeBuffer = StringBuffer();

    for (int i = 0; i < lines.length; i++) {
      final String line = lines[i];
      final String trimmed = line.trimLeft();

      // 代码块开始 / 结束
      if (trimmed.startsWith('```')) {
        if (inCodeBlock) {
          widgets.add(_buildCodeBlock(codeBuffer.toString(), context));
          codeBuffer.clear();
          inCodeBlock = false;
        } else {
          inCodeBlock = true;
        }
        continue;
      }
      if (inCodeBlock) {
        if (codeBuffer.isNotEmpty) codeBuffer.write('\n');
        codeBuffer.write(line);
        continue;
      }

      // 空行
      if (line.trim().isEmpty) {
        widgets.add(const SizedBox(height: 8));
        continue;
      }

      // 标题
      if (line.startsWith('### ')) {
        widgets.add(_buildHeading(line.substring(4), 3, context));
      } else if (line.startsWith('## ')) {
        widgets.add(_buildHeading(line.substring(3), 2, context));
      } else if (line.startsWith('# ')) {
        widgets.add(_buildHeading(line.substring(2), 1, context));
      } else if (line.startsWith('> ')) {
        widgets.add(_buildBlockquote(line.substring(2), context));
      } else if (line.startsWith('- ') || line.startsWith('* ')) {
        widgets.add(_buildListItem(line.substring(2), false, context: context));
      } else {
        final RegExpMatch? orderedMatch =
            RegExp(r'^(\d+)\.\s+(.*)').firstMatch(line);
        if (orderedMatch != null) {
          widgets.add(_buildListItem(
            orderedMatch.group(2)!,
            true,
            number: orderedMatch.group(1)!,
            context: context,
          ));
        } else {
          widgets.add(_buildParagraph(line, context));
        }
      }
    }

    // 处理未闭合的代码块
    if (inCodeBlock) {
      widgets.add(_buildCodeBlock(codeBuffer.toString(), context));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  /// 构建标题
  Widget _buildHeading(String text, int level, BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    double fontSize;
    if (level == 1) {
      fontSize = 22;
    } else if (level == 2) {
      fontSize = 18;
    } else {
      fontSize = 15;
    }
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 6),
      child: RichText(
        text: TextSpan(
          children: _parseInline(text, context),
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            color: cs.onSurface,
            height: 1.4,
          ),
        ),
      ),
    );
  }

  /// 构建段落
  Widget _buildParagraph(String text, BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: RichText(
        text: TextSpan(
          children: _parseInline(text, context),
          style: TextStyle(
            fontSize: 14,
            height: 1.6,
            color: cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// 构建引用块
  Widget _buildBlockquote(String text, BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          left: BorderSide(color: cs.primary, width: 3),
        ),
        borderRadius: BorderRadius.only(
          topRight: Radius.circular(4),
          bottomRight: Radius.circular(4),
        ),
      ),
      child: RichText(
        text: TextSpan(
          children: _parseInline(text, context),
          style: TextStyle(
            fontSize: 13,
            height: 1.6,
            color: cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// 构建列表项
  Widget _buildListItem(
    String text,
    bool ordered, {
    String? number,
    required BuildContext context,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ordered ? '$number. ' : '• ',
            style: TextStyle(
              fontSize: 14,
              height: 1.6,
              color: cs.onSurfaceVariant,
            ),
          ),
          Expanded(
            child: RichText(
              text: TextSpan(
                children: _parseInline(text, context),
                style: TextStyle(
                  fontSize: 14,
                  height: 1.6,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建代码块
  Widget _buildCodeBlock(String code, BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: SelectableText(
        code,
        style: TextStyle(
          fontSize: 12.5,
          height: 1.5,
          fontFamily: 'monospace',
          color: cs.onSurface,
        ),
      ),
    );
  }

  /// 解析行内样式：**加粗** *斜体* `代码` [链接](url)
  ///
  /// 返回 InlineSpan 列表，用于 RichText 渲染。
  List<InlineSpan> _parseInline(String text, BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final List<InlineSpan> spans = <InlineSpan>[];
    final RegExp regex = RegExp(
      r'(\*\*[^*]+\*\*|`[^`]+`|\[[^\]]+\]\([^)]+\)|\*[^*]+\*)',
    );
    int lastEnd = 0;
    for (final RegExpMatch match in regex.allMatches(text)) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: text.substring(lastEnd, match.start)));
      }
      final String token = match.group(0)!;
      if (token.startsWith('**')) {
        spans.add(TextSpan(
          text: token.substring(2, token.length - 2),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ));
      } else if (token.startsWith('`')) {
        spans.add(TextSpan(
          text: token.substring(1, token.length - 1),
          style: TextStyle(
            fontFamily: 'monospace',
            backgroundColor: Theme.of(context).dividerColor,
          ),
        ));
      } else if (token.startsWith('[')) {
        final RegExpMatch? linkMatch =
            RegExp(r'\[([^\]]+)\]\(([^)]+)\)').firstMatch(token);
        if (linkMatch != null) {
          spans.add(TextSpan(
            text: linkMatch.group(1),
            style: TextStyle(
              color: cs.primary,
              decoration: TextDecoration.underline,
            ),
          ));
        } else {
          spans.add(TextSpan(text: token));
        }
      } else if (token.startsWith('*')) {
        spans.add(TextSpan(
          text: token.substring(1, token.length - 1),
          style: const TextStyle(fontStyle: FontStyle.italic),
        ));
      }
      lastEnd = match.end;
    }
    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }
    return spans;
  }
}

/// 下载进度对话框
///
/// 调用 [ApiService.downloadFile] 获取单个文件字节，
/// 然后通过 [FilePicker.platform.saveFile] 让用户选择保存位置，
/// 写入本地文件后显示结果，1.5 秒后自动关闭。
class _DownloadProgressDialog extends StatefulWidget {
  /// 工作空间 ID
  final String workspaceId;

  /// 工作空间内的文件路径
  final String filePath;

  /// 建议的文件名
  final String filename;

  const _DownloadProgressDialog({
    required this.workspaceId,
    required this.filePath,
    required this.filename,
  });

  @override
  State<_DownloadProgressDialog> createState() =>
      _DownloadProgressDialogState();
}

class _DownloadProgressDialogState extends State<_DownloadProgressDialog> {
  /// 是否正在执行
  bool _isRunning = true;

  /// 结果消息
  String? _result;

  /// 是否成功
  bool _success = false;

  @override
  void initState() {
    super.initState();
    _runTask();
  }

  /// 执行下载任务：获取字节 -> 选择保存路径 -> 写入本地
  Future<void> _runTask() async {
    try {
      // 1. 下载文件字节
      final Uint8List bytes = await ApiService.downloadFile(
        widget.workspaceId,
        widget.filePath,
      );
      if (!mounted) return;

      // 2. 让用户选择保存位置
      final String? savePath = await FilePicker.platform.saveFile(
        dialogTitle: '保存文件',
        fileName: widget.filename,
        bytes: bytes,
      );
      if (!mounted) return;

      if (savePath == null) {
        // 用户取消保存
        setState(() {
          _isRunning = false;
          _result = '已取消';
          _success = false;
        });
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
        return;
      }

      // 3. 写入本地文件
      await File(savePath).writeAsBytes(bytes);

      if (!mounted) return;
      setState(() {
        _isRunning = false;
        _result = '下载完成';
        _success = true;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _isRunning = false;
        _result = e.toString().replaceFirst('Exception: ', '');
        _success = false;
      });
    }
    // 1.5 秒后自动关闭
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('下载文件'),
      content: Row(
        children: [
          if (_isRunning)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(
              _success ? Icons.check_circle : Icons.info_outline,
              size: 20,
              color: _success
                  ? const Color(0xFF10B981)
                  : const Color(0xFFF59E0B),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _isRunning ? '正在下载 ${widget.filename} ...' : (_result ?? ''),
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
