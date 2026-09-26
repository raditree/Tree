import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

import 'fake_transport.dart';
import 'ws_harness.dart';

/// 会话待办的前后端闭环：工具写入 → HTTP 读回（前端 TodoPanel 的口径）。
void main() {
  late Directory root;
  late Directory workspace;
  late TreePaths paths;
  late FileTodoStore todos;
  late CoreServer server;
  late CoreSettings settings;
  late String agentId;

  Future<FakeTransport> start(List<List<LlmStreamEvent>> script) async {
    final FakeTransport transport = FakeTransport(script);
    settings = CoreSettings();
    settings.createModel(<String, dynamic>{
      'model_id': 'demo',
      'base_url': 'https://api.example.com/v1',
      'api_key': 'sk-test',
    });
    server = await CoreServer.start(
      streamChunkDelay: Duration.zero,
      enableHeartbeat: false,
      settings: settings,
      todoStore: todos,
      engine: LlmAgentEngine(
        resolveModel: settings.model,
        toolRunner: WorkspaceToolRunner(
          resolveWorkspaceDir: (String id) => workspace.path,
          todoStore: todos,
        ),
        transportFactory: (CoreModelConfig config) => transport,
      ),
    );
    agentId = server.store.createAgent(name: '待办用例', modelId: 'demo').id;
    return transport;
  }

  Future<Map<String, dynamic>> getJson(String path) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.getUrl(
        Uri.parse('${server.handshake.httpBaseUrl}$path'),
      );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${server.token}',
      );
      final HttpClientResponse response = await request.close();
      final String body = await utf8.decoder.bind(response).join();
      expect(response.statusCode, 200, reason: body);
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('tree_todos_api_');
    workspace = Directory('${root.path}/ws')..createSync(recursive: true);
    paths = TreePaths(root.path);
    paths.ensureLayoutSync();
    todos = FileTodoStore(paths);
  });

  tearDown(() async {
    await server.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('GET todos：默认空集；按 session_id 隔离', () async {
    await start(<List<LlmStreamEvent>>[]);
    final Map<String, dynamic> empty = await getJson(
      '/api/agents/$agentId/todos?session_id=session_default',
    );
    expect(empty['todos'], isEmpty);
    expect(empty['session_id'], 'session_default');
    expect((await getJson('/api/agents/$agentId/todos'))['todos'], isEmpty);

    todos.write('agt_x', 'ses_other', <TodoItem>[
      const TodoItem(id: 't1', content: '别的会话'),
    ]);
    expect(
      (await getJson(
        '/api/agents/$agentId/todos?session_id=ses_other',
      ))['todos'],
      isEmpty,
      reason: '会话文件按 (agent, session) 隔离',
    );
  });

  test('未知 agent 的 todos 返回 404', () async {
    await start(<List<LlmStreamEvent>>[]);
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.getUrl(
        Uri.parse('${server.handshake.httpBaseUrl}/api/agents/nope/todos'),
      );
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${server.token}',
      );
      final HttpClientResponse response = await request.close();
      await utf8.decoder.bind(response).join();
      expect(response.statusCode, 404);
    } finally {
      client.close(force: true);
    }
  });

  test('模型调用 set_todo_list → API 读回前端口径条目 → 落盘文件可手改', () async {
    final FakeTransport transport = await start(<List<LlmStreamEvent>>[
      toolCallScript(
        name: 'set_todo_list',
        arguments: '{"action":"set","todos":[{"content":"实现登录"},{"content":"写测试","status":"in_progress","progress":30}]}',
      ),
      textScript('已排好待办'),
    ]);
    expect(transport.requests, isEmpty, reason: '尚未发消息前不应有请求');

    final TestWs ws = await TestWs.connect(server);
    ws.record();
    addTearDown(ws.close);
    ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': agentId,
      'content': '帮我排一下待办',
      'session_id': TreeStore.defaultSessionId,
    });
    await waitIdle(ws);

    final Map<String, dynamic> toolStart = ws.frames.firstWhere(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.toolStart,
    );
    expect(toolStart['name'], 'set_todo_list');

    final Map<String, dynamic> payload = await getJson(
      '/api/agents/$agentId/todos?session_id=session_default',
    );
    final List<dynamic> items = payload['todos'] as List<dynamic>;
    expect(items, hasLength(2));
    final Map<String, dynamic> first = items.first as Map<String, dynamic>;
    expect(first['content'], '实现登录');
    expect(first['status'], 'pending');
    expect(first['progress'], 0);
    expect(first['updated_at'], isA<int>());
    expect((items[1] as Map<String, dynamic>)['status'], 'in_progress');
    expect((items[1] as Map<String, dynamic>)['progress'], 30);

    final File file = File(paths.todoFile(agentId, TreeStore.defaultSessionId));
    expect(file.existsSync(), isTrue);
    final String markdown = file.readAsStringSync();
    expect(markdown, contains('- [ ] t1 | status=pending progress=0 | 实现登录'));
    expect(
      markdown,
      contains('- [~] t2 | status=in_progress progress=30 | 写测试'),
    );

    file.writeAsStringSync(
      '- [ ] t1 | status=completed progress=100 | 我手动改成了完成\n',
    );
    final Map<String, dynamic> afterEdit = await getJson(
      '/api/agents/$agentId/todos?session_id=session_default',
    );
    final Map<String, dynamic> edited =
        (afterEdit['todos'] as List<dynamic>).single as Map<String, dynamic>;
    expect(edited['content'], '我手动改成了完成');
    expect(edited['status'], 'completed');
    expect(edited['progress'], 100);
  });
}
