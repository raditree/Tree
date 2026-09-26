// 插件宿主会话（M2：plugin_host_* 通道前端侧，契约 v1.3 §14）。
//
// 背景：宿主通道 = 插件 ↔ 宿主（本机前端执行器 / SSH 会话）的受控通道，
// 复用反向 WS ``tool_exec_request`` / ``tool_exec_response`` 链路与
// ``mcp_stdio_tunnel`` 会话状态机思想（退出感知 / 幂等关闭）。本批仅
// 生命周期三 op（``start`` / ``stop`` / ``status``），不含数据面（§14.2）。
//
// 本文件承载与执行器解耦的纯逻辑，便于单测（进程启动经 [PluginHostSpawn]
// 注入，测试用 fake 句柄，不依赖真进程）：
// - [PluginHostSessionManager]：会话表 + 最小生命周期 + 清理契约四场景
//   （stop 指令 / 级联回收（team） / 应用退出 / 断连回收对账，§14.3）；
// - 回传字段按 §14.2：start → ``host_session_id`` / ``error``；stop →
//   ``ok`` / ``error``（幂等）；status → ``state``（running/closed）/
//   ``exit_code?`` / ``stderr_tail?``；
// - 退出上报：承载进程退出 → [PluginHostSessionManager] 经 ``notify`` 发出
//   上行帧 [kPluginHostEventType]（断连时尽力而为；状态仍留驻本表供
//   status 查询 / 重连对账）；
// - SSH 侧远端命令构建 / 解析的纯函数（供 ssh_workspace_executor 复用）。
//
// 安全收口（栖迟 17:58 回执 #3，§14.4 不扩信任）：本批 payload 透传容忍
// （command/args 仅留位、可解析），但**不落地取自 payload 的任意命令**——
// 承载进程固定走平台最小空转型；自定义命令留后续批次评审。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

/// 退出上报上行帧类型（契约 §14.3.4「宿主主动上报」）。
const String kPluginHostEventType = 'plugin_host_event';

/// 宿主进程 stderr 尾部保留的最大字符数（status 诊断用）。
const int kPluginHostStderrTailCap = 2000;

/// 会话 id 自增序号（与毫秒时间戳拼接，避免同毫秒内碰撞）。
int _pluginHostSessionSeq = 0;

/// 生成宿主会话 id（前端生成、后端按不透明字符串存取，契约 §14.2）。
///
/// 格式 ``phs_<epoch_ms>_<seq>``：epoch 毫秒跨重启仍单调，保证全局唯一。
String newPluginHostSessionId([DateTime? now]) {
  final int ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
  _pluginHostSessionSeq += 1;
  return 'phs_${ms}_$_pluginHostSessionSeq';
}

/// 保留文本末尾 [maxChars] 个字符（stderr 尾部截断；超长丢弃头部）。
String trimTail(String text, int maxChars) {
  if (maxChars <= 0) return '';
  if (text.length <= maxChars) return text;
  return text.substring(text.length - maxChars);
}

/// 解码宿主进程输出字节：严格 UTF-8 优先，失败回退 latin1（不抛异常）。
String decodePluginHostBytes(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return latin1.decode(bytes, allowInvalid: true);
  }
}

/// POSIX shell 单引号转义（远端命令拼接用；与既有 SSH 执行器口径一致）。
String shQuotePosix(String value) => "'${value.replaceAll("'", "'\\''")}'";

/// 宿主默认「最小空转进程」的命令行参数（本批唯一承载形态）。
///
/// 选择原则：存活可 kill、退出可观察、无外部副作用——
/// - Windows 纯本地目录：``ping -n 3600 127.0.0.1``（约 1 小时后自然退出）；
/// - Windows + Unix/WSL 目录：``bash -lc "cd <目录> && sleep 3600"``
///   （Windows API 无法以 Unix 路径作进程 cwd，经 bash 进入）；
/// - Unix：``sleep 3600``。
List<String> defaultIdleArgv({
  required bool isWindows,
  required bool unixLike,
  required String workingDirectory,
}) {
  if (isWindows && !unixLike) {
    return <String>['ping', '-n', '3600', '127.0.0.1'];
  }
  if (isWindows) {
    return <String>[
      'bash',
      '-lc',
      'cd ${shQuotePosix(workingDirectory)} && sleep 3600',
    ];
  }
  return <String>['sleep', '3600'];
}

// ---------------------------------------------------------------------------
// SSH 侧远端命令构建 / 解析（纯函数；由 ssh_workspace_executor 使用）
// ---------------------------------------------------------------------------

