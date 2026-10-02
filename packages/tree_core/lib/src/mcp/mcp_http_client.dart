import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../llm/sse_parser.dart';
import '../util/liveness.dart';
import 'mcp_client.dart';

/// Streamable HTTP 传输下我们请求的协议版本。
///
/// 这是**引入 Streamable HTTP（单端点 POST + 可选 SSE 流）**的那一版规范。服务端可以在
/// 响应里回它自己的版本（我们会记住并用于后续请求的 `MCP-Protocol-Version` 头）。
const String kMcpHttpProtocolVersion = '2025-03-26';

/// MCP **Streamable HTTP** 客户端（单端点）。
///
/// 规范要点（本实现覆盖其中"工具来源"需要的部分）：
/// - **一个端点**，客户端把每条 JSON-RPC 报文 `POST` 过去；请求头带
///   `Content-Type: application/json`、`Accept: application/json, text/event-stream`，
///   以及用户在配置里写的自定义头（`Authorization` 等）；
/// - 响应可能是 **`application/json`**（一条报文）也可能是 **`text/event-stream`**
///   （SSE 流：其间可能有通知/多条报文，取 `id` 匹配的那条为响应）；
/// - **会话**：`initialize` 的响应头 `Mcp-Session-Id` 要原样带到后续请求上；关闭时
///   尽力 `DELETE` 该端点（带会话头）让服务端释放会话；
/// - 后续请求带 `MCP-Protocol-Version: <协商到的版本>`（2025-06-18 起是硬要求，
///   带上对 2025-03-26 的服务端也无害）。
///
/// **判活口径与 stdio 完全一致（M9 规约 1.1）**：没有静态超时——每 [LivenessTracker.interval]
/// 发一次 `ping`，一拍内没有任何协议消息就记一次丢失，连续 N 拍判链路失活，在途请求以
/// 显式错误结束（`McpLivenessException`），恢复自动清除。
///
/// **不做的事（诚实边界）**：不做 GET 型 server→client 长流（服务端主动请求我们也不支持，
/// 收到就记日志并忽略——与 stdio 实现同一口径）；不做 OAuth/客户端证书，鉴权只靠自定义请求头；
/// 不做旧版双端点 `HTTP+SSE`（2024-11-05）。
///
/// **由谁发起**：HTTP 请求由**核心进程**发出（与 stdio 起子进程同一侧）；`scope`
/// （server/local/ssh）目前仍是"展示 + 持久化"字段，不改变请求的发起位置。
class HttpMcpClient implements McpClient {
  /// 建连 + 握手（`initialize` → `notifications/initialized`）。
  static Future<McpClient> start(
    McpServerConfig config, {
    Duration heartbeatInterval = LivenessTracker.defaultInterval,
    int missedHeartbeatLimit = LivenessTracker.defaultMaxMisses,
  }) async {
    final Uri? uri = Uri.tryParse(config.url.trim());
    if (uri == null ||
        !(uri.isScheme('http') || uri.isScheme('https')) ||
        uri.host.isEmpty) {
      throw McpException(
        'MCP 服务 ${config.name} 的 url 不是合法的 http(s) 地址：${config.url}',
      );
    }
    final HttpMcpClient client = HttpMcpClient._(
      config,
      uri,
      LivenessTracker(
        label: 'MCP 服务 ${config.name}（HTTP）',
        interval: heartbeatInterval,
        maxMisses: missedHeartbeatLimit,
      ),
    );
    // 心跳在握手之前就起来：服务端一直不回就等于"心跳丢失"，判据只有一套。
    client._startHeartbeat();
    try {
      await client._initialize();
    } catch (error) {
      await client.close();
      rethrow;
    }
    return client;
  }

  HttpMcpClient._(this.config, this.uri, this.liveness);

  final McpServerConfig config;
  final Uri uri;

  /// 链路活性台账（与 stdio 同一套判据）。
  @override
  final LivenessTracker liveness;

  final HttpClient _http = HttpClient();
  final Map<int, Completer<Map<String, dynamic>>> _pending =
      <int, Completer<Map<String, dynamic>>>{};

  /// 最近若干条链路备注（HTTP 没有 stderr，这里放失败片段与异常，报错时附上）。
  final List<String> _notes = <String>[];

  int _nextId = 0;
  bool _closed = false;
  bool _beatSinceTick = false;
  bool _wasStale = false;
  int _degradeCount = 0;
  Timer? _heartbeatTimer;

  /// 上一个 `ping` 还在路上（避免每拍堆一个请求：只发不等，回包算心跳）。
  bool _pingInFlight = false;

  /// 在途 `ping` 的报文 id（回包到了就解除 `_pingInFlight`）。
  int? _pingId;

