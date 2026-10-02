/// **POSIX** 伪终端后端：借系统自带的 `script` 命令起一个带 PTY 的会话。
///
/// ## 为什么不直接 `forkpty`
/// `forkpty` 属于 `libutil`，`dart:ffi` 要自己摆平 `termios`/`winsize` 结构体、
/// `fork` 之后**不能在有 GC 与 isolate 的运行时里随便跑**（Dart 明确不支持在
/// isolate 之外 fork），风险远大于收益。系统 `script` 本身就是"给一条命令接一个 PTY"的
/// 标准工具，行为稳定、平台自带，所以这一版走它。
///
/// ## 取舍（如实标注，别当它是完整实现）
/// - **依赖系统自带 `script`**：拿不到（精简镜像、Alpine + busybox 等）就抛
///   [PtyUnsupportedException]（可读中文），**不崩**，也**不静默降级**成无 TTY 执行；
/// - **改尺寸做不到**：我们没有那个 pty 主设备的 fd（`script` 在它自己进程里持有），
///   [PtySession.resize] 因此只记日志、不抛（见接口文档里这条口径的理由）；
/// - **命令与参数拼法分平台**：
///   - Linux（util-linux 的 script）：`script -qefc <cmd> /dev/null`
///     （`-e` 才会把**子命令的退出码**当自己的退出码回传）；
///   - macOS/BSD：`script -q /dev/null <cmd>`（BSD 的 script 本来就回传子命令退出码）；
/// - **未在本仓库 CI / 本机真机验证**（开发机是 Windows）：本文件只保证编译通过与
///   有据可依的参数形状；真机验证留给有 POSIX 环境的机器。
library;

import 'dart:async';
import 'dart:io';

import 'pty_session.dart';

/// 起一个 `script` 后端（POSIX）的伪终端会话。
Future<PtySession> startPosixPtySession({
  String command = '',
  required String workingDirectory,
  int columns = 80,
  int rows = 24,
  Map<String, String>? environment,
  void Function(String message)? log,
}) async {
  if (Platform.isWindows) {
    throw PtyUnsupportedException(
      'script 后端只能在 POSIX 上使用（当前平台：${Platform.operatingSystem}）',
    );
  }
  final String requested = command.trim();
  final String inner = requested.isNotEmpty ? requested : _defaultShell();
  final List<String> args = Platform.isLinux
      ? <String>['-qefc', inner, '/dev/null']
      : <String>['-q', '/dev/null', inner];

  try {
    await Directory(workingDirectory).create(recursive: true);
  } on Object catch (error) {
    throw PtySessionException('工作目录不可用（$workingDirectory）：$error');
  }

  final Process process;
  try {
    process = await Process.start(
      'script',
      args,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: true,
      runInShell: false,
    );
  } on ProcessException catch (error) {
    throw PtyUnsupportedException(
      '本机没有可用的 PTY 后端：POSIX 分支依赖系统自带的 script 命令，启动失败'
      '（${error.message}）。请安装 util-linux（Linux）或改用一次性命令执行。',
    );
  } on Object catch (error) {
    throw PtySessionException('启动 script 失败：$error');
  }

  final _ScriptPtySession session = _ScriptPtySession(
    process: process,
    commandLine: inner,
    log: log,
  );
  session.bind();
  return session;
}

/// 默认 shell：`$SHELL` → `/bin/sh`。
String _defaultShell() {
  final String shell = (Platform.environment['SHELL'] ?? '').trim();
  return shell.isEmpty ? '/bin/sh' : shell;
}

/// `script` 撑起来的会话。
///
/// 输出 = `script` 的 stdout + stderr（带 `-q` 时它不再打 "Script started/done" banner）；
/// 退出码 = `script` 自己的退出码（Linux 带 `-e`、BSD 原生即回传子命令退出码）。
class _ScriptPtySession implements PtySession {
  _ScriptPtySession({
    required this.process,
    required this.commandLine,
    this.log,
  });

  final Process process;
  final String commandLine;
  final void Function(String message)? log;

  final StreamController<List<int>> _outputController =
      StreamController<List<int>>();
  final Completer<int> _exitCompleter = Completer<int>();
  final List<StreamSubscription<List<int>>> _subscriptions =
      <StreamSubscription<List<int>>>[];

  bool _closed = false;

  @override
  String get shell => commandLine;

  @override
  Stream<List<int>> get output => _outputController.stream;

  @override
  Future<int> get exitCode => _exitCompleter.future;

  /// 接上输出与退出码（由 [startPosixPtySession] 在构造完成后调用）。
  void bind() {
    void forward(List<int> chunk) {
      if (!_outputController.isClosed) _outputController.add(chunk);
    }

    _subscriptions.add(process.stdout.listen(forward));
    _subscriptions.add(process.stderr.listen(forward));
    unawaited(
      process.exitCode.then((int code) {
        if (!_exitCompleter.isCompleted) _exitCompleter.complete(code);
        _closeOutput();
      }),
    );
  }

  @override
  Future<void> write(List<int> data) async {
    if (_closed) throw PtySessionException('会话已关闭，无法写入');
    if (data.isEmpty) return;
    try {
      process.stdin.add(data);
    } on Object catch (error) {
      throw PtySessionException('写入 script 进程失败：$error');
    }
  }

  @override
  Future<void> resize(int columns, int rows) async {
    // script 后端拿不到 pty 主设备的 fd：改尺寸做不到，只记日志（接口约定不抛）。
    log?.call(
      '[pty] script 后端不支持改尺寸（请求 $columns 列 x $rows 行）：已忽略',
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await process.stdin.close();
    } on Object {
      // 进程可能已经退出：关 stdin 失败无所谓
    }
    if (!_exitCompleter.isCompleted) {
      process.kill(ProcessSignal.sigterm);
      try {
        await _exitCompleter.future.timeout(const Duration(milliseconds: 500));
      } on TimeoutException {
        if (!_exitCompleter.isCompleted) {
          process.kill(ProcessSignal.sigkill);
        }
      }
    }
    for (final StreamSubscription<List<int>> subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _closeOutput();
    if (!_exitCompleter.isCompleted) _exitCompleter.complete(-1);
  }

  void _closeOutput() {
    if (_outputController.isClosed) return;
    // 不 await：没有监听者时 close() 的 future 永远不会完成。
    unawaited(_outputController.close());
  }
}
