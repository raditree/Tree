import 'dart:io';

/// **「启动一个 shell 进程」的可注入小接缝**。
///
/// 为什么要有这层：`exec.run` 的逻辑（分块收输出、软超时不杀、缺省关闭 stdin、
/// base64 往返、退出码）才是容易出错的部分，而它可以完全与"具体用哪个 shell"解耦。
/// 抽出来之后：
/// - 生产（目标机 Linux）用 [/bin/sh -c]（协议 §3.3：**登录外壳由插件完成**，
///   agent 收到的 `command` 是最终字符串）；
/// - 开发机（Windows）单测用 `cmd.exe /c`，于是同一套逻辑在 Windows 上也有真覆盖。
///
/// 子进程的 stdout/stderr 一律是**原始字节**（`Process.start` 不设编码 ⇒
/// `Stream<List<int>>`），字节不丢（协议 §3.3）。
abstract interface class ShellLauncher {
  /// 起一条 shell 命令（**不**等待它结束）。
  Future<Process> start(
    String command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  });

  /// 日志/诊断用的一句话（说明这条命令是交给谁跑的）。
  String get description;
}

/// 缺省实现：**按平台**选 `/bin/sh -c` 或（仅开发机）`cmd.exe /c`。
class DefaultShellLauncher implements ShellLauncher {
  const DefaultShellLauncher();

  @override
  String get description =>
      Platform.isWindows ? 'cmd.exe /c' : '/bin/sh -c';

  @override
  Future<Process> start(
    String command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) {
    if (Platform.isWindows) {
      return Process.start(
        'cmd.exe',
        <String>['/c', command],
        workingDirectory: workingDirectory,
        environment: environment,
        includeParentEnvironment: includeParentEnvironment,
        runInShell: false,
      );
    }
    return Process.start(
      '/bin/sh',
      <String>['-c', command],
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: false,
    );
  }
}

/// 强制 POSIX 的 `/bin/sh -c`（`exec.spawn` 与 `shell.*` 走这条路：
/// 那些是**目标机专属**能力，不该被开发机平台影响）。
class PosixShellLauncher implements ShellLauncher {
  const PosixShellLauncher();

  @override
  String get description => '/bin/sh -c';

  @override
  Future<Process> start(
    String command, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) => Process.start(
    '/bin/sh',
    <String>['-c', command],
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: includeParentEnvironment,
    runInShell: false,
  );
}
