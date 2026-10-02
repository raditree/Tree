import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 进程内假 MCP **Streamable HTTP** 服务端（真 HTTP，不出网）。
///
/// 覆盖规范里我们需要的几面：单端点 POST、`Mcp-Session-Id` 会话、`initialize` /
/// `notifications/initialized` / `tools/list` / `tools/call` / `ping`，响应形态既有
/// `application/json` 也有 `text/event-stream`（SSE），以及 404（会话失效）、500、
/// 完全不回（判活用）与 `DELETE`（释放会话）。
class _FakeHttpMcp {
  _FakeHttpMcp._(this._server, this._sub);

  static Future<_FakeHttpMcp> start({
    bool silent = false,
    bool requireSession = true,
  }) async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    late final _FakeHttpMcp fake;
    final StreamSubscription<HttpRequest> sub = server.listen(
      (HttpRequest request) => fake._handle(request),
    );
    fake = _FakeHttpMcp._(server, sub)
      ..silent = silent
      ..requireSession = requireSession;
    return fake;
  }

  final HttpServer _server;
  final StreamSubscription<HttpRequest> _sub;

  /// 收到的 JSON-RPC 报文（按到达顺序）。
  final List<Map<String, dynamic>> messages = <Map<String, dynamic>>[];

  /// 每个请求带的 `Mcp-Session-Id`（含 DELETE）。
  final List<String> sessionHeaders = <String>[];

  /// 每个请求带的 `Accept`。
  final List<String> acceptHeaders = <String>[];

  /// 自定义请求头是否透传（`x-test`）。
  String customHeader = '';

  int deletes = 0;
  bool silent = false;
  bool requireSession = true;
  final String sessionId = 'sess-1';

  String get url => 'http://${_server.address.host}:${_server.port}/mcp';

  Future<void> close() async {
    await _sub.cancel();
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    acceptHeaders.add(request.headers.value(HttpHeaders.acceptHeader) ?? '');
    customHeader = request.headers.value('x-test') ?? '';
    sessionHeaders.add(request.headers.value('mcp-session-id') ?? '');
    if (request.method == 'DELETE') {
      deletes++;
      request.response.statusCode = 200;
      await request.response.close();
      return;
    }
    if (silent) return; // 一声不吭：验证"心跳丢失"判据（连接挂着不回）
    final String body = await utf8.decoder.bind(request).join();
    final Map<String, dynamic> message =
        jsonDecode(body) as Map<String, dynamic>;
    messages.add(message);
    final String method = (message['method'] ?? '').toString();
    if (requireSession &&
        method != 'initialize' &&
        (request.headers.value('mcp-session-id') ?? '').isEmpty) {
      request.response.statusCode = 400;
      request.response.write('missing Mcp-Session-Id');
      await request.response.close();
      return;
    }
    switch (method) {
      case 'initialize':
        request.response.headers.set('mcp-session-id', sessionId);
        await _json(request, <String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <String, dynamic>{
            'protocolVersion': '2025-03-26',
            'capabilities': <String, dynamic>{},
            'serverInfo': <String, dynamic>{
              'name': 'fake-http',
              'version': '0.1',
            },
          },
        });
      case 'notifications/initialized':
        request.response.statusCode = 202;
        await request.response.close();
      case 'ping':
        await _json(request, <String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <String, dynamic>{},
        });
      case 'tools/list':
        await _json(request, <String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <String, dynamic>{
            'tools': <Map<String, dynamic>>[
              <String, dynamic>{
                'name': 'echo',
                'description': '回显',
                'inputSchema': <String, dynamic>{'type': 'object'},
              },
            ],
          },
        });
      case 'tools/call':
        final Map<String, dynamic> params =
            (message['params'] as Map<dynamic, dynamic>? ?? <dynamic, dynamic>{})
                .map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
        final String tool = (params['name'] ?? '').toString();
        final Object? id = message['id'];
        if (tool == 'sse') {
          await _sse(request, id);
          return;
        }
        if (tool == 'stale') {
          request.response.statusCode = 404;
          await request.response.close();
          return;
        }
        if (tool == 'boom') {
          request.response.statusCode = 500;
          request.response.write('内部错误（假）');
          await request.response.close();
          return;
        }
        final Map<dynamic, dynamic> args =
            (params['arguments'] as Map<dynamic, dynamic>? ??
            <dynamic, dynamic>{});
        await _json(request, <String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, dynamic>{
            'content': <Map<String, dynamic>>[
              <String, dynamic>{
                'type': 'text',
                'text': 'echo: ${args['text'] ?? ''}',
              },
            ],
          },
        });
      default:
        request.response.statusCode = 500;
        request.response.write('未知方法（假）');
        await request.response.close();
    }
  }

  Future<void> _json(HttpRequest request, Map<String, dynamic> body) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  /// SSE 形态的响应：先一条通知，再一条本请求的响应（规范允许的流式回包）。
  Future<void> _sse(HttpRequest request, Object? id) async {
    request.response.headers.contentType = ContentType(
      'text',
      'event-stream',
      charset: 'utf-8',
    );
    request.response.write(': 心跳注释\n\n');
    request.response.write(
      'data: ${jsonEncode(<String, dynamic>{'jsonrpc': '2.0', 'method': 'notifications/message', 'params': <String, dynamic>{'level': 'info'}})}\n\n',
    );
    request.response.write(
      'data: ${jsonEncode(<String, dynamic>{'jsonrpc': '2.0', 'id': id, 'result': <String, dynamic>{'content': <Map<String, dynamic>>[<String, dynamic>{'type': 'text', 'text': 'sse-ok'}]}})}\n\n',
    );
    await request.response.flush();
    await request.response.close();
  }
}

