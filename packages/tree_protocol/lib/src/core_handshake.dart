import 'dart:convert';

/// 核心进程「就绪握手」信封（CLI 首行 stdout → Flutter 父进程）。
///
/// 桌面分支中核心进程与前端是两个进程（见迁移方案 §4）：核心绑定
/// 127.0.0.1 的**随机空闲端口**，并生成本次会话专用的**随机本地 token**，
/// 二者随本信封以单行 JSON 发布出去。父进程解析后据此设置
/// `ApiService.baseUrl` / `WebSocketService.baseUrl` 与 token，
/// 因此前端不再需要任何硬编码的后端地址或登录流程。
///
/// 该信封同时是**唯一**的进程间启动契约：CLI 只依赖它，前端只解析它，
/// 二者无需共享命令行参数约定。
class CoreHandshake {
  const CoreHandshake({
    required this.port,
    required this.token,
    required this.pid,
    required this.version,
    this.host = '127.0.0.1',
  });

  /// `event` 字段固定值：核心已就绪。
  static const String readyEvent = 'ready';

  /// 监听主机（回环，不接受外部连接）。
  final String host;

  /// 实际监听端口（由内核分配，非请求值）。
  final int port;

  /// 本次运行的一次性本地 token（进程退出即失效）。
  final String token;

  /// 核心进程 pid（父进程用于退出时兜底清理）。
  final int pid;

  /// 核心版本号。
  final String version;

  /// HTTP 基址，形如 `http://127.0.0.1:54321`。
  String get httpBaseUrl => 'http://$host:$port';

  /// WebSocket 基址，形如 `ws://127.0.0.1:54321`。
  String get wsBaseUrl => 'ws://$host:$port';

  /// 序列化为信封 Map。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'event': readyEvent,
    'host': host,
    'port': port,
    'token': token,
    'pid': pid,
    'version': version,
  };

  /// 序列化为**单行** JSON（stdout 一行，父进程逐行读取）。
  String encode() => jsonEncode(toJson());

  /// 解析握手行；非就绪信封、非法 JSON 或缺少 port/token 时返回 null。
  ///
  /// 父进程在等待握手时可能先收到核心的普通日志行，因此解析失败必须是
  /// **可判定的 null** 而非抛异常，调用方据此继续读下一行。
  static CoreHandshake? decode(String line) {
    final String text = line.trim();
    if (text.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    if (decoded['event'] != readyEvent) return null;
    final int? port = (decoded['port'] as num?)?.toInt();
    final String? token = decoded['token'] as String?;
    if (port == null || port <= 0 || token == null || token.isEmpty) {
      return null;
    }
    return CoreHandshake(
      host: decoded['host'] as String? ?? '127.0.0.1',
      port: port,
      token: token,
      pid: (decoded['pid'] as num?)?.toInt() ?? 0,
      version: decoded['version'] as String? ?? '',
    );
  }
}
