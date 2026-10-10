import 'dart:async';

import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'agent_binary.dart';
import 'bootstrap.dart';
import 'ssh_dialer.dart';
import 'tunnel.dart';
import 'tunnel_manager.dart';

/// 本插件在 `hello` 里自报的身份（核心只读 `plugin_id` / `name` / `capabilities`）。
///
/// `plugin_id` 直接用协议包里的 `kSshExecutorPluginId`：核心的面板开关、内置目录播种、
/// `sshExecutorLookup()` 的文案都用这**同一个字符串**（核心当前按**能力**认身份，
/// 但另起一个 id 只会在将来埋雷）。
const String kPluginId = kSshExecutorPluginId;
const String kPluginName = 'SSH 执行器中转站';
const String kPluginVersion = '0.1.0';

/// 既有插件协议的**标准方法名**（`hello` / `ping` / `shutdown` / `tools/list`）。
///
/// 说明：`tree_tunnel_protocol` 只收敛**中转站协议**的方法名与错误码（协议 §2 的 5 个
/// `tunnel.*`），标准插件方法不在其中（核心侧同样是字面量，见 `plugin_host.dart` 的
/// `_request('hello')` / `_request('tools/list')`）。所以它们在本文件里定义一次，
/// 全插件只引用常量，不散落字面量。
abstract final class PluginMethods {
  static const String hello = 'hello';
  static const String ping = 'ping';
  static const String toolsList = 'tools/list';
  static const String shutdown = 'shutdown';
}

/// 插件主循环（L1：核心 ⇄ 插件）。
///
/// 铁律（`plugin-development.md` §1）逐条落到代码里：
/// 1. **stdout 只放协议报文**（本类只通过 [send] 出帧，日志走 [log] → stderr）；
/// 2. **必须并发**：每个请求在独立的 Future 里处理，读循环**从不 await 业务**
///    （否则一次 `tunnel.ensure` 就把 `ping` 堵死 ⇒ 被判 degraded）；
/// 3. **心跳必答**：`ping` 是纯内存操作，永远立即回。
///
/// 未知方法**回 `-32601`，不静默**；`shutdown`（请求或通知）都收手退出。
class PluginLoop {
  PluginLoop({
    required SshDialer dialer,
    AgentBinaryLoader? loadBinary,
    TunnelManager? manager,
    required this.send,
    this.log,
    TimerFactory? timerFactory,
    DateTime Function()? now,
    int chunkBytes = kPushChunkBytes,
  }) {
    _manager = manager ??
        TunnelManager(
          dialer: dialer,
          loadBinary: loadBinary ?? AgentBinaryResolver().call,
          timerFactory: timerFactory,
          now: now,
          onEvent: _sendEvent,
          log: log,
          chunkBytes: chunkBytes,
        );
  }

  final void Function(Map<String, dynamic> message) send;
  final void Function(String message)? log;

  late final TunnelManager _manager;

  final Set<Future<void>> _inFlight = <Future<void>>{};
  Completer<int>? _done;
  StreamSubscription<List<int>>? _input;
  bool _shuttingDown = false;

  /// 隧道台账（测试用）。
  TunnelManager get manager => _manager;

  /// 当前在途的请求处理数（诊断用）。
  int get inFlightCount => _inFlight.length;

  /// 跑读循环；返回进程退出码。**只有** stdin 关闭或收到 `shutdown` 才会返回。
  Future<int> run(Stream<List<int>> input) {
    final Completer<int> done = Completer<int>();
    _done = done;
    final LineFrameDecoder decoder = LineFrameDecoder(
      onFrame: _onFrame,
      onError: (String reason) => log?.call('核心报文的坏帧（已丢弃）：$reason'),
    );
    _input = input.listen(
      decoder.add,
      onError: (Object error) => _finish(1, '读 stdin 出错：$error'),
      onDone: () => _finish(0, '核心关闭了 stdin'),
      cancelOnError: false,
    );
    return done.future;
  }

  /// 主动收手（供 `shutdown` / 测试调用）。
  Future<void> shutdown() async {
    if (_shuttingDown) return;
    _shuttingDown = true;
    log?.call('收到 shutdown：收掉全部隧道后退出');
    await _manager.closeAll();
    _finish(0, 'shutdown');
  }

  // ───────────────────────── 分发 ─────────────────────────

  void _onFrame(Map<String, dynamic> frame) {
    if (RpcIds.isRequest(frame)) {
      final Object? id = frame['id'];
      final String method = frame['method'] as String;
      final Map<String, dynamic> params = _paramsOf(frame);
      // **并发**：不 await，读循环立刻回到监听（铁律 2）。
      late final Future<void> task;
      task = _handleRequest(id, method, params).whenComplete(() {
        _inFlight.remove(task);
      });
      _inFlight.add(task);
      return;
    }
    if (RpcIds.isNotification(frame)) {
      final String method = frame['method'] as String;
      if (method == PluginMethods.shutdown) {
        unawaited(shutdown());
      } else {
        log?.call('核心通知（本插件不消费）：$method');
      }
      return;
    }
    // 响应：本插件从不向核心发请求 ⇒ 只可能是陈旧回包，忽略并留痕。
    log?.call('忽略来自核心的响应帧（本插件不主动请求核心）');
  }

