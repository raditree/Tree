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

/// 可控引擎：启动后一直转，直到被取消（用来固定「正在运行」这条闸门）。
class _GatedEngine implements AgentEngine {
  final List<String> started = <String>[];

  @override
  Stream<AgentEvent> run(
    AgentRunContext context, {
    required bool Function() isCancelled,
  }) async* {
    started.add(context.agentId);
    yield const AgentText('开始');
    while (!isCancelled()) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    yield const AgentDone(cancelled: true);
  }

  @override
  Future<void> close() async {}
}

Future<void> _until(bool Function() ready, {int ms = 2000}) async {
  final DateTime limit = DateTime.now().add(Duration(milliseconds: ms));
  while (!ready()) {
    if (DateTime.now().isAfter(limit)) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late MemoryStore store;
  late MemoryQuestionStore questions;
  late QuestionBroker broker;
  late TeamService teams;
  late CoreServer server;
  late _Client client;
  late _GatedEngine engine;
  late CoreAgent top;

  setUp(() async {
    store = MemoryStore();
    questions = MemoryQuestionStore();
    broker = QuestionBroker(
      questions: questions,
      transcript: store,
      broadcast: (Map<String, dynamic> _) {},
      pollInterval: const Duration(milliseconds: 10),
    );
    teams = TeamService(store: store, settings: CoreSettings());
    engine = _GatedEngine();
    server = await CoreServer.start(
      store: store,
      questions: broker,
      teamService: teams,
      engine: engine,
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
    );
    client = _Client(server);
    top = store.createAgent(name: '队长', modelId: '', maxLevel: 3, maxMembersPerLevel: 7);
  });

  tearDown(() async {
    client.close();
    await server.close();
  });

  Map<String, dynamic> create(String name, [String parent = '']) =>
      teams.createMember(parent.isEmpty ? top.id : parent, <String, dynamic>{
        'action': 'create_member',
        'member_name': name,
      });

  group('删除闸门：下级', () {
    test('有下级不删：409 列出下级，且什么都没动', () async {
      final String leader = create('组长')['member_id'] as String;
      final String kid = create('组员', leader)['member_id'] as String;
      final _Res res = await client.send('DELETE', '/api/agents/$leader');
      expect(res.status, 409);
      expect(res.json['error'], contains('下级'));
      final List<dynamic> required = res.json['cascade_required'] as List<dynamic>;
      expect(required, hasLength(1));
      final Map<String, dynamic> row = required.single as Map<String, dynamic>;
      expect(row['member_id'], kid);
      expect(row['name'], '组员');
      expect(row['level'], 2);
      expect(row['parent_agent_id'], leader);
      expect(res.json['hint'], contains('cascade'));
      expect(store.agent(leader), isNotNull, reason: '拒绝时不得删任何东西');
      expect(store.agent(kid), isNotNull, reason: '拒绝时不得删任何东西');
    });

    test('cascade=1：连整棵子树一起删（叶→根），计数回填到 TOP', () async {
      final String leader = create('组长')['member_id'] as String;
      final String kid = create('组员', leader)['member_id'] as String;
      final String peer = create('其他成员')['member_id'] as String;
      expect(store.agent(top.id)!.teamMemberCount, 3);
      final _Res res = await client.send(
        'DELETE',
        '/api/agents/$leader?cascade=1',
      );
      expect(res.status, 200);
      expect(res.json['removed'], <String>[kid, leader], reason: '叶先于根');
      expect(store.agent(leader), isNull);
      expect(store.agent(kid), isNull);
      expect(store.agent(peer), isNotNull, reason: '不连带平级');
      expect(
        store.agent(top.id)!.teamMemberCount,
        1,
        reason: '用户侧删除同样要回填 member_count',
      );
    });

    test('删 TOP：无 cascade 也被拦（整队成员都会成孤儿）', () async {
      create('成员甲');
      final _Res blocked = await client.send('DELETE', '/api/agents/${top.id}');
      expect(blocked.status, 409);
      expect(store.agent(top.id), isNotNull);
      final _Res ok = await client.send(
        'DELETE',
        '/api/agents/${top.id}?cascade=true',
      );
      expect(ok.status, 200);
      expect(store.teams(), isEmpty);
    });
  });

  group('删除闸门：正在运行', () {
    test('运行中拒绝（409 + running），停止并空闲后才删得掉', () async {
      final CoreAgent member = store.agent(create('成员甲')['member_id'] as String)!;
      // 有意不 await：这轮会一直跑（闸门引擎），await 就成了"等它跑完"
      unawaited(
        server.conversation.handleUserMessage(<String, dynamic>{
          'agent_id': member.id,
          'content': '干活',
          'session_id': TreeStore.defaultSessionId,
        }),
      );
      await _until(() => server.conversation.isRunning(member.id));
      expect(server.conversation.isRunning(member.id), isTrue);

      final _Res busy = await client.send('DELETE', '/api/agents/${member.id}');
      expect(busy.status, 409);
      expect(busy.json['error'], contains('正在运行'));
      expect(busy.json['running'], <String>[member.id]);
      expect(busy.json['hint'], contains('停止'));
      expect(store.agent(member.id), isNotNull, reason: '拒绝时不得删');

      // 「停止」（标题栏那颗按钮走的就是这条）→ 等它收敛 → 再删
      server.conversation.cancelAgent(member.id);
      await _until(() => !server.conversation.isRunning(member.id));
      final _Res ok = await client.send('DELETE', '/api/agents/${member.id}');
      expect(ok.status, 200);
      expect(store.agent(member.id), isNull);
    });

    test('cascade 时下级正在运行也拦（整棵子树都要空闲）', () async {
      final String leader = create('组长')['member_id'] as String;
      final CoreAgent kid = store.agent(create('组员', leader)['member_id'] as String)!;
      unawaited(
        server.conversation.handleUserMessage(<String, dynamic>{
          'agent_id': kid.id,
          'content': '干活',
          'session_id': TreeStore.defaultSessionId,
        }),
      );
      await _until(() => server.conversation.isRunning(kid.id));
      final _Res res = await client.send(
        'DELETE',
        '/api/agents/$leader?cascade=1',
      );
      expect(res.status, 409);
      expect(res.json['running'], <String>[kid.id]);
      expect(store.agent(leader), isNotNull);
      server.conversation.cancelAgent(kid.id);
      await _until(() => !server.conversation.isRunning(kid.id));
    });
  });

  test('删除时先收尾在途提问（记录被摘掉也不会让那一轮永远挂着）', () async {
    final CoreAgent member = store.agent(create('成员甲')['member_id'] as String)!;
    bool done = false;
    bool cancelled = false;
    unawaited(
      broker
          .ask(
            AskQuestionRequest(
              agentId: member.id,
              sessionId: TreeStore.defaultSessionId,
              question: '选哪个？',
              isCancelled: () => false,
            ),
          )
          .then((QuestionOutcome outcome) {
            done = true;
            cancelled = outcome.cancelled;
          }),
    );
    await _until(() => broker.inFlightCount == 1);
    expect(broker.inFlightCount, 1);

    final _Res res = await client.send('DELETE', '/api/agents/${member.id}');
    expect(res.status, 200);
    expect(res.json['questions_removed'], 1);
    expect(broker.inFlightCount, 0, reason: '在途等待必须被收尾');
    expect(done, isTrue);
    expect(cancelled, isTrue);
    expect(questions.list(), isEmpty);
  });

  test('删除后不留会话数据目录（先排水再删）', () async {
    final Directory temp = Directory.systemTemp.createTempSync('agent_delete');
    addTearDown(() {
      try {
        temp.deleteSync(recursive: true);
      } catch (_) {}
    });
    final TreePaths paths = TreePaths(temp.path);
    await paths.ensureLayout();
    final FileTreeStore fileStore = FileTreeStore(paths);
    final CoreServer fileServer = await CoreServer.start(
      store: fileStore,
      teamService: TeamService(store: fileStore, settings: CoreSettings()),
      engine: _GatedEngine(),
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
    );
    final _Client fileClient = _Client(fileServer);
    addTearDown(() async {
      fileClient.close();
      await fileServer.close();
    });
    final CoreAgent agent = fileStore.createAgent(name: '临时');
    fileStore.appendMessage(
      CoreMessage(
        id: CoreIds.message(),
        agentId: agent.id,
        sessionId: TreeStore.defaultSessionId,
        role: 'user',
        content: '你好',
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    await fileStore.flush();
    expect(File(paths.agentFile(agent.id)).existsSync(), isTrue);
    expect(Directory(paths.agentDataDir(agent.id)).existsSync(), isTrue);

    final _Res res = await fileClient.send('DELETE', '/api/agents/${agent.id}');
    expect(res.status, 200);
    expect(File(paths.agentFile(agent.id)).existsSync(), isFalse);
    expect(Directory(paths.agentDataDir(agent.id)).existsSync(), isFalse);
    expect(fileStore.agent(agent.id), isNull);
  });
}
