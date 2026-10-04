import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// terminal 软超时用例用的"跑很久"的命令（本地路径）。
String _longCommand(int seconds) =>
    Platform.isWindows ? 'Start-Sleep -Seconds $seconds' : 'sleep $seconds';

/// 本地命令软超时 → hook 模式（2026-10-02 遗留项）。
void main() {
  late Directory root;
  late LocalWorkspaceIO io;
  late TerminalHooks hooks;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tree_soft_hook_');
    io = LocalWorkspaceIO(root.path);
    hooks = TerminalHooks();
  });

  tearDown(() async {
    await hooks.close();
    for (int i = 0; i < 10 && root.existsSync(); i++) {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
  });

  ToolInvocation call(Map<String, dynamic> args) => ToolInvocation(
    id: 'tool_1',
    name: BuiltinTools.terminal,
    arguments: args,
    rawArguments: '',
    agentId: 'agt_1',
    sessionId: 'ses_1',
  );

  test('本地命令软超时 ⇒ 转后台：进程保留、可取消、结束回调唤醒', () async {
    final Completer<String> woken = Completer<String>();
    hooks.onFinished = (HookTask task, int code) async {
      if (!woken.isCompleted) woken.complete(await hookNotice(task, code));
    };
    final ToolOutcome outcome = await BuiltinTools.run(
      call(<String, dynamic>{
        'command': _longCommand(30),
        'timeout_seconds': 1,
      }),
      io,
      hooks: hooks,
    );
    expect(outcome.isError, isFalse, reason: '转后台不是失败');
    expect(outcome.content, contains('已转后台'));
    expect(outcome.content, contains('直接结束本轮'));
    expect(hooks.runningCount, 1);

    final HookTask task = hooks.tasks.single;
    expect(task.detached, isFalse, reason: '本机进程有句柄：不是"失联转来的"');
    expect(task.handle, isNotNull);
    expect(task.running, isTrue);

    // 取消（杀整棵进程树）→ 结束回调唤醒 agent
    expect(await hooks.cancel(task.id), isTrue);
    final String notice = await woken.future.timeout(
      const Duration(seconds: 20),
    );
    expect(notice, contains('[terminal hook] 后台命令已结束'));
    expect(task.exitCode, isNot(0));
    final String log = File(io.resolve(task.logRelative)).readAsStringSync();
    expect(log, contains('转后台'));
    expect(log, contains('（完整输出）'));
    expect(log, contains('结束：退出码'));
  });

  test('提示词说清 hook 模式：可做别的事 / 可直接结束本轮 / 会被唤醒', () {
    final ToolSpec spec = BuiltinTools.specs().firstWhere(
      (ToolSpec s) => s.name == BuiltinTools.terminal,
    );
    expect(spec.description, contains('直接结束本轮'));
    expect(spec.description, contains('唤醒'));
    final Map<String, dynamic> props =
        spec.parameters['properties'] as Map<String, dynamic>;
    expect(props.containsKey('timeout_seconds'), isTrue);
    final Map<String, dynamic> hook = props['hook'] as Map<String, dynamic>;
    expect(hook['description'], contains('结束本轮'));
  });

  test('hook=true 的回复同样说明"可以直接结束本轮等唤醒"', () async {
    final ToolOutcome outcome = await BuiltinTools.run(
      call(<String, dynamic>{'command': 'echo hi', 'hook': true}),
      io,
      hooks: hooks,
    );
    expect(outcome.content, contains('直接结束本轮'));
    expect(outcome.content, contains('唤醒'));
  });
}
