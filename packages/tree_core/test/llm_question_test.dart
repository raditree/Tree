import 'dart:async';
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

  /// 假 LLM 传输（脚本可在用例里改写：多问题用例需要不同的工具参数）
  late FakeTransport transport;

  const String sessionId = TreeStore.defaultSessionId;

  setUp(() async {
    transport = FakeTransport(<List<LlmStreamEvent>>[
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
    expect(card['questions'], <Map<String, dynamic>>[
      <String, dynamic>{
        'question': '选 A 还是 B？',
        'options': <String>['A', 'B'],
      },
    ]);
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

  test('多问题：一次问两道，作答一次交齐后按题回灌并落库', () async {
    transport.script
      ..clear()
      ..addAll(<List<LlmStreamEvent>>[
        toolCallScript(
          name: BuiltinTools.askUserQuestion,
          arguments:
              '{"questions":['
              '{"question":"部署到哪台？","options":["A 机","B 机"]},'
              '{"question":"要不要回滚预案？"}]}',
        ),
        textScript('已按你的选择继续。'),
      ]);
    ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': agent.id,
      'content': '帮我定两件事',
      'session_id': sessionId,
    });

    // 1) 卡片帧：questions 是完整问题表，一次调用只有一个 qid（一张卡片）
    await ws.until(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.askUserQuestion,
      reason: '提问卡片帧',
    );
    final Map<String, dynamic> card = ws.frames.firstWhere(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.askUserQuestion,
    );
    final String qid = card['id'] as String;
    expect((card['questions'] as List<dynamic>).length, 2);
    expect((card['question'] as String), '部署到哪台？', reason: '兼容第一问');
    expect(
      ws.frames
          .where(
            (Map<String, dynamic> f) =>
                f['type'] == WsOutboundType.askUserQuestion,
          )
          .length,
      1,
      reason: '两道题共用一张卡片',
    );

    // 2) 用户一次交齐两道题的答案
    ws.send(<String, dynamic>{
      'type': WsInboundType.userAnswer,
      'data': <String, dynamic>{
        'question_id': qid,
        'answers': <String>['B 机', '要'],
      },
    });

    // 3) 工具结果按题列出，本轮续跑完成
    await waitIdle(ws);
    final Map<String, dynamic> toolEnd = ws.frames.firstWhere(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.toolEnd,
    );
    expect(toolEnd['name'], BuiltinTools.askUserQuestion);
    expect(toolEnd['result'], contains('第1题（部署到哪台？）：B 机'));
    expect(toolEnd['result'], contains('第2题（要不要回滚预案？）：要'));
    expect(ws.types(), isNot(contains(WsOutboundType.error)));

    // 4) 落库：提问记录与工具卡片都带逐题答案
    expect(questions.byId(qid)?.answers, <String>['B 机', '要']);
    final CoreMessage toolMessage = store
        .messages(agent.id, sessionId)
        .firstWhere((CoreMessage m) => m.kind == 'tool');
    expect(toolMessage.toolResult, contains('第2题（要不要回滚预案？）：要'));
  });

  test('插话 / hook 完成提示落在提问期间：提问不被掐掉，插入消息排队等作答', () async {
    // 用户 2026-10-04 断言：「任何工具调用执行期间不被插话打断，插入消息（包括
    // terminal/subagent hook 完成消息）在工具调用期间必须排队等待」。
    // 旧实现两处都违反：_interruptForNewMessage 直接 cancelForSession，且 broker 的
    // isCancelled 轮询拿到的是**软**信号 ⇒ 一条 hook 完成提示就把题卡掐掉。
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
    final String qid =
        ws.frames.firstWhere(
              (Map<String, dynamic> f) =>
                  f['type'] == WsOutboundType.askUserQuestion,
            )['id']
            as String;
    expect(transport.turnsUsed, 1, reason: '第一跳已发出，工具正等作答');

    // 两种"有人说话"：用户又发一条 + terminal hook 完成提示
    ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': agent.id,
      'content': '顺便说一句',
      'session_id': sessionId,
    });
    unawaited(
      server.conversation.wake(
        agentId: agent.id,
        sessionId: sessionId,
        notice: '[terminal hook] 后台命令已结束',
      ),
    );

    await _untilTrue(
      () => server.conversation.interruptedRunCount >= 1,
      reason: '插话被记下来（软收敛标记）',
    );
    // 旧实现里 broker 的取消轮询 500ms 就会把它掐掉：这里等够再断言
    await Future<void>.delayed(const Duration(milliseconds: 900));

    expect(questions.byId(qid)?.isPending, isTrue, reason: '在途提问不许被插话掐掉');
    expect(broker.pending(), hasLength(1));
    expect(transport.turnsUsed, 1, reason: '插入的两条在排队：没开新的 LLM 跳');

    // 作答 ⇒ 工具返回 ⇒ 被打断的那轮收敛 ⇒ 排队那轮才起跑
    ws.send(<String, dynamic>{
      'type': WsInboundType.userAnswer,
      'data': <String, dynamic>{'question_id': qid, 'answer': 'B'},
    });
    await _untilTrue(
      () => transport.turnsUsed >= 2,
      reason: '排队的消息起跑（第二跳）',
    );
    await waitIdle(ws);
    final Map<String, dynamic> toolEnd = ws.frames.firstWhere(
      (Map<String, dynamic> f) => f['type'] == WsOutboundType.toolEnd,
    );
    expect(toolEnd['result'], contains('用户回答：B'), reason: '作答照常回灌工具结果');
    expect(ws.types(), isNot(contains(WsOutboundType.error)));
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

/// 轮询等条件成立（与 message_interrupt_test 同一套路：并行满负载下别用固定 sleep）。
Future<void> _untilTrue(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 20),
  String reason = '',
}) async {
  final DateTime deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('超时等待：' + reason);
}
