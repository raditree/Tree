import 'package:flutter_test/flutter_test.dart';

import 'package:tree/io/ssh_workspace_executor.dart';

void main() {
  group('SshWorkspaceExecutor.posixNormPath', () {
    test('绝对路径必须保留开头根标记', () {
      // 回归：此前把开头的 `/` 剥掉，导致 SFTP 把
      // `home/open/CodeStudio/x` 当相对路径解析到错误位置而报 No such file。
      expect(
        SshWorkspaceExecutor.posixNormPath('/home/open/CodeStudio/f.txt'),
        '/home/open/CodeStudio/f.txt',
      );
      expect(
        SshWorkspaceExecutor.posixNormPath('/home/open/CodeStudio/requirements.txt'),
        '/home/open/CodeStudio/requirements.txt',
      );
    });

    test('相对路径保持相对（不带根标记）', () {
      expect(
        SshWorkspaceExecutor.posixNormPath('home/open/CodeStudio/f.txt'),
        'home/open/CodeStudio/f.txt',
      );
      expect(
        SshWorkspaceExecutor.posixNormPath('relative/x'),
        'relative/x',
      );
    });

    test('折叠 . 与 ..，统一多余分隔符', () {
      expect(
        SshWorkspaceExecutor.posixNormPath('/home/./open/../open/CodeStudio//f.txt'),
        '/home/open/CodeStudio/f.txt',
      );
      expect(
        SshWorkspaceExecutor.posixNormPath('/a/b/../../f.txt'),
        '/f.txt',
      );
      expect(
        SshWorkspaceExecutor.posixNormPath('.self/team_roster.md'),
        '.self/team_roster.md',
      );
    });

    test('根与空路径边界', () {
      expect(SshWorkspaceExecutor.posixNormPath('/'), '/');
      expect(SshWorkspaceExecutor.posixNormPath(''), '');
      expect(SshWorkspaceExecutor.posixNormPath('///'), '/');
      expect(SshWorkspaceExecutor.posixNormPath('/..'), '/');
    });
  });
}
