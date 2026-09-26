import 'dart:async';
import 'dart:convert';

import 'package:tree_protocol/tree_protocol.dart';

import '../settings/core_settings.dart';
import '../store/tree_store.dart';
import '../util/ids.dart';
import '../util/tokens.dart' as tokens;
import '../llm/llm_agent_engine.dart';
import '../ws/ws_hub.dart';
import 'agent_engine.dart';
import 'compaction_service.dart';
import 'question_broker.dart';
import 'scripted_agent.dart';
import 'workspace_prompt.dart';

/// 一次生成任务的取消令牌。
class _RunToken {
  bool cancelled = false;
}

/// 本轮正在生成的一条消息（与前端消息一一对应：先立 start，再追加 chunk）。
class _PendingMessage {
  _PendingMessage({required this.id, required this.kind});

  final String id;
  final String kind;
  final StringBuffer content = StringBuffer();
  String? toolName;
  Map<String, dynamic>? toolArguments;
  String toolResult = '';
  String toolCallId = '';
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
/// - 推送刷新帧率：增量攒帧后按帧率合并成一条 `msg_chunk`（[_ChunkPump]）。
///
/// 并发策略：**按 agent 串行**（同一 agent 的多条消息排队执行）。同一会话的
/// 流式片段若交错下发，前端的 `msg_chunk` 追加会互相污染。
class ConversationService {
  ConversationService({
    required this.store,
    required this.hub,
    required this.settings,
    this.questions,
    this.compaction,
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
    }
  }

  final TreeStore store;
  final WsHub hub;
  final CoreSettings settings;

  /// 提问回路（M5a）；为 null 时 `user_answer` / `cancel_question` 帧被忽略。
  final QuestionBroker? questions;

  /// 上下文压缩（M7d-4）；为 null 时不做自动压缩（最小骨架/部分测试）。
  final CompactionService? compaction;

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

  /// 每个 agent 的任务链尾（保证串行）。
  final Map<String, Future<void>> _chains = <String, Future<void>>{};

  /// 每个 agent 当前在途任务的取消令牌。
  final Map<String, _RunToken> _running = <String, _RunToken>{};

  /// 每个 agent 的**任务代次**：stop 时 +1，丢弃此前还在排队、尚未开始的任务。
  final Map<String, int> _epoch = <String, int>{};

  /// 因 `stop` 被丢弃的排队任务数（自检/测试用）。
  int droppedQueuedCount = 0;

  /// 已提示过的"压缩失败 / 模型没配 max_seqlen"（同一件事只打扰用户一次）。
  final Set<String> _notified = <String>{};

  /// 当前在途生成数（自检/日志用）。
  int get activeRunCount => _running.length;

  /// 某 agent 是否正在生成（团队名单的 `working` 状态唯一权威）。
  bool isRunning(String agentId) => _running.containsKey(agentId);

  /// 处理 `user_message`。
  ///
  /// 帧字段（与现状 server 一致）：
  /// `{type, agent_id, content, attachments, session_id}`。
  Future<void> handleUserMessage(Map<String, dynamic> frame) {
    final String agentId = frame['agent_id'] as String? ?? '';
    final String content = frame['content'] as String? ?? '';
    final String sessionId = frame['session_id'] as String? ?? '';
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
    return _enqueue(agent.id, () => _runReply(agent, session, content));
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
    final _RunToken? token = _running[agentId];
    if (token == null) return false;
    token.cancelled = true;
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
    return _enqueue(agent.id, () => _runReply(agent, session, text));
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
  }) {
    final CoreAgent? agent = store.agent(agentId);
    final CoreSession? session = store.session(agentId, sessionId);
    if (agent == null || session == null) return Future<void>.value();
    _sendNotice(agent, session, notice);
    return _enqueue(agentId, () => _runReply(agent, session, notice));
  }

