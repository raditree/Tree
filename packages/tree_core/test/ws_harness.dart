import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tree_core/tree_core.dart';

/// 测试用的极简 WS 客户端 + 帧记录器。
///
/// 单次订阅、持续累积：服务端广播是"订阅即收"，若在断言之间反复订阅/取消会
/// 丢事件，因此这里一次订阅、按需轮询。
class TestWs {
  TestWs._(this._socket, this._controller) {
    _subscription = _socket.listen(
      (dynamic data) {
        final Object? decoded = jsonDecode(data.toString());
        if (decoded is Map<String, dynamic>) _controller.add(decoded);
      },
      onDone: () => _controller.close(),
      onError: (Object _) => _controller.close(),
    );
  }

  static Future<TestWs> connect(CoreServer server) async {
    final WebSocket socket = await WebSocket.connect(
      '${server.handshake.wsBaseUrl}${CoreServer.wsPath}'
      '?token=${server.token}',
    );
    return TestWs._(socket, StreamController<Map<String, dynamic>>.broadcast());
  }

  final WebSocket _socket;
  final StreamController<Map<String, dynamic>> _controller;
  late final StreamSubscription<dynamic> _subscription;
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];

  /// 发送一个上行帧。
  void send(Map<String, dynamic> frame) => _socket.add(jsonEncode(frame));

  /// 开始记录（必须在发送前调用）。
  void record() => _controller.stream.listen(frames.add);

  /// 全部帧类型（断言用）。
  List<String> types() => frames
      .map((Map<String, dynamic> f) => f['type'] as String? ?? '')
      .toList();

  /// 轮询直到某个帧满足条件。
  Future<void> until(
    bool Function(Map<String, dynamic> frame) predicate, {
    Duration timeout = const Duration(seconds: 10),
    String? reason,
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (frames.any(predicate)) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw TimeoutException('超时等待${reason ?? '帧'}；已收到：${types()}');
  }

  /// 轮询直到某类型帧累计到 [count] 个。
  Future<void> untilCount(
    String type,
    int count, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (frames.where((Map<String, dynamic> f) => f['type'] == type).length >=
          count) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw TimeoutException('超时等待 $count 个 $type；已收到：${types()}');
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _socket.close();
    if (!_controller.isClosed) await _controller.close();
  }
}

/// 等待服务端 agent 回到 idle（一轮生成结束）。
Future<void> waitIdle(TestWs ws) => ws.until(
  (Map<String, dynamic> f) =>
      f['type'] == 'agent_status' &&
      (f['data'] as Map<String, dynamic>?)?['status'] == 'idle',
  reason: 'agent_status(idle)',
);
