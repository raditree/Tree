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
/// - 接管 ``tool_exec_request``：请求所属 team 处于 SSH 模式时经 SSH 会话
///   执行并回传 ``tool_exec_response``；
/// - 注销/清理时关闭前端持有的 SSH 连接。
///
/// 内部状态为 per-team 的 ``Map<teamId, _SshTeamState>``：所有执行路径按请求
/// payload 的 ``team_id`` 查找对应状态，与"当前选中 agent"解耦。注册由懒激活
/// 驱动：消息发送前 [ensureTeam] 幂等地加载并注册已启用的 team，WS 重连后
/// [syncRegisteredTeams] 恢复"已注册且启用"team 的注册。
///
/// 与 [LocalExecutorService] 的差异：SSH 配置在后端是持久化的，因此
/// [cleanup] 不注销（避免应用退出误删用户配置），重启后前端按持久化状态
/// 恢复显示，后端仍按 DB 配置继续执行。

/// 单个顶部 agent（team）的 SSH 执行器状态。
class _SshTeamState {
  _SshTeamState({required this.teamId});

  /// 顶部 agent（team）ID
  final String teamId;

  /// SSH 模式是否启用（持久化）
  bool enabled = false;

  /// SSH 连接配置（host/port/username/auth_type/remote_base_dir/...）
  Map<String, dynamic> config = <String, dynamic>{};

  /// 是否已向后端注册 SSH 执行器
  bool registered = false;

  /// 该 team 等待后端 ack 的挂起请求（per-team Completer）
  Completer<Map<String, dynamic>>? pendingAck;
}

/// 在途 SSH hook 任务定位记录（取消 ``tool_exec_cancel`` 时使用）。
///
/// 后端取消 hook 时发送 ``tool_exec_cancel``（tool_id + pidfile）；hook 请求
/// 到达本端时记录其归属 team 与 workspace，取消处理者据此经该 team 的 SSH
/// 会话执行远端 ``kill -TERM``。
class _SshHookTarget {
  const _SshHookTarget({
    required this.teamId,
    required this.workspaceId,
    required this.pidfile,
  });

  /// 发起 hook 请求的顶部 agent（team）ID
  final String teamId;

  /// hook 请求的 workspace_id
  final String workspaceId;

  /// 远端 pidfile 路径（workspace 相对路径，= output_file + '.pid'）
  final String pidfile;
}

class SshExecutorService extends ChangeNotifier {
  SshExecutorService._();

  /// 全局单例
  static final SshExecutorService instance = SshExecutorService._();

  /// 前端 SSH 连接管理器（按顶部 agent 懒建连 / 缓存 / 失活重建）
  final SshConnectionManager _connectionManager = SshConnectionManager();

  /// per-team 状态：team_id -> SSH 执行器状态。
  ///
  /// 所有执行路径按请求 payload 的 ``team_id`` 查找状态，与"当前选中
  /// agent"解耦；条目由 [loadTeamSettings] / [ensureTeam] 懒创建。
  final Map<String, _SshTeamState> _states = <String, _SshTeamState>{};

  /// 在途 SSH hook 任务记录：tool_id -> 定位信息（取消处理用）。
  ///
  /// hook 请求（op=``exec_shell_hook``）到达时记录，hook 执行结束（正常/
  /// 出错/取消）后移除；取消处理者据此把 tool_id 关联回 team 与 pidfile。
  final Map<String, _SshHookTarget> _hookTargets =
      <String, _SshHookTarget>{};

  /// 等待后端 ack 的 FIFO 队列（按注册消息发送顺序排列）。
  ///
  /// 后端对每条 ``register_ssh_executor`` 恰好回一条 ack 且不回显 team_id，
  /// 同一连接上按发送顺序逐条匹配即可准确路由到对应 team 的 per-team
  /// Completer。
  final List<_SshTeamState> _ackQueue = <_SshTeamState>[];

  /// SharedPreferences 键前缀（后接团队 ID，实现按顶部 agent 持久化）
  static const String _kEnabledPrefix = 'ssh_exec_enabled_';
  static const String _kConfigPrefix = 'ssh_exec_config_';

