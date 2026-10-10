import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'tunnel_config.dart';

/// 一次性远端命令的结果（bootstrap 的每一步都靠它）。
class ExecOutcome {
  const ExecOutcome({
    required this.exitCode,
    this.stdout = const <int>[],
    this.stderr = const <int>[],
  });

  final int exitCode;
  final List<int> stdout;
  final List<int> stderr;

  String get stdoutText => utf8.decode(stdout, allowMalformed: true);
  String get stderrText => utf8.decode(stderr, allowMalformed: true);

  @override
  String toString() => 'ExecOutcome(exit=$exitCode)';
}

/// **常驻通道**的最小面：`tree_agent` 的 stdin/stdout + 生命周期。
///
/// 刻意只暴露这一件事——agent 的全部能力都走这条通道上的行分隔 JSON-RPC，
/// 插件不需要（也不许）在这里加别的 IO。
abstract class SshChannel {
  /// agent 的 stdout 字节流（L2 帧的来源）。
  Stream<List<int>> get stdout;

  /// agent 的 stderr 字节流（**只记日志**：agent 的日志不走协议）。
  Stream<List<int>> get stderr;

  /// 往 agent 的 stdin 写字节（一帧一条）。
  void write(List<int> bytes);

  /// 通道结束时的退出码（拿不到给 `-1`；**一定收口**）。
  Future<int> get exitCode;

  /// 收掉这条通道（EOF + close）。**幂等**。
  Future<void> close();
}

/// 一条 SSH 连接的最小面（可注入：单测用假实现，**不碰真网络**）。
abstract class SshConnection {
  /// 跑一条一次性命令（bootstrap / 登录外壳探测）。
  Future<ExecOutcome> exec(String command);

  /// 起一条**常驻** exec 通道（拉 agent 用）。
  Future<SshChannel> openChannel(String command);

  /// 关掉整条 SSH 连接（通道随之结束 ⇒ agent 进程退出，其托管的后台任务不受影响）。
  Future<void> close();
}

/// 连接工厂：`config → 连接`。测试注入假 dialer 就能钉住 bootstrap 的全部命令形状。
typedef SshDialer = Future<SshConnection> Function(TunnelConfig config);

/// SSH 建连/认证失败（**可读原因，不含凭据**）。
class SshDialException implements Exception {
  SshDialException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// **本机侧**配置问题（私钥文件不存在 / 无法解析）。
///
/// 与 [SshDialException] 分开是为了 `error_kind` 能说实话：这类问题**回退内置 dartssh2
/// 也一样连不上** ⇒ 映射成 `config_incomplete`（协议 §5：不回退），而不是
/// `agent_unreachable`（回退）——否则核心会把"用户私钥填错"显示成"目标机连不上"。
class SshConfigException extends SshDialException {
  SshConfigException(super.message);
}

/// 生产实现：dartssh2（`SSHSocket` + `SSHClient`）。
///
/// **不建 SFTP**：稳态数据面全走常驻通道的 JSON-RPC（协议 §0/§2）。SFTP 只在旧模型里
/// 用来"开多通道"，而"服务端拒绝新通道 ⇒ 整条链路哑掉"正是本次要摆脱的短板。
///
/// `keepAliveInterval` 保留 dartssh2 的内置 SSH 保活（global request，不占 channel）：
/// 它是"TCP 已经断了"的一层兜底探测；**真正的判活面仍是 `tunnel.state`**。
class DartSshDialer {
  const DartSshDialer({this.keepAliveInterval = const Duration(seconds: 10)});

  final Duration keepAliveInterval;

  /// 建连（供 [SshDialer] 位置使用：`DartSshDialer().call`）。
  Future<SshConnection> call(TunnelConfig config) async {
    List<SSHIdentity>? identities;
    if (config.keyPath.isNotEmpty) {
      final String path = config.resolvedKeyPath();
      final File keyFile = File(path);
      if (!keyFile.existsSync()) {
        throw SshConfigException('私钥文件不存在：$path');
      }
      try {
        identities = SSHKeyPair.fromPem(
          keyFile.readAsStringSync(),
          config.keyPassphrase.isEmpty ? null : config.keyPassphrase,
        );
      } catch (error) {
        // 异常文本可能带 pem 解析细节；只报"解析失败"，不把凭据/密钥体带出去。
        throw SshConfigException('私钥无法解析（${config.label}）：$error');
      }
    }

    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(config.host, config.port);
    } catch (error) {
      throw SshDialException('无法连接 ${config.label}：$error');
    }

    final SSHClient client = SSHClient(
      socket,
      username: config.username,
      identities: identities,
      onPasswordRequest: config.password.isEmpty
          ? null
          : () => config.password,
      keepAliveInterval: keepAliveInterval,
    );
    try {
      await client.authenticated;
    } catch (error) {
      client.close();
      throw SshDialException('SSH 认证失败（${config.label}）：$error');
    }
    return DartSshConnection(client);
  }
}

/// dartssh2 的 [SshConnection] 实现。
class DartSshConnection implements SshConnection {
  DartSshConnection(this._client);

  final SSHClient _client;

  @override
  Future<ExecOutcome> exec(String command) async {
    try {
      final SSHRunResult result = await _client.runWithResult(command);
      return ExecOutcome(
        exitCode: result.exitCode ?? -1,
        stdout: result.stdout,
        stderr: result.stderr,
      );
    } catch (error) {
      throw SshDialException('远端命令执行失败：$error');
    }
  }

  @override
  Future<SshChannel> openChannel(String command) async {
    try {
      final SSHSession session = await _client.execute(command);
      return DartSshChannel(session);
    } catch (error) {
      throw SshDialException('无法打开常驻通道：$error');
    }
  }

  @override
  Future<void> close() async {
    _client.close();
  }
}

/// dartssh2 的常驻通道实现（`SSHSession`）。
class DartSshChannel implements SshChannel {
  DartSshChannel(this._session) {
    _done = _session.done.then<int>((_) => _session.exitCode ?? -1);
  }

  final SSHSession _session;
  late final Future<int> _done;

  @override
  Stream<List<int>> get stdout => _session.stdout;

  @override
  Stream<List<int>> get stderr => _session.stderr;

  @override
  void write(List<int> bytes) => _session.write(Uint8List.fromList(bytes));

  @override
  Future<int> get exitCode => _done;

  @override
  Future<void> close() async {
    // 只关这一条通道（`SSHSession.close` 是 void 且幂等）；**不**关 `SSHClient`
    // ——整条连接归 [DartSshConnection.close] 管，别在这里连带拆掉。
    _session.close();
  }
}
