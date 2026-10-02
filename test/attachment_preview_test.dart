import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/widgets/attachment_preview.dart';

/// 1x1 透明 PNG（只证明图片走缩略图/原图那条路，不校验像素）
const String kTinyPngB64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==';

/// 附件预览（本机文件）：分类、大小文案、三档读取，以及对话框本身。
///
/// 为什么盯这里：输入框里的附件在发送前是**本机**路径，预览只能读本地文件；
/// 读不到时必须是"看得懂的提示"，而不是乱码、0 B 或红色报错。
void main() {
  group('扩展名分类（纯函数）', () {
    test('是不是图片看扩展名，大小写不敏感', () {
      expect(attachmentIsImage(r'C:\tmp\图.PNG'), isTrue);
      expect(attachmentIsImage('a/b.jpeg'), isTrue);
      expect(attachmentIsImage('a/b.txt'), isFalse);
      expect(attachmentIsImage('a/b'), isFalse);
    });

    test('文本类扩展名与附件名（兼容 / 与 \\）', () {
      expect(attachmentIsText('a/b.dart'), isTrue);
      expect(attachmentIsText(r'a\b.md'), isTrue);
      expect(attachmentIsText('a/b.exe'), isFalse);
      expect(attachmentName(r'C:\tmp\x\报告.docx'), '报告.docx');
      // 以分隔符结尾时原样返回整串，不返回空串（空串会让界面显示成"没有名字"）
      expect(attachmentName('a/b/'), 'a/b/');
    });

    test('图标按扩展名分类，认不出来给通用文件图标', () {
      expect(attachmentIcon('a.png'), Icons.image_outlined);
      expect(attachmentIcon('a.dart'), Icons.description_outlined);
      expect(attachmentIcon('a.pdf'), Icons.picture_as_pdf_outlined);
      expect(attachmentIcon('a.zip'), Icons.folder_zip_outlined);
      expect(attachmentIcon('a.xyz'), Icons.insert_drive_file_outlined);
    });

    test('大小文案：空文件是 0 B，读不到才是"大小未知"', () {
      expect(formatFileSize(-1), '大小未知');
      expect(formatFileSize(0), '0 B');
      expect(formatFileSize(512), '512 B');
      expect(formatFileSize(2048), '2.0 KB');
      expect(formatFileSize(20 * 1024 * 1024), '20 MB');
    });
  });

  group('AttachmentPreviewData.read（真实文件）', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('tree_preview_test');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    /// 临时目录里的一个路径（Dart 的 File 在 Windows 上也认 '/'）
    String p(String name) => '${dir.path}/$name';

    test('文本文件按内容读出，大小对得上', () async {
      await File(p('note.txt')).writeAsString('你好，附件');
      final AttachmentPreviewData d =
          await AttachmentPreviewData.read(p('note.txt'));
      expect(d.kind, AttachmentPreviewKind.text);
      expect(d.text, '你好，附件');
      expect(d.size, utf8.encode('你好，附件').length);
      expect(d.truncated, isFalse);
    });

    test('超过 256 KB 只读前一段，并标注已截断', () async {
      await File(p('big.log'))
          .writeAsBytes(List<int>.filled(kPreviewTextLimit + 1024, 0x61));
      final AttachmentPreviewData d =
          await AttachmentPreviewData.read(p('big.log'));
      expect(d.kind, AttachmentPreviewKind.text);
      expect(d.text.length, kPreviewTextLimit);
      expect(d.truncated, isTrue, reason: '必须让用户知道后面还有内容');
      expect(d.size, kPreviewTextLimit + 1024);
    });

    test('没有扩展名但没有 NUL：照样当文本读', () async {
      await File(p('Makefile')).writeAsString('all:\n\techo hi\n');
      final AttachmentPreviewData d =
          await AttachmentPreviewData.read(p('Makefile'));
      expect(d.kind, AttachmentPreviewKind.text);
      expect(d.text, contains('echo hi'));
    });

    test('头部有 NUL：扩展名说是文本也不算数，按二进制', () async {
      await File(p('weird.txt')).writeAsBytes(<int>[0x61, 0x00, 0x62]);
      final AttachmentPreviewData d =
          await AttachmentPreviewData.read(p('weird.txt'));
      expect(d.kind, AttachmentPreviewKind.binary,
          reason: '按字节判文本，才不会被骗着渲染乱码');
      expect(d.size, 3);
    });

    test('图片走图片分支', () async {
      await File(p('pixel.png')).writeAsBytes(base64Decode(kTinyPngB64));
      final AttachmentPreviewData d =
          await AttachmentPreviewData.read(p('pixel.png'));
      expect(d.kind, AttachmentPreviewKind.image);
      expect(d.size, greaterThan(0));
    });

    test('空文件是空文本，不是二进制', () async {
      await File(p('empty.txt')).writeAsBytes(<int>[]);
      final AttachmentPreviewData d =
          await AttachmentPreviewData.read(p('empty.txt'));
      expect(d.kind, AttachmentPreviewKind.text);
      expect(d.text, isEmpty);
    });

    test('文件不存在：missing 且带得出原因', () async {
      final AttachmentPreviewData d =
          await AttachmentPreviewData.read(p('nope.txt'));
      expect(d.kind, AttachmentPreviewKind.missing);
      expect(d.note, contains('不存在'));
    });

    test('目录：当二进制并说明这是文件夹', () async {
      final AttachmentPreviewData d =
          await AttachmentPreviewData.read(dir.path);
      expect(d.kind, AttachmentPreviewKind.binary);
      expect(d.note, contains('文件夹'));
    });
  });

  group('预览对话框', () {
    late Directory dir;

    // 同步 IO：这一组是 testWidgets（跑在假时钟里），await 文件操作永远不返回
    setUp(() {
      dir = Directory.systemTemp.createTempSync('tree_preview_dialog_test');
    });

    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {
        // 删不掉就算了：清理失败不该把一个跑完的用例判成失败
      }
    });

    String p(String name) => '${dir.path}/$name';

    /// 摆上对话框并把**真实文件 IO** 放行。
    ///
    /// widget 测试跑在假时钟里：真实 IO 的回调躺在假队列里，而不动事件循环它就
    /// 永远不动。读一个文件是好几步（stat → open → length → read），每圈只能推
    /// 进一步，所以「转一圈真实事件循环 → pump 一次」要重复几圈；一圈不够时
    /// 对话框会一直停在转圈的加载态（别用 pumpAndSettle 等 IO，它会转到超时）。
    Future<void> pumpDialog(WidgetTester tester, String path) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AttachmentPreviewDialog(path: path)),
      ));
      await tester.pump();
      for (int i = 0; i < 10; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)));
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 350));
    }

    testWidgets('文本文件：内容直接看得见，标题给名字', (WidgetTester tester) async {
      File(p('note.txt')).writeAsStringSync('预览里的内容');

      await pumpDialog(tester, p('note.txt'));

      final SelectableText body =
          tester.widget<SelectableText>(find.byType(SelectableText).last);
      expect(body.data, '预览里的内容');
      expect(find.text('note.txt'), findsOneWidget);
      expect(find.text('在文件夹中显示'), findsOneWidget);
    });

    testWidgets('文件不存在：给出可见原因，且不允许"在文件夹中显示"',
        (WidgetTester tester) async {
      await pumpDialog(tester, p('nope.txt'));

      expect(find.text('文件不存在或已被移动'), findsOneWidget);
      final TextButton reveal = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '在文件夹中显示'),
      );
      expect(reveal.onPressed, isNull,
          reason: 'explorer 对不存在的路径毫无反馈，别让人白点');
    });

    testWidgets('二进制：说明不能预览，路径照给', (WidgetTester tester) async {
      File(p('blob.dat')).writeAsBytesSync(<int>[0x00, 0x01, 0x02]);

      await pumpDialog(tester, p('blob.dat'));

      expect(find.text('这个文件不能在应用内预览'), findsOneWidget);
      final SelectableText shown =
          tester.widget<SelectableText>(find.byType(SelectableText));
      expect(shown.data, p('blob.dat'));
    });

    testWidgets('关闭按钮能关掉对话框', (WidgetTester tester) async {
      File(p('note.txt')).writeAsStringSync('x');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showAttachmentPreview(context, p('note.txt')),
              child: const Text('打开'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('打开'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(AttachmentPreviewDialog), findsOneWidget);

      await tester.tap(find.text('关闭'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(AttachmentPreviewDialog), findsNothing);
    });
  });
}
