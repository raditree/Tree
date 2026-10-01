import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

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

/// Spec 的 REST 面（左侧 Spec 面板）。
void main() {
  late CoreServer server;
  late _Client client;
  late MemoryStore store;
  late CoreSettings settings;
  late SpecService specs;
  late LocalWorkspaceIO io;
  late Directory temp;
  late CoreAgent agent;

  const String sessionId = TreeStore.defaultSessionId;

  setUp(() async {
    store = MemoryStore();
    settings = CoreSettings();
    temp = Directory.systemTemp.createTempSync('tree_spec_api_');
    io = LocalWorkspaceIO(temp.path);
    specs = SpecService(store: store);
    server = await CoreServer.start(
      store: store,
      settings: settings,
      specService: specs,
      specIoFor: (String _) async => io,
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
    );
    agent = store.createAgent(name: '队长');
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

  Future<String> createCustom() async {
    final Map<String, dynamic> created = await specs.run(
      ToolInvocation(
        id: 'spec',
        name: 'spec',
        arguments: <String, dynamic>{
          'action': 'create',
          'title': '数据库迁移规范',
          'workflow': '先备份',
        },
        agentId: agent.id,
        sessionId: sessionId,
      ),
      io,
    );
    return created['spec_id'] as String;
  }

  test('GET specs：内置 4 个在前 + 自定义 spec；selected_spec_ids 与 store 一致', () async {
    final String custom = await createCustom();
    final _Res res = await client.send(
      'GET',
      '/api/agents/${agent.id}/specs?session_id=$sessionId',
    );
    expect(res.status, 200);
    final List<dynamic> list = res.json['specs'] as List<dynamic>;
    expect(list, hasLength(5));
    expect((list.first as Map<String, dynamic>)['id'], 'general-task');
    expect((list.first as Map<String, dynamic>)['builtin'], isTrue);
    final Map<String, dynamic> customView = list.last as Map<String, dynamic>;
    expect(customView['id'], custom);
    expect(customView['builtin'], isFalse);
    expect(customView['task_type'], 'custom');
    expect(res.json['selected_spec_ids'], isEmpty);

    // 勾选（前端直接 set，不做"必须先 read"校验）
    final _Res saved = await client.send(
      'POST',
      '/api/agents/${agent.id}/sessions/$sessionId/specs',
      body: <String, dynamic>{
        'spec_ids': <String>['general-task', custom],
      },
    );
    expect(saved.status, 200);
    final _Res after = await client.send(
      'GET',
      '/api/agents/${agent.id}/specs?session_id=$sessionId',
    );
    expect(after.json['selected_spec_ids'], <String>['general-task', custom]);
  });

  test('GET spec 详情：内置与自定义都给 meta+全文；不存在 404', () async {
    final String custom = await createCustom();
    final _Res builtin = await client.send(
      'GET',
      '/api/agents/${agent.id}/specs/general-task',
    );
    expect(builtin.status, 200);
    expect((builtin.json['meta'] as Map<String, dynamic>)['builtin'], isTrue);
    expect(builtin.json['content'], kBuiltinSpecs['general-task']);

    final _Res mine = await client.send(
      'GET',
      '/api/agents/${agent.id}/specs/$custom',
    );
    expect(mine.status, 200);
    expect((mine.json['meta'] as Map<String, dynamic>)['id'], custom);
    expect(mine.json['content'], contains('先备份'));

    final _Res ghost = await client.send(
      'GET',
      '/api/agents/${agent.id}/specs/ghost',
    );
    expect(ghost.status, 404);
    expect(jsonEncode(ghost.json), contains('Spec 不存在'));
  });

  test('POST reset：备份 .bak.<n> 后清空自定义并还原内置 Spec', () async {
    final String custom = await createCustom();
    final _Res before = await client.send(
      'GET',
      '/api/agents/${agent.id}/specs?session_id=$sessionId',
    );
    expect((before.json['specs'] as List<dynamic>), hasLength(5));

    final _Res reset = await client.send(
      'POST',
      '/api/agents/${agent.id}/reset',
      body: <String, dynamic>{'target': 'spec'},
    );
    expect(reset.status, 200, reason: '${reset.status} ${reset.json}');
    final Map<String, dynamic> spec =
        reset.json['spec'] as Map<String, dynamic>;
    expect(spec['backup_index'], 1);
    expect(
      (spec['removed'] as List<dynamic>),
      contains('.self/spec/$custom.md'),
      reason: '自定义规范被清理',
    );
    // 旧文件可从备份找回
    expect(
      File('${temp.path}/.self/spec/$custom.md.bak.1').existsSync(),
      isTrue,
    );
    // 重置后只剩内置 4 个
    final _Res after = await client.send(
      'GET',
      '/api/agents/${agent.id}/specs?session_id=$sessionId',
    );
    final List<dynamic> specsAfter = after.json['specs'] as List<dynamic>;
    expect(specsAfter, hasLength(4));
    expect(
      specsAfter.map((dynamic e) => (e as Map<String, dynamic>)['id']).toSet(),
      kBuiltinSpecIds.toSet(),
    );
  });
}
