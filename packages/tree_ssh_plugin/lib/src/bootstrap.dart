import 'dart:convert';
import 'dart:math';

import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'agent_binary.dart';
import 'agent_client.dart';
import 'keepalive.dart';
import 'login_shell.dart';
import 'sha256.dart';
import 'ssh_dialer.dart';
import 'tunnel_config.dart';

/// 推送分块大小（**原文字节**）。
///
/// 上限不是"命令太长"而是 **SSH 信道请求报文**：`exec` 的 command 是一个报文，
/// 塞太大时对端会当协议错误**直接断连**（实测现象 `SSHStateError(SSH connection closed)`，
/// 整条 ensure 因此 `push_failed`）。
///
/// **实测（2026-10-10，`tool/probe_command_len.dart`，对 WSL 的 OpenSSH sshd）**：
/// base64 载荷 131072 / 174764 / **218456** 字节都 OK，**262144 字节起失败**。
/// 所以这里取 **64 KiB 原文 ⇒ base64 约 87 KiB 命令**，比实测失败点低 3 倍，
/// 留足余量给"对端 max packet 配置不同"的情况。
/// 代价：6.7 MB 的 agent 要 107 次往返（本机/局域网几秒级）——**只在首次或版本变化时发生**
/// （sha256 一致就跳过），所以不值得为它引入更复杂的传输（如 SFTP 上传）。
const int kPushChunkBytes = 64 * 1024;

/// `chunked push` 阶段写文件的临时后缀（校验通过才 `mv` 成正式路径）。
const String kPushPartSuffix = '.part';

/// `$HOME` 探测的标记（远端 profile 往 stdout 打欢迎语也不影响取值）。
const String kHomeMarker = '__TREE_HOME__';

/// "目标机上没有这个文件"的标记。
const String kMissingMarker = '__TREE_AGENT_MISSING__';

/// bootstrap 失败（**每一步都带 `error_kind`**，直接进 `tunnel.ensure` 的失败面）。
class BootstrapException implements Exception {
  BootstrapException(this.kind, this.message);

  /// [TunnelErrorKinds] 之一。
  final String kind;
  final String message;

  @override
  String toString() => '$kind: $message';
}

/// `agent.hello` 的握手结果（协议 §3.1）。
class AgentHello {
  const AgentHello({
    required this.protocol,
    required this.agentVersion,
    required this.os,
    required this.arch,
    required this.home,
    required this.root,
    required this.pid,
  });

  static AgentHello parse(Map<String, dynamic> result) => AgentHello(
    protocol: (result['protocol'] as num?)?.toInt() ?? 0,
    agentVersion: (result['agent_version'] ?? '').toString(),
    os: (result['os'] ?? '').toString(),
    arch: (result['arch'] ?? '').toString(),
    home: (result['home'] ?? '').toString(),
    root: (result['root'] ?? '').toString(),
    pid: (result['pid'] as num?)?.toInt() ?? -1,
  );

  final int protocol;
  final String agentVersion;
  final String os;
  final String arch;
  final String home;
  final String root;
  final int pid;

  /// 可安全回给核心的形态（**没有凭据、没有 token**）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': agentVersion,
    'protocol': protocol,
    if (os.isNotEmpty) 'os': os,
    if (arch.isNotEmpty) 'arch': arch,
    if (pid >= 0) 'pid': pid,
  };
}

/// 一次 bootstrap 的产物。
class BootstrapResult {
  const BootstrapResult({
    required this.client,
    required this.hello,
    required this.root,
    required this.installPath,
    required this.binary,
    required this.loginShell,
  });

  final AgentClient client;
  final AgentHello hello;

  /// 权威的远端工作空间根（来自 `agent.hello`；为空则回退配置里的 root）。
  final String root;

  /// 目标机上 agent 的绝对路径（诊断用）。
  final String installPath;
  final AgentBinary binary;

  /// 已探好的登录外壳（`exec.run` 转发时用）。
  final LoginShell loginShell;
}

