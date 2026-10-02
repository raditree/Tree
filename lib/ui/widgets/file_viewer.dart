import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../io/api_service.dart';
import '../../io/platform_support.dart';
import '../models/file_content.dart';
import '../services/code_highlight.dart';
import '../services/download_center.dart';
import '../services/editor_buffer.dart';
import '../services/editor_settings.dart';
import 'input_style.dart';
import 'pdf_preview.dart';

/// 文本文件扩展名
const List<String> textExtensions = [
  '.txt',
  '.py',
  '.js',
  '.ts',
  '.json',
  '.yaml',
  '.yml',
  '.xml',
  '.csv',
  '.dart',
  '.go',
  '.rs',
  '.sh',
  '.bat',
  '.css',
  '.html',
  '.java',
  '.c',
  '.cpp',
  '.h',
  '.hpp',
  '.cs',
  '.rb',
  '.php',
  '.swift',
  '.kt',
  '.sql',
  '.toml',
  '.ini',
  '.cfg',
  '.conf',
  '.log',
  '.jsx',
  '.tsx',
  '.scss',
];

/// 图片扩展名
const List<String> imageExtensions = [
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.bmp',
  '.webp',
];

/// Markdown 扩展名
const List<String> mdExtensions = ['.md', '.markdown'];

/// SVG 扩展名
const List<String> svgExtensions = ['.svg'];

/// PDF 扩展名
const List<String> pdfExtensions = ['.pdf'];

/// Office 文档扩展名
const List<String> officeExtensions = [
  '.docx',
  '.doc',
  '.odt',
  '.rtf',
  '.pptx',
  '.xlsx',
  '.xls',
];

/// 文件查看器 - 支持多种文件格式的查看与预览
///
/// 根据文件扩展名自动选择合适的查看方式：
/// - 文本 / 源码：**按语言着色**（见 code_highlight.dart），纯文本可直接编辑并保存
///   （Ctrl+S 或标题栏保存键；失焦 / 关窗格 / 换文件时自动保存，可在设置里关）
/// - Markdown：源码 / 预览切换，预览支持基础语法渲染
/// - SVG：源码 / 预览切换（预览暂显示提示与源码）
/// - 图片：通过 base64 解码后用 Image.memory 显示
/// - PDF / Office：显示文件信息与提示，提供下载按钮
///
/// **编辑只限纯文本**（[lib/README.md] 不变量 12）：图片 / PDF / Office 只读，
/// 被截断的大文件（只预览了前一段）与含 NUL 的二进制也只读——把截断的内容写回去
/// 等于把文件截短。保存统一走核心（本机与 SSH 同一套），前端不直接写盘。
///
/// **分屏里同一个文件的两个窗格共用一份 [EditorBuffer]**（同一个控制器 + 一份
/// dirty / saving / loadedSize）：两边都能编辑，一边打字另一边立刻可见，谁保存都只有
/// 一套语义（见 [lib/README.md] 不变量 13）。
class FileViewer extends StatefulWidget {
  /// 工作空间 ID
  final String workspaceId;

  /// 顶层 agent（team）ID，用于后端三模式分派；为空时后端按 workspaceId 兜底
  final String? teamId;

  /// 顶层 agent 显示名（下载列表里标注「来自哪个 team」）。
  final String? teamName;

  /// 文件相对路径
  final String filePath;

  /// 返回回调（用于关闭查看器）
  final VoidCallback? onClose;

  /// 外部强制只读（其它调用方与测试用；分屏**不再**用它锁第二个窗格）
  final bool readOnly;

  /// 外部强制只读的原因（显示在锁图标与正文提示条上）
  final String readOnlyReason;

  /// 这份文档的**共享编辑缓冲**。
  ///
  /// 同一个路径的多个窗格传**同一个实例** ⇒ 两边共用一个控制器与一份
  /// dirty / saving / loadedSize（见 [EditorBuffer]），这就是"一个文件一份文档、
  /// 两个视图"。为 null 时本控件自己 new 一份并**自己负责 dispose**
  /// （既有调用方与测试零改动）；外部传入的那份由传入者释放（文件面板按路径持有）。
  final EditorBuffer? buffer;

  /// 非阻断的窗格提示（同文件双开时说明两侧共享同一份缓冲；空串 = 不显示）
  final String paneNotice;

