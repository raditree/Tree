import 'dart:convert';

import '../store/atomic_file.dart';
import '../store/tree_paths.dart';
import '../store/tree_store.dart';
import '../store/write_queue.dart';
import '../tool/question_channel.dart';
import '../util/ids.dart';

/// 提问状态（取值与前端 `lib/ui/widgets/question_panel.dart` 一致）。
abstract final class QuestionStatus {
  /// 待作答（前端渲染输入框）。
  static const String pending = 'pending';

  /// 已作答。
  static const String answered = 'answered';

  /// 已取消（stop / 用户取消 / 超时）。
  static const String cancelled = 'cancelled';

  /// 全部取值。
  static const List<String> all = <String>[pending, answered, cancelled];
}

/// 下一条提问要用的时间戳：把 [requested] 抬成"全库严格递增"（见 [monotonicStamp]）。
///
/// 用**全库最大值**而不是"列表最后一条"：[removeForAgent] 会摘掉记录，尾部可能比中段
/// 更旧；"任意排序下都不出现平局"这件事由最大值直接保证。
int _nextQuestionStamp(List<QuestionRecord> records, int requested) {
  int previous = 0;
  for (final QuestionRecord record in records) {
    if (record.createdAt > previous) previous = record.createdAt;
  }
  return monotonicStamp(requested, previous);
}

/// 一条提问记录（`ask_user_question` 工具产出）。
///
/// 为什么单独存，而不是只靠会话消息日志：
/// - 右侧「问题回复」页要**跨会话**列出提问（`GET /api/questions`）；
/// - `messages.jsonl` 是**只追加**日志，作答要改状态（`pending → answered`）与写回答案，
///   追加日志做不到"就地更新"，只能重写整个文件；
/// - 因此状态与答案放在独立的小快照文件里（原子覆盖），消息日志只负责"聊天记录里
///   有一张提问卡片"这件事。
///
/// **多问题口径**：一条记录 = **一次提问**（一个 qid / 一张卡片），里面可以有 N 道题
/// （[questions] ≥ 1，单问是它的退化形态）。[question] / [options] 是"第一问"的
/// 兼容读法，[answer]/[answers] 是逐题答案。
class QuestionRecord {
  QuestionRecord({
    required this.qid,
    required this.agentId,
    required this.sessionId,
    required this.createdAt,
    List<AskedQuestion>? questions,
    String question = '',
    List<String>? options,
    List<String>? answers,
    String answer = '',
    this.teamId = '',
    this.isMember = false,
    this.status = QuestionStatus.pending,
    this.answeredAt = 0,
  }) : questions = (questions != null && questions.isNotEmpty)
           ? List<AskedQuestion>.of(questions)
           : <AskedQuestion>[
               AskedQuestion(question: question, options: options ?? const <String>[]),
             ],
       answers = normalizeAnswers(
         (questions != null && questions.isNotEmpty)
             ? questions
             : <AskedQuestion>[
                 AskedQuestion(
                   question: question,
                   options: options ?? const <String>[],
                 ),
               ],
         // 老调用方/老文件只有单个 `answer` ⇒ 它就是第一问的答案，其余未作答
         (answers != null && answers.isNotEmpty)
             ? answers
             : (answer.isEmpty ? const <String>[] : <String>[answer]),
       ) {
    this.answer = answer;
    if (this.answer.isEmpty && this.answers.any((String a) => a.isNotEmpty)) {
      // 兼容展示字段：只给了逐题答案时，按逐题排版推出来（单问 = 原样）
      this.answer = formatAnswerLines(this.questions, this.answers);
    }
  }

  /// 提问 id（同时是会话里提问卡片的消息 id）。
  final String qid;

  final String agentId;

  /// 团队成员提问时的队伍 id（普通 agent 为空）。
  final String teamId;

  final String sessionId;

  /// 提问者是否为团队成员（前端据此标注"来自成员"）。
  final bool isMember;

  /// 一次提问里的**全部**问题（至少一项；顺序即展示与作答顺序）。
  final List<AskedQuestion> questions;

  /// 逐题答案（与 [questions] 等长；**未作答项为空串**）。
  ///
  /// 不是 final 字段但内容可变（作答时就地填充），与 [answer] 同一条口径：
  /// 内存实现与落盘实现都只改这一份记录。
  final List<String> answers;

