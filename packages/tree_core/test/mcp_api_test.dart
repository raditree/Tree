import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

class _Client {
  _Client(this._server) : _http = HttpClient();

  final CoreServer _server;
  final HttpClient _http;

  Future<_Res> send(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final HttpClientRequest request = await _http.openUrl(
      method,
      Uri.parse('${_server.handshake.httpBaseUrl}$path'),
    );
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${_server.token}',
    );
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
    }
    final HttpClientResponse response = await request.close();
    final String text = await utf8.decoder.bind(response).join();
    return _Res(
      response.statusCode,
      text.trim().isEmpty
          ? <String, dynamic>{}
          : jsonDecode(text) as Map<String, dynamic>,
    );
  }

  void close() => _http.close(force: true);
}

class _Res {
  const _Res(this.status, this.json);
  final int status;
  final Map<String, dynamic> json;
}

class _FakeMcpClient implements McpClient {
  _FakeMcpClient(this.config);
  final McpServerConfig config;
  bool closed = false;

  @override
  Map<String, dynamic> get serverInfo => <String, dynamic>{'name': config.name};
  @override
  String get protocolVersion => '2024-11-05';
  @override
  String get stderrTail => '';
  @override
  bool get isClosed => closed;
  @override
  final LivenessTracker liveness = LivenessTracker(label: '假 MCP 服务');
  @override
  bool get isDegraded => liveness.isStale;
  @override
  int get degradeCount => 0;
  @override
  Future<List<McpToolInfo>> listTools() async => <McpToolInfo>[
    McpToolInfo(name: 'echo', description: '回显'),
  ];
  @override
  Future<McpCallResult> callTool(
    String toolName,
    Map<String, dynamic> arguments,
  ) async => McpCallResult(text: 'echo: ${arguments['text']}');
  @override
  Future<void> close() async => closed = true;
}

/// MCP 的 REST 面（右栏 MCP 配置页）。
void main() {
  late CoreServer server;
  late _Client client;
  late Directory temp;
  late McpService mcp;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tree_mcp_api_');
    mcp = McpService(
      configFile: '${temp.path}/config/mcp.yaml',
      clientFactory: (McpServerConfig config) async => _FakeMcpClient(config),
    );
    server = await CoreServer.start(
      mcpService: mcp,
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
    );
    client = _Client(server);
  });

  tearDown(() async {
    client.close();
    await server.close();
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  test('POST 注册 → GET 列表（服务 + 工具 + 错误）→ DELETE 删除', () async {
    final _Res empty = await client.send('GET', '/api/mcp/services');
    expect(empty.status, 200);
    expect(empty.json['services'], isEmpty);

    final _Res created = await client.send(
      'POST',
      '/api/mcp/services',
      body: <String, dynamic>{
        'name': 'fs',
        'command': 'npx',
        'args': <String>['-y', 'server-fs'],
        'scope': 'local',
      },
    );
    expect(created.status, 200);
    expect(created.json['success'], isTrue);

    final _Res listed = await client.send('GET', '/api/mcp/services');
    final Map<String, dynamic> view =
        (listed.json['services'] as List<dynamic>).single
            as Map<String, dynamic>;
    expect(view['name'], 'fs');
    expect(view['command'], 'npx');
    expect(view['args'], <String>['-y', 'server-fs']);
    expect(view['enabled'], isTrue);
    expect(view['builtin'], isFalse);
    final Map<String, dynamic> tool =
        (listed.json['tools'] as List<dynamic>).single as Map<String, dynamic>;
    expect(tool['mcp_name'], 'mcp__fs__echo');
    expect(listed.json['errors'], isEmpty);

    final _Res deleted = await client.send('DELETE', '/api/mcp/services/fs');
    expect(deleted.status, 200);
    expect(deleted.json['success'], isTrue);
    expect(
      (await client.send('GET', '/api/mcp/services')).json['services'],
      isEmpty,
    );
  });

  test('POST 注册 Streamable HTTP 服务：要 url 不要 command；GET 带 transport/url/headers', () async {
    final _Res missingUrl = await client.send(
      'POST',
      '/api/mcp/services',
      body: <String, dynamic>{'name': 'h', 'transport': 'http'},
    );
    expect(missingUrl.status, 400);
    expect(
      missingUrl.json['detail'].toString(),
      contains('需要合法 url'),
      reason: '错误响应体的可读原因在 detail 字段（见 errorBody）',
    );

    final _Res created = await client.send(
      'POST',
      '/api/mcp/services',
      body: <String, dynamic>{
        'name': 'h',
        'transport': 'http',
        'url': 'https://example.com/mcp',
        'headers': <String, String>{'Authorization': 'Bearer x'},
        'scope': '',
      },
    );
    expect(created.status, 200);
    expect(created.json['success'], isTrue);

    final _Res listed = await client.send('GET', '/api/mcp/services');
    final Map<String, dynamic> view =
        (listed.json['services'] as List<dynamic>).single
            as Map<String, dynamic>;
    expect(view['transport'], 'http');
    expect(view['url'], 'https://example.com/mcp');
    expect(view['headers'], <String, String>{'Authorization': 'Bearer x'});
    expect(view['command'], '', reason: 'http 传输没有本机命令');
  });

  test('非法注册 400；未知/内置服务删除有可读反馈', () async {
    expect(
      (await client.send(
        'POST',
        '/api/mcp/services',
        body: <String, dynamic>{'name': 'fs'},
      )).status,
      400,
      reason: '缺 command',
    );
    expect(
      (await client.send('DELETE', '/api/mcp/services/ghost')).status,
      404,
    );
    await client.send(
      'POST',
      '/api/mcp/services',
      body: <String, dynamic>{
        'name': 'builtin-fs',
        'command': 'npx',
        'builtin': true,
      },
    );
    final _Res refused = await client.send(
      'DELETE',
      '/api/mcp/services/builtin-fs',
    );
    expect(refused.status, 404);
    expect(jsonEncode(refused.json), contains('内置 MCP 服务不可删除'));
  });
}
