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

    test('limit 夹在 1..1000', () {
      expect(GitOutput.clampLimit(0), 1);
      expect(GitOutput.clampLimit(-5), 1);
      expect(GitOutput.clampLimit(50), 50);
      expect(GitOutput.clampLimit(1001), 1000);
    });
  });
}
