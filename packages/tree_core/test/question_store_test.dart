import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 提问存储契约：内存实现与落盘实现必须**行为一致**（同一套断言双向约束）。
void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('tree_questions_'));
  tearDown(() async {
    await _delete(temp);
  });

  for (final MapEntry<String, QuestionStore Function()> variant
      in <String, QuestionStore Function()>{
        'MemoryQuestionStore': MemoryQuestionStore.new,
        'FileQuestionStore': () => FileQuestionStore(TreePaths(temp.path)),
      }.entries) {
    group(variant.key, () {
      late QuestionStore store;
      setUp(() => store = variant.value());

      QuestionRecord record({
        String qid = 'q_1',
        String agentId = 'agt_1',
        String sessionId = 'ses_1',
        String question = '选哪个？',
        List<String>? options,
        int createdAt = 1000,
      }) => QuestionRecord(
        qid: qid,
        agentId: agentId,
        sessionId: sessionId,
        question: question,
        createdAt: createdAt,
        options: options,
      );

      test('add/byId/list 保序；未知 id 返回 null', () {
        store.add(record(qid: 'q_1', createdAt: 1));
        store.add(record(qid: 'q_2', createdAt: 2));
        expect(store.byId('q_1')?.question, '选哪个？');
        expect(store.byId('nope'), isNull);
        expect(store.list().map((QuestionRecord r) => r.qid), <String>[
          'q_1',
          'q_2',
        ]);
      });

      test('createdAt 单调递增：同毫秒的连续两条不漂移（"最新的排前面"必须确定）', () {
        // 真机现场：`GET /api/questions` 按 `created_at` 降序，而 Dart 的 `List.sort`
        // 不保证稳定 —— 两条提问落在同一毫秒时，"最新的一条"在两次请求之间会换位置
        // （`questions_api_test` 全量跑约 3 次红 1 次）。
        const int now = 1700000000000;
        store.add(record(qid: 'q_a', createdAt: now));
        store.add(record(qid: 'q_b', createdAt: now));
        expect(store.byId('q_a')!.createdAt, now, reason: '第一条原样保留（绝不伪造时刻）');
        expect(
          store.byId('q_b')!.createdAt,
          now + 1,
          reason: '同毫秒的第二条抬 1ms：把落库顺序压进时间戳，顺序就与排序实现无关',
        );
        final List<QuestionRecord> desc = List<QuestionRecord>.of(store.list())
          ..sort(
            (QuestionRecord a, QuestionRecord b) =>
                b.createdAt.compareTo(a.createdAt),
          );
        expect(desc.first.qid, 'q_b', reason: '按时间倒序取"最新" = 最后提出的那条');
      });

      test('作答只对 pending 生效，且第二次作答不再改变状态', () {
        store.add(record());
        final QuestionRecord? first = store.markAnswered('q_1', <String>['A']);
        expect(first?.status, QuestionStatus.answered);
        expect(first?.answer, 'A');
        expect(first?.answers, <String>['A']);
        expect(first?.answeredAt, greaterThan(0));
        expect(first?.isPending, isFalse);
        expect(store.markAnswered('q_1', <String>['B']), isNull, reason: '幂等闸门');
        expect(store.byId('q_1')?.answer, 'A');
        expect(store.markAnswered('nope', <String>['A']), isNull);
      });

      test('多问题：questions/answers 往返，缺项按「未作答」，兼容读法指第一问', () {
        store.add(
          QuestionRecord(
            qid: 'q_m',
            agentId: 'agt_1',
            sessionId: 'ses_1',
            questions: <AskedQuestion>[
              AskedQuestion(question: '第一问', options: <String>['A', 'B']),
              AskedQuestion(question: '第二问'),
            ],
            createdAt: 1000,
          ),
        );
        final QuestionRecord? pending = store.byId('q_m');
        expect(pending?.questions.length, 2);
        expect(pending?.isMulti, isTrue);
        expect(pending?.question, '第一问', reason: '兼容读法 = 第一问的题面');
        expect(pending?.options, <String>['A', 'B'], reason: '兼容读法 = 第一问的选项');
        expect(pending?.answers, <String>['', ''], reason: '逐题答案，未作答为空串');

        final QuestionRecord? answered = store.markAnswered(
          'q_m',
          <String>['是'],
        );
        expect(answered?.status, QuestionStatus.answered);
        expect(
          answered?.answers,
          <String>['是', ''],
          reason: '缺项按未作答补齐（老前端只回一个答案也走这条）',
        );
        expect(answered?.answer, contains('第1题（第一问）：是'));
        expect(answered?.answer, contains('（未作答）'), reason: '多问摘要逐题成行');
      });

      test('取消只对 pending 生效，且清空答案语义正确', () {
        store.add(record());
        final QuestionRecord? cancelled = store.markCancelled('q_1');
        expect(cancelled?.status, QuestionStatus.cancelled);
        expect(cancelled?.answeredAt, greaterThan(0));
        expect(store.markCancelled('q_1'), isNull);
      });

      test('list 支持按 agent/session/待答过滤', () {
        store.add(record(qid: 'q_1', agentId: 'agt_1', sessionId: 'ses_1'));
        store.add(record(qid: 'q_2', agentId: 'agt_1', sessionId: 'ses_2'));
        store.add(record(qid: 'q_3', agentId: 'agt_2', sessionId: 'ses_1'));
        store.markAnswered('q_3', <String>['x']);
        expect(store.list(agentId: 'agt_1').length, 2);
        expect(store.list(sessionId: 'ses_1').length, 2);
        expect(
          store.list(agentId: 'agt_1', sessionId: 'ses_2').single.qid,
          'q_2',
        );
        expect(
          store.list(onlyPending: true).map((QuestionRecord r) => r.qid),
          <String>['q_1', 'q_2'],
        );
      });

      test('removeForAgent 只删该 agent 的记录', () {
        store.add(record(qid: 'q_1', agentId: 'agt_1'));
        store.add(record(qid: 'q_2', agentId: 'agt_2'));
        expect(store.removeForAgent('agt_1'), 1);
        expect(store.list().single.qid, 'q_2');
        expect(store.removeForAgent('agt_1'), 0);
      });

      test('toApiJson 字段与前端 question_panel 一致', () {
        store.add(
          QuestionRecord(
            qid: 'q_1',
            agentId: 'agt_1',
            teamId: 'agt_1',
            sessionId: 'ses_1',
            isMember: true,
            question: '选哪个？',
            options: <String>['A', 'B'],
            createdAt: 1000,
            status: QuestionStatus.answered,
            answer: 'B',
            answeredAt: 2000,
          ),
        );
        final Map<String, dynamic> json = store.byId('q_1')!.toApiJson();
        expect(json['qid'], 'q_1');
        expect(json['agent_id'], 'agt_1');
        expect(json['team_id'], 'agt_1');
        expect(json['session_id'], 'ses_1');
        expect(json['is_member'], isTrue);
        expect(json['question'], '选哪个？');
        expect(json['options'], <String>['A', 'B']);
        expect(json['answer'], 'B');
        expect(json['status'], 'answered');
        expect(json['created_at'], 1000);
        expect(json['answered_at'], 2000);
        // 多问题字段（老前端忽略，只看上面那组）
        expect(json['questions'], <Map<String, dynamic>>[
          <String, dynamic>{
            'question': '选哪个？',
            'options': <String>['A', 'B'],
          },
        ]);
        expect(json['answers'], <String>['B']);
      });
    });
  }

  test('FileQuestionStore：重启后读回全部状态（含答案）', () async {
    final FileQuestionStore first = FileQuestionStore(TreePaths(temp.path));
    first.add(
      QuestionRecord(
        qid: 'q_1',
        agentId: 'agt_1',
        sessionId: 'ses_1',
        question: '继续吗？',
        createdAt: 10,
        options: const <String>['是', '否'],
      ),
    );
    first.add(
      QuestionRecord(
        qid: 'q_2',
        agentId: 'agt_1',
        sessionId: 'ses_1',
        question: '另一个',
        createdAt: 20,
      ),
    );
    first.markAnswered('q_1', <String>['是']);
    await first.flush();
    expect(first.lastError, isNull);

    final FileQuestionStore second = FileQuestionStore(TreePaths(temp.path));
    expect(second.list().length, 2);
    expect(second.byId('q_1')?.status, QuestionStatus.answered);
    expect(second.byId('q_1')?.answer, '是');
    expect(second.byId('q_1')?.answers, <String>['是']);
    expect(second.byId('q_1')?.options, <String>['是', '否']);
    expect(second.byId('q_1')?.questions.single.question, '继续吗？');
    expect(second.byId('q_2')?.isPending, isTrue);
  });

  test('FileQuestionStore：多问题记录往返（questions 与 answers 都落盘）', () async {
    final FileQuestionStore first = FileQuestionStore(TreePaths(temp.path));
    first.add(
      QuestionRecord(
        qid: 'q_multi',
        agentId: 'agt_1',
        sessionId: 'ses_1',
        questions: <AskedQuestion>[
          AskedQuestion(question: '部署到哪台？', options: <String>['A 机', 'B 机']),
          AskedQuestion(question: '要不要回滚预案？'),
        ],
        createdAt: 10,
      ),
    );
    first.markAnswered('q_multi', <String>['B 机', '要']);
    await first.flush();

    final FileQuestionStore second = FileQuestionStore(TreePaths(temp.path));
    final QuestionRecord? record = second.byId('q_multi');
    expect(record?.isMulti, isTrue);
    expect(record?.questions.length, 2);
    expect(record?.questions[0].options, <String>['A 机', 'B 机']);
    expect(record?.answers, <String>['B 机', '要']);
    expect(record?.answer, contains('第2题'));
  });

  test('FileQuestionStore：旧文件里同毫秒的两条原样读入（不追改用户数据）', () async {
    final TreePaths paths = TreePaths(temp.path);
    Map<String, dynamic> legacy(String qid, String question, int at) =>
        <String, dynamic>{
          'qid': qid,
          'agent_id': 'agt_1',
          'team_id': '',
          'session_id': 'ses_1',
          'is_member': false,
          'question': question,
          'options': <String>[],
          'answer': '',
          'status': QuestionStatus.pending,
          'created_at': at,
          'answered_at': 0,
        };
    File(paths.questionsFile)
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode(<Map<String, dynamic>>[legacy('q_a', '第一条', 500), legacy('q_b', '第二条', 500)]),
      );
    final FileQuestionStore store = FileQuestionStore(paths);
    expect(
      store.list().map((QuestionRecord r) => r.qid),
      <String>['q_a', 'q_b'],
      reason: '装载顺序 = 文件顺序',
    );
    expect(
      store.list().map((QuestionRecord r) => r.createdAt),
      <int>[500, 500],
      reason: '时间戳是用户数据的真实时刻：装载只读不改（旧平局不去追改）',
    );
    expect(
      store.byId('q_a')?.questions.single.question,
      '第一条',
      reason: '旧记录没有 questions 键 ⇒ 由 question/options 合成单问',
    );
    expect(store.byId('q_a')?.isMulti, isFalse);
    expect(store.byId('q_a')?.answers, <String>[''], reason: '未作答：逐题答案为空串');
  });

  test('FileQuestionStore：旧文件里"已作答"的单问记录合成出 answers（不追改文件）', () async {
    final TreePaths paths = TreePaths(temp.path);
    File(paths.questionsFile)
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{
            'qid': 'q_old',
            'agent_id': 'agt_1',
            'team_id': '',
            'session_id': 'ses_1',
            'is_member': false,
            'question': '继续吗？',
            'options': <String>['是', '否'],
            'answer': '是',
            'status': QuestionStatus.answered,
            'created_at': 100,
            'answered_at': 200,
          },
        ]),
      );
    final FileQuestionStore store = FileQuestionStore(paths);
    final QuestionRecord? record = store.byId('q_old');
    expect(record?.status, QuestionStatus.answered);
    expect(record?.answer, '是', reason: '旧键原样保留');
    expect(record?.answers, <String>['是'], reason: '单个 answer 归一成第一问的答案');
    expect(record?.questions.single.question, '继续吗？');
    // 装载只读不改：文件内容一个字节都没动
    final String text = File(paths.questionsFile).readAsStringSync();
    expect(jsonDecode(text), isA<List<dynamic>>());
    expect(text.contains('"questions"'), isFalse, reason: '装载不写回（不追改用户数据）');
  });

  test('FileQuestionStore：文件被手改坏时不阻止启动（按空表处理）', () async {
    File(TreePaths(temp.path).questionsFile)
      ..createSync(recursive: true)
      ..writeAsStringSync('{ 这不是 JSON');
    final FileQuestionStore store = FileQuestionStore(TreePaths(temp.path));
    expect(store.list(), isEmpty);
    store.add(
      QuestionRecord(
        qid: 'q_1',
        agentId: 'a',
        sessionId: 's',
        question: 'x',
        createdAt: 1,
      ),
    );
    await store.flush();
    final Object? decoded = jsonDecode(
      File(TreePaths(temp.path).questionsFile).readAsStringSync(),
    );
    expect(decoded, isA<List<dynamic>>());
  });
}

Future<void> _delete(Directory dir) async {
  for (int i = 0; i < 5; i++) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      return;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
