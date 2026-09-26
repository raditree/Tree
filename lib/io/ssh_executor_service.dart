import 'package:flutter/foundation.dart';

import 'api_service.dart';
import 'websocket_service.dart';

/// SSH 运行模式的**配置适配器**（桌面端 M7c）。
///
/// 桌面端 SSH 连接由**核心进程**发起（`dartssh2` 在 `tree_local_exec` 里，工作空间
/// 语义在 `SshWorkspaceIO`）。前端只负责把用户填写的配置写进
/// `agents/<id>.yaml` 的 `ssh:` 段：
///
/// - 连接可达性与认证由核心在工具执行时校验（错误可读）；SSH 配置弹窗里的
///   「测试连接」按钮仍可在前端本机测一次（`ssh_connection_manager`，与核心同机）；
/// - 密码/口令由用户自己选择是否写在 agent 配置里（核心存明文、API 永不回显）；
/// - 注册/ack/凭据补录等方法保留为空实现（描述的是已删除的前端执行器）。
class SshExecutorService extends ChangeNotifier {
  SshExecutorService._();

  /// 全局单例（UI 直接取用）。
  static final SshExecutorService instance = SshExecutorService._();

  /// 凭据补录回调（保留字段：核心自己持有连接，不再需要前端补录）。
  Future<Map<String, dynamic>?> Function(String teamId, String reason)?
  onCredentialRequired;

  final Map<String, Map<String, dynamic>> _configs =
      <String, Map<String, dynamic>>{};

  Map<String, dynamic>? _agent(String teamId) =>
      _configs[teamId]?['agent'] as Map<String, dynamic>?;

  /// 该 agent 是否配置了 SSH。
  bool isTeamEnabled(String teamId) => _agent(teamId)?['has_ssh'] == true;

  /// SSH 配置的非机密字段（供配置表单预填；不含密码/口令）。
  Map<String, dynamic> teamConfig(String teamId) =>
      Map<String, dynamic>.from(
        (_configs[teamId]?['ssh'] as Map<dynamic, dynamic>?) ??
            const <dynamic, dynamic>{},
      );

  /// 从核心拉取该 agent 的配置（幂等；供 UI 显示与预填）。
  Future<void> loadTeamSettings(String teamId) async {
    if (teamId.isEmpty) return;
    try {
      final Map<String, dynamic> data = await ApiService.getAgent(teamId);
      _configs[teamId] = data;
    } catch (_) {
      // 核心不可达时保留上次状态
    }
  }

  /// 发送消息前确保配置已加载。
  Future<void> ensureTeam(String teamId) => loadTeamSettings(teamId);

  /// 启用 SSH 模式：把配置写进 agent（`PATCH /api/agents/{id}` 的 `ssh` 段）。
  ///
  /// 返回 `{success, message?}`：**配置校验失败（host 缺失等）在这里就报错**；
  /// 连通性则在核心首次执行工具时给出可读错误（或用户先用弹窗里的「测试连接」）。
  Future<Map<String, dynamic>> enableTeam(
    String teamId,
    Map<String, dynamic> config,
  ) async {
    if (teamId.isEmpty) {
      return <String, dynamic>{'success': false, 'message': '未选择顶部 agent'};
    }
    try {
      await ApiService.updateAgent(teamId, ssh: config);
    } catch (error) {
      return <String, dynamic>{
        'success': false,
        'message': '$error'.replaceFirst('Exception: ', ''),
      };
    }
    await loadTeamSettings(teamId);
    notifyListeners();
    return <String, dynamic>{'success': true};
  }

  /// 关闭 SSH 模式（清空 agent 的 ssh 配置，回到本机执行）。
  Future<void> disableTeam(String teamId) async {
    if (teamId.isEmpty) return;
    await ApiService.updateAgent(teamId, clearSsh: true);
    await loadTeamSettings(teamId);
    notifyListeners();
  }

  // ── 以下为**已删除的前端执行器**遗留签名：保留空实现以维持 UI 兼容 ──

  /// 注册确认：桌面端不存在前端注册（保留空实现）。
  void resolveAck(Map<String, dynamic> ackData) {}

  /// 桌面端没有前端执行器需要注册（保留空实现）。
  void syncRegisteredTeams() {}

  /// 注册丢失回调：保留空实现。
  void handleRegistrationLost(String teamId) {}

  /// WS 通道：桌面端不需要（工具由核心执行），保留空实现。
  void attach(WebSocketService ws) {}

  /// 停用某 agent：只需清内存缓存（配置在核心）。
  Future<void> deactivateTeam(String teamId) async {
    _configs.remove(teamId);
  }

  /// 释放资源（幂等）。
  Future<void> cleanup() async {
    _configs.clear();
  }
}