  static String _kEnabledKey(String teamId) => '$_kEnabledPrefix$teamId';
  static String _kConfigKey(String teamId) => '$_kConfigPrefix$teamId';

  /// 同步工具执行期间的进度上报间隔（与 LocalExecutorService 一致）。
  ///
  /// 后端等待响应时以"距最近一次进度上报"做卡死判定：只要前端还在经 SSH
  /// 执行就周期上报 ``tool_exec_progress`` 续期，远程长任务（grep 数分钟 /
  /// terminal 360s+）不会被后端等待窗口误杀；本间隔应明显小于后端的
  /// _STALL_WITHOUT_PROGRESS_SECONDS（60s），留足网络/调度余量。
  static const Duration _kToolProgressInterval = Duration(seconds: 10);

  /// 承载当前 WebSocket 通道的服务（用于发送注册/注销消息）
  WebSocketService? _ws;

  /// 指定 team 的 SSH 模式是否已启用（无状态时视为未启用，供 UI 显示）
  bool isTeamEnabled(String teamId) => _states[teamId]?.enabled ?? false;

  /// 指定 team 的 SSH 连接配置（无状态时返回空 Map，供配置表单预填）
  Map<String, dynamic> teamConfig(String teamId) =>
      Map<String, dynamic>.from(_states[teamId]?.config ??
          const <String, dynamic>{});

  /// 读取指定 team 的持久化设置到内存状态（不触发注册，供 UI 显示/预填）。
  Future<void> loadTeamSettings(String teamId) async {
    if (teamId.isEmpty) return;
    final _SshTeamState state =
        _states.putIfAbsent(teamId, () => _SshTeamState(teamId: teamId));
    await _loadTeamSettings(state);
  }

  /// 从 SharedPreferences 恢复单个 team 的 SSH 模式设置。
  ///
  /// 竞态防护：等待期间该条目可能已被 [deactivateTeam] 移除或替换，
  /// 丢弃过期恢复结果（否则已删除 team 的 SSH 启用态会被写回内存态）。
  Future<void> _loadTeamSettings(_SshTeamState state) async {
    final String id = state.teamId;
    final prefs = await SharedPreferences.getInstance();
    if (!identical(_states[id], state)) return;
    state.enabled = prefs.getBool(_kEnabledKey(id)) ?? false;
    final String? raw = prefs.getString(_kConfigKey(id));
    if (raw != null && raw.isNotEmpty) {
      try {
        state.config = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        state.config = <String, dynamic>{};
      }
    }
  }

  /// 懒激活指定 team 的 SSH 执行器（幂等）。
  ///
  /// - 状态不存在：创建并从 SharedPreferences 恢复设置；
  /// - 已启用且有配置但未注册：发送注册并等待 ack（per-team Completer，
  ///   最长 15s），成功后预热 SSH 连接；
  /// - 未启用 / 无配置：静默返回（后端按"无执行器"回落云端执行）。
  Future<void> ensureTeam(String teamId) async {
    if (teamId.isEmpty) return;
    _SshTeamState? state = _states[teamId];
    if (state == null) {
      final _SshTeamState created = _SshTeamState(teamId: teamId);
      _states[teamId] = created;
      await _loadTeamSettings(created);
      state = _states[teamId];
      if (state == null) return; // 等待期间被 deactivateTeam 移除
    }
    if (state.enabled && state.config.isNotEmpty && !state.registered) {
      await _registerTeam(state);
    }
  }

