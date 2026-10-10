import 'dart:async';
import 'dart:io';

import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'agent_config.dart';
import 'exec_ops.dart';
import 'fs_ops.dart';
import 'path_guard.dart';
import 'proc_ledger.dart';
import 'shell_launcher.dart';
import 'shell_ops.dart';

/// 写一帧字节出去（`bin` 里是 `stdout.add` + `flush`；单测里是内存收集器）。
typedef FrameEmitter = Future<void> Function(List<int> bytes);

/// **L2 服务端**：读 stdin 的字节流 → [LineFrameDecoder] 切帧 → 分发 → 写 stdout 帧，
/// 另加 agent → 插件的**通知**通道（PTY 数据面 / 退出面）。
///
/// 纪律（协议 §1 / §3）：
/// - **stdout 只写协议帧**：一行一帧（[encodeFrame]），别的什么都不写（日志走 stderr）；
/// - 帧的写出**串行化**（单队列）：并发请求的响应绝不会互相截断；
/// - 坏帧（非法 UTF-8 / 非法 JSON / 超限）由 [LineFrameDecoder] 报错并**继续读**——
///   一条坏帧不能让整条通道哑掉；
/// - stdin **EOF = agent 退出**（协议 §8：agent 进程本身不随 SSH 通道存活）；
/// - `--idle-timeout-ms` 缺省 **0 = 永不**（仓库口径："没有静态总时长上限"）。
class AgentServer {
  AgentServer({
    required this.config,
    ShellLauncher? launcher,
    PidAliveProbe? aliveProbe,
    void Function(String message)? log,
  }) {
    _log = log ?? _ignore;
    final PathGuard guard = PathGuard(config.root);
    _fs = FsOps(guard);
    _ledger = ProcLedger(stateDir: config.stateDir, aliveProbe: aliveProbe);
    _exec = ExecOps(
      guard: guard,
      root: config.root,
      stateDir: config.stateDir,
      launcher: launcher ?? const DefaultShellLauncher(),
      ledger: _ledger,
      log: log,
    );
    _shells = ShellOps(
      guard: guard,
      root: config.root,
      notify: _notify,
      log: log,
    );
  }

  final AgentConfig config;

  late final void Function(String message) _log;
  late final FsOps _fs;
  late final ExecOps _exec;
  late final ShellOps _shells;
  late final ProcLedger _ledger;

  final DateTime _startedAt = DateTime.now();

  /// 写出队列：所有帧串行过它（一条帧一次 `emit`，绝不会交错）。
  Future<void> _writeQueue = Future<void>.value();

  FrameEmitter? _emit;
  Timer? _idleTimer;
  Completer<int>? _done;

  /// 跑服务循环；返回进程退出码（`0`）。
  ///
  /// [input] 是 stdin 的**字节流**；[emit] 把一帧字节写到 stdout。
  Future<int> serve({
    required Stream<List<int>> input,
    required FrameEmitter emit,
  }) async {
    _emit = emit;
    await _ledger.load();
    _log(
      'tree_agent $kAgentVersion（协议 $kAgentProtocolVersion）启动：'
      'root=${config.root} state=${config.stateDir} '
      'idle=${config.idleTimeout?.inMilliseconds ?? 0}ms pid=$pid',
    );

    final Completer<int> done = Completer<int>();
    _done = done;

    final LineFrameDecoder decoder = LineFrameDecoder(
      onFrame: _onFrame,
      onError: (String reason) => _log('[协议] $reason（已丢弃该帧，通道继续）'),
    );

    _armIdleTimer();
    final StreamSubscription<List<int>> subscription = input.listen(
      decoder.add,
      onError: (Object error) {
        _log('stdin 出错：$error');
        _shutdown(0);
      },
      onDone: () {
        _log('stdin EOF：agent 退出（通道断 = agent 退）');
        _shutdown(0);
      },
      cancelOnError: true,
    );

    final int code = await done.future;
    _idleTimer?.cancel();
    _idleTimer = null;
    await subscription.cancel();
    await _shells.closeAll();
    await _writeQueue;
    return code;
  }

  void _shutdown(int code) {
    final Completer<int>? done = _done;
    if (done != null && !done.isCompleted) done.complete(code);
  }

  void _armIdleTimer() {
    final Duration? idle = config.idleTimeout;
    if (idle == null) return;
    _idleTimer?.cancel();
    _idleTimer = Timer(idle, () {
      _log('idle-timeout=${idle.inMilliseconds}ms 到点（期间没有任何帧进来）：agent 退出');
      _shutdown(0);
    });
  }

  // ── 帧输入 ───────────────────────────────────────────────────────────

  void _onFrame(Map<String, dynamic> frame) {
    _armIdleTimer();
    if (RpcIds.isRequest(frame)) {
      unawaited(_handleRequest(frame));
      return;
    }
    if (RpcIds.isNotification(frame)) {
      _log('收到通知（本端不回响应，忽略）：${frame['method']}');
      return;
    }
    _log('收到无法识别的帧（忽略）：$frame');
  }