/// 架构映射：目标机 `uname -m` → 随包二进制名里用的架构串。
///
/// 只认任务书列的两种（本方案随包只发 linux amd64 / arm64）；其它一律
/// `arch_unsupported`（**不猜**，也不"试着跑一个差不多的"）。
String? mapArch(String unameMachine) {
  switch (unameMachine.trim().toLowerCase()) {
    case 'x86_64':
    case 'amd64':
    // Dart 的 `Abi.current()` 报的是 `x64`（不是 uname 的叫法）—— 握手对账要认它，
    // 否则会把"同一个架构"误判成不一致（实测踩过：agent 自报 x64 vs uname x86_64）。
    case 'x64':
      return 'amd64';
    case 'aarch64':
    case 'arm64':
      return 'arm64';
    default:
      return null;
  }
}

/// 拉起 agent 的命令行（**最终字符串**，由远端 `$SHELL -c` 执行）。
///
/// `--token` 只走命令行、**永不进日志**（协议 §3.1）；
/// [root] **必须是绝对路径**（调用方先过 [resolveRemoteRoot]）—— 它是 agent 的越界防护基线，
/// 也是 `exec.run` 里 `cd` 的目标：给相对路径 / `~`，agent 的 `--root` 校验会直接拒绝启动
/// （实测：`[tree_agent] 缺少 --root <工作空间根绝对路径>` 后通道立刻关闭 ⇒ `handshake_failed`）。
///
/// `--idle-timeout-ms` **总是显式传**（[idleTimeoutMs]，缺省 [kAgentIdleTimeoutMs]）：
/// agent 的缺省是 0 = 永不，那是给"手工起一个 agent 玩"用的；由插件拉起的常驻 agent
/// 必须能**自己察觉断连**（物理断网时它收不到 EOF）——靠"这么久没有任何帧进来"自救退出，
/// 见 `keepalive.dart` 的成组注释（用户 2026-10-11 口径：执行器自觉优雅结束）。
String buildSpawnCommand({
  required String agentPath,
  required String root,
  required String token,
  int idleTimeoutMs = kAgentIdleTimeoutMs,
}) {
  final StringBuffer buffer = StringBuffer()
    ..write(posixSingleQuote(agentPath));
  buffer
    ..write(' --root ')
    ..write(posixSingleQuote(root.trim()));
  buffer
    ..write(' --token ')
    ..write(posixSingleQuote(token));
  buffer
    ..write(' --idle-timeout-ms ')
    ..write(idleTimeoutMs);
  return buffer.toString();
}

/// 把用户填的远端工作空间根解析成**绝对路径**（语义与 `tree_local_exec` 的
/// `resolveRemoteRoot` 一致，这里是插件侧的那一份）。
///
/// 规则：空 / `~` ⇒ 远端 `$HOME`；`~/x` 或相对路径 ⇒ 相对 `$HOME`；绝对路径 ⇒ 原样归一化。
/// 为什么不直接照发：SFTP 不展开 `~`，而 agent 的 `--root` 必须是绝对路径
/// （越界防护的基线）；归一化同时去掉尾斜杠与 `.`/`..`，避免"前缀判断把兄弟目录放进来"。
String resolveRemoteRoot(String configured, String home) {
  final String raw = configured.trim();
  final String joined;
  if (raw.isEmpty || raw == '~') {
    joined = home;
  } else if (raw.startsWith('~/')) {
    joined = '$home/${raw.substring(2)}';
  } else if (raw.startsWith('/')) {
    joined = raw;
  } else {
    joined = '$home/$raw';
  }
  return normalizePosixPath(joined);
}

/// POSIX 路径归一化（折叠 `//`、`.`、消解 `..`；保留前导 `/`）。
String normalizePosixPath(String input) {
  if (input.isEmpty) return '/';
  final bool absolute = input.startsWith('/');
  final List<String> parts = <String>[];
  for (final String part in input.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (parts.isNotEmpty && parts.last != '..') {
        parts.removeLast();
      } else if (!absolute) {
        parts.add('..');
      }
      continue;
    }
    parts.add(part);
  }
  final String joined = parts.join('/');
  if (absolute) return '/$joined';
  return joined.isEmpty ? '.' : joined;
}