  const FileViewer({
    super.key,
    required this.workspaceId,
    this.teamId,
    this.teamName,
    required this.filePath,
    this.onClose,
    this.readOnly = false,
    this.readOnlyReason = '',
    this.buffer,
    this.paneNotice = '',
  });

  @override
  State<FileViewer> createState() => FileViewerState();
}

/// 文件类型分类
enum _FileType { text, markdown, svg, image, pdf, office, unknown }

/// 查看器状态。**公开**是为了让分屏（file_panel）能用 GlobalKey 在换文件 / 关窗格
/// 前调 [confirmLeave]——未保存的内容必须先处理掉。
class FileViewerState extends State<FileViewer> {
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

  /// PDF 本地临时文件路径（M8c：流式下载到临时文件，pdfrx 按文件渐进加载）
  String? _pdfPath;

  /// PDF 总页数（来自核心的启发式 pdf_info，仅用于信息栏展示）
  int _totalPages = 0;

  /// 这份文档的共享编辑缓冲：外部传入的就用它，否则自己 new 一份（见 [_bindBuffer]）
  late EditorBuffer _buf;

  /// 自己 new 的那份缓冲（widget.buffer == null 时）；外部传入的由持有者释放
  EditorBuffer? _ownBuf;

  /// 编辑器控制器（可编辑时才有）。带高亮，见 code_highlight.dart。
  ///
  /// 委托到共享缓冲：控制器归缓冲所有，换窗格 / 换文件都不在这里释放。
  CodeEditingController? get _editor => _buf.controller;
  set _editor(CodeEditingController? value) => _buf.controller = value;

  /// 文本域的焦点节点：失焦就是「切走」，触发自动保存
  final FocusNode _editorFocus = FocusNode();

  /// 是否有未保存的改动（共享：任一窗格改了，两边都是未保存态）
  bool get _dirty => _buf.dirty;
  set _dirty(bool value) => _buf.dirty = value;

  /// 是否正在保存（共享，挡住重复提交：一次保存 = 一次 HTTP + 一次落盘）
  bool get _saving => _buf.saving;
  set _saving(bool value) => _buf.saving = value;

  /// 加载时文件的**真实**字节数：保存时作为 if_size 做外部改动检测（共享）
  int get _loadedSize => _buf.loadedSize;
  set _loadedSize(int value) => _buf.loadedSize = value;

  /// 内容被截断（大文件只回了前一段）⇒ 只读
  bool _truncated = false;

  /// 内容含 NUL ⇒ 二进制 ⇒ 只读
  bool _isBinary = false;

  /// 上一次保存失败的可见原因（挂在标题栏状态行上，不指望用户看见 SnackBar）
  String? _saveError;

  @override
  void initState() {
    super.initState();
    _bindBuffer();
    _editorFocus.addListener(_onEditorBlur);
    _startLoad();
  }

  /// 绑定这份文档的共享缓冲：外部传入就用它（同一个文件的两个窗格就是同一个实例），
  /// 否则自己 new 一份并自己负责 dispose。
  void _bindBuffer() {
    _ownBuf = widget.buffer == null ? EditorBuffer() : null;
    _buf = widget.buffer ?? _ownBuf!;
    _buf.addListener(_onBufferChanged);
  }

