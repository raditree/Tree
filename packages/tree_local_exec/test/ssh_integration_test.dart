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
    // 探针全部落在**自建目录**里，并把 grep 限定在该目录：
    // 远端根是真实的共享工作空间（可能很大），全根 grep 实测 2 分钟扫不完；
    // 而 `matches.single` 又假设命中全局唯一 —— 两者都会让这条用例假失败。
    final String dir = 'tree_probe_${DateTime.now().microsecondsSinceEpoch}';
    final String probe = '$dir/a.txt';
    addTearDown(() async {
      await io.exec('rm -rf $dir');
      await io.close();
    });
    await io.exec('mkdir -p $dir');

    // 1) cwd 就是工作空间根（cd 到 root）
    final ExecOutcome pwd = await io.exec('pwd');
    expect(pwd.exitCode, 0);
    expect(pwd.stdout.trim(), remoteRoot);

    // 2) SFTP 写→读（含非 ASCII，验证字节不经过 shell；结尾换行也要保真）
    await io.writeFile(probe, 'hello\n世界\n');
    final FileContent content = await io.readFile(probe);
    expect(content.text, 'hello\n世界\n');
    expect(content.totalLines, 2);

    // 3) grep 走 listFiles + read，路径必须是工作空间相对路径（不带 ./）
    final GrepOutcome found = await io.grep(
      GrepQuery(pattern: '世界', relativePath: dir),
    );
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

  test('真 SSH：hook=true（startBackground）立即返回，命令在远端跑完后拿得到退出码与产物', () async {
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
    const String logRel = '.tree_probe_bg/hook.log';
    addTearDown(() async {
      await io.exec('rm -rf .tree_probe_bg');
      await io.close();
    });
    await io.exec('rm -rf .tree_probe_bg');

    // 命令要跑 8s；**不许**等它：startBackground 必须立刻返回（旧形状会等满 8s）。
    final Stopwatch watch = Stopwatch()..start();
    final BackgroundExecHandle handle = await io.startBackground(
      command: 'sleep 8; echo REMOTE-OK; hostname; date -u +%FT%TZ',
      logRelativePath: logRel,
    );
    watch.stop();

    expect(handle.remote, isTrue);
    expect(handle.pid, isNotNull, reason: '远端包装子壳的 pid 要拿得到（cancel 依赖它）');
    expect(
      watch.elapsed.inSeconds,
      lessThan(4),
      reason: '立即返回：耗时与命令时长无关（命令要跑 8s）',
    );

    // 返回时命令**仍在跑**——日志里还没有结尾输出
    final String? early = await io.readTail(logRel, 2000);
    expect(
      early ?? '',
      isNot(contains('REMOTE-OK')),
      reason: '返回时命令尚未跑完（不是"等它跑完才返回"）',
    );

    // 后台台账仍拿得到退出码；产物证明命令确实在**远端**跑完
    final int code = await handle.exitCode.timeout(const Duration(seconds: 60));
    expect(code, 0);
    final String? tail = await io.readTail(logRel, 2000);
    expect(tail, contains('REMOTE-OK'), reason: '命令确实在远端跑完了');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
