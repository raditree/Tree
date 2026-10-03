import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// 真 SSH 的**门控**集成测试：只有设置 `TREE_SSH_TEST_HOST` 才执行，否则跳过。
///
/// 为什么门控：CI 与开发机通常没有可连的 sshd（本机就没有）。[SshWorkspaceIO]
/// 的全部工作空间语义已由内存假传输的单测覆盖；这里只验证 dartssh2 那一层
/// "真的能连上、能走 SFTP 搬字节、能跑命令"，所以不进默认测试路径。
///
/// 需要的环境变量：
/// - `TREE_SSH_TEST_HOST`（必填，缺失即跳过）
/// - `TREE_SSH_TEST_USER` / `TREE_SSH_TEST_PASSWORD` 或 `TREE_SSH_TEST_KEY`
/// - `TREE_SSH_TEST_PORT`（默认 22）/ `TREE_SSH_TEST_ROOT`（默认远端 HOME）
/// - `TREE_SSH_TEST_KEY_PASSPHRASE`（有口令的私钥才需要）
void main() {
  final Map<String, String> env = Platform.environment;
  final String host = env['TREE_SSH_TEST_HOST'] ?? '';

  test('真 SSH：连接 + SFTP 读写改 + exec + 清理', () async {
    if (host.isEmpty) {
      markTestSkipped('未设置 TREE_SSH_TEST_HOST，跳过真 SSH 集成测试');
      return;
    }
    final DartSshTransport transport = await DartSshTransport.connect(
      host: host,
      port: int.tryParse(env['TREE_SSH_TEST_PORT'] ?? '') ?? 22,
      username: env['TREE_SSH_TEST_USER'] ?? '',
      password: env['TREE_SSH_TEST_PASSWORD'] ?? '',
      keyPath: env['TREE_SSH_TEST_KEY'] ?? '',
      keyPassphrase: env['TREE_SSH_TEST_KEY_PASSPHRASE'] ?? '',
    );
    final String remoteRoot = await resolveRemoteRoot(
      transport,
      env['TREE_SSH_TEST_ROOT'] ?? '',
    );
    final SshWorkspaceIO io = SshWorkspaceIO(remoteRoot, transport);
    final String probe =
        '.tree_probe_${DateTime.now().microsecondsSinceEpoch}.txt';
    addTearDown(() async {
      await io.exec('rm -f $probe');
      await io.close();
    });

    // 1) cwd 就是工作空间根（cd 到 root）
    final ExecOutcome pwd = await io.exec('pwd');
    expect(pwd.exitCode, 0);
    expect(pwd.stdout.trim(), remoteRoot);

    // 2) SFTP 写→读（含非 ASCII，验证字节不经过 shell）
    await io.writeFile(probe, 'hello\n世界\n');
    final FileContent content = await io.readFile(probe);
    expect(content.text, 'hello\n世界\n');
    expect(content.totalLines, 2);

    // 3) grep 走 listFiles + read，路径必须是工作空间相对路径（不带 ./）
    final GrepOutcome found = await io.grep(GrepQuery(pattern: '世界'));
    expect(found.matches.single.path, probe);
    expect(found.matches.single.line, '世界');

    // 4) edit 唯一匹配 + exec 看得到结果（两套通路一致）
    await io.editFile(probe, oldText: '世界', newText: '远端');
    final ExecOutcome cat = await io.exec('cat $probe');
    expect(cat.exitCode, 0);
    expect(cat.stdout, contains('远端'));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('真 SSH：软超时交出仍在运行的远端命令（不杀进程，随后自然跑完）', () async {
    if (host.isEmpty) {
      markTestSkipped('未设置 TREE_SSH_TEST_HOST，跳过真 SSH 集成测试');
      return;
    }
    final DartSshTransport transport = await DartSshTransport.connect(
      host: host,
      port: int.tryParse(env['TREE_SSH_TEST_PORT'] ?? '') ?? 22,
      username: env['TREE_SSH_TEST_USER'] ?? '',
      password: env['TREE_SSH_TEST_PASSWORD'] ?? '',
      keyPath: env['TREE_SSH_TEST_KEY'] ?? '',
      keyPassphrase: env['TREE_SSH_TEST_KEY_PASSPHRASE'] ?? '',
    );
    final String remoteRoot = await resolveRemoteRoot(
      transport,
      env['TREE_SSH_TEST_ROOT'] ?? '',
    );
    final SshWorkspaceIO io = SshWorkspaceIO(remoteRoot, transport);
    addTearDown(io.close);

    // 1) `sleep 5` 的命令 + 1s 软超时 ⇒ 约 1s 就返回"仍在运行"（不是超时错误、不是杀进程）
    SshExecStillRunning? still;
    final Stopwatch watch = Stopwatch()..start();
    try {
      await io.exec(
        'sleep 5; echo remote-done',
        timeout: const Duration(seconds: 1),
      );
    } on SshExecStillRunning catch (error) {
      still = error;
    }
    watch.stop();
    expect(still, isNotNull, reason: '到点仍在跑应当抛 SshExecStillRunning');
    expect(
      watch.elapsed.inSeconds,
      lessThan(4),
      reason: '约 1s 返回，不是等命令跑完（5s）',
    );
    expect(still!.elapsed.inSeconds, lessThan(4));

    // 2) 远端进程**没被杀**：它照常跑完，句柄拿得到退出码与完整输出
    final SshExecResult done = await still.running.result.timeout(
      const Duration(seconds: 60),
    );
    expect(done.exitCode, 0, reason: '没杀进程：命令照常跑完');
    expect(done.stdout, contains('remote-done'));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