  /// 中止全部在途生成（服务器关闭时）。
  void dispose() {
    for (final _RunToken token in _running.values) {
      token.cancelled = true;
    }
    _running.clear();
    _chains.clear();
    _notified.clear();
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
  ) async {
    final _RunToken token = _RunToken();
    _running[agent.id] = token;
    final Map<String, dynamic> envelope = <String, dynamic>{
      'agent_id': agent.id,
      'session_id': session.sessionId,
    };
    // Q13：token 管道（思考 / 正文 / 工具参数**共用一条**）。本轮内复用同一个
    // 节拍器，三者的时间轴因此连续，速率口径也完全一致。
    final TokenPacer roundPacer =
        pacer ??
        TokenPacer(
          tokensPerSecond: settings.tokenAcquisitionRate.toDouble(),
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
      'data': <String, dynamic>{'agent_id': agent.id, 'status': 'working'},
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
    // 整轮正文：端点没给 usage 时，completion 的兜底口径是**整轮**生成量。
    final StringBuffer roundText = StringBuffer();
    Map<String, dynamic>? usage;
    bool cancelled = false;
    String? errorMessage;

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
            agentId: agent.id,
            sessionId: session.sessionId,
            role: 'agent',
            content: '',
            timestamp: DateTime.now().millisecondsSinceEpoch,
            kind: 'tool',
            toolName: message.toolName,
            toolArguments: message.toolArguments,
            toolResult: message.toolResult,
            toolCallId: message.toolCallId.isEmpty ? null : message.toolCallId,
          ),
        );
        return;
      }
      final String body = message.content.toString();
      if (body.isEmpty) return;
      store.appendMessage(
        CoreMessage(
          id: message.id,
          agentId: agent.id,
          sessionId: session.sessionId,
          role: 'agent',
          content: body,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          kind: message.kind,
          usage: usage,
        ),
      );
    }

    /// 结束一段：`msg_end` + 落库（对应参考实现的 `_close_thinking` / `_close_text`）。
    void endSegment(
      _PendingMessage message, {
      Map<String, dynamic>? usage,
      bool cancelled = false,
    }) {
      pump.flush();
      hub.broadcast(<String, dynamic>{
        'type': WsOutboundType.msgEnd,
        'id': message.id,
        'usage': usage,
        'cancelled': cancelled,
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
    await _autoCompact(agent, session);
    final AgentRunContext context = _contextOf(agent, session, userContent);

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
                ..toolCallId = event.callId;
          toolSegments[event.id] = message;
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

    final String? failure = errorMessage;
    if (failure != null) {
      // 1) error 帧（日志/遥测）；2) 一条**可见**的 agent 消息（前端只忽略 error 帧）
      _sendError(failure);
      _sendNotice(agent, session, failure);
    }
    if (cancelled) {
      _sendNotice(agent, session, '已停止本轮生成。');
    }
    hub.broadcast(<String, dynamic>{
      'type': WsOutboundType.agentStatus,
      'data': <String, dynamic>{'agent_id': agent.id, 'status': 'idle'},
    });
    _running.remove(agent.id);
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
  void _sendNotice(CoreAgent agent, CoreSession session, String content) {
    final String id = CoreIds.message();
    hub.broadcast(<String, dynamic>{
      'type': WsOutboundType.message,
      'id': id,
      'role': 'agent',
      'content': content,
      'kind': 'text',
      'agent_id': agent.id,
      'session_id': session.sessionId,
    });
    store.appendMessage(
      CoreMessage(
        id: id,
        agentId: agent.id,
        sessionId: session.sessionId,
        role: 'agent',
        content: content,
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// 存储消息 → 引擎视图。
  static CoreMessageRef _toRef(CoreMessage message) => CoreMessageRef(
    role: message.role,
    content: message.content,
    kind: message.kind,
    toolName: message.toolName,
    toolArguments: message.toolArguments,
    toolResult: message.toolResult,
    toolCallId: message.toolCallId,
    timestamp: message.timestamp,
  );

  /// 按 agent 串行执行：前一个任务（含失败）结束后才启动下一个。
  Future<void> _enqueue(String agentId, Future<void> Function() task) {
    final Future<void> previous = _chains[agentId] ?? Future<void>.value();
    final Completer<void> gate = Completer<void>();
    _chains[agentId] = gate.future;
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
        if (identical(_chains[agentId], gate.future)) _chains.remove(agentId);
        return;
      }
      try {
        await task();
      } catch (e) {
        _sendError('会话任务异常：$e');
      }
      if (!gate.isCompleted) gate.complete();
      if (identical(_chains[agentId], gate.future)) {
        _chains.remove(agentId);
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

  /// 构造引擎看到的运行上下文（生成前与工具循环内压缩后共用同一份装配逻辑）。
  AgentRunContext _contextOf(
    CoreAgent agent,
    CoreSession session, [
    String userContent = '',
  ]) {
    // 压缩会把摘要与水位线写回会话对象；重新取一次避免拿到过期快照
    final CoreSession fresh =
        store.session(agent.id, session.sessionId) ?? session;
    return AgentRunContext(
      agentId: agent.id,
      sessionId: fresh.sessionId,
      modelId: agent.modelId,
      systemPrompt: systemPromptWithWorkspace(agent),
      userContent: userContent,
      contextSummary: fresh.compactedSummary,
      compactedMessageCount: fresh.compactedMessageCount,
      // 用户消息已在 handleUserMessage 里落库，因此这里取到的历史已含本次输入
      history: store
          .messages(agent.id, fresh.sessionId)
          .map(_toRef)
          .toList(growable: false),
    );
  }

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
      if (result != null && result.compressed && result.degraded) {
        // 总结模型没跑成功、退化成截断摘要：压缩是压了，但要点可能不全，必须说
        _notifyOnce(
          'compact-degraded|${agent.id}',
          () => _sendAdvisory(
            agent,
            session,
            '上下文已压缩，但总结模型调用失败，本次用的是截断摘要（要点可能不全）；'
            '下一次压缩会重新尝试完整总结。',
          ),
        );
      }
      return result?.compressed ?? false;
    } catch (error) {
      // CompactionService 内部已对"总结失败"做了回退；这里兜的是存储层等
      // 非预期异常。宁可这轮上下文大一点，也不能因此拒绝回复——但要让用户看见。
      _notifyOnce(
        'compact-failed|${agent.id}|$error',
        () => _sendAdvisory(
          agent,
          session,
          '上下文压缩失败：$error\n'
          '本轮会按未压缩的上下文继续（更可能撞上模型上限）；'
          '可在会话里手动压缩重试。',
        ),
      );
      return false;
    }
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

  /// 推一条**不落库**的 agent 提示（诊断用），前端收到 message 帧就会渲染。
  ///
  /// 为什么不复用 [_sendNotice]：那些诊断（压缩失败 / 模型没配 max_seqlen / 压缩
  /// 降级）往往发生在"用户消息已落库、模型还没回答"之间，落库会让它插进上下文里，
  /// 模型下一轮会拿这条系统提示当对话内容来回。前端可见即可，历史里不留噪声。
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

  static List<Map<String, dynamic>>? _attachments(Object? raw) {
    if (raw is! List<dynamic> || raw.isEmpty) return null;
    return raw
        .whereType<Map<dynamic, dynamic>>()
        .map(
          (Map<dynamic, dynamic> e) =>
              e.map((dynamic k, dynamic v) => MapEntry(k.toString(), v)),
        )
        .toList();
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

  /// 追加一段增量（同消息的连续增量会在同一帧内合并）。
  void add(String id, String delta) {
    (_pending[id] ??= StringBuffer()).write(delta);
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
      if (chunk.isEmpty) continue;
      hub.broadcast(<String, dynamic>{
        'type': WsOutboundType.msgChunk,
        'id': entry.key,
        'chunk': chunk,
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
    this.enabled = true,
    DateTime Function()? clock,
    Future<void> Function(Duration delay)? wait,
  }) : _clock = clock ?? DateTime.now,
       _wait = wait ?? Future<void>.delayed;

  /// 速率（token/秒）；<= 0 视为不限速。
  final double tokensPerSecond;

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
    if (!enabled || tokensPerSecond <= 0 || tokens <= 0) return;
    final DateTime origin = _origin ??= _clock();
    _consumed += tokens;
    final Duration target = Duration(
      microseconds:
          (_consumed / tokensPerSecond * Duration.microsecondsPerSecond)
              .round(),
    );
    final Duration lag = target - _clock().difference(origin);
    if (lag <= Duration.zero) return; // 落后：欠账直接补掉（可突发）
    await _wait(lag);
  }
}
