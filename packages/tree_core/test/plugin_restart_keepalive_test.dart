// **重启期保活**的端到端用例（20261015-hot-restart 阶段 2）。
//
// 命题只有一句话：**插件在热重启的那几百毫秒里，对外仍是"正常状态"**。
// 跑的是真插件进程 + 真中转站点位 + 真投递路径（`bus.relayToolCall` / `bus.callTool`），
// 结论全部来自核心侧的计数读数与插件自己的回包内容——不靠"看起来没掉一次"。
//
// 钉住的七件事：
// 1. 窗口里的站点请求**被暂存**（`queued` 看得见），ready 后**重放**并拿到插件的改写
//    （调用方拿到的是插件的回包，不是 fail-open 的原数据）；
// 2. 重启窗口里这个插件的**站点订阅不被注销**（保活的前提：订阅一没，请求连入队的
//    入口都没有）；
// 3. 窗口里的 `callTool` 不当场失败：等就绪再投，结果就是插件的答案（等的是**事件**
//    而不是时长）；
// 4. 重启**失败**时队列以可读原因收尾：调用方拿到放行原数据 + 日志里有那句原因
//    （不静默、也不挂着；不变量 6）；
// 5. 溢出走既有 fail-open：超出每插件上限的那条**立即**放行原数据，且写了可读原因；
// 6. 全程 `status` / `health` 不参与这件事（三个轴各管各的；见 plugin_status_compat_test）；
// 7. 窗口里**改了归属**（scope.team_id）⇒ 新一世重新申报时，上一世那条声明必须被
//    作废：中转站「全站只许一个处理者」会把它变成 key_conflict 拒绝，收集站会留下
//    一条还能投递给旧团队的声明 —— 两种都是隔离/功能问题，不是读数问题。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/src/plugin/plugin_lifecycle.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  late Directory temp;
  late String script;
  late List<String> logs;

  const String team = 'team-1';
  const String agent = 'agt_1';
  const String pluginId = 'relay';

  /// 调用点上下文的团队（用例可以改）：改 scope 那条用例靠它证明
  /// 「旧团队再也递不到这个插件，新团队能」。
  late String callTeam;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_restart_keepalive_');
    callTeam = team;
    script = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'fake_plugin.dart',
    );
    logs = <String>[];
    expect(File(script).existsSync(), isTrue, reason: '假插件脚本必须存在');
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

  String slash(String path) => path.replaceAll(Platform.pathSeparator, '/');

  /// 订阅中转站（工具前 / 工具后两个点位）、把 `text` 改写成 `REWRITTEN` 的插件。
  ///
  /// [args] 可以换成别的启动参数（对账看到 args 变了 ⇒ 断开并重新拉起）：
  /// “新一世注定就绪不了”的那些用例就靠它。
  String relayYaml({List<String>? args, String? teamId}) {
    final List<String> effective =
        args ??
        <String>[
          script,
          '--relay-subscribe',
          '--relay-rewrite',
          'REWRITTEN',
          '--relay-key',
          'text',
        ];
    final String argList = effective
        .map((String a) => '"${slash(a)}"')
        .join(', ');
    return 'enabled: true\n'
        'plugins:\n'
        '  - id: $pluginId\n'
        '    name: 中转插件\n'
        '    command: "${slash(Platform.resolvedExecutable)}"\n'
        '    args: [$argList]\n'
        '    granularity: team\n'
        '    scope: {team_id: ${teamId ?? team}, mode_key: local}\n';
  }

  Future<PluginBus> startBus({
    String? yaml,
    int maxPerPlugin = 32,
    Duration connectTimeout = const Duration(seconds: 5),
  }) async {
    final File file = File(p.join(temp.path, 'config', 'plugins.yaml'));
    file.createSync(recursive: true);
    file.writeAsStringSync(yaml ?? relayYaml());
    final PluginBus bus = PluginBus(
      configFile: file.path,
      coreVersion: 'test',
      // 心跳节拍拉长：本文件只关心重启窗口，不要让探活定时器插进来判失活
      //（"心跳丢了会不会被误杀"是 plugin_close_no_hard_timeout_test.dart 的题）。
      // 顺带把站点的活性窗口（I×N）撑到 90s：暂存的请求有足够时间等到 ready。
      heartbeatInterval: const Duration(seconds: 30),
      // 新一世拉不起来时不必等 20s（本文件有一例故意让它失败）
      connectTimeout: connectTimeout,
      restartBufferMaxPerPlugin: maxPerPlugin,
      log: logs.add,
    );
    addTearDown(bus.close);
    // 复刻生产接线（CoreServer._wirePluginStations）：team / mode 按 agent 真实归属。
    bus.callSiteContext = (String agentId, String sessionId) =>
        StationScopeContext(
          teamId: agentId == agent ? callTeam : '',
          agentId: agentId,
          sessionId: sessionId,
        );
    bus.agentModeKeyResolver = (String agentId) =>
        agentId == agent ? StationModeKey.local : '';
    await bus.start();
    return bus;
  }

  /// 等到中转站点位真的有了这个插件的订阅（插件起进程后主动 subscribe，有先后）。
  Future<void> waitSubscribed(PluginBus bus) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      final RelayStation? station =
          bus.stations.station(StationHubIds.relayToolPre) as RelayStation?;
      if (station != null &&
          station.subscribers.any(
            (StationSubscriber s) => s.pluginId == pluginId,
          )) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw StateError('插件没订上「工具调用前」点位；日志：${logs.join(' | ')}');
  }

  /// 等到进入「暂时不可用」的保活窗口（重启已经开始、新一世还没就绪）。
  Future<void> waitKeepaliveWindow(PluginBus bus) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (bus.lifecycleOf(pluginId).isTemporarilyUnavailable) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw StateError(
      '没等到保活窗口（生命周期一直是 ${bus.lifecycleOf(pluginId).wire}）；'
      '日志：${logs.join(' | ')}',
    );
  }

  Future<Map<String, dynamic>?> relay(
    PluginBus bus,
    String callId, {
    String text = 'ORIG',
  }) => bus.relayToolCall(
    phase: 'pre',
    tool: 'echo',
    callId: callId,
    round: 1,
    agentId: agent,
    sessionId: 'sess-1',
    arguments: <String, dynamic>{'text': text},
  );

  test('基线：就绪时的中转真的被插件改写（后面的暂存断言才有对照物）', () async {
    final PluginBus bus = await startBus();
    await waitSubscribed(bus);
    expect(bus.lifecycleOf(pluginId), PluginLifecycleState.ready);

    final Map<String, dynamic>? rewritten = await relay(bus, 'base-1');
    expect(rewritten, isNotNull, reason: '订阅者真的改写了');
    expect(
      ((rewritten!['arguments'] ?? const <String, dynamic>{})
          as Map<String, dynamic>)['text'],
      'REWRITTEN',
    );
    expect(bus.restartBufferReadings()['queued'], 0, reason: '没重启就不该有暂存');
  });

  test('重启窗口里的站点请求：暂存 ⇒ ready 后重放 ⇒ 调用方拿到插件的改写', () async {
    final PluginBus bus = await startBus();
    await waitSubscribed(bus);

    // ① 热重启开始（假插件不实现 suspend ⇒ 走冷启动续跑，但**窗口照样存在**：
    //    保活靠的是生命周期，不是"转储成功"这件事）
    final Future<PluginHotRestartResult> restarting = bus.hotRestart(pluginId);
    await waitKeepaliveWindow(bus);

    // ② 窗口里下一条站点请求：它不该失败，也不该当场放行原数据
    final Future<Map<String, dynamic>?> inWindow = relay(bus, 'win-1');
    final DateTime queueDeadline = DateTime.now().add(
      const Duration(seconds: 10),
    );
    while (DateTime.now().isBefore(queueDeadline) &&
        bus.restartBuffer.lengthOf(pluginId) == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      bus.restartBuffer.lengthOf(pluginId),
      1,
      reason: '请求必须真的进了暂存队列；日志：${logs.join(' | ')}',
    );
    expect(
      bus.restartBufferReadings()['queued'],
      1,
      reason: '水位读数与队列一致（面板读的就是它）',
    );
    // 保活的前提：窗口里这个插件的回包函数**还在**（注销了就轮不到暂存）
    final RelayStation station =
        bus.stations.station(StationHubIds.relayToolPre)! as RelayStation;
    expect(
      station.subscribers.where(
        (StationSubscriber s) => s.pluginId == pluginId,
      ),
      hasLength(1),
      reason: '重启窗口里不得退订（也不能多出一条）',
    );

    // ③ 重启完成 ⇒ ready ⇒ FIFO 重放
    final PluginHotRestartResult result = await restarting;
    expect(result.ok, isTrue, reason: result.reason);
    final Map<String, dynamic>? rewritten = await inWindow;
    expect(
      rewritten,
      isNotNull,
      reason: '调用方拿到的是插件的改写，不是 fail-open 的原数据；日志：${logs.join(' | ')}',
    );
    expect(
      ((rewritten!['arguments'] ?? const <String, dynamic>{})
          as Map<String, dynamic>)['text'],
      'REWRITTEN',
    );
    expect(rewritten['call_id'], 'win-1', reason: '回来的必须是那一条');

    final Map<String, dynamic> readings = bus.restartBufferReadings();
    expect(readings['queued'], 0, reason: '重放完队列必须归零（不留悬挂）');
    expect(readings['replayed'], 1);
    expect(readings['dropped'], 0);
    expect(readings['overflowed'], 0);
    expect(
      logs.any((String l) => l.contains('重放重启窗口里暂存的 1 条站点请求')),
      isTrue,
      reason: '重放这件事必须能被日志查到（不静默）',
    );
    // 新一世自己重新订上：同一个身份 = 幂等更新，不得留下两条订阅
    expect(
      station.subscribers.where(
        (StationSubscriber s) => s.pluginId == pluginId,
      ),
      hasLength(1),
      reason: '重启不得在站点上积出重复订阅（中转站只能有一个处理者）',
    );
    expect(bus.lifecycleOf(pluginId), PluginLifecycleState.ready);
  });

  test('重启**失败**：暂存的请求以可读原因收尾，押后的订阅注销补上（不悬着）', () async {
    // 失败从哪来：把盘上那一行的 args 换成一个“拉得起来、但永不握手”的脚本，再走对账
    //（_startOne 在 connectTimeout 后判失败）。为什么选这条路而不是注入 hostFactory：
    // 注入宿主拿不到 `onPluginRequest` 的生产接线（它在 _spawn 里建连时就接上），
    // 插件握手期间的 station/subscribe 会被拒 ⇒ 根本没有订阅可暂存。这里要钉的恰好
    // 是**生产那条路**；而“永不握手”而不是“执行器不存在”，是为了让重启窗口有
    // **确定的一段**可以往里投请求（否则瞬间就失败完了，断言只能靠运气）。
    // 另外：配置驱动的换一世也必须算“重启窗口”（否则它会直接退订，保活当场失效）。
    final File hang = File(p.join(temp.path, 'hang.dart'))
      ..writeAsStringSync('Future<void> main() => Future<void>.never();\n');
    final PluginBus bus = await startBus(
      connectTimeout: const Duration(seconds: 2),
    );
    await waitSubscribed(bus);
    final RelayStation station =
        bus.stations.station(StationHubIds.relayToolPre)! as RelayStation;
    expect(station.subscribers, hasLength(1));

    final File file = File(p.join(temp.path, 'config', 'plugins.yaml'));
    file.writeAsStringSync(relayYaml(args: <String>[hang.path]));
    final Future<PluginReconcileResult> reconciling = bus.applyConfigs();
    await waitKeepaliveWindow(bus);
    // 窗口里：订阅还在（一注销，后面的请求连入队的入口都没有）
    expect(
      station.subscribers.any((StationSubscriber s) => s.pluginId == pluginId),
      isTrue,
      reason: '重启窗口里必须还挂着这个插件的回包函数',
    );

    final Future<Map<String, dynamic>?> inWindow = relay(bus, 'fail-1');
    final DateTime queueDeadline = DateTime.now().add(
      const Duration(seconds: 10),
    );
    while (DateTime.now().isBefore(queueDeadline) &&
        bus.restartBuffer.lengthOf(pluginId) == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      bus.restartBuffer.lengthOf(pluginId),
      1,
      reason: '请求进了暂存队列；日志：${logs.join(' | ')}',
    );

    final PluginReconcileResult result = await reconciling;
    expect(result.failed.map((PluginReconcileAction a) => a.pluginId), <String>[
      pluginId,
    ]);
    expect(bus.lifecycleOf(pluginId), PluginLifecycleState.failed);

    // ① 队列以可读失败收尾（不静默、不挂着）
    expect(await inWindow, isNull, reason: '失败 ⇒ 中转放行原数据（fail-open），会话不受影响');
    expect(bus.restartBufferReadings()['queued'], 0);
    expect(bus.restartBufferReadings()['dropped'], 1);
    expect(
      logs.any((String l) => l.contains('丢弃插件 $pluginId 的 1 条暂存站点请求')),
      isTrue,
      reason: '丢弃必须写清丢了几条、为什么；日志：${logs.join(' | ')}',
    );
    // ② 押后的注销在失败时补上（不留一个指向死插件的订阅）
    expect(
      station.subscribers.where(
        (StationSubscriber s) => s.pluginId == pluginId,
      ),
      isEmpty,
      reason: '重启最终失败 ⇒ 补注销，不能让订阅永远悬在半路',
    );
  });

  test('窗口里的 callTool 不当场失败：等就绪再投，返回插件的答案', () async {
    final PluginBus bus = await startBus();
    await waitSubscribed(bus);

    final Future<PluginHotRestartResult> restarting = bus.hotRestart(pluginId);
    await waitKeepaliveWindow(bus);

    final Future<PluginCallResult> calling = bus.callTool(
      'plugin__${pluginId}__echo',
      <String, dynamic>{'text': 'LATE'},
      pluginId: pluginId,
      agentId: agent,
      sessionId: 'sess-1',
    );
    final PluginHotRestartResult result = await restarting;
    expect(result.ok, isTrue, reason: result.reason);

    final PluginCallResult called = await calling;
    expect(
      called.isError,
      isFalse,
      reason:
          '工具调用等到了就绪（等的是生命周期跃迁这个**事件**，不是时长）；'
          '文本：${called.text}；日志：${logs.join(' | ')}',
    );
    expect(called.text, contains('plugin-echo: LATE'));
  });

  test('溢出：超出每插件上限的那条**立即**放行原数据，并写下可读原因', () async {
    final PluginBus bus = await startBus(maxPerPlugin: 1);
    await waitSubscribed(bus);

    final Future<PluginHotRestartResult> restarting = bus.hotRestart(pluginId);
    await waitKeepaliveWindow(bus);

    final Future<Map<String, dynamic>?> first = relay(bus, 'ovf-1');
    final DateTime queueDeadline = DateTime.now().add(
      const Duration(seconds: 10),
    );
    while (DateTime.now().isBefore(queueDeadline) &&
        bus.restartBuffer.lengthOf(pluginId) == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(bus.restartBuffer.lengthOf(pluginId), 1, reason: '第一条进队');

    // 第二条撞上上限：**不等重启**，当场按 fail-open 放行原数据
    final Map<String, dynamic>? overflowed = await relay(bus, 'ovf-2');
    expect(overflowed, isNull, reason: '溢出 = 原样放行，不是报错、也不是排队');
    expect(bus.restartBuffer.lengthOf(pluginId), 1, reason: '溢出那条不进队（有界）');
    expect(bus.restartBufferReadings()['overflowed'], 1);
    expect(
      logs.any((String l) => l.contains('暂存队列已满')),
      isTrue,
      reason: '溢出的原因必须能查到；日志：${logs.join(' | ')}',
    );

    final PluginHotRestartResult result = await restarting;
    expect(result.ok, isTrue, reason: result.reason);
    expect(await first, isNotNull, reason: '在队的那条照样重放并拿到改写');
    expect(bus.restartBufferReadings()['replayed'], 1);
  });

  test('重启窗口结束后，后续请求直投新实例（暂存不是永久挡路）', () async {
    final PluginBus bus = await startBus();
    await waitSubscribed(bus);
    final PluginHotRestartResult result = await bus.hotRestart(pluginId);
    expect(result.ok, isTrue, reason: result.reason);
    expect(bus.lifecycleOf(pluginId), PluginLifecycleState.ready);

    final Map<String, dynamic>? rewritten = await relay(bus, 'after-1');
    expect(rewritten, isNotNull);
    expect(
      ((rewritten!['arguments'] ?? const <String, dynamic>{})
          as Map<String, dynamic>)['text'],
      'REWRITTEN',
    );
    expect(
      bus.restartBuffer.lengthOf(pluginId),
      0,
      reason: '就绪之后不再进队列：暂存只是重启窗口这一件事',
    );
  });

  test('重启窗口里**改了归属** ⇒ 上一世那条声明被作废，不能留两条还能投递的', () async {
    // 为什么这条必须单独钉：保活把注销押后了，于是「旧归属的声明」和「新归属的声明」
    // 会同时挂在站点上。中转站只会让第二个人 key_conflict（新一世根本订不上），
    // 收集站则会让 team-1 的请求递给一个已经属于 team-2 的进程。两种都不是读数差异。
    final PluginBus bus = await startBus();
    await waitSubscribed(bus);
    final RelayStation relayPoint =
        bus.stations.station(StationHubIds.relayToolPre)! as RelayStation;
    expect(relayPoint.subscribers.single.scope.teamId, team);

    // 只改 scope（它是启动参数 ⇒ 对账会断开重启，并走保活窗口）
    final File file = File(p.join(temp.path, 'config', 'plugins.yaml'));
    file.writeAsStringSync(relayYaml(teamId: 'team-9'));
    final PluginReconcileResult result = await bus.applyConfigs();
    expect(
      result.restarted.map((PluginReconcileAction a) => a.pluginId),
      <String>[pluginId],
      reason: 'scope 是启动参数：$result',
    );
    expect(bus.lifecycleOf(pluginId), PluginLifecycleState.ready);

    // ① 中转站：新一世确实订上了，而且**只有一条**，归属是新的
    final List<StationSubscriber> relaySubs = relayPoint.subscribers
        .where((StationSubscriber s) => s.pluginId == pluginId)
        .toList(growable: false);
    expect(
      relaySubs,
      hasLength(1),
      reason:
          '旧归属那条必须被作废（留着它就是一边占坑一边 key_conflict）；'
          '日志：${logs.join(' | ')}',
    );
    expect(relaySubs.single.scope.teamId, 'team-9');

    // ② 收集站（核心自己下的订阅，插件一行代码都没写）：同样只能有一条
    final CollectStation collect =
        bus.stations.station(StationHubIds.collect)! as CollectStation;
    final List<StationSubscriber> collectSubs = collect.subscribers
        .where((StationSubscriber s) => s.pluginId == pluginId)
        .toList(growable: false);
    expect(
      collectSubs,
      hasLength(1),
      reason: '核心侧那条申报路同样要销账；日志：${logs.join(' | ')}',
    );
    expect(collectSubs.single.scope.teamId, 'team-9');
    expect(
      logs.any((String l) => l.contains('注销上一世被保活代管的那份站点声明')),
      isTrue,
      reason: '销账这件事要能查到（不静默）；日志：${logs.join(' | ')}',
    );

    // ③ 旧团队的上下文再也递不到这个插件（fail-open 放行原数据，不报错也不谎报），
    //    新团队能：上一世那条声明真的不再参与投递了。
    expect(
      await relay(bus, 'scope-old'),
      isNull,
      reason:
          'team-1 的请求不该被递给现在属于 team-9 的插件（留着旧声明就会）；'
          '日志：${logs.join(' | ')}',
    );
    callTeam = 'team-9';
    final Map<String, dynamic>? rewritten = await relay(bus, 'scope-1');
    expect(
      rewritten,
      isNotNull,
      reason: '新团队的请求能递到（新一世自己重新申报过）；日志：${logs.join(' | ')}',
    );
    expect(
      ((rewritten!['arguments'] ?? const <String, dynamic>{})
          as Map<String, dynamic>)['text'],
      'REWRITTEN',
    );
  });
}
