import 'dart:async';
import 'dart:convert';
import 'dart:math' show min;

import 'package:web_socket_channel/web_socket_channel.dart';

/// WebSocket 服务 - 与后端实时消息通信
///
/// 负责建立 WebSocket 连接、发送消息、接收消息与心跳保活。
/// 后端地址固定为 `ws://localhost:8000/ws?token=xxx`，
/// 通过 [connect] 传入 JWT token 完成鉴权连接。
///
/// 连接异常断开时会按指数退避策略自动重连（手动 [disconnect] 不重连）。
class WebSocketService {
  /// WebSocket 通道
  WebSocketChannel? _channel;

  /// 心跳定时器（每 30 秒发送一次）
  Timer? _heartbeatTimer;

  /// 流式订阅
  StreamSubscription<dynamic>? _subscription;

  /// 收到消息时的回调（已解析为 Map）
  void Function(Map<String, dynamic> message)? onMessage;

  /// 连接状态变化回调
  void Function(bool connected)? onConnectionChange;

  /// 当前是否已连接
  bool _isConnected = false;
  bool get isConnected => _isConnected;

  /// 重连定时器
  Timer? _reconnectTimer;

  /// 当前重连次数
  int _reconnectAttempts = 0;

  /// 最大重连次数（默认 10）
  final int _maxReconnectAttempts = 10;

  /// 是否应该重连（手动断开时不重连）
  bool _shouldReconnect = false;

  /// 保存当前 token 用于重连
  String? _token;

  /// 连接 WebSocket
  ///
  /// 使用 [token] 进行鉴权，连接成功后启动心跳定时器。
  /// 若已有连接会先断开再重连。
  void connect(String token) {
    _token = token;
    disconnect();
    _shouldReconnect = true;
    final Uri uri = Uri.parse('ws://localhost:8000/ws?token=$token');
    _channel = WebSocketChannel.connect(uri);
    _isConnected = true;
    onConnectionChange?.call(true);

    _subscription = _channel!.stream.listen(
      (dynamic data) {
        _handleData(data);
      },
      onError: (Object error) {
        _scheduleReconnect();
      },
      onDone: () {
        _scheduleReconnect();
      },
    );

    _startHeartbeat();
  }

  /// 处理收到的数据
  ///
  /// 将原始字符串解析为 JSON Map 并触发 [onMessage] 回调。
  /// 心跳响应包会被过滤不向上传递。
  void _handleData(dynamic data) {
    try {
      final Map<String, dynamic> json =
          jsonDecode(data.toString()) as Map<String, dynamic>;
      // 过滤心跳响应
      final String? type = json['type'] as String?;
      if (type == 'heartbeat' || type == 'pong') {
        return;
      }
      onMessage?.call(json);
    } catch (e) {
      // 忽略解析失败的包
    }
  }

  /// 调度自动重连
  ///
  /// 先标记为已断开，再按指数退避策略（最长 30 秒）启动重连定时器。
  /// 手动断开（[_shouldReconnect] 为 false）或超过最大重连次数时不再重连。
  void _scheduleReconnect() {
    _markDisconnected();
    if (_shouldReconnect && _reconnectAttempts < _maxReconnectAttempts) {
      // 指数退避：0、2、4、6... 秒，最大 30 秒
      final int delay = min(_reconnectAttempts * 2, 30);
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(Duration(seconds: delay), _reconnect);
      _reconnectAttempts++;
    }
  }

  /// 执行重连
  ///
  /// 使用上次保存的 token 重新建立连接，连接成功后重置重连次数。
  void _reconnect() {
    if (_token == null) {
      return;
    }
    connect(_token!);
    _reconnectAttempts = 0;
  }

  /// 标记为已断开
  void _markDisconnected() {
    _isConnected = false;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    onConnectionChange?.call(false);
  }

  /// 启动心跳定时器
  ///
  /// 每 30 秒发送一次 `{"type": "heartbeat"}` 消息，保持连接活跃。
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => send(<String, dynamic>{'type': 'heartbeat'}),
    );
  }

  /// 发送消息（Map 会被序列化为 JSON 字符串）
  void send(Map<String, dynamic> message) {
    if (_channel != null) {
      _channel!.sink.add(jsonEncode(message));
    }
  }

  /// 发送聊天消息（语义化封装）
  ///
  /// 与 [send] 等价，仅为调用方提供更语义化的方法名。
  void sendMessage(Map<String, dynamic> message) {
    send(message);
  }

  /// 断开连接
  ///
  /// 取消心跳与重连定时器、取消订阅并关闭通道。
  /// 手动断开会标记为不再重连。
  void disconnect() {
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _isConnected = false;
  }
}
