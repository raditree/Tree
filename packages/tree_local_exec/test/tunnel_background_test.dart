import 'dart:async';

import 'package:test/test.dart';
import 'package:tree_local_exec/tree_local_exec.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

/// 假传输：实现 `SshTransport`（全部方法都给最小实现），**并按需实现** `TunnelBackgroundExec`
/// —— 用它钉住"有托管能力走托管、没有就走 nohup"这条选路，以及托管句柄的各种收尾语义。
class FakeTransport implements SshTransport, TunnelBackgroundExec {
  FakeTransport({this.managed = true, this.root = '/ws'});

  final bool managed;
  final String root;

  /// 所有 `run(...)` 命令（用来断言 nohup 路径 vs 托管路径）。
  final List<String> commands = <String>[];

  final Map<String, TunnelBackgroundProc> procs = <String, TunnelBackgroundProc>{};
  int spawnCalls = 0;
  int killCalls = 0;

  /// 下一次 query 抛这个（一次性）。
  Object? nextQueryError;

  /// 已"结束"的进程数（用于推进状态）。
  @override
  SshLiveness get liveness => _liveness;
  final SshLiveness _liveness = SshLiveness();

  @override
  Future<TunnelBackgroundStart> spawnBackground({
    required String command,
    required String logAbsolutePath,
  }) async {
    spawnCalls++;
    final String id = 'bg-$spawnCalls';
    procs[id] = TunnelBackgroundProc(
      id: id,
      logPath: logAbsolutePath,
      state: BackgroundStates.running,
      pid: 1000 + spawnCalls,
    );
    return TunnelBackgroundStart(
      id: id,
      logPath: logAbsolutePath,
      pid: 1000 + spawnCalls,
    );
  }

  @override
  Future<List<TunnelBackgroundProc>> listBackground() async =>
      procs.values.toList();

  @override
  Future<TunnelBackgroundProc?> queryBackground(String id) async {
    final Object? err = nextQueryError;
    if (err != null) {
      nextQueryError = null;
      throw err;
    }
    return procs[id];
  }

  @override
  Future<bool> killBackground(String id) async {
    killCalls++;
    return procs.containsKey(id);
  }

  // ── SshTransport（只有 run / liveness / reconnect / close 会被这条路用到）──

  @override
  Future<SshExecResult> run(String command, {Duration timeout = Duration.zero}) async {
    commands.add(command);
    // nohup 路径会 `echo $!`，这里回一个 pid
    return const SshExecResult(exitCode: 0, stdout: '4321\n', stderr: '');
  }

  @override
  Future<void> reconnect() async {}

  @override
  Future<void> close() async {}

  @override
  Future<List<int>> read(String absolutePath) async => <int>[];

  @override
  Future<void> write(String absolutePath, List<int> bytes) async {}

  @override
  Future<int> size(String absolutePath) async => 0;

  @override
  Stream<List<int>> readStream(String absolutePath, {int offset = 0, int? length}) =>
      const Stream<List<int>>.empty();

  @override
  Future<void> writeStream(String absolutePath, Stream<List<int>> data) async {}

  @override
  Future<List<String>> listFiles(String absolutePath, {int maxDepth = 2}) async =>
      <String>[];

  @override
  Future<List<SshFileEntry>> listEntries(String absolutePath, {int maxEntries = 5000}) async =>
      <SshFileEntry>[];

  @override
  Future<bool> exists(String absolutePath) async => false;

  @override
  Future<void> delete(String absolutePath) async {}

  @override
  Future<void> makeDirectory(String absolutePath) async {}

  @override
  Future<void> rename(String oldPath, String newPath) async {}

  @override
  Future<void> remove(String absolutePath, {bool recursive = false}) async {}

  @override
  Future<bool> isDirectory(String absolutePath) async => false;