  /// 注销指定 team 的 SSH 执行器并移除其状态（删除顶部 agent 时调用）：
  /// 持久化关闭开关、通知后端注销、关闭该 team 的 SSH 连接、清理等待。
  Future<void> deactivateTeam(String teamId) async {
    if (teamId.isEmpty) return;
    // 回收该 team 的 MCP 隧道会话与插件宿主会话：远端 kill 需要通道，
    // 须在关闭连接之前执行（M2 §14.3.2 级联）
    SshWorkspaceExecutor.disposeMcpSessionsOf(teamId);
    await SshWorkspaceExecutor.disposePluginHostSessionsOf(teamId);
    final _SshTeamState? state = _states.remove(teamId);
    if (state == null) return;
    final Completer<Map<String, dynamic>>? completer = state.pendingAck;
    state.pendingAck = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(<String, dynamic>{
        'success': false,
        'message': '该顶部 agent 已删除',
      });
    }
    _ackQueue.remove(state);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabledKey(teamId), false);
    await _connectionManager.close(teamId);
    _sendUnregister(teamId);
  }

  /// 启用指定 team 的 SSH 模式（模式切换弹窗调用）：前端本机连接测试 →
  /// 注册并等待 ack → 建立并缓存连接。
  ///
  /// 返回 ``{success: true}`` 或 ``{success: false, message}``。
  /// 连接测试在**前端本机**进行（IP 相对前端），失败即返回，不再发后端；
  /// ack 成功才持久化启用状态并预热 SSH 连接。
  Future<Map<String, dynamic>> enableTeam(
    String teamId,
    Map<String, dynamic> config,
  ) async {
    if (teamId.isEmpty) {
      return <String, dynamic>{'success': false, 'message': '未选择顶部 agent'};
    }
    final _SshTeamState state =
        _states.putIfAbsent(teamId, () => _SshTeamState(teamId: teamId));
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
    state.config = Map<String, dynamic>.from(config);
    final Map<String, dynamic> ack = await _registerTeam(state);
    if (ack['success'] == true) {
      // ③ ack 成功则持久化启用状态（SSH 连接由注册流程预热；执行时失活
      // 会按需重建）
      state.enabled = true;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kEnabledKey(teamId), true);
      await prefs.setString(_kConfigKey(teamId), jsonEncode(state.config));
      notifyListeners();
    } else {
      state.enabled = false;
      notifyListeners();
    }
    return ack;
  }

  /// 禁用指定 team 的 SSH 模式：持久化关闭、关闭 SSH 连接并通知后端注销。
  Future<void> disableTeam(String teamId) async {
    if (teamId.isEmpty) return;
    final _SshTeamState? state = _states[teamId];
    if (state == null) return;
    state.enabled = false;
    state.registered = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabledKey(teamId), false);
    // 关闭连接前先回收该 team 的 MCP 隧道会话：远端 kill 依赖通道，
    // 连接一关就只剩本地残留记录（远端进程会随通道挂断，但记录须清掉）
    SshWorkspaceExecutor.disposeMcpSessionsOf(teamId);
    await SshWorkspaceExecutor.disposePluginHostSessionsOf(teamId);
    await _connectionManager.close(teamId);
    _sendUnregister(teamId);
    notifyListeners();
  }

  /// WS 重连/首连后恢复注册：仅对"已注册且启用"的 team 重新发送注册确认
  /// 并重建 SSH 连接（不等待 ack）；未激活的 team 不注册。
  ///
  /// 配置后端已持久化，这里仅重建 SSH 连接（若已断开）并重新发送注册确认。
  void syncRegisteredTeams() {
    // 断线期间挂起的 ack 永远不会到达：先清空旧队列，避免新旧注册的
    // ack 错位匹配
    _failAllPendingAcks('连接已断开，注册结果未知');
    for (final _SshTeamState state in _states.values) {
      if (state.enabled && state.config.isNotEmpty && state.registered) {
        unawaited(_rebuildConnection(state));
        _registerTeam(state, waitForAck: false);
      }
    }
    // 宿主会话对账：team 未注册/未启用 → 回收（经远端 kill，尽力而为）
    final Set<String> usable = _states.values
        .where((_SshTeamState s) => s.enabled && s.registered)
        .map((_SshTeamState s) => s.teamId)
        .toSet();
    unawaited(SshWorkspaceExecutor.reconcilePluginHostSessions(usable));
  }

  /// 处理后端 ``registration_lost`` 通知：该 team 的 SSH 执行器注册已被后端
  /// 清除（WS 断连清理 / 连续超时自动停用）。
  ///
  /// 复位 registered=false，使后续 [ensureTeam]（发消息/作答/重连自动补注册）
  /// 不会因 stale registered=true 而跳过——否则后端已注销执行器、前端仍以为
  /// 注册在册，工具调用会一直"前端执行器未启用"无法自愈。启用开关与 SSH
  /// 配置等持久化设置不受影响。
  void handleRegistrationLost(String teamId) {
    if (teamId.isEmpty) return;
    final _SshTeamState? state = _states[teamId];
    if (state != null && state.registered) {
      state.registered = false;
      debugPrint(
        '[SshExecutor] 后端通知 SSH 执行器注册已丢失(team=$teamId)，'
        '将在下次动作时自动重注册',
      );
    }
  }

  /// 按该 team 配置重建（或复用）SSH 连接；失败静默忽略（工具执行时按需重建）。
  Future<void> _rebuildConnection(_SshTeamState state) async {
    try {
      await _connectionManager.connect(state.teamId, state.config);
    } catch (_) {
      // 建连失败不阻塞注册流程，首个工具调用会按需重建
    }
  }

  /// 处理后端 ack 消息（由 message_panel 在 WS 分发中调用）。
  ///
  /// ack 不回显 team_id，按注册消息发送顺序（FIFO）匹配到对应 team 的
  /// per-team Completer 完成挂起等待。
  void resolveAck(Map<String, dynamic> ackData) {
    // 应用后端下发（后端 app.yaml: ssh.max_concurrent_per_team）的单连接
    // 并发上限；缺失/非正整数时保持前端当前值
    if (ackData['success'] == true) {
      _connectionManager
          .applyMaxConcurrentPerTeam(ackData['max_concurrent_per_team']);
    }
    while (_ackQueue.isNotEmpty) {
      final _SshTeamState state = _ackQueue.removeAt(0);
      final Completer<Map<String, dynamic>>? completer = state.pendingAck;
      state.pendingAck = null;
      if (completer != null && !completer.isCompleted) {
        completer.complete(ackData);
        return;
      }
    }
  }

  /// 释放资源（应用退出时调用）。
  ///
  /// 不注销后端 SSH 注册（配置后端持久化，注销会误删用户配置），仅关闭
  /// 前端持有的 SSH 连接、终结挂起的 ack 等待并移除工具请求/取消处理者。
  void cleanup() {
    _failAllPendingAcks('连接已关闭');
    _ws?.removeToolExecRequestHandler(_handleToolExecRequest);
    _ws?.removeToolExecCancelHandler(_handleToolExecCancel);
    _hookTargets.clear();
    // 回收残留的 MCP 隧道会话（调用中途退出时后端不再回 close）：
    // 远端 kill 需要通道，须在关闭连接之前执行
    SshWorkspaceExecutor.disposeAllMcpSessions();
    _ws = null;
    // 插件宿主会话回收依赖远端通道：kill 完成后才关连接（尽力而为）
    unawaited(
      SshWorkspaceExecutor.disposeAllPluginHostSessions()
          .whenComplete(() => _connectionManager.closeAll()),
    );
  }

  /// 终结所有挂起的 ack 等待（per-team Completer 以失败完成）并清空队列。
  void _failAllPendingAcks(String message) {
    for (final _SshTeamState state in _ackQueue) {
      final Completer<Map<String, dynamic>>? completer = state.pendingAck;
      state.pendingAck = null;
      if (completer != null && !completer.isCompleted) {
        completer.complete(<String, dynamic>{
          'success': false,
          'message': message,
        });
      }
    }
    _ackQueue.clear();
  }

  /// 绑定 WebSocket 服务并接管 ``tool_exec_request`` / ``tool_exec_cancel``。
  ///
  /// 与本地执行器共同注册为工具请求/取消处理者；本处理者仅在 SSH 模式
  /// 启用时接管请求，取消按 hook 记录匹配。
  void attach(WebSocketService ws) {
    _ws = ws;
    ws.addToolExecRequestHandler(_handleToolExecRequest);
    ws.addToolExecCancelHandler(_handleToolExecCancel);
  }

  /// 处理 ``tool_exec_request``：请求所属 team 处于 SSH 模式时经 SSH 会话
  /// 执行并回传 ``tool_exec_response``。
  ///
  /// 返回 `true` 表示已接管（该 team 的 SSH 模式已注册且启用时）；否则返回
  /// `false` 放行。
  ///
  /// 归属校验（集合化）：后端按注册连接定向投递（``data.targeted=true``），
  /// 仅接管"本前端已注册且启用 SSH 模式"的 team——按请求 payload 的
  /// ``team_id`` 查 per-team 状态，不读"当前选中 agent"槽位，避免残留其他
  /// team 的 SSH 启用态把请求误截获发往错误远端主机。
  bool _handleToolExecRequest(Map<String, dynamic> message) {
    final Map<String, dynamic> data =
        (message['data'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final String toolId = (data['tool_id'] as String?) ?? '';
    final String reqTeam = (data['team_id'] as String?) ?? '';
    // payload 校验：tool_id 缺失时后端 pending 无法定位、本端无法回包，放行
    if (toolId.isEmpty) return false;
    // team_id 缺失：直接快速失败回包，避免后端 pending 空等 120s
    if (reqTeam.isEmpty) {
      _sendToolExecResponse(toolId, <String, dynamic>{
        'success': false,
        'error': 'missing team_id/tool_id',
      });
      return true;
    }
    final _SshTeamState? state = _states[reqTeam];
    if (state == null || !state.enabled || !state.registered) {
      // 定向投递到本连接说明后端认定本端是该 team 的 SSH 执行器，本端却不
      // 可执行（刚被 registration_lost 复位 / 已关闭 SSH 模式 / 状态不一致）：
      // 明确回传错误，避免后端空等满卡死窗口（60s）后误判卡死并自动停用。
      // 广播兜底（targeted=false）下保持静默放行，理由同本地执行器。
      if ((data['targeted'] as bool?) ?? false) {
        _sendToolExecResponse(toolId, <String, dynamic>{
          'success': false,
          'error': 'SSH 执行器当前不可用（未注册或未启用 SSH 模式），'
              '请重新开启该 agent 的 SSH 模式后重试',
        });
        return true;
      }
      return false;
    }
    final String workspaceId = (data['workspace_id'] as String?) ?? '';
    final String op = (data['op'] as String?) ?? '';

    // hook 模式：记录 tool_id → (team, workspace, pidfile)，供取消时定位；
    // hook 执行结束（正常/出错）后移除记录
    if (op == 'exec_shell_hook') {
      final String outputFile = (data['output_file'] as String?) ?? '';
      _hookTargets[toolId] = _SshHookTarget(
        teamId: reqTeam,
        workspaceId: workspaceId,
        pidfile: outputFile.isEmpty ? '' : '$outputFile.pid',
      );
    }

    // 非 hook 的同步工具执行：执行期间每 _kToolProgressInterval 上报一次进度，
    // 让后端的卡死检测续期——远程长任务（grep / terminal 等）只要在跑就不会
    // 被误判为超时；hook 走非阻塞通道、无后端等待窗口，不需进度续期。
    final Timer? progressTimer = op == 'exec_shell_hook'
        ? null
        : Timer.periodic(
            _kToolProgressInterval,
            (_) => _sendToolProgress(toolId, reqTeam),
          );
    // 按请求 team 构建执行器：连接与路径映射都用该 team 自己的配置，
    // 执行 A team 请求时不会读到 B team 的配置（per-team 隔离）
    SshWorkspaceExecutor(_connectionManager, teamId: reqTeam,
            config: state.config)
        .execute(workspaceId, op, data)
        .then((Map<String, dynamic> result) {
      if (op == 'exec_shell_hook') {
        _hookTargets.remove(toolId);
      }
      _sendToolExecResponse(toolId, result);
    }).catchError((Object error) {
      _hookTargets.remove(toolId);
      _sendToolExecResponse(toolId, <String, dynamic>{
        'error': error.toString(),
      });
    }).whenComplete(() => progressTimer?.cancel());
    return true;
  }

  /// 上报一次工具执行进度（``tool_exec_progress``，供后端卡死检测续期）。
  void _sendToolProgress(String toolId, String teamId) {
    _send(<String, dynamic>{
      'type': 'tool_exec_progress',
      'data': <String, dynamic>{
        'tool_id': toolId,
        'team_id': teamId,
      },
    });
  }

  /// 处理 ``tool_exec_cancel``：终止对应 hook 的远端后台进程。
  ///
  /// 按 tool_id 找到 hook 启动时记录的 team/workspace/pidfile（payload 中
  /// 的 pidfile 优先），经该 team 的 SSH 会话执行 ``kill -TERM``（尽力终止）。
  /// 不立即回执：远端 wrapped 命令的 wait 在进程退出后返回，hook 请求随即
  /// 回传退出码，后端据此把任务落定为 cancelled（与本地执行器语义一致）。
  void _handleToolExecCancel(Map<String, dynamic> message) {
    final Map<String, dynamic> data =
        (message['data'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final String toolId = (data['tool_id'] as String?) ?? '';
    if (toolId.isEmpty) return;
    final _SshHookTarget? target = _hookTargets.remove(toolId);
    if (target == null) return; // 非本端 hook（本地模式/已结束），静默忽略
    final String payloadPidfile = (data['pidfile'] as String?) ?? '';
    final String pidfile = payloadPidfile.isNotEmpty ? payloadPidfile : target.pidfile;
    if (pidfile.isEmpty) return;
    final _SshTeamState? state = _states[target.teamId];
    if (state == null || state.config.isEmpty) return;
    unawaited(
      SshWorkspaceExecutor(_connectionManager,
              teamId: target.teamId, config: state.config)
          .cancelHook(target.workspaceId, pidfile),
    );
  }

  /// 回传一次工具执行结果（``tool_exec_response``，格式对齐 LocalExecutorService）。
  void _sendToolExecResponse(String toolId, Map<String, dynamic> result) {
    _send(<String, dynamic>{
      'type': 'tool_exec_response',
      'data': <String, dynamic>{
        'tool_id': toolId,
        'result': result,
      },
    });
  }

  /// 发送指定 team 的注册消息并按需等待 ack。
  ///
  /// 发送时即乐观置位 registered：后端处理注册后即开始向本端转发工具请求，
  /// 此时该 team 的配置已知可直接接管；ack 失败再回退。
  ///
  /// [waitForAck] 为 false 时（WS 重连恢复注册场景）不等待结果：ack 由
  /// [resolveAck] 按 FIFO 匹配后丢弃。
  Future<Map<String, dynamic>> _registerTeam(
    _SshTeamState state, {
    bool waitForAck = true,
  }) {
    if (state.teamId.isEmpty) {
      return Future<Map<String, dynamic>>.value(
        <String, dynamic>{'success': false, 'message': '未选择顶部 agent'},
      );
    }
    final Completer<Map<String, dynamic>> completer =
        Completer<Map<String, dynamic>>();
    state.pendingAck = completer;
    state.registered = true;
    _ackQueue.add(state);
    _send(<String, dynamic>{
      'type': 'register_ssh_executor',
      'data': <String, dynamic>{
        'team_id': state.teamId,
        'config': state.config,
      },
    });
    if (!waitForAck) {
      unawaited(completer.future.then<void>((_) {
        if (identical(state.pendingAck, completer)) {
          state.pendingAck = null;
        }
      }));
      return Future<Map<String, dynamic>>.value(
        <String, dynamic>{'success': true},
      );
    }
    return _awaitAck(state, completer);
  }

  /// 等待指定 team 的注册 ack（超时 15 秒）；成功后预热该 team 的 SSH 连接。
  Future<Map<String, dynamic>> _awaitAck(
    _SshTeamState state,
    Completer<Map<String, dynamic>> completer,
  ) async {
    try {
      final Map<String, dynamic> ack = await completer.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          return <String, dynamic>{'success': false, 'message': '等待后端确认超时'};
        },
      );
      if (ack['success'] == true) {
        // 预热建连（失败不阻塞注册流程，工具执行时按需重建）
        unawaited(_rebuildConnection(state));
      } else {
        state.registered = false;
      }
      return ack;
    } finally {
      if (identical(state.pendingAck, completer)) {
        state.pendingAck = null;
      }
      _ackQueue.remove(state);
    }
  }

  void _sendUnregister(String teamId) {
    _send(<String, dynamic>{
      'type': 'unregister_ssh_executor',
      'data': <String, dynamic>{'team_id': teamId},
    });
  }

  void _send(Map<String, dynamic> message) {
    _ws?.send(message);
  }
}
