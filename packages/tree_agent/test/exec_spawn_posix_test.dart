import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_agent/tree_agent.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'support.dart';

/// 非 POSIX 平台（Windows 开发机）显式 skip —— **带可读理由**，且**一条断言都不删**
/// （M7 会用交叉编译出的 Linux 二进制真跑 `setsid` / `kill -0` / pgid 这些）。
final String? posixSkipReason = Platform.isWindows
    ? 'POSIX 专属（setsid、kill -0、进程组、/bin/sh）：Windows 开发机跳过，'
          'M7 用交叉编译的 Linux 二进制真跑'
    : null;

/// 造一个 `ExecOps`（每次都是新的台账实例 ⇒ 可以模拟 "agent 重启"）。
ExecOps buildExec(String rootPath, String stateDir) => ExecOps(
  guard: PathGuard(rootPath),
  root: rootPath,
  stateDir: stateDir,
  launcher: const PosixShellLauncher(),
  ledger: ProcLedger(stateDir: stateDir, aliveProbe: defaultPidAlive),
);

Future<Map<String, dynamic>> waitForProc(
  ExecOps exec,
  String id,
  bool Function(Map<String, dynamic> proc) predicate, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final Stopwatch watch = Stopwatch()..start();
  Map<String, dynamic> last = <String, dynamic>{};
  while (watch.elapsed < timeout) {
    final Map<String, dynamic> r = await exec.query(<String, dynamic>{'id': id});
    last = (r['proc'] as Map<dynamic, dynamic>).cast<String, dynamic>();
    if (predicate(last)) return last;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('等待后台任务状态超时，最后看到：$last');
}

void main() {
  group('launcher 脚本形状（纯函数，跨平台可断言）', () {
    test('cd 失败也写退出码 127；路径单引号转义；command 不转义', () {
      final String script = buildLauncherScript(
        command: 'echo hi',
        cwd: '/ws',
        logPath: "/ws/it's.log",
        exitFile: '/st/exit/1',
      );
      expect(
        script,
        contains("cd '/ws' || { printf %s 127 > '/st/exit/1'; exit 127; }"),
      );
      expect(
        script,
        contains(
          r"{ echo hi ; } >> '/ws/it'\''s.log' 2>&1 < /dev/null",
        ),
      );
      expect(script, contains("printf '%s' \$? > '/st/exit/1'"));
    });
  });

  group('exec.spawn / list / query / kill（POSIX）', () {
    late Directory root;
    late String rootPath;
    late String stateDir;
    late ExecOps exec;

    setUp(() {
      root = createTempRoot('spawn');
      rootPath = toPosix(root.path);
      stateDir = '$rootPath/state';
      exec = buildExec(rootPath, stateDir);
    });

    tearDown(() => removeTempRoot(root));

    test('**立即返回**；pid/pgid/log_path 有据；退出码与日志可对账', () async {
      final String logPath = '$rootPath/logs/one.log';
      final Stopwatch watch = Stopwatch()..start();
      final Map<String, dynamic> spawned = await exec.spawn(<String, dynamic>{
        'command': 'echo hello-from-bg; exit 7',
        'log_path': logPath,
      });
      watch.stop();

      expect(watch.elapsedMilliseconds, lessThan(3000), reason: '立即返回，不等命令结束');
      final int pid = spawned['pid'] as int;
      expect(pid, greaterThan(0));
      expect(spawned['pgid'], pid, reason: 'setsid ⇒ pgid == pid');
      expect(spawned['log_path'], logPath);
      expect(spawned['started_at_ms'], isA<int>());

      final String id = spawned['id'] as String;
      final Map<String, dynamic> proc = await waitForProc(
        exec,
        id,
        (Map<String, dynamic> p) => p['state'] == BackgroundStates.exited,
      );
      expect(proc['exit_code'], 7);
      expect(
        await File(logPath).readAsString(),
        contains('hello-from-bg'),
        reason: '日志落在调用方给的工作空间内 log_path',
      );
    });

    test('running → kill 整个进程组；杀掉后至少不再是 running（gone 是可辨的）', () async {
      final Map<String, dynamic> spawned = await exec.spawn(<String, dynamic>{
        'command': 'sleep 30',
        'log_path': '$rootPath/logs/sleep.log',
      });
      final String id = spawned['id'] as String;

      final Map<String, dynamic> running = await waitForProc(
        exec,
        id,
        (Map<String, dynamic> p) => p['state'] == BackgroundStates.running,
      );
      expect(running['exit_code'], isNull, reason: 'running 时不该猜退出码');

      final Map<String, dynamic> killed = await exec.kill(<String, dynamic>{
        'id': id,
      });
      expect(killed['killed'], true);

      final Map<String, dynamic> after = await waitForProc(
        exec,
        id,
        (Map<String, dynamic> p) => p['state'] != BackgroundStates.running,
      );
      expect(
        after['state'],
        anyOf(BackgroundStates.gone, BackgroundStates.exited),
      );
    });

    test('exec.list 逐条对账；exec.kill 拿不到记录 ⇒ killed:false（不假装）', () async {
      final Map<String, dynamic> spawned = await exec.spawn(<String, dynamic>{
        'command': 'true',
        'log_path': '$rootPath/logs/t.log',
      });
      final String id = spawned['id'] as String;

      final Map<String, dynamic> listed = await exec.list(<String, dynamic>{});
      final List<Map<String, dynamic>> procs = (listed['procs'] as List<dynamic>)
          .map((dynamic e) => (e as Map<dynamic, dynamic>).cast<String, dynamic>())
          .toList();
      expect(procs.map((Map<String, dynamic> p) => p['id']), contains(id));
      expect(
        procs.firstWhere((Map<String, dynamic> p) => p['id'] == id)['state'],
        anyOf(BackgroundStates.running, BackgroundStates.exited, BackgroundStates.gone),
      );

      expect(
        await exec.kill(<String, dynamic>{'id': 'no-such-id'}),
        <String, dynamic>{'killed': false},
      );
      expect(
        () => exec.query(<String, dynamic>{'id': 'no-such-id'}),
        throwsA(
          isA<RpcException>().having(
            (RpcException e) => e.code,
            'code',
            TunnelErrorCodes.notFound,
          ),
        ),
      );
    });

    test('**agent 重启后 exec.list 读回台账**（不依赖任何内存态）', () async {
      final Map<String, dynamic> spawned = await exec.spawn(<String, dynamic>{
        'command': 'sleep 30',
        'log_path': '$rootPath/logs/restart.log',
      });
      final String id = spawned['id'] as String;

      // 换一个全新的 ExecOps + 全新台账，模拟 agent 进程重启（只靠磁盘）。
      final ExecOps restarted = buildExec(rootPath, stateDir);
      final Map<String, dynamic> listed = await restarted.list(<String, dynamic>{});
      final Map<String, dynamic> proc =
          (listed['procs'] as List<dynamic>)
              .map((dynamic e) => (e as Map<dynamic, dynamic>).cast<String, dynamic>())
              .firstWhere((Map<String, dynamic> p) => p['id'] == id);
      expect(proc['command'], 'sleep 30');
      expect(proc['log_path'], '$rootPath/logs/restart.log');

      await restarted.kill(<String, dynamic>{'id': id});
    });

    test('log_path / cwd 都过越界检查', () async {
      expect(
        () => exec.spawn(<String, dynamic>{
          'command': 'true',
          'log_path': '/tmp/escape.log',
        }),
        throwsA(
          isA<RpcException>().having(
            (RpcException e) => e.code,
            'code',
            TunnelErrorCodes.pathOutOfRoot,
          ),
        ),
      );
      expect(
        () => exec.spawn(<String, dynamic>{
          'command': 'true',
          'log_path': '$rootPath/ok.log',
          'cwd': '/etc',
        }),
        throwsA(isA<RpcException>()),
      );
    });

    test('launcher 脚本真的落盘在 <state>/run/<id>.sh，退出码文件在 <state>/exit/<id>', () async {
      final Map<String, dynamic> spawned = await exec.spawn(<String, dynamic>{
        'command': 'true',
        'log_path': '$rootPath/logs/shape.log',
      });
      final String id = spawned['id'] as String;
      final String script = await File('$stateDir/run/$id.sh').readAsString();
      expect(
        script,
        isNot(contains('setsid')),
        reason: 'setsid 在包装 shell 的命令行里，不在 launcher 脚本里',
      );
      expect(script, contains("cd '$rootPath'"));
      expect(script, contains("> '$stateDir/exit/$id'"));
      expect(script, contains('2>&1 < /dev/null'));

      await waitForProc(
        exec,
        id,
        (Map<String, dynamic> p) => p['state'] == BackgroundStates.exited,
      );
      expect(
        await File('$stateDir/exit/$id').readAsString(),
        '0',
      );
    });
  }, skip: posixSkipReason);
}