/// 构建远端「启动宿主会话」命令：后台常驻 + pid 落盘（供 kill/status 定位）。
///
/// 本批固定 ``sleep 3600`` 最小空转型（安全收口：不执行任意命令）；
/// pidfile 固定放 ``/tmp``（前端生成、仅含安全字符，无需转义用户输入）。
String buildRemoteHostStartCommand({
  required String cwd,
  required String pidFile,
}) {
  return 'cd ${shQuotePosix(cwd)} || exit 1; '
      'nohup sleep 3600 </dev/null >/dev/null 2>&1 & '
      'echo \$! > ${shQuotePosix(pidFile)}';
}

/// 构建远端「查询宿主会话状态」命令（输出 ``running`` / ``closed``）。
String buildRemoteHostStatusCommand({required String pidFile}) {
  return 'if [ -f ${shQuotePosix(pidFile)} ] && '
      'kill -0 \$(cat ${shQuotePosix(pidFile)}) 2>/dev/null; '
      'then echo running; else echo closed; fi';
}

/// 构建远端「停止宿主会话」命令（尽力终止 + 清理 pidfile）。
String buildRemoteHostStopCommand({required String pidFile}) {
  return 'kill -TERM \$(cat ${shQuotePosix(pidFile)}) 2>/dev/null || true; '
      'rm -f ${shQuotePosix(pidFile)}';
}

/// 解析远端状态命令输出 → ``running`` / ``closed``（未知输出按 closed 处理）。
String parseRemoteHostStatusOutput(String stdout) {
  return stdout.contains('running') ? 'running' : 'closed';
}

// ---------------------------------------------------------------------------
// 会话模型与注入点
// ---------------------------------------------------------------------------

/// 宿主进程启动请求（由 [PluginHostSessionManager] 组装后交给注入的启动器）。
class PluginHostSpawnRequest {
  PluginHostSpawnRequest({
    required this.hostSessionId,
    required this.teamId,
    required this.workingDirectory,
    required this.unixLike,
  });

  /// 本次会话 id（pidfile / 日志关联用）。
  final String hostSessionId;

  /// 归属 team（隔离键）。
  final String teamId;

  /// 进程工作目录（本地 = team 工作目录；SSH = 远端工作空间根）。
  final String workingDirectory;

  /// 工作目录是否为 Unix/WSL 风格（决定默认空转进程形态）。
  final bool unixLike;
}

/// 宿主进程句柄：屏蔽本地 [Process] / 远端命令 / 测试 fake 的差异。
class PluginHostProcessHandle {
  PluginHostProcessHandle({
    required this.pid,
    required this.exitCode,
    required this.stderr,
    required this.kill,
  });

  final int pid;

  /// 进程退出码（进程退出时完成；kill 后同样会完成）。
  final Future<int> exitCode;

  /// stderr 流（用于聚合尾部诊断信息）。
  final Stream<List<int>> stderr;

  /// 尽力终止（幂等；返回是否发出终止信号）。
  final bool Function() kill;
}

/// 宿主进程启动器签名（本地 / SSH / 测试 fake 各自实现）。
typedef PluginHostSpawn = Future<PluginHostProcessHandle> Function(
  PluginHostSpawnRequest request,
);

/// 单个宿主会话的持存状态（status 诊断 + 清理对账）。
class PluginHostSession {
  PluginHostSession({
    required this.hostSessionId,
    required this.hostKey,
    required this.teamId,
    required this.pid,
  });

  final String hostSessionId;

  /// 幂等键（plugin_id + granularity + scope 键位，装配与实例键一致）。
  final String hostKey;

  final String teamId;

  final int pid;

  /// 进程句柄（终止用；进程退出后仍持有引用，kill 幂等无碍）。
  PluginHostProcessHandle? handle;

  /// ``running`` / ``closed``（契约 §14.2）。
  String state = 'running';

  /// 进程退出码（退出后可知；stop 后由退出回调补齐）。
  int? exitCode;

  /// stderr 尾部（截断至 [kPluginHostStderrTailCap]）。
  String stderrTail = '';

  /// 断连 / 注册丢失后的失联标记（重连对账回收依据，§14.3.3）。
  bool lost = false;

  /// 是否已发出过终止信号（stop 幂等保护）。
  bool killIssued = false;
}

// ---------------------------------------------------------------------------
// 会话表 + 最小生命周期 + 清理契约
// ---------------------------------------------------------------------------

