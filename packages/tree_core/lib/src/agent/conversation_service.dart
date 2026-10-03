import 'dart:async';
import 'dart:convert';

import 'package:tree_protocol/tree_protocol.dart';

import '../plugin/agent_events.dart';
import '../settings/core_settings.dart';
import '../store/tree_store.dart';
import '../util/ids.dart';
import '../util/tokens.dart' as tokens;
import '../llm/llm_agent_engine.dart';
import '../ws/ws_hub.dart';
import '../store/subagent_registry.dart';
import '../tool/subagent_tool.dart';
import 'agent_engine.dart';
import 'compaction_service.dart';
import 'question_broker.dart';
import 'scripted_agent.dart';
import 'subagent_service.dart';
import 'workspace_prompt.dart';

/// 一次生成任务的取消令牌。
class _RunToken {
  /// 这一轮归属的 agent / 会话。运行键 = `agentId|sessionId`（见 [_runKey]）：
  /// **同一个 agent 的不同会话是两条独立任务链**，可以并行生成。
  String agentId = '';
  String sessionId = '';

  /// **归属的真实 agent**（只有临时员工轮非空 = 它的会话主人）。
  ///
  /// 用途：`stop` 与"新消息插话"要能连带停掉"父 agent 正在阻塞等待的那批临时员工"，
  /// 否则父那轮会一直卡在等一个没人管的子任务上。
  String ownerAgentId = '';

  bool cancelled = false;

  /// 是否因"**收到新消息**"而被打断（与用户按 `stop` 区分）。
  ///
  /// 为什么要区分：用户按 stop 时应当看到"已停止本轮生成。"这条可见提示；
  /// 而"我发新消息 → 旧那轮自动让位"是打断/插话（interjection）语义，
  /// 再刷一条"已停止"只会造成噪声（用户根本没按停止）。
  bool interrupted = false;

  /// 这一轮是不是**人**叫停的（用户按停止 / 用户插话）。
  ///
  /// 与"系统内部收敛"刻意分开（用户 2026-10-04 的硬要求：停止后不用向父 agent 发结束
  /// 提示，用户自己说原因；但**其它原因导致的中止必须报**）。系统内部的收敛有两类，
  /// 都不算人叫停：hook 提示唤醒（wake）、以及别的临时员工完成报告注入时连带收敛
  /// 同一会话里还在跑的那些——那两类被中止的活，发起者**有权知道**它没干完。
  bool userStopped = false;
}

/// 一轮生成的产出：临时员工轮要拿它的"最终报告"回灌给发起者。
class _TurnOutcome {
  const _TurnOutcome({
    this.report = '',
    this.error = '',
    this.cancelled = false,
    this.userStopped = false,
  });

  /// 本轮最后一段正文（最终回复；没有正文时为空串）。
  final String report;

  /// 可读失败原因（空串 = 没失败）。
  final String error;

  /// 这一轮是不是**被人为中止**（任何原因）的，而不是自然结束或出错。
  ///
  /// 区别很重要（用户 2026-10-04）：「停止后不用向父 agent 发结束提示（用户自己说原因），
  /// 用户可能再次向 subagent 发消息使其启动，自然结束后回父 agent 总结。但如果是其他
  /// 错误导致的中止要向父 agent 发消息提示」——所以"人为中止"与"出错"必须分得开。
  final bool cancelled;

  /// 中止这件事是不是**人**做的（用户按停止 / 用户插话）。
  ///
  /// 只有"人叫停"才不向发起者注入结束提示（见 [cancelled] 与 subagent 的完成注入）。
  final bool userStopped;
}

/// 本轮正在生成的一条消息（与前端消息一一对应：先立 start，再追加 chunk）。
class _PendingMessage {
  _PendingMessage({required this.id, required this.kind});

  final String id;
  final String kind;
  final StringBuffer content = StringBuffer();
  String? toolName;
  Map<String, dynamic>? toolArguments;

  /// 模型原始参数串（回灌历史时要逐字复现的那一份）。
  String toolArgumentsRaw = '';
  String toolResult = '';

  /// 送模型那一份工具结果（状态前缀 + 门控之后）；空 = 与 [toolResult] 相同。
  String toolResultForModel = '';
  String toolCallId = '';

  /// **工具调用轮次**（本任务内从 1 开始；插件生态的 `agent.tool_call` 事件带它）。
  int round = 0;
}

/// 会话服务：把 WS 上行的 `user_message` / `stop` 变成"落库 + 流式下行"。
///
/// 本类只做**协议适配**：把 [AgentEngine] 产出的 [AgentEvent] 翻成既有 WS 帧，
/// 并把本轮产生的消息按事件顺序落库。生成逻辑（真实 LLM / 占位回显）在引擎里，
/// 因此 M5 的成员编排可以复用同一套事件而无需改这里。
///
/// 帧映射（Q3 起按**段**下发，与参考实现 `server/agent/chat.py:1984-2210` 一致）：
/// - [AgentText]：每段一个 `msg_start(kind=text)` + `msg_chunk`…，段遇工具调用
///   即关闭（`msg_end`）并**独立落库**——工具轮之间的中间正文因此单独成消息，
///   不会被并进最终回复；
/// - [AgentThinking]：每段一个 `msg_start(kind=thinking)` + `msg_chunk`…，段遇
///   正文 / 工具调用 / 提问即关闭并落库（`kind=thinking`）；
/// - [AgentToolStart]/[AgentToolEnd]：先关掉在开的思考与正文段，再立卡片、填结果
///   （同 id，落库 `kind=tool`）；
/// - [AgentUsage] → `msg_usage`（挂在最近开始的段上）；
/// - [AgentError] → `error` 帧 **+ 一条可见的 agent 文本消息**
///   （前端对 `error` 帧是静默忽略的，只发 error 用户会看不到任何反馈）；
/// - [AgentDone] → 逐段 `msg_end` + `agent_status(idle)`；结束时仍打开的正文段
///   就是**最终回复**，整段全文与 usage 都挂在它上面（usage 只挂最后一条）。
///
/// 节奏控制（Q13，可整体关闭，见 [pacingEnabled]）：
/// - token 管道：思考 / 正文 / **工具调用参数**共用同一条 [TokenPacer]，口径为
///   `token = ceil(字符数 / token_scale)`（`util/tokens.dart` 的唯一实现），
///   速率取 `settings.token_acquisition_rate`；工具结果**直接推**、不延迟；
/// - 推送刷新帧率：增量攒帧后按帧率合并成一条 `msg_chunk`（[_ChunkPump]），
///   同一 message id 内带**严格递增的单调序号**（`WsStreamSeq`）——断线补发队列
///   原样重播帧时，前端据此把"已经渲染过的同一片段"判掉（M9 重播去重）。
///
/// 插件生态（M9 追加）：每次工具调用开始 / 结束各发一条 `agent.tool_call` 事件
/// （[agentEvents]），插件据此统计轮次与耗时、超限时用执行站的 `agent.stop` 停下
/// 这一轮——核心侧不再有工具轮次静态上限（plan §2 Q8）。**默认未接线 = no-op**。
///
/// 并发策略：**按 agent×会话**——同一会话内串行（同一会话的流式片段若交错下发，
/// 前端的 `msg_chunk` 追加会互相污染），**不同会话并行**（前端按 `session_id` 过滤
/// 下行帧，见 `message_panel._isForCurrentSession`；跨会话的消息既不打断也不排队，
/// 各会话各自发言）。
class ConversationService {
  ConversationService({
    required this.store,
    required this.hub,
    required this.settings,
    this.questions,
    this.compaction,
    this.subagents,
    AgentEngine? engine,
    this.pacer,
    this.pacingEnabled,
  }) : engine = engine ?? ScriptedAgent() {
    // 工具循环内压缩（Q1-③）：引擎（调用方构造）不认识存储与压缩服务，压缩服务
    // 也拿不到引擎；会话服务两边都有，因此在这里把钩子接上。没接的引擎只是少了
    // "轮内压缩"这一层保护，其余行为不变。
    final AgentEngine target = this.engine;
    if (target is LlmAgentEngine) {
      target.toolTurnCompactor = _compactTurnContext;
      // 压缩插件复用前缀：把"引擎这一轮会发的那份线形请求"供给压缩服务
      // （插件据此在自己的 llm.call 里吃端点前缀缓存；见 CompactionService.wireRequestProvider）
      compaction?.wireRequestProvider =
          (CoreAgent agent, CoreSession session) =>
              target.wireRequestFor(_contextOf(agent, session));
    }
    // 压缩的过程提示（重试进度）也走会话：落一条 llm_hidden 的消息，用户看得见、模型看不到
    if (compaction != null) {
      compaction!.noticeSink = _sendHiddenNotice;
    }
  }

  final TreeStore store;
  final WsHub hub;
  final CoreSettings settings;

  /// 提问回路（M5a）；为 null 时 `user_answer` / `cancel_question` 帧被忽略。
  final QuestionBroker? questions;

  /// 上下文压缩（M7d-4）；为 null 时不做自动压缩（最小骨架/部分测试）。
  final CompactionService? compaction;

  /// 会话级**临时员工**名册（subagent）；为 null 时本服务不认识临时员工
  /// （`runSubagent` 仍可用，只是收尾不清理索引——生产由 CLI 注入）。
  final SubagentRegistry? subagents;

  final AgentEngine engine;

  /// token 管道节拍器（Q13）；非 null 时**每一轮都复用它**（测试注入可控时钟）。
  ///
  /// 为空时按 [settings] 的 token 速率与 [pacingEnabled] 每轮新建一个。
  final TokenPacer? pacer;

  /// 节奏控制总开关；null = 自动（见 [_pacingByDefault]）。
  ///
  /// 关闭后 token 管道直接放行、攒帧也不再看计时器——测试要的是"没有时间轴"的
  /// 确定性，而不是"用真实计时器伪造一条时间轴"。
  final bool? pacingEnabled;

  /// **agent 事件发布器**（插件生态，M9 追加）：工具调用开始 / 结束时各发一条
  /// `agent.tool_call`，插件据此统计轮次与耗时（见 `agent_events.dart`）。
  ///
  /// **默认未接线 = no-op**：不接线时事件根本不构造，行为与本改动之前完全一致。
  /// 接线点（主控在 core_server 里接一行）：
  /// ```dart
  /// conversation.agentEvents.sink = pluginBus.dispatchAgentEvent;
  /// ```
  /// 测试可以注入自己的记录器（或 CLI 接总线）来决定要不要发。
  final AgentEventPublisher agentEvents = AgentEventPublisher();

  /// 每个 **agent×会话** 的任务链尾（同一会话串行；不同会话各自一条链 ⇒ 并行）。
  final Map<String, Future<void>> _chains = <String, Future<void>>{};

