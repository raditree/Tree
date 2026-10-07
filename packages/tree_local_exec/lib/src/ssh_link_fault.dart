import 'dart:async';

import 'ssh_reconnect.dart';

/// 把「一次远端操作以**链路级**错误失败」中继成「起一次后台重建」。
///
/// ## 为什么需要它（2026-10-07 现场事故）
///
/// 自愈原本只由**心跳判失活**触发（`SshLiveness.onStale` → [SshReconnectPump]）。
/// 但现场出现过另一种形态：
///
/// - 心跳走的是 SSH **global request**（不占 channel），一直有回包 ⇒ 判活通过、
///   `isStale == false`；
/// - 服务端却开始**拒绝新的 session 通道**（`SSHChannelOpenError(2: open failed)`，
///   reason code 2 = 服务端回的 `SSH_MSG_CHANNEL_OPEN_FAILURE`）；
/// - 于是：文件浏览（SFTP subsystem 通道，**建连时就已开、之后一直复用**）仍然可用；
///   git 历史 / terminal 工具（每次都**新开** exec 通道）全部失败；
/// - 而判死判据只看心跳 ⇒ **自动重连永远不触发**，故障一直持续到重启应用为止
///   （现场 10-07 07:29 → 12:47，5 小时不自愈）。
///
/// 本类补的就是这一段：**只要有一次操作以链路级错误失败，就把这条连接视作
/// 「需要重建」**。
///
/// ## 口径（与 `ssh_liveness` / `ssh_reconnect` 同一套，不许破）
///
/// - **判死判据不变**：`isStale` 仍然只看「连续 N 拍心跳丢失」。本类只扩大
///   「**主动重建**」的触发面，**不是**新的判活依据、也**不引入任何静态时长上限**；
/// - **单飞**：故障期间重复上报只记数，重建复用 [SshReconnectPump.start] 的同一次在途
///   ——「每次调用都失败」不会被放大成连接风暴；
/// - **退避是节奏**：重建按 [SshReconnectPump.backoff] 重试，走完一直用最后一拍；
/// - **不假装恢复**：重建失败保持「故障中」，下一次操作仍会如实失败（并再触发一次）；
///   只有重建真的成功（由 [_clearOnSuccess] 那条路）才清标记。
///
/// ## 与 [SshReconnectPump] 一样是纯策略
///
/// 注入 `pump`（生产 = `DartSshTransport._reconnectPump`）、可注入假 `attempt` /
/// 假 `sleep`，因此「幂等 / 单飞 / 成功后清标记 / stop 后不再试」都能单测。
class SshLinkFaultRelay {
  SshLinkFaultRelay({required this.pump, this.log});

  /// 真正的重建节拍器（单飞 + 退避 + 可停止）。**与心跳失活共用同一个实例**：
  /// 两条触发路（心跳判死 / 链路级故障）必须落在同一次在途重建上，否则会并发建连。
  final SshReconnectPump pump;

  /// 可观测出口（生产接到核心日志）。
  final void Function(String message)? log;

  bool _faulted = false;
  int _reports = 0;

  /// 当前是否处于「链路级故障」状态（重建成功后清零）。
  bool get faulted => _faulted;

  /// 累计上报次数（成功/失败都算）。用于观测「反复失败」——它若不涨说明链路已恢复。
  int get reports => _reports;

  /// 上报一次链路级故障：置标记 + 起一次后台重建。
  ///
  /// 幂等：故障期间重复上报**只记数**（重建仍只有一次在途）；因此一个每 3s 轮询一次
  /// 的远端后台任务不会把连接打爆。
  ///
  /// **不阻塞调用方**：本次调用照旧**如实失败**（由调用方抛出去），重建只保证
  /// 「之后能再用」——这与 `SshReconnectPump` 对心跳失活的口径一致。
  void report(Object error) {
    _reports++;
    final bool first = !_faulted;
    _faulted = true;
    if (first) {
      log?.call('SSH 链路级故障（$error）：触发一次后台重建…');
    }
    unawaited(pump.start());
  }

  /// 重建成功后清标记（新连接可以再用）。
  ///
  /// 由 `DartSshTransport._reconnectOnce` 在**换会话成功之后**调用——顺序不能反：
  /// 先清标记再换会话就成「假活」（标记说好了、实际还在旧连接上）。
  void clear() => _faulted = false;
}
