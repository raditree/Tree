import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/widgets/message_input.dart';

/// Q5（多文件粘贴）+ Q6（草稿按 team+session 缓存）。
///
/// 原生侧 readFiles 在测试里用 mock 通道顶替：这里验证的是 Dart 侧的
/// 「文件列表优先，且一次全部成为附件」与草稿存取语义。
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
    expect(find.byType(Chip), findsNothing);
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
      expect(find.byType(Chip), findsNothing);

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

      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();

      expect(sentTexts, <String>['要发的内容']);
      expect(sentFiles.single, <String>[r'C:\tmp\x.bin']);
      expect(fieldText(tester), '');
      expect(find.byType(Chip), findsNothing);

      // 切走再切回来：已发送的内容不得复活
      await pumpInput(tester, cacheKey: 'teamA::s2');
      await pumpInput(tester, cacheKey: 'teamA::s1');
      expect(fieldText(tester), '');
      expect(find.byType(Chip), findsNothing);
    });

    testWidgets('发送失败（回调返回 false）：文本与附件都保留，草稿不丢',
        (WidgetTester tester) async {
      mockClipboard(files: <String>[r'C:\tmp\x.bin']);
      await pumpInput(tester, cacheKey: 'teamA::s1');
      await pressCtrlV(tester);
      await tester.enterText(find.byType(TextField), '要重发的内容');

      // 模拟"附件上传失败"：面板回调返回 false，消息没有发出去
      sendOk = false;
      await tester.tap(find.byIcon(Icons.send));
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
      expect(find.byType(Chip), findsNothing);

      await pumpInput(tester, cacheKey: 'teamA::s1');
      expect(fieldText(tester), '甲');
      expect(find.text('only.bin'), findsOneWidget);

      await pumpInput(tester, cacheKey: 'teamA::s2');
      expect(fieldText(tester), '');
      expect(find.byType(Chip), findsNothing);
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
}
