import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

import 'fake_transport.dart';

/// WS 级集成测试：**真实 HTTP + 真实 WebSocket**，只有 LLM 传输层是假的。
///
/// 验证 ConversationService 的事件→帧映射与落库：
/// 思考卡片、工具卡片、用量推进、两条流式消息的收尾、以及 `tool_call_id` 的持久化
/// （下一轮必须能原样回灌给端点，否则历史重放会被端点拒绝）。
void main() {
  late CoreServer server;
  late CoreSettings settings;
  late String agentId;

  Future<void> startWith(FakeTransport transport) async {
    settings = CoreSettings();
    settings.createModel(<String, dynamic>{
      'model_id': 'demo',
      'name': '演示模型',
      'base_url': 'https://api.example.com/v1',
      'api_key': 'sk-test',
      'max_seqlen': 64000,
    });
    server = await CoreServer.start(
      streamChunkDelay: Duration.zero,
      enableHeartbeat: false,
      settings: settings,
      engine: LlmAgentEngine(
        resolveModel: settings.model,
        toolRunner: FakeToolRunner(
          specs: const <ToolSpec>[
            ToolSpec(name: 'read_file', description: '读文件'),
          ],
          result: '工具结果',
        ),
        transportFactory: (CoreModelConfig config) => transport,
      ),
    );
    final CoreAgent agent = server.store.createAgent(
      name: 'LLM 用例',
      systemPrompt: '你是助手',
      modelId: 'demo',
    );
    agentId = agent.id;
  }

  tearDown(() async {
    await server.close();
  });

  test('思考 + 工具 + 正文：帧序列、落库顺序与 tool_call_id 全链路', () async {
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      <LlmStreamEvent>[
        const LlmThinkingDelta('我先想想'),
        const LlmThinkingDelta('，再看文件'),
        ...toolCallScript(name: 'read_file', arguments: '{"path":"a.txt"}'),
      ],
      textScript('文件内容是 hello'),
    ]);
    await startWith(transport);

    final _Ws ws = await _Ws.connect(server);
    ws.record();
    addTearDown(ws.close);
    ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': agentId,
      'content': '读一下 a.txt',
      'session_id': TreeStore.defaultSessionId,
    });
    await ws.untilCount(WsOutboundType.agentStatus, 2);

    final List<Map<String, dynamic>> frames = ws.frames;
    final List<String> types = frames
        .map((Map<String, dynamic> f) => f['type'] as String)
        .toList();
    expect(types.first, WsOutboundType.agentStatus);
    expect(types.last, WsOutboundType.agentStatus);

    // 思考消息：msg_start(kind=thinking) + 两个 chunk
    final Map<String, dynamic> thinkingStart = frames.firstWhere(
      (Map<String, dynamic> f) =>
          f['type'] == WsOutboundType.msgStart && f['kind'] == 'thinking',
    );
    final String thinkingId = thinkingStart['id'] as String;
    expect(
      frames
          .where(
            (Map<String, dynamic> f) =>
                f['type'] == WsOutboundType.msgChunk && f['id'] == thinkingId,
          )
          .map((Map<String, dynamic> f) => f['chunk'] as String)
          .join(),
      '我先想想，再看文件',
    );

    // 工具卡片
    final Map<String, dynamic> toolStart = frames.firstWhere(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.toolStart,
    );
    expect(toolStart['name'], 'read_file');
    expect((toolStart['arguments'] as Map<String, dynamic>)['path'], 'a.txt');
    final Map<String, dynamic> toolEnd = frames.firstWhere(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.toolEnd,
    );
    expect(toolEnd['id'], toolStart['id']);
    expect(toolEnd['result'], '工具结果');

    // 正文消息 + usage
    final Map<String, dynamic> textStart = frames.firstWhere(
      (Map<String, dynamic> f) =>
          f['type'] == WsOutboundType.msgStart && f['kind'] == 'text',
    );
    final String textId = textStart['id'] as String;
    expect(
      frames
          .where(
            (Map<String, dynamic> f) =>
                f['type'] == WsOutboundType.msgChunk && f['id'] == textId,
          )
          .map((Map<String, dynamic> f) => f['chunk'] as String)
          .join(),
      '文件内容是 hello',
    );
    // 用量口径：每轮推一次 msg_usage；prompt 取**最后一轮**（= 当前上下文长度），
    // completion 为**全轮累加**（工具循环里模型生成了两轮内容）。
    final List<Map<String, dynamic>> usages = frames
        .where((Map<String, dynamic> f) => f['type'] == WsOutboundType.msgUsage)
        .map((Map<String, dynamic> f) => f['usage'] as Map<String, dynamic>)
        .toList();
    expect(usages, hasLength(2), reason: '工具循环里两轮都推 usage');
    expect(usages.first['total_tokens'], 55, reason: '第一轮：50 prompt + 5');
    expect(usages.first['prompt_tokens'], 50);
    expect(usages.last['prompt_tokens'], 100, reason: 'prompt 取最后一轮');
    expect(usages.last['completion_tokens'], 12, reason: 'completion 全轮累加');
    expect(usages.last['total_tokens'], 112);
    expect(usages.last['max_tokens'], 64000, reason: '进度条分母来自模型配置');

    // 两条流式消息都要收尾
    final Iterable<Map<String, dynamic>> ends = frames.where(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.msgEnd,
    );
    expect(ends.map((Map<String, dynamic> f) => f['id']).toSet(), <String>{
      thinkingId,
      textId,
    });
    expect(
      (ends.firstWhere((Map<String, dynamic> f) => f['id'] == textId)['usage']
          as Map<String, dynamic>)['total_tokens'],
      112,
      reason: '正文消息的 msg_end 带最终累计用量',
    );

    // 落库顺序与 UI 一致：user → thinking → tool → text
    final List<CoreMessage> stored = server.store.messages(
      agentId,
      TreeStore.defaultSessionId,
    );
    expect(stored.map((CoreMessage m) => m.role).toList(), <String>[
      'user',
      'agent',
      'agent',
      'agent',
    ]);
    expect(stored.map((CoreMessage m) => m.kind).toList(), <String>[
      'text',
      'thinking',
      'tool',
      'text',
    ]);
    expect(stored[1].content, '我先想想，再看文件');
    expect(stored[2].toolName, 'read_file');
    expect(stored[2].toolResult, '工具结果');
    expect(
      stored[2].toolCallId,
      'call_1',
      reason: '端点给的 tool_call id 必须落库，历史重放才能配对',
    );
    expect(stored[3].content, '文件内容是 hello');
    expect(stored[3].usage?['total_tokens'], 112);

    // 第二次请求确实带上了工具结果（工具循环闭环）
    final List<LlmMessage> second = transport.requests[1].messages;
    expect(
      second.where((LlmMessage m) => m.isToolResult).single.toolCallId,
      'call_1',
    );
  });

  test('模型未配置：给出可见的错误消息（前端只忽略 error 帧，必须落一条文本）', () async {
    settings = CoreSettings();
    server = await CoreServer.start(
      streamChunkDelay: Duration.zero,
      enableHeartbeat: false,
      settings: settings,
      engine: LlmAgentEngine(resolveModel: settings.model),
    );
    final CoreAgent agent = server.store.createAgent(name: '无模型', modelId: '');
    agentId = agent.id;

    final _Ws ws = await _Ws.connect(server);
    ws.record();
    addTearDown(ws.close);
    ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': agentId,
      'content': '你好',
      'session_id': TreeStore.defaultSessionId,
    });
    await ws.until(
      (Map<String, dynamic> f) =>
          f['type'] == WsOutboundType.agentStatus &&
          (f['data'] as Map<String, dynamic>)['status'] == 'idle',
    );

    final Map<String, dynamic> error = ws.frames.firstWhere(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.error,
    );
    expect(
      (error['data'] as Map<String, dynamic>)['message'],
      contains('尚未指定模型'),
    );
    final Map<String, dynamic> notice = ws.frames.firstWhere(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.message,
    );
    expect(notice['content'], contains('尚未指定模型'));
    final List<CoreMessage> stored = server.store.messages(
      agentId,
      TreeStore.defaultSessionId,
    );
    expect(
      stored.last.content,
      contains('尚未指定模型'),
      reason: '错误提示要留在会话里，否则用户刷新后什么都看不到',
    );
  });
}

