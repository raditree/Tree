library;

import 'dart:convert';

/// 「详情」页里 `write` / `edit` 两个工具的**变更视图**（纯函数，可单测）。
///
/// 用户 2026-10-04：「写入的具体内容呢？编辑做成 diff 的输出格式（最好带少量几行上下文
/// 方便用户阅读）」——原来的详情页只给「内容长度 15720 字符」与「查找 / 替换」两块原文，
/// 想核一眼改了什么得自己再去开文件。
///
/// 两种视图：
/// - [buildWriteContent]：write 的**内容本身**（带行数 / 截断说明）；
/// - [buildEditDiff]：edit 的**带上下文变更块**（`-` 旧行、`+` 新行、无前缀的是上下文），
///   上下文取自**磁盘上的当前内容**（改完之后的样子）：用这次调用的 `new_text` 定位，
///   上下各取 N 行。定位不到（文件后来又被改过 / 读不到）返回 null——调用方如实说明，
///   退回「查找 / 替换」参数视图，绝不给一份看起来像 diff 的假东西。

/// 变更块里一行的性质。
enum ToolDiffKind { context, removed, added }

/// 变更块里的一行。
class ToolDiffLine {
  const ToolDiffLine(
    this.kind,
    this.text, {
    this.sourceStart = -1,
    this.sourceEnd = -1,
  });

  final ToolDiffKind kind;
  final String text;

  /// 这一行在**对应源码段**里的 `[start, end)`：`removed` 用 [ToolDiffHunk.beforeText]，
  /// 其余用 [ToolDiffHunk.fileText]。界面据此切片上色（按整段词法结果，见
  /// [codeColorRuns]）——`-1` = 没有区间（调用方只按纯文本渲染）。
  final int sourceStart;
  final int sourceEnd;

  /// 行首那一个字符（上下文是空格，与 unified diff 一致）。
  String get marker => switch (kind) {
    ToolDiffKind.context => ' ',
    ToolDiffKind.removed => '-',
    ToolDiffKind.added => '+',
  };
}

/// 一次编辑的变更块（含少量上下文）。
class ToolDiffHunk {
  const ToolDiffHunk({
    required this.lines,
    required this.truncated,
    required this.startLine,
    this.fileText = '',
    this.beforeText = '',
    this.hasContext = true,
  });

  final List<ToolDiffLine> lines;

  /// 上下文行与新增行来自它（**磁盘当前内容**）。
  final String fileText;

  /// 被替换前的那一整段（`prefix + old_text + suffix`）：`-` 行来自它。
  final String beforeText;

  /// 有没有上下文行。"翻历史、只拿得到调用参数"时是 false——界面要如实标注，
  /// 不能假装这是一份完整 diff（用户 2026-10-04：「翻历史的 edit 怎么全都找不到原始变更」）。
  final bool hasContext;

  /// 行数超过上限（只显示前面这些行）——界面要如实标出来。
  final bool truncated;

  /// 变更块第一行在**当前文件**里的行号（1 基；`@@ -N,M +N,K @@` 那个 N）。
  final int startLine;

  int get removedCount =>
      lines.where((ToolDiffLine l) => l.kind == ToolDiffKind.removed).length;

  int get addedCount =>
      lines.where((ToolDiffLine l) => l.kind == ToolDiffKind.added).length;

  /// 变更块的头部（`@@ -12,4 +12,6 @@`）。
  String get header => '@@ -$startLine,$removedCount +$startLine,$addedCount @@';
}

/// write 的内容视图。
class WriteContentView {
  const WriteContentView({
    required this.text,
    required this.truncated,
    required this.totalLines,
    required this.totalChars,
  });

  /// 要显示的内容（可能被截断）。
  final String text;
  final bool truncated;
  final int totalLines;
  final int totalChars;
}

/// write 的内容（默认最多 2000 行 / 128 KB；超了如实标 [WriteContentView.truncated]）。
///
/// 为什么还要上限：详情页是给人读的，几十万字符的写入（模型偶尔干得出来）整段塞进一次
/// 布局只会把界面卡住；真正想看全文去右栏「文件」页打开那个文件。
WriteContentView buildWriteContent(
  String content, {
  int maxLines = 2000,
  int maxChars = 131072,
}) {
  final List<String> lines = _splitLines(content);
  final bool tooManyLines = lines.length > maxLines;
  final bool tooManyChars = content.length > maxChars;
  if (!tooManyLines && !tooManyChars) {
    return WriteContentView(
      text: content,
      truncated: false,
      totalLines: lines.length,
      totalChars: content.length,
    );
  }
  final String byLines = tooManyLines
      ? lines.take(maxLines).join('\n')
      : content;
  final String shown = byLines.length > maxChars
      ? byLines.substring(0, maxChars)
      : byLines;
  return WriteContentView(
    text: shown,
    truncated: true,
    totalLines: lines.length,
    totalChars: content.length,
  );
}

