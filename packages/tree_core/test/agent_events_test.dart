import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// agent 事件发布器与**会话服务的注入点**（M9 追加）：
/// 每次工具调用开始 / 结束各发一条 `agent.tool_call`，未接线 = no-op。
void main() {
  group('AgentEventPublisher', () {
    test('toolCall：字段完整，start / end 成对口径一致', () {
      final List<Map<String, dynamic>> events = <Map<String, dynamic>>[];
      final AgentEventPublisher publisher = AgentEventPublisher(
        sink: events.add,
      );
      expect(publisher.enabled, isTrue);

      publisher.toolCall(
        agentId: 'agt_1',
        sessionId: 'ses_1',
        teamId: 'team-1',
        tool: 'plugin__sample__echo',
        callId: 'call_1',
        round: 3,
        phase: AgentEvents.phaseStart,
      );
      publisher.toolCall(
        agentId: 'agt_1',
        sessionId: 'ses_1',
        teamId: 'team-1',
        tool: 'plugin__sample__echo',
        callId: 'call_1',
        round: 3,
        phase: AgentEvents.phaseEnd,
      );

      expect(events, hasLength(2));
      expect(events.first, <String, dynamic>{
        'event': 'agent.tool_call',
        'agent_id': 'agt_1',
        'session_id': 'ses_1',
        'team_id': 'team-1',
        'tool': 'plugin__sample__echo',
        'call_id': 'call_1',
        'round': 3,
        'phase': 'start',
      });
      expect(events.last, <String, dynamic>{
        ...events.first,
        'phase': 'end',
      }, reason: '结束事件与开始事件同 call_id / round（插件据此算耗时）');
    });

    test('未接线 = no-op：不构造事件、不抛异常', () {
      final AgentEventPublisher publisher = AgentEventPublisher();
      expect(publisher.enabled, isFalse);
      expect(
        () => publisher.toolCall(
          agentId: 'agt_1',
          sessionId: 'ses_1',
          phase: AgentEvents.phaseStart,
        ),
        returnsNormally,
      );

      // 显式断开（先接线再置空）后同样 no-op
      final List<Map<String, dynamic>> events = <Map<String, dynamic>>[];
      publisher.sink = events.add;
      publisher.sink = null;
      publisher.toolCall(
        agentId: 'agt_1',
        sessionId: 'ses_1',
        phase: AgentEvents.phaseEnd,
      );
      expect(events, isEmpty);
    });

    test('订阅方抛异常不冒泡（收敛到 onError）', () {
      final List<String> errors = <String>[];
      final AgentEventPublisher publisher = AgentEventPublisher(
        sink: (Map<String, dynamic> _) => throw StateError('插件侧炸了'),
        onError: errors.add,
      );
      expect(
        () => publisher.toolCall(
          agentId: 'agt_1',
          sessionId: 'ses_1',
          phase: AgentEvents.phaseStart,
        ),
        returnsNormally,
        reason: '事件发布在生成循环里：插件侧的问题绝不能让生成失败',
      );
      expect(errors.single, contains('agent.tool_call'));
      expect(errors.single, contains('插件侧炸了'));
    });
  });

}
