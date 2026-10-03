import 'dart:async';
import 'dart:convert';

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
      reason: '键盘事件那条路不再转发字符：再发一遍会让每个字母进 shell 两次',
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
    state.debugImeClient.updateEditingValue(
      const TextEditingValue(
        text: 'ls',
        selection: TextSelection.collapsed(offset: 2),
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
}
