import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree/ui/widgets/pdf_preview.dart';

/// PDF 预览（M7e 方案②）的接线测试。
///
/// 为什么用假渲染器：pdfrx 依赖 pdfium 原生库，`flutter test` 环境里没有它。
/// 光栅化是第三方的事，我们只需要保证"拿到的字节与文件名原样交到渲染器手上"、
/// 以及空内容时给可读提示而不是崩掉。
void main() {
  testWidgets('PdfPreview 把字节与文件名交给渲染器', (WidgetTester tester) async {
    final Uint8List bytes = Uint8List.fromList(<int>[37, 80, 68, 70, 45]);
    Uint8List? seenBytes;
    String? seenName;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PdfPreview(
            bytes: bytes,
            fileName: '季度报告.pdf',
            viewBuilder:
                (BuildContext context, Uint8List data, String fileName) {
                  seenBytes = data;
                  seenName = fileName;
                  return const Text('fake-pdf-view');
                },
          ),
        ),
      ),
    );
    expect(find.text('fake-pdf-view'), findsOneWidget);
    expect(seenBytes, same(bytes));
    expect(seenName, '季度报告.pdf');
  });

  testWidgets('filePath 模式：生产走 PdfViewer.file，文件名照样交给渲染器', (
    WidgetTester tester,
  ) async {
    String? seenName;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PdfPreview(
            filePath: '/tmp/tree_preview/a.pdf',
            fileName: 'a.pdf',
            viewBuilder:
                (BuildContext context, Uint8List data, String fileName) {
                  seenName = fileName;
                  return const Text('fake-file-view');
                },
          ),
        ),
      ),
    );
    expect(find.text('fake-file-view'), findsOneWidget);
    expect(seenName, 'a.pdf');
  });

  testWidgets('空字节：可读提示且不调渲染器', (WidgetTester tester) async {
    bool called = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PdfPreview(
            bytes: Uint8List(0),
            fileName: 'empty.pdf',
            viewBuilder:
                (BuildContext context, Uint8List data, String fileName) {
                  called = true;
                  return const SizedBox.shrink();
                },
          ),
        ),
      ),
    );
    expect(find.textContaining('PDF 内容为空'), findsOneWidget);
    expect(called, isFalse);
  });
}
