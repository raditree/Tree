/// 终端屏幕缓冲（VT / ANSI 转义序列解析器）——**纯 Dart，不依赖 Flutter**。
///
/// 职责：把 PTY 出来的**原始字节**解析成一块可渲染的字符网格（见 lines），并收集终端
/// 需要**回写**给 PTY 的应答（见 takeResponses）。本文件不 import Flutter、不 import
/// dart:io、不发网络请求，只做「字节 → 屏幕」的转换，所以能直接单测。
/// UTF-8 解码是手写的增量解码器（见 write），为的是跨 write 分块时能接上半个字符。
///
/// ## 已支持
/// - 可打印字符：UTF-8（含跨 write 分块的多字节字符）、CJK/emoji 宽字符占两格、
///   组合记号（零宽）忽略；自动换行 DECAWM（?7），含行尾**延迟换行**（pending wrap）。
/// - 控制字符：CR、LF、VT、FF、BS、TAB（固定 8 列制表位）、BEL（忽略）。
/// - SGR（CSI ... m）：0/1/2/3/4/7/8/9/22/23/24/27/28/29、30-37/39、40-47/49、
///   90-97/100-107、38;5;n 与 48;5;n、38;2;r;g;b 与 48;2;r;g;b（RGB 就近落到 256 索引）。
/// - 光标：A B C D E F G H f d e a、反引号(HPA)、I、Z（计数缺省值 1）、s/u、
///   ESC 7 / ESC 8、?25 h/l 可见性、?6 h/l 原点模式、?1 h/l 应用光标键（只记状态）。
/// - 擦除/编辑：J(ED 0/1/2/3)、K(EL 0/1/2)、X、P、@、L、M、ANS 模式 4(IRM) 插入模式。
/// - 滚动：S/T、滚动区域 r(DECSTBM)、ESC D(IND)、ESC M(RI)、ESC E(NEL)。
/// - 模式：?1049（备用屏 + 保存/恢复光标，vim 必用）、?1047/?47、?1048、
///   ?7（自动换行）、?2004（括号粘贴，只记状态）、?1（应用光标键，只记状态）。
/// - 应答：CSI 6 n (DSR-CPR)、CSI 5 n (DSR-OK)、CSI c (DA1)、CSI > c (DA2)。
/// - 安全跳过：OSC（ESC ] ... BEL/ST）、DCS/APC/PM（ESC P/_/^ ... ST）、字符集选择
///   （ESC ( ) * + 后跟一个字节）、不认识或畸形的 CSI/ESC —— 一律丢弃，不打印、不抛异常。
///
/// ## 没做 / 不完整（已知取舍，给 known-issues 用）
/// - **没有回滚缓冲（scrollback）**：ED3（CSI 3 J）视为无操作。
/// - **没有真正的制表位表**：TAB / CSI I / CSI Z 按固定 8 列步进；HTS(ESC H)、
///   TBC(CSI g) 不生效。
/// - **组合记号（零宽字符）直接丢弃**，不做「贴到前一格合成一个字素」的处理。
/// - **宽字符右半格用空串** 标记（见 VtCell.text），不是空格；渲染方必须跳过它。
/// - **RGB 真彩**：38;2 与 38:2:... 一律按「取 3 个数值」处理。若对方用 ITU T.416 的
///   38:2:<色空间>:r:g:b 且色空间字段非空，取色会错位（真彩本身也被压成 256 色）。
/// - SGR 21（双下划线/关粗体）、10-19（字体选择）、4:3（花式下划线）等**未处理**，忽略。
/// - OSC **不解析内容**：窗口标题、OSC 8 超链接、OSC 52 剪贴板等全部丢弃。
/// - 鼠标/焦点上报（?1000-?1006、?1004 等）**只记状态，不回写序列**；
///   ?2004、?1 也只暴露状态给调用方（见 bracketedPaste、applicationCursorKeys）。
/// - 备用屏只保留**一块**主屏快照（标准行为），不实现多屏栈。
/// - 不处理 8 位 C1 控制码（0x9B 等）；现代 PTY 用 UTF-8，不会发。
/// - 擦除/滚动填充使用**当前 SGR 属性**（BCE 风格），不是固定默认属性。
library;

/// 单元格属性。
///
/// 颜色是 **ANSI 256 色索引**（0-255），-1 表示「默认色」（由渲染方决定）；
/// 真彩 38;2;r;g;b 会被就近折算成 256 索引（见文件头「没做」）。
class VtAttr {
  const VtAttr({
    this.foreground = -1,
    this.background = -1,
    this.bold = false,
    this.dim = false,
    this.italic = false,
    this.underline = false,
    this.inverse = false,
    this.hidden = false,
    this.strike = false,
  });

  /// 前景色：0..255，或 -1（默认）
  final int foreground;

  /// 背景色：0..255，或 -1（默认）
  final int background;

  final bool bold;
  final bool dim;
  final bool italic;
  final bool underline;
  final bool inverse;
  final bool hidden;
  final bool strike;

  @override
  bool operator ==(Object other) =>
      other is VtAttr &&
      other.foreground == foreground &&
      other.background == background &&
      other.bold == bold &&
      other.dim == dim &&
      other.italic == italic &&
      other.underline == underline &&
      other.inverse == inverse &&
      other.hidden == hidden &&
      other.strike == strike;

  @override
  int get hashCode => Object.hash(foreground, background, bold, dim, italic,
      underline, inverse, hidden, strike);

  @override
  String toString() => 'VtAttr(fg: $foreground, bg: $background, '
      'b: $bold, d: $dim, i: $italic, u: $underline, '
      'inv: $inverse, hid: $hidden, s: $strike)';
}

/// 一个屏幕单元格（不可变值对象）。
class VtCell {
  const VtCell(this.text, this.attr);

