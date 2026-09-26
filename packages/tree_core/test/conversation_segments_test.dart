import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

import 'ws_harness.dart';

/// 可控引擎：按脚本一次性产出全部事件（不模拟任何时间）。
class _ScriptEngine implements AgentEngine {
  _ScriptEngine(this.events);

  final List<AgentEvent> events;

  @override
  Stream<AgentEvent> run(
    AgentRunContext context, {
    required bool Function() isCancelled,
  }) async* {
    for (final AgentEvent event in events) {
      yield event;
    }
  }

  @override
  Future<void> close() async {}
}

/// 段的时间线：只保留"边界帧"（msg_start / msg_end / tool_start / tool_end），
/// 增量帧（msg_chunk）不参与顺序断言。
List<String> _timeline(List<Map<String, dynamic>> frames) => <String>[
  for (final Map<String, dynamic> frame in frames)
    switch (frame['type'] as String? ?? '') {
      'msg_start' => 'start:${frame['kind']}',
      'msg_end' => 'end',
      'tool_start' => 'tool_start:${frame['name']}',
      'tool_end' => 'tool_end:${frame['name']}',
      _ => '',
    },
].where((String label) => label.isNotEmpty).toList();

/// 段的 id 顺序（msg_start 与 tool_start 的出现顺序）= 前端看到的消息顺序。
List<String> _segmentIds(List<Map<String, dynamic>> frames) => <String>[
  for (final Map<String, dynamic> frame in frames)
    if (frame['type'] == 'msg_start' || frame['type'] == 'tool_start')
      frame['id'] as String,
];

/// 走**历史接口**重载消息（真实路径：该接口按时间戳排序）。
Future<List<Map<String, dynamic>>> _reload(
  CoreServer server,
  String agentId,
  String sessionId,
) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.getUrl(
      Uri.parse(
        '${server.handshake.httpBaseUrl}/api/conversations/$agentId'
        '?session_id=$sessionId',
      ),
    );
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${server.token}',
    );
    final HttpClientResponse response = await request.close();
    final String text = await utf8.decoder.bind(response).join();
    final Map<String, dynamic> json = jsonDecode(text) as Map<String, dynamic>;
    return (json['messages'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .toList();
  } finally {
    client.close(force: true);
  }
}

