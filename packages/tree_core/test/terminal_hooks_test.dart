import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// 后台长任务（terminal hook）：启动即返回、输出直写日志、结束回调唤醒。
void main() {
  late Directory root;
  late LocalWorkspaceIO io;
  late TerminalHooks hooks;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tree_hooks_');
    io = LocalWorkspaceIO(root.path);
    hooks = TerminalHooks();
  });

  tearDown(() async {
    await hooks.close();
    // Windows 上被终止的子进程可能还短暂持有日志文件句柄：删除要重试
    for (int i = 0; i < 10 && root.existsSync(); i++) {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  });

  Future<HookTask> start(String command, {String? outputFile}) => hooks.start(
    io: io,
    agentId: 'agt_1',
    sessionId: 'ses_1',
    command: command,
    outputFile: outputFile,
  );

  Future<void> waitFinished(HookTask task) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
    while (task.running && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(task.running, isFalse, reason: '任务应在超时前结束');
  }

  test('启动即返回；输出直写日志；结束后写结束标记并回调', () async {
    int? callbackCode;
    HookTask? callbackTask;
    final Completer<int> finished = Completer<int>();
    hooks.onFinished = (HookTask task, int code) {
      callbackTask = task;
      callbackCode = code;
      if (!finished.isCompleted) finished.complete(code);
    };

    final HookTask task = await start('echo hook-output');
    expect(task.running, isTrue, reason: '启动后应立即返回（不等待命令结束）');
    expect(task.id.startsWith('hook_'), isTrue);
    expect(task.logRelative, contains('.output/'));
    expect(hooks.runningCount, 1);

    // 等**回调**而不是只等 running：日志尾部与回调都在 running 变 false 之后完成
    await finished.future.timeout(const Duration(seconds: 20));
    expect(task.exitCode, 0);
    expect(callbackTask?.id, task.id);
    expect(callbackCode, 0);

    final String log = File(task.logAbsolute).readAsStringSync();
    expect(log, contains('# [terminal hook] echo hook-output'));
    expect(log, contains('hook-output'));
    expect(log, contains('结束：退出码 0'));
    expect(hooks.runningCount, 0);
  });

  test('可指定日志文件（工作空间相对路径），越界路径被拒', () async {
    final HookTask task = await start(
      'echo custom-log',
      outputFile: 'logs/hook.log',
    );
    await waitFinished(task);
    expect(task.logRelative, 'logs/hook.log');
    expect(File(p.join(root.path, 'logs', 'hook.log')).existsSync(), isTrue);

    await expectLater(
      start('echo x', outputFile: '../escape.log'),
      throwsA(isA<WorkspacePathException>()),
    );
  });

  test('status 渲染：运行中与已结束两种状态都带日志尾部', () async {
    final HookTask quick = await start('echo status-line');
    await waitFinished(quick);
    final String finished = hooks.renderStatus(quick);
    expect(finished, contains('已结束'));
    expect(finished, contains('退出码 0'));
    expect(finished, contains('status-line'));
    expect(finished, contains(quick.logRelative));

    final HookTask slow = await start(
      Platform.isWindows ? 'ping -n 10 127.0.0.1 | Out-Null' : 'sleep 5',
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(hooks.renderStatus(slow), contains('运行中'));
  });

  test('cancel 杀整棵进程树：任务在超时前结束且标记 cancelled', () async {
    final HookTask task = await start(
      Platform.isWindows ? 'ping -n 30 127.0.0.1 | Out-Null' : 'sleep 30',
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(hooks.runningCount, 1);
    expect(await hooks.cancel(task.id), isTrue);
    await waitFinished(task);
    expect(task.cancelled, isTrue);
    expect(task.exitCode, isNot(0));
    expect(hooks.renderStatus(task), contains('已被取消'));
    expect(await hooks.cancel(task.id), isFalse, reason: '已结束的任务不再可取消');
    expect(await hooks.cancel('nope'), isFalse);
  });

  test('close 杀掉全部在途任务', () async {
    final HookTask a = await start(
      Platform.isWindows ? 'ping -n 30 127.0.0.1 | Out-Null' : 'sleep 30',
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(hooks.runningCount, 1);
    await hooks.close();
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
    while (a.running && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(a.running, isFalse);
    expect(hooks.tasks, isEmpty);
  });

  test('hookNotice 里带命令、退出码与日志路径', () async {
    final HookTask task = await start('echo notice-body');
    await waitFinished(task);
    final String notice = hookNotice(task, 0);
    expect(notice, contains('[terminal hook]'));
    expect(notice, contains('echo notice-body'));
    expect(notice, contains('退出码 0'));
    expect(notice, contains(task.logRelative));
    expect(notice, contains('notice-body'));
  });
}
