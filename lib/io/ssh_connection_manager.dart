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
  /// 单连接并发上限的**内置默认值**（超出排队等待槽位）。
  ///
  /// 运行时可用后端下发值覆盖：后端 app.yaml ``ssh.max_concurrent_per_team``
  /// 会随 ``register_ssh_executor`` ack 下发，经 [applyMaxConcurrentPerTeam]
  /// 生效（见 [SshExecutorService.resolveAck]）。此值需严格小于主机 sshd 单
  /// 连接会话上限 ``MaxSessions``（已约定主机配套调到 50），并给 SFTP 等
  /// 会话型通道留余量（42 + 8 < 50），避免并发会话打满后新命令全部
  /// ``open failed``。若主机 ``MaxSessions`` 未同步调大，请把配置调回其以下
  /// （如主机为默认 10 时取 6~8）。
  static const int defaultMaxConcurrentPerTeam = 42;

  /// 排队等槽位的最长时限：超过即自动移出队列并报错（见 [_TeamGate.acquire]），
  /// 保证等待项不永久驻留、队列长度有界。
  static const Duration queueWaitTimeout = Duration(minutes: 5);

  /// 实际生效的单连接并发上限（新建闸的默认值）：初始为
  /// [defaultMaxConcurrentPerTeam]，可经 [applyMaxConcurrentPerTeam] 动态调整。
  int _concurrentLimit = defaultMaxConcurrentPerTeam;

  /// 应用后端下发的并发上限（来自 app.yaml ``ssh.max_concurrent_per_team``）。
  ///
  /// 值非正整数时忽略（保持当前值）；对已创建的闸同步生效（仅影响后续的
  /// 排队判定，正在执行的会话不受影响）。
  void applyMaxConcurrentPerTeam(Object? value) {
    final int v = value is num ? value.toInt() : 0;
    if (v <= 0) return;
    _concurrentLimit = v;
    for (final _TeamGate gate in _gates.values) {
      gate.max = v;
    }
  }

  /// 已建立的连接缓存：team_id -> SSHClient
  final Map<String, SSHClient> _clients = <String, SSHClient>{};

  /// 每 team 的并发闸（同一连接上的工具并发上限，超出排队）：team_id -> 闸
  final Map<String, _TeamGate> _gates = <String, _TeamGate>{};

  /// 在 [teamId] 的并发配额内执行 [action]：同连接并发已达上限时排队等待
  /// 槽位，前一个执行结束即让位；排队超过 [SshConnectionManager.queueWaitTimeout]
  /// 未拿到槽位时抛 [TimeoutException]（该项自动移出队列）。
  ///
  /// 排队等待期间调用方的进度心跳仍在发送（后端卡死检测因此不会误判超时）。
  /// 注意：取消 hook / 复用既有分片会话的操作**不要**经此排队——它们要么需要
  /// 立即执行以解除卡死，要么本就不开新通道，应直连执行。
  ///
  /// [maxConcurrent] / [queueWait] 仅在该 team 尚无闸时生效（测试可注入更小
  /// 的并发上限与等待时限；生产走 [applyMaxConcurrentPerTeam] 设定的值）。
  Future<T> runWithSlot<T>(
    String teamId,
    Future<T> Function() action, {
    int? maxConcurrent,
    Duration? queueWait,
  }) async {
    final _TeamGate gate = _gates.putIfAbsent(
      teamId,
      () => _TeamGate(
        max: maxConcurrent ?? _concurrentLimit,
        queueWait: queueWait ?? queueWaitTimeout,
      ),
    );
    await gate.acquire();
    try {
      return await action();
    } finally {
      gate.release();
    }
  }

  /// 建立中的连接（in-flight 去重）：team_id -> 建连 Future。
  ///
  /// 同一 team 的并发首连共享同一个 Future，避免重复建连；完成（成功或
  /// 失败）后移除，后续请求按缓存命中 / 重新建连处理。
  final Map<String, Future<SSHClient>> _connecting =
      <String, Future<SSHClient>>{};

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
  /// [config] 由调用方传入（来自该 team 的 per-team 状态，而非全局槽位）。
  /// 已缓存且未关闭时直接复用；同 team 的并发首连共享同一个建连 Future
  /// （in-flight 去重）；否则新建并缓存。transport 关闭（失活）时自动从
  /// 缓存移除，下次调用按需重建。
  Future<SSHClient> connect(
    String teamId,
    Map<String, dynamic> config,
  ) async {
    final SSHClient? existing = getClient(teamId);
    if (existing != null) {
      return existing;
    }
    final Future<SSHClient>? inFlight = _connecting[teamId];
    if (inFlight != null) {
      return inFlight;
    }
    final Future<SSHClient> future = _connectAndCache(teamId, config);
    _connecting[teamId] = future;
    try {
      return await future;
    } finally {
      if (identical(_connecting[teamId], future)) {
        _connecting.remove(teamId);
      }
    }
  }

  /// 建立并缓存指定 team 的 SSH 连接（供 [connect] 的 in-flight 去重使用）。
  Future<SSHClient> _connectAndCache(
    String teamId,
    Map<String, dynamic> config,
  ) async {
    final SSHClient client = await _buildClient(config);
    _clients[teamId] = client;
    // 监听 transport 关闭：失活后从缓存移除，避免后续请求复用已断开的连接
    client.done.then((_) {
      _dropIfSame(teamId, client);
    }).catchError((_) {
      _dropIfSame(teamId, client);
    });
    return client;
  }

  /// 取回指定顶部 agent 的已认证连接；已关闭 / 不存在时返回 null。
  SSHClient? getClient(String teamId) {
    final SSHClient? client = _clients[teamId];
    if (client == null) {
      return null;
    }
    if (client.isClosed) {
      _clients.remove(teamId);
      return null;
    }
    return client;
  }

  /// 关闭并移除指定顶部 agent 的连接。
  Future<void> close(String teamId) async {
    // 同步清理该 team 的建连中去重项（其结果不再被等待方复用）
    _connecting.remove(teamId);
    final SSHClient? client = _clients.remove(teamId);
    if (client != null) {
      try {
        client.close();
      } catch (_) {
        // 忽略关闭异常
      }
    }
    // 连接已关闭：顺手回收空闲的并发闸，防止 _gates 随 team 反复建/销而膨胀
    // （仍在执行或仍有排队的闸保留，由它们的 finally/排队超时自行收尾）
    final _TeamGate? gate = _gates[teamId];
    if (gate != null && gate._isIdle) {
      _gates.remove(teamId);
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
    _gates.clear();
  }

  /// 若缓存中仍是 [client]，则移除（transport 已失活）。
  void _dropIfSame(String teamId, SSHClient client) {
    if (identical(_clients[teamId], client)) {
      _clients.remove(teamId);
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

/// 每 team 的并发闸状态：当前执行数 + 等待队列。
///
/// 同一条 SSH 连接上的会话型通道数量受 sshd ``MaxSessions`` 限制（默认
/// 10），此闸把并发工具数限制在默认
/// [SshConnectionManager.defaultMaxConcurrentPerTeam]（可经
/// [SshConnectionManager.applyMaxConcurrentPerTeam] 动态调整 [max]），
/// 超出部分排队等槽位——避免并发会话打满通道上限后新命令 ``open failed``。
///
/// 注：Dart 2.19 没有原生 Future 取消（也无 ``CanceledException``），等待中
/// 的请求无法被调用方"取消"，因此 [acquire] 通过**排队超时 + 自动移出队列**
/// 保证任何等待项都不会永久驻留在 [_waiters] 中（队列长度有界）。
class _TeamGate {
  _TeamGate({
    this.max = SshConnectionManager.defaultMaxConcurrentPerTeam,
    this.queueWait = SshConnectionManager.queueWaitTimeout,
  });

  /// 允许同时执行的并发上限（可被 [SshConnectionManager.applyMaxConcurrentPerTeam]
  /// 动态调大/调小，仅影响后续排队判定，正在执行的会话不受影响）
  int max;

  /// 排队等槽位的最长时限（测试可注入更小值以缩短验证耗时）
  final Duration queueWait;

  /// 当前占用槽位的执行数（不含等待者）
  int _active = 0;

  /// 排队等待槽位的请求（FIFO 让位）
  final List<Completer<void>> _waiters = <Completer<void>>[];

  /// 是否空闲（无执行中、无排队），供连接关闭时清理闸本身、防 map 膨胀。
  bool get _isIdle => _active == 0 && _waiters.isEmpty;

  /// 申请一个槽位：未满立即占用；已满则排队等待，直到被让位唤醒。
  ///
  /// 排队超过 [queueWait] 未拿到槽位时，把自己从 [_waiters] 移出后
  /// 抛出 [TimeoutException]（不会进入执行，也不占槽位）。
  Future<void> acquire() async {
    if (_active < max) {
      _active++;
      return;
    }
    final Completer<void> waiter = Completer<void>();
    _waiters.add(waiter);
    try {
      await waiter.future.timeout(queueWait);
    } on TimeoutException {
      // 拿到槽位的路径由 timeout 正常返回走，不会落到本分支；能走到这里
      // 说明本 waiter 尚未被让位，仍在队列中，移除即可（单线程模型下无
      // 并发插入/让位的竞态）。
      _waiters.remove(waiter);
      rethrow;
    }
  }

  /// 释放当前槽位：有等待者则让位给队首（槽位数不变），否则归还槽位。
  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
      return;
    }
    _active--;
  }
}