  /// 一个字符（可能是一个 UTF-16 代理对，即一个码点）。
  ///
  /// **约定**：宽字符（CJK/emoji）占两格，左边一格是字符本身，右边一格是
  /// **空串**（长度为 0），表示「被左边那格盖住，渲染时跳过」。普通空白格是空格，
  /// 所以空串与空格不会混。渲染方判断 text.isEmpty 即可跳过。
  final String text;

  final VtAttr attr;

  @override
  String toString() {
    final String body = text.isEmpty ? '<宽字符右半格>' : text;
    return 'VtCell($body, $attr)';
  }
}

/// 终端屏幕：吃字节、吐网格 + 回写应答。
class VtScreen {
  VtScreen({required int columns, required int rows})
      : _cols = columns < 1 ? 1 : columns,
        _rows = rows < 1 ? 1 : rows {
    _mainGrid = _blankGrid(_cols, _rows);
    _altGrid = _blankGrid(_cols, _rows);
    _scrollBottom = _rows - 1;
  }

  // ---------------------------------------------------------------- 基本状态

  int _cols;
  int _rows;

  late List<List<VtCell>> _mainGrid;
  late List<List<VtCell>> _altGrid;

  /// 当前屏幕上吃的格子（跟随备用屏切换）
  List<List<VtCell>> get _grid => _alt ? _altGrid : _mainGrid;

  int _cursorX = 0;
  int _cursorY = 0;
  bool _cursorVisible = true;

  /// 行尾延迟换行：在最后一列写过字后，下一个可打印字符才真正换行（DEC 语义）
  bool _pendingWrap = false;

  bool _autoWrap = true;
  bool _alt = false;
  bool _originMode = false;
  bool _insertMode = false;
  bool _bracketedPaste = false;
  bool _applicationCursorKeys = false;

  int _scrollTop = 0;
  int _scrollBottom = 0;

  bool _dirty = true;

  final List<int> _responses = <int>[];

  final _Pen _pen = _Pen();
  final _Pen _savedPen = _Pen();
  int _savedX = 0;
  int _savedY = 0;

  /// 见过的私有模式号（含只记状态的 2004/1/1000 等）
  final Set<int> _privateModes = <int>{};
  final Set<int> _ansiModes = <int>{};

  // ---------------------------------------------------------------- 对外只读

  int get columns => _cols;
  int get rows => _rows;

  /// 可读的屏幕行：lines[row][col]，长度恒为 columns、行数恒为 rows。
  ///
  /// 返回的是**内部网格本身**（不拷贝，渲染方每帧遍历不产生分配）。
  /// 调用方只读，不要改。
  List<List<VtCell>> get lines => _grid;

  int get cursorColumn => _cursorX;
  int get cursorRow => _cursorY;
  bool get cursorVisible => _cursorVisible;

  /// 是否处于备用屏（vim/top 用）；界面可据此显示「（备用屏）」
  bool get alternateScreen => _alt;

  /// 自上次 clearDirty 以来屏幕（含光标/属性/模式）是否变过
  bool get dirty => _dirty;

  /// 额外状态：自动换行 DECAWM（?7）
  bool get autoWrap => _autoWrap;

  /// 额外状态：括号粘贴（?2004）。模块只记状态，粘贴内容由调用方自己包 ESC[200~ / ESC[201~
  bool get bracketedPaste => _bracketedPaste;

  /// 额外状态：应用光标键（?1）。模块只记状态，按键编码由调用方决定
  bool get applicationCursorKeys => _applicationCursorKeys;

  /// 额外状态：原点模式（?6）
  bool get originMode => _originMode;

  /// 额外状态：插入模式（ANS 模式 4，IRM）
  bool get insertMode => _insertMode;

  int get scrollTop => _scrollTop;
  int get scrollBottom => _scrollBottom;

  /// 额外状态：某个私有模式当前是否打开（未知模式只记状态、不产生行为）
  bool privateModeEnabled(int mode) => _privateModes.contains(mode);

  /// 额外状态：某个 ANSI（无 ? 前缀）模式当前是否打开
  bool ansiModeEnabled(int mode) => _ansiModes.contains(mode);

  void clearDirty() {
    _dirty = false;
  }

  /// 终端**要回写**给 PTY 的应答字节（DSR/DA 之类），取走后清空。
  List<int> takeResponses() {
    if (_responses.isEmpty) return <int>[];
    final List<int> out = List<int>.of(_responses);
    _responses.clear();
    return out;
  }

  /// 调试用：把屏幕拼成多行字符串（宽字符右半格跳过）
  @override
  String toString() {
    final StringBuffer sb = StringBuffer()
      ..write('VtScreen(')
      ..write(_cols)
      ..write('x')
      ..write(_rows)
      ..write(', cursor=')
      ..write(_cursorX)
      ..write(',')
      ..write(_cursorY)
      ..write(', alt=')
      ..write(_alt)
      ..write(')');
    for (int y = 0; y < _rows; y++) {
      sb.write('\n');
      for (final VtCell c in _grid[y]) {
        sb.write(c.text);
      }
    }
    return sb.toString();
  }

  // ---------------------------------------------------------------- 尺寸

  /// 改尺寸：保留左上角内容、超出部分丢弃，光标夹回范围内；
  /// 被裁掉的半个宽字符退化成空格，滚动区域重置为整屏。
  void resize(int columns, int rows) {
    final int c = columns < 1 ? 1 : columns;
    final int r = rows < 1 ? 1 : rows;
    if (c == _cols && r == _rows) return;
    _mainGrid = _resizeGrid(_mainGrid, c, r);
    _altGrid = _resizeGrid(_altGrid, c, r);
    _cols = c;
    _rows = r;
    _scrollTop = 0;
    _scrollBottom = _rows - 1;
    _cursorX = _cursorX.clamp(0, _cols - 1);
    _cursorY = _cursorY.clamp(0, _rows - 1);
    _savedX = _savedX.clamp(0, _cols - 1);
    _savedY = _savedY.clamp(0, _rows - 1);
    _pendingWrap = false;
    _markDirty();
  }

