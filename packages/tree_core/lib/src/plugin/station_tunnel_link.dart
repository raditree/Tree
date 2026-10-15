import 'dart:async';
import 'dart:convert';

import 'package:tree_local_exec/tree_local_exec.dart';
import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'plugin_bus.dart';

/// [TunnelLink] 的**站点实现**：把"建立 / 使用一条 SSH 隧道"落到
/// 中转站的处理拓展点位 `system.relay.ssh.execute` 上（`PluginBus.relaySshExecute`）。
///
/// 与 [PluginTunnelLink] 的关系（2026-10-15：SSH 迁移到「处理拓展点位」）：
/// - **同一个 [TunnelSshTransport]** 复用——本类只换"请求怎么投递"这一层翻译，
///   liveness / 心跳 / PTY / 回退判据全部沿用，因此稳定性与旧路径逐条对齐；
/// - 旧路径按**能力 + 进程**认插件、发顶层 `tunnel.*` JSON-RPC；
/// - 本路径按**点位有没有订阅者**认接管者、把每个动作投成一次 `station/request`
///   （`ensure` / `request` / `state` / `reconnect` / `close`，见 [SshExecuteStation]）；
/// - **PTY 数据面不变**：插件仍以 `tunnel/event` 通知推 `shell.data` / `shell.exit`，
///   本类经 [PluginBus.addTunnelEventListener] 认领自己 conn_id 的事件（与旧路径并存、
///   各按 conn_id 分流，互不串道）。
///
/// 一条链路服务**所有 agent**（[TunnelConnectRequest.scopeAgentId] 随连接携带各自的
/// agent ⇒ relay 投递时据此解析隔离四元组的 team / mode），因此一个进程只建**一份**本链路，
/// 与 [PluginTunnelLink] 的"单一选路者"假设一致。
class StationTunnelLink implements TunnelLink {
  StationTunnelLink(this._bus, [this._log]) {
    _bus.addTunnelEventListener(_onTunnelEvent);
  }

  final PluginBus _bus;
  final void Function(String message)? _log;

  /// `conn_id` → 会话的通知接收口（与 [PluginTunnelLink._sinks] 同构，各自独立）。
  final Map<String, void Function(TunnelShellEvent event)> _sinks =
      <String, void Function(TunnelShellEvent event)>{};

  @override
  bool get available => _bus.sshExecuteStationSubscribed();

  /// 当前为什么走不了站点（可读；`available == true` 时给出"订阅在场"的说明）。
  String get unavailableReason => available
      ? ''
      : 'SSH 执行中转站点位当前无订阅者（插件未订阅 / 已停用 / 进程不在）';

  /// 显式收手（进程退出时调用）：注销通知监听，避免链路对象堆积。
  void dispose() => _bus.removeTunnelEventListener(_onTunnelEvent);