  Future<void> _handleRequest(
    Object? id,
    String method,
    Map<String, dynamic> params,
  ) async {
    try {
      switch (method) {
        case PluginMethods.hello:
          _reply(id, <String, dynamic>{
            'plugin_id': kPluginId,
            'name': kPluginName,
            'version': kPluginVersion,
            'protocol': kTunnelProtocolVersion,
            // ★ 核心"有没有中转站"的**唯一判据**（协议 §6）。
            'capabilities': <String>[kCapabilitySshExecutor],
          });
          return;
        case PluginMethods.ping:
          _reply(id, <String, dynamic>{'ok': true});
          return;
        case PluginMethods.toolsList:
          // 执行器是**通道**不是点位：不申报任何工具（协议 §2 的说明）。
          _reply(id, <String, dynamic>{'tools': const <Object>[]});
          return;
        case PluginMethods.shutdown:
          _reply(id, <String, dynamic>{'ok': true});
          await shutdown();
          return;
        case TunnelMethods.ensure:
          _reply(id, await _manager.ensure(params));
          return;
        case TunnelMethods.request:
          _reply(id, await _handleTunnelRequest(params));
          return;
        case TunnelMethods.state:
          _reply(id, _manager.state(_optionalString(params['conn_id'])));
          return;
        case TunnelMethods.reconnect:
          final String? connId = _requiredString(params['conn_id']);
          if (connId == null) {
            _replyError(id, RpcCodes.invalidParams, 'tunnel.reconnect 需要 conn_id');
            return;
          }
          _reply(id, await _manager.reconnect(connId));
          return;
        case TunnelMethods.close:
          final String? connId = _requiredString(params['conn_id']);
          if (connId == null) {
            _replyError(id, RpcCodes.invalidParams, 'tunnel.close 需要 conn_id');
            return;
          }
          _reply(id, await _manager.closeTunnel(connId));
          return;
        default:
          // 未知方法**绝不静默**（协议级错误，不是业务级 ok:false）。
          _replyError(
            id,
            RpcCodes.methodNotFound,
            'method not found: $method',
          );
          return;
      }
    } on RpcFailure catch (failure) {
      // 业务侧参数不全 ⇒ 协议级 `-32602`（不是内部错）。
      _replyError(id, failure.code, failure.message);
    } catch (error) {
      _replyError(id, RpcCodes.internalError, '$method 处理异常：$error');
    }
  }

  Future<Map<String, dynamic>> _handleTunnelRequest(
    Map<String, dynamic> params,
  ) async {
    final String? connId = _requiredString(params['conn_id']);
    final String? method = _requiredString(params['method']);
    if (connId == null || method == null) {
      throw RpcFailure(
        RpcCodes.invalidParams,
        'tunnel.request 需要 conn_id 与 method',
      );
    }
    final Object? raw = params['params'];
    final Map<String, dynamic> inner = raw is Map
        ? raw.map((dynamic k, dynamic v) => MapEntry('$k', v))
        : <String, dynamic>{};
    return _manager.request(connId, method, inner);
  }

  void _reply(Object? id, Map<String, dynamic> result) {
    send(rpcResult(id ?? 0, result));
  }

  void _replyError(Object? id, int code, String message) {
    send(rpcErrorResult(id ?? 0, code, message));
  }

  void _sendEvent(Map<String, dynamic> event) {
    // 及时性补充（权威面是 tunnel.state）：丢了不致命，所以这里只发不成对。
    send(rpcNotification(TunnelMethods.event, event));
  }

  void _finish(int code, String reason) {
    final Completer<int>? done = _done;
    if (done == null || done.isCompleted) return;
    log?.call('插件主循环结束（exit=$code）：$reason');
    unawaited(_input?.cancel());
    done.complete(code);
  }

  static Map<String, dynamic> _paramsOf(Map<String, dynamic> frame) {
    final Object? raw = frame['params'];
    if (raw is! Map) return <String, dynamic>{};
    return raw.map((dynamic k, dynamic v) => MapEntry('$k', v));
  }

  static String? _requiredString(Object? raw) {
    if (raw is String && raw.trim().isNotEmpty) return raw.trim();
    return null;
  }

  static String? _optionalString(Object? raw) {
    if (raw is String && raw.trim().isNotEmpty) return raw.trim();
    return null;
  }
}

/// 内部用的"参数非法/业务异常"载体（只在本文件里转成 JSON-RPC error 响应）。
class RpcFailure implements Exception {
  RpcFailure(this.code, this.message);

  final int code;
  final String message;

  @override
  String toString() => message;
}

/// 把一行帧编码成 UTF-8 字节（bin 层用于写 stdout；**永不写日志进 stdout**）。
List<int> frameBytes(Map<String, dynamic> message) => encodeFrame(message);
