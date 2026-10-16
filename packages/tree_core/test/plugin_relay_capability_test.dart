// 阶段 6 A 级点位批的**最后五片**：中转站 4 条 + 收集站 1 条。
//
// 为什么这批必须现在接（用户 2026-10-16 的原话口径）：核心要长期先进、少更新，
// 而这四条的**槽在核心里已经存在**（`toolResultRepair` / `toolResultProbe` /
// `llmRequestRegistrar` / `compactionSkipSink`）——不接就等于把"要动核心"的窗口留着。
// 接法全部是「表 + 装配」：引擎与 LlmSession 一行都没改。
//
// 钉住的六件事：
// 1. 五个新点位都**四处齐改**（表项 + 常量 + 进 `StationHubIds.all` + 投递口）；
//    本文件写的是**本阶段那一批**的增量，而类型分布断言钉的是**当前**总数（阶段 8
//    又加了中转站 `loop.run` ⇒ 中转 12），与 `station_points_test` 保持同步；
// 2. `tool.repair` 接管的是**文案**，落库仍然只走内置那一条路；
// 3. `tool.probe` 的**三档**必须分得开（没接管 / 有结果 / 肯定没有）；
// 4. `llm.register` 只能附加：内置登记表永远建立，取消 / 关闭 / 判死不在这一条上；
// 5. `compact.skip.reason` 只覆盖**还账上那一条**且**保留分级位**，账上没有就不凭空造；
// 6. `plugin.capability.define` **缺 schema 就拒那一条**（申报只是描述，不产生投递路）。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  late Directory temp;
  late List<String> logs;

  const String team = 'team-1';
  const String agent = 'agt_1';
  const String session = 'ses_default';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_relay_capability_');
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

  /// 起一条总线：不启真插件进程（这里验的是**投递判据与回包形状**），但接上核心在
  /// 生产里接的那一行 `callSiteContext`，否则运行期四元组证明不了归属、点位一律放行。
  ///
  /// **每条总线用自己的配置目录**：站点订阅会落盘（stations.yaml），共用一份就会
  /// 把上一条总线的进程内订阅者恢复进来（人已不在，回包永远拿不到）。
  int busSeq = 0;

  Future<PluginBus> startBus({bool enabled = true}) async {
    final String dir = p.join(temp.path, 'bus-${++busSeq}');
    final File config = File(p.join(dir, 'config', 'plugins.yaml'));
    config.createSync(recursive: true);
    config.writeAsStringSync(
      <String>[
        'enabled: $enabled',
        'plugins:',
        '  - id: alpha',
        '    name: 甲插件',
        '    command: "definitely-not-a-real-command-xyz"',
        '    enabled: true',
        '    granularity: team',
        '    scope: {team_id: team-1}',
        '',
      ].join('\n'),
    );
    final PluginBus bus = PluginBus(
      configFile: config.path,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
      log: logs.add,
    );
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

  /// 在某个**中转点位**上放一个接管者（中转站只允许一个订阅者）。
  ///
  /// [reply] 就是插件的回包载荷；返回收到的请求列表（先订阅再触发，一条都不漏）。
  List<StationRequest> takeOver(
    PluginBus bus,
    String stationId,
    Map<String, dynamic> Function(StationRequest request) reply,
  ) {
    bus.stations.ensureBuiltinStations();
    final List<StationRequest> received = <StationRequest>[];
    final StationSubResult sub = bus.stations.subscribe(
      stationId,
      StationSubscriber(
        pluginId: 'taker-$stationId',
        scope: const StationScope(teamId: team, modeKey: StationModeKey.local),
        subscribedAt: 1,
      ),
      (StationRequest request) async {
        received.add(request);
        return StationReply.ok(reply(request));
      },
    );
    expect(sub.ok, isTrue, reason: '接管失败：${sub.error}');
    return received;
  }

  group('表与投递口', () {
    test('五个新点位都在表里、都进了 all，readme 都是四段式', () {
      const List<String> relayIds = <String>[
        StationHubIds.relayToolRepair,
        StationHubIds.relayToolProbe,
        StationHubIds.relayLlmRegister,
        StationHubIds.relayCompactSkipReason,
      ];
      for (final String id in <String>[
        ...relayIds,
        StationHubIds.collectCapability,
      ]) {
        final StationPointSpec? spec = StationPoints.byId(id);
        expect(spec, isNotNull, reason: '$id 不在点位表里');
        expect(StationHubIds.all, contains(id), reason: '$id 没进 all（会静默失效）');
        // 四段式：是什么 / 何时触发 / 回包形状 / 限制
        expect(spec!.readme, contains('触发时机'));
        expect(spec.readme, contains('限制'));
      }
      // 中转点位一律**唯一订阅者**（接管语义，不是广播）
      for (final String id in relayIds) {
        expect(
          StationPoints.byId(id)!.maxSubscriptions,
          1,
          reason: '$id 是接管型点位，必须只允许一个订阅者',
        );
      }
    });

    test('类型分布 广播 10 / 执行 11 / 中转 12 / 收集 2 = 35；预建 33', () {
      expect(StationPoints.ofKind(StationKind.relay), hasLength(12));
      expect(StationPoints.ofKind(StationKind.collect), hasLength(2));
      expect(StationPoints.all.length, 35);
    });

    test('点位不可用（被别的类型占住）⇒ 一律按未接管放行，不抛', () async {
      final PluginBus bus = await startBus();
      // 没有任何接管者：三档读口全回"未接管"，两个 fire-and-forget 不炸
      expect(
        await bus.relayToolRepairText(
          agentId: agent,
          sessionId: session,
          toolCallId: 'call_1',
          toolName: 'terminal',
          text: '内置那句',
        ),
        isNull,
      );
      expect(
        await bus.relayToolProbe(
          agentId: agent,
          sessionId: session,
          toolCallId: 'call_1',
        ),
        isNull,
      );
      expect(
        () => bus.relayLlmRegisterNotice(
          handle: 'llm_1',
          agentId: agent,
          sessionId: session,
          model: 'm',
          turn: 2,
        ),
        returnsNormally,
      );
      expect(
        () => bus.relayCompactSkipReason(
          agentId: agent,
          sessionId: session,
          reason: '插件回了非法形状',
          hasSubscriber: true,
        ),
        returnsNormally,
      );
    });
  });

  group('tool.repair / tool.probe', () {
    test('tool.repair：接管者改写的文案就是返回值（落库仍然只有内置那一条路）', () async {
      final PluginBus bus = await startBus();
      final List<StationRequest> seen = takeOver(
        bus,
        StationHubIds.relayToolRepair,
        (StationRequest r) => <String, dynamic>{
          'repaired': true,
          'text': '网关侧超时，这次调用没有产出（重跑请用同一组参数）',
        },
      );
      final String? better = await bus.relayToolRepairText(
        agentId: agent,
        sessionId: session,
        toolCallId: 'call_9',
        toolName: 'terminal',
        text: '内置那句',
      );
      expect(better, contains('网关侧超时'));
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(1));
      final Map<String, dynamic> payload =
          seen.single.payload! as Map<String, dynamic>;
      expect(payload['point'], StationHubIds.relayToolRepair);
      expect(payload['tool_call_id'], 'call_9');
      expect(payload['text'], '内置那句', reason: '内置那句要递过去，插件才知道自己在改什么');
    });

    test('tool.repair：回 repaired=false / 回空 text ⇒ 一律用内置那句（不假装改过）', () async {
      final PluginBus bus = await startBus();
      takeOver(
        bus,
        StationHubIds.relayToolRepair,
        (StationRequest r) => <String, dynamic>{'repaired': false},
      );
      expect(
        await bus.relayToolRepairText(
          agentId: agent,
          sessionId: session,
          toolCallId: 'c',
          toolName: 'fs.read',
          text: '内置那句',
        ),
        isNull,
      );
    });

    test('tool.probe 三档分得开：有结果 / 肯定没有 / 没接管', () async {
      final PluginBus bus = await startBus();
      // ① 接管者交出结果原文
      takeOver(
        bus,
        StationHubIds.relayToolProbe,
        (StationRequest r) => <String, dynamic>{
          'found': true,
          'text': '插件那一侧的原始输出',
        },
      );
      final StationToolProbeVerdict? hit = await bus.relayToolProbe(
        agentId: agent,
        sessionId: session,
        toolCallId: 'call_1',
      );
      expect(hit, isNotNull, reason: '接管了就必须是"接管"，不能塌成 null');
      expect(hit!.found, isTrue);
      expect(hit.text, '插件那一侧的原始输出');

      // ② 接管者**肯定地**说没有：仍然是"接管"（found=false），调用方据此不再查库
      final PluginBus bus2 = await startBus();
      final List<StationRequest> seen = takeOver(
        bus2,
        StationHubIds.relayToolProbe,
        (StationRequest r) => <String, dynamic>{'found': false},
      );
      final StationToolProbeVerdict? none = await bus2.relayToolProbe(
        agentId: agent,
        sessionId: session,
        toolCallId: 'call_2',
      );
      expect(none, isNotNull, reason: '"肯定没有"与"没接管"是两个动作');
      expect(none!.found, isFalse);
      expect(seen, hasLength(1));

      // ③ 回包里根本没有布尔 found ⇒ 按未接管（null），绝不当成"没有"
      final PluginBus bus3 = await startBus();
      takeOver(
        bus3,
        StationHubIds.relayToolProbe,
        (StationRequest r) => <String, dynamic>{'found': 'yes'},
      );
      expect(
        await bus3.relayToolProbe(
          agentId: agent,
          sessionId: session,
          toolCallId: 'call_3',
        ),
        isNull,
      );
      expect(
        logs.any((String l) => l.contains('按未接管走内置探针')),
        isTrue,
        reason: '$logs',
      );
    });
  });

  group('llm.register / compact.skip.reason', () {
    test('llm.register：登记通告带 handle / model / turn，回 note 只进日志', () async {
      final PluginBus bus = await startBus();
      final List<StationRequest> seen = takeOver(
        bus,
        StationHubIds.relayLlmRegister,
        (StationRequest r) => <String, dynamic>{
          'accepted': true,
          'note': '网关侧计费会话 bill-77',
        },
      );
      bus.relayLlmRegisterNotice(
        handle: 'llm-42',
        agentId: agent,
        sessionId: session,
        model: 'deepseek-v4',
        turn: 3,
      );
      await pumpEventQueue();
      expect(seen, hasLength(1));
      final Map<String, dynamic> payload =
          seen.single.payload! as Map<String, dynamic>;
      expect(payload['handle'], 'llm-42');
      expect(payload['model'], 'deepseek-v4');
      expect(payload['turn'], 3);
      // 回执只进日志：不返回任何东西给调用方，也就没有任何东西能改写请求本身
      expect(
        logs.any((String l) => l.contains('bill-77')),
        isTrue,
        reason: '$logs',
      );
    });

    test('compact.skip.reason：插件那句覆盖账上那条，**分级位原样保留**', () async {
      final MemoryStore store = MemoryStore();
      final CoreSettings settings = CoreSettings();
      final List<String> pushed = <String>[];
      final CompactionService service =
          CompactionService(store: store, settings: settings, log: logs.add)
            ..relaySkipSink = (
              String agentId,
              String sessionId,
              String reason, {
              required bool hasSubscriber,
            }) => pushed.add('$reason|hasSub=$hasSubscriber');
      // 内置那句先记账（可读性不依赖插件）
      service.noteRelaySkip(agent, session, '插件回包非法', hasSubscriber: true);
      expect(service.relaySkipOf(agent, session)!.reason, '插件回包非法');
      // 插件补一句更准的
      service.annotateRelaySkip(
        agent,
        session,
        'covered_message_count 越界（插件侧原因）',
      );
      final ({String reason, bool hasSubscriber})? now = service.relaySkipOf(
        agent,
        session,
      );
      expect(now!.reason, contains('越界'));
      expect(now.hasSubscriber, isTrue, reason: '分级位是核心的判据，插件改不了');
      // 已经推出去的那条通知**不回改**（历史与 REST 不能对不上）
      expect(pushed, hasLength(1));
      expect(pushed.single, contains('插件回包非法'));
    });

    test('compact.skip.reason：账上没有 ⇒ 不凭空造一条（结论已交付就作罢）', () {
      final CompactionService service = CompactionService(
        store: MemoryStore(),
        settings: CoreSettings(),
        log: logs.add,
      );
      service.annotateRelaySkip(agent, session, '插件补的那句');
      expect(service.relaySkipOf(agent, session), isNull);
      expect(logs.last, contains('不凭空造一条'));
      // 空文案一律不收（否则面板上会出现一句没内容的原因）
      service.noteRelaySkip(agent, session, '内置那句', hasSubscriber: false);
      service.annotateRelaySkip(agent, session, '   ');
      expect(service.relaySkipOf(agent, session)!.reason, '内置那句');
    });
  });

  group('plugin.capability.define', () {
    StationCollectedItem item(String pluginId, Map<String, dynamic> payload) =>
        StationCollectedItem(
          subscriber: StationSubscriber(
            pluginId: pluginId,
            scope: const StationScope(
              teamId: team,
              modeKey: StationModeKey.local,
            ),
            subscribedAt: 1,
          ),
          payload: payload,
        );

    Map<String, dynamic> okCap(String name, {Map<String, dynamic>? schema}) =>
        <String, dynamic>{
          'capability_id': name,
          'direction': 'push',
          'event': 'gateway.$name',
          'description': '网关侧的 $name 事件',
          'schema': schema ?? <String, dynamic>{'seq': 'int'},
        };

    test('合格申报登记上，命名空间化成 plugin.<id>.<点位>', () {
      final CapabilityAbsorption absorbed = absorbCapabilityRows(
        items: <StationCollectedItem>[
          item('alpha', <String, dynamic>{
            'capabilities': <Object>[okCap('audit'), okCap('bill')],
          }),
        ],
      );
      expect(absorbed.count, 2);
      expect(absorbed.notes, isEmpty);
      expect(
        absorbed.all.first.stationId,
        'plugin.alpha.audit',
        reason: '不加前缀就会有两个插件用同一个点位名互相顶掉',
      );
      expect(absorbed.all.first.toJson()['schema'], isNotNull);
    });

    test('缺 schema 的那一条被拒（只丢那一条，同插件其余照常登记）', () {
      final CapabilityAbsorption absorbed = absorbCapabilityRows(
        items: <StationCollectedItem>[
          item('alpha', <String, dynamic>{
            'capabilities': <Object>[
              okCap('audit'),
              okCap('nobody', schema: <String, dynamic>{}),
            ],
          }),
        ],
      );
      expect(absorbed.count, 1);
      expect(absorbed.notes, hasLength(1));
      expect(absorbed.notes.single, contains('没有字段表'));
      expect(absorbed.notes.single, contains('nobody'));
    });

    test('方向非法 / 缺事件名 / 重复申报：各丢那一条并写清原因', () {
      final CapabilityAbsorption absorbed = absorbCapabilityRows(
        items: <StationCollectedItem>[
          item('alpha', <String, dynamic>{
            'capabilities': <Object>[
              <String, dynamic>{...okCap('weird'), 'direction': 'maybe'},
              <String, dynamic>{...okCap('noevent'), 'event': ''},
              okCap('dup'),
              okCap('dup'),
            ],
          }),
        ],
      );
      expect(absorbed.count, 1, reason: '只有第一条 dup 留下');
      expect(absorbed.notes, hasLength(3));
      expect(absorbed.notes.join('\n'), contains('direction="maybe"'));
      expect(absorbed.notes.join('\n'), contains('缺事件名'));
      expect(absorbed.notes.join('\n'), contains('只留第一条'));
    });

    test('未响应者显式列出（不静默，也不影响别人那一份）', () {
      final CapabilityAbsorption absorbed = absorbCapabilityRows(
        items: <StationCollectedItem>[
          item('alpha', <String, dynamic>{
            'capabilities': <Object>[okCap('audit')],
          }),
        ],
        unresponsive: <StationUnresponsive>[
          StationUnresponsive(
            subscriber: StationSubscriber(
              pluginId: 'beta',
              scope: const StationScope(
                teamId: team,
                modeKey: StationModeKey.local,
              ),
              subscribedAt: 1,
            ),
            reason: '心跳丢失',
          ),
        ],
      );
      expect(absorbed.count, 1);
      expect(absorbed.byPlugin.containsKey('beta'), isFalse);
      expect(absorbed.notes.single, contains('beta'));
      expect(absorbed.notes.single, contains('心跳丢失'));
    });

    test('收集站由接入点现建（不预建），schema 就是输入格式且非空', () async {
      // 拿一个**干净的站点中枢**验预建那一格：总线一 start() 就会刷一次工具表，
      // 而刷工具表正是收集站的接入点（它会把两个收集站都现建出来）。
      final StationHub hub = StationHub(
        storePath: p.join(temp.path, 'stations-fresh.yaml'),
      );
      expect(hub.ensureBuiltinStations(), hasLength(33));
      expect(
        hub.station(StationHubIds.collectCapability),
        isNull,
        reason: '收集站不预建（schema 由接入点决定）',
      );
      expect(hub.station(StationHubIds.collect), isNull);
      final CollectStation? station = hub.capabilityDefineStationFor();
      expect(station, isNotNull);
      expect(station!.schema.fields, isNotEmpty);
      expect(
        station.schema.fields.map((StationSchemaField f) => f.name),
        contains('capabilities'),
      );

      // 总线侧：插件没起来 ⇒ 采集拿不到东西，申报读数就是**空表**（不是 null：
      // 面板要能区分“没人申报”与“没这块”）。
      final PluginBus bus = await startBus();
      expect(bus.capabilityDeclarations(), isEmpty);
      expect(bus.capabilitySkipNotes, isEmpty);
    });

    test('总开关关闭：点位申报表跟着清空（留着就是假的在册）', () async {
      final PluginBus bus = await startBus(enabled: false);
      final ToolDefinitionRefresh refresh = await bus.refreshToolDefinitions();
      expect(refresh.registered, isEmpty);
      expect(bus.capabilityDeclarations(), isEmpty);
    });
  });
}
