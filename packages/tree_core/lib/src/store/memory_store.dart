import '../util/ids.dart';
import '../util/json_time.dart';

/// agent 记录（现状 server `agents` 表的桌面替身）。
///
/// `toJson` 是**持久化形态**（M2 落 `~/.tree/agents/<id>.yaml`，时间用
/// ISO 字符串便于人读）；`toApiJson` 是**前端形态**（字段名与现状 server
/// 的 `GET /api/agents` 一致，时间用毫秒整数）。
class CoreAgent {
  CoreAgent({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.systemPrompt = '',
    this.modelId = '',
    this.workspaceId = '',
    this.teamMemberCount = 0,
    this.maxLevel = 1,
    this.maxMembersPerLevel = 0,
  });

  final String id;
  String name;
  String systemPrompt;
  String modelId;
  String workspaceId;
  int teamMemberCount;
  int maxLevel;
  int maxMembersPerLevel;
  final int createdAt;
  int updatedAt;

  /// 持久化形态。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'system_prompt': systemPrompt,
    'model_id': modelId,
    'workspace_id': workspaceId,
    'team_member_count': teamMemberCount,
    'max_level': maxLevel,
    'max_members_per_level': maxMembersPerLevel,
    'created_at': JsonTime.encode(createdAt),
    'updated_at': JsonTime.encode(updatedAt),
  };

  /// 从前端形态或持久化形态还原（两种形态字段名一致，仅时间表示不同）。
  static CoreAgent fromJson(Map<String, dynamic> json) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    return CoreAgent(
      id: json['id'] as String? ?? CoreIds.agent(),
      name: json['name'] as String? ?? '',
      systemPrompt: json['system_prompt'] as String? ?? '',
      modelId: json['model_id'] as String? ?? '',
      workspaceId: json['workspace_id'] as String? ?? '',
      teamMemberCount: (json['team_member_count'] as num?)?.toInt() ?? 0,
      maxLevel: (json['max_level'] as num?)?.toInt() ?? 1,
      maxMembersPerLevel: (json['max_members_per_level'] as num?)?.toInt() ?? 0,
      createdAt: JsonTime.decode(json['created_at']) ?? now,
      updatedAt: JsonTime.decode(json['updated_at']) ?? now,
    );
  }

  /// 前端形态（`GET /api/agents` 列表项与创建响应）。
  Map<String, dynamic> toApiJson({
    String lastMessage = '',
    int? lastMessageTime,
    int unreadCount = 0,
    int pendingMemberCount = 0,
  }) => <String, dynamic>{
    'id': id,
    'name': name,
    'type': 'normal',
    'system_prompt': systemPrompt,
    'model_id': modelId,
    'workspace_id': workspaceId,
    'last_message': lastMessage,
    'last_message_time': lastMessageTime,
    'unread_count': unreadCount,
    'avatar_url': null,
    'pending_member_count': pendingMemberCount,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };
}

/// 会话记录（现状 server `sessions` 表的桌面替身）。
class CoreSession {
  CoreSession({
    required this.sessionId,
    required this.agentId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.status = 'active',
    List<String>? selectedSpecIds,
  }) : selectedSpecIds = selectedSpecIds ?? <String>[];

  /// 兜底默认会话 id（与前端 `_currentSessionId` 的缺省值一致）。
  static const String defaultSessionId = 'session_default';

  final String sessionId;
  final String agentId;
  String title;
  String status;
  final int createdAt;
  int updatedAt;
  List<String> selectedSpecIds;

