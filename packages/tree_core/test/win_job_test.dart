import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// Job Object 的口径：
/// 结构体布局必须与 MSDN 对齐（否则 SetInformationJobObject 会静默不生效），
/// 关掉作业句柄必须真的把作业内进程收走（KILL_ON_JOB_CLOSE）。
void main() {
  test('JOBOBJECT_EXTENDED_LIMIT_INFORMATION 布局 = 144 字节（x64）', () {
    expect(winJobExtendedLimitInfoSize, 144);
  }, skip: Platform.isWindows ? false : '仅 Windows');

  test('非 Windows 下拿不到作业，登记是空操作', () {
    if (Platform.isWindows) return;
    expect(pluginJob, isNull);
    assignPluginProcessToJob(1);
  });

  test('close() 触发 KILL_ON_JOB_CLOSE，作业内进程被内核终止', () async {
    final WinJobObject? job = WinJobObject.create();
    expect(job, isNotNull, reason: 'CreateJobObjectW 失败');

    final Process process = await Process.start('cmd.exe', <String>[
      '/c',
      'ping',
      '-n',
      '30',
      '127.0.0.1',
    ]);
    process.stdout.drain<void>();
    process.stderr.drain<void>();
    expect(job!.assign(process.pid), isTrue, reason: 'AssignProcessToJobObject 失败');

    // 让它真的跑起来再收作业，避免“还没被赋进作业就退出”的假阳性。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    job.close();

    final int code = await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () => -1,
    );
    expect(code, isNot(-1), reason: '进程没有被作业带走');
  }, skip: Platform.isWindows ? false : '仅 Windows');

  test('无效 pid / 重复关闭都安全返回 false', () {
    final WinJobObject? job = WinJobObject.create();
    expect(job, isNotNull);
    expect(job!.assign(-1), isFalse);
    expect(job.assign(0), isFalse);
    job.close();
    expect(job.assign(1), isFalse);
    expect(job.terminate(), isFalse);
  }, skip: Platform.isWindows ? false : '仅 Windows');
}
