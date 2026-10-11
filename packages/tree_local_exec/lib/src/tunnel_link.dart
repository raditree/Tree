import 'dart:async';

import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

/// 一次**建立隧道**的请求（字段与核心 `SshConfig` 同构）。
///
/// 为什么不让 `tree_local_exec` 直接用 `SshConfig`：那是**核心**的类型
/// （`packages/tree_core/lib/src/settings/ssh_config.dart`），本包只认"连接描述"，
/// 由核心在 `sshIoFactory` 里翻译一次。这样本包不需要（也不该）依赖 tree_core。
class TunnelConnectRequest {
  const TunnelConnectRequest({
    required this.host,
    this.port = 22,
    this.username = '',
    this.password = '',
    this.keyPath = '',
    this.keyPassphrase = '',
    this.root = '',
    this.loginShell,
    this.heartbeatInterval = const Duration(seconds: 10),
    this.maxMissedHeartbeats = 3,
  });

  final String host;
  final int port;
  final String username;
  final String password;
  final String keyPath;
  final String keyPassphrase;

  /// 远端工作空间根（空 = 远端登录用户 HOME）。
  final String root;

  /// 登录外壳模板三态：`null` = 内置候选（默认开）、`''` = 显式关、非空 = 自定义模板。
  final String? loginShell;

  /// 心跳间隔 I（核心侧判活窗口同时用它）。
  final Duration heartbeatInterval;

  /// 连续丢失阈值 N。
  final int maxMissedHeartbeats;

  /// 给插件看的下行形态（**不含日志用途**：调用方要日志请用 [redacted]）。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'host': host,
    'port': port,
    'username': username,
    if (password.isNotEmpty) 'password': password,
    if (keyPath.isNotEmpty) 'key_path': keyPath,
    if (keyPassphrase.isNotEmpty) 'key_passphrase': keyPassphrase,
    if (root.isNotEmpty) 'root': root,
    if (loginShell != null) 'login_shell': loginShell,
    'heartbeat_interval_ms': heartbeatInterval.inMilliseconds,
    'max_missed': maxMissedHeartbeats,
  };

  /// 可安全打印的形态（**不含任何凭据**）。
  Map<String, dynamic> redacted() => <String, dynamic>{
    'host': host,
    'port': port,
    'username': username,
    'auth': password.isNotEmpty
        ? 'password'
        : (keyPath.isNotEmpty ? 'key' : 'none'),
    if (root.isNotEmpty) 'root': root,
  };
}

/// 一条隧道的运行快照（插件 `tunnel.state` 的投影）。
class TunnelSnapshot {
  const TunnelSnapshot({
    required this.connId,
    required this.state,
    this.root = '',
    this.attempt = 0,
    this.elapsedMs = 0,
    this.lastError = '',
    this.agent = const <String, dynamic>{},
  });

  final String connId;

  /// [TunnelStates] 之一。
  final String state;

  /// 远端已解析的绝对根（`ready` 后才有意义）。
  final String root;

  /// 当前是第几次重连尝试。
  final int attempt;

  /// 这一轮退避已经用了多久（毫秒）。
  final int elapsedMs;

  /// 最近一次失败的可读原因（空 = 没失败过）。
  final String lastError;

  /// agent 上报的平台信息（`os` / `arch` / `agent_version` / `pid` …）。
  final Map<String, dynamic> agent;

  bool get ready => state == TunnelStates.ready;

  bool get down => state == TunnelStates.down;

  @override
  String toString() =>
      'TunnelSnapshot($connId, $state, attempt=$attempt, ${elapsedMs}ms'
      '${lastError.isEmpty ? '' : ', last=$lastError'})';
}

/// 插件推来的**通知**事件（`tunnel/event`）。
class TunnelShellEvent {
  const TunnelShellEvent({
    required this.connId,
    required this.kind,
    this.shellId = '',
    this.data = const <int>[],
    this.exitCode = -1,
  });

  final String connId;

  /// [TunnelEventKind] 之一。
  final String kind;

  final String shellId;

  /// `shell.data` 的原始字节（已从 base64 解出）。
  final List<int> data;

