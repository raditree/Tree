import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'path_guard.dart';
import 'proc_ledger.dart';

/// agent → 插件的**通知**发送端（`shell.data` / `shell.exit`）。
typedef ShellNotifier =
    Future<void> Function(String method, Map<String, dynamic> params);

/// 目标机侧的**交互终端（PTY）**（协议 §3.5）。
///
/// 用系统自带的 `script -qec <command> /dev/null`（util-linux）包裹命令：
/// - **拿不到 `script` ⇒ 回 `-32006 pty_unsupported`**，**绝不**静默降级成无 TTY 的
///   `exec`（不变量 8：那会让 vim/top/Ctrl+C 直接坏掉，比明确报错更难查）；
/// - 输出是**原始字节**（base64 过线，解码后**不清洗 ANSI**）；
/// - `shell.exit` **一定收口**（拿不到退出状态给 -1）；`close` 幂等且**只关这一条**。
class ShellOps {
  ShellOps({
    required this.guard,
    required this.root,
    required this.notify,
    AgentIdGen? ids,
    this.log,
  }) : _ids = ids ?? AgentIdGen();

  final PathGuard guard;
  final String root;
  final ShellNotifier notify;
  final AgentIdGen _ids;

  /// 诊断日志出口（`bin` 里接 stderr；缺省什么都不做）。
  final void Function(String message)? log;

  final Map<String, _ShellSession> _sessions = <String, _ShellSession>{};

  /// `{command?, cwd?, columns, rows, term?='xterm-256color'}`
  /// → `{shell_id, pty:true}` 或 `-32006`。
  Future<Map<String, dynamic>> open(Map<String, dynamic> params) async {
    final String command = (params['command'] ?? '').toString().trim();
    final String cwd = params['cwd'] == null
        ? root
        : guard.check(params['cwd'], label: 'cwd');
    final String termRaw = (params['term'] ?? '').toString().trim();
    final String term = termRaw.isEmpty ? 'xterm-256color' : termRaw;
    final int columns = _optionalInt(params['columns']) ?? 80;
    final int rows = _optionalInt(params['rows']) ?? 24;

    if (!await Directory(cwd).exists()) {
      throw RpcException(TunnelErrorCodes.notFound, '工作目录不存在：$cwd');
    }

    final String inner = command.isEmpty ? loginShell() : command;
    final List<String> arguments = <String>['-qec', inner, '/dev/null'];

    final Process process;
    try {
      process = await Process.start(
        'script',
        arguments,
        workingDirectory: cwd,
        environment: <String, String>{
          ...Platform.environment,
          'TERM': term,
          'COLUMNS': '$columns',
          'LINES': '$rows',
        },
        runInShell: false,
      );
    } on ProcessException catch (error) {
      // 目标机没有 script（精简镜像 / busybox）—— **如实报**，不静默降级。
      throw RpcException(
        TunnelErrorCodes.ptyUnsupported,
        '目标机没有可用的 PTY 后端（script -qec）：${error.message}',
      );
    }

    final String id = _ids.next();
    final _ShellSession session = _ShellSession(
      id: id,
      process: process,
      commandLine: inner,
      notify: notify,
      log: log,
    );
    session.bind();
    _sessions[id] = session;
    log?.call('PTY 会话 $id 已开（script -qec，term=$term，${columns}x$rows）');
    return <String, dynamic>{'shell_id': id, 'pty': true};
  }

  /// `{shell_id, data:base64}` → `{}`（把字节写进 PTY 的 stdin）。
  Future<Map<String, dynamic>> write(Map<String, dynamic> params) async {
    final _ShellSession session = _requireSession(params['shell_id'], 'shell_id');
    final Object? raw = params['data'];
    if (raw is! String) {
      throw RpcException(RpcCodes.invalidParams, 'data 必须是 base64 字符串');
    }
    final List<int> bytes;
    try {
      bytes = base64Decode(raw);
    } on FormatException catch (error) {
      throw RpcException(RpcCodes.invalidParams, 'data 不是合法 base64：${error.message}');
    }
    await session.write(bytes);
    return <String, dynamic>{};
  }

  /// `{shell_id, columns, rows}` → `{supported:false}`。
  ///
  /// `script` 不暴露 TIOCSWINSZ（pty 主设备 fd 在它自己进程里）⇒ **做不到就说出来**，
  /// 按不变量 9 / 协议 §3.5 **只回 `supported:false`、不抛**（与 POSIX PTY 后端同口径）。
  Future<Map<String, dynamic>> resize(Map<String, dynamic> params) async {
    log?.call(
      'PTY 改尺寸不可用（script 不暴露 TIOCSWINSZ）：已回 supported=false',
    );
    return <String, dynamic>{'supported': false};
  }

