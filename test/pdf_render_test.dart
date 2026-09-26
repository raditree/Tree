import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

/// **真渲染**测试（M7e）：不用假渲染器，直接让 pdfium 打开并光栅化一张最小 PDF。
///
/// 为什么值得单独跑一次：前端渲染方案的全部风险都压在"原生库在目标机器上真的能
/// 加载"这一点上（pdfrx 通过 Dart native assets 带 pdfium；打 Windows 包时它不会
/// 自动进发行目录，见 tool/package_windows.dart 的拷贝步骤）。只测假渲染器等于
/// 把这唯一的风险点绕过去了。
void main() {
  test('pdfium 真渲染：最小 PDF 能打开、页数正确、能渲染出像素', () async {
    final PdfDocument document = await PdfDocument.openData(
      _minimalPdf(),
      sourceName: 'unit-test.pdf',
    );
    expect(document.pages, hasLength(1));
    final PdfPage page = document.pages.first;
    expect(page.width, closeTo(200, 1));
    expect(page.height, closeTo(100, 1));
    final PdfImage? image = await page.render(fullWidth: 200, fullHeight: 100);
    expect(image, isNotNull, reason: 'pdfium 没能渲染出图像');
    expect(image!.width, 200);
    expect(image.pixels, isNotEmpty);
    image.dispose();
    await document.dispose();
  });
}

/// 手搓一张最小可用 PDF（1 页、内含一段文字、xref 偏移量精确计算）。
///
/// 不依赖任何 PDF 库：测试要验证的正是"不靠核心渲染"，自己再造一个 PDF 生成器
/// 反而多一层不可信。
Uint8List _minimalPdf() {
  const String content = 'BT /F1 24 Tf 20 40 Td (Hello) Tj ET\n';
  final List<String> objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] '
        '/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
    '<< /Length ${utf8.encode(content).length} >>\n'
        'stream\n$content'
        'endstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  final StringBuffer out = StringBuffer('%PDF-1.4\n');
  final List<int> offsets = <int>[];
  for (int i = 0; i < objects.length; i++) {
    offsets.add(utf8.encode(out.toString()).length);
    out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final int startxref = utf8.encode(out.toString()).length;
  out.write('xref\n0 ${objects.length + 1}\n');
  out.write('0000000000 65535 f \n');
  for (final int offset in offsets) {
    out.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
    'startxref\n$startxref\n%%EOF\n',
  );
  return Uint8List.fromList(utf8.encode(out.toString()));
}
