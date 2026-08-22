import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'websocket_service.dart';

/// SSH 执行器服务 - SSH 运行模式下管理远端主机的注册/注销。
///
/// SSH 运行模式：工具调用（文件读写 / 终端命令）经后端 paramiko 转发到
/// 用户配置的远端主机执行。连接配置由后端持久化在 ``ssh_connections`` 表
/// （重启后仍生效），本服务仅负责：
///
/// - 前端侧"是否已启用 SSH 模式"的状态持久化（按顶部 agent），供三态开关显示；
/// - 经反向 WebSocket 发送 ``register_ssh_executor`` / ``unregister_ssh_executor``，
///   并等待 ``register_ssh_executor_ack`` 确认（连接测试失败会收到错误）。
///
/// 与 [LocalExecutorService] 的差异：SSH 配置在后端是持久化的，因此
/// [cleanup] 不注销（避免应用退出误删用户配置），重启后前端按持久化状态
/// 恢复显示，后端仍按 DB 配置继续执行。
class SshExecutorService extends ChangeNotifier {
  SshExecutorService._();

  /// 全局单例
  static final SshExecutorService instance = SshExecutorService._();

  /// 当前选中的顶部 agent ID（SSH 模式按此单独控制）
  String _currentTopAgentId = '';

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
  /// 不注销后端连接：各顶部 agent 的 SSH 模式相互独立，配置持久化在 DB，
  /// 切换只影响前端显示与后续注册动作。
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
    final prefs = await SharedPreferences.getInstance();
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

  /// 绑定 WebSocket 服务（用于发送注册/注销消息）
  void attach(WebSocketService ws) {
    _ws = ws;
  }

  /// 启用 SSH 模式：持久化配置并注册，等待后端 ack。
  ///
  /// 返回 ack 结果字典：``{success: true}`` 或 ``{success: false, message}``。
  /// 注册失败（连接测试未通过 / 与 local 模式冲突）时不改变启用状态。
  Future<Map<String, dynamic>> enable(Map<String, dynamic> config) async {
    final Map<String, dynamic> ack = await _register(config);
    if (ack['success'] == true) {
      _enabled = true;
      _config = Map<String, dynamic>.from(config);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kEnabledKey(_currentTopAgentId), true);
      await prefs.setString(_kConfigKey(_currentTopAgentId), jsonEncode(_config));
      notifyListeners();
    } else {
      _enabled = false;
      notifyListeners();
    }
    return ack;
  }

  /// 禁用 SSH 模式：持久化关闭并通知后端注销（保留配置以便再次启用时预填）。
  Future<void> disable() async {
    _enabled = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabledKey(_currentTopAgentId), false);
    _sendUnregister(_currentTopAgentId);
    notifyListeners();
  }

  /// 按当前顶部 agent 的持久化 SSH 状态同步注册（重连/切换后调用）。
  ///
  /// 配置后端已持久化，这里仅重新发送注册确认，不等待 ack。
  void syncRegistration() {
    if (_currentTopAgentId.isEmpty) return;
    if (_enabled && _config.isNotEmpty) {
      _send(<String, dynamic>{
        'type': 'register_ssh_executor',
        'data': <String, dynamic>{
          'top_agent_id': _currentTopAgentId,
          'config': _config,
        },
      });
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
  /// 不注销后端 SSH 连接：SSH 配置后端持久化，注销会误删用户配置。
  void cleanup() {
    _ws = null;
    _pendingAck = null;
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
