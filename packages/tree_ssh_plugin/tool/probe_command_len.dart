/// 一次性探针（**不是产品代码**）：实测一条 SSH `exec` 命令里能塞多长的 base64 载荷。
///
/// 为什么要它：`exec.spawn` 的上限不是"ARG_MAX"而是**SSH 报文上限**——`exec` 是一个
/// 信道请求报文，长度受协商的 max packet size（默认 32768）约束，超了 sshd 会当成协议
/// 错误直接断连（实测现象：`SSHStateError(SSH connection closed)`）。
/// 所以推送 agent 的分块大小必须**实测**出来，不能拍脑袋。
///
/// 用法：`dart run tool/probe_command_len.dart <host> <port> <user> <keyPath>`
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

Future<void> main(List<String> args) async {
  if (args.length < 4) {
    stderr.writeln('用法：dart run tool/probe_command_len.dart <host> <port> <user> <keyPath>');
    exitCode = 2;
    return;
  }
  final String host = args[0];
  final int port = int.parse(args[1]);
  final String user = args[2];
  final String keyText = File(args[3]).readAsStringSync();
  final List<SSHKeyPair> keys = SSHKeyPair.fromPem(keyText);

  for (final int rawBytes in <int>[98304, 131072, 163840, 196608, 229376]) {
    SSHClient? client;
    try {
      client = SSHClient(
        await SSHSocket.connect(host, port, timeout: const Duration(seconds: 10)),
        username: user,
        identities: keys,
      );
      final String payload = base64Encode(List<int>.filled(rawBytes, 0x41));
      final String cmd =
          "printf %s '$payload' > /tmp/probe.b64 && wc -c < /tmp/probe.b64";
      final r = await client.runWithResult(cmd);
      final int? written = int.tryParse(utf8.decode(r.stdout).trim());
      stdout.writeln(
        'raw=$rawBytes  base64=${payload.length}  → OK（远端收到 $written 字节）',
      );
    } catch (error) {
      stdout.writeln('raw=$rawBytes  → 失败：$error');
    } finally {
      try {
        client?.close();
      } catch (_) {}
    }
  }
}
