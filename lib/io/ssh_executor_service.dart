import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ssh_connection_manager.dart';
import 'ssh_workspace_executor.dart';
import 'websocket_service.dart';

/// SSH 执行器服务 - SSH 运行模式下由前端建连并执行后端委托的工具调用。
///
/// SSH 运行模式：SSH 连接由**前端（Flutter + dartssh2）**发起，IP 相对前端
/// 机器（无论后端部署在本机还是远程服务器都成立）。工具调用经后端反向
/// WebSocket（``tool_exec_request`` / ``tool_exec_response``）委托到本端，
/// 由 [SshWorkspaceExecutor] 在 dartssh2 会话上执行（SFTP / exec）。
///
/// 本服务负责：
/// - 前端侧"是否已启用 SSH 模式"的状态持久化（按顶部 agent），供三态开关显示；
/// - 启用时先在**前端本机**做连接测试（真正"相对前端"的可达性验证），通过后
///   发送 ``register_ssh_executor`` 等待 ack，成功则建立并缓存 SSH 连接；
/// - 接管 ``tool_exec_request``：当前顶部 agent 处于 SSH 模式时经 SSH 会话
///   执行并回传 ``tool_exec_response``；
/// - 注销/清理时关闭前端持有的 SSH 连接。
///
/// 与 [LocalExecutorService] 的差异：SSH 配置在后端是持久化的，因此
/// [cleanup] 不注销（避免应用退出误删用户配置），重启后前端按持久化状态
/// 恢复显示，后端仍按 DB 配置继续执行。
class SshExecutorService extends ChangeNotifier {
  SshExecutorService._();

  /// 全局单例
  static final SshExecutorService instance = SshExecutorService._();

  /// 前端 SSH 连接管理器（按顶部 agent 懒建连 / 缓存 / 失活重建）
  final SshConnectionManager _connectionManager = SshConnectionManager();

  /// SSH 工具执行器（从服务当前状态取配置与顶部 agent ID）
  late final SshWorkspaceExecutor _workspaceExecutor = SshWorkspaceExecutor(
    _connectionManager,
    configProvider: () => _config,
    topAgentIdProvider: () => _currentTopAgentId,
  );

  /// 当前选中的顶部 agent ID（SSH 模式按此单独控制）
  String _currentTopAgentId = '';

  /// 当前服务的顶部 agent ID（供本地执行器等校验被服务方归属）
  String get currentTopAgentId => _currentTopAgentId;

  /// SharedPreferences 键前缀（后接顶部 agent ID，实现按顶部 agent 持久化）
  static const String _kEnabledPrefix = 'ssh_exec_enabled_';
  static const String _kConfigPrefix = 'ssh_exec_config_';

  static String _kEnabledKey(String topAgentId) => '$_kEnabledPrefix$topAgentId';
  static String _kConfigKey(String topAgentId) => '$_kConfigPrefix$topAgentId';

  /// 承载当前 WebSocket 通道的服务（用于发送注册/注销消息）
  WebSocketService? _ws;

  /// 当前顶部 agent 的 SSH 模式是否启用（持久化）
  bool _enabled = false;
  bool get enabled => _enabled;

  /// 当前顶部 agent 的 SSH 连接配置（host/port/username/auth_type/...）
  Map<String, dynamic> _config = <String, dynamic>{};
  Map<String, dynamic> get config => Map<String, dynamic>.from(_config);

  /// 等待后端 ack 的挂起请求（同时只有一个进行中）
  Completer<Map<String, dynamic>>? _pendingAck;

  /// 切换当前操作的顶部 agent，并重置其 SSH 状态。
  ///
  /// 不注销后端注册、不关闭既有连接：各顶部 agent 的 SSH 模式相互独立，
  /// 配置持久化在 DB，连接按顶部 agent 缓存，切换只影响前端显示与后续注册动作。
  void setCurrentTopAgent(String topAgentId) {
    if (topAgentId == _currentTopAgentId) return;
    _currentTopAgentId = topAgentId;
    _enabled = false;
    _config = <String, dynamic>{};
    notifyListeners();
  }

