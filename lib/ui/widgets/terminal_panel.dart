import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tree_protocol/tree_protocol.dart';

import '../../io/websocket_service.dart';
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
  });

  /// 在哪个 agent 的工作区里起 shell（核心按它解析工作区根）
  final String agentId;

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

  @override
  void initState() {
    super.initState();
    _frames = widget.webSocket.terminalFrames.listen(_onFrame);
    // 主动展开的含义之一：进终端就把焦点放进去，用户直接能打字
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    // 关面板就把 shell 收掉：不留孤儿进程占着工作区
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

    final List<int>? bytes = _translateKey(event, ctrl: ctrl);
    if (bytes == null) return KeyEventResult.ignored;
    _sendInput(bytes);
    return KeyEventResult.handled;
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
    // 可打印字符：用 character（已按 shift/输入法解出），控制字符不转发
    final String? character = event.character;
    if (character == null || character.isEmpty) return null;
    final int code = character.codeUnitAt(0);
    if (code < 0x20 || code == 0x7f) return null;
    return utf8.encode(character);
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
        ],
      ),
    );
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
          screen: _screen,
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
    required this.screen,
    required this.cellWidth,
    required this.cellHeight,
    required this.baseStyle,
    required this.defaultForeground,
    required this.defaultBackground,
    required this.cursorColor,
  });

  final VtScreen screen;
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
    final List<List<VtCell>> lines = screen.lines;
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
    if (screen.cursorVisible) {
      final double left = screen.cursorColumn * cellWidth;
      final double top = screen.cursorRow * cellHeight;
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
