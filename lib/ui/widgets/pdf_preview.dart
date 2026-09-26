import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

/// 测试注入点：pdfrx 依赖 pdfium 原生库（flutter test 环境里没有），因此渲染器
/// 可替换——测试只关心"字节/路径与文件名有没有交到渲染器手上"，光栅化本身是第三方的事。
typedef PdfViewBuilder = Widget Function(
  BuildContext context,
  Uint8List bytes,
  String fileName,
);

/// PDF 预览（M7e 方案②：**渲染放在前端**；M8c：支持按文件渐进加载）。
///
/// 核心进程只提供 PDF 字节（POST /api/files/{id}/download），光栅化交给
/// Flutter 插件 pdfrx（内置 pdfium）。为什么不让核心渲染：纯 Dart 核心要保持
/// **零第三方依赖**、可 dart compile exe 单文件分发，塞进 PDF 光栅化库等于把几十
/// MB 原生库与许可问题一起带进核心；而前端本来就跑在用户机器上，pdfium 随应用
/// 分发只是一次性代价（tool/package_windows.dart 打出来的包里就有它）。
///
/// 两种输入二选一：
/// - [bytes]：小文件 / 测试（整块字节已在内存里）；
/// - [filePath]：生产路径——查看器先把字节**流式**下载到临时文件（M8c），
///   `PdfViewer.file` 再按文件渐进加载，几百 MB 的 PDF 不必整块进内存。
class PdfPreview extends StatelessWidget {
  const PdfPreview({
    super.key,
    this.bytes,
    this.filePath,
    required this.fileName,
    this.viewBuilder,
  }) : assert(
         bytes != null || filePath != null,
         'PdfPreview 需要 bytes 或 filePath 之一',
       );

  /// PDF 原始字节（小文件 / 测试）。
  final Uint8List? bytes;

  /// PDF 本地文件路径（生产路径：查看器下载到临时文件后传入）。
  final String? filePath;

  /// 文件名：pdfrx 用它标识文档（要求同一文档用同一个名字），也用于错误提示。
  final String fileName;

  /// 渲染器；null = pdfrx（生产路径）。测试传假渲染器以避免依赖 pdfium。
  final PdfViewBuilder? viewBuilder;

  @override
  Widget build(BuildContext context) {
    final PdfViewBuilder? custom = viewBuilder;
    final String? path = filePath;
    if (path != null && path.isNotEmpty) {
      if (custom != null) {
        return custom(context, bytes ?? Uint8List(0), fileName);
      }
      return PdfViewer.file(path, params: _params(context));
    }
    final Uint8List? raw = bytes;
    if (raw == null || raw.isEmpty) {
      return const _PdfHint(
        icon: Icons.picture_as_pdf_outlined,
        message: 'PDF 内容为空，无法预览',
      );
    }
    if (custom != null) return custom(context, raw, fileName);
    return PdfViewer.data(raw, sourceName: fileName, params: _params(context));
  }

  static PdfViewerParams _params(BuildContext context) => PdfViewerParams(
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    // 失败时给中文可读提示，而不是 pdfrx 默认的英文横幅
    errorBannerBuilder: _errorBanner,
  );

  static Widget _errorBanner(
    BuildContext context,
    Object error,
    StackTrace? stackTrace,
    PdfDocumentRef documentRef,
  ) => _PdfHint(icon: Icons.error_outline, message: 'PDF 渲染失败：$error');
}

/// 居中提示块（空文件 / 渲染失败）。
class _PdfHint extends StatelessWidget {
  const _PdfHint({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 40, color: cs.outline),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
