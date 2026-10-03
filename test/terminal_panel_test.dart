import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/io/websocket_service.dart';
import 'package:tree/ui/widgets/terminal_panel.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// 假 WS：只把终端那条广播流交出来，并记录前端发出去的帧。
///
/// 为什么不打真核心：这一层要验证的是「键盘怎么变成字节、帧怎么变成屏幕」，
/// 与网络无关；真 PTY 的行为在核心侧单测里验（见 packages/tree_core/test/terminal_service_test.dart）。
class FakeWs extends WebSocketService {
  FakeWs() {
    _controller = StreamController<Map<String, dynamic>>.broadcast();
  }

  late final StreamController<Map<String, dynamic>> _controller;
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  @override
  Stream<Map<String, dynamic>> get terminalFrames => _controller.stream;

  @override
  void send(Map<String, dynamic> message) => sent.add(message);

  void emit(Map<String, dynamic> frame) => _controller.add(frame);

  Map<String, dynamic>? lastOf(String type) {
    final List<Map<String, dynamic>> all = sent
        .where((Map<String, dynamic> f) => f['type'] == type)
        .toList();
    return all.isEmpty ? null : all.last;
  }

  List<String> inputTexts(String terminalId) => sent
      .where((Map<String, dynamic> f) =>
          f['type'] == TerminalInboundType.input &&
          f[TerminalFrame.terminalId] == terminalId)
      .map((Map<String, dynamic> f) =>
          utf8.decode(base64Decode(f[TerminalFrame.bytes] as String)))
      .toList();
}

