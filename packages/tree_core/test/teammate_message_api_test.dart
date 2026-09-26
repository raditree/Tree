import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
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

/// 用户→成员消息（REST）与成员活动日志（REST）。
void main() {
  late CoreServer server;
  late _Client client;
  late MemoryStore store;
  late CoreSettings settings;
  late TeamService teams;
  late Directory temp;
  late CoreAgent top;
  late List<String> delivered;
  late TeamMessageDispatcher dispatcher;

  setUp(() async {
    store = MemoryStore();
    settings = CoreSettings();
    settings.createModel(<String, dynamic>{
      'model_id': 'demo',
      'base_url': 'https://api.example.com/v1',
      'api_key': 'sk-test',
    });
    teams = TeamService(store: store, settings: settings);
    temp = Directory.systemTemp.createTempSync('tree_tmsg_');
    delivered = <String>[];
    dispatcher = TeamMessageDispatcher(
      store: store,
      teams: teams,
      deliver:
          ({
            required String agentId,
            required String sessionId,
            required String content,
            String senderId = '',
            String senderName = '',
          }) async {
            delivered.add('$agentId::$content');
          },
      workspaceDirOf: (String id) => p.join(temp.path, id),
    );
    server = await CoreServer.start(
      store: store,
      settings: settings,
      teamService: teams,
      messageDispatcher: dispatcher,
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
    );
    top = store.createAgent(name: '队长', modelId: 'demo');
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

  String member() =>
      teams.createMember(top.id, <String, dynamic>{
            'action': 'create_member',
            'member_name': '成员甲',
          })['member_id']
          as String;

  void approve(String id) => teams.assignModel(
    topId: top.id,
    memberId: id,
    body: <String, dynamic>{'model_id': 'demo', 'review_status': 'approved'},
  );

  test(
    'POST message：未就绪 → success:false + detail；就绪 → success:true 并投递',
    () async {
      final String id = member();
      final _Res blocked = await client.send(
        'POST',
        '/api/agents/${top.id}/teammate/$id/message',
        body: <String, dynamic>{'content': '帮个忙'},
      );
      expect(blocked.status, 200);
      expect(blocked.json['success'], isFalse);
      expect(blocked.json['error'], contains('投递失败'));
      expect(delivered, isEmpty);

      approve(id);
      final _Res ok = await client.send(
        'POST',
        '/api/agents/${top.id}/teammate/$id/message',
        body: <String, dynamic>{'content': '帮个忙', 'session_id': 'ses_x'},
      );
      expect(ok.status, 200);
      expect(ok.json['success'], isTrue);
      expect(delivered.single, '$id::帮个忙');
    },
  );

  test('POST message：缺 content / 未知成员都有可读反馈', () async {
    final String id = member();
    final _Res empty = await client.send(
      'POST',
      '/api/agents/${top.id}/teammate/$id/message',
      body: <String, dynamic>{'content': '   '},
    );
    expect(empty.json['success'], isFalse);
    expect(empty.json['error'], '缺少 content');

    final _Res unknown = await client.send(
      'POST',
      '/api/agents/${top.id}/teammate/nope/message',
      body: <String, dynamic>{'content': 'x'},
    );
    expect(unknown.json['success'], isFalse);
    expect(unknown.json['error'], contains('成员不存在'));
  });

  test('GET log：返回成员活动日志尾部（blocked 与 start 都看得见）', () async {
    final String id = member();
    await client.send(
      'POST',
      '/api/agents/${top.id}/teammate/$id/message',
      body: <String, dynamic>{'content': '先试一次'},
    );
    approve(id);
    await client.send(
      'POST',
      '/api/agents/${top.id}/teammate/$id/message',
      body: <String, dynamic>{'content': '再来一次'},
    );
    final _Res log = await client.send(
      'GET',
      '/api/agents/$id/teammate/$id/log?lines=50',
    );
    expect(log.status, 200);
    expect(log.json['success'], isTrue);
    final String text = log.json['log'] as String;
    expect(text, contains('[blocked]'));
    expect(text, contains('[start(成员)]'));
    expect(log.json['path'], contains('activity.log'));
  });
}