  List<List<VtCell>> _resizeGrid(List<List<VtCell>> old, int c, int r) {
    final List<List<VtCell>> out = <List<VtCell>>[];
    for (int y = 0; y < r; y++) {
      final List<VtCell> line =
          List<VtCell>.generate(c, (_) => _blankCell, growable: true);
      if (y < old.length) {
        final List<VtCell> src = old[y];
        for (int x = 0; x < c && x < src.length; x++) {
          line[x] = src[x];
        }
      }
      _normalizeWide(line);
      out.add(line);
    }
    return out;
  }

  /// 把裁切后「缺了一半」的宽字符修回空格，保证网格自洽
  void _normalizeWide(List<VtCell> line) {
    for (int x = 0; x < line.length; x++) {
      final String t = line[x].text;
      if (t.isEmpty) {
        // 右半格：左边必须是真正的宽字符，否则当空格
        if (x == 0 || _cellWidth(line[x - 1]) != 2) {
          line[x] = _blankCell;
        }
      } else if (_cellWidth(line[x]) == 2 &&
          (x + 1 >= line.length || line[x + 1].text.isNotEmpty)) {
        // 宽字符缺右半格（被裁掉或原本就不成对）
        line[x] = _blankCell;
      }
    }
  }

  // ---------------------------------------------------------------- 字节入口

  /// 半字符残留（跨 write 分块）
  List<int> _pendingBytes = <int>[];

  /// 吃一段原始字节。内部按 UTF-8 增量解码，跨块的多字节字符会接上。
  /// 非法字节按 U+FFFD 处理，任何输入都不抛异常。
  void write(List<int> bytes) {
    if (bytes.isEmpty) return;
    final List<int> data;
    if (_pendingBytes.isEmpty) {
      data = bytes;
    } else {
      data = <int>[..._pendingBytes, ...bytes];
      _pendingBytes = <int>[];
    }
    int i = 0;
    final int n = data.length;
    while (i < n) {
      final int b = data[i];
      if (b < 0x80) {
        _feed(b);
        i++;
        continue;
      }
      int need;
      int cp;
      if (b >= 0xF0 && b <= 0xF7) {
        need = 4;
        cp = b & 0x07;
      } else if (b >= 0xE0 && b <= 0xEF) {
        need = 3;
        cp = b & 0x0F;
      } else if (b >= 0xC2 && b <= 0xDF) {
        need = 2;
        cp = b & 0x1F;
      } else {
        // 0x80..0xC1、0xF8..0xFF：非法起始字节
        _feed(0xFFFD);
        i++;
        continue;
      }
      if (i + need > n) {
        // 只到了一部分，留给下一次 write
        _pendingBytes = data.sublist(i);
        break;
      }
      bool ok = true;
      for (int k = 1; k < need; k++) {
        final int cb = data[i + k];
        if ((cb & 0xC0) != 0x80) {
          ok = false;
          break;
        }
        cp = (cp << 6) | (cb & 0x3F);
      }
      if (!ok || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
        _feed(0xFFFD);
        i++;
        continue;
      }
      _feed(cp);
      i += need;
    }
  }

  // ---------------------------------------------------------------- 解析状态机

  static const int _sGround = 0;
  static const int _sEscape = 1;
  static const int _sCsi = 2;
  static const int _sOsc = 3;
  static const int _sCharset = 4;

  int _state = _sGround;
  final StringBuffer _csiParams = StringBuffer();
  final StringBuffer _csiInter = StringBuffer();
  int _csiPrivate = 0;
  bool _oscEsc = false;

  void _feed(int cp) {
    switch (_state) {
      case _sGround:
        _ground(cp);
        return;
      case _sEscape:
        _escape(cp);
        return;
      case _sCsi:
        _csi(cp);
        return;
      case _sOsc:
        _osc(cp);
        return;
      case _sCharset:
        // 字符集选择：吃掉一个字节就走（不支持 G0/G1 图形字符集）
        _state = _sGround;
        return;
    }
  }

  void _ground(int cp) {
    if (cp == 0x1B) {
      _state = _sEscape;
      return;
    }
    if (cp == 0x0D) {
      _setCursor(0, _cursorY);
      return;
    }
    if (cp == 0x0A || cp == 0x0B || cp == 0x0C) {
      _lineFeed();
      return;
    }
    if (cp == 0x08) {
      if (_cursorX > 0) {
        _setCursor(_cursorX - 1, _cursorY);
      } else {
        _pendingWrap = false;
      }
      return;
    }
    if (cp == 0x09) {
      _tabForward();
      return;
    }
    if (cp == 0x07) return; // BEL：不响铃
    if (cp == 0x0E || cp == 0x0F) return; // SO/SI 字符集切换：不支持
    if (cp < 0x20 || cp == 0x7F) return; // 其它 C0 / DEL：忽略
    _putChar(cp);
  }