  /// 问题正文（= [questions] 的第一问；兼容读法，单问时就是全部）。
  String get question => questions.first.question;

  /// 候选选项（= 第一问的选项；兼容读法）。
  List<String> get options => questions.first.options;

  /// 是否一次问了多道题。
  bool get isMulti => questions.length > 1;

  /// 用户回答（未作答为空串）。
  ///
  /// 单问 = 那道题的答案；多问 = 逐题排版的摘要（见 [formatAnswerLines]），
  /// 供右栏「问题回复」页与历史卡片显示。
  String answer = '';

  /// [QuestionStatus] 之一。
  String status;

  /// 提问时间（毫秒）。
  ///
  /// **不是 final**：[QuestionStore.add] 在落库时把它抬成"全库严格递增"
  /// （见 [monotonicStamp]）——同毫秒的两条提问在按时间排序的列表里会重排，
  /// 而 Dart 的 `List.sort` 不保证稳定。与 [CoreMessage.timestamp] 同一条规则。
  int createdAt;

  /// 作答/取消时间（毫秒；未收尾为 0）。
  int answeredAt;

  bool get isPending => status == QuestionStatus.pending;

  QuestionRecord copyWith({
    List<String>? answers,
    String? answer,
    String? status,
    int? answeredAt,
  }) => QuestionRecord(
    qid: qid,
    agentId: agentId,
    teamId: teamId,
    sessionId: sessionId,
    isMember: isMember,
    questions: questions,
    answers: answers ?? this.answers,
    answer: answer ?? this.answer,
    createdAt: createdAt,
    status: status ?? this.status,
    answeredAt: answeredAt ?? this.answeredAt,
  );

  /// 持久化形态（`data/questions.json` 的一项）。
  ///
  /// `question` / `options` / `answer` 是**单问时期的键**，保留它们是为了**老前端**
  /// （只看第一问）与老文件阅读器不会瞎；新前端读 `questions` / `answers`。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'qid': qid,
    'agent_id': agentId,
    'team_id': teamId,
    'session_id': sessionId,
    'is_member': isMember,
    'questions': questions.map((AskedQuestion q) => q.toJson()).toList(),
    'answers': answers,
    'question': question,
    'options': options,
    'answer': answer,
    'status': status,
    'created_at': createdAt,
    'answered_at': answeredAt,
  };

  static QuestionRecord fromJson(Map<String, dynamic> json) => QuestionRecord(
    qid: json['qid'] as String? ?? CoreIds.question(),
    agentId: json['agent_id'] as String? ?? '',
    teamId: json['team_id'] as String? ?? '',
    sessionId: json['session_id'] as String? ?? '',
    isMember: json['is_member'] == true,
    // 老记录（多问题之前落盘的）没有 `questions` 键 ⇒ 由 question/options 合成一项；
    // 装载只读不改，不追改用户数据（与 createdAt 平局同一条口径）。
    questions: (json['questions'] as List<dynamic>?)
        ?.whereType<Map<dynamic, dynamic>>()
        .map(
          (Map<dynamic, dynamic> item) => AskedQuestion.fromJson(
            item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
          ),
        )
        .toList(),
    question: json['question'] as String? ?? '',
    options:
        (json['options'] as List<dynamic>?)
            ?.map((dynamic e) => e.toString())
            .toList() ??
        const <String>[],
    answers: (json['answers'] as List<dynamic>?)
        ?.map((dynamic e) => e.toString())
        .toList(),
    answer: json['answer'] as String? ?? '',
    status: json['status'] as String? ?? QuestionStatus.pending,
    createdAt: _int(json['created_at']),
    answeredAt: _int(json['answered_at']),
  );

  /// 前端形态（`GET /api/questions` 列表项）。
  ///
  /// 字段名与 `question_panel.dart::_QuestionItem.fromJson` 一一对应。
  Map<String, dynamic> toApiJson() => <String, dynamic>{
    'qid': qid,
    'agent_id': agentId,
    'team_id': teamId,
    'session_id': sessionId,
    'is_member': isMember,
    'questions': questions.map((AskedQuestion q) => q.toJson()).toList(),
    'answers': answers,
    'question': question,
    'options': options,
    'answer': answer,
    'status': status,
    'created_at': createdAt,
    'answered_at': answeredAt,
  };

  static int _int(Object? raw) {
    if (raw is num) return raw.toInt();
    return int.tryParse(raw?.toString() ?? '') ?? 0;
  }
}