McpServerConfig _httpConfig(_FakeHttpMcp fake, {Map<String, String>? headers}) =>
    McpServerConfig(
      name: 'httpdemo',
      transport: mcpTransportHttp,
      url: fake.url,
      headers: headers ?? <String, String>{'x-test': 'yes'},
    );

void main() {
  late _FakeHttpMcp fake;

  setUp(() async {
    fake = await _FakeHttpMcp.start();
  });

  tearDown(() async {
    await fake.close();
  });

  test('握手（带会话）→ tools/list → tools/call（JSON 响应）全链路', () async {
    final McpClient client = await McpClient.start(
      _httpConfig(fake),
      heartbeatInterval: const Duration(milliseconds: 40),
      missedHeartbeatLimit: 3,
    );
    addTearDown(client.close);

    expect(client.serverInfo['name'], 'fake-http');
    expect(client.protocolVersion, '2025-03-26');

    final List<McpToolInfo> tools = await client.listTools();
    expect(tools.map((McpToolInfo t) => t.name), <String>['echo']);

    final McpCallResult result = await client.callTool('echo', <String, dynamic>{
      'text': 'hi',
    });
    expect(result.isError, isFalse);
    expect(result.text, 'echo: hi');

    // 请求形态：单端点 POST、Accept 同时要 JSON 与 SSE、自定义头透传
    expect(fake.acceptHeaders.first, contains('application/json'));
    expect(fake.acceptHeaders.first, contains('text/event-stream'));
    expect(fake.customHeader, 'yes');
    // 会话：initialize 那一发不带（那时还没有会话），之后的每一发都要带服务端给的 id。
    // 这里服务端是 `requireSession: true`：tools/list / tools/call 能成功本身就证明
    // 会话被带上了；下面再把"带上的值"钉死。
    expect(fake.sessionHeaders.first, isEmpty);
    expect(
      fake.sessionHeaders.where((String s) => s.isNotEmpty),
      everyElement('sess-1'),
    );
    expect(
      fake.messages
          .where((Map<String, dynamic> m) => m['method'] == 'initialize')
          .length,
      1,
    );
  });

  test('SSE 形态的响应：流里先来通知、再来本请求的响应', () async {
    final McpClient client = await McpClient.start(
      _httpConfig(fake),
      heartbeatInterval: const Duration(milliseconds: 40),
      missedHeartbeatLimit: 3,
    );
    addTearDown(client.close);

    final McpCallResult result = await client.callTool('sse', <String, dynamic>{});
    expect(result.isError, isFalse, reason: '收到 SSE 流里的响应即为成功');
    expect(result.text, 'sse-ok');
  });

  test('会话失效（404）与非 2xx（500）都给可读错误（不静默、不挂死）', () async {
    final McpClient client = await McpClient.start(
      _httpConfig(fake),
      heartbeatInterval: const Duration(milliseconds: 40),
      missedHeartbeatLimit: 3,
    );
    addTearDown(client.close);

    await expectLater(
      client.callTool('stale', <String, dynamic>{}),
      throwsA(
        predicate(
          (Object e) => '$e'.contains('会话已失效') || '$e'.contains('404'),
        ),
      ),
    );
    await expectLater(
      client.callTool('boom', <String, dynamic>{}),
      throwsA(
        predicate((Object e) => '$e'.contains('500') && '$e'.contains('内部错误')),
      ),
    );
  });

  test('close() 尽力 DELETE 释放会话（带上 Mcp-Session-Id）', () async {
    final McpClient client = await McpClient.start(
      _httpConfig(fake),
      heartbeatInterval: const Duration(milliseconds: 40),
      missedHeartbeatLimit: 3,
    );
    await client.listTools();
    await client.close();

    expect(fake.deletes, 1);
    expect(fake.sessionHeaders.last, 'sess-1');
    expect(client.isClosed, isTrue);
  });

  test('服务端一声不吭 ⇒ 心跳丢失：握手以 McpLivenessException 显式结束（无静态超时）', () async {
    final _FakeHttpMcp quiet = await _FakeHttpMcp.start(silent: true);
    addTearDown(quiet.close);
    await expectLater(
      McpClient.start(
        _httpConfig(quiet),
        heartbeatInterval: const Duration(milliseconds: 40),
        missedHeartbeatLimit: 3,
      ),
      throwsA(isA<McpLivenessException>()),
    );
  });

  test('配置校验：transport=http 但不给（或给错）url ⇒ 立刻可读失败，不发请求', () async {
    await expectLater(
      McpClient.start(
        McpServerConfig(name: 'bad', transport: mcpTransportHttp),
        heartbeatInterval: const Duration(milliseconds: 40),
      ),
      throwsA(
        predicate((Object e) => '$e'.contains('url 不是合法的 http(s) 地址')),
      ),
    );
    await expectLater(
      McpClient.start(
        McpServerConfig(
          name: 'bad2',
          transport: mcpTransportHttp,
          url: 'file:///etc/passwd',
        ),
        heartbeatInterval: const Duration(milliseconds: 40),
      ),
      throwsA(predicate((Object e) => '$e'.contains('url 不是合法'))),
    );
  });
}
