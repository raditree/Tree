import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// 提问回路（M5a）语义：落盘 + 推帧 + 等待作答 + 取消 + 重启后补答。
void main() {
  late MemoryStore store;
  late MemoryQuestionStore questions;
  late List<Map<String, dynamic>> frames;
  late QuestionBroker broker;
  late CoreAgent agent;

  const String sessionId = TreeStore.defaultSessionId;

  setUp(() {
    store = MemoryStore();
    agent = store.createAgent(name: '主 agent');
    questions = MemoryQuestionStore();
    frames = <Map<String, dynamic>>[];
    broker = QuestionBroker(
      questions: questions,
      transcript: store,
      broadcast: frames.add,
      pollInterval: const Duration(milliseconds: 10),
    );
  });

  AskQuestionRequest request({
    String question = '选哪个方案？',
    List<String> options = const <String>['A', 'B'],
    bool Function()? isCancelled,
  }) => AskQuestionRequest(
    agentId: agent.id,
    sessionId: sessionId,
    question: question,
    options: options,
    isCancelled: isCancelled ?? () => false,
  );

  test('ask：先落盘再推帧，并在会话里留下提问卡片', () async {
    final Future<QuestionOutcome> pending = broker.ask(request());
    expect(broker.inFlightCount, 1);

    // 1) 提问记录已落盘（重启后右侧「问题回复」页仍能看到）
    final QuestionRecord record = questions.list().single;
    expect(record.status, QuestionStatus.pending);
    expect(record.question, '选哪个方案？');
    expect(record.options, <String>['A', 'B']);
    expect(record.agentId, agent.id);
    expect(record.sessionId, sessionId);

    // 2) 下行帧：顶层字段（前端 _handleAskUserQuestion 的口径，不包 data）
    final Map<String, dynamic> frame = frames.single;
    expect(frame['type'], WsOutboundType.askUserQuestion);
    expect(frame['id'], record.qid);
    expect(frame['question'], '选哪个方案？');
    expect(frame['options'], <String>['A', 'B']);
    expect(frame['agent_id'], agent.id);
    expect(frame['session_id'], sessionId);
    expect(frame.containsKey('data'), isFalse);

    // 3) 会话里有一条提问卡片消息（重载历史时仍渲染卡片）
    final CoreMessage card = store
        .messages(agent.id, sessionId)
        .singleWhere((CoreMessage m) => m.kind == 'ask_user_question');
    expect(card.id, record.qid, reason: 'qid 即消息 id');
    expect(card.content, '选哪个方案？');
    expect(card.options, <String>['A', 'B']);
    expect(card.answered, isFalse);

    // 4) 作答：等待中的 future 完成，并广播 resolved
    expect(broker.answer(record.qid, 'B'), isTrue);
    final QuestionOutcome outcome = await pending;
    expect(outcome.cancelled, isFalse);
    expect(outcome.answer, 'B');
    expect(broker.inFlightCount, 0);
    expect(questions.byId(record.qid)?.status, QuestionStatus.answered);
    expect(frames.last['type'], WsOutboundType.askUserQuestionResolved);
    expect((frames.last['data'] as Map<String, dynamic>)['id'], record.qid);

    // 5) 重复作答被幂等闸门拒绝（并发 WS + REST 只生效一次）
    expect(broker.answer(record.qid, 'C'), isFalse);
    expect(questions.byId(record.qid)?.answer, 'B');
  });

  test('cancel：等待立刻结束且记录标记为已取消', () async {
    final Future<QuestionOutcome> pending = broker.ask(request());
    final String qid = questions.list().single.qid;
    expect(broker.cancel(qid, reason: '用户取消'), isTrue);
    final QuestionOutcome outcome = await pending;
    expect(outcome.cancelled, isTrue);
    expect(questions.byId(qid)?.status, QuestionStatus.cancelled);
    expect(broker.cancel(qid), isFalse, reason: '重复取消幂等');
  });

  test('stop 语义：isCancelled 轮询与 cancelForAgent 都能收尾', () async {
    bool cancelled = false;
    final Future<QuestionOutcome> polled = broker.ask(
      request(isCancelled: () => cancelled),
    );
    final Future<QuestionOutcome> forced = broker.ask(
      request(question: '第二个问题'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    cancelled = true;
    expect((await polled).cancelled, isTrue, reason: '轮询到 stop 后收尾');

    expect(broker.inFlightCount, 1);
    expect(broker.cancelForAgent(agent.id), 1);
    expect((await forced).cancelled, isTrue);
    expect(broker.pending(), isEmpty);
  });

  test('超时按取消收尾（默认不超时，可显式指定）', () async {
    final QuestionOutcome outcome = await broker.ask(
      request(),
      timeout: const Duration(milliseconds: 30),
    );
    expect(outcome.cancelled, isTrue);
    expect(questions.list().single.status, QuestionStatus.cancelled);
    expect(broker.inFlightCount, 0);
  });

  test('重启后补答：没有在途生成就把答案写进会话，供下一轮续跑', () async {
    // 模拟"重启"：只保留提问记录，broker 是新的（无在途 future）
    final MemoryQuestionStore persisted = MemoryQuestionStore();
    final QuestionBroker restarted = QuestionBroker(
      questions: persisted,
      transcript: store,
      broadcast: frames.add,
    );
    persisted.add(
      QuestionRecord(
        qid: 'q_old',
        agentId: agent.id,
        sessionId: sessionId,
        question: '旧提问',
        createdAt: 1,
      ),
    );
    expect(restarted.answer('q_old', '继续'), isTrue);
    final CoreMessage answer = store
        .messages(agent.id, sessionId)
        .lastWhere((CoreMessage m) => m.role == 'user');
    expect(answer.content, '${QuestionBroker.answerPrefix}继续');
    expect(restarted.inFlightCount, 0);
  });

  test('dispose：关停时全部在途等待立刻收尾（不让生成任务挂着）', () async {
    final Future<QuestionOutcome> pending = broker.ask(request());
    broker.dispose();
    expect((await pending).cancelled, isTrue);
    expect(broker.inFlightCount, 0);
  });

  group('工具层', () {
    test('只接入提问通道时才声明 ask_user_question；且它不需要工作空间', () {
      expect(
        BuiltinTools.specs().map((ToolSpec s) => s.name),
        isNot(contains(BuiltinTools.askUserQuestion)),
      );
      expect(
        BuiltinTools.specs(withQuestions: true).map((ToolSpec s) => s.name),
        contains(BuiltinTools.askUserQuestion),
      );
      expect(
        BuiltinTools.needsWorkspace(BuiltinTools.askUserQuestion),
        isFalse,
      );
      expect(BuiltinTools.needsWorkspace(BuiltinTools.setTodoList), isFalse);
      for (final String name in <String>[
        'read',
        'write',
        'edit',
        'grep',
        'terminal',
      ]) {
        expect(BuiltinTools.needsWorkspace(name), isTrue, reason: name);
      }
    });

    test('工作空间不可用时提问仍可用（不被连带失败），结果回灌用户回答', () async {
      final List<AskQuestionRequest> requests = <AskQuestionRequest>[];
      final WorkspaceToolRunner runner = WorkspaceToolRunner(
        resolveWorkspaceDir: (String _) => '',
        askQuestion: (AskQuestionRequest request) async {
          requests.add(request);
          return const QuestionOutcome(answer: 'B');
        },
      );
      final ToolOutcome outcome = await runner.run(
        ToolInvocation(
          id: 'tool_1',
          name: BuiltinTools.askUserQuestion,
          arguments: <String, dynamic>{
            'question': '  选哪个？  ',
            'options': <dynamic>['A', 'B', 'B', '  ', 3],
          },
          agentId: agent.id,
          sessionId: sessionId,
        ),
      );
      expect(outcome.isError, isFalse);
      expect(outcome.content, contains('用户回答：B'));
      expect(requests.single.question, '选哪个？');
      expect(requests.single.options, <String>['A', 'B', '3']);

      // 反例：工作空间工具在不可用时必须明确报错（不静默造一个空目录）
      final ToolOutcome read = await runner.run(
        ToolInvocation(
          id: 'tool_2',
          name: BuiltinTools.read,
          arguments: <String, dynamic>{'file_path': 'a.txt'},
          agentId: agent.id,
          sessionId: sessionId,
        ),
      );
      expect(read.isError, isTrue);
      expect(read.content, contains('无法准备工作空间'));
      await runner.close();
    });

    test('question 为空报错；取消时的文案明确要求不要重复提问', () async {
      final WorkspaceToolRunner runner = WorkspaceToolRunner(
        resolveWorkspaceDir: (String _) => '',
        askQuestion: (AskQuestionRequest request) async =>
            const QuestionOutcome(answer: '', cancelled: true),
      );
      ToolInvocation invocation(String question) => ToolInvocation(
        id: 'tool_1',
        name: BuiltinTools.askUserQuestion,
        arguments: <String, dynamic>{'question': question},
        agentId: agent.id,
        sessionId: sessionId,
      );
      final ToolOutcome empty = await runner.run(invocation('   '));
      expect(empty.isError, isTrue);
      expect(empty.content, contains('question 不能为空'));
      final ToolOutcome cancelled = await runner.run(invocation('继续吗？'));
      expect(cancelled.isError, isFalse);
      expect(cancelled.content, contains('不要重复提问'));
      await runner.close();
    });
  });
}
