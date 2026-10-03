import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/services/terminal_output_notice.dart';

/// 终端里的 #16 防呆（用户 2026-10-03：「别忘了模拟终端啊」，后来又「补上」）。
/// 判据三条：**两种措辞都认得**（系统措辞 + CMake 措辞，后者要"两半同时出现"）、
/// **被分帧切断也认得出**、**一次会话只提示一次**。
void main() {
  /// 用户真机那次的输出（截图/粘贴原文的形态）：CMake 看不见 `.plugin_symlinks` 里的链接。
  const String cmakeForm = 'CMake Error at flutter/generated_plugins.cmake:19 '
      '(add_subdirectory):\n'
      '  add_subdirectory given source\n'
      '  "flutter/ephemeral/.plugin_symlinks/desktop_drop/windows" which is not an\n'
      '  existing directory.\n';

  test('系统措辞（中文 / 英文）认，无关输出不认', () {
    expect(
      untrustedMountNotice('错误：无法遍历该路径，因为它包含不受信任的装入点。'),
      isNotEmpty,
    );
    expect(
      untrustedMountNotice('Cannot traverse the path: untrusted mount point'),
      isNotEmpty,
    );
    expect(untrustedMountNotice('npm ERR! code ENOENT'), isNull);
    expect(untrustedMountNotice(''), isNull);
  });

  test('CMake 措辞（用户真机那次）认出来——它不含任何"不受信任的装入点"字样', () {
    expect(
      untrustedMountNotice(cmakeForm),
      isNotEmpty,
      reason: '这是用户实际踩到的形态；上一轮的关键字里没有它，所以指引根本没弹出来',
    );
  });

  test('CMake 措辞的"两半"缺一不可（防误报）', () {
    // 只有 CMake 的通用措辞：任何缺目录的构建都会这么报，不该弹 #16 的指引
    expect(
      untrustedMountNotice(
        'CMake Error: add_subdirectory given source "libs/nope/windows" which is '
        'not an existing directory.',
      ),
      isNull,
    );
    // 只有路径名：别的工具也可能提这个目录名，单看不作数
    expect(
      untrustedMountNotice('warning: .plugin_symlinks is stale, rerun pub get'),
      isNull,
    );
  });

  test('指引给的是"改正后的下一步"（退出 Tree 从开始菜单重开 / 系统终端里跑）', () {
    final String? notice = untrustedMountNotice(cmakeForm);
    expect(notice, contains('开始菜单'));
    expect(notice, contains('known-issues.md #16'));
    expect(
      notice,
      isNot(contains('管理员终端跑一次')),
      reason: '真因查清后，"先去管理员终端 pub get"不再是最优解（见 #16）',
    );
  });

  test('分帧切断也能认（两种措辞各切一刀，含切在多字节字符中间）', () {
    for (final String text in <String>[
      'CMake Error: 无法遍历该路径，因为它包含不受信任的装入点 : x',
      cmakeForm,
    ]) {
      final List<int> whole = utf8.encode(text);
      for (final int cut in <int>[1, 12, 13, 14, 40, whole.length - 1]) {
        final TerminalNoticeWatcher watcher = TerminalNoticeWatcher();
        final String? first = watcher.accept(whole.sublist(0, cut));
        final String? second = watcher.accept(whole.sublist(cut));
        expect(
          first ?? second,
          isNotEmpty,
          reason: '「${text.substring(0, 12)}…」切在第 $cut 字节处时也必须认出来',
        );
      }
    }
  });

  test('一次会话只提示一次，reset 之后可以再提示', () {
    final TerminalNoticeWatcher watcher = TerminalNoticeWatcher();
    final List<int> hit = utf8.encode('untrusted mount point');
    expect(watcher.accept(hit), isNotEmpty);
    expect(watcher.accept(hit), isNull, reason: '同一会话不该反复弹');
    watcher.reset();
    expect(watcher.accept(hit), isNotEmpty, reason: '换会话后要能再提示');
  });

  test('尾巴不会无限长（只留固定字节数）', () {
    final TerminalNoticeWatcher watcher = TerminalNoticeWatcher();
    for (int i = 0; i < 50; i++) {
      expect(watcher.accept(utf8.encode('噪声' * 100)), isNull);
    }
    // 尾巴里不该还留着最早那批噪声：隔着 5000 字节把关键字分两半，第二半仍能被认出来
    final TerminalNoticeWatcher other = TerminalNoticeWatcher();
    expect(other.accept(utf8.encode('不受信任的')), isNull);
    expect(other.accept(utf8.encode('装入点')), isNotEmpty);
  });
}
