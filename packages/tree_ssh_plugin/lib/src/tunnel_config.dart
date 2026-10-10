import 'dart:io';

/// 一条隧道的 SSH 配置（L1 `tunnel.ensure.config`，与核心 `SshConfig` 同构）。
///
/// 只解析必要字段，且**刻意保留"未填"与"填空"的区别**：
/// - [loginShell]：`null` = 用内置候选（默认开），`''` = 显式关，非空 = 自定义模板；
/// - [root]：空 = 远端登录用户 HOME（由 agent 侧解析）。
///
/// 凭据（[password] / [keyPassphrase]）**永不进日志、永不进 `tunnel.state` 回包**：
/// 要打日志一律用 [label]（`host:port/user`）或 [redacted]。
class TunnelConfig {
  const TunnelConfig({
    required this.host,
    this.port = 22,
    this.username = '',
    this.password = '',
    this.keyPath = '',
    this.keyPassphrase = '',
    this.root = '',
    this.loginShell,
    this.agentsDir = '',
  });

  /// 从 L1 的 `config` 对象解析；不是映射或缺 `host` ⇒ null（调用方给 `config_incomplete`）。
  static TunnelConfig? parse(Object? raw) {
    if (raw is! Map) return null;
    final Map<String, dynamic> map = raw.map(
      (dynamic k, dynamic v) => MapEntry('$k', v),
    );
    final String host = (map['host'] ?? '').toString().trim();
    if (host.isEmpty) return null;
    return TunnelConfig(
      host: host,
      port: _int(map['port'], 22),
      username: (map['username'] ?? map['user'] ?? '').toString().trim(),
      password: (map['password'] ?? '').toString(),
      keyPath: (map['key_path'] ?? map['keyPath'] ?? '').toString().trim(),
      keyPassphrase: (map['key_passphrase'] ?? map['keyPassphrase'] ?? '')
          .toString(),
      root: (map['root'] ?? '').toString().trim(),
      loginShell: _loginShell(map['login_shell'] ?? map['loginShell']),
      agentsDir: (map['agents_dir'] ?? map['agentsDir'] ?? '').toString().trim(),
    );
  }

  final String host;
  final int port;
  final String username;
  final String password;

  /// 私钥路径（支持 `~`）；为空则用 [password]。
  final String keyPath;
  final String keyPassphrase;

  /// 远端工作空间根（空 = 远端登录用户 HOME）。
  final String root;

  /// 登录外壳模板三态（同核心 `SshConfig.loginShell`）。
  final String? loginShell;

  /// 目标机上 agent 的驻留目录（空 = `~/.tree/agent`）。
  final String agentsDir;

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

  /// **去重键**：`host|port|username|root|login_shell`（任务书口径）。
  ///
  /// `login_shell` 的 `null`（默认）与 `''`（显式关）**行为不同**，所以键里必须区分：
  /// 分别记成 `~` 与 `!`。
  String get dedupeKey =>
      '$host|$port|$username|$root|${loginShell == null ? '~' : (loginShell!.isEmpty ? '!' : loginShell)}';

  /// 可安全打印的形态（**不含凭据**）。
  String get label => '$host:$port/$username';

  /// 私钥路径展开 `~`（dartssh2 不做这个展开；核心侧 [SshConfig.resolvedKeyPath] 同理）。
  ///
  /// **不引 `package:path`**（本插件只允许 `dartssh2` + `tree_tunnel_protocol` 两个依赖，
  /// 而 `path` 只是 dartssh2 的传递依赖、直接 import 会踩 `depend_on_referenced_packages`）：
  /// 这里手写一段"把 `~/x/y` 拼到本机 HOME 下"的最小逻辑。
  String resolvedKeyPath() {
    if (!keyPath.startsWith('~')) return keyPath;
    final String home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    if (home.isEmpty) return keyPath;
    final String rest = keyPath.substring(1).replaceAll('\\', '/');
    // HOME 在 Windows 上长 `C:\Users\x`，在 POSIX 上长 `/home/x`：跟着它自己的分隔符拼。
    final String separator = home.contains('\\') ? '\\' : '/';
    final List<String> parts = rest
        .split('/')
        .where((String s) => s.isNotEmpty)
        .toList(growable: false);
    final String trimmedHome = home.endsWith(separator)
        ? home.substring(0, home.length - separator.length)
        : home;
    if (parts.isEmpty) return trimmedHome;
    return '$trimmedHome$separator${parts.join(separator)}';
  }

  /// 日志/事件里用的形态（**不含凭据**）。
  Map<String, dynamic> redacted() => <String, dynamic>{
    'host': host,
    'port': port,
    'username': username,
    'auth': password.isNotEmpty
        ? 'password'
        : (keyPath.isNotEmpty ? 'key' : 'none'),
    if (root.isNotEmpty) 'root': root,
    if (loginShell != null) 'login_shell': loginShell,
  };

  static String? _loginShell(Object? raw) {
    if (raw == null) return null;
    if (raw is bool) return raw ? null : '';
    return raw.toString().trim();
  }

  static int _int(Object? raw, int fallback) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? fallback;
    return fallback;
  }
}
