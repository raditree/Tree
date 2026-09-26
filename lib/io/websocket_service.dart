import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:tree_protocol/tree_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 工具执行请求处理者签名。
///
/// 返回 `true` 表示已接管该 ``tool_exec_request``（WebSocket 服务不再派发
/// 给后续处理者）；返回 `false` 表示未接管（交由其他处理者按需处理）。
typedef ToolExecRequestHandler = bool Function(Map<String, dynamic> message);

/// 工具执行取消处理者签名。
///
/// 各处理者（本地执行器 / SSH 执行器）按自身记录（hook 分离进程 / SSH hook
/// pidfile）判断该取消是否归属本端，无关时静默忽略。
typedef ToolExecCancelHandler = void Function(Map<String, dynamic> message);

// 分帧参数（阈值 kWsFrameChunkThresholdBytes / 分片预算
// kWsFrameChunkPartBytes / 在途 TTL kWsFrameChunkTtl）与三件套类型名统一由
// 协议包提供（见 package:tree_protocol 的 ws_frame.dart 与
// WsOutboundType.frameBegin/frameChunk/frameEnd）——核心进程使用同一组常量，
// 两侧阈值不可能再漂移。

/// 在途分片序列（接收侧重组缓冲）。
class _InboundFrames {
  _InboundFrames(this.total, this.startedAt);

  /// 声明的总片数。
  final int total;

  /// 首片到达时刻（TTL 判定用）。
  final DateTime startedAt;

  /// 已到达的分片：seq -> part。
  final Map<int, String> parts = <int, String>{};
}

/// 一次分片切片的结果（Dart 2.19 无 record，故用具名字段类）。
class _FrameSlice {
  const _FrameSlice(this.part, this.consumedCodeUnits);

  /// 切出的片段。
  final String part;

  /// 消费掉的 UTF-16 码元数（0 表示无法推进，调用方应停止）。
  final int consumedCodeUnits;
}

/// WebSocket 服务 - 与后端实时消息通信
///
/// 负责建立 WebSocket 连接、发送消息、接收消息与心跳保活。
/// 后端地址通过 [baseUrl] 配置（默认 `ws://localhost:8000`），
/// 通过 [connect] 传入 JWT token 完成鉴权连接。
///
/// 连接异常断开时会按指数退避策略自动重连（手动 [disconnect] 不重连）。
/// 桌面分支已取消账号体系：token 是核心进程下发的一次性本地 token，不存在
/// "过期"语义，因此不再有跳登录页的回调。
class WebSocketService {
  /// WebSocket 基础地址（核心进程回环地址，形如 `ws://127.0.0.1:54321`）
  static String baseUrl = 'ws://127.0.0.1:0';

  /// WebSocket 通道
  WebSocketChannel? _channel;

  /// 心跳定时器（每 30 秒发送一次）
  Timer? _heartbeatTimer;

  /// 流式订阅
  StreamSubscription<dynamic>? _subscription;

  /// 收到消息时的回调（已解析为 Map）
  void Function(Map<String, dynamic> message)? onMessage;

  /// 未知会话消息回调（Task 7 接收方会话保障）。
  ///
  /// 收到携带未知 session_id（不在 [knownSessionIds] 中）的
  /// ``msg_chunk`` / ``msg_end`` 时触发，早于 [onMessage] 派发。UI 层据此
  /// 自动创建本地会话条目并纳入列表，保证被动接收（如跨 team 推送、
  /// 成员主动汇报）的消息在会话列表可见。
  void Function(Map<String, dynamic> message)? onUnknownSession;

  /// 已知会话 id 集合（UI 层在会话列表/选中会话变化时经
  /// [registerKnownSessions] 同步；未注册时视为全部未知）。
  final Set<String> knownSessionIds = <String>{};

  /// 同步已知会话 id（增量合并，供未知会话判定）。
  void registerKnownSessions(Iterable<String> ids) {
    knownSessionIds.addAll(ids);
  }

  /// 清空已知会话 id（切换 agent / 会话列表整体重载前调用）。
  void clearKnownSessions() {
    knownSessionIds.clear();
  }

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

