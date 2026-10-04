/// 提问通道：工具层与编排层之间的契约（M5a）。
///
/// 为什么单独抽一层：`ask_user_question` 工具的执行体在工具层（[BuiltinTools]），
/// 而"把问题推给前端并等待作答"的回路在编排层（`QuestionBroker`）。用具名契约
/// 把两者隔开，工具层就不必反向依赖编排层（依赖方向保持 tool ← agent）。
library;

/// 一道问题（多问题：`ask_user_question` 一次调用可以问多道，这是其中一道）。
///
/// 形状与前端 `lib/ui/models/message.dart` 里解析的 `{question, options}` 一致
/// （帧 / 会话卡片 / `data/questions.json` 三处共用这一个形状）。
class AskedQuestion {
  AskedQuestion({required this.question, List<String>? options})
    : options = options ?? const <String>[];

  /// 题面正文。
  final String question;

  /// 候选选项（可为空；用户始终可以自由输入）。
  final List<String> options;

  /// 单问简写形态（`question` 字符串直接当一项）。
  factory AskedQuestion.single(String question, [List<String>? options]) =>
      AskedQuestion(question: question, options: options);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'question': question,
    'options': options,
  };

  static AskedQuestion fromJson(Map<String, dynamic> json) => AskedQuestion(
    question: (json['question'] ?? '').toString(),
    options: (json['options'] as List<dynamic>?)
        ?.map((dynamic e) => e.toString())
        .toList(),
  );

  @override
  String toString() =>
      options.isEmpty ? question : '$question（选项：${options.join(' / ')}）';
}

/// 一次提问的请求上下文。
///
/// **多问题口径**（用户 2026-10-04 定稿）：[questions] 是**唯一**的问题来源，
/// 至少一项；单问只是它的退化形态（长度 1）。[question] / [options] 保留为
/// "第一问"的兼容读法，老代码与临时员工的题面前缀因此不必到处改。
class AskQuestionRequest {
  AskQuestionRequest({
    required this.agentId,
    required this.sessionId,
    required this.questions,
    this.teamId = '',
    this.isMember = false,
    this.subagentId = '',
    this.subagentName = '',
    this.subagentParentId = '',
    this.subagentLevel = 0,
    required this.isCancelled,
  });

  final String agentId;
  final String sessionId;

  /// 要问的全部问题（**至少一项**；顺序即展示与作答顺序）。
  final List<AskedQuestion> questions;

  /// 团队成员提问时带上队伍归属（前端据此标注来源）。
  final String teamId;
  final bool isMember;

  /// **临时员工提问**的来源标记（空串 = 主 agent / 团队成员在问）。
  ///
  /// 问题文本里也会带上它的名字（"【临时员工「张三」提问】…"）：右侧「问题回复」页
  /// 只看提问记录（那里没有这套标记），靠正文也认得出是谁在问。
  final String subagentId;
  final String subagentName;
  final String subagentParentId;
  final int subagentLevel;

  /// 本轮是否已被**硬取消**（`stop` / 删除 agent / 关服）。等待作答期间要能立刻退出。
  ///
  /// **插话不算取消**（用户 2026-10-04 断言：「任何工具调用执行期间不被插话打断，
  /// 插入消息（包括 terminal/subagent hook 完成消息）在工具调用期间必须排队等待」）：
  /// 传进来的必须是"真取消"那条谓词（见 `AgentRunContext.isHardCancelled`），
  /// 否则一条 hook 完成提示就能把用户正看着的提问掐掉。
  final bool Function() isCancelled;

  /// 第一问的正文（兼容读法；单问时就是全部）。
  String get question => questions.first.question;

  /// 第一问的候选选项（兼容读法）。
  List<String> get options => questions.first.options;

  /// 是否一次问了多道。
  bool get isMulti => questions.length > 1;
}

/// 一次提问的结果。
class QuestionOutcome {
  const QuestionOutcome({
    this.answers = const <String>[],
    this.cancelled = false,
  });

  /// 逐题答案（与 [AskQuestionRequest.questions] **等长**；未作答项为空串）。
  /// 取消时为空表。
  final List<String> answers;

  /// 是否被取消/超时（未作答）。
  final bool cancelled;

  /// 单问兼容读法（取消时为空串；多问时用 `；` 连接——展示口径见 [formatAnswerLines]）。
  String get answer => cancelled
      ? ''
      : answers.where((String a) => a.trim().isNotEmpty).join('；');

  @override
  String toString() =>
      cancelled ? 'QuestionOutcome(cancelled)' : 'QuestionOutcome(${answers.join(' | ')})';
}

/// 「答案」的排版：**唯一实现**（工具结果、重启后的补答消息、提问记录里的摘要
/// 展示都调它，别在别处复制第二套）。
///
/// - 单问：`B`（与"只支持单问题"时期**逐字一致**）
/// - 多问：逐题一行，题面带在行里（模型据此把答案对回问题），未作答写 `（未作答）`
String formatAnswerLines(List<AskedQuestion> questions, List<String> answers) {
  String at(int i) => i < answers.length ? answers[i].trim() : '';
  if (questions.length <= 1) {
    final String only = at(0);
    return only.isEmpty ? '（未作答）' : only;
  }
  final StringBuffer buffer = StringBuffer();
  for (int i = 0; i < questions.length; i++) {
    if (i > 0) buffer.write('\n');
    final String text = at(i);
    buffer.write(
      '第${i + 1}题（${_questionLabel(questions[i].question)}）：'
      '${text.isEmpty ? '（未作答）' : text}',
    );
  }
  return buffer.toString();
}

/// 题面摘要（多问时的行内标题；太长就截断并如实标注省略号）。
String _questionLabel(String question) {
  final String text = question.replaceAll(RegExp(r'\s+'), ' ').trim();
  const int max = 40;
  return text.length <= max ? text : '${text.substring(0, max)}…';
}

/// 把 [answers] 归一成与 [questions] 等长的表（缺项补空串、多余截掉）。
///
/// 单问时期的老调用方只回一个答案 ⇒ 这里天然变成"第一问有答、其余未作答"，
/// 是兼容老前端（只回 `answer`）的落点。
List<String> normalizeAnswers(
  List<AskedQuestion> questions,
  List<String>? answers,
) {
  final List<String> source = answers ?? const <String>[];
  return <String>[
    for (int i = 0; i < questions.length; i++)
      i < source.length ? source[i].trim() : '',
  ];
}

/// 把来源标记（如 `【临时员工「张三」提问】`）加在**第一问**的题面上。
///
/// 多问题时只加一次：卡片本来就显示在那名提问者名下（帧/消息都带 subagent 标记），
/// 每道题都重复一遍名字只会把题面撑得读不下去（见 `WorkspaceToolRunner` 的临时
/// 员工包装）。单问时就是"给题面加前缀"这一件事。
List<AskedQuestion> prefixFirstQuestion(
  List<AskedQuestion> questions,
  String prefix,
) => <AskedQuestion>[
  AskedQuestion(
    question: '$prefix${questions.first.question}',
    options: questions.first.options,
  ),
  ...questions.skip(1),
];

/// 提问通道（实现见 `QuestionBroker`）。
typedef AskQuestion =
    Future<QuestionOutcome> Function(AskQuestionRequest request);
