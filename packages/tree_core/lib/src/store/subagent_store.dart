import 'subagent_registry.dart';
import 'tree_store.dart';

/// **内存覆盖层**：把临时员工（`sub_…`）挡在真 store 之外，其余一律转发。
///
/// 为什么用装饰器而不是改每个调用点：`store.agent(id)` 的查询路径散落在工具层
/// （`WorkspaceToolRunner._ioFor` 的工作空间/SSH 解析）、文件服务（`FileService.rootFor`）、
/// 团队工作目录（`teamWorkspaceFor`）、系统提示词、结果门控、会话服务……临时员工必须
/// 在**这些既有路径上**被认出来（与团队成员同一口径），而不是每个调用点各加一个分支。
/// 包一层之后，"临时员工是谁"只有一处答案。
///
/// 三条刻意的不转发（都是本能力的不变量，见 store/README.md）：
/// 1. [agents] / [teams] / [members] **不**列临时员工——否则左栏/团队视图会冒出临时实体，
///    而"它不是 agent"正是它与 `agents/<id>.yaml` 的本质区别；
/// 2. [messages]（"该 agent 自己的对话"）滤掉带 [CoreMessage.subagentId] 标记的消息——
///    临时员工的话不能进父 agent 的模型上下文（工具批会被切开 ⇒ 端点 400）；
///    用户要看的完整历史走 [sessionMessages]；
/// 3. 临时员工的**记录**（名册）只按 `(agentId, sessionId)` 存/取：跨会话一律查不到。
class SubagentStore implements TreeStore {
  SubagentStore({required this.inner, required this.registry});

  /// 真 store（`FileTreeStore` / `MemoryStore`）：落盘与其余全部语义都由它负责。
  final TreeStore inner;

  /// 会话级名册（内存索引 + 落盘）。
  final SubagentRegistry registry;

  /// 已经"全库找过一遍"的临时员工 id（找不到的只找一次，避免热路径反复扫盘）。
  final Set<String> _resolvedOnce = <String>{};

  /// **兜底解析**：`sub_…` 没在内存索引里时，按需把各会话的名册装载一遍。
  ///
  /// 正常路径不需要它——[SubagentService] 会在跑一轮之前先"打开会话"（装载名册），
  /// 因此 `agent(sub_…)` 那时已经命中。它兜的是"重启之后、打开会话之前"某个既有
  /// 路径先问了一句这个 id（例如工具层解析工作空间）：那时**不能静默答"不知道"**
  /// （会把它当成一个不存在的工作空间），也不能答错（串到别的会话）。
  void _resolveRoster(String id) {
    if (!_resolvedOnce.add(id)) return;
    for (final CoreAgent agent in inner.agents()) {
      for (final CoreSession session in inner.sessions(agent.id)) {
        registry.ensureSession(agent.id, session.sessionId);
        if (registry.handle(id) != null) return;
      }
    }
  }

  /// 取临时员工记录（带 [SubagentStore._resolveRoster] 兜底）。
  CoreSubagent? _record(String id) {
    final CoreSubagent? direct = registry.handle(id);
    if (direct != null) return direct;
    _resolveRoster(id);
    return registry.handle(id);
  }

  // ── agent：`sub_…` 走内存名册，其余转发 ─────────────────────────────

  @override
  List<CoreAgent> agents() => inner.agents();

  @override
  CoreAgent? agent(String id) {
    if (!registry.isSubagent(id)) return inner.agent(id);
    final CoreAgent? direct = registry.agent(id);
    if (direct != null) return direct;
    _resolveRoster(id);
    return registry.agent(id);
  }

  @override
  List<CoreAgent> teams() => inner.teams();

  @override
  List<CoreAgent> members(String teamId) => inner.members(teamId);

  @override
  CoreAgent createAgent({
    required String name,
    String systemPrompt = '',
    String modelId = '',
    int teamMemberCount = 0,
    int maxLevel = TeamLimits.defaultMaxLevel,
    int maxMembersPerLevel = TeamLimits.defaultMaxMembersPerLevel,
  }) => inner.createAgent(
    name: name,
    systemPrompt: systemPrompt,
    modelId: modelId,
    teamMemberCount: teamMemberCount,
    maxLevel: maxLevel,
    maxMembersPerLevel: maxMembersPerLevel,
  );

  @override
  void putAgent(CoreAgent agent) {
    // 临时员工的配置只能经名册改（它没有 `agents/<id>.yaml`）：命中记录就替换配置
    if (registry.isSubagent(agent.id)) {
      registry.putAgent(agent);
      return;
    }
    inner.putAgent(agent);
  }

  @override
  CoreAgent? updateAgent(
    String id, {
    String? name,
    String? systemPrompt,
    String? modelId,
  }) {
    if (registry.isSubagent(id)) {
      // 临时员工不做"改名/改模型"这类管理动作（用户侧没有它的入口；模型侧不能改配置）
      return registry.agent(id);
    }
    return inner.updateAgent(
      id,
      name: name,
      systemPrompt: systemPrompt,
      modelId: modelId,
    );
  }

  @override
  bool deleteAgent(String id) {
    // 删除临时员工 = 删它这一棵子树（只在本会话内）
    final CoreSubagent? record = registry.isSubagent(id) ? _record(id) : null;
    if (record != null) {
      return registry.removeTree(record.ownerAgentId, record.sessionId, id) > 0;
    }
    registry.forgetAgent(id);
    return inner.deleteAgent(id);
  }