  /// 是否已完成 `initialize`。
  ///
  /// **握手完成前不发 `ping`**：那时还没有会话（`Mcp-Session-Id` 要等 initialize 的响应头），
  /// 发出去只会被服务端按"未建立会话"拒掉——徒增噪音，也会污染会话断言。
  /// 握手期间的判活不受影响：一拍内没收到任何协议消息照样记一次丢失（`liveness.guard`
  /// 会以心跳丢失收口这次握手）。
  bool _initialized = false;

  /// 会话 id（`initialize` 响应头 `Mcp-Session-Id`；空 = 服务端不要求会话）。
  String sessionId = '';

  @override
  Map<String, dynamic> serverInfo = <String, dynamic>{};

  @override
  String protocolVersion = '';

  @override
  int get degradeCount => _degradeCount;

  /// 是否已判 degraded（连续 N 次心跳丢失；心跳恢复后自动变回 false）。
  @override
  bool get isDegraded => liveness.isStale;

  @override
  bool get isClosed => _closed;

  /// HTTP 传输没有 stderr：这里给最近几条备注（HTTP 状态、异常片段）。
  @override
  String get stderrTail {
    final String text = _notes.join('\n');
    return text.length <= 2000 ? text : text.substring(text.length - 2000);
  }

  // ── 协议方法（与 stdio 客户端同一套解析） ─────────────────────────────

  @override
  Future<List<McpToolInfo>> listTools() async {
    final Map<String, dynamic> result = await _request(
      'tools/list',
      const <String, dynamic>{},
    );
    return mcpToolsFromResult(result);
  }

  @override
  Future<McpCallResult> callTool(
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    final Map<String, dynamic> result = await _request(
      'tools/call',
      <String, dynamic>{'name': toolName, 'arguments': arguments},
    );
    return mcpCallResultFrom(result);
  }

  Future<void> _initialize() async {
    final Map<String, dynamic> result = await _request(
      'initialize',
      <String, dynamic>{
        'protocolVersion': kMcpHttpProtocolVersion,
        'capabilities': <String, dynamic>{},
        'clientInfo': <String, dynamic>{
          'name': 'tree_core',
          'version': '1.0.0',
        },
      },
    );
    serverInfo =
        (result['serverInfo'] as Map<dynamic, dynamic>?)?.map(
          (dynamic k, dynamic v) => MapEntry(k.toString(), v),
        ) ??
        <String, dynamic>{};
    protocolVersion = (result['protocolVersion'] ?? '').toString();
    // 通知（无 id）：规范期望 202。**不 await**——握手不该被一个"服务端不回 202"的实现挂住
    // （判活只由心跳说了算，见类文档）；失败记在备注里。
    unawaited(
      _postNotification('notifications/initialized', const <String, dynamic>{}),
    );
    _initialized = true;
  }

