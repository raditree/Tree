import 'dart:io';

import 'package:path/path.dart' as p;

/// SSH 工作空间配置（写在 `agents/<id>.yaml` 的 `ssh:` 段里）。
///
/// 设计取舍：
/// - **凭据落在用户自己的 agent 配置文件里**（和模型 api_key 同一策略：桌面单用户
///   形态下用户必须能直接看到并替换自己的凭据；文件在用户私有目录）。
/// - [redacted] 只暴露"谁连哪台机器"，**永不带密钥**——日志、错误文案、
///   自检输出一律用它，避免密钥随日志外泄。
/// - [parse] 宽容读取手写 YAML（端口可写字符串、key_path 支持 `~`），
///   但**必填项缺失时返回 null**，由调用方给出可读错误。
class SshConfig {
  const SshConfig({
    required this.host,
    this.port = 22,
    this.username = '',
    this.password = '',
    this.keyPath = '',
    this.keyPassphrase = '',
  });

  /// 从 agent yaml 的 `ssh:` 映射解析；缺少 host 时返回 null。
  static SshConfig? parse(Object? raw) {
    if (raw is! Map) return null;
    final Map<String, dynamic> map = raw.map(
      (dynamic k, dynamic v) => MapEntry('$k', v),
    );
    final String host = (map['host'] ?? '').toString().trim();
    if (host.isEmpty) return null;
    return SshConfig(
      host: host,
      port: _port(map['port']),
      username: (map['username'] ?? map['user'] ?? '').toString().trim(),
      password: (map['password'] ?? '').toString(),
      keyPath: (map['key_path'] ?? map['keyPath'] ?? '').toString().trim(),
      keyPassphrase: (map['key_passphrase'] ?? map['keyPassphrase'] ?? '')
          .toString(),
    );
  }

  final String host;
  final int port;
  final String username;
  final String password;

  /// 私钥路径（支持 `~`）；为空则用 [password]。
  final String keyPath;
  final String keyPassphrase;

  /// 是否具备建立连接的最小信息。
  bool get isComplete =>
      host.isNotEmpty &&
      username.isNotEmpty &&
      (password.isNotEmpty || keyPath.isNotEmpty);

  /// 缺失项（用于可读错误）。
  List<String> get missingFields => <String>[
    if (host.isEmpty) 'host',
    if (username.isEmpty) 'username',
    if (password.isEmpty && keyPath.isEmpty) 'password 或 key_path',
  ];

  /// 可安全打印的形态（**不含任何凭据**）。
  Map<String, dynamic> redacted() => <String, dynamic>{
    'host': host,
    'port': port,
    'username': username,
    'auth': password.isNotEmpty
        ? 'password'
        : (keyPath.isNotEmpty ? 'key' : 'none'),
  };

  /// 持久化形态（**含凭据**，写进 agent yaml；与模型 api_key 同一策略）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'host': host,
    'port': port,
    if (username.isNotEmpty) 'username': username,
    if (password.isNotEmpty) 'password': password,
    if (keyPath.isNotEmpty) 'key_path': keyPath,
    if (keyPassphrase.isNotEmpty) 'key_passphrase': keyPassphrase,
  };

  /// 展开 `~` 为用户目录（dartssh2 不做这个展开）。
  String resolvedKeyPath() {
    if (!keyPath.startsWith('~')) return keyPath;
    final String home =
        Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    if (home.isEmpty) return keyPath;
    // 用 p.join 拼接，避免出现 C:\Users\x/.ssh/id_ed25519 这种混合分隔符
    final String rest = keyPath.substring(1).replaceAll('\\', '/');
    return p.joinAll(<String>[
      home,
      ...rest.split('/').where((String s) => s.isNotEmpty),
    ]);
  }

  @override
  String toString() => 'SshConfig(${redacted()})';

  static int _port(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? 22;
    return 22;
  }
}
