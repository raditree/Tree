import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tree/io/api_service.dart';
import 'package:tree/ui/services/code_highlight.dart';
import 'package:tree/ui/services/editor_settings.dart';
import 'package:tree/ui/widgets/file_viewer.dart';

/// 假核心：只实现文件读写两个端点，并记录收到的 PUT。
///
/// 为什么真起一个本机 HttpServer：ApiService 是静态的、直连核心，只有让它真发一次
/// 请求，才能验证「打到的是 PUT /api/files/{id}/content、body 里有 if_size / force」
/// 这类前后端契约——这正是不一致时最先坏掉的地方。
class FakeCore {
  FakeCore._(this._http);

  final HttpServer _http;

  /// GET content 返回的内容 / 真实大小 / 是否截断
  String content = '';
  int size = 0;
  bool truncated = false;

  /// PUT 的响应脚本（按顺序取；用完后都按 200 成功）
  final List<({int status, Map<String, dynamic> body})> putResponses =
      <({int status, Map<String, dynamic> body})>[];

  /// 收到的 PUT（查询串 + 请求体）
  final List<({String query, Map<String, dynamic> body})> puts =
      <({String query, Map<String, dynamic> body})>[];

  static Future<FakeCore> start() async {
    final HttpServer http =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final FakeCore core = FakeCore._(http);
    http.listen(core._handle);
    return core;
  }

  String get baseUrl => 'http://127.0.0.1:${_http.port}';

  Future<void> close() => _http.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final String raw = await utf8.decoder.bind(request).join();
    final Map<String, dynamic> body = raw.trim().isEmpty
        ? <String, dynamic>{}
        : jsonDecode(raw) as Map<String, dynamic>;
    Map<String, dynamic> payload;
    int status = 200;
    if (request.method == 'GET') {
      payload = <String, dynamic>{
        'content': content,
        'path': request.uri.queryParameters['path'] ?? '',
        'size': size,
        if (truncated) 'truncated': true,
      };
    } else {
      puts.add((query: request.uri.query, body: body));
      final ({int status, Map<String, dynamic> body}) script =
          putResponses.isNotEmpty ? putResponses.removeAt(0) : (status: 200, body: <String, dynamic>{});
      status = script.status;
      payload = script.body.isEmpty
          ? <String, dynamic>{
              'success': true,
              'size': (body['content'] as String? ?? '').length,
            }
          : script.body;
    }
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(payload));
    await request.response.close();
  }
}

/// 本用例真正发出的那些 PUT（按内容筛）。
///
/// 为什么要筛：上一个用例的控件树是在这一帧被替换掉的，它 dispose 时的补写会打到
/// 刚起来的假核心上；断言"总共一次"会随请求到达时机抖动，断言"这条内容发了一次"才稳。
List<Map<String, dynamic>> putsWith(FakeCore core, String content) => core.puts
    .map((({String query, Map<String, dynamic> body}) p) => p.body)
    .where((Map<String, dynamic> b) => b['content'] == content)
    .toList();

/// 放行挂在控件上的真实 IO/网络：假时钟里必须「转一圈真实事件循环 + pump」多来几圈，
/// 一次请求往往要走好几步（建连 → 请求 → 读响应），一圈只推进一步。
Future<void> settleIo(WidgetTester tester, {int rounds = 12}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)));
    await tester.pump();
  }
}