  void _escape(int cp) {
    _state = _sGround;
    switch (cp) {
      case 0x1B:
        _state = _sEscape; // 连续 ESC
        return;
      case 0x5B: // '['
        _state = _sCsi;
        _csiParams.clear();
        _csiInter.clear();
        _csiPrivate = 0;
        return;
      case 0x5D: // ']' OSC
      case 0x50: // 'P' DCS
      case 0x58: // 'X' SOS
      case 0x5E: // '^' PM
      case 0x5F: // '_' APC
        _state = _sOsc;
        _oscEsc = false;
        return;
      case 0x28: // '(' G0
      case 0x29: // ')' G1
      case 0x2A: // '*' G2
      case 0x2B: // '+' G3
        _state = _sCharset;
        return;
      case 0x37: // '7' DECSC 保存光标
        _saveCursor();
        return;
      case 0x38: // '8' DECRC 恢复光标
        _restoreCursor();
        return;
      case 0x44: // 'D' IND 索引（下移，必要时滚屏）
        _lineFeed();
        return;
      case 0x4D: // 'M' RI 反索引（上移，必要时反向滚屏）
        _reverseIndex();
        return;
      case 0x45: // 'E' NEL 下一行行首
        _setCursor(0, _cursorY);
        _lineFeed();
        return;
      case 0x63: // 'c' RIS 全复位
        _reset();
        return;
      case 0x3D: // '=' DECKPAM 应用键盘
        _applicationCursorKeys = true;
        return;
      case 0x3E: // '>' DECKPNM 数字键盘
        _applicationCursorKeys = false;
        return;
      default:
        // 不认识的 ESC 序列：已经回到 ground，安全跳过
        return;
    }
  }

  void _csi(int cp) {
    if (cp == 0x1B) {
      _state = _sEscape; // CSI 里冒出 ESC：重新当转义开始
      return;
    }
    if (cp >= 0x30 && cp <= 0x3F) {
      if (_csiParams.isEmpty &&
          (cp == 0x3F || cp == 0x3E || cp == 0x3C || cp == 0x3D)) {
        _csiPrivate = cp; // '?' '>' '<' '='
      } else {
        _csiParams.writeCharCode(cp);
      }
      return;
    }
    if (cp >= 0x20 && cp <= 0x2F) {
      _csiInter.writeCharCode(cp); // 中间字节（SP ! " # $ 等）
      return;
    }
    if (cp >= 0x40 && cp <= 0x7E) {
      _state = _sGround;
      // 带中间字节的序列（CSI SP q、CSI ! p 等）没有实现，安全跳过
      if (_csiInter.isEmpty) {
        _dispatchCsi(cp, _csiParams.toString(), _csiPrivate);
      }
      _csiParams.clear();
      _csiInter.clear();
      _csiPrivate = 0;
      return;
    }
    // 其它字节（含 C0）：畸形序列，安全跳过
    _state = _sGround;
    _csiParams.clear();
    _csiInter.clear();
    _csiPrivate = 0;
  }

  void _osc(int cp) {
    if (_oscEsc) {
      if (cp == 0x5C) {
        _state = _sGround; // ST：结束
        _oscEsc = false;
      } else if (cp != 0x1B) {
        _oscEsc = false;
      }
      return;
    }
    if (cp == 0x07) {
      _state = _sGround; // BEL 结束
      return;
    }
    if (cp == 0x1B) {
      _oscEsc = true;
      return;
    }
    // OSC 内容一律丢弃
  }

  static final RegExp _paramSplitter = RegExp(r'[;:]');

  List<int?> _parseParams(String raw) {
    if (raw.isEmpty) return const <int?>[];
    return raw
        .split(_paramSplitter)
        .map<int?>((String p) => p.isEmpty ? null : int.tryParse(p))
        .toList(growable: false);
  }

  static int _p(List<int?> ps, int i, int fallback) {
    if (i >= 0 && i < ps.length) {
      final int? v = ps[i];
      if (v != null) return v;
    }
    return fallback;
  }

  /// 计数类参数：缺省或 0/负数都当 1
  static int _count(List<int?> ps, int i) {
    final int v = _p(ps, i, 1);
    return v <= 0 ? 1 : v;
  }

