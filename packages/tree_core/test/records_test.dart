import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  group('记录序列化（持久化形态）', () {
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

    test('CoreAgent 前端形态：字段名与时间口径符合前端模型', () {
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = store.createAgent(name: 'a', modelId: 'm');
      final Map<String, dynamic> api = agent.toApiJson(
        lastMessage: '预览',
        lastMessageTime: 1234,
      );
      expect(api['type'], 'normal');
      expect(api['last_message'], '预览');
      expect(api['last_message_time'], 1234);
      expect(api['pending_member_count'], 0);
      expect(api['created_at'], isA<int>());
    });

    test('CoreSession：持久化形态是 ISO 字符串，前端形态是毫秒整数', () {
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = store.createAgent(name: 'a');
      final CoreSession session = store.session(
        agent.id,
        TreeStore.defaultSessionId,
      )!;
      final Map<String, dynamic> api = session.toApiJson(messageCount: 2);
      expect(api['created_at'], isA<int>());
      expect(api['updated_at'], isA<int>());
      expect(api['message_count'], 2);
      expect(session.toJson()['created_at'], isA<String>());
      expect(
        CoreSession.fromJson(session.toJson()).sessionId,
        session.sessionId,
      );
    });

    test('CoreMessage：形态即前端 ChatMessage 输入（含工具字段）', () {
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
      expect(restored.isTool, isTrue);
    });

    test('CoreMessage：模型视角字段（原始参数串 / 送模型那一份）可往返，为空不写键', () {
      // 这两个字段是"前缀缓存"的锚：落库时存下实发的那一串字节，重建历史时原样取用
      // （见 docs/known-issues.md #6）。为空时不写键 ⇒ 老会话文件形态零变化。
      final CoreMessage message = CoreMessage(
        id: 'msg_2',
        agentId: 'agt_1',
        sessionId: 'ses_1',
        role: 'agent',
        content: '',
        timestamp: 2,
        kind: 'tool',
        toolName: 'read',
        toolArgumentsRaw: '{"path": "a.txt"}',
        toolResult: '完整结果',
        toolResultForModel: '[状态前缀]\n完整结果',
      );
      final Map<String, dynamic> json = message.toJson();
      expect(json['tool_arguments_raw'], '{"path": "a.txt"}');
      expect(json['tool_result_for_model'], '[状态前缀]\n完整结果');
      final CoreMessage restored = CoreMessage.fromJson(json);
      expect(restored.toolArgumentsRaw, '{"path": "a.txt"}');
      expect(restored.toolResultForModel, '[状态前缀]\n完整结果');
      expect(restored.toolResult, '完整结果');

      final Map<String, dynamic> lean = CoreMessage(
        id: 'msg_3',
        agentId: 'agt_1',
        sessionId: 'ses_1',
        role: 'agent',
        content: 'x',
        timestamp: 3,
      ).toJson();
      expect(lean.containsKey('tool_arguments_raw'), isFalse);
      expect(lean.containsKey('tool_result_for_model'), isFalse);
    });

    test('记录可安全通过 YAML 往返（配置文件的形态）', () {
      final MemoryStore store = MemoryStore();
      final CoreAgent agent = store.createAgent(
        name: 'yaml',
        systemPrompt: '多行\n提示词',
        modelId: 'm1',
      );
      final CoreAgent restored = CoreAgent.fromJson(
        YamlCodec.decode(YamlCodec.encode(agent.toJson())),
      );
      expect(restored.name, 'yaml');
      expect(restored.systemPrompt, '多行\n提示词');
      expect(restored.createdAt, agent.createdAt);
    });
  });
}
