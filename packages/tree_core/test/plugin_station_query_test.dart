// 执行站·站点族（`station.list` / `station.state`，20261015-hot-restart 阶段 6）。
//
// 这一族存在的理由很窄：热重启一个插件前必须先能看见「谁接管了哪个点位」——
// 接走 `relay.llm.handle` 的那个插件一停，整条 LLM 就回退内置实现。看不见这层关系
// 就只能猜，而猜错的代价是停在正在干活的插件上。
//
// 钉住的五件事：
// 1. `station.list` 把内置点位全递出来，并把**中转点的唯一处理者**写成 `handled_by`
//    （这就是控制面要的那个读数）；列表是**投影**：不递 readme / 公告板 / 配置；
// 2. `station.state` 接受订阅时那套**别名**（`llm.handle`）——「订得到、问不到」是
//    自相矛盾的面；
// 3. 归属只有一条：**内置点位人人可见，插件自建站只对订阅者所在 team 可见**；
//    team 证明不了 ⇒ fail-closed 拒绝；
// 4. 本族**只读**：接管权易手仍然只走 `station/subscribe`，这里不开第二条路；
// 5. 没接线时以「未接线」显式失败，不假装读过（口径与 plugin 族一致）。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

void main() {
  late Directory temp;
  late String configFile;
  late PluginBus bus;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_station_query_');
    configFile = p.join(temp.path, 'config', 'plugins.yaml');
    Directory(p.dirname(configFile)).createSync(recursive: true);
    File(configFile).writeAsStringSync(
      <String>[
        'enabled: true',
        'plugins:',
        '  - id: alpha',
        '    name: 甲插件',
        '    command: "definitely-not-a-real-command-xyz"',
        '    enabled: true',
        '    granularity: team',
        '    scope: {team_id: team-1}',
        '  - id: beta',
        '    name: 乙插件',
        '    command: "definitely-not-a-real-command-xyz"',
        '    enabled: true',
        '    granularity: team',
        '    scope: {team_id: team-2}',
        '',
      ].join('\n'),
    );
    bus = PluginBus(
      configFile: configFile,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
    );
    final ExecuteStationMounts mounts = ExecuteStationMounts.forStore(
      store: MemoryStore(),
      ioFor: (String agentId) async => null,
      // 生产由 CoreServer 注入同一个实现（站点表只在总线里）
      topologyQuery: bus.handleStationQuery,
    );
    expect(bus.mountExecuteStations(mounts), isNull, reason: '挂载必须全成功');
  });

  tearDown(() async {
    await bus.close();
    for (int i = 0; i < 5; i++) {
      try {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  /// 走**执行站**下命令（绕过站点就等于没测到白名单与归属校验）。
  Future<StationCommandResult> run(
    String command, {
    Map<String, dynamic> arguments = const <String, dynamic>{},
    StationScope scope = const StationScope(teamId: 'team-1'),
    String sourcePluginId = '',
  }) async {
    final ExecuteStation? station = bus.stations.executeForCommand(command);
    expect(station, isNotNull, reason: '$command 没有所属点位');
    return station!.execute(
      command: command,
      scope: scope,
      arguments: arguments,
      sourcePluginId: sourcePluginId,
    );
  }

  Map<String, dynamic> payloadOf(StationCommandResult result) =>
      (result.payload ?? const <String, dynamic>{}) as Map<String, dynamic>;

  /// 让某个插件**接管**一个中转点位（真订阅，不是伪造读数）。
  void takeover(String stationId, String pluginId, String team) {
    bus.stations.ensureBuiltinStations();
    final StationSubResult sub = bus.stations.subscribe(
      stationId,
      StationSubscriber(
        pluginId: pluginId,
        scope: StationScope(teamId: team, modeKey: StationModeKey.local),
        subscribedAt: 1,
      ),
      (StationRequest request) async => StationReply.ok(<String, dynamic>{}),
    );
    expect(sub.ok, isTrue, reason: sub.error);
  }

  test('station.list：内置点位全可见，中转点的接管者写成 handled_by', () async {
    takeover(StationHubIds.relayLlmHandle, 'alpha', 'team-1');

    final StationCommandResult result = await run('station.list');
    expect(result.ok, isTrue, reason: result.error);
    final Map<String, dynamic> body = payloadOf(result);
    expect(body['ok'], isTrue);
    expect(body['team_id'], 'team-1');
    final List<dynamic> rows = body['stations'] as List<dynamic>;
    expect(
      rows.map((dynamic r) => (r as Map<String, dynamic>)['station_id']),
      contains(StationHubIds.relayLlmHandle),
      reason: '内置点位是系统接口，任何 team 都要能看见它被谁订了',
    );
    final Map<String, dynamic> llm = rows.firstWhere(
      (dynamic r) =>
          (r as Map<String, dynamic>)['station_id'] ==
          StationHubIds.relayLlmHandle,
    ) as Map<String, dynamic>;
    expect(llm['handled_by'], 'alpha', reason: '控制面要的就是这一个读数');
    expect(llm['builtin'], isTrue);
    // 列表是投影：不递 readme / 公告板 / 站点配置（那些属于 station.state）
    expect(llm.containsKey('readme'), isFalse);
    expect(llm.containsKey('config'), isFalse);
    expect(llm.containsKey('board_latest'), isFalse);
  });

  test('没被接管的中转点位 handled_by 是空串（不省略键：省略就分不出"没人订"与"没测到"）', () async {
    final StationCommandResult result = await run('station.list');
    final List<dynamic> rows = payloadOf(result)['stations'] as List<dynamic>;
    final Map<String, dynamic> compact = rows.firstWhere(
      (dynamic r) =>
          (r as Map<String, dynamic>)['station_id'] ==
          StationHubIds.relayContextCompact,
    ) as Map<String, dynamic>;
    expect(compact['handled_by'], '');
    expect(compact['subscriber_count'], 0);
  });

  test('station.state 接受订阅时那套别名（订得到就必须问得到）', () async {
    takeover(StationHubIds.relayLlmHandle, 'alpha', 'team-1');

    final StationCommandResult result = await run(
      'station.state',
      arguments: <String, dynamic>{'point': 'llm.handle'},
    );
    expect(result.ok, isTrue, reason: result.error);
    final Map<String, dynamic> station =
        payloadOf(result)['station'] as Map<String, dynamic>;
    expect(station['station_id'], StationHubIds.relayLlmHandle);
    expect(
      (station['subscriptions'] as List<dynamic>).map(
        (dynamic s) => (s as Map<String, dynamic>)['plugin_id'],
      ),
      contains('alpha'),
    );
  });

  test('自建站只对订阅者所在 team 可见：别的 team 连"它存在"都问不到', () async {
    const String selfBuilt = 'plugin.beta.relay.audit';
    final String? error = bus.stations.register(
      BroadcastStation(
        id: selfBuilt,
        description: '乙插件自己的审计广播站',
        scope: const StationScope(teamId: 'team-2'),
      ),
    );
    expect(error, isNull, reason: error);

    // team-1 问它 ⇒ 显式拒，而不是"没这个站"（也不递任何字段）
    final StationCommandResult denied = await run(
      'station.state',
      arguments: <String, dynamic>{'station_id': selfBuilt},
    );
    expect(denied.ok, isFalse);
    expect(denied.error, contains('不属于 team team-1'));
    expect(denied.payload, isNull);

    // 列表里也不许出现它
    final List<dynamic> rows =
        payloadOf(await run('station.list'))['stations'] as List<dynamic>;
    expect(
      rows.map((dynamic r) => (r as Map<String, dynamic>)['station_id']),
      isNot(contains(selfBuilt)),
    );

    // team-2 自己问 ⇒ 能看到（归属证明得了就绝不拦）
    final StationCommandResult owner = await run(
      'station.state',
      arguments: <String, dynamic>{'station_id': selfBuilt},
      scope: const StationScope(
        teamId: 'team-2',
        modeKey: StationModeKey.local,
      ),
    );
    expect(owner.ok, isTrue, reason: owner.error);
  });

  test('team 证明不了 ⇒ fail-closed 拒绝（不放宽成"给你看点公共的"）', () async {
    final StationCommandResult result = await run(
      'station.list',
      scope: const StationScope(),
    );
    expect(result.ok, isFalse);
    expect(result.error, contains('缺少 team_id'));
    expect(result.error, contains('fail-closed'));
  });

  test('只读：这一族里没有能改接管权的命令，也不动既有订阅', () async {
    takeover(StationHubIds.relayLlmHandle, 'alpha', 'team-1');
    final int before = bus.stations
        .station(StationHubIds.relayLlmHandle)!
        .subscribers
        .length;

    await run('station.list');
    await run(
      'station.state',
      arguments: <String, dynamic>{'point': 'llm.handle'},
    );

    expect(
      bus.stations.station(StationHubIds.relayLlmHandle)!.subscribers,
      hasLength(before),
      reason: '看过一遍拓扑不许动任何订阅',
    );
    // 白名单里没有 station.takeover / station.unsubscribe 这类第二条路：
    // 点位表认不出它（第一道），拿本站直接执行也只会拿到拒与整张清单（第二道）。
    expect(StationPoints.ownerOfCommand('station.takeover'), isNull);
    expect(StationPoints.ownerOfCommand('station.unsubscribe'), isNull);
    final ExecuteStation station = bus.stations.executePointFor(
      StationHubIds.executeStation,
    )!;
    final StationCommandResult takeoverTry = await station.execute(
      command: 'station.takeover',
      scope: const StationScope(teamId: 'team-1'),
      arguments: <String, dynamic>{'station_id': StationHubIds.relayLlmHandle},
    );
    expect(takeoverTry.ok, isFalse, reason: '接管权只能走 station/subscribe 那一条');
    expect(takeoverTry.error, contains('station.list'));
    expect(
      bus.stations.station(StationHubIds.relayLlmHandle)!.subscribers,
      hasLength(before),
      reason: '被拒的那一次也不许留下任何副作用',
    );
  });

  test('命令参数缺 station_id ⇒ 显式要（不"看起来返回了空"）', () async {
    final StationCommandResult result = await run('station.state');
    expect(result.ok, isFalse);
    expect(result.error, contains('station_id'));
  });

  test('未接线：核心没注入读口时以「未接线」失败，不假装读过', () async {
    final ExecuteStationMounts bare = ExecuteStationMounts.forStore(
      store: MemoryStore(),
      ioFor: (String agentId) async => null,
    );
    final PluginBus other = PluginBus(
      configFile: configFile,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
    );
    addTearDown(other.close);
    expect(other.mountExecuteStations(bare), isNull);
    final ExecuteStation station = other.stations.executeForCommand(
      'station.list',
    )!;
    final StationCommandResult result = await station.execute(
      command: 'station.list',
      scope: const StationScope(teamId: 'team-1'),
      arguments: const <String, dynamic>{},
    );
    expect(result.ok, isFalse);
    expect(result.error, contains('未接线'));
  });
}
