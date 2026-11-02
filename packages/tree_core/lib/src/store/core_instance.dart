import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'atomic_file.dart';

/// 当前核心的**实例发现记录**（`<数据根>/runtime/core.json`）。
///
/// 为什么需要它：核心必须是**单实例**。loader 双击一次就 `Process.start` 一个
/// `tree_core.exe`，而每个核心都会各自拉起一整套插件与界面窗口、并发写同一份数据根
/// （2026-11-01 实测出现过 3 个核心同时跑）。这份记录让「先问有没有活着的核心」成为
/// 可能：读到就**附着**，读到但连不上（硬杀留下的陈旧记录）就当没有。
///
/// 口径：
/// - 只在**监听成功之后**写（端口 / token 在此之前不存在）；
/// - 正常退出时删；硬杀留下的由下一个启动者探测后清理；
/// - token 是本次进程内的一次性凭据，写在这里只是为了**跨进程附着**（文件位于
///   当前用户的数据根，与 UI 插件从环境变量拿到的是同一份凭据）。
class CoreInstanceRecord {
  const CoreInstanceRecord({
    required this.pid,
    required this.port,
    required this.token,
    this.host = '127.0.0.1',
    this.version = '',
    this.dataRoot = '',
  });

  final int pid;
  final int port;
  final String token;
  final String host;
  final String version;
  final String dataRoot;

  String get httpBaseUrl => 'http://$host:$port';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'pid': pid,
    'host': host,
    'port': port,
    'token': token,
    'version': version,
    'data_root': dataRoot,
  };

  /// 解析记录；非法 JSON / 缺 port、token 一律返回 null（陈旧或写坏 = 当没有）。
  static CoreInstanceRecord? decode(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final int? port = (decoded['port'] as num?)?.toInt();
    final String? token = decoded['token'] as String?;
    if (port == null || port <= 0 || token == null || token.isEmpty) return null;
    return CoreInstanceRecord(
      pid: (decoded['pid'] as num?)?.toInt() ?? 0,
      port: port,
      token: token,
      host: (decoded['host'] as String?)?.trim().isNotEmpty == true
          ? (decoded['host'] as String).trim()
          : '127.0.0.1',
      version: (decoded['version'] as String?) ?? '',
      dataRoot: (decoded['data_root'] as String?) ?? '',
    );
  }
}

/// 实例发现文件 + 存活探测。
///
/// 存活判据是 **`GET /api/meta` 能用这份 token 拿到 200**：只检查端口有没有人监听
/// 不够（端口会被别的进程复用），只检查文件够不够（硬杀会留下陈旧文件）。
class CoreInstanceFile {
  CoreInstanceFile(this.path);

  final String path;

  CoreInstanceRecord? read() {
    try {
      if (!File(path).existsSync()) return null;
      return CoreInstanceRecord.decode(File(path).readAsStringSync());
    } catch (_) {
      return null;
    }
  }

  Future<void> write(CoreInstanceRecord record) async {
    await AtomicFile.writeStringAtomic(path, jsonEncode(record.toJson()));
  }

  /// 删除记录（正常退出走这里；文件不存在不算错）。
  void clear() {
    try {
      final File file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  /// 探测记录指向的核心是否**真的**活着。
  ///
  /// 任何异常（端口没人听、超时、token 不认）都返回 false —— 探测失败只会让调用方
  /// 选择"新起一个核心"，这比"附着到一个不存在/不认我们的端点"安全。
  Future<bool> alive(
    CoreInstanceRecord record, {
    Duration timeout = const Duration(milliseconds: 1500),
  }) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = timeout;
    try {
      final HttpClientRequest request = await client
          .getUrl(Uri.parse('${record.httpBaseUrl}/api/meta'))
          .timeout(timeout);
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${record.token}',
      );
      final HttpClientResponse response = await request.close().timeout(
        timeout,
      );
      await response.drain<void>();
      return response.statusCode == HttpStatus.ok;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}