  /// `shell.exit` 的退出码（拿不到 -1）。
  final int exitCode;
}

/// **中转站**的可用性 + 建隧道入口。
///
/// 实现由核心提供（`packages/tree_core` 的 `PluginTunnelLink`，包住 `PluginBus`）；
/// 本包只声明形状，因此 `TunnelSshTransport` 能用假实现单测（本机没有可连的 sshd，
/// 真链路只能靠 WSL/Docker 里的端到端）。
abstract interface class TunnelLink {
  /// 中转站是否**在场且可用**：插件已启用、进程在跑、且申报了 `ssh-executor` 能力。
  ///
  /// `false` ⇒ 核心压根不该走这条路（直接回退内置 dartssh2），
  /// 因此这是"有没有中转站"这一维的**唯一判据**。
  bool get available;

  /// 建立（或复用）一条隧道；失败抛 [TunnelUnavailableException]。
  ///
  /// 同一条连接描述（host/port/username/root/login_shell）**复用同一条隧道**。
  Future<TunnelSession> ensure(TunnelConnectRequest request);
}

/// 一条已建立的隧道会话。
abstract interface class TunnelSession {
  String get connId;

  /// 远端已解析的绝对工作空间根（来自 agent）。
  String get root;

  /// agent 上报的平台信息（诊断用）。
  Map<String, dynamic> get agent;

  /// 把一次 L2 请求透传给 agent；`error` 抛 [RpcException]。
  Future<Object?> request(String method, Map<String, dynamic> params);

  /// 拉取状态（**权威判活面**：核心每心跳拉一次）。
  Future<TunnelSnapshot> snapshot();

  /// 中转站插件**此刻还在不在**（核心 `PluginBus` 的实时查询，不是缓存）。
  ///
  /// 用途只有一个：心跳失败时区分"插件没了"（⇒ 判死、回退内置、明示）与
  /// "插件还在、只是这条隧道的结果拉不到"（⇒ 不判死，等它回来 —— 用户 2026-10-11 口径）。
  bool get pluginAvailable;

  /// [pluginAvailable] 为 false 时的可读原因（给日志与右栏用）。
  String get unavailableReason;

  /// 重置退避并立即重试（用户的「重连」/ 执行站 `ssh.reconnect`）。
  Future<void> reconnect();

  /// 收掉这条隧道（**不杀** agent，它托管的后台任务照常跑）。
  Future<void> close();

  /// 插件推来的通知（`shell.data` / `shell.exit` / `state`）。
  Stream<TunnelShellEvent> get events;
}

/// 中转站**建立不了**这条隧道时的失败（带核心据以决策的 `kind`）。
///
/// 为什么要 `kind` 而不是一个字符串异常：核心要**分级**处理 ——
/// "插件在但隧道建不起来"（可回退）与"配置本身不完整"（回退也一样连不上，不该回退）
/// 是两种完全不同的处置，用异常文本猜是不可靠的。
class TunnelUnavailableException implements Exception {
  TunnelUnavailableException(this.kind, this.message);

  /// [TunnelErrorKinds] 之一。
  final String kind;

  final String message;

  /// 核心是否应当**回退内置 dartssh2**（见 [TunnelErrorKinds.fallbackKinds]）。
  bool get shouldFallback => TunnelErrorKinds.fallbackKinds.contains(kind);

  @override
  String toString() => 'TunnelUnavailableException($kind): $message';
}

/// **已判死的中转站**：核心据此把缓存的 IO 撤换掉，让下一次解析走内置实现。
///
/// 为什么需要它：`WorkspaceToolRunner._ios` 是**按 owner 永久缓存**的（只有核心关停才清），
/// 所以"隧道退避耗尽"这件事如果只写在传输层里，缓存里那条死链路会被一直用下去 ——
/// 那就等于"降级只发生在有没有插件这一维"这条红线被悄悄破了。
abstract interface class FallbackableWorkspace {
  /// 中转站已判死（退避耗尽 / 隧道不可调和）⇒ 核心应撤换本 IO。
  bool get tunnelDown;

  /// 撤换原因（可读，进日志 / 右栏）。
  String get fallbackReason;
}
