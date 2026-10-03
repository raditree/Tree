import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tree_protocol/tree_protocol.dart';

import '../../io/websocket_service.dart';
import '../services/terminal_ime_input.dart';
import '../services/terminal_send_command.dart';
import '../services/vt_screen.dart';

/// 集成终端（Ctrl+J）：真伪终端会话的渲染 + 键盘转发。
///
/// 分工：核心开 PTY、把**原始字节**发过来；[VtScreen] 把这些字节解析成「一块屏幕」；
/// 这里只做两件事——把屏幕画出来、把键盘**原样**转成字节发回去。真终端不该有
/// 「输入行」这个概念：vim 要的是每一次按键（方向键、Esc、Ctrl+C），不是一行命令。
///
/// 因此没有 TextField：所有按键都经 [Focus.onKeyEvent] 直接转发（Ctrl+J 例外，
/// 它留给"切回对话输入框"，见 [onToggle]）。
class TerminalPanel extends StatefulWidget {
  const TerminalPanel({
    super.key,
    required this.agentId,
    required this.webSocket,
    required this.onToggle,
    this.onClose,
    this.onSend,
  });

  /// 在哪个 agent 的工作区里起 shell（核心按它解析工作区根）
  final String agentId;

  /// `#TSend` 的落点：把一段文本（与可选的本机文件路径附件）发给**当前会话**。
  ///
  /// 与 composer 的发送口是同一个（[MessagePanelState._handleSend]）——终端里发出去的
  /// 消息因此和手打一条完全等价（上传附件、上屏、WS 帧都一样）。为 null 时
  /// `#TSend` 不可用（如实提示，不静默吞掉用户那一行）。
  final Future<bool> Function(String text, List<String> filePaths)? onSend;

  /// 与核心通信的 WS（终端帧走它自己的广播流，不混进消息分发）
  final WebSocketService webSocket;

  /// Ctrl+J：切回对话输入框
  final VoidCallback onToggle;

  /// 关闭终端（收起面板）
  final VoidCallback? onClose;

  @override
  State<TerminalPanel> createState() => TerminalPanelState();
}

class TerminalPanelState extends State<TerminalPanel> {
  /// 会话 id 由**前端**生成：核心按它路由输出与退出。
  /// 每次重开换一个新 id，免得旧会话的迟到输出泼到新屏幕上。
  String _terminalId = _newTerminalId();

  static String _newTerminalId() =>
      'term_${DateTime.now().microsecondsSinceEpoch}';

  final FocusNode _focus = FocusNode(debugLabel: 'terminal');
  StreamSubscription<Map<String, dynamic>>? _frames;

  /// 屏幕缓冲（cols/rows 随面板尺寸变）
  VtScreen _screen = VtScreen(columns: 80, rows: 24);

  /// `#TSend` 的按键拦截（以 `#` 开头、还可能是 `#TSend` 的那一行不发 shell）
  final TerminalSendInterceptor _send = TerminalSendInterceptor();

  /// **输入法通道**（中文 / 日文靠它；真机现象：终端里打不出中文，见
  /// [TerminalTextInputClient]）。它只在终端有焦点时打开连接。
  late final TerminalTextInputClient _ime = TerminalTextInputClient(
    onText: _handleImeText,
  );
  bool _opened = false;
  int _columns = 80;
  int _rows = 24;

  /// 单元格尺寸（等宽字体实测；用来把像素换算成列/行）
  double _cellWidth = 8;
  double _cellHeight = 17;

  String _cwd = '';
  String _shell = '';
  String? _error;
  int? _exitCode;

  /// 回滚偏移：0 = 跟最新（画 [VtScreen.lines]），>0 = 往上翻了多少行
  /// （画"历史尾部 + 当前屏"的那一段）。
  int _scrollOffset = 0;

  /// 已经同步过的 [VtScreen.historyPushed]：正在回滚时把视图**钉在同一段内容**上
  /// （新输出继续往下长，视野不动）——否则每来一帧用户就被拽回底部。
  int _historyPushedSeen = 0;

