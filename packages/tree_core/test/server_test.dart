import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// 极简 HTTP 客户端：默认携带核心 token，返回状态码 + 解析后的 JSON。
class _Client {
  _Client(this._server) : _http = HttpClient();

  final CoreServer _server;
  final HttpClient _http;

  Future<_Res> send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    String? token,
    bool omitAuth = false,
  }) async {
    final HttpClientRequest request = await _http.openUrl(
      method,
      Uri.parse('${_server.handshake.httpBaseUrl}$path'),
    );
    if (!omitAuth) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${token ?? _server.token}',
      );
    }
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

  @override
  String toString() => 'HTTP $status $json';
}

/// WS 客户端 + 帧记录器（单次订阅、持续累积，避免 broadcast 流丢事件）。
class _WsClient {
  _WsClient._(this._socket, this._controller) {
    _subscription = _socket.listen(
      (dynamic data) {
        final Object? decoded = jsonDecode(data.toString());
        if (decoded is Map<String, dynamic>) _controller.add(decoded);
      },
      onDone: () => _controller.close(),
      onError: (Object _) => _controller.close(),
    );
  }

  static Future<_WsClient> connect(CoreServer server, {String? token}) async {
    final WebSocket socket = await WebSocket.connect(
      '${server.handshake.wsBaseUrl}${CoreServer.wsPath}'
      '?token=${token ?? server.token}',
    );
    return _WsClient._(
      socket,
      StreamController<Map<String, dynamic>>.broadcast(),
    );
  }

  final WebSocket _socket;
  final StreamController<Map<String, dynamic>> _controller;
  late final StreamSubscription<dynamic> _subscription;
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];

  void send(Map<String, dynamic> frame) => _socket.add(jsonEncode(frame));

  /// 记录后续到达的帧。
  void record() => _controller.stream.listen(frames.add);

  /// 轮询直到某个帧满足条件（比"订阅-发送-等待"更稳：不会漏帧）。
  Future<void> until(
    bool Function(Map<String, dynamic> frame) predicate, {
    Duration timeout = const Duration(seconds: 5),
    String? reason,
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (frames.any(predicate)) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw TimeoutException(
      '超时等待${reason ?? '帧'}；已收到：'
      '${frames.map((Map<String, dynamic> f) => f['type']).toList()}',
    );
  }

  /// 轮询直到某类型帧累计到 [count] 个。
  ///
  /// 必须用"累计计数"而非"是否存在"：同一用例里连发多轮消息时，
  /// `until` 会被上一轮已到达的帧立刻满足，从而漏等本轮完成。
  Future<void> untilCount(
    String type,
    int count, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (frames.where((Map<String, dynamic> f) => f['type'] == type).length >=
          count) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw TimeoutException('超时等待 $count 个 $type；已收到：${types()}');
  }

  List<String> types() => frames
      .map((Map<String, dynamic> f) => f['type'] as String? ?? '')
      .toList();

  Future<void> close() async {
    await _subscription.cancel();
    await _socket.close();
    if (!_controller.isClosed) await _controller.close();
  }
}

