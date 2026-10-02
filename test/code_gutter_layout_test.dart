import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree/ui/services/code_gutter_layout.dart';

/// 代码视图行号槽的**逐视觉行**布局（用户要求：源码模式加行号）。
///
/// 关键点是软换行：TextField 按宽度折行，一条逻辑行可能占多个视觉行，续行不许重复编号
/// —— 这块错了的表现就是「折一行之后所有数字都错位」。
void main() {
  const TextStyle style = TextStyle(fontSize: 14, height: 1.4);

  CodeGutterLayout layout(String text, {double width = 400}) =>
      CodeGutterLayout.compute(text: text, style: style, maxWidth: width);

  /// 参考行高：**不要硬编码**（Flutter 会把 14*1.4=19.6 取整成 20.0），
  /// 拿同一 style 量一行出来当基准，断言的是「行高一致 + 累加正确」这件事本身。
  final double lineHeight = layout('x').rows.first.height;

  test('无折行：一行一个号，从 1 起', () {
    final CodeGutterLayout g = layout('a\nb\nc');
    expect(g.rows.map((CodeGutterRow r) => r.number), <int>[1, 2, 3]);
    expect(g.lineCount, 3);
    expect(g.rows.first.height, closeTo(lineHeight, 0.01));
    expect(g.totalHeight, closeTo(lineHeight * 3, 0.01));
  });

  test('折行：续行不编号，逻辑行号只在首行出现', () {
    final String long = 'x' * 200;
    final CodeGutterLayout g = layout('$long\nshort', width: 100);
    expect(g.rows.length, greaterThan(2), reason: '窄宽度下那一长行必须折成多行');
    expect(g.rows.first.number, 1);
    expect(
      g.rows.take(g.rows.length - 1).skip(1).map((CodeGutterRow r) => r.number),
      everyElement(isNull),
      reason: '折出来的续行不许再编号',
    );
    expect(g.rows.last.number, 2, reason: '折行之后的下一条逻辑行仍是 2');
    expect(g.lineCount, 2);
  });

  test('宽度越窄折行越多（同一份文本）', () {
    final String text = 'y' * 120;
    expect(
      layout(text, width: 60).rows.length,
      greaterThan(layout(text, width: 400).rows.length),
    );
  });

  test('尾随换行：末尾的空行是新的逻辑行（编辑器口径，第 2 行）', () {
    final CodeGutterLayout g = layout('a\n');
    expect(g.rows.map((CodeGutterRow r) => r.number), <int>[1, 2]);
    expect(g.lineCount, 2);
  });

  test('空文本：仍然有一行（第 1 行）', () {
    final CodeGutterLayout g = layout('');
    expect(g.rows, hasLength(1));
    expect(g.rows.single.number, 1);
    expect(g.lineCount, 1);
    expect(g.rows.single.height, greaterThan(0), reason: '空文本也要有可画的一行高度');
    expect(g.totalHeight, greaterThan(0));
  });

  test('纵向位置单调递增，且最后一行底边 = totalHeight', () {
    final CodeGutterLayout g = layout(
      'a\nbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\nc',
      width: 80,
    );
    double previous = -1;
    for (final CodeGutterRow row in g.rows) {
      expect(row.top, greaterThan(previous));
      previous = row.top;
    }
    final CodeGutterRow last = g.rows.last;
    expect(last.top + last.height, closeTo(g.totalHeight, 0.01));
  });

  test('非法宽度不抛（宽度为 0 时退化，不崩）', () {
    final CodeGutterLayout g = layout('a\nb', width: 0);
    expect(g.rows, isNotEmpty);
    expect(g.lineCount, greaterThanOrEqualTo(1));
  });
}