  @override
  Future<SshShellChannel> openShell({
    required int columns,
    required int rows,
    String command = '',
    String workingDirectory = '',
  }) async => throw UnsupportedError('本用例不涉及 PTY');
}

/// 只有 `SshTransport`、**没有**托管能力的假传输（模拟内置 dartssh2 回退路径）。
class FakePlainTransport implements SshTransport {
  final List<String> commands = <String>[];

  @override
  SshLiveness get liveness => _liveness;
  final SshLiveness _liveness = SshLiveness();

  @override
  Future<SshExecResult> run(String command, {Duration timeout = Duration.zero}) async {
    commands.add(command);
    return const SshExecResult(exitCode: 0, stdout: '777\n', stderr: '');
  }

  @override
  Future<void> reconnect() async {}
  @override
  Future<void> close() async {}
  @override
  Future<List<int>> read(String absolutePath) async => <int>[];
  @override
  Future<void> write(String absolutePath, List<int> bytes) async {}
  @override
  Future<int> size(String absolutePath) async => 0;
  @override
  Stream<List<int>> readStream(String absolutePath, {int offset = 0, int? length}) =>
      const Stream<List<int>>.empty();
  @override
  Future<void> writeStream(String absolutePath, Stream<List<int>> data) async {}
  @override
  Future<List<String>> listFiles(String absolutePath, {int maxDepth = 2}) async => <String>[];
  @override
  Future<List<SshFileEntry>> listEntries(String absolutePath, {int maxEntries = 5000}) async =>
      <SshFileEntry>[];
  @override
  Future<bool> exists(String absolutePath) async => false;
  @override
  Future<void> delete(String absolutePath) async {}
  @override
  Future<void> makeDirectory(String absolutePath) async {}
  @override
  Future<void> rename(String oldPath, String newPath) async {}
  @override
  Future<void> remove(String absolutePath, {bool recursive = false}) async {}
  @override
  Future<bool> isDirectory(String absolutePath) async => false;
  @override
  Future<SshShellChannel> openShell({
    required int columns,
    required int rows,
    String command = '',
    String workingDirectory = '',
  }) async => throw UnsupportedError('本用例不涉及 PTY');
}