void main() {
  late CoreServer server;
  late _Client client;

  setUp(() async {
    // 20ms 片间延迟：既让"停止"测试有确定的取消窗口，又不拖慢整体用例
    server = await CoreServer.start(
      streamChunkDelay: const Duration(milliseconds: 20),
      enableHeartbeat: false,
    );
    client = _Client(server);
  });

  tearDown(() async {
    client.close();
    await server.close();
  });

  /// 建一个模型 + agent，返回 agent id。
  Future<String> seedAgent(String name) async {
    final _Res model = await client.send(
      'POST',
      ApiPaths.models,
      body: <String, dynamic>{
        'model_id': 'demo',
        'name': '演示模型',
        'base_url': 'https://api.example.com/v1',
        'api_key': 'sk-test',
      },
    );
    expect(model.status, 200, reason: '$model');
    final _Res agent = await client.send(
      'POST',
      ApiPaths.agents,
      body: <String, dynamic>{'name': name, 'model_id': 'demo'},
    );
    expect(agent.status, 200, reason: '$agent');
    return (agent.json['agent'] as Map<String, dynamic>)['id'] as String;
  }

  group('启动与握手', () {
    test('监听回环随机端口，且 token 具备足够熵', () async {
      expect(server.address.address, '127.0.0.1');
      expect(server.port, greaterThan(0));
      expect(server.handshake.httpBaseUrl, 'http://127.0.0.1:${server.port}');
      expect(server.handshake.wsBaseUrl, 'ws://127.0.0.1:${server.port}');
      expect(server.token.length, greaterThanOrEqualTo(42));
      expect(server.processId, pid);

      // 握手行必须能被协议包的解析器读回（前端父进程即按此解析）
      final CoreHandshake? decoded = CoreHandshake.decode(
        server.handshake.encode(),
      );
      expect(decoded, isNotNull);
      expect(decoded!.port, server.port);
      expect(decoded.token, server.token);
      expect(decoded.pid, pid);
    });

    test('两个实例端口互不冲突（内核分配）', () async {
      final CoreServer other = await CoreServer.start(
        streamChunkDelay: Duration.zero,
        enableHeartbeat: false,
      );
      expect(other.port, isNot(server.port));
      await other.close();
    });
  });

  group('本地 token 鉴权', () {
    test('缺 Authorization 头 -> 401', () async {
      final _Res res = await client.send(
        'GET',
        ApiPaths.agents,
        omitAuth: true,
      );
      expect(res.status, 401);
      expect(server.rejectedRequests, 1);
    });

    test('token 错误 -> 401；正确 -> 200', () async {
      expect(
        (await client.send('GET', ApiPaths.agents, token: 'bad')).status,
        401,
      );
      expect((await client.send('GET', ApiPaths.agents)).status, 200);
    });

    test('WS token 错误 -> 401（拒绝升级）', () async {
      final _Res res = await client.send(
        'GET',
        '${CoreServer.wsPath}?token=bad',
      );
      expect(res.status, 401);
    });
  });

  group('路由覆盖度不变量', () {
    test('保留路径 = 已实现 ∪ 显式 501 桩，且两组不相交', () {
      final Set<String> implemented = server.router.patterns;
      final Set<String> stubs = server.stubRouter.patterns;

      expect(
        implemented.intersection(stubs),
        isEmpty,
        reason: '同一路径不应既实现又声明为未实现',
      );
      expect(
        ApiPaths.kept.difference(implemented.union(stubs)),
        isEmpty,
        reason: '协议包声明保留的路径必须在核心进程登记',
      );
      expect(
        implemented.difference(ApiPaths.kept),
        isEmpty,
        reason: '核心进程不应实现协议包未声明的路径（含错别字）',
      );
      expect(stubs, CoreServer.stubApiPaths);
      expect(
        CoreServer.stubApiPaths.difference(ApiPaths.kept),
        isEmpty,
        reason: '501 桩只允许针对协议包声明保留的路径',
      );
      expect(
        stubs.intersection(ApiPaths.removedWithAccounts),
        isEmpty,
        reason: '账号体系路径在 desktop 分支已删除，不应登记',
      );
    });

    test('未知路径 -> 404；已登记的未实现路径 -> 501', () async {
      expect((await client.send('GET', '/api/nope')).status, 404);
      expect(server.notFoundRequests, 1);

      // 注意：`/api/files/*` 的读路径与 Git 路径已在 M7d 实现，这里改探仍未实现的
      // 写路径（上传），否则测的是"已实现路由"而不是"501 桩"。
      final _Res stub = await client.send('GET', '/api/files/ws_1/upload_init');
      expect(stub.status, 501);
      expect((stub.json['detail'] as String), contains('功能开发中'));
      expect(server.stubRequests, 1);

      // 桩对所有方法一致（POST/PATCH/DELETE 同样 501）
      expect(
        (await client.send('POST', '/api/files/ws_1/upload_init')).status,
        501,
      );
    });
  });

  group('模型池', () {
    test('新增/列表/更新/删除，密钥不回显', () async {
      expect(
        (await client.send(
          'POST',
          ApiPaths.models,
          body: <String, dynamic>{
            'model_id': 'demo',
            'base_url': 'https://api.example.com/v1',
            'api_key': 'sk-test',
          },
        )).status,
        200,
      );
      expect(
        (await client.send(
          'POST',
          ApiPaths.models,
          body: <String, dynamic>{
            'model_id': 'demo',
            'base_url': 'https://api.example.com/v1',
            'api_key': 'sk-test',
          },
        )).status,
        409,
      );
      expect(
        (await client.send(
          'POST',
          ApiPaths.models,
          body: <String, dynamic>{'model_id': 'no-key'},
        )).status,
        400,
      );

      final _Res list = await client.send('GET', ApiPaths.models);
      final List<dynamic> models = list.json['models'] as List<dynamic>;
      expect(models.length, 1);
      final Map<String, dynamic> model = (models.first as Map<String, dynamic>);
      expect(model.containsKey('api_key'), isFalse);
      expect(model['base_url'], 'https://api.example.com');

      expect(
        (await client.send(
          'PATCH',
          '/api/models/demo',
          body: <String, dynamic>{'name': '改名'},
        )).status,
        200,
      );
      expect((await client.send('DELETE', '/api/models/demo')).status, 200);
      expect((await client.send('DELETE', '/api/models/demo')).status, 404);
    });

    test('删除模型时回传仍绑定该模型的 agent（供前端提示）', () async {
      final String agentId = await seedAgent('绑定者');
      final _Res deleted = await client.send('DELETE', '/api/models/demo');
      expect(deleted.status, 200);
      expect(deleted.json['bound_agents'], contains(agentId));
    });
  });

  group('agent 与会话', () {
    test('创建时校验 name / model_id，且模型必须已存在', () async {
      expect(
        (await client.send(
          'POST',
          ApiPaths.agents,
          body: <String, dynamic>{'model_id': 'demo'},
        )).status,
        400,
      );
      expect(
        (await client.send(
          'POST',
          ApiPaths.agents,
          body: <String, dynamic>{'name': 'a'},
        )).status,
        400,
      );
      expect(
        (await client.send(
          'POST',
          ApiPaths.agents,
          body: <String, dynamic>{'name': 'a', 'model_id': 'missing'},
        )).status,
        400,
      );
    });

    test('列表返回前端 Agent 模型所需字段，并自动带兜底默认会话', () async {
      final String agentId = await seedAgent('列表用例');
      final _Res list = await client.send('GET', ApiPaths.agents);
      final Map<String, dynamic> agent =
          ((list.json['agents'] as List<dynamic>).first
              as Map<String, dynamic>);
      expect(agent['id'], agentId);
      expect(agent['name'], '列表用例');
      expect(agent['type'], 'normal');
      expect(agent['workspace_id'], isNotEmpty);
      expect(agent['pending_member_count'], 0);
      expect(agent['last_message'], '');
      expect(agent['last_message_time'], isNull);

      final _Res sessions = await client.send(
        'GET',
        '/api/agents/$agentId/sessions',
      );
      final List<dynamic> items = sessions.json['sessions'] as List<dynamic>;
      expect(items.length, 1);
      expect(
        (items.first as Map<String, dynamic>)['session_id'],
        TreeStore.defaultSessionId,
      );
      expect((items.first as Map<String, dynamic>)['message_count'], 0);
      expect((items.first as Map<String, dynamic>)['created_at'], isA<int>());
    });

    test('会话增删改与 specs 选择', () async {
      final String agentId = await seedAgent('会话用例');
      final _Res created = await client.send(
        'POST',
        '/api/agents/$agentId/sessions',
        body: <String, dynamic>{'title': '第二个'},
      );
      expect(created.status, 200);
      final String sessionId =
          (created.json['session'] as Map<String, dynamic>)['session_id']
              as String;
      expect(sessionId, isNot(TreeStore.defaultSessionId));

      expect(
        (await client.send(
          'GET',
          '/api/agents/$agentId/sessions',
        )).json['sessions'],
        hasLength(2),
      );
      expect(
        (await client.send(
          'PATCH',
          '/api/agents/$agentId/sessions/$sessionId',
          body: <String, dynamic>{'title': '改名后'},
        )).status,
        200,
      );
      expect(
        (await client.send(
          'GET',
          '/api/agents/$agentId/sessions/$sessionId',
        )).json['session'],
        containsPair('title', '改名后'),
      );
      expect(
        (await client.send(
          'POST',
          '/api/agents/$agentId/sessions/$sessionId/specs',
          body: <String, dynamic>{
            'spec_ids': <String>['spec_a'],
          },
        )).json['selected_spec_ids'],
        <String>['spec_a'],
      );
      expect(
        (await client.send(
          'GET',
          '/api/agents/$agentId/specs?session_id=$sessionId',
        )).json['selected_spec_ids'],
        <String>['spec_a'],
      );
      expect(
        (await client.send(
          'DELETE',
          '/api/agents/$agentId/sessions/$sessionId',
        )).status,
        200,
      );
      expect(
        (await client.send(
          'GET',
          '/api/agents/$agentId/sessions/$sessionId',
        )).status,
        404,
      );
      // 不存在的 agent 一律 404
      expect(
        (await client.send('GET', '/api/agents/agt_missing/sessions')).status,
        404,
      );
      expect((await client.send('GET', '/api/agents/agt_missing')).status, 404);
      expect(
        (await client.send('DELETE', '/api/agents/agt_missing')).status,
        404,
      );
    });

    test('models-info 同时给出 agent 当前绑定与模型池', () async {
      final String agentId = await seedAgent('模型信息');
      final _Res res = await client.send(
        'GET',
        '/api/agents/$agentId/models-info',
      );
      expect(res.status, 200);
      expect((res.json['agent'] as Map<String, dynamic>)['model_id'], 'demo');
      expect(res.json['models'], hasLength(1));
      expect(res.json['overrides'], isEmpty);
    });

    test('todos / teammates / questions 返回空集（M4/M5 前）', () async {
      final String agentId = await seedAgent('空集');
      expect(
        (await client.send('GET', '/api/agents/$agentId/todos')).json['todos'],
        isEmpty,
      );
      expect(
        (await client.send(
          'GET',
          '/api/agents/$agentId/teammates',
        )).json['members'],
        isEmpty,
      );
      expect(
        (await client.send('GET', ApiPaths.questions)).json['questions'],
        isEmpty,
      );
      final _Res snapshot = await client.send('GET', ApiPaths.pluginSnapshot);
      expect(snapshot.json['enabled'], isFalse);
      expect(
        (await client.send('GET', ApiPaths.mcpServices)).json['services'],
        isEmpty,
      );
    });
  });

  group('设置', () {
    test('帧率夹取、主动延迟、消息切入、数据收集开关', () async {
      final _Res initial = await client.send('GET', ApiPaths.settingsFrameRate);
      expect(initial.json['frame_rate'], CoreSettings.frameRateMin);
      expect(initial.json['min'], CoreSettings.frameRateMin);
      expect(initial.json['max'], CoreSettings.frameRateMax);

      final _Res set = await client.send(
        'POST',
        ApiPaths.settingsFrameRate,
        body: <String, dynamic>{'frame_rate': 99999},
      );
      expect(set.json['frame_rate'], CoreSettings.frameRateMax);

      await client.send(
        'POST',
        ApiPaths.settingsRateLimit,
        body: <String, dynamic>{'enabled': true},
      );
      expect(
        (await client.send('GET', ApiPaths.settingsRateLimit)).json['enabled'],
        isTrue,
      );

      await client.send(
        'POST',
        ApiPaths.settingsMessageCutin,
        body: <String, dynamic>{'mode': 'direct'},
      );
      expect(
        (await client.send('GET', ApiPaths.settingsMessageCutin)).json['mode'],
        'direct',
      );
      await client.send(
        'POST',
        ApiPaths.settingsMessageCutin,
        body: <String, dynamic>{'mode': 'queue'},
      );
      expect(
        (await client.send('GET', ApiPaths.settingsMessageCutin)).json['mode'],
        'queue',
      );

      expect(
        (await client.send(
          'POST',
          ApiPaths.settingsDataCollection,
          body: <String, dynamic>{'enabled': true},
        )).status,
        200,
      );
    });
  });

  group('WS 会话链路', () {
    test('user_message -> agent_status/msg_start/msg_chunk/msg_end 并按序落库', () async {
      final String agentId = await seedAgent('流式用例');
      final _WsClient ws = await _WsClient.connect(server);
      ws.record();
      addTearDown(ws.close);

      ws.send(<String, dynamic>{
        'type': WsInboundType.userMessage,
        'agent_id': agentId,
        'content': '你好，核心进程',
        'session_id': TreeStore.defaultSessionId,
      });
      await ws.until(
        (Map<String, dynamic> f) => f['type'] == WsOutboundType.msgEnd,
        reason: 'msg_end',
      );
      // 再等终止的 idle 帧：msg_end 到达不等于 idle 已到达（帧是异步过网的），
      // 不等就容易在负载高时把"最后一帧是 msg_end"读成断言失败
      await ws.until(
        (Map<String, dynamic> f) =>
            f['type'] == WsOutboundType.agentStatus &&
            ((f['data'] as Map<String, dynamic>?)?['status'] ?? '') == 'idle',
        reason: 'agent_status(idle)',
      );

      final List<String> types = ws.types();
      expect(types.first, WsOutboundType.agentStatus);
      expect(types[1], WsOutboundType.msgStart);
      expect(
        types.where((String t) => t == WsOutboundType.msgChunk).length,
        greaterThan(1),
      );
      expect(types.last, WsOutboundType.agentStatus);

      final Map<String, dynamic> start = ws.frames.firstWhere(
        (Map<String, dynamic> f) => f['type'] == WsOutboundType.msgStart,
      );
      expect(start['agent_id'], agentId);
      expect(start['session_id'], TreeStore.defaultSessionId);
      expect(start['kind'], 'text');
      final String messageId = start['id'] as String;
      expect(messageId, isNotEmpty);
      for (final Map<String, dynamic> chunk in ws.frames.where(
        (Map<String, dynamic> f) => f['type'] == WsOutboundType.msgChunk,
      )) {
        expect(chunk['id'], messageId);
      }
      final Map<String, dynamic> end = ws.frames.firstWhere(
        (Map<String, dynamic> f) => f['type'] == WsOutboundType.msgEnd,
      );
      expect(end['id'], messageId);
      expect(end['cancelled'], isFalse);
      final Map<String, dynamic> usage = end['usage'] as Map<String, dynamic>;
      expect(usage['total_tokens'], greaterThan(0));
      expect(usage['estimated'], isTrue);
      expect(usage['max_tokens'], 128000);

      // 状态帧内容
      final Map<String, dynamic> working = ws.frames.firstWhere(
        (Map<String, dynamic> f) =>
            f['type'] == WsOutboundType.agentStatus &&
            (f['data'] as Map<String, dynamic>)['status'] == 'working',
      );
      expect((working['data'] as Map<String, dynamic>)['agent_id'], agentId);

      // 流式内容拼接 = 落库正文（API 与 WS 两条路径必须一致）
      final String streamed = ws.frames
          .where(
            (Map<String, dynamic> f) => f['type'] == WsOutboundType.msgChunk,
          )
          .map((Map<String, dynamic> f) => f['chunk'] as String)
          .join();
      final _Res history = await client.send(
        'GET',
        '/api/conversations/$agentId?session_id=${TreeStore.defaultSessionId}',
      );
      final List<dynamic> messages = history.json['messages'] as List<dynamic>;
      expect(messages, hasLength(2));
      expect((messages[0] as Map<String, dynamic>)['role'], 'user');
      expect((messages[0] as Map<String, dynamic>)['content'], '你好，核心进程');
      expect((messages[1] as Map<String, dynamic>)['role'], 'agent');
      expect((messages[1] as Map<String, dynamic>)['content'], streamed);
      expect((messages[1] as Map<String, dynamic>)['id'], messageId);
      expect((messages[1] as Map<String, dynamic>)['timestamp'], isA<String>());

      // agent 列表的会话摘要也同步了
      final _Res sessions = await client.send(
        'GET',
        '/api/agents/$agentId/sessions',
      );
      expect(
        ((sessions.json['sessions'] as List<dynamic>).first
            as Map<String, dynamic>)['message_count'],
        2,
      );
      final _Res agents = await client.send('GET', ApiPaths.agents);
      final Map<String, dynamic> listed =
          (agents.json['agents'] as List<dynamic>).first
              as Map<String, dynamic>;
      expect(listed['last_message'], streamed);
      expect(listed['last_message_time'], isA<int>());
    });

    test('会话 id 为空时自动建会话并推送 session_created', () async {
      final String agentId = await seedAgent('自动建会话');
      final _WsClient ws = await _WsClient.connect(server);
      ws.record();
      addTearDown(ws.close);

      ws.send(<String, dynamic>{
        'type': WsInboundType.userMessage,
        'agent_id': agentId,
        // 内容 > 30 字符以触发标题截断（标题取前 30 字 + 省略号）
        'content': '首条消息标题会截断到这里为止吧' * 3,
      });
      await ws.until(
        (Map<String, dynamic> f) => f['type'] == WsOutboundType.msgEnd,
        reason: 'msg_end',
      );
      final Map<String, dynamic> created = ws.frames.firstWhere(
        (Map<String, dynamic> f) => f['type'] == WsOutboundType.sessionCreated,
      );
      final Map<String, dynamic> data = created['data'] as Map<String, dynamic>;
      expect(data['agent_id'], agentId);
      expect(data['session_id'], isNot(TreeStore.defaultSessionId));
      expect(data['title'], isA<String>());
      expect((data['title'] as String).endsWith('…'), isTrue);
      expect(
        (await client.send(
          'GET',
          '/api/agents/$agentId/sessions',
        )).json['sessions'],
        hasLength(2),
      );
    });

    test('stop 中断流式并回 cancelled=true + message 提示', () async {
      final String agentId = await seedAgent('停止用例');
      final _WsClient ws = await _WsClient.connect(server);
      ws.record();
      addTearDown(ws.close);

      ws.send(<String, dynamic>{
        'type': WsInboundType.userMessage,
        'agent_id': agentId,
        'content': '这条会被中途停止',
        'session_id': TreeStore.defaultSessionId,
      });
      await ws.until(
        (Map<String, dynamic> f) => f['type'] == WsOutboundType.msgChunk,
        reason: '首个 msg_chunk',
      );
      ws.send(<String, dynamic>{
        'type': WsInboundType.stop,
        'data': <String, dynamic>{
          'agent_id': agentId,
          'session_id': TreeStore.defaultSessionId,
        },
      });
      await ws.until(
        (Map<String, dynamic> f) => f['type'] == WsOutboundType.msgEnd,
        reason: 'msg_end',
      );
      // 同上：等 idle 帧到齐再断言"最后一帧是 agent_status"
      await ws.until(
        (Map<String, dynamic> f) =>
            f['type'] == WsOutboundType.agentStatus &&
            ((f['data'] as Map<String, dynamic>?)?['status'] ?? '') == 'idle',
        reason: 'agent_status(idle)',
      );
      final Map<String, dynamic> end = ws.frames.firstWhere(
        (Map<String, dynamic> f) => f['type'] == WsOutboundType.msgEnd,
      );
      expect(end['cancelled'], isTrue);
      final Map<String, dynamic> notice = ws.frames.firstWhere(
        (Map<String, dynamic> f) => f['type'] == WsOutboundType.message,
      );
      expect(notice['role'], 'agent');
      expect(notice['content'], contains('已停止'));
      expect(notice['agent_id'], agentId);
      expect(ws.frames.last['type'], WsOutboundType.agentStatus);
      // 中断后 agent 归闲，可以继续下一轮
      expect(server.conversation.activeRunCount, 0);
    });

    test('未知 agent 的 user_message 回 error 帧', () async {
      final _WsClient ws = await _WsClient.connect(server);
      ws.record();
      addTearDown(ws.close);
      ws.send(<String, dynamic>{
        'type': WsInboundType.userMessage,
        'agent_id': 'agt_missing',
        'content': 'x',
        'session_id': TreeStore.defaultSessionId,
      });
      await ws.until(
        (Map<String, dynamic> f) => f['type'] == WsOutboundType.error,
        reason: 'error',
      );
      final Map<String, dynamic> error = ws.frames.firstWhere(
        (Map<String, dynamic> f) => f['type'] == WsOutboundType.error,
      );
      expect(
        (error['data'] as Map<String, dynamic>)['message'],
        contains('未知 agent'),
      );
    });

    test('心跳帧即时回执（前端 30s 保活）', () async {
      final _WsClient ws = await _WsClient.connect(server);
      ws.record();
      addTearDown(ws.close);
      ws.send(<String, dynamic>{'type': WsInboundType.heartbeat});
      await ws.until(
        (Map<String, dynamic> f) => f['type'] == WsOutboundType.heartbeat,
        reason: 'heartbeat',
      );
    });

    test('已删除的反向执行帧被静默忽略（老前端不崩、正常帧照常处理）', () async {
      final _WsClient ws = await _WsClient.connect(server);
      ws.record();
      addTearDown(ws.close);
      // M7c 删除了"前端执行器"与反向执行通道：老版本前端若仍发这些帧，
      // 核心必须**静默忽略**（前向兼容），而不是崩溃或回错——它们描述的
      // 执行器已不存在，但协议宽容性不能退化。
      for (final String removed in <String>[
        'register_local_executor',
        'unregister_local_executor',
        'register_ssh_executor',
        'unregister_ssh_executor',
        'tool_exec_response',
        'tool_exec_progress',
        'plugin_host_event',
      ]) {
        ws.send(<String, dynamic>{
          'type': removed,
          'data': <String, dynamic>{'team_id': 'agt_1'},
        });
      }
      // 之后正常帧仍被处理（心跳必须有应答）
      ws.send(<String, dynamic>{'type': WsInboundType.heartbeat});
      await ws.until(
        (Map<String, dynamic> f) => f['type'] == WsOutboundType.heartbeat,
        reason: '心跳应答',
      );
      expect(
        ws.types(),
        isNot(contains(WsOutboundType.error)),
        reason: '已删除的帧不应触发错误帧',
      );
    });

    test('分片上行被重组后按普通帧处理（大帧不再静默丢弃）', () async {
      final String agentId = await seedAgent('分片上行');
      final _WsClient ws = await _WsClient.connect(server);
      ws.record();
      addTearDown(ws.close);

      final Map<String, dynamic> frame = <String, dynamic>{
        'type': WsInboundType.userMessage,
        'agent_id': agentId,
        'content': '分片内容' * 40,
        'session_id': TreeStore.defaultSessionId,
      };
      final String raw = jsonEncode(frame);
      final List<String> parts = WsConnection.splitByUtf8Budget(raw, 64);
      expect(parts.length, greaterThan(1));
      ws.send(<String, dynamic>{
        'type': WsOutboundType.frameBegin,
        'id': 'frg_test',
        'total': parts.length,
      });
      for (int i = 0; i < parts.length; i++) {
        ws.send(<String, dynamic>{
          'type': WsOutboundType.frameChunk,
          'id': 'frg_test',
          'seq': i,
          'part': parts[i],
        });
      }
      ws.send(<String, dynamic>{
        'type': WsOutboundType.frameEnd,
        'id': 'frg_test',
      });
      await ws.until(
        (Map<String, dynamic> f) => f['type'] == WsOutboundType.msgEnd,
        reason: 'msg_end（分片消息已重组）',
      );
      final _Res history = await client.send(
        'GET',
        '/api/conversations/$agentId?session_id=${TreeStore.defaultSessionId}',
      );
      final List<dynamic> messages = history.json['messages'] as List<dynamic>;
      expect((messages.first as Map<String, dynamic>)['content'], '分片内容' * 40);
    });

    test('多窗口并发连接都能收到广播', () async {
      final String agentId = await seedAgent('多窗口');
      final _WsClient a = await _WsClient.connect(server);
      final _WsClient b = await _WsClient.connect(server);
      a.record();
      b.record();
      addTearDown(a.close);
      addTearDown(b.close);
      // 服务端在 upgrade 完成后才登记连接：客户端 connect 返回可能更早，
      // 因此这里轮询等待，而不是直接断言（否则是竞态型 flaky）
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 5));
      while (server.hub.connectionCount < 2 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(server.hub.connectionCount, 2);

      a.send(<String, dynamic>{
        'type': WsInboundType.userMessage,
        'agent_id': agentId,
        'content': '广播',
        'session_id': TreeStore.defaultSessionId,
      });
      await b.until(
        (Map<String, dynamic> f) => f['type'] == WsOutboundType.msgEnd,
        reason: '另一窗口收到 msg_end',
      );
      await a.until(
        (Map<String, dynamic> f) => f['type'] == WsOutboundType.msgEnd,
        reason: 'msg_end',
      );
    });
  });

  group('清空历史', () {
    test('按会话清空只删该会话，all 清空全部', () async {
      final String agentId = await seedAgent('清空');
      final _WsClient ws = await _WsClient.connect(server);
      ws.record();
      addTearDown(ws.close);
      for (int i = 0; i < 2; i++) {
        ws.send(<String, dynamic>{
          'type': WsInboundType.userMessage,
          'agent_id': agentId,
          'content': i == 0 ? '一' : '二',
          'session_id': TreeStore.defaultSessionId,
        });
        await ws.untilCount(WsOutboundType.msgEnd, i + 1);
      }
      expect(server.store.totalMessageCount, 4);
      final _Res cleared = await client.send(
        'DELETE',
        '/api/conversations/$agentId?session_id=${TreeStore.defaultSessionId}',
      );
      expect(cleared.json['deleted'], 4);
      expect(server.store.totalMessageCount, 0);
      expect(
        (await client.send(
          'DELETE',
          '/api/conversations/$agentId?session_id=all',
        )).json['deleted'],
        0,
      );
    });
  });
}
