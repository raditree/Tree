import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/git_status.dart';

/// git 状态解析 / 归一化 / 目录聚合全是纯函数：核心给的东西再脏也不许抛异常
/// （宁可少上色），这里逐条钉住。
void main() {
  group('状态码 → 枚举', () {
    test('契约里的七个码都能认（大小写不敏感）', () {
      expect(gitFileStatusFromCode('M'), GitFileStatus.modified);
      expect(gitFileStatusFromCode('m'), GitFileStatus.modified);
      expect(gitFileStatusFromCode('U'), GitFileStatus.untracked);
      expect(gitFileStatusFromCode('A'), GitFileStatus.added);
      expect(gitFileStatusFromCode('D'), GitFileStatus.deleted);
      expect(gitFileStatusFromCode('R'), GitFileStatus.renamed);
      expect(gitFileStatusFromCode('I'), GitFileStatus.ignored);
    });

    test('porcelain 的 ?? / ! 也收（核心将来换成 porcelain 口径也不坏）', () {
      expect(gitFileStatusFromCode('??'), GitFileStatus.untracked);
      expect(gitFileStatusFromCode('!'), GitFileStatus.ignored);
    });

    test('没见过的码**不着色**（返回 null，不猜）', () {
      for (final String code in <String>['', '  ', 'X', 'MM', 'modified']) {
        expect(gitFileStatusFromCode(code), isNull, reason: code);
      }
    });
  });

  group('字母 / 中文 / 聚合优先级', () {
    test('行尾字母就是 VS Code 那一套', () {
      expect(GitFileStatus.modified.letter, 'M');
      expect(GitFileStatus.untracked.letter, 'U');
      expect(GitFileStatus.added.letter, 'A');
      expect(GitFileStatus.deleted.letter, 'D');
      expect(GitFileStatus.renamed.letter, 'R');
      expect(GitFileStatus.ignored.letter, 'I');
    });

    test('中文说明（悬停里给用户看的）', () {
      expect(GitFileStatus.modified.label, '已修改');
      expect(GitFileStatus.untracked.label, '未跟踪');
      expect(GitFileStatus.added.label, '已暂存的新增');
      expect(GitFileStatus.deleted.label, '已删除');
      expect(GitFileStatus.renamed.label, '已重命名');
      expect(GitFileStatus.ignored.label, '被忽略');
    });

    test('优先级严格递减：删除 > 修改 > 未跟踪 > 新增 > 重命名 > 忽略', () {
      const List<GitFileStatus> ordered = <GitFileStatus>[
        GitFileStatus.deleted,
        GitFileStatus.modified,
        GitFileStatus.untracked,
        GitFileStatus.added,
        GitFileStatus.renamed,
        GitFileStatus.ignored,
      ];
      for (int i = 1; i < ordered.length; i++) {
        expect(
          ordered[i - 1].priority,
          greaterThan(ordered[i].priority),
          reason: '${ordered[i - 1].name} 应优先于 ${ordered[i].name}',
        );
      }
    });
  });

  group('路径归一化', () {
    test('反斜杠 → 正斜杠、去掉尾部斜杠', () {
      expect(normalizeGitPath('a\\b\\c'), 'a/b/c');
      expect(normalizeGitPath('src/'), 'src');
      expect(normalizeGitPath('src//'), 'src');
      expect(normalizeGitPath('/'), '');
      expect(normalizeGitPath(''), '');
      expect(normalizeGitPath('src/a.dart'), 'src/a.dart');
    });
  });

  group('响应解析（宽容）', () {
    test('不是仓库：entries 一律不着色', () {
      final GitStatusSnapshot snapshot = parseGitStatus(<String, dynamic>{
        'is_repo': false,
        'entries': <dynamic>[
          <String, dynamic>{'path': 'a.txt', 'status': 'M'},
        ],
      });
      expect(snapshot.isRepo, isFalse);
      expect(snapshot.hasChanges, isFalse);
      expect(snapshot.statusFor('a.txt'), isNull);
      expect(snapshot.aggregateForDirectory(''), isNull);
    });

    test('缺 is_repo 当"不是仓库"（核心没落地时不着色，而不是报错）', () {
      final GitStatusSnapshot snapshot = parseGitStatus(<String, dynamic>{});
      expect(snapshot.isRepo, isFalse);
      expect(snapshot.byPath, isEmpty);
      expect(snapshot.truncated, isFalse);
    });

    test('正常响应：路径归一化、未知状态丢掉、缺 path 丢掉、非 Map 项跳过', () {
      final GitStatusSnapshot snapshot = parseGitStatus(<String, dynamic>{
        'is_repo': true,
        'truncated': true,
        'entries': <dynamic>[
          <String, dynamic>{'path': 'src/a.dart', 'status': 'M'},
          <String, dynamic>{'path': 'src\\b.dart', 'status': 'u'},
          <String, dynamic>{'path': 'old.txt', 'status': 'D'},
          <String, dynamic>{'path': 'x.txt', 'status': 'X'},
          <String, dynamic>{'status': 'A'},
          'nonsense',
        ],
      });
      expect(snapshot.isRepo, isTrue);
      expect(snapshot.truncated, isTrue);
      expect(snapshot.byPath, hasLength(3));
      expect(snapshot.statusFor('src/a.dart'), GitFileStatus.modified);
      expect(snapshot.statusFor('src/b.dart'), GitFileStatus.untracked);
      expect(snapshot.statusFor('old.txt'), GitFileStatus.deleted);
      expect(snapshot.statusFor('x.txt'), isNull, reason: '未知状态不进表');
      expect(snapshot.hasChanges, isTrue);
    });

    test('entries 不是 List / 是 null 都不抛', () {
      expect(
        parseGitStatus(<String, dynamic>{'is_repo': true, 'entries': 'oops'})
            .byPath,
        isEmpty,
      );
      expect(
        parseGitStatus(<String, dynamic>{'is_repo': true}).byPath,
        isEmpty,
      );
    });

    test('目录带尾斜杠的条目也能对上文件路径', () {
      final GitStatusSnapshot snapshot = parseGitStatus(<String, dynamic>{
        'is_repo': true,
        'entries': <dynamic>[
          <String, dynamic>{'path': 'src/', 'status': 'M'},
        ],
      });
      expect(snapshot.statusFor('src'), GitFileStatus.modified);
    });
  });

  group('目录聚合（VS Code 的"目录也带标记"）', () {
    final Map<String, GitFileStatus> byPath = <String, GitFileStatus>{
      'src/a.dart': GitFileStatus.modified,
      'src/deep/b.py': GitFileStatus.untracked,
      'src2/c.txt': GitFileStatus.added,
      'old.txt': GitFileStatus.deleted,
      'build/x.o': GitFileStatus.ignored,
    };

    test('名下任一后代命中 ⇒ 目录有状态；更深层也算', () {
      expect(aggregateGitStatus('src', byPath), GitFileStatus.modified);
      expect(aggregateGitStatus('src/deep', byPath), GitFileStatus.untracked);
    });

    test('前缀陷阱：src2 不算在 src 名下', () {
      expect(aggregateGitStatus('src2', byPath), GitFileStatus.added);
      // src 只有 a.dart(M) 与 deep/b.py(U)：按优先级取 M
      expect(aggregateGitStatus('src', byPath), GitFileStatus.modified);
    });

    test('优先级：目录里既有删除又有忽略 ⇒ 显示删除（最需要注意的那个）', () {
      final Map<String, GitFileStatus> mixed = <String, GitFileStatus>{
        'x/a.txt': GitFileStatus.ignored,
        'x/b.txt': GitFileStatus.modified,
        'x/c.txt': GitFileStatus.deleted,
      };
      expect(aggregateGitStatus('x', mixed), GitFileStatus.deleted);
    });

    test('目录自身在表里（核心直接给目录条目）也算命中', () {
      expect(
        aggregateGitStatus('src', <String, GitFileStatus>{
          'src': GitFileStatus.renamed,
        }),
        GitFileStatus.renamed,
      );
    });

    test('没有改动 ⇒ null（不涂色）；根聚合所有改动', () {
      expect(aggregateGitStatus('other', byPath), isNull);
      expect(aggregateGitStatus('', <String, GitFileStatus>{}), isNull);
      expect(aggregateGitStatus('', byPath), GitFileStatus.deleted);
    });

    test('快照上的两个入口与纯函数同口径（isRepo 为假时都返回 null）', () {
      final GitStatusSnapshot snapshot = GitStatusSnapshot(
        isRepo: true,
        byPath: byPath,
      );
      expect(snapshot.statusFor('src/a.dart'), GitFileStatus.modified);
      expect(snapshot.aggregateForDirectory('src'), GitFileStatus.modified);
      expect(GitStatusSnapshot.none.statusFor('src/a.dart'), isNull);
      expect(GitStatusSnapshot.none.aggregateForDirectory('src'), isNull);
    });
  });
}
