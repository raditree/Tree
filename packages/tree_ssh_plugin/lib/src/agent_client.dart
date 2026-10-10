import 'dart:async';
import 'dart:convert';

import 'package:tree_tunnel_protocol/tree_tunnel_protocol.dart';

import 'ssh_dialer.dart';

/// agent 通道断了 / 关了：**在途请求一律以它显式失败**（绝不静默、绝不重放）。
class AgentChannelClosed implements Exception {
  AgentChannelClosed(this.message);

  final String message;

  @override
  String toString() => message;
}

/// L2 客户端：在一条常驻 [SshChannel] 上说行分隔 JSON-RPC 2.0。
///
/// 职责只有三件（其余全在协议包里）：
/// 1. 请求/响应配对（`RpcIds` 自增 id，一条请求一条响应，**不做静态超时**——
///    agent 那边的 `exec.run` 可能跑很久，仓库统一口径是"没有静态总时长上限"）；
/// 2. agent → 插件通知（`shell.data` / `shell.exit`）往外转；
/// 3. 通道死亡时把在途请求全部收口（可读失败），并通知外层（外层据此走重连）。
class AgentClient {
  AgentClient(
    this.channel, {
    this.onNotification,
    this.onClosed,
    this.log,
  }) {
    _decoder = LineFrameDecoder(
      onFrame: _onFrame,
      onError: (String reason) => log?.call('agent 通道坏帧（已丢弃）：$reason'),
    );
    _stdoutSub = channel.stdout.listen(
      _decoder.add,
      onError: (Object error) => _markClosed('agent stdout 出错：$error'),
      onDone: () => _markClosed('agent stdout 已关闭'),
    );
    _stderrSub = channel.stderr.listen(
      (List<int> chunk) => _onStderr(chunk),
      onError: (Object _) {},
    );
    unawaited(
      channel.exitCode.then((int code) {
        _markClosed('agent 进程已退出（exit=$code）');
      }),
    );
  }

  final SshChannel channel;

  /// agent → 插件通知的落点（外层转成 `tunnel/event`）。可随时改（重连后重挂）。
  void Function(String method, Map<String, dynamic> params)? onNotification;

  /// 通道死亡的通知（外层据此走重连）。可随时改（重连后重挂）。
  void Function(String reason)? onClosed;

  final void Function(String message)? log;

  final RpcIds _ids = RpcIds();
  final Map<int, Completer<Map<String, dynamic>>> _pending =
      <int, Completer<Map<String, dynamic>>>{};

  late final LineFrameDecoder _decoder;
  late final StreamSubscription<List<int>> _stdoutSub;
  late final StreamSubscription<List<int>> _stderrSub;

  bool _closed = false;
  String? _closedReason;
  final StringBuffer _stderrTail = StringBuffer();

  bool get isClosed => _closed;

  /// 关闭原因（null = 通道还在）。
  String? get closedReason => _closedReason;

  /// agent 的 stderr 尾部（诊断用；**不参与协议**）。
  String get stderrTail {
    final String text = _stderrTail.toString();
    return text.length <= 2000 ? text : text.substring(text.length - 2000);
  }