  /// `{shell_id}` → `{}`（**幂等**；只关这一条会话，不牵连别的）。
  Future<Map<String, dynamic>> close(Map<String, dynamic> params) async {
    final Object? raw = params['shell_id'];
    if (raw is String) {
      final _ShellSession? session = _sessions.remove(raw);
      if (session != null) await session.dispose(notifyExit: true);
    }
    return <String, dynamic>{};
  }

  /// 关停（agent 退出 / stdin EOF 时调）：收掉所有会话，退出面一律收口。
  Future<void> closeAll() async {
    final List<_ShellSession> sessions = _sessions.values.toList();
    _sessions.clear();
    for (final _ShellSession session in sessions) {
      await session.dispose(notifyExit: true);
    }
  }

  _ShellSession _requireSession(Object? raw, String label) {
    if (raw is! String || raw.isEmpty) {
      throw RpcException(RpcCodes.invalidParams, '$label 必须是非空字符串');
    }
    final _ShellSession? session = _sessions[raw];
    if (session == null) {
      throw RpcException(TunnelErrorCodes.notFound, '没有这条 shell 会话：$raw');
    }
    return session;
  }

  /// 登录 shell：`$SHELL` → `/bin/sh`（与 `pty_posix.dart` 同口径）。
  static String loginShell() {
    final String shell = (Platform.environment['SHELL'] ?? '').trim();
    return shell.isEmpty ? '/bin/sh' : shell;
  }
}

class _ShellSession {
  _ShellSession({
    required this.id,
    required this.process,
    required this.commandLine,
    required this.notify,
    this.log,
  });

  final String id;
  final Process process;
  final String commandLine;
  final ShellNotifier notify;

  /// 诊断日志出口。
  final void Function(String message)? log;

  final Completer<int> _exit = Completer<int>();
  final List<StreamSubscription<List<int>>> _subscriptions =
      <StreamSubscription<List<int>>>[];

  bool _closed = false;
  bool _exitNotified = false;

  void bind() {
    void forward(List<int> chunk) {
      if (chunk.isEmpty) return;
      // 原始字节，不清洗 ANSI（终端渲染归前端）。
      unawaited(
        notify(AgentMethods.shellData, <String, dynamic>{
          'shell_id': id,
          'data': base64Encode(chunk),
        }),
      );
    }

    _subscriptions.add(process.stdout.listen(forward));
    _subscriptions.add(process.stderr.listen(forward));
    unawaited(process.exitCode.then(_completeExit));
  }

  Future<void> write(List<int> data) async {
    if (_closed) {
      throw RpcException(TunnelErrorCodes.notFound, '会话已关闭：$id');
    }
    try {
      process.stdin.add(data);
    } on Object catch (error) {
      throw RpcException(
        RpcCodes.internalError,
        '写入 PTY stdin 失败（$id）：$error',
      );
    }
  }

  Future<void> _completeExit(int code) async {
    if (!_exit.isCompleted) _exit.complete(code);
    await _notifyExit(code);
  }

  Future<void> _notifyExit(int code) async {
    if (_exitNotified) return;
    _exitNotified = true;
    try {
      await notify(AgentMethods.shellExit, <String, dynamic>{
        'shell_id': id,
        'exit_code': code,
      });
    } on Object catch (error) {
      log?.call('发送 shell.exit 失败（$id）：$error');
    }
  }

  /// 幂等关闭：关 stdin → 还在跑就 SIGTERM →（500ms 后）SIGKILL；
  /// 无论如何都把 `exitCode` 与 `shell.exit` 收口（拿不到给 -1）。
  Future<void> dispose({required bool notifyExit}) async {
    if (_closed) return;
    _closed = true;
    try {
      await process.stdin.close();
    } on Object {
      // 进程可能已退出
    }
    if (!_exit.isCompleted) {
      process.kill(ProcessSignal.sigterm);
      try {
        await _exit.future.timeout(const Duration(milliseconds: 500));
      } on TimeoutException {
        if (!_exit.isCompleted) process.kill(ProcessSignal.sigkill);
      }
    }
    for (final StreamSubscription<List<int>> subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    if (!_exit.isCompleted) _exit.complete(-1);
    if (notifyExit) await _notifyExit(-1);
  }
}

int? _optionalInt(Object? raw) {
  if (raw == null) return null;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw);
  return null;
}
