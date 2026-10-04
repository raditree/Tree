import 'dart:async';
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

/// 提问的 REST 面（右侧「问题回复」页）与历史叠加语义。
void main() {
  late CoreServer server;
  late _Client client;
  late MemoryStore store;
  late MemoryQuestionStore questions;
  late QuestionBroker broker;
  late CoreAgent agent;

  const String sessionId = TreeStore.defaultSessionId;

  setUp(() async {
    store = MemoryStore();
    questions = MemoryQuestionStore();
    broker = QuestionBroker(
      questions: questions,
      transcript: store,
      broadcast: (Map<String, dynamic> _) {},
    );
    server = await CoreServer.start(
      store: store,
      questions: broker,
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
    );
    agent = store.createAgent(name: '提问用例');
    client = _Client(server);
  });

  tearDown(() async {
    client.close();
    await server.close();
  });

  Future<QuestionRecord> ask(
    String question, {
    List<AskedQuestion>? asked,
  }) async {
    // 有意不 await：提问的"等待"本身就是被测行为（在途 future 由作答/关停收尾）。
    unawaited(
      broker.ask(
        AskQuestionRequest(
          agentId: agent.id,
          sessionId: sessionId,
          questions:
              asked ??
              <AskedQuestion>[
                AskedQuestion(question: question, options: const <String>['A', 'B']),
              ],
          isCancelled: () => false,
        ),
      ),
    );
    return questions.list().last;
  }

  test('GET /api/questions：字段与前端一致，支持 session 过滤', () async {
    final QuestionRecord first = await ask('第一个问题');
    await ask('第二个问题');

    final _Res res = await client.send('GET', '/api/questions');
    expect(res.status, 200);
    final List<dynamic> list = res.json['questions'] as List<dynamic>;
    expect(list, hasLength(2));
    expect(res.json['total'], 2);
    final Map<String, dynamic> newest = list.first as Map<String, dynamic>;
    expect(newest['question'], '第二个问题', reason: '最新的排前面');
    final Map<String, dynamic> older = list.last as Map<String, dynamic>;
    expect(older['qid'], first.qid);
    expect(older['agent_id'], agent.id);
    expect(older['session_id'], sessionId);
    expect(older['options'], <String>['A', 'B']);
    expect(older['questions'], <Map<String, dynamic>>[
      <String, dynamic>{'question': '第一个问题', 'options': <String>['A', 'B']},
    ]);
    expect(older['answers'], <String>[''], reason: '待答：逐题答案为空串');
    expect(older['status'], 'pending');
    expect(older['created_at'], isA<int>());

    final _Res filtered = await client.send(
      'GET',
      '/api/questions?session_id=$sessionId&status=pending',
    );
    expect((filtered.json['questions'] as List<dynamic>), hasLength(2));
    final _Res none = await client.send(
      'GET',
      '/api/questions?status=answered',
    );
    expect(none.json['total'], 0);
  });

  test('POST /api/questions/{qid}/answer：与 WS 等价、幂等、未知 id 404', () async {
    final QuestionRecord record = await ask('继续吗？');
    final _Res ok = await client.send(
      'POST',
      '/api/questions/${record.qid}/answer',
      body: <String, dynamic>{
        'answers': <String>['继续'],
      },
    );
    expect(ok.status, 200);
    expect(ok.json['success'], isTrue);
    expect(ok.json['qid'], record.qid);
    expect(ok.json['status'], 'answered');
    expect(ok.json['answers'], <String>['继续']);
    expect(questions.byId(record.qid)?.answer, '继续');

    // 第二次作答：幂等闸门，必须明确报错而不是假装成功
    final _Res twice = await client.send(
      'POST',
      '/api/questions/${record.qid}/answer',
      body: <String, dynamic>{
        'answers': <String>['再改一次'],
      },
    );
    expect(twice.status, 400);
    expect(jsonEncode(twice.json), contains('没有等待回答的问题'));
    expect(questions.byId(record.qid)?.answer, '继续');

    final _Res unknown = await client.send(
      'POST',
      '/api/questions/q_none/answer',
      body: <String, dynamic>{'answers': <String>['x']},
    );
    expect(unknown.status, 404);
    expect(jsonEncode(unknown.json), contains('没有等待回答的问题'));
  });

  test('多问题：GET 带 questions；作答一次交齐（老前端只回 answer 也接受）', () async {
    final QuestionRecord record = await ask(
      '占位',
      asked: <AskedQuestion>[
        AskedQuestion(question: '部署到哪台？', options: <String>['A 机', 'B 机']),
        AskedQuestion(question: '要不要回滚预案？'),
      ],
    );
    final _Res listed = await client.send('GET', '/api/questions');
    final Map<String, dynamic> item =
        (listed.json['questions'] as List<dynamic>).first
            as Map<String, dynamic>;
    expect((item['questions'] as List<dynamic>).length, 2);
    expect(item['question'], '部署到哪台？', reason: '兼容读法 = 第一问');

    final _Res ok = await client.send(
      'POST',
      '/api/questions/${record.qid}/answer',
      body: <String, dynamic>{
        'answers': <String>['B 机'],
      },
    );
    expect(ok.status, 200);
    expect(ok.json['answers'], <String>['B 机', ''], reason: '未答项按未作答补齐');
    expect(questions.byId(record.qid)?.answer, contains('（未作答）'));

    // 老前端（只回单个 answer）：等价于"第一问有答、其余未作答"
    final QuestionRecord legacy = await ask(
      '占位二',
      asked: <AskedQuestion>[
        AskedQuestion(question: '第一问'),
        AskedQuestion(question: '第二问'),
      ],
    );
    final _Res single = await client.send(
      'POST',
      '/api/questions/${legacy.qid}/answer',
      body: <String, dynamic>{'answer': '只答第一问'},
    );
    expect(single.status, 200);
    expect(questions.byId(legacy.qid)?.answers, <String>['只答第一问', '']);
  });

  test('会话历史：提问卡片的 answered/answer 由提问记录叠加（消息日志只追加）', () async {
    final QuestionRecord record = await ask('要不要继续？');
    final _Res before = await client.send(
      'GET',
      '/api/conversations/${agent.id}?session_id=$sessionId',
    );
    Map<String, dynamic> card = (before.json['messages'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .singleWhere(
          (Map<String, dynamic> m) => m['kind'] == 'ask_user_question',
        );
    expect(card['id'], record.qid);
    expect(card['answered'], isFalse);
    expect(card['options'], <String>['A', 'B']);
    expect(card['questions'], <Map<String, dynamic>>[
      <String, dynamic>{'question': '要不要继续？', 'options': <String>['A', 'B']},
    ]);

    broker.answer(record.qid, <String>['要']);
    final _Res after = await client.send(
      'GET',
      '/api/conversations/${agent.id}?session_id=$sessionId',
    );
    card = (after.json['messages'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .singleWhere(
          (Map<String, dynamic> m) => m['kind'] == 'ask_user_question',
        );
    expect(card['answered'], isTrue, reason: '叠加提问记录状态');
    expect(card['answer'], '要');
    expect(card['answers'], <String>['要']);
  });

  test('删除 agent 时清理其提问记录（避免右栏孤儿卡片）', () async {
    await ask('待清理');
    expect(questions.list(), hasLength(1));
    final _Res res = await client.send('DELETE', '/api/agents/${agent.id}');
    expect(res.status, 200);
    expect(res.json['questions_removed'], 1);
    expect(questions.list(), isEmpty);
  });
}
