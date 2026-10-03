/// 终端输出里的**可读防呆**：把操作系统那句用户没法照做的话，翻译成一句能照做的指引。
///
/// 眼下只认一个场景（用户 2026-10-03 报的"Tree 的 terminal 和我自己的 terminal 行为不一致"，
/// 根因见 `docs/known-issues.md` #16）：Windows 11 的 **Redirection Trust** 会说
/// 「**无法遍历该路径，因为它包含不受信任的装入点**」（英文 `untrusted mount point`）——
/// `flutter build` 这类依赖 `.plugin_symlinks`（reparse point）的构建，在**非管理员**上下文里
/// 就是这么失败的；而那句话对用户毫无可操作性：既没说是权限还是链接坏了，也没说下一步做什么。
///
/// 这里只做两件事：**认这句话** + **给一句指引**。判断与呈现分开：
/// - [untrustedMountNotice] 是纯函数（给定一段输出，要不要提示、提示什么）；
/// - [TerminalNoticeWatcher] 管"跨帧"与"一次会话只提示一次"——平台输出是分帧来的，
///   关键字可能被切断（甚至切在 UTF-8 多字节字符中间），所以它留的是**字节尾巴**、
///   每次把"尾巴 + 新字节"一起解码，而不是各自解一次再拼字符串。
library;

import 'dart:convert';

/// 命中的措辞（中文系统 / 英文系统各一套；再叠一句"无法遍历该路径"兜住措辞微调）。
const List<String> kUntrustedMountMarkers = <String>[
  '不受信任的装入点',
  'untrusted mount point',
  '无法遍历该路径',
];

/// 提示文案：一句能照做的指引（不写"可能 / 也许"，直接给下一步）。
const String kUntrustedMountNotice =
    '这条命令碰到「不受信任的装入点」（Windows 11 的 Redirection Trust）：'
    '依赖 reparse point 的构建在非管理员上下文里跑不通 —— '
    '先在管理员终端跑一次 flutter pub get，详见 docs/known-issues.md #16';

/// 纯函数：这段输出要不要给指引（要就给文案，不要就给 null）。
String? untrustedMountNotice(String output) {
  if (output.isEmpty) return null;
  final String lower = output.toLowerCase();
  for (final String marker in kUntrustedMountMarkers) {
    if (marker == marker.toLowerCase()) {
      if (lower.contains(marker)) return kUntrustedMountNotice;
    } else if (output.contains(marker)) {
      return kUntrustedMountNotice;
    }
  }
  return null;
}

/// 跨帧扫描器：喂**原始字节**（终端输出帧就是字节），命中过一次就不再提示。
class TerminalNoticeWatcher {
  /// 尾巴留多少字节：够覆盖一个被切断的关键字（最长的那句是 9 个 UTF-8 字节的"不受信任的装入点"
  /// 里的一小段，256 字节绰绰有余，又不至于把整屏历史都留着）。
  static const int tailBytes = 256;

  final List<int> _tail = <int>[];
  bool _untrustedShown = false;

  /// 吃一段输出，返回**本次该弹出的提示**（没有就 null）。
  String? accept(List<int> bytes) {
    if (bytes.isEmpty) return null;
    final List<int> window = <int>[..._tail, ...bytes];
    // 尾巴按**字节**裁：宁可多解一次，也不要把一个多字节字符从中间切开丢给解码器
    final int keep = window.length > tailBytes ? tailBytes : window.length;
    _tail
      ..clear()
      ..addAll(window.sublist(window.length - keep));
    if (_untrustedShown) return null;
    final String text = utf8.decode(window, allowMalformed: true);
    final String? notice = untrustedMountNotice(text);
    if (notice == null) return null;
    _untrustedShown = true;
    return notice;
  }

  /// 换会话 / 重开终端时清掉（同一个 shell 反复出现同一句，不该只提示一次）。
  void reset() {
    _tail.clear();
    _untrustedShown = false;
  }
}
