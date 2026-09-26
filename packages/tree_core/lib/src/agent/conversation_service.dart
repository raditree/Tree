import 'dart:async';

import 'package:tree_protocol/tree_protocol.dart';

import '../settings/core_settings.dart';
import '../store/tree_store.dart';
import '../util/ids.dart';
import '../ws/ws_hub.dart';
import 'scripted_agent.dart';

/// 一次生成任务的取消令牌。
class _RunToken {
  bool cancelled = false;
}

/// 会话服务：把 WS 上行的 `user_message` / `stop` 变成"落库 + 流式下行"。
///
/// 这里是 M1 的**最小纵切面**：会话解析 → 用户消息落库 → agent_status
/// working → msg_start/msg_chunk/msg_end → agent_status idle。M3 换掉
/// [ReplyEngine] 实现即接入真实 LLM；M5 在此之上叠加成员编排与提问暂停。
///
/// 并发策略：**按 agent 串行**（同一 agent 的多条消息排队执行）。理由与现状
/// server 的"串行排队"默认一致：同一会话的流式片段若交错下发，前端的
/// `msg_chunk` 追加会互相污染（消息面板按 id 定位，但语义上仍是一轮一答）。
class ConversationService {
  ConversationService({
    required this.store,
    required this.hub,
    required this.settings,
    ReplyEngine? engine,
  }) : engine = engine ?? ScriptedAgent();

  final TreeStore store;
  final WsHub hub;
  final CoreSettings settings;
  final ReplyEngine engine;

  /// 每个 agent 的任务链尾（保证串行）。
  final Map<String, Future<void>> _chains = <String, Future<void>>{};

  /// 每个 agent 当前在途任务的取消令牌。
  final Map<String, _RunToken> _running = <String, _RunToken>{};

  /// 当前在途生成数（自检/日志用）。
  int get activeRunCount => _running.length;

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

  /// 处理 `stop`：置位取消令牌，正在流式的任务会在下个片段检查点退出。
  ///
  /// 帧字段：`{type, data:{agent_id, session_id}}`。
  void handleStop(Map<String, dynamic> frame) {
    final Map<String, dynamic> data =
        (frame['data'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final String agentId =
        (data['agent_id'] as String?) ?? (frame['agent_id'] as String?) ?? '';
    final _RunToken? token = _running[agentId];
    if (token == null) return;
    token.cancelled = true;
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
    final String messageId = CoreIds.message();
    final Map<String, dynamic> envelope = <String, dynamic>{
      'agent_id': agent.id,
      'session_id': session.sessionId,
    };
    hub.broadcast(<String, dynamic>{
      'type': WsOutboundType.agentStatus,
      'data': <String, dynamic>{'agent_id': agent.id, 'status': 'working'},
    });
    hub.broadcast(<String, dynamic>{
      'type': WsOutboundType.msgStart,
      'id': messageId,
      'kind': 'text',
      ...envelope,
    });
    final StringBuffer buffer = StringBuffer();
    bool cancelled = false;
    try {
      await for (final String chunk in engine.stream(
        agentId: agent.id,
        systemPrompt: agent.systemPrompt,
        userContent: userContent,
        isCancelled: () => token.cancelled,
      )) {
        if (token.cancelled) {
          cancelled = true;
          break;
        }
        buffer.write(chunk);
        hub.broadcast(<String, dynamic>{
          'type': WsOutboundType.msgChunk,
          'id': messageId,
          'chunk': chunk,
          ...envelope,
        });
      }
    } catch (e) {
      _sendError('生成失败：$e');
    }
    if (token.cancelled) cancelled = true;

    final String full = buffer.toString();
    final Map<String, dynamic> usage = usageOf(agent, userContent, full);
    if (full.isNotEmpty) {
      store.appendMessage(
        CoreMessage(
          id: messageId,
          agentId: agent.id,
          sessionId: session.sessionId,
          role: 'agent',
          content: full,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          usage: usage,
        ),
      );
    }
    hub.broadcast(<String, dynamic>{
      'type': WsOutboundType.msgEnd,
      'id': messageId,
      'usage': usage,
      'cancelled': cancelled,
      ...envelope,
    });
    if (cancelled) {
      // 停止反馈走 `message` 帧（完整 ChatMessage 形态），前端直接追加一条
      hub.broadcast(<String, dynamic>{
        'type': WsOutboundType.message,
        'id': CoreIds.message(),
        'role': 'agent',
        'content': '已停止本轮生成。',
        'kind': 'text',
        ...envelope,
      });
    }
    hub.broadcast(<String, dynamic>{
      'type': WsOutboundType.agentStatus,
      'data': <String, dynamic>{'agent_id': agent.id, 'status': 'idle'},
    });
    _running.remove(agent.id);
  }

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

  /// 本轮 token 用量（M1 为估算值；M3 改用端点返回的真实 usage）。
  Map<String, dynamic> usageOf(
    CoreAgent agent,
    String prompt,
    String completion,
  ) {
    final int promptTokens = estimateTokens(prompt);
    final int completionTokens = estimateTokens(completion);
    final CoreModelConfig? model = settings.model(agent.modelId);
    return <String, dynamic>{
      'prompt_tokens': promptTokens,
      'completion_tokens': completionTokens,
      'total_tokens': promptTokens + completionTokens,
      'max_tokens': model?.effectiveMaxSeqlen ?? 128000,
      'estimated': true,
    };
  }

  /// 粗略 token 估算：CJK 码点 ≈ 1 token，其余按 4 字符 ≈ 1 token。
  ///
  /// 仅在 M1 占位引擎下使用；结果带 `estimated: true` 标记，避免 UI 把它
  /// 当成真实计费数据。
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
