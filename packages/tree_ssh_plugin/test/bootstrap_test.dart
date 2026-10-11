import 'dart:convert';

import 'package:test/test.dart';
import 'package:tree_ssh_plugin/tree_ssh_plugin.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'fake_ssh.dart';

void main() {
  late FakeRemote remote;

  setUp(() {
    remote = FakeRemote();
  });

  List<int> fakeBinary([int size = 300]) =>
      List<int>.generate(size, (int i) => (i * 7) % 256);

  Future<BootstrapResult> boot({
    List<int>? binary,
    AgentRequest? agent,
    TunnelConfig? config,
    String token = 'tok-abc',
    int chunkBytes = kPushChunkBytes,
    List<String>? logs,
  }) {
    final List<int> bytes = binary ?? fakeBinary();
    return runBootstrap(
      connection: remote.connect(),
      config: config ?? TunnelConfig.parse(configJson())!,
      agent: agent ?? const AgentRequest(version: '1.2.3'),
      loadBinary: memoryBinary(bytes),
      token: token,
      chunkBytes: chunkBytes,
      log: logs?.add,
    );
  }

  group('架构映射（只认两种，别猜）', () {
    test('x86_64 → amd64，aarch64/arm64 → arm64', () {
      expect(mapArch('x86_64'), 'amd64');
      expect(mapArch('amd64\n'), 'amd64');
      expect(mapArch('aarch64'), 'arm64');
      expect(mapArch('ARM64'), 'arm64');
    });

    test('其它一律 null（⇒ arch_unsupported，不"试着跑一个差不多的"）', () {
      expect(mapArch('i686'), isNull);
      expect(mapArch('riscv64'), isNull);
      expect(mapArch(''), isNull);
    });
  });

  group('AgentRequest', () {
    test('缺 version ⇒ 用 kAgentVersion；binary_name 支持 {arch} 占位', () {
      final AgentRequest parsed = AgentRequest.parse(const <String, dynamic>{});
      expect(parsed.version, kAgentVersion);
      expect(parsed.binaryNameFor('amd64'), 'tree_agent-linux-amd64');
      final AgentRequest templated = AgentRequest.parse(<String, dynamic>{
        'binary_name': 'tree_agent-{arch}',
      });
      expect(templated.binaryNameFor('arm64'), 'tree_agent-arm64');
    });
  });

  group('buildSpawnCommand / token', () {
    test('**总是**带 --root（agent 的越界基线，缺了它 agent 直接拒绝启动）', () {
      // 实测（2026-10-10 真机）：不给 `--root` ⇒ agent stderr
      // 「缺少 --root <工作空间根绝对路径>」后立刻关通道 ⇒ `handshake_failed`。
      // 所以这里钉住"永远带"，而不是"空则省略"。
      expect(
        buildSpawnCommand(agentPath: '/a/tree_agent', root: '/data x', token: 't'),
        "'/a/tree_agent' --root '/data x' --token 't' --idle-timeout-ms 90000",
      );
    });

    test('resolveRemoteRoot：空 / ~ ⇒ HOME；相对 ⇒ 相对 HOME；绝对 ⇒ 归一化', () {
      expect(resolveRemoteRoot('', '/home/tester'), '/home/tester');
      expect(resolveRemoteRoot('~', '/home/tester'), '/home/tester');
      expect(resolveRemoteRoot('~/proj', '/home/tester'), '/home/tester/proj');
      expect(resolveRemoteRoot('proj/x', '/home/tester'), '/home/tester/proj/x');
      expect(resolveRemoteRoot('/srv/ws/', '/home/tester'), '/srv/ws');
      expect(resolveRemoteRoot('/srv/a/../ws', '/home/tester'), '/srv/ws');
    });

    test('token 是 32 位十六进制（每次不同）', () {
      final String a = newHandshakeToken();
      final String b = newHandshakeToken();
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(a), isTrue);
      expect(a == b, isFalse);
    });
  });

  group('bootstrap 全流程（命令形状）', () {
    test('全新主机：探架构 → 建目录 → 对账 → 分块推送 → chmod+mv → 拉起 → 握手', () async {
      final List<int> bytes = fakeBinary();
      final List<String> logs = <String>[];
      final BootstrapResult result = await boot(binary: bytes, logs: logs);
      addTearDown(result.client.close);

      const String dir = '/home/tester/.tree/agent/1.2.3';
      const String path = '$dir/tree_agent-linux-amd64';
      expect(result.installPath, path);
      expect(result.root, '/home/tester');
      expect(result.hello.protocol, kAgentProtocolVersion);
      expect(result.binary.sha256, sha256Hex(bytes));

      final List<String> cmds = remote.commands;
      expect(cmds[0], 'uname -m');
      expect(cmds[1], 'printf $kHomeMarker%s "\$HOME"');
      expect(cmds[2], "mkdir -p '$dir'");
      expect(
        cmds[3],
        "if [ -f '$path' ]; then sha256sum '$path'; "
        'else echo $kMissingMarker; fi',
      );
      // 300 字节一块就够 ⇒ 一条推送命令
      expect(
        cmds[4],
        "printf %s '${base64.encode(bytes)}' | base64 -d > '$path.part'",
      );
      expect(cmds[5], "sha256sum '$path.part'");
      expect(cmds[6], "chmod +x '$path.part' && mv -f '$path.part' '$path'");
      // 推送后目标机上就是那份字节
      expect(remote.files[path], bytes);
      expect(remote.files.containsKey('$path.part'), isFalse);
      // 拉起前先确保工作空间根存在（root 为空 ⇒ 解析成远端 $HOME）
      expect(cmds[7], "mkdir -p '/home/tester'");
      // 常驻通道用最终路径 + **绝对 root** + token 拉起
      expect(
        remote.spawned,
        <String>["'$path' --root '/home/tester' --token 'tok-abc' --idle-timeout-ms 90000"],
      );
      // 登录外壳探测（bash 在 ⇒ 只探 bash）
      expect(cmds[8], 'command -v bash');
      expect(await result.loginShell.resolve(), 'bash -lc {cmd}');
      // 日志里**不能**出现 token（只允许出现 ***）
      expect(logs.join('\n').contains('tok-abc'), isFalse);
      expect(logs.join('\n'), contains('--token ***'));
    });

    test('root 非空 ⇒ 拉起命令带 --root', () async {
      final BootstrapResult result = await boot(
        config: TunnelConfig.parse(configJson(root: '/srv/ws'))!,
      );
      addTearDown(result.client.close);
      expect(
        remote.spawned.single,
        endsWith("--root '/srv/ws' --token 'tok-abc' --idle-timeout-ms 90000"),
      );
    });

    test('agents_dir 覆盖安装目录；version 进路径', () async {
      final BootstrapResult result = await boot(
        agent: const AgentRequest(version: '9.9.9'),
        config: TunnelConfig.parse(configJson(agentsDir: '/opt/tree/agent'))!,
      );
      addTearDown(result.client.close);
      expect(result.installPath, '/opt/tree/agent/9.9.9/tree_agent-linux-amd64');
    });

    test('~ 开头的 agents_dir 展开成 HOME', () async {
      final BootstrapResult result = await boot(
        config: TunnelConfig.parse(configJson(agentsDir: '~/alt/agent'))!,
      );
      addTearDown(result.client.close);
      expect(result.installPath, '/home/tester/alt/agent/1.2.3/tree_agent-linux-amd64');
    });
  });

  group('bootstrap 分块推送', () {
    test('按 kPushChunkBytes 分块，第一块截断、其余追加（块数由常量推出，避免与实现漂移）', () async {
      // 为什么用"由 kPushChunkBytes 推出"的字节数而不是写死 600000/256KiB：
      // 块大小是**实测出来的**（SSH 信道请求报文上限，见 bootstrap.dart 的注释），
      // 它会随实测结论调整；写死数字会让"调块大小"变成"顺手改测试"，把真正的
      // 断言（分块内容逐字节一致 + 第一块截断其余追加）冲淡。
      final List<int> bytes = fakeBinary(kPushChunkBytes * 2 + 1234);
      final BootstrapResult result = await boot(binary: bytes);
      addTearDown(result.client.close);

      const String part = '/home/tester/.tree/agent/1.2.3/tree_agent-linux-amd64.part';
      final List<String> pushes = remote.commands
          .where((String c) => c.startsWith('printf %s '))
          .toList(growable: false);
      expect(pushes.length, 3);
      expect(pushes[0], contains("base64 -d > '$part'"));
      expect(pushes[1], contains("base64 -d >> '$part'"));
      expect(pushes[2], contains("base64 -d >> '$part'"));
      // 拼出来的字节与随包二进制**逐字节一致**（虚拟远端累加了分块）
      expect(remote.files['/home/tester/.tree/agent/1.2.3/tree_agent-linux-amd64'], bytes);
    });

    test('推送块必须留在**实测的** SSH 命令长度上限之下（不许悄悄调大）', () {
      // 实测（2026-10-10，tool/probe_command_len.dart 对 WSL 的 OpenSSH sshd）：
      // base64 载荷 218456 字节 OK、**262144 起失败**（`SSHStateError(SSH connection closed)`）。
      // 命令里还包着 `printf %s '<b64>' > ... | base64 -d > '<path>'` 的骨架（约 100 字节）。
      // 这里按 base64 膨胀 4/3 算出"一条命令大概多长"，要求它 ≤ 200 KiB ——
      // 比实测失败点（≈256 KiB）留出 1.28 倍以上余量，同时挡住"顺手把块调到 128 KiB"。
      const int base64Expansion = 4;
      const int base64Group = 3;
      final int commandBytes =
          (kPushChunkBytes * base64Expansion) ~/ base64Group + 256;
      expect(
        commandBytes,
        lessThan(200 * 1024),
        reason: 'kPushChunkBytes=$kPushChunkBytes ⇒ 单条命令约 $commandBytes 字节，'
            '已逼近实测的断连点（262144 起失败）',
      );
    });

    test('chunkBytes 可调（测试用小块也能工作）', () async {
      final List<int> bytes = fakeBinary(300);
      final BootstrapResult result = await boot(binary: bytes, chunkBytes: 128);
      addTearDown(result.client.close);
      final int pushes = remote.commands
          .where((String c) => c.startsWith('printf %s '))
          .length;
      expect(pushes, 3); // 128 * 2 = 256 < 300
    });
  });

  group('bootstrap 跳过推送（sha 对账）', () {
    test('目标机已有同 sha 的 agent ⇒ 不推送，只确认可执行', () async {
      final List<int> bytes = fakeBinary();
      remote.putFile(
        '/home/tester/.tree/agent/1.2.3/tree_agent-linux-amd64',
        bytes,
      );
      final BootstrapResult result = await boot(binary: bytes);
      addTearDown(result.client.close);

      expect(
        remote.commands.where((String c) => c.startsWith('printf %s ')),
        isEmpty,
      );
      expect(
        remote.commands,
        contains(
          "chmod +x '/home/tester/.tree/agent/1.2.3/tree_agent-linux-amd64'",
        ),
      );
    });

    test('sha 不一致 ⇒ 重推', () async {
      remote.putFile(
        '/home/tester/.tree/agent/1.2.3/tree_agent-linux-amd64',
        utf8.encode('旧版本'),
      );
      final List<int> bytes = fakeBinary();
      final BootstrapResult result = await boot(binary: bytes);
      addTearDown(result.client.close);
      expect(
        remote.commands.where((String c) => c.startsWith('printf %s ')).length,
        1,
      );
      expect(
        remote.files['/home/tester/.tree/agent/1.2.3/tree_agent-linux-amd64'],
        bytes,
      );
    });
  });

  group('bootstrap 失败面（每步都要有 error_kind）', () {
    test('连上但命令执行失败 ⇒ agent_unreachable', () async {
      remote.failCommandsContaining = 'uname';
      await expectLater(
        boot(),
        throwsA(
          isA<BootstrapException>().having(
            (BootstrapException e) => e.kind,
            'kind',
            TunnelErrorKinds.agentUnreachable,
          ),
        ),
      );
    });

    test(r'取不到 $HOME ⇒ agent_unreachable（不拿空路径去建目录）', () async {
      remote.home = '';
      await expectLater(
        boot(),
        throwsA(
          isA<BootstrapException>().having(
            (BootstrapException e) => e.kind,
            'kind',
            TunnelErrorKinds.agentUnreachable,
          ),
        ),
      );
    });

    test('架构不支持 ⇒ arch_unsupported（且不推送）', () async {
      remote.machine = 'riscv64';
      await expectLater(
        boot(),
        throwsA(
          isA<BootstrapException>()
              .having(
                (BootstrapException e) => e.kind,
                'kind',
                TunnelErrorKinds.archUnsupported,
              )
              .having(
                (BootstrapException e) => e.message,
                'message',
                contains('riscv64'),
              ),
        ),
      );
      expect(
        remote.commands.where((String c) => c.startsWith('printf %s ')),
        isEmpty,
      );
    });

    test('建目录失败 ⇒ push_failed', () async {
      remote.failCommandsContaining = 'mkdir';
      await expectLater(
        boot(),
        throwsA(
          isA<BootstrapException>().having(
            (BootstrapException e) => e.kind,
            'kind',
            TunnelErrorKinds.pushFailed,
          ),
        ),
      );
    });

    test('推送中断 ⇒ push_failed（且不落地半个二进制）', () async {
      remote.failCommandsContaining = 'printf %s';
      await expectLater(
        boot(),
        throwsA(
          isA<BootstrapException>().having(
            (BootstrapException e) => e.kind,
            'kind',
            TunnelErrorKinds.pushFailed,
          ),
        ),
      );
      expect(
        remote.files.containsKey(
          '/home/tester/.tree/agent/1.2.3/tree_agent-linux-amd64',
        ),
        isFalse,
      );
    });

    test('常驻通道起不来 ⇒ spawn_failed', () async {
      remote.failSpawn = true;
      await expectLater(
        boot(),
        throwsA(
          isA<BootstrapException>().having(
            (BootstrapException e) => e.kind,
            'kind',
            TunnelErrorKinds.spawnFailed,
          ),
        ),
      );
    });

    test('agent.hello 回 protocol_mismatch ⇒ handshake_failed', () async {
      remote.errorHandler = (String method, Map<String, dynamic> params) {
        if (method != AgentMethods.hello) return null;
        return <String, dynamic>{
          'code': TunnelErrorCodes.protocolMismatch,
          'message': '协议不匹配',
        };
      };
      await expectLater(
        boot(),
        throwsA(
          isA<BootstrapException>().having(
            (BootstrapException e) => e.kind,
            'kind',
            TunnelErrorKinds.handshakeFailed,
          ),
        ),
      );
    });

    test('agent.hello 自报协议 ≠ 1 ⇒ handshake_failed', () async {
      remote.helloProtocol = 2;
      await expectLater(
        boot(),
        throwsA(
          isA<BootstrapException>()
              .having(
                (BootstrapException e) => e.kind,
                'kind',
                TunnelErrorKinds.handshakeFailed,
              )
              .having(
                (BootstrapException e) => e.message,
                'message',
                contains('升级随包 agent'),
              ),
        ),
      );
    });

    test('握手自报架构与 uname -m 不一致 ⇒ handshake_failed（不装作没事）', () async {
      remote.helloArch = 'arm64';
      await expectLater(
        boot(),
        throwsA(
          isA<BootstrapException>().having(
            (BootstrapException e) => e.kind,
            'kind',
            TunnelErrorKinds.handshakeFailed,
          ),
        ),
      );
    });

    test('通道在握手前就断 ⇒ handshake_failed', () async {
      remote.channelExitCode = 1;
      await expectLater(
        boot(),
        throwsA(
          isA<BootstrapException>().having(
            (BootstrapException e) => e.kind,
            'kind',
            TunnelErrorKinds.handshakeFailed,
          ),
        ),
      );
    });
  });
}