  /// 缓冲变了（另一个窗格在打字 / 保存）：本窗格跟着重建。
  ///
  /// 只重建，不在这里改缓冲——否则会在别的窗格的通知里再触发一轮通知。
  void _onBufferChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// 换文件：丢掉旧缓冲与编辑态，重新加载。
  ///
  /// 调用方（file_panel）在换之前已经问过 [confirmLeave]，所以这里不弹确认框。
  @override
  void didUpdateWidget(covariant FileViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath == widget.filePath &&
        oldWidget.workspaceId == widget.workspaceId &&
        identical(oldWidget.buffer, widget.buffer)) {
      return;
    }
    // 换缓冲：旧的解绑。**自己 new 的那份**随旧文档一起作废（下一帧回收：本帧
    // TextField 还在用它换 controller）；外部传入的那份归持有者（文件面板），
    // 另一个窗格可能还在用，绝不能在这里 dispose。
    _buf.removeListener(_onBufferChanged);
    final EditorBuffer? orphan = _ownBuf;
    if (widget.buffer != null) {
      _ownBuf = null;
      _buf = widget.buffer!;
    } else {
      _ownBuf = EditorBuffer();
      _buf = _ownBuf!;
    }
    _buf.addListener(_onBufferChanged);
    if (orphan != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => orphan.dispose());
    }
    // 只清**本窗格**自己的态：控制器 / dirty / saving / loadedSize 是共享缓冲的，
    // 新文档有它自己的那份（上面刚绑好）。
    _saveError = null;
    _content = '';
    _truncated = false;
    _isBinary = false;
    _showPreview = true;
    // 不在这里写共享缓冲的只读理由：此刻本窗格还没加载，算出来的"可编辑"可能是错的，
    // 而 target 缓冲对同一个路径本来就存着正确的那条（没有就等加载完成后再写，见
    // [_publishBufferReason]）。
    _startLoad();
  }

  /// 按类型分派加载
  void _startLoad() {
    // Office 为二进制格式，不支持预览，直接结束加载状态
    if (_fileType == _FileType.office) {
      setState(() {
        _isLoading = false;
      });
      // 这里跑在 build 里（initState / didUpdateWidget 直接调过来）：帧后再写
      _publishBufferReasonAfterFrame();
    } else if (_fileType == _FileType.pdf) {
      // PDF：核心给字节，前端用 pdfrx 渲染（M7e 方案②）
      unawaited(_loadPdf());
    } else {
      unawaited(_loadContent());
    }
  }

  /// 失焦即是「切走」：开了失焦保存就把改动写回去（不做定时器，见 EditorSettings）
  void _onEditorBlur() {
    if (!mounted) return;
    if (_editorFocus.hasFocus || !_dirty) return;
    if (!EditorSettings.instance.saveOnBlur) return;
    // 正在保存 / 正等用户决定冲突：别再加一次（弹冲突框会让焦点走掉，
    // 不挡的话会再发一次注定 409 的写，甚至叠出第二个框）
    if (_saving) return;
    unawaited(_save(silent: true));
  }

  /// 清掉 PDF 预览留下的临时目录（M8c：预览走临时文件，退出时要删）。
  void _cleanupPdfTemp() {
    final Directory? dir = _pdfPath == null ? null : File(_pdfPath!).parent;
    _pdfPath = null;
    if (dir == null) return;
    try {
      // 只删自己建的 tree_dl_ 前缀目录，避免误删用户文件
      if (dir.existsSync() && dir.path.contains('tree_dl_')) {
        dir.deleteSync(recursive: true);
      }
    } catch (_) {
      // 临时目录清理失败不影响预览结果
    }
  }

  @override
  void dispose() {
    _editorFocus.removeListener(_onEditorBlur);
    // 关窗格 / 切文件时还有未保存内容：开了失焦保存就补一次静默写。
    // 参数先取出来——这个 future 可能在 State unmount 之后才跑完，那时不许再碰 widget。
    final CodeEditingController? editor = _editor;
    if (_dirty && editor != null && EditorSettings.instance.saveOnBlur) {
      unawaited(_writeQuietly(
        workspaceId: widget.workspaceId,
        teamId: widget.teamId ?? '',
        path: widget.filePath,
        content: editor.text,
        ifSize: _loadedSize,
      ));
    }
    _cleanupPdfTemp();
    // 控制器归共享缓冲所有：外部传入的缓冲由持有者（文件面板）在没有窗格再引用它时
    // 释放，**不能**被先关掉的那个窗格 dispose 掉；只有自己 new 的那份跟着本 State 走。
    _buf.removeListener(_onBufferChanged);
    _ownBuf?.dispose();
    _editorFocus.dispose();
    super.dispose();
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
  ///
  /// [reload] = 这份文档已经在编辑（刷新 / 409 的"放弃我的改动并刷新"）：允许用磁盘
  /// 内容**覆盖**共享缓冲。普通加载（含同文件第二个窗格的首载）只读磁盘，
  /// 绝不用重读到的旧内容把另一个窗格正在编辑的那份重建或清掉。
  Future<void> _loadContent({bool reload = false}) async {
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
      // 用带元信息的接口：编辑要 size（外部改动检测）与 truncated（截断只读）
      final FileContentInfo info = await ApiService.getFileContentInfo(
        widget.workspaceId,
        widget.filePath,
        teamId: widget.teamId ?? '',
      );
      if (!mounted) return;
      if (type == _FileType.image) {
        // 图片内容按 base64 解码
        final Uint8List? bytes = _decodeBase64(info.content);
        if (bytes == null) {
          setState(() {
            _error = '图片解码失败，后端可能未返回 base64 编码内容';
            _isLoading = false;
          });
          return;
        }
        setState(() {
          _imageBytes = bytes;
          _content = info.content;
          _loadedSize = info.size;
          _isLoading = false;
        });
        _publishBufferReason();
      } else {
        final CodeEditingController? open = _buf.controller;
        setState(() {
          // 同一份文档已在别的窗格打开：预览 / 复制看到的是**共享缓冲**里那份，
          // 不是刚读回来的旧磁盘内容（reload 例外——那正是要回到盘上那一份）。
          _content = (open != null && !reload) ? open.text : info.content;
          _loadedSize = info.size;
          _truncated = info.truncated;
          _isBinary = info.content.contains('\u0000');
          _isLoading = false;
        });
        _publishBufferReason();
        _prepareEditor(reload: reload);
      }
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _isLoading = false;
      });
    }
  }

  /// 加载 PDF（M7e 方案② + M8c 流式）：核心提供元信息与字节，渲染交给前端 pdfrx。
  ///
  /// 字节**流式下载到临时文件**再交给 pdfrx：`PdfViewer.file` 能按文件渐进加载，
  /// 几百 MB 的 PDF 不必先整个读进内存（旧的 `downloadFile` 会把整文件读进 RAM）。
  Future<void> _loadPdf() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> info = await ApiService.getPdfInfo(
        widget.workspaceId,
        widget.filePath,
        teamId: widget.teamId ?? '',
      );
      final String path = await ApiService.downloadFileToTemp(
        widget.workspaceId,
        widget.filePath,
        teamId: widget.teamId ?? '',
      );
      if (!mounted) return;
      _cleanupPdfTemp();
      setState(() {
        _totalPages = (info['total_pages'] as num?)?.toInt() ?? 0;
        _pdfPath = path;
        _isLoading = false;
      });
      _publishBufferReason();
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
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
      const SnackBar(content: Text('已复制到剪贴板'), duration: Duration(seconds: 2)),
    );
  }

  /// 下载文件（单个文件，走流式 + 左栏「下载」列表）
  ///
  /// M8d：选保存目录后交给 [DownloadCenter] 后台流式落盘，进度与取消都在下载列表里。
  Future<void> _downloadFile() async {
    if (isMobile) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('移动端暂不支持保存到本地文件系统，请到桌面端下载')));
      return;
    }
    final String filename = widget.filePath.split('/').last;
    final String? dirPath = await FilePicker.getDirectoryPath(
      dialogTitle: '选择保存目录',
    );
    if (dirPath == null || dirPath.isEmpty) return;
    if (!mounted) return;
    final String savePath = '$dirPath${Platform.pathSeparator}$filename';
    unawaited(
      DownloadCenter.instance.startFileDownload(
        workspaceId: widget.workspaceId,
        path: widget.filePath,
        savePath: savePath,
        name: filename,
        sourceTeam: widget.teamName ?? '',
        sourceTeamId: widget.teamId ?? '',
        teamId: widget.teamId ?? '',
      ),
    );
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已加入下载列表：$filename')));
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
          // 非阻断的窗格提示（同文件双开：说明两侧共享同一份缓冲，不挡编辑）
          if (widget.paneNotice.isNotEmpty) _buildPaneNotice(),
          // 内容区域
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  /// 窗格提示条：一条**不挡编辑**的说明（与只读提示条的区别是谁都能继续写）
  Widget _buildPaneNotice() {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      color: cs.primary.withValues(alpha: 0.08),
      child: Row(
        children: <Widget>[
          Icon(Icons.sync_alt, size: 13, color: cs.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              widget.paneNotice,
              style: TextStyle(fontSize: 11, color: cs.primary),
            ),
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
    final bool canToggle = type == _FileType.markdown || type == _FileType.svg;
    final bool canCopy = !_isLoading && _error == null && _content.isNotEmpty;
    final bool canRefresh = type != _FileType.pdf && type != _FileType.office;
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          // 返回按钮（先把未保存内容处理掉再关）
          if (widget.onClose != null)
            IconButton(
              icon: const Icon(Icons.arrow_back, size: 20),
              color: cs.onSurfaceVariant,
              tooltip: '返回',
              onPressed: () => unawaited(_handleClose()),
            ),
          // 文件名 + 语言标签 + 路径 / 状态
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        _fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                    if (_showLanguageTag) ...<Widget>[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: cs.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          _language.label,
                          style: TextStyle(fontSize: 10, color: cs.primary),
                        ),
                      ),
                    ],
                    if (!_editableFile && !_isLoading) ...<Widget>[
                      const SizedBox(width: 6),
                      Tooltip(
                        message: _readOnlyReason,
                        child: Icon(
                          Icons.lock_outline,
                          size: 13,
                          color: cs.outline,
                        ),
                      ),
                    ],
                  ],
                ),
                if (widget.filePath.isNotEmpty)
                  Text(
                    _subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: _saveError != null
                          ? cs.error
                          : (_dirty ? cs.primary : cs.outline),
                    ),
                  ),
              ],
            ),
          ),
          // 保存（有未保存改动时才可点，键位是 Ctrl+S）
          if (_editor != null)
            IconButton(
              icon: Icon(
                _dirty ? Icons.save : Icons.save_outlined,
                size: 18,
              ),
              color: _dirty ? cs.primary : cs.onSurfaceVariant,
              tooltip: _dirty ? '保存（Ctrl+S）' : '没有未保存的改动',
              onPressed:
                  (_dirty && !_saving) ? () => unawaited(_save()) : null,
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
              tooltip: '刷新（重新读盘，放弃未保存的改动）',
              onPressed:
                  _isLoading ? null : () => unawaited(_loadContent(reload: true)),
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
        return _showPreview ? _buildMarkdownPreview() : _buildCodeView();
      case _FileType.svg:
        return _showPreview ? _buildSvgPreview() : _buildCodeView();
      case _FileType.pdf:
        return _buildPdfView();
      case _FileType.office:
        return _buildOfficeView();
      case _FileType.text:
      case _FileType.unknown:
        return _buildCodeView();
    }
  }

  /// 着色语言（按扩展名；认不出来是纯文本语言，不着色）
  CodeLanguage get _language => languageForPath(widget.filePath);

  /// 标题栏要不要显示语言标签：认得出语言、且这个类型确实走代码视图
  bool get _showLanguageTag {
    if (_language.id == 'plain') return false;
    switch (_fileType) {
      case _FileType.image:
      case _FileType.pdf:
      case _FileType.office:
        return false;
      case _FileType.markdown:
      case _FileType.svg:
        return !_showPreview;
      case _FileType.text:
      case _FileType.unknown:
        return true;
    }
  }

  /// 这个文件**允许**编辑吗：只看类型与内容特征，不看控制器是否就绪。
  ///
  /// 拒绝的四类情况（见 lib/README.md 不变量 12）：图片 / PDF / Office（复杂格式）、
  /// 被截断的大文件（写回去会把文件截短）、含 NUL 的二进制、以及外部显式传入的
  /// readOnly。**同文件双开不在其中**——那两个窗格共享同一份缓冲，两边都能编辑。
  bool get _editableFile =>
      _readOnlyReason.isEmpty && !_isLoading && _error == null;

  /// 只读原因（空串 = 可编辑）：外部强制只读优先；否则以共享缓冲里那条**跟着文件走**
  /// 的理由为准（同一个文件的两个窗格同一条），缓冲里还没有就按当前已知信息自己算一条。
  String get _readOnlyReason {
    if (widget.readOnly) {
      return widget.readOnlyReason.isEmpty ? '只读打开' : widget.readOnlyReason;
    }
    final String shared = _buf.readOnlyReason;
    return shared.isNotEmpty ? shared : _documentReadOnlyReason;
  }

  /// 这份**文档自身**不能编辑的原因（空串 = 可编辑）；外部 readOnly 不在这里判
  String get _documentReadOnlyReason {
    switch (_fileType) {
      case _FileType.image:
        return '图片不支持编辑';
      case _FileType.pdf:
        return 'PDF 不支持编辑（复杂格式不在编辑范围内，需要下载后用专用工具改）';
      case _FileType.office:
        return 'Office 文档不支持编辑（复杂格式不在编辑范围内，需要下载后用专用工具改）';
      case _FileType.markdown:
      case _FileType.svg:
      case _FileType.text:
      case _FileType.unknown:
        if (_truncated) {
          return '文件较大，只预览了前一段：保存会把文件截短，因此只读（完整内容请下载）';
        }
        if (_isBinary) return '内容含二进制字节，按只读打开';
        return '';
    }
  }

  /// 把这条**跟着文件走**的只读理由记进共享缓冲：同一个文件的两个窗格用同一条理由，
  /// 而不是各算各的（值没变时缓冲不通知，所以不会多出一次重建）。
  ///
  /// 只在**异步**路径（加载完成之后）调用：写缓冲会通知另一个窗格重建，
  /// build 期间通知会撞上"build 期间 markNeedsBuild"，那种场合走
  /// [_publishBufferReasonAfterFrame]。
  void _publishBufferReason() {
    _buf.readOnlyReason = _documentReadOnlyReason;
  }

  /// 帧后再把只读理由记进共享缓冲（initState / didUpdateWidget / _startLoad 跑在 build 里）。
  ///
  /// 到帧后**重算**一次（此时加载结果可能已经落地），值没变时缓冲自己就不通知。
  void _publishBufferReasonAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _publishBufferReason();
    });
  }

  /// 造 / 更新编辑器控制器（可编辑时才有）。
  ///
  /// **控制器只建一次**：同一个文件在第二个窗格里打开时缓冲里已经有控制器了，必须复用
  /// （另一个窗格可能已经在编辑），绝不能用刚读回来的磁盘内容把它重建或清掉。
  /// [reload] = 刷新 /「放弃我的改动并刷新」：这时才允许用磁盘内容覆盖，
  /// 两个窗格一起回到盘上那一份。
  void _prepareEditor({bool reload = false}) {
    if (!_editableFile) return;
    final CodeEditingController? open = _editor;
    if (open == null) {
      // 走 _editor 的 setter：控制器归共享缓冲所有（换文件 / 换窗格都不在这里释放）
      _editor = CodeEditingController(language: _language, text: _content);
      return;
    }
    if (!reload) return;
    open.text = _content;
    _saveError = null;
    _buf.dirty = false;
  }

  /// 标题栏副标题：优先报「保存失败 / 未保存」，否则给路径
  String get _subtitle {
    if (_saveError != null) return '保存失败：$_saveError';
    if (_dirty) return '未保存的改动 · ${widget.filePath}';
    return widget.filePath;
  }

  /// Ctrl/Cmd+S 保存；其它按键一律不拦（回车、Tab、撤销都留给文本域自己）
  KeyEventResult _handleEditorKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey != LogicalKeyboardKey.keyS) {
      return KeyEventResult.ignored;
    }
    final Set<LogicalKeyboardKey> pressed =
        HardwareKeyboard.instance.logicalKeysPressed;
    final bool modifier = pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight) ||
        pressed.contains(LogicalKeyboardKey.metaLeft) ||
        pressed.contains(LogicalKeyboardKey.metaRight);
    if (!modifier) return KeyEventResult.ignored;
    unawaited(_save());
    return KeyEventResult.handled;
  }

  /// 保存当前内容；返回是否已保存。
  ///
  /// [force] = 覆盖保存（外部改动确认之后）；[silent] = 自动保存，成功不弹提示。
  Future<bool> _save({bool force = false, bool silent = false}) async {
    final CodeEditingController? editor = _editor;
    if (editor == null || _saving) return false;
    if (!_dirty && !force) return true;
    final String content = editor.text;
    _saving = true;
    if (mounted) {
      setState(() {
        _saveError = null;
      });
    }
    try {
      final int written = await ApiService.saveFileContent(
        widget.workspaceId,
        widget.filePath,
        content,
        teamId: widget.teamId ?? '',
        ifSize: force ? null : _loadedSize,
        force: force,
      );
      _saving = false;
      if (mounted) {
        setState(() {
          _dirty = false;
          _loadedSize = written;
          _truncated = false;
        });
      }
      if (!silent) _toast('已保存（$written 字节）');
      return true;
    } on FileWriteConflict catch (conflict) {
      if (!mounted) {
        _saving = false;
        return false;
      }
      // 冲突框挂着期间保持 _saving：用户还在决定，别让失焦保存插一次进来。
      // 但**重试之前必须先放开**，否则覆盖保存会被自己挡掉（_saving 还是 true）。
      final String action = await _askConflict(conflict);
      _saving = false;
      if (action == 'overwrite') return _save(force: true);
      if (action == 'reload') await _loadContent(reload: true);
      return false;
    } catch (error) {
      _saving = false;
      final String reason = error.toString().replaceFirst('Exception: ', '');
      if (mounted) {
        setState(() {
          _saveError = reason;
        });
      }
      if (!silent) _toast('保存失败：$reason');
      return false;
    }
  }

  /// 409 冲突问用户：返回 'overwrite' / 'reload' / 'cancel'（由调用方决定下一步）
  Future<String> _askConflict(FileWriteConflict conflict) async {
    final String size = conflict.missing
        ? '文件已不存在'
        : '${conflict.currentSize} 字节';
    final String? choice = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('文件已被外部修改'),
        content: Text(
          '${conflict.detail}\n\n磁盘上的当前内容：$size\n你手上的改动：${_editor?.text.length ?? 0} 字符',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop('cancel'),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('reload'),
            child: const Text('放弃我的改动并刷新'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('overwrite'),
            child: const Text('覆盖保存'),
          ),
        ],
      ),
    );
    return choice ?? 'cancel';
  }

  /// 离开当前文件前的收尾（关窗格 / 换文件 / 关查看器都走它）。
  ///
  /// 开着失焦保存：静默写回，返回写成功与否；关着：问一次（保存 / 不保存 / 取消）。
  Future<bool> confirmLeave() async {
    if (!_dirty) return true;
    if (EditorSettings.instance.saveOnBlur) return _save(silent: true);
    final String? choice = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('还有未保存的改动'),
        content: Text('$_fileName 有未保存的改动。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop('cancel'),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('discard'),
            child: const Text('不保存'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('save'),
            child: const Text('保存并继续'),
          ),
        ],
      ),
    );
    if (choice == 'save') return _save();
    return choice == 'discard';
  }

  /// 返回：先把未保存内容处理掉再关（开着失焦保存就静默写回）
  Future<void> _handleClose() async {
    final VoidCallback? onClose = widget.onClose;
    if (onClose == null) return;
    final bool canLeave = await confirmLeave();
    if (canLeave && mounted) onClose();
  }

  /// dispose 里的静默补写：不能 setState、不需要回报。
  ///
  /// 参数全部显式传入：这个 future 可能在 State unmount 之后才跑完，那时不许再碰 widget。
  Future<void> _writeQuietly({
    required String workspaceId,
    required String teamId,
    required String path,
    required String content,
    required int ifSize,
  }) async {
    try {
      await ApiService.saveFileContent(
        workspaceId,
        path,
        content,
        teamId: teamId,
        ifSize: ifSize,
      );
    } catch (_) {
      // 关窗格时的补写失败只能放弃：此刻已经没有界面可以提示了
    }
  }

  /// 轻提示（保存成功 / 失败兜底）
  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
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
            const Icon(Icons.error_outline, size: 40, color: Color(0xFFEF4444)),
            const SizedBox(height: 8),
            Text(
              message,
              style: TextStyle(color: cs.outline, fontSize: 13),
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
  Widget _buildCodeView() {
    if (_content.isEmpty && !_editableFile) {
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
    final ColorScheme cs = Theme.of(context).colorScheme;
    final TextStyle baseStyle = TextStyle(
      fontSize: 13,
      height: 1.5,
      fontFamily: 'Consolas',
      fontFamilyFallback: const <String>['Cascadia Mono', 'monospace'],
      color: cs.onSurface,
    );
    final CodeEditingController? editor = _editor;
    // 可编辑：文本域（带高亮控制器）。expands + maxLines:null 让它铺满窗格并自己滚动。
    if (_editableFile && editor != null) {
      return Focus(
        onKeyEvent: _handleEditorKey,
        child: TextField(
          controller: editor,
          focusNode: _editorFocus,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          style: baseStyle,
          cursorColor: cs.primary,
          // 编辑器自己的框由外层窗格画；这里必须显式清掉主题的 enabled/focused 边框
          // （只写 border: none 会被 inputDecorationTheme 覆盖回来，见 input_style.dart）
          decoration: kBorderlessInput.copyWith(
            isDense: true,
            contentPadding: const EdgeInsets.all(12),
          ),
          onChanged: (String _) {
            if (!_dirty) {
              setState(() {
                _dirty = true;
              });
            }
          },
        ),
      );
    }
    // 只读：同样按语言着色（着色开关关掉就退回单色），可选可复制
    final bool highlight = EditorSettings.instance.highlight;
    final TextSpan span = highlight
        ? buildCodeTextSpan(
            text: _content,
            language: _language,
            theme: CodeTheme.of(context),
            baseStyle: baseStyle,
          )
        : TextSpan(style: baseStyle, text: _content);
    final String reason = _readOnlyReason;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (reason.isNotEmpty) _buildReadOnlyBanner(cs, reason),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SelectableText.rich(span),
          ),
        ),
      ],
    );
  }

  /// 只读提示条：说清**为什么**不能编辑（不然用户只会觉得保存键坏了）
  Widget _buildReadOnlyBanner(ColorScheme cs, String reason) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
      child: Row(
        children: <Widget>[
          Icon(Icons.lock_outline, size: 13, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              reason,
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
            ),
          ),
        ],
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

  /// PDF 视图（M7e：**前端渲染**，pdfrx/pdfium）
  ///
  /// 核心只给字节；滚动、缩放、翻页、文本选择复制都由 pdfrx 处理——比"核心逐页
  /// 渲染成 PNG"少一次往返，也不再需要自绘页码导航。
  Widget _buildPdfView() {
    final String? path = _pdfPath;
    if (path == null) return _buildErrorView('PDF 内容为空');
    return Column(
      children: [
        Expanded(
          child: PdfPreview(filePath: path, fileName: _fileName),
        ),
        Container(
          height: 34,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              top: BorderSide(color: Theme.of(context).dividerColor, width: 1),
            ),
          ),
          child: Text(
            _totalPages > 0 ? '$_totalPages 页 · 可滚动缩放、选中文字复制' : '可滚动缩放、选中文字复制',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
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
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: cs.onSurfaceVariant,
                  ),
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
          Text('$label：', style: TextStyle(fontSize: 12, color: cs.outline)),
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
        final RegExpMatch? orderedMatch = RegExp(r'^(\d+)\.\s+(.*)')
            .firstMatch(line);
        if (orderedMatch != null) {
          widgets.add(
            _buildListItem(
              orderedMatch.group(2)!,
              true,
              number: orderedMatch.group(1)!,
              context: context,
            ),
          );
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
        border: Border(left: BorderSide(color: cs.primary, width: 3)),
        borderRadius: const BorderRadius.only(
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
        spans.add(
          TextSpan(
            text: token.substring(2, token.length - 2),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        );
      } else if (token.startsWith('`')) {
        spans.add(
          TextSpan(
            text: token.substring(1, token.length - 1),
            style: TextStyle(
              fontFamily: 'monospace',
              backgroundColor: Theme.of(context).dividerColor,
            ),
          ),
        );
      } else if (token.startsWith('[')) {
        final RegExpMatch? linkMatch = RegExp(r'\[([^\]]+)\]\(([^)]+)\)')
            .firstMatch(token);
        if (linkMatch != null) {
          spans.add(
            TextSpan(
              text: linkMatch.group(1),
              style: TextStyle(
                color: cs.primary,
                decoration: TextDecoration.underline,
              ),
            ),
          );
        } else {
          spans.add(TextSpan(text: token));
        }
      } else if (token.startsWith('*')) {
        spans.add(
          TextSpan(
            text: token.substring(1, token.length - 1),
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        );
      }
      lastEnd = match.end;
    }
    if (lastEnd < text.length) {
      spans.add(TextSpan(text: text.substring(lastEnd)));
    }
    return spans;
  }
}