  @override
  Future<TunnelSession> ensure(TunnelConnectRequest request) async {
    if (!available) {
      throw TunnelUnavailableException(
        TunnelErrorKinds.agentUnreachable,
        unavailableReason,
      );
    }
    final String agentId = request.scopeAgentId;
    final Map<String, dynamic>? result = await _bus.relaySshExecute(
      action: SshExecuteStation.ensure,
      agentId: agentId,
      sessionId: '',
      payload: <String, dynamic>{'config': request.toJson()},
    );
    if (result == null) {
      // relay 返回 null = fail-open（无订阅者 / 未接管 / 非法回包）⇒ 等价"没有中转站"（可回退）。
      throw TunnelUnavailableException(
        TunnelErrorKinds.agentUnreachable,
        'SSH 执行中转站点位未接管本次建连（回退内置）',
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
    final _StationTunnelSession session = _StationTunnelSession(
      this,
      agentId,
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
    if (sink == null) return; // 不是这条链路认领的隧道（旧路径 / 已收）⇒ 丢掉
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

  /// 从站点回包（`state` 动作）的一条记录建快照（形状与 `tunnel.state` 同源）。
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

/// 一条由 SSH 执行中转站点位掌握的隧道（经 [PluginBus.relaySshExecute] 投递）。
class _StationTunnelSession implements TunnelSession {
  _StationTunnelSession(
    this._link,
    this._agentId,
    this.connId,
    this.root,
    this._agent,
  );

  final StationTunnelLink _link;
  final String _agentId;

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

  /// 站点此刻是否仍有订阅者（实时问总线，不是缓存）。
  @override
  bool get pluginAvailable => _link.available;

  /// 站点路径**不绑定**具体插件实例（relay 每次投递都路由给"当前订阅者"），
  /// 因此本属性与 [pluginAvailable] 同义：订阅在场 = 这条会话赖以工作的中转站在。
  ///
  /// 与旧路径"实例被换掉"的判死差异（2026-10-11 真机 bug 的根因）在这里由另一条更硬的
  /// 证据接住：插件重启 → 台账清空 → 本 conn_id 在 `state` 回包中消失 → [snapshot] 如实返回
  /// `down` → `TunnelSshTransport._beat` 据 `snapshot.down` 判死。故不必再区分"绑定实例"。
  @override
  bool get boundHostAlive => _link.available;

  @override
  String get unavailableReason => _link.unavailableReason;

  @override
  Future<Object?> request(String method, Map<String, dynamic> params) async {
    final Map<String, dynamic>? result = await _link._bus.relaySshExecute(
      action: SshExecuteStation.request,
      agentId: _agentId,
      sessionId: '',
      payload: <String, dynamic>{
        'conn_id': connId,
        'method': method,
        'params': params,
      },
    );
    if (result == null) {
      // fail-open（订阅撤了 / 未接管）：如实失败、**不判死**（判死由心跳快照定）。
      throw TunnelUnavailableException(
        TunnelErrorKinds.tunnelDown,
        'SSH 执行中转站点位未接管本次请求（订阅已撤 / 未回填）',
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
    final Map<String, dynamic>? result = await _link._bus.relaySshExecute(
      action: SshExecuteStation.state,
      agentId: _agentId,
      sessionId: '',
      payload: <String, dynamic>{'conn_id': connId},
    );
    if (result == null) {
      throw TunnelUnavailableException(
        TunnelErrorKinds.tunnelDown,
        'SSH 执行中转站点位未回填隧道状态',
      );
    }
    if (result['ok'] != true) {
      throw TunnelUnavailableException(
        TunnelErrorKinds.tunnelDown,
        (result['error'] ?? '拉取隧道状态失败').toString(),
      );
    }
    final List<Map<String, dynamic>> tunnels =
        StationTunnelLink.tunnelsOf(result['tunnels']);
    for (final Map<String, dynamic> raw in tunnels) {
      if ((raw['conn_id'] ?? '').toString() == connId) {
        return StationTunnelLink.snapshotOf(raw, connId);
      }
    }
    // 站点说 ok 但列表里没有这条隧道 ⇒ **如实**当成不可用（不假装 ready）。
    // 这正是插件重启（台账清空）后被判死的确凿证据（见 [boundHostAlive] 注释）。
    return TunnelSnapshot(
      connId: connId,
      state: TunnelStates.down,
      lastError: '中转站已不再持有这条隧道',
    );
  }

  @override
  Future<void> reconnect() async {
    final Map<String, dynamic>? result = await _link._bus.relaySshExecute(
      action: SshExecuteStation.reconnect,
      agentId: _agentId,
      sessionId: '',
      payload: <String, dynamic>{'conn_id': connId},
    );
    if (result == null || result['ok'] != true) {
      throw WorkspaceIoException(
        '重建隧道失败：${result?['error'] ?? '中转站点位未接管重连'}',
      );
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _link._unregister(connId);
    try {
      await _link._bus.relaySshExecute(
        action: SshExecuteStation.close,
        agentId: _agentId,
        sessionId: '',
        payload: <String, dynamic>{'conn_id': connId},
      );
    } catch (error) {
      _link._debug('关闭隧道 $connId 失败（忽略）：$error');
    }
    if (!_events.isClosed) await _events.close();
  }

  /// 由 [StationTunnelLink] 在注册时调用。
  void attach() {
    _link._register(connId, (TunnelShellEvent event) {
      if (_events.isClosed) return;
      _events.add(event);
    });
  }
}