/// 提问存储契约（内存实现与落盘实现由同一套契约测试双向约束）。
abstract interface class QuestionStore {
  /// 新增一条提问（同时写入缓存与落盘队列）。
  ///
  /// **单调序号（契约）**：实现必须把 `createdAt` 抬成"全库严格递增"
  /// （见 [monotonicStamp]）——两次提问落在同一毫秒时，`GET /api/questions` 的
  /// "最新的排前面"就是任意的（`List.sort` 不保证稳定），用户看到右栏顺序偶发漂移。
  /// **已装载的历史记录不改写**：`load()` 原样读入，旧文件里的平局不去追改用户数据。
  QuestionRecord add(QuestionRecord record);

  /// 按 id 取；不存在返回 null。
  QuestionRecord? byId(String qid);

  /// 作答：仅在**仍处于 `pending`** 时生效；返回更新后的记录（无效则 null）。
  ///
  /// [answers] 是**逐题**答案（与 `record.questions` 等长；缺项按"未作答"处理）：
  /// 单问时期的老调用方只回一个答案，归一后就是"第一问有答、其余未作答"。
  QuestionRecord? markAnswered(String qid, List<String> answers);

  /// 取消：仅当仍处于 `pending` 才生效；返回更新后的记录。
  QuestionRecord? markCancelled(String qid);

  /// 列表（按创建时间升序）。
  List<QuestionRecord> list({
    String? agentId,
    String? sessionId,
    bool onlyPending = false,
  });

  /// 删除某 agent 的全部提问（删除 agent 时调用），返回删除条数。
  ///
  /// **只摘记录、不负责收尾在途等待**：正在等答案的工具靠
  /// `QuestionBroker` 的 completer 挂着，调用方必须先经 broker 取消
  /// （`cancelForAgent`）再删记录，否则那一轮永远收不了尾（见
  /// `QuestionBroker.cancel` 的不变量）。
  int removeForAgent(String agentId);

  /// 等待全部在途落盘（关停与测试必须调用）。
  Future<void> flush();

  /// 最近一次落盘错误（无则 null）。
  Object? get lastError;
}

/// 把逐题答案写进记录（内存实现与落盘实现共用一份语义）。
///
/// 归一（与 `questions` 等长、缺项未作答）→ 同步兼容展示字段 [QuestionRecord.answer]。
void _applyAnswers(QuestionRecord record, List<String> answers) {
  record.answers
    ..clear()
    ..addAll(normalizeAnswers(record.questions, answers));
  record
    ..answer = formatAnswerLines(record.questions, record.answers)
    ..status = QuestionStatus.answered
    ..answeredAt = DateTime.now().millisecondsSinceEpoch;
}

/// 内存实现（测试与无盘场景）。
class MemoryQuestionStore implements QuestionStore {
  MemoryQuestionStore({List<QuestionRecord>? seed}) {
    for (final QuestionRecord record in seed ?? const <QuestionRecord>[]) {
      add(record);
    }
  }

  final List<QuestionRecord> _records = <QuestionRecord>[];

  @override
  QuestionRecord add(QuestionRecord record) {
    record.createdAt = _nextQuestionStamp(_records, record.createdAt);
    _records.add(record);
    return record;
  }

  @override
  QuestionRecord? byId(String qid) {
    for (final QuestionRecord record in _records) {
      if (record.qid == qid) return record;
    }
    return null;
  }

  @override
  QuestionRecord? markAnswered(String qid, List<String> answers) {
    final QuestionRecord? record = byId(qid);
    if (record == null || !record.isPending) return null;
    _applyAnswers(record, answers);
    return record;
  }

  @override
  QuestionRecord? markCancelled(String qid) {
    final QuestionRecord? record = byId(qid);
    if (record == null || !record.isPending) return null;
    record
      ..status = QuestionStatus.cancelled
      ..answeredAt = DateTime.now().millisecondsSinceEpoch;
    return record;
  }

