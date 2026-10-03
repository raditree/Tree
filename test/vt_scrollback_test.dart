import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/services/vt_screen.dart';

/// 回滚缓冲（scrollback）：Ctrl+J 终端"滚不上去"就是因为没有它（用户 2026-10-04）。
///
/// 口径（xterm 那一套）：
/// - 只有**主屏**、且滚动区顶端 = 第 0 行时，被顶出去的行才进历史；
/// - 备用屏（vim/top 的 ?1049）没有回滚缓冲；
/// - 滚动区域内部的滚动是"区域内翻页"，同样不进历史；
/// - ED3（`CSI 3 J`）与 RIS 清空历史；resize 时历史行跟着换宽度（否则渲染串行）。
void main() {
  List<int> enc(String s) => utf8.encode(s);

  String rowText(VtScreen s, int row) =>
      s.lines[row].map((VtCell c) => c.text.isEmpty ? '·' : c.text).join();

  String histText(VtScreen s, int index) =>
      s.history[index].map((VtCell c) => c.text.isEmpty ? '·' : c.text).join();

  test('整屏滚动：顶出去的行进历史，屏幕只剩最新的', () {
    final VtScreen s = VtScreen(columns: 3, rows: 2);
    s.write(enc('a\r\nb\r\nc\r\nd'));
    // 2 行屏：写 4 行 ⇒ 前两行被顶进历史
    expect(s.historyLength, 2);
    expect(histText(s, 0), 'a  ');
    expect(histText(s, 1), 'b  ');
    expect(rowText(s, 0), 'c  ');
    expect(rowText(s, 1), 'd  ');
    expect(s.historyPushed, 2);
  });

  test('备用屏滚动不进历史（vim 里翻页不该污染回滚）', () {
    final VtScreen s = VtScreen(columns: 3, rows: 2);
    s.write(enc('\x1b[?1049h')); // 进备用屏
    s.write(enc('1\r\n2\r\n3\r\n4'));
    expect(s.historyLength, 0);
    s.write(enc('\x1b[?1049l')); // 回主屏
    expect(s.historyLength, 0);
  });

  test('滚动区域内部的滚动不进历史（区域顶不在第 0 行的滚动）', () {
    final VtScreen s = VtScreen(columns: 3, rows: 4);
    // 滚动区 = 第 2..3 行（1-based 2;4 ⇒ 0-based 1..3），光标放到区域底再换行
    s.write(enc('\x1b[2;4r\x1b[2;1Hx\r\ny\r\nz'));
    expect(s.historyLength, 0, reason: '区域内部翻页：顶出去的行属于"这屏"，不是历史');
  });

  test('上限：超过 historyLimit 丢最老的（historyPushed 只增不减）', () {
    final VtScreen s = VtScreen(columns: 2, rows: 1, historyLimit: 3);
    s.write(enc('1\r\n2\r\n3\r\n4\r\n5'));
    expect(s.historyLength, 3);
    expect(histText(s, 0), '2 ');
    expect(histText(s, 2), '4 ');
    expect(s.historyPushed, 4, reason: '推入过 4 行，只保留最后 3 行');
  });

  test('ED3（CSI 3 J）清空历史；ED2 只清屏不动历史', () {
    final VtScreen s = VtScreen(columns: 3, rows: 1);
    s.write(enc('a\r\nb\r\nc'));
    expect(s.historyLength, 2);
    s.write(enc('\x1b[2J'));
    expect(s.historyLength, 2, reason: 'ED2 = 清屏，不碰回滚缓冲');
    s.write(enc('\x1b[3J'));
    expect(s.historyLength, 0, reason: 'ED3 = 连回滚缓冲一起清');
  });

  test('resize：历史行跟着换成新宽度（渲染按当前列数画格子）', () {
    final VtScreen s = VtScreen(columns: 4, rows: 1);
    s.write(enc('abcd\r\nefgh'));
    expect(s.historyLength, 1);
    s.resize(6, 1);
    expect(s.history.first.length, 6, reason: '历史行的宽度必须与当前列数一致');
    expect(histText(s, 0), 'abcd  ');
  });

  test('RIS（ESC c）连历史一起复位', () {
    final VtScreen s = VtScreen(columns: 3, rows: 1);
    s.write(enc('a\r\nb'));
    expect(s.historyLength, 1);
    s.write(enc('\x1bc'));
    expect(s.historyLength, 0);
  });
}