/// 极简 WS 客户端 + 帧记录器（单次订阅、持续累积，避免 broadcast 流丢事件）。
class _Ws {
  _Ws._(this._socket, this._controller) {
    _subscription = _socket.listen(
      (dynamic data) {
        final Object? decoded = jsonDecode(data.toString());
        if (decoded is Map<String, dynamic>) _controller.add(decoded);
      },
      onDone: () => _controller.close(),
      onError: (Object _) => _controller.close(),
    );
  }

  static Future<_Ws> connect(CoreServer server) async {
    final WebSocket socket = await WebSocket.connect(
      '${server.handshake.wsBaseUrl}${CoreServer.wsPath}'
      '?token=${server.token}',
    );
    return _Ws._(socket, StreamController<Map<String, dynamic>>.broadcast());
  }

  final WebSocket _socket;
  final StreamController<Map<String, dynamic>> _controller;
  late final StreamSubscription<dynamic> _subscription;
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];

  void send(Map<String, dynamic> frame) => _socket.add(jsonEncode(frame));

  void record() => _controller.stream.listen(frames.add);

  Future<void> until(
    bool Function(Map<String, dynamic> frame) predicate, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (frames.any(predicate)) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw TimeoutException(
      '等待帧超时；已收到：'
      '${frames.map((Map<String, dynamic> f) => f['type']).toList()}',
    );
  }

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
    throw TimeoutException('等待 $count 个 $type 超时');
  }

  Future<void> close() async {
    await _subscription.cancel();
    await _socket.close();
    if (!_controller.isClosed) await _controller.close();
  }
}