  /// 工具执行取消处理者列表（本地执行器 / SSH 执行器 hook 模式）。
  ///
  /// 收到 ``tool_exec_cancel`` 时逐个调用：本地执行器终止对应分离进程，
  /// SSH 执行器经远端 ``kill -TERM`` 终止对应 hook 后台进程；无关的
  /// tool_id 由各处理者自行静默忽略。
  final List<ToolExecCancelHandler> _toolExecCancelHandlers =
      <ToolExecCancelHandler>[];

  /// 注册一个工具执行取消处理者（重复注册会被忽略）。
  void addToolExecCancelHandler(ToolExecCancelHandler handler) {
    if (!_toolExecCancelHandlers.contains(handler)) {
      _toolExecCancelHandlers.add(handler);
    }
  }

  /// 注销一个工具执行取消处理者。
  void removeToolExecCancelHandler(ToolExecCancelHandler handler) {
    _toolExecCancelHandlers.remove(handler);
  }

  /// 连接状态变化回调
  void Function(bool connected)? onConnectionChange;

  /// 在途分片序列（接收侧重组缓冲）：transfer_id -> 缓冲。
  ///
  /// 断连时会被清空（见 [disconnect] / [_markDisconnected] 路径）：跨连接的
  /// 残片无法拼接，且不清会内存泄漏并让该次传输永久悬挂。
  final Map<String, _InboundFrames> _inboundFrames = <String, _InboundFrames>{};

  /// 出站分片序号（仅用于生成唯一 transfer_id）。
  static int _frameSeq = 0;

  /// 生成一个传输层分片序列 id：`frg_<epoch_ms>_<seq>`（对齐既有
  /// `phs_<epoch_ms>_<seq>` 的命名与"epoch 毫秒跨重启仍单调"约定）。
  static String _newFrameId() {
    final int ms = DateTime.now().millisecondsSinceEpoch;
    _frameSeq = (_frameSeq + 1) & 0xFFFFFF;
    return 'frg_${ms}_${_frameSeq.toRadixString(16)}';
  }

  /// 从 [text] 的起始下标切出至多 [maxBytes] 个 UTF-8 字节的片段。
  ///
  /// 在**字符边界**回退，绝不把一个码点切成两半：按码位累加其 UTF-8 长度，
  /// 超出预算即停。返回 [_FrameSlice]，`consumedCodeUnits` 为 0 表示无法推进。
  static _FrameSlice _takeFramePart(String text, int start, int maxBytes) {
    int index = start;
    int bytes = 0;
    while (index < text.length) {
      final int unit = text.codeUnitAt(index);
      final bool isHighSurrogate =
          unit >= 0xD800 && unit <= 0xDBFF && index + 1 < text.length;
      final int codeUnits = isHighSurrogate ? 2 : 1;
      final int charBytes;
      if (unit < 0x80) {
        charBytes = 1;
      } else if (unit < 0x800) {
        charBytes = 2;
      } else if (isHighSurrogate) {
        charBytes = 4; // 补充平面（代理对）
      } else {
        charBytes = 3;
      }
      // 至少消费一个码点，避免单码点超预算时死循环
      if (index > start && bytes + charBytes > maxBytes) {
        break;
      }
      bytes += charBytes;
      index += codeUnits;
    }
    if (index == start) {
      return const _FrameSlice('', 0);
    }
    return _FrameSlice(text.substring(start, index), index - start);
  }

  /// 当前是否已连接
  bool _isConnected = false;
  bool get isConnected => _isConnected;

  /// 重连定时器
  Timer? _reconnectTimer;

  /// 连接确认定时器（见 [connect]）。
  Timer? _connectedTimer;

  /// 当前重连次数
  int _reconnectAttempts = 0;

  /// 最大重连次数（默认 10）
  final int _maxReconnectAttempts = 10;

