import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 历史接口的**懒加载分页**（用户 2026-10-04：「会话太长时导入不能直接划到底部；
/// 长会话仅加载末尾一段」）。
///
/// 口径：
/// - 不传 limit = 老行为（整份返回，has_more=false）；
/// - limit=N = 取**末尾** N 条，has_more 表示还有更早的；
/// - before=<id> = 只取比这条更早的（前端拿"当前最老那条 id"往回翻页）；
/// - before 找不到（被清掉 / 换了会话）= 当从头开始，不静默返回整份。
void main() {
  late Directory temp;
  late MemoryStore store;
  late CoreServer server;
  late CoreAgent agent;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tree_history_page_');
    store = MemoryStore();
    final CoreSettings settings = CoreSettings();
    settings.putModel(CoreModelConfig(modelId: 'demo', name: 'demo'));
    server = await CoreServer.start(
      store: store,
      settings: settings,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
    );
    agent = store.createAgent(name: '队长', modelId: 'demo');
    // 用默认会话：查询串就是它（createSession 不带 id 会另建一个会话）
    final CoreSession session =
        store.createSession(agent.id, sessionId: TreeStore.defaultSessionId)!;
    for (int i = 0; i < 10; i++) {
      store.appendMessage(
        CoreMessage(
          id: 'm$i',
          agentId: agent.id,
          sessionId: session.sessionId,
          role: i.isEven ? 'user' : 'agent',
          content: '第 $i 条',
          timestamp: DateTime(2026, 1, 1, 12, 0, i).millisecondsSinceEpoch,
        ),
      );
    }
  });

  tearDown(() async {
    await server.close();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<Map<String, dynamic>> fetch({String query = ''}) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.getUrl(
        Uri.parse(
          '${server.handshake.httpBaseUrl}/api/conversations/${agent.id}'
          '?session_id=${TreeStore.defaultSessionId}$query',
        ),
      );
      // 核心的 REST 面要 token（与 questions_api_test 同一口径）
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${server.token}',
      );
      final HttpClientResponse response = await request.close();
      final String body = await response.transform(utf8.decoder).join();
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  List<String> idsOf(Map<String, dynamic> json) => (json['messages'] as List<dynamic>)
      .map((dynamic m) => (m as Map<String, dynamic>)['id'] as String)
      .toList();

  test('不传 limit：整份返回（老行为，has_more=false）', () async {
    final Map<String, dynamic> json = await fetch();
    expect(idsOf(json), hasLength(10));
    expect(json['has_more'], isFalse);
    expect(json['total'], 10);
  });

  test('limit=3：只取末尾三条，has_more=true', () async {
    final Map<String, dynamic> json = await fetch(query: '&limit=3');
    expect(idsOf(json), <String>['m7', 'm8', 'm9']);
    expect(json['has_more'], isTrue);
    expect(json['total'], 10, reason: '总数要如实给出来（前端显示/排障）');
  });

  test('before=m7&limit=3：取更早的那三条（往回翻页）', () async {
    final Map<String, dynamic> json = await fetch(query: '&before=m7&limit=3');
    expect(idsOf(json), <String>['m4', 'm5', 'm6']);
    expect(json['has_more'], isTrue);
  });

  test('翻到头：has_more=false（前端据此收起入口）', () async {
    final Map<String, dynamic> json = await fetch(query: '&before=m3&limit=3');
    expect(idsOf(json), <String>['m0', 'm1', 'm2']);
    expect(json['has_more'], isFalse);
  });

  test('before 找不到：当从头开始（不静默返回整份）', () async {
    final Map<String, dynamic> json =
        await fetch(query: '&before=m_不存在&limit=3');
    expect(idsOf(json), <String>['m7', 'm8', 'm9']);
    expect(json['has_more'], isTrue);
  });
}
