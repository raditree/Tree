import 'dart:async';

import 'package:test/test.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

import 'fake_ssh_transport.dart';

/// SSH 侧 `exec(timeout:)` 的**软超时**（2026-10-03 修订）。
///
/// 与本地同一套语义（见 `exec_soft_timeout_test.dart`）：
/// - `timeout > 0` ⇒ 到点**不杀远端进程、不重跑、不关通道**，把仍在跑的命令交出来；
/// - `timeout <= 0`（含缺省）⇒ **永不软超时**（老行为：只有心跳判活）。
///
/// 活性判据仍是心跳：软超时之后链路被判失活，交接出去的句柄如实失败（不静默）。
///
/// 回归的现场事故：SSH 侧原先**忽略** `timeout_seconds`，模型写了一条自带 120 s
/// 超时的命令（两个 25 GB 全树 `find`）⇒ 工具永不返回 ⇒ 整批工具不结束 ⇒
/// teammate「发消息无反应」（见 `.self/recon-arch-stability.md` §2.7）。
void main() {
  late FakeSshTransport t;
  late SshWorkspaceIO io;

  setUp(() {
    t = FakeSshTransport();
    io = SshWorkspaceIO('/ws', t);
  });

  /// 跑一次 exec，把"仍在运行"的交接结果取出来（没抛出则返回 null）。
  Future<SshExecStillRunning?> execSoft(
    String command, {
    required Duration timeout,
  }) async {
    try {
      await io.exec(command, timeout: timeout);
      return null;
    } on SshExecStillRunning catch (error) {
      return error;
    }
  }

  test('timeout 到点后工具调用必须返回（不能无限期等）', () async {
    t.pendingRun = Completer<SshExecResult>(); // 远端命令"仍在跑"，不会自己结束
    final Future<ExecOutcome> pending = io.exec(
      'find /mnt/space -name x',
      timeout: const Duration(seconds: 1),
    );
    final Object? raced = await Future.any<Object?>(<Future<Object?>>[
      pending.then<Object?>(
        (ExecOutcome _) => 'returned',
        onError: (Object error) => error,
      ),
      Future<Object?>.delayed(
        const Duration(seconds: 3),
        () => 'still-waiting',
      ),
    ]);
    expect(
      raced,
      isNot('still-waiting'),
      reason: 'timeout 到点必须返回"仍在运行"的结果，而不是继续无限期等',
    );
  });

  test('软超时：约 1s 交出仍在运行的远端命令（没杀、没重跑、通道没关）', () async {
    t.pendingRun = Completer<SshExecResult>(); // 远端 `sleep 30` 还没结束
    final Stopwatch watch = Stopwatch()..start();
    final SshExecStillRunning? still = await execSoft(
      'sleep 30',
      timeout: const Duration(seconds: 1),
    );
    watch.stop();

    expect(still, isNotNull, reason: '到点仍在跑应当抛 SshExecStillRunning');
    expect(still!.command, 'sleep 30');
    expect(
      still.elapsed.inMilliseconds,
      greaterThanOrEqualTo(900),
      reason: '"已经等了多久" ≈ 软超时值',
    );
    expect(
      watch.elapsed.inMilliseconds,
      lessThan(5000),
      reason: '到点就返回：不是超时错误、也不是永久 hang',
    );
    expect(still.message, contains('没有终止它'));
    // 到点只是"不再等"：命令只发过一次（没重跑）、连接没关、链路也没被判死
    expect(t.commands.single, "cd '/ws' && sleep 30");
    expect(t.commands, hasLength(1));
    expect(t.closed, isFalse, reason: 'SSH 通道仍然开着（整条连接不关）');
    expect(t.liveness.isStale, isFalse, reason: '心跳仍是活性判据，没丢心跳就不判失活');

    // 句柄可继续收尾：远端命令**自然跑完**时给出退出码与完整输出
    expect(
      still.running.snapshotText(),
      contains('仍在运行'),
      reason: '远端 exec 一次性回包：结束前没有输出快照，如实说明',
    );
    t.pendingRun!.complete(
      const SshExecResult(
        exitCode: 7,
        stdout: 'remote out\n',
        stderr: 'warn\n',
      ),
    );
    final SshExecResult done = await still.running.result;
    expect(done.exitCode, 7, reason: '远端进程没被杀：它照常跑完并给出自己的退出码');
    expect(await still.running.exitCode, 7);
    expect(still.running.snapshotText(), contains('remote out'));
    expect(still.running.snapshotText(), contains('warn'));
  });

  test('命令在到点前结束 ⇒ 照常返回结果，不误报软超时', () async {
    t.onRun = (String _) =>
        const SshExecResult(exitCode: 0, stdout: 'fast', stderr: '');
    final ExecOutcome outcome = await io.exec(
      'echo fast',
      timeout: const Duration(seconds: 1),
    );
    expect(outcome.exitCode, 0);
    expect(outcome.stdout, 'fast');
    expect(outcome.timedOut, isFalse);
  });

  for (final ({String label, Duration value}) probe
      in <({String label, Duration value})>[
        (label: 'Duration.zero', value: Duration.zero),
        (label: '负数（调用方用它表达"关掉"）', value: const Duration(seconds: -1)),
      ]) {
    test('${probe.label} = 永不软超时：一直等到命令自然结束（老行为）', () async {
      t.pendingRun = Completer<SshExecResult>();
      final Future<ExecOutcome> pending = io.exec(
        'sleep 30',
        timeout: probe.value,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      t.pendingRun!.complete(
        const SshExecResult(exitCode: 0, stdout: 'late', stderr: ''),
      );
      final ExecOutcome outcome = await pending.timeout(
        const Duration(seconds: 10),
      );
      expect(outcome.exitCode, 0);
      expect(outcome.stdout, 'late', reason: '没有软超时，输出照常收全');
    });
  }

  test('缺省 timeout = Duration.zero（与本地同口径：永不软超时）', () async {
    t.pendingRun = Completer<SshExecResult>();
    final Future<ExecOutcome> pending = io.exec('sleep 30');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      t.timeouts.single,
      Duration.zero,
      reason: '缺省不软超时，且透传给传输层的也是零值',
    );
    t.pendingRun!.complete(
      const SshExecResult(exitCode: 0, stdout: 'default-ok', stderr: ''),
    );
    final ExecOutcome outcome = await pending.timeout(
      const Duration(seconds: 10),
    );
    expect(outcome.stdout, 'default-ok');
  });

  test('软超时后心跳仍是活性判据：链路判失活 ⇒ 句柄显式失败（不静默）', () async {
    t.pendingRun = Completer<SshExecResult>(); // 远端永远不回
    final SshExecStillRunning? still = await execSoft(
      'find /mnt/space -name x',
      timeout: const Duration(seconds: 1),
    );
    expect(still, isNotNull);

    for (int i = 0; i < 3; i++) {
      t.liveness.recordMiss(); // 连续 3 次心跳窗口没回包 ⇒ 判失活
    }
    await expectLater(
      still!.running.result,
      throwsA(
        isA<SshLinkStaleException>().having(
          (SshLinkStaleException e) => e.message,
          'message',
          contains('心跳丢失'),
        ),
      ),
    );
    expect(t.liveness.isStale, isTrue);
    expect(t.closed, isFalse, reason: '心跳丢失期间不关连接，也不杀远端进程');
  });
}
