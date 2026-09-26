import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

import 'fake_transport.dart';
import 'ws_harness.dart';

/// 端到端提问回路（真 HTTP/WS + 假 LLM 传输）：
/// 工具被调用 → 提问卡片帧 → 用户作答帧 → 工具结果回灌 → 续跑收尾。
void main() {
  late CoreServer server;
  late MemoryStore store;
  late MemoryQuestionStore questions;
  late QuestionBroker broker;
  late CoreAgent agent;
  late Directory temp;
  late TestWs ws;

  const String sessionId = TreeStore.defaultSessionId;

  setUp(() async {
    final FakeTransport transport = FakeTransport(<List<LlmStreamEvent>>[
      toolCallScript(
        name: BuiltinTools.askUserQuestion,
        arguments: '{"question":"选 A 还是 B？","options":["A","B"]}',
      ),
      textScript('已按 B 继续。'),
    ]);
    final CoreSettings settings = CoreSettings();
    settings.createModel(<String, dynamic>{
      'model_id': 'demo',
      'name': '演示模型',
      'base_url': 'https://api.example.com/v1',
      'api_key': 'sk-test',
      'max_seqlen': 64000,
    });
    store = MemoryStore();
    questions = MemoryQuestionStore();
    void Function(Map<String, dynamic> frame)? sink;
    broker = QuestionBroker(
      questions: questions,
      transcript: store,
      broadcast: (Map<String, dynamic> frame) => sink?.call(frame),
    );
    temp = Directory.systemTemp.createTempSync('tree_question_ws_');
    final WorkspaceToolRunner tools = WorkspaceToolRunner(
      resolveWorkspaceDir: (String _) => temp.path,
      askQuestion: broker.ask,
    );
    server = await CoreServer.start(
      store: store,
      settings: settings,
      questions: broker,
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: LlmAgentEngine(
        resolveModel: settings.model,
        toolRunner: tools,
        transportFactory: (CoreModelConfig _) => transport,
      ),
    );
    sink = server.hub.broadcast;
    agent = store.createAgent(name: '提问用例', modelId: 'demo');
    ws = await TestWs.connect(server);
    ws.record();
  });

  tearDown(() async {
    await ws.close();
    await server.close();
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  test('提问→作答→续跑：帧序列、工具结果回灌与落库', () async {
    ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': agent.id,
      'content': '帮我选一个',
      'session_id': sessionId,
    });

    // 1) 提问卡片：顶层字段（前端 _handleAskUserQuestion 直接读）
    await ws.until(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.askUserQuestion,
      reason: '提问卡片帧',
    );
    final Map<String, dynamic> card = ws.frames.firstWhere(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.askUserQuestion,
    );
    final String qid = card['id'] as String;
    expect(qid, isNotEmpty);
    expect(card['question'], '选 A 还是 B？');
    expect(card['options'], <String>['A', 'B']);
    expect(card['agent_id'], agent.id);
    expect(card['session_id'], sessionId);
    expect(questions.byId(qid)?.isPending, isTrue, reason: '提问已落盘');

    // 2) 用户作答（帧口径与前端一致：字段嵌在 data 里）
    ws.send(<String, dynamic>{
      'type': WsInboundType.userAnswer,
      'data': <String, dynamic>{'question_id': qid, 'answer': 'B'},
    });

    // 3) 本轮继续跑完
    await waitIdle(ws);
    final Map<String, dynamic> toolEnd = ws.frames.firstWhere(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.toolEnd,
    );
    expect(toolEnd['name'], BuiltinTools.askUserQuestion);
    expect(toolEnd['result'], contains('用户回答：B'));
    expect(
      ws.types(),
      contains(WsOutboundType.askUserQuestionResolved),
      reason: '多窗口同步信号',
    );
    expect(ws.types(), isNot(contains(WsOutboundType.error)));

    // 4) 续跑产出的正文
    final Map<String, dynamic> textStart = ws.frames.firstWhere(
      (Map<String, dynamic> f) =>
          f['type'] == WsOutboundType.msgStart && f['kind'] == 'text',
    );
    final String textId = textStart['id'] as String;
    expect(
      ws.frames
          .where(
            (Map<String, dynamic> f) =>
                f['type'] == WsOutboundType.msgChunk && f['id'] == textId,
          )
          .map((Map<String, dynamic> f) => f['chunk'] as String)
          .join(),
      '已按 B 继续。',
    );

    // 5) 落库：提问卡片 + 工具卡片（结果里带用户回答）
    final List<CoreMessage> messages = store.messages(agent.id, sessionId);
    final CoreMessage toolMessage = messages.firstWhere(
      (CoreMessage m) => m.kind == 'tool',
    );
    expect(toolMessage.toolName, BuiltinTools.askUserQuestion);
    expect(toolMessage.toolResult, contains('用户回答：B'));
    expect(questions.byId(qid)?.status, QuestionStatus.answered);
    expect(questions.byId(qid)?.answer, 'B');
  });

  test('stop：在途提问被取消，本轮收敛而不是永久挂起', () async {
    ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': agent.id,
      'content': '帮我选一个',
      'session_id': sessionId,
    });
    await ws.until(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.askUserQuestion,
      reason: '提问卡片帧',
    );
    ws.send(<String, dynamic>{
      'type': WsInboundType.stop,
      'data': <String, dynamic>{'agent_id': agent.id, 'session_id': sessionId},
    });
    await waitIdle(ws);
    expect(broker.pending(), isEmpty, reason: 'stop 必须取消在途提问');
    final Map<String, dynamic> toolEnd = ws.frames.firstWhere(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.toolEnd,
    );
    expect(toolEnd['result'], contains('取消'));
  });
}
