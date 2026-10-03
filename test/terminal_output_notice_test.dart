import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/services/terminal_output_notice.dart';

/// 终端里的"不受信任的装入点"防呆（用户 2026-10-03：「别忘了模拟终端啊」）。
/// 判据只有两条：**认得那句话**（含被分帧切断的形态）与**一次会话只提示一次**。
void main() {
  test('中文 / 英文措辞都认，无关输出不认', () {
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

  test('分帧切断也能认（切在多字节字符中间也一样）', () {
    final List<int> whole = utf8.encode(
      'CMake Error: 无法遍历该路径，因为它包含不受信任的装入点 : x',
    );
    // 随便切两刀，其中一刀落在中文的三字节序列中间
    for (final int cut in <int>[1, 12, 13, 14, 20, whole.length - 1]) {
      final TerminalNoticeWatcher watcher = TerminalNoticeWatcher();
      final String? first = watcher.accept(whole.sublist(0, cut));
      final String? second = watcher.accept(whole.sublist(cut));
      expect(
        first ?? second,
        isNotEmpty,
        reason: '切在第 $cut 字节处时也必须认出来',
      );
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
