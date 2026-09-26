import 'package:flutter/foundation.dart';

import 'api_service.dart';
import 'websocket_service.dart';

/// 本机执行模式的**配置适配器**（桌面端 M7c）。
///
/// 桌面端**不再由前端执行工具**：核心进程就在本机，工具（读写/终端/检索…）全部
/// 在核心里跑，因此 `register_local_executor` / `tool_exec_request` 这套反向执行协议
/// 已经没有生产者与消费者。
///
/// 但 `lib/ui` 仍按原接口调用本类（`lib/ui` 零改动对接），所以这里保留**同名同签名**
/// 的薄适配：
/// - 「本地模式」= 该 agent **未配置 SSH**；「工作目录」= `agents/<id>.yaml` 的
///   `workspace_dir`（空 = 核心默认 `<数据根>/workspaces/<agent_id>`）；
/// - 所有写操作都走 `PATCH /api/agents/{id}`，核心据此决定工具在哪跑；
/// - 注册/注销/心跳/凭据补录等方法保留为空实现（它们描述的是已删除的前端执行器）。
class LocalExecutorService extends ChangeNotifier {
  LocalExecutorService._();

  /// 全局单例（UI 直接取用）。
  static final LocalExecutorService instance = LocalExecutorService._();

  /// 每个 agent 最近一次从核心拉取的配置（未加载时为 null）。
  final Map<String, Map<String, dynamic>> _configs =
      <String, Map<String, dynamic>>{};

  Map<String, dynamic>? _agent(String teamId) =>
      _configs[teamId]?['agent'] as Map<String, dynamic>?;

  /// 该 agent 是否处于「本地」模式（= 未配置 SSH）。
  bool isTeamEnabled(String teamId) => !(_agent(teamId)?['has_ssh'] == true);

  /// 工作目录（空 = 核心默认工作空间）。
  String teamWorkingDirectory(String teamId) =>
      (_agent(teamId)?['workspace_dir'] ?? '').toString();

  /// 从核心拉取该 agent 的配置（幂等；供 UI 显示与预填）。
  Future<void> loadTeamSettings(String teamId) async {
    if (teamId.isEmpty) return;
    try {
      final Map<String, dynamic> data = await ApiService.getAgent(teamId);
      _configs[teamId] = data;
    } catch (_) {
      // 核心不可达时保留上次状态：UI 显示为未启用，不伪造成功
    }
  }

  /// 发送消息前确保配置已加载（旧的"确保执行器已注册"语义）。
  Future<void> ensureTeam(String teamId) => loadTeamSettings(teamId);

  /// 切换「本地模式」：开启 = 清空该 agent 的 SSH 配置（回到本机执行）。
  ///
  /// 关闭 = 什么都不做：真正的 SSH 模式由 [SshExecutorService.enableTeam] 写入配置。
  Future<void> setTeamEnabled(String teamId, bool value) async {
    if (teamId.isEmpty) return;
    if (value) {
      await ApiService.updateAgent(teamId, clearSsh: true);
    }
    await loadTeamSettings(teamId);
    notifyListeners();
  }

  /// 设置工作目录（空串 = 恢复核心默认工作空间）。
  Future<void> setTeamWorkingDirectory(String teamId, String path) async {
    if (teamId.isEmpty) return;
    await ApiService.updateAgent(teamId, workspaceDir: path.trim());
    await loadTeamSettings(teamId);
    notifyListeners();
  }

  // ── 以下为**已删除的前端执行器**遗留签名：保留空实现以维持 UI 兼容 ──

  /// 桌面端没有前端执行器需要注册（保留空实现）。
  void syncRegisteredTeams() {}

  /// 注册丢失回调：桌面端不存在注册，保留空实现。
  void handleRegistrationLost(String teamId) {}

  /// WS 通道：桌面端不需要（工具由核心执行），保留空实现。
  void attach(WebSocketService ws) {}

  /// 停用某 agent（本地模式无需启停），保留空实现。
  void deactivateTeam(String teamId) {}

  /// 终止某个工具进程：进程由核心管理，前端不再持有句柄。
  void killProcess(String toolId) {}

  /// 释放资源（幂等）。
  Future<void> cleanup() async {}
}
