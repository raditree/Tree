import 'dart:async';
import 'dart:convert';
import 'dart:math' show min;

import 'package:web_socket_channel/web_socket_channel.dart';

/// 工具执行请求处理者签名。
///
/// 返回 `true` 表示已接管该 ``tool_exec_request``（WebSocket 服务不再派发
/// 给后续处理者）；返回 `false` 表示未接管（交由其他处理者按需处理）。
typedef ToolExecRequestHandler = bool Function(Map<String, dynamic> message);

/// WebSocket 服务 - 与后端实时消息通信
///
/// 负责建立 WebSocket 连接、发送消息、接收消息与心跳保活。
/// 后端地址通过 [baseUrl] 配置（默认 `ws://localhost:8000`），
/// 通过 [connect] 传入 JWT token 完成鉴权连接。
///
/// 连接异常断开时会按指数退避策略自动重连（手动 [disconnect] 不重连）。
/// 若连接失败是因 token 过期导致，会触发 [onAuthError] 回调跳转登录页。
class WebSocketService {
  /// WebSocket 基础地址（可运行时切换，用于本地/远程模式切换）
  static String baseUrl = 'ws://localhost:8000';

  /// 认证失败回调（token 过期/无效时触发，用于跳转登录页）
  static void Function()? onAuthError;

  /// WebSocket 通道
  WebSocketChannel? _channel;

  /// 心跳定时器（每 30 秒发送一次）
  Timer? _heartbeatTimer;

  /// 流式订阅
  StreamSubscription<dynamic>? _subscription;

  /// 收到消息时的回调（已解析为 Map）
  void Function(Map<String, dynamic> message)? onMessage;

  /// 工具执行取消回调（本地执行器 hook 模式）
  ///
  /// 收到 ``tool_exec_cancel`` 时通知本地执行器终止对应分离进程。
  void Function(Map<String, dynamic> message)? onToolExecCancel;

  /// 工具执行请求处理者列表（本地执行器 / SSH 执行器共同注册）。
  ///
  /// 收到 ``tool_exec_request`` 时按注册顺序依次调用各处理者；返回 `true`
  /// 表示该处理者已接管消息（不再派发给后续处理者，也不会派发给
  /// [onMessage]，避免页面重复解析）。本地与 SSH 模式互斥，由各处理者
  /// 按自身模式状态决定是否接管（本地处理者在 SSH 模式时返回 false 放行）。
  final List<ToolExecRequestHandler> _toolExecRequestHandlers =
      <ToolExecRequestHandler>[];

  /// 注册一个工具执行请求处理者（重复注册会被忽略）。
  void addToolExecRequestHandler(ToolExecRequestHandler handler) {
    if (!_toolExecRequestHandlers.contains(handler)) {
      _toolExecRequestHandlers.add(handler);
    }
  }

  /// 注销一个工具执行请求处理者。
  void removeToolExecRequestHandler(ToolExecRequestHandler handler) {
    _toolExecRequestHandlers.remove(handler);
  }

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
  /// 地址使用 [baseUrl]（可在运行时切换本地/远程模式）。
  void connect(String token) {
    _token = token;
    disconnect();
    _shouldReconnect = true;
    final Uri uri = Uri.parse('$baseUrl/ws?token=$token');
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
      // 工具执行请求交给已注册的执行器处理者（本地/SSH 按模式互斥接管，
      // 不向上派发）。某处理者返回 true 表示已接管，停止后续派发。
      if (type == 'tool_exec_request') {
        final List<ToolExecRequestHandler> handlers =
            List<ToolExecRequestHandler>.of(_toolExecRequestHandlers);
        for (final ToolExecRequestHandler handler in handlers) {
          if (handler(json)) return;
        }
        return;
      }
      // 工具执行取消交给本地执行器（hook 模式终止分离进程，不向上派发）
      if (type == 'tool_exec_cancel') {
        onToolExecCancel?.call(json);
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
  /// 若 token 已过期，直接触发 [onAuthError] 回调跳转登录页。
  void _scheduleReconnect() {
    _markDisconnected();
    // 检查 token 是否过期
    if (_isTokenExpired()) {
      _shouldReconnect = false;
      onAuthError?.call();
      return;
    }
    if (_shouldReconnect && _reconnectAttempts < _maxReconnectAttempts) {
      // 指数退避：0、2、4、6... 秒，最大 30 秒
      final int delay = min(_reconnectAttempts * 2, 30);
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(Duration(seconds: delay), _reconnect);
      _reconnectAttempts++;
    }
  }

  /// 检查本地存储的 JWT token 是否已过期
  ///
  /// 解码 token 的 payload（不验证签名），比对 `exp` 字段与当前时间。
  /// 无法解码或无 `exp` 字段时返回 false，避免误判。
  bool _isTokenExpired() {
    final String? token = _token;
    if (token == null || token.isEmpty) return false;
    try {
      final List<String> parts = token.split('.');
      if (parts.length < 2) return false;
      final String normalized = base64Url.normalize(parts[1]);
      final String decoded = utf8.decode(base64Url.decode(normalized));
      final Map<String, dynamic> payload =
          jsonDecode(decoded) as Map<String, dynamic>;
      final int exp = payload['exp'] as int;
      return DateTime.now().millisecondsSinceEpoch ~/ 1000 > exp;
    } catch (_) {
      return false;
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