  /// 每个 **agent×会话** 当前在途任务的取消令牌。
  final Map<String, _RunToken> _running = <String, _RunToken>{};

  /// 运行键：**会话级**。用它而不是 agent id，是因为同一个 agent 的不同会话要能
  /// **并行**跑（跨会话消息既不打断也不排队）；同一会话内仍然串行。
  static String _runKey(String agentId, String sessionId) =>
      '$agentId|$sessionId';

  /// 每个 agent 的**任务代次**：stop 时 +1，丢弃此前还在排队、尚未开始的任务。
  final Map<String, int> _epoch = <String, int>{};

  /// 因 `stop` 被丢弃的排队任务数（自检/测试用）。
  int droppedQueuedCount = 0;

  /// 因"收到新消息"而被打断的在途轮次数（测试与排障用，见 [_interruptForNewMessage]）。
  ///
  /// 只统计**同一会话**的插话；跨会话的消息不会打断任何在途轮次（各会话并行）。
  int interruptedRunCount = 0;

  /// 已提示过的"压缩失败 / 模型没配 max_seqlen"（同一件事只打扰用户一次）。
  final Set<String> _notified = <String>{};

  /// 当前在途生成数（自检/日志用）。
  int get activeRunCount => _running.length;

  /// 某 agent 是否**有任一会话**正在生成（团队名单的 `working` 状态唯一权威）。
  ///
  /// **含它名下的临时员工**：后台临时员工在跑时，它的发起者也算"working"
  /// （这正是用户看到的语义：我派出去的活还在干）。
  bool isRunning(String agentId) => _running.values.any(
    (_RunToken token) =>
        token.agentId == agentId || token.ownerAgentId == agentId,
  );

  /// 处理 `user_message`。
  ///
  /// 帧字段（与现状 server 一致）：
  /// `{type, agent_id, content, attachments, session_id}`。
  Future<void> handleUserMessage(Map<String, dynamic> frame) {
    final String agentId = frame['agent_id'] as String? ?? '';
    final String content = frame['content'] as String? ?? '';
    final String sessionId = frame['session_id'] as String? ?? '';
    // 收件人是**临时员工**（`sub_…`）：这是"用户直接对它说话"（用户 2026-10-04：
    // 「允许用户停止 subagent 的工作、向其发消息」）——复用同一条 `user_message` 帧，
    // 因为语义上它就是一条用户消息，只是收件人不是真 agent（见 [sendToSubagent]）。
    if (subagents?.isSubagent(agentId) ?? false) {
      return sendToSubagent(frame);
    }
    final CoreAgent? agent = store.agent(agentId);
    if (agent == null) {
      _sendError('未知 agent：$agentId');
      return Future<void>.value();
    }
    // 会话解析必须先于排队：前端可能在会话创建前就发消息（session_id 为空）
    final CoreSession session = _resolveSession(agent, sessionId, content);
    store.appendMessage(
      CoreMessage(
        id: CoreIds.message(),
        agentId: agent.id,
        sessionId: session.sessionId,
        role: 'user',
        content: content,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        attachments: _attachments(frame['attachments']),
      ),
    );
    // 新消息到达 = 插话：把**同一会话**在途的那一轮立刻打断（工具循环就此收敛），
    // 让这条新消息的下一轮紧接着跑起来（顺序 / 代次 / 会话边界见 [_interruptForNewMessage]）。
    _interruptForNewMessage(
      agent.id,
      sessionId: session.sessionId,
      byUser: true,
    );
    return _enqueue(
      agent.id,
      session.sessionId,
      () => _runReply(agent, session, content),
    );
  }

  /// 处理 `stop`（单个 agent；`agent_id` 为 TOP 时的**级联**由核心层展开，
  /// 见 `CoreServer._handleStop`）。
  ///
  /// 帧字段：`{type, data:{agent_id, session_id}}`。
  void handleStop(Map<String, dynamic> frame) {
    final Map<String, dynamic> data = _dataOf(frame);
    final String agentId =
        (data['agent_id'] as String?) ?? (frame['agent_id'] as String?) ?? '';
    if (agentId.isEmpty) return;
    cancelAgent(agentId);
  }

  /// 取消某 agent 的当前生成，并**作废它的排队任务**；返回是否真有在途任务。
  ///
  /// 为什么要作废排队任务：`stop` 之后那些还没开始的消息会接着把 agent 拉起来，
  /// 用户看到的"停止"就是假的。参考实现在 stop 时清空 broker 队列，这里用
  /// **epoch** 表达同一语义：入队时记下代次，stop 时代次 +1，旧代次的任务直接
  /// 丢弃（`droppedQueuedCount` 计数便于测试与排障）。
  bool cancelAgent(String agentId) {
    // 先取消在途提问：等待中的工具会立刻拿到 cancelled 结果，工具循环才能收敛。
    questions?.cancelForAgent(agentId);
    _epoch[agentId] = (_epoch[agentId] ?? 0) + 1;
    // stop 是 agent 级的：该 agent 的**每个在途会话**都要停（会话可以并行跑），
    // **以及它名下正在跑的临时员工**（父那轮正卡在等它们）。
    final List<_RunToken> tokens = _running.values
        .where(
          (_RunToken token) =>
              token.agentId == agentId || token.ownerAgentId == agentId,
        )
        .toList(growable: false);
    if (tokens.isEmpty) return false;
    for (final _RunToken token in tokens) {
      token.cancelled = true;
      // 人按的停止：被中止的临时员工**不**向发起者注入结束提示（用户自己会说原因）
      token.userStopped = true;
    }
    return true;
  }

