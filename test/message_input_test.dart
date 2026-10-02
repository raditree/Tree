import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/widgets/attachment_preview.dart';
import 'package:tree/ui/widgets/message_input.dart';

/// Q5（多文件粘贴）+ Q6（草稿按 team+session 缓存）。
///
/// 原生侧 readFiles 在测试里用 mock 通道顶替：这里验证的是 Dart 侧的
/// 「文件列表优先，且一次全部成为附件」与草稿存取语义。
/// 清理临时目录：删不掉就算了（Windows 上可能还被别的句柄占着），
/// 不能让清理失败把一个已经跑完的用例判成失败。
void cleanTempDir(Directory dir) {
  try {
    dir.deleteSync(recursive: true);
  } catch (_) {}
}

/// 1x1 透明 PNG（只用来证明"图片附件走缩略图这条路"，不校验像素）
final Uint8List kTinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==',
);

void main() {
  const MethodChannel clipboardChannel = MethodChannel('tree/clipboard');

  late List<String> sentTexts;
  late List<List<String>> sentFiles;
  late List<String> clipboardCalls;

  /// 发送回调的返回值（true = 已发出 ⇒ 输入框清空；false = 没发出去 ⇒ 保留）。
  /// 由用例按需切换：附件上传失败时面板就是靠这个 false 把草稿留给用户。
  late bool sendOk;

  setUp(() {
    sentTexts = <String>[];
    sentFiles = <List<String>>[];
    clipboardCalls = <String>[];
    sendOk = true;
    MessageDraftCache.instance.clearAll();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(clipboardChannel, null);
  });

  /// 模拟原生剪贴板通道：files 为 readFiles 的返回，image 为 readImage 的返回
  void mockClipboard({List<String>? files, Map<String, dynamic>? image}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(clipboardChannel, (MethodCall call) async {
      clipboardCalls.add(call.method);
      switch (call.method) {
        case 'readFiles':
          return files;
        case 'readImage':
          return image;
        default:
          return null;
      }
    });
  }

  Future<void> pumpInput(WidgetTester tester, {String? cacheKey}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageInput(
          cacheKey: cacheKey,
          onSend: (String text, List<String> files) async {
            sentTexts.add(text);
            sentFiles.add(files);
            return sendOk;
          },
        ),
      ),
    ));
  }

  /// 模拟用户按下 Ctrl+V（走 MessageInput 自己的按键拦截）
  Future<void> pressCtrlV(WidgetTester tester) async {
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  String fieldText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  testWidgets('文本域不画内框：主题强制边框时也被显式清掉（否则卡片里会多一个方框）',
      (WidgetTester tester) async {
    // 与真实主题同口径（main.dart 的 inputDecorationTheme：给设置页/表单用的那一圈）。
    // 焦点：只写 border: InputBorder.none 压不住主题 —— InputDecoration 的解析顺序是
    // focusedBorder → enabledBorder → border（用户 2026-10-03 截图就是这圈绿框）。
    final ThemeData theme = ThemeData(
      useMaterial3: false,
      inputDecorationTheme: const InputDecorationTheme(
        enabledBorder: OutlineInputBorder(),
        focusedBorder: OutlineInputBorder(),
      ),
    );
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: Scaffold(
        body: MessageInput(
          onSend: (String text, List<String> files) async => true,
        ),
      ),
    ));
    final TextField field = tester.widget<TextField>(find.byType(TextField));
    final InputDecoration effective = field.decoration!.applyDefaults(
      theme.inputDecorationTheme,
    );
    expect(effective.border, InputBorder.none);
    expect(
      effective.enabledBorder,
      InputBorder.none,
      reason: '主题的 enabledBorder 会盖过 border：必须显式清掉，边框归外层卡片画',
    );
    expect(
      effective.focusedBorder,
      InputBorder.none,
      reason: '聚焦时也不许冒出主题那圈绿框',
    );
  });

  testWidgets('一次粘贴多个文件：每个都成为附件，且不再尝试读位图',
      (WidgetTester tester) async {
    mockClipboard(files: <String>[
      r'C:\tmp\一.txt',
      r'C:\tmp\二.txt',
      r'C:\tmp\三.txt',
    ]);
    await pumpInput(tester);
    await pressCtrlV(tester);

    expect(find.text('一.txt'), findsOneWidget);
    expect(find.text('二.txt'), findsOneWidget);
    expect(find.text('三.txt'), findsOneWidget);
    expect(clipboardCalls, <String>['readFiles'],
        reason: '有文件列表时不该再去读剪贴板位图');
  });

  testWidgets('剪贴板无文件列表：仍然按原有顺序继续（不打断粘贴）',
      (WidgetTester tester) async {
    mockClipboard(files: null, image: null);
    await pumpInput(tester);
    await pressCtrlV(tester);

    expect(clipboardCalls, <String>['readFiles', 'readImage']);
    expect(find.byType(AttachmentTile), findsNothing);
  });

  group('草稿缓存（Q6）', () {
    testWidgets('切换 cacheKey：各自恢复文本与附件，未编辑过的键为空',
        (WidgetTester tester) async {
      mockClipboard(files: <String>[r'C:\tmp\附件.bin']);

      await pumpInput(tester, cacheKey: 'teamA::s1');
      await tester.enterText(find.byType(TextField), '甲草稿');
      await pressCtrlV(tester);
      expect(fieldText(tester), '甲草稿');
      expect(find.text('附件.bin'), findsOneWidget);

      // 切到同 team 的另一个会话：没有缓存 → 输入框与附件都空
      await pumpInput(tester, cacheKey: 'teamA::s2');
      expect(fieldText(tester), '');
      expect(find.byType(AttachmentTile), findsNothing);

      await tester.enterText(find.byType(TextField), '乙草稿');

      // 切到另一个 team：同样空
      await pumpInput(tester, cacheKey: 'teamB::s1');
      expect(fieldText(tester), '');

      // 切回来：文本与附件一起恢复
      await pumpInput(tester, cacheKey: 'teamA::s1');
      expect(fieldText(tester), '甲草稿');
      expect(find.text('附件.bin'), findsOneWidget);

      await pumpInput(tester, cacheKey: 'teamA::s2');
      expect(fieldText(tester), '乙草稿');
    });

    testWidgets('发送成功后清空输入框与附件，并作废该键草稿',
        (WidgetTester tester) async {
      mockClipboard(files: <String>[r'C:\tmp\x.bin']);
      await pumpInput(tester, cacheKey: 'teamA::s1');
      await pressCtrlV(tester);
      await tester.enterText(find.byType(TextField), '要发的内容');

      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pumpAndSettle();

      expect(sentTexts, <String>['要发的内容']);
      expect(sentFiles.single, <String>[r'C:\tmp\x.bin']);
      expect(fieldText(tester), '');
      expect(find.byType(AttachmentTile), findsNothing);

      // 切走再切回来：已发送的内容不得复活
      await pumpInput(tester, cacheKey: 'teamA::s2');
      await pumpInput(tester, cacheKey: 'teamA::s1');
      expect(fieldText(tester), '');
      expect(find.byType(AttachmentTile), findsNothing);
    });

    testWidgets('发送失败（回调返回 false）：文本与附件都保留，草稿不丢',
        (WidgetTester tester) async {
      mockClipboard(files: <String>[r'C:\tmp\x.bin']);
      await pumpInput(tester, cacheKey: 'teamA::s1');
      await pressCtrlV(tester);
      await tester.enterText(find.byType(TextField), '要重发的内容');

      // 模拟"附件上传失败"：面板回调返回 false，消息没有发出去
      sendOk = false;
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pumpAndSettle();

      expect(sentTexts, <String>['要重发的内容'], reason: '回调仍然被调用了一次');
      expect(fieldText(tester), '要重发的内容', reason: '失败不该清空输入框');
      expect(find.text('x.bin'), findsOneWidget, reason: '失败不该丢掉附件');

      // 切走再切回来：草稿还在（否则用户得重写一遍）
      await pumpInput(tester, cacheKey: 'teamA::s2');
      await pumpInput(tester, cacheKey: 'teamA::s1');
      expect(fieldText(tester), '要重发的内容');
      expect(find.text('x.bin'), findsOneWidget);
    });

    testWidgets('未编辑过的键不会被上一个键的草稿污染',
        (WidgetTester tester) async {
      mockClipboard(files: <String>[r'C:\tmp\only.bin']);
      await pumpInput(tester, cacheKey: 'teamA::s1');
      await pressCtrlV(tester);
      await tester.enterText(find.byType(TextField), '甲');
      expect(find.text('only.bin'), findsOneWidget);

      // 首次切到没编辑过的键：回填（改 controller 会触发监听）不能把上一个键的
      // 文本/附件写进新键——否则第二次切回来就会看到不属于它的草稿
      await pumpInput(tester, cacheKey: 'teamA::s2');
      expect(fieldText(tester), '');
      expect(find.byType(AttachmentTile), findsNothing);

      await pumpInput(tester, cacheKey: 'teamA::s1');
      expect(fieldText(tester), '甲');
      expect(find.text('only.bin'), findsOneWidget);

      await pumpInput(tester, cacheKey: 'teamA::s2');
      expect(fieldText(tester), '');
      expect(find.byType(AttachmentTile), findsNothing);
    });

    testWidgets('不传 cacheKey（复用方）：不写缓存，切到带缓存的键不串味',
        (WidgetTester tester) async {
      await pumpInput(tester);
      await tester.enterText(find.byType(TextField), '无键内容');

      await pumpInput(tester, cacheKey: 'teamA::s1');
      expect(fieldText(tester), '');
    });
  });

  group('MessageDraftCache', () {
    test('write / read / clear：附件是拷贝，外部列表变化不影响缓存', () {
      final MessageDraftCache cache = MessageDraftCache.instance;
      final List<String> files = <String>['a.txt'];

      cache.write('t::s', '文本', files);
      final MessageDraft? draft = cache.read('t::s');
      expect(draft?.text, '文本');
      expect(draft?.filePaths, <String>['a.txt']);

      files.add('b.txt');
      expect(cache.read('t::s')?.filePaths, <String>['a.txt']);
    });

    test('文本与附件都为空时删除该键，不留空条目', () {
      final MessageDraftCache cache = MessageDraftCache.instance;
      cache.write('t::s', 'x', <String>['a.txt']);
      cache.write('t::s', '', <String>[]);
      expect(cache.read('t::s'), isNull);
    });
  });

  group('卡片式输入框：展开与附件预览', () {
    /// 放行挂在控件上的**真实文件 IO**。
    ///
    /// widget 测试跑在假时钟里，真实 IO 的回调躺在假队列里等着；而且一次 IO 往往
    /// 是好几步（stat → open → length → read），每圈只能推进一步。所以必须
    /// 「让真实事件循环转一圈 → pump 一次把回调放出来」反复来几圈——
    /// 只转一圈的话，多步 IO 会永远停在中间（界面一直是加载态）。
    Future<void> settleIo(WidgetTester tester, {int rounds = 10}) async {
      for (int i = 0; i < rounds; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 15)));
        await tester.pump();
      }
    }

    testWidgets('「+」菜单里的展开把文本域原位变高，Esc 收起',
        (WidgetTester tester) async {
      await pumpInput(tester);
      final double collapsed =
          tester.getSize(find.byType(TextField)).height.toDouble();

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      expect(find.text('展开输入框（长文本）'), findsOneWidget);
      await tester.tap(find.text('展开输入框（长文本）'));
      await tester.pumpAndSettle();

      final double expanded =
          tester.getSize(find.byType(TextField)).height.toDouble();
      expect(expanded, greaterThan(collapsed), reason: '原位展开要真的变高');
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
        isTrue,
        reason: '展开就是为了接着写，焦点不能被菜单抢走',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(TextField)).height, collapsed,
          reason: 'Esc 要把展开态收回去');

      // 菜单入口随状态翻转：收起后再打开应显示「展开输入框」
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      expect(find.text('展开输入框（长文本）'), findsOneWidget);
      await tester.tap(find.text('展开输入框（长文本）'));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(TextField)).height, expanded);
    });

    testWidgets('图片附件给缩略图，非图片给文件卡（含异步读到的大小）',
        (WidgetTester tester) async {
      // 造真实文件必须用**同步** IO：testWidgets 的测试体跑在假时钟里，
      // `await File(...)` 永远不返回（整个用例卡死），除非包进 runAsync。
      final Directory dir = Directory.systemTemp.createTempSync('tree_input_test');
      addTearDown(() => cleanTempDir(dir));
      final File image =
          File('${dir.path}${Platform.pathSeparator}pixel.png');
      image.writeAsBytesSync(kTinyPng, flush: true);
      final File doc = File('${dir.path}${Platform.pathSeparator}note.txt');
      doc.writeAsStringSync('随便写点什么');

      mockClipboard(files: <String>[image.path, doc.path]);
      await pumpInput(tester);
      await pressCtrlV(tester);
      await settleIo(tester);

      expect(find.byType(AttachmentTile), findsNWidgets(2));
      final Image thumb = tester.widget<Image>(find.descendant(
        of: find.byType(AttachmentTile).first,
        matching: find.byType(Image),
      ));
      // 缩略图带 cacheWidth，Image 会把 provider 包成 ResizeImage：断言要拆一层
      final ImageProvider provider = thumb.image;
      final FileImage file = provider is ResizeImage
          ? provider.imageProvider as FileImage
          : provider as FileImage;
      expect(file.file.path, image.path,
          reason: '图片附件要走缩略图，不是一张通用文件卡');
      expect(find.text('note.txt'), findsOneWidget);
      expect(find.text('读取中…'), findsNothing,
          reason: '大小读到了就该显示出来，不能一直占位');
    });

    testWidgets('点附件打开本机文件预览对话框', (WidgetTester tester) async {
      final Directory dir = Directory.systemTemp.createTempSync('tree_input_test');
      addTearDown(() => cleanTempDir(dir));
      final File doc = File('${dir.path}${Platform.pathSeparator}note.txt');
      doc.writeAsStringSync('预览里的内容');

      mockClipboard(files: <String>[doc.path]);
      await pumpInput(tester);
      await pressCtrlV(tester);
      await settleIo(tester);

      await tester.tap(find.byType(AttachmentTile));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(AttachmentPreviewDialog), findsOneWidget);
      await settleIo(tester);
      expect(find.text('预览里的内容'), findsOneWidget);

      await tester.tap(find.text('关闭'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(AttachmentPreviewDialog), findsNothing);
    });

    testWidgets('移除键把附件从当前草稿里删掉，切走再切回来不复活',
        (WidgetTester tester) async {
      mockClipboard(files: <String>[r'C:\tmp\x.bin']);
      await pumpInput(tester, cacheKey: 'teamA::s1');
      await pressCtrlV(tester);
      expect(find.byType(AttachmentTile), findsOneWidget);

      await tester.tap(find.descendant(
        of: find.byType(AttachmentTile),
        matching: find.byIcon(Icons.close),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(AttachmentTile), findsNothing);

      await pumpInput(tester, cacheKey: 'teamA::s2');
      await pumpInput(tester, cacheKey: 'teamA::s1');
      expect(find.byType(AttachmentTile), findsNothing);
    });
  });
}