/// Q3 消息分段：一轮回复里的思考 / 中间正文 / 工具卡片 / 最终回复各自独立成段。
void main() {
  late CoreServer server;
  late TestWs ws;
  late String agentId;
  const String sessionId = TreeStore.defaultSessionId;

  Future<void> start(List<AgentEvent> events) async {
    server = await CoreServer.start(
      streamChunkDelay: Duration.zero,
      enableHeartbeat: false,
      engine: _ScriptEngine(events),
    );
    agentId = server.store.createAgent(name: '分段用例').id;
    ws = await TestWs.connect(server);
    ws.record();
  }

  tearDown(() async {
    await ws.close();
    await server.close();
  });

  Future<void> send(String content) async {
    ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': agentId,
      'content': content,
      'session_id': sessionId,
    });
    await waitIdle(ws);
  }

  test('一轮两次工具调用：帧顺序 [思考][正文][工具]×2 + 最终回复，中间正文不被并进最终回复', () async {
    await start(<AgentEvent>[
      const AgentThinking('先想一下：'),
      const AgentText('先查一下 read。'),
      AgentToolStart(
        id: 'tool_a',
        callId: 'call_a',
        name: 'read',
        arguments: const <String, dynamic>{'file_path': 'a.txt'},
      ),
      const AgentToolEnd(id: 'tool_a', name: 'read', result: 'A 的内容'),
      const AgentThinking('再想一下：'),
      const AgentText('接着写 write。'),
      AgentToolStart(
        id: 'tool_b',
        callId: 'call_b',
        name: 'write',
        arguments: const <String, dynamic>{
          'file_path': 'b.txt',
          'content': '内容',
        },
      ),
      const AgentToolEnd(id: 'tool_b', name: 'write', result: '已写入'),
      const AgentText('两件事都做完了。'),
      const AgentUsage(<String, dynamic>{
        'prompt_tokens': 10,
        'completion_tokens': 5,
        'total_tokens': 15,
        'max_tokens': 100,
      }),
      const AgentDone(finishReason: 'stop'),
    ]);
    await send('帮我做两件事');

    // ① 前端帧：思考段遇正文关闭、正文段遇工具调用关闭、工具结果直接推
    expect(_timeline(ws.frames), <String>[
      'start:thinking',
      'end',
      'start:text',
      'end',
      'tool_start:read',
      'tool_end:read',
      'start:thinking',
      'end',
      'start:text',
      'end',
      'tool_start:write',
      'tool_end:write',
      'start:text',
      'end',
    ]);
    // usage 只挂最后一段（中间段不带 usage）
    final List<Map<String, dynamic>> ends = ws.frames
        .where((Map<String, dynamic> f) => f['type'] == WsOutboundType.msgEnd)
        .toList();
    expect(ends, hasLength(5));
    expect(ends.last['usage'], isNotNull);
    expect(
      ends.take(4).every((Map<String, dynamic> f) => f['usage'] == null),
      isTrue,
      reason: '中间段不挂 usage',
    );

    // ② 落库：顺序与帧一致，且逐条 id 对得上
    final List<CoreMessage> stored = server.store.messages(agentId, sessionId);
    expect(stored.map((CoreMessage m) => m.kind).toList(), <String>[
      'text',
      'thinking',
      'text',
      'tool',
      'thinking',
      'text',
      'tool',
      'text',
    ]);
    expect(stored.first.role, 'user');
    expect(
      stored.skip(1).map((CoreMessage m) => m.id).toList(),
      _segmentIds(ws.frames),
    );
    expect(
      stored
          .where((CoreMessage m) => m.role == 'agent' && !m.isTool)
          .map((CoreMessage m) => m.content)
          .toList(),
      <String>['先想一下：', '先查一下 read。', '再想一下：', '接着写 write。', '两件事都做完了。'],
    );
    // ③ 中间正文**没有**被并进最终回复（Q3 的核心回归点）
    final CoreMessage last = stored.last;
    expect(last.content, '两件事都做完了。');
    expect(last.content, isNot(contains('先查一下')));
    expect(last.content, isNot(contains('接着写')));
    expect(last.usage?['total_tokens'], 15, reason: 'usage 只挂最后一条');
    expect(
      stored
          .where((CoreMessage m) => m.id != last.id)
          .every((CoreMessage m) => m.usage == null),
      isTrue,
    );
    expect(
      stored.map((CoreMessage m) => m.toolCallId).whereType<String>().toList(),
      <String>['call_a', 'call_b'],
      reason: '工具卡片的 call id 必须落库，历史重放才能配对',
    );

    // ④ 时间戳是单调序号：历史接口按时间戳排序，同毫秒会让重载顺序漂移
    final List<int> stamps = stored
        .map((CoreMessage m) => m.timestamp)
        .toList();
    for (int i = 1; i < stamps.length; i++) {
      expect(
        stamps[i],
        greaterThan(stamps[i - 1]),
        reason: '同一会话内时间戳必须严格递增（第 $i 条）',
      );
    }

    // ⑤ 重载历史（走真实接口，含按时间戳排序）后顺序完全一致
    final List<Map<String, dynamic>> reloaded = await _reload(
      server,
      agentId,
      sessionId,
    );
    expect(
      reloaded.map((Map<String, dynamic> m) => m['id']).toList(),
      stored.map((CoreMessage m) => m.id).toList(),
    );
    expect(
      reloaded.map((Map<String, dynamic> m) => m['kind']).toList(),
      stored.map((CoreMessage m) => m.kind).toList(),
    );
  });

  test('无思考时缺省：正文段与工具卡片交替，最终回复仍是独立一段', () async {
    await start(<AgentEvent>[
      const AgentText('第一段正文。'),
      AgentToolStart(
        id: 'tool_a',
        callId: 'call_a',
        name: 'read',
        arguments: const <String, dynamic>{'file_path': 'a.txt'},
      ),
      const AgentToolEnd(id: 'tool_a', name: 'read', result: 'A'),
      const AgentText('第二段正文。'),
      const AgentDone(finishReason: 'stop'),
    ]);
    await send('读一下');

    expect(_timeline(ws.frames), <String>[
      'start:text',
      'end',
      'tool_start:read',
      'tool_end:read',
      'start:text',
      'end',
    ]);
    expect(
      server.store
          .messages(agentId, sessionId)
          .map((CoreMessage m) => m.kind)
          .toList(),
      <String>['text', 'text', 'tool', 'text'],
    );
    expect(server.store.messages(agentId, sessionId).last.content, '第二段正文。');
  });

  test('一轮 40+ 条消息：历史接口按时间戳排序后顺序仍与落库顺序一致', () async {
    // 历史接口 GET /api/conversations 会按时间戳排序，而 Dart 的 List.sort 在
    // 32 条以上不保证稳定：整轮落在同一毫秒时，重载顺序会漂移（Q3 的根因）。
    final List<AgentEvent> events = <AgentEvent>[];
    for (int i = 0; i < 20; i++) {
      events.add(AgentText('正文$i。'));
      events.add(
        AgentToolStart(
          id: 'tool_$i',
          callId: 'call_$i',
          name: 'read',
          arguments: const <String, dynamic>{'file_path': 'a.txt'},
        ),
      );
      events.add(AgentToolEnd(id: 'tool_$i', name: 'read', result: 'r'));
    }
    events.add(const AgentText('收尾。'));
    events.add(const AgentDone(finishReason: 'stop'));
    await start(events);
    await send('干活');

    final List<CoreMessage> stored = server.store.messages(agentId, sessionId);
    expect(stored, hasLength(42), reason: '1 条用户消息 + 20 正文 + 20 工具 + 收尾');
    final List<Map<String, dynamic>> reloaded = await _reload(
      server,
      agentId,
      sessionId,
    );
    expect(
      reloaded.map((Map<String, dynamic> m) => m['id']).toList(),
      stored.map((CoreMessage m) => m.id).toList(),
      reason: '重载顺序必须与落库顺序逐条一致',
    );
  });
}
