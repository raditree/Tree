import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// 一条"跑很久"的命令（本地软超时用例）。
String _longCommand(int seconds) =>
    Platform.isWindows ? 'Start-Sleep -Seconds $seconds' : 'sleep $seconds';

/// 一条"有点慢但会结束"的命令：验证默认（不设软超时）仍是老行为。
String _slowEcho() => Platform.isWindows
    ? 'Start-Sleep -Seconds 0.8; echo slow-done'
    : 'sleep 0.8; echo slow-done';

void main() {
  late Directory root;
  late LocalWorkspaceIO io;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tree_soft_');
    io = LocalWorkspaceIO(root.path);
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {
      // 子进程可能还短暂持有句柄：删不掉就算了（临时目录）
    }
  });

  test('软超时：交出仍活着的进程（没杀、没重跑），由调用方收尾', () async {
    LocalExecStillRunning? caught;
    try {
      await io.exec(
        _longCommand(30),
        timeout: const Duration(milliseconds: 800),
      );
    } on LocalExecStillRunning catch (error) {
      caught = error;
    }
    expect(caught, isNotNull, reason: '到点仍在跑应当抛 LocalExecStillRunning');
    final RunningLocalExec running = caught!.running;
    expect(running.pid, greaterThan(0));
    // **没有杀进程**：再等一会儿，它的退出码仍然不会完成
    final String raced = await Future.any(<Future<String>>[
      running.exitCode.then((int _) => 'exited'),
      Future<String>.delayed(const Duration(milliseconds: 600), () => 'running'),
    ]);
    expect(raced, 'running', reason: '软超时的语义是"不再等"，不是"杀掉"');
    expect(running.snapshotText(), isNotEmpty);
    // 收尾：真实调用方会把句柄登记成 hook 任务，这里模拟"取消"
    await Shell.killProcessTree(running.pid);
    expect(await running.exitCode, isNot(0));
  });

  test('默认 timeout（Duration.zero）：老行为，慢命令跑完就返回', () async {
    final ExecOutcome outcome = await io
        .exec(_slowEcho())
        .timeout(const Duration(seconds: 30));
    expect(outcome.exitCode, 0);
    expect(outcome.stdout, contains('slow-done'));
  });
}
