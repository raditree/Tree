import 'package:tree_local_exec/tree_local_exec.dart';

import 'pty_process.dart';

/// 把 tree_local_exec 的**平台伪终端实现**（Windows ConPTY / POSIX script）接到核心的
/// [PtyProcess] 形状上。
///
/// 为什么要这一层：核心只依赖 [PtyProcess] 这个最小形状——好单测（注入假实现）、好换
/// 平台实现；而平台实现住在 tree_local_exec。这层转接把两者对上，别处都不用知道
/// 「伪终端到底是 ConPTY 还是 script」。
class LocalPtyStarter {
  const LocalPtyStarter({this.log});

  final void Function(String message)? log;

  /// 起一个会话（签名与 [PtyStarter] 一致，可直接当工厂用）
  Future<PtyProcess> start({
    required String command,
    required String workingDirectory,
    required int columns,
    required int rows,
  }) async {
    final PtySession session = await startPtySession(
      command: command,
      workingDirectory: workingDirectory,
      columns: columns,
      rows: rows,
      log: log,
    );
    return _LocalPtyProcess(session);
  }
}

/// 把 [PtySession] 原样转成 [PtyProcess]（两边形状一致，只是不互相依赖）
class _LocalPtyProcess implements PtyProcess {
  _LocalPtyProcess(this._session);

  final PtySession _session;

  @override
  Stream<List<int>> get output => _session.output;

  @override
  Future<void> write(List<int> data) => _session.write(data);

  @override
  Future<void> resize(int columns, int rows) => _session.resize(columns, rows);

  @override
  Future<int> get exitCode => _session.exitCode;

  @override
  Future<void> close() => _session.close();

  @override
  String get shell => _session.shell;
}
