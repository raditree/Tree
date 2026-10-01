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
    bus.callSiteContext = (String agentId, String sessionId) =>
        StationScopeContext(
          teamId: agentId == agent ? team : '',
          agentId: agentId,
          sessionId: sessionId,
        );
    bus.agentModeKeyResolver = (String agentId) =>
        agentId == agent ? StationModeKey.local : '';
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
