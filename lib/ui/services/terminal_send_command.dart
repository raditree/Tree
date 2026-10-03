/// 终端里的 `#TSend` 约定：**在集成终端里直接给当前会话发消息**。
///
/// 用法（用户 2026-10-04 要求）：
/// - `#TSend "一段话"` —— 把引号里的话当成用户消息发给当前 agent 的当前会话；
/// - `#TSend 一段没有引号的话` —— 同上（没有引号时整行都是正文）；
/// - `#TSend @<文件路径>` —— 把该文件作为**附件**发出去（与在 composer 里拖一个文件等价）；
/// - 也能混着用：`#TSend "看这个" @C:\x\a.md`；路径带空格写 `@"C:\a b.md"`。
///
/// **为什么在按键这一层拦，而不是让 shell 先跑一遍**：`#TSend` 不是 shell 命令，
/// 真发给 shell 只会得到一句 "command not found" 并把噪声写进屏幕。所以：
/// 以 `#` 开头、且**仍是 `#TSend` 前缀**（或已经是 `#TSend ` 开头）的那一行只在
/// 本地缓存，一个字节都不发给 PTY；一旦发现不是它（例如 `#Tx`），就把缓存**原样
/// 补发**给 PTY —— 对 shell 与用户而言与"从来没拦过"完全一致。
library;

import 'dart:convert';

/// 魔法前缀（大写 S，与用户口径逐字一致）。
const String kTerminalSendPrefix = '#TSend';

/// 解析出来的一条"终端发送"指令。
class TerminalSendCommand {
  const TerminalSendCommand({required this.text, required this.filePaths});

  /// 正文（可能为空 —— 只发附件时）。
  final String text;

  /// 附件：**本机绝对路径**（与 composer 选择的文件同一口径，交给上传服务）。
  final List<String> filePaths;

  /// 正文与附件都空：`#TSend` 后面什么都没写。
  bool get isEmpty => text.trim().isEmpty && filePaths.isEmpty;

  @override
  String toString() =>
      'TerminalSendCommand(text: "$text", files: ${filePaths.length})';
}

/// 一整行是否是 `#TSend` 指令；不是（普通命令）返回 null。
TerminalSendCommand? parseTerminalSend(String line) {
  final String trimmed = line.trim();
  if (!trimmed.startsWith(kTerminalSendPrefix)) return null;
  final String rest = trimmed.substring(kTerminalSendPrefix.length);
  // `#TSendfoo` 不是指令：前缀后面必须是空白或行尾
  if (rest.isNotEmpty && rest[0] != ' ' && rest[0] != '\t') return null;
  return _parseArgs(rest.trim());
}

/// 参数解析：`@` 开头的算附件路径（可加引号），其余算正文（可加引号，裸词也行）。
TerminalSendCommand _parseArgs(String body) {
  final StringBuffer text = StringBuffer();
  final List<String> paths = <String>[];
  int i = 0;
  while (i < body.length) {
    final String c = body[i];
    if (c == ' ') {
      i++;
      continue;
    }
    if (c == '@') {
      i++;
      final String path = _quotedOrWord(body, i);
      i = _nextIndex(body, i);
      if (path.isNotEmpty) paths.add(path);
      continue;
    }
    final String word = _quotedOrWord(body, i);
    i = _nextIndex(body, i);
    if (word.isEmpty) continue;
    if (text.isNotEmpty && !text.toString().endsWith(' ')) text.write(' ');
    text.write(word);
  }
  return TerminalSendCommand(text: text.toString().trim(), filePaths: paths);
}

/// 从 [start] 起读一段"带引号的整段"或"到空白为止的一个词"。
String _quotedOrWord(String body, int start) {
  if (start >= body.length) return '';
  if (body[start] == '"') {
    final int end = body.indexOf('"', start + 1);
    return end < 0
        ? body.substring(start + 1)
        : body.substring(start + 1, end);
  }
  int end = start;
  while (end < body.length && body[end] != ' ') {
    end++;
  }
  return body.substring(start, end);
}

/// 与 [_quotedOrWord] 配套：读完这一段之后的下标。
int _nextIndex(String body, int start) {
  if (start >= body.length) return start;
  if (body[start] == '"') {
    final int end = body.indexOf('"', start + 1);
    return end < 0 ? body.length : end + 1;
  }
  int end = start;
  while (end < body.length && body[end] != ' ') {
    end++;
  }
  return end;
}

/// 按键层的拦截器：把"可能长成 `#TSend …`"的那一行**留在本地**，别喂给 shell。
///
/// 纯 Dart（不 import Flutter），因此可以逐键单测——这条约定的正确性全在"什么时候
/// 吞、什么时候补发"上，值得用测试钉住。
class TerminalSendInterceptor {
  final StringBuffer _pending = StringBuffer();

  /// 当前本地缓存、**还没**发给 PTY 的行前缀（空 = 没在拦）。
  String get pending => _pending.toString();

  bool get buffering => _pending.isNotEmpty;

  /// 吃一个可打印字符（可能是一整段粘贴文本）。
  ///
  /// 返回要发给 PTY 的 UTF-8 字节；**null = 被吞掉**（仍在 `#TSend` 前缀上，
  /// 先不给 shell 看）。
  List<int>? accept(String char) {
    if (char.isEmpty) return const <int>[];
    final String next = '${_pending.toString()}$char';
    if (_isCandidate(next)) {
      _pending.write(char);
      return null;
    }
    // 不是候选项了：把缓存连同这一个字符一起补发（对 shell 而言等于没拦过）
    _pending.clear();
    return utf8.encode(next);
  }

  /// 把缓存交还（其它按键前 / 行尾不是指令时）：返回要补发的字节并清空。
  List<int> release() {
    if (_pending.isEmpty) return const <int>[];
    final String out = _pending.toString();
    _pending.clear();
    return utf8.encode(out);
  }

  /// Enter：这一行是指令就返回它（并清空缓存）；否则返回 null
  /// （调用方自己 [release] 出缓存再发 `\r`）。
  TerminalSendCommand? commit() {
    final TerminalSendCommand? command = parseTerminalSend(_pending.toString());
    if (command == null) return null;
    _pending.clear();
    return command;
  }

  /// 退格：吃掉缓存里的最后一个字符（那个字符从没进 shell，所以什么都不用补）。
  /// 返回 true 表示这一下退格被本地消化了。
  bool backspace() {
    if (_pending.isEmpty) return false;
    final String out = _pending.toString();
    _pending.clear();
    _pending.write(out.substring(0, out.length - 1));
    return true;
  }

  void clear() => _pending.clear();

  /// 还可能是 `#TSend` 指令的一行：要么是它的前缀（`#`、`#T`…`#TSend`），
  /// 要么已经进了参数段（`#TSend ` 开头）。
  static bool _isCandidate(String text) {
    if (kTerminalSendPrefix.startsWith(text)) return true;
    return text.startsWith('$kTerminalSendPrefix ') ||
        text.startsWith('$kTerminalSendPrefix\t');
  }
}