/// 生成一次性握手 token（32 位十六进制，`Random.secure`）。
String newHandshakeToken({Random? random}) {
  final Random rng = random ?? Random.secure();
  final StringBuffer out = StringBuffer();
  for (int i = 0; i < 32; i++) {
    out.write(rng.nextInt(16).toRadixString(16));
  }
  return out.toString();
}

/// 一次完整的 bootstrap：**探架构 → 推送 → 拉起 → 握手**（协议 §7 的时序图）。
///
/// 六步、每步失败都有明确的 `error_kind`：
/// ① 连 SSH（`agent_unreachable`）② `uname -m`（不支持 ⇒ `arch_unsupported`）
/// ③ 安装路径 + `sha256sum` 对账 ④ 分块推送 `.part` + 校验 + `chmod +x` + `mv`（`push_failed`）
/// ⑤ `execute` 拉起（`spawn_failed`）⑥ `agent.hello` 握手（`handshake_failed`）。
///
/// **连接**由调用方建好（dialer 负责），本函数只管"在这条连接上把 agent 跑起来"。
Future<BootstrapResult> runBootstrap({
  required SshConnection connection,
  required TunnelConfig config,
  required AgentRequest agent,
  required AgentBinaryLoader loadBinary,
  required String token,
  void Function(String message)? log,
  int chunkBytes = kPushChunkBytes,
}) async {
  final String target = config.label;

  // ① 探架构。
  final ExecOutcome unameOutcome = await _exec(
    connection,
    'uname -m',
    kind: TunnelErrorKinds.agentUnreachable,
    what: '在 $target 上探测目标机架构',
  );
  if (unameOutcome.exitCode != 0) {
    throw BootstrapException(
      TunnelErrorKinds.agentUnreachable,
      '目标机没有可用的 `uname -m`（exit=${unameOutcome.exitCode}）：'
      '${unameOutcome.stderrText.trim()}',
    );
  }
  final String machine = unameOutcome.stdoutText.trim();
  final String? arch = mapArch(machine);
  if (arch == null) {
    throw BootstrapException(
      TunnelErrorKinds.archUnsupported,
      '目标机架构不支持：「$machine」（只支持 x86_64→amd64、aarch64/arm64→arm64；'
      '本方案随包只发 linux amd64 / arm64）',
    );
  }

  // ② HOME + 安装目录。
  final ExecOutcome homeOutcome = await _exec(
    connection,
    'printf $kHomeMarker%s "\$HOME"',
    kind: TunnelErrorKinds.agentUnreachable,
    what: '读取目标机 \$HOME',
  );
  final String home = _stripMarker(homeOutcome.stdoutText, kHomeMarker).trim();
  if (home.isEmpty) {
    throw BootstrapException(
      TunnelErrorKinds.agentUnreachable,
      '目标机取不到 \$HOME（stdout=${homeOutcome.stdoutText.trim()}）',
    );
  }
  final String installDir = _joinPosix(
    _resolveAgentsDir(config.agentsDir, home),
    agent.version,
  );

  // ③ 找一个"随包二进制"的本机字节（并核对核心声明的 sha256）。
  final AgentBinary binary = await loadBinary(agent, arch);
  final String remotePath = _joinPosix(installDir, binary.name);
  final String partPath = '$remotePath$kPushPartSuffix';

  await _exec(
    connection,
    "mkdir -p ${posixSingleQuote(installDir)}",
    kind: TunnelErrorKinds.pushFailed,
    what: '在 $target 上创建 agent 目录（$installDir）',
  );

  final ExecOutcome current = await _exec(
    connection,
    'if [ -f ${posixSingleQuote(remotePath)} ]; then '
    'sha256sum ${posixSingleQuote(remotePath)}; else echo $kMissingMarker; fi',
    kind: TunnelErrorKinds.pushFailed,
    what: '在 $target 上对账 agent 摘要',
  );
  final String? remoteSha = _parseSha256(current.stdoutText);
  final bool needPush = remoteSha != binary.sha256;
  if (needPush) {
    log?.call(
      'agent 需要推送（$target）：目标机 ${remoteSha == null ? '缺失' : shortDigest(remoteSha)} '
      '≠ 随包 ${shortDigest(binary.sha256)}',
    );
    await _pushBinary(
      connection: connection,
      partPath: partPath,
      bytes: binary.bytes,
      chunkBytes: chunkBytes,
      log: log,
    );
    final ExecOutcome pushed = await _exec(
      connection,
      'sha256sum ${posixSingleQuote(partPath)}',
      kind: TunnelErrorKinds.pushFailed,
      what: '校验刚推送的 agent',
    );
    final String? pushedSha = _parseSha256(pushed.stdoutText);
    if (pushedSha != binary.sha256) {
      throw BootstrapException(
        TunnelErrorKinds.pushFailed,
        '推送后校验不一致（目标机 ${pushedSha == null ? '取不到摘要' : shortDigest(pushedSha)} '
        '≠ 随包 ${shortDigest(binary.sha256)}）',
      );
    }
    await _exec(
      connection,
      'chmod +x ${posixSingleQuote(partPath)} && '
      'mv -f ${posixSingleQuote(partPath)} ${posixSingleQuote(remotePath)}',
      kind: TunnelErrorKinds.pushFailed,
      what: '把 agent 落位（chmod +x + mv）',
    );
  } else {
    log?.call('目标机上的 agent 与随包一致（$target，${shortDigest(binary.sha256)}）：跳过推送');
    // 已有文件也必须可执行（例如用户手工改过权限）。
    await _exec(
      connection,
      'chmod +x ${posixSingleQuote(remotePath)}',
      kind: TunnelErrorKinds.pushFailed,
      what: '确认 agent 可执行',
    );
  }

  // ④ 拉起常驻通道。
  //
  // `--root` **必须**是绝对路径：它既是 agent 的越界防护基线，也是 `exec.run` 里
  // `cd` 的目标。所以先解析（空 / `~` / 相对 ⇒ 相对远端 `$HOME`），再确保目录存在
  // —— 目录不存在的话，之后**每一条** `cd <root> && …` 都会失败。
  final String remoteRoot = resolveRemoteRoot(config.root, home);
  await _exec(
    connection,
    'mkdir -p ${posixSingleQuote(remoteRoot)}',
    kind: TunnelErrorKinds.spawnFailed,
    what: '确保远端工作空间根存在（$remoteRoot）',
  );
  final String spawn = buildSpawnCommand(
    agentPath: remotePath,
    root: remoteRoot,
    token: token,
  );
  log?.call('拉起 agent（$target）：$remotePath --root $remoteRoot --token ***');
  final SshChannel channel;
  try {
    channel = await connection.openChannel(spawn);
  } catch (error) {
    throw BootstrapException(
      TunnelErrorKinds.spawnFailed,
      '拉起 agent 失败（$target）：$error',
    );
  }

  final AgentClient client = AgentClient(channel, log: log);

  // ⑤ 握手。
  final Map<String, dynamic> helloResult;
  try {
    helloResult = await client.call(AgentMethods.hello, <String, dynamic>{
      'protocol': kAgentProtocolVersion,
      'token': token,
      'agent_version': agent.version,
    });
  } on RpcException catch (error) {
    await client.close();
    throw BootstrapException(
      TunnelErrorKinds.handshakeFailed,
      'agent 握手被拒（$target）：${describeRpcCode(error.code)}（code=${error.code}）'
      '${error.code == TunnelErrorCodes.protocolMismatch ? '——协议 $kAgentProtocolVersion 不匹配，请升级随包 agent' : ''}',
    );
  } on AgentChannelClosed catch (error) {
    await client.close();
    throw BootstrapException(
      TunnelErrorKinds.handshakeFailed,
      'agent 握手前通道就断了（$target）：$error',
    );
  }
  final AgentHello hello = AgentHello.parse(helloResult);
  if (hello.protocol != kAgentProtocolVersion) {
    await client.close();
    throw BootstrapException(
      TunnelErrorKinds.handshakeFailed,
      'agent 协议不匹配（$target）：期望 $kAgentProtocolVersion，实际 ${hello.protocol}'
      '——请升级随包 agent',
    );
  }
  if (hello.agentVersion.isNotEmpty &&
      agent.version.isNotEmpty &&
      hello.agentVersion != agent.version) {
    // 不致命（"要不要重推"的判据是 sha256，不是版本串），但必须留痕：
    // 常见成因是插件与 agent 的 `--define kAgentVersion` 不一致（各端各自编译）。
    log?.call(
      '注意：agent 自报版本 ${hello.agentVersion}，插件按版本 ${agent.version} 安装'
      '（$target）——重推判据是 sha256，本次继续',
    );
  }
  if (hello.arch.isNotEmpty && mapArch(hello.arch) != arch) {
    await client.close();
    throw BootstrapException(
      TunnelErrorKinds.handshakeFailed,
      'agent 自报架构（${hello.arch}）与 `uname -m`（$machine）不一致（$target）',
    );
  }

  // ⑥ 探登录外壳（一次、按隧道缓存；探测失败不致命 —— 原样发）。
  final LoginShell loginShell = LoginShell(
    template: config.loginShell,
    log: log,
    prober: (String command) async {
      final ExecOutcome outcome = await connection.exec(command);
      return outcome.exitCode;
    },
  );
  await loginShell.resolve();

  final String root = hello.root.trim().isNotEmpty
      ? hello.root.trim()
      : config.root;
  log?.call(
    '隧道就绪（$target）：agent ${hello.agentVersion} / ${hello.os} ${hello.arch} / '
    'root=${root.isEmpty ? '(HOME)' : root}',
  );
  return BootstrapResult(
    client: client,
    hello: hello,
    root: root,
    installPath: remotePath,
    binary: binary,
    loginShell: loginShell,
  );
}

