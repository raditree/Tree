import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/services/code_highlight.dart';
import 'package:tree/ui/services/code_highlight_lines.dart';

/// 详情页 diff / 内容块的**按整段着色再切片**（用户 2026-10-04：「为什么没按源码渲染」）。
///
/// 这里钉的是那条容易做错的口径：着色必须来自**整段**词法结果，块注释与多行字符串是跨行的
/// ——逐行着色会在第二行起掉色。
void main() {
  const CodeLanguage dart = CodeLanguage(id: 'dart', label: 'Dart');
  const CodeTheme theme = CodeTheme.dark;

  test('颜色段覆盖整段、升序不重叠，关键字 / 数字有颜色', () {
    const String text = 'final x = 1;';
    final List<CodeColorRun> runs = codeColorRuns(
      text: text,
      language: languageForPath('a.dart'),
      theme: theme,
    );
    expect(runs, isNotEmpty);
    expect(runs.first.start, 0);
    expect(runs.last.end, text.length);
    for (int i = 1; i < runs.length; i++) {
      expect(runs[i].start, runs[i - 1].end, reason: '连续覆盖，不留缝');
    }
    expect(
      runs.any((CodeColorRun r) => r.color == theme.keyword),
      isTrue,
      reason: 'final 是关键字，要有颜色',
    );
    expect(
      runs.any((CodeColorRun r) => r.color == theme.number),
      isTrue,
      reason: '1 是数字',
    );
  });

  test('块注释跨行：第二行仍是注释色（逐行着色就会掉色）', () {
    const String text = '/* 说明\n   还在注释里 */\nint x = 1;';
    final List<CodeColorRun> runs = codeColorRuns(
      text: text,
      language: languageForPath('a.dart'),
      theme: theme,
    );
    // 第二行（'   还在注释里 */'）整行都该是注释色
    final int secondStart = text.indexOf('\n') + 1;
    final int secondEnd = text.indexOf('\n', secondStart);
    final CodeColorRun covering = runs.firstWhere(
      (CodeColorRun r) => r.start <= secondStart && r.end >= secondEnd,
    );
    expect(covering.color, theme.comment, reason: '跨行块注释的续行也是注释');
  });

  test('多行字符串跨行：续行仍是字符串色', () {
    const String text = 'var s = """第一行\n第二行""";';
    final List<CodeColorRun> runs = codeColorRuns(
      text: text,
      language: languageForPath('a.dart'),
      theme: theme,
    );
    final int secondLineStart = text.indexOf('\n') + 1;
    final CodeColorRun covering = runs.firstWhere(
      (CodeColorRun r) =>
          r.start <= secondLineStart &&
          r.end >= secondLineStart + '第二行'.length,
    );
    expect(covering.color, theme.string, reason: '多行字符串的续行也是字符串色');
  });

  test('按区间切片：文本与颜色都对得上（行中间的区间也准）', () {
    const String text = 'aaa\nfinal x = 1;\nbbb';
    final List<CodeColorRun> runs = codeColorRuns(
      text: text,
      language: languageForPath('a.dart'),
      theme: theme,
    );
    final int start = text.indexOf('final');
    final TextSpan span = codeSpanForRange(
      text: text,
      runs: runs,
      start: start,
      end: start + 'final x = 1;'.length,
      baseStyle: const TextStyle(fontSize: 11),
    );
    expect(span.toPlainText(), 'final x = 1;');
    final List<Color?> colors = <Color?>[];
    span.visitChildren((InlineSpan child) {
      colors.add(child.style?.color);
      return true;
    });
    expect(colors.contains(theme.keyword), isTrue);
    expect(
      span.style?.fontSize,
      11,
      reason: '基础样式照旧（等宽 / 行高）',
    );
  });

  test('超过 128 KB：完全不着色（只回一段普通文本，不让详情页卡住）', () {
    final String huge = 'x' * (kHighlightMaxChars + 10);
    final List<CodeColorRun> runs = codeColorRuns(
      text: huge,
      language: languageForPath('a.dart'),
      theme: theme,
    );
    expect(runs, hasLength(1));
    expect(runs.single.color, isNull);
    expect(codeColorRuns(text: '', language: dart, theme: theme), isEmpty);
  });
}
