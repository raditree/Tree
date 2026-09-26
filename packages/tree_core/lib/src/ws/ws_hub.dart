import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tree_protocol/tree_protocol.dart';

import '../util/ids.dart';

/// 一条已建立的回环 WS 连接。
///
/// 对外只暴露 [send]（单个业务帧）与统计字段；**分帧细节全部封装在内部**，
/// 调用方（会话服务、执行器通道）永远按完整业务帧思考。
class WsConnection {
  WsConnection({
    required this.socket,
    String? id,
    this.chunkThresholdBytes = kWsFrameChunkThresholdBytes,
    this.chunkPartBytes = kWsFrameChunkPartBytes,
  }) : id = id ?? CoreIds.connection();

  /// 连接 id（仅日志/排障用，不参与协议）。
  final String id;

  /// 底层 WebSocket。
  final WebSocket socket;

  /// 触发分帧的编码后字节阈值。
  final int chunkThresholdBytes;

  /// 单个分片的目标字节预算。
  final int chunkPartBytes;

  bool _open = true;

  /// 已发送的业务帧数（不含分片帧）。
  int framesSent = 0;

  /// 已发送的业务帧编码后总字节数。
  int bytesSent = 0;

  /// 触发分帧的帧数。
  int framesChunked = 0;

  bool get isOpen => _open;

  /// 标记连接已断开（由 socket 的 done/error 回调调用）。
  void markClosed() {
    _open = false;
  }

  /// 发送一个业务帧；超过阈值时自动分帧。
  ///
  /// 分帧后接收侧（前端 `WebSocketService._maybeReassemble`）重组为原始
  /// JSON 文本再走业务分发，因此**业务语义与单帧发送完全等价**。
  void send(Map<String, dynamic> frame) {
    if (!_open) return;
    final String raw = jsonEncode(frame);
    final List<int> bytes = utf8.encode(raw);
    framesSent++;
    bytesSent += bytes.length;
    if (bytes.length <= chunkThresholdBytes) {
      _write(raw);
      return;
    }
    framesChunked++;
    _sendChunked(raw);
  }

  void _write(String raw) {
    if (!_open) return;
    try {
      socket.add(raw);
    } catch (_) {
      // 对端已断开：静默标记，交由清理路径注销
      _open = false;
    }
  }

  /// 把 [raw] 按 [chunkPartBytes] 切分并以 frame_begin/chunk/end 三件套发出。
  void _sendChunked(String raw) {
    final String transferId = CoreIds.next('frg');
    final List<String> parts = splitByUtf8Budget(raw, chunkPartBytes);
    _write(
      jsonEncode(<String, dynamic>{
        'type': WsOutboundType.frameBegin,
        'id': transferId,
        'total': parts.length,
      }),
    );
    for (int i = 0; i < parts.length; i++) {
      _write(
        jsonEncode(<String, dynamic>{
          'type': WsOutboundType.frameChunk,
          'id': transferId,
          'seq': i,
          'part': parts[i],
        }),
      );
    }
    _write(
      jsonEncode(<String, dynamic>{
        'type': WsOutboundType.frameEnd,
        'id': transferId,
      }),
    );
  }

  /// 按 UTF-8 字节预算切分 [text]，**始终在码点边界切开**。
  ///
  /// 代理对（补充平面字符）按 2 个 UTF-16 码元、4 字节计；单码点超过预算时
  /// 仍消费该码点，保证每次调用都推进（否则分包循环会死循环）。
  static List<String> splitByUtf8Budget(String text, int maxBytes) {
    if (text.isEmpty) return <String>[''];
    final List<String> parts = <String>[];
    int start = 0;
    while (start < text.length) {
      int index = start;
      int bytes = 0;
      while (index < text.length) {
        final int unit = text.codeUnitAt(index);
        final bool highSurrogate =
            unit >= 0xD800 && unit <= 0xDBFF && index + 1 < text.length;
        final int codeUnits = highSurrogate ? 2 : 1;
        final int charBytes;
        if (unit < 0x80) {
          charBytes = 1;
        } else if (unit < 0x800) {
          charBytes = 2;
        } else if (highSurrogate) {
          charBytes = 4;
        } else {
          charBytes = 3;
        }
        if (index > start && bytes + charBytes > maxBytes) break;
        bytes += charBytes;
        index += codeUnits;
      }
      parts.add(text.substring(start, index));
      start = index;
    }
    return parts;
  }

  /// 主动关闭连接。
  Future<void> close([int code = 1000, String reason = '']) async {
    _open = false;
    try {
      await socket.close(code, reason);
    } catch (_) {
      // 已关闭/对端先关闭：忽略
    }
  }
}

/// 回环 WS 连接注册表（现状 server `ws_manager` 的桌面替身）。
///
/// 桌面分支是单用户单进程，但前端可能开多个窗口（teammates 独立窗口），
/// 因此仍需要"广播 + 多连接"语义；不区分 user（无账号体系）。
class WsHub {
  final Map<String, WsConnection> _connections = <String, WsConnection>{};

  /// 心跳定时器（对齐现状 server 的保活下发）。
  Timer? _heartbeatTimer;

  /// 当前在线连接数。
  int get connectionCount => _connections.length;

  /// 当前在线连接（只读快照）。
  List<WsConnection> connections() =>
      List<WsConnection>.unmodifiable(_connections.values);

  /// 自进程启动以来累计建立的连接数（自检/日志）。
  int totalConnectionsAccepted = 0;

  void register(WsConnection connection) {
    _connections[connection.id] = connection;
    totalConnectionsAccepted++;
  }

  void unregister(String connectionId) {
    _connections.remove(connectionId)?.markClosed();
  }

  /// 向全部在线连接广播一个业务帧。
  void broadcast(Map<String, dynamic> frame) {
    for (final WsConnection connection in connections()) {
      connection.send(frame);
    }
  }

  /// 启动保活心跳：周期下发 `{"type": "heartbeat"}`（前端会过滤该帧）。
  void startHeartbeat({Duration interval = const Duration(seconds: 30)}) {
    stopHeartbeat();
    _heartbeatTimer = Timer.periodic(interval, (_) {
      broadcast(<String, dynamic>{'type': WsOutboundType.heartbeat});
    });
  }

  void stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// 关闭全部连接（进程退出/服务器关闭时）。
  Future<void> closeAll() async {
    stopHeartbeat();
    final List<WsConnection> snapshot = connections();
    _connections.clear();
    for (final WsConnection connection in snapshot) {
      await connection.close(1001, 'core shutting down');
    }
  }
}
