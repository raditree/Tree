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
        question: request.question,
        options: request.options,
        createdAt: now,
      ),
    );
    // 聊天记录里的提问卡片（`answered` 由会话历史接口按提问记录覆盖）
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
      ),
    );

    final _InFlight flight = _InFlight(Completer<QuestionOutcome>());
    _inFlight[qid] = flight;
    broadcast(<String, dynamic>{
      'type': WsOutboundType.askUserQuestion,
      'id': qid,
      'question': request.question,
      'options': request.options,
      'agent_id': request.agentId,
      'session_id': request.sessionId,
      if (request.teamId.isNotEmpty) 'team_id': request.teamId,
      'is_member': request.isMember,
    });
    log?.call('提问 $qid（agent=${request.agentId}）等待作答');

    flight.poll = Timer.periodic(pollInterval, (Timer _) {
      if (request.isCancelled()) cancel(qid, reason: '本轮已停止');
    });
    final Duration? limit = timeout ?? defaultTimeout;
    if (limit != null) {
      flight.timeout = Timer(limit, () {
        log?.call('提问 $qid 超时（${limit.inSeconds}s）');
        _finish(qid, const QuestionOutcome(answer: '', cancelled: true));
        questions.markCancelled(qid);
        _broadcastResolved(qid, cancelled: true);
      });
    }
    return flight.completer.future;
  }

  /// 作答：只有仍处于 `pending` 的提问会被接受（幂等）。
  ///
  /// 返回是否真的改变了状态——调用方据此决定"重复作答"要不要提示。
  bool answer(String qid, String answer) {
    final QuestionRecord? record = questions.markAnswered(qid, answer);
    if (record == null) return false;
    log?.call('提问 $qid 已作答');
    final bool inFlight = _inFlight.containsKey(qid);
    _broadcastResolved(qid, answer: answer);
    _finish(qid, QuestionOutcome(answer: answer));
    if (!inFlight) {
      // 重启后的补答（或恢复历史卡片后作答）：没有在途生成可唤醒，就把答案按
      // 参考实现的 [AskUserQuestion 用户回答] 形态写进会话——下一轮生成读到它
      // 就相当于"续跑"，用户不必重述。
      transcript.appendMessage(
        CoreMessage(
          id: CoreIds.message(),
          agentId: record.agentId,
          sessionId: record.sessionId,
          role: 'user',
          content: '$answerPrefix$answer',
          timestamp: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      log?.call('提问 $qid 无在途生成，答案已写入会话等待下一轮');
    }
    return true;
  }

  /// 取消：用户显式取消、`stop` 或超时都会走这里（幂等）。
  bool cancel(String qid, {String reason = ''}) {
    final QuestionRecord? record = questions.markCancelled(qid);
    if (record == null) return false;
    log?.call('提问 $qid 已取消${reason.isEmpty ? '' : '（$reason）'}');
    _broadcastResolved(qid, cancelled: true);
    _finish(qid, const QuestionOutcome(answer: '', cancelled: true));
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
      _finish(qid, const QuestionOutcome(answer: '', cancelled: true));
    }
  }

  void _broadcastResolved(
    String qid, {
    String answer = '',
    bool cancelled = false,
  }) {
    broadcast(<String, dynamic>{
      'type': WsOutboundType.askUserQuestionResolved,
      'data': <String, dynamic>{
        'id': qid,
        'answer': answer,
        'cancelled': cancelled,
      },
    });
  }

  void _finish(String qid, QuestionOutcome outcome) {
    final _InFlight? flight = _inFlight.remove(qid);
    if (flight == null) return;
    flight.dispose();
    if (!flight.completer.isCompleted) flight.completer.complete(outcome);
  }
}