void main() {
  late FakeWs ws;

  setUp(() {
    ws = FakeWs();
  });

  Future<void> pumpPanel(
    WidgetTester tester, {
    VoidCallback? onToggle,
    VoidCallback? onClose,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 640,
          height: 320,
          child: TerminalPanel(
            agentId: 'a1',
            webSocket: ws,
            onToggle: onToggle ?? () {},
            onClose: onClose,
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  /// 送一帧下去并把它画出来。
  ///
  /// 为什么要 pump 两次：流的监听是在微任务里跑的，第一次 pump 把事件跑完（监听里
  /// 的 setState 落地），第二次才画出新状态——只 pump 一次会读到上一帧的界面。
  Future<void> emit(WidgetTester tester, Map<String, dynamic> frame) async {
    ws.emit(frame);
    await tester.pump();
    await tester.pump();
  }

  /// 首帧就会发 terminal_open；把会话 id 取出来备用
  String openedId(WidgetTester tester) {
    final Map<String, dynamic> open = ws.lastOf(TerminalInboundType.open)!;
    return open[TerminalFrame.terminalId] as String;
  }

  testWidgets('打开就发 terminal_open（带 agent 与尺寸），并主动要焦点',
      (WidgetTester tester) async {
    await pumpPanel(tester);

    final Map<String, dynamic> open = ws.lastOf(TerminalInboundType.open)!;
    expect(open[TerminalFrame.agentId], 'a1');
    expect(open[TerminalFrame.columns], isA<int>());
    expect(open[TerminalFrame.rows], isA<int>());
    expect((open[TerminalFrame.columns] as int) > 0, isTrue);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'terminal',
        reason: '进终端就该能直接打字（焦点在终端自己身上）');
  });

  testWidgets('输入法连接必须带 viewId（缺了平台不认这个 client，键盘文字全丢）',
      (WidgetTester tester) async {
    // 真机 bug（用户 2026-10-04）：attach 时没给 viewId ⇒ Windows 端
    // TextInput.setClient 直接报错（"Could not set client, view ID is null."），
    // 平台侧 active_model_ 一直是空的 ⇒ 键盘交出来的文字被 TextHook 静默丢掉，
    // 终端里中英文**一个字都打不出来**。这里把真正发给平台的配置钉住。
    final List<MethodCall> calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.textInput,
      (MethodCall call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.textInput,
        null,
      );
    });

    await pumpPanel(tester);
    await tester.pump();

    final Iterable<MethodCall> setClient = calls.where(
      (MethodCall c) => c.method == 'TextInput.setClient',
    );
    expect(setClient, isNotEmpty, reason: '终端有焦点却没挂输入法连接：文字没有来路');
    final List<dynamic> args = setClient.first.arguments as List<dynamic>;
    final Map<String, dynamic> config =
        (args[1] as Map<dynamic, dynamic>).cast<String, dynamic>();
    expect(config['viewId'], isNotNull,
        reason: '缺 viewId 平台就不认这个 client（引擎 side 直接回错误）');
    expect(
      config['viewId'],
      View.of(tester.element(find.byType(TerminalPanel))).viewId,
      reason: '要和本视图同一个 id（与 EditableText 同口径）',
    );
    expect(config['enableDeltaModel'], isFalse,
        reason: '没开 delta 通道：本 client 只实现 updateEditingValue');
  });

  testWidgets('ready 帧把 shell 与工作目录显示在工具条上', (WidgetTester tester) async {
    await pumpPanel(tester);
    final String id = openedId(tester);

    await emit(tester, <String, dynamic>{
      'type': TerminalOutboundType.ready,
      TerminalFrame.terminalId: id,
      TerminalFrame.cwd: 'E:/programs/Tree/desktop',
      TerminalFrame.shell: 'cmd.exe',
    });

    expect(find.textContaining('cmd.exe'), findsOneWidget);
    expect(find.textContaining('E:/programs/Tree/desktop'), findsOneWidget);
  });

  testWidgets('输出帧进屏幕缓冲：字符画得出来（不抛异常）',
      (WidgetTester tester) async {
    await pumpPanel(tester);
    final String id = openedId(tester);

    await emit(tester, <String, dynamic>{
      'type': TerminalOutboundType.output,
      TerminalFrame.terminalId: id,
      TerminalFrame.bytes: base64Encode(utf8.encode('hello\r\nworld')),
    });

    expect(tester.takeException(), isNull);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('键盘：回车发 \\r、方向键发 CSI；可打印字符**只**走输入法通道',
      (WidgetTester tester) async {
    await pumpPanel(tester);
    final String id = openedId(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();

    final List<String> inputs = ws.inputTexts(id);
    expect(
      inputs,
      isNot(contains('a')),
      reason: '键盘那一路必须把可打印字符判成 ignored（引擎 keyboard_manager 的'
          ' HandleOnKeyResult：键事件被判 handled 就不再派发文字）——在这里再发一次'
          ' 不但会重复，还会把文字那条路彻底挡死',
    );
    expect(inputs, contains('\r'));
    expect(inputs, contains('\u001b[A'), reason: '方向键是 xterm 转义序列');
  });

  testWidgets('输入法通道：中文与 ASCII 都按 UTF-8 发给 PTY（终端能打字）',
      (WidgetTester tester) async {
    await pumpPanel(tester);
    final String id = openedId(tester);
    final TerminalPanelState state = tester.state<TerminalPanelState>(
      find.byType(TerminalPanel),
    );

    state.debugImeClient.updateEditingValue(
      const TextEditingValue(
        text: '你好',
        selection: TextSelection.collapsed(offset: 2),
      ),
    );
    // 平台送来的永远是**模型整段文本**（见 terminal_ime_input 的文件头）：
    // 第二段是在"你好"后面接着敲的，所以文本是"你好ls"而不是"ls"
    state.debugImeClient.updateEditingValue(
      const TextEditingValue(
        text: '你好ls',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    await tester.pump();

    final List<String> inputs = ws.inputTexts(id);
    expect(
      inputs.join(''),
      contains('你好'),
      reason: '中文必须真发出去（真机现象就是它发不出去）',
    );
    expect(inputs.join(''), contains('ls'));
  });

  testWidgets('输入法组字中：只发已定字，拼音半截不进 shell', (WidgetTester tester) async {
    await pumpPanel(tester);
    final String id = openedId(tester);
    final TerminalPanelState state = tester.state<TerminalPanelState>(
      find.byType(TerminalPanel),
    );

    // 组字中（composing 覆盖整段）：一个字都不发
    state.debugImeClient.updateEditingValue(
      const TextEditingValue(
        text: 'ni',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    await tester.pump();
    expect(ws.inputTexts(id), isEmpty, reason: '组字中的拼音不能进 shell');

    // 定字：整段发出去
    state.debugImeClient.updateEditingValue(
      const TextEditingValue(
        text: '你',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pump();
    expect(ws.inputTexts(id), contains('你'));
  });

  testWidgets('Ctrl+C 发 0x03（不是把 c 打进去）', (WidgetTester tester) async {
    await pumpPanel(tester);
    final String id = openedId(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    final Map<String, dynamic> last = ws.sent.lastWhere(
      (Map<String, dynamic> f) =>
          f['type'] == TerminalInboundType.input &&
          f[TerminalFrame.terminalId] == id,
    );
    expect(base64Decode(last[TerminalFrame.bytes] as String), <int>[0x03]);
  });

  testWidgets('Ctrl+J 交给外层切换（不被终端吞掉）', (WidgetTester tester) async {
    int toggled = 0;
    await pumpPanel(tester, onToggle: () => toggled++);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(toggled, 1);
    expect(ws.inputTexts(openedId(tester)), isEmpty, reason: 'Ctrl+J 不该被当成输入');
  });

  testWidgets('error 帧显示可读原因；exit 帧显示已退出',
      (WidgetTester tester) async {
    await pumpPanel(tester);
    final String id = openedId(tester);

    await emit(tester, <String, dynamic>{
      'type': TerminalOutboundType.error,
      TerminalFrame.terminalId: id,
      TerminalFrame.message: '远端（SSH）agent 的交互终端暂不支持',
    });
    expect(find.textContaining('交互终端暂不支持'), findsOneWidget);

    await emit(tester, <String, dynamic>{
      'type': TerminalOutboundType.exit,
      TerminalFrame.terminalId: id,
      TerminalFrame.exitCode: 3,
    });
    expect(find.textContaining('已退出'), findsOneWidget);
  });

  testWidgets('别的会话 id 的帧被丢掉（重开不串台）', (WidgetTester tester) async {
    await pumpPanel(tester);

    await emit(tester, <String, dynamic>{
      'type': TerminalOutboundType.ready,
      TerminalFrame.terminalId: 'term_别的',
      TerminalFrame.cwd: 'D:/不该显示',
      TerminalFrame.shell: '不该显示',
    });

    expect(find.textContaining('不该显示'), findsNothing);
  });

  testWidgets('收起（dispose）时发 terminal_close：不留孤儿 shell',
      (WidgetTester tester) async {
    await pumpPanel(tester);
    final String id = openedId(tester);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(ws.lastOf(TerminalInboundType.close)![TerminalFrame.terminalId], id);
  });

  testWidgets('布局变化发 terminal_resize', (WidgetTester tester) async {
    await pumpPanel(tester);
    final String id = openedId(tester);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 900,
          height: 600,
          child: TerminalPanel(
            agentId: 'a1',
            webSocket: ws,
            onToggle: () {},
          ),
        ),
      ),
    ));
    await tester.pump();

    final Map<String, dynamic>? resize = ws.lastOf(TerminalInboundType.resize);
    expect(resize, isNotNull, reason: '窗口变大要告诉 PTY 新的列行数');
    expect(resize![TerminalFrame.terminalId], id);
  });

  // ── 选中 / 复制粘贴（用户 2026-10-03：「没法选中文字，没法复制粘贴」）──────────

  late List<String> clipboardWrites;
  String? clipboardRead;

  /// 剪贴板走平台通道：这里捕获写入、给读出备好内容。
  void mockClipboard(WidgetTester tester) {
    clipboardWrites = <String>[];
    clipboardRead = null;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardWrites
              .add((call.arguments as Map<dynamic, dynamic>)['text'] as String);
        } else if (call.method == 'Clipboard.getData') {
          return clipboardRead == null
              ? null
              : <String, dynamic>{'text': clipboardRead};
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
  }

  Future<void> pressWithCtrl(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool shift = false,
  }) async {
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
  }

  /// 画两行字并等它上屏（屏幕区从 y=31 开始：工具条 30 + 分割线 1）。
  Future<void> emitTwoLines(WidgetTester tester, String id) async {
    await emit(tester, <String, dynamic>{
      'type': TerminalOutboundType.output,
      TerminalFrame.terminalId: id,
      TerminalFrame.bytes: base64Encode(utf8.encode('hello\r\nworld')),
    });
  }

  testWidgets('左键拖拽选中文字 + Ctrl+C 复制到剪贴板（不再发 0x03）',
      (WidgetTester tester) async {
    await pumpPanel(tester);
    final String id = openedId(tester);
    await emitTwoLines(tester, id);
    mockClipboard(tester);

    await tester.dragFrom(const Offset(4, 35), const Offset(300, 24));
    await tester.pump();

    final TerminalPanelState state =
        tester.state<TerminalPanelState>(find.byType(TerminalPanel));
    expect(state.debugSelection, isNotNull, reason: '左键拖拽必须落下选区');
    expect(state.debugSelection!.isCollapsed, isFalse,
        reason: '拖了就该是跨格选区，不是一格');

    await pressWithCtrl(tester, LogicalKeyboardKey.keyC);

    expect(clipboardWrites, hasLength(1), reason: 'Ctrl+C 有选区时是复制');
    expect(clipboardWrites.single, contains('hello'));
    expect(clipboardWrites.single, contains('world'));
    expect(
      ws.inputTexts(id),
      isNot(contains('\u0003')),
      reason: '有选区时 Ctrl+C 不该再把 SIGINT 打给 shell',
    );
  });

  testWidgets('Ctrl+Shift+C / Ctrl+Insert 也是复制（不依赖 Ctrl+C 的两义）',
      (WidgetTester tester) async {
    await pumpPanel(tester);
    final String id = openedId(tester);
    await emitTwoLines(tester, id);
    mockClipboard(tester);

    await tester.dragFrom(const Offset(4, 35), const Offset(300, 24));
    await tester.pump();
    await pressWithCtrl(tester, LogicalKeyboardKey.keyC, shift: true);
    expect(clipboardWrites, hasLength(1));

    await pressWithCtrl(tester, LogicalKeyboardKey.insert);
    expect(clipboardWrites, hasLength(2), reason: 'Ctrl+Insert 是 Windows 上的老习惯');
  });

  testWidgets('没选中时 Ctrl+C 仍然发 0x03（SIGINT 语义不丢）',
      (WidgetTester tester) async {
    await pumpPanel(tester);
    final String id = openedId(tester);
    await emitTwoLines(tester, id);
    mockClipboard(tester);

    await pressWithCtrl(tester, LogicalKeyboardKey.keyC);
    expect(clipboardWrites, isEmpty);
    expect(
      ws.inputTexts(id).join(''),
      contains('\u0003'),
      reason: '没有选区时 Ctrl+C 必须照旧是中断信号',
    );
  });

  testWidgets('Ctrl+V 粘贴：换行归一成 \\r（PTY 认回车不认换行）',
      (WidgetTester tester) async {
    await pumpPanel(tester);
    final String id = openedId(tester);
    mockClipboard(tester);
    clipboardRead = 'ls\necho hi\r\npwd';

    await pressWithCtrl(tester, LogicalKeyboardKey.keyV);

    expect(ws.inputTexts(id).join(''), 'ls\recho hi\rpwd');
  });

  testWidgets('Shift+Insert 也是粘贴', (WidgetTester tester) async {
    await pumpPanel(tester);
    final String id = openedId(tester);
    mockClipboard(tester);
    clipboardRead = 'whoami';

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.insert);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(ws.inputTexts(id).join(''), 'whoami');
  });

  testWidgets('括号粘贴：应用开了 ?2004 就按 xterm 口径包 ESC[200~ … ESC[201~',
      (WidgetTester tester) async {
    await pumpPanel(tester);
    final String id = openedId(tester);
    mockClipboard(tester);
    await emit(tester, <String, dynamic>{
      'type': TerminalOutboundType.output,
      TerminalFrame.terminalId: id,
      TerminalFrame.bytes: base64Encode(utf8.encode('\u001b[?2004h')),
    });
    clipboardRead = 'ls\necho hi';

    await pressWithCtrl(tester, LogicalKeyboardKey.keyV);

    expect(ws.inputTexts(id).join(''), '\u001b[200~ls\recho hi\u001b[201~');
  });

  testWidgets('右键菜单：没选中时"复制"置灰并说明，粘贴可用',
      (WidgetTester tester) async {
    await pumpPanel(tester);
    final String id = openedId(tester);
    mockClipboard(tester);
    clipboardRead = 'dir';

    await tester.tap(find.byType(TerminalPanel), buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    expect(find.text('复制（先按住左键拖选一段）'), findsOneWidget);
    final PopupMenuItem<String> copyItem = tester.widget<PopupMenuItem<String>>(
      find.ancestor(
        of: find.text('复制（先按住左键拖选一段）'),
        matching: find.byType(PopupMenuItem<String>),
      ),
    );
    expect(copyItem.enabled, isFalse, reason: '没选区时"复制"应该点不动');

    await tester.tap(find.text('粘贴'));
    await tester.pumpAndSettle();
    expect(ws.inputTexts(id).join(''), 'dir');
  });

  testWidgets('单击清掉选区（新的一拖才是新选区）', (WidgetTester tester) async {
    await pumpPanel(tester);
    final String id = openedId(tester);
    await emitTwoLines(tester, id);

    await tester.dragFrom(const Offset(4, 35), const Offset(300, 24));
    await tester.pump();
    final TerminalPanelState state =
        tester.state<TerminalPanelState>(find.byType(TerminalPanel));
    expect(state.debugSelection, isNotNull);

    await tester.tapAt(const Offset(200, 100));
    await tester.pump();
    expect(state.debugSelection, isNull);
  });

  testWidgets('输出里出现"不受信任的装入点"⇒ 弹一次可读指引（不再让用户对着原文发愣）',
      (WidgetTester tester) async {
    await pumpPanel(tester);
    final String id = openedId(tester);
    // 分两帧喂，且切在中文多字节字符中间：跨帧也必须认出来
    final List<int> whole = utf8.encode(
      'CMake Error: 无法遍历该路径，因为它包含不受信任的装入点 : x',
    );
    for (final List<int> piece in <List<int>>[whole.sublist(0, 5), whole.sublist(5)]) {
      await emit(tester, <String, dynamic>{
        'type': TerminalOutboundType.output,
        TerminalFrame.terminalId: id,
        TerminalFrame.bytes: base64Encode(piece),
      });
    }
    await tester.pumpAndSettle();

    expect(find.textContaining('不受信任的装入点'), findsWidgets);
    expect(find.textContaining('known-issues.md #16'), findsWidgets);

    // 等第一条 SnackBar 自己消失（3s），再喂一次同样的输出：不该再弹（每会话一次）
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.textContaining('known-issues.md #16'), findsNothing,
        reason: '前一条提示该自己消失了，否则下面的断言没有意义');
    await emit(tester, <String, dynamic>{
      'type': TerminalOutboundType.output,
      TerminalFrame.terminalId: id,
      TerminalFrame.bytes: base64Encode(whole),
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('known-issues.md #16'), findsNothing,
        reason: '同一个会话里第二次出现不该再弹');
  });

  testWidgets('把光标那一格报给平台（IME 候选窗才贴着光标，不再用别处的陈旧矩形）',
      (WidgetTester tester) async {
    final List<MethodCall> calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.textInput,
      (MethodCall call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.textInput, null);
    });

    await pumpPanel(tester);
    await tester.pump();

    final Iterable<MethodCall> geometry = calls.where((MethodCall c) =>
        c.method == 'TextInput.setEditableSizeAndTransform' ||
        c.method == 'TextInput.setMarkedTextRect');
    expect(geometry, isNotEmpty,
        reason: 'Windows 就是用这两条消息摆 IME 窗口的（text_input_manager 的 caret_rect）');
    final MethodCall caret = calls.lastWhere(
      (MethodCall c) => c.method == 'TextInput.setMarkedTextRect',
    );
    final Map<String, dynamic> rect =
        (caret.arguments as Map<dynamic, dynamic>).cast<String, dynamic>();
    expect(rect['width'], greaterThan(0));
    expect(rect['height'], greaterThan(0));
  });
}
