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
        'thinking': true,
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
    // 回传思考：三态覆盖（true / false / null=清除），effective 给出生效值
    expect((member0['overrides'] as Map<String, dynamic>)['thinking'], isTrue);
    expect((member0['effective'] as Map<String, dynamic>)['thinking'], isTrue);
    expect(store.agent(member)!.thinkingOverride, isTrue);

    final _Res off = await client.send(
      'PATCH',
      '/api/agents/${top.id}/teammate/$member',
      body: <String, dynamic>{'thinking': false},
    );
    expect(off.status, 200);
    expect(
      ((off.json['member'] as Map<String, dynamic>)['effective']
          as Map<String, dynamic>)['thinking'],
      isFalse,
      reason: '显式关掉要能压过模型的 thinking',
    );

    final _Res cleared = await client.send(
      'PATCH',
      '/api/agents/${top.id}/teammate/$member',
      body: <String, dynamic>{'thinking': null},
    );
    expect(cleared.status, 200);
    expect(
      ((cleared.json['member'] as Map<String, dynamic>)['overrides']
              as Map<String, dynamic>)
          .containsKey('thinking'),
      isFalse,
      reason: 'null = 清除覆盖，不是"关掉"',
    );
    expect(store.agent(member)!.thinkingOverride, isNull);

    expect(
      (await client.send(
        'PATCH',
        '/api/agents/${top.id}/teammate/$member',
        body: <String, dynamic>{'thinking': 'maybe'},
      )).status,
      400,
      reason: '非法取值显式拒绝',
    );
  });

  group('成员面板只列「自己的下属」：不列自己、不列兄弟、不列上级', () {
    test('成员看自己的面板：名单为空 + pending 0 + self 如实标注', () async {
      final String leader = createMember('甲');
      createMember('乙');
      final _Res res = await client.send(
        'GET',
        '/api/agents/$leader/teammates',
      );
      expect(res.status, 200);
      expect(
        res.json['members'],
        isEmpty,
        reason: '成员不是「自己的成员」；以前这里回的是整队（含它自己，用户 2026-10-03 报的）',
      );
      expect(res.json['pending_member_count'], 0);
      final Map<String, dynamic> self =
          res.json['self'] as Map<String, dynamic>;
      expect(self['id'], leader);
      expect(self['name'], '甲');
      expect(self['is_member'], isTrue, reason: '根卡片要能如实说「这是成员」');
      expect(self['level'], 1);
      expect(self['top_agent_id'], top.id);
      expect(self['top_agent_name'], '队长');
    });

    test('成员带自己的下级：只列那个下级（不含自己、兄弟、上级）', () async {
      final String leader = createMember('甲');
      createMember('乙');
      final String grand =
          teams.createMember(leader, <String, dynamic>{
                'action': 'create_member',
                'member_name': '丙',
              })['member_id']
              as String;
      final _Res res = await client.send(
        'GET',
        '/api/agents/$leader/teammates',
      );
      final List<dynamic> members = res.json['members'] as List<dynamic>;
      expect(members, hasLength(1), reason: '只有它自己的下属');
      expect((members.single as Map<String, dynamic>)['id'], grand);
    });

    test('TOP 视角逐字不变：整队 + self 是 Level 0（顺序不断言，见下）', () async {
      final String a = createMember('甲');
      final String b = createMember('乙');
      final _Res res = await client.send(
        'GET',
        '/api/agents/${top.id}/teammates',
      );
      // 顺序不断言：同一毫秒创建的两个成员在 `members()` 里本来就是平局
      // （谁在前按 id 决定），这里只钉「TOP 拿到的是整队」这半句。
      final List<String> ids = (res.json['members'] as List<dynamic>)
          .map((dynamic e) => (e as Map<String, dynamic>)['id'] as String)
          .toList();
      expect(ids, hasLength(2));
      expect(ids, containsAll(<String>[a, b]));
      final Map<String, dynamic> self =
          res.json['self'] as Map<String, dynamic>;
      expect(self['is_member'], isFalse);
      expect(self['level'], 0);
      expect(self['top_agent_id'], '');
      expect(self['top_agent_name'], '');
    });

    test('两个入口同口径：list_members 里自己只有 team_leader 一行，teammates 里根本不出现',
        () async {
      final String leader = createMember('甲');
      final List<dynamic> toolMembers =
          teams.listMembers(leader)['members'] as List<dynamic>;
      expect(
        toolMembers.where(
          (dynamic e) => (e as Map<String, dynamic>)['id'] == leader,
        ),
        hasLength(1),
        reason: '自己是 team_leader 那一行，且只有一行（重复出现是旧 bug）',
      );
      final _Res res = await client.send(
        'GET',
        '/api/agents/$leader/teammates',
      );
      expect(
        (res.json['members'] as List<dynamic>).where(
          (dynamic e) => (e as Map<String, dynamic>)['id'] == leader,
        ),
        isEmpty,
      );
    });
  });
}
