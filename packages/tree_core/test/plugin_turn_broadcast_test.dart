// 广播站点位：本轮结局、提问暂停与清单变更（阶段 6，A 级点位批）。
//
// 钉住的口径（plan 第 6 天 / station-catalog §3 的 A 级行）：
// 1. 五个新点位都**成对登记**（常量 + 进 `all` + 表项 + readme），漏一处就是静默失效；
// 2. turn.done / turn.cancelled / turn.error **互斥**，同一轮只出一条，且互斥由**会话层**
//    保证（按 error > cancelled > done 取第一条）；
// 3. 载荷**只有度量与结论**：turn.done 不带正文，ask.paused 不带题面与选项；
// 4. 新事件走**广播点位**（订了才投），**不再**走 `agent.tool_call` 那一路
//    「scope 命中就收」的既有实例事件流——同一条走两处，订了站点的插件会收到两份；
// 5. `config.changed` 的 `action` 与 `PluginReconcileKind` 同源，而 **unchanged 一律不发**
//    （"没改动"不是变更：发了就是让监听插件每次对账白醒一次）；
// 6. 证明不了归属 ⇒ 显式跳过并写下原因（不变量 6），不静默。
//
// 观察方式与 `plugin_state_broadcast_test.dart` 一致：挂一个**进程内订阅者**直接收载荷，
// 断言的是"真的投递到了订阅者"，而不是"计数器说发过了"。
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  late Directory temp;
  late String configFile;
  late List<String> logs;

  const String team = 'team-1';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_turn_broadcast_');
    configFile = p.join(temp.path, 'config', 'plugins.yaml');
    File(configFile).createSync(recursive: true);
    logs = <String>[];
  });

  tearDown(() async {
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  /// 起一条总线（不启任何插件进程：这里验的是**投递判据与载荷形状**）。
  ///
  /// [withCallSite] = 接上核心在生产里接的那一行（按 agent 解析 team）；
  /// 不接就复现"证明不了归属"那格。
  Future<PluginBus> startBus(
    String configYaml, {
    bool withCallSite = true,
  }) async {
    File(configFile).writeAsStringSync(configYaml);
    final PluginBus bus = PluginBus(
      configFile: configFile,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
      missThreshold: 3,
      log: logs.add,
    );
    if (withCallSite) {
      bus.callSiteContext = (String agentId, String sessionId) =>
          StationScopeContext(teamId: team, agentId: agentId);
    }
    addTearDown(bus.close);
    await bus.start();
    return bus;
  }

  /// 在某个点位上挂进程内观察者（**先订阅再触发**，一条都不漏）。
  List<StationRequest> watch(PluginBus bus, String stationId) {
    bus.stations.ensureBuiltinStations();
    final List<StationRequest> received = <StationRequest>[];
    final StationSubResult sub = bus.stations.subscribe(
      stationId,
      StationSubscriber(
        pluginId: 'watcher-$stationId',
        // 通配订阅（team 留空 = 不设条件）：哪个 team 的事件都要收
        scope: const StationScope(),
        subscribedAt: 1,
      ),
      (StationRequest request) async {
        received.add(request);
        return StationReply.ok(<String, dynamic>{'acked': true});
      },
    );
    expect(sub.ok, isTrue, reason: '观察者订阅失败：${sub.error}');
    return received;
  }

  Map<String, dynamic> turnEvent({
    String event = 'agent.turn.done',
    String agentId = 'agt_1',
  }) => <String, dynamic>{
    'event': event,
    'agent_id': agentId,
    'session_id': 'ses_default',
    'team_id': team,
    'content_chars': 12,
    'elapsed_ms': 34,
    'tool_rounds': 2,
  };

  group('点位登记（成对出现，缺一处就静默失效）', () {
    test('五个新点位：常量进 all、有表项、readme 不空', () {
      for (final String id in <String>[
        StationHubIds.broadcastTurnDone,
        StationHubIds.broadcastTurnCancelled,
        StationHubIds.broadcastTurnError,
        StationHubIds.broadcastAskPaused,
        StationHubIds.broadcastConfigChanged,
      ]) {
        expect(StationHubIds.all, contains(id), reason: '$id 漏进 all');
        final StationPointSpec? spec = StationPoints.byId(id);
        expect(spec, isNotNull, reason: '$id 没有表项');
        expect(spec!.kind, StationKind.broadcast);
        expect(spec.readme, isNotEmpty, reason: '每个点位都必须有介绍（面板读它）');
      }
      expect(
        StationPoints.byId(StationHubIds.broadcastTurnDone)!.alias,
        'turn.done',
      );
      expect(
        StationPoints.byId(StationHubIds.broadcastConfigChanged)!.alias,
        'config.changed',
      );
    });

    test('readme 把「不带正文 / 不带题面」这条限制写给插件作者', () {
      expect(
        StationPoints.byId(StationHubIds.broadcastTurnDone)!.readme,
        contains('不带正文'),
      );
      expect(
        StationPoints.byId(StationHubIds.broadcastAskPaused)!.readme,
        contains('不带题面与选项'),
      );
      expect(
        StationPoints.byId(StationHubIds.broadcastConfigChanged)!.readme,
        contains('unchanged 一律不发'),
      );
    });
  });

  group('本轮结局的投递判据', () {
    test('turn.done 投给订阅者：topic = 去掉前缀的点位名，载荷只有度量', () async {
      final PluginBus bus = await startBus('enabled: true\nplugins: []\n');
      final List<StationRequest> got = watch(
        bus,
        StationHubIds.broadcastTurnDone,
      );

      expect(
        bus.dispatchAgentEvent(turnEvent()),
        1,
        reason: '总线一个插件进程都没起⇒ 这个 1 只能来自订阅者，不是实例事件流',
      );
      await pumpEventQueue(); // 送达是异步的（publish 不 await，广播不能拖慢生成）
      final StationRequest request = got.single;
      expect(request.stationId, StationHubIds.broadcastTurnDone);
      expect(request.meta['topic'], 'turn.done');
      final Map<String, dynamic> payload =
          request.payload! as Map<String, dynamic>;
      expect(payload['point'], StationHubIds.broadcastTurnDone);
      expect(payload['content_chars'], 12);
      expect(payload['tool_rounds'], 2);
      expect(
        payload.containsKey('content'),
        isFalse,
        reason: '正文的正经读处是会话存储与 REST，不许复制进每个插件',
      );
    });

    test('没人订这个点位 ⇒ 零投递、零异常，也不冒泡成新失败', () async {
      final PluginBus bus = await startBus('enabled: true\nplugins: []\n');
      expect(bus.dispatchAgentEvent(turnEvent()), 0);
      expect(bus.dispatchAgentEvent(turnEvent(event: 'agent.turn.error')), 0);
    });

    test('证明不了归属 ⇒ 显式跳过并写下为什么（fail-closed，不静默）', () async {
      final PluginBus bus = await startBus(
        'enabled: true\nplugins: []\n',
        withCallSite: false,
      );
      watch(bus, StationHubIds.broadcastTurnDone);
      expect(bus.dispatchAgentEvent(turnEvent()), 0);
      expect(
        logs.any((String line) => line.contains('不能证明归属')),
        isTrue,
        reason: '这条广播为什么没发出去必须查得到（不变量 6）',
      );
    });

    test('agent.tool_call 仍走既有那一路（新点位没有把老事件抢走）', () async {
      final PluginBus bus = await startBus('enabled: true\nplugins: []\n');
      final List<StationRequest> got = watch(
        bus,
        StationHubIds.broadcastTurnDone,
      );
      bus.dispatchAgentEvent(<String, dynamic>{
        'event': AgentEvents.toolCall,
        'agent_id': 'agt_1',
        'session_id': 'ses_default',
        'team_id': team,
        'phase': 'start',
      });
      expect(got, isEmpty, reason: 'tool_call 不在分流表里：改它的投递口径就是改一个已经上线的行为');
    });

    test('三条互斥由会话层保证：同一轮只构造一条（error > cancelled > done）', () async {
      final List<Map<String, dynamic>> events = <Map<String, dynamic>>[];
      final AgentEventPublisher publisher = AgentEventPublisher(
        sink: events.add,
      );
      // 取消 + 错误同时成立时，ConversationService 只调 turnError（见 _publishTurnOutcome
      // 的分支顺序）；这里钉的是三条事件的**形状**与互斥约定的字面口径。
      publisher.turnError(
        agentId: 'agt_1',
        sessionId: 'ses_default',
        teamId: team,
        message: '生成失败：端点返回 400',
        failedAfterTools: true,
        contentChars: 8,
        elapsedMs: 66,
        toolRounds: 2,
      );
      expect(events, hasLength(1));
      expect(events.single['event'], AgentEvents.turnError);
      expect(
        events.single['error'],
        '生成失败：端点返回 400',
        reason: '与用户看到的那一句同源，不另造一套说法',
      );
      expect(events.single['failed_after_tools'], isTrue);

      events.clear();
      publisher.turnDone(
        agentId: 'agt_1',
        sessionId: 'ses_default',
        teamId: team,
        contentChars: 42,
        elapsedMs: 100,
        toolRounds: 3,
        finishReason: 'stop',
      );
      expect(events.single['finish_reason'], 'stop');
      expect(events.single.containsKey('content'), isFalse);

      events.clear();
      publisher.turnCancelled(
        agentId: 'agt_1',
        sessionId: 'ses_default',
        teamId: team,
        source: AgentEvents.sourceInterjection,
        contentChars: 0,
        elapsedMs: 10,
        toolRounds: 0,
      );
      expect(
        events.single['source'],
        'interjection',
        reason: '插话不算“用户停了本轮”（审计上这是两件事）',
      );
      expect(
        events.single.containsKey('subagent_id'),
        isFalse,
        reason: '主 agent 的轮次不带临时员工标记（带了会被误读成子级）',
      );
    });

    test('未接线 = 一条都不构造；发布器抛异常也不冒泡', () {
      expect(AgentEventPublisher().enabled, isFalse);
      AgentEventPublisher().turnDone(
        agentId: 'a',
        sessionId: 's',
        teamId: team,
        contentChars: 1,
        elapsedMs: 1,
        toolRounds: 0,
      );
      final List<String> errors = <String>[];
      final AgentEventPublisher publisher = AgentEventPublisher(
        sink: (Map<String, dynamic> _) => throw StateError('插件侧炸了'),
        onError: errors.add,
      );
      expect(
        () => publisher.turnDone(
          agentId: 'a',
          sessionId: 's',
          teamId: team,
          contentChars: 1,
          elapsedMs: 1,
          toolRounds: 0,
        ),
        returnsNormally,
        reason: '事件发布在生成收尾路径上：插件侧的问题绝不能让本轮失败',
      );
      expect(errors.single, contains('agent.turn.done'));
    });

    test('ask.paused 的载荷只有 qid 与题数（不递题面与选项）', () {
      final Map<String, dynamic> event = agentAskPausedEvent(
        questionId: 'que_1',
        agentId: 'agt_1',
        sessionId: 'ses_default',
        teamId: team,
        questionCount: 2,
      );
      expect(event['event'], AgentEvents.askPaused);
      expect(event['question_id'], 'que_1');
      expect(event['question_count'], 2);
      expect(
        event.values.whereType<String>().any((String v) => v.contains('请选择')),
        isFalse,
        reason: '题面是用户与 agent 之间的内容',
      );
    });

    test('ask.paused 经同一个派发入口投给订阅者（与 turn.* 同一机制）', () async {
      final PluginBus bus = await startBus('enabled: true\nplugins: []\n');
      final List<StationRequest> got = watch(
        bus,
        StationHubIds.broadcastAskPaused,
      );
      bus.dispatchAgentEvent(
        agentAskPausedEvent(
          questionId: 'que_1',
          agentId: 'agt_1',
          sessionId: 'ses_default',
          teamId: team,
          questionCount: 1,
        ),
      );
      await pumpEventQueue();
      final Map<String, dynamic> payload =
          got.single.payload! as Map<String, dynamic>;
      expect(payload['question_id'], 'que_1');
      expect(payload['question_count'], 1);
      expect(got.single.meta['topic'], 'ask.paused');
    });
  });

  group('config.changed（对账结果的对外面）', () {
    String entryYaml({bool enabled = true}) =>
        'enabled: true\n'
        'plugins:\n'
        '  - id: demo\n'
        '    name: 本轮广播用例\n'
        '    command: "definitely-not-an-executable-xyz"\n'
        '    enabled: $enabled\n'
        '    granularity: team\n'
        '    scope: {team_id: $team, mode_key: local}\n';

    test('插件没起来 ⇒ 广播 failed 并带可读原因（一次对账一个动作一条）', () async {
      final PluginBus bus = await startBus(entryYaml());
      final List<StationRequest> got = watch(
        bus,
        StationHubIds.broadcastConfigChanged,
      );

      await bus.applyConfigs();
      await pumpEventQueue();
      final Map<String, dynamic> payload =
          got.single.payload! as Map<String, dynamic>;
      expect(payload['plugin_id'], 'demo');
      expect(
        payload['action'],
        'failed',
        reason: 'action 与 PluginReconcileKind 同源，不发明第二套词汇',
      );
      expect(payload['reason'], isNotEmpty, reason: '失败必须可归因（不变量 6）');
      expect(got.single.meta['topic'], 'config.changed');
    });

    test('本来就没在跑的停用条目 ⇒ unchanged ⇒ **一条都不发**', () async {
      final PluginBus bus = await startBus(entryYaml(enabled: false));
      final List<StationRequest> got = watch(
        bus,
        StationHubIds.broadcastConfigChanged,
      );

      final PluginReconcileResult result = await bus.applyConfigs();
      await pumpEventQueue();
      expect(
        result.unchanged,
        isNotEmpty,
        reason: '这条对账确实给出了 unchanged（否则本用例没钉住任何东西）',
      );
      expect(got, isEmpty, reason: '"没改动"不是变更：发了就是让监听插件每次对账白醒一次');
    });
  });
}
