import 'dart:io';

/// 命令执行相关的跨平台细节（同步执行与后台 hook 模式**共用同一套语义**）。
///
/// Windows 上的两个坑（都由本文件集中承担）：
/// 1. 命令走 `cmd.exe /c` 并前置 `chcp 65001`（cmd 内建命令的输出代码页问题，
///    实测 chcp 管不住管道输出，见 [LocalWorkspaceIO.decodeBytes] 的说明）；
/// 2. 终止命令要杀**整棵进程树**：只杀 `cmd.exe` 会留下真正的干活进程。
abstract final class Shell {
  /// 当前平台的 shell 可执行文件。
  static String get executable => Platform.isWindows ? 'cmd.exe' : '/bin/sh';

  /// 把命令包成 shell 参数。
  static List<String> argsFor(String command) => Platform.isWindows
      ? <String>['/c', 'chcp 65001 >nul && $command']
      : <String>['-c', command];

  /// 后台模式的重定向后缀（把 stdout/stderr 都写进日志文件）。
  ///
  /// 用 shell 自带的重定向而不是 Dart 侧转发：这样日志是**子进程直接写文件**，
  /// 核心进程重启/退出都不会丢输出，也少一层管道。
  static String redirectTo(String logPath) {
    final String quoted = Platform.isWindows ? '"$logPath"' : "'$logPath'";
    return ' >> $quoted 2>&1';
  }

  /// 终止进程及其整棵子树（Windows: taskkill /T；POSIX: 先 TERM 后 KILL）。
  static Future<void> killProcessTree(int pid) async {
    if (!Platform.isWindows) {
      Process.killPid(pid, ProcessSignal.sigterm);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      Process.killPid(pid, ProcessSignal.sigkill);
      return;
    }
    try {
      await Process.run('taskkill', <String>['/PID', '$pid', '/T', '/F']);
    } catch (_) {
      // 尽力而为：进程可能已经退出
    }
  }
}
