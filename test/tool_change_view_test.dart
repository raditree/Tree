import 'package:flutter_test/flutter_test.dart';
import 'package:tree/ui/services/tool_change_view.dart';

/// 「详情」页的变更视图（纯函数）：write 的内容 + edit 的**带上下文 diff**。
///
/// 用户 2026-10-04：「写入的具体内容呢？编辑做成 diff 的输出格式（最好带少量几行上下文
/// 方便用户阅读）」。这里钉的就是那两个口径：内容要给全、diff 要带上下文且**不能编**。
void main() {
  group('write：内容本身 + 截断如实', () {
    test('正常内容原样给出，行数 / 字符数照核心 LineSplitter 口径', () {
      final WriteContentView view = buildWriteContent('a\nb\nc');
      expect(view.text, 'a\nb\nc');
      expect(view.truncated, isFalse);
      expect(view.totalLines, 3);
      expect(view.totalChars, 5);
    });

    test('末尾换行不多算一行（与核心一致）', () {
      expect(buildWriteContent('a\nb\n').totalLines, 2);
      expect(buildWriteContent('').totalLines, 0);
    });

    test('行数超上限：只给前面这些行，并标 truncated', () {
      final String content = List<String>.generate(10, (int i) => 'line$i').join('\n');
      final WriteContentView view = buildWriteContent(content, maxLines: 4);
      expect(view.truncated, isTrue);
      expect(view.totalLines, 10, reason: '总数照实报');
      expect(view.text, 'line0\nline1\nline2\nline3');
    });

    test('字符数超上限：按字符截断（长单行也不会把界面卡死）', () {
      final String content = 'x' * 100;
      final WriteContentView view = buildWriteContent(content, maxChars: 10);
      expect(view.truncated, isTrue);
      expect(view.text.length, 10);
      expect(view.totalChars, 100);
    });
  });

  group('edit：带上下文的变更块', () {
    // 文件结构：header 1..3 / 目标行 / tail 1..3
    String fileWith(String middle) => <String>[
      'line1',
      'line2',
      'line3',
      middle,
      'tail1',
      'tail2',
      'tail3',
    ].join('\n');

    test('单行替换：上下各 3 行上下文，新旧行各一条', () {
      final ToolDiffHunk? hunk = buildEditDiff(
        fileText: fileWith('新的一行'),
        oldText: '旧的一行',
        newText: '新的一行',
      );
      expect(hunk, isNotNull);
      expect(hunk!.removedCount, 1);
      expect(hunk.addedCount, 1);
      expect(hunk.header, '@@ -1,1 +1,1 @@');
      expect(
        hunk.lines.map((ToolDiffLine l) => '${l.marker}${l.text}').toList(),
        <String>[
          ' line1',
          ' line2',
          ' line3',
          '-旧的一行',
          '+新的一行',
          ' tail1',
          ' tail2',
          ' tail3',
        ],
      );
    });

    test('多行块替换：旧块逐行 -、新块逐行 +', () {
      final ToolDiffHunk? hunk = buildEditDiff(
        fileText: fileWith('new1\nnew2\nnew3'),
        oldText: 'old1\nold2',
        newText: 'new1\nnew2\nnew3',
      );
      expect(hunk, isNotNull);
      expect(hunk!.removedCount, 2);
      expect(hunk.addedCount, 3);
      final List<String> marked = hunk.lines
          .where((ToolDiffLine l) => l.kind != ToolDiffKind.context)
          .map((ToolDiffLine l) => '${l.marker}${l.text}')
          .toList();
      expect(marked, <String>['-old1', '-old2', '+new1', '+new2', '+new3']);
      expect(hunk.lines.first.kind, ToolDiffKind.context);
    });

    test('行中间的替换：把**整行**标出来（不是只贴两段碎片）', () {
      // 磁盘上是**改完之后**的样子（new_text 在里面），old_text 用于还原被替换的那一段
      const String file = 'aaa\nfinal x = post(msg, retry);\nbbb';
      final ToolDiffHunk? hunk = buildEditDiff(
        fileText: file,
        oldText: 'post(msg)',
        newText: 'post(msg, retry)',
      );
      expect(hunk, isNotNull);
      final List<String> marked = hunk!.lines
          .where((ToolDiffLine l) => l.kind != ToolDiffKind.context)
          .map((ToolDiffLine l) => '${l.marker}${l.text}')
          .toList();
      expect(marked, <String>[
        '-final x = post(msg);',
        '+final x = post(msg, retry);',
      ]);
      expect(hunk.lines.first.text, 'aaa', reason: '上下文照旧');
      expect(hunk.lines.last.text, 'bbb');
    });

    test('纯删除（new_text 为空）：用 old_text 定位', () {
      final ToolDiffHunk? hunk = buildEditDiff(
        fileText: <String>['a', 'b', 'c'].join('\n'),
        oldText: 'b',
        newText: '',
      );
      expect(hunk, isNotNull);
      expect(hunk!.removedCount, 1);
      expect(
        hunk.lines
            .firstWhere((ToolDiffLine l) => l.kind == ToolDiffKind.removed)
            .text,
        'b',
      );
    });

    test('定位不到就返回 null（不许编一份像 diff 的东西）', () {
      expect(
        buildEditDiff(
          fileText: '完全另一份内容',
          oldText: 'old',
          newText: 'new',
        ),
        isNull,
      );
      expect(
        buildEditDiff(fileText: 'abc', oldText: '', newText: ''),
        isNull,
        reason: '两段都空 = 没有可展示的改动',
      );
    });

    test('每行都带着"它在哪段源码的哪一段"（界面据此按整段着色切片）', () {
      final ToolDiffHunk? hunk = buildEditDiff(
        fileText: fileWith('新的一行'),
        oldText: '旧的一行',
        newText: '新的一行',
      );
      expect(hunk, isNotNull);
      expect(hunk!.hasContext, isTrue);
      for (final ToolDiffLine line in hunk.lines) {
        final String source = line.kind == ToolDiffKind.removed
            ? hunk.beforeText
            : hunk.fileText;
        expect(line.sourceStart, greaterThanOrEqualTo(0));
        expect(
          source.substring(line.sourceStart, line.sourceEnd),
          line.text,
          reason: '区间必须正好圈住这一行：${line.kind.name}',
        );
      }
    });

    test('翻历史（只有调用参数）：退化成 -旧/+新，且**如实标没有上下文**', () {
      final ToolDiffHunk? hunk = buildEditDiffFromArgs(
        oldText: 'old1\nold2',
        newText: 'new1',
      );
      expect(hunk, isNotNull);
      expect(hunk!.hasContext, isFalse, reason: '不能假装这是完整 diff');
      expect(
        hunk.lines.map((ToolDiffLine l) => '${l.marker}${l.text}').toList(),
        <String>['-old1', '-old2', '+new1'],
      );
      expect(hunk.removedCount, 2);
      expect(hunk.addedCount, 1);
      // 两段源码各自给出，界面照样能按源码着色
      expect(hunk.beforeText, 'old1\nold2');
      expect(hunk.fileText, 'new1');
      final ToolDiffLine removed = hunk.lines.first;
      expect(
        hunk.beforeText.substring(removed.sourceStart, removed.sourceEnd),
        'old1',
      );
      expect(buildEditDiffFromArgs(oldText: '', newText: ''), isNull);
    });

    test('上下文可调；行数超上限时标 truncated 且只留前 N 行', () {
      final ToolDiffHunk? hunk = buildEditDiff(
        fileText: fileWith('x'),
        oldText: 'x',
        newText: 'x',
        context: 1,
        maxLines: 3,
      );
      expect(hunk, isNotNull);
      expect(hunk!.truncated, isTrue);
      expect(hunk.lines.length, 3);
    });
  });
}
