import 'dart:async';

import 'package:test/test.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

import 'fake_ssh_shell_channel.dart';
import 'fake_ssh_transport.dart';

/// 让流事件与 async 回调落地（与 `tree_core/test/terminal_service_test.dart` 同一手法）。
Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 10));

/// 远端 shell 通道的**契约钉子**（本机没有可连的 sshd，真实现见
/// `dartssh_transport.dart` 的 `_DartSshShellChannel`，真链路由 `ssh_integration_test.dart`
/// 的环境变量门控用例覆盖）。这里断言的是"核心侧适配器与终端服务依赖的那些性质"：
/// 透传（尺寸 / 远端工作目录）、原始字节、幂等 close、exitCode 必收口、close 不关连接。
void main() {
  late FakeSshTransport transport;
  late SshWorkspaceIO io;

  setUp(() {
    transport = FakeSshTransport();
    io = SshWorkspaceIO('/srv/app', transport);
  });

  test('openShell 透传：窗口尺寸原样，工作目录用**远端根**（绝不传本机路径）', () async {
    final SshShellChannel channel = await io.openShell(columns: 120, rows: 40);
    final ({int columns, int rows, String command, String workingDirectory})
    open = transport.shellOpens.single;
    expect(open.columns, 120);
    expect(open.rows, 40);
    expect(
      open.workingDirectory,
      '/srv/app',
      reason: '远端根只有 SshWorkspaceIO 知道',
    );
    expect(open.command, '');
    expect(channel.shell, 'fake-ssh');
    await channel.close();
  });

  test('写入与 resize：原样进通道（含 ESC / 非法 UTF-8 字节，不解码、不清洗）', () async {
    final SshShellChannel channel = await io.openShell(columns: 80, rows: 24);
    final FakeSshShellChannel fake = transport.lastShell!;
    final List<int> keys = <int>[0x1b, 0x5b, 0x41, 0xff, 0x0d];
    await channel.write(keys);
    await channel.resize(100, 30);
    expect(fake.writes.single, keys);
    expect(fake.resizes.single, (100, 30));
    await channel.close();
  });

  test('输出是原始字节：ESC 序列与非法 UTF-8 一模一样地过', () async {
    final SshShellChannel channel = await io.openShell(columns: 80, rows: 24);
    final FakeSshShellChannel fake = transport.lastShell!;
    final List<int> got = <int>[];
    final StreamSubscription<List<int>> sub = channel.output.listen(got.addAll);
    final List<int> raw = <int>[
      0x1b,
      0x5b,
      0x33,
      0x31,
      0x6d,
      0xe7,
      0xba,
      0xa2,
      0xff,
      0x0a,
    ];
    fake.emit(raw);
    await settle();
    expect(got, raw);
    await sub.cancel();
    await channel.close();
  });

  test('close 幂等，且**不关整条 SSH 连接**（SFTP / exec 共用的那条）', () async {
    final SshShellChannel channel = await io.openShell(columns: 80, rows: 24);
    final FakeSshShellChannel fake = transport.lastShell!;
    await channel.close();
    await channel.close(); // 第二次：不抛、不再改状态
    expect(fake.closeCount, 2);
    expect(fake.isClosed, isTrue);
    expect(transport.closed, isFalse, reason: '关个终端不该把文件面板与其他工具一起打断');
    // 连接还活着：同一传输上的 exec 照常工作
    await io.exec('echo hi');
    expect(transport.commands, hasLength(1));
  });

  test('exitCode 一定收口：远端报告就有码，主动 close 给 -1，绝不悬挂', () async {
    // 1) 远端进程正常退出：拿到真实退出码
    final SshShellChannel exited = await io.openShell(columns: 80, rows: 24);
    transport.lastShell!.finish(3);
    expect(await exited.exitCode.timeout(const Duration(seconds: 1)), 3);

    // 2) 我们主动关（对端可能永远不回退出状态）：也必须在 1s 内收口
    final SshShellChannel closed = await io.openShell(columns: 80, rows: 24);
    await closed.close();
    expect(
      await closed.exitCode.timeout(const Duration(seconds: 1)),
      -1,
      reason: '拿不到退出状态时的口径（与 DartSshTransport.run 的 ?? -1 一致）',
    );
  });

  test('会话结束后：写入与 resize 静默丢弃，不抛（高频输入不该刷日志）', () async {
    final SshShellChannel channel = await io.openShell(columns: 80, rows: 24);
    final FakeSshShellChannel fake = transport.lastShell!;
    await channel.close();
    await channel.write(<int>[0x0d]);
    await channel.resize(90, 20);
    expect(fake.writes, isEmpty);
    expect(fake.resizes, isEmpty);
  });

  test('链路已判失活：openShell 显式失败，不新开会话（复用既有 SshLiveness）', () async {
    for (int i = 0; i < SshLiveness.defaultMaxMisses; i++) {
      transport.liveness.recordMiss();
    }
    expect(transport.liveness.isStale, isTrue);
    await expectLater(
      io.openShell(columns: 80, rows: 24),
      throwsA(isA<SshLinkStaleException>()),
    );
    expect(transport.shellOpens, isEmpty);
  });
}
