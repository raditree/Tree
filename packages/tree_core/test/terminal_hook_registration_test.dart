import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 回归：**后台 hook（`terminal hook=true`）必须登记进「正在执行的 tool」登记表**。
///
/// 病根（2026-10-04，known-issues #25）：`WorkspaceToolRunner` 构造体里
/// `TerminalHooks(toolRuns: toolRuns)` 裸写了形参名——它解析到**同名形参**，而生产调用方
/// （`tree_core_cli/bin/tree_core.dart`）**不传** `toolRuns:` ⇒ 恒为 null，不是已初始化成
/// `ToolRunRegistry.instance` 的字段 `this.toolRuns`。
///
/// 后果：后台 hook **从不登记** ⇒ 右栏「正在执行的 tool」看不到、关不掉；agent 自己的
/// `tool_runs action=list` 同样看不到（只有它自己那次调用可见）。
///
/// **为什么要单独一个文件**：既有用例都是 `TerminalHooks(toolRuns: registry)` **直接**
/// 构造 hook 管理器（如 `terminal_hooks_ssh_test.dart`），正好绕过了这处"接线"。
/// 本用例刻意**穿过生产接线**——`WorkspaceToolRunner` 且**不传** `toolRuns:`，
/// 它炸掉才算钉住了生产路径。
void main() {
  const String agent = 'agt_hook_reg';
  const String session = 'ses_hook_reg';

  /// 本机"跑很久"的命令（与 `tool_run_registry_test.dart` 同口径）。
  String longCommand(int seconds) =>
      Platform.isWindows ? 'Start-Sleep -Seconds $seconds' : 'sleep $seconds';

  late Directory temp;
  late String workspace;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_hook_reg_');
    workspace = p.join(temp.path, 'ws');
    Directory(workspace).createSync(recursive: true);
  });

  tearDown(() async {
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
  });

  test('生产接线：hooks 用的就是 runner 那张登记表（不是构造形参）', () {
    final WorkspaceToolRunner runner = WorkspaceToolRunner(
      resolveWorkspaceDir: (String _) => workspace,
    );
    addTearDown(runner.close);

    expect(
      runner.hooks.toolRuns,
      isNotNull,
      reason: '不传 toolRuns 时必须回退到进程级唯一那份（ToolRunRegistry.instance）',
    );
    expect(
      identical(runner.hooks.toolRuns, runner.toolRuns),
      isTrue,
      reason: 'hooks 与 REST 快照 / tool_runs 必须读**同一份**表',
    );
    expect(
      identical(runner.hooks.toolRuns, ToolRunRegistry.instance),
      isTrue,
      reason: '生产默认就是进程级唯一那份',
    );
  });

  test('hook=true 的后台任务登记在表里（watchdog:false + crossCall:true），且关得掉', () async {
    final WorkspaceToolRunner runner = WorkspaceToolRunner(
      resolveWorkspaceDir: (String _) => workspace,
    );
    addTearDown(runner.close);

    final ToolOutcome outcome = await runner.run(
      ToolInvocation(
        id: 'call-hook-1',
        name: 'terminal',
        arguments: <String, dynamic>{
          'command': longCommand(60),
          'hook': true,
        },
        agentId: agent,
        sessionId: session,
      ),
    );
    expect(outcome.isError, isFalse);
    expect(outcome.content, contains('[terminal hook] 已在后台启动'));
    expect(outcome.content, contains('task_id'));

    // ① 登记项必须在（后台 hook 跨工具调用存活）
    final List<ToolRun> runs = runner.toolRuns.list();
    expect(
      runs,
      hasLength(1),
      reason: '后台 hook 必须出现在登记表里（右栏「正在执行的 tool」/ tool_runs 的数据源）',
    );
    final ToolRun run = runs.single;
    expect(run.tool, 'terminal');
    expect(run.agentId, agent);
    expect(run.sessionId, session);
    expect(run.watchdog, isFalse, reason: '长任务不判超时、不刷 warning');
    expect(run.crossCall, isTrue, reason: '发起调用早已返回，任务还在跑');
    expect(
      run.overThreshold(runner.toolRuns.threshold),
      isFalse,
      reason: 'hook 永不进 stuck_tools',
    );

    // ② 关得掉：登记表的关闭 = 取消该 hook（本机真杀进程树）
    expect(runner.hooks.tasks, hasLength(1));
    final HookTask task = runner.hooks.tasks.single;
    final ToolCloseOutcome closed = await runner.toolRuns.close(run.handle);
    expect(closed.closed, isTrue);
    expect(closed.tool, 'terminal');
    expect(
      closed.note,
      contains('已终止本机后台进程树'),
      reason: '必须**真的**终止了本机后台进程，而不是"没杀到却说关掉了"',
    );
    expect(runner.toolRuns.length, 0, reason: '关闭后登记项即刻移除');

    final DateTime deadline = DateTime.now().add(const Duration(seconds: 15));
    while (task.running && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(task.running, isFalse, reason: '被终止的进程要收尾，任务不再在途');
    expect(task.cancelled, isTrue, reason: '如实标记"已按关闭请求终止"');
  });
}
