/// 终端输出里的**可读防呆**：把操作系统那句用户没法照做的话，翻译成一句能照做的指引。
///
/// 场景（用户 2026-10-03 报的"Tree 的 terminal 和我自己的 terminal 行为不一致"，机制见
/// `docs/known-issues.md` #16）＝ Windows 的 **RedirectionGuard**：带着它的进程一律拒绝跟随
/// "非管理员创建的"重定向点（reparse point），而 `flutter` 生成的 `.plugin_symlinks/*`
/// 正是这种链接。它有两种**措辞**，都要认：
///
/// 1. **系统的措辞**（.NET / 内核）：`无法遍历该路径，因为它包含不受信任的装入点`
///    （英文 `untrusted mount point`）——用户在这一层毫无可操作性；
/// 2. **CMake 的措辞**（真机上用户实际踩到的那种）：
///    `add_subdirectory given source "flutter/ephemeral/.plugin_symlinks/<插件>/windows"
///    which is not an existing directory`——CMake 看不见那些链接，只能这么报。
///    **它单看是通用措辞**（任何缺目录都这么报），所以判据是"它**与** `.plugin_symlinks`
///    同时出现"，见 [TerminalNoticeScene.allOf]。
///
/// 这里只做两件事：**认这些话** + **给一句能照做的下一步**。判断与呈现分开：
/// - [untrustedMountNotice] 是纯函数（给定一段输出，要不要提示、提示什么）；
/// - [TerminalNoticeWatcher] 管"跨帧"与"一次会话只提示一次"——平台输出是分帧来的，
///   关键字可能被切断（甚至切在 UTF-8 多字节字符中间），所以它留的是**字节尾巴**、
///   每次把"尾巴 + 新字节"一起解码，而不是各自解一次再拼字符串。
library;

import 'dart:convert';

/// 一个防呆**场景**：命中的判据是"**同时**满足 [allOf] 里的每一组"（组内命中任一关键字即可）。
class TerminalNoticeScene {
  const TerminalNoticeScene({
    required this.id,
    required this.allOf,
    required this.notice,
  });

  /// 排障 / 用例用的标识。
  final String id;

  /// 每一组都要命中（组内是"或"）。
  final List<List<String>> allOf;

  /// 命中后给用户的那句话。
  final String notice;

  /// [raw] 原文、[lower] 小写副本（调用方各算一次，省得每条都重复 lowercase）。
  bool matches({required String raw, required String lower}) {
    for (final List<String> group in allOf) {
      bool hit = false;
      for (final String marker in group) {
        final String lowered = marker.toLowerCase();
        if (lowered == marker ? lower.contains(lowered) : raw.contains(marker)) {
          hit = true;
          break;
        }
      }
      if (!hit) return false;
    }
    return true;
  }
}

/// 提示文案：一句能照做的下一步（不写"可能 / 也许"）。
///
/// **注意这句在 2026-10-03 下半场改过**：真因查清后，"先去管理员终端 `flutter pub get`"
/// 不再是最优解——**退出 Tree 从开始菜单重开**就会拿到干净上下文（新版本启动时会自愈，
/// 见 `windows/runner/main.cpp`），而系统终端里跑这条命令永远可行。
const String kUntrustedMountNotice =
    '这条命令撞上了 Windows 的 RedirectionGuard（「不受信任的装入点」）：'
    '.plugin_symlinks 这类链接是"非管理员创建的"，带着该缓解的进程一律跟随不了，'
    '而这次 Tree 是从提权进程（安装器）启动的，整棵进程树都带着它。'
    '下一步：退出 Tree、从开始菜单重开一次（新版本启动时会自愈），'
    '或先在系统终端（cmd / PowerShell）里跑这条命令；详见 docs/known-issues.md #16';

/// 系统措辞的关键字（中文系统 / 英文系统各一套；再叠一句"无法遍历该路径"兜住措辞微调）。
const List<String> kUntrustedMountMarkers = <String>[
  '不受信任的装入点',
  'untrusted mount point',
  '无法遍历该路径',
];

/// CMake 措辞的两半：**必须同时出现**才算 #16 那个场景（单看都是通用措辞）。
const List<String> kPluginSymlinkCmakeMarkers = <String>[
  'add_subdirectory given source',
];
const String kPluginSymlinkPathMarker = '.plugin_symlinks';

/// 认得的场景（加新场景就加在这里，并在用例里钉住"命中 / 不命中"两侧）。
const List<TerminalNoticeScene> kTerminalNoticeScenes = <TerminalNoticeScene>[
  TerminalNoticeScene(
    id: 'untrusted-mount-point',
    allOf: <List<String>>[kUntrustedMountMarkers],
    notice: kUntrustedMountNotice,
  ),
  TerminalNoticeScene(
    id: 'plugin-symlinks-not-traversable',
    allOf: <List<String>>[kPluginSymlinkCmakeMarkers, <String>[kPluginSymlinkPathMarker]],
    notice: kUntrustedMountNotice,
  ),
];

/// 纯函数：这段输出要不要给指引（要就给文案，不要就给 null）。
String? untrustedMountNotice(String output) {
  if (output.isEmpty) return null;
  final String lower = output.toLowerCase();
  for (final TerminalNoticeScene scene in kTerminalNoticeScenes) {
    if (scene.matches(raw: output, lower: lower)) return scene.notice;
  }
  return null;
}

/// 跨帧扫描器：喂**原始字节**（终端输出帧就是字节），命中过一次就不再提示。
class TerminalNoticeWatcher {
  /// 尾巴留多少字节：够覆盖一个被切断的关键字（最长的那句是 9 个 UTF-8 字节的"不受信任的装入点"
  /// 里的一小段，256 字节绰绰有余；CMake 那两半相隔约 60 字节，也在窗口内），又不至于把整屏历史都留着。
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
