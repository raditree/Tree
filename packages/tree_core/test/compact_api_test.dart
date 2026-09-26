import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

import 'ws_harness.dart';

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
    Object? decoded;
    try {
      decoded = text.trim().isEmpty ? null : jsonDecode(text);
    } catch (_) {
      decoded = null;
    }
    return _Res(
      response.statusCode,
      decoded is Map<String, dynamic> ? decoded : <String, dynamic>{},
      text,
    );
  }

  void close() => _http.close(force: true);
}

class _Res {
  const _Res(this.status, this.json, this.raw);
  final int status;
  final Map<String, dynamic> json;
  final String raw;
}

/// 假总结器：记录调用次数，可加延迟（让压缩ing 状态帧可观测）。
class _Summarizer implements ContextSummarizer {
  _Summarizer({this.delay = Duration.zero});

  final Duration delay;
  int calls = 0;

  @override
  Future<String> summarize(CoreAgent agent, String prompt) async {
    calls++;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return '压缩摘要：早期对话要点';
  }

  @override
  Future<void> close() async {}
}

/// 手动压缩的 REST 面（M7d-4）：状态帧、互斥与摘要写回。
void main() {
  late MemoryStore store;
  late CoreSettings settings;
  late CoreAgent agent;
  late _Summarizer summarizer;
  late CompactionService compaction;
  late CoreServer server;
  late _Client client;
  late TestWs ws;

  Future<void> start({
    bool withCompaction = true,
    Duration chunkDelay = Duration.zero,
  }) async {
    store = MemoryStore();
    settings = CoreSettings()
      ..putModel(
        CoreModelConfig(
          modelId: 'demo',
          name: '演示',
          baseUrl: 'https://api.example.com/v1',
          apiKey: 'sk-test',
          maxSeqlen: 1000,
        ),
      );
    agent = store.createAgent(name: '压缩用例', modelId: 'demo');
    agent.systemPrompt = '你是助手';
    store.putAgent(agent);
    summarizer = _Summarizer(delay: const Duration(milliseconds: 20));
    compaction = CompactionService(
      store: store,
      settings: settings,
      summarizer: summarizer,
      keepRecentUserMessages: 1,
      keepTailLength: 1,
    );
    server = await CoreServer.start(
      store: store,
      settings: settings,
      compaction: withCompaction ? compaction : null,
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: ScriptedAgent(chunkDelay: chunkDelay),
    );
    client = _Client(server);
    ws = await TestWs.connect(server);
    ws.record();
  }

  tearDown(() async {
    await ws.close();
    client.close();
    await server.close();
  });

  /// 造 [turns] 轮用户/助手对话（时间戳递增）。
  void seed(int turns) {
    for (int i = 0; i < turns; i++) {
      for (final (String role, String text) in <(String, String)>[
        ('user', '需求$i'),
        ('agent', '回答$i'),
      ]) {
        store.appendMessage(
          CoreMessage(
            id: CoreIds.next('m'),
            agentId: agent.id,
            sessionId: TreeStore.defaultSessionId,
            role: role,
            content: text,
            timestamp: i * 2 + (role == 'user' ? 1 : 2),
          ),
        );
      }
    }
  }

  test('未接入压缩服务 -> 501（而不是静默 404）', () async {
    await start(withCompaction: false);
    final _Res res = await client.send(
      'POST',
      '/api/agents/${agent.id}/compact',
      body: <String, dynamic>{'session_id': TreeStore.defaultSessionId},
    );
    expect(res.status, 501);
  });

  test('没有活跃会话 / agent 不存在：可读原因而不是假装成功', () async {
    await start();
    final _Res missing = await client.send(
      'POST',
      '/api/agents/${agent.id}/compact',
      body: <String, dynamic>{'session_id': 'ses_nope'},
    );
    expect(missing.status, 200);
    expect(missing.json['compressed'], false);
    expect(missing.json['reason'], 'no_active_session');

    final _Res unknown = await client.send(
      'POST',
      '/api/agents/agt_nope/compact',
      body: <String, dynamic>{},
    );
    expect(unknown.status, 404);
    expect(unknown.raw, contains('agent 不存在'));
  });

  test('手动压缩：摘要写回会话 + WS 帧 compacting -> idle', () async {
    await start();
    seed(4);
    final _Res res = await client.send(
      'POST',
      '/api/agents/${agent.id}/compact',
      body: <String, dynamic>{'session_id': TreeStore.defaultSessionId},
    );
    expect(res.status, 200, reason: res.raw);
    expect(res.json['compressed'], true);
    expect(res.json['summarized_messages'], greaterThan(0));
    expect(res.json['context_size'], greaterThan(1));
    expect(summarizer.calls, 1);
    final CoreSession? after = store.session(
      agent.id,
      TreeStore.defaultSessionId,
    );
    expect(after?.compactedSummary, contains('压缩摘要'));
    expect(after?.compactedMessageCount, greaterThan(0));

    await ws.until(
      (Map<String, dynamic> f) =>
          f['type'] == 'agent_status' &&
          (f['data'] as Map<String, dynamic>?)?['status'] == 'compacting',
      reason: 'agent_status(compacting)',
    );
    await ws.until(
      (Map<String, dynamic> f) =>
          f['type'] == 'agent_status' &&
          (f['data'] as Map<String, dynamic>?)?['status'] == 'idle',
      reason: 'agent_status(idle)',
    );
  });

  test('会话正在生成 -> agent_working：不并发总结，也不推 compacting', () async {
    await start(chunkDelay: const Duration(milliseconds: 60));
    seed(4);
    final Future<void> run = server.conversation.handleUserMessage(
      <String, dynamic>{
        'agent_id': agent.id,
        'session_id': TreeStore.defaultSessionId,
        'content': '你好',
      },
    );
    await _waitFor(() => server.conversation.isRunning(agent.id));
    final _Res res = await client.send(
      'POST',
      '/api/agents/${agent.id}/compact',
      body: <String, dynamic>{'session_id': TreeStore.defaultSessionId},
    );
    expect(res.status, 200);
    expect(res.json['compressed'], false);
    expect(res.json['reason'], 'agent_working');
    expect(summarizer.calls, 0, reason: '生成中不该真的去总结');
    expect(
      ws.frames.any(
        (Map<String, dynamic> f) =>
            (f['data'] as Map<String, dynamic>?)?['status'] == 'compacting',
      ),
      isFalse,
      reason: '被拒绝的压缩不该让界面进入「压缩中」',
    );
    await run;
  });
}

/// 轮询等待条件成立（生成是异步的，isRunning 不是立即置位）。
Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('等待条件超时');
}
