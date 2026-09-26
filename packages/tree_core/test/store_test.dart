import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  group('MemoryStore agent', () {
    test('创建 agent 时自动建立兜底默认会话', () {
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = store.createAgent(name: '测试', modelId: 'm1');
      expect(
        store.sessions(agent.id).map((CoreSession s) => s.sessionId),
        contains(MemoryStore.defaultSessionId),
      );
    });

    test('lastTextMessage 只取 agent 文本消息，忽略用户与工具消息', () {
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = store.createAgent(name: 'a');
      store.appendMessage(
        CoreMessage(
          id: 'm1',
          agentId: agent.id,
          sessionId: MemoryStore.defaultSessionId,
          role: 'user',
          content: '你好',
          timestamp: 1000,
        ),
      );
      store.appendMessage(
        CoreMessage(
          id: 'm2',
          agentId: agent.id,
          sessionId: MemoryStore.defaultSessionId,
          role: 'agent',
          content: '工具卡片',
          timestamp: 2000,
          kind: 'tool',
          toolName: 'read_file',
        ),
      );
      store.appendMessage(
        CoreMessage(
          id: 'm3',
          agentId: agent.id,
          sessionId: MemoryStore.defaultSessionId,
          role: 'agent',
          content: '回复',
          timestamp: 3000,
        ),
      );
      expect(store.lastTextMessage(agent.id)?.content, '回复');
    });

    test('messageCount 只统计文本消息', () {
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = store.createAgent(name: 'a');
      for (int i = 0; i < 3; i++) {
        store.appendMessage(
          CoreMessage(
            id: 'tool$i',
            agentId: agent.id,
            sessionId: MemoryStore.defaultSessionId,
            role: 'agent',
            content: '',
            timestamp: i,
            kind: 'tool',
          ),
        );
      }
      expect(store.messageCount(agent.id, MemoryStore.defaultSessionId), 0);
      store.appendMessage(
        CoreMessage(
          id: 'txt',
          agentId: agent.id,
          sessionId: MemoryStore.defaultSessionId,
          role: 'agent',
          content: 'hi',
          timestamp: 9,
        ),
      );
      expect(store.messageCount(agent.id, MemoryStore.defaultSessionId), 1);
    });

    test('删除 agent 会一并清理其会话与消息', () {
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = store.createAgent(name: 'a');
      store.appendMessage(
        CoreMessage(
          id: 'm1',
          agentId: agent.id,
          sessionId: MemoryStore.defaultSessionId,
          role: 'user',
          content: 'x',
          timestamp: 1,
        ),
      );
      expect(store.deleteAgent(agent.id), isTrue);
      expect(store.agent(agent.id), isNull);
      expect(store.sessions(agent.id), isEmpty);
      expect(store.totalMessageCount, 0);
      expect(store.deleteAgent(agent.id), isFalse);
    });

    test('clearMessages 支持按会话与 all', () {
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = store.createAgent(name: 'a');
      final CoreSession other = store.createSession(agent.id, title: 'other')!;
      for (final String sid in <String>[
        MemoryStore.defaultSessionId,
        other.sessionId,
      ]) {
        store.appendMessage(
          CoreMessage(
            id: 'm_$sid',
            agentId: agent.id,
            sessionId: sid,
            role: 'user',
            content: 'x',
            timestamp: 1,
          ),
        );
      }
      expect(store.clearMessages(agent.id, sessionId: other.sessionId), 1);
      expect(store.messages(agent.id, MemoryStore.defaultSessionId).length, 1);
      expect(store.clearMessages(agent.id, sessionId: 'all'), 1);
      expect(store.totalMessageCount, 0);
    });

    test('createSession 不会覆盖已有同 id 会话', () {
      final MemoryStore store = MemoryStore();
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
      expect(store.sessions(agent.id).length, 2);
    });
  });

  group('记录序列化', () {
    test('CoreAgent 持久化形态可往返（含时间字段）', () {
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = store.createAgent(
        name: '往返',
        modelId: 'm',
        systemPrompt: '提示词',
        maxLevel: 3,
        maxMembersPerLevel: 4,
        teamMemberCount: 5,
      );
      final CoreAgent restored = CoreAgent.fromJson(agent.toJson());
      expect(restored.id, agent.id);
      expect(restored.name, agent.name);
      expect(restored.modelId, agent.modelId);
      expect(restored.systemPrompt, agent.systemPrompt);
      expect(restored.createdAt, agent.createdAt);
      expect(restored.updatedAt, agent.updatedAt);
      expect(restored.maxLevel, 3);
      expect(restored.maxMembersPerLevel, 4);
      expect(restored.teamMemberCount, 5);
    });

    test('CoreSession API 形态时间是毫秒整数（前端 ChatSession 要求）', () {
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = store.createAgent(name: 'a');
      final CoreSession session = store.session(
        agent.id,
        MemoryStore.defaultSessionId,
      )!;
      final Map<String, dynamic> api = session.toApiJson(messageCount: 2);
      expect(api['created_at'], isA<int>());
      expect(api['updated_at'], isA<int>());
      expect(api['message_count'], 2);
      expect(
        CoreSession.fromJson(session.toJson()).sessionId,
        session.sessionId,
      );
    });

    test('CoreMessage 形态即前端 ChatMessage 输入（时间 ISO，含工具字段）', () {
      final CoreMessage message = CoreMessage(
        id: 'msg_1',
        agentId: 'agt_1',
        sessionId: 'ses_1',
        role: 'agent',
        content: '正文',
        timestamp: 1735689600000,
        kind: 'tool',
        toolName: 'read_file',
        toolArguments: <String, dynamic>{'path': 'a.txt'},
        toolResult: 'ok',
        usage: <String, dynamic>{'total_tokens': 7},
        answered: true,
      );
      final Map<String, dynamic> json = message.toJson();
      expect(json['timestamp'], isA<String>());
      expect(json['is_streaming'], isFalse);
      expect(json['tool_arguments'], <String, dynamic>{'path': 'a.txt'});
      final CoreMessage restored = CoreMessage.fromJson(json);
      expect(restored.toolName, 'read_file');
      expect(restored.toolResult, 'ok');
      expect(restored.usage, <String, dynamic>{'total_tokens': 7});
      expect(restored.timestamp, message.timestamp);
      expect(restored.answered, isTrue);
    });
  });

  group('CoreSettings', () {
    test('新增模型校验必填项，重复 model_id 被拒绝', () {
      final CoreSettings settings = CoreSettings();
      expect(CoreSettings.validateNewModel(<String, dynamic>{}), isNotNull);
      expect(
        CoreSettings.validateNewModel(<String, dynamic>{
          'model_id': 'm1',
          'base_url': 'https://api.example.com/v1',
        }),
        isNotNull,
      );
      final CoreModelConfig? created = settings.createModel(<String, dynamic>{
        'model_id': 'm1',
        'name': '示例',
        'base_url': 'https://api.example.com/v1',
        'api_key': 'sk-secret',
        'max_seqlen': 64000,
      });
      expect(created, isNotNull);
      expect(
        settings.createModel(<String, dynamic>{
          'model_id': 'm1',
          'base_url': 'https://x',
          'api_key': 'k',
        }),
        isNull,
      );
    });

    test('API 形态剥离密钥并把 base_url 脱敏为协议+主机', () {
      final CoreSettings settings = CoreSettings();
      settings.createModel(<String, dynamic>{
        'model_id': 'm1',
        'base_url': 'https://api.example.com:8443/v1/chat',
        'api_key': 'sk-secret',
      });
      final Map<String, dynamic> api = settings.model('m1')!.toApiJson();
      expect(api.containsKey('api_key'), isFalse);
      expect(api['base_url'], 'https://api.example.com:8443');
      expect(settings.model('m1')!.toJson()['api_key'], 'sk-secret');
      expect(
        CoreModelConfig.maskBaseUrl('https://api.example.com/v1'),
        'https://api.example.com',
      );
      expect(CoreModelConfig.maskBaseUrl(''), '');
      expect(CoreModelConfig.maskBaseUrl('not a url'), '');
    });

    test('更新时空 base_url/api_key 保留原值；档位收窄时默认档位跟随', () {
      final CoreSettings settings = CoreSettings();
      settings.createModel(<String, dynamic>{
        'model_id': 'm1',
        'base_url': 'https://api.example.com/v1',
        'api_key': 'sk-old',
        'reasoning_effort': 'max',
      });
      settings.updateModel('m1', <String, dynamic>{
        'base_url': '',
        'api_key': '',
        'name': '新名字',
      });
      final CoreModelConfig model = settings.model('m1')!;
      expect(model.apiKey, 'sk-old');
      expect(model.baseUrl, 'https://api.example.com/v1');
      expect(model.name, '新名字');
      settings.updateModel('m1', <String, dynamic>{
        'reasoning_effort_options': <String>['low', 'high'],
      });
      expect(model.reasoningEffort, 'low');
      expect(settings.updateModel('missing', <String, dynamic>{}), isNull);
    });

    test('帧率夹取到 20~1000；有效上下文长度有兜底', () {
      final CoreSettings settings = CoreSettings();
      expect(settings.setFrameRate(5), CoreSettings.frameRateMin);
      expect(settings.setFrameRate(99999), CoreSettings.frameRateMax);
      expect(settings.setFrameRate(60), 60);
      expect(CoreModelConfig(modelId: 'm').effectiveMaxSeqlen, 128000);
    });
  });
}
