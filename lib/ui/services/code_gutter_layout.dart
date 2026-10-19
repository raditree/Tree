// LineMetrics / TextDirection / TextPainter 都由 painting 提供（不要再单独 import dart:ui，
// 会被 lint 判成多余导入）。
import 'package:flutter/painting.dart';

/// 代码视图左侧**行号槽**的布局（纯函数，可单测）。
///
/// 为什么不是简单的「按换行符切出多少行就排多少个数字」：源模式的文本域是**软换行**的
/// （TextField 的 maxLines 为空时按可用宽度折行），一条逻辑行因此可能占**多个视觉行**。
/// 行号槽必须与文本域用同一套度量（同一 TextStyle、同一 textScaler、同一可用宽度）排出来，
/// 否则只要有一行折行，后面的数字就整体错位。
///
/// 输出是**逐视觉行**的清单：
/// - [CodeGutterRow.number] 非空 = 这是某个逻辑行的首行，画这个行号；
/// - 空 = 该逻辑行的续行，行号槽留空（与 VS Code 等编辑器同口径）；
/// - [CodeGutterRow.top] 与 [CodeGutterRow.height] 是该视觉行在文本块里的位置与高度，
///   按它累加即可与文本域对齐。
class CodeGutterRow {
  const CodeGutterRow({
    required this.number,
    required this.height,
    required this.top,
  });

  /// 行号（从 1 起）；null = 续行，不画数字。
  final int? number;

  /// 该视觉行的高度（像素，与文本域同一度量）。
  final double height;

  /// 该视觉行顶边相对文本块顶边的偏移（像素）。
  final double top;
}

/// 行号槽布局结果。
class CodeGutterLayout {
  const CodeGutterLayout({
    required this.rows,
    required this.totalHeight,
    required this.lineCount,
  });

  final List<CodeGutterRow> rows;

  /// 文本块总高度（与文本域内容同口径，用于同步滚动）。
  final double totalHeight;

  /// 逻辑行数（= 画出来的最后一个行号）。
  final int lineCount;

  bool get isEmpty => rows.isEmpty;

  /// 按 [text] / [style] / [maxWidth] 量出逐视觉行的行号布局（**一次量完整篇**）。
  ///
  /// 这是给测试与"就是要全篇"的调用方用的入口；查看器的行号槽走的是
  /// [CodeGutterMeasurer]（**按需增量**测量），长文件打开时才不会卡（见那里的说明）。
  ///
  /// [maxWidth] 必须传**文本域实际可用**的宽度（已去掉左右 contentPadding、行号槽宽度、
  /// 滚动条），否则折行位置与文本域不一致，数字会跟着错位。
  static CodeGutterLayout compute({
    required String text,
    required TextStyle style,
    required double maxWidth,
    TextScaler textScaler = TextScaler.noScaling,
  }) {
    final CodeGutterMeasurer measurer = CodeGutterMeasurer(
      text: text,
      style: style,
      maxWidth: maxWidth,
      textScaler: textScaler,
    )..measureAll();
    return CodeGutterLayout(
      rows: measurer.rows,
      totalHeight: measurer.height,
      lineCount: measurer.lineCount,
    );
  }
}

/// 逐逻辑行**增量**测量器：只在被要求时才往下量，供虚拟化行号槽使用。
///
/// 为什么要有它（用户 2026-10-19：「2000 行的文件加载就要卡几秒」）：一次性把**全篇**
/// 逻辑行各 layout 一遍（[CodeGutterLayout.compute]）是 O(行数) 次
/// `TextPainter.layout` + `computeLineMetrics`，2000 行就是 2000 次同步布局，全压在同一
/// 帧里跑完就是那次卡顿；而且可编辑时**每敲一个键**（文本变了）都会再来一遍——打字越发涩。
///
/// 改成"量到看得见的那一段为止"（[measureUntilHeight]）之后：打开文件只付第一屏的代价，
/// 往下滚才继续量；敲键时只重量看得见的那些行。已量出的行累加在 [rows] 里，同一份文本
/// + 同一套度量只量一次。
///
/// 逐**逻辑行**测量，而不是量整段再猜哪个视觉行属于哪条逻辑行：整段量之后能拿到的
/// 只有 LineMetrics.hardBreak，而它在本项目实测里**并不区分**软换行与换行符（依赖它
/// 会把续行也编上号）。逐行量还顺带把位置（[CodeGutterRow.top]）变成一次简单累加。
///
/// 逐行量与整段量在折行位置上是等价的：折行只取决于该行自身内容与可用宽度，
/// 与段落里别的行无关。
class CodeGutterMeasurer {
  CodeGutterMeasurer({
    required this.text,
    required this.style,
    required this.maxWidth,
    this.textScaler = TextScaler.noScaling,
  })  : _lines = text.split('\n'),
        _lastHeight = (style.fontSize ?? 14) * (style.height ?? 1.2);

  final String text;
  final TextStyle style;
  final double maxWidth;
  final TextScaler textScaler;

  /// 逻辑行（按 `\n` 切；末尾换行会多切出一条空行，与编辑器口径一致）
  final List<String> _lines;

  /// 已量出的视觉行（按 [CodeGutterRow.top] 递增）
  final List<CodeGutterRow> rows = <CodeGutterRow>[];

  /// 已量到第几条逻辑行（0 基的下一条下标）
  int _measuredLines = 0;

  /// 已量出的累计高度（= 下一条视觉行的 top）
  double _height = 0;

  /// 上一次的行高（空行 / 度量给 0 时借用）
  double _lastHeight;

  /// 逻辑行数（= 画出来的最后一个行号）
  int get lineCount => _lines.length;

  /// 全篇是否量完
  bool get complete => _measuredLines >= _lines.length;

  /// 已量出的累计高度（像素）
  double get height => _height;

  /// 继续量，直到累计高度 ≥ [targetHeight] 或全篇量完。
  ///
  /// 高度对逻辑行下标单调递增，所以"量到 [targetHeight]"就等于"量到盖住目标位置的那一
  /// 条逻辑行"，不必先知道每条逻辑行的位置（那正是循环依赖）。
  void measureUntilHeight(double targetHeight) {
    final double target =
        targetHeight.isFinite ? targetHeight : double.infinity;
    while (!complete && _height < target) {
      _measureNextLine();
    }
  }

  /// 量完整篇（不虚拟化时用）。
  void measureAll() {
    while (!complete) {
      _measureNextLine();
    }
  }

  /// 量下一条逻辑行，把它折出来的每个视觉行追加进 [rows]，并累加高度。
  void _measureNextLine() {
    final String line = _lines[_measuredLines];
    final TextPainter painter = TextPainter(
      text: TextSpan(text: line, style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout(maxWidth: maxWidth <= 0 ? 0 : maxWidth);
    final List<LineMetrics> metrics = painter.computeLineMetrics();
    if (metrics.isEmpty) {
      // 空行（含空文本）：computeLineMetrics 给的是**空清单**，按段落高补一行。
      final double height = painter.height > 0 ? painter.height : _lastHeight;
      _lastHeight = height;
      rows.add(
        CodeGutterRow(number: _measuredLines + 1, height: height, top: _height),
      );
      _height += height;
    } else {
      for (int j = 0; j < metrics.length; j++) {
        final double height =
            metrics[j].height > 0 ? metrics[j].height : _lastHeight;
        _lastHeight = height;
        rows.add(
          CodeGutterRow(
            number: j == 0 ? _measuredLines + 1 : null,
            height: height,
            top: _height,
          ),
        );
        _height += height;
      }
    }
    painter.dispose();
    _measuredLines++;
  }
}