  void _dispatchCsi(int f, String raw, int priv) {
    final List<int?> ps = _parseParams(raw);
    switch (f) {
      // ---- 光标移动
      case 0x41: // A CUU
        _setCursor(
            _cursorX, (_cursorY - _count(ps, 0)).clamp(_upBound(), _rows - 1));
        return;
      case 0x42: // B CUD
        _setCursor(_cursorX, (_cursorY + _count(ps, 0)).clamp(0, _downBound()));
        return;
      case 0x43: // C CUF
        final int nx = _cursorX + _count(ps, 0);
        _setCursor(nx > _cols - 1 ? _cols - 1 : nx, _cursorY);
        return;
      case 0x44: // D CUB
        final int nx = _cursorX - _count(ps, 0);
        _setCursor(nx < 0 ? 0 : nx, _cursorY);
        return;
      case 0x45: // E CNL
        _setCursor(0, (_cursorY + _count(ps, 0)).clamp(0, _downBound()));
        return;
      case 0x46: // F CPL
        _setCursor(0, (_cursorY - _count(ps, 0)).clamp(_upBound(), _rows - 1));
        return;
      case 0x47: // G CHA
        final int c = _p(ps, 0, 1);
        _setCursor((c <= 0 ? 1 : c) - 1, _cursorY);
        return;
      case 0x48: // H CUP
      case 0x66: // f HVP
        _cursorTo(_p(ps, 0, 1) - 1, _p(ps, 1, 1) - 1);
        return;
      case 0x64: // d VPA
        _cursorTo(_p(ps, 0, 1) - 1, _cursorX);
        return;
      case 0x65: // e VPR
        _setCursor(_cursorX, (_cursorY + _count(ps, 0)).clamp(0, _downBound()));
        return;
      case 0x61: // a HPR
        final int nx = _cursorX + _count(ps, 0);
        _setCursor(nx > _cols - 1 ? _cols - 1 : nx, _cursorY);
        return;
      case 0x60: // 反引号 HPA
        final int c = _p(ps, 0, 1);
        _setCursor((c <= 0 ? 1 : c) - 1, _cursorY);
        return;
      case 0x49: // I CHT 向前 n 个制表位
        for (int k = _count(ps, 0); k > 0; k--) {
          _tabForward();
        }
        return;
      case 0x5A: // Z CBT 向后 n 个制表位
        for (int k = _count(ps, 0); k > 0; k--) {
          _tabBack();
        }
        return;

      // ---- 擦除 / 编辑
      case 0x4A: // J ED
        _eraseInDisplay(_p(ps, 0, 0));
        return;
      case 0x4B: // K EL
        _eraseInLine(_p(ps, 0, 0));
        return;
      case 0x58: // X ECH
        _eraseCells(_cursorY, _cursorX, (_cursorX + _count(ps, 0)).clamp(0, _cols));
        return;
      case 0x50: // P DCH
        _deleteChars(_count(ps, 0));
        return;
      case 0x40: // @ ICH
        _insertChars(_count(ps, 0));
        return;
      case 0x4C: // L IL
        _insertLines(_count(ps, 0));
        return;
      case 0x4D: // M DL
        _deleteLines(_count(ps, 0));
        return;

      // ---- 滚动
      case 0x53: // S SU
        _scrollUp(_count(ps, 0));
        return;
      case 0x54: // T SD
        _scrollDown(_count(ps, 0));
        return;
      case 0x72: // r DECSTBM
        _setScrollRegion(_p(ps, 0, 1), _p(ps, 1, _rows));
        return;

      // ---- 属性
      case 0x6D: // m SGR
        _applySgr(ps);
        return;

      // ---- 模式
      case 0x68: // h SM
        _setMode(ps, priv, true);
        return;
      case 0x6C: // l RM
        _setMode(ps, priv, false);
        return;

      // ---- 保存 / 恢复光标
      case 0x73: // s SCOSC
        _saveCursor();
        return;
      case 0x75: // u SCORC
        _restoreCursor();
        return;

      // ---- 应答
      case 0x6E: // n DSR
        final int q = _p(ps, 0, 0);
        if (q == 5) {
          _respond('\x1b[0n');
        } else if (q == 6) {
          final int r = _cursorY + 1;
          final int c = _cursorX + 1;
          // 相邻字面量拼接，避免用 + 触 prefer_interpolation_to_compose_strings
          _respond('\x1b[$r;' '$c' 'R');
        }
        return;
      case 0x63: // c DA
        if (priv == 0x3E) {
          _respond('\x1b[>0;276;0c'); // DA2（xterm 风格）
        } else {
          _respond('\x1b[?1;2c'); // DA1（VT100 + AVO）
        }
        return;

      default:
        // 不认识的 CSI：安全跳过（已经回到 ground）
        return;
    }
  }

  // ---------------------------------------------------------------- 网格与写入

  static const VtCell _blankCell = VtCell(' ', VtAttr());

  List<List<VtCell>> _blankGrid(int c, int r) {
    return List<List<VtCell>>.generate(
      r,
      (_) => List<VtCell>.generate(c, (_) => _blankCell, growable: true),
      growable: true,
    );
  }

  VtCell get _eraseCell => VtCell(' ', _pen.toAttr());

  void _markDirty() {
    _dirty = true;
  }

  void _setCursor(int x, int y) {
    final int cx = x.clamp(0, _cols - 1);
    final int cy = y.clamp(0, _rows - 1);
    if (cx == _cursorX && cy == _cursorY && !_pendingWrap) return;
    _cursorX = cx;
    _cursorY = cy;
    _pendingWrap = false;
    _markDirty();
  }

  void _cursorTo(int row0, int col0) {
    final int y;
    if (_originMode) {
      y = (_scrollTop + row0).clamp(_scrollTop, _scrollBottom);
    } else {
      y = row0.clamp(0, _rows - 1);
    }
    _setCursor(col0, y);
  }

  int _upBound() =>
      (_cursorY >= _scrollTop && _cursorY <= _scrollBottom) ? _scrollTop : 0;

  int _downBound() => (_cursorY >= _scrollTop && _cursorY <= _scrollBottom)
      ? _scrollBottom
      : _rows - 1;

  void _lineFeed() {
    if (_cursorY == _scrollBottom) {
      _scrollUp(1);
    } else if (_cursorY < _rows - 1) {
      _cursorY++;
      _markDirty();
    }
    _pendingWrap = false;
  }

  void _reverseIndex() {
    if (_cursorY == _scrollTop) {
      _scrollDown(1);
    } else if (_cursorY > 0) {
      _cursorY--;
      _markDirty();
    }
    _pendingWrap = false;
  }

  void _tabForward() {
    final int nx = ((_cursorX ~/ 8) + 1) * 8;
    _setCursor(nx > _cols - 1 ? _cols - 1 : nx, _cursorY);
  }

  void _tabBack() {
    final int nx = ((_cursorX - 1) ~/ 8) * 8;
    _setCursor(nx < 0 ? 0 : nx, _cursorY);
  }

  /// 写一个码点到屏幕（含宽字符、自动换行、插入模式）
  void _putChar(int cp) {
    final int w = _charWidth(cp);
    if (w <= 0) return; // 组合记号/零宽：不支持合成，直接丢
    if (_cols < w) return; // 屏幕比一个字还窄
    if (_pendingWrap) {
      _pendingWrap = false;
      _cursorX = 0;
      _lineFeed();
    }
    if (w == 2 && _cursorX >= _cols - 1) {
      if (!_autoWrap) return; // 放不下又不开自动换行：丢弃
      _cursorX = 0;
      _lineFeed();
    }
    if (_insertMode) _insertChars(w);
    final List<VtCell> line = _grid[_cursorY];
    final VtAttr attr = _pen.toAttr();
    line[_cursorX] = VtCell(String.fromCharCode(cp), attr);
    if (w == 2) line[_cursorX + 1] = VtCell('', attr);
    _markDirty();
    final int nx = _cursorX + w;
    if (nx >= _cols) {
      _cursorX = _cols - 1;
      if (_autoWrap) _pendingWrap = true;
    } else {
      _cursorX = nx;
    }
  }