  /// 连接确认延迟：`WebSocketChannel.connect` 是惰性的（立即返回、握手在后台
  /// 进行），因此不能在建连调用处判定"已连上"。见 [connect] 的说明。
  static const Duration _connectedGrace = Duration(milliseconds: 400);

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
    // 乐观标记为已连接（UI 立即反映"连接中"），但**不**在此处清零重连计数：
    // WebSocketChannel.connect 立即返回、握手在后台进行，若在此清零则每次重连
    // 尝试都会把计数归零，`_scheduleReconnect` 的指数退避将恒为 0 秒并永不
    // 触达 _maxReconnectAttempts（后端不可用时形成 0 秒重连风暴）。
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
    // 连接确认：宽限期内未收到错误/正常关闭，则视为握手成功，此时才清零
    // 重连计数（使下一轮故障重新从 0 开始退避，而非叠加历史失败次数）。
    _connectedTimer?.cancel();
    _connectedTimer = Timer(_connectedGrace, () {
      _reconnectAttempts = 0;
    });
  }

  /// 处理收到的数据
  ///
  /// 将原始字符串解析为 JSON Map 并触发 [onMessage] 回调。
  /// 心跳响应包会被过滤不向上传递。
  ///
  /// **最前面**先拦截传输层分片帧（``frame_begin`` / ``frame_chunk`` /
  /// ``frame_end``）做重组：必须早于任何业务 type 分发，否则残片会落到
  /// [onMessage] 被业务层误判。
  void _handleData(dynamic data) {
    final String raw = data.toString();
    // 传输层分片帧的快速预判：避免对每个普通帧都做一次额外 jsonDecode
    if (raw.isNotEmpty &&
        raw.length > 20 &&
        raw.contains('"frame_')) {
      if (_maybeReassemble(raw)) {
        return;
      }
    }
    _dispatchDecoded(raw);
  }

  /// 尝试把 [raw] 当作传输层分片帧处理。
  ///
  /// :return: True 表示已消费（调用方不应再走业务分发）
  bool _maybeReassemble(String raw) {
    Map<String, dynamic> frame;
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return false;
      frame = decoded;
    } catch (_) {
      return false;
    }
    final String? type = frame['type'] as String?;
    if (type != WsOutboundType.frameBegin &&
        type != WsOutboundType.frameChunk &&
        type != WsOutboundType.frameEnd) {
      return false;
    }
    final String id = frame['id'] as String? ?? '';
    if (id.isEmpty) return false;

    // TTL 清理：丢弃过期残片，防内存泄漏与永久悬挂
    final DateTime now = DateTime.now();
    _inboundFrames.removeWhere((_, _InboundFrames f) =>
        now.difference(f.startedAt) > kWsFrameChunkTtl);

    if (type == WsOutboundType.frameBegin) {
      final int total = (frame['total'] as num?)?.toInt() ?? 0;
      if (total <= 0) return true;
      _inboundFrames[id] = _InboundFrames(total, now);
      return true;
    }

    final _InboundFrames? buffer = _inboundFrames[id];
    if (buffer == null) {
      // 无起始帧的残片（跨重连/超时后到达）：丢弃该片但不影响其他帧
      debugPrint('[WS] 收到无起始帧的分片，已丢弃: id=$id type=$type');
      return true;
    }

    if (type == WsOutboundType.frameChunk) {
      final int seq = (frame['seq'] as num?)?.toInt() ?? -1;
      final String? part = frame['part'] as String?;
      if (seq >= 0 && part != null) {
        buffer.parts[seq] = part;
      }
    }

    // 片数齐了（或收到结束帧）即尝试提交
    if (buffer.parts.length >= buffer.total ||
        type == WsOutboundType.frameEnd) {
      _inboundFrames.remove(id);
      final String joined = List<String>.generate(
        buffer.total,
        (int i) => buffer.parts[i] ?? '',
      ).join();
      debugPrint('[WS] 分片重组完成: id=$id parts=${buffer.total}');
      _deliverReassembled(joined);
    }
    return true;
  }

  /// 对已确认完整的 JSON 字符串做业务分发（原 [_handleData] 主体）。
  void _dispatchDecoded(String raw) {
    try {
      final Map<String, dynamic> json =
          jsonDecode(raw) as Map<String, dynamic>;
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
      // 工具执行取消分发给已注册的执行器处理者：本地执行器终止对应分离
      // 进程，SSH 执行器经远端 kill -TERM 终止 hook 后台进程（不向上派发）
      if (type == 'tool_exec_cancel') {
        final List<ToolExecCancelHandler> handlers =
            List<ToolExecCancelHandler>.of(_toolExecCancelHandlers);
        for (final ToolExecCancelHandler handler in handlers) {
          handler(json);
        }
        return;
      }
      // 未知会话消息（Task 7 接收方会话保障）：msg_chunk / msg_end 携带
      // 不在已知列表中的 session_id 时，先回调 UI 层创建本地会话条目，
      // 再照常派发 onMessage（是否渲染仍由 UI 按当前会话过滤）。
      if ((type == 'msg_chunk' || type == 'msg_end') &&
          onUnknownSession != null) {
        final String? sid = json['session_id'] as String?;
        if (sid != null && sid.isNotEmpty && !knownSessionIds.contains(sid)) {
          onUnknownSession!(json);
        }
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
      // 指数退避：2、4、6 … 30 秒封顶（下限 2s，避免 0 秒重连风暴）
      final int delay = (_reconnectAttempts + 1) * 2;
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(
        Duration(seconds: delay > 30 ? 30 : delay),
        _reconnect,
      );
      _reconnectAttempts++;
    }
  }

  /// 执行重连
  ///
  /// 使用上次保存的 token 重新建立连接。**不在此处清零 [_reconnectAttempts]**：
  /// 清零时机是"连接确认成功"（见 [connect] 的宽限定时器），否则每次重连尝试
  /// 都会把计数归零，指数退避与最大次数上限同时失效。
  void _reconnect() {
    if (_token == null) {
      return;
    }
    connect(_token!);
  }

  /// 标记为已断开
  void _markDisconnected() {
    _isConnected = false;
    // 禁止"连接确认"定时器在本次失败之后触发（它会把重连计数清零，
    // 使指数退避退化为 0 秒）。
    _connectedTimer?.cancel();
    _connectedTimer = null;
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
  ///
  /// 编码结果超过 [kWsFrameChunkThresholdBytes] 时自动分片为
  /// ``frame_begin`` / ``frame_chunk`` x N / ``frame_end``，由后端重组为同一条
  /// 逻辑消息——避免超过 uvicorn ``ws_max_size``(16 MiB) 被判超限后**静默**
  /// 关闭连接（连带注销执行器注册、打断在途工具调用）。
  void send(Map<String, dynamic> message) {
    if (_channel == null) {
      return;
    }
    final String encoded = jsonEncode(message);
    final int total = utf8.encode(encoded).length;
    if (total <= kWsFrameChunkThresholdBytes) {
      _channel!.sink.add(encoded);
      return;
    }
    _sendChunked(encoded, total);
  }

  /// 把已编码的超限消息切分发送。
  void _sendChunked(String encoded, int totalBytes) {
    final String id = _newFrameId();
    final int count = (totalBytes + kWsFrameChunkPartBytes - 1) ~/
        kWsFrameChunkPartBytes;
    final String? type = _peekType(encoded);
    debugPrint(
      '[WS] 发送消息超过分片阈值，已分片: type=$type bytes=$totalBytes '
      'chunks=$count id=$id',
    );
    _channel!.sink.add(jsonEncode(<String, dynamic>{
      'type': WsOutboundType.frameBegin,
      'id': id,
      'total': count,
      'bytes': totalBytes,
    }));
    int offset = 0;
    int seq = 0;
    while (offset < encoded.length) {
      final _FrameSlice slice =
          _takeFramePart(encoded, offset, kWsFrameChunkPartBytes);
      if (slice.consumedCodeUnits <= 0) break;
      _channel!.sink.add(jsonEncode(<String, dynamic>{
        'type': WsOutboundType.frameChunk,
        'id': id,
        'seq': seq,
        'part': slice.part,
      }));
      offset += slice.consumedCodeUnits;
      seq++;
    }
    _channel!.sink.add(jsonEncode(<String, dynamic>{
      'type': WsOutboundType.frameEnd,
      'id': id,
      'total': seq,
    }));
  }

  /// 轻量提取已编码消息的 type（仅用于日志，失败不影响发送）。
  static String? _peekType(String encoded) {
    try {
      final Object? decoded = jsonDecode(encoded);
      if (decoded is Map) {
        return decoded['type'] as String?;
      }
    } catch (_) {
      // 忽略：仅日志用途
    }
    return null;
  }

  /// 重建分片消息：把 part 拼回原始 JSON 字符串后走业务分发。
  void _deliverReassembled(String json) {
    _dispatchDecoded(json);
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
    _connectedTimer?.cancel();
    _connectedTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _isConnected = false;
    // 跨连接的残片无法拼接：清空在途分片，防内存泄漏与永久悬挂
    _inboundFrames.clear();
  }
}
