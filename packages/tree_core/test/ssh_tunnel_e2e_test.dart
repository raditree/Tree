import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

/// **核心侧**的 SSH 执行器端到端（真插件进程 + 真 sshd + 真 `tree_agent`）。
///
/// 为什么单独一条：`tool/tunnel_e2e.dart` 验的是**线上协议**（黑盒），
/// 而核心自己的那三块（`PluginBus.sshExecutorLookup()` / `PluginTunnelLink` /
/// `TunnelSshTransport` + `SshWorkspaceIO` 的后台托管选路）此前只用**假实现**测过。
/// 这条把它们接到真东西上：内置目录解析可执行文件 → 真起插件进程 → 建隧道 →
/// 文件/命令/托管后台任务。
///
/// 门控（与仓库其它真机用例同口径）：未设下面这些环境变量就 **skip**。
///   TREE_SSH_TEST_HOST / TREE_SSH_TEST_PORT / TREE_SSH_TEST_USER / TREE_SSH_TEST_KEY
void main() {
  final String host = Platform.environment['TREE_SSH_TEST_HOST'] ?? '';
  final String port = Platform.environment['TREE_SSH_TEST_PORT'] ?? '2222';
  final String user = Platform.environment['TREE_SSH_TEST_USER'] ?? '';
  final String key = Platform.environment['TREE_SSH_TEST_KEY'] ?? '';

  test('核心侧：解析内置中转站 → 起真插件 → 建隧道 → 文件/命令/托管后台任务', () async {
    if (host.isEmpty) {
      markTestSkipped(
        '未设 TREE_SSH_TEST_HOST：本机没有可连的 sshd 时这是预期行为（真机门控）',
      );
      return;
    }
    final Directory temp = Directory.systemTemp.createTempSync('tree_tunnel_');
    addTearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final String configFile = p.join(temp.path, 'plugins.yaml');

    // ① 用**真实的内置目录**解析可执行文件 —— 顺带验了"binary 型怎么找插件"。
    //
    // `executableDir` 是这本就为测试准备的注入点（见 `BuiltinPluginCatalog` 的构造器注释）：
    // 跑 `dart test` 时 `Platform.resolvedExecutable` 是 SDK 里的 dart，
    // `repoRoot()` 因此锚不到仓根。注入 `<仓根>/build` 正好复现**开发态的真实布局**
    // （`tool/build_ssh_plugin.dart` 就把产物放在 `<仓根>/build/plugins/`）。
    final String? repo = BuiltinPluginCatalog.repoRoot(Directory.current.path);
    final BuiltinPluginCatalog catalog = BuiltinPluginCatalog(
      executableDir: repo == null ? null : p.join(repo, 'build'),
    );
    final BuiltinPluginSpec spec =
        BuiltinPluginCatalog.specOf(kSshExecutorPluginId)!;
    final BuiltinResolution resolution = await catalog.resolve(spec);
    expect(resolution.ok, isTrue, reason: resolution.error);
    expect(resolution.scriptPath, isEmpty, reason: 'binary 型没有脚本参数');
    PluginConfigStore(configFile).upsert(
      BuiltinPluginCatalog.entryFor(spec, resolution),
    );

    // ② 起真插件进程，按**能力**认它
    final PluginBus bus = PluginBus(configFile: configFile, coreVersion: 'e2e');
    addTearDown(() => bus.close());
    await bus.start();
    final ({PluginHost? host, String reason}) lookup = bus.sshExecutorLookup();
    expect(lookup.host, isNotNull, reason: lookup.reason);
    expect(
      lookup.host!.capabilities,
      contains(kCapabilitySshExecutor),
      reason: 'hello 必须申报 ssh-executor —— 这是核心"有没有中转站"的唯一判据',
    );

    // ③ 经核心的 TunnelLink 建隧道
    final PluginTunnelLink link = PluginTunnelLink(bus);
    expect(link.available, isTrue, reason: link.unavailableReason);
    final TunnelSshTransport transport = await TunnelSshTransport.connect(
      link,
      TunnelConnectRequest(
        host: host,
        port: int.tryParse(port) ?? 2222,
        username: user,
        keyPath: key,
      ),
    );
    addTearDown(transport.close);
    expect(transport.root.startsWith('/'), isTrue, reason: transport.root);
    expect(transport.tunnelDown, isFalse);

    // ④ 文件原语（含跨块读写）
    final String file = '${transport.root}/.tree/e2e-core.txt';
    final List<int> payload = List<int>.generate(1024 * 1024 + 77, (int i) => i % 253);
    await transport.write(file, payload);
    final List<int> back = await transport.read(file);
    expect(back, payload, reason: '跨块读写必须逐字节一致');
    expect(await transport.size(file), payload.length);
    expect(await transport.exists(file), isTrue);

    // ⑤ 前台命令（登录外壳由插件包裹，agent 只执行最终串）
    final SshExecResult ran = await transport.run('echo CORE-E2E-\$(uname -s)');
    expect(ran.exitCode, 0);
    expect(ran.stdout, contains('CORE-E2E-Linux'));

    // ⑥ **后台托管**：经 SshWorkspaceIO 的选路（这条正是"跨日稳定"要保的那条路）
    final SshWorkspaceIO io = SshWorkspaceIO(transport.root, transport);
    final BackgroundExecHandle handle = await io.startBackground(
      command: 'sleep 1; echo CORE-BG-DONE',
      logRelativePath: '.tree/e2e-core-bg.log',
    );
    expect(handle.remote, isTrue);
    expect(
      await handle.exitCode.timeout(const Duration(seconds: 60)),
      0,
      reason: '托管后台任务的退出码来自目标机落盘台账',
    );
    final String? tail = await io.readTail('.tree/e2e-core-bg.log', 4096);
    expect(tail, contains('CORE-BG-DONE'));
    await handle.close();

    // ⑨ **断连不误发 + 恢复后接续**（用户 2026-10-11 症状 #1 的正面复现，协议 §10）：
    //    起一条长后台任务 → 从**服务端**掐断这条通道（客户端立刻看到断，后台任务不受影响）
    //    → 断言切断期间 hook 的 `exitCode` **没有**提前失败 → 自动重连后拿到**真实**退出码与日志。
    //
    // 为什么这条必须在真机上钉：修复前它会在断连瞬间以 `SshLinkStaleException` 收尾（而退避还没耗尽），
    // 之后就再没人认领那个仍在跑的任务 —— 用户原话："即使重连后那个后台任务也没有回来"。
    Future<String> sshRun(String command) async {
      final ProcessResult r = await Process.run('ssh', <String>[
        '-i', key,
        '-p', port,
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=/dev/null',
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=10',
        '$user@$host',
        command,
      ]);
      return '${r.stdout}'.trim();
    }

    final SshWorkspaceIO cutIo = SshWorkspaceIO(
      transport.root,
      transport,
      // 断连期间的探测间隔：生产默认 30s，这里压到 500ms，免得一条用例等半分钟
      // （实际路径上"等隧道回来"发生在传输层内部，这个值只在**探测本身失败**时才起作用）。
      backgroundStalePollInterval: const Duration(milliseconds: 500),
    );
    final BackgroundExecHandle cutHandle = await cutIo.startBackground(
      command: 'sleep 12; echo CORE-CUT-SURVIVED',
      logRelativePath: '.tree/e2e-core-cut.log',
    );
    await Future<void>.delayed(const Duration(seconds: 3)); // 让它先跑起来（首拍立即探测）
    Object? earlyFailure;
    bool earlyDone = false;
    unawaited(
      cutHandle.exitCode.then(
        (int _) => earlyDone = true,
        onError: (Object error) => earlyFailure = error,
      ),
    );

    // 掐断：**顺着 agent 的父进程**找那条会话并杀它（名字叫什么都无所谓；
    // 为什么不用 `pkill -f 'sshd: …'`：新版 OpenSSH 的会话进程叫 `sshd-session: <user>@notty`，
    // 而且方括号防自匹配要套在用户名**第一个**字符上，写错一个字符就会"静默不命中"）。
    final int? agentPid = (transport.agentInfo['pid'] as num?)?.toInt();
    expect(agentPid, isNotNull, reason: 'agent.hello 应当自报 pid');
    final String cutSession = await sshRun(
      'SES=\$(ps -o ppid= -p $agentPid 2>/dev/null | tr -d " "); '
      'if [ -n "\$SES" ]; then kill "\$SES" 2>/dev/null && echo "killed \$SES" '
      '|| echo "kill-failed \$SES"; else echo "no-session"; fi',
    );
    expect(
      cutSession.startsWith('killed'),
      isTrue,
      reason: '掐断动作必须真的打到那条会话，否则下面的断言毫无意义：$cutSession',
    );
    await Future<void>.delayed(const Duration(seconds: 4));
    expect(earlyFailure, isNull, reason: '断连期间**不许**以失联收尾（退避还没耗尽）');
    expect(earlyDone, isFalse, reason: '任务还在目标机上跑，不该提前收尾');

    expect(
      await cutHandle.exitCode.timeout(const Duration(seconds: 120)),
      0,
      reason: '自动重连后应当从**落盘台账**拿到真实退出码',
    );
    expect(
      await cutIo.readTail('.tree/e2e-core-cut.log', 4096),
      contains('CORE-CUT-SURVIVED'),
    );
    expect(
      transport.tunnelDown,
      isFalse,
      reason: '抖一下不该判死（判死只来自心跳快照 down / 插件不可用）',
    );
    await cutHandle.close();
    await transport.delete('${transport.root}/.tree/e2e-core-cut.log');

    // ⑦ 越界仍由 agent 侧第二道防线拒绝
    await expectLater(
      transport.read('/etc/passwd'),
      throwsA(isA<WorkspaceIoException>()),
    );

    // ⑧ 收尾：清掉本次自建的文件（`delete` = **文件**且缺失不报错；
    //    `remove` 是给目录用的，对不存在的路径会如实报 not_found）。
    await transport.delete('${transport.root}/.tree/e2e-core.txt');
    await transport.delete('${transport.root}/.tree/e2e-core-bg.log');
    expect(await transport.exists('${transport.root}/.tree/e2e-core.txt'), isFalse);
  }, timeout: const Timeout(Duration(minutes: 6)));
}
