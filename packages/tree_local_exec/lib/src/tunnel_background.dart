/// 「后台执行」的**隧道托管**能力（可选能力接口）。
///
/// 与 [BackgroundExecHost] 的关系：那是**面对调用方**的语义（`terminal` 的 `hook=true`
/// 用它起/接续/读写日志），这是**面对传输层**的能力（谁真的把子进程托管起来）。
/// 两者不是一回事，所以分开：
///
/// - **本机**：`LocalWorkspaceIO` 直接用 `dart:io` 的进程句柄（没有中间人）；
/// - **中转站（隧道）**：目标机上的 `tree_agent` 托管子进程 —— `setsid` 脱离会话、
///   输出直写文件、退出码落盘、台账落盘 ⇒ **SSH 通道断了、核心崩了、应用退了都不影响它**，
///   重连后 `exec.list` 重新对账。这正是"跨日级稳定性"的来源（用户 2026-10-10 点名的核心目标）；
/// - **内置 dartssh2（回退路径）**：没有这个能力（本类 `is` 判断为假），
///   `SshWorkspaceIO` 自动退回既有的 `nohup` + 哨兵轮询方案 —— **行为与今天完全一致**。
///
/// 为什么做成**并列的可选接口**而不是给 `SshTransport` 加方法：加方法会同时破掉
/// `DartSshTransport` 与一大票测试 fake 的编译；而 `SshWorkspaceIO` 手上只有
/// `SshTransport` 抽象，"这条链路能不能托管后台进程"只有实现者自己知道
/// （与 `ReconnectableWorkspace` / `FallbackableWorkspace` 同一手法）。
abstract interface class TunnelBackgroundExec {
  /// 起一条后台命令（**立即返回**，不等它结束）。
  ///
  /// [logAbsolutePath] 是**目标机绝对路径**，必须在 `--root` 之内（由
  /// `SshWorkspaceIO.resolve` 保证；agent 侧还有第二道越界检查）。
  Future<TunnelBackgroundStart> spawnBackground({
    required String command,
    required String logAbsolutePath,
  });

  /// 列出目标机上**所有**被托管的后台进程（含历史，靠落盘台账对账）。
  Future<List<TunnelBackgroundProc>> listBackground();

  /// 查一条（拿不到返回 null）。
  Future<TunnelBackgroundProc?> queryBackground(String id);

  /// **尽力**终止（返回是否确实发出了信号；拿不到 pid ⇒ false，**不假装**）。
  Future<bool> killBackground(String id);
}

/// 一次 `spawnBackground` 的结果。
class TunnelBackgroundStart {
  const TunnelBackgroundStart({
    required this.id,
    required this.logPath,
    this.pid,
    this.pgid,
  });

  /// agent 侧的托管 id（**重连后仍有效**：台账在目标机磁盘上）。
  final String id;

  /// 目标机上的日志绝对路径（agent 原样回报，便于核对）。
  final String logPath;

  final int? pid;
  final int? pgid;
}

/// 一条被托管的后台进程的状态快照。
class TunnelBackgroundProc {
  const TunnelBackgroundProc({
    required this.id,
    required this.logPath,
    required this.state,
    this.pid,
    this.pgid,
    this.command = '',
    this.startedAtMs = 0,
    this.exitCode,
  });

  final String id;
  final String logPath;

  /// `running` / `exited` / `gone`（见 `BackgroundStates`）。
  final String state;

  final int? pid;
  final int? pgid;
  final String command;
  final int startedAtMs;

  /// 仅 `state == 'exited'` 时有值。
  final int? exitCode;
}
