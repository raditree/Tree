import 'dart:async';
import 'dart:convert';

import 'package:tree_protocol/tree_protocol.dart';

import '../files/file_service.dart';
import 'pty_process.dart';
import '../store/tree_store.dart';
import '../team/team_workspace.dart';
import '../ws/ws_hub.dart';

/// 起一个**远端（SSH）伪终端**会话的工厂（CLI 从缓存的 SSH 工作空间 IO 注入；测试注入
/// 假实现）。
///
/// 签名**只依赖核心自己的类型**（[CoreAgent] / [PtyProcess]）：
/// - 远端工作目录与连接复用全在注入方（`SshWorkspaceIO` 那条已经建好的连接）里解决，
///   核心不碰 dartssh2、不碰远端路径，也不拿"本机路径"去猜；
/// - 没有 `command`：远端分支一律登录 shell。要支持"命令终端"得先扩这个签名，
///   **不要**为了它偷偷退回本机执行。
typedef SshPtyStarter = Future<PtyProcess> Function({
  required CoreAgent agent,
  required int columns,
  required int rows,
});

/// 集成终端（Ctrl+J）的会话管理。
///
/// 一个 terminal_id 对应一个**伪终端进程**（真 PTY：vim/top 这类全屏程序能跑，
/// Ctrl+C 能打断）。输出按 base64 **原始字节**回给**开它的那条连接**——终端是本机
/// 交互，不广播给别的窗口，也不进消息库。
///
/// 两个后端，都是**真 PTY**：
/// - 本机 agent：平台伪终端（Windows ConPTY / POSIX pty，见 lib/src/terminal/README.md）；
/// - 远端（SSH）agent：SSH 会话通道 + `pty-req`（dartssh2 的 shell / exec 通道，形状见
///   tree_local_exec 的 `SshShellChannel`），由注入的 [SshPtyStarter] 提供。
///
/// 判据是**有效 SSH**（[teamSshConfigFor]：成员跟随团队 TOP 的 SSH 配置），不是
/// `agent.sshConfig`——只看后者会把"SSH leader 的成员"误判成本机，在本机给它起一个
/// 终端（真实 bug，见 [docs/known-issues.md #12](../../../../../docs/known-issues.md)）。
/// 远端工作空间根由远端后端解决（归 `SshWorkspaceIO`）：核心**不**解析远端路径，也不把
/// 本机路径发给远端；远端分支的 `terminal_ready.cwd` 因此是空串（界面显示"工作区"）。
class TerminalService {
  TerminalService({
    required this.store,
    required this.files,
    this.startPty,
    this.startSshPty,
    this.log,
  });

  final TreeStore store;
  final FileService files;

  /// 起伪终端的工厂：由 CLI 注入平台实现（ConPTY / POSIX），测试注入假实现。
  ///
  /// 为 null = 没接线：`terminal_open` 会回一帧可读错误，而不是假装起了个终端。
  final PtyStarter? startPty;

  /// 起**远端（SSH）伪终端**的工厂：由 CLI 注入（它从缓存的 `SshWorkspaceIO` 上取一条
  /// 远端 shell 通道，复用同一条 SSH 连接），测试注入假实现。
  ///
  /// 为 null = 没接线：远端 agent 的 `terminal_open` 会回一帧可读错误，而不是假装起了
  /// 个终端，也不会悄悄在本机起一个（那正是判据用 [teamSshConfigFor] 要防的事）。
  final SshPtyStarter? startSshPty;

  final void Function(String message)? log;

  final Map<String, _TerminalSession> _sessions = <String, _TerminalSession>{};

  /// 当前活着的会话数（日志与测试用）
  int get activeCount => _sessions.length;

  /// 某个 terminal_id 是否还在（测试用）
  bool isActive(String terminalId) => _sessions.containsKey(terminalId);