void main() {
  group('有托管能力 ⇒ 走 agent 托管（不再用 nohup + 哨兵轮询）', () {
    test('startBackground 调 spawnBackground，命令里**不出现** setsid nohup', () async {
      final FakeTransport transport = FakeTransport();
      final SshWorkspaceIO io = SshWorkspaceIO('/ws', transport);
      final BackgroundExecHandle handle = await io.startBackground(
        command: 'sleep 60',
        logRelativePath: '.tree/background/a.log',
      );
      expect(transport.spawnCalls, 1);
      expect(
        transport.commands.where((String c) => c.contains('nohup')),
        isEmpty,
        reason: '托管路径下不该再起 nohup（那是 dartssh2 回退路径的形状）',
      );
      expect(handle.remote, isTrue);
      expect(handle.pid, 1001);
      await handle.close();
    });

    test('exitCode 从台账收尾（running → exited）', () async {
      final FakeTransport transport = FakeTransport();
      final SshWorkspaceIO io = SshWorkspaceIO('/ws', transport);
      final BackgroundExecHandle handle = await io.startBackground(
        command: 'sleep 1',
        logRelativePath: 'a.log',
      );
      final Future<int> code = handle.exitCode;
      // 任务结束：台账把状态改成 exited + 退出码
      transport.procs['bg-1'] = TunnelBackgroundProc(
        id: 'bg-1',
        logPath: '/ws/a.log',
        state: BackgroundStates.exited,
        pid: 1001,
        exitCode: 42,
      );
      expect(await code, 42);
      await handle.close();
    });

    test('gone ⇒ 可辨退出码（不当正常退出）', () async {
      final FakeTransport transport = FakeTransport();
      final SshWorkspaceIO io = SshWorkspaceIO('/ws', transport);
      final BackgroundExecHandle handle = await io.startBackground(
        command: 'x',
        logRelativePath: 'a.log',
      );
      final Future<int> code = handle.exitCode;
      transport.procs['bg-1'] = TunnelBackgroundProc(
        id: 'bg-1',
        logPath: '/ws/a.log',
        state: BackgroundStates.gone,
      );
      expect(await code, BackgroundExecHandle.goneExitCode);
      await handle.close();
    });

    test('断链（SshLinkStale）**不**让 exitCode 失败，而是继续等 —— 这正是跨日稳定的来源', () async {
      final FakeTransport transport = FakeTransport();
      final SshWorkspaceIO io = SshWorkspaceIO('/ws', transport);
      final BackgroundExecHandle handle = await io.startBackground(
        command: 'x',
        logRelativePath: 'a.log',
      );
      final Future<int> code = handle.exitCode;
      // 第一拍：链路判失活（真相仍在目标机磁盘上）
      transport.nextQueryError = SshLinkStaleException('链路失活');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(code, isA<Future<int>>());
      // 链路回来后拿到真实退出码
      transport.procs['bg-1'] = TunnelBackgroundProc(
        id: 'bg-1',
        logPath: '/ws/a.log',
        state: BackgroundStates.exited,
        exitCode: 7,
      );
      expect(await code.timeout(const Duration(seconds: 10)), 7);
      await handle.close();
    });

    test('attachBackground 只给日志路径就能对账（核心重启接续）', () async {
      final FakeTransport transport = FakeTransport();
      transport.procs['bg-9'] = TunnelBackgroundProc(
        id: 'bg-9',
        logPath: '/ws/.tree/background/old.log',
        state: BackgroundStates.running,
        pid: 4242,
      );
      final SshWorkspaceIO io = SshWorkspaceIO('/ws', transport);
      final BackgroundExecHandle handle = await io.attachBackground(
        command: 'whatever',
        logRelativePath: '.tree/background/old.log',
      );
      final Future<int> code = handle.exitCode;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(transport.spawnCalls, 0, reason: '接续**不重跑、不新起**');
      transport.procs['bg-9'] = TunnelBackgroundProc(
        id: 'bg-9',
        logPath: '/ws/.tree/background/old.log',
        state: BackgroundStates.exited,
        exitCode: 0,
      );
      expect(await code.timeout(const Duration(seconds: 10)), 0);
      await handle.close();
    });

    test('cancel 走 exec.kill；台账里没有 ⇒ 如实 false', () async {
      final FakeTransport transport = FakeTransport();
      final SshWorkspaceIO io = SshWorkspaceIO('/ws', transport);
      final BackgroundExecHandle handle = await io.startBackground(
        command: 'x',
        logRelativePath: 'a.log',
      );
      expect(await handle.cancel(), isTrue);
      expect(transport.killCalls, 1);
      await handle.close();

      // 台账里没有这条：attach 之后 cancel 应如实 false
      final BackgroundExecHandle orphan = await io.attachBackground(
        command: 'x',
        logRelativePath: 'nope.log',
      );
      expect(await orphan.cancel(), isFalse);
      await orphan.close();
    });
  });

  group('没有托管能力 ⇒ 原样走 nohup + 哨兵轮询（回退路径行为不变）', () {
    test('startBackground 用 setsid nohup 形状', () async {
      final FakePlainTransport transport = FakePlainTransport();
      final SshWorkspaceIO io = SshWorkspaceIO('/ws', transport);
      final BackgroundExecHandle handle = await io.startBackground(
        command: 'sleep 5',
        logRelativePath: 'a.log',
      );
      expect(transport.commands, hasLength(1));
      expect(transport.commands.single, contains('setsid nohup'));
      expect(transport.commands.single, contains(r'echo $!'));
      expect(handle.pid, 777);
      expect(handle.remote, isTrue);
      // 关掉（远端不杀）
      await handle.close();
    });
  });
}