/// `edit` 的变更块：用 [newText] 在 [fileText]（**改完之后**的磁盘内容）里定位，
/// 再把"被替换的那几行"整行标出来（`-` 旧 / `+` 新），上下各带 [context] 行上下文。
///
/// 为什么按"整行"标而不是只贴 `old_text` / `new_text`：一次替换常常落在行中间
/// （改一个表达式），只贴两段碎片读起来不知道它在哪一行；把整行拿出来、给上下文，
/// 才是用户要的「diff 输出格式」。
///
/// [newText] 为空（纯删除）时用 [oldText] 定位。返回 null = 定位不到。
ToolDiffHunk? buildEditDiff({
  required String fileText,
  required String oldText,
  required String newText,
  int context = 3,
  int maxLines = 400,
}) {
  final String needle = newText.isNotEmpty ? newText : oldText;
  if (needle.isEmpty) return null;
  final int index = fileText.indexOf(needle);
  if (index < 0) return null;

  // 被替换区域所在**整行**的范围：行首 .. 行尾（含两端的行内片段）
  final int lineStart = fileText.lastIndexOf('\n', index) + 1;
  final int afterEnd = index + needle.length;
  int lineEnd = fileText.indexOf('\n', afterEnd);
  if (lineEnd < 0) lineEnd = fileText.length;
  final String prefix = fileText.substring(lineStart, index);
  final String suffix = fileText.substring(afterEnd, lineEnd);

  // before 版本 = 把这一段换回 oldText（其余一模一样）
  final String beforeRegion = '$prefix$oldText$suffix';
  final String afterRegion = '$prefix$newText$suffix';

  // 上下文行：变更块之前的 context 行 + 之后的 context 行（都来自当前文件）
  final List<_SourceLine> fileLines = _linesWithOffsets(fileText);
  final int startLineIndex = _lineIndexAt(fileText, lineStart);
  final int endLineIndex = _lineIndexAt(fileText, lineEnd);
  final int from = (startLineIndex - context) < 0 ? 0 : startLineIndex - context;
  final List<ToolDiffLine> out = <ToolDiffLine>[];
  for (int i = from; i < startLineIndex; i++) {
    out.add(_of(fileLines[i], ToolDiffKind.context));
  }
  // 被替换的那几行整行标出来；两段源码各自带上区间，界面因此能按整段着色切片
  final List<_SourceLine> beforeLines = _linesWithOffsets(beforeRegion);
  for (final _SourceLine line in beforeLines) {
    out.add(_of(line, ToolDiffKind.removed));
  }
  final int afterFromLine = endLineIndex + 1;
  final List<_SourceLine> afterLines = _linesWithOffsets(afterRegion);
  for (final _SourceLine line in afterLines) {
    // afterRegion == fileText.substring(lineStart, lineEnd) ⇒ 文件里的偏移 = 段内偏移 + lineStart
    out.add(
      ToolDiffLine(
        ToolDiffKind.added,
        line.text,
        sourceStart: lineStart + line.start,
        sourceEnd: lineStart + line.end,
      ),
    );
  }
  final int afterTo = afterFromLine + context > fileLines.length
      ? fileLines.length
      : afterFromLine + context;
  for (int i = afterFromLine; i < afterTo; i++) {
    out.add(_of(fileLines[i], ToolDiffKind.context));
  }

  final bool truncated = out.length > maxLines;
  return ToolDiffHunk(
    lines: truncated ? out.sublist(0, maxLines) : out,
    truncated: truncated,
    startLine: from + 1,
    fileText: fileText,
    beforeText: beforeRegion,
  );
}

/// 只有参数、没有源文件时（翻历史：文件之后又被改过）的**退化变更块**：
/// `-` 是这次替换掉的整段、`+` 是替换进去的整段，**没有上下文**（那份上下文没被存下来）。
///
/// 返回 null = 两段都空（没有可展示的改动）。界面把 [ToolDiffHunk.hasContext] 为假的情况
/// 如实标注出来——不假装这是完整的 diff。
ToolDiffHunk? buildEditDiffFromArgs({
  required String oldText,
  required String newText,
  int maxLines = 400,
}) {
  if (oldText.isEmpty && newText.isEmpty) return null;
  final List<ToolDiffLine> out = <ToolDiffLine>[];
  for (final _SourceLine line in _linesWithOffsets(oldText)) {
    out.add(_of(line, ToolDiffKind.removed));
  }
  for (final _SourceLine line in _linesWithOffsets(newText)) {
    out.add(
      ToolDiffLine(
        ToolDiffKind.added,
        line.text,
        sourceStart: line.start,
        sourceEnd: line.end,
      ),
    );
  }
  final bool truncated = out.length > maxLines;
  return ToolDiffHunk(
    lines: truncated ? out.sublist(0, maxLines) : out,
    truncated: truncated,
    startLine: 0,
    fileText: newText,
    beforeText: oldText,
    hasContext: false,
  );
}

/// 一行 + 它在**自己那段源码**里的区间。
class _SourceLine {
  const _SourceLine(this.text, this.start, this.end);
  final String text;
  final int start;
  final int end;
}

ToolDiffLine _of(_SourceLine line, ToolDiffKind kind) => ToolDiffLine(
  kind,
  line.text,
  sourceStart: line.start,
  sourceEnd: line.end,
);

/// 文本 → 行（含各自在文本里的 `[start, end)`）：末尾换行不额外算一行，与 `LineSplitter` 同口径。
List<_SourceLine> _linesWithOffsets(String text) {
  final List<_SourceLine> out = <_SourceLine>[];
  if (text.isEmpty) return out;
  int lineStart = 0;
  while (lineStart <= text.length) {
    final int nl = text.indexOf('\n', lineStart);
    if (nl < 0) {
      if (lineStart < text.length) {
        out.add(_SourceLine(text.substring(lineStart), lineStart, text.length));
      }
      break;
    }
    out.add(_SourceLine(text.substring(lineStart, nl), lineStart, nl));
    lineStart = nl + 1;
  }
  return out;
}

/// 与核心 `LineSplitter` 同口径：空串 = 0 行；末尾换行不额外算一行；空行照算。
List<String> _splitLines(String text) {
  if (text.isEmpty) return const <String>[];
  return const LineSplitter().convert(text);
}

/// [offset] 落在第几行（0 基）——与 [_splitLines] 同一口径（数它前面有几个换行）。
int _lineIndexAt(String text, int offset) {
  int count = 0;
  for (int i = 0; i < offset && i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) count++;
  }
  return count;
}