  @override
  void initState() {
    super.initState();
    _frames = widget.webSocket.terminalFrames.listen(_onFrame);
    // 焦点 = 输入法通道的开关：有焦点才 attach（没有焦点的连接收不到字，
    // 也会跟别处的文本输入抢平台连接）
    _focus.addListener(_syncImeConnection);
    // 主动展开的含义之一：进终端就把焦点放进去，用户直接能打字
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    // 关面板就把 shell 收掉：不留孤儿进程占着工作区
    _focus.removeListener(_syncImeConnection);
    _ime.detach();
    _frames?.cancel();
    widget.webSocket.send(<String, dynamic>{
      'type': TerminalInboundType.close,
      TerminalFrame.terminalId: _terminalId,
    });
    _focus.dispose();
    super.dispose();
  }

  /// 核心来的终端帧
  void _onFrame(Map<String, dynamic> frame) {
    final String id = (frame[TerminalFrame.terminalId] ?? '').toString();
    if (id != _terminalId) return; // 旧会话的迟到帧：丢掉
    final String type = (frame['type'] ?? '').toString();
    switch (type) {
      case TerminalOutboundType.ready:
        setState(() {
          _cwd = (frame[TerminalFrame.cwd] ?? '').toString();
          _shell = (frame[TerminalFrame.shell] ?? '').toString();
          _error = null;
          _exitCode = null;
        });
        break;
      case TerminalOutboundType.output:
        final String bytes = (frame[TerminalFrame.bytes] ?? '').toString();
        if (bytes.isEmpty) break;
        _screen.write(base64Decode(bytes));
        _flushResponses();
        _followHistory();
        setState(() {}); // 一帧一次重绘：同一帧里的多次 setState 会被合并
        break;
      case TerminalOutboundType.exit:
        setState(() {
          _exitCode = (frame[TerminalFrame.exitCode] as num?)?.toInt() ?? 0;
          // 进程都退出了，之前那句错误提示（如果有）就不再是当前状态
          _error = null;
        });
        break;
      case TerminalOutboundType.error:
        setState(() {
          _error = (frame[TerminalFrame.message] ?? '终端出错').toString();
        });
        break;
      default:
        break;
    }
  }

  /// 新输出滚掉了若干行时，把"正在回滚"的视图往前顶同样多的行。
  ///
  /// 语义：用户翻上去看历史时，新输出**不该**把他拽回底部（与真终端一致）——
  /// 视野固定在**同一段内容**上；他一直滚到底（`_scrollOffset == 0`）时才继续跟随。
  void _followHistory() {
    final int pushed = _screen.historyPushed;
    final int grew = pushed - _historyPushedSeen;
    _historyPushedSeen = pushed;
    if (grew <= 0 || _scrollOffset <= 0) return;
    _scrollOffset = (_scrollOffset + grew).clamp(0, _screen.historyLength);
  }

  /// VT 解析器要回写给 PTY 的应答（DSR / DA 之类）
  void _flushResponses() {
    final List<int> responses = _screen.takeResponses();
    if (responses.isEmpty) return;
    _sendInput(responses);
  }

  void _sendInput(List<int> bytes) {
    widget.webSocket.send(<String, dynamic>{
      'type': TerminalInboundType.input,
      TerminalFrame.terminalId: _terminalId,
      TerminalFrame.bytes: base64Encode(bytes),
    });
  }

  /// 开一个会话（尺寸取自当前布局）
  void _open() {
    widget.webSocket.send(<String, dynamic>{
      'type': TerminalInboundType.open,
      TerminalFrame.terminalId: _terminalId,
      TerminalFrame.agentId: widget.agentId,
      TerminalFrame.columns: _columns,
      TerminalFrame.rows: _rows,
    });
    setState(() {
      _opened = true;
      _error = null;
      _exitCode = null;
    });
    _focus.requestFocus();
  }