  /// 发一次 L2 请求并等响应（无静态超时；通道死 = 显式失败）。
  ///
  /// 失败有两种，调用方要分清：
  /// - [RpcException] = **agent 回了错误**（业务/协议级，链路是好的 ⇒ 如实暴露，不回退）；
  /// - [AgentChannelClosed] = **链路级**（通道死了 ⇒ 外层走重连，本次请求如实失败，不重放）。
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? params,
  ]) {
    if (_closed) {
      return Future<Map<String, dynamic>>.error(
        AgentChannelClosed('agent 通道不可用：${_closedReason ?? '已关闭'}'),
      );
    }
    final int id = _ids.next();
    final Completer<Map<String, dynamic>> completer =
        Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    try {
      channel.write(encodeFrame(rpcRequest(id, method, params)));
    } catch (error) {
      _pending.remove(id);
      return Future<Map<String, dynamic>>.error(
        AgentChannelClosed('写 agent 通道失败：$error'),
      );
    }
    return completer.future;
  }

  /// 发一条 L2 通知（不等响应）。
  void notify(String method, [Map<String, dynamic>? params]) {
    if (_closed) return;
    try {
      channel.write(encodeFrame(rpcNotification(method, params)));
    } catch (error) {
      log?.call('写 agent 通知失败：$error');
    }
  }

  /// 主动收掉（幂等）：关通道 → 在途请求以 [AgentChannelClosed] 收口。
  Future<void> close() async {
    if (!_closed) {
      _markClosed('通道被插件主动关闭');
    }
    await channel.close();
  }

  void _onFrame(Map<String, dynamic> frame) {
    // ① 响应：有 id、没有 method（与 plugin_host 同一套判别）。
    if (RpcIds.isResponse(frame)) {
      final Object? rawId = frame['id'];
      final Completer<Map<String, dynamic>>? completer = rawId is int
          ? _pending.remove(rawId)
          : null;
      if (completer == null || completer.isCompleted) {
        log?.call('忽略未知/重复的 agent 回包（id=$rawId）');
        return;
      }
      try {
        completer.complete(_resultOf(frame));
      } catch (error) {
        completer.completeError(error);
      }
      return;
    }

    // ② 通知：agent 主动推（PTY 数据面 / 退出面）。
    if (RpcIds.isNotification(frame)) {
      final String method = frame['method'] as String;
      final Object? rawParams = frame['params'];
      final Map<String, dynamic> params = rawParams is Map
          ? rawParams.map((dynamic k, dynamic v) => MapEntry('$k', v))
          : <String, dynamic>{};
      _onNotificationForward(method, params);
      return;
    }

    // ③ 请求：协议里 agent 不向插件发请求 ⇒ 明确回 `-32601`（不静默，别让它挂住）。
    if (RpcIds.isRequest(frame)) {
      final Object? id = frame['id'];
      final String method = frame['method'] as String;
      log?.call('agent 发来了未知请求：$method（回 -32601）');
      try {
        channel.write(
          encodeFrame(
            rpcErrorResult(
              id ?? 0,
              RpcCodes.methodNotFound,
              '插件不透传 agent → 插件的请求：$method',
            ),
          ),
        );
      } catch (_) {
        // 通道已坏：写不进去不算新错误（死亡路径会统一收口）。
      }
    }
  }

  void _onNotificationForward(String method, Map<String, dynamic> params) {
    final void Function(String method, Map<String, dynamic> params)? handler =
        onNotification;
    if (handler == null) {
      log?.call('agent 通知无人接收（已丢弃）：$method');
      return;
    }
    handler(method, params);
  }

  Map<String, dynamic> _resultOf(Map<String, dynamic> frame) {
    final Object? result = rpcUnwrap(frame); // 带 error 时抛 RpcException
    if (result == null) return <String, dynamic>{};
    if (result is Map) {
      return result.map((dynamic k, dynamic v) => MapEntry('$k', v));
    }
    throw RpcException(
      RpcCodes.invalidRequest,
      'agent 回包的 result 不是 JSON 对象（${result.runtimeType}）',
    );
  }

  void _onStderr(List<int> chunk) {
    if (chunk.isEmpty) return;
    final String text = utf8.decode(chunk, allowMalformed: true);
    _stderrTail.write(text);
    for (final String line in const LineSplitter().convert(text)) {
      if (line.trim().isEmpty) continue;
      log?.call('agent stderr: ${line.trim()}');
    }
  }

  void _markClosed(String reason) {
    if (_closed) return;
    _closed = true;
    _closedReason = reason;
    unawaited(_stdoutSub.cancel());
    unawaited(_stderrSub.cancel());
    final List<Completer<Map<String, dynamic>>> waiting = _pending.values
        .toList(growable: false);
    _pending.clear();
    for (final Completer<Map<String, dynamic>> completer in waiting) {
      if (!completer.isCompleted) {
        completer.completeError(AgentChannelClosed(reason));
      }
    }
    _onClosedForward(reason);
  }

  void _onClosedForward(String reason) => onClosed?.call(reason);
}
