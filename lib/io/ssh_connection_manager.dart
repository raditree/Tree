import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

/// SSH 连接管理器 - 由前端（本机）发起并持有 dartssh2 连接。
///
/// SSH 运行模式下，SSH 连接由**前端机器**建立（IP 相对前端），后端仅经反向
/// WebSocket 委托工具执行。本类按顶部 agent 懒建立 `SSHClient`，transport
/// 失活时自动从缓存移除（下次请求按需重建），对齐原后端 `SSHConnectionManager`
/// 的语义。
///
/// 认证：
/// - 密码（auth_type == "password"）：`onPasswordRequest` 返回密码；
/// - 私钥（auth_type == "key"）：读取 `private_key_path` 的 PEM 经
///   `SSHKeyPair.fromPem` 解析为 identities。
class SshConnectionManager {
  /// 已建立的连接缓存：top_agent_id -> SSHClient
  final Map<String, SSHClient> _clients = <String, SSHClient>{};

  /// 测试一次 SSH 连接（建立→关闭），用于启用 SSH 模式时的前端侧验证。
  ///
  /// 返回 ``{success: bool, message: String}``；成功时 message 为空串，
  /// 失败时 message 为可读错误信息。IP 相对前端机器，因此由前端本机测试。
  Future<Map<String, dynamic>> testConnection(
    Map<String, dynamic> config,
  ) async {
    SSHClient? client;
    try {
      client = await _buildClient(config);
      client.close();
      return <String, dynamic>{'success': true, 'message': ''};
    } catch (e) {
      return <String, dynamic>{'success': false, 'message': '$e'};
    } finally {
      if (client != null) {
        try {
          client.close();
        } catch (_) {
          // 忽略重复关闭
        }
      }
    }
  }

  /// 建立（或复用）指定顶部 agent 的 SSH 连接，返回已认证的 `SSHClient`。
  ///
  /// 已缓存且未关闭时直接复用；否则新建并缓存。transport 关闭（失活）时自动
  /// 从缓存移除，下次调用按需重建。
  Future<SSHClient> connect(
    String topAgentId,
    Map<String, dynamic> config,
  ) async {
    final SSHClient? existing = getClient(topAgentId);
    if (existing != null) {
      return existing;
    }
    final SSHClient client = await _buildClient(config);
    _clients[topAgentId] = client;
    // 监听 transport 关闭：失活后从缓存移除，避免后续请求复用已断开的连接
    client.done.then((_) {
      _dropIfSame(topAgentId, client);
    }).catchError((_) {
      _dropIfSame(topAgentId, client);
    });
    return client;
  }

  /// 取回指定顶部 agent 的已认证连接；已关闭 / 不存在时返回 null。
  SSHClient? getClient(String topAgentId) {
    final SSHClient? client = _clients[topAgentId];
    if (client == null) {
      return null;
    }
    if (client.isClosed) {
      _clients.remove(topAgentId);
      return null;
    }
    return client;
  }

  /// 关闭并移除指定顶部 agent 的连接。
  Future<void> close(String topAgentId) async {
    final SSHClient? client = _clients.remove(topAgentId);
    if (client != null) {
      try {
        client.close();
      } catch (_) {
        // 忽略关闭异常
      }
    }
  }

  /// 关闭全部连接并清空缓存。
  Future<void> closeAll() async {
    for (final SSHClient client in _clients.values) {
      try {
        client.close();
      } catch (_) {
        // 忽略关闭异常
      }
    }
    _clients.clear();
  }

  /// 若缓存中仍是 [client]，则移除（transport 已失活）。
  void _dropIfSame(String topAgentId, SSHClient client) {
    if (identical(_clients[topAgentId], client)) {
      _clients.remove(topAgentId);
    }
  }

  /// 依据配置建立并完成认证的 SSH 连接。
  ///
  /// 认证失败 / 连接超时会抛异常，由调用方捕获转成可读错误。
  Future<SSHClient> _buildClient(Map<String, dynamic> config) async {
    final String host = ((config['host'] as String?) ?? '').trim();
    final int port = ((config['port'] as num?) ?? 22).toInt();
    final String username = ((config['username'] as String?) ?? '').trim();
    final String authType = (config['auth_type'] as String?) ?? 'password';
    final String password = (config['password'] as String?) ?? '';
    final String keyPath = ((config['private_key_path'] as String?) ?? '').trim();

    if (host.isEmpty) {
      throw StateError('SSH 主机地址为空');
    }
    if (username.isEmpty) {
      throw StateError('SSH 用户名不能为空');
    }

    final SSHSocket socket = await SSHSocket.connect(
      host,
      port,
      timeout: const Duration(seconds: 15),
    );

    List<SSHKeyPair>? identities;
    SSHPasswordRequestHandler? onPasswordRequest;
    if (authType == 'key') {
      if (keyPath.isEmpty) {
        socket.destroy();
        throw StateError('私钥认证需提供私钥文件路径');
      }
      final String pem = await File(keyPath).readAsString();
      identities = SSHKeyPair.fromPem(pem);
    } else {
      onPasswordRequest = () => password;
    }

    final SSHClient client = SSHClient(
      socket,
      username: username,
      identities: identities,
      onPasswordRequest: onPasswordRequest,
      keepAliveInterval: const Duration(seconds: 15),
    );
    try {
      await client.authenticated.timeout(const Duration(seconds: 20));
    } catch (_) {
      try {
        client.close();
      } catch (_) {
        // 忽略关闭异常
      }
      rethrow;
    }
    return client;
  }
}
