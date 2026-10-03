import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// **临时员工名册**（`SubagentRegistry` + `SubagentStore` 装饰器）。
///
/// 不变量（见 store/README.md 不变量 9）：
/// - 名册是**会话级**的：`(ownerAgentId, sessionId)` 之外一律查不到；
/// - `agents()` / `teams()` / `members()` **不**列它（它不是 agent）；
/// - `store.agent(sub_…)` 能查到它（工作空间/SSH/系统提示词这些既有路径因此认得它）；
/// - `messages(sub_…)` 是它**自己**那一段历史（复用 = 历史延续）；
/// - 删一个临时员工按**树**收（它召出来的一起走）。
void main() {
  late MemoryStore inner;
  late SubagentRegistry registry;
  late SubagentStore store;

  setUp(() {
    inner = MemoryStore();
    registry = SubagentRegistry(persistence: inner);
    store = SubagentStore(inner: inner, registry: registry);
  });

  CoreAgent newSub(
    CoreAgent owner,
    String sessionId, {
    required String name,
    String parentId = '',
    int level = 1,
    String modelId = 'demo',
  }) {
    final String id = registry.nextId();
    final int now = DateTime.now().millisecondsSinceEpoch;
    return CoreAgent(
      id: id,
      name: name,
      modelId: modelId,
      teamId: owner.id,
      parentAgentId: parentId.isEmpty ? owner.id : parentId,
      level: level,
      reviewStatus: ReviewStatus.approved,
      createdAt: now,
      updatedAt: now,
    );
  }

  CoreSubagent register(
    CoreAgent owner,
    String sessionId,
    CoreAgent agent, {
    String scope = '干活',
    String parentId = '',
    int level = 1,
  }) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final CoreSubagent record = CoreSubagent(
      id: agent.id,
      name: agent.name,
      ownerAgentId: owner.id,
      sessionId: sessionId,
      parentId: parentId.isEmpty ? owner.id : parentId,
      level: level,
      scope: scope,
      agent: agent,
      createdAt: now,
      updatedAt: now,
    );
    registry.put(record);
    return record;
  }

  test('id 形如 sub_…：全局唯一（store.agent 没有会话维度，撞号会串工作空间）', () {
    final CoreAgent owner = store.createAgent(name: 'leader');
    final Set<String> ids = <String>{
      for (int i = 0; i < 50; i++) registry.nextId(),
    };
    expect(ids, hasLength(50));
    for (final String id in ids) {
      expect(id, startsWith(SubagentLimits.idPrefix));
      expect(registry.isSubagent(id), isTrue);
    }
    expect(registry.isSubagent(owner.id), isFalse);
  });

  test('名册按会话装载：跨会话不可见，agent() 只在装载过的会话里命中', () {
    final CoreAgent owner = store.createAgent(name: 'leader');
    final CoreSession s1 = store.createSession(owner.id)!;
    final CoreSession s2 = store.createSession(owner.id)!;
    final CoreAgent subAgent = newSub(owner, s1.sessionId, name: '张三');
    register(owner, s1.sessionId, subAgent);

    // 新进程（新 registry + 新装饰器）打开 s1：名册原样回来
    final SubagentRegistry restarted = SubagentRegistry(persistence: inner);
    final SubagentStore reopened = SubagentStore(inner: inner, registry: restarted);
    // 打开之前谁都没装载（名册是"打开会话时装载"的）
    expect(restarted.isSessionLoaded(owner.id, s1.sessionId), isFalse);
    expect(
      restarted.isSessionLoaded(owner.id, s2.sessionId),
      isFalse,
      reason: '没打开过的会话不该被装载',
    );
    expect(reopened.agent(subAgent.id)?.name, '张三');
    expect(
      reopened.subAgentsInSession(owner.id, s1.sessionId).map((CoreSubagent s) => s.id),
      <String>[subAgent.id],
    );
    expect(
      reopened.subAgentsInSession(owner.id, s2.sessionId),
      isEmpty,
      reason: '换会话必须查不到它',
    );
  });

  test('agents()/teams()/members() 不列临时员工，但 agent(id) / subAgentsInSession 能查到', () {
    final CoreAgent owner = store.createAgent(name: 'leader');
    final CoreSession session = store.createSession(owner.id)!;
    final CoreAgent subAgent = newSub(owner, session.sessionId, name: '张三');
    register(owner, session.sessionId, subAgent);

    expect(store.agents().map((CoreAgent a) => a.id), isNot(contains(subAgent.id)));
    expect(store.teams().map((CoreAgent a) => a.id), isNot(contains(subAgent.id)));
    expect(store.members(owner.id), isEmpty, reason: '它不是团队成员');
    expect(store.agent(subAgent.id)?.name, '张三');
    expect(
      store.subAgentsInSession(owner.id, session.sessionId).single.id,
      subAgent.id,
    );
  });

  test('messages(sub_…) = 它自己那一段；sessionMessages = 完整流；父 agent 上下文不含它', () {
    final CoreAgent owner = store.createAgent(name: 'leader');
    final CoreSession session = store.createSession(owner.id)!;
    final CoreAgent a = newSub(owner, session.sessionId, name: '甲');
    final CoreAgent b = newSub(owner, session.sessionId, name: '乙');
    register(owner, session.sessionId, a);
    register(owner, session.sessionId, b);
    CoreMessage tagged(String id, String subId, String subName, String content) =>
        CoreMessage(
          id: id,
          agentId: owner.id,
          sessionId: session.sessionId,
          role: 'agent',
          content: content,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          subagentId: subId,
          subagentName: subName,
          subagentParentId: owner.id,
          subagentLevel: 1,
        );
    store.appendMessage(
      CoreMessage(
        id: 'u1',
        agentId: owner.id,
        sessionId: session.sessionId,
        role: 'user',
        content: '派活',
        timestamp: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    store.appendMessage(tagged('s1', a.id, '甲', '甲的话'));
    store.appendMessage(tagged('s2', b.id, '乙', '乙的话'));

    expect(
      store.messages(a.id, session.sessionId).map((CoreMessage m) => m.content),
      <String>['甲的话'],
      reason: '临时员工的历史只是它自己那一段（复用 = 历史延续）',
    );
    expect(store.messages(owner.id, session.sessionId).map((CoreMessage m) => m.id), <String>['u1']);
    expect(
      store.sessionMessages(owner.id, session.sessionId).map((CoreMessage m) => m.id),
      <String>['u1', 's1', 's2'],
    );
  });

  test('按树收：删上级连下级一起走（注册表与落盘同步）', () {
    final CoreAgent owner = store.createAgent(name: 'leader');
    final CoreSession session = store.createSession(owner.id)!;
    final CoreAgent root = newSub(owner, session.sessionId, name: '甲');
    register(owner, session.sessionId, root, scope: '整件改造');
    final CoreAgent child = newSub(
      owner,
      session.sessionId,
      name: '甲的下级',
      parentId: root.id,
      level: 2,
    );
    register(owner, session.sessionId, child, parentId: root.id, level: 2);
    expect(registry.count, 2);
    expect(registry.privateOwnerOf(child.id), owner.id, reason: '私有分栏归到树根');
    expect(registry.levelOf(child.id), 2);

    expect(store.deleteSubagent(owner.id, session.sessionId, root.id), 2);
    expect(registry.count, 0);
    expect(inner.subagents(owner.id, session.sessionId), isEmpty, reason: '落盘也要按树收');
    expect(
      SubagentRegistry(persistence: inner)
          .records(owner.id, session.sessionId),
      isEmpty,
    );
  });

  test('putAgent(sub_…) 换运行配置；markRun 记账；forgetSession 只摘内存索引', () {
    final CoreAgent owner = store.createAgent(name: 'leader');
    final CoreSession session = store.createSession(owner.id)!;
    final CoreAgent agent = newSub(owner, session.sessionId, name: '甲');
    register(owner, session.sessionId, agent);

    final CoreAgent changed = newSub(owner, session.sessionId, name: '甲')
      ..modelId = 'm9'
      ..reasoningEffort = 'high';
    expect(registry.putAgent(changed), isFalse, reason: 'id 不同：不该命中已有记录');
    final CoreAgent same = CoreAgent.fromJson(agent.toJson());
    same.modelId = 'm9';
    expect(registry.putAgent(same), isTrue);
    expect(registry.agent(agent.id)?.modelId, 'm9');
    expect(inner.subagents(owner.id, session.sessionId).single.agent.modelId, 'm9');

    registry.markRun(agent.id);
    expect(registry.handle(agent.id)?.runCount, 1);

    registry.forgetSession(owner.id, session.sessionId);
    expect(registry.handle(agent.id), isNull, reason: '内存索引已摘掉');
    expect(
      inner.subagents(owner.id, session.sessionId),
      hasLength(1),
      reason: '落盘名册不因"关掉会话"而消失（临时员工随会话持久化）',
    );
  });

  test('删会话：内存索引与落盘名册一起清掉', () {
    final CoreAgent owner = store.createAgent(name: 'leader');
    final CoreSession session = store.createSession(owner.id)!;
    final CoreAgent agent = newSub(owner, session.sessionId, name: '甲');
    register(owner, session.sessionId, agent);
    expect(store.deleteSession(owner.id, session.sessionId), isTrue);
    expect(registry.handle(agent.id), isNull);
    expect(store.subAgentsInSession(owner.id, session.sessionId), isEmpty);
    expect(store.agent(agent.id), isNull);
  });
}