void main() {
  late FakeCore core;

  setUpAll(() {
    // flutter_test 默认给进程装了 HttpOverrides：请求会被拦成 400、不真发出去
    HttpOverrides.global = null;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await EditorSettings.instance.setSaveOnBlur(true);
    await EditorSettings.instance.setHighlight(true);
    core = await FakeCore.start();
    ApiService.baseUrl = core.baseUrl;
    ApiService.setToken('test-token');
  });

  tearDown(() async {
    await core.close();
  });

  Future<void> pumpViewer(
    WidgetTester tester, {
    String path = 'lib/main.dart',
    bool readOnly = false,
    String reason = '',
    VoidCallback? onClose,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FileViewer(
          workspaceId: 'ws1',
          teamId: 'ws1',
          filePath: path,
          readOnly: readOnly,
          readOnlyReason: reason,
          onClose: onClose,
        ),
      ),
    ));
    await settleIo(tester);
    // 上一个用例的控件树是在这一帧被替换掉的，它的 dispose 补写会打到刚起来的假核心上。
    // 清一次，保证每个用例只量自己这几步发出的请求。
    core.puts.clear();
  }

  Future<void> pressCtrlS(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  group('源码模式按语言渲染', () {
    testWidgets('按扩展名挑语言，标题栏给出语言标签', (WidgetTester tester) async {
      core.content = 'final int x = 1;';
      core.size = core.content.length;
      await pumpViewer(tester, path: 'lib/main.dart');

      expect(find.text('Dart'), findsOneWidget);
      final TextField field = tester.widget<TextField>(find.byType(TextField));
      final CodeEditingController controller =
          field.controller! as CodeEditingController;
      expect(controller.language.id, 'dart');
    });

    testWidgets('只读的源码文件也按语言着色（不是纯 txt）',
        (WidgetTester tester) async {
      core.content = 'final int x = 1;';
      core.size = core.content.length;
      await pumpViewer(tester, path: 'lib/main.dart', readOnly: true,
          reason: '测试用只读');

      // 只读态用 SelectableText.rich，切出来的 span 带颜色
      final SelectableText text =
          tester.widget<SelectableText>(find.byType(SelectableText));
      final List<InlineSpan> children = text.textSpan!.children!;
      expect(
        children.whereType<TextSpan>().any((TextSpan s) =>
            s.text == 'final' && s.style?.color != null),
        isTrue,
        reason: '关键字要有着色，而不是一坨同色的 txt',
      );
    });
  });

  group('编辑与保存', () {
    testWidgets('改一下就进未保存态；Ctrl+S 把完整内容与 if_size 发出去',
        (WidgetTester tester) async {
      core.content = 'line1\n';
      core.size = 6;
      await pumpViewer(tester, path: 'notes.txt');

      await tester.enterText(find.byType(TextField), 'line1\nline2\n');
      await tester.pump();
      expect(find.textContaining('未保存的改动'), findsOneWidget);

      await pressCtrlS(tester);
      await settleIo(tester);

      final List<Map<String, dynamic>> saved = putsWith(core, 'line1\nline2\n');
      expect(saved, hasLength(1), reason: '点一次保存只发一次 PUT');
      expect(saved.single['if_size'], 6,
          reason: '带上加载时的字节数，核心才能发现外部改动');
      expect(core.puts.singleWhere((({String query, Map<String, dynamic> body}) p) => p.body['content'] == 'line1\nline2\n').query,
          contains('path=notes.txt'));
      expect(find.textContaining('未保存的改动'), findsNothing);
    });

    testWidgets('保存失败给出可见原因，不静默', (WidgetTester tester) async {
      core.content = 'x';
      core.size = 1;
      core.putResponses.add((
        status: 400,
        body: <String, dynamic>{'error': 'not_text', 'detail': '目标不是纯文本，拒绝写入'},
      ));
      await pumpViewer(tester, path: 'a.txt');

      await tester.enterText(find.byType(TextField), 'failcase');
      await tester.pump();
      await pressCtrlS(tester);
      await settleIo(tester);

      // 标题栏状态行 + SnackBar 兜底：两处都给原因，不静默
      expect(find.textContaining('保存失败'), findsWidgets);
      expect(find.textContaining('目标不是纯文本'), findsWidgets);
      expect(find.textContaining('未保存的改动'), findsNothing,
          reason: '失败时状态行让位给失败原因，但改动仍在（保存键仍可点）');
      // 改动还在：保存键仍是实心可点的
      expect(find.byIcon(Icons.save), findsOneWidget);
    });

    testWidgets('409 冲突：弹框说明后「覆盖保存」带 force=1 重试',
        (WidgetTester tester) async {
      core.content = 'x';
      core.size = 1;
      core.putResponses.add((
        status: 409,
        body: <String, dynamic>{
          'error': 'conflict',
          'detail': '文件已被外部修改，请刷新后再保存',
          'size': 99,
        },
      ));
      await pumpViewer(tester, path: 'a.txt');

      await tester.enterText(find.byType(TextField), 'mine');
      await tester.pump();
      await pressCtrlS(tester);
      await settleIo(tester);

      expect(putsWith(core, 'mine'), hasLength(1), reason: '点保存只应发一次 PUT');
      expect(find.byType(AlertDialog), findsOneWidget,
          reason: '409 要弹冲突框，而不是把失败糊在状态行上');
      expect(find.text('文件已被外部修改'), findsOneWidget);
      expect(find.textContaining('99 字节'), findsOneWidget);
      expect(find.textContaining('4 字符'), findsOneWidget);

      await tester.tap(find.text('覆盖保存'));
      await settleIo(tester);

      expect(putsWith(core, 'mine'), hasLength(2), reason: '第一次 409，覆盖保存再发一次');
      expect(core.puts.last.query, contains('force=1'));
    });
  });

  group('只读闸门（仅纯文本可编辑）', () {
    testWidgets('被截断的大文件只读：说明原因，不给文本域',
        (WidgetTester tester) async {
      core.content = '前一段内容';
      core.size = 50 * 1024 * 1024;
      core.truncated = true;
      await pumpViewer(tester, path: 'big.log');

      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('只读'), findsOneWidget);
      expect(find.textContaining('截短'), findsOneWidget);
    });

    testWidgets('含 NUL 的二进制只读', (WidgetTester tester) async {
      core.content = 'abc\u0000def';
      core.size = 7;
      await pumpViewer(tester, path: 'weird.txt');

      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('二进制'), findsOneWidget);
    });

    testWidgets('图片只读（复杂格式不在编辑范围内）', (WidgetTester tester) async {
      core.content = base64Encode(<int>[1, 2, 3, 4]);
      core.size = 4;
      await pumpViewer(tester, path: 'pic.png');

      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('图片不支持编辑'), findsNothing,
          reason: '图片视图不铺只读提示条，锁图标 tooltip 里说明即可');
      expect(find.byTooltip('图片不支持编辑'), findsOneWidget);
    });

    testWidgets('分屏里被锁成只读的窗格：给出理由，不给文本域',
        (WidgetTester tester) async {
      core.content = 'x';
      core.size = 1;
      await pumpViewer(
        tester,
        path: 'a.txt',
        readOnly: true,
        reason: '同一个文件已在另一个窗格打开',
      );

      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('同一个文件已在另一个窗格打开'), findsOneWidget);
    });
  });

  group('失焦与离开', () {
    testWidgets('开着失焦保存：焦点一走就写回', (WidgetTester tester) async {
      core.content = 'x';
      core.size = 1;
      await pumpViewer(tester, path: 'a.txt');

      await tester.enterText(find.byType(TextField), 'blur-on');
      await tester.pump();
      expect(core.puts, isEmpty);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await settleIo(tester);

      expect(putsWith(core, 'blur-on'), hasLength(1));
    });

    testWidgets('关掉失焦保存：焦点走了也不写（只认手动保存）',
        (WidgetTester tester) async {
      await EditorSettings.instance.setSaveOnBlur(false);
      core.content = 'x';
      core.size = 1;
      await pumpViewer(tester, path: 'a.txt');

      await tester.enterText(find.byType(TextField), 'blur-off');
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await settleIo(tester);

      expect(putsWith(core, 'blur-off'), isEmpty);
    });

    testWidgets('返回时先静默写回再关（开着失焦保存）',
        (WidgetTester tester) async {
      core.content = 'x';
      core.size = 1;
      bool closed = false;
      await pumpViewer(tester, path: 'a.txt', onClose: () => closed = true);

      await tester.enterText(find.byType(TextField), 'close-save');
      await tester.pump();
      await tester.tap(find.byTooltip('返回'));
      await settleIo(tester);

      expect(putsWith(core, 'close-save'), hasLength(1));
      expect(closed, isTrue);
    });

    testWidgets('关掉失焦保存：返回前问一次，选取消就不关',
        (WidgetTester tester) async {
      await EditorSettings.instance.setSaveOnBlur(false);
      core.content = 'x';
      core.size = 1;
      bool closed = false;
      await pumpViewer(tester, path: 'a.txt', onClose: () => closed = true);

      await tester.enterText(find.byType(TextField), 'close-cancel');
      await tester.pump();
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();

      expect(find.text('还有未保存的改动'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(putsWith(core, 'close-cancel'), isEmpty);
      expect(closed, isFalse);
    });
  });
}
