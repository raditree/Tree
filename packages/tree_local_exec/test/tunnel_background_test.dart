import 'dart:async';

import 'package:test/test.dart';
import 'package:tree_local_exec/tree_local_exec.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

/// 假传输：实现 `SshTransport`（全部方法都给最小实现），**并按需实现** `TunnelBackgroundExec`
/// —— 用它钉住"有托管能力走托管、没有就走 nohup"这条选路，以及托管句柄的各种收尾语义。
class FakeTransport
    implements SshTransport, TunnelBackgroundExec, FallbackableWorkspace {
  FakeTransport({this.managed = true, this.root = '/ws'});

  final bool managed;
  final String root;

  /// 所有 `run(...)` 命令（用来断言 nohup 路径 vs 托管路径）。
  final List<String> commands = <String>[];

  final Map<String, TunnelBackgroundProc> procs = <String, TunnelBackgroundProc>{};
  int spawnCalls = 0;
  int killCalls = 0;

  /// `queryBackground` 被调了几次（用来断言"断连期间不猛戳"）。
  int queryCalls = 0;

  /// 中转站是否已判死（驱动 `FallbackableWorkspace`）。
  bool dead = false;

  /// 下一次 query 抛这个（一次性）。
  Object? nextQueryError;

  /// **每一拍**都抛这个（模拟"链路一直断着"；置 null 恢复）。
  Object? alwaysQueryError;

  @override
  bool get tunnelDown => dead;

  @override
  String get fallbackReason => dead ? '测试：判死' : '';

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
  Future<List<TunnelBackgroundProc>> listBackground() async {
    final Object? err = alwaysQueryError;
    if (err != null) throw err;
    return procs.values.toList();
  }

  @override
  Future<TunnelBackgroundProc?> queryBackground(String id) async {
    queryCalls++;
    final Object? always = alwaysQueryError;
    if (always != null) throw always;
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

    test('断链（还在退避重连）**不**发结束通知，链路回来后仍拿到真相', () async {
      final FakeTransport transport = FakeTransport();
      // 注入短间隔：生产是 30s，用例里等不起
      final SshWorkspaceIO io = SshWorkspaceIO(
        '/ws',
        transport,
        backgroundStalePollInterval: const Duration(milliseconds: 150),
      );
      final BackgroundExecHandle handle = await io.startBackground(
        command: 'x',
        logRelativePath: 'a.log',
      );
      final Future<int> code = handle.exitCode;
      // 第一拍：链路断着（还在退避重连、**没判死**）
      transport.alwaysQueryError = SshLinkStaleException('链路失活');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(
        code,
        isA<Future<int>>(),
        reason: '断连期间**不许**收尾（收了就等于发"可能结束"的通知——那是假装知道）',
      );
      // 链路回来：真相（退出码）照样拿得到
      transport.alwaysQueryError = null;
      transport.procs['bg-1'] = TunnelBackgroundProc(
        id: 'bg-1',
        logPath: '/ws/a.log',
        state: BackgroundStates.exited,
        exitCode: 7,
      );
      expect(await code.timeout(const Duration(seconds: 10)), 7);
      await handle.close();
    });

    test('断连期间**不猛戳**：探测节奏交给中转站的退避，核心侧不按 3s 重试', () async {
      final FakeTransport transport = FakeTransport();
      final SshWorkspaceIO io = SshWorkspaceIO(
        '/ws',
        transport,
        // 断连间隔故意设成 1s：若实现还在用 3s 周期或更密的节奏，下面的计数会露馅
        backgroundStalePollInterval: const Duration(seconds: 1),
      );
      final BackgroundExecHandle handle = await io.startBackground(
        command: 'x',
        logRelativePath: 'a.log',
      );
      transport.alwaysQueryError = SshLinkStaleException('链路失活');
      unawaited(handle.exitCode);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(
        transport.queryCalls,
        1,
        reason: '600ms 内只该有**首次那一拍**（断连间隔 1s）；'
            '按 3s 周期重写这段会变成 0，按更密的重试会变成多条',
      );
      await handle.close();
    });

    test('退避耗尽（判死）⇒ 以显式错误收尾（一次性），此后**不再重试**', () async {
      final FakeTransport transport = FakeTransport();
      final SshWorkspaceIO io = SshWorkspaceIO(
        '/ws',
        transport,
        backgroundStalePollInterval: const Duration(milliseconds: 150),
      );
      final BackgroundExecHandle handle = await io.startBackground(
        command: 'x',
        logRelativePath: 'a.log',
      );
      transport.alwaysQueryError = SshLinkStaleException('链路失活');
      final Future<int> code = handle.exitCode;
      // 第一拍之后中转站判死
      await Future<void>.delayed(const Duration(milliseconds: 200));
      transport.dead = true;
      await expectLater(
        code,
        throwsA(
          isA<SshLinkStaleException>().having(
            (SshLinkStaleException e) => e.message,
            'message',
            // 2026-10-15 文案降级：判死只说明"本轮未能取回退出码"，不再断言"目标主机关闭/不可达"
            //（健康链路读不到终态也会到这）。
            allOf(
              contains('未能取回'),
              contains('不要大量重试'),
              isNot(contains('可能目标主机关闭')),
            ),
          ),
        ),
      );
      final int callsAtDeath = transport.queryCalls;
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(
        transport.queryCalls,
        callsAtDeath,
        reason: '判死之后**不许**再探测（退避已耗尽，再戳也不会变好）',
      );
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