  /// 重开：换一个会话 id 重新开（旧会话由核心在 close 时收掉）
  void _restart() {
    widget.webSocket.send(<String, dynamic>{
      'type': TerminalInboundType.close,
      TerminalFrame.terminalId: _terminalId,
    });
    setState(() {
      _terminalId = _newTerminalId();
      _screen = VtScreen(columns: _columns, rows: _rows);
      _exitCode = null;
      _error = null;
      _cwd = '';
      _shell = '';
      _opened = false;
      // 新会话 = 新屏幕：回滚偏移与"历史水位"一起归零，否则会指到不存在的行
      _scrollOffset = 0;
      _historyPushedSeen = 0;
      _send.clear(); // 旧会话里扣住的那半截 `#T` 不带进新会话
    });
    _open();
  }

  /// 布局变化：把像素换算成列/行，屏幕与远端的 PTY 一起改。
  ///
  /// 这个函数是 LayoutBuilder 在**布局期间**调的：那里既不能 setState，也不该发帧
  /// （会打断布局），所以真正的副作用统一推到帧后回调里做。
  void _applySize(BoxConstraints constraints) {
    final int columns =
        (constraints.maxWidth / _cellWidth).floor().clamp(20, 500);
    final int rows =
        (constraints.maxHeight / _cellHeight).floor().clamp(5, 200);
    if (columns == _columns && rows == _rows && _opened) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final bool sizeChanged = columns != _columns || rows != _rows;
      _columns = columns;
      _rows = rows;
      _screen.resize(columns, rows);
      if (!_opened) {
        _open();
        return;
      }
      if (sizeChanged) {
        widget.webSocket.send(<String, dynamic>{
          'type': TerminalInboundType.resize,
          TerminalFrame.terminalId: _terminalId,
          TerminalFrame.columns: columns,
          TerminalFrame.rows: rows,
        });
      }
      setState(() {}); // 新尺寸下重画（列行数变了）
    });
  }

  /// 焦点变化 → 开关输入法连接（中文 / 日文要靠一条活着的文本输入连接才收得到）。
  void _syncImeConnection() {
    if (_focus.hasFocus) {
      _ime.attach();
    } else {
      _ime.detach();
    }
  }

  /// 输入法 / 直接键入交出来的**已定字**：逐个字符过 `#TSend` 拦截器，该吞的吞、
  /// 该发的发（可打印字符**只**从这条路来——键盘事件里再取一次就会发两遍）。
  void _handleImeText(String text) {
    if (text.isEmpty) return;
    final List<int> bytes = <int>[];
    // 按**码点**走（不是 UTF-16 编码单元）：emoji 这类补充平面字符不会被拆成两半
    for (final int rune in text.runes) {
      final List<int>? forward = _send.accept(String.fromCharCode(rune));
      if (forward == null) continue; // 还在 `#TSend` 前缀上：扣在本地
      bytes.addAll(forward);
    }
    // 一次定字发一帧（一轮 IME 提交就是一串字节，不必拆成多帧）
    if (bytes.isNotEmpty) _sendInput(bytes);
  }

  /// 键盘 → 字节。顺序：先让 Ctrl+J 走（切回对话），再按真终端的笨办法逐键翻译。
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final Set<LogicalKeyboardKey> pressed =
        HardwareKeyboard.instance.logicalKeysPressed;
    final bool ctrl = pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight);

    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyJ) {
      widget.onToggle();
      return KeyEventResult.handled;
    }

    // ── `#TSend`：这几行**只有本地知道**（见 [TerminalSendInterceptor]）────────
    // 1) 退格：缓存里的字符从没进过 shell，先吃本地缓存
    if (!ctrl &&
        event.logicalKey == LogicalKeyboardKey.backspace &&
        _send.backspace()) {
      return KeyEventResult.handled;
    }
    // 2) Enter：整行是 `#TSend …` 就发给会话（**不给 shell**）；否则把缓存补发 + 回车
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final TerminalSendCommand? command = _send.commit();
      if (command != null) {
        unawaited(_dispatchSend(command));
        return KeyEventResult.handled;
      }
      final List<int> pending = _send.release();
      if (pending.isNotEmpty) _sendInput(pending);
      _sendInput(<int>[0x0d]);
      return KeyEventResult.handled;
    }
    // 3) 其它按键（方向键 / Tab / Esc / Ctrl+C…）：先把缓存交还 shell，再照常转发
    //    （半截的 `#T` 因此不会消失，用户看到的与"从来没拦过"一致）
    final List<int> released = _send.release();
    final List<int>? bytes = _translateKey(event, ctrl: ctrl);
    if (released.isEmpty && bytes == null) return KeyEventResult.ignored;
    if (released.isNotEmpty) _sendInput(released);
    if (bytes != null) _sendInput(bytes);
    return KeyEventResult.handled;
  }

  /// `#TSend` 落到会话上：与 composer 的发送口同一个（上传附件、上屏、WS 帧）。
  ///
  /// 反馈只走 SnackBar：那一行**没进过 shell**，屏幕上的提示位置不属于它；
  /// 真要写进终端屏幕就得跟 shell 抢光标，得不偿失。
  Future<void> _dispatchSend(TerminalSendCommand command) async {
    final Future<bool> Function(String text, List<String> filePaths)? send =
        widget.onSend;
    if (send == null) {
      _notify('这条终端没有接到会话发送口，#TSend 不可用');
      return;
    }
    if (command.isEmpty) {
      _notify('#TSend 后面要跟一段话（可加引号）或 @文件路径');
      return;
    }
    final bool ok = await send(command.text, command.filePaths);
    if (!mounted) return;
    if (!ok) {
      _notify('终端发送失败：消息没有发出去（附件路径或核心状态有问题）');
      return;
    }
    final String what = command.text.trim().isEmpty
        ? '${command.filePaths.length} 个文件'
        : (command.text.length > 40
              ? '${command.text.substring(0, 40)}…'
              : command.text);
    _notify('已从终端发给会话：$what');
  }

  void _notify(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  /// 单个按键 → 终端字节（含 xterm 的转义序列）
  List<int>? _translateKey(KeyEvent event, {required bool ctrl}) {
    final LogicalKeyboardKey key = event.logicalKey;
    if (ctrl) {
      // Ctrl+字母 → 0x01..0x1A
      final int? code = _ctrlCode(key);
      if (code != null) return <int>[code];
    }
    switch (key) {
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        return <int>[0x0d];
      case LogicalKeyboardKey.backspace:
        return <int>[0x7f];
      case LogicalKeyboardKey.tab:
        return <int>[0x09];
      case LogicalKeyboardKey.escape:
        return <int>[0x1b];
      case LogicalKeyboardKey.arrowUp:
        return _cursor('A');
      case LogicalKeyboardKey.arrowDown:
        return _cursor('B');
      case LogicalKeyboardKey.arrowRight:
        return _cursor('C');
      case LogicalKeyboardKey.arrowLeft:
        return _cursor('D');
      case LogicalKeyboardKey.home:
        return _csi('H');
      case LogicalKeyboardKey.end:
        return _csi('F');
      case LogicalKeyboardKey.insert:
        return _csi('2~');
      case LogicalKeyboardKey.delete:
        return _csi('3~');
      case LogicalKeyboardKey.pageUp:
        return _csi('5~');
      case LogicalKeyboardKey.pageDown:
        return _csi('6~');
      default:
        break;
    }
    // 可打印字符**不在这里转发**：它们（含输入法组出来的中文）统一从文本输入通道来
    // （见 [_handleImeText]）——两条路都发一遍的话每个字符会进shell两次。
    return null;
  }

  /// 应用光标键模式（DECCKM）下方向键用 SS3
  List<int> _cursor(String letter) {
    if (_screen.applicationCursorKeys) {
      return <int>[0x1b, 0x4f, letter.codeUnitAt(0)];
    }
    return _csi(letter);
  }

  static List<int> _csi(String tail) =>
      <int>[0x1b, 0x5b, ...utf8.encode(tail)];

  static int? _ctrlCode(LogicalKeyboardKey key) {
    final String label = key.keyLabel.toLowerCase();
    if (label.length != 1) return null;
    final int code = label.codeUnitAt(0);
    if (code < 0x61 || code > 0x7a) return null;
    return code - 0x60;
  }

  /// 仅供测试：拿到输入法通道，直接喂 `updateEditingValue`（等价于平台回调）。
  ///
  /// 可打印字符**只**从这条路来（键盘事件那条路不再转发字符），所以键盘用例必须能
  /// 驱动它，否则"终端能打字"就没被任何测试盖住。
  @visibleForTesting
  TerminalTextInputClient get debugImeClient => _ime;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.surface,
      child: Column(
        children: <Widget>[
          _buildToolbar(cs),
          Divider(height: 1, thickness: 1, color: Theme.of(context).dividerColor),
          Expanded(
            child: Focus(
              focusNode: _focus,
              onKeyEvent: _handleKey,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _focus.requestFocus,
                // 滚轮翻回滚缓冲（终端里没有"滚动条"，鼠标滚轮是唯一入口）；
                // 键盘一律转发给 PTY（PageUp/方向键在 vim/less 里有用），不劫持。
                child: Listener(
                  onPointerSignal: _handlePointerSignal,
                  child: LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints constraints) {
                      _measureText(cs);
                      _applySize(constraints);
                      return _buildScreen(cs, constraints);
                    },
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 鼠标滚轮 → 回滚偏移（向下滚 = 看更新的内容）。
  ///
  /// 步长 3 行：与大多数终端一致；到顶 / 到底就夹住，并且**滚到底自动恢复跟随**。
  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (_screen.historyLength == 0 && _scrollOffset == 0) return;
    final int steps = event.scrollDelta.dy > 0 ? -3 : 3;
    _scrollTo(_scrollOffset + steps);
  }

  void _scrollTo(int offset) {
    final int next = offset.clamp(0, _screen.historyLength);
    if (next == _scrollOffset) return;
    setState(() => _scrollOffset = next);
  }

  /// 当前该画的 rows 行：`_scrollOffset == 0` 时就是屏幕本身，
  /// 否则是"历史尾部 + 当前屏顶部"的一段窗口。
  List<List<VtCell>> _visibleRows() {
    final List<List<VtCell>> live = _screen.lines;
    final List<List<VtCell>> history = _screen.history;
    if (_scrollOffset <= 0 || history.isEmpty) return live;
    final int rows = live.length;
    final int total = history.length + rows;
    final int start = (total - rows - _scrollOffset).clamp(0, history.length);
    return <List<VtCell>>[
      for (int i = 0; i < rows; i++)
        if (start + i < history.length)
          history[start + i]
        else
          live[start + i - history.length],
    ];
  }

  /// 工具条：shell / cwd + 重开 / 清屏 / 关闭
  Widget _buildToolbar(ColorScheme cs) {
    final String location = _cwd.isEmpty ? '工作区' : _cwd;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: <Widget>[
          Icon(Icons.terminal, size: 14, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _error ?? '${_shell.isEmpty ? '终端' : _shell} · $location',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: _error != null ? cs.error : cs.onSurfaceVariant,
              ),
            ),
          ),
          if (_scrollOffset > 0) _buildScrollChip(cs),
          if (_exitCode != null && _error == null)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(
                '已退出（\$_exitCode）· Ctrl+J 返回',
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Text(
                'Ctrl+J 返回对话',
                style: TextStyle(fontSize: 11, color: cs.outline),
              ),
            ),
          IconButton(
            tooltip: '重开终端',
            icon: const Icon(Icons.refresh, size: 15),
            color: cs.onSurfaceVariant,
            onPressed: _restart,
          ),
          IconButton(
            tooltip: '清屏（Ctrl+L）',
            icon: const Icon(Icons.cleaning_services_outlined, size: 15),
            color: cs.onSurfaceVariant,
            onPressed: () => _sendInput(<int>[0x0c]),
          ),
          IconButton(
            tooltip: '收起终端（Ctrl+J）',
            icon: const Icon(Icons.close, size: 15),
            color: cs.onSurfaceVariant,
            onPressed: widget.onClose ?? widget.onToggle,
          ),
        ],
      ),
    );
  }

  /// 「已回滚 N 行」的小胶囊：点一下回到最新（滚轮翻上去之后唯一的可见状态）。
  Widget _buildScrollChip(ColorScheme cs) {
    return Tooltip(
      message: '已往上翻 $_scrollOffset 行（鼠标滚轮继续翻）· 点这里回到最新',
      child: InkWell(
        onTap: () => _scrollTo(0),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          margin: const EdgeInsets.only(right: 6),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: cs.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: cs.primary.withValues(alpha: 0.35)),
          ),
          child: Text(
            '已回滚 $_scrollOffset 行',
            style: TextStyle(fontSize: 11, color: cs.primary),
          ),
        ),
      ),
    );
  }

  /// 实测等宽字体的单元格尺寸（列数=宽/字宽，行数=高/行高）
  void _measureText(ColorScheme cs) {
    final TextPainter painter = TextPainter(
      text: const TextSpan(text: 'MMMMMMMMMM', style: _baseStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    if (painter.width > 0) _cellWidth = painter.width / 10;
    if (painter.height > 0) _cellHeight = painter.height;
  }

  static const TextStyle _baseStyle = TextStyle(
    fontSize: 13,
    height: 1.25,
    fontFamily: 'Consolas',
    fontFamilyFallback: <String>['Cascadia Mono', 'DejaVu Sans Mono', 'monospace'],
  );

  Widget _buildScreen(ColorScheme cs, BoxConstraints constraints) {
    return ClipRect(
      child: CustomPaint(
        size: Size(constraints.maxWidth, constraints.maxHeight),
        painter: _TerminalPainter(
          rows: _visibleRows(),
          // 回滚时不画光标：它属于"当前屏"，画在历史行上会误导
          cursorColumn: _screen.cursorColumn,
          cursorRow: _screen.cursorRow,
          showCursor: _screen.cursorVisible && _scrollOffset == 0,
          cellWidth: _cellWidth,
          cellHeight: _cellHeight,
          baseStyle: _baseStyle,
          defaultForeground: cs.onSurface,
          defaultBackground: cs.surface,
          cursorColor: cs.primary,
        ),
      ),
    );
  }
}

/// 把屏幕缓冲画成格子。
///
/// 为什么按「同属性的连续格子」合成一个 TextPainter：80x24 逐格建 TextPainter 每帧要
/// 上千次文本布局，滚动时会卡；合成之后一行通常只有几个 run。
class _TerminalPainter extends CustomPainter {
  _TerminalPainter({
    required this.rows,
    required this.cursorColumn,
    required this.cursorRow,
    required this.showCursor,
    required this.cellWidth,
    required this.cellHeight,
    required this.baseStyle,
    required this.defaultForeground,
    required this.defaultBackground,
    required this.cursorColor,
  });

  /// 要画的行：跟随时是屏幕本身，回滚时是"历史尾部 + 当前屏"的一段窗口
  /// （由 [TerminalPanelState._visibleRows] 算好——画笔只管画）。
  final List<List<VtCell>> rows;

  final int cursorColumn;
  final int cursorRow;
  final bool showCursor;
  final double cellWidth;
  final double cellHeight;
  final TextStyle baseStyle;
  final Color defaultForeground;
  final Color defaultBackground;
  final Color cursorColor;

  /// 标准 16 色（暗色主题下可读的那一套）
  static const List<Color> _basic = <Color>[
    Color(0xFF1B1F1C), // 0 黑
    Color(0xFFE06C75), // 1 红
    Color(0xFF7FD1A6), // 2 绿
    Color(0xFFE8C07D), // 3 黄
    Color(0xFF6FB7E8), // 4 蓝
    Color(0xFFC792EA), // 5 品红
    Color(0xFF4DD0E1), // 6 青
    Color(0xFFE6F3EC), // 7 白
    Color(0xFF5E8E71), // 8 亮黑（灰）
    Color(0xFFFF8A80), // 9 亮红
    Color(0xFF9BE8C0), // 10 亮绿
    Color(0xFFF5D6A0), // 11 亮黄
    Color(0xFF9CCBF0), // 12 亮蓝
    Color(0xFFDDB0F3), // 13 亮品红
    Color(0xFF7FE3F0), // 14 亮青
    Color(0xFFFFFFFF), // 15 亮白
  ];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = defaultBackground);
    final List<List<VtCell>> lines = rows;
    final Paint fill = Paint();
    for (int row = 0; row < lines.length; row++) {
      final double top = row * cellHeight;
      if (top > size.height) break;
      final List<VtCell> line = lines[row];
      int col = 0;
      while (col < line.length) {
        final VtCell cell = line[col];
        // 宽字符的右半格是空串（占位）：位置由左半格那一格覆盖，这里跳过
        if (cell.text.isEmpty) {
          col++;
          continue;
        }
        int end = col + 1;
        while (end < line.length &&
            line[end].text.isNotEmpty &&
            line[end].attr == cell.attr) {
          end++;
        }
        final VtAttr attr = cell.attr;
        final Color fg = _color(attr.foreground, fallback: defaultForeground);
        final Color bg = _color(attr.background, fallback: defaultBackground);
        final Color bgPaint = attr.inverse ? fg : bg;
        final Color fgPaint = attr.inverse ? bg : fg;
        if (bgPaint != defaultBackground && bgPaint.a > 0) {
          fill.color = bgPaint;
          canvas.drawRect(
            Rect.fromLTWH(
              col * cellWidth,
              top,
              (end - col) * cellWidth,
              cellHeight,
            ),
            fill,
          );
        }
        if (!attr.hidden) {
          final String run = line
              .sublist(col, end)
              .map((VtCell c) => c.text)
              .join();
          final TextPainter painter = TextPainter(
            text: TextSpan(text: run, style: _styleFor(attr, fgPaint)),
            textDirection: TextDirection.ltr,
          )..layout();
          painter.paint(canvas, Offset(col * cellWidth, top));
        }
        col = end;
      }
    }
    if (showCursor) {
      final double left = cursorColumn * cellWidth;
      final double top = cursorRow * cellHeight;
      if (left < size.width && top < size.height) {
        canvas.drawRect(
          Rect.fromLTWH(left, top, cellWidth, cellHeight),
          Paint()..color = cursorColor.withValues(alpha: 0.75),
        );
      }
    }
  }

  TextStyle _styleFor(VtAttr attr, Color color) {
    return baseStyle.copyWith(
      color: attr.dim ? color.withValues(alpha: 0.55) : color,
      fontWeight: attr.bold ? FontWeight.bold : FontWeight.normal,
      fontStyle: attr.italic ? FontStyle.italic : FontStyle.normal,
      decoration: attr.underline
          ? (attr.strike ? TextDecoration.combine(<TextDecoration>[
              TextDecoration.underline,
              TextDecoration.lineThrough,
            ]) : TextDecoration.underline)
          : (attr.strike ? TextDecoration.lineThrough : TextDecoration.none),
    );
  }

  /// ANSI 256 色索引 → 颜色（-1 = 默认色）
  Color _color(int index, {required Color fallback}) {
    if (index < 0) return fallback;
    if (index < 16) return _basic[index];
    if (index < 232) {
      final int i = index - 16;
      int ramp(int n) => n == 0 ? 0 : 55 + n * 40;
      return Color.fromARGB(
        255,
        ramp((i ~/ 36) % 6),
        ramp((i ~/ 6) % 6),
        ramp(i % 6),
      );
    }
    final int gray = 8 + (index - 232) * 10;
    return Color.fromARGB(255, gray, gray, gray);
  }

  /// 每次 setState 都是一次"屏幕变了"，且缓冲是**原地修改**的同一个实例，
  /// 逐字段比较没有意义——直接重画（一帧一次，成本可接受）。
  @override
  bool shouldRepaint(covariant _TerminalPainter oldDelegate) => true;
}