  // ---------------------------------------------------------------- 擦除 / 编辑

  void _eraseCells(int row, int from, int toExclusive) {
    if (row < 0 || row >= _rows) return;
    final List<VtCell> line = _grid[row];
    final int a = from < 0 ? 0 : from;
    final int b = toExclusive > _cols ? _cols : toExclusive;
    for (int x = a; x < b; x++) {
      line[x] = _eraseCell;
    }
    _markDirty();
  }

  void _eraseInLine(int mode) {
    switch (mode) {
      case 0:
        _eraseCells(_cursorY, _cursorX, _cols);
        return;
      case 1:
        _eraseCells(_cursorY, 0, _cursorX + 1);
        return;
      case 2:
        _eraseCells(_cursorY, 0, _cols);
        return;
      default:
        return;
    }
  }

  void _eraseInDisplay(int mode) {
    switch (mode) {
      case 0:
        _eraseCells(_cursorY, _cursorX, _cols);
        for (int y = _cursorY + 1; y < _rows; y++) {
          _eraseCells(y, 0, _cols);
        }
        return;
      case 1:
        for (int y = 0; y < _cursorY; y++) {
          _eraseCells(y, 0, _cols);
        }
        _eraseCells(_cursorY, 0, _cursorX + 1);
        return;
      case 2:
      case 3: // 3 = 清回滚缓冲；本模块没有回滚缓冲，等同清屏
        for (int y = 0; y < _rows; y++) {
          _eraseCells(y, 0, _cols);
        }
        return;
      default:
        return;
    }
  }

  void _deleteChars(int n) {
    if (_cursorX >= _cols) return;
    final List<VtCell> line = _grid[_cursorY];
    final int end = (_cursorX + n).clamp(_cursorX, _cols);
    line.removeRange(_cursorX, end);
    while (line.length < _cols) {
      line.add(_eraseCell);
    }
    _markDirty();
  }

  void _insertChars(int n) {
    if (_cursorX >= _cols) return;
    final List<VtCell> line = _grid[_cursorY];
    final int count = n.clamp(1, _cols - _cursorX);
    for (int k = 0; k < count; k++) {
      line.insert(_cursorX, _eraseCell);
    }
    if (line.length > _cols) line.removeRange(_cols, line.length);
    _markDirty();
  }

  void _insertLines(int n) {
    if (_cursorY < _scrollTop || _cursorY > _scrollBottom) return;
    final int count = n.clamp(1, _scrollBottom - _cursorY + 1);
    for (int k = 0; k < count; k++) {
      _grid.removeAt(_scrollBottom);
      _grid.insert(_cursorY, _blankLine());
    }
    _markDirty();
  }

  void _deleteLines(int n) {
    if (_cursorY < _scrollTop || _cursorY > _scrollBottom) return;
    final int count = n.clamp(1, _scrollBottom - _cursorY + 1);
    for (int k = 0; k < count; k++) {
      _grid.removeAt(_cursorY);
      _grid.insert(_scrollBottom, _blankLine());
    }
    _markDirty();
  }

  List<VtCell> _blankLine() =>
      List<VtCell>.generate(_cols, (_) => _eraseCell, growable: true);

  // ---------------------------------------------------------------- 滚动

  void _scrollUp(int n) {
    final int region = _scrollBottom - _scrollTop + 1;
    if (region <= 0) return;
    final int count = n.clamp(1, region);
    for (int k = 0; k < count; k++) {
      _grid.removeAt(_scrollTop);
      _grid.insert(_scrollBottom, _blankLine());
    }
    _markDirty();
  }

  void _scrollDown(int n) {
    final int region = _scrollBottom - _scrollTop + 1;
    if (region <= 0) return;
    final int count = n.clamp(1, region);
    for (int k = 0; k < count; k++) {
      _grid.removeAt(_scrollBottom);
      _grid.insert(_scrollTop, _blankLine());
    }
    _markDirty();
  }

  void _setScrollRegion(int top, int bottom) {
    int t = top;
    int b = bottom;
    if (t < 1) t = 1;
    if (b > _rows) b = _rows;
    if (b <= t) return; // 非法区域：忽略（保留原区域）
    _scrollTop = t - 1;
    _scrollBottom = b - 1;
    _cursorTo(0, 0); // DEC 规定设置区域后光标归位
    _markDirty();
  }

  // ---------------------------------------------------------------- 属性 / SGR