/// 插件宿主会话表 + 最小生命周期 + 清理契约（§14.2 / §14.3）。
///
/// 线程模型：全部方法在后端消息处理（单线程事件循环）内调用，不做加锁；
/// 进程退出的异步回调串行到达，天然有序。
class PluginHostSessionManager {
  PluginHostSessionManager({
    required this._spawn,
    required this._notify,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final PluginHostSpawn _spawn;
  final void Function(Map<String, dynamic> frame) _notify;
  final DateTime Function() _now;

  final Map<String, PluginHostSession> _sessions =
      <String, PluginHostSession>{};

  /// host_key → host_session_id（幂等复用索引）
  final Map<String, String> _byKey = <String, String>{};

  /// 当前会话数（测试 / 诊断用）。
  @visibleForTesting
  int get sessionCount => _sessions.length;

  /// 按 id 取会话（测试 / 诊断用）。
  @visibleForTesting
  PluginHostSession? sessionById(String hostSessionId) =>
      _sessions[hostSessionId];

  // -- 三 op ---------------------------------------------------------------

  /// ``plugin_host_start``：建立宿主侧插件会话（幂等：同 host_key 复用）。
  ///
  /// - 同 host_key 且会话在跑 → 复用并返回同一 [PluginHostSession.hostSessionId]；
  /// - 同 host_key 但旧会话已 closed/残留 → 回收旧条目后重建、返回新 id；
  /// - 启动失败 → ``{error}``（不建条目）。
  ///
  /// [payload] 本批透传容忍、不消费（安全收口：不落地任意命令）。
  Future<Map<String, dynamic>> start({
    required String hostKey,
    required String teamId,
    required String workingDirectory,
    required bool unixLike,
    Map<String, dynamic>? payload,
  }) async {
    if (hostKey.isEmpty) {
      return <String, dynamic>{'error': 'plugin_host_start 缺少 host_key'};
    }
    final String? existingId = _byKey[hostKey];
    final PluginHostSession? existing =
        existingId == null ? null : _sessions[existingId];
    if (existing != null && existing.state == 'running') {
      debugPrint(
        '[plugin_host] start 复用会话 key=$hostKey id=${existing.hostSessionId}',
      );
      return <String, dynamic>{'host_session_id': existing.hostSessionId};
    }
    if (existing != null) {
      // 旧会话已 closed：回收残留条目后重建
      _killSession(existing, reason: 'start 重建回收旧会话');
      _removeSession(existing.hostSessionId);
    }
    final String id = newPluginHostSessionId(_now());
    try {
      final PluginHostProcessHandle handle =
          await _spawn(PluginHostSpawnRequest(
        hostSessionId: id,
        teamId: teamId,
        workingDirectory: workingDirectory,
        unixLike: unixLike,
      ));
      final PluginHostSession session = PluginHostSession(
        hostSessionId: id,
        hostKey: hostKey,
        teamId: teamId,
        pid: handle.pid,
      );
      session.handle = handle;
      _sessions[id] = session;
      _byKey[hostKey] = id;
      _wireExit(session, handle);
      debugPrint(
        '[plugin_host] start 已建立会话 key=$hostKey id=$id pid=${handle.pid} '
        'team=$teamId',
      );
      return <String, dynamic>{'host_session_id': id};
    } catch (e) {
      debugPrint('[plugin_host] start 失败 key=$hostKey: $e');
      return <String, dynamic>{'error': 'plugin_host_start 启动失败: $e'};
    }
  }

  /// ``plugin_host_stop``：停止会话（幂等；尽力而为，失败仅记日志）。
  Map<String, dynamic> stop({
    required String hostSessionId,
    required String teamId,
  }) {
    if (hostSessionId.isEmpty) {
      return <String, dynamic>{'error': 'plugin_host_stop 缺少 host_session_id'};
    }
    final PluginHostSession? session = _sessions[hostSessionId];
    if (session == null) {
      // 幂等：已回收 / 从未存在的会话视为已停止
      return <String, dynamic>{'ok': true};
    }
    if (session.teamId != teamId) {
      // 隔离 fail-closed：不允许跨 team 操作会话
      return <String, dynamic>{'error': 'host_session_id 不属于 team=$teamId'};
    }
    _killSession(session, reason: 'stop 指令');
    return <String, dynamic>{'ok': true};
  }

  /// ``plugin_host_status``：查询会话状态（面板 / 诊断用）。
  Map<String, dynamic> status({
    required String hostSessionId,
    required String teamId,
  }) {
    if (hostSessionId.isEmpty) {
      return <String, dynamic>{'error': 'plugin_host_status 缺少 host_session_id'};
    }
    final PluginHostSession? session = _sessions[hostSessionId];
    if (session == null) {
      return <String, dynamic>{'error': '宿主会话不存在（可能已回收）'};
    }
    if (session.teamId != teamId) {
      return <String, dynamic>{'error': 'host_session_id 不属于 team=$teamId'};
    }
    return <String, dynamic>{
      'state': session.state,
      if (session.exitCode != null) 'exit_code': session.exitCode,
      if (session.stderrTail.isNotEmpty) 'stderr_tail': session.stderrTail,
    };
  }

  // -- 清理契约四场景（§14.3） --------------------------------------------

  /// 级联回收：停止并移除指定 team 的全部会话（scope 销毁级联，§14.3.2）。
  void recycleTeam(String teamId) {
    final List<PluginHostSession> owned = _sessions.values
        .where((PluginHostSession s) => s.teamId == teamId)
        .toList(growable: false);
    for (final PluginHostSession session in owned) {
      _killSession(session, reason: 'team 级联回收');
      _removeSession(session.hostSessionId);
    }
    if (owned.isNotEmpty) {
      debugPrint('[plugin_host] 级联回收 team=$teamId 会话数=${owned.length}');
    }
  }

  /// 应用退出：停止并清空全部会话（§14.3 清理兜底；进程不可跨应用退出存活）。
  void recycleAll() {
    final int count = _sessions.length;
    for (final PluginHostSession session
        in _sessions.values.toList(growable: false)) {
      _killSession(session, reason: '应用退出');
    }
    _sessions.clear();
    _byKey.clear();
    if (count > 0) {
      debugPrint('[plugin_host] 应用退出回收全部会话数=$count');
    }
  }

  /// 断连 / 注册丢失：全部会话标记失联（不 kill；重连后对账回收，§14.3.3）。
  void markAllLost() {
    for (final PluginHostSession session in _sessions.values) {
      session.lost = true;
    }
  }

  /// 断连 / 注册丢失：指定 team 的会话标记失联（不 kill）。
  void markTeamLost(String teamId) {
    for (final PluginHostSession session in _sessions.values) {
      if (session.teamId == teamId) {
        session.lost = true;
      }
    }
  }

  /// 重连对账：team 不可用（未注册 / 未启用）→ 回收；可用 → 清除失联标记。
  ///
  /// 「本地进程不可达时以宿主侧对账为准」（§14.3.3）：本方法以前端会话表
  /// 为准做本地侧清账；后端可另行按需 `plugin_host_status` 探测。
  void reconcileAfterReconnect(bool Function(String teamId) teamUsable) {
    final List<PluginHostSession> toRecycle = <PluginHostSession>[];
    for (final PluginHostSession session in _sessions.values) {
      if (teamUsable(session.teamId)) {
        session.lost = false;
      } else {
        toRecycle.add(session);
      }
    }
    for (final PluginHostSession session in toRecycle) {
      _killSession(session, reason: '重连对账回收');
      _removeSession(session.hostSessionId);
    }
    if (toRecycle.isNotEmpty) {
      debugPrint('[plugin_host] 重连对账回收失联会话数=${toRecycle.length}');
    }
  }

  // -- 内部 ---------------------------------------------------------------

  /// 绑定进程句柄：聚合 stderr 尾部；退出时转 closed 并发出退出上报帧。
  void _wireExit(PluginHostSession session, PluginHostProcessHandle handle) {
    handle.stderr.listen(
      (List<int> chunk) {
        session.stderrTail = trimTail(
          session.stderrTail + decodePluginHostBytes(chunk),
          kPluginHostStderrTailCap,
        );
      },
      onError: (Object _) {},
      cancelOnError: false,
    );
    handle.exitCode.then((int code) {
      session.state = 'closed';
      session.exitCode = code;
      debugPrint(
        '[plugin_host] 会话退出 id=${session.hostSessionId} exit_code=$code '
        'team=${session.teamId}',
      );
      // 退出上报（尽力而为：断连时 _send 丢弃，状态仍留驻本表供 status）
      _notify(<String, dynamic>{
        'type': kPluginHostEventType,
        'data': <String, dynamic>{
          'host_session_id': session.hostSessionId,
          'team_id': session.teamId,
          'event': 'exit',
          'exit_code': code,
          if (session.stderrTail.isNotEmpty)
            'stderr_tail': session.stderrTail,
        },
      });
    });
  }

  /// 发出终止信号（幂等；尽力而为：成功与否都以 closed 收口，失败仅记日志）。
  void _killSession(PluginHostSession session, {required String reason}) {
    if (session.killIssued) return;
    session.killIssued = true;
    session.state = 'closed';
    bool signaled = false;
    try {
      signaled = session.handle?.kill() ?? false;
    } catch (e) {
      debugPrint(
        '[plugin_host] $reason：终止信号异常 id=${session.hostSessionId}: $e',
      );
    }
    debugPrint(
      '[plugin_host] $reason：终止会话 id=${session.hostSessionId} '
      'pid=${session.pid} signaled=$signaled',
    );
  }

  /// 移除会话条目及幂等索引。
  void _removeSession(String hostSessionId) {
    final PluginHostSession? removed = _sessions.remove(hostSessionId);
    if (removed != null && _byKey[removed.hostKey] == hostSessionId) {
      _byKey.remove(removed.hostKey);
    }
  }
}
