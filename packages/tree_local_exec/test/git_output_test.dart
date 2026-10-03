import 'package:test/test.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// 解析规则的单测（M9 Q4）。
///
/// 本地与 SSH 两侧共用 [GitOutput] 的命令与解析，所以边界用纯字符串钉死即可，
/// 不需要真 git、也不需要远端：真链路（进程/SFTP/exec）另有集成测试。
void main() {
  group('parseLog', () {
    test('四段：hash / 作者 / 日期 / 标题', () {
      final List<GitCommit> commits = GitOutput.parseLog(
        'abc\t张三\t2026-01-02 03:04:05 +0800\t修复登录\n'
        'def\t李四\t2026-01-01 00:00:00 +0800\t初次提交\n',
      );
      expect(commits, hasLength(2));
      expect(commits.first.hash, 'abc');
      expect(commits.first.author, '张三');
      expect(commits.first.date, '2026-01-02 03:04:05 +0800');
      expect(commits.first.message, '修复登录');
      expect(commits.last.message, '初次提交');
    });

    test('标题含 tab：只切前三段，余下整体归 message', () {
      final List<GitCommit> commits = GitOutput.parseLog(
        'abc\tauthor\t2026-01-02 03:04:05 +0800\t标题\t带\t两个 tab',
      );
      expect(commits.single.message, '标题\t带\t两个 tab');
    });

    test('段数不足的行跳过（报错文本不会变成提交）', () {
      expect(GitOutput.parseLog('fatal: not a git repository'), isEmpty);
      expect(GitOutput.parseLog('a\tb\tc'), isEmpty);
      expect(GitOutput.parseLog(''), isEmpty);
    });

    test('CRLF 与空行：仍按行切、去掉行尾空白', () {
      final List<GitCommit> commits = GitOutput.parseLog(
        'abc\tauthor\t2026-01-02 03:04:05 +0800\t标题\r\n\r\n',
      );
      expect(commits, hasLength(1));
      expect(commits.single.message, '标题');
    });
  });

  group('parseBranches', () {
    test('* 是当前分支，且当前分支同样进列表（与旧实现一致）', () {
      final ({List<String> branches, String current}) parsed =
          GitOutput.parseBranches('* main\n  dev\n  remotes/origin/main\n');
      expect(parsed.current, 'main');
      expect(parsed.branches, <String>['main', 'dev', 'remotes/origin/main']);
    });

    test('空输出 → 空列表 + 空当前分支', () {
      final ({List<String> branches, String current}) parsed =
          GitOutput.parseBranches('');
      expect(parsed.branches, isEmpty);
      expect(parsed.current, '');
    });
  });

  group('parseStatus（M11：git status --porcelain=v1 -z）', () {
    /// 按 -z 的真实形状拼输出：每条记录以 NUL 结尾。
    String z(List<String> records) =>
        records.map((String r) => '$r\u0000').join();

    test('XY 映射成面板口径（M / U / A / D）', () {
      final ({List<GitStatusEntry> entries, bool truncated}) parsed =
          GitOutput.parseStatus(
            z(<String>[' M a.txt', 'A  b.txt', '?? c.txt', ' D d.txt']),
          );
      expect(
        parsed.entries
            .map((GitStatusEntry e) => '${e.status}:${e.path}')
            .toList(),
        <String>['M:a.txt', 'A:b.txt', 'U:c.txt', 'D:d.txt'],
      );
      expect(parsed.truncated, isFalse);
    });

    test('空格 / 中文 / 引号路径不碎（-z 不做引号转义）', () {
      final ({List<GitStatusEntry> entries, bool truncated}) parsed =
          GitOutput.parseStatus(
            z(<String>[
              ' M my file.txt',
              ' M 中文 目录/文件 名.txt',
              ' M a"b.txt',
            ]),
          );
      expect(
        parsed.entries.map((GitStatusEntry e) => e.path).toList(),
        <String>['my file.txt', '中文 目录/文件 名.txt', 'a"b.txt'],
      );
    });

    test('重命名 / 复制：取新名，旧名字段不另成一条', () {
      final ({List<GitStatusEntry> entries, bool truncated}) parsed =
          GitOutput.parseStatus(
            z(<String>['R  new name.txt', 'old name.txt', ' M after.txt']),
          );
      expect(parsed.entries, hasLength(2));
      expect(parsed.entries.first.path, 'new name.txt');
      expect(parsed.entries.first.status, 'R');
      expect(
        parsed.entries.map((GitStatusEntry e) => e.path),
        isNot(contains('old name.txt')),
        reason: '旧名是上一条的补充字段，不是独立条目',
      );
      expect(parsed.entries.last.path, 'after.txt');
    });

    test('暂存与工作区混合：M 优先于 A', () {
      expect(GitOutput.reduceStatus('A', 'M'), 'M');
      expect(GitOutput.reduceStatus('M', 'M'), 'M');
      expect(GitOutput.reduceStatus('M', 'D'), 'M');
      expect(GitOutput.reduceStatus('R', 'M'), 'M');
      expect(GitOutput.reduceStatus(' ', 'M'), 'M');
      expect(GitOutput.reduceStatus('A', ' '), 'A');
      expect(GitOutput.reduceStatus(' ', 'D'), 'D');
      expect(GitOutput.reduceStatus('R', ' '), 'R');
      expect(GitOutput.reduceStatus('C', ' '), 'R');
      expect(GitOutput.reduceStatus('U', 'U'), 'U');
      expect(GitOutput.reduceStatus('?', '?'), 'U');
      expect(GitOutput.reduceStatus('!', '!'), 'I');
      expect(GitOutput.reduceStatus('X', 'Y'), isNull);
    });

    test('被忽略（!!）与未跟踪目录（去掉 git 补的尾斜杠）', () {
      final ({List<GitStatusEntry> entries, bool truncated}) parsed =
          GitOutput.parseStatus(z(<String>['!! build/', '?? dist/']));
      expect(parsed.entries, hasLength(2));
      expect(parsed.entries.first.path, 'build');
      expect(parsed.entries.first.status, 'I');
      expect(parsed.entries.last.path, 'dist');
      expect(parsed.entries.last.status, 'U');
    });

    test('非法 / 不完整输入不抛（认不出的记录跳过）', () {
      expect(GitOutput.parseStatus('').entries, isEmpty);
      expect(
        GitOutput.parseStatus('fatal: not a git repository').entries,
        isEmpty,
        reason: '非 -z 的报错文本不该被当成条目',
      );
      expect(GitOutput.parseStatus('\u0000\u0000').entries, isEmpty);
      expect(GitOutput.parseStatus('AB').entries, isEmpty);
      expect(GitOutput.parseStatus(' M ').entries, isEmpty, reason: '空路径跳过');
      expect(
        GitOutput.parseStatus('R  only-new.txt\u0000').entries.single.path,
        'only-new.txt',
        reason: '旧名缺失也不抛，取到的那条照收',
      );
    });

    test('截断：达到 maxEntries 即停并置 truncated', () {
      final ({List<GitStatusEntry> entries, bool truncated}) parsed =
          GitOutput.parseStatus(
            z(<String>[' M a', ' M b', ' M c']),
            maxEntries: 2,
          );
      expect(parsed.entries, hasLength(2));
      expect(parsed.truncated, isTrue);
      expect(
        GitOutput.parseStatus(z(<String>[' M a']), maxEntries: 0).truncated,
        isTrue,
      );
    });

    test('toJson 形状：{path, status}', () {
      final ({List<GitStatusEntry> entries, bool truncated}) parsed =
          GitOutput.parseStatus(z(<String>[' M a.txt']));
      expect(parsed.entries.single.toJson(), <String, dynamic>{
        'path': 'a.txt',
        'status': 'M',
      });
    });
  });

  group('命令形状（本地与 SSH 必须一字不差）', () {
    test('log：--pretty/--date=iso/-n 与旧实现一致', () {
      expect(
        GitOutput.logCommand(10),
        'git log --pretty=format:%H%x09%an%x09%ad%x09%s --date=iso -n 10',
      );
      expect(GitOutput.logArgs(3), <String>[
        'log',
        '--pretty=format:%H%x09%an%x09%ad%x09%s',
        '--date=iso',
        '-n',
        '3',
      ]);
    });

    test('branch：-a 含远端分支', () {
      expect(GitOutput.branchCommand, 'git branch -a');
      expect(GitOutput.branchArgs(), <String>['branch', '-a']);
    });

    test('status：--porcelain=v1 -z，按需 --ignored（路径不碎）', () {
      expect(GitOutput.statusArgs(), <String>[
        'status',
        '--porcelain=v1',
        '-z',
      ]);
      expect(GitOutput.statusCommand(), 'git status --porcelain=v1 -z');
      expect(
        GitOutput.statusCommand(ignored: true),
        'git status --porcelain=v1 -z --ignored',
      );
    });

    test('limit 夹在 1..1000', () {
      expect(GitOutput.clampLimit(0), 1);
      expect(GitOutput.clampLimit(-5), 1);
      expect(GitOutput.clampLimit(50), 50);
      expect(GitOutput.clampLimit(1001), 1000);
    });
  });
}
