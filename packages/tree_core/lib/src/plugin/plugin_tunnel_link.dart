import 'dart:async';
import 'dart:convert';

import 'package:tree_local_exec/tree_local_exec.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'plugin_bus.dart';
import 'plugin_host.dart';

/// [TunnelLink] 的**核心侧实现**：把"建立/使用一条 SSH 隧道"落到
/// `ssh_executor` 插件进程上（`tunnel.*` 方法，见 `docs/ssh-tunnel-protocol.md` §2）。
///
/// 为什么单独一个文件：`tree_local_exec` 不认识插件、`PluginBus` 也不该认识
/// `SshTransport` —— 这个类就是两者之间那层薄薄的翻译。它**只做**四件事：
/// 选插件（按能力）、发请求、把插件的失败面翻成 [TunnelUnavailableException]
/// （带 `kind`，核心据此决定"回退 vs 如实暴露"）、把 `tunnel/event` 通知按
/// `conn_id` 分发给对应的会话。
class PluginTunnelLink implements TunnelLink {
  PluginTunnelLink(this._bus, [this._log]) {
    // 挂上唯一的通知出口（`PluginBus.onTunnelEvent`）。
    // 覆盖式赋值是安全的：一个进程里只会有一个 SSH 执行器选路者。
    _bus.onTunnelEvent = _onTunnelEvent;
  }

  final PluginBus _bus;
  final void Function(String message)? _log;

  /// `conn_id` → 会话的通知接收口。
  final Map<String, void Function(TunnelShellEvent event)> _sinks =
      <String, void Function(TunnelShellEvent event)>{};

  @override
  bool get available => _bus.sshExecutorLookup().host != null;

  /// 当前为什么没有中转站（可读；`available == true` 时为空串）。
  String get unavailableReason => _bus.sshExecutorLookup().reason;

  @override
  Future<TunnelSession> ensure(TunnelConnectRequest request) async {
    final ({PluginHost? host, String reason}) lookup = _bus.sshExecutorLookup();
    final PluginHost? host = lookup.host;
    if (host == null) {
      throw TunnelUnavailableException(
        TunnelErrorKinds.agentUnreachable,
        lookup.reason,
      );
    }
    final Map<String, dynamic> result;
    try {
      result = await host.requestMethod(TunnelMethods.ensure, <String, dynamic>{
        'config': request.toJson(),
      });
    } on PluginException catch (error) {
      // 插件进程没了 / 通道断了：等价于"没有中转站"（**可回退**）。
      throw TunnelUnavailableException(
        TunnelErrorKinds.agentUnreachable,
        '中转站插件不可用：${error.message}',
      );
    } catch (error) {
      throw TunnelUnavailableException(
        TunnelErrorKinds.agentUnreachable,
        '中转站插件请求失败：$error',
      );
    }
    if (result['ok'] != true) {
      final String kind = (result['error_kind'] ?? '').toString().trim();
      throw TunnelUnavailableException(
        kind.isEmpty ? TunnelErrorKinds.agentUnreachable : kind,
        (result['error'] ?? '中转站未能建立隧道（未提供原因）').toString(),
      );
    }
    final String connId = (result['conn_id'] ?? '').toString();
    if (connId.isEmpty) {
      throw TunnelUnavailableException(
        TunnelErrorKinds.handshakeFailed,
        '中转站回了 ok 但没给 conn_id（协议违规）',
      );
    }
    final Map<String, dynamic> agent = _asMap(result['agent']);
    final _PluginTunnelSession session = _PluginTunnelSession(
      this,
      host,
      connId,
      (result['root'] ?? '').toString(),
      agent,
    );
    // 先挂上通知接收口，再交出去：`shell.data` 可能在第一帧请求之前就到。
    session.attach();
    return session;
  }

  void _onTunnelEvent(String pluginId, Map<String, dynamic> params) {
    final String connId = (params['conn_id'] ?? '').toString();
    final void Function(TunnelShellEvent event)? sink = _sinks[connId];
    if (sink == null) return; // 没有人在听（隧道已收 / 别的插件）⇒ 丢掉
    final String kind = (params['kind'] ?? '').toString();
    final List<int> data = _decodeBase64(params['data']);
    sink(
      TunnelShellEvent(
        connId: connId,
        kind: kind,
        shellId: (params['shell_id'] ?? '').toString(),
        data: data,
        exitCode: (params['exit_code'] as num?)?.toInt() ?? -1,
      ),
    );
  }

  static List<int> _decodeBase64(Object? raw) {
    if (raw == null) return const <int>[];
    try {
      return base64Decode(raw.toString());
    } catch (_) {
      return const <int>[];
    }
  }

  static Map<String, dynamic> _asMap(Object? raw) {
    if (raw is Map) {
      return raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
    }
    return <String, dynamic>{};
  }

  /// 从 `tunnel.state` 的一条记录建快照。
  static TunnelSnapshot snapshotOf(Map<String, dynamic> raw, String fallbackId) {
    return TunnelSnapshot(
      connId: (raw['conn_id'] ?? fallbackId).toString(),
      state: (raw['state'] ?? TunnelStates.down).toString(),
      root: (raw['root'] ?? '').toString(),
      attempt: (raw['attempt'] as num?)?.toInt() ?? 0,
      elapsedMs: (raw['elapsed_ms'] as num?)?.toInt() ?? 0,
      lastError: (raw['last_error'] ?? '').toString(),
      agent: _asMap(raw['agent']),
    );
  }

