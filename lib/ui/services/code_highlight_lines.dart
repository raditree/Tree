library;

import 'package:flutter/material.dart';

import 'code_highlight.dart';

/// 把源码的着色结果摊成**按字符区间排序的颜色段**，供"一行一行渲染但仍要按整段着色"的
/// 场景切片用（详情页的 diff：每一行要单独上底色与行首标记，但着色必须来自整段词法结果）。
///
/// 为什么不逐行着色（用户 2026-10-04：「为什么没按源码渲染」）：块注释与多行字符串是
/// **跨行**的——逐行着色时 `/* ...` 之后的几行会被当成普通代码，字符串也会在中途断色。
/// 这里先对整段调一次 [tokenize]，再把结果摊成区间，切片时按区间取色，块注释/多行字符串
/// 因此能一直保持正确的颜色。

/// 一段同色的字符区间（[color] 为 null = 普通文本，跟随基础样式）。
class CodeColorRun {
  const CodeColorRun({required this.start, required this.end, this.color});

  final int start;
  final int end;
  final Color? color;

  bool get isEmpty => end <= start;
}

/// 整段源码 → 颜色段（升序、互不重叠、连续覆盖 `[0, text.length)`）。
///
/// 超过 [kHighlightMaxChars] 时**完全不着色**（只回一个 null 色的整段区间）：与源码视图
/// 同一条口径——宁可单色，也不让详情页在大文件上卡住。
List<CodeColorRun> codeColorRuns({
  required String text,
  required CodeLanguage language,
  required CodeTheme theme,
}) {
  if (text.isEmpty) return const <CodeColorRun>[];
  if (text.length > kHighlightMaxChars) {
    return <CodeColorRun>[CodeColorRun(start: 0, end: text.length)];
  }
  final List<CodeToken> tokens = tokenize(text, language);
  final List<CodeColorRun> runs = <CodeColorRun>[];
  int cursor = 0;
  for (final CodeToken token in tokens) {
    if (token.start > cursor) {
      runs.add(CodeColorRun(start: cursor, end: token.start));
    }
    runs.add(CodeColorRun(
      start: token.start,
      end: token.end,
      color: theme.colorOf(token.kind),
    ));
    cursor = token.end;
  }
  if (cursor < text.length) {
    runs.add(CodeColorRun(start: cursor, end: text.length));
  }
  return runs;
}

/// 取 [text] 的 `[start, end)` 这一段，按 [runs] 上色（落在区间外的颜色段自动裁掉）。
TextSpan codeSpanForRange({
  required String text,
  required List<CodeColorRun> runs,
  required int start,
  required int end,
  TextStyle? baseStyle,
}) {
  if (start < 0) start = 0;
  if (end > text.length) end = text.length;
  if (end <= start) return TextSpan(text: '', style: baseStyle);
  final List<TextSpan> spans = <TextSpan>[];
  int cursor = start;
  for (final CodeColorRun run in runs) {
    if (run.end <= start) continue;
    if (run.start >= end) break;
    final int s = run.start < start ? start : run.start;
    final int e = run.end > end ? end : run.end;
    if (e <= s) continue;
    if (s > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, s)));
    }
    spans.add(TextSpan(
      text: text.substring(s, e),
      style: run.color == null ? null : TextStyle(color: run.color),
    ));
    cursor = e;
  }
  if (cursor < end) {
    spans.add(TextSpan(text: text.substring(cursor, end)));
  }
  return TextSpan(style: baseStyle, children: spans);
}
