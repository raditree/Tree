import 'dart:async';

/// 「后台执行」原语：`terminal` 的 `hook=true` 在本机与远端的**同一套语义**。
///
/// 为什么单开一个接口（而不是往 [WorkspaceIO] 上挂方法）：`WorkspaceIO` 是
/// `abstract interface class`，加方法会**同时**破掉 `LocalWorkspaceIO` /
/// `SshWorkspaceIO` / `PrivateWorkspaceIO` 与一堆测试 fake 的编译；而
/// `PrivateWorkspaceIO` 是装饰器（`inner` 的具体类型被它挡住），"按具体类型判远端"
/// 也走不通。并列接口 + 三方都实现，是唯一能同时满足"不改既有签名"与"装饰器可透传"
/// 的形态。
///
/// **两端语义一致、能力差异如实**：
/// - 本机：[startBackground] 起本机进程，输出由 shell 重定向直写日志文件，退出码来自
///   进程句柄；[BackgroundExecHandle.cancel] 杀整棵进程树。
/// - 远端（SSH）：[startBackground] 用 `nohup` 在**远端**起，输出重定向到远端日志，
///   结束标记（退出码）由远端写进哨兵文件、本机按间隔轮询；远端进程不归本机管——
///   [BackgroundExecHandle.cancel] 只能尽力（拿不到 pid 就如实返回 false）。
///
/// **路径一律是工作空间相对路径**（与 [WorkspaceIO] 同一条边界）。
abstract interface class BackgroundExecHost {
  /// 起一条后台命令：输出**追加**写进工作空间内的 [logRelativePath]（实现负责建父目录
  /// 与写日志头），**立即返回**句柄、不等待命令结束。
  ///
  /// 句柄的 [BackgroundExecHandle.exitCode] 在命令真正结束时完成；远端若链路判失活，
  /// 该 future 以错误（`SshLinkStaleException`）结束——**不假装知道远端状态**。
  Future<BackgroundExecHandle> startBackground({
    required String command,
    required String logRelativePath,
  });

  /// **重新接管**一条仍在运行的后台命令（核心/应用重启后的接续）：**不重跑、不新起**，
  /// 只按 [logRelativePath]（+ 可选 [pid]）重新挂上"等它结束"的那条路。
  ///
  /// 远端用同一套哨兵轮询；**本机不支持**（本机进程随应用退出而终止，没有可接续的东西）
  /// —— 本机实现抛 [UnsupportedError]，调用方（[TerminalHooks] 的恢复路径）只在远端
  /// 台账上调用它。
  Future<BackgroundExecHandle> attachBackground({
    required String command,
    required String logRelativePath,
    int? pid,
  });

  /// 把文本**追加**到工作空间内文件的末尾（自动建父目录）。**失败不抛**
  /// （日志写不进去不该害死任务本身，调用方只记日志）。
  Future<void> appendLog(String relativePath, String text);

  /// 读文件**尾部** [maxChars] 个字符；文件不存在 / 读不到返回 null（不抛）。
  Future<String?> readTail(String relativePath, int maxChars);
}

/// 一条**已在后台运行**的命令（本机进程 / 远端命令，语义统一）。
abstract interface class BackgroundExecHandle {
  /// 结束时的退出码。
  ///
  /// - 本机：进程退出码（实时、准确）；
  /// - 远端：哨兵文件轮询（最坏延迟 = 一个轮询间隔）；进程消失但没写哨兵时给
  ///   [BackgroundExecHandle.goneExitCode]（**如实**区分"没拿到退出码"，不假装是正常退出）；
  /// - 链路判失活：future 以 `SshLinkStaleException` 结束。
  Future<int> get exitCode;

  /// "远端进程已消失但没留下退出码"时用的可辨退出码（负值：真实退出码不会是它）。
  static const int goneExitCode = -2;

  /// 展示用 pid（本机进程 pid / 远端包装子 shell 的 pid）；拿不到时 null。
  int? get pid;

  /// 这条命令跑在**远端**（SSH）还是本机。
  ///
  /// 用途有二：① 落盘台账只记远端任务（本机进程随应用退出终止，没有可接续的东西）；
  /// ② 关闭语义不同（本机杀进程树；远端尽力 kill、且关停**不杀**）。
  bool get remote;

  /// **尽力终止**：返回**是否确实发出了终止**。
  ///
  /// - 本机：杀整棵进程树，返回 true；
  /// - 远端：拿得到 pid 就发 `kill -TERM`，拿不到（或远端不认）⇒ false ——
  ///   **不假装杀成功**，调用方要把这个 false 如实写给模型/用户。
  Future<bool> cancel();

  /// 关停（幂等）。**两端语义不同，各自如实**：
  /// - 本机：杀进程树（本机后台进程不该随应用退出变成孤儿）；
  /// - 远端：**不杀**——关掉桌面应用不该杀掉远端正在跑的训练/构建；只停掉本机的轮询，
  ///   远端任务由下次启动的接续逻辑（[BackgroundExecHost.attachBackground]）接管。
  Future<void> close();
}