  /// 开一个终端（terminal_open）。
  Future<void> open(WsConnection connection, Map<String, dynamic> frame) async {
    final Map<String, dynamic> data = _payload(frame);
    final String terminalId = _str(data, TerminalFrame.terminalId);
    if (terminalId.isEmpty) {
      _fail(connection, '', '终端会话缺少 terminal_id');
      return;
    }
    // 同一个 id 重复开（前端重连）：先收掉旧的，绝不静默叠出第二个进程
    if (_sessions.containsKey(terminalId)) await close(terminalId);

    final String agentId = _str(data, TerminalFrame.agentId);
    final CoreAgent? agent = store.agent(agentId);
    if (agent == null) {
      _fail(connection, terminalId, '找不到 agent：$agentId');
      return;
    }
    // 判据是**有效 SSH**（成员跟随团队 TOP 的配置，见 [teamSshConfigFor]），不是 agent
    // 自己的 `sshConfig`：SSH leader 的成员自己那份是空的，只看它会把成员当本机、在
    // **本机**起一个终端（真实 bug，见 docs/known-issues.md #12）。
    final bool remote = teamSshConfigFor(agent, store.agent) != null;
    // 本机路径**只在本地分支**求值：远端的工作空间根在远端，核心不解析也不回传
    // （远端根归 `SshWorkspaceIO`，见 ssh_pty_adapter.dart）。
    final String cwd = remote ? '' : files.rootFor(agent);

    final String command = _str(data, TerminalFrame.command);
    final int columns = _clampInt(data, TerminalFrame.columns, 80, 20, 500);
    final int rows = _clampInt(data, TerminalFrame.rows, 24, 5, 200);

    final PtyProcess pty;
    try {
      if (remote) {
        final SshPtyStarter? sshStarter = startSshPty;
        if (sshStarter == null) {
          _fail(
            connection,
            terminalId,
            '核心没有接线远端（SSH）伪终端实现，远端 agent 的终端不可用；'
            '本机 agent 的终端不受影响。',
          );
          return;
        }
        // 远端工作目录由注入方（SshWorkspaceIO）自己解决：这里只给 agent 与尺寸。
        pty = await sshStarter(agent: agent, columns: columns, rows: rows);
      } else {
        final PtyStarter? starter = startPty;
        if (starter == null) {
          _fail(connection, terminalId, '核心没有接线伪终端实现，终端不可用（需要带 PTY 支持的核心构建）');
          return;
        }
        pty = await starter(
          command: command,
          workingDirectory: cwd,
          columns: columns,
          rows: rows,
        );
      }
    } catch (error) {
      _fail(connection, terminalId, '启动终端失败：$error');
      return;
    }

    final _TerminalSession session = _TerminalSession(
      connectionId: connection.id,
      connection: connection,
      pty: pty,
    );
    _sessions[terminalId] = session;
    connection.send(<String, dynamic>{
      'type': WsOutboundType.terminalReady,
      TerminalFrame.terminalId: terminalId,
      TerminalFrame.cwd: cwd,
      TerminalFrame.shell: pty.shell,
      TerminalFrame.columns: columns,
      TerminalFrame.rows: rows,
    });
    session.subscription = pty.output.listen(
      (List<int> chunk) {
        if (chunk.isEmpty) return;
        session.connection.send(<String, dynamic>{
          'type': WsOutboundType.terminalOutput,
          TerminalFrame.terminalId: terminalId,
          TerminalFrame.bytes: base64Encode(chunk),
        });
      },
      onError: (Object error) {
        _fail(session.connection, terminalId, '终端输出中断：$error');
      },
    );
    // 进程退出 → 回退出码并清理。不 await：open 要尽快返回，界面才能开始打字。
    unawaited(
      pty.exitCode.then((int code) {
        return _finish(terminalId, exitCode: code);
      }).catchError((Object error) {
        log?.call('终端 $terminalId 的退出码读取失败：$error');
      }),
    );
  }