  void _applySgr(List<int?> ps) {
    if (ps.isEmpty) {
      _pen.reset();
      _markDirty();
      return;
    }
    int i = 0;
    while (i < ps.length) {
      final int v = ps[i] ?? 0;
      switch (v) {
        case 0:
          _pen.reset();
          break;
        case 1:
          _pen.bold = true;
          break;
        case 2:
          _pen.dim = true;
          break;
        case 3:
          _pen.italic = true;
          break;
        case 4:
          _pen.underline = true;
          break;
        case 7:
          _pen.inverse = true;
          break;
        case 8:
          _pen.hidden = true;
          break;
        case 9:
          _pen.strike = true;
          break;
        case 22:
          _pen.bold = false;
          _pen.dim = false;
          break;
        case 23:
          _pen.italic = false;
          break;
        case 24:
          _pen.underline = false;
          break;
        case 27:
          _pen.inverse = false;
          break;
        case 28:
          _pen.hidden = false;
          break;
        case 29:
          _pen.strike = false;
          break;
        case 38:
        case 48:
          final bool isFg = v == 38;
          final int mode = _p(ps, i + 1, -1);
          if (mode == 5) {
            final int idx = _p(ps, i + 2, -1);
            if (idx >= 0 && idx <= 255) {
              if (isFg) {
                _pen.fg = idx;
              } else {
                _pen.bg = idx;
              }
            }
            i += 3;
            continue;
          } else if (mode == 2) {
            int j = i + 2;
            // 冒号形式 38:2::r:g:b 会多出一个空的色空间参数，跳过它
            if (j < ps.length && ps[j] == null) j++;
            final int r = _p(ps, j, -1);
            final int g = _p(ps, j + 1, -1);
            final int b = _p(ps, j + 2, -1);
            if (r >= 0 &&
                r <= 255 &&
                g >= 0 &&
                g <= 255 &&
                b >= 0 &&
                b <= 255) {
              final int idx = _rgbTo256(r, g, b);
              if (isFg) {
                _pen.fg = idx;
              } else {
                _pen.bg = idx;
              }
            }
            i = j + 3;
            continue;
          }
          break;
        default:
          if (v >= 30 && v <= 37) {
            _pen.fg = v - 30;
          } else if (v >= 40 && v <= 47) {
            _pen.bg = v - 40;
          } else if (v >= 90 && v <= 97) {
            _pen.fg = v - 90 + 8;
          } else if (v >= 100 && v <= 107) {
            _pen.bg = v - 100 + 8;
          } else if (v == 39) {
            _pen.fg = -1;
          } else if (v == 49) {
            _pen.bg = -1;
          }
          break;
      }
      i++;
    }
    _markDirty();
  }

  /// 24 位 RGB 就近折算到 ANSI 256 索引（6x6x6 立方 16-231 / 灰阶 232-255）
  static int _rgbTo256(int r, int g, int b) {
    int level(int v) {
      if (v < 48) return 0;
      if (v < 115) return 1;
      return (v - 35) ~/ 40;
    }

    const List<int> steps = <int>[0, 95, 135, 175, 215, 255];
    final int ri = level(r);
    final int gi = level(g);
    final int bi = level(b);
    final int dr = r - steps[ri];
    final int dg = g - steps[gi];
    final int db = b - steps[bi];
    final int cubeDist = dr * dr + dg * dg + db * db;
    final int cubeIdx = 16 + 36 * ri + 6 * gi + bi;

    final int avg = (r + g + b) ~/ 3;
    final int grayIdx = ((avg - 3) ~/ 10).clamp(0, 23);
    final int gv = 8 + 10 * grayIdx;
    final int gd = avg - gv;
    final int grayDist = 3 * gd * gd;
    return grayDist < cubeDist ? 232 + grayIdx : cubeIdx;
  }

  // ---------------------------------------------------------------- 模式

  void _setMode(List<int?> ps, int priv, bool on) {
    for (final int? raw in ps) {
      if (raw == null) continue;
      if (priv == 0x3F) {
        _setPrivateMode(raw, on);
      } else {
        if (on) {
          _ansiModes.add(raw);
        } else {
          _ansiModes.remove(raw);
        }
        if (raw == 4) {
          _insertMode = on; // IRM
          _markDirty();
        }
      }
    }
  }

  void _setPrivateMode(int mode, bool on) {
    if (on) {
      _privateModes.add(mode);
    } else {
      _privateModes.remove(mode);
    }
    switch (mode) {
      case 1: // 应用光标键：只记状态
        _applicationCursorKeys = on;
        return;
      case 4: // 平滑滚动（xterm）：只记状态
        return;
      case 6: // DECOM 原点模式
        _originMode = on;
        _setCursor(0, on ? _scrollTop : 0);
        return;
      case 7: // DECAWM 自动换行
        _autoWrap = on;
        _markDirty();
        return;
      case 25: // DECTCEM 光标可见
        _cursorVisible = on;
        _markDirty();
        return;
      case 47: // 备用屏（不清屏、不存光标）
        _switchAlt(on, clear: false);
        return;
      case 1047: // 备用屏（进入时清屏）
        _switchAlt(on, clear: on);
        return;
      case 1048: // 只保存/恢复光标
        if (on) {
          _saveCursor();
        } else {
          _restoreCursor();
        }
        return;
      case 1049: // 备用屏 + 保存/恢复光标（vim 必用）
        if (on) {
          if (!_alt) _saveCursor();
          _switchAlt(true, clear: true);
          _setCursor(0, 0);
        } else {
          if (_alt) {
            _switchAlt(false, clear: false);
            _restoreCursor();
          }
        }
        return;
      case 2004: // 括号粘贴：只记状态
        _bracketedPaste = on;
        _markDirty();
        return;
      default:
        // 鼠标/焦点上报等：只记状态，不回写序列
        return;
    }
  }

  void _switchAlt(bool toAlt, {required bool clear}) {
    if (_alt == toAlt) {
      if (toAlt && clear) {
        _altGrid = _blankGrid(_cols, _rows);
        _markDirty();
      }
      return;
    }
    _alt = toAlt;
    if (toAlt && clear) {
      _altGrid = _blankGrid(_cols, _rows);
    }
    _scrollTop = 0;
    _scrollBottom = _rows - 1;
    _pendingWrap = false;
    _markDirty();
  }

  void _saveCursor() {
    _savedX = _cursorX;
    _savedY = _cursorY;
    _savedPen.copyFrom(_pen);
  }

  void _restoreCursor() {
    _pen.copyFrom(_savedPen);
    _setCursor(_savedX, _savedY);
  }

  void _reset() {
    _pen.reset();
    _savedPen.reset();
    _mainGrid = _blankGrid(_cols, _rows);
    _altGrid = _blankGrid(_cols, _rows);
    _alt = false;
    _scrollTop = 0;
    _scrollBottom = _rows - 1;
    _cursorX = 0;
    _cursorY = 0;
    _pendingWrap = false;
    _autoWrap = true;
    _originMode = false;
    _insertMode = false;
    _bracketedPaste = false;
    _applicationCursorKeys = false;
    _cursorVisible = true;
    _privateModes.clear();
    _ansiModes.clear();
    _pendingBytes = <int>[];
    _state = _sGround;
    _markDirty();
  }

