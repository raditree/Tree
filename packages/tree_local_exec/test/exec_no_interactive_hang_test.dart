import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// Windows 上命令是否走 PowerShell（退化成 cmd 时下面几条 PowerShell 断言不适用）。
bool get _isPowerShellWindows =>
    Platform.isWindows && !Shell.windowsShell.toLowerCase().endsWith('cmd.exe');

/// 读一行 stdin：拿到 EOF 就打印 STDIN_EOF。
///
/// 子进程的 stdin 是 Dart 侧的管道，我们从不往里写——**关掉它**这条命令才会立刻打印
/// STDIN_EOF；不关就会一直等。这是「本地执行会不会被等输入的子进程挂死」的最小判定探针。
String get _stdinProbe => Platform.isWindows
    ? r'$line = [Console]::In.ReadLine(); if ($null -eq $line) { "STDIN_EOF" } else { $line }'
    : r'if read -r line; then echo "$line"; else echo "STDIN_EOF"; fi';

void main() {
  group('本地执行绝不进入交互等待', () {
    late Directory root;
    late LocalWorkspaceIO io;

    setUp(() {
      root = Directory.systemTemp.createTempSync('tree_stdin_');
      io = LocalWorkspaceIO(root.path);
    });

    tearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {
        // 清理失败不影响断言结果
      }
    });

    test('裸 echo 不会把 exec 挂住（2026-10-02 线上事故）', () async {
      // PowerShell 里 `echo` 是 `Write-Output` 的别名，而它缺 -InputObject 时会**弹参数
      // 提示等输入**；子进程 stdin 永不关闭 + 本地执行「进程活着就永不超时」⇒ 整轮会话永久
      // 卡死（现场：`git log …; echo; echo "=== …"` 卡了十几分钟）。
      final ExecOutcome outcome = await io
          .exec('echo; echo after-bare-echo')
          .timeout(const Duration(seconds: 30));
      expect(outcome.stdout, contains('after-bare-echo'));
    });

    test('读 stdin 的命令立刻拿到 EOF，而不是一直等', () async {
      if (Platform.isWindows && !_isPowerShellWindows) return;
      final ExecOutcome outcome = await io
          .exec(_stdinProbe)
          .timeout(const Duration(seconds: 30));
      expect(outcome.stdout, contains('STDIN_EOF'));
    });

    test('裸 echo 的语义回到 cmd：真的输出一个空行', () async {
      final ExecOutcome outcome = await io
          .exec('echo "a"; echo; echo "b"')
          .timeout(const Duration(seconds: 30));
      expect(outcome.exitCode, 0);
      final List<String> lines = outcome.stdout
          .split('\n')
          .map((String line) => line.trimRight())
          .toList();
      expect(lines.contains(''), isTrue, reason: '裸 echo 应当输出一个空行');
      expect(outcome.stdout, contains('a'));
      expect(outcome.stdout, contains('b'));
    });

  });

  group('Shell 参数：不进入交互模式', () {
    test('PowerShell 命令行带 -NonInteractive（且在 -Command 之前）', () {
      if (!_isPowerShellWindows) return;
      final List<String> args = Shell.argsFor('echo hi');
      expect(args, contains('-NonInteractive'));
      expect(args.indexOf('-NonInteractive') < args.indexOf('-Command'), isTrue);
      expect(Shell.argsForScript(r'C:\tmp\x.ps1'), contains('-NonInteractive'));
    });

  });
}
