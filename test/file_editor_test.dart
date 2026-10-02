import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tree/io/api_service.dart';
import 'package:tree/ui/services/code_highlight.dart';
import 'package:tree/ui/services/editor_buffer.dart';
import 'package:tree/ui/services/editor_settings.dart';
import 'package:tree/ui/widgets/file_panel.dart';
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

  /// GET 文件列表端点（/api/files/{id}，不带 /content）返回的条目
  List<Map<String, dynamic>> files = <Map<String, dynamic>>[];

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
      if (!request.uri.path.endsWith('/content')) {
        // 文件列表端点（文件面板的端到端用例）
        payload = <String, dynamic>{'files': files};
      } else {
        payload = <String, dynamic>{
          'content': content,
          'path': request.uri.queryParameters['path'] ?? '',
          'size': size,
          if (truncated) 'truncated': true,
        };
      }
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
    ThemeData? theme,
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: theme,
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

  /// 同一个文件的两个窗格：**共享同一份** [EditorBuffer]（file_panel 的分屏就这么接）。
  ///
  /// 直接摆两个 FileViewer 而不是整套 FilePanel：这里要钉的是"一份缓冲、两个视图"，
  /// 面板那侧的接线由 split_panes_test 的源钉看着。
  Future<EditorBuffer> pumpSharedPanes(
    WidgetTester tester, {
    String path = 'a.txt',
    String notice = '',
  }) async {
    final EditorBuffer buffer = EditorBuffer();
    Widget pane() => FileViewer(
          workspaceId: 'ws1',
          teamId: 'ws1',
          filePath: path,
          buffer: buffer,
          paneNotice: notice,
        );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Row(
          children: <Widget>[
            Expanded(child: pane()),
            Expanded(child: pane()),
          ],
        ),
      ),
    ));
    await settleIo(tester);
    // 上一个用例的控件树是在这一帧被替换掉的，它的 dispose 补写会打到刚起来的假核心上
    core.puts.clear();
    return buffer;
  }

  Future<void> pressCtrlS(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  group('源码模式按语言渲染', () {
    testWidgets('代码视图的文本域不画内框（主题强制边框也不画）',
        (WidgetTester tester) async {
      core.content = 'final int x = 1;';
      core.size = core.content.length;
      final ThemeData theme = ThemeData(
        useMaterial3: false,
        inputDecorationTheme: const InputDecorationTheme(
          enabledBorder: OutlineInputBorder(),
          focusedBorder: OutlineInputBorder(),
        ),
      );
      await pumpViewer(tester, path: 'lib/main.dart', theme: theme);
      final TextField field = tester.widget<TextField>(find.byType(TextField));
      final InputDecoration effective = field.decoration!.applyDefaults(
        theme.inputDecorationTheme,
      );
      // 编辑器自己的框由外层窗格画：只写 border: none 会被主题的 enabled/focused 边框盖回来
      expect(effective.border, InputBorder.none);
      expect(effective.enabledBorder, InputBorder.none);
      expect(effective.focusedBorder, InputBorder.none);
    });

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

    testWidgets('外部 readOnly 参数语义不变：给出理由，不给文本域',
        (WidgetTester tester) async {
      core.content = 'x';
      core.size = 1;
      await pumpViewer(
        tester,
        path: 'a.txt',
        readOnly: true,
        reason: '外部调用方要求只读',
      );

      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('外部调用方要求只读'), findsOneWidget);
    });

    testWidgets('同文件双窗格里的真只读闸门不变：两边都不给文本域，理由一致',
        (WidgetTester tester) async {
      core.content = 'abc\u0000def';
      core.size = 7;
      final EditorBuffer buffer =
          await pumpSharedPanes(tester, path: 'weird.txt');

      expect(find.byType(TextField), findsNothing);
      expect(find.textContaining('二进制'), findsNWidgets(2));
      expect(buffer.controller, isNull, reason: '真只读的文档不建控制器');
    });
  });

  group('同文件双窗格共享一份缓冲（VS Code 的 TextDocument 口径）', () {
    testWidgets('两个窗格都能编辑：两个文本域同一个控制器，一边打字另一边立刻可见',
        (WidgetTester tester) async {
      core.content = 'line1\n';
      core.size = 6;
      const String notice = '同一文件已在另一窗格打开：两侧共享同一份缓冲，就地编辑即同步';
      final EditorBuffer buffer = await pumpSharedPanes(tester, notice: notice);

      // 旧口径"同文件双开 ⇒ 第二个窗格只读"已被推翻：两边都是可编辑的文本域
      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.text(notice), findsNWidgets(2),
          reason: '双开只给提示，不再锁只读');

      final List<TextField> fields =
          tester.widgetList<TextField>(find.byType(TextField)).toList();
      expect(identical(fields[0].controller, fields[1].controller), isTrue,
          reason: '两个窗格必须共用同一个 CodeEditingController（一份缓冲）');
      expect(identical(fields[0].controller, buffer.controller), isTrue);

      await tester.enterText(find.byType(TextField).first, 'line1\nline2\n');
      await tester.pump();

      // 另一个窗格的文本域跟着变（同一个控制器 ⇒ 同一份文本、同一份脏标记）
      expect(find.text('line1\nline2\n'), findsNWidgets(2));
      expect(find.textContaining('未保存的改动'), findsNWidgets(2));
    });

    testWidgets('任一窗格保存成功：两边一起变成已保存，loadedSize 一起更新，只发一次 PUT',
        (WidgetTester tester) async {
      core.content = 'x';
      core.size = 1;
      final EditorBuffer buffer = await pumpSharedPanes(tester);

      await tester.enterText(find.byType(TextField).first, 'two-panes');
      await tester.pump();
      expect(find.textContaining('未保存的改动'), findsNWidgets(2));
      expect(find.byIcon(Icons.save), findsNWidgets(2),
          reason: '脏标记共享：两边都显示可点的保存键');

      // 在第二个窗格点保存（共享缓冲：从哪一边保存都是同一份文档）
      await tester.tap(find.byIcon(Icons.save).last);
      await settleIo(tester);

      final List<Map<String, dynamic>> saved = putsWith(core, 'two-panes');
      expect(saved, hasLength(1), reason: '一份缓冲一次保存只发一次 PUT');
      expect(saved.single['if_size'], 1,
          reason: '两个窗格看到的是同一个加载字节数');
      expect(buffer.loadedSize, 'two-panes'.length,
          reason: '保存成功后共享的 loadedSize 一起更新');
      expect(find.textContaining('未保存的改动'), findsNothing,
          reason: '保存成功后两边都不再是未保存态');
      expect(find.byIcon(Icons.save), findsNothing);
    });

    testWidgets('FileViewer 对**外部传入**的缓冲不做 dispose：窗格关了，控制器还在',
        (WidgetTester tester) async {
      core.content = 'x';
      core.size = 1;
      final EditorBuffer buffer = await pumpSharedPanes(tester);
      await tester.enterText(find.byType(TextField).first, 'kept');
      await tester.pump();

      // 两个窗格都拆掉（此时面板还没释放这份缓冲）：缓冲与控制器必须活着，
      // 否则"两个窗格都关掉之后才释放"这条会被先关掉的那个窗格破坏。
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      );
      await tester.pump();

      expect(buffer.controller, isNotNull,
          reason: '外部传入的缓冲归持有者释放，窗格不能把它 dispose 掉');
      expect(buffer.controller!.text, 'kept', reason: '另一个窗格编辑的内容还在');
      expect(buffer.dirty, isTrue);
    });

    testWidgets('EditorBuffer：值没变不通知；dispose 时把控制器一起收掉',
        (WidgetTester tester) async {
      final EditorBuffer buffer = EditorBuffer();
      int notified = 0;
      buffer.addListener(() => notified++);

      buffer.dirty = true;
      buffer.dirty = true; // 同一个值：不该再通知一次（按键不该重建另一个窗格）
      buffer.loadedSize = 5;
      buffer.loadedSize = 5;
      expect(notified, 2, reason: '每个 setter 只在值真的变化时通知');

      final CodeEditingController controller = CodeEditingController(
        language: languageForPath('a.txt'),
        text: 'x',
      );
      buffer.controller = controller;
      expect(buffer.controller, same(controller));

      buffer.dispose();
      expect(buffer.controller, isNull, reason: '控制器归缓冲所有，随它一起释放');
      // dispose 之后在途的保存 / 加载回调再写也不该抛（值照收，只是不再通知）
      buffer.dirty = false;
      expect(buffer.dirty, isFalse);
      expect(notified, 3, reason: '释放之后不再通知任何人');
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

  /// 端到端：真文件面板 + 真分屏按钮（面板自己的缓冲接线，不只是源钉）
  group('文件面板的分屏（端到端接线）', () {
    Future<void> pumpPanel(WidgetTester tester) async {
      core.files = <Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'a.txt',
          'path': 'a.txt',
          'type': 'file',
          'size': 6,
          'modified': '',
        },
      ];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 760,
            height: 600,
            child: FilePanel(workspaceId: 'ws1', teamId: 'ws1'),
          ),
        ),
      ));
      await settleIo(tester);
      core.puts.clear();
    }

    testWidgets('分屏后两个窗格共享一份缓冲：一边打字另一边可见，关掉一个窗格缓冲还在',
        (WidgetTester tester) async {
      core.content = 'alpha\n';
      core.size = 6;
      await pumpPanel(tester);

      // 文件树里点开 a.txt
      await tester.tap(find.text('a.txt'));
      await settleIo(tester);
      expect(find.byType(TextField), findsOneWidget);

      // 分屏按钮：第二个窗格复用**同一个**缓冲（不是又开一份）
      await tester.tap(find.byTooltip('分屏：同一个文件再开一个窗格（两侧共享同一份缓冲）'));
      await settleIo(tester);

      expect(find.byType(TextField), findsNWidgets(2));
      expect(
        find.text('同一文件已在另一窗格打开：两侧共享同一份缓冲，就地编辑即同步'),
        findsNWidgets(2),
      );
      final List<TextField> fields =
          tester.widgetList<TextField>(find.byType(TextField)).toList();
      expect(identical(fields[0].controller, fields[1].controller), isTrue,
          reason: '同一个文件的两个窗格必须共用同一个控制器');

      await tester.enterText(find.byType(TextField).first, 'alpha\nbeta\n');
      await tester.pump();
      expect(find.text('alpha\nbeta\n'), findsNWidgets(2));

      // 关掉一个窗格：缓冲还有引用 ⇒ 不该被释放，另一个窗格继续可编辑
      await tester.tap(find.byTooltip('关闭当前窗格'));
      await settleIo(tester);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('alpha\nbeta\n'), findsOneWidget);

      // 再用窗格自己的「返回」关掉**最后一个**窗格：列表清空也要能关
      // （曾经 clamp(0, -1) 会抛 ArgumentError）
      await tester.tap(find.byTooltip('返回'));
      await settleIo(tester);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('a.txt'), findsOneWidget, reason: '查看器关掉后回到文件树');
    });
  });
}
