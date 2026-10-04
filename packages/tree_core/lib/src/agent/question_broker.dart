import 'dart:async';

import 'package:tree_protocol/tree_protocol.dart';

import '../store/tree_store.dart';
import '../tool/question_channel.dart';
import '../util/ids.dart';
import 'question_store.dart';

/// 一个在途提问（等待作答的 Completer + 两个定时器）。
class _InFlight {
  _InFlight(this.completer);

  final Completer<QuestionOutcome> completer;

  /// 轮询取消标志（`stop` 之后立刻收尾；[QuestionBroker.cancelForAgent] 是快路径）。
  Timer? poll;

  /// 超时兜底（默认不设：提问可以等到用户回来）。
  Timer? timeout;

  void dispose() {
    poll?.cancel();
    timeout?.cancel();
  }
}

/// 提问回路（M5a）：把"工具要问用户"变成"下行帧 + 等待作答"，作答后恢复生成。
///
/// 三件事必须一起成立，缺一个都会造成"看起来能问、其实卡死"：
/// 1. **先落盘再推帧**：进程被杀/重启后，右侧「问题回复」页仍能列出待答提问；
/// 2. **作答是幂等的**：WS `user_answer` 与 REST `POST /api/questions/{qid}/answer`
///    可能同时到达（中栏点选 + 右栏提交），只有第一次生效；
/// 3. **取消能打断等待**：`stop` 会取消该 agent 的全部在途提问，工具立刻拿到
///    `cancelled` 结果，工具循环因此能收敛而不是永远挂着。
///
/// **多问题口径**（用户 2026-10-04）：一次 `ask` = 一条记录 / 一张卡片 / 一个在途等待，
/// 里面可以有 N 道题；作答是**逐题一次交齐**（[answer] 收 `List<String>`），
/// 缺项按"未作答"落库。等待与取消的口径一个字没变（仍然是一个 Completer）。
class QuestionBroker {
  QuestionBroker({
    required this.questions,
    required this.transcript,
    required this.broadcast,
    this.log,
    this.pollInterval = const Duration(milliseconds: 500),
    this.defaultTimeout,
  });

  /// 提问记录（跨会话状态与答案的真源）。
  final QuestionStore questions;

  /// 会话消息存储：提问同时写一条 `kind = ask_user_question` 的卡片消息，
  /// 这样重载历史时聊天记录里仍有那张卡片（前端按消息渲染）。
  final TreeStore transcript;

  /// 下行帧通道（生产环境是 `WsHub.broadcast`）。
  final void Function(Map<String, dynamic> frame) broadcast;

  final void Function(String message)? log;

  /// 补答写入会话时的前缀（与参考实现一致，便于历史可读）。
  static const String answerPrefix = '[AskUserQuestion 用户回答] ';

  /// 取消标志轮询间隔。
  final Duration pollInterval;

  /// 默认超时（null = 不超时，可等到用户回来）。
  final Duration? defaultTimeout;

  final Map<String, _InFlight> _inFlight = <String, _InFlight>{};

  /// 当前在途提问数（自检/日志用）。
  int get inFlightCount => _inFlight.length;

  /// 待答提问（REST `GET /api/questions` 与自检用）。
  List<QuestionRecord> pending({String? agentId, String? sessionId}) =>
      questions.list(agentId: agentId, sessionId: sessionId, onlyPending: true);

  /// 发起提问：落盘 → 推帧 → 等作答（或取消/超时）。
  Future<QuestionOutcome> ask(AskQuestionRequest request, {Duration? timeout}) {
    final String qid = CoreIds.question();
    final int now = DateTime.now().millisecondsSinceEpoch;
    questions.add(
      QuestionRecord(
        qid: qid,
        agentId: request.agentId,
        teamId: request.teamId,
        sessionId: request.sessionId,
        isMember: request.isMember,
        // 一次提问 = 一条记录（一个 qid / 一张卡片），里面可以有 N 道题
        questions: request.questions,
        createdAt: now,
      ),
    );
    // 聊天记录里的提问卡片（`answered` 由会话历史接口按提问记录覆盖）
    //
    // 临时员工提问：卡片归集到**会话主人**的会话（[AskQuestionRequest.agentId] 已由
    // 工具层改写），并带上它的标记 ⇒ 前端能把这句提问显示在这名临时员工名下
    // （问题正文里也有它的名字，右侧「问题回复」页只看提问记录，靠正文认人）。
    transcript.appendMessage(
      CoreMessage(
        id: qid,
        agentId: request.agentId,
        sessionId: request.sessionId,
        role: 'agent',
        content: request.question,
        timestamp: now,
        kind: 'ask_user_question',
        options: request.options,
        // 卡片消息自带完整问题表（记录仍是作答状态与答案的真源）
        questions: request.questions
            .map((AskedQuestion q) => q.toJson())
            .toList(),
        subagentId: request.subagentId,
        subagentName: request.subagentName,
        subagentParentId: request.subagentParentId,
        subagentLevel: request.subagentLevel,
      ),
    );

    final _InFlight flight = _InFlight(Completer<QuestionOutcome>());
    _inFlight[qid] = flight;
    broadcast(<String, dynamic>{
      'type': WsOutboundType.askUserQuestion,
      'id': qid,
      // 多问题：完整的问题表（新前端按它逐题渲染、逐题作答）
      'questions': request.questions
          .map((AskedQuestion q) => q.toJson())
          .toList(),
      // 兼容（老前端只认第一问）：`question` / `options` 是第一问的简写形态
      'question': request.question,
      'options': request.options,
      'agent_id': request.agentId,
      'session_id': request.sessionId,
      if (request.teamId.isNotEmpty) 'team_id': request.teamId,
      'is_member': request.isMember,
      // 临时员工提问的标记（空串 = 主 agent / 团队成员在问）
      if (request.subagentId.isNotEmpty) ...<String, dynamic>{
        'subagent_id': request.subagentId,
        'subagent_name': request.subagentName,
        'subagent_parent_id': request.subagentParentId,
        'subagent_level': request.subagentLevel,
      },
    });
    log?.call('提问 $qid（agent=${request.agentId}）等待作答');

    flight.poll = Timer.periodic(pollInterval, (Timer _) {
      if (request.isCancelled()) cancel(qid, reason: '本轮已停止');
    });
    final Duration? limit = timeout ?? defaultTimeout;
    if (limit != null) {
      flight.timeout = Timer(limit, () {
        log?.call('提问 $qid 超时（${limit.inSeconds}s）');
        _finish(qid, const QuestionOutcome(cancelled: true));
        questions.markCancelled(qid);
        _broadcastResolved(qid, cancelled: true);
      });
    }
    return flight.completer.future;
  }