  @override
  CoreMessage? lastTextMessage(String agentId) =>
      registry.isSubagent(agentId) ? null : inner.lastTextMessage(agentId);

  // ── 临时员工（subagent，会话级） ─────────────────────────────────────

  @override
  List<CoreSubagent> subagents(String agentId, String sessionId) =>
      registry.records(agentId, sessionId);

  /// **显式接口**：某会话里的临时员工名册（[agents] 刻意不列它们，需要的地方用它）。
  ///
  /// 目前只有测试与自检用它；将来前端要"按会话列出临时员工"也走这里。
  List<CoreSubagent> subAgentsInSession(String agentId, String sessionId) =>
      registry.records(agentId, sessionId);

  @override
  void putSubagent(CoreSubagent subagent) => registry.put(subagent);

  @override
  int deleteSubagent(String agentId, String sessionId, String id) =>
      registry.removeTree(agentId, sessionId, id);

  @override
  int clearSubagents(String agentId, String sessionId) =>
      registry.clearSession(agentId, sessionId);

  // ── 会话 ─────────────────────────────────────────────────────────────

  @override
  List<CoreSession> sessions(String agentId) => inner.sessions(agentId);

  @override
  CoreSession? session(String agentId, String sessionId) =>
      inner.session(agentId, sessionId);

  @override
  CoreSession ensureDefaultSession(String agentId) =>
      inner.ensureDefaultSession(agentId);

  @override
  CoreSession? createSession(
    String agentId, {
    String title = '',
    String? sessionId,
  }) => inner.createSession(agentId, title: title, sessionId: sessionId);

  @override
  bool renameSession(String agentId, String sessionId, String title) =>
      inner.renameSession(agentId, sessionId, title);

  @override
  bool deleteSession(String agentId, String sessionId) {
    // 临时员工随会话存在：删会话即把它这一整棵树从内存索引里摘掉
    // （落盘的 `subagents.json` 随会话目录一起被删，见 FileTreeStore.deleteSession）
    registry.forgetSession(agentId, sessionId);
    return inner.deleteSession(agentId, sessionId);
  }

  @override
  int setSelectedSpecs(String agentId, String sessionId, List<String> specIds) =>
      inner.setSelectedSpecs(agentId, sessionId, specIds);

  @override
  int setPinnedSystemPrompt(String agentId, String sessionId, String text) =>
      inner.setPinnedSystemPrompt(agentId, sessionId, text);

  @override
  bool setCompacted(
    String agentId,
    String sessionId, {
    required String summary,
    required int messageCount,
  }) => inner.setCompacted(
    agentId,
    sessionId,
    summary: summary,
    messageCount: messageCount,
  );

  @override
  bool setCompactedContext(
    String agentId,
    String sessionId, {
    required List<Map<String, dynamic>> context,
    required int coveredMessageCount,
  }) => inner.setCompactedContext(
    agentId,
    sessionId,
    context: context,
    coveredMessageCount: coveredMessageCount,
  );

  // ── 消息 ─────────────────────────────────────────────────────────────

  @override
  List<CoreMessage> messages(String agentId, String sessionId) {
    final CoreSubagent? record = registry.isSubagent(agentId)
        ? _record(agentId)
        : null;
    if (record == null) return inner.messages(agentId, sessionId);
    // 临时员工的历史 = 会话消息流里**它自己**那一段（复用时"历史延续"读的就是它）
    return List<CoreMessage>.unmodifiable(
      inner
          .sessionMessages(record.ownerAgentId, sessionId)
          .where(
            (CoreMessage m) =>
                m.subagentId == agentId && !m.isSubagentReport,
          ),
    );
  }

  @override
  List<CoreMessage> sessionMessages(String agentId, String sessionId) {
    final CoreSubagent? record = registry.isSubagent(agentId)
        ? _record(agentId)
        : null;
    return inner.sessionMessages(
      record?.ownerAgentId ?? agentId,
      sessionId,
    );
  }

  @override
  int messageCount(String agentId, String sessionId) => messages(
    agentId,
    sessionId,
  ).where((CoreMessage m) => !m.isTool).length;

  @override
  CoreMessage appendMessage(CoreMessage message) => inner.appendMessage(message);

  /// 自动修复一律转发给真 store：临时员工的工具卡与主 agent 的卡都在同一份
  /// `messages.jsonl` 里（`tool_call_id` 全局唯一），没有"按 agent 分栏"的问题。
  @override
  bool repairToolResult(
    String agentId,
    String sessionId,
    String toolCallId, {
    required String toolResult,
    required String toolResultForModel,
  }) => inner.repairToolResult(
    agentId,
    sessionId,
    toolCallId,
    toolResult: toolResult,
    toolResultForModel: toolResultForModel,
  );

  @override
  int clearMessages(String agentId, {String? sessionId}) =>
      inner.clearMessages(agentId, sessionId: sessionId);

  @override
  int get totalMessageCount => inner.totalMessageCount;

  // ── 生命周期 ─────────────────────────────────────────────────────────

  @override
  Future<void> flush() => inner.flush();

  @override
  Future<void> close() => inner.close();
}
