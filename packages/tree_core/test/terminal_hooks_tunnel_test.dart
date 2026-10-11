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
class _FakeTunnelSsh
    implements SshTransport, TunnelBackgroundExec, FallbackableWorkspace {
  final List<String> spawnedCommands = <String>[];
  String? logPath;
  String state = BackgroundStates.running;
  int? exitCode;

  /// 中转站是否已判死（退避耗尽）。
  bool dead = false;

  /// 每一拍都抛这个（模拟"链路一直断着"）。
  Object? alwaysQueryError;

  @override
  bool get tunnelDown => dead;

  @override
  String get fallbackReason => dead ? '测试：判死' : '';

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
  Future<TunnelBackgroundProc?> queryBackground(String id) async {
    final Object? err = alwaysQueryError;
    if (err != null) throw err;
    return id == 'bg-1' ? _proc() : null;
  }

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
  /// 判死（退避耗尽）后**台账留着**，链路恢复后能**认领回来**、给出真实结局
  /// （用户 2026-10-11 明确要求："失活即失败"照旧，但重连后该 hook 要回来）。
  ///
  /// "判死收尾但台账保留"这一条由本文件另一条用例（"退避耗尽（判死）⇒ 回一条**失联**提醒"）
  /// 直接钉住；这里钉的是**接回来**这一段：挂账的条目能被 `restorePending(agentId:)` 认领，
  /// 拿到的退出码来自**目标机落盘台账**（不是本机猜的），且认领后台账才被清掉。
  test('挂账的任务在链路恢复后能被认领回来，并给出真实退出码', () async {
    final Directory dir = Directory.systemTemp.createTempSync('tree_hook_adopt_');
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
    final _FakeTunnelSsh transport = _FakeTunnelSsh()
      ..state = BackgroundStates.exited
      ..exitCode = 0
      // 认领靠"按日志路径从台账里认出那条任务"⇒ 假远端也要在同一个绝对路径上报到
      ..logPath = '/ws/.output/hook_1791683373134_1.log';
    final SshWorkspaceIO io = SshWorkspaceIO('/ws', transport);
    // 挂账的那一条（判死时留下的：命令、日志相对路径、归属都要在）
    await ledger.save(HookLedgerEntry(
      id: 'hook_1791683373134_1',
      agentId: 'agt_1',
      sessionId: 'ses_1',
      command: 'python train.py',
      logRelative: '.output/hook_1791683373134_1.log',
      startedAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
    ));
    final TerminalHooks hooks = TerminalHooks(ledger: ledger);
    addTearDown(hooks.close);
    final List<String> notices = <String>[];
    hooks.onFinished = (HookTask t, int code) async {
      notices.add('${t.id}|$code');
    };

    final List<String> spawnedBefore = List<String>.from(transport.spawnedCommands);
    final int resumed = await hooks.restorePending(
      ioFor: (String agentId) async => agentId == 'agt_1' ? io : null,
      agentId: 'agt_1',
    );
    expect(resumed, 1, reason: '挂账的那条要被认领回来');

    // 认领 = **对账**，不是重跑：等它按落盘台账收尾
    final Stopwatch wait = Stopwatch()..start();
    while (notices.isEmpty && wait.elapsed < const Duration(seconds: 20)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(notices, hasLength(1), reason: '认领后要投一次结局');
    expect(notices.single, 'hook_1791683373134_1|0', reason: '退出码来自目标机落盘台账');
    expect(
      transport.spawnedCommands,
      spawnedBefore,
      reason: '接回来只对账，**绝不重跑**命令',
    );
    expect(await ledger.load(), isEmpty, reason: '拿到真实结局才删台账');
  });

  test('restorePending 的 agent 过滤：别的 agent 的挂账不动', () async {
    final Directory dir = Directory.systemTemp.createTempSync('tree_hook_filter_');
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
    // 两条挂账，分属两个 agent
    for (final String agent in <String>['agt_1', 'agt_2']) {
      await ledger.save(HookLedgerEntry(
        id: 'hook_$agent',
        agentId: agent,
        sessionId: 'ses_1',
        command: 'echo $agent',
        logRelative: '.output/$agent.log',
        startedAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
      ));
    }
    final _FakeTunnelSsh transport = _FakeTunnelSsh()
      ..state = BackgroundStates.exited
      ..exitCode = 0
      ..logPath = '/ws/.output/agt_1.log';
    final SshWorkspaceIO io = SshWorkspaceIO('/ws', transport);
    final TerminalHooks hooks = TerminalHooks(ledger: ledger);
    addTearDown(hooks.close);
    final List<String> finished = <String>[];
    hooks.onFinished = (HookTask t, int code) async => finished.add(t.id);

    final int resumed = await hooks.restorePending(
      ioFor: (String agentId) async => io,
      agentId: 'agt_1',
    );
    expect(resumed, 1, reason: '只认领 agt_1 名下的那条');
    // 等 agt_1 那条按落盘台账收尾（收尾时才清它自己的台账）
    final Stopwatch wait = Stopwatch()..start();
    while (finished.isEmpty && wait.elapsed < const Duration(seconds: 20)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(finished, <String>['hook_agt_1'], reason: '只有 agt_1 那条被认领');
    final List<HookLedgerEntry> left = await ledger.load();
    expect(left, hasLength(1));
    expect(left.single.agentId, 'agt_2', reason: '别的 agent 的挂账不许被顺手认领');
  });

  test('挂账被召回时**要告知**：一条"链路已恢复 + 已召回清单"的提示（用户 2026-10-11 要求）', () async {
    final Directory dir = Directory.systemTemp.createTempSync('tree_hook_recall_');
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
    // 目标机上**还在跑**（state = running）⇒ 认领后继续挂着等真实结局
    final _FakeTunnelSsh transport = _FakeTunnelSsh()
      ..logPath = '/ws/.output/hook_recall_1.log';
    final SshWorkspaceIO io = SshWorkspaceIO('/ws', transport);
    await ledger.save(
      HookLedgerEntry(
        id: 'hook_recall_1',
        agentId: 'agt_1',
        sessionId: 'ses_1',
        command: 'sleep 10800',
        logRelative: '.output/hook_recall_1.log',
        startedAt: DateTime(2026, 1, 1).millisecondsSinceEpoch,
      ),
    );
    final TerminalHooks hooks = TerminalHooks(ledger: ledger);
    addTearDown(hooks.close);
    final List<String> announced = <String>[];
    hooks.onRecalled = (List<HookTask> group) async {
      announced.add(recalledNotice(group));
    };

    final int resumed = await hooks.restorePending(
      ioFor: (String agentId) async => io,
      agentId: 'agt_1',
    );
    expect(resumed, 1);
    expect(announced, hasLength(1), reason: '召回必须告知（不许静默接回来）');
    final String text = announced.single;
    expect(text, contains('SSH 链路已恢复'));
    expect(text, contains('已召回 1 个'));
    expect(text, contains('hook_recall_1'));
    expect(text, contains('sleep 10800'));
    expect(text, contains('.output/hook_recall_1.log'));
    expect(text, contains('没有重跑'), reason: '文案要写明"没重跑、没新起进程"');
    expect(await ledger.load(), hasLength(1), reason: '它还在跑 ⇒ 台账留着，等真实退出码');
  });

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

  test('退避耗尽（判死）⇒ 回一条**失联**提醒：可能目标主机关闭、不要大量重试', () async {
    final Directory dir = Directory.systemTemp.createTempSync('tree_hook_dead_');
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
    final SshWorkspaceIO io = SshWorkspaceIO(
      '/ws',
      transport,
      // 断连间隔注短：生产 30s，用例里等不起
      backgroundStalePollInterval: const Duration(milliseconds: 150),
    );

    final TerminalHooks hooks = TerminalHooks(ledger: ledger);
    addTearDown(hooks.close);
    final Completer<List<Object?>> told = Completer<List<Object?>>();
    hooks.onFinished = (HookTask t, int code) async {
      if (!told.isCompleted) {
        told.complete(<Object?>[t.agentId, t.sessionId, code, await hookNotice(t, code)]);
      }
    };

    // 起任务（第一拍成功 ⇒ running），随后链路断掉**并且**中转站判死
    await hooks.start(
      io: io,
      agentId: 'agt_1',
      sessionId: 'ses_1',
      command: 'python train.py',
    );
    transport
      ..alwaysQueryError = SshLinkStaleException('链路失活')
      ..dead = true;

    final List<Object?> delivered = await told.future.timeout(
      const Duration(seconds: 20),
    );
    expect(delivered[0], 'agt_1');
    expect(delivered[1], 'ses_1', reason: '提醒回到**原会话**');
    expect(
      delivered[2],
      TerminalHooks.remoteFailureExitCode,
      reason: '拿不到退出码 ⇒ 可辨的"失联"码，不假装正常结束',
    );
    final String notice = delivered[3]! as String;
    expect(notice, contains('失联'));
    // 文案里有 markdown 加固（`**目标主机关闭**`），所以断言取不带星号的那一段
    expect(notice, contains('目标主机关闭'));
    expect(notice, contains('不要大量重试'));
    expect(
      await ledger.load(),
      hasLength(1),
      reason: '2026-10-11 改口径：失联收尾**保留台账**（远端进程可能还在跑）——'
          '链路恢复 / 下次启动时由 `restorePending` 认领，拿到**真实**结局再删。'
          '一次任务最多因此多收到一条"其实已结束"的提醒，不会无限重复：'
          '真相一旦可判（exited / gone），认领即收尾并清台账。',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));
}
