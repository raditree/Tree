import 'package:tree_local_exec/tree_local_exec.dart';

import '../store/records.dart';
import 'pty_process.dart';

/// 远端（SSH）shell 通道的**来源**：按 agent 给一条**已经连上**的远端 shell 通道。
///
/// 生产实现由 CLI 提供：它从缓存的那条 SSH 工作空间 IO（`SshWorkspaceIO`）上取通道，
/// 因此终端**复用同一条已建好的连接**（与文件面板 / 工具层同一条），不会为终端再连一次。
/// 测试注入假的即可（本机没有可连的 sshd）。
typedef SshShellOpener = Future<SshShellChannel> Function(
  CoreAgent agent, {
  required int columns,
  required int rows,
});

/// 把 tree_local_exec 的**远端 shell 通道**（dartssh2 的会话通道 + PTY）接到核心的
/// [PtyProcess] 形状上——与 [LocalPtyStarter] 对称的一层。
///
/// 为什么要这一层（与本地那份同一理由）：核心只依赖 [PtyProcess] 这个最小形状——好
/// 单测（注入假实现）、好换远端实现；而 dartssh2 的通道住在 tree_local_exec。这层把
/// 两者对上，别处都不用知道"远端终端到底是 dartssh2 还是别的"。
///
/// **远端工作目录不在核心解析**：核心只有"本机路径"的概念（[PtyStarter] 要一个
/// `workingDirectory`），而远端根归 `SshWorkspaceIO`（它知道 `resolveRemoteRoot` 的
/// 结果）。通道由 [openChannel] 的实现在自己的 IO 上解决工作目录，这里既不接收也不
/// 传本机路径给远端——把本机路径发给远端只会得到一个不存在的目录。
class SshPtyAdapter {
  const SshPtyAdapter({required this.openChannel});

  /// 取一条远端 shell 通道（生产 = CLI 从缓存的 `SshWorkspaceIO` 透传；测试注入假的）。
  final SshShellOpener openChannel;

  /// 起一个远端会话（签名与 [SshPtyStarter] 一致，可直接当工厂用）。
  ///
  /// 注：[SshPtyStarter] 的签名里**没有** `command`（见 terminal_service.dart），因此远端
  /// 分支一律开**登录 shell**（在远端工作空间根下，见上）；`columns` / `rows` 由终端帧
  /// 给出（核心已把越界值夹回范围内）。
  Future<PtyProcess> start({
    required CoreAgent agent,
    required int columns,
    required int rows,
  }) async {
    final SshShellChannel channel = await openChannel(
      agent,
      columns: columns,
      rows: rows,
    );
    return _SshPtyProcess(channel);
  }
}

/// 把 [SshShellChannel] 原样转成 [PtyProcess]（两边形状一致，只是不互相依赖）。
class _SshPtyProcess implements PtyProcess {
  _SshPtyProcess(this._channel);

  final SshShellChannel _channel;

  @override
  Stream<List<int>> get output => _channel.output;

  @override
  Future<void> write(List<int> data) => _channel.write(data);

  @override
  Future<void> resize(int columns, int rows) => _channel.resize(columns, rows);

  @override
  Future<int> get exitCode => _channel.exitCode;

  @override
  Future<void> close() => _channel.close();

  @override
  String get shell => _channel.shell;
}