  /// 作答：只有仍处于 `pending` 的提问会被接受（幂等）。
  ///
  /// [answers] 是**逐题**答案（与记录里的 `questions` 等长；缺项按未作答）。
  /// 返回是否真的改变了状态——调用方据此决定"重复作答"要不要提示。
  bool answer(String qid, List<String> answers) {
    final QuestionRecord? record = questions.markAnswered(qid, answers);
    if (record == null) return false;
    // 落库那份已归一（等长、未作答项 = 空串）⇒ 后续一律用它，别拿原始入参
    final List<String> normalized = List<String>.of(record.answers);
    final String text = formatAnswerLines(record.questions, normalized);
    log?.call('提问 $qid 已作答');
    final bool inFlight = _inFlight.containsKey(qid);
    _broadcastResolved(qid, answer: text, answers: normalized);
    _finish(qid, QuestionOutcome(answers: normalized));
    if (!inFlight) {
      // 重启后的补答（或恢复历史卡片后作答）：没有在途生成可唤醒，就把答案按
      // 参考实现的 [AskUserQuestion 用户回答] 形态写进会话——下一轮生成读到它
      // 就相当于"续跑"，用户不必重述。多问题时逐题成行。
      transcript.appendMessage(
        CoreMessage(
          id: CoreIds.message(),
          agentId: record.agentId,
          sessionId: record.sessionId,
          role: 'user',
          content: record.isMulti
              ? '$answerPrefix\n$text'
              : '$answerPrefix$text',
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      log?.call('提问 $qid 无在途生成，答案已写入会话等待下一轮');
    }
    return true;
  }

  /// 取消：用户显式取消、`stop` 或超时都会走这里（幂等）。
  ///
  /// **只要还有在途等待就必须收尾**，即使提问记录已经不在——删除 agent 时
  /// `QuestionStore.removeForAgent` 会把记录直接摘掉，若这里因为"记录没了"而
  /// 提前返回，等答案的工具就永远拿不到结果：那一轮既不收敛、`isRunning` 永远为真，
  /// 连 `stop`/`cancelForAgent`（它们都按 store 里的 pending 列表遍历）也救不回来
  /// （实测见 test/question_broker_test.dart『记录被摘掉』用例）。
  bool cancel(String qid, {String reason = ''}) {
    final QuestionRecord? record = questions.markCancelled(qid);
    final bool settled = _finish(
      qid,
      const QuestionOutcome(cancelled: true),
    );
    if (record == null) {
      // 记录已不在：state 没变，但**在途等待被收尾**同样是有效结果（返回 true）
      if (settled) {
        log?.call(
          '提问 $qid 的记录已不存在，仍收尾在途等待'
          '${reason.isEmpty ? '' : '（$reason）'}',
        );
      }
      return settled;
    }
    log?.call('提问 $qid 已取消${reason.isEmpty ? '' : '（$reason）'}');
    _broadcastResolved(qid, cancelled: true);
    return true;
  }

  /// 取消某 agent 的全部待答提问（收到 `stop` 时调用），返回取消数。
  int cancelForAgent(String agentId) {
    int count = 0;
    for (final QuestionRecord record in pending(agentId: agentId)) {
      if (cancel(record.qid, reason: 'agent 已停止')) count++;
    }
    return count;
  }

  /// 取消某会话的全部待答提问，返回取消数。
  int cancelForSession(String agentId, String sessionId) {
    int count = 0;
    for (final QuestionRecord record in pending(
      agentId: agentId,
      sessionId: sessionId,
    )) {
      if (cancel(record.qid, reason: '会话已停止')) count++;
    }
    return count;
  }

  /// 关停：取消全部在途等待（进程要退出，不能让生成任务挂着）。
  void dispose() {
    for (final String qid in _inFlight.keys.toList(growable: false)) {
      _finish(qid, const QuestionOutcome(cancelled: true));
    }
  }

  void _broadcastResolved(
    String qid, {
    String answer = '',
    List<String>? answers,
    bool cancelled = false,
  }) {
    final Map<String, dynamic> data = <String, dynamic>{
      'id': qid,
      'answer': answer,
      'cancelled': cancelled,
    };
    // 多问题：逐题答案（老前端忽略这个键，只看 answer）
    if (answers != null) data['answers'] = answers;
    broadcast(<String, dynamic>{
      'type': WsOutboundType.askUserQuestionResolved,
      'data': data,
    });
  }

  /// 收尾一个在途等待；返回是否真的完成了一个（记录已消失时也照样收尾）。
  bool _finish(String qid, QuestionOutcome outcome) {
    final _InFlight? flight = _inFlight.remove(qid);
    if (flight == null) return false;
    flight.dispose();
    if (!flight.completer.isCompleted) flight.completer.complete(outcome);
    return true;
  }
}
