import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// **工具调用的广播站点位**（`system.broadcast.tool.pre` / `.tool.post`）与
/// **插件发起的工具调用**（`WorkspaceToolRunner.runFromPlugin`）。
///
/// 用户定稿语义（`docs/plugin-development.md` §7.1 / §6.3）：
/// - 每次工具调用**前 / 后各广播一条**（单向通知），payload 里带齐
///   `phase` / `tool` / `call_id` / `round` / `origin` / `arguments`（post 还有
///   `result` / `is_error`）；
/// - **不等回包**：`publish()` 会对每个订阅者 `awaitReply`，工具调用却绝不能因此被拖慢
///   ——所以这里用「订阅者心跳在、但永不回包」的假订阅者把这条红线钉住；
/// - 插件经执行站发起的调用（`runFromPlugin`）**默认绕开**中转与广播（防自锁），
///   显式 `relay: true` 才触发（`origin: plugin` + `source_plugin_id`）。
///
/// 假订阅者是**进程内闭包**（站点是纯数据面），工具执行走真 `WorkspaceToolRunner`
/// + 真工作空间 IO。
void main() {
  late Directory temp;
  late String workspace;
  late PluginBus bus;
  late List<String> logs;

  const String team = 'team-1';
  const String agent = 'agt_1';
  const String session = 'sess-1';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_tool_broadcast_');
    workspace = p.join(temp.path, 'ws');
    Directory(workspace).createSync(recursive: true);
    logs = <String>[];
    final File file = File(p.join(temp.path, 'config', 'plugins.yaml'));
    file.createSync(recursive: true);
    file.writeAsStringSync('enabled: true\nplugins: []\n');
    bus = PluginBus(configFile: file.path, log: logs.add);
    addTearDown(bus.close);
    // 复刻生产接线：team / mode 按 agent 真实归属（站点消息必须有可证明的归属）
    // 站点四元组按 agent 真实归属：临时员工（sub_…）与它的会话主人同队同模式
    // （生产里 team 来自它持久化配置里的 team_id，见 SubagentService._buildAgent）。
    bus.callSiteContext = (String agentId, String sessionId) =>
        StationScopeContext(
          teamId: agentId == agent || agentId.startsWith('sub_') ? team : '',
          agentId: agentId,
          sessionId: sessionId,
        );
    bus.agentModeKeyResolver = (String agentId) =>
        agentId == agent || agentId.startsWith('sub_') ? StationModeKey.local : '';
    // 进程内假订阅者不在总线实例表里：这里统一声明"心跳在"，
    // 让"永不回包"那条用例测的是**核心不等回包**，而不是"订阅者被判死"。
    bus.stations.livenessProbe = (String pluginId) =>
        const StationLivenessState.alive();
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

  Future<void> waitUntil(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 10),
    String description = '条件',
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail(
      '等待「$description」超时（${timeout.inMilliseconds}ms）；日志：${logs.join(' | ')}',
    );
  }

  /// 订阅一个点位，把收到的请求 payload 收进 [sink]（回空包 = 不改动）。
  void subscribe(
    String stationId,
    String pluginId,
    List<Map<String, dynamic>> sink, {
    Object? reply,
  }) {
    expect(
      bus.stations.pointFor(stationId),
      isNotNull,
      reason: '点位 $stationId 必须存在（内置点位懒创建）',
    );
    final StationSubResult result = bus.stations.subscribe(
      stationId,
      StationSubscriber(
        pluginId: pluginId,
        scope: const StationScope(teamId: team),
      ),
      (StationRequest request) async {
        sink.add(_asMap(request.payload));
        return StationReply.ok(reply);
      },
    );
    expect(result.ok, isTrue, reason: '订阅 $stationId 失败：${result.error}');
  }

  /// 订阅一个点位，但**永不回包**（返回的 completer 由用例显式放行）。
  Completer<StationReply> subscribeSilent(
    String stationId,
    String pluginId,
    List<Map<String, dynamic>> sink,
  ) {
    expect(
      bus.stations.pointFor(stationId),
      isNotNull,
      reason: '点位 $stationId 必须存在（内置点位懒创建）',
    );
    final Completer<StationReply> gate = Completer<StationReply>();
    final StationSubResult result = bus.stations.subscribe(
      stationId,
      StationSubscriber(
        pluginId: pluginId,
        scope: const StationScope(teamId: team),
      ),
      (StationRequest request) {
        sink.add(_asMap(request.payload));
        return gate.future; // 心跳在（见 setUp 的探针），但就是不回
      },
    );
    expect(result.ok, isTrue, reason: '订阅 $stationId 失败：${result.error}');
    return gate;
  }

  WorkspaceToolRunner runner() {
    final WorkspaceToolRunner built = WorkspaceToolRunner(
      resolveWorkspaceDir: (String agentId) => workspace,
      pluginBus: bus,
      log: logs.add,
    );
    addTearDown(built.close);
    return built;
  }

  ToolInvocation writeInvocation(String content, {String id = 'tool-1'}) =>
      ToolInvocation(
        id: id,
        name: 'write',
        arguments: <String, dynamic>{
          'file_path': 'notes/a.txt',
          'content': content,
        },
        agentId: agent,
        sessionId: session,
      );

  String written() =>
      File(p.join(workspace, 'notes', 'a.txt')).readAsStringSync();

  /// 组装"临时员工在场"的工具层：真 MemoryStore + 名册 + 装饰器 + 服务。
  ///
  /// [inner] = 服务跑一轮时执行的"临时员工内部工具调用"（null = 内部啥也不干），
  /// 用它证明**子 agent 自己的工具调用同样走三站**。
  ({
    WorkspaceToolRunner runner,
    SubagentService service,
    CoreAgent owner,
    String subagentId,
  })
  subagentRig(
    List<Map<String, dynamic>> pre,
    List<Map<String, dynamic>> post, {
    ToolInvocation? internalCall,
  }) {
    final MemoryStore inner = MemoryStore();
    final SubagentRegistry registry = SubagentRegistry(persistence: inner);
    final SubagentStore store = SubagentStore(inner: inner, registry: registry);
    final CoreSettings settings = CoreSettings()
      ..putModel(CoreModelConfig(modelId: 'demo'));
    final int now = DateTime.now().millisecondsSinceEpoch;
    final CoreAgent owner = CoreAgent(
      id: agent,
      name: 'leader',
      modelId: 'demo',
      teamId: '',
      createdAt: now,
      updatedAt: now,
    );
    store.putAgent(owner);
    final String subagentId = 'sub_test1';
    registry.put(
      CoreSubagent(
        id: subagentId,
        name: '临时员工',
        ownerAgentId: agent,
        sessionId: session,
        parentId: agent,
        level: 1,
        agent: CoreAgent(
          id: subagentId,
          name: '临时员工',
          modelId: 'demo',
          teamId: agent,
          parentAgentId: agent,
          level: 1,
          reviewStatus: ReviewStatus.approved,
          createdAt: now,
          updatedAt: now,
        ),
        createdAt: now,
        updatedAt: now,
      ),
    );
    final SubagentService service = SubagentService(
      store: store,
      registry: registry,
      settings: settings,
    );
    late WorkspaceToolRunner runner;
    service.runner = (SubagentTurnRequest request) async {
      if (internalCall != null) {
        // 它自己的一次工具调用：走**同一个** runner（同一份中转/广播）
        final ToolOutcome inner = await runner.run(
          ToolInvocation(
            id: internalCall.id,
            name: internalCall.name,
            arguments: internalCall.arguments,
            agentId: request.tag.id,
            sessionId: request.sessionId,
          ),
        );
        return SubagentTurnResult(report: '报告：${request.task}（内部=${inner.isError}）');
      }
      return SubagentTurnResult(report: '报告：${request.task}');
    };
    runner = WorkspaceToolRunner(
      resolveWorkspaceDir: (String agentId) => workspace,
      pluginBus: bus,
      subagentService: service,
      log: logs.add,
    );
    addTearDown(runner.close);
    return (runner: runner, service: service, owner: owner, subagentId: subagentId);
  }

  test('广播：subagent 调用 pre / post 各一条；它内部的工具调用同样各一条（轮次不串号）', () async {
    final List<Map<String, dynamic>> pre = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> post = <Map<String, dynamic>>[];
    subscribe(StationHubIds.broadcastToolPre, 'probe-pre', pre);
    subscribe(StationHubIds.broadcastToolPost, 'probe-post', post);

    final rig = subagentRig(
      pre,
      post,
      internalCall: ToolInvocation(
        id: 'inner-1',
        name: 'write',
        arguments: <String, dynamic>{
          'file_path': 'notes/sub.txt',
          'content': '临时员工写的',
        },
        agentId: 'ignored',
        sessionId: 'ignored',
      ),
    );

    final ToolOutcome outcome = await rig.runner
        .run(
          ToolInvocation(
            id: 'tool-sub',
            name: 'subagent',
            arguments: <String, dynamic>{
              'task': '写一个文件',
              'name': '写字员',
              'subagent_id': rig.subagentId,
            },
            agentId: rig.owner.id,
            sessionId: session,
          ),
        )
        .timeout(const Duration(seconds: 15));
    expect(outcome.isError, isFalse, reason: outcome.content);
    // 内层真的执行了（子 agent 的工具调用没有被吞掉）
    expect(
      File(p.join(workspace, 'notes', 'sub.txt')).readAsStringSync(),
      '临时员工写的',
    );

    await waitUntil(
      () => pre.length == 2 && post.length == 2,
      description: '外层 subagent + 内层 write 各 pre/post 一条',
    );
    final Map<String, dynamic> outerPre = pre.firstWhere(
      (Map<String, dynamic> p) => p['tool'] == 'subagent',
    );
    final Map<String, dynamic> outerPost = post.firstWhere(
      (Map<String, dynamic> p) => p['tool'] == 'subagent',
    );
    final Map<String, dynamic> innerPre = pre.firstWhere(
      (Map<String, dynamic> p) => p['tool'] == 'write',
    );
    final Map<String, dynamic> innerPost = post.firstWhere(
      (Map<String, dynamic> p) => p['tool'] == 'write',
    );

    // 本站点：pre / post 各一条，载荷与普通工具一致
    for (final Map<String, dynamic> payload in <Map<String, dynamic>>[
      outerPre,
      innerPost,
    ]) {
      expect(payload['origin'], 'agent');
      expect(payload['agent_id'], isNotEmpty);
      expect(payload['session_id'], session);
      expect(payload['call_id'], isNotEmpty);
    }
    expect(outerPre['point'], StationHubIds.broadcastToolPre);
    expect(outerPre['phase'], 'pre');
    expect(outerPre['tool'], 'subagent');
    expect(outerPre['arguments'], <String, dynamic>{
      'task': '写一个文件',
      'name': '写字员',
      'subagent_id': rig.subagentId,
    });
    expect(outerPost['point'], StationHubIds.broadcastToolPost);
    expect(outerPost['result'], outcome.content);
    expect(innerPre['arguments'], <String, dynamic>{
      'file_path': 'notes/sub.txt',
      'content': '临时员工写的',
    });
    expect(innerPost['point'], StationHubIds.broadcastToolPost);
    // 轮次按**调用**分配：父调用与它内部那次调用不串号（同名工具并行也不串）
    expect(
      outerPre['round'],
      outerPost['round'],
      reason: 'pre / post 必须同轮次（否则插件配不上对）',
    );
    expect(innerPre['round'], innerPost['round']);
    expect(
      outerPre['round'],
      isNot(innerPre['round']),
      reason: '嵌套调用各有各的轮次序号',
    );
  });

  test('执行站 tool.call 传 subagent：默认绕开站点，relay: true 触发（与普通工具同语义）', () async {
    final List<Map<String, dynamic>> pre = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> post = <Map<String, dynamic>>[];
    subscribe(StationHubIds.broadcastToolPre, 'probe-pre', pre);
    subscribe(StationHubIds.broadcastToolPost, 'probe-post', post);
    final rig = subagentRig(pre, post);

    ToolInvocation call(String id) => ToolInvocation(
      id: id,
      name: 'subagent',
      arguments: <String, dynamic>{'task': '插件派下来的活'},
      agentId: rig.owner.id,
      sessionId: session,
    );

    // ① 默认 relay=false：**绕开**中转与广播（防自锁），但工具照常执行
    final ToolOutcome quiet = await rig.runner
        .runFromPlugin(call('plugin-1'), sourcePluginId: 'plugin-1')
        .timeout(const Duration(seconds: 15));
    expect(quiet.isError, isFalse, reason: quiet.content);
    expect(quiet.content, contains('报告：插件派下来的活'));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(pre, isEmpty, reason: '默认绕开广播：不该有条目');
    expect(post, isEmpty);

    // ② relay=true：与普通工具逐字同语义——pre / post 各一条，origin=plugin
    final ToolOutcome relayed = await rig.runner
        .runFromPlugin(call('plugin-2'), sourcePluginId: 'plugin-1', relay: true)
        .timeout(const Duration(seconds: 15));
    expect(relayed.isError, isFalse, reason: relayed.content);
    await waitUntil(
      () => pre.length == 1 && post.length == 1,
      description: '插件发起的 subagent 调用也广播 pre / post',
    );
    expect(pre.single['tool'], 'subagent');
    expect(pre.single['origin'], 'plugin');
    expect(post.single['point'], StationHubIds.broadcastToolPost);
    expect(post.single['round'], pre.single['round']);
  });

  test('广播：一次真实工具调用 ⇒ pre / post 各一条，payload 字段齐全（origin=agent）', () async {
    final List<Map<String, dynamic>> pre = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> post = <Map<String, dynamic>>[];
    subscribe(StationHubIds.broadcastToolPre, 'probe-pre', pre);
    subscribe(StationHubIds.broadcastToolPost, 'probe-post', post);

    final ToolOutcome outcome = await runner()
        .run(writeInvocation('广播内容'))
        .timeout(const Duration(seconds: 10));
    expect(outcome.isError, isFalse, reason: outcome.content);
    expect(written(), '广播内容');

    await waitUntil(
      () => pre.length == 1 && post.length == 1,
      description: 'pre / post 广播各一条',
    );

    final Map<String, dynamic> prePayload = pre.single;
    expect(prePayload['point'], StationHubIds.broadcastToolPre);
    expect(prePayload['phase'], 'pre');
    expect(prePayload['tool'], 'write');
    expect(prePayload['call_id'], 'tool-1');
    expect(prePayload['round'], greaterThanOrEqualTo(1));
    expect(prePayload['origin'], 'agent', reason: '模型发起的调用 origin=agent');
    expect(prePayload['agent_id'], agent);
    expect(prePayload['session_id'], session);
    expect(prePayload['arguments'], <String, dynamic>{
      'file_path': 'notes/a.txt',
      'content': '广播内容',
    });
    expect(
      prePayload.containsKey('result'),
      isFalse,
      reason: 'pre 广播是"即将发生"：此时还没有结果',
    );

    final Map<String, dynamic> postPayload = post.single;
    expect(postPayload['point'], StationHubIds.broadcastToolPost);
    expect(postPayload['phase'], 'post');
    expect(postPayload['tool'], 'write');
    expect(postPayload['call_id'], 'tool-1');
    expect(
      postPayload['round'],
      prePayload['round'],
      reason: 'pre / post 必须同轮次（调用方靠它配对，串号就等于拼错历史）',
    );
    expect(postPayload['origin'], 'agent');
    expect(postPayload['arguments'], prePayload['arguments']);
    expect(postPayload['result'], outcome.content);
    expect(postPayload['is_error'], isFalse);
    expect(
      postPayload.containsKey('source_plugin_id'),
      isFalse,
      reason: '模型发起的调用没有来源插件',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('广播不等回包：订阅者心跳在但永不回包，工具调用仍在 1 秒内正常返回', () async {
    final List<Map<String, dynamic>> pre = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> post = <Map<String, dynamic>>[];
    final Completer<StationReply> preGate = subscribeSilent(
      StationHubIds.broadcastToolPre,
      'slow-pre',
      pre,
    );
    final Completer<StationReply> postGate = subscribeSilent(
      StationHubIds.broadcastToolPost,
      'slow-post',
      post,
    );

    final Stopwatch watch = Stopwatch()..start();
    final ToolOutcome outcome = await runner()
        .run(writeInvocation('等回包就会挂'))
        .timeout(const Duration(seconds: 5));
    watch.stop();

    expect(outcome.isError, isFalse, reason: outcome.content);
    expect(written(), '等回包就会挂');
    expect(
      watch.elapsedMilliseconds,
      lessThan(1000),
      reason:
          '广播是**单向通知**：订阅者永不回包也不得拖慢工具调用'
          '（实测 ${watch.elapsedMilliseconds}ms）',
    );

    await waitUntil(
      () => pre.length == 1 && post.length == 1,
      description: '广播已投出',
    );
    final BroadcastStation preStation = bus.stations.broadcastPointFor(
      StationHubIds.broadcastToolPre,
    )!;
    expect(
      preStation.waitsInFlight,
      greaterThanOrEqualTo(1),
      reason: '证据：核心确实在等这个回包（waits_in_flight>0），只是没让工具调用等它',
    );

    // 放行等待（避免留下永远不完成的投递）
    preGate.complete(const StationReply.ok());
    postGate.complete(const StationReply.ok());
    await waitUntil(() => preStation.waitsInFlight == 0, description: '等待归零');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test(
    'runFromPlugin：默认绕开中转与广播；relay:true 才触发（origin=plugin + source_plugin_id）',
    () async {
      final List<Map<String, dynamic>> pre = <Map<String, dynamic>>[];
      final List<Map<String, dynamic>> post = <Map<String, dynamic>>[];
      final List<Map<String, dynamic>> relayPre = <Map<String, dynamic>>[];
      final List<Map<String, dynamic>> relayPost = <Map<String, dynamic>>[];
      subscribe(StationHubIds.broadcastToolPre, 'probe-pre', pre);
      subscribe(StationHubIds.broadcastToolPost, 'probe-post', post);
      subscribe(StationHubIds.relayToolPre, 'relay-pre', relayPre);
      subscribe(StationHubIds.relayToolPost, 'relay-post', relayPost);
      final WorkspaceToolRunner toolRunner = runner();

      // ① 默认（relay: false）：插件自己的调用**不进**站点（否则它既是 tool.call 的
      //    发起方、又是 tool.pre 的唯一订阅者，单线程插件会自锁）
      final ToolOutcome direct = await toolRunner
          .runFromPlugin(
            writeInvocation('插件直连', id: 'call-plugin-1'),
            sourcePluginId: 'sample',
          )
          .timeout(const Duration(seconds: 10));
      expect(direct.isError, isFalse, reason: direct.content);
      expect(written(), '插件直连');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(pre, isEmpty, reason: 'relay:false 不广播 pre');
      expect(post, isEmpty, reason: 'relay:false 不广播 post');
      expect(relayPre, isEmpty, reason: 'relay:false 不走工具中转（pre）');
      expect(relayPost, isEmpty, reason: 'relay:false 不走工具中转（post）');

      // ② 显式 relay: true：要审计自己的调用就打开（代价自负）
      final ToolOutcome relayed = await toolRunner
          .runFromPlugin(
            writeInvocation('插件审计', id: 'call-plugin-2'),
            sourcePluginId: 'sample',
            relay: true,
          )
          .timeout(const Duration(seconds: 10));
      expect(relayed.isError, isFalse, reason: relayed.content);
      expect(written(), '插件审计');
      await waitUntil(
        () =>
            pre.length == 1 &&
            post.length == 1 &&
            relayPre.length == 1 &&
            relayPost.length == 1,
        description: 'relay:true 触发广播与中转',
      );

      for (final Map<String, dynamic> payload in <Map<String, dynamic>>[
        pre.single,
        post.single,
      ]) {
        expect(payload['origin'], 'plugin', reason: '插件发起的调用 origin=plugin');
        expect(payload['source_plugin_id'], 'sample', reason: '审计要能看出是谁发起的');
        expect(payload['call_id'], 'call-plugin-2');
        expect(payload['agent_id'], agent);
        expect(payload['session_id'], session);
      }
      expect(post.single['result'], relayed.content);

      expect(relayPre.single['phase'], 'pre');
      expect(relayPre.single['tool'], 'write');
      expect(relayPre.single['call_id'], 'call-plugin-2');
      expect(relayPre.single['round'], greaterThanOrEqualTo(1));
      expect(relayPre.single['arguments'], <String, dynamic>{
        'file_path': 'notes/a.txt',
        'content': '插件审计',
      });
      expect(relayPost.single['phase'], 'post');
      expect(relayPost.single['call_id'], 'call-plugin-2');
      expect(relayPost.single['result'], relayed.content);
      expect(relayPost.single['is_error'], isFalse);
      // **中转 payload 与广播同口径**：也带 origin / source_plugin_id。
      // 否则一个"既订 tool.pre、又用 tool.call 审计自己"的插件在中转侧无法区分
      // 「模型发起的调用」与「插件发起的调用」，闭环审计就做不成。
      for (final Map<String, dynamic> payload in <Map<String, dynamic>>[
        relayPre.single,
        relayPost.single,
      ]) {
        expect(payload['origin'], 'plugin', reason: '中转侧也要能看出调用来源');
        expect(payload['source_plugin_id'], 'sample');
      }
      expect(relayPre.single['point'], StationHubIds.relayToolPre);
      expect(relayPost.single['point'], StationHubIds.relayToolPost);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('中转 payload：模型发起的调用 origin=agent 且不带 source_plugin_id', () async {
    final List<Map<String, dynamic>> relayPre = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> relayPost = <Map<String, dynamic>>[];
    subscribe(StationHubIds.relayToolPre, 'relay-pre', relayPre);
    subscribe(StationHubIds.relayToolPost, 'relay-post', relayPost);

    final ToolOutcome outcome = await runner()
        .run(writeInvocation('模型调用', id: 'call-agent-1'))
        .timeout(const Duration(seconds: 10));
    expect(outcome.isError, isFalse, reason: outcome.content);
    await waitUntil(
      () => relayPre.length == 1 && relayPost.length == 1,
      description: '中转 pre / post 各一条',
    );
    for (final Map<String, dynamic> payload in <Map<String, dynamic>>[
      relayPre.single,
      relayPost.single,
    ]) {
      expect(payload['origin'], 'agent');
      expect(
        payload.containsKey('source_plugin_id'),
        isFalse,
        reason: '模型发起的调用没有来源插件',
      );
      expect(payload['call_id'], 'call-agent-1');
      expect(payload['round'], greaterThanOrEqualTo(1));
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}

/// payload → 普通 Map（站点请求的 payload 是 dynamic）。
Map<String, dynamic> _asMap(Object? payload) => payload is Map
    ? payload.map((dynamic k, dynamic v) => MapEntry(k.toString(), v))
    : <String, dynamic>{'raw': payload};