  /// 团队消息投递（M5c）：把 **agent** 发来的消息落库并触发一轮生成。
  ///
  /// 与 `user_message` 的区别：
  /// - 消息带 `[来自 <发送者>]` 前缀——本项目的消息模型没有 sender 字段，而模型
  ///   必须知道该向谁回发（参考实现用 session.sender_id 表达同一件事）；
  /// - 到点即执行：投递是"新消息"，不受此前 stop 的历史代次影响。
  Future<void> deliver({
    required String agentId,
    required String sessionId,
    required String content,
    String senderId = '',
    String senderName = '',
  }) {
    final CoreAgent? agent = store.agent(agentId);
    if (agent == null) return Future<void>.value();
    final CoreSession session = _resolveSession(agent, sessionId, content);
    final String sender = senderName.trim().isEmpty ? senderId : senderName;
    final String text = sender.trim().isEmpty
        ? content
        : '[来自 $sender] $content';
    store.appendMessage(
      CoreMessage(
        id: CoreIds.message(),
        agentId: agent.id,
        sessionId: session.sessionId,
        role: 'user',
        content: text,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    // 团队消息也是"有人对它说话"：同样打断**同一会话**在途那一轮
    // （跨会话只排队，见 [_interruptForNewMessage]）
    _interruptForNewMessage(agent.id, sessionId: session.sessionId);
    return _enqueue(
      agent.id,
      session.sessionId,
      () => _runReply(agent, session, text),
    );
  }

  /// 处理 `user_answer`（`ask_user_question` 的应答）。
  ///
  /// 帧口径（前端 `message_panel._handleAskAnswer`）：
  /// `{type: 'user_answer', data: {question_id, answer}}`。
  /// 返回是否真的改变了状态（重复作答返回 false，幂等）。
  bool handleUserAnswer(Map<String, dynamic> frame) {
    final Map<String, dynamic> data = _dataOf(frame);
    final String qid =
        (data['question_id'] ?? data['qid'] ?? frame['question_id'] ?? '')
            .toString();
    if (qid.isEmpty) return false;
    final String answer = (data['answer'] ?? frame['answer'] ?? '').toString();
    return questions?.answer(qid, answer) ?? false;
  }

  /// 处理 `cancel_question`（用户放弃作答）。
  bool handleCancelQuestion(Map<String, dynamic> frame) {
    final Map<String, dynamic> data = _dataOf(frame);
    final String qid = (data['question_id'] ?? data['qid'] ?? data['id'] ?? '')
        .toString();
    if (qid.isEmpty) return false;
    return questions?.cancel(qid, reason: '用户取消') ?? false;
  }

  /// 兼容两种帧形状：`{data: {...}}` 与把字段直接放在顶层。
  static Map<String, dynamic> _dataOf(Map<String, dynamic> frame) {
    final Object? raw = frame['data'];
    if (raw is Map) {
      return raw.map((dynamic k, dynamic v) => MapEntry(k.toString(), v));
    }
    return frame;
  }

  /// 后台任务完成后唤醒 agent（terminal hook 模式）。
  ///
  /// 提示以 **agent 角色**消息进入会话（前端直接渲染，历史重载也还在），随后
  /// 发起新一轮生成——新一轮读到的历史最后一条就是它，模型因此能接着任务继续。
  Future<void> wake({
    required String agentId,
    required String sessionId,
    required String notice,
    SubagentTag? subagent,
  }) {
    final CoreAgent? agent = store.agent(agentId);
    final CoreSession? session = store.session(agentId, sessionId);
    if (agent == null || session == null) return Future<void>.value();
    // 按 `kind='notice'` 落库（UI 仍渲染成 agent 消息），但**引擎翻译时按 user 处理**：
    // 实测（见 `.self/plan/20261001-thinking-400-and-interrupt/recon.md`）表明，
    // 带 tools 的思考模式端点（DeepSeek）不允许请求以"没有 reasoning_content 的
    // assistant 消息"收尾，而 hook 提示恰恰是追加到历史末尾的那条 —— 之前正是它
    // 让唤醒轮次连续 400。按 user 翻译同时也纠正了"模型以为那句是自己说的"。
    //
    // [subagent] 非空 = 这条完成通知来自一个**后台临时员工**：消息与帧都要带上它的
    // 标记（前端据此把它显示在这名临时员工名下）。多个后台临时员工并发完成时，
    // 每次 wake 都是**独立的一条消息 + 独立的一轮**，不会互相覆盖。
    // 后台完成报告用**独立 kind**（`subagent_report`）：它带 subagent 标记（前端按
    // 它分组到那名临时员工名下），但又是**唯一**会进发起者模型上下文的带标记消息
    // （发起者必须知道活干完了）；临时员工自己的历史则把它排掉（见 store/records.dart）。
    _sendNotice(
      agent,
      session,
      notice,
      kind: subagent == null
          ? MessageKinds.notice
          : MessageKinds.subagentReport,
      subagent: subagent,
    );
    _interruptForNewMessage(agentId, sessionId: session.sessionId);
    return _enqueue(
      agentId,
      session.sessionId,
      () => _runReply(agent, session, notice),
    );
  }

  /// 新消息到达时的"插话"：打断该 agent **同一会话**在途的那一轮生成。
  ///
  /// 语义：
  /// - **会话级**：只找 `agentId|sessionId` 这条链上的在途轮次。**跨会话的消息既不
  ///   打断也不排队**——各会话是并行的任务链，互不相干（被打断的那一轮不会再发言，
  ///   见 [_runReply] 的 `interrupted` 分支：不推"已停止本轮生成"，也不产生最终答复，
  ///   所以跨会话打断只会让那个会话的答复凭空消失。实测见 known-issues #9：leader 在
  ///   团队会话里 `wait_for` 成员，成员回发落在默认会话 ⇒ 在途那一轮被自己的成员消息
  ///   掐掉，工具结果后面再没有任何回复）；
  /// - **不 bump epoch**（`stop` 才 bump）：打断的目的恰恰是"让刚入队的新消息
  ///   赶紧跑起来"，把代次往前推会让新任务被当旧任务丢掉；
  /// - 顺带作废在途提问（`ask_user_question`）：等答案的工具会立刻拿到取消结果，
  ///   工具循环才能收敛——否则用户发了新消息，agent 还卡在等一个没人回答的问题上；
  /// - 打断**只在"流式生成中"与"两次工具之间"生效**：正在执行的工具跑完才收敛
  ///   （`WorkspaceIO.exec` 没有取消参数，且 M9 规定本地执行活着就永不超时、
  ///   不按时间杀进程）；
  /// - 有在途任务时计数 [interruptedRunCount]，便于测试与排障。
  void _interruptForNewMessage(
    String agentId, {
    required String sessionId,
    bool byUser = false,
  }) {
    final _RunToken? token = _running[_runKey(agentId, sessionId)];
    if (token == null) return;
    // 只作废**这个会话**在途的提问：别的会话可能也在跑、也在等人回答，不能一起取消。
    questions?.cancelForSession(agentId, sessionId);
    token.interrupted = true;
    token.cancelled = true; // 复用既有取消通道：流式循环每帧检查，工具之间也检查
    if (byUser) token.userStopped = true;
    // 父那轮被打断时，它在**同一个会话**里派出去、正在跑的临时员工也要收敛：
    // 否则父的工具调用要一直等它们跑完，用户看到的"插话"就是假的。
    for (final _RunToken child in _running.values) {
      if (child.ownerAgentId != agentId) continue;
      if (child.sessionId != sessionId) continue;
      if (identical(child, token)) continue;
      child.interrupted = true;
      child.cancelled = true;
      // 连带收敛的那些：**只有用户插话**才算"人叫停"；hook 提示唤醒 / 别的临时员工
      // 完成报告导致的收敛都算系统内部，被中止的活照样要回报给发起者
      if (byUser) child.userStopped = true;
    }
    interruptedRunCount++;
  }

  /// 中止全部在途生成（服务器关闭时）。
  void dispose() {
    for (final _RunToken token in _running.values) {
      token.cancelled = true;
    }
    _running.clear();
    _chains.clear();
    _notified.clear();
    // 临时员工只活在会话里：内存索引随进程收起（落盘名册仍在会话数据里，
    // 下次打开同一会话原样回来）。
    subagents?.clear();
  }

  // ── 内部实现 ─────────────────────────────────────────────────────────

  CoreSession _resolveSession(
    CoreAgent agent,
    String sessionId,
    String content,
  ) {
    if (sessionId.isEmpty) {
      // 前端未指定会话：新建并把 `session_created` 推回（前端据此即时入列）
      final CoreSession created = store.createSession(
        agent.id,
        title: _titleFrom(content),
      )!;
      hub.broadcast(<String, dynamic>{
        'type': WsOutboundType.sessionCreated,
        'data': <String, dynamic>{
          'agent_id': agent.id,
          'session_id': created.sessionId,
          'title': created.title,
        },
      });
      return created;
    }
    final CoreSession? existing = store.session(agent.id, sessionId);
    if (existing != null) return existing;
    // 前端指定了核心不认识的会话 id（例如其本地兜底条目）：按给定 id 建之
    return store.createSession(agent.id, sessionId: sessionId)!;
  }

  static String _titleFrom(String content) {
    final String text = content.trim();
    if (text.isEmpty) return '新会话';
    return text.length > 30 ? '${text.substring(0, 30)}…' : text;
  }

  Future<void> _runReply(
    CoreAgent agent,
    CoreSession session,
    String userContent,
  ) => _runTurn(agent, session, userContent);

  /// 跑一轮生成的**唯一实现**（普通轮与临时员工轮共用同一条路径）。
  ///
  /// 两条身份只差三处，全部由参数表达：
  /// - [transcriptAgentId]：消息**归集到谁**（临时员工归集到它的会话主人，用户因此
  ///   能在会话历史里看到它干了什么）；
  /// - [subagent]：给每条消息/帧打上 subagent 标记（前端据此分组）；
  /// - [history] / [freshContext]：临时员工只带**它自己**的历史（复用 = 历史延续），
  ///   且不做上下文压缩（它的历史由复用累积，压缩水位线属于父会话）。
  ///
  /// **运行标识永远是 [agent] 自己的**（`(agent.id, sessionId)`）：临时员工因此
  /// 绝不会和"正阻塞等它的父 agent"那一轮撞键（撞了就是死锁），多个后台临时员工
  /// 也能真正并行（各占各的 `_running` 槽）。
  Future<_TurnOutcome> _runTurn(
    CoreAgent agent,
    CoreSession session,
    String userContent, {
    SubagentTag? subagent,
    String? transcriptAgentId,
    List<CoreMessageRef>? history,
    bool freshContext = false,
  }) async {
    final String ownerId = transcriptAgentId ?? agent.id;
    final String runKey = _runKey(agent.id, session.sessionId);
    final _RunToken token = _RunToken()
      ..agentId = agent.id
      ..sessionId = session.sessionId
      // 只有临时员工轮记归属：父 agent 的 stop / 插话要能连带停掉它
      ..ownerAgentId = subagent == null ? '' : ownerId;
    _running[runKey] = token;
    // 一条消息/一帧的**归属与标记**：普通轮 = 自己，临时员工轮 = 会话主人 + 标记
    final Map<String, dynamic> envelope = <String, dynamic>{
      'agent_id': ownerId,
      'session_id': session.sessionId,
      if (subagent != null) ...subagent.frameFields,
    };
    // Q13：token 管道（思考 / 正文 / 工具参数**共用一条**）。本轮内复用同一个
    // 节拍器，三者的时间轴因此连续，速率口径也完全一致。
    //
    // 速率**现读**（rateProvider）而不是在开始时快照：设置页点「应用」后，正在
    // 生成中的这一轮下一批 token 就按新速率走，不必等下一次发消息。设置本身仍然
    // 由 core 持久化（POST /api/settings/token-rate），这里只解决"何时生效"。
    final TokenPacer roundPacer =
        pacer ??
        TokenPacer(
          tokensPerSecond: settings.tokenAcquisitionRate.toDouble(),
          rateProvider: () => settings.tokenAcquisitionRate.toDouble(),
          enabled: pacingEnabled ?? _pacingByDefault,
        );
    // 逐模型的字符 → token 比例（Q1-①）：工具参数与思考/正文必须同口径。
    final double tokenScale =
        settings.model(agent.modelId)?.tokenScale ?? tokens.defaultTokenScale;
    // 推送刷新帧率：本轮所有流式增量先攒帧，按帧率合并成一条 `msg_chunk` 下发。
    // 内容总量不变（落库用完整文本），只把「逐 token 下发」降为「按帧率下发」，
    // 避免以 token 速率刷屏。帧窗口由设置页调节；节奏控制被整体关闭时（测试旋钮）
    // 不挂定时器——攒下的增量只在显式 flush 点落地，"同一帧窗口内合并成一帧"
    // 因此与 OS 计时器粒度无关。
    final _ChunkPump pump = _ChunkPump(
      frameWindow: roundPacer.enabled
          ? frameWindowFor(settings.frameRate)
          : Duration.zero,
      envelope: envelope,
      hub: hub,
    );
    hub.broadcast(<String, dynamic>{
      'type': WsOutboundType.agentStatus,
      'data': <String, dynamic>{
        'agent_id': ownerId,
        'status': 'working',
        if (subagent != null) ...subagent.frameFields,
      },
    });

    // ── Q3 消息分段 ──────────────────────────────────────────────────────
    // 每个 thinking 段 / 正文段 / 工具卡片各自是一条消息。用 `??=` 复用单条消息
    // 会让所有思考挤进同一张卡片、把工具轮之间的中间正文并进最终回复，最终输出的
    // 位置也会随第一次 text 事件漂移到最前面。
    _PendingMessage? thinkingSegment;
    _PendingMessage? textSegment;
    final Map<String, _PendingMessage> toolSegments =
        <String, _PendingMessage>{};
    // 最近开始的段 id：`msg_usage` 要挂在一张已存在的卡片上（工具循环里就挂在
    // 工具卡片上，与参考实现一致）。
    String lastSegmentId = '';
    // 工具调用轮次（插件生态）：**本任务内**从 1 开始计数，随 `agent.tool_call`
    // 事件下发给插件——插件据此实现"超过 N 次就停"（Q8：限制交给插件做）。
    int toolRound = 0;
    // 整轮正文：端点没给 usage 时，completion 的兜底口径是**整轮**生成量。
    final StringBuffer roundText = StringBuffer();
    Map<String, dynamic>? usage;
    bool cancelled = false;
    String? errorMessage;
    // 本轮**最后一段正文**：临时员工的"最终报告"取它（结束时仍开着的那段优先）
    String lastTextBody = '';

    void startSegment(_PendingMessage message) {
      pump.flush(); // 先把上一批增量落地，保证界面顺序与事件顺序一致
      hub.broadcast(<String, dynamic>{
        'type': WsOutboundType.msgStart,
        'id': message.id,
        'kind': message.kind,
        ...envelope,
      });
      lastSegmentId = message.id;
    }

    void appendChunk(_PendingMessage message, String delta) {
      // 正文完整写入（落库口径不变），下发则交给 pump 按帧率攒帧合并
      message.content.write(delta);
      pump.add(message.id, delta);
    }

    // 落库一段：思考段 / 正文段各自独立成消息（中间输出不再并进最终回复），
    // 工具调用一条一张卡片；空文本不落库。
    void persistSegment(
      _PendingMessage message, {
      Map<String, dynamic>? usage,
    }) {
      if (message.kind == 'tool') {
        if (message.toolName == null) return;
        store.appendMessage(
          CoreMessage(
            id: message.id,
            agentId: ownerId,
            sessionId: session.sessionId,
            role: 'agent',
            content: '',
            timestamp: DateTime.now().millisecondsSinceEpoch,
            kind: 'tool',
            toolName: message.toolName,
            toolArguments: message.toolArguments,
            toolResult: message.toolResult,
            toolCallId: message.toolCallId.isEmpty ? null : message.toolCallId,
            // 「送模型那一份」按原样落库：下一轮重建历史时直接取用（缓存前缀）
            toolArgumentsRaw: message.toolArgumentsRaw,
            toolResultForModel: message.toolResultForModel,
            subagentId: subagent?.id ?? '',
            subagentName: subagent?.name ?? '',
            subagentParentId: subagent?.parentId ?? '',
            subagentLevel: subagent?.level ?? 0,
          ),
        );
        return;
      }
      final String body = message.content.toString();
      if (body.isEmpty) return;
      if (message.kind == 'text') lastTextBody = body;
      store.appendMessage(
        CoreMessage(
          id: message.id,
          agentId: ownerId,
          sessionId: session.sessionId,
          role: 'agent',
          content: body,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          kind: message.kind,
          usage: usage,
          subagentId: subagent?.id ?? '',
          subagentName: subagent?.name ?? '',
          subagentParentId: subagent?.parentId ?? '',
          subagentLevel: subagent?.level ?? 0,
        ),
      );
    }

    /// 结束一段：`msg_end` + 落库（对应参考实现的 `_close_thinking` / `_close_text`）。
    void endSegment(
      _PendingMessage message, {
      Map<String, dynamic>? usage,
      bool cancelled = false,
    }) {
      // msg_end 之前必须先落地全部增量：这样封口水位才是"本段最后一条增量帧的
      // 序号"，前端收到的正文也才完整（帧序与事件序一致，见 [_ChunkPump]）。
      pump.flush();
      // 封口水位（可选字段）：值 = 本段最后一条 `msg_chunk` 的序号，本段没下发过
      // 增量时**省略**（不是写 0——0 是合法序号，会把第一条增量判成重播）。
      // 前端封口时把已消费水位一并推进到段末，即使封口集合被历史整批重建清掉，
      // 更老的重播帧仍会被序号判据挡住（协议见 `WsStreamSeq`）。
      final int? sealSeq = pump.sealSeq(message.id);
      hub.broadcast(<String, dynamic>{
        'type': WsOutboundType.msgEnd,
        'id': message.id,
        'usage': usage,
        'cancelled': cancelled,
        // 空值 = 本段没下发过增量：整条字段省略（空值标记由 Dart 的空感知元素负责）
        WsStreamSeq.field: ?sealSeq,
        ...envelope,
      });
      persistSegment(message, usage: usage);
    }

    // thinking 段：遇正文 / 工具调用 / 提问即关闭（独立 id，落库 kind=thinking）。
    void closeThinking({bool cancelled = false}) {
      final _PendingMessage? message = thinkingSegment;
      if (message == null) return;
      thinkingSegment = null;
      endSegment(message, cancelled: cancelled); // 思考段不带 usage
    }

    // text 段：遇工具调用即关闭，且**独立落库**（中间输出不带 usage）。
    void closeText() {
      final _PendingMessage? message = textSegment;
      if (message == null) return;
      textSegment = null;
      endSegment(message);
    }

    // 自动压缩（M7d-4）：长会话先把早期历史总结掉，再按「摘要 + 近期消息」生成。
    // 这只是"本轮生成前那一次"；工具循环里**每一轮 API 调用前**还会再检查
    // （Q1-③），那次由引擎经 [LlmAgentEngine.toolTurnCompactor] 回调回这里，
    // 用的是同一套阈值与水位线。
    // 临时员工轮**不做压缩**：压缩水位线（`compactedMessageCount`）是父会话的口径，
    // 而它的历史是"自己那一段"；它的上下文上限交给端点的超限报错显式表达。
    final bool compacted = freshContext
        ? false
        : await _autoCompact(agent, session);
    if (compacted) {
      // compact 之后是允许重建系统提示词的两个时机之一
      invalidateSystemPrompt(agent.id, session.sessionId);
    }
    // 会话初始化（本进程第一轮）才真的拼一次并钉住；之后每轮直接复用同一串字节
    // ⇒ 发消息不会让 `[0]` 变样（见 [promptStatePrewarm] 与 docs/known-issues.md #8）。
    await _ensureSystemPromptPinned(agent, session.sessionId);
    final AgentRunContext context = _contextOf(
      agent,
      session,
      userContent: userContent,
      transcriptAgentId: ownerId,
      historyOverride: history,
      fresh: freshContext,
    );

    try {
      await for (final AgentEvent event in engine.run(
        context,
        isCancelled: () => token.cancelled,
      )) {
        if (event is AgentText) {
          closeThinking(); // thinking 段遇正文即关闭
          final _PendingMessage message = textSegment ??= _PendingMessage(
            id: CoreIds.message(),
            kind: 'text',
          );
          if (message.content.isEmpty) startSegment(message);
          appendChunk(message, event.delta);
          roundText.write(event.delta);
          await roundPacer.consume(
            estimateTokens(event.delta, scale: tokenScale),
          );
        } else if (event is AgentThinking) {
          final _PendingMessage message = thinkingSegment ??= _PendingMessage(
            id: CoreIds.message(),
            kind: 'thinking',
          );
          if (message.content.isEmpty) startSegment(message);
          appendChunk(message, event.delta);
          await roundPacer.consume(
            estimateTokens(event.delta, scale: tokenScale),
          );
        } else if (event is AgentToolStart) {
          // 工具调用：先关掉在开的思考与正文段（各自 msg_end + 落库），再立卡片
          closeThinking();
          closeText();
          final _PendingMessage message =
              _PendingMessage(id: event.id, kind: 'tool')
                ..toolName = event.name
                ..toolArguments = event.arguments
                ..toolArgumentsRaw = event.rawArguments
                ..toolCallId = event.callId
                // 轮次 = 本任务内第几次工具调用（插件按它判"超限"）
                ..round = ++toolRound;
          toolSegments[event.id] = message;
          // 插件生态：**工具调用开始**事件。先发事件再等工具执行——插件因此有机会在
          // 工具真正跑起来之前（乃至下次调用之前）用 `agent.stop` 掐掉超限的轮次。
          _publishToolCall(
            agent,
            session,
            message,
            AgentEvents.phaseStart,
            teamAgentId: ownerId,
          );
          // Q13：工具参数按 `字符数 / token_scale` 折算 token，走**同一条** token
          // 管道排队推送 —— write 这类大参数调用自然产生等待，read 几乎不等待。
          await roundPacer.consume(
            estimateTokens(jsonEncode(event.arguments), scale: tokenScale),
          );
          pump.flush(); // 工具卡片前先落地正文，避免界面顺序错位
          hub.broadcast(<String, dynamic>{
            'type': WsOutboundType.toolStart,
            'id': message.id,
            'name': event.name,
            'arguments': event.arguments,
            ...envelope,
          });
          lastSegmentId = message.id;
        } else if (event is AgentToolEnd) {
          final _PendingMessage? message = toolSegments.remove(event.id);
          if (message == null) continue;
          message.toolResult = event.result;
          message.toolResultForModel = event.modelContent;
          // 插件生态：**工具调用结束**事件（与开始事件同 `call_id` / `round`，插件
          // 据此统计每次耗时；工具名以结束事件为准，兜底用卡片里的名字）。
          _publishToolCall(
            agent,
            session,
            message,
            AgentEvents.phaseEnd,
            tool: event.name,
            teamAgentId: ownerId,
          );
          // 工具结果**直接推**、不延迟（Q13）：等待只花在参数上；推完即进入下一轮
          pump.flush();
          hub.broadcast(<String, dynamic>{
            'type': WsOutboundType.toolEnd,
            'id': event.id,
            'name': event.name,
            'result': event.result,
            ...envelope,
          });
          persistSegment(message); // 工具卡片与结果一起落库（与帧同 id）
        } else if (event is AgentUsage) {
          usage = event.usage;
          pump.flush();
          hub.broadcast(<String, dynamic>{
            'type': WsOutboundType.msgUsage,
            'id': lastSegmentId,
            'usage': event.usage,
            ...envelope,
          });
        } else if (event is AgentNotice) {
          // 系统发言（重试进度等）：立刻落库 + 下发，但**不进模型上下文**（llm_hidden）。
          // 不下发的话，用户面对的就是"最长两分多钟的空白"。
          _sendNotice(
            agent,
            session,
            event.text,
            llmHidden: true,
            subagent: subagent,
            transcriptAgentId: ownerId,
          );
        } else if (event is AgentError) {
          errorMessage = event.message;
        } else if (event is AgentDone) {
          if (event.cancelled) cancelled = true;
        }
      }
    } catch (error) {
      errorMessage ??= '生成失败：$error';
    }
    if (token.cancelled) cancelled = true;
    // 结束/中断本轮：停表并落地残余增量，保证 msg_end 之前正文已全部下发
    pump.dispose();

    // 端点没给 usage 时用本地估算兜底（前端上下文进度条依赖该字段）；
    // completion 的兜底口径是**整轮正文**（工具循环里模型生成了多轮内容）。
    final Map<String, dynamic> finalUsage =
        usage ?? usageOf(agent, userContent, roundText.toString());

    // 仍在开的思考段：收尾（不带 usage，对应参考实现 finally 里的 _close_thinking）
    closeThinking(cancelled: cancelled);

    // 结束时仍打开的正文段 = **最终回复**：整段全文 + usage（usage 只挂最后一条）
    final _PendingMessage? finalText = textSegment;
    if (finalText != null) {
      textSegment = null;
      endSegment(finalText, usage: finalUsage, cancelled: cancelled);
    }

    // 没等到结果的工具卡片（中途取消 / 异常）：照旧落库，历史里不丢这张卡
    for (final _PendingMessage message in toolSegments.values) {
      persistSegment(message);
    }
    toolSegments.clear();

    // 临时员工的"最终报告"：结束时仍开着的那段正文优先，否则用本轮最后一段正文
    // （它可能以工具调用收尾——那时最后一段中间正文就是它唯一说出来的话）。
    final String finalBody = finalText?.content.toString() ?? '';
    final String report = finalBody.trim().isNotEmpty ? finalBody : lastTextBody;

    final String? failure = errorMessage;
    if (failure != null) {
      // 1) error 帧（日志/遥测）；2) 一条**可见**的 agent 消息（前端只忽略 error 帧）。
      // 落库带 llm_hidden：**给人看，不喂模型**——否则模型下一轮读到这句错误，会把它
      // 当成"新的排查任务"接着干活（用户实测反馈）。
      _sendError(failure);
      _sendNotice(
        agent,
        session,
        failure,
        llmHidden: true,
        subagent: subagent,
        transcriptAgentId: ownerId,
      );
    }
    if (cancelled) {
      // 用户按 stop → 给一条可见提示；被"新消息"打断（interjection）则**不提示**：
      // 用户刚发的话就是它的上下文，再刷"已停止本轮生成。"纯属噪声。
      if (!token.interrupted) {
        // 同样是"给人看"的一句话：模型不需要知道"这一轮被用户停了"（读到只会当成新指令）
        _sendNotice(
          agent,
          session,
          '已停止本轮生成。',
          llmHidden: true,
          subagent: subagent,
          transcriptAgentId: ownerId,
        );
      }
    }
    _running.remove(runKey);
    // 别的会话 / 别的后台临时员工可能还在跑：只有该 agent **一个在途轮次都不剩**
    // 时才广播 idle（[isRunning] 把"它名下的临时员工"也算在内）。
    //
    // **临时员工例外**：它有自己的标记、自己的视角（用户 2026-10-04 起还能被用户直接
    // 停止/追问），所以它这一轮结束就**总是**报自己的 idle——否则父那轮还卡着等它时
    // （blocking 模式）它那边的"工作中"永远亮着，面板也就不会把停止键换回发送键。
    if (subagent != null || !isRunning(ownerId)) {
      hub.broadcast(<String, dynamic>{
        'type': WsOutboundType.agentStatus,
        'data': <String, dynamic>{
          'agent_id': ownerId,
          'status': 'idle',
          if (subagent != null) ...subagent.frameFields,
        },
      });
    }
    return _TurnOutcome(
      report: report,
      error: failure ?? '',
      cancelled: cancelled,
      userStopped: token.userStopped,
    );
  }

  /// 跑一轮**临时员工**生成（`subagent` 工具的落点，见 [SubagentTurnRunner]）。
  ///
  /// 与普通轮的差别只有身份与历史：
  /// - 运行键 = `(subagentId, sessionId)` —— 父 agent 此刻正阻塞等它，两者**绝不撞键**
  ///   （撞了会死锁）；同时这也让 N 个后台临时员工各自独立并行（不互相顶掉轮次）；
  /// - 消息归集到**会话主人**的会话，并带上 subagent 标记（用户看得到它干了什么，
  ///   父 agent 的模型上下文则被 `messages()` 挡在外面）；
  /// - 上下文 = **它自己**的历史（`store.messages(subId, sid)`）：不含父会话、
  ///   不做压缩；复用同一个 id 时这份历史天然延续（"历史延续、配置不变"）；
  /// - 本轮先把 task 记成一条带标记的 `notice`（引擎按 user 翻译）：它既是这次任务的
  ///   输入，也是复用时历史延续的锚点。
  Future<SubagentTurnResult> runSubagent(SubagentTurnRequest request) async {
    final SubagentTag tag = request.tag;
    final CoreAgent? sub = store.agent(tag.id);
    if (sub == null) {
      return const SubagentTurnResult(error: '临时员工未注册或已被清理（请重新召一个）');
    }
    final CoreAgent? owner = store.agent(request.ownerAgentId);
    if (owner == null) {
      return SubagentTurnResult(
        error: '发起者不存在：${request.ownerAgentId}',
      );
    }
    CoreSession? session = store.session(owner.id, request.sessionId);
    session ??= store.createSession(owner.id, sessionId: request.sessionId);
    if (session == null) {
      return SubagentTurnResult(error: '会话不可用：${request.sessionId}');
    }
    final String runKey = _runKey(tag.id, request.sessionId);
    if (_running.containsKey(runKey)) {
      return SubagentTurnResult(
        error:
            '临时员工「${tag.name}」正在跑上一轮（${tag.id}）：'
            '等它这一轮结束后再复用，或新召一个（不填 subagent_id）。',
      );
    }
    // 用户直接说的那句话，调用方（[sendToSubagent]）**已经落库**了：
    // 它得是 `role='user'` 的普通消息，屏幕上就是"我对它说了一句"，
    // 不能再补一条 `subagent_task`（那会变成两句）。
    if (!request.fromUser) {
      store.appendMessage(
        CoreMessage(
          id: CoreIds.message(),
          agentId: owner.id,
          sessionId: session.sessionId,
          role: 'agent',
          content: request.task,
          // 它自己那一轮的输入：与 hook 提示同类（引擎按 user 翻译），但发起者的上下文
          // 里没有它（任务已经写在发起者的 subagent 工具调用参数里了）
          kind: MessageKinds.subagentTask,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          subagentId: tag.id,
          subagentName: tag.name,
          subagentParentId: tag.parentId,
          subagentLevel: tag.level,
        ),
      );
    }
    final List<CoreMessageRef> history = store
        .messages(tag.id, session.sessionId)
        .map(_toRef)
        .toList(growable: false);
    final _TurnOutcome outcome = await _runTurn(
      sub,
      session,
      request.task,
      subagent: tag,
      transcriptAgentId: owner.id,
      history: history,
      freshContext: true,
    );
    return SubagentTurnResult(
      report: outcome.report,
      error: outcome.error,
      cancelled: outcome.cancelled,
      userStopped: outcome.userStopped,
    );
  }

  /// **用户（界面）直接给某个临时员工发消息**（用户 2026-10-04 要求）。
  ///
  /// 与工具那条路的区别：
  /// - 不新建、不校验层级：只认"这个会话里真有它"；
  /// - 落库是 `role='user'` 的普通消息 + **它的标记**（它自己的历史按标记取，见
  ///   store 不变量；发起者的模型上下文照旧看不到它）；
  /// - **插话语义与主 agent 一致**：它正在跑就先把那一轮打断，这条消息接着跑；
  /// - 跑完照旧把报告注入**发起者会话**（与后台临时员工同一段话术）——发起者对
  ///   "我的员工又干了一轮"因此是知情的。
  Future<void> sendToSubagent(Map<String, dynamic> frame) async {
    final String subagentId = (frame['agent_id'] as String? ?? '').trim();
    final String content = (frame['content'] as String? ?? '').trim();
    final String sessionId = (frame['session_id'] as String? ?? '').trim();
    final CoreSubagent? record = subagents?.handle(subagentId);
    if (record == null) {
      _sendError('临时员工不存在或已被清理：$subagentId（请重新召一个）');
      return;
    }
    // 它只活在它被召来的那个会话里（跨会话复用是硬错误，见 store 不变量）
    final String targetSession = sessionId.isEmpty
        ? record.sessionId
        : sessionId;
    if (targetSession != record.sessionId) {
      _sendError(
        '临时员工「${record.name}」只活在它被召来的那个会话里'
        '（${record.sessionId}）：请回到那个会话里跟它说话。',
      );
      return;
    }
    if (content.isEmpty) {
      _sendError('消息内容为空：请写一句要它做什么的话。');
      return;
    }
    final SubagentTag tag = SubagentTag(
      id: record.id,
      name: record.name,
      parentId: record.parentId,
      level: record.level,
    );
    store.appendMessage(
      CoreMessage(
        id: CoreIds.message(),
        agentId: record.ownerAgentId,
        sessionId: record.sessionId,
        role: 'user',
        content: content,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        attachments: _attachments(frame['attachments']),
        subagentId: tag.id,
        subagentName: tag.name,
        subagentParentId: tag.parentId,
        subagentLevel: tag.level,
      ),
    );
    // 插话：先打断它当前那一轮（工具之间的收敛口径与主 agent 完全一致）。
    // 这是**用户**说的 → byUser：被中止的那一轮不向发起者注入结束提示。
    _interruptForNewMessage(
      record.id,
      sessionId: record.sessionId,
      byUser: true,
    );
    await _enqueue(
      record.id,
      record.sessionId,
      () => _runUserSubagentTurn(record, tag, content),
    );
  }

  /// 用户那条消息触发的那一轮：等上一轮收尾 → 跑 → 把报告注入发起者会话。
  Future<void> _runUserSubagentTurn(
    CoreSubagent record,
    SubagentTag tag,
    String content,
  ) async {
    // 上一轮可能正在收尾（它被取消了，但工具跑完才收敛；M9 不杀工具）。
    // 给一个有界的等待，而不是当场报"正在跑上一轮"——用户刚说过话，不该被丢掉。
    final String runKey = _runKey(tag.id, record.sessionId);
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
    while (_running.containsKey(runKey) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final CoreAgent? owner = store.agent(record.ownerAgentId);
    final CoreSession? session = store.session(record.ownerAgentId, record.sessionId);
    if (owner == null || session == null) return;
    if (_running.containsKey(runKey)) {
      _sendNotice(
        owner,
        session,
        '没能把你的消息交给临时员工「${record.name}」：它还在收尾上一轮'
        '（正在跑的工具不杀进程，跑完才收敛）。可以稍后再发，或先停止它。',
        subagent: tag,
        transcriptAgentId: record.ownerAgentId,
      );
      return;
    }
    final SubagentTurnResult result = await runSubagent(
      SubagentTurnRequest(
        tag: tag,
        ownerAgentId: record.ownerAgentId,
        sessionId: record.sessionId,
        task: content,
        fromUser: true,
      ),
    );
    // 完成报告注入发起者会话（与后台临时员工同一段话术、同一条 wake 链路）。
    //
    // **人为中止不注入**（用户 2026-10-04）：用户按了停止，或他自己插话把这一轮打断了
    // ——原因由用户自己向发起者说，发起者不该收到一条"我的员工结束了一轮"的噪声；
    // 用户很可能马上又发一条让它接着干，那时**自然结束**的报告才该回去。
    // 反过来，**出错导致的中止必须说**（发起者否则以为活还在干）。
    if (result.userStopped && result.error.isEmpty) {
      // 不注入 = 不 wake。这里**只留一条日志**（不是消息）：发起者的上下文因此
      // 干干净净，用户想说什么由他自己说。
      hub.broadcast(<String, dynamic>{
        'type': WsOutboundType.agentStatus,
        'data': <String, dynamic>{
          'agent_id': record.ownerAgentId,
          'status': 'idle',
          ...tag.frameFields,
        },
      });
      return;
    }
    await wake(
      agentId: record.ownerAgentId,
      sessionId: record.sessionId,
      notice: SubagentService.noticeText(record, result),
      subagent: tag,
    );
  }

  /// 发布一条工具调用事件（`agent.tool_call`；字段口径见 [AgentEvents.toolCall]）。
  ///
  /// - `team_id` 取 agent 的**有效团队归属**（与 `TeamService.teamIdOf` / 站点 keying /
  ///   `StationScopeContext` 同口径）：顶层 agent（`team_id` 为空）**自成一队**，
  ///   取它自己的 id。只读 `agent.teamId` 会让顶层 agent 的事件永远带空 team，而
  ///   插件**要订阅站点就必须声明 `scope.team_id`**（站点隔离要求四元组）——两条
  ///   要求会互相打架：声明了 team 的插件反而收不到自己 agent 的事件（计数静默归零）。
  ///   执行站早已踩过同一个坑并改成同口径（见 `execute_mounts.dart` 的 agentTeamOf）。
  /// - `round` 取卡片里记的本任务轮次（start / end 同值），插件因此能把一对事件配上；
  /// - 未接线（[AgentEventPublisher.sink] 为空）时是**纯 no-op**，不影响既有行为。
  void _publishToolCall(
    CoreAgent agent,
    CoreSession session,
    _PendingMessage message,
    String phase, {
    String tool = '',
    String? teamAgentId,
  }) {
    // 团队归属取**会话主人**（临时员工与发起者同一个队）：临时员工不是独立团队，
    // 否则订阅了该 team 的插件收不到它（以及它的临时员工）发出来的工具事件。
    final CoreAgent teamAgent = store.agent(teamAgentId ?? agent.id) ?? agent;
    final String teamId = teamAgent.teamId.trim();
    agentEvents.toolCall(
      agentId: agent.id,
      sessionId: session.sessionId,
      teamId: teamId.isEmpty ? teamAgent.id : teamId,
      tool: tool.isEmpty ? (message.toolName ?? '') : tool,
      callId: message.toolCallId,
      round: message.round,
      phase: phase,
    );
  }

  /// 默认是否做节奏控制。
  ///
  /// [ScriptedAgent.chunkDelay] 是 `CoreServer.start(streamChunkDelay:)` 这个
  /// 测试旋钮的落点：为 [Duration.zero] 表示"不模拟时间"，一轮事件会在同一批
  /// 微任务里全部产出。此时再按 token/帧率节流，等于用真实计时器伪造一条时间轴
  /// ——Windows 的计时器粒度约 15.6ms（6 次 1ms 的延迟实测要 88~96ms，配置
  /// 1000 token/s 实际只有 ~64 token/s），攒帧断言必然随负载抖动。
  /// 因此**零延迟 = 关掉节奏控制**；真实引擎（[LlmAgentEngine]）永远按速率节流。
  bool get _pacingByDefault {
    final AgentEngine current = engine;
    return current is! ScriptedAgent || current.chunkDelay > Duration.zero;
  }

  /// 推一条完整的 agent 文本消息（`message` 帧）并落库。
  ///
  /// 现状 server 的 `_send_text_as_agent` 走的就是这条路径：错误提示、停止提示
  /// 等"系统发言"必须出现在会话里，用户才看得到。
  ///
  /// [kind] 两选一（都是"落库 + 前端可见"）：`text`（默认：模型自己说的话，引擎按
  /// assistant 发回去）、`notice`（**hook 唤醒提示**：引擎按 **user** 发，它是"新输入"，
  /// 原因见 [wake] 的注释与 recon 实测）。
  ///
  /// [llmHidden] = **不插进模型提示词**（系统发言 / 过程提示用）：消息照常落库、照常
  /// 下发，但引擎重建请求时整条跳过。
  void _sendNotice(
    CoreAgent agent,
    CoreSession session,
    String content, {
    String kind = 'text',
    bool llmHidden = false,
    SubagentTag? subagent,
    String? transcriptAgentId,
  }) {
    final String id = CoreIds.message();
    final String ownerId = transcriptAgentId ?? agent.id;
    hub.broadcast(<String, dynamic>{
      'type': WsOutboundType.message,
      'id': id,
      'role': 'agent',
      'content': content,
      'kind': kind,
      if (llmHidden) 'llm_hidden': true,
      'agent_id': ownerId,
      'session_id': session.sessionId,
      if (subagent != null) ...subagent.frameFields,
    });
    store.appendMessage(
      CoreMessage(
        id: id,
        agentId: ownerId,
        sessionId: session.sessionId,
        role: 'agent',
        content: content,
        kind: kind,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        llmHidden: llmHidden,
        subagentId: subagent?.id ?? '',
        subagentName: subagent?.name ?? '',
        subagentParentId: subagent?.parentId ?? '',
        subagentLevel: subagent?.level ?? 0,
      ),
    );
  }

  /// 存储消息 → 引擎视图。
  static CoreMessageRef _toRef(CoreMessage message) => CoreMessageRef(
    role: message.role,
    content: message.content,
    kind: message.kind,
    llmHidden: message.llmHidden,
    toolName: message.toolName,
    toolArguments: message.toolArguments,
    toolResult: message.toolResult,
    toolCallId: message.toolCallId,
    toolArgumentsRaw: message.toolArgumentsRaw,
    toolResultForModel: message.toolResultForModel,
    timestamp: message.timestamp,
    attachments: message.attachments,
  );

  /// 按 **agent×会话** 串行执行：同一会话的前一个任务（含失败）结束后才启动下一个，
  /// **不同会话各自一条链、并行启动**。
  Future<void> _enqueue(
    String agentId,
    String sessionId,
    Future<void> Function() task,
  ) {
    final String key = _runKey(agentId, sessionId);
    final Future<void> previous = _chains[key] ?? Future<void>.value();
    final Completer<void> gate = Completer<void>();
    _chains[key] = gate.future;
    final int epoch = _epoch[agentId] ?? 0;
    unawaited(() async {
      try {
        await previous;
      } catch (_) {
        // 前序任务的错误已在内部上报，不阻断队列
      }
      // stop 之后旧代次的排队任务一律丢弃（参考实现清空 broker 队列的等价语义）
      if ((_epoch[agentId] ?? 0) != epoch) {
        droppedQueuedCount++;
        if (!gate.isCompleted) gate.complete();
        if (identical(_chains[key], gate.future)) _chains.remove(key);
        return;
      }
      try {
        await task();
      } catch (e) {
        _sendError('会话任务异常：$e');
      }
      if (!gate.isCompleted) gate.complete();
      if (identical(_chains[key], gate.future)) {
        _chains.remove(key);
      }
    }());
    return gate.future;
  }

  /// 本地估算的 token 用量（端点未返回 usage 时的兜底，带 `estimated: true`）。
  ///
  /// 比例取该模型的 token_scale（Q1-①）：进度条、压缩阈值、工具结果门控必须
  /// 同口径，否则会出现"进度条说没超、端点却报超限"。
  Map<String, dynamic> usageOf(
    CoreAgent agent,
    String prompt,
    String completion,
  ) {
    final CoreModelConfig? model = settings.model(agent.modelId);
    final double scale = model?.tokenScale ?? tokens.defaultTokenScale;
    return agentUsageMap(
      promptTokens: estimateTokens(prompt, scale: scale),
      completionTokens: estimateTokens(completion, scale: scale),
      maxTokens: model?.effectiveMaxSeqlen ?? CoreSettings.fallbackMaxSeqlen,
      estimated: true,
    );
  }

  /// 粗略 token 估算（唯一实现在 util/tokens.dart，压缩阈值与进度条共用）。
  static int estimateTokens(
    String text, {
    double scale = tokens.defaultTokenScale,
  }) => tokens.estimateTokens(text, scale: scale);

  /// **拼上下文之前**把提示词依赖的异步快照热起来的钩子（Q9 Spec 的 ⑦ 索引 / ⑧ 已选全文）。
  ///
  /// 为什么放在这里而不是引擎里：`AgentRunContext.systemPrompt` 在进入引擎**之前**就拼好
  /// 了（见 [_contextOf]），引擎再预热已经来不及改这一轮要发的字节。
  ///
  /// 不接线的语义 = 不预热（测试、无 Spec 服务的场景，行为与接线前逐字一致）。
  Future<void> Function(String agentId, String sessionId)? promptStatePrewarm;

  /// 构造引擎看到的运行上下文（生成前与工具循环内压缩后共用同一份装配逻辑）。
  AgentRunContext _contextOf(
    CoreAgent agent,
    CoreSession session, {
    String userContent = '',
    String? transcriptAgentId,
    List<CoreMessageRef>? historyOverride,
    bool fresh = false,
  }) {
    // 压缩会把摘要与水位线写回会话对象；重新取一次避免拿到过期快照。
    // 历史与压缩状态按**归集归属**（`transcriptAgentId`）取：临时员工的消息写进
    // 会话主人的会话里，但它的上下文用的是"它自己那一段"（[historyOverride]）。
    final String ownerId = transcriptAgentId ?? agent.id;
    final CoreSession currentSession =
        store.session(ownerId, session.sessionId) ?? session;
    return AgentRunContext(
      agentId: agent.id,
      sessionId: currentSession.sessionId,
      modelId: agent.modelId,
      // ⑧ 已选 Spec 全文是会话级的，所以键里带 sessionId；取的是**钉住值**
      // （没有时同步建一份并钉住——正常路径已由 _ensureSystemPromptPinned 建好）
      systemPrompt: _systemPromptPinned(agent, currentSession.sessionId),
      userContent: userContent,
      // 临时员工轮不带父会话的压缩摘要/水位（它的历史是自己那一段，见 freshContext）
      contextSummary: fresh ? '' : currentSession.compactedSummary,
      compactedMessageCount: fresh ? 0 : currentSession.compactedMessageCount,
      // 中转站产出的整份上下文（非空时引擎原样使用它，不再拼 system/摘要）
      compactedContext: fresh
          ? const <Map<String, dynamic>>[]
          : currentSession.compactedContext,
      // 用户消息已在 handleUserMessage 里落库，因此这里取到的历史已含本次输入。
      // `messages()` 刻意排掉临时员工的消息：父 agent 的工具批必须保持原子。
      history:
          historyOverride ??
          store
              .messages(agent.id, currentSession.sessionId)
              .map(_toRef)
              .toList(growable: false),
    );
  }

  /// **按会话钉住的系统提示词**（`agentId|sessionId` → 文本）。
  ///
  /// 为什么钉住：`system` 是消息序列的**第 0 条**，它一变，后面的整条前缀（含全部历史）
  /// 在端点前缀缓存上都对不上 ⇒ 0 命中。而提示词的内容来自多变的外部状态（Spec 索引、
  /// 已选 Spec 全文、工作空间文件、agent 配置），「发一条消息」不该改变它。
  ///
  /// **只有两个重建时机**：① 会话初始化（本进程第一次为该会话拼装）；② compact 之后
  /// （此时前缀本来就要重写，重建不额外亏）。另有 [invalidateSystemPrompt] 供"用户显式
  /// 改提示词 / 重置工作空间"这类主动操作调用——**发消息永远不调它**。
  final Map<String, String> _systemPrompts = <String, String>{};

  static String _promptKey(String agentId, String sessionId) =>
      '$agentId|$sessionId';

  /// 自检/测试读数点：本会话当前钉住的系统提示词（null = 还没建过）。
  String? pinnedSystemPrompt(String agentId, String sessionId) =>
      _systemPrompts[_promptKey(agentId, sessionId)];

  /// 丢掉钉住的系统提示词，下一次拼装重建。
  ///
  /// [sessionId] 为空 = 该 agent 的**所有会话**（改 agent 自己的提示词时用）。
  /// 调用点只有三类：compact 之后、用户显式改提示词 / 重置工作空间、测试。
  void invalidateSystemPrompt(String agentId, [String? sessionId]) {
    final String? id = sessionId;
    if (id == null || id.trim().isEmpty) {
      _systemPrompts.removeWhere(
        (String key, String _) => key.startsWith('$agentId|'),
      );
      return;
    }
    _systemPrompts.remove(_promptKey(agentId, id));
  }

  /// 取回（必要时**建好并钉住**）本会话的系统提示词。
  ///
  /// 没有钉住值 = 会话初始化：先热 ⑦/⑧ 快照（[promptStatePrewarm]），再同步拼一份并钉住。
  /// 已经钉住则**直接返回**，不看外部状态——这正是"发消息不更新系统提示词"的实现。
  Future<void> _ensureSystemPromptPinned(
    CoreAgent agent,
    String sessionId,
  ) async {
    if (_systemPrompts.containsKey(_promptKey(agent.id, sessionId))) return;
    await promptStatePrewarm?.call(agent.id, sessionId);
    _systemPromptPinned(agent, sessionId);
  }

  /// 同步取（无则建并钉住）：`_contextOf` 是同步的，走这里。
  String _systemPromptPinned(CoreAgent agent, String sessionId) =>
      _systemPrompts.putIfAbsent(
        _promptKey(agent.id, sessionId),
        () => systemPromptWithWorkspace(agent, sessionId: sessionId),
      );

  /// 工具循环内压缩（Q1-③）：压动了就把**新的上下文快照**交给引擎重新装配。
  ///
  /// 返回 null = 没压（没配压缩器 / 没到阈值 / 已经没有可压的历史），引擎保持
  /// 原上下文继续——压不动的情况由端点超限重试那条路兜底报错。
  Future<AgentRunContext?> _compactTurnContext(
    String agentId,
    String sessionId, {
    required bool force,
  }) async {
    if (compaction == null) return null;
    final CoreAgent? agent = store.agent(agentId);
    if (agent == null) return null;
    final CoreSession? session = store.session(agentId, sessionId);
    if (session == null) return null;
    final bool compacted = await _autoCompact(agent, session, force: force);
    if (!compacted) return null;
    // 轮内 compact 同样是"允许重建"的时机（前缀本来就要重写）
    invalidateSystemPrompt(agent.id, session.sessionId);
    await _ensureSystemPromptPinned(agent, session.sessionId);
    return _contextOf(agent, session);
  }

  /// 自动压缩：返回**是否真的压动了**（工具循环要靠它决定是否重新装配上下文）。
  ///
  /// 失败必须**可见**（Q1-③）：以前只写日志，用户看到的是"上下文怎么还是超"，
  /// 却完全不知道压缩压根没跑起来。同一个错误只提示一次，避免每轮刷屏。
  Future<bool> _autoCompact(
    CoreAgent agent,
    CoreSession session, {
    bool force = false,
  }) async {
    final CompactionService? service = compaction;
    if (service == null) return false;
    _warnIfBudgetFallback(agent, session, service);
    try {
      final CompactionResult? result = await service.autoCompact(
        agent,
        session,
        force: force,
      );
      if (result != null && result.compressed) {
        // 压缩已发生 / 降级 / 插件为什么没接管：统一走**落库**通路，刷新后仍在
        _notifyCompacted(agent, session, result);
      }
      return result?.compressed ?? false;
    } catch (error) {
      // CompactionService 内部已对"总结失败"做了回退；这里兜的是存储层等
      // 非预期异常。宁可这轮上下文大一点，也不能因此拒绝回复——但要让用户看见，
      // 且刷新后仍在（落库，见 [_notifyCompacted] 的说明）。
      _notifyOnce(
        'compact-failed|${agent.id}|$error',
        () => _sendNotice(
          agent,
          session,
          '上下文压缩失败：$error\n'
          '本轮会按未压缩的上下文继续（更可能撞上模型上限）；'
          '可在会话里手动压缩重试。',
          llmHidden: true,
        ),
      );
      return false;
    }
  }

  /// 「压缩已发生 / 降级 / 插件没接管」的可见提示——**落库**（`llm_hidden` 消息）。
  ///
  /// 为什么必须落库：这几条以前走 [_sendAdvisory]（只 broadcast、不落库），刷新或
  /// 重连后历史里就没有了，用户事后想核对"这次压缩走的是哪条路、插件为什么没接管"
  /// 只剩服务端账单可猜——而"压缩到底跑了几次、走的哪条路"正是本次要查的东西。
  /// 落成 `llm_hidden` 消息后：用户看得到、模型看不到（不插进下一轮提示词）、
  /// 刷新后仍在。
  ///
  /// **每次压缩记一条**（不做进程内去重）：压缩是真实发生过的上下文事件，去重会
  /// 把"跑了几次"这件事重新藏起来。降级信息并进同一条，避免两次压缩之间刷两条。
  ///
  /// **自动压缩与手动压缩（REST / 执行站 `agent.compact`）共用这一条文案口径**：
  /// 手动那条由 [notifyCompactionResult] 进来，别在别处复制第二套文案。
  void _notifyCompacted(
    CoreAgent agent,
    CoreSession session,
    CompactionResult result,
  ) {
    final String via = switch (result.source) {
      compactionSourceRelay => '插件中转站压缩',
      compactionSourceBuiltin => '内置压缩',
      _ => '',
    };
    final StringBuffer text = StringBuffer('上下文已压缩')
      ..write(via.isEmpty ? '' : '（来源：$via）')
      ..write('，当前 ${result.contextSize} 条');
    // 只有"没走中转站"时才谈"插件为什么没接管"（接管成功了就没有这回事）；
    // 而且**只写"有订阅者却没接管"**那类：早退（没装插件 / 总开关关 / 作用域不匹配 /
    // 无点位）写进历史只会让没装压缩插件的用户每条通知都多一句废话。
    // REST 响应不受此过滤影响（那里要全量，见 CompactionResult.relaySkipReason）。
    final String skip = result.relaySkipReason.trim();
    if (result.source != compactionSourceRelay &&
        result.relaySkipHasSubscriber &&
        skip.isNotEmpty) {
      text.write('\n这次插件没有接管：$skip');
    }
    if (result.degraded) {
      final String reason = result.degradedReason.trim();
      text.write(
        '\n但总结模型调用失败，本次用的是截断摘要（要点可能不全）；'
        '下一次压缩会重新尝试完整总结。',
      );
      if (reason.isNotEmpty) text.write('\n失败原因：$reason');
    }
    _sendNotice(agent, session, text.toString(), llmHidden: true);
  }

  /// **手动压缩**（REST `POST /api/agents/{id}/compact`、执行站 `agent.compact`）
  /// 的结论通知：压动了就落一条 `llm_hidden` 会话消息。
  ///
  /// 为什么要有这个公开入口：手动压缩发生在 [CoreServer] 里，它手上没有 agent/session
  /// 对象、也不该复制一套文案——文案口径只有一处（[_notifyCompacted]），自动压缩与
  /// 手动压缩因此**形状完全一致**（同一个 `llm_hidden` 机制、同一条文案）。
  /// 用户在界面上点「压缩」后刷新页面，历史里仍能看到"压缩已发生（来源：…）"。
  ///
  /// 没压动（`reason` 那几种）不落库：那是"无事发生"，前端 SnackBar 已经说清了。
  void notifyCompactionResult(
    String agentId,
    String sessionId,
    CompactionResult result,
  ) {
    if (!result.compressed) return;
    final CoreAgent? agent = store.agent(agentId);
    if (agent == null) return;
    final CoreSession? session = store.session(agentId, sessionId);
    if (session == null) return;
    _notifyCompacted(agent, session, result);
  }

  /// 模型没配 max_seqlen 时的可见提示（Q1-③：不再默默兜 128000）。
  ///
  /// 去重键只含模型：一个模型提示一次，否则每一轮都会往会话里塞同一条消息。
  void _warnIfBudgetFallback(
    CoreAgent agent,
    CoreSession session,
    CompactionService service,
  ) {
    final MaxSeqlenBudget budget = service.maxSeqlenFor(agent);
    if (!budget.fallback) return;
    _notifyOnce(
      'max-seqlen-fallback|${agent.modelId}',
      () => _sendAdvisory(
        agent,
        session,
        '模型「${agent.modelId}」没有配置 max_seqlen，压缩与上下文进度按兜底值 '
        '${budget.value} token 判断，可能明显偏离端点的真实上限；'
        '请到「设置 → 自定义模型」补上该模型的上下文长度。',
      ),
    );
  }

  /// 同一条提示在本次进程内只发一次（键由调用方给）。
  void _notifyOnce(String key, void Function() notify) {
    if (!_notified.add(key)) return;
    notify();
  }

  /// 按 id 发一条 `llm_hidden` 的**过程提示**（压缩重试进度这类）。
  ///
  /// 与 [_sendNotice] 的关系：那个要持有对象（生成路径手上就有）；这条是给"手里只有
  /// id"的接线方用的（例如 [CompactionService.noticeSink]——压缩发生在引擎回调里，
  /// 谁都不知道当下是哪个对象）。对象找不到就静默丢弃：提示丢了不影响压缩本身。
  void _sendHiddenNotice(String agentId, String sessionId, String text) {
    final CoreAgent? agent = store.agent(agentId);
    if (agent == null) return;
    final CoreSession? session = store.session(agentId, sessionId);
    if (session == null) return;
    _sendNotice(agent, session, text, llmHidden: true);
  }

  /// 推一条**不落库**的 agent 提示（只 broadcast），前端收到 message 帧就会渲染。
  ///
  /// **什么时候才该用它**：提示只在"当下"有意义、且每一轮都可能重复时（目前只剩
  /// "模型没配 max_seqlen"这一条：它每次都成立，落库会把历史刷满）。凡是"事后还要
  /// 能查"的（压缩已发生 / 降级 / 插件没接管 / 压缩失败），一律走 [_sendNotice]
  /// 的 `llmHidden: true` 落库通路——刷新后仍在，见 [_notifyCompacted]。
  ///
  /// 注：协议里没有独立的"状态栏"帧，message 帧是当前唯一前端可见的通道。
  void _sendAdvisory(CoreAgent agent, CoreSession session, String content) {
    hub.broadcast(<String, dynamic>{
      'type': WsOutboundType.message,
      'id': CoreIds.message(),
      'role': 'agent',
      'content': content,
      'kind': 'text',
      'agent_id': agent.id,
      'session_id': session.sessionId,
    });
  }

  void _sendError(String message) {
    hub.broadcast(<String, dynamic>{
      'type': WsOutboundType.error,
      'data': <String, dynamic>{'message': message},
    });
  }

  /// 规范化 `user_message` 帧里的附件列表。
  ///
  /// 两种形态都收（前端是唯一生产者，桌面端当前发的是 Map）：
  /// - **Map**：`{name, path, size, type}`，其中 `path` 是**工作空间相对路径**
  ///   （前端已把文件上传到工作空间，如 `.input/20261001/a.png`）——模型据此用
  ///   文件工具读取；
  /// - **String**：直接当作路径（兼容旧形态与手工调用）。
  ///
  /// 只保留 `path` 非空的条目：没有路径的附件对模型毫无意义，留着只会让提示词里
  /// 多出一行空项。整条列表没有可用项时返回 null（与"没有附件"同义），避免落库
  /// 出一堆空壳。
  static List<Map<String, dynamic>>? _attachments(Object? raw) {
    if (raw is! List<dynamic> || raw.isEmpty) return null;
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (final Object? entry in raw) {
      final Map<String, dynamic>? item = _attachmentOf(entry);
      if (item != null) out.add(item);
    }
    return out.isEmpty ? null : out;
  }

  /// 单条附件的规范化（非法/无路径返回 null）。
  ///
  /// 只认两种形态：`{'path': '...'}` 的 Map，或直接给路径的字符串。数字、嵌套
  /// 结构之类一律丢弃——把 `42` 当成路径只会让模型拿到一个不存在的文件。
  static Map<String, dynamic>? _attachmentOf(Object? entry) {
    if (entry is Map) {
      final Object? rawPath = entry['path'];
      if (rawPath is! String) return null;
      final String path = rawPath.trim();
      if (path.isEmpty) return null;
      final Object? rawName = entry['name'];
      final String name = rawName is String ? rawName.trim() : '';
      final Object? rawType = entry['type'];
      return <String, dynamic>{
        'name': name.isEmpty ? _baseNameOf(path) : name,
        'path': path,
        'size': (entry['size'] as num?)?.toInt() ?? 0,
        'type': rawType is String ? rawType.trim() : '',
      };
    }
    if (entry is! String) return null;
    final String path = entry.trim();
    if (path.isEmpty) return null;
    return <String, dynamic>{
      'name': _baseNameOf(path),
      'path': path,
      'size': 0,
      'type': '',
    };
  }

  /// 从路径取文件名（兼容 `/` 与 `\`）。
  static String _baseNameOf(String path) {
    final String replaced = path.replaceAll('\\', '/');
    final int idx = replaced.lastIndexOf('/');
    return idx >= 0 ? replaced.substring(idx + 1) : replaced;
  }
}

/// 推送刷新帧率（帧/秒）→ 帧窗口时长。
Duration frameWindowFor(int frameRate) {
  final int fps = frameRate < 1 ? 1 : frameRate;
  return Duration(microseconds: (1000000 / fps).ceil());
}

/// 流式「推送刷新帧率」：把同一消息的增量攒帧后按帧率合并成一条 `msg_chunk`。
///
/// 定时器每 `1/帧率` 秒把攒下的增量合并广播一次（同一消息一次一帧）；内容总量
/// 不变，只是把下发/渲染频率从「token 速率」降到「帧率」。任何非增量帧下发前都
/// 要先 [flush]，[dispose] 时停表并落地残余，保证界面顺序与事件顺序一致。
///
/// **单调序号**（M9 断线补发重播去重，协议契约见 `WsStreamSeq`）：本类是同一条
/// `msg_chunk` 的**唯一产出点**，序号因此在这里记账——
/// - **作用域**：按 message id 各自维护，**跨 id 独立**计数、互不干扰，各自从
///   [WsStreamSeq.firstSeq] 起；
/// - **一帧一个序号**：同一帧窗口里被合并的多个增量（多次 [add]）只占**一个**序号
///   ——序号是"第几帧"（帧计数），不是字节偏移 / token 下标；
/// - **严格递增**：同一 id 内每下发一条非空 `msg_chunk` 消耗一个序号；空增量不
///   落帧、也就不占号（否则前端水位会凭空多走一格）；
/// - **允许缺口**：本类只保证递增，不保证下游一定送达（补发队列溢出会丢最老的帧），
///   缺口由前端当作"那几帧没送到"处理，不是协议错误。
///
/// [frameWindow] 为 [Duration.zero] 时**不挂定时器**（节奏控制被关闭的测试形态）：
/// 攒下的增量只在显式 flush 点落地，整轮因此落在"同一帧窗口"里——这是确定性的
/// 关键，否则窗口边界落在哪一毫秒取决于 OS 计时器粒度与机器负载。
class _ChunkPump {
  _ChunkPump({
    required Duration frameWindow,
    required this.envelope,
    required this.hub,
  }) {
    if (frameWindow > Duration.zero) {
      _timer = Timer.periodic(frameWindow, (_) => flush());
    }
  }

  final Map<String, dynamic> envelope;
  final WsHub hub;
  Timer? _timer;

  /// 待下发增量：按消息首次出现的顺序保留（Dart Map 保序）。
  final Map<String, StringBuffer> _pending = <String, StringBuffer>{};

  /// 每条消息**下一个要用的序号**（缺项 = 该 id 还没下发过任何增量帧）。
  ///
  /// 只在下发一条非空 `msg_chunk` 时前进，因此"同一帧窗口合并掉的多个增量"
  /// 天然只占一个序号。计数器跨 [flush] 存活（攒帧窗口不止一个），随本轮
  /// pump 一起作废——message id 逐段唯一，不存在跨轮复用的旧水位。
  final Map<String, int> _nextSeq = <String, int>{};

  /// 追加一段增量（同消息的连续增量会在同一帧内合并）。
  void add(String id, String delta) {
    (_pending[id] ??= StringBuffer()).write(delta);
  }

  /// 该 id 的**封口水位** = 本段最后一条增量帧的序号；本段没下发过增量时返回 null
  /// （调用方据此**省略** `msg_end` 的序号字段，而不是写 [WsStreamSeq.firstSeq]：
  /// 0 是合法序号，写成 0 会让前端把第一条增量判成重播）。
  ///
  /// 调用方必须先 [flush]：还攒在 [_pending] 里的增量尚未下发，水位不该把它们算作
  /// "已下发"；而 `msg_end` 的语义是"≤ 该序号的增量都已下发完毕"，所以顺序必须是
  /// 先 flush 再取封口水位。
  int? sealSeq(String id) {
    final int? next = _nextSeq[id];
    return next == null ? null : next - 1;
  }

  /// 把攒下的增量合并成 `msg_chunk` 广播出去。
  void flush() {
    if (_pending.isEmpty) return;
    final List<MapEntry<String, StringBuffer>> batch = _pending.entries.toList(
      growable: false,
    );
    _pending.clear();
    for (final MapEntry<String, StringBuffer> entry in batch) {
      final String chunk = entry.value.toString();
      // 空增量不落帧：不占用序号（序号是"第几帧"，不是"第几次 add"）
      if (chunk.isEmpty) continue;
      // 取号即消费：一条帧一个序号，本 id 的下一条帧顺延。序号写在**帧上**，
      // 补发队列原样重播时随之回来 —— 前端按 (id, seq) 判重才成立。
      final int seq = _nextSeq[entry.key] ?? WsStreamSeq.firstSeq;
      _nextSeq[entry.key] = seq + 1;
      hub.broadcast(<String, dynamic>{
        'type': WsOutboundType.msgChunk,
        'id': entry.key,
        'chunk': chunk,
        WsStreamSeq.field: seq,
        ...envelope,
      });
    }
  }

  /// 结束本轮：停表并落地残余增量。
  void dispose() {
    _timer?.cancel();
    _timer = null;
    flush();
  }
}

/// token rate 管道（Q13）：**思考 / 正文 / 工具参数共用**的一条速率节流器。
///
/// 口径：`token = ceil(字符数 / token_scale)`（见 `util/tokens.dart`，全局唯一
/// 换算），速率取设置里的 token 速率（token/秒）。
///
/// 为什么是「目标时间轴 + 累计欠账」而不是「每个增量延迟 1/速率」：
/// - 后者会被 OS 计时器粒度放大成"实际速率随负载抖动"——Windows 上 6 次 1ms 的
///   `Future.delayed` 实测要 88~96ms，配置 1000 token/s 实际只有 ~64 token/s；
/// - 这里按 `已消费 token 数 / 速率` 算出**应到达的时刻**（时间轴原点在首次
///   消费时锚定）：落后于目标就直接放行（欠账一次性补掉，允许突发），超前才等到
///   目标时刻。平均速率因此恒等于配置值，与计时器粒度无关——与参考实现
///   `_FramePacer` 的"固定时间步"同一个道理。
///
/// 测试可注入 [clock] / [wait]（可控时钟 + 可控睡眠），断言不再依赖真实计时器。
class TokenPacer {
  TokenPacer({
    required this.tokensPerSecond,
    this.rateProvider,
    this.enabled = true,
    DateTime Function()? clock,
    Future<void> Function(Duration delay)? wait,
  }) : _clock = clock ?? DateTime.now,
       _wait = wait ?? Future<void>.delayed;

  /// 起始速率（token/秒）；<= 0 视为不限速。[rateProvider] 非空时它只作兜底。
  final double tokensPerSecond;

  /// 速率**现读**入口（可空）：设置页改速率后，正在进行的这一轮下一批 token 就
  /// 生效，而不必等下一次发消息。为空 = 用构造时的 [tokensPerSecond] 固定不变
  /// （测试与不关心热更新的调用方）。
  final double Function()? rateProvider;

  /// 当前速率（token/秒）：优先现读，否则取构造时的固定值。
  double get currentTokensPerSecond => rateProvider?.call() ?? tokensPerSecond;

  /// 总开关：false 时 [consume] 直接放行（关闭节奏控制，见 [pacingEnabled]）。
  final bool enabled;

  final DateTime Function() _clock;
  final Future<void> Function(Duration delay) _wait;

  /// 已消费的 token 数（累计欠账的分子）。
  double _consumed = 0;

  /// 时间轴原点；首次消费时才锚定，避免把"本轮开始前的等待"算进来。
  DateTime? _origin;

  /// 已消费的 token 总数（自检 / 测试用）。
  double get consumedTokens => _consumed;

  /// 消费 [tokens] 个 token 的额度。
  ///
  /// 返回时保证"应到达时刻"已到（或本来就已经落后于它）。
  Future<void> consume(int tokens) async {
    final double rate = currentTokensPerSecond;
    if (!enabled || rate <= 0 || tokens <= 0) return;
    final DateTime origin = _origin ??= _clock();
    _consumed += tokens;
    final Duration target = Duration(
      microseconds: (_consumed / rate * Duration.microsecondsPerSecond).round(),
    );
    final Duration lag = target - _clock().difference(origin);
    if (lag <= Duration.zero) return; // 落后：欠账直接补掉（可突发）
    await _wait(lag);
  }
}
