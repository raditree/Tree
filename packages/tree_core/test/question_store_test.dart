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

      test('作答只对 pending 生效，且第二次作答不再改变状态', () {
        store.add(record());
        final QuestionRecord? first = store.markAnswered('q_1', 'A');
        expect(first?.status, QuestionStatus.answered);
        expect(first?.answer, 'A');
        expect(first?.answeredAt, greaterThan(0));
        expect(first?.isPending, isFalse);
        expect(store.markAnswered('q_1', 'B'), isNull, reason: '幂等闸门');
        expect(store.byId('q_1')?.answer, 'A');
        expect(store.markAnswered('nope', 'A'), isNull);
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
        store.markAnswered('q_3', 'x');
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
    first.markAnswered('q_1', '是');
    await first.flush();
    expect(first.lastError, isNull);

    final FileQuestionStore second = FileQuestionStore(TreePaths(temp.path));
    expect(second.list().length, 2);
    expect(second.byId('q_1')?.status, QuestionStatus.answered);
    expect(second.byId('q_1')?.answer, '是');
    expect(second.byId('q_1')?.options, <String>['是', '否']);
    expect(second.byId('q_2')?.isPending, isTrue);
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
