import 'dart:async';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

import 'ws_harness.dart';

/// 可控引擎：按脚本一次性产出全部事件（不模拟任何时间）。
class _ScriptEngine implements AgentEngine {
  _ScriptEngine(this.events);

  final List<AgentEvent> events;

  @override
  Stream<AgentEvent> run(
    AgentRunContext context, {
    required bool Function() isCancelled,
  }) async* {
    for (final AgentEvent event in events) {
      yield event;
    }
  }

  @override
  Future<void> close() async {}
}

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

  group('ConversationService 的注入点', () {
    late CoreServer server;
    late TestWs ws;
    late String agentId;
    const String sessionId = TreeStore.defaultSessionId;

    Future<void> start(List<AgentEvent> events) async {
      server = await CoreServer.start(
        streamChunkDelay: Duration.zero,
        enableHeartbeat: false,
        engine: _ScriptEngine(events),
      );
      agentId = server.store.createAgent(name: '事件用例').id;
      // 团队归属：事件里的 team_id 取自 agent（站点隔离四元组的 team）
      final CoreAgent agent = server.store.agent(agentId)!;
      agent.teamId = 'team-1';
      server.store.putAgent(agent);
      ws = await TestWs.connect(server);
      ws.record();
    }

    tearDown(() async {
      await ws.close();
      await server.close();
    });

    Future<void> send(String content) async {
      ws.send(<String, dynamic>{
        'type': WsInboundType.userMessage,
        'agent_id': agentId,
        'content': content,
        'session_id': sessionId,
      });
      await waitIdle(ws);
    }

    test('工具调用开始 / 结束各一条事件，字段完整、round 递增、call_id 保留', () async {
      await start(<AgentEvent>[
        AgentToolStart(
          id: 'tool_a',
          callId: 'call_a',
          name: 'read',
          arguments: const <String, dynamic>{'file_path': 'a.txt'},
        ),
        const AgentToolEnd(id: 'tool_a', name: 'read', result: 'A 的内容'),
        AgentToolStart(
          id: 'tool_b',
          callId: 'call_b',
          name: 'plugin__sample__echo',
          arguments: const <String, dynamic>{'text': 'x'},
        ),
        const AgentToolEnd(
          id: 'tool_b',
          name: 'plugin__sample__echo',
          result: 'ok',
        ),
        const AgentDone(finishReason: 'stop'),
      ]);
      final List<Map<String, dynamic>> events = <Map<String, dynamic>>[];
      server.conversation.agentEvents.sink = events.add;

      await send('跑两个工具');

      expect(events, hasLength(4), reason: '两次工具调用 ⇒ 两条 start + 两条 end');
      expect(events[0], <String, dynamic>{
        'event': AgentEvents.toolCall,
        'agent_id': agentId,
        'session_id': sessionId,
        'team_id': 'team-1',
        'tool': 'read',
        'call_id': 'call_a',
        'round': 1,
        'phase': AgentEvents.phaseStart,
      });
      expect(events[1]['phase'], AgentEvents.phaseEnd);
      expect(events[1]['call_id'], 'call_a');
      expect(events[1]['round'], 1, reason: '结束事件与开始事件同轮次');
      expect(events[1]['tool'], 'read');
      expect(events[2]['tool'], 'plugin__sample__echo');
      expect(events[2]['round'], 2, reason: '轮次本任务内递增（插件按它判超限）');
      expect(events[3]['round'], 2);
      expect(events[3]['phase'], AgentEvents.phaseEnd);

      // 顺序与帧/落库一致：start 在 end 之前（同一 call_id 成对）
      expect(
        events.map((Map<String, dynamic> e) => '${e['call_id']}:${e['phase']}'),
        <String>['call_a:start', 'call_a:end', 'call_b:start', 'call_b:end'],
      );
    });

    test('未接线时照常生成：不发事件、不崩（既有行为不变）', () async {
      await start(<AgentEvent>[
        AgentToolStart(
          id: 'tool_a',
          callId: 'call_a',
          name: 'read',
          arguments: const <String, dynamic>{'file_path': 'a.txt'},
        ),
        const AgentToolEnd(id: 'tool_a', name: 'read', result: 'A 的内容'),
        const AgentText('做完了。'),
        const AgentDone(finishReason: 'stop'),
      ]);
      expect(server.conversation.agentEvents.enabled, isFalse);

      await send('跑一个工具');

      expect(
        ws.types(),
        containsAll(<String>['tool_start', 'tool_end']),
        reason: '未接线只是不发事件，工具卡片照常推送',
      );
      expect(ws.types().last, 'agent_status');
    });
  });
}