  Future<void> _handleRequest(Map<String, dynamic> frame) async {
    final Object id = frame['id']!;
    final String method = frame['method'] as String;
    try {
      final Map<String, dynamic> params = _asParams(frame['params']);
      final Object? result = await _dispatch(method, params);
      await _writeFrame(rpcResult(id, result));
    } on RpcException catch (error) {
      await _writeFrame(
        rpcErrorResult(id, error.code, error.message, error.data),
      );
    } on Object catch (error, stack) {
      _log('处理 $method 时内部出错：$error\n$stack');
      await _writeFrame(
        rpcErrorResult(id, RpcCodes.internalError, '内部错误：$error'),
      );
    }
  }

  Future<Object?> _dispatch(String method, Map<String, dynamic> params) async {
    switch (method) {
      case AgentMethods.hello:
        return _hello(params);
      case AgentMethods.ping:
        return <String, dynamic>{
          'ok': true,
          'at_ms': DateTime.now().millisecondsSinceEpoch,
        };
      case AgentMethods.info:
        return _info();

      case AgentMethods.fsRead:
        return _fs.read(params);
      case AgentMethods.fsWrite:
        return _fs.write(params);
      case AgentMethods.fsStat:
        return _fs.stat(params);
      case AgentMethods.fsExists:
        return _fs.exists(params);
      case AgentMethods.fsList:
        return _fs.list(params);
      case AgentMethods.fsListEntries:
        return _fs.listEntries(params);
      case AgentMethods.fsMkdir:
        return _fs.mkdir(params);
      case AgentMethods.fsRename:
        return _fs.rename(params);
      case AgentMethods.fsRemove:
        return _fs.remove(params);
      case AgentMethods.fsDelete:
        return _fs.delete(params);
      case AgentMethods.fsIsDir:
        return _fs.isDir(params);

      case AgentMethods.execRun:
        return _exec.run(params);
      case AgentMethods.execSpawn:
        return _exec.spawn(params);
      case AgentMethods.execList:
        return _exec.list(params);
      case AgentMethods.execQuery:
        return _exec.query(params);
      case AgentMethods.execKill:
        return _exec.kill(params);

      case AgentMethods.shellOpen:
        return _shells.open(params);
      case AgentMethods.shellWrite:
        return _shells.write(params);
      case AgentMethods.shellResize:
        return _shells.resize(params);
      case AgentMethods.shellClose:
        return _shells.close(params);

      default:
        throw RpcException(RpcCodes.methodNotFound, '方法不存在：$method');
    }
  }

  // ── agent.hello / info ───────────────────────────────────────────────

  Map<String, dynamic> _hello(Map<String, dynamic> params) {
    final String token = (params['token'] ?? '').toString();
    if (token != config.token) {
      // 一次性握手凭据校验：这条 stdio 只能是同一个启动方的（防别的本机用户蹭）。
      throw RpcException(
        TunnelErrorCodes.handshakeFailed,
        'token 校验失败：这条通道不是同一个启动方',
      );
    }
    final int protocol = (params['protocol'] as num?)?.toInt() ?? -1;
    if (protocol != kAgentProtocolVersion) {
      throw RpcException(
        TunnelErrorCodes.protocolMismatch,
        'agent 协议 $kAgentProtocolVersion 不匹配：目标是 $protocol'
        ' —— 请升级随包 agent',
      );
    }
    return <String, dynamic>{
      'protocol': kAgentProtocolVersion,
      'ok': true,
      'agent_version': kAgentVersion,
      'os': Platform.operatingSystem,
      'arch': AgentConfig.detectArch(),
      'home': config.home,
      'root': config.root,
      'pid': pid,
    };
  }

  Map<String, dynamic> _info() => <String, dynamic>{
    'home': config.home,
    'root': config.root,
    'os': Platform.operatingSystem,
    'arch': AgentConfig.detectArch(),
    'agent_version': kAgentVersion,
    'pid': pid,
    'uptime_ms': DateTime.now().difference(_startedAt).inMilliseconds,
  };

  // ── 帧输出 ───────────────────────────────────────────────────────────

  Future<void> _notify(String method, Map<String, dynamic> params) =>
      _writeFrame(rpcNotification(method, params));

  /// 往写队列尾部挂一帧。**永远不抛**（写失败只记日志）：一条帧写不出去不该
  /// 把整条通道搞哑。
  Future<void> _writeFrame(Map<String, dynamic> message) {
    _writeQueue = _writeQueue.then((void _) async {
      final FrameEmitter? emit = _emit;
      if (emit == null) return;
      try {
        await emit(encodeFrame(message));
      } on FrameTooLargeException catch (error) {
        _log('帧过大，已丢弃：$error');
      } on Object catch (error) {
        _log('写 stdout 失败：$error');
      }
    });
    return _writeQueue;
  }

  static Map<String, dynamic> _asParams(Object? raw) {
    if (raw == null) return <String, dynamic>{};
    if (raw is Map) {
      return raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
    }
    throw RpcException(RpcCodes.invalidParams, 'params 必须是一个对象');
  }

  static void _ignore(String message) {}
}
