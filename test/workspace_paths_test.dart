import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/services/workspace_paths.dart';

/// 文件树的路径与名字口径全是纯函数，这里逐条钉住（树的行为测试见
/// test/file_tree_explorer_test.dart）。
void main() {
  group('工作空间相对路径纯函数', () {
    test('归一化：反斜杠 / 首尾斜杠 / 空串', () {
      expect(workspacePathNormalize('a/b'), 'a/b');
      expect(workspacePathNormalize('a\\b\\c'), 'a/b/c');
      expect(workspacePathNormalize('/a/b/'), 'a/b');
      expect(workspacePathNormalize(''), '');
      expect(workspacePathNormalize('/'), '');
    });

    test('拼路径：根（空串）直接给名字，否则逐级', () {
      expect(workspacePathJoin('', 'a.txt'), 'a.txt');
      expect(workspacePathJoin('src', 'a.txt'), 'src/a.txt');
      expect(workspacePathJoin('src/lib/', 'a.txt'), 'src/lib/a.txt');
      expect(workspacePathJoin('src', ''), 'src');
    });

    test('父目录 / 名字', () {
      expect(workspacePathParent(''), '');
      expect(workspacePathParent('a.txt'), '');
      expect(workspacePathParent('src/a.txt'), 'src');
      expect(workspacePathParent('src/lib/a.txt'), 'src/lib');
      expect(workspacePathName('src/lib/a.txt'), 'a.txt');
      expect(workspacePathName(''), '');
    });

    test('祖孙判据：本身算、前缀陷阱不算、根是一切祖先', () {
      expect(workspacePathAtOrUnder('src/a.txt', 'src'), isTrue);
      expect(workspacePathAtOrUnder('src', 'src'), isTrue);
      expect(workspacePathAtOrUnder('src/deep/a.txt', 'src'), isTrue);
      expect(
        workspacePathAtOrUnder('src2/a.txt', 'src'),
        isFalse,
        reason: 'src2 不是 src 的后代（前缀陷阱）',
      );
      expect(workspacePathAtOrUnder('other', 'src'), isFalse);
      expect(workspacePathAtOrUnder('any', ''), isTrue);
    });

    test('改名重映射：整棵子树一起搬，别的前缀不动', () {
      expect(workspacePathRemap('a.txt', 'a.txt', 'b.txt'), 'b.txt');
      expect(workspacePathRemap('src/a.txt', 'src', 'lib'), 'lib/a.txt');
      expect(workspacePathRemap('src/deep/a.txt', 'src', 'lib'), 'lib/deep/a.txt');
      expect(workspacePathRemap('src2/a.txt', 'src', 'lib'), 'src2/a.txt');
      expect(
        workspacePathRemap('a.txt', '', 'x'),
        'a.txt',
        reason: '根不能改名：保守不动',
      );
    });
  });

  group('条目名校验（新建 / 重命名共用）', () {
    String? check(
      String raw, {
      List<String> siblings = const <String>[],
      String? original,
    }) => validateEntryName(raw, siblings: siblings, originalName: original);

    test('空 / 点 / 分隔符 / 保留字符 / 控制字符 / 结尾点空格 / 过长', () {
      expect(check('   '), '名字不能为空');
      expect(check('.'), '名字不能是 . 或 ..');
      expect(check('..'), '名字不能是 . 或 ..');
      expect(check('a/b'), isNotNull);
      expect(check('a\\b'), isNotNull);
      expect(check('a:b'), isNotNull);
      expect(check('a*b'), isNotNull);
      expect(check('a\u0000b'), '名字里不能有控制字符');
      expect(check('a.'), isNotNull);
      expect(check('a' * 129), isNotNull);
    });

    test('Windows 保留设备名（带扩展名也算）', () {
      expect(check('CON'), isNotNull);
      expect(check('nul.txt'), isNotNull);
      expect(check('com1'), isNotNull);
      expect(check('console'), isNull, reason: '只有精确的保留名才拦');
    });

    test('同名：不分大小写；重命名跳过自己；没改名字单独给原因', () {
      expect(check('a.txt', siblings: <String>['A.TXT']), '同名条目已存在：a.txt');
      expect(check('a.txt', siblings: <String>['b.txt']), isNull);
      expect(
        check('a.txt', siblings: <String>['a.txt'], original: 'a.txt'),
        '名字没有变化',
      );
      expect(
        check('A.txt', siblings: <String>['a.txt'], original: 'B.txt'),
        '同名条目已存在：A.txt',
      );
      // 重命名成别的名字时，自己那条（同名）不算冲突
      expect(
        check('c.txt', siblings: <String>['a.txt', 'b.txt'], original: 'a.txt'),
        isNull,
      );
    });

    test('合法名字：中文 / 点开头 / 带空格 / 数字开头都放行', () {
      expect(check('新建文件.txt'), isNull);
      expect(check('.gitignore'), isNull);
      expect(check('my file.md'), isNull);
      expect(check('2026-10-03.md'), isNull);
    });

    test('校验的是 trim 后的名字', () {
      expect(check('  a.txt  '), isNull);
      expect(
        validateEntryName('  a.txt  ', siblings: <String>['a.txt']),
        '同名条目已存在：a.txt',
      );
    });

    test('行内重命名默认选中名字本体（不含扩展名）', () {
      expect(entryNameSelectionLength('a.txt'), 1);
      expect(entryNameSelectionLength('dir'), 3);
      expect(entryNameSelectionLength('.gitignore'), 10);
      expect(entryNameSelectionLength('a.tar.gz'), 5);
    });
  });
}
