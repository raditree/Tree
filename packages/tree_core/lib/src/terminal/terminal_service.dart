import 'dart:async';
import 'dart:convert';

import 'package:tree_protocol/tree_protocol.dart';

import '../files/file_service.dart';
import 'pty_process.dart';
import '../store/tree_store.dart';
import '../ws/ws_hub.dart';

/// 集成终端（Ctrl+J）的会话管理。
///
/// 一个 terminal_id 对应一个**伪终端进程**（真 PTY：vim/top 这类全屏程序能跑，
/// Ctrl+C 能打断）。输出按 base64 **原始字节**回给**开它的那条连接**——终端是本机
/// 交互，不广播给别的窗口，也不进消息库。
///
/// 边界（见 lib/README.md 不变量 14）：只支持本机 agent。远端（SSH）agent 那边只有
/// 一次性 exec、没有伪终端与流式会话，因此明确回一帧可读错误，不假装成功。
class TerminalService {
  TerminalService({
    required this.store,
    required this.files,
    this.startPty,
    this.log,
  });

  final TreeStore store;
  final FileService files;

  /// 起伪终端的工厂：由 CLI 注入平台实现（ConPTY / POSIX），测试注入假实现。
  ///
  /// 为 null = 没接线：`terminal_open` 会回一帧可读错误，而不是假装起了个终端。
  final PtyStarter? startPty;

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
    final String cwd = files.rootFor(agent);
    // 判据是「这个 agent 配了 SSH」而不是「远端后端接线了没有」：SSH agent 的交互
    // 终端一律不支持（那条通道只有一次性 exec，没有伪终端与流式会话），不给用户
    // 留下「终端能开、但打不了字」的错觉。
    if (agent.sshConfig != null) {
      _fail(
        connection,
        terminalId,
        '远端（SSH）agent 的交互终端暂不支持：SSH 通道没有伪终端与流式会话。'
        '本地模式可以用终端；远端请用 agent 的 terminal 工具，或改用本地模式。',
      );
      return;
    }

    final String command = _str(data, TerminalFrame.command);
    final int columns = _clampInt(data, TerminalFrame.columns, 80, 20, 500);
    final int rows = _clampInt(data, TerminalFrame.rows, 24, 5, 200);

    final PtyStarter? starter = startPty;
    if (starter == null) {
      _fail(connection, terminalId, '核心没有接线伪终端实现，终端不可用（需要带 PTY 支持的核心构建）');
      return;
    }
    final PtyProcess pty;
    try {
      pty = await starter(
        command: command,
        workingDirectory: cwd,
        columns: columns,
        rows: rows,
      );
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