  void _respond(String s) {
    for (final int cu in s.codeUnits) {
      _responses.add(cu);
    }
  }

  // ---------------------------------------------------------------- 字符宽度

  static int _cellWidth(VtCell c) =>
      c.text.isEmpty ? 0 : _charWidth(c.text.runes.first);

  /// 码点占几格：2 = 宽（CJK/emoji），1 = 普通，0 = 零宽/组合记号
  static int _charWidth(int cp) {
    if (cp < 0x20 || (cp >= 0x7F && cp < 0xA0)) return 0;
    if (_isZeroWidth(cp)) return 0;
    if (_isWide(cp)) return 2;
    return 1;
  }

  /// 零宽 / 组合记号（精简表，够覆盖常见输入）
  static bool _isZeroWidth(int cp) {
    for (final List<int> r in _zeroWidthRanges) {
      if (cp >= r[0] && cp <= r[1]) return true;
    }
    return false;
  }

  /// 宽字符（East Asian Wide / Fullwidth + emoji）
  static bool _isWide(int cp) {
    for (final List<int> r in _wideRanges) {
      if (cp >= r[0] && cp <= r[1]) return true;
    }
    return false;
  }

  static const List<List<int>> _zeroWidthRanges = <List<int>>[
    <int>[0x00AD, 0x00AD],
    <int>[0x0300, 0x036F],
    <int>[0x0483, 0x0489],
    <int>[0x0591, 0x05BD],
    <int>[0x05BF, 0x05BF],
    <int>[0x05C1, 0x05C2],
    <int>[0x0610, 0x061A],
    <int>[0x064B, 0x065F],
    <int>[0x0670, 0x0670],
    <int>[0x06D6, 0x06DC],
    <int>[0x0711, 0x0711],
    <int>[0x0730, 0x074A],
    <int>[0x07A6, 0x07B0],
    <int>[0x0900, 0x0902],
    <int>[0x093C, 0x093C],
    <int>[0x0941, 0x0948],
    <int>[0x094D, 0x094D],
    <int>[0x0E31, 0x0E31],
    <int>[0x0E34, 0x0E3A],
    <int>[0x0E47, 0x0E4E],
    <int>[0x1AB0, 0x1AFF],
    <int>[0x1DC0, 0x1DFF],
    <int>[0x200B, 0x200F],
    <int>[0x202A, 0x202E],
    <int>[0x2060, 0x2064],
    <int>[0x20D0, 0x20F0],
    <int>[0xFE00, 0xFE0F],
    <int>[0xFE20, 0xFE2F],
    <int>[0xFEFF, 0xFEFF],
  ];

  static const List<List<int>> _wideRanges = <List<int>>[
    <int>[0x1100, 0x115F], // 谚文字母
    <int>[0x2E80, 0x303E], // 部首扩展 / 康熙部首 / CJK 符号 / 表意空格
    <int>[0x3041, 0x33FF], // 假名 到 CJK 兼容
    <int>[0x3400, 0x4DBF], // CJK 扩展 A
    <int>[0x4E00, 0x9FFF], // CJK 基本区
    <int>[0xA000, 0xA4CF], // 彝文
    <int>[0xA960, 0xA97F], // 谚文字母扩展 A
    <int>[0xAC00, 0xD7A3], // 谚文音节
    <int>[0xF900, 0xFAFF], // CJK 兼容表意
    <int>[0xFE10, 0xFE19], // 竖排标点
    <int>[0xFE30, 0xFE6F], // CJK 兼容形式 / 小写变体
    <int>[0xFF00, 0xFF60], // 全角形式
    <int>[0xFFE0, 0xFFE6], // 全角符号
    <int>[0x1B000, 0x1B001], // 假名补充
    <int>[0x1F004, 0x1F004],
    <int>[0x1F0CF, 0x1F0CF],
    <int>[0x1F18E, 0x1F18E],
    <int>[0x1F191, 0x1F19A],
    <int>[0x1F200, 0x1F202],
    <int>[0x1F210, 0x1F23B],
    <int>[0x1F240, 0x1F248],
    <int>[0x1F250, 0x1F251],
    <int>[0x1F300, 0x1F64F], // 绘文字
    <int>[0x1F680, 0x1F6FF], // 交通符号
    <int>[0x1F900, 0x1F9FF], // 补充符号
    <int>[0x1FA70, 0x1FAFF],
    <int>[0x20000, 0x2FFFD], // CJK 扩展 B 及以上
    <int>[0x30000, 0x3FFFD],
  ];
}

/// 当前 SGR「画笔」（可变，方便逐个参数调整）
class _Pen {
  int fg = -1;
  int bg = -1;
  bool bold = false;
  bool dim = false;
  bool italic = false;
  bool underline = false;
  bool inverse = false;
  bool hidden = false;
  bool strike = false;

  void reset() {
    fg = -1;
    bg = -1;
    bold = false;
    dim = false;
    italic = false;
    underline = false;
    inverse = false;
    hidden = false;
    strike = false;
  }

  void copyFrom(_Pen o) {
    fg = o.fg;
    bg = o.bg;
    bold = o.bold;
    dim = o.dim;
    italic = o.italic;
    underline = o.underline;
    inverse = o.inverse;
    hidden = o.hidden;
    strike = o.strike;
  }

  VtAttr toAttr() => VtAttr(
        foreground: fg,
        background: bg,
        bold: bold,
        dim: dim,
        italic: italic,
        underline: underline,
        inverse: inverse,
        hidden: hidden,
        strike: strike,
      );
}