  /// 是否为兜底默认会话。
  bool get isDefault => sessionId == defaultSessionId;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'session_id': sessionId,
    'agent_id': agentId,
    'title': title,
    'status': status,
    'selected_spec_ids': selectedSpecIds,
    'created_at': JsonTime.encode(createdAt),
    'updated_at': JsonTime.encode(updatedAt),
  };

  static CoreSession fromJson(Map<String, dynamic> json) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    return CoreSession(
      sessionId: json['session_id'] as String? ?? defaultSessionId,
      agentId: json['agent_id'] as String? ?? '',
      title: json['title'] as String? ?? '新会话',
      status: json['status'] as String? ?? 'active',
      selectedSpecIds:
          (json['selected_spec_ids'] as List<dynamic>?)
              ?.map((dynamic e) => e.toString())
              .toList() ??
          <String>[],
      createdAt: JsonTime.decode(json['created_at']) ?? now,
      updatedAt: JsonTime.decode(json['updated_at']) ?? now,
    );
  }

  Map<String, dynamic> toApiJson({int messageCount = 0}) => <String, dynamic>{
    'session_id': sessionId,
    'agent_id': agentId,
    'title': title,
    'status': status,
    'selected_spec_ids': selectedSpecIds,
    'message_count': messageCount,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };
}

/// 消息记录（现状 server `messages` 表的桌面替身）。
///
/// 形态即前端 `ChatMessage.fromJson` 的输入（`GET /api/conversations/...`
/// 与 WS `message` 帧共用），因此 [toJson] 同时是持久化形态与 API 形态。
class CoreMessage {
  CoreMessage({
    required this.id,
    required this.agentId,
    required this.sessionId,
    required this.role,
    required this.content,
    required this.timestamp,
    this.kind = 'text',
    this.toolName,
    this.toolArguments,
    this.toolResult = '',
    this.usage,
    this.attachments,
    this.options,
    this.answered = false,
  });

  final String id;
  final String agentId;
  final String sessionId;
  final String role;
  final String content;
  final int timestamp;
  final String kind;
  final String? toolName;
  final Map<String, dynamic>? toolArguments;
  final String toolResult;
  final Map<String, dynamic>? usage;
  final List<Map<String, dynamic>>? attachments;
  final List<String>? options;
  final bool answered;

  bool get isTool => kind == 'tool';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'agent_id': agentId,
    'session_id': sessionId,
    'role': role,
    'content': content,
    'timestamp': JsonTime.encode(timestamp),
    'kind': kind,
    'tool_name': toolName,
    'tool_arguments': toolArguments,
    'tool_result': toolResult,
    'usage': usage,
    'attachments': attachments,
    'options': options ?? const <String>[],
    'answered': answered,
    'is_streaming': false,
  };

  static CoreMessage fromJson(Map<String, dynamic> json) {
    return CoreMessage(
      id: json['id'] as String? ?? CoreIds.message(),
      agentId: json['agent_id'] as String? ?? '',
      sessionId: json['session_id'] as String? ?? CoreSession.defaultSessionId,
      role: json['role'] as String? ?? 'agent',
      content: json['content'] as String? ?? '',
      timestamp:
          JsonTime.decode(json['timestamp']) ??
          DateTime.now().millisecondsSinceEpoch,
      kind: json['kind'] as String? ?? 'text',
      toolName: json['tool_name'] as String?,
      toolArguments: (json['tool_arguments'] as Map<dynamic, dynamic>?)?.map(
        (dynamic k, dynamic v) => MapEntry(k.toString(), v),
      ),
      toolResult: json['tool_result'] as String? ?? '',
      usage: (json['usage'] as Map<dynamic, dynamic>?)?.map(
        (dynamic k, dynamic v) => MapEntry(k.toString(), v),
      ),
      attachments: (json['attachments'] as List<dynamic>?)
          ?.map(
            (dynamic e) =>
                Map<String, dynamic>.from(e as Map<dynamic, dynamic>),
          )
          .toList(),
      options: (json['options'] as List<dynamic>?)
          ?.map((dynamic e) => e.toString())
          .toList(),
      answered: json['answered'] as bool? ?? false,
    );
  }
}

