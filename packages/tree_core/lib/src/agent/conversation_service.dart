import 'dart:async';

import 'package:tree_protocol/tree_protocol.dart';

import '../settings/core_settings.dart';
import '../store/tree_store.dart';
import '../util/ids.dart';
import '../ws/ws_hub.dart';
import 'agent_engine.dart';
import 'question_broker.dart';
import 'scripted_agent.dart';

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

  bool get isEmpty => content.isEmpty && kind != 'tool';
}

/// 会话服务：把 WS 上行的 `user_message` / `stop` 变成"落库 + 流式下行"。
///
/// 本类只做**协议适配**：把 [AgentEngine] 产出的 [AgentEvent] 翻成既有 WS 帧，
/// 并把本轮产生的消息按事件顺序落库。生成逻辑（真实 LLM / 占位回显）在引擎里，
/// 因此 M5 的成员编排可以复用同一套事件而无需改这里。
///
/// 帧映射：
/// - [AgentText] → `msg_start(kind=text)` + `msg_chunk`；
/// - [AgentThinking] → `msg_start(kind=thinking)` + `msg_chunk`（前端渲染思考卡片）；
/// - [AgentToolStart]/[AgentToolEnd] → `tool_start`/`tool_end`（工具卡片）；
/// - [AgentUsage] → `msg_usage`；
/// - [AgentError] → `error` 帧 **+ 一条可见的 agent 文本消息**
///   （前端对 `error` 帧是静默忽略的，只发 error 用户会看不到任何反馈）；
/// - [AgentDone] → 每个流式消息的 `msg_end` + `agent_status(idle)`。
///
/// 并发策略：**按 agent 串行**（同一 agent 的多条消息排队执行）。同一会话的
/// 流式片段若交错下发，前端的 `msg_chunk` 追加会互相污染。
class ConversationService {
  ConversationService({
    required this.store,
    required this.hub,
    required this.settings,
    this.questions,
    AgentEngine? engine,
  }) : engine = engine ?? ScriptedAgent();

  final TreeStore store;
  final WsHub hub;
  final CoreSettings settings;

  /// 提问回路（M5a）；为 null 时 `user_answer` / `cancel_question` 帧被忽略。
  final QuestionBroker? questions;

  final AgentEngine engine;

  /// 每个 agent 的任务链尾（保证串行）。
  final Map<String, Future<void>> _chains = <String, Future<void>>{};

  /// 每个 agent 当前在途任务的取消令牌。
  final Map<String, _RunToken> _running = <String, _RunToken>{};

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