  /// 键盘输入（terminal_input）：原样写进伪终端
  Future<void> input(Map<String, dynamic> frame) async {
    final Map<String, dynamic> data = _payload(frame);
    final _TerminalSession? session = _sessions[_str(data, TerminalFrame.terminalId)];
    if (session == null) return;
    final String encoded = _str(data, TerminalFrame.bytes);
    if (encoded.isEmpty) return;
    try {
      await session.pty.write(base64Decode(encoded));
    } catch (error) {
      log?.call('终端输入写入失败：$error');
    }
  }

  /// 改窗口尺寸（terminal_resize）
  Future<void> resize(Map<String, dynamic> frame) async {
    final Map<String, dynamic> data = _payload(frame);
    final _TerminalSession? session = _sessions[_str(data, TerminalFrame.terminalId)];
    if (session == null) return;
    final int columns = _clampInt(data, TerminalFrame.columns, 80, 20, 500);
    final int rows = _clampInt(data, TerminalFrame.rows, 24, 5, 200);
    try {
      await session.pty.resize(columns, rows);
    } catch (error) {
      log?.call('终端尺寸调整失败：$error');
    }
  }

  /// 结束一个会话（terminal_close，或进程已退出后的收尾）
  Future<void> close(String terminalId) => _finish(terminalId, exitCode: null);

  /// terminal_close 帧入口（从帧里取 terminal_id）
  Future<void> closeFromFrame(Map<String, dynamic> frame) =>
      close(_str(_payload(frame), TerminalFrame.terminalId));

  /// 连接断开：把它开的终端全部收掉（否则会留下孤儿 shell 占着工作区）
  Future<void> closeForConnection(String connectionId) async {
    final List<String> owned = _sessions.entries
        .where((MapEntry<String, _TerminalSession> e) => e.value.connectionId == connectionId)
        .map((MapEntry<String, _TerminalSession> e) => e.key)
        .toList();
    for (final String terminalId in owned) {
      await _finish(terminalId, exitCode: null);
    }
  }

  /// 核心退出：收掉所有终端
  Future<void> closeAll() async {
    for (final String terminalId in _sessions.keys.toList()) {
      await _finish(terminalId, exitCode: null);
    }
  }

  /// 收尾一个会话：[exitCode] 非空时再回一帧 terminal_exit
  Future<void> _finish(String terminalId, {required int? exitCode}) async {
    final _TerminalSession? session = _sessions.remove(terminalId);
    if (session == null) return;
    await session.subscription?.cancel();
    session.subscription = null;
    try {
      await session.pty.close();
    } catch (error) {
      log?.call('终端 $terminalId 关闭失败：$error');
    }
    if (exitCode == null) return;
    session.connection.send(<String, dynamic>{
      'type': WsOutboundType.terminalExit,
      TerminalFrame.terminalId: terminalId,
      TerminalFrame.exitCode: exitCode,
    });
  }


  /// 帧字段：优先顶层，其次 data 子对象（与插件交互帧同一套兼容口径）
  static Map<String, dynamic> _payload(Map<String, dynamic> frame) {
    final Object? data = frame['data'];
    if (data is Map) {
      final Map<String, dynamic> nested = data.cast<String, dynamic>();
      return <String, dynamic>{...frame, ...nested};
    }
    return frame;
  }

  static String _str(Map<String, dynamic> data, String key) =>
      (data[key] ?? '').toString().trim();

  static int _clampInt(
    Map<String, dynamic> data,
    String key,
    int fallback,
    int min,
    int max,
  ) {
    final Object? raw = data[key];
    final int? value = raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '');
    if (value == null) return fallback;
    return value < min ? min : (value > max ? max : value);
  }

  void _fail(WsConnection connection, String terminalId, String message) {
    log?.call('终端失败（$terminalId）：$message');
    connection.send(<String, dynamic>{
      'type': WsOutboundType.terminalError,
      TerminalFrame.terminalId: terminalId,
      TerminalFrame.message: message,
    });
  }
}

/// 一个活着的终端会话
class _TerminalSession {
  _TerminalSession({
    required this.connectionId,
    required this.connection,
    required this.pty,
  });

  final String connectionId;
  final WsConnection connection;
  final PtyProcess pty;
  StreamSubscription<List<int>>? subscription;
}
