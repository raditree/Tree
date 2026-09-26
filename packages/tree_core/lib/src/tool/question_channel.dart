/// 提问通道：工具层与编排层之间的契约（M5a）。
///
/// 为什么单独抽一层：`ask_user_question` 工具的执行体在工具层（[BuiltinTools]），
/// 而"把问题推给前端并等待作答"的回路在编排层（`QuestionBroker`）。用具名契约
/// 把两者隔开，工具层就不必反向依赖编排层（依赖方向保持 tool ← agent）。
library;

/// 一次提问的请求上下文。
class AskQuestionRequest {
  const AskQuestionRequest({
    required this.agentId,
    required this.sessionId,
    required this.question,
    this.options = const <String>[],
    this.teamId = '',
    this.isMember = false,
    required this.isCancelled,
  });

  final String agentId;
  final String sessionId;
  final String question;

  /// 候选选项（可为空；用户始终可以自由输入）。
  final List<String> options;

  /// 团队成员提问时带上队伍归属（前端据此标注来源）。
  final String teamId;
  final bool isMember;

  /// 本轮是否已被取消（`stop`）。等待作答期间要能立刻退出。
  final bool Function() isCancelled;
}

/// 一次提问的结果。
class QuestionOutcome {
  const QuestionOutcome({required this.answer, this.cancelled = false});

  /// 用户回答（[cancelled] 时为空串）。
  final String answer;

  /// 是否被取消/超时（未作答）。
  final bool cancelled;

  @override
  String toString() =>
      cancelled ? 'QuestionOutcome(cancelled)' : 'QuestionOutcome($answer)';
}

/// 提问通道（实现见 `QuestionBroker`）。
typedef AskQuestion = Future<QuestionOutcome> Function(
  AskQuestionRequest request,
);