  /// 处理 `stop`：置位取消令牌，正在流式的任务会在下个检查点退出。
  ///
  /// 帧字段：`{type, data:{agent_id, session_id}}`。
  void handleStop(Map<String, dynamic> frame) {
    final Map<String, dynamic> data = _dataOf(frame);
    final String agentId =
        (data['agent_id'] as String?) ?? (frame['agent_id'] as String?) ?? '';
    if (agentId.isEmpty) return;
    // 先取消在途提问：等待中的工具会立刻拿到 cancelled 结果，工具循环才能收敛。
    questions?.cancelForAgent(agentId);
    final _RunToken? token = _running[agentId];
    if (token == null) return;
    token.cancelled = true;
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
    hub.broadcast(<String, dynamic>{
      'type': WsOutboundType.agentStatus,
      'data': <String, dynamic>{'agent_id': agent.id, 'status': 'working'},
    });

    // 本轮消息按**事件首次出现的顺序**记录，结束时统一落库：
    // 这样"界面看到的顺序"与"重载历史后的顺序"一致。
    final List<_PendingMessage> pending = <_PendingMessage>[];
    _PendingMessage? textMessage;
    _PendingMessage? thinkingMessage;
    final Map<String, _PendingMessage> toolMessages =
        <String, _PendingMessage>{};
    Map<String, dynamic>? usage;
    bool cancelled = false;
    String? errorMessage;

    void startStreamingMessage(_PendingMessage message) {
      pending.add(message);
      hub.broadcast(<String, dynamic>{
        'type': WsOutboundType.msgStart,
        'id': message.id,
        'kind': message.kind,
        ...envelope,
      });
    }

    void appendChunk(_PendingMessage message, String delta) {
      message.content.write(delta);
      hub.broadcast(<String, dynamic>{
        'type': WsOutboundType.msgChunk,
        'id': message.id,
        'chunk': delta,
        ...envelope,
      });
    }

    final AgentRunContext context = AgentRunContext(
      agentId: agent.id,
      sessionId: session.sessionId,
      modelId: agent.modelId,
      systemPrompt: agent.systemPrompt,
      userContent: userContent,
      // 用户消息已在 handleUserMessage 里落库，因此这里取到的历史已含本次输入
      history: store
          .messages(agent.id, session.sessionId)
          .map(_toRef)
          .toList(growable: false),
    );

    try {
      await for (final AgentEvent event in engine.run(
        context,
        isCancelled: () => token.cancelled,
      )) {
        if (event is AgentText) {
          final _PendingMessage message = textMessage ??= _PendingMessage(
            id: CoreIds.message(),
            kind: 'text',
          );
          if (message.content.isEmpty) startStreamingMessage(message);
          appendChunk(message, event.delta);
        } else if (event is AgentThinking) {
          final _PendingMessage message = thinkingMessage ??= _PendingMessage(
            id: CoreIds.message(),
            kind: 'thinking',
          );
          if (message.content.isEmpty) startStreamingMessage(message);
          appendChunk(message, event.delta);
        } else if (event is AgentToolStart) {
          final _PendingMessage message =
              _PendingMessage(id: event.id, kind: 'tool')
                ..toolName = event.name
                ..toolArguments = event.arguments
                ..toolCallId = event.callId;
          toolMessages[event.id] = message;
          pending.add(message);
          hub.broadcast(<String, dynamic>{
            'type': WsOutboundType.toolStart,
            'id': message.id,
            'name': event.name,
            'arguments': event.arguments,
            ...envelope,
          });
        } else if (event is AgentToolEnd) {
          final _PendingMessage? message = toolMessages[event.id];
          if (message == null) continue;
          message.toolResult = event.result;
          hub.broadcast(<String, dynamic>{
            'type': WsOutboundType.toolEnd,
            'id': event.id,
            'name': event.name,
            'result': event.result,
            ...envelope,
          });
        } else if (event is AgentUsage) {
          usage = event.usage;
          hub.broadcast(<String, dynamic>{
            'type': WsOutboundType.msgUsage,
            'id': textMessage?.id ?? '',
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

    // 端点没给 usage 时用本地估算兜底（前端上下文进度条依赖该字段）
    final Map<String, dynamic> finalUsage =
        usage ??
        usageOf(agent, userContent, textMessage?.content.toString() ?? '');

    // 每个已开始的流式消息都要收尾（前端据此结束流式态）
    for (final _PendingMessage message in pending) {
      if (message.kind == 'tool') continue;
      hub.broadcast(<String, dynamic>{
        'type': WsOutboundType.msgEnd,
        'id': message.id,
        'usage': message.kind == 'text' ? finalUsage : null,
        'cancelled': cancelled,
        ...envelope,
      });
    }

    // 落库（顺序与 UI 一致；空文本不落库）
    for (final _PendingMessage message in pending) {
      if (message.kind == 'tool') {
        if (message.toolName == null) continue;
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
        continue;
      }
      final String text = message.content.toString();
      if (text.isEmpty) continue;
      store.appendMessage(
        CoreMessage(
          id: message.id,
          agentId: agent.id,
          sessionId: session.sessionId,
          role: 'agent',
          content: text,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          kind: message.kind,
          usage: message.kind == 'text' ? finalUsage : null,
        ),
      );
    }

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
    unawaited(() async {
      try {
        await previous;
      } catch (_) {
        // 前序任务的错误已在内部上报，不阻断队列
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
  Map<String, dynamic> usageOf(
    CoreAgent agent,
    String prompt,
    String completion,
  ) {
    final CoreModelConfig? model = settings.model(agent.modelId);
    return agentUsageMap(
      promptTokens: estimateTokens(prompt),
      completionTokens: estimateTokens(completion),
      maxTokens: model?.effectiveMaxSeqlen ?? 128000,
      estimated: true,
    );
  }

  /// 粗略 token 估算：CJK 码点 ≈ 1 token，其余按 4 字符 ≈ 1 token。
  static int estimateTokens(String text) {
    int cjk = 0;
    int other = 0;
    for (final int rune in text.runes) {
      if ((rune >= 0x2E80 && rune <= 0x9FFF) ||
          (rune >= 0xF900 && rune <= 0xFAFF) ||
          (rune >= 0xFF00 && rune <= 0xFFEF)) {
        cjk++;
      } else {
        other++;
      }
    }
    return cjk + (other + 3) ~/ 4;
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
