/// 终端网格上的**选区**（用户 2026-10-03：「没法选中文字，没法复制粘贴」）。
///
/// 坐标是 **(绝对行号, 列)**：屏幕缓冲与回滚缓冲拼成一条线，`0` = 最老的那一行历史，
/// 末尾 = 当前屏最后一行（面板按"可见区第一行的绝对行号"把指针像素换算过来，
/// 见 `terminal_panel.dart` 的 `_firstVisibleAbsolute`）。这样选区的语义与真终端一致：
///
/// - 输出把内容顶上去、用户又往上翻了历史，选区**仍锚在同一段文本**上（不会指到别的行）；
/// - 因此不需要"一有输出就清选区"（那段文本还在，用户正是要复制它）；
/// - 代价：`VtScreen.resize()` 会重排行 ⇒ 面板在尺寸变化时清选区（锚点会失效）。
///
/// 本文件**不 import Flutter 的 widget 层**（只依赖 [VtCell]），纯逻辑可单测。
library;

import 'package:flutter/foundation.dart';

import 'vt_screen.dart';

/// 一条选区：起点 [anchorRow]/[anchorColumn]（按下那一格）与终点 [focusRow]/[focusColumn]
/// （拖到的那一格）。方向无所谓——取文本时用 [startCell]/[endCell] 规范化。
@immutable
class TerminalSelection {
  const TerminalSelection({
    required this.anchorRow,
    required this.anchorColumn,
    required this.focusRow,
    required this.focusColumn,
  });

  /// 起点（绝对行号）。
  final int anchorRow;

  /// 起点列。
  final int anchorColumn;

  /// 终点（绝对行号）。
  final int focusRow;

  /// 终点列。
  final int focusColumn;

  /// 只有一个格子（单击 / 没拖动）：复制不出东西。
  bool get isCollapsed => anchorRow == focusRow && anchorColumn == focusColumn;

  /// 拖到别的行上了（多行选区）。
  bool get isMultiRow => anchorRow != focusRow;

  /// 起点在终点之前（同一行时按列比较）。
  bool get _anchorFirst =>
      anchorRow < focusRow ||
      (anchorRow == focusRow && anchorColumn <= focusColumn);

  /// 规范化后的起点（行, 列）。
  (int row, int column) get startCell => _anchorFirst
      ? (anchorRow, anchorColumn)
      : (focusRow, focusColumn);

  /// 规范化后的终点（行, 列）。
  (int row, int column) get endCell => _anchorFirst
      ? (focusRow, focusColumn)
      : (anchorRow, anchorColumn);

  /// 拖动中：换终点（起点不动）。
  TerminalSelection withFocus(int row, int column) => TerminalSelection(
        anchorRow: anchorRow,
        anchorColumn: anchorColumn,
        focusRow: row,
        focusColumn: column,
      );

  /// 某一行被选中的列区间 `[start, end)`（**已夹进** `[0, columns)`）。
  ///
  /// 这一行不在选区里时返回 `(-1, -1)`。首行从起点列开始、末行到终点列（含），
  /// 中间整行都算——画笔与取文本共用这一处，免得两处各算一套。
  (int start, int end) columnsIn(int row, int columns) {
    final (int startRow, int startColumn) = startCell;
    final (int endRow, int endColumn) = endCell;
    if (row < startRow || row > endRow || columns <= 0) return (-1, -1);
    final int from = row == startRow ? startColumn : 0;
    final int to = row == endRow ? endColumn + 1 : columns;
    final int clampedFrom = from.clamp(0, columns);
    final int clampedTo = to.clamp(0, columns);
    if (clampedTo <= clampedFrom) return (-1, -1);
    return (clampedFrom, clampedTo);
  }

  @override
  bool operator ==(Object other) =>
      other is TerminalSelection &&
      other.anchorRow == anchorRow &&
      other.anchorColumn == anchorColumn &&
      other.focusRow == focusRow &&
      other.focusColumn == focusColumn;

  @override
  int get hashCode =>
      Object.hash(anchorRow, anchorColumn, focusRow, focusColumn);

  @override
  String toString() => 'TerminalSelection($anchorRow:$anchorColumn → '
      '$focusRow:$focusColumn)';
}

/// 把选区抽成**要复制到剪贴板的文本**。
///
/// - [history] 是回滚缓冲、[screen] 是当前屏（`VtScreen.history` / `VtScreen.lines`），
///   两者的行号接在一起就是选区用的绝对行号；
/// - 逐行取 `[start, end)` 的格子文本（宽字符的右半格是空串，不会重复补字符）；
/// - [trimTrailingSpaces] 为真时裁掉每行**行尾空格**（网格是按整行填满的，不裁的话
///   复出来一坨空白；这是各终端的通行口径）；
/// - 多行用 `\n` 连接，**末尾不补换行**（要执行就自己敲回车；粘贴时 `\n` 会被换回 `\r`）。
String terminalSelectionText({
  required List<List<VtCell>> history,
  required List<List<VtCell>> screen,
  required TerminalSelection selection,
  bool trimTrailingSpaces = true,
}) {
  final int lastRow = history.length + screen.length - 1;
  if (lastRow < 0) return '';
  final (int startRow, _) = selection.startCell;
  final (int endRow, _) = selection.endCell;
  final int from = startRow.clamp(0, lastRow);
  final int to = endRow.clamp(0, lastRow);
  final StringBuffer out = StringBuffer();
  for (int row = from; row <= to; row++) {
    final List<VtCell> line =
        row < history.length ? history[row] : screen[row - history.length];
    final (int start, int end) = selection.columnsIn(row, line.length);
    if (start < 0) continue;
    final StringBuffer buffer = StringBuffer();
    for (int column = start; column < end && column < line.length; column++) {
      buffer.write(line[column].text);
    }
    String text = buffer.toString();
    if (trimTrailingSpaces) {
      int cut = text.length;
      while (cut > 0 && text[cut - 1] == ' ') {
        cut--;
      }
      if (cut != text.length) text = text.substring(0, cut);
    }
    if (row != from) out.write('\n');
    out.write(text);
  }
  return out.toString();
}
