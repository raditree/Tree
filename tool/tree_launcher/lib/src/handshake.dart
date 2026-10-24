import 'dart:convert';

/// 核心握手的最小副本（**不 import tree_protocol，保持纯 Dart 零依赖**）。
///
/// 字段口径与 `packages/tree_protocol/lib/src/core_handshake.dart` 一致：
/// `event=ready` 单行 JSON，含 host/port/token/pid/version，可选 `data_root`。
class MinimalHandshake {
  const MinimalHandshake({
    required this.host,
    required this.port,
    required this.token,
    this.pid = 0,
    this.version = '',
    this.dataRoot = '',
  });

  final String host;
  final int port;
  final String token;
  final int pid;
  final String version;
  final String dataRoot;

  String get httpBaseUrl => 'http://$host:$port';

  /// 解析单行握手；日志行 / 非法 JSON 返回 null（继续读下一行）。
  static MinimalHandshake? decode(String line) {
    final String text = line.trim();
    if (text.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    if (decoded['event'] != 'ready') return null;
    final Object? rawPort = decoded['port'];
    final Object? rawToken = decoded['token'];
    final int? port = rawPort is num ? rawPort.toInt() : null;
    final String? token = rawToken is String ? rawToken : null;
    if (port == null || port <= 0 || token == null || token.isEmpty) {
      return null;
    }
    final Object? rawHost = decoded['host'];
    final Object? rawPid = decoded['pid'];
    final Object? rawVersion = decoded['version'];
    final Object? rawRoot = decoded['data_root'];
    return MinimalHandshake(
      host: rawHost is String && rawHost.isNotEmpty ? rawHost : '127.0.0.1',
      port: port,
      token: token,
      pid: rawPid is num ? rawPid.toInt() : 0,
      version: rawVersion is String ? rawVersion : '',
      dataRoot: rawRoot is String ? rawRoot : '',
    );
  }
}