  /// 把插件返回的对象列表规整出来（`tunnels` 字段）。
  static List<Map<String, dynamic>> tunnelsOf(Object? raw) {
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map(
          (Map<dynamic, dynamic> m) =>
              m.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
        )
        .toList();
  }

  void _register(String connId, void Function(TunnelShellEvent event) sink) {
    _sinks[connId] = sink;
  }

  void _unregister(String connId) {
    _sinks.remove(connId);
  }

  void _debug(String message) => _log?.call(message);
}

/// 一条由 `ssh_executor` 插件掌握的隧道。
class _PluginTunnelSession implements TunnelSession {
  _PluginTunnelSession(
    this._link,
    this._host,
    this.connId,
    this.root,
    this._agent,
  );

  final PluginTunnelLink _link;
  final PluginHost _host;

  @override
  final String connId;

  @override
  final String root;

  final Map<String, dynamic> _agent;

  final StreamController<TunnelShellEvent> _events =
      StreamController<TunnelShellEvent>.broadcast();
  bool _closed = false;

  @override
  Map<String, dynamic> get agent => _agent;

  @override
  Stream<TunnelShellEvent> get events => _events.stream;

  /// 插件**此刻**还在不在（实时问 `PluginBus`，不是缓存）。
  ///
  /// 心跳失败时用它区分两件事（2026-10-11 用户口径）：
  /// - 插件没了（缺失 / 未启用 / 进程不在 / 能力丢了）⇒ **判死**，核心回退内置并明示；
  /// - 插件还在（只是这条隧道的结果拉不到：网络抖动、隧道在重连）⇒ **不判死**，等它回来。
  @override
  bool get pluginAvailable => _link.available;

  @override
  String get unavailableReason => _link.unavailableReason;

  @override
  Future<Object?> request(String method, Map<String, dynamic> params) async {
    final Map<String, dynamic> result;
    try {
      result = await _host.requestMethod(TunnelMethods.request, <String, dynamic>{
        'conn_id': connId,
        'method': method,
        'params': params,
      });
    } on PluginException catch (error) {
      throw TunnelUnavailableException(
        TunnelErrorKinds.tunnelDown,
        '中转站通道已断：${error.message}',
      );
    }
    if (result['ok'] != true) {
      final Object? code = result['error_code'];
      if (code is num) {
        // agent 的**业务错误**（not_found / already_exists …）：原样抛，
        // 由 TunnelSshTransport 翻成 WorkspaceIoException / 结果码。
        throw RpcException(
          code.toInt(),
          (result['error'] ?? '').toString(),
          data: result['error_data'],
        );
      }
      final String kind = (result['error_kind'] ?? '').toString().trim();
      throw TunnelUnavailableException(
        kind.isEmpty ? TunnelErrorKinds.tunnelDown : kind,
        (result['error'] ?? '中转站请求失败').toString(),
      );
    }
    return result['result'];
  }

  @override
  Future<TunnelSnapshot> snapshot() async {
    final Map<String, dynamic> result = await _host.requestMethod(
      TunnelMethods.state,
      <String, dynamic>{'conn_id': connId},
    );
    if (result['ok'] != true) {
      throw TunnelUnavailableException(
        TunnelErrorKinds.tunnelDown,
        (result['error'] ?? '拉取隧道状态失败').toString(),
      );
    }
    final List<Map<String, dynamic>> tunnels = PluginTunnelLink.tunnelsOf(
      result['tunnels'],
    );
    for (final Map<String, dynamic> raw in tunnels) {
      if ((raw['conn_id'] ?? '').toString() == connId) {
        return PluginTunnelLink.snapshotOf(raw, connId);
      }
    }
    // 插件说 ok 但列表里没有这条隧道 ⇒ **如实**当成不可用（不假装 ready）。
    return TunnelSnapshot(
      connId: connId,
      state: TunnelStates.down,
      lastError: '中转站已不再持有这条隧道',
    );
  }

  @override
  Future<void> reconnect() async {
    final Map<String, dynamic> result;
    try {
      result = await _host.requestMethod(TunnelMethods.reconnect, <String, dynamic>{
        'conn_id': connId,
      });
    } on PluginException catch (error) {
      throw WorkspaceIoException('重建隧道失败：${error.message}');
    }
    if (result['ok'] != true) {
      throw WorkspaceIoException(
        '重建隧道失败：${result['error'] ?? '未知原因'}',
      );
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _link._unregister(connId);
    try {
      await _host.requestMethod(TunnelMethods.close, <String, dynamic>{
        'conn_id': connId,
      });
    } catch (error) {
      _link._debug('关闭隧道 $connId 失败（忽略）：$error');
    }
    if (!_events.isClosed) await _events.close();
  }

  /// 由 [PluginTunnelLink] 在注册时调用。
  void attach() {
    _link._register(connId, (TunnelShellEvent event) {
      if (_events.isClosed) return;
      _events.add(event);
    });
  }
}
