import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// 假 SSH 传输：只实现后台 hook 用例需要的那部分（其余显式未实现）。
///
/// 本机没有 sshd（见 `docs/known-issues.md`），所以远端后台这一支**只能**用假链路
/// 验证"命令形状 / 轮询语义 / 唤醒与接续"；真 dartssh2 链路不在本仓库可验范围内。
class _FakeSsh implements SshTransport {
  final List<String> commands = <String>[];
  SshExecResult Function(String command)? onRun;
  bool closed = false;

  @override
  Future<SshExecResult> run(
    String command, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    commands.add(command);
    return onRun?.call(command) ??
        const SshExecResult(exitCode: 0, stdout: '', stderr: '');
  }

  @override
  final SshLiveness liveness = SshLiveness();

  /// 显式重连：这组用例只关心后台 hook 的台账语义，不涉及"失活后重建"，
  /// 所以这里只清失活标记并记账（真实现见 `dartssh_transport.dart`）。
  int reconnects = 0;

  @override
  Future<void> reconnect() async {
    reconnects++;
    liveness.reset();
  }

  @override
  Future<void> close() async => closed = true;

  // ── 后台 hook 用例不涉及的文件 / 终端操作（显式未实现，别静默成功）──────
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

const String _running = '__TREE_RUNNING__';
const String _gone = '__TREE_GONE__';
const String _pidReply = '4242\n';

SshExecResult _reply(String stdout, [int code = 0]) =>
    SshExecResult(exitCode: code, stdout: stdout, stderr: '');

void main() {
  late _FakeSsh transport;
  late SshWorkspaceIO sshIo;

  setUp(() {
    transport = _FakeSsh();
    sshIo = SshWorkspaceIO('/home/u/proj', transport);
  });

  test('远端后台 hook：启动即返回 → 轮询到结束 → 唤醒（含退出码与日志路径）', () async {
    final TerminalHooks hooks = TerminalHooks();
    addTearDown(hooks.close);
    final Completer<String> woken = Completer<String>();
    hooks.onFinished = (HookTask task, int code) async {
      if (!woken.isCompleted) woken.complete(await hookNotice(task, code));
    };
    int probes = 0;
    transport.onRun = (String command) {
      if (command.contains('nohup')) return _reply(_pidReply);
      probes++;
      return probes == 1 ? _reply('$_running\n') : _reply('7\n');
    };

    final HookTask task = await hooks.start(
      io: sshIo,
      agentId: 'agt_1',
      sessionId: 'ses_1',
      command: 'python train.py',
    );
    expect(task.remote, isTrue, reason: '日志与进程都在远端');
    expect(task.running, isTrue, reason: '启动即返回，不等待远端命令结束');
    expect(task.logRelative, startsWith('.output/'));
    expect(task.handle?.pid, 4242);

    final String notice = await woken.future.timeout(const Duration(seconds: 30));
    expect(notice, contains('[terminal hook] 后台命令已结束'));
    expect(notice, contains('task_id: ${task.id}'));
    expect(notice, contains('退出码 7'));
    expect(notice, contains(task.logRelative));
    expect(notice, contains('远端工作空间'), reason: '如实说明日志在远端');
    expect(task.exitCode, 7);
    expect(task.running, isFalse);
  });

  test('远端进程消失且没留退出码 ⇒ 可辨退出码 + 提示如实（不假装正常退出）', () async {
    final TerminalHooks hooks = TerminalHooks();
    addTearDown(hooks.close);
    final Completer<String> woken = Completer<String>();
    hooks.onFinished = (HookTask task, int code) async {
      if (!woken.isCompleted) woken.complete(await hookNotice(task, code));
    };
    transport.onRun = (String command) =>
        command.contains('nohup') ? _reply(_pidReply) : _reply('$_gone\n');

    final HookTask task = await hooks.start(
      io: sshIo,
      agentId: 'agt_1',
      sessionId: 'ses_1',
      command: 'python train.py',
    );
    final String notice = await woken.future.timeout(const Duration(seconds: 20));
    expect(task.exitCode, BackgroundExecHandle.goneExitCode);
    expect(notice, contains('没有留下退出码'));
    expect(notice, contains('不要直接重跑'));
  });

  test('链路判失活：记 remoteFailureExitCode，不假装知道远端状态', () async {
    final TerminalHooks hooks = TerminalHooks();
    addTearDown(hooks.close);
    final Completer<String> woken = Completer<String>();
    hooks.onFinished = (HookTask task, int code) async {
      if (!woken.isCompleted) woken.complete(await hookNotice(task, code));
    };
    transport.onRun = (String command) {
      if (command.contains('nohup')) return _reply(_pidReply);
      throw SshLinkStaleException('心跳连续丢失');
    };

    final HookTask task = await hooks.start(
      io: sshIo,
      agentId: 'agt_1',
      sessionId: 'ses_1',
      command: 'python train.py',
    );
    final String notice = await woken.future.timeout(const Duration(seconds: 20));
    expect(task.exitCode, TerminalHooks.remoteFailureExitCode);
    expect(notice, contains('链路判失活'));
  });

  test('cancel：拿得到远端 pid 就发 kill；拿不到时如实说明为什么杀不掉', () async {
    final TerminalHooks hooks = TerminalHooks();
    addTearDown(hooks.close);
    transport.onRun = (String command) {
      if (command.contains('nohup')) return _reply(_pidReply);
      if (command.contains('kill -TERM')) return _reply('done\n');
      return _reply('$_running\n');
    };
    final HookTask task = await hooks.start(
      io: sshIo,
      agentId: 'agt_1',
      sessionId: 'ses_1',
      command: 'python train.py',
    );
    expect(await hooks.cancel(task.id), isTrue);
    expect(task.cancelled, isTrue);
    expect(
      transport.commands.any((String c) => c.contains('kill -TERM')),
      isTrue,
    );
    // 远端进程不归本机管：取消只表示"发出了终止"，任务仍在运行是**如实**的
    expect(task.running, isTrue);
    expect(await hooks.cancel('hook_不存在'), isFalse);
  });

  test('右栏「正在执行的 tool」：hook 出现在快照里，用户关闭 = 取消该 hook', () async {
    final ToolRunRegistry registry = ToolRunRegistry();
    final TerminalHooks hooks = TerminalHooks(toolRuns: registry);
    addTearDown(hooks.close);
    int kills = 0;
    transport.onRun = (String command) {
      if (command.contains('nohup')) return _reply(_pidReply);
      if (command.contains('kill -TERM')) {
        kills++;
        return _reply('done\n');
      }
      return _reply('$_running\n');
    };

    await hooks.start(
      io: sshIo,
      agentId: 'agt_1',
      sessionId: 'ses_1',
      command: 'python train.py',
    );
    final Map<String, dynamic> snapshot = registry.snapshot();
    final List<dynamic> runs = snapshot['runs'] as List<dynamic>;
    expect(runs, hasLength(1));
    final Map<String, dynamic> row = runs.single as Map<String, dynamic>;
    expect(row['tool'], 'terminal');
    expect(row['agent_id'], 'agt_1');
    expect(
      row['over_threshold'],
      isFalse,
      reason: '后台 hook 是长任务：不判超时、不刷 warning',
    );
    expect(row['command_preview'], contains('python train.py'));

    final ToolCloseOutcome outcome = await registry.close(
      row['handle'] as String,
    );
    expect(outcome.closed, isTrue);
    expect(outcome.note, contains('已请求终止远端后台命令'));
    expect(kills, 1);
    expect(registry.length, 0, reason: '关闭后从登记表移除');

    // 任务结束（哨兵出现）时登记项**不会**再被重复收尾（幂等）
    expect(hooks.runningCount, 1);
  });

  test('落盘台账 + 重启接续：应用不在运行时跑完 ⇒ 启动即收尾并投递回原会话', () async {
    final Directory dir = Directory.systemTemp.createTempSync('tree_hook_ledger_');
    addTearDown(() async {
      // Windows 上刚删过的句柄可能还短暂占用：重试几次
      for (int i = 0; i < 10 && dir.existsSync(); i++) {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });
    final HookLedger ledger = HookLedger(dir.path);

    // ① 第一次运行：远端任务还在跑（哨兵没出现）⇒ 台账落盘
    final TerminalHooks first = TerminalHooks(ledger: ledger);
    transport.onRun = (String command) =>
        command.contains('nohup') ? _reply(_pidReply) : _reply('$_running\n');
    final HookTask task = await first.start(
      io: sshIo,
      agentId: 'agt_1',
      sessionId: 'ses_1',
      command: 'python train.py',
    );
    final List<HookLedgerEntry> saved = await ledger.load();
    expect(saved, hasLength(1));
    expect(saved.single.id, task.id);
    expect(saved.single.sessionId, 'ses_1');
    expect(saved.single.pid, 4242);
    // 关应用：远端**不杀**、台账**保留**（下次启动接续）
    await first.close();
    expect(await ledger.load(), hasLength(1));

    // ② 第二次运行（应用重启）：哨兵已经在 ⇒ 接续时立刻收尾并投递回原会话；
    //    `commands` 清空，用来断言"接续**绝不重跑**命令"（只有探测）。
    transport.commands.clear();
    final TerminalHooks second = TerminalHooks(ledger: ledger);
    addTearDown(second.close);
    final Completer<List<String>> woken = Completer<List<String>>();
    second.onFinished = (HookTask t, int code) async {
      if (!woken.isCompleted) {
        woken.complete(<String>[t.agentId, t.sessionId, await hookNotice(t, code)]);
      }
    };
    transport.onRun = (String command) => _reply('0\n');
    final int resumed = await second.restorePending(
      ioFor: (String agentId) async => agentId == 'agt_1' ? sshIo : null,
    );
    expect(resumed, 1);
    final List<String> delivered = await woken.future.timeout(
      const Duration(seconds: 15),
    );
    expect(delivered[0], 'agt_1');
    expect(delivered[1], 'ses_1', reason: '完成提示投递回**原会话**');
    expect(delivered[2], contains('退出码 0'));
    expect(await ledger.load(), isEmpty, reason: '收尾后台账删除');
    // 接续**绝不重跑命令**：这一轮只有探测，没有 nohup
    expect(
      transport.commands.any((String c) => c.contains('nohup')),
      isFalse,
      reason: '接续不重跑远端命令',
    );
  });

  test('接续：工作空间不可用（agent 已删除 / SSH 配置缺失）⇒ 如实记日志、台账保留', () async {
    final Directory dir = Directory.systemTemp.createTempSync('tree_hook_ledger_');
    addTearDown(() async {
      for (int i = 0; i < 10 && dir.existsSync(); i++) {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });
    final List<String> logs = <String>[];
    final HookLedger ledger = HookLedger(dir.path);
    await ledger.save(
      const HookLedgerEntry(
        id: 'hook_x_1',
        agentId: 'agt_gone',
        sessionId: 'ses_1',
        command: 'python train.py',
        logRelative: '.output/hook_x_1.log',
        pid: 5,
        startedAt: 1700000000000,
      ),
    );
    final TerminalHooks hooks = TerminalHooks(ledger: ledger, log: logs.add);
    addTearDown(hooks.close);
    bool woke = false;
    hooks.onFinished = (HookTask t, int code) async => woke = true;

    final int resumed = await hooks.restorePending(
      ioFor: (String agentId) async => null,
    );
    expect(resumed, 0);
    expect(woke, isFalse, reason: '拿不到工作空间就不假装投递成功');
    expect(
      logs.any((String line) => line.contains('工作空间不可用')),
      isTrue,
      reason: '如实记录，不静默',
    );
    expect(await ledger.load(), hasLength(1), reason: '台账保留，等 agent 回来后再说');
    expect(hooks.tasks, isEmpty);
  });
}
