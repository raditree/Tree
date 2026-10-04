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
    List<AskedQuestion>? questions,
    bool Function()? isCancelled,
  }) => AskQuestionRequest(
    agentId: agent.id,
    sessionId: sessionId,
    questions:
        questions ??
        <AskedQuestion>[AskedQuestion(question: question, options: options)],
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
    expect(broker.answer(record.qid, <String>['B']), isTrue);
    final QuestionOutcome outcome = await pending;
    expect(outcome.cancelled, isFalse);
    expect(outcome.answer, 'B');
    expect(broker.inFlightCount, 0);
    expect(questions.byId(record.qid)?.status, QuestionStatus.answered);
    expect(frames.last['type'], WsOutboundType.askUserQuestionResolved);
    expect((frames.last['data'] as Map<String, dynamic>)['id'], record.qid);

    // 5) 重复作答被幂等闸门拒绝（并发 WS + REST 只生效一次）
    expect(broker.answer(record.qid, <String>['C']), isFalse);
    expect(questions.byId(record.qid)?.answer, 'B');
  });

  test('多问题：一条记录一张卡片，作答一次交齐（未答项按未作答）', () async {
    final Future<QuestionOutcome> pending = broker.ask(
      request(
        questions: <AskedQuestion>[
          AskedQuestion(question: '部署到哪台？', options: <String>['A 机', 'B 机']),
          AskedQuestion(question: '要不要回滚预案？'),
        ],
      ),
    );
    // 1) 落盘：一条记录、两道题
    final QuestionRecord record = questions.list().single;
    expect(record.isMulti, isTrue);
    expect(record.questions.length, 2);
    expect(record.question, '部署到哪台？', reason: '兼容读法 = 第一问');

    // 2) 下行帧：questions 是完整问题表；question/options 保留为第一问（老前端）
    final Map<String, dynamic> frame = frames.single;
    expect(frame['questions'], <Map<String, dynamic>>[
      <String, dynamic>{
        'question': '部署到哪台？',
        'options': <String>['A 机', 'B 机'],
      },
      <String, dynamic>{'question': '要不要回滚预案？', 'options': <String>[]},
    ]);
    expect(frame['question'], '部署到哪台？');
    expect(frame['options'], <String>['A 机', 'B 机']);

    // 3) 会话里那张卡片同样是两道题（历史重载时按它渲染）
    final CoreMessage card = store
        .messages(agent.id, sessionId)
        .singleWhere((CoreMessage m) => m.kind == 'ask_user_question');
    expect(card.questions?.length, 2);

    // 4) 只答第一题也接受（缺项按未作答），resolved 帧带逐题答案
    expect(broker.answer(record.qid, <String>['B 机']), isTrue);
    final QuestionOutcome outcome = await pending;
    expect(outcome.cancelled, isFalse);
    expect(outcome.answers, <String>['B 机', '']);
    expect(record.answers, <String>['B 机', '']);
    final Map<String, dynamic> resolved =
        frames.last['data'] as Map<String, dynamic>;
    expect(resolved['answers'], <String>['B 机', '']);
    expect(resolved['answer'], contains('第1题（部署到哪台？）：B 机'));
  });

  test('多问题：取消同样立刻收尾（一个 Completer，与题数无关）', () async {
    final Future<QuestionOutcome> pending = broker.ask(
      request(
        questions: <AskedQuestion>[
          AskedQuestion(question: '第一问'),
          AskedQuestion(question: '第二问'),
        ],
      ),
    );
    final String qid = questions.list().single.qid;
    expect(broker.cancel(qid, reason: '用户取消'), isTrue);
    final QuestionOutcome outcome = await pending;
    expect(outcome.cancelled, isTrue);
    expect(outcome.answers, isEmpty);
    expect(questions.byId(qid)?.status, QuestionStatus.cancelled);
    expect(broker.inFlightCount, 0);
  });

  test('多问题：没有在途生成时的补答消息逐题成行', () async {
    final MemoryQuestionStore persisted = MemoryQuestionStore();
    final QuestionBroker restarted = QuestionBroker(
      questions: persisted,
      transcript: store,
      broadcast: frames.add,
    );
    persisted.add(
      QuestionRecord(
        qid: 'q_multi_old',
        agentId: agent.id,
        sessionId: sessionId,
        questions: <AskedQuestion>[
          AskedQuestion(question: '第一问'),
          AskedQuestion(question: '第二问'),
        ],
        createdAt: 1,
      ),
    );
    expect(restarted.answer('q_multi_old', <String>['甲', '乙']), isTrue);
    final CoreMessage answer = store
        .messages(agent.id, sessionId)
        .lastWhere((CoreMessage m) => m.role == 'user');
    expect(answer.content, startsWith('${QuestionBroker.answerPrefix}\n'));
    expect(answer.content, contains('第1题（第一问）：甲'));
    expect(answer.content, contains('第2题（第二问）：乙'));
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
    expect(restarted.answer('q_old', <String>['继续']), isTrue);
    final CoreMessage answer = store
        .messages(agent.id, sessionId)
        .lastWhere((CoreMessage m) => m.role == 'user');
    expect(answer.content, '${QuestionBroker.answerPrefix}继续');
    expect(restarted.inFlightCount, 0);
  });

  test('记录被摘掉（删除 agent）后 cancel 仍收尾在途等待', () async {
    final Future<QuestionOutcome> pending = broker.ask(request());
    final String qid = questions.list().single.qid;
    // 删除 agent 的动作就是把记录直接摘掉（QuestionStore.removeForAgent）
    expect(questions.removeForAgent(agent.id), 1);
    expect(broker.inFlightCount, 1, reason: '摘记录本身不会收尾在途等待');

    // 硬化后的 cancel：记录没了也照样完成 completer（否则那一轮永远挂着）
    expect(broker.cancel(qid, reason: 'agent 已删除'), isTrue);
    expect((await pending).cancelled, isTrue);
    expect(broker.inFlightCount, 0);
    expect(broker.cancel(qid), isFalse, reason: '已经没有可收尾的了');
  });

  test('cancelForAgent 按 store 的 pending 列表遍历：记录摘掉后它救不回来', () async {
    final Future<QuestionOutcome> pending = broker.ask(request());
    questions.removeForAgent(agent.id);
    expect(broker.cancelForAgent(agent.id), 0);
    expect(broker.inFlightCount, 1, reason: '这就是删除路径必须先取消的原因');
    broker.dispose();
    expect((await pending).cancelled, isTrue);
  });

  test('dispose：关停时全部在途等待立刻收尾（不让生成任务挂着）', () async {
    final Future<QuestionOutcome> pending = broker.ask(request());
    broker.dispose();
    expect((await pending).cancelled, isTrue);
    expect(broker.inFlightCount, 0);
  });

  group('工具层', () {
    test('题面前缀只加在第一问上（临时员工提问：卡片本就显示在它名下）', () {
      final List<AskedQuestion> tagged = prefixFirstQuestion(
        <AskedQuestion>[
          AskedQuestion(question: '部署到哪台？', options: <String>['A 机']),
          AskedQuestion(question: '要不要回滚预案？'),
        ],
        '【临时员工「张三」提问】',
      );
      expect(tagged.first.question, '【临时员工「张三」提问】部署到哪台？');
      expect(tagged.first.options, <String>['A 机'], reason: '选项原样保留');
      expect(tagged[1].question, '要不要回滚预案？', reason: '第二问不加前缀');
      // 单问：等价于给题面加前缀
      expect(
        prefixFirstQuestion(
          <AskedQuestion>[AskedQuestion(question: '继续吗？')],
          '【临时员工「张三」提问】',
        ).single.question,
        '【临时员工「张三」提问】继续吗？',
      );
    });

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
          return const QuestionOutcome(answers: <String>['B']);
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
      expect(
        outcome.content,
        '用户回答：B',
        reason: '单问的结果文案与"只支持单问题"时期逐字一致（模型侧口径不变）',
      );
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
            const QuestionOutcome(cancelled: true),
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

    test('多问题：questions 数组归一（题面去空白、选项去重去空），结果逐题列出', () async {
      final List<AskQuestionRequest> requests = <AskQuestionRequest>[];
      final WorkspaceToolRunner runner = WorkspaceToolRunner(
        resolveWorkspaceDir: (String _) => '',
        askQuestion: (AskQuestionRequest request) async {
          requests.add(request);
          return const QuestionOutcome(answers: <String>['B 机', '']);
        },
      );
      final ToolOutcome outcome = await runner.run(
        ToolInvocation(
          id: 'tool_1',
          name: BuiltinTools.askUserQuestion,
          arguments: <String, dynamic>{
            'questions': <dynamic>[
              <String, dynamic>{
                'question': '  部署到哪台？  ',
                'options': <dynamic>['A 机', 'B 机', 'B 机', '  '],
              },
              <String, dynamic>{'question': '要不要回滚预案？'},
            ],
          },
          agentId: agent.id,
          sessionId: sessionId,
        ),
      );
      expect(outcome.isError, isFalse);
      expect(requests.single.questions.length, 2);
      expect(requests.single.questions[0].question, '部署到哪台？');
      expect(requests.single.questions[0].options, <String>['A 机', 'B 机']);
      // 结果按题列出；未作答如实标注
      expect(outcome.content, startsWith('用户回答：\n'));
      expect(outcome.content, contains('第1题（部署到哪台？）：B 机'));
      expect(outcome.content, contains('第2题（要不要回滚预案？）：（未作答）'));
      await runner.close();
    });

    test('多问题：题数超上限（10）与坏形状都给可读错误', () async {
      final WorkspaceToolRunner runner = WorkspaceToolRunner(
        resolveWorkspaceDir: (String _) => '',
        askQuestion: (AskQuestionRequest request) async =>
            const QuestionOutcome(answers: <String>['x']),
      );
      Future<ToolOutcome> run(Map<String, dynamic> arguments) => runner.run(
        ToolInvocation(
          id: 'tool_1',
          name: BuiltinTools.askUserQuestion,
          arguments: arguments,
          agentId: agent.id,
          sessionId: sessionId,
        ),
      );
      final ToolOutcome tooMany = await run(<String, dynamic>{
        'questions': <dynamic>[
          for (int i = 0; i <= BuiltinTools.maxQuestionsPerCall; i++)
            <String, dynamic>{'question': '第 $i 题'},
        ],
      });
      expect(tooMany.isError, isTrue);
      expect(tooMany.content, contains('一次最多问 10 道题'));

      final ToolOutcome badItem = await run(<String, dynamic>{
        'questions': <dynamic>['裸字符串'],
      });
      expect(badItem.isError, isTrue);
      expect(badItem.content, contains('{question, options} 对象'));

      final ToolOutcome emptyQuestion = await run(<String, dynamic>{
        'questions': <dynamic>[
          <String, dynamic>{'question': '   '},
        ],
      });
      expect(emptyQuestion.isError, isTrue);
      expect(emptyQuestion.content, contains('question 不能为空'));

      final ToolOutcome bothMissing = await run(<String, dynamic>{});
      expect(bothMissing.isError, isTrue);
      expect(bothMissing.content, contains('question 不能为空'));

      // 简写与数组同时给时以 questions 为准（约定：数组是权威形态）
      final ToolOutcome preferArray = await run(<String, dynamic>{
        'question': '简写那道',
        'questions': <dynamic>[
          <String, dynamic>{'question': '数组那道'},
        ],
      });
      expect(preferArray.isError, isFalse);
      expect(preferArray.content, contains('用户回答：x'));
      await runner.close();
    });
  });
}
