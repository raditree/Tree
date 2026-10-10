import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';
// 后台任务状态的**唯一真源**（进制字符串手写必然与 agent 侧漂移）
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart'
    show BackgroundStates;

/// **隧道托管路径**下的后台 hook：核心重启 → 接上 → 回 hook 结束提醒。
///
/// 为什么单独一条（`terminal_hooks_ssh_test.dart` 已经覆盖了远端后台）：
/// 那里的假传输**只实现 `SshTransport`**，于是走的是内置 dartssh2 的
/// **`nohup` + 哨兵轮询**那条路（用例里 `command.contains('nohup')` 就是证据）。
/// 中转站接管之后后台任务走的是**另一条实现**：进程由目标机 agent 托管，
/// 退出码来自目标机**落盘台账**，接续靠"按日志路径从 `exec.list` 里认出那条任务"。
/// 两条路的接续语义不同（一个靠哨兵文件、一个靠台账对账），必须各钉一条。
///
/// 本用例覆盖：① 起任务走托管（**不起 nohup**）② 核心关不杀任务、台账保留
/// ③ 重启后 `restorePending` 只靠日志路径认领 ④ 拿到退出码后**回 hook 结束提醒**
/// ⑤ 接续**绝不重跑**命令。
class _FakeTunnelSsh implements SshTransport, TunnelBackgroundExec {
  final List<String> spawnedCommands = <String>[];
  String? logPath;
  String state = BackgroundStates.running;
  int? exitCode;

  @override
  Future<TunnelBackgroundStart> spawnBackground({
    required String command,
    required String logAbsolutePath,
  }) async {
    spawnedCommands.add(command);
    logPath = logAbsolutePath;
    return TunnelBackgroundStart(
      id: 'bg-1',
      logPath: logAbsolutePath,
      pid: 4242,
    );
  }

  @override
  Future<List<TunnelBackgroundProc>> listBackground() async =>
      <TunnelBackgroundProc>[_proc()];

  @override
  Future<TunnelBackgroundProc?> queryBackground(String id) async =>
      id == 'bg-1' ? _proc() : null;

  TunnelBackgroundProc _proc() => TunnelBackgroundProc(
    id: 'bg-1',
    logPath: logPath ?? '',
    state: state,
    pid: 4242,
    command: 'python train.py',
    exitCode: exitCode,
  );

  @override
  Future<bool> killBackground(String id) async => true;

  // ── SshTransport 里这组用例不需要的部分：显式未实现，别静默成功 ──────────
  @override
  final SshLiveness liveness = SshLiveness();
  @override
  Future<void> reconnect() async {}
  @override
  Future<void> close() async {}
  @override
  Future<SshExecResult> run(
    String command, {
    Duration timeout = Duration.zero,
  }) async => const SshExecResult(exitCode: 0, stdout: '', stderr: '');
  @override
  Future<List<int>> read(String absolutePath) => throw UnimplementedError();
  @override
  Future<void> write(String absolutePath, List<int> bytes) =>
      throw UnimplementedError();
  @override
  Future<int> size(String absolutePath) => throw UnimplementedError();
  @override
  Stream<List<int>> readStream(
    String absolutePath, {
    int offset = 0,
    int? length,
  }) => throw UnimplementedError();
  @override
  Future<void> writeStream(String absolutePath, Stream<List<int>> data) =>
      throw UnimplementedError();
  @override
  Future<List<String>> listFiles(String absolutePath, {int maxDepth = 2}) =>
      throw UnimplementedError();
  @override
  Future<List<SshFileEntry>> listEntries(
    String absolutePath, {
    int maxEntries = 2000,
  }) => throw UnimplementedError();
  @override
  Future<bool> exists(String absolutePath) => throw UnimplementedError();
  @override
  Future<void> delete(String absolutePath) => throw UnimplementedError();
  @override
  Future<void> makeDirectory(String absolutePath) =>
      throw UnimplementedError();
  @override
  Future<void> rename(String oldPath, String newPath) =>
      throw UnimplementedError();
  @override
  Future<void> remove(String absolutePath, {bool recursive = false}) =>
      throw UnimplementedError();
  @override
  Future<bool> isDirectory(String absolutePath) =>
      throw UnimplementedError();
  @override
  Future<SshShellChannel> openShell({
    required int columns,
    required int rows,
    String command = '',
    String workingDirectory = '',
  }) => throw UnimplementedError();
}

void main() {
  test('隧道托管：核心重启后接上任务，并把 hook 结束提醒回给**原会话**（且不重跑）', () async {
    final Directory dir = Directory.systemTemp.createTempSync('tree_hook_tunnel_');
    addTearDown(() async {
      for (int i = 0; i < 10 && dir.existsSync(); i++) {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });
    final HookLedger ledger = HookLedger(dir.path);
    final _FakeTunnelSsh transport = _FakeTunnelSsh();
    final SshWorkspaceIO io = SshWorkspaceIO('/ws', transport);

    // ① 第一次运行：起一条后台任务（走**托管**，不是 nohup）⇒ 台账落盘
    final TerminalHooks first = TerminalHooks(ledger: ledger);
    final HookTask task = await first.start(
      io: io,
      agentId: 'agt_1',
      sessionId: 'ses_1',
      command: 'python train.py',
    );
    expect(
      transport.spawnedCommands,
      <String>['python train.py'],
      reason: '走托管路径（有 TunnelBackgroundExec 能力就不该退化成 nohup）',
    );
    final List<HookLedgerEntry> saved = await ledger.load();
    expect(saved, hasLength(1));
    expect(saved.single.id, task.id);
    expect(saved.single.agentId, 'agt_1');
    expect(saved.single.sessionId, 'ses_1');

    // ② 关核心：任务**不杀**、台账**保留**（下次启动接续）
    await first.close();
    expect(await ledger.load(), hasLength(1), reason: '关核心不该清台账');

    // ③ 重启：目标机上的任务跑完了（退出码来自**落盘台账**，与核心是否活着无关）
    transport
      ..state = BackgroundStates.exited
      ..exitCode = 0;

    final TerminalHooks second = TerminalHooks(ledger: ledger);
    addTearDown(second.close);
    final Completer<List<String>> woken = Completer<List<String>>();
    second.onFinished = (HookTask t, int code) async {
      if (!woken.isCompleted) {
        woken.complete(<String>[
          t.agentId,
          t.sessionId,
          t.id,
          await hookNotice(t, code),
        ]);
      }
    };

    final List<String> spawnCallsBefore = List<String>.from(
      transport.spawnedCommands,
    );
    final int resumed = await second.restorePending(
      ioFor: (String agentId) async => agentId == 'agt_1' ? io : null,
    );
    expect(resumed, 1, reason: '应当认领 1 条台账');

    final List<String> delivered = await woken.future.timeout(
      const Duration(seconds: 20),
    );
    expect(delivered[0], 'agt_1');
    expect(delivered[1], 'ses_1', reason: '完成提示投递回**原会话**');
    expect(delivered[2], task.id, reason: '提醒挂在**原任务**上（id 不变）');
    expect(delivered[3], contains('退出码 0'), reason: '退出码来自台账');

    // ④ 接续**绝不重跑**：这一轮一次 spawn 都不该有
    expect(
      transport.spawnedCommands,
      spawnCallsBefore,
      reason: '接续只对账，不重跑命令',
    );
    expect(await ledger.load(), isEmpty, reason: '收尾后台账删除');
  }, timeout: const Timeout(Duration(seconds: 60)));
}
