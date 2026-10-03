import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 存储层的**共享契约测试**。
///
/// 内存实现与落盘实现跑同一份用例，确保"换持久化"不改变任何可观察行为；
/// 各实现再由自己的测试文件补充实现特有的部分（落盘/重开/手改/损坏容错）。
///
/// 约定：契约只依赖 [TreeStore] 的方法语义，不依赖任何实现细节。所有断言都
/// 走内存缓存即可满足（写操作同步更新缓存），因此契约本身与 write-behind
/// 的落盘时机无关。
void runStoreContract(String label, TreeStore Function() create) {
  group('$label 存储契约', () {
    late TreeStore store;

    setUp(() => store = create());
    tearDown(() => store.close());

    CoreMessage text(
      String agentId,
      String sessionId, {
      String role = 'agent',
      String content = 'c',
      int timestamp = 1,
      String id = 'm',
      String kind = 'text',
    }) => CoreMessage(
      id: id,
      agentId: agentId,
      sessionId: sessionId,
      role: role,
      content: content,
      timestamp: timestamp,
      kind: kind,
    );

    test('repairToolResult：把"结果拿不到"的工具卡写回失败信息（幂等、不新增消息）', () {
      final CoreAgent agent = store.createAgent(name: 'a');
      const String session = TreeStore.defaultSessionId;
      store.appendMessage(
        CoreMessage(
          id: 'tool_1',
          agentId: agent.id,
          sessionId: session,
          role: 'agent',
          content: '',
          timestamp: 10,
          kind: 'tool',
          toolName: 'grep',
          toolCallId: 'call_1',
          toolArguments: <String, dynamic>{'pattern': 'x'},
        ),
      );
      final int before = store.sessionMessages(agent.id, session).length;
      expect(
        store.repairToolResult(
          agent.id,
          session,
          'call_1',
          toolResult: '【自动修复】结果没被收集',
          toolResultForModel: '【自动修复】结果没被收集',
        ),
        isTrue,
      );
      final CoreMessage card = store.sessionMessages(agent.id, session).last;
      expect(card.toolResult, contains('自动修复'));
      expect(card.toolResultForModel, contains('自动修复'));
      expect(
        store.sessionMessages(agent.id, session).length,
        before,
        reason: '修复写回**同一张**卡，不许新增消息（tool_call_id 不能重复）',
      );
      // 幂等：已经有结果就不再改（引擎每次组装请求都会问一次）
      expect(
        store.repairToolResult(
          agent.id,
          session,
          'call_1',
          toolResult: 'again',
          toolResultForModel: 'again',
        ),
        isFalse,
      );
      expect(
        store.sessionMessages(agent.id, session).last.toolResult,
        isNot('again'),
      );
      // 找不到这张卡 / 别的会话：如实回 false，不假装修过
      expect(
        store.repairToolResult(
          agent.id,
          session,
          'call_missing',
          toolResult: 'x',
          toolResultForModel: 'x',
        ),
        isFalse,
      );
    });

    test('createAgent：可取回、自动带兜底默认会话、name 为空有兜底', () {
      final CoreAgent agent = store.createAgent(name: '', modelId: 'm1');
      expect(agent.id, isNotEmpty);
      expect(agent.name, '新 Agent');
      expect(agent.modelId, 'm1');
      expect(agent.workspaceId, isNotEmpty);
      expect(store.agent(agent.id)?.id, agent.id);
      expect(store.agent('agt_missing'), isNull);
      expect(
        store.sessions(agent.id).map((CoreSession s) => s.sessionId),
        contains(TreeStore.defaultSessionId),
      );
      expect(
        store.session(agent.id, TreeStore.defaultSessionId)?.isDefault,
        isTrue,
      );
    });

    test('agents()：返回全部 agent，最近更新的排在最前', () async {
      final CoreAgent a = store.createAgent(name: 'a');
      final CoreAgent b = store.createAgent(name: 'b');
      expect(store.agents().map((CoreAgent x) => x.id).toSet(), <String>{
        a.id,
        b.id,
      });
      // 确保时间戳严格递增，避免同毫秒下的排序歧义
      await Future<void>.delayed(const Duration(milliseconds: 3));
      store.updateAgent(a.id, name: 'a2');
      expect(store.agents().first.id, a.id);
    });

    test('updateAgent：只覆盖传入字段；不存在返回 null', () {
      final CoreAgent agent = store.createAgent(
        name: 'n',
        systemPrompt: 'p',
        modelId: 'm',
      );
      final CoreAgent? updated = store.updateAgent(agent.id, name: 'n2');
      expect(updated?.name, 'n2');
      expect(updated?.systemPrompt, 'p');
      expect(updated?.modelId, 'm');
      final CoreAgent? modelChanged = store.updateAgent(
        agent.id,
        modelId: 'm2',
      );
      expect(modelChanged?.modelId, 'm2');
      expect(modelChanged?.name, 'n2');
      expect(store.updateAgent('agt_missing', name: 'x'), isNull);
    });

    test('putAgent：覆盖写入并保证默认会话存在', () {
      final CoreAgent agent = store.createAgent(name: 'old');
      final CoreAgent replaced = CoreAgent(
        id: agent.id,
        name: 'replaced',
        systemPrompt: 'sp',
        modelId: 'm9',
        createdAt: agent.createdAt,
        updatedAt: agent.updatedAt,
      );
      store.putAgent(replaced);
      expect(store.agent(agent.id)?.name, 'replaced');
      expect(store.agent(agent.id)?.systemPrompt, 'sp');
      expect(store.session(agent.id, TreeStore.defaultSessionId), isNotNull);
    });

    test('deleteAgent：连带清理会话与消息；重复删除返回 false', () {
      final CoreAgent agent = store.createAgent(name: 'a');
      store.appendMessage(text(agent.id, TreeStore.defaultSessionId));
      expect(store.deleteAgent(agent.id), isTrue);
      expect(store.agent(agent.id), isNull);
      expect(store.sessions(agent.id), isEmpty);
      expect(store.messages(agent.id, TreeStore.defaultSessionId), isEmpty);
      expect(store.deleteAgent(agent.id), isFalse);
    });

    test('messageCount：只统计文本消息（工具卡片不计入）', () {
      final CoreAgent agent = store.createAgent(name: 'a');
      const String sid = TreeStore.defaultSessionId;
      for (int i = 0; i < 3; i++) {
        store.appendMessage(text(agent.id, sid, id: 'tool$i', kind: 'tool'));
      }
      expect(store.messageCount(agent.id, sid), 0);
      store.appendMessage(text(agent.id, sid, id: 't1'));
      expect(store.messageCount(agent.id, sid), 1);
      store.appendMessage(text(agent.id, sid, id: 't2', role: 'user'));
      expect(store.messageCount(agent.id, sid), 2);
    });

    test('lastTextMessage：只取 agent 的文本消息，忽略用户消息与工具卡片', () {
      final CoreAgent agent = store.createAgent(name: 'a');
      const String sid = TreeStore.defaultSessionId;
      store.appendMessage(
        text(agent.id, sid, id: 'u', role: 'user', timestamp: 1),
      );
      store.appendMessage(
        text(agent.id, sid, id: 'tool', kind: 'tool', timestamp: 2),
      );
      expect(store.lastTextMessage(agent.id), isNull);
      store.appendMessage(text(agent.id, sid, id: 'a1', timestamp: 3));
      store.appendMessage(
        text(agent.id, sid, id: 'a2', content: '最后', timestamp: 4),
      );
      expect(store.lastTextMessage(agent.id)?.content, '最后');
      expect(store.lastTextMessage('agt_missing'), isNull);
    });

    test('createSession：agent 不存在返回 null；同 id 不覆盖既有会话', () {
      expect(store.createSession('agt_missing'), isNull);
      final CoreAgent agent = store.createAgent(name: 'a');
      final CoreSession first = store.createSession(
        agent.id,
        title: '一',
        sessionId: 'ses_x',
      )!;
      final CoreSession second = store.createSession(
        agent.id,
        title: '二',
        sessionId: 'ses_x',
      )!;
      expect(second.title, first.title);
      expect(store.sessions(agent.id).length, 2); // 默认会话 + ses_x
      expect(first.sessionId, 'ses_x');
    });

    test('会话重命名 / 删除 / 选择 spec', () {
      final CoreAgent agent = store.createAgent(name: 'a');
      final CoreSession session = store.createSession(agent.id, title: '原标题')!;
      expect(store.renameSession(agent.id, session.sessionId, '新标题'), isTrue);
      expect(store.session(agent.id, session.sessionId)?.title, '新标题');
      // 空标题不改名
      expect(store.renameSession(agent.id, session.sessionId, ''), isTrue);
      expect(store.session(agent.id, session.sessionId)?.title, '新标题');
      expect(store.renameSession(agent.id, 'ses_missing', 'x'), isFalse);

      expect(
        store.setSelectedSpecs(agent.id, session.sessionId, <String>[
          's1',
          's2',
        ]),
        2,
      );
      expect(
        store.session(agent.id, session.sessionId)?.selectedSpecIds,
        <String>['s1', 's2'],
      );
      expect(store.setSelectedSpecs(agent.id, 'ses_missing', <String>['x']), 0);

      store.appendMessage(text(agent.id, session.sessionId));
      expect(store.deleteSession(agent.id, session.sessionId), isTrue);
      expect(store.session(agent.id, session.sessionId), isNull);
      expect(store.messages(agent.id, session.sessionId), isEmpty);
      expect(store.deleteSession(agent.id, session.sessionId), isFalse);
    });

    test('setCompacted：记录摘要与已压缩前缀长度；会话不存在返回 false', () {
      final CoreAgent agent = store.createAgent(name: 'a');
      final CoreSession session = store.createSession(agent.id)!;
      expect(
        store.setCompacted(
          agent.id,
          'ses_missing',
          summary: 's',
          messageCount: 1,
        ),
        isFalse,
      );
      expect(
        store.setCompacted(
          agent.id,
          session.sessionId,
          summary: '早期对话摘要',
          messageCount: 4,
        ),
        isTrue,
      );
      final CoreSession? reloaded = store.session(agent.id, session.sessionId);
      expect(reloaded?.compactedSummary, '早期对话摘要');
      expect(reloaded?.compactedMessageCount, 4);
      expect(reloaded?.compacted, isTrue);
      // 负数按 0 处理（不抛异常，也不留下非法水位）
      expect(
        store.setCompacted(
          agent.id,
          session.sessionId,
          summary: '',
          messageCount: -3,
        ),
        isTrue,
      );
      expect(
        store.session(agent.id, session.sessionId)?.compactedMessageCount,
        0,
      );
      expect(store.session(agent.id, session.sessionId)?.compacted, isFalse);
    });

    test('setCompactedContext：中转站列表可落盘可读回，且与摘要互斥', () {
      final CoreAgent agent = store.createAgent(name: 'a');
      final CoreSession session = store.createSession(agent.id)!;
      expect(
        store.setCompactedContext(
          agent.id,
          'ses_missing',
          context: const <Map<String, dynamic>>[],
          coveredMessageCount: 1,
        ),
        isFalse,
      );
      // 先走内置路径留下摘要，再让中转站接管：摘要必须被清掉
      store.setCompacted(
        agent.id,
        session.sessionId,
        summary: '内置摘要',
        messageCount: 2,
      );
      expect(
        store.setCompactedContext(
          agent.id,
          session.sessionId,
          context: const <Map<String, dynamic>>[
            <String, dynamic>{'role': 'system', 'content': '中转站上下文'},
            <String, dynamic>{'role': 'user', 'content': '最近一条'},
          ],
          coveredMessageCount: 5,
        ),
        isTrue,
      );
      final CoreSession? reloaded = store.session(agent.id, session.sessionId);
      expect(reloaded?.compactedContext, hasLength(2));
      expect(reloaded?.compactedContext.first['content'], '中转站上下文');
      expect(reloaded?.compactedSummary, isEmpty, reason: '列表接管即清摘要');
      expect(reloaded?.compactedMessageCount, 5);
      expect(reloaded?.compacted, isTrue, reason: '列表非空也算已压缩');
      // 反向：内置路径再接管时列表必须被清掉
      store.setCompacted(
        agent.id,
        session.sessionId,
        summary: '又回到内置摘要',
        messageCount: 6,
      );
      final CoreSession? again = store.session(agent.id, session.sessionId);
      expect(again?.compactedContext, isEmpty, reason: '摘要接管即清列表');
      expect(again?.compactedSummary, '又回到内置摘要');
      expect(again?.compactedMessageCount, 6);
    });

    test('appendMessage：按写入顺序保存并推进会话/agent 的 updated_at', () async {
      final CoreAgent agent = store.createAgent(name: 'a');
      final int agentUpdated = agent.updatedAt;
      await Future<void>.delayed(const Duration(milliseconds: 3));
      store.appendMessage(
        text(agent.id, TreeStore.defaultSessionId, id: 'm1', content: '一'),
      );
      store.appendMessage(
        text(agent.id, TreeStore.defaultSessionId, id: 'm2', content: '二'),
      );
      final List<CoreMessage> messages = store.messages(
        agent.id,
        TreeStore.defaultSessionId,
      );
      expect(messages.map((CoreMessage m) => m.content), <String>['一', '二']);
      expect(store.totalMessageCount, greaterThanOrEqualTo(2));
      final CoreSession session = store.session(
        agent.id,
        TreeStore.defaultSessionId,
      )!;
      expect(session.updatedAt, greaterThan(0));
      expect(
        store.agent(agent.id)!.updatedAt,
        greaterThanOrEqualTo(agentUpdated),
      );
    });

    test('appendMessage：同一会话内时间戳严格递增（重载顺序不漂移）', () {
      final CoreAgent agent = store.createAgent(name: 'a');
      const String sid = TreeStore.defaultSessionId;
      // 一轮回复里的多条消息（思考段 / 中间正文 / 工具卡片 / 最终回复）常常落在
      // 同一毫秒；历史接口按时间戳排序而 `List.sort` 不保证稳定，因此落库必须把
      // 它们抬成严格递增，"追加顺序 = 读回顺序"才成立。
      const int base = 1700000000000;
      for (int i = 0; i < 5; i++) {
        store.appendMessage(text(agent.id, sid, id: 'm$i', timestamp: base));
      }
      expect(
        store
            .messages(agent.id, sid)
            .map((CoreMessage m) => m.timestamp)
            .toList(),
        <int>[base, base + 1, base + 2, base + 3, base + 4],
      );
      // 真实时刻不被推远：比上一条更新的时间戳原样保留
      store.appendMessage(
        text(agent.id, sid, id: 'later', timestamp: base + 100),
      );
      expect(store.messages(agent.id, sid).last.timestamp, base + 100);
    });

    test('messages() 返回不可变视图，改不动底层集合', () {
      final CoreAgent agent = store.createAgent(name: 'a');
      store.appendMessage(text(agent.id, TreeStore.defaultSessionId));
      final List<CoreMessage> view = store.messages(
        agent.id,
        TreeStore.defaultSessionId,
      );
      expect(() => view.add(view.first), throwsUnsupportedError);
      expect(
        store.messages(agent.id, TreeStore.defaultSessionId),
        hasLength(1),
      );
    });

    test('clearMessages：按会话清空只删该会话，all 清空全部', () {
      final CoreAgent agent = store.createAgent(name: 'a');
      final CoreSession other = store.createSession(agent.id, title: 'o')!;
      store.appendMessage(text(agent.id, TreeStore.defaultSessionId, id: 'd1'));
      store.appendMessage(text(agent.id, other.sessionId, id: 'o1'));
      store.appendMessage(text(agent.id, other.sessionId, id: 'o2'));
      expect(store.clearMessages(agent.id, sessionId: other.sessionId), 2);
      expect(store.messages(agent.id, other.sessionId), isEmpty);
      expect(
        store.messages(agent.id, TreeStore.defaultSessionId),
        hasLength(1),
      );
      expect(store.clearMessages(agent.id, sessionId: 'all'), 1);
      expect(store.totalMessageCount, 0);
      // 空会话清空返回 0
      expect(store.clearMessages(agent.id, sessionId: other.sessionId), 0);
    });

    test('会话与消息按 agent 隔离', () {
      final CoreAgent a = store.createAgent(name: 'a');
      final CoreAgent b = store.createAgent(name: 'b');
      store.appendMessage(text(a.id, TreeStore.defaultSessionId, id: 'a1'));
      expect(store.messages(b.id, TreeStore.defaultSessionId), isEmpty);
      expect(store.session(b.id, TreeStore.defaultSessionId), isNotNull);
      expect(store.messageCount(b.id, TreeStore.defaultSessionId), 0);
    });

    // ── 临时员工（subagent，会话级） ───────────────────────────────────

    CoreSubagent sub(
      String ownerAgentId,
      String sessionId,
      String id, {
      String name = '临时员工',
      String parentId = '',
      int level = 1,
    }) {
      final int now = DateTime.now().millisecondsSinceEpoch;
      return CoreSubagent(
        id: id,
        name: name,
        ownerAgentId: ownerAgentId,
        sessionId: sessionId,
        parentId: parentId.isEmpty ? ownerAgentId : parentId,
        level: level,
        agent: CoreAgent(id: id, name: name, createdAt: now, updatedAt: now),
        createdAt: now,
        updatedAt: now,
      );
    }

    test('subagents：只在它被召来的会话里存在（跨会话一律查不到）', () {
      final CoreAgent agent = store.createAgent(name: 'a');
      final CoreSession s1 = store.createSession(agent.id)!;
      final CoreSession s2 = store.createSession(agent.id)!;
      store.putSubagent(sub(agent.id, s1.sessionId, 'sub_x', name: '张三'));

      expect(
        store.subagents(agent.id, s1.sessionId).map((CoreSubagent s) => s.id),
        <String>['sub_x'],
      );
      expect(
        store.subagents(agent.id, s2.sessionId),
        isEmpty,
        reason: '临时员工只在被召来的那个会话里存在',
      );
      // 另一个 agent 的同名会话也看不到
      final CoreAgent other = store.createAgent(name: 'b');
      expect(store.subagents(other.id, s1.sessionId), isEmpty);
      // 记录里的字段原样读回（含运行配置快照）
      final CoreSubagent loaded = store.subagents(agent.id, s1.sessionId).single;
      expect(loaded.name, '张三');
      expect(loaded.ownerAgentId, agent.id);
      expect(loaded.sessionId, s1.sessionId);
      expect(loaded.level, 1);
      expect(loaded.agent.id, 'sub_x');
    });

    test('deleteSubagent / clearSubagents：按树收，且不误伤别的会话', () {
      final CoreAgent agent = store.createAgent(name: 'a');
      final CoreSession s1 = store.createSession(agent.id)!;
      final CoreSession s2 = store.createSession(agent.id)!;
      store.putSubagent(sub(agent.id, s1.sessionId, 'sub_root'));
      store.putSubagent(
        sub(agent.id, s1.sessionId, 'sub_child', parentId: 'sub_root', level: 2),
      );
      store.putSubagent(
        sub(
          agent.id,
          s1.sessionId,
          'sub_grand',
          parentId: 'sub_child',
          level: 3,
        ),
      );
      store.putSubagent(sub(agent.id, s2.sessionId, 'sub_other'));

      // 删一棵树 = 它 + 全部下级（悬空的 parent_id 会像悬空的 parent_agent_id 一样
      // 让"按树收"失效）
      expect(store.deleteSubagent(agent.id, s1.sessionId, 'sub_root'), 3);
      expect(store.subagents(agent.id, s1.sessionId), isEmpty);
      expect(
        store.subagents(agent.id, s2.sessionId).map((CoreSubagent s) => s.id),
        <String>['sub_other'],
        reason: '别的会话的临时员工不能被误伤',
      );
      expect(store.deleteSubagent(agent.id, s1.sessionId, 'sub_root'), 0);
      expect(store.clearSubagents(agent.id, s2.sessionId), 1);
      expect(store.subagents(agent.id, s2.sessionId), isEmpty);
      expect(store.clearSubagents(agent.id, s2.sessionId), 0);
    });

    test('删会话 / 删 agent：临时员工一起消失（不残留）', () {
      final CoreAgent agent = store.createAgent(name: 'a');
      final CoreSession s1 = store.createSession(agent.id)!;
      store.putSubagent(sub(agent.id, s1.sessionId, 'sub_a'));
      expect(store.deleteSession(agent.id, s1.sessionId), isTrue);
      expect(
        store.subagents(agent.id, s1.sessionId),
        isEmpty,
        reason: '临时员工随会话一起消失',
      );

      final CoreSession s2 = store.createSession(agent.id)!;
      store.putSubagent(sub(agent.id, s2.sessionId, 'sub_b'));
      expect(store.deleteAgent(agent.id), isTrue);
      expect(store.subagents(agent.id, s2.sessionId), isEmpty);
    });

    test('messages() 不含临时员工的消息；sessionMessages() 是完整流', () {
      final CoreAgent agent = store.createAgent(name: 'a');
      const String sid = TreeStore.defaultSessionId;
      store.appendMessage(text(agent.id, sid, id: 'own', content: '自己的话'));
      final CoreMessage fromSub = CoreMessage(
        id: 'sub-msg',
        agentId: agent.id,
        sessionId: sid,
        role: 'agent',
        content: '临时员工的话',
        timestamp: 2,
        subagentId: 'sub_x',
        subagentName: '张三',
        subagentParentId: agent.id,
        subagentLevel: 1,
      );
      store.appendMessage(fromSub);

      expect(
        store.messages(agent.id, sid).map((CoreMessage m) => m.id),
        <String>['own'],
        reason: '父 agent 的模型上下文必须排掉临时员工的消息（工具批要保持原子）',
      );
      expect(
        store.sessionMessages(agent.id, sid).map((CoreMessage m) => m.id),
        <String>['own', 'sub-msg'],
        reason: '用户要能看到临时员工干过什么：完整消息流包含它',
      );
      expect(store.messageCount(agent.id, sid), 1);
      expect(
        store.sessionMessages(agent.id, sid).last.subagentName,
        '张三',
        reason: '标记字段要能原样读回（前端据此分组）',
      );
    });
  });
}
