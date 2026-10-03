import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

class _Client {
  _Client(this._server) : _http = HttpClient();

  final CoreServer _server;
  final HttpClient _http;

  Future<_Res> send(String method, String path) async {
    final HttpClientRequest request = await _http.openUrl(
      method,
      Uri.parse('${_server.handshake.httpBaseUrl}$path'),
    );
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${_server.token}',
    );
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

/// `GET /api/agents/{agentId}/subagents`：会话级临时员工名册（**落盘那份**，只读）。
///
/// 这条接口存在的理由（用户 2026-10-03）：「进入某个临时成员的选项经常会无端变化」
/// ——入口以前只能从"当前已加载的消息窗口"里猜，消息被淘汰（不变量 19 只缓存视口附近）
/// 就凭空消失。名册本身**早就落盘**（`data/<agentId>/<sessionId>/subagents.json`），
/// 这里只是把它原样、**按会话**读出来；「跨会话不保留」照旧是硬不变量。
void main() {
  late CoreServer server;
  late _Client client;
  late MemoryStore store;
  late CoreSettings settings;
  late CoreAgent owner;

  setUp(() async {
    store = MemoryStore();
    settings = CoreSettings();
    server = await CoreServer.start(
      store: store,
      settings: settings,
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
    );
    owner = store.createAgent(name: '队长', modelId: 'demo');
    client = _Client(server);
  });

  tearDown(() async {
    client.close();
    await server.close();
  });

  void seed(
    String sessionId, {
    String id = 'sub_a',
    String name = '甲',
    String parentId = '',
    int level = 1,
  }) {
    store.putSubagent(
      CoreSubagent(
        id: id,
        name: name,
        ownerAgentId: owner.id,
        sessionId: sessionId,
        parentId: parentId,
        level: level,
        agent: store.createAgent(name: name, modelId: 'demo'),
        createdAt: 100,
        updatedAt: 200,
      ),
    );
  }

  test('只读该会话的落盘名册：字段 / total / 缺省会话口径', () async {
    const String session = TreeStore.defaultSessionId;
    seed(session);
    final _Res res = await client.send(
      'GET',
      '/api/agents/${owner.id}/subagents?session_id=$session',
    );
    expect(res.status, 200);
    expect(res.json['agent_id'], owner.id);
    expect(res.json['session_id'], session);
    expect(res.json['total'], 1);
    final Map<String, dynamic> one =
        ((res.json['subagents'] as List<dynamic>).single as Map)
            .cast<String, dynamic>();
    expect(one['id'], 'sub_a');
    expect(one['name'], '甲');
    expect(one['owner_agent_id'], owner.id);
    expect(one['session_id'], session);
    expect(one['parent_id'], '');
    expect(one['level'], 1);
    expect(one['run_count'], 0);
    expect(
      one.containsKey('agent'),
      isFalse,
      reason: '名册接口不发运行配置快照（那是 subagents.json 的内部形态）',
    );

    // 不带 session_id：与邻居同口径，落到默认会话
    final _Res noQuery = await client.send(
      'GET',
      '/api/agents/${owner.id}/subagents',
    );
    expect(noQuery.json['session_id'], TreeStore.defaultSessionId);
    expect(noQuery.json['total'], 1);
  });

  test('跨会话不保留：查别的会话只得到它自己那一份（空表）', () async {
    seed(TreeStore.defaultSessionId);
    final CoreSession other = store.createSession(
      owner.id,
      title: '另一个会话',
    )!;
    final _Res res = await client.send(
      'GET',
      '/api/agents/${owner.id}/subagents?session_id=${other.sessionId}',
    );
    expect(res.status, 200);
    expect(res.json['total'], 0);
    expect(res.json['subagents'], isEmpty);
  });

  test('删会话即消失：名册随会话走，不残留到任何全局位置', () async {
    final CoreSession other = store.createSession(owner.id, title: '临时会话')!;
    seed(other.sessionId);
    expect(
      (await client.send(
        'GET',
        '/api/agents/${owner.id}/subagents?session_id=${other.sessionId}',
      )).json['total'],
      1,
    );
    expect(store.deleteSession(owner.id, other.sessionId), isTrue);
    expect(
      (await client.send(
        'GET',
        '/api/agents/${owner.id}/subagents?session_id=${other.sessionId}',
      )).json['total'],
      0,
    );
  });

  test('agent 不存在 ⇒ 404 + 可读原因（不静默回空表）', () async {
    final _Res res = await client.send(
      'GET',
      '/api/agents/agt_missing/subagents',
    );
    expect(res.status, 404);
    expect(res.json['detail'], contains('agent 不存在'));
  });
}