/// 纯内存存储（M1 骨架 -> M2 落盘）。
///
/// **接口即契约**：M2 会用 `~/.tree` 下的 `config/*.yaml` + 每会话一个
/// `session.json` / `messages.jsonl` 实现同一组方法，调用方（HTTP 路由、
/// WS 会话服务）无需改动。因此这里刻意不暴露任何 Map 细节，只提供
/// 语义化操作与 [toJson] / [fromJson] 记录，便于 M2 直接复用序列化格式。
class MemoryStore {
  /// 默认会话 id（与前端 `_currentSessionId` 的兜底值一致）。
  static const String defaultSessionId = CoreSession.defaultSessionId;

  final Map<String, CoreAgent> _agents = <String, CoreAgent>{};
  final Map<String, CoreSession> _sessions = <String, CoreSession>{};
  final Map<String, List<CoreMessage>> _messages =
      <String, List<CoreMessage>>{};

  // ── agent ────────────────────────────────────────────────────────────

  List<CoreAgent> agents() => _agents.values.toList()
    ..sort((CoreAgent a, CoreAgent b) => b.updatedAt.compareTo(a.updatedAt));

  CoreAgent? agent(String id) => _agents[id];

  CoreAgent createAgent({
    required String name,
    String systemPrompt = '',
    String modelId = '',
    int teamMemberCount = 0,
    int maxLevel = 1,
    int maxMembersPerLevel = 0,
  }) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final String id = CoreIds.agent();
    final CoreAgent agent = CoreAgent(
      id: id,
      name: name.isEmpty ? '新 Agent' : name,
      systemPrompt: systemPrompt,
      modelId: modelId,
      // 桌面端工作空间就是本机目录（M4 由用户指定）；此处先给稳定占位 id
      workspaceId: 'ws_$id',
      teamMemberCount: teamMemberCount,
      maxLevel: maxLevel,
      maxMembersPerLevel: maxMembersPerLevel,
      createdAt: now,
      updatedAt: now,
    );
    _agents[id] = agent;
    ensureDefaultSession(id);
    return agent;
  }

  void putAgent(CoreAgent agent) {
    _agents[agent.id] = agent;
    ensureDefaultSession(agent.id);
  }

  /// 更新 agent；仅当传入非 null 的字段被覆盖。
  CoreAgent? updateAgent(
    String id, {
    String? name,
    String? systemPrompt,
    String? modelId,
  }) {
    final CoreAgent? agent = _agents[id];
    if (agent == null) return null;
    if (name != null) agent.name = name;
    if (systemPrompt != null) agent.systemPrompt = systemPrompt;
    if (modelId != null) agent.modelId = modelId;
    agent.updatedAt = DateTime.now().millisecondsSinceEpoch;
    return agent;
  }

  bool deleteAgent(String id) {
    if (_agents.remove(id) == null) return false;
    _sessions.removeWhere((_, CoreSession s) => s.agentId == id);
    _messages.removeWhere((String key, _) => key.startsWith('$id::'));
    return true;
  }

  /// 该 agent 最近一条文本消息（列表页预览用）。
  CoreMessage? lastTextMessage(String agentId) {
    CoreMessage? latest;
    for (final MapEntry<String, List<CoreMessage>> entry in _messages.entries) {
      if (!entry.key.startsWith('$agentId::')) continue;
      for (final CoreMessage m in entry.value) {
        if (m.isTool || m.role != 'agent') continue;
        if (latest == null || m.timestamp > latest.timestamp) latest = m;
      }
    }
    return latest;
  }

  // ── session ──────────────────────────────────────────────────────────

  List<CoreSession> sessions(String agentId) =>
      _sessions.values.where((CoreSession s) => s.agentId == agentId).toList()
        ..sort(
          (CoreSession a, CoreSession b) => b.updatedAt.compareTo(a.updatedAt),
        );

  CoreSession? session(String agentId, String sessionId) {
    final CoreSession? session = _sessions[sessionId];
    return (session != null && session.agentId == agentId) ? session : null;
  }

  /// 兜底默认会话：前端在无会话时回退 `session_default`，故每个 agent
  /// 建立时即保证该会话存在（对齐现状 server 的 `list_sessions` 行为）。
  CoreSession ensureDefaultSession(String agentId) {
    final CoreSession? existing = session(agentId, defaultSessionId);
    if (existing != null) return existing;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final CoreSession created = CoreSession(
      sessionId: defaultSessionId,
      agentId: agentId,
      title: '默认会话',
      createdAt: now,
      updatedAt: now,
    );
    _sessions[defaultSessionId] = created;
    return created;
  }

  CoreSession? createSession(
    String agentId, {
    String title = '',
    String? sessionId,
  }) {
    if (_agents[agentId] == null) return null;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final String id = (sessionId != null && sessionId.isNotEmpty)
        ? sessionId
        : CoreIds.session();
    if (_sessions.containsKey(id)) return _sessions[id];
    final CoreSession created = CoreSession(
      sessionId: id,
      agentId: agentId,
      title: title.isEmpty ? '新会话' : title,
      createdAt: now,
      updatedAt: now,
    );
    _sessions[id] = created;
    return created;
  }

  bool renameSession(String agentId, String sessionId, String title) {
    final CoreSession? session = this.session(agentId, sessionId);
    if (session == null) return false;
    session.title = title.isEmpty ? session.title : title;
    session.updatedAt = DateTime.now().millisecondsSinceEpoch;
    return true;
  }

  bool deleteSession(String agentId, String sessionId) {
    final CoreSession? session = this.session(agentId, sessionId);
    if (session == null) return false;
    _sessions.remove(sessionId);
    _messages.remove(_messagesKey(agentId, sessionId));
    return true;
  }

  int setSelectedSpecs(String agentId, String sessionId, List<String> specIds) {
    final CoreSession? session = this.session(agentId, sessionId);
    if (session == null) return 0;
    session.selectedSpecIds = List<String>.of(specIds);
    return session.selectedSpecIds.length;
  }

  // ── message ──────────────────────────────────────────────────────────

  static String _messagesKey(String agentId, String sessionId) =>
      '$agentId::$sessionId';

  List<CoreMessage> messages(String agentId, String sessionId) =>
      List<CoreMessage>.unmodifiable(
        _messages[_messagesKey(agentId, sessionId)] ?? const <CoreMessage>[],
      );

  /// 该会话的「有效消息数」：仅统计文本消息（工具卡片不计入）。
  ///
  /// 前端用 `message_count > 0` 判定该 agent 是否已开始过对话（运行模式
  /// 锁定），工具卡片不算对话开始，故与文本消息口径对齐。
  int messageCount(String agentId, String sessionId) =>
      messages(agentId, sessionId).where((CoreMessage m) => !m.isTool).length;

  CoreMessage appendMessage(CoreMessage message) {
    final List<CoreMessage> list = _messages.putIfAbsent(
      _messagesKey(message.agentId, message.sessionId),
      () => <CoreMessage>[],
    );
    list.add(message);
    final CoreSession? session = _sessions[message.sessionId];
    if (session != null) session.updatedAt = message.timestamp;
    final CoreAgent? agent = _agents[message.agentId];
    if (agent != null) agent.updatedAt = message.timestamp;
    return message;
  }

  /// 清空某会话消息；[sessionId] 为 null 或 'all' 时清空该 agent 全部会话。
  int clearMessages(String agentId, {String? sessionId}) {
    if (sessionId == null || sessionId.isEmpty || sessionId == 'all') {
      int deleted = 0;
      _messages.removeWhere((String key, List<CoreMessage> value) {
        if (!key.startsWith('$agentId::')) return false;
        deleted += value.length;
        return true;
      });
      return deleted;
    }
    final List<CoreMessage>? removed = _messages.remove(
      _messagesKey(agentId, sessionId),
    );
    return removed?.length ?? 0;
  }

  /// 全部 agent 的消息总量（自检/日志用）。
  int get totalMessageCount => _messages.values.fold<int>(
    0,
    (int sum, List<CoreMessage> list) => sum + list.length,
  );
}
