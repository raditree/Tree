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
  });
}
