// 阶段 8：整轮 tool loop 接管（中转站点位 `system.relay.loop.run`）。
//
// 这条点位把**一整轮**（一条用户消息 ⇒ 第几跳、工具怎么排、何时收尾）交给插件，
// 与 `llm.handle`（只交一跳）的分界就在这里。这里钉的是"接管不夺权"的六件事：
// 1. 五个交付位齐（表项 + 常量 + 进 `StationHubIds.all` + 投递口 + readme 四段式），
//    中转点位 11 → **12**、内置点位 34 → **35**；
// 2. **接管信号只有一个**：回 `stream: true`（与 llm.handle 同一约定）；不回 /
//    明确 `taken:false` / 只回整包 ⇒ 内置 loop 逐字不变，且**每种都留下一行说明**；
// 3. 收尾**只播一条 AgentDone**——不管它是从 done、从取消、还是从心跳丢失来的；
//    取消的形状与内置一致：`AgentDone(cancelled:true)`，**不发 AgentError**；
// 4. 工具活动卡片由**核心**播（接管者经 `tool.call` 回带 `run_id`）：成对、同 id、
//    归属可证；**已收尾的 run 再报工具 ⇒ 拒**（不留"核心已收尾还在写工作空间"的孤儿）；
// 5. 接管期间同一会话的 `agent.message` 被拒：双写历史这件事不能靠约定，得当场拦；
// 6. 接管者报的 usage 与内置**同一形状**：`cached_tokens` 为 0 不写键、上限拿不到不写。
//
// 这里用**进程内订阅者**当接管者（接管判据与流的生命周期都是总线内的逻辑）；
// `station/stream` 的帧只能由真插件进程推，所以事件正文那一段用夹具插件补一条端到端。
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tree_core/src/plugin/execute_mounts.dart';
import 'package:tree_core/src/plugin/plugin_bus.dart';
import 'package:tree_core/src/plugin/station_ids.dart';
import 'package:tree_core/src/plugin/station_instance.dart';
import 'package:tree_core/src/plugin/station_points.dart';
import 'package:tree_core/src/plugin/station_runtime.dart';
import 'package:tree_core/src/plugin/station_schema.dart';
import 'package:tree_core/src/plugin/station_scope.dart';
import 'package:tree_core/src/plugin/stations.dart';
import 'package:tree_core/src/agent/agent_engine.dart';
import 'package:tree_core/src/llm/llm_types.dart';
import 'package:tree_core/src/tool/tool_runner.dart';
import 'package:tree_local_exec/tree_local_exec.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late List<String> logs;
  late int busSeq;

  const String team = 'team-1';
  const String agent = 'agt_1';
  const String session = 'ses_default';

  const List<LlmMessage> hello = <LlmMessage>[
    LlmMessage(role: LlmRole.user, content: '开工'),
  ];
  const List<ToolSpec> oneTool = <ToolSpec>[
    ToolSpec(name: 'read', description: '读文件'),
  ];

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_loop_relay_');
    logs = <String>[];
    busSeq = 0;
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

  /// 起一条总线（**每条一个独立配置目录**：站点订阅会落盘，共用会互相串台）。
  Future<PluginBus> startBus(String configYaml) async {
    final String dir = p.join(temp.path, 'bus-${++busSeq}');
    final File file = File(p.join(dir, 'config', 'plugins.yaml'));
    file.createSync(recursive: true);
    file.writeAsStringSync(configYaml);
    final PluginBus bus = PluginBus(
      configFile: file.path,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
      log: logs.add,
    );
    // 复刻生产接线（CoreServer._wirePluginStations）：team / mode 按 agent 真实归属，
    // 否则运行期四元组证明不了归属，中转点位一律放行（那正是 fail-open 的另一格）。
    bus.callSiteContext = (String agentId, String sessionId) =>
        StationScopeContext(
          teamId: team,
          agentId: agentId,
          sessionId: sessionId,
        );
    addTearDown(bus.close);
    await bus.start();
    return bus;
  }

  const String alphaConfig =
      'enabled: true\n'
      'plugins:\n'
      '  - id: alpha\n'
      '    name: 甲插件\n'
      '    command: "definitely-not-a-real-command-xyz"\n'
      '    enabled: true\n'
      '    granularity: team\n'
      '    scope: {team_id: team-1}\n';

  /// 在 `loop.run` 点位上放一个接管者（进程内）；返回它收到的请求列表。
  List<StationRequest> takeOver(
    PluginBus bus,
    Map<String, dynamic> Function(StationRequest request) reply,
  ) {
    bus.stations.ensureBuiltinStations();
    final List<StationRequest> seen = <StationRequest>[];
    final StationSubResult sub = bus.stations.subscribe(
      StationHubIds.relayLoopRun,
      StationSubscriber(
        pluginId: 'taker',
        scope: const StationScope(teamId: team, modeKey: StationModeKey.local),
        subscribedAt: 1,
      ),
      (StationRequest request) async {
        seen.add(request);
        return StationReply.ok(reply(request));
      },
    );
    expect(sub.ok, isTrue, reason: '接管失败：${sub.error}');
    return seen;
  }

  Future<Stream<AgentEvent>?> run(
    PluginBus bus, {
    bool Function()? isCancelled,
  }) => bus.relayLoopRun(
    messages: hello,
    tools: oneTool,
    agentId: agent,
    sessionId: session,
    model: 'm-test',
    maxContextTokens: 8000,
    isCancelled: isCancelled ?? () => false,
  );

  group('交付位与接管判据', () {
    test('loop.run 四处齐改，readme 是四段式，且只允许一个订阅者', () {
      final StationPointSpec? spec = StationPoints.byId(
        StationHubIds.relayLoopRun,
      );
      expect(spec, isNotNull);
      expect(
        StationHubIds.all,
        contains(StationHubIds.relayLoopRun),
        reason: '漏进 all ⇒ 插件订阅会被当成别人的自建站拒掉（静默失效）',
      );
      expect(spec!.kind, StationKind.relay);
      expect(spec.alias, 'loop.run');
      expect(spec.maxSubscriptions, 1, reason: '接管型点位，不是广播');
      expect(spec.readme, contains('触发时机'));
      expect(spec.readme, contains('限制'));
      // 派生计数（加点位必须同时改这里）
      expect(StationPoints.ofKind(StationKind.relay), hasLength(12));
      expect(StationPoints.all.length, 35);
    });

    test('未接线（点位不可用）⇒ null，内置路径逐字不变', () async {
      final PluginBus bus = await startBus('enabled: false\nplugins: []\n');
      expect(await run(bus), isNull);
    });

    test('无人订阅 ⇒ null 且**零投递**（快路径不等回包）', () async {
      final PluginBus bus = await startBus(alphaConfig);
      bus.stations.ensureBuiltinStations();
      expect(await run(bus), isNull);
      expect(
        logs.where((String l) => l.contains('整轮接管')),
        isEmpty,
        reason: '没人订阅不是异常，不该留一行"未接管"的噪声',
      );
    });

    test('明确回 taken:false ⇒ null，并留下一行"插件主动让路"', () async {
      final PluginBus bus = await startBus(alphaConfig);
      final List<StationRequest> seen = takeOver(
        bus,
        (StationRequest r) => <String, dynamic>{'taken': false},
      );
      expect(await run(bus), isNull);
      expect(seen, hasLength(1));
      expect(
        logs.any((String l) => l.contains('明确回了 taken:false')),
        isTrue,
        reason: '$logs',
      );
    });

    test('只回整包（没有 stream:true）⇒ null + 日志说明这一条只收流式', () async {
      final PluginBus bus = await startBus(alphaConfig);
      takeOver(
        bus,
        (StationRequest r) => <String, dynamic>{
          'taken': true,
          'text': '我一次性把整轮说完了',
        },
      );
      expect(await run(bus), isNull);
      expect(
        logs.any((String l) => l.contains('只回了整包')),
        isTrue,
        reason: '必须让插件作者知道为什么没生效：$logs',
      );
    });

    test('payload 交出去的是"引擎这一轮真会用的那份"（消息 + 工具表 + 四元组）', () async {
      final PluginBus bus = await startBus(alphaConfig);
      final List<StationRequest> seen = takeOver(
        bus,
        (StationRequest r) => <String, dynamic>{'stream': true},
      );
      final Stream<AgentEvent>? stream = await run(bus);
      expect(stream, isNotNull, reason: '回 stream:true 就是接管成立');
      await stream!.listen(null).cancel();
      final Map<String, dynamic> payload =
          seen.single.payload! as Map<String, dynamic>;
      expect(payload['point'], StationHubIds.relayLoopRun);
      expect(payload['agent_id'], agent);
      expect(payload['session_id'], session);
      expect(payload['team_id'], team);
      expect(payload['model'], 'm-test');
      expect(payload['message_count'], 1);
      expect(payload['messages'], hasLength(1));
      expect(
        (payload['tools'] as List<dynamic>).cast<Map<String, dynamic>>().single,
        containsPair('name', 'read'),
        reason: '工具表必须是引擎给会话的那一份（同名同参数），否则插件看到的是另一个世界',
      );
    });
  });

  group('接管成立之后的生命周期', () {
    test('在册可查：openLoopRuns / activeLoopRunOf 认到这一轮', () async {
      final PluginBus bus = await startBus(alphaConfig);
      takeOver(bus, (StationRequest r) => <String, dynamic>{'stream': true});
      final Stream<AgentEvent>? stream = await run(bus);
      expect(stream, isNotNull);
      expect(bus.openLoopRuns, 1);
      expect(
        bus.activeLoopRunOf(agentId: agent, sessionId: session),
        isNotEmpty,
      );
      expect(
        bus.activeLoopRunOf(agentId: agent, sessionId: '别的会话'),
        isNull,
        reason: '按会话隔离：别的会话照样能自己跑一轮',
      );
      await stream!.listen(null).cancel();
    });

    test('取消 ⇒ 只播**一条** AgentDone(cancelled:true)，且不发 AgentError', () async {
      final PluginBus bus = await startBus(alphaConfig);
      takeOver(bus, (StationRequest r) => <String, dynamic>{'stream': true});
      bool cancelled = false;
      final Stream<AgentEvent>? stream = await run(
        bus,
        isCancelled: () => cancelled,
      );
      expect(stream, isNotNull);
      final List<AgentEvent> got = <AgentEvent>[];
      final Completer<void> done = Completer<void>();
      stream!.listen(
        (AgentEvent event) {
          got.add(event);
          if (event is AgentDone && !done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );
      cancelled = true; // 用户按下"停止"：守护定时器据此单方面收尾
      await done.future.timeout(const Duration(seconds: 3));
      expect(got.whereType<AgentDone>(), hasLength(1), reason: '$got');
      expect(got.whereType<AgentError>(), isEmpty, reason: '被用户停下不是出错：$got');
      expect(got.single, isA<AgentDone>());
      expect((got.single as AgentDone).cancelled, isTrue);
      expect(bus.openLoopRuns, 0, reason: '收尾后要从在册表里退掉');
    });

    test('取消之后插件再报工具 ⇒ 拒（不收"核心已收尾还在写工作空间"的孤儿）', () async {
      final PluginBus bus = await startBus(alphaConfig);
      takeOver(bus, (StationRequest r) => <String, dynamic>{'stream': true});
      bool cancelled = false;
      final Stream<AgentEvent>? stream = await run(
        bus,
        isCancelled: () => cancelled,
      );
      expect(stream, isNotNull);
      final String runId = bus.activeLoopRunOf(sessionId: session)!;
      final Completer<void> closed = Completer<void>();
      stream!.listen(
        null,
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
      );
      cancelled = true;
      await closed.future.timeout(const Duration(seconds: 3));
      expect(
        bus.noteRunToolActivity(
          runId: runId,
          sourcePluginId: 'taker',
          phase: 'start',
          tool: 'fs.write',
        ),
        isFalse,
        reason: '这一轮已经收尾了',
      );
      expect(
        logs.any((String l) => l.contains('这扇工具调用已被拒')),
        isTrue,
        reason: '$logs',
      );
    });
  });

  group('工具活动卡片由核心播（写侧不交出去）', () {
    test('start / end 成对且同 id；卡片真的进这一轮的事件流', () async {
      final PluginBus bus = await startBus(alphaConfig);
      takeOver(bus, (StationRequest r) => <String, dynamic>{'stream': true});
      final Stream<AgentEvent>? stream = await run(bus);
      expect(stream, isNotNull);
      final List<AgentEvent> got = <AgentEvent>[];
      final StreamSubscription<AgentEvent> sub = stream!.listen(got.add);
      final String runId = bus.activeLoopRunOf(sessionId: session)!;
      expect(
        bus.noteRunToolActivity(
          runId: runId,
          sourcePluginId: 'taker',
          phase: 'start',
          tool: 'read',
          callId: 'call_7',
          arguments: <String, dynamic>{'path': 'a.txt'},
        ),
        isTrue,
      );
      expect(
        bus.noteRunToolActivity(
          runId: runId,
          sourcePluginId: 'taker',
          phase: 'end',
          tool: 'read',
          callId: 'call_7',
          result: '文件内容',
        ),
        isTrue,
      );
      await pumpEventQueue();
      expect(got, hasLength(2), reason: '$got');
      final AgentToolStart start = got.first as AgentToolStart;
      final AgentToolEnd end = got.last as AgentToolEnd;
      expect(start.name, 'read');
      expect(start.callId, 'call_7');
      expect(start.arguments, <String, dynamic>{'path': 'a.txt'});
      expect(end.id, start.id, reason: '不成对的话面板上会留一张永远转圈的卡片');
      expect(end.result, '文件内容');
      await sub.cancel();
    });

    test('归属：别人的 run_id 播不进去；不在册的 run 也播不进去', () async {
      final PluginBus bus = await startBus(alphaConfig);
      takeOver(bus, (StationRequest r) => <String, dynamic>{'stream': true});
      final Stream<AgentEvent>? stream = await run(bus);
      expect(stream, isNotNull);
      // 注：这里**先不能**取消订阅——取消会走 controller.onCancel ⇒ 这一轮当场收尾，
      // 而这一条要验的是“流还开着，但归属不对”。
      final String runId = bus.activeLoopRunOf(sessionId: session)!;
      expect(
        bus.noteRunToolActivity(
          runId: runId,
          sourcePluginId: '别的插件',
          phase: 'start',
          tool: 'read',
        ),
        isFalse,
        reason: 'A 插件不能凭一个 id 就往 B 插件那一轮里塞卡片',
      );
      expect(
        bus.noteRunToolActivity(
          runId: '不存在的-run',
          sourcePluginId: 'taker',
          phase: 'start',
          tool: 'read',
        ),
        isFalse,
      );
      expect(
        bus.noteRunToolActivity(
          runId: runId,
          sourcePluginId: 'taker',
          phase: 'middle',
          tool: 'read',
        ),
        isFalse,
        reason: 'phase 只能是 start | end（不拿非法值假装成功）',
      );
      await stream!.listen(null).cancel();
    });
  });

  group('接管期间不开第二条写入口', () {
    late StationHub hub;
    late ExecuteStation point;

    setUp(() {
      hub = StationHub(
        storePath: p.join(temp.path, 'stations-mount-${++busSeq}.yaml'),
      );
      hub.ensureBuiltinStations();
      point = hub.executePointFor(StationHubIds.executeAgent)!;
    });

    /// 一份只接了 `agent.message` 那族的挂载位置；[activeRun] 非空 = 模拟
    /// “这一轮正被插件接管”（总线递进来的那个 run_id）。
    void mountInto({String? activeRun}) {
      final String workspace = p.join(temp.path, 'ws-${++busSeq}');
      Directory(workspace).createSync(recursive: true);
      final ExecuteStationMounts built = ExecuteStationMounts(
        ioFor: (String agentId) async => LocalWorkspaceIO(workspace),
        agentTeamOf: (String agentId) => agentId == agent ? team : '',
        agentModeOf: (String agentId) =>
            agentId == agent ? StationModeKey.local : '',
        activeLoopRunOf: activeRun == null
            ? null
            : ({required String agentId, required String sessionId}) =>
                  activeRun,
        messageSender: ({
          required String agentId,
          required String sessionId,
          required String content,
          String sourcePluginId = '',
        }) async => <String, dynamic>{'success': true},
      );
      expect(built.mountInto(point), isNull, reason: 'agent.message 应挂载成功');
      addTearDown(built.close);
    }

    Future<StationCommandResult> send(String content) => point.execute(
      command: 'agent.message',
      scope: const StationScope(
        teamId: team,
        agentId: agent,
        sessionId: session,
        modeKey: StationModeKey.local,
      ),
      arguments: <String, dynamic>{
        'agent_id': agent,
        'session_id': session,
        'message': content,
      },
      sourcePluginId: 'alpha',
    );

    test('这一轮正被接管 ⇒ agent.message 拒，并说清是哪一轮在挡', () async {
      mountInto(activeRun: 'run-77');
      final StationCommandResult blocked = await send('我来补一句');
      expect(blocked.ok, isFalse);
      expect(blocked.error, contains('双写历史'));
      expect(blocked.error, contains('run-77'));
    });

    test('没被接管 ⇒ 照旧发得出去（这条闸门只在真接管时生效）', () async {
      mountInto();
      final StationCommandResult ok = await send('正常派活');
      expect(ok.ok, isTrue, reason: ok.error);
    });
  });

  group('接管者的 usage 形状（与内置同口径）', () {
    test('total 有真值用真值，否则 prompt+completion', () {
      expect(
        loopRunUsageMap(
          const LlmUsage(promptTokens: 100, completionTokens: 20),
          8000,
        ),
        <String, dynamic>{
          'prompt_tokens': 100,
          'completion_tokens': 20,
          'total_tokens': 120,
          'max_tokens': 8000,
        },
      );
      expect(
        loopRunUsageMap(
          const LlmUsage(
            promptTokens: 100,
            completionTokens: 20,
            totalTokens: 130,
          ),
          8000,
        )['total_tokens'],
        130,
        reason: '端点给了真值就不要自己算',
      );
    });

    test('cached=0 与拿不到上限 ⇒ **不写键**（绝不编造 0 / 假上限）', () {
      final Map<String, dynamic> bare = loopRunUsageMap(
        const LlmUsage(promptTokens: 5, completionTokens: 1),
        0,
      );
      expect(bare.containsKey('cached_tokens'), isFalse);
      expect(bare.containsKey('max_tokens'), isFalse);
      expect(
        loopRunUsageMap(
          const LlmUsage(promptTokens: 5, completionTokens: 1, cachedTokens: 4),
          0,
        )['cached_tokens'],
        4,
      );
    });
  });
}
