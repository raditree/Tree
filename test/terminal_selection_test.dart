import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/services/terminal_selection.dart';
import 'package:tree/ui/services/vt_screen.dart';

/// 终端选区的**纯逻辑**（用户 2026-10-03：「没法选中文字，没法复制粘贴」）。
///
/// 坐标是绝对行号：回滚缓冲 + 当前屏拼成一条线（见 [TerminalSelection] 的文件头）。
void main() {
  /// 造一行：`'ab  '` → 每字符一格，行尾补空格到 [columns]。
  List<VtCell> row(String text, {int columns = 6}) {
    final List<VtCell> line = <VtCell>[];
    for (int i = 0; i < columns; i++) {
      line.add(VtCell(i < text.length ? text[i] : ' ', const VtAttr()));
    }
    return line;
  }

  /// 造一行宽字符（中文占两格：左半格有字、右半格空）。
  List<VtCell> wideRow(String text, {int columns = 8}) {
    final List<VtCell> line = <VtCell>[];
    for (final String ch in text.split('')) {
      line.add(VtCell(ch, const VtAttr()));
      line.add(VtCell('', const VtAttr()));
    }
    while (line.length < columns) {
      line.add(VtCell(' ', const VtAttr()));
    }
    return line;
  }

  TerminalSelection sel(int ar, int ac, int fr, int fc) => TerminalSelection(
        anchorRow: ar,
        anchorColumn: ac,
        focusRow: fr,
        focusColumn: fc,
      );

  test('规范化：反向拖拽（从下往上）与正向拖拽取出同一段', () {
    expect(sel(3, 4, 1, 2).startCell, (1, 2));
    expect(sel(3, 4, 1, 2).endCell, (3, 4));
    expect(sel(1, 2, 3, 4).startCell, (1, 2));
    expect(sel(2, 4, 2, 1).startCell, (2, 1));
    expect(sel(2, 4, 2, 1).endCell, (2, 4));
    expect(sel(2, 2, 2, 2).isCollapsed, isTrue);
    expect(sel(2, 2, 2, 3).isCollapsed, isFalse);
    expect(sel(2, 2, 3, 0).isMultiRow, isTrue);
  });

  test('单行单选：只取那几格，行尾空格被裁掉', () {
    final List<List<VtCell>> screen = <List<VtCell>>[row('ab'), row('cd')];
    expect(
      terminalSelectionText(
        history: const <List<VtCell>>[],
        screen: screen,
        selection: sel(0, 0, 0, 1),
      ),
      'ab',
    );
    expect(
      terminalSelectionText(
        history: const <List<VtCell>>[],
        screen: screen,
        selection: sel(1, 1, 1, 3),
      ),
      'd',
      reason: '第 2 行只选了 1..3 列：d + 一个空格 ⇒ 裁掉行尾空格',
    );
  });

  test('多行：首行从起点列起、中间整行、末行到终点列（含）', () {
    final List<List<VtCell>> screen = <List<VtCell>>[
      row('ab'),
      row('cd'),
      row('ef'),
    ];
    expect(
      terminalSelectionText(
        history: const <List<VtCell>>[],
        screen: screen,
        selection: sel(0, 1, 2, 0),
      ),
      'b\ncd\ne',
    );
  });

  test('跨历史与当前屏：行号接在一条线上', () {
    final List<List<VtCell>> history = <List<VtCell>>[row('old.')];
    final List<List<VtCell>> screen = <List<VtCell>>[row('new!')];
    expect(
      terminalSelectionText(
        history: history,
        screen: screen,
        selection: sel(0, 0, 1, 3),
      ),
      'old.\nnew!',
    );
  });

  test('宽字符：两个半格合成一个字，不重复', () {
    final List<List<VtCell>> screen = <List<VtCell>>[wideRow('你好')];
    expect(
      terminalSelectionText(
        history: const <List<VtCell>>[],
        screen: screen,
        selection: sel(0, 0, 0, 3),
      ),
      '你好',
      reason: '每字两格：0..3 覆盖"你好"两个字 + 右半格',
    );
  });

  test('越界 / 空表：夹住、不抛，空选区取出空串', () {
    expect(
      terminalSelectionText(
        history: const <List<VtCell>>[],
        screen: const <List<VtCell>>[],
        selection: sel(0, 0, 5, 5),
      ),
      '',
    );
    final List<List<VtCell>> screen = <List<VtCell>>[row('abc')];
    expect(
      terminalSelectionText(
        history: const <List<VtCell>>[],
        screen: screen,
        selection: sel(0, 0, 9, 99),
      ),
      'abc',
      reason: '终点越界要夹到最后一行最后一格，而不是抛下标',
    );
    expect(
      terminalSelectionText(
        history: const <List<VtCell>>[],
        screen: screen,
        selection: sel(4, 4, 9, 9),
      ),
      '',
      reason: '整段都在表外 ⇒ 空串',
    );
  });

  test('columnsIn：首行/中间行/末行的列区间', () {
    final TerminalSelection selection = sel(1, 2, 3, 1);
    expect(selection.columnsIn(0, 6), (-1, -1), reason: '不在选区里的行');
    expect(selection.columnsIn(1, 6), (2, 6), reason: '首行：从起点列到行尾');
    expect(selection.columnsIn(2, 6), (0, 6), reason: '中间行：整行');
    expect(selection.columnsIn(3, 6), (0, 2), reason: '末行：行首到终点列（含）');
    expect(selection.columnsIn(4, 6), (-1, -1));
  });
}
