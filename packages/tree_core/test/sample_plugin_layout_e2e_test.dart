import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_protocol/tree_protocol.dart';

import 'ws_harness.dart';

/// 可控引擎：只产出一次工具调用（不模拟任何时间）。
class _ToolEngine implements AgentEngine {
  _ToolEngine(this.events);

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

/// **示例插件的可见性契约**（真 Python 插件 + 真插件总线，端到端）。
///
/// 为什么单独一个文件：示例插件是用户的"第一个插件"，它一旦"看起来没生效"，
/// 现象全是**静默**的（面板停在 0、卡片不出现、没有任何报错），排查成本极高。
/// 这里把最容易踩的三条边界钉死：
///
/// 1. **声明了 team** ⇒ 站点订阅按该 team 成立 + `ui/manifest` 必须先申报 card 槽位
///    （`ui.push` 只发 update 帧、不建槽位；前端注册表要求槽位先存在，否则整条
///    update 被静默忽略——卡片永远不出现）；
/// 2. **没声明 team**（`scope: {}`，即界面上开内置插件后的默认形态）⇒ 订阅成立但
///    退化为**通配**：空 team = 作用于所有 team、空 mode = local / ssh 都收；
///    卡片与中转拦截因此**开箱即用**，不需要用户先手改 plugins.yaml；
/// 3. **`agent.tool_call` 事件与 team 声明无关**（scope 里没限定的维度不设条件）
///    ——轮次计数一直在工作，界面上看不到的原因只会是"可见通路被拒"。
void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_sample_layout_');
  });

  tearDown(() async {
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        // Windows 上文件句柄可能还没释放，稍后重试
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  /// 示例插件脚本（测试的工作目录是 packages/tree_core ⇒ 往上两层才是仓根）。
  String sampleScript() => p.normalize(
    p.join(
      Directory.current.path,
      '..',
      '..',
      'examples',
      'plugins',
      'sample_plugin.py',
    ),
  );

  String slash(String path) => path.replaceAll(Platform.pathSeparator, '/');

  String configYaml(String scopeLine) =>
      'enabled: true\n'
      'plugins:\n'
      '  - id: sample\n'
      '    name: 示例插件\n'
      '    command: "${Platform.isWindows ? 'python' : 'python3'}"\n'
      '    args: ["${slash(sampleScript())}"]\n'
      '    granularity: team\n'
      '    $scopeLine\n';

  Future<({PluginBus bus, List<Map<String, dynamic>> frames})> start(
    String scopeLine,
  ) async {
    final File config = File(p.join(temp.path, 'config', 'plugins.yaml'));
    config.createSync(recursive: true);
    config.writeAsStringSync(configYaml(scopeLine));
    final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
    final PluginBus bus = PluginBus(
      configFile: config.path,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
      broadcast: frames.add,
    );
    addTearDown(bus.close);
    await bus.start();
    return (bus: bus, frames: frames);
  }

  /// 等某类帧出现（真插件进程启动 + 握手 + 申报，最多 20s）。
  Future<Map<String, dynamic>?> waitForFrame(
    List<Map<String, dynamic>> frames,
    bool Function(Map<String, dynamic> frame) match,
  ) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      for (final Map<String, dynamic> frame in frames) {
        if (match(frame)) return frame;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
  }

  Map<String, dynamic>? manifestFrame(List<Map<String, dynamic>> frames) {
    for (final Map<String, dynamic> frame in frames) {
      if (frame['type'] == PluginUiFrameType.manifest) return frame;
    }
    return null;
  }

  test('声明了 team：站点订阅成立，且 card 槽位在 ui.push 之前先申报', () async {
    final String script = sampleScript();
    if (!File(script).existsSync()) {
      markTestSkipped('示例插件不在预期路径：$script');
      return;
    }

    final ({PluginBus bus, List<Map<String, dynamic>> frames}) started =
        await start('scope: {team_id: team-1}');

    // ① 工具照旧申报（模型能看到 plugin__sample__echo / rounds / read_probe）
    final Map<String, dynamic>? manifest = await waitForFrame(
      started.frames,
      (Map<String, dynamic> f) => f['type'] == PluginUiFrameType.manifest,
    ) ?? manifestFrame(started.frames);
    expect(
      manifest,
      isNotNull,
      reason: '插件必须声明槽位（否则面板与卡片都无处可挂）',
    );
    expect(
      started.bus
          .toolTable()
          .map((({String pluginId, PluginToolInfo tool}) e) => e.tool.name),
      contains('echo'),
      reason: 'tools/list 或收集站申报的工具必须在工具表里',
    );

    // ② ui/manifest 必须申报消息流 card 槽位，且 slot_key 与 ui.push 的目标一致
    final PluginUiManifest parsed = PluginUiManifest.fromFrame(manifest!)!;
    expect(parsed.teamId, 'team-1', reason: 'team 取 plugins.yaml 的声明');
    final Iterable<PluginUiSlot> cards = parsed.slots.where(
      (PluginUiSlot s) => s.kind == PluginUiSlotKind.card,
    );
    expect(
      cards.map((PluginUiSlot s) => s.slotKey),
      contains('sample.card.tool_rounds'),
      reason:
          'ui.push 只发 update、不建槽位：card 槽位必须先在 manifest 里申报，'
          '否则前端注册表忽略整条 update（卡片永远不出现且无报错）',
    );

    // ③ ui.push 真的把 update 帧推出来，且**晚于**申报（顺序即契约）
    final Map<String, dynamic>? cardUpdate = await waitForFrame(
      started.frames,
      (Map<String, dynamic> f) =>
          f['type'] == PluginUiFrameType.update &&
          ((f['data'] as Map?)?['slot_key']) == 'sample.card.tool_rounds',
    );
    expect(cardUpdate, isNotNull, reason: '启动时应推一次计数卡片');
    expect(
      started.frames.indexOf(manifest),
      lessThan(started.frames.indexOf(cardUpdate!)),
      reason: '必须"先 manifest 后 update"',
    );

    // ④ 中转站订阅成立（声明了 team 才进得了站点体系）。
    //    点位化：插件写 `station: 'relay'`（不带 point）= 一次订**工具前 + 工具后
    //    两个点位**（点位化之前是一个实例收两段）——两处都必须订上，
    //    否则"工具调用前后各一次拦截"就少了一半。
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
    StationInstance? relayPre;
    StationInstance? relayPost;
    while (DateTime.now().isBefore(deadline)) {
      relayPre = started.bus.stations.station(StationHubIds.relayToolPre);
      relayPost = started.bus.stations.station(StationHubIds.relayToolPost);
      if ((relayPre?.subscribers.isNotEmpty ?? false) &&
          (relayPost?.subscribers.isNotEmpty ?? false)) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(
      relayPre?.subscribers.map((StationSubscriber s) => s.pluginId),
      contains('sample'),
      reason: '声明 team 后「工具调用前」点位订阅必须成立',
    );
    expect(
      relayPost?.subscribers.map((StationSubscriber s) => s.pluginId),
      contains('sample'),
      reason: '声明 team 后「工具调用后」点位订阅同样成立（两个点位一起订）',
    );
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('没声明 team（scope: {}）：订阅落成通配（所有 team），事件照收', () async {
    final String script = sampleScript();
    if (!File(script).existsSync()) {
      markTestSkipped('示例插件不在预期路径：$script');
      return;
    }

    final ({PluginBus bus, List<Map<String, dynamic>> frames}) started =
        await start('scope: {}');
    // 等插件就绪（有工具表内容即说明握过手了）
    final DateTime ready = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(ready) && started.bus.toolTable().isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(started.bus.toolTable(), isNotEmpty, reason: '工具走 tools/list 路径仍然可用');

    // 站点订阅：**空 scope = 通配**（用户定稿：为空默认作用于所有 team），
    // 所以启动时就能订上中转站的两个工具点位，且订阅 scope 的 team / mode 都为空
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
    StationSubscriber? sample;
    while (DateTime.now().isBefore(deadline)) {
      for (final String pointId in <String>[
        StationHubIds.relayToolPre,
        StationHubIds.relayToolPost,
      ]) {
        final StationInstance? relay = started.bus.stations.station(pointId);
        for (final StationSubscriber sub
            in relay?.subscribers ?? const <StationSubscriber>[]) {
          if (sub.pluginId == 'sample') sample = sub;
        }
      }
      if (sample != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(sample, isNotNull, reason: '空 scope 是合法订阅声明：不再 fail-closed 拒绝');
    expect(sample!.scope.teamIsWildcard, isTrue, reason: '空 team = 所有 team');
    expect(sample.scope.modeIsWildcard, isTrue, reason: '空 mode = local / ssh 都收');
    expect(
      started.bus.stations
          .station(StationHubIds.relayToolPost)
          ?.subscribers
          .map((StationSubscriber s) => s.pluginId),
      contains('sample'),
      reason: '一次 relay 订阅落在两个工具点位上（工具前 + 工具后）',
    );

    // 事件：scope 里没限定的维度不设条件 ⇒ 照收（计数与 team 声明无关）
    expect(
      started.bus.dispatchAgentEvent(<String, dynamic>{
        'event': 'agent.tool_call',
        'agent_id': 'agt_demo',
        'session_id': 'ses_demo',
        'team_id': 'team-1',
        'tool': 'read',
        'call_id': 'call-1',
        'round': 1,
        'phase': 'start',
      }),
      1,
      reason: 'scope: {} 的插件收全部事件——轮次计数一直在工作',
    );
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('没声明 team（scope: {}）：卡片与中转拦截开箱即用（无需手改配置）', () async {
    final String script = sampleScript();
    if (!File(script).existsSync()) {
      markTestSkipped('示例插件不在预期路径：$script');
      return;
    }

    // 空 scope = 内置项在界面上开关后的默认形态：**应当开箱即用**。
    final ({PluginBus bus, List<Map<String, dynamic>> frames}) started =
        await start('scope: {}');
    final CoreServer server = await CoreServer.start(
      streamChunkDelay: Duration.zero,
      enableHeartbeat: false,
      pluginBus: started.bus,
      engine: _ToolEngine(<AgentEvent>[
        AgentToolStart(
          id: 'tool_a',
          callId: 'call_a',
          name: 'read',
          arguments: const <String, dynamic>{'file_path': 'a.txt'},
        ),
        const AgentToolEnd(id: 'tool_a', name: 'read', result: 'A 的内容'),
        const AgentDone(finishReason: 'stop'),
      ]),
    );
    addTearDown(server.close);
    server.conversation.agentEvents.sink = started.bus.dispatchAgentEvent;

    // 顶层 agent（team_id 为空，自成一队）：作用域只能由核心按 agent 解析出来
    final String agentId = server.store.createAgent(name: '空 scope 用例').id;
    expect(server.store.agent(agentId)!.teamId, isEmpty);

    final TestWs ws = await TestWs.connect(server);
    addTearDown(ws.close);
    ws.record();
    ws.send(<String, dynamic>{
      'type': WsInboundType.userMessage,
      'agent_id': agentId,
      'content': '跑一个工具',
      'session_id': TreeStore.defaultSessionId,
    });
    await waitIdle(ws);

    // ① 卡片真的推出来了（走 ui.push → plugin_ui_update 帧）。
    //    注意这里**不是**靠"事件里学到的 agent 身份"救回来的：空 scope 本身就是
    //    合法声明（空 team = 所有 team），启动那次 ui.push 就该成功。
    final Map<String, dynamic>? cardUpdate = await waitForFrame(
      started.frames,
      (Map<String, dynamic> f) =>
          f['type'] == PluginUiFrameType.update &&
          ((f['data'] as Map?)?['slot_key']) == 'sample.card.tool_rounds',
    );
    expect(
      cardUpdate,
      isNotNull,
      reason: '空 scope 开箱即用：卡片不依赖用户先手改 plugins.yaml',
    );
    expect(
      ((cardUpdate!['data'] as Map)['team_id'] ?? 'x'),
      '',
      reason: '通配卡片的 team 为空 = 前端在任何 team 下都呈现',
    );

    // ② 中转站订阅在**启动时**就成立（不是靠懒订阅补的）：两个工具点位都有
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
    Iterable<String> subscribers = const <String>[];
    while (DateTime.now().isBefore(deadline)) {
      subscribers = <String>[
        for (final String pointId in <String>[
          StationHubIds.relayToolPre,
          StationHubIds.relayToolPost,
        ])
          ...(started.bus.stations.station(pointId)?.subscribers ??
                  const <StationSubscriber>[])
              .map((StationSubscriber s) => s.pluginId),
      ];
      if (subscribers.contains('sample')) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(
      subscribers,
      contains('sample'),
      reason: '空 scope 的通配订阅让中转拦截也开箱即用（不必等第一个事件）',
    );
  }, timeout: const Timeout(Duration(seconds: 120)));
}