Future<void> _pushBinary({
  required SshConnection connection,
  required String partPath,
  required List<int> bytes,
  required int chunkBytes,
  void Function(String message)? log,
}) async {
  final int effective = chunkBytes <= 0 ? kPushChunkBytes : chunkBytes;
  int sent = 0;
  int index = 0;
  while (sent < bytes.length) {
    final int end = min(sent + effective, bytes.length);
    final String encoded = base64.encode(bytes.sublist(sent, end));
    // 第一块截断（`>`），其余追加（`>>`）：base64 的输出字符集不含引号，单引号包裹安全。
    final String redirect = index == 0 ? '>' : '>>';
    await _exec(
      connection,
      "printf %s '$encoded' | base64 -d $redirect ${posixSingleQuote(partPath)}",
      kind: TunnelErrorKinds.pushFailed,
      what: '推送 agent 第 ${index + 1} 块（${end - sent} 字节）',
    );
    sent = end;
    index++;
  }
  log?.call('agent 推送完成：${bytes.length} 字节 / $index 块');
}

Future<ExecOutcome> _exec(
  SshConnection connection,
  String command, {
  required String kind,
  required String what,
}) async {
  try {
    return await connection.exec(command);
  } catch (error) {
    throw BootstrapException(kind, '$what 失败：$error');
  }
}

String _stripMarker(String text, String marker) {
  final int index = text.indexOf(marker);
  return index < 0 ? text : text.substring(index + marker.length);
}

/// 从 `sha256sum` 输出里取第一个 64 位十六进制（格式：`<hash>  <path>`）。
String? _parseSha256(String text) {
  final RegExpMatch? match = RegExp(r'\b([0-9a-fA-F]{64})\b').firstMatch(text);
  return match?.group(1)?.toLowerCase();
}

String _resolveAgentsDir(String configured, String home) {
  if (configured.isEmpty) return _joinPosix(home, kAgentInstallDir);
  if (configured.startsWith('~')) {
    return '$home${configured.substring(1)}';
  }
  return configured;
}

String _joinPosix(String dir, String name) {
  if (dir.isEmpty) return name;
  final String trimmed = dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
  return '$trimmed/$name';
}