  // ── 请求 / 响应 ───────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> params,
  ) {
    if (isClosed) {
      return Future<Map<String, dynamic>>.error(
        McpException('MCP 服务 ${config.name} 已关闭'),
      );
    }
    final int id = ++_nextId;
    final Completer<Map<String, dynamic>> completer =
        Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    unawaited(_send(id, method, <String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    }));
    return _awaitRequest(id, method, completer);
  }

  /// 等回包：**没有静态超时**，只有心跳丢失（`liveness.guard`）才会结束等待。
  Future<Map<String, dynamic>> _awaitRequest(
    int id,
    String method,
    Completer<Map<String, dynamic>> completer,
  ) async {
    try {
      return await liveness.guard(() => completer.future);
    } on LivenessLostException catch (error) {
      _pending.remove(id);
      final McpLivenessException lost = _livenessError(method, cause: error);
      if (!completer.isCompleted) completer.completeError(lost);
      throw lost;
    } finally {
      _pending.remove(id);
    }
  }

  McpLivenessException _livenessError(String method, {Object? cause}) =>
      McpLivenessException(
        'MCP 服务 ${config.name} 的 $method 心跳丢失（链路失活）：'
        '连续 ${liveness.missedCount} 次心跳未达（心跳间隔 '
        '${LivenessTracker.formatDuration(liveness.interval)}，阈值 '
        '${liveness.maxMisses} 次）；连接未关闭，心跳恢复后自动清除',
        service: config.name,
        method: method,
        missedCount: liveness.missedCount,
        interval: liveness.interval,
        maxMisses: liveness.maxMisses,
        cause: cause,
      );

  /// 发一条报文并处理响应（JSON 或 SSE）。
  Future<void> _send(int id, String method, Map<String, dynamic> message) async {
    try {
      final HttpClientResponse response = await _post(message);
      if (response.statusCode >= 400) {
        final String body = await _readTail(response);
        final String reason = _httpErrorReason(response.statusCode, body);
        _note('$method ⇒ HTTP ${response.statusCode}：$reason');
        _failPending(id, McpException(reason));
        return;
      }
      // 会话：服务端在 initialize 的响应头里给（带了就要在后续请求上原样带回去）
      final String? session = response.headers.value('mcp-session-id');
      if (session != null && session.trim().isNotEmpty && sessionId.isEmpty) {
        sessionId = session.trim();
        _note('已建立会话：${sessionId.substring(0, sessionId.length > 8 ? 8 : sessionId.length)}…');
      }
      final String mime =
          response.headers.contentType?.mimeType.toLowerCase() ?? '';
      if (mime.contains('text/event-stream')) {
        await _readSse(response, waitingFor: id);
        return;
      }
      if (mime.contains('json')) {
        final String body = await response.transform(utf8.decoder).join();
        _dispatch(body);
        return;
      }
      // 既不是 JSON 也不是 SSE：如实报出来（不猜、不静默）
      final String body = await _readTail(response);
      final String reason =
          'MCP 服务 ${config.name} 的 $method 响应类型不可识别'
          '（Content-Type: ${response.headers.contentType}）：$body';
      _note(reason);
      _failPending(id, McpException(reason));
    } catch (error) {
      _note('$method 请求失败：$error');
      _failPending(
        id,
        McpException('MCP 服务 ${config.name} 的 $method 请求失败：$error'),
      );
    }
  }

  /// 发一条**通知**（无 id）：只要 2xx / 202 就算成功（不等业务回包）。
  Future<void> _postNotification(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (isClosed) return;
    try {
      final HttpClientResponse response = await _post(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': method,
        'params': params,
      });
      if (response.statusCode >= 400) {
        final String body = await _readTail(response);
        _note('$method ⇒ HTTP ${response.statusCode}：$body');
      } else {
        await response.drain<void>();
      }
    } catch (error) {
      _note('$method 发送失败：$error');
    }
  }

  Future<HttpClientResponse> _post(Map<String, dynamic> message) async {
    final HttpClientRequest request = await _http.postUrl(uri);
    request.headers.contentType = ContentType.json;
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/json, text/event-stream',
    );
    if (sessionId.isNotEmpty) {
      request.headers.set('Mcp-Session-Id', sessionId);
    }
    final String version = protocolVersion.isNotEmpty
        ? protocolVersion
        : kMcpHttpProtocolVersion;
    request.headers.set('MCP-Protocol-Version', version);
    for (final MapEntry<String, String> header in config.headers.entries) {
      if (header.key.trim().isEmpty) continue;
      request.headers.set(header.key, header.value);
    }
    request.add(utf8.encode(jsonEncode(message)));
    return request.close();
  }

  /// 把响应体读成一段有界的文本尾巴（错误提示用）。
  Future<String> _readTail(HttpClientResponse response) async {
    try {
      final String text = await response
          .transform(utf8.decoder)
          .join();
      final String trimmed = text.trim();
      return trimmed.length <= 400
          ? trimmed
          : '…${trimmed.substring(trimmed.length - 400)}';
    } catch (_) {
      return '';
    }
  }

  String _httpErrorReason(int status, String body) {
    final String detail = body.isEmpty ? '' : '，响应体：$body';
    if (status == 404) {
      return 'MCP 服务 ${config.name} 返回 HTTP 404：会话已失效或端点不存在'
          '（需要重新握手）$detail';
    }
    return 'MCP 服务 ${config.name} 返回 HTTP $status$detail';
  }

  /// 逐块解析 SSE 流：其间可能有通知、多条报文，取 `id` 匹配的那条为响应。
  ///
  /// [waitingFor] 是本次 POST 的请求 id：一旦它的回包到了就收工（服务端可能还开着流）。
  Future<void> _readSse(HttpClientResponse response, {int? waitingFor}) async {
    final SseParser parser = SseParser();
    try {
      await for (final List<int> chunk in response) {
        final String text = utf8.decode(chunk, allowMalformed: true);
        for (final String line in const LineSplitter().convert(text)) {
          final String? payload = parser.accept(line);
          if (payload != null) _dispatch(payload);
        }
        if (waitingFor != null && !_pending.containsKey(waitingFor)) {
          // 本次 POST 的响应已到：**跳出**（而不是 drain 到流结束）——服务端可能一直开着
          // 这条流，drain 会把一个 future 永久挂住。
          break;
        }
      }
      final String? rest = parser.flush();
      if (rest != null) _dispatch(rest);
    } catch (error) {
      _note('SSE 流读取失败：$error');
      if (waitingFor != null) {
        _failPending(
          waitingFor,
          McpException('MCP 服务 ${config.name} 的 SSE 流中断：$error'),
        );
      }
    }
  }

  /// 处理一段可能是单条报文、也可能是批量的 JSON 文本。
  void _dispatch(String body) {
    final String text = body.trim();
    if (text.isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      // SSE 里夹了非 JSON（注释/心跳文本）：忽略，不打断协议
      return;
    }
    if (decoded is List<dynamic>) {
      for (final dynamic item in decoded) {
        if (item is Map<dynamic, dynamic>) _onMessage(_stringKeyed(item));
      }
      return;
    }
    if (decoded is Map<dynamic, dynamic>) _onMessage(_stringKeyed(decoded));
  }

  Map<String, dynamic> _stringKeyed(Map<dynamic, dynamic> map) =>
      map.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));

  void _onMessage(Map<String, dynamic> message) {
    // 任意一条合法 JSON-RPC 报文都是"链路还活着"的证据（与 stdio 同口径）
    _beat();
    final Object? id = message['id'];
    if (id is! int) {
      final Object? method = message['method'];
      if (method != null) {
        // 服务端主动请求（sampling / roots 之类）：本客户端不实现，如实记一笔
        _note('忽略了服务端主动请求：$method（本客户端不支持）');
      }
      return;
    }
    final Completer<Map<String, dynamic>>? completer = _pending.remove(id);
    if (id == _pingId) {
      _pingId = null;
      _pingInFlight = false;
    }
    if (completer == null || completer.isCompleted) return;
    try {
      completer.complete(_requestResult(message));
    } catch (error) {
      completer.completeError(error);
    }
  }

  Map<String, dynamic> _requestResult(Map<String, dynamic> message) {
    final Object? error = message['error'];
    if (error is Map<dynamic, dynamic>) {
      throw McpException('MCP 返回错误：${error['message'] ?? jsonEncode(error)}');
    }
    final Object? result = message['result'];
    if (result is Map<dynamic, dynamic>) return _stringKeyed(result);
    return <String, dynamic>{};
  }

  void _failPending(int id, Object error) {
    final Completer<Map<String, dynamic>>? completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    completer.completeError(error);
  }

  void _note(String text) {
    _notes.add(text);
    if (_notes.length > 20) _notes.removeAt(0);
  }

  // ── 心跳（与 stdio 同口径：没有静态超时，只有"心跳丢没丢"） ────────────

  void _startHeartbeat() {
    final Duration interval = liveness.interval;
    if (interval <= Duration.zero) return;
    _heartbeatTimer = Timer.periodic(interval, (Timer _) => _heartbeatTick());
  }

  void _heartbeatTick() {
    if (_closed) {
      _stopHeartbeat();
      return;
    }
    if (_beatSinceTick) {
      _beatSinceTick = false;
    } else {
      final bool staleNow = liveness.recordMiss();
      if (staleNow && !_wasStale) _degradeCount++;
      _wasStale = staleNow;
    }
    _sendPing();
  }

  /// 主动探活：MCP 有 `ping` 就用它。只发不等（回包在 [_onMessage] 里算心跳）；
  /// 上一拍还没回来就不重复发，避免往死链路里堆请求。
  void _sendPing() {
    if (isClosed || _pingInFlight || !_initialized) return;
    final int id = ++_nextId;
    final Completer<Map<String, dynamic>> completer =
        Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _pingInFlight = true;
    _pingId = id;
    unawaited(
      _send(id, 'ping', <String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'method': 'ping',
        'params': const <String, dynamic>{},
      }),
    );
    // ping 的回包只用于记心跳；这里把异常收掉（失败会经 _failPending 落地）
    unawaited(completer.future.catchError((Object _) => <String, dynamic>{}));
  }

  void _beat() {
    _beatSinceTick = true;
    _wasStale = false;
    liveness.recordBeat();
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// 关闭：尽力 `DELETE` 让服务端释放会话，再关掉 HTTP 客户端。
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _stopHeartbeat();
    final List<Completer<Map<String, dynamic>>> waiting = _pending.values
        .toList(growable: false);
    _pending.clear();
    for (final Completer<Map<String, dynamic>> completer in waiting) {
      if (!completer.isCompleted) {
        completer.completeError(
          McpException('MCP 服务 ${config.name} 已关闭'),
        );
      }
    }
    if (sessionId.isNotEmpty) {
      try {
        final HttpClientRequest request = await _http.deleteUrl(uri);
        request.headers.set('Mcp-Session-Id', sessionId);
        final HttpClientResponse response = await request.close();
        await response.drain<void>();
      } catch (error) {
        // 释放会话失败不该拦住关闭：记一笔即可（服务端会按自己的超时回收）
        _note('DELETE 会话失败：$error');
      }
    }
    _http.close(force: true);
  }
}
