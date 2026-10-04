import '../util/ids.dart';
import 'tree_store.dart';

/// 纯内存存储（M1 起作为测试与"无落盘"场景的实现）。
///
/// 与落盘实现（`FileTreeStore`）共享同一份契约测试，因此业务代码不会依赖
/// 任何内存实现特有的行为。
class MemoryStore implements TreeStore {
  /// 默认会话 id（与前端 `_currentSessionId` 的兜底值一致）。
  static const String defaultSessionId = CoreSession.defaultSessionId;

  final Map<String, CoreAgent> _agents = <String, CoreAgent>{};
  final Map<String, CoreSession> _sessions = <String, CoreSession>{};
  final Map<String, List<CoreMessage>> _messages =
      <String, List<CoreMessage>>{};

  /// 临时员工名册（`agentId::sessionId` → 记录）。与 [FileTreeStore] 同一契约：
  /// 只在该会话里可见，删会话/删 agent 一并清掉。
  final Map<String, List<CoreSubagent>> _subagents =
      <String, List<CoreSubagent>>{};

  // ── agent ────────────────────────────────────────────────────────────

  @override
  List<CoreAgent> agents() => _agents.values.toList()
    ..sort((CoreAgent a, CoreAgent b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  CoreAgent? agent(String id) => _agents[id];

  @override
  List<CoreAgent> teams() =>
      agents().where((CoreAgent a) => a.teamId.isEmpty).toList(growable: false);

  @override
  List<CoreAgent> members(String teamId) =>
      agents()
          .where((CoreAgent a) => a.teamId == teamId)
          .toList(growable: false)
        ..sort(
          (CoreAgent a, CoreAgent b) => a.createdAt == b.createdAt
              ? a.id.compareTo(b.id)
              : a.createdAt.compareTo(b.createdAt),
        );

  @override
  CoreAgent createAgent({
    required String name,
    String systemPrompt = '',
    String modelId = '',
    int teamMemberCount = 0,
    int maxLevel = TeamLimits.defaultMaxLevel,
    int maxMembersPerLevel = TeamLimits.defaultMaxMembersPerLevel,
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

  @override
  void putAgent(CoreAgent agent) {
    _agents[agent.id] = agent;
    ensureDefaultSession(agent.id);
  }

  @override
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

  @override
  bool deleteAgent(String id) {
    if (_agents.remove(id) == null) return false;
    _sessions.removeWhere((_, CoreSession s) => s.agentId == id);
    _messages.removeWhere((String key, _) => key.startsWith('$id::'));
    _subagents.removeWhere((String key, _) => key.startsWith('$id::'));
    return true;
  }

  @override
  CoreMessage? lastTextMessage(String agentId) {
    CoreMessage? latest;
    for (final MapEntry<String, List<CoreMessage>> entry in _messages.entries) {
      if (!entry.key.startsWith('$agentId::')) continue;
      for (final CoreMessage m in entry.value) {
        if (m.isTool || m.role != 'agent' || m.isSubagentMessage) continue;
        if (latest == null || m.timestamp > latest.timestamp) latest = m;
      }
    }
    return latest;
  }

  // ── 临时员工（subagent，会话级） ─────────────────────────────────────

  static String _subagentsKey(String agentId, String sessionId) =>
      '$agentId::$sessionId';

  @override
  List<CoreSubagent> subagents(String agentId, String sessionId) =>
      List<CoreSubagent>.unmodifiable(
        _subagents[_subagentsKey(agentId, sessionId)] ?? const <CoreSubagent>[],
      );

  @override
  void putSubagent(CoreSubagent subagent) {
    final String key = _subagentsKey(subagent.ownerAgentId, subagent.sessionId);
    final List<CoreSubagent> list = _subagents.putIfAbsent(
      key,
      () => <CoreSubagent>[],
    );
    final int index = list.indexWhere((CoreSubagent s) => s.id == subagent.id);
    if (index >= 0) {
      list[index] = subagent;
    } else {
      list.add(subagent);
    }
  }

  @override
  int deleteSubagent(String agentId, String sessionId, String id) {
    final List<CoreSubagent>? list = _subagents[_subagentsKey(agentId, sessionId)];
    if (list == null) return 0;
    // 按树收：目标是"这条记录 + 它的全部下级"（下级由 parent_id 链确定）
    final Set<String> doomed = subagentTreeIds(list, id);
    final int before = list.length;
    list.removeWhere((CoreSubagent s) => doomed.contains(s.id));
    final int removed = before - list.length;
    if (list.isEmpty) _subagents.remove(_subagentsKey(agentId, sessionId));
    return removed;
  }

  @override
  int clearSubagents(String agentId, String sessionId) {
    final List<CoreSubagent>? removed = _subagents.remove(
      _subagentsKey(agentId, sessionId),
    );
    return removed?.length ?? 0;
  }

  // ── 会话 ─────────────────────────────────────────────────────────────

  @override
  List<CoreSession> sessions(String agentId) =>
      _sessions.values.where((CoreSession s) => s.agentId == agentId).toList()
        ..sort(
          (CoreSession a, CoreSession b) => b.updatedAt.compareTo(a.updatedAt),
        );

  @override
  CoreSession? session(String agentId, String sessionId) {
    final CoreSession? session = _sessions[sessionId];
    return (session != null && session.agentId == agentId) ? session : null;
  }

  @override
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

  @override
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

  @override
  bool renameSession(String agentId, String sessionId, String title) {
    final CoreSession? session = this.session(agentId, sessionId);
    if (session == null) return false;
    session.title = title.isEmpty ? session.title : title;
    session.updatedAt = DateTime.now().millisecondsSinceEpoch;
    return true;
  }

  @override
  bool deleteSession(String agentId, String sessionId) {
    final CoreSession? session = this.session(agentId, sessionId);
    if (session == null) return false;
    _sessions.remove(sessionId);
    _messages.remove(_messagesKey(agentId, sessionId));
    // 临时员工只在会话里存在：删会话即连同整棵名册一起消失（不残留任何全局位置）
    _subagents.remove(_subagentsKey(agentId, sessionId));
    return true;
  }

  @override
  int setSelectedSpecs(String agentId, String sessionId, List<String> specIds) {
    final CoreSession? session = this.session(agentId, sessionId);
    if (session == null) return 0;
    session.selectedSpecIds = List<String>.of(specIds);
    return session.selectedSpecIds.length;
  }

  @override
  int setPinnedSystemPrompt(String agentId, String sessionId, String text) {
    final CoreSession? session = this.session(agentId, sessionId);
    if (session == null) return 0;
    session.systemPromptPinned = text;
    session.systemPromptPinnedAt =
        text.isEmpty ? 0 : DateTime.now().millisecondsSinceEpoch;
    return 1;
  }

  @override
  bool setCompacted(
    String agentId,
    String sessionId, {
    required String summary,
    required int messageCount,
  }) {
    final CoreSession? session = this.session(agentId, sessionId);
    if (session == null) return false;
    session.compactedSummary = summary;
    // 内置摘要路径接管：中转站产出的列表作废（两者互斥，见 CoreSession）
    session.compactedContext = <Map<String, dynamic>>[];
    session.compactedMessageCount = messageCount < 0 ? 0 : messageCount;
    session.updatedAt = DateTime.now().millisecondsSinceEpoch;
    return true;
  }

  @override
  bool setCompactedContext(
    String agentId,
    String sessionId, {
    required List<Map<String, dynamic>> context,
    required int coveredMessageCount,
  }) {
    final CoreSession? session = this.session(agentId, sessionId);
    if (session == null) return false;
    session.compactedContext = context;
    // 中转站路径接管：内置摘要作废（下一次内置压缩会重新总结当前前缀）
    session.compactedSummary = '';
    session.compactedMessageCount = coveredMessageCount < 0
        ? 0
        : coveredMessageCount;
    session.updatedAt = DateTime.now().millisecondsSinceEpoch;
    return true;
  }

  // ── 消息 ─────────────────────────────────────────────────────────────

  static String _messagesKey(String agentId, String sessionId) =>
      '$agentId::$sessionId';

  @override
  List<CoreMessage> messages(String agentId, String sessionId) =>
      List<CoreMessage>.unmodifiable(
        // 自己的对话：排掉临时员工的消息——**除了**给它的完成报告
        // （那是"新的输入"，发起者得知道活干完了）
        sessionMessages(agentId, sessionId).where(
          (CoreMessage m) => !m.isSubagentMessage || m.isSubagentReport,
        ),
      );

  @override
  List<CoreMessage> sessionMessages(String agentId, String sessionId) =>
      List<CoreMessage>.unmodifiable(
        _messages[_messagesKey(agentId, sessionId)] ?? const <CoreMessage>[],
      );

  @override
  int messageCount(String agentId, String sessionId) =>
      messages(agentId, sessionId).where((CoreMessage m) => !m.isTool).length;

  @override
  CoreMessage appendMessage(CoreMessage message) {
    final List<CoreMessage> list = _messages.putIfAbsent(
      _messagesKey(message.agentId, message.sessionId),
      () => <CoreMessage>[],
    );
    // 单调序号（Q3）：同毫秒的多条消息在"按时间戳排序"的历史接口里会重排
    // （`List.sort` 不保证稳定），把落库顺序直接压进时间戳就不会漂移。
    message.timestamp = monotonicStamp(
      message.timestamp,
      list.isEmpty ? 0 : list.last.timestamp,
    );
    list.add(message);
    // updated_at 只前进不后退：消息时间戳理论上递增，但导入/补投的历史消息可能
    // 更旧，此时不应把"最近活跃时间"改回去
    final CoreSession? session = _sessions[message.sessionId];
    if (session != null && message.timestamp > session.updatedAt) {
      session.updatedAt = message.timestamp;
    }
    final CoreAgent? agent = _agents[message.agentId];
    if (agent != null && message.timestamp > agent.updatedAt) {
      agent.updatedAt = message.timestamp;
    }
    return message;
  }

  @override
  bool repairToolResult(
    String agentId,
    String sessionId,
    String toolCallId, {
    required String toolResult,
    required String toolResultForModel,
  }) {
    final List<CoreMessage>? list = _messages[_messagesKey(agentId, sessionId)];
    if (list == null) return false;
    final int index = list.indexWhere(
      (CoreMessage m) => m.isTool && m.toolCallId == toolCallId,
    );
    if (index < 0) return false;
    final CoreMessage existing = list[index];
    // 幂等：已经有结果就不再改（自动修复每次组装请求都会问一次）
    if (existing.toolResult.trim().isNotEmpty) return false;
    list[index] = CoreMessage.fromJson(<String, dynamic>{
      ...existing.toJson(),
      'tool_result': toolResult,
      'tool_result_for_model': toolResultForModel,
    });
    return true;
  }

  @override
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

  @override
  int get totalMessageCount => _messages.values.fold<int>(
    0,
    (int sum, List<CoreMessage> list) => sum + list.length,
  );

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {}
}
