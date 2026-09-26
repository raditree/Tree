import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 极简 HTTP 客户端（带核心 token）。
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

/// 团队成员 REST：`GET teammates`（窗口数据）与 `PATCH teammate`（唯一的模型写入口）。
void main() {
  late CoreServer server;
  late _Client client;
  late MemoryStore store;
  late CoreSettings settings;
  late TeamService teams;
  late CoreAgent top;
  late CoreAgent other;

  setUp(() async {
    store = MemoryStore();
    settings = CoreSettings();
    settings.createModel(<String, dynamic>{
      'model_id': 'demo',
      'name': '演示模型',
      'base_url': 'https://api.example.com/v1',
      'api_key': 'sk-test',
      'max_seqlen': 64000,
      'max_output_tokens': 4096,
    });
    teams = TeamService(store: store, settings: settings);
    server = await CoreServer.start(
      store: store,
      settings: settings,
      teamService: teams,
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
    );
    top = store.createAgent(name: '队长', modelId: 'demo');
    other = store.createAgent(name: '别的队');
    client = _Client(server);
  });

  tearDown(() async {
    client.close();
    await server.close();
  });

  String createMember([String name = '成员甲']) =>
      teams.createMember(top.id, <String, dynamic>{
            'action': 'create_member',
            'member_name': name,
          })['member_id']
          as String;

  test('GET teammates：members + pending_member_count + live_status', () async {
    final String member = createMember();
    final _Res res = await client.send(
      'GET',
      '/api/agents/${top.id}/teammates',
    );
    expect(res.status, 200);
    expect(res.json['agent_id'], top.id);
    expect(res.json['pending_member_count'], 1);
    final List<dynamic> members = res.json['members'] as List<dynamic>;
    expect(members, hasLength(1));
    final Map<String, dynamic> view = members.single as Map<String, dynamic>;
    expect(view['id'], member);
    expect(view['review_status'], ReviewStatus.pendingModel);
    expect(view['live_status'], 'idle');
    expect(view['overrides'], <String, dynamic>{});
    expect(view.containsKey('system_prompt'), isFalse);
  });

  test('PATCH teammate：分配模型 → 可工作；非法输入 400、越权 404', () async {
    final String member = createMember();
    final _Res assigned = await client.send(
      'PATCH',
      '/api/agents/${top.id}/teammate/$member',
      body: <String, dynamic>{'model_id': 'demo'},
    );
    expect(assigned.status, 200);
    expect(assigned.json['success'], isTrue);
    final Map<String, dynamic> view =
        assigned.json['member'] as Map<String, dynamic>;
    expect(view['model_id'], 'demo');
    expect(view['review_status'], ReviewStatus.approved);
    expect((view['effective'] as Map<String, dynamic>)['max_seqlen'], 64000);
    expect(teams.reviewBlock(member), isNull, reason: '放行后可工作');

    // 只改审核状态
    final _Res rejected = await client.send(
      'PATCH',
      '/api/agents/${top.id}/teammate/$member',
      body: <String, dynamic>{'review_status': 'rejected'},
    );
    expect(rejected.status, 200);
    expect(teams.reviewBlock(member), contains('已被用户驳回'));

    // 空 body / 未知模型 / 非法状态 / 未知成员 / 别队的成员
    expect(
      (await client.send(
        'PATCH',
        '/api/agents/${top.id}/teammate/$member',
        body: <String, dynamic>{},
      )).status,
      400,
    );
    expect(
      (await client.send(
        'PATCH',
        '/api/agents/${top.id}/teammate/$member',
        body: <String, dynamic>{'model_id': '不存在'},
      )).status,
      400,
    );
    expect(
      (await client.send(
        'PATCH',
        '/api/agents/${top.id}/teammate/$member',
        body: <String, dynamic>{'review_status': 'x'},
      )).status,
      400,
    );
    expect(
      (await client.send(
        'PATCH',
        '/api/agents/${top.id}/teammate/nope',
        body: <String, dynamic>{'review_status': 'approved'},
      )).status,
      404,
    );
    expect(
      (await client.send(
        'PATCH',
        '/api/agents/${other.id}/teammate/$member',
        body: <String, dynamic>{'review_status': 'approved'},
      )).status,
      404,
      reason: '只能操作本团队的成员',
    );
  });

  test('PATCH 覆盖参数：max_seqlen 写入并出现在 effective/overrides', () async {
    final String member = createMember();
    final _Res res = await client.send(
      'PATCH',
      '/api/agents/${top.id}/teammate/$member',
      body: <String, dynamic>{
        'model_id': 'demo',
        'review_status': 'approved',
        'max_seqlen': 32000,
        'max_output_tokens': 2048,
        'reasoning_effort': 'high',
      },
    );
    expect(res.status, 200);
    final Map<String, dynamic> member0 =
        res.json['member'] as Map<String, dynamic>;
    expect((member0['overrides'] as Map<String, dynamic>)['max_seqlen'], 32000);
    expect(
      (member0['effective'] as Map<String, dynamic>)['max_output_tokens'],
      2048,
    );
    expect(store.agent(member)!.reasoningEffort, 'high');
  });
}
