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

  /// 按 [text] / [style] / [maxWidth] 量出逐视觉行的行号布局。
  ///
  /// [maxWidth] 必须传**文本域实际可用**的宽度（已去掉左右 contentPadding、行号槽宽度、
  /// 滚动条），否则折行位置与文本域不一致，数字会跟着错位。
  static CodeGutterLayout compute({
    required String text,
    required TextStyle style,
    required double maxWidth,
    TextScaler textScaler = TextScaler.noScaling,
  }) {
    // 逐**逻辑行**测量，而不是量整段再猜哪个视觉行属于哪条逻辑行：整段量之后能拿到的
    // 只有 LineMetrics.hardBreak，而它在本项目实测里**并不区分**软换行与换行符（依赖它
    // 会把续行也编上号，正是本类要防的错位）。逐行量还顺带把位置（CodeGutterRow.top）
    // 变成一次简单累加。代价是每行一次 layout；文本量由调用方把关（源模式本来就把着色
    // 限制在 128 KB 内），这个量级下每次编辑多花的是毫秒级。
    //
    // 逐行量与整段量在折行位置上是等价的：折行只取决于该行自身内容与可用宽度，
    // 与段落里别的行无关。
    final List<String> logicalLines = text.split('\n');
    final List<CodeGutterRow> rows = <CodeGutterRow>[];
    double top = 0;
    double lastHeight = (style.fontSize ?? 14) * (style.height ?? 1.2);
    for (int i = 0; i < logicalLines.length; i++) {
      final TextPainter painter = TextPainter(
        text: TextSpan(text: logicalLines[i], style: style),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
      )..layout(maxWidth: maxWidth <= 0 ? 0 : maxWidth);
      final List<LineMetrics> metrics = painter.computeLineMetrics();
      if (metrics.isEmpty) {
        // 空行（含空文本）：computeLineMetrics 给的是**空清单**，按段落高补一行。
        final double height = painter.height > 0 ? painter.height : lastHeight;
        lastHeight = height;
        rows.add(CodeGutterRow(number: i + 1, height: height, top: top));
        top += height;
      } else {
        for (int j = 0; j < metrics.length; j++) {
          final double height = metrics[j].height > 0
              ? metrics[j].height
              : lastHeight;
          lastHeight = height;
          rows.add(
            CodeGutterRow(
              number: j == 0 ? i + 1 : null,
              height: height,
              top: top,
            ),
          );
          top += height;
        }
      }
      painter.dispose();
    }
    return CodeGutterLayout(
      rows: rows,
      totalHeight: top,
      lineCount: logicalLines.length,
    );
  }
}
