import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

import 'fake_ssh_transport.dart';

/// 后台执行原语（terminal 的 `hook=true`）在**本机**与**远端**两个后端上的行为。
///
/// 本机分支是真进程（真起、真杀）；远端分支用假 transport 断言**命令形状**与
/// **轮询语义**——本机没有 sshd，真链路在这里验不了（见 docs/known-issues.md）。
void main() {
  group('LocalWorkspaceIO 后台执行（本机分支）', () {
    late Directory root;
    late LocalWorkspaceIO io;

    setUp(() {
      root = Directory.systemTemp.createTempSync('tree_bgexec_');
      io = LocalWorkspaceIO(root.path);
    });

    tearDown(() async {
      // Windows 上被终止的子进程可能还短暂持有日志文件句柄：删除要重试
      for (int i = 0; i < 10 && root.existsSync(); i++) {
        try {
          root.deleteSync(recursive: true);
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
      }
    });

    test('startBackground：立即返回、日志头落盘、结束时给退出码', () async {
      final DateTime began = DateTime.now();
      final BackgroundExecHandle handle = await io.startBackground(
        command: 'echo bg-ok',
        logRelativePath: '.output/t1.log',
      );
      expect(
        DateTime.now().difference(began).inSeconds,
        lessThan(5),
        reason: '起后台不等待命令结束',
      );
      expect(handle.remote, isFalse);
      expect(handle.pid, isNotNull);

      final int code = await handle.exitCode.timeout(const Duration(seconds: 20));
      expect(code, 0);
      final String log = File(io.resolve('.output/t1.log')).readAsStringSync();
      expect(log, contains('# [terminal hook] echo bg-ok'));
      expect(log, contains('bg-ok'));
      expect(log, contains('(cwd='));
    });

    test('appendLog / readTail：追加写与尾部读取（工作空间相对路径）', () async {
      await io.appendLog('.output/t2.log', '第一行\n');
      await io.appendLog('.output/t2.log', '第二行\n');
      final String? tail = await io.readTail('.output/t2.log', 100);
      expect(tail, contains('第一行'));
      expect(tail, contains('第二行'));
      expect(
        await io.readTail('.output/不存在.log', 10),
        isNull,
        reason: '读不到返回 null，不抛',
      );
    });

    test('readTail 只取尾部 N 个字符', () async {
      await io.appendLog('.output/t3.log', 'ABCDEFGHIJ');
      expect(await io.readTail('.output/t3.log', 3), 'HIJ');
    });

    test('cancel：杀整棵进程树（退出码非 0）；重复 cancel 仍走 killProcessTree', () async {
      final BackgroundExecHandle handle = await io.startBackground(
        command: Platform.isWindows ? 'Start-Sleep -Seconds 30' : 'sleep 30',
        logRelativePath: '.output/t4.log',
      );
      expect(await handle.cancel(), isTrue);
      final int code = await handle.exitCode.timeout(const Duration(seconds: 20));
      expect(code, isNot(0), reason: '被终止的进程不会以 0 退出');
      expect(await handle.cancel(), isTrue, reason: 'killProcessTree 尽力而为，不假装失败');
    });

    test('attachBackground：本机不支持接续（显式拒绝，不假装能接管）', () async {
      await expectLater(
        io.attachBackground(
          command: 'echo x',
          logRelativePath: '.output/t5.log',
        ),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('越界日志路径被拒（与工具层同一条边界）', () async {
      await expectLater(
        io.startBackground(command: 'echo x', logRelativePath: '../x.log'),
        throwsA(isA<WorkspacePathException>()),
      );
      // appendLog 的约定是"**失败不抛**"（日志写不进去不该害死任务本身）：
      // 越界路径只被记日志、不落盘，也不把调用方炸掉。
      await io.appendLog('../x.log', 'x');
    });
  });

  group('SshWorkspaceIO 后台执行（远端分支；假 transport）', () {
    late FakeSshTransport transport;
    late SshWorkspaceIO io;

    setUp(() {
      transport = FakeSshTransport();
      io = SshWorkspaceIO('/home/u/proj', transport);
    });

    test('startBackground：nohup + 三路重定向 + 哨兵 + echo pid；命令过 POSIX 单引号转义', () async {
      transport.onRun = (String command) => command.contains('nohup')
          ? const SshExecResult(exitCode: 0, stdout: '4242\n', stderr: '')
          : const SshExecResult(
              exitCode: 0,
              stdout: '__TREE_RUNNING__\n',
              stderr: '',
            );
      final BackgroundExecHandle handle = await io.startBackground(
        command: "python train.py --tag 'a b'",
        logRelativePath: '.output/h1.log',
      );
      expect(handle.remote, isTrue);
      expect(handle.pid, 4242, reason: '从 echo 的输出里取后台子 shell 的 pid');

      final String cmd = transport.commands.first;
      expect(cmd, contains('( setsid nohup sh -c'));
      expect(
        cmd,
        contains(r'& echo $! )'),
        reason: r'子壳内 `& echo $!`：子壳立刻退出 ⇒ 通道立刻 EOF ⇒ run 立刻返回；pid 仍在 stdout',
      );
      expect(
        cmd,
        isNot(contains('; } & echo')),
        reason: r'旧形状 `{ ... ; } & echo $!` 会让承载组的子壳握通道、阻塞到命令结束（known-issues #23）',
      );
      expect(
        cmd,
        contains("> '/home/u/proj/.output/h1.log' 2>&1 < /dev/null"),
        reason: '日志在**远端工作空间**，且三路重定向 + stdin 接 /dev/null',
      );
      expect(
        cmd,
        contains('printf %s \$? >'),
        reason: '退出码写进哨兵文件（本机据此轮询）',
      );
      expect(cmd, contains('/home/u/proj/.output/h1.exit'));
      expect(cmd, contains(r'echo $!'));
      expect(cmd, contains("cd '/home/u/proj'"));
      expect(
        cmd,
        contains(r"'\''"),
        reason: '用户命令里的单引号经过 POSIX 单引号转义，不原样塞进去',
      );
      await handle.close();
    });

    test('退出码哨兵的相对路径派生规则（台账只需记日志路径）', () {
      expect(io.exitMarkerRelativePath('.output/h1.log'), '.output/h1.exit');
      expect(io.exitMarkerRelativePath('.output/h1'), '.output/h1.exit');
      expect(io.exitMarkerRelativePath('logs/a.b.log'), 'logs/a.b.exit');
    });

    test('appendLog / readTail 都走远端 shell（printf >> 与 tail -c）', () async {
      transport.onRun = (String command) => const SshExecResult(
        exitCode: 0,
        stdout: 'tail-content',
        stderr: '',
      );
      await io.appendLog('.output/h2.log', '第 1 行\n');
      final String append = transport.commands.single;
      expect(append, startsWith("mkdir -p '/home/u/proj/.output'"));
      expect(append, contains('printf %s '));
      expect(append, contains(">> '/home/u/proj/.output/h2.log'"));

      final String? tail = await io.readTail('.output/h2.log', 5);
      expect(tail, 'ntent', reason: '只取尾部 5 个字符');
      expect(
        transport.commands.last,
        contains("tail -c 6 '/home/u/proj/.output/h2.log'"),
      );
    });

    test('cancel：拿得到 pid 就发 kill（进程组 + 单进程）；拿不到时如实 false', () async {
      transport.onRun = (String command) => command.contains('nohup')
          ? const SshExecResult(exitCode: 0, stdout: '777\n', stderr: '')
          : const SshExecResult(
              exitCode: 0,
              stdout: 'done\n',
              stderr: '',
            );
      final BackgroundExecHandle handle = await io.startBackground(
        command: 'sleep 999',
        logRelativePath: '.output/h3.log',
      );
      expect(await handle.cancel(), isTrue);
      final String kill = transport.commands.last;
      expect(kill, contains('kill -TERM -777'));
      expect(kill, contains('kill -TERM 777'));
      await handle.close();

      // 拿不到 pid（包装命令没回 pid）⇒ 如实说"杀不掉"
      transport.commands.clear();
      transport.onRun = (String command) => const SshExecResult(
        exitCode: 0,
        stdout: '不是数字的输出\n',
        stderr: '',
      );
      final BackgroundExecHandle noPid = await io.startBackground(
        command: 'sleep 999',
        logRelativePath: '.output/h4.log',
      );
      expect(noPid.pid, isNull);
      expect(await noPid.cancel(), isFalse, reason: '没有 pid 就不假装杀成功');
      await noPid.close();
    });

    test('attachBackground：不重跑命令，只重挂轮询（首次探测立刻发生）', () async {
      final List<String> seen = <String>[];
      transport.onRun = (String command) {
        seen.add(command);
        return const SshExecResult(exitCode: 0, stdout: '0\n', stderr: '');
      };
      final BackgroundExecHandle handle = await io.attachBackground(
        command: 'python train.py',
        logRelativePath: '.output/h5.log',
        pid: 7,
      );
      final int code = await handle.exitCode.timeout(const Duration(seconds: 10));
      expect(code, 0);
      expect(seen, hasLength(1), reason: '只探测一次；绝不重跑远端命令');
      expect(seen.single, contains("cat '/home/u/proj/.output/h5.exit'"));
      await handle.close();
    });

    test('轮询判 GONE：进程消失且没有哨兵 ⇒ 可辨退出码（不假装正常退出）', () async {
      transport.onRun = (String command) => command.contains('nohup')
          ? const SshExecResult(exitCode: 0, stdout: '99\n', stderr: '')
          : const SshExecResult(
              exitCode: 0,
              stdout: '__TREE_GONE__\n',
              stderr: '',
            );
      final BackgroundExecHandle handle = await io.startBackground(
        command: 'sleep 999',
        logRelativePath: '.output/h6.log',
      );
      final int code = await handle.exitCode.timeout(const Duration(seconds: 10));
      expect(code, BackgroundExecHandle.goneExitCode);
      await handle.close();
    });
  });
}