  /// 从 SharedPreferences 恢复当前顶部 agent 的 SSH 模式设置
  Future<void> loadSettings() async {
    final String id = _currentTopAgentId;
    // 竞态防护：等待期间可能已切换顶部 agent，丢弃过期恢复结果
    // （否则旧 agent 的 SSH 启用态会被写回当前 agent 内存态，
    // 造成本地 agent 的工具请求被残留 SSH 启用态误接管）
    final prefs = await SharedPreferences.getInstance();
    if (id != _currentTopAgentId) return;
    _enabled = prefs.getBool(_kEnabledKey(id)) ?? false;
    final String? raw = prefs.getString(_kConfigKey(id));
    if (raw != null && raw.isNotEmpty) {
      try {
        _config = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        _config = <String, dynamic>{};
      }
    }
  }

  /// 绑定 WebSocket 服务并接管 ``tool_exec_request`` 消息。
  ///
  /// 与本地执行器共同注册为工具请求处理者；本处理者仅在 SSH 模式启用时接管。
  void attach(WebSocketService ws) {
    _ws = ws;
    ws.addToolExecRequestHandler(_handleToolExecRequest);
  }

  /// 启用 SSH 模式：前端本机连接测试 → 注册并等待 ack → 建立并缓存连接。
  ///
  /// 返回 ``{success: true}`` 或 ``{success: false, message}``。
  /// 连接测试在**前端本机**进行（IP 相对前端），失败即返回，不再发后端；
  /// ack 成功才持久化启用状态并建立 SSH 连接。
  Future<Map<String, dynamic>> enable(Map<String, dynamic> config) async {
    // ① 前端本机连接测试（建立→关闭），验证"相对前端"可达性与认证
    final Map<String, dynamic> test =
        await _connectionManager.testConnection(config);
    if (test['success'] != true) {
      return <String, dynamic>{
        'success': false,
        'message': '连接测试失败：${test['message'] ?? '未知错误'}',
      };
    }
    // ② 发送注册并等待后端 ack（互斥校验 / 持久化由后端完成）
    final Map<String, dynamic> ack = await _register(config);
    if (ack['success'] == true) {
      // ③ ack 成功则建立并缓存 SSH 连接（预热；执行时失活会按需重建）
      try {
        await _connectionManager.connect(_currentTopAgentId, config);
      } catch (_) {
        // 预热建连失败不阻塞启用：工具执行时会按需重建（execute 内兜底）
      }
      _enabled = true;
      _config = Map<String, dynamic>.from(config);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kEnabledKey(_currentTopAgentId), true);
      await prefs.setString(
          _kConfigKey(_currentTopAgentId), jsonEncode(_config));
      notifyListeners();
    } else {
      _enabled = false;
      notifyListeners();
    }
    return ack;
  }

  /// 禁用 SSH 模式：持久化关闭、关闭 SSH 连接并通知后端注销。
  Future<void> disable() async {
    _enabled = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabledKey(_currentTopAgentId), false);
    await _connectionManager.close(_currentTopAgentId);
    _sendUnregister(_currentTopAgentId);
    notifyListeners();
  }

  /// 按当前顶部 agent 的持久化 SSH 状态同步注册/建连（重连/切换后调用）。
  ///
  /// 配置后端已持久化，这里仅重建 SSH 连接（若已断开）并重新发送注册确认，
  /// 不等待 ack。
  void syncRegistration() {
    if (_currentTopAgentId.isEmpty) return;
    if (_enabled && _config.isNotEmpty) {
      // 重建（或复用）SSH 连接：失活后按配置自动重建（失败由执行时兜底）
      unawaited(_rebuildConnection());
      _send(<String, dynamic>{
        'type': 'register_ssh_executor',
        'data': <String, dynamic>{
          'top_agent_id': _currentTopAgentId,
          'config': _config,
        },
      });
    }
  }

  /// 按当前配置重建（或复用）SSH 连接；失败静默忽略（工具执行时按需重建）。
  Future<void> _rebuildConnection() async {
    try {
      await _connectionManager.connect(_currentTopAgentId, _config);
    } catch (_) {
      // 建连失败不阻塞注册流程，首个工具调用会按需重建
    }
  }

  /// 处理后端 ack 消息（由 message_panel 在 WS 分发中调用）。
  void resolveAck(Map<String, dynamic> ackData) {
    final Completer<Map<String, dynamic>>? completer = _pendingAck;
    _pendingAck = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(ackData);
    }
  }

  /// 释放资源（应用退出时调用）。
  ///
  /// 不注销后端 SSH 注册（配置后端持久化，注销会误删用户配置），仅关闭前端
  /// 持有的 SSH 连接并移除工具请求处理者。
  void cleanup() {
    _ws?.removeToolExecRequestHandler(_handleToolExecRequest);
    _ws = null;
    _pendingAck = null;
    unawaited(_connectionManager.closeAll());
  }

  /// 处理 ``tool_exec_request``：当前顶部 agent 处于 SSH 模式时经 SSH 会话
  /// 执行并回传 ``tool_exec_response``。
  ///
  /// 返回 `true` 表示已接管（SSH 模式启用时）；否则返回 `false` 放行。
  ///
  /// 归属校验：请求由后端按 (user_id, top_agent_id) 广播到用户全部 WS 连接，
  /// 消息携带 ``top_agent_id`` 时，只接管属于本执行器当前服务 agent 的请求。
  /// 修复"同窗口先与 SSH 模式 agent 对话后切回本地 agent，工具请求被残留
  /// SSH 启用态误截获发往错误远端主机"的问题（findstr 等命令随机连不通）。
  bool _handleToolExecRequest(Map<String, dynamic> message) {
    if (!_enabled) return false;
    final Map<String, dynamic> data =
        (message['data'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final String execId = (data['exec_id'] as String?) ?? '';
    if (execId.isEmpty) return false;
    // 归属校验：请求明确属于其他顶部 agent 时不接管（放行给正确执行器/实例）
    final String reqAgent = (data['top_agent_id'] as String?) ?? '';
    if (reqAgent.isNotEmpty && reqAgent != _currentTopAgentId) return false;
    final String workspaceId = (data['workspace_id'] as String?) ?? '';
    final String op = (data['op'] as String?) ?? '';

    _workspaceExecutor.execute(workspaceId, op, data)
        .then((Map<String, dynamic> result) {
      _sendToolExecResponse(execId, result);
    }).catchError((Object error) {
      _sendToolExecResponse(execId, <String, dynamic>{
        'error': error.toString(),
      });
    });
    return true;
  }

  /// 回传一次工具执行结果（``tool_exec_response``，格式对齐 LocalExecutorService）。
  void _sendToolExecResponse(String execId, Map<String, dynamic> result) {
    _send(<String, dynamic>{
      'type': 'tool_exec_response',
      'data': <String, dynamic>{
        'exec_id': execId,
        'result': result,
      },
    });
  }

  /// 发送注册消息并等待 ack（超时 15 秒）
  Future<Map<String, dynamic>> _register(Map<String, dynamic> config) async {
    if (_currentTopAgentId.isEmpty) {
      return <String, dynamic>{'success': false, 'message': '未选择顶部 agent'};
    }
    final Completer<Map<String, dynamic>> completer =
        Completer<Map<String, dynamic>>();
    _pendingAck = completer;
    _send(<String, dynamic>{
      'type': 'register_ssh_executor',
      'data': <String, dynamic>{
        'top_agent_id': _currentTopAgentId,
        'config': config,
      },
    });
    try {
      return await completer.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          return <String, dynamic>{'success': false, 'message': '等待后端确认超时'};
        },
      );
    } finally {
      if (identical(_pendingAck, completer)) {
        _pendingAck = null;
      }
    }
  }

  void _sendUnregister(String topAgentId) {
    _send(<String, dynamic>{
      'type': 'unregister_ssh_executor',
      'data': <String, dynamic>{'top_agent_id': topAgentId},
    });
  }

  void _send(Map<String, dynamic> message) {
    _ws?.send(message);
  }
}