  @override
  List<QuestionRecord> list({
    String? agentId,
    String? sessionId,
    bool onlyPending = false,
  }) => _records
      .where(
        (QuestionRecord r) =>
            (agentId == null || agentId.isEmpty || r.agentId == agentId) &&
            (sessionId == null ||
                sessionId.isEmpty ||
                r.sessionId == sessionId) &&
            (!onlyPending || r.isPending),
      )
      .toList(growable: false);

  @override
  int removeForAgent(String agentId) {
    final int before = _records.length;
    _records.removeWhere((QuestionRecord r) => r.agentId == agentId);
    return before - _records.length;
  }

  @override
  Future<void> flush() async {}

  @override
  Object? get lastError => null;
}

/// 落盘实现：全部提问存在一个原子快照文件里（`<数据根>/data/questions.json`）。
///
/// 写入走 [WriteQueue]（同一文件串行 + write-behind），与 [FileTreeStore] 同语义：
/// 先改内存、再排队落盘，`flush()` 保证落盘完成。
class FileQuestionStore implements QuestionStore {
  FileQuestionStore(this.paths, {List<QuestionRecord>? seed}) {
    load();
    for (final QuestionRecord record in seed ?? const <QuestionRecord>[]) {
      add(record);
    }
  }

  final TreePaths paths;
  final WriteQueue _queue = WriteQueue();
  final List<QuestionRecord> _records = <QuestionRecord>[];
  bool _loaded = false;

  /// 从磁盘装载（幂等；构造时已调用一次，测试可显式再调）。
  void load() {
    if (_loaded) return;
    _loaded = true;
    final String? text = AtomicFile.readStringOrNullSync(paths.questionsFile);
    if (text == null || text.trim().isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return; // 文件被手改坏：当作空表，不阻止核心启动
    }
    if (decoded is! List<dynamic>) return;
    for (final dynamic item in decoded) {
      if (item is! Map<dynamic, dynamic>) continue;
      _records.add(
        QuestionRecord.fromJson(
          item.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
        ),
      );
    }
  }

  @override
  QuestionRecord add(QuestionRecord record) {
    record.createdAt = _nextQuestionStamp(_records, record.createdAt);
    _records.add(record);
    _persist();
    return record;
  }

  @override
  QuestionRecord? byId(String qid) {
    for (final QuestionRecord record in _records) {
      if (record.qid == qid) return record;
    }
    return null;
  }

  @override
  QuestionRecord? markAnswered(String qid, List<String> answers) =>
      _update(qid, (QuestionRecord r) => _applyAnswers(r, answers));

  @override
  QuestionRecord? markCancelled(String qid) => _update(
    qid,
    (QuestionRecord r) => r
      ..status = QuestionStatus.cancelled
      ..answeredAt = DateTime.now().millisecondsSinceEpoch,
  );

  @override
  List<QuestionRecord> list({
    String? agentId,
    String? sessionId,
    bool onlyPending = false,
  }) => _records
      .where(
        (QuestionRecord r) =>
            (agentId == null || agentId.isEmpty || r.agentId == agentId) &&
            (sessionId == null ||
                sessionId.isEmpty ||
                r.sessionId == sessionId) &&
            (!onlyPending || r.isPending),
      )
      .toList(growable: false);

  @override
  int removeForAgent(String agentId) {
    final int before = _records.length;
    _records.removeWhere((QuestionRecord r) => r.agentId == agentId);
    final int removed = before - _records.length;
    if (removed > 0) _persist();
    return removed;
  }

  @override
  Future<void> flush() => _queue.flush();

  @override
  Object? get lastError => _queue.lastError;

  QuestionRecord? _update(
    String qid,
    void Function(QuestionRecord record) mutate,
  ) {
    final QuestionRecord? record = byId(qid);
    if (record == null || !record.isPending) return null;
    mutate(record);
    _persist();
    return record;
  }

  void _persist() {
    final String json = const JsonEncoder.withIndent('  ')
        .convert(_records.map((QuestionRecord r) => r.toJson()).toList());
    _queue.enqueue(
      paths.questionsFile,
      () => AtomicFile.writeStringAtomic(paths.questionsFile, '$json\n'),
    );
  }
}
