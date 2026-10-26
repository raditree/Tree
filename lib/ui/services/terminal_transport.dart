import 'dart:async';
import 'dart:convert';

import 'package:tree_protocol/tree_protocol.dart';

import '../../io/api_service.dart';
import '../../io/station_client.dart';

/// 终端会话的**传输面**（可注入）。
///
/// 为什么单独抽出来：面板要验的是"键盘怎么变成字节、帧怎么变成屏幕"，与网络无关；
/// 测试用内存桩就能把这条链路钉住（见 `test/terminal_panel_test.dart`）。
abstract interface class TerminalTransport {
  /// 当前会话的输出帧（`terminal_output` / `terminal_exit`，形状同旧 WS 帧）。
  Stream<Map<String, dynamic>> get frames;

  /// 建会话；返回执行器回显的 `cwd` / `shell` 等。
  Future<Map<String, dynamic>> open({
    required String sessionId,
    required String agentId,
    required int columns,
    required int rows,
  });

  Future<void> input(String sessionId, List<int> bytes);

  Future<void> resize(String sessionId, int columns, int rows);

  /// 关掉**当前**会话（换会话 / 收起面板时用）。
  Future<void> close();

  /// 释放传输资源（退订广播站、关会话）。
  void dispose();
}

/// 生产实现（L-26）：会话管理走执行器 REST，输出走执行器自建广播站。
///
/// 核心既不持有 PTY，也没有终端数据面：这里只做两件事——按**有效模式**（local / ssh）
/// 选执行器，把用户能看到的身份（agent_id / host / username）交给插件。
class CoreTerminalTransport implements TerminalTransport {
  CoreTerminalTransport({
    required this.sshMode,
    StationClient? stations,
  }) : _stations = stations ?? StationClient.instance {
    _subscription = _stations.deliveries.listen(_onDelivery);
  }

  /// 有效执行模式（local / ssh）。
  ///
  /// 由外层按团队合成口径算好再传进来（成员跟随团队 TOP，见 `TeamScopeView`）：
  /// 这里**不**自己读 `agent.has_ssh`——那只反映成员自己的配置，会把"跟随 TOP 的
  /// SSH 成员"误判成本地。
  final bool sshMode;

  /// 本机 / SSH 执行器的输出站（与插件侧常量同串；改名前先改
  /// `docs/pluginization/agent_pluginization.md`）。
  static const String localStation = 'plugin.local_executor.broadcast.terminal';
  static const String sshStation = 'plugin.ssh_executor.broadcast.terminal';

  final StationClient _stations;
  final StreamController<Map<String, dynamic>> _frames =
      StreamController<Map<String, dynamic>>.broadcast();
  late final StreamSubscription<StationDelivery> _subscription;

  String _stationId = '';
  String _sessionId = '';
  bool _disposed = false;

  String get _base => sshMode
      ? '/api/terminal/ssh/sessions'
      : '/api/terminal/local/sessions';

  @override
  Stream<Map<String, dynamic>> get frames => _frames.stream;

  @override
  Future<Map<String, dynamic>> open({
    required String sessionId,
    required String agentId,
    required int columns,
    required int rows,
  }) async {
    // SSH：先让 tree.agent **激活执行器**（真建连 + 登记远端租约）。
    // UI 拿不到 SSH 密码，能不碰凭据拿到租约的唯一路径就是这一步；
    // 失败（连不上 / 配置不全）在这里就以可读错误结束，不去建一个注定失败的会话。
    final Map<String, dynamic> activated =
        sshMode
            ? await ApiService.activateAgent(agentId)
            : const <String, dynamic>{};

    // local 只需要工作目录（ssh 的远端根在租约里，由插件自己用）。
    final Map<String, dynamic> agent = sshMode
        ? const <String, dynamic>{}
        : _asMap((await ApiService.getAgent(agentId))['agent']);
    _sessionId = sessionId;

    // 先订阅再建会话：否则 shell 的首个提示符可能落在订阅之前（真实丢帧）。
    final String station = sshMode ? sshStation : localStation;
    if (_stationId != station) {
      if (_stationId.isNotEmpty) _stations.unsubscribeStation(_stationId);
      _stationId = station;
      _stations.subscribeStation(station);
    }

    final String workspaceDir = (agent['workspace_dir'] ?? '').toString().trim();
    final String query = Uri(
      queryParameters: <String, String>{
        'agent_id': agentId,
        if (!sshMode && workspaceDir.isNotEmpty) 'workspace_dir': workspaceDir,
      },
    ).query;
    final Map<String, dynamic> reply = await ApiService.terminalPost(
      '$_base?$query',
      <String, dynamic>{
        'session_id': sessionId,
        if (sshMode) 'ssh_lease_id': (activated['ssh_lease_id'] ?? '').toString(),
        if (sshMode) 'host': (activated['host'] ?? '').toString(),
        'columns': columns,
        'rows': rows,
      },
    );
    // 面板在请求途中就收起了：会话已建好但没人认领 ⇒ 当场收掉，不留孤儿 shell。
    if (_disposed) {
      try {
        await ApiService.terminalDelete(
          '$_base/${Uri.encodeComponent(sessionId)}',
        );
      } catch (_) {
        // 关不掉只能留给插件下线时统一收（会话不持久化）。
      }
    }
    return reply;
  }

  @override
  Future<void> input(String sessionId, List<int> bytes) {
    if (bytes.isEmpty) return Future<void>.value();
    return ApiService.terminalPost(
      '$_base/${Uri.encodeComponent(sessionId)}/input',
      <String, dynamic>{'bytes': base64Encode(bytes)},
    ).then((_) {});
  }

  @override
  Future<void> resize(String sessionId, int columns, int rows) {
    return ApiService.terminalPost(
      '$_base/${Uri.encodeComponent(sessionId)}/resize',
      <String, dynamic>{'columns': columns, 'rows': rows},
    ).then((_) {});
  }

  @override
  Future<void> close() async {
    final String id = _sessionId;
    _sessionId = '';
    if (id.isEmpty) return;
    try {
      await ApiService.terminalDelete('$_base/${Uri.encodeComponent(id)}');
    } catch (_) {
      // 会话可能已随进程退出 / 插件重启消失：关闭失败不必打扰用户。
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(close());
    unawaited(_subscription.cancel());
    if (_stationId.isNotEmpty) {
      _stations.unsubscribeStation(_stationId);
    }
    if (!_frames.isClosed) unawaited(_frames.close());
  }

  void _onDelivery(StationDelivery delivery) {
    if (_sessionId.isEmpty || delivery.stationId != _stationId) return;
    if (delivery.state != StationDeliveryState.data) return;
    final String topic = delivery.topic ?? '';
    if (!topic.startsWith('terminal.$_sessionId.')) return;
    final Object? raw = delivery.payload;
    if (raw is! Map) return;
    _frames.add(raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)));
  }

  static Map<String, dynamic> _asMap(Object? raw) {
    if (raw is! Map) return <String, dynamic>{};
    return raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
  }
}
