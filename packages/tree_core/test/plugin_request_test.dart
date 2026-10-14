import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// **插件 → 核心的请求通道**（M9 §3 执行站的核心语义）：插件主动下命令
/// （`station/command`）——此前这类报文会被宿主静默丢掉（只认响应 / 通知两类）。
///
/// 这里跑的是**真插件进程 + 真执行站 + 真工作空间 IO**：
/// - 插件（`--station-client`）主动发请求 ⇒ 宿主三类判别的「请求」分支 ⇒
///   总线解析 scope ⇒ 站点中枢 `execute` ⇒ 挂载位置干活 ⇒ 响应原样回到插件；
/// - **scope 只认插件自己的声明**：插件在 arguments 里塞 team_id / agent_id /
///   mode_key 不改变作用域（跨 team 目标照样被拒，fail-closed）；
/// - 未知 method ⇒ `-32601`；处理器抛异常 ⇒ error 响应，且宿主读循环不受影响
///   （后续请求照常）。
void main() {
  late Directory temp;
  late String script;
  late String workspace;

  const String team = 'team-1';

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tree_plugin_request_');
    script = p.join(
      Directory.current.path,
      'test',
      'fixtures',
      'fake_plugin.dart',
    );
    workspace = p.join(temp.path, 'ws');
    Directory(workspace).createSync(recursive: true);
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

  /// Windows 路径转正斜杠（YAML 双引号标量里不出现反斜杠，避免转义歧义）。
  String slash(String path) => path.replaceAll(Platform.pathSeparator, '/');

  /// 执行站首命令集的挂载位置：agt_1 ∈ team-1、agt_2 ∈ team-2（都走本地工作空间）。
  ExecuteStationMounts mounts(String workspaceDir, {bool bothAgents = false}) =>
      ExecuteStationMounts(
        ioFor: (String agentId) async => switch (agentId) {
          'agt_1' => LocalWorkspaceIO(workspaceDir),
          'agt_2' => bothAgents ? LocalWorkspaceIO(workspaceDir) : null,
          _ => null,
        },
        agentTeamOf: (String agentId) => switch (agentId) {
          'agt_1' => 'team-1',
          'agt_2' => 'team-2',
          _ => '',
        },
        agentModeOf: (String agentId) =>
            (agentId == 'agt_1' || agentId == 'agt_2')
            ? StationModeKey.local
            : '',
      );

  /// 声明了 team 的插件（能进站点体系 ⇒ 能使用执行站）。
  String teamPluginYaml() =>
      'enabled: true\n'
      'plugins:\n'
      '  - id: sample\n'
      '    name: 样例插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: ["${slash(script)}", "--station-client"]\n'
      '    granularity: team\n'
      '    scope: {team_id: $team}\n';

  /// 同上，但插件主动请求时**复用核心在途请求的 int id**（撞号用例）。
  String teamPluginIntIdYaml() =>
      'enabled: true\n'
      'plugins:\n'
      '  - id: sample\n'
      '    name: 样例插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: ["${slash(script)}", "--station-client", '
      '"--station-client-int-id"]\n'
      '    granularity: team\n'
      '    scope: {team_id: $team}\n';

  /// 单实例全局插件：**不声明 scope**，身份完全由每条命令的 agent_id 提供。
  String globalPluginYaml() =>
      'enabled: true\n'
      'plugins:\n'
      '  - id: global\n'
      '    name: 全局插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: ["${slash(script)}", "--station-client"]\n'
      '    granularity: team\n';

  /// 额外申报 scope_probe 的插件（验证核心 → 插件的 tools/call 带身份）。
  String scopeProbePluginYaml() =>
      'enabled: true\n'
      'plugins:\n'
      '  - id: sample\n'
      '    name: 样例插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: ["${slash(script)}", "--station-client", "--scope-probe"]\n'
      '    granularity: team\n'
      '    scope: {team_id: $team}\n';

  /// **两个**插件：用来验证自建站的归属隔离（别人的站不能订、不能注销）。
  String twoPluginsYaml() =>
      'enabled: true\n'
      'plugins:\n'
      '  - id: sample\n'
      '    name: 样例插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: ["${slash(script)}", "--station-client"]\n'
      '    granularity: team\n'
      '    scope: {team_id: $team}\n'
      '  - id: other\n'
      '    name: 另一个插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: ["${slash(script)}", "--station-client"]\n'
      '    granularity: team\n'
      '    scope: {team_id: $team}\n';

  /// 没声明 team 的插件：站点四元组不成立 ⇒ 执行站必须显式拒绝（不静默）。
  String noTeamPluginYaml() =>
      'enabled: true\n'
      'plugins:\n'
      '  - id: noteam\n'
      '    name: 无归属插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: ["${slash(script)}", "--station-client"]\n';

  /// 两个插件都当**自建站订阅者**（回显 station/request）：用于验证
  /// 「A 建站 → B 订阅 → 触发时真的投到 B」这条跨插件调用链。
  String echoPluginsYaml() =>
      'enabled: true\n'
      'plugins:\n'
      '  - id: sample\n'
      '    name: 样例插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: ["${slash(script)}", "--station-client", "--station-echo"]\n'
      '    granularity: team\n'
      '    scope: {team_id: $team}\n'
      '  - id: other\n'
      '    name: 另一个插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: ["${slash(script)}", "--station-client", "--station-echo"]\n'
      '    granularity: team\n'
      '    scope: {team_id: $team}\n';

  Future<PluginBus> startBus(
    String yaml, {
    void Function(Map<String, dynamic> frame)? broadcast,
    bool wireRuntimeScope = false,
    bool bothAgents = false,
  }) async {
    final File file = File(p.join(temp.path, 'config', 'plugins.yaml'));
    file.createSync(recursive: true);
    file.writeAsStringSync(yaml);
    final PluginBus bus = PluginBus(
      configFile: file.path,
      coreVersion: 'test',
      heartbeatInterval: const Duration(seconds: 30),
      broadcast: broadcast,
    );
    addTearDown(bus.close);
    // 执行站的挂载位置：与核心接线一致（八条命令都接到真实现上）。
    expect(
      bus.mountExecuteStations(mounts(workspace, bothAgents: bothAgents)),
      isNull,
    );
    if (wireRuntimeScope) {
      // 复刻生产接线（CoreServer._wirePluginStations）：按目标 agent 的**真实归属**
      // 解析 team / mode —— 单实例插件因此能服务多个 team。
      bus.callSiteContext = (String agentId, String sessionId) =>
          StationScopeContext(
            teamId: switch (agentId) {
              'agt_1' => 'team-1',
              'agt_2' => 'team-2',
              _ => '',
            },
            agentId: agentId,
            sessionId: sessionId,
          );
      bus.agentModeKeyResolver = (String agentId) =>
          (agentId == 'agt_1' || agentId == 'agt_2')
          ? StationModeKey.local
          : '';
    }
    await bus.start();
    return bus;
  }

  /// 让假插件**主动**发一条请求，并把它读回的核心响应解出来。
  Future<Map<String, dynamic>> pluginRequest(
    PluginBus bus, {
    String pluginId = 'sample',
    required String method,
    Map<String, dynamic> params = const <String, dynamic>{},
  }) async {
    final PluginCallResult called = await bus.callTool(
      'plugin__${pluginId}__request_station',
      <String, dynamic>{'method': method, 'params': params},
    );
    expect(called.isError, isFalse, reason: called.text);
    return jsonDecode(called.text) as Map<String, dynamic>;
  }

  test('插件发 station/subscribe ⇒ 订阅成立并可退订（中转站 / 广播站）', () async {
    final PluginBus bus = await startBus(teamPluginYaml());

    final Map<String, dynamic> subscribed = await pluginRequest(
      bus,
      method: 'station/subscribe',
      params: <String, dynamic>{'station': 'relay'},
    );
    expect(subscribed['error'], isNull, reason: '${subscribed['error']}');
    final Map<String, dynamic> sub = subscribed['result'] as Map<String, dynamic>;
    expect(sub['ok'], isTrue, reason: '${sub['error']}');
    expect(sub['kind'], 'relay');
    // 点位化：`station: 'relay'` 不带 point = **一次订阅工具前 + 工具后两个点位**
    // （点位化之前就是一个实例收两段，老插件因此零改动）；station_id 取第一条。
    expect(
      sub['station_ids'],
      <String>[
        StationHubIds.relayToolPre,
        StationHubIds.relayToolPost,
      ],
      reason: '一次订阅两个点位，回包逐条给出',
    );
    expect(
      sub['station_id'],
      StationHubIds.relayToolPre,
      reason: 'station_id = station_ids 的第一条（站点 id 是全局常量）',
    );

    final RelayStation relay =
        bus.stations.station(StationHubIds.relayToolPre)! as RelayStation;
    expect(relay.subscribers.single.pluginId, 'sample');
    expect(relay.subscribers.single.scope.teamId, team);
    expect(
      (bus.stations.station(StationHubIds.relayToolPost)! as RelayStation)
          .subscribers
          .single
          .pluginId,
      'sample',
      reason: '工具后点位同样订上了（两个点位各自唯一订阅者，互不干扰）',
    );

    // 重复订阅 = 幂等更新（同一插件同 scope；不报"键位冲突"）
    final Map<String, dynamic> again = await pluginRequest(
      bus,
      method: 'station/subscribe',
      params: <String, dynamic>{'station': 'relay'},
    );
    expect((again['result'] as Map<String, dynamic>)['ok'], isTrue);
    expect(relay.subscribers.length, 1);
    expect(
      (bus.stations.station(StationHubIds.relayToolPost)! as RelayStation)
          .subscribers
          .length,
      1,
    );

    // 广播站同样可订阅（collect 之外的站过去没有任何订阅入口）
    final Map<String, dynamic> broadcast = await pluginRequest(
      bus,
      method: 'station/subscribe',
      params: <String, dynamic>{'station': 'broadcast'},
    );
    expect((broadcast['result'] as Map<String, dynamic>)['ok'], isTrue);
    expect(bus.stations.station(StationHubIds.broadcast), isNotNull);

    // 非可订阅站 / 未知站点类型 ⇒ 参数错误（显式，不静默）
    final Map<String, dynamic> execute = await pluginRequest(
      bus,
      method: 'station/subscribe',
      params: <String, dynamic>{'station': 'execute'},
    );
    expect((execute['error'] as Map<String, dynamic>)['code'], -32602);

    // 退订：幂等。`station: 'relay'` 与订阅对称 —— 两个点位一起退 ⇒ removed = 2
    final Map<String, dynamic> removed = await pluginRequest(
      bus,
      method: 'station/unsubscribe',
      params: <String, dynamic>{'station': 'relay'},
    );
    final Map<String, dynamic> unsub =
        removed['result'] as Map<String, dynamic>;
    expect(unsub['ok'], isTrue);
    expect(
      unsub['removed'],
      2,
      reason: '一个 relay 订阅声明落在两个点位上，逐条退订共 2 条',
    );
    expect(relay.subscribers, isEmpty);
    expect(
      (bus.stations.station(StationHubIds.relayToolPost)! as RelayStation)
          .subscribers,
      isEmpty,
    );
  });

  test('未声明 team 的插件订阅站点 ⇒ 成立但为**通配**（作用于所有 team）', () async {
    final PluginBus bus = await startBus(noTeamPluginYaml());
    final Map<String, dynamic> response = await pluginRequest(
      bus,
      pluginId: 'noteam',
      method: 'station/subscribe',
      params: <String, dynamic>{'station': 'relay'},
    );
    expect(response['error'], isNull, reason: '${response['error']}');
    final Map<String, dynamic> result =
        response['result'] as Map<String, dynamic>;
    expect(result['ok'], isTrue, reason: '${result['error']}');
    // 空 scope 落成一条**四维全通配**的订阅：team 空 = 所有 team，
    // mode 空 = local / ssh 都收（用户定稿：为空默认作用于所有 team）
    final Map<String, dynamic> scope = result['scope'] as Map<String, dynamic>;
    expect(scope['team_id'], '');
    expect(scope['mode_key'], '');
    final RelayStation relay =
        bus.stations.station(StationHubIds.relayToolPre)! as RelayStation;
    expect(relay.subscribers.single.pluginId, 'noteam');
    expect(relay.subscribers.single.scope.teamIsWildcard, isTrue);
    expect(relay.subscribers.single.scope.modeIsWildcard, isTrue);
    // 不带 point 的 relay 一次订两个点位：工具后点位同样拿到通配订阅
    expect(
      (bus.stations.station(StationHubIds.relayToolPost)! as RelayStation)
          .subscribers
          .single
          .scope
          .teamIsWildcard,
      isTrue,
      reason: '两个工具点位都落成通配订阅',
    );
  });

  test('插件发 station/command ⇒ 核心的响应原样回到插件，命令真的执行', () async {
    final PluginBus bus = await startBus(teamPluginYaml());

    final Map<String, dynamic> write = await pluginRequest(
      bus,
      method: 'station/command',
      params: <String, dynamic>{
        'command': 'fs.write',
        'arguments': <String, dynamic>{
          'agent_id': 'agt_1',
          'path': 'notes/a.txt',
          'content': '插件下的命令',
        },
      },
    );
    expect(write['jsonrpc'], '2.0');
    expect(write['id'], isA<String>(), reason: '响应必须原样回填插件的 id');
    expect(write['error'], isNull);
    final Map<String, dynamic> result = write['result'] as Map<String, dynamic>;
    expect(result['ok'], isTrue, reason: '${result['error']}');
    expect(result['command'], 'fs.write');
    expect(result['mount_id'], 'core.execute.fs.write');
    expect(
      (result['payload'] as Map<String, dynamic>)['bytes_written'],
      greaterThan(0),
    );
    expect(
      File(p.join(workspace, 'notes', 'a.txt')).readAsStringSync(),
      '插件下的命令',
      reason: '插件命令必须真的落在目标 agent 的工作空间里',
    );

    // 同一插件的**后续请求照常**（读回刚写的文件）
    final Map<String, dynamic> read = await pluginRequest(
      bus,
      method: 'station/command',
      params: <String, dynamic>{
        'command': 'fs.read',
        'arguments': <String, dynamic>{
          'agent_id': 'agt_1',
          'path': 'notes/a.txt',
        },
      },
    );
    final Map<String, dynamic> readResult =
        read['result'] as Map<String, dynamic>;
    expect(readResult['ok'], isTrue, reason: '${readResult['error']}');
    expect(
      (readResult['payload'] as Map<String, dynamic>)['content'],
      '插件下的命令',
    );
  });

  test('未声明 team 的插件 ⇒ 明确错误（不能使用执行站）', () async {
    final PluginBus bus = await startBus(noTeamPluginYaml());
    final Map<String, dynamic> response = await pluginRequest(
      bus,
      pluginId: 'noteam',
      method: 'station/command',
      params: <String, dynamic>{
        'command': 'fs.read',
        'arguments': <String, dynamic>{'agent_id': 'agt_1', 'path': 'a.txt'},
      },
    );
    expect(response['result'], isNull, reason: '不合法的 scope 不许执行');
    final Map<String, dynamic> error =
        response['error'] as Map<String, dynamic>;
    expect(error['code'], PluginRpcErrorCode.scopeDenied);
    expect(error['message'], contains('noteam'), reason: '要点名是哪个插件');
    expect(error['message'], contains('未声明 team'));
    expect(error['message'], contains('不能使用执行站'));
  });

  test('请求里带的身份必须与目标 agent 的真实归属一致（不一致则拒）', () async {
    final PluginBus bus = await startBus(teamPluginYaml());
    final Map<String, dynamic> response = await pluginRequest(
      bus,
      method: 'station/command',
      params: <String, dynamic>{
        'command': 'fs.read',
        'arguments': <String, dynamic>{
          // 请求里带的 team_id 与目标 agent 的真实归属不一致 ⇒ 显式拒绝
          // （身份要被**校验**，不是被忽略，也不能拿来给自己"换 scope"）
          'team_id': 'team-2',
          'agent_id': 'agt_2',
          'session_id': 'ses-2',
          'mode_key': StationModeKey.ssh,
          'path': 'secret.txt',
        },
      },
    );
    expect(
      response['result'],
      isNull,
      reason: 'scope 不一致走 -32001，不是站点级 ok=false',
    );
    final Map<String, dynamic> error =
        response['error'] as Map<String, dynamic>;
    expect(error['code'], PluginRpcErrorCode.scopeDenied);
    expect(error['message'], contains('跨 team'));
    expect(error['message'], contains('agt_2'));
    expect(
      error['message'],
      contains('team=$team'),
      reason: '真实归属（或未接线时回退的声明）是 team-1，请求里的 team-2 对不上',
    );

    // 站点侧旁证：身份不一致在**选站之前**就被拒，没有为 team-2 / ssh 建执行站
    final List<ExecuteStation> executes = bus.stations
        .stationList()
        .whereType<ExecuteStation>()
        .toList();
    expect(executes, isEmpty);
    expect(File(p.join(workspace, 'secret.txt')).existsSync(), isFalse);
  });

  test('单实例插件（不声明 scope）用每条命令的 agent_id 服务多个 team', () async {
    final PluginBus bus = await startBus(
      globalPluginYaml(),
      wireRuntimeScope: true,
      bothAgents: true,
    );
    final Map<String, dynamic> one = await pluginRequest(
      bus,
      pluginId: 'global',
      method: 'station/command',
      params: <String, dynamic>{
        'command': 'fs.write',
        'arguments': <String, dynamic>{
          'agent_id': 'agt_1',
          'path': 't1.txt',
          'content': 'team-1',
        },
      },
    );
    expect(
      (one['result'] as Map<String, dynamic>)['ok'],
      isTrue,
      reason: '${one['error']}',
    );
    final Map<String, dynamic> two = await pluginRequest(
      bus,
      pluginId: 'global',
      method: 'station/command',
      params: <String, dynamic>{
        'command': 'fs.write',
        'arguments': <String, dynamic>{
          'agent_id': 'agt_2',
          'path': 't2.txt',
          'content': 'team-2',
        },
      },
    );
    expect(
      (two['result'] as Map<String, dynamic>)['ok'],
      isTrue,
      reason: '${two['error']}',
    );
    expect(File(p.join(workspace, 't1.txt')).readAsStringSync(), 'team-1');
    expect(File(p.join(workspace, 't2.txt')).readAsStringSync(), 'team-2');
    expect(
      bus.stations.stationList().whereType<ExecuteStation>().map(
        (ExecuteStation s) => s.id,
      ),
      <String>[StationHubIds.executeFs],
      reason: '两条 fs 命令同属**文件操作点位**：该点位按每条命令的 agent_id 服务多个 team',
    );
    expect(
      bus.stations.station(StationHubIds.executeFs)!.scope.teamId,
      isEmpty,
      reason: '站点不绑 team——归属在每次命令的 scope 上',
    );
  });

  test('声明了 team 的插件在运行期解析下仍被限制在自己 team（声明是上限）', () async {
    final PluginBus bus = await startBus(
      teamPluginYaml(),
      wireRuntimeScope: true,
      bothAgents: true,
    );
    final Map<String, dynamic> response = await pluginRequest(
      bus,
      method: 'station/command',
      params: <String, dynamic>{
        'command': 'fs.write',
        'arguments': <String, dynamic>{
          'agent_id': 'agt_2',
          'path': 'nope.txt',
          'content': 'x',
        },
      },
    );
    expect(response['result'], isNull);
    final Map<String, dynamic> error =
        response['error'] as Map<String, dynamic>;
    expect(error['code'], PluginRpcErrorCode.scopeDenied);
    expect(
      error['message'],
      contains('跨 team'),
      reason: '声明 team-1 的插件不能碰 team-2 的 agent（声明是作用域上限）',
    );
    expect(File(p.join(workspace, 'nope.txt')).existsSync(), isFalse);
  });

  test('核心 → 插件的 tools/call 带调用点 team/agent/session/mode', () async {
    final PluginBus bus = await startBus(
      scopeProbePluginYaml(),
      wireRuntimeScope: true,
    );
    final PluginCallResult probe = await bus.callTool(
      'plugin__sample__scope_probe',
      <String, dynamic>{},
      agentId: 'agt_1',
      sessionId: 'ses-1',
    );
    expect(probe.isError, isFalse, reason: probe.text);
    final Map<String, dynamic> params =
        jsonDecode(probe.text) as Map<String, dynamic>;
    expect(params['name'], 'scope_probe');
    final Map<String, dynamic> scope = params['scope'] as Map<String, dynamic>;
    expect(scope['team_id'], 'team-1');
    expect(scope['agent_id'], 'agt_1');
    expect(scope['session_id'], 'ses-1');
    expect(scope['mode_key'], StationModeKey.local);
  });

  test('插件用与核心在途请求撞号的 int id 发请求：仍判为请求（不被当回包吞掉）', () async {
    final PluginBus bus = await startBus(teamPluginIntIdYaml());
    final Map<String, dynamic> response = await pluginRequest(
      bus,
      method: 'station/command',
      params: <String, dynamic>{
        'command': 'fs.write',
        'arguments': <String, dynamic>{
          'agent_id': 'agt_1',
          'path': 'collision.txt',
          'content': '撞号也要回',
        },
      },
    );
    // 判别口径：**有 method ⇒ 请求**（JSON-RPC 的 Response 不带 method）。
    // 若按"int id 命中在途请求就当回包"，这里会把核心的 tools/call 用空 result
    // 提前完成，插件只能拿到超时兜底——本用例因此有牙齿。
    expect(response['result'], isNotNull, reason: '插件必须拿到一条真响应');
    final Map<String, dynamic> result =
        response['result'] as Map<String, dynamic>;
    expect(result['ok'], isTrue, reason: '${result['error']}');
    expect(
      File(p.join(workspace, 'collision.txt')).readAsStringSync(),
      '撞号也要回',
    );
  });

  test('未知 method ⇒ -32601（不静默）；随后请求照常', () async {
    final PluginBus bus = await startBus(teamPluginYaml());
    final Map<String, dynamic> response = await pluginRequest(
      bus,
      method: 'station/unknown',
      params: const <String, dynamic>{},
    );
    expect(response['result'], isNull);
    final Map<String, dynamic> error =
        response['error'] as Map<String, dynamic>;
    expect(error['code'], PluginRpcErrorCode.methodNotFound);
    expect(error['message'], contains('method not found'));
    expect(error['message'], contains('station/unknown'));

    // 宿主与请求通道不受影响：紧接着下一条真命令
    final Map<String, dynamic> follow = await pluginRequest(
      bus,
      method: 'station/command',
      params: <String, dynamic>{
        'command': 'fs.write',
        'arguments': <String, dynamic>{
          'agent_id': 'agt_1',
          'path': 'after-unknown.txt',
          'content': 'ok',
        },
      },
    );
    expect((follow['result'] as Map<String, dynamic>)['ok'], isTrue);

    // 缺 command / arguments 不是对象：也是显式错误（-32602），不是静默
    final Map<String, dynamic> missing = await pluginRequest(
      bus,
      method: 'station/command',
      params: const <String, dynamic>{},
    );
    expect(
      (missing['error'] as Map<String, dynamic>)['code'],
      PluginRpcErrorCode.invalidParams,
    );
    final Map<String, dynamic> badArgs = await pluginRequest(
      bus,
      method: 'station/command',
      params: <String, dynamic>{
        'command': 'fs.read',
        'arguments': <String>['not', 'an', 'object'],
      },
    );
    expect(
      (badArgs['error'] as Map<String, dynamic>)['code'],
      PluginRpcErrorCode.invalidParams,
    );
  });

  test('宿主：未接线 ⇒ -32601；处理器抛异常 ⇒ error 响应且读循环不受影响', () async {
    final PluginHost host = await PluginHost.start(
      PluginConfig(
        id: 'sample',
        command: Platform.resolvedExecutable,
        args: <String>[script, '--station-client'],
      ),
      coreVersion: 'test',
    );
    addTearDown(host.close);

    Future<Map<String, dynamic>> ask(String method) async {
      final PluginCallResult called = await host.callTool(
        'request_station',
        <String, dynamic>{
          'method': method,
          'params': const <String, dynamic>{},
        },
      );
      expect(called.isError, isFalse, reason: called.text);
      return jsonDecode(called.text) as Map<String, dynamic>;
    }

    // ① 未设置处理器：回 -32601（明确拒绝，不静默丢弃）
    final Map<String, dynamic> unwired = await ask('station/command');
    expect(unwired['result'], isNull);
    expect(
      (unwired['error'] as Map<String, dynamic>)['code'],
      PluginRpcErrorCode.methodNotFound,
    );

    // ② 接线后：处理器返回值成为 result
    host.onPluginRequest = (String method, Map<String, dynamic> params) async =>
        <String, dynamic>{'handled': method, 'params': params};
    final Map<String, dynamic> wired = await ask('station/command');
    expect(wired['result'], <String, dynamic>{
      'handled': 'station/command',
      'params': <String, dynamic>{},
    });

    // ③ 处理器抛异常：变成 error 响应（绝不冲掉读循环）
    host.onPluginRequest = (String method, Map<String, dynamic> params) async =>
        throw StateError('处理器炸了');
    final Map<String, dynamic> broken = await ask('station/command');
    expect(broken['result'], isNull);
    final Map<String, dynamic> brokenError =
        broken['error'] as Map<String, dynamic>;
    expect(brokenError['code'], PluginRpcErrorCode.internalError);
    expect(brokenError['message'], contains('处理器炸了'));

    // ④ 宿主仍然可用：心跳 + 普通工具调用 + 再发请求都照常
    expect(await host.ping(), isTrue);
    expect(
      (await host.callTool('echo', <String, dynamic>{'text': 'X'})).text,
      'plugin-echo: X',
    );
    host.onPluginRequest = (String method, Map<String, dynamic> params) async =>
        <String, dynamic>{'recovered': true};
    expect((await ask('station/command'))['result'], <String, dynamic>{
      'recovered': true,
    });
    expect(host.notifications, isEmpty, reason: '请求不是通知：不该落进通知转发口');
  });

  test('插件命令 ui.push ⇒ 核心按 card 槽位帧推到前端（带 team_id）', () async {
    final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
    final PluginBus bus = await startBus(
      teamPluginYaml(),
      broadcast: frames.add,
    );
    final Map<String, dynamic> response = await pluginRequest(
      bus,
      method: 'station/command',
      params: <String, dynamic>{
        'command': 'ui.push',
        'arguments': <String, dynamic>{
          'slot_key': 'sample.card.1',
          'view': <String, dynamic>{'type': 'text', 'text': '插件卡片'},
        },
      },
    );
    expect(
      (response['result'] as Map<String, dynamic>)['ok'],
      isTrue,
      reason: '${(response['result'] as Map<String, dynamic>)['error']}',
    );
    final Map<String, dynamic> frame = frames.singleWhere(
      (Map<String, dynamic> f) => f['type'] == PluginUiFrameType.update,
    );
    final Map<String, dynamic> data = frame['data'] as Map<String, dynamic>;
    expect(data['plugin_id'], 'sample');
    expect(data['team_id'], team, reason: '槽位帧一律带 team_id（1.2 隔离）');
    expect(data['slot_key'], 'sample.card.1');
    expect((data['view'] as Map<String, dynamic>)['text'], '插件卡片');
  });

  test('未声明 team 的插件 ui.push ⇒ 照推，帧的 team 为空 = 所有 team 都呈现', () async {
    final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
    final PluginBus bus = await startBus(
      noTeamPluginYaml(),
      broadcast: frames.add,
    );
    final Map<String, dynamic> response = await pluginRequest(
      bus,
      pluginId: 'noteam',
      method: 'station/command',
      params: <String, dynamic>{
        'command': 'ui.push',
        'arguments': <String, dynamic>{
          'slot_key': 'noteam.card.1',
          'view': <String, dynamic>{'type': 'text', 'text': '通配卡片'},
        },
      },
    );
    final Map<String, dynamic> result =
        response['result'] as Map<String, dynamic>;
    expect(result['ok'], isTrue, reason: '${result['error']}');
    final Map<String, dynamic> data =
        frames
                .singleWhere(
                  (Map<String, dynamic> f) =>
                      f['type'] == PluginUiFrameType.update,
                )['data']
            as Map<String, dynamic>;
    expect(
      data['team_id'],
      '',
      reason: '空 team 的槽位帧在前端对**所有 team** 可见（_visible 把空 team 当通配）',
    );
  });

  // ── 插件自建站（station/register）：转发型订阅者的出路 ──────────────────
  //
  // 为什么有这组：站点全局化后**每个点位只有一个订阅者**，插件要按 team / agent
  // 分开处理时，正解是"由一个转发型订阅者接管内置站，再在插件内建站点分发"——
  // 而"建站点"必须经核心，否则下游没有回包通道与等待链。

  /// 自建站的必填介绍（断言 3：`readme` 缺失直接拒绝注册）。
  const String selfReadme =
      '自建广播站：接管内置工具公告后按 team 再分发；'
      '订阅者回 payload = 附带再分发数据，回 null = 收到不改动';

  test('station/register：自建广播站 ⇒ id 由核心拼装（plugin.<自己>.<kind>.<name>）', () async {
    final PluginBus bus = await startBus(teamPluginYaml());

    final Map<String, dynamic> response = await pluginRequest(
      bus,
      method: 'station/register',
      params: <String, dynamic>{
        'kind': 'broadcast',
        'name': 'fanout',
        'description': '转发站：按 team 再分发',
        'readme': selfReadme,
      },
    );
    final Map<String, dynamic> result =
        response['result'] as Map<String, dynamic>;
    expect(result['ok'], isTrue, reason: '${result['error']}');
    expect(
      result['station_id'],
      'plugin.sample.broadcast.fanout',
      reason: 'id 由**核心**按插件身份拼：插件不能自选 id（归属强制点）',
    );
    // 真的落在站点中枢里，且是持久化实例（非内置）
    final StationInstance? station = bus.stations.station(
      'plugin.sample.broadcast.fanout',
    );
    expect(station, isA<BroadcastStation>());
    expect(station!.builtin, isFalse);
    expect(station.description, '转发站：按 team 再分发');
    // 断言 3：介绍落进实例（面板详情页读它）
    expect(station.readme, selfReadme);
    expect(station.readmeText, selfReadme);
    // 默认不共享：别人的插件既不能用它（断言 2 的闸门只认显式声明）
    expect(station.shared, isFalse);
    expect(station.allowedPlugins, isEmpty);
    expect(station.config, isEmpty);

    // 同名重复注册 = 幂等（插件重启后会再注册一遍，不能报错也不能覆盖）
    final Map<String, dynamic> again = await pluginRequest(
      bus,
      method: 'station/register',
      params: <String, dynamic>{
        'kind': 'broadcast',
        'name': 'fanout',
        'readme': '改写过的介绍',
      },
    );
    expect((again['result'] as Map<String, dynamic>)['ok'], isTrue);
    expect(
      (again['result'] as Map<String, dynamic>)['station_id'],
      result['station_id'],
    );
    expect(station.readme, selfReadme, reason: '幂等分支不覆盖既有站点：介绍也保持第一次注册的版本');
    expect(
      bus.stations
          .stationList()
          .where((StationInstance s) => !s.builtin)
          .length,
      1,
      reason: '没有建出第二条',
    );
  });

  test('station/register：name 非法 / 缺 readme / 执行站 / 收集站缺 schema 都是可读拒绝', () async {
    final PluginBus bus = await startBus(teamPluginYaml());

    // ① 缺 name
    final Map<String, dynamic> noName = await pluginRequest(
      bus,
      method: 'station/register',
      params: <String, dynamic>{'kind': 'relay'},
    );
    expect((noName['result'] as Map<String, dynamic>)['ok'], isFalse);
    expect(
      (noName['result'] as Map<String, dynamic>)['error'],
      contains('name'),
    );

    // ② name 里带点号：会与归属前缀判定冲突（插件 a 建 b.relay.x 顶掉 a.b 的站）
    final Map<String, dynamic> dotted = await pluginRequest(
      bus,
      method: 'station/register',
      params: <String, dynamic>{'kind': 'relay', 'name': 'a.b'},
    );
    expect((dotted['result'] as Map<String, dynamic>)['ok'], isFalse);
    expect(
      (dotted['result'] as Map<String, dynamic>)['error'],
      contains('只允许'),
    );

    // ③ 执行站不能自建（没有消费方：它由插件主动下命令）
    final Map<String, dynamic> execute = await pluginRequest(
      bus,
      method: 'station/register',
      params: <String, dynamic>{'kind': 'execute', 'name': 'x'},
    );
    expect((execute['result'] as Map<String, dynamic>)['ok'], isFalse);
    expect(
      (execute['result'] as Map<String, dynamic>)['error'],
      contains('station/command'),
      reason: '拒绝理由要指向正解',
    );

    // ④ 收集站必须带非空 schema（输入格式由站点定义）
    final Map<String, dynamic> collect = await pluginRequest(
      bus,
      method: 'station/register',
      params: <String, dynamic>{'kind': 'collect', 'name': 'probe'},
    );
    expect((collect['result'] as Map<String, dynamic>)['ok'], isFalse);
    expect(
      (collect['result'] as Map<String, dynamic>)['error'],
      contains('schema'),
    );

    // ⑥ **缺 readme ⇒ 拒绝**（断言 3：每个插件内置站点必须有介绍）。
    // 站是插件建的，"它干什么、别人该怎么用"只有建站的插件说得清；共享时
    // 这份介绍是别人唯一能读到的说明书，所以不能省。
    final Map<String, dynamic> noReadme = await pluginRequest(
      bus,
      method: 'station/register',
      params: <String, dynamic>{'kind': 'broadcast', 'name': 'silent'},
    );
    expect((noReadme['result'] as Map<String, dynamic>)['ok'], isFalse);
    expect(
      (noReadme['result'] as Map<String, dynamic>)['error'],
      contains('readme'),
      reason: '拒绝理由要点出缺的是介绍',
    );

    // ⑤ 类型未知 ⇒ 参数错误（JSON-RPC 层，不静默）
    final Map<String, dynamic> badKind = await pluginRequest(
      bus,
      method: 'station/register',
      params: <String, dynamic>{'kind': 'teleport', 'name': 'x'},
    );
    expect(badKind['result'], isNull);
    expect(
      (badKind['error'] as Map<String, dynamic>)['code'],
      PluginRpcErrorCode.invalidParams,
    );

    // 一个都不该留下
    expect(
      bus.stations.stationList().where((StationInstance s) => !s.builtin),
      isEmpty,
    );
  });

  test('station/register：自建收集站带 schema ⇒ 可建，且订阅上限可自报', () async {
    final PluginBus bus = await startBus(teamPluginYaml());

    final Map<String, dynamic> response = await pluginRequest(
      bus,
      method: 'station/register',
      params: <String, dynamic>{
        'kind': 'collect',
        'name': 'probe',
        'readme': selfReadme,
        'max_subscriptions': 3,
        'schema': <String, dynamic>{
          'description': '探针产出',
          'fields': <dynamic>[
            <String, dynamic>{'name': 'value', 'type': 'string', 'required': true},
          ],
        },
      },
    );
    final Map<String, dynamic> result =
        response['result'] as Map<String, dynamic>;
    expect(result['ok'], isTrue, reason: '${result['error']}');
    final StationInstance station = bus.stations.station(
      result['station_id'] as String,
    )!;
    expect(station, isA<CollectStation>());
    expect(station.maxSubscriptions, 3);
    expect(
      (station as CollectStation).schema.fields.map((dynamic f) => f.name),
      <String>['value'],
      reason: 'schema 跨注册保留（订阅者要按它产出）',
    );
  });

  test('station/register：不能冒用内置 id / 别人的命名空间；注销只能注销自己的', () async {
    final PluginBus bus = await startBus(twoPluginsYaml());

    // 先让 sample 建一个站
    final Map<String, dynamic> mine = await pluginRequest(
      bus,
      method: 'station/register',
      params: <String, dynamic>{
        'kind': 'broadcast',
        'name': 'mine',
        'readme': selfReadme,
      },
    );
    final String myId = (mine['result'] as Map<String, dynamic>)['station_id']
        as String;

    // ① 别的插件注销我的站 ⇒ 拒绝（归属校验）
    final Map<String, dynamic> steal = await pluginRequest(
      bus,
      pluginId: 'other',
      method: 'station/unregister',
      params: <String, dynamic>{'station_id': myId},
    );
    expect((steal['result'] as Map<String, dynamic>)['ok'], isFalse);
    expect(
      (steal['result'] as Map<String, dynamic>)['error'],
      contains('不属于插件 other'),
    );
    expect(bus.stations.station(myId), isNotNull, reason: '站还在');

    // ①b 另一个插件用自己的名字建站：**各自成站**（命名空间按插件隔离）
    final Map<String, dynamic> otherOwn = await pluginRequest(
      bus,
      pluginId: 'other',
      method: 'station/register',
      params: <String, dynamic>{
        'kind': 'broadcast',
        'name': 'mine',
        'readme': selfReadme,
      },
    );
    expect((otherOwn['result'] as Map<String, dynamic>)['ok'], isTrue);
    expect(
      (otherOwn['result'] as Map<String, dynamic>)['station_id'],
      'plugin.other.broadcast.mine',
      reason: '同名不会撞车：id 里带插件 id',
    );

    // ② 内置站不得注销（先让内置点位就位：站点是懒创建的，核心启动时会预建）
    expect(bus.stations.ensureBuiltinStations(), isNotEmpty);
    final Map<String, dynamic> builtin = await pluginRequest(
      bus,
      method: 'station/unregister',
      params: <String, dynamic>{'station_id': StationHubIds.relayToolPre},
    );
    expect((builtin['result'] as Map<String, dynamic>)['ok'], isFalse);
    expect(
      (builtin['result'] as Map<String, dynamic>)['error'],
      contains('内置'),
    );
    expect(bus.stations.station(StationHubIds.relayToolPre), isNotNull);

    // ③ 自己注销自己的：成功，且站点表里消失
    final Map<String, dynamic> gone = await pluginRequest(
      bus,
      method: 'station/unregister',
      params: <String, dynamic>{'kind': 'broadcast', 'name': 'mine'},
    );
    expect((gone['result'] as Map<String, dynamic>)['ok'], isTrue);
    expect(bus.stations.station(myId), isNull);

    // ④ 幂等：再注销一次不报错
    final Map<String, dynamic> again = await pluginRequest(
      bus,
      method: 'station/unregister',
      params: <String, dynamic>{'kind': 'broadcast', 'name': 'mine'},
    );
    expect((again['result'] as Map<String, dynamic>)['ok'], isTrue);
    expect(
      (again['result'] as Map<String, dynamic>)['notice'],
      contains('不存在'),
    );
  });

  test('station/register：自建站默认私有 ⇒ 别人既订不到也触发不了（断言 2 的反面）', () async {
    final PluginBus bus = await startBus(twoPluginsYaml());
    final Map<String, dynamic> created = await pluginRequest(
      bus,
      method: 'station/register',
      params: <String, dynamic>{
        'kind': 'relay',
        'name': 'forwarder',
        'readme': selfReadme,
      },
    );
    final String id =
        (created['result'] as Map<String, dynamic>)['station_id'] as String;

    // ① 自己订自己的自建站：成功（转发型订阅者的第一步）
    final Map<String, dynamic> sub = await pluginRequest(
      bus,
      method: 'station/subscribe',
      params: <String, dynamic>{'station_id': id},
    );
    final Map<String, dynamic> subResult =
        sub['result'] as Map<String, dynamic>;
    expect(subResult['ok'], isTrue, reason: '${subResult['error']}');
    expect(subResult['station_id'], id);
    expect(subResult['kind'], 'relay');
    expect(
      (bus.stations.station(id)! as RelayStation).subscribers.single.pluginId,
      'sample',
    );

    // ② 别的插件订它 ⇒ 拒（没声明 shared：任何插件都能挂上别人的拦截点）
    final Map<String, dynamic> other = await pluginRequest(
      bus,
      pluginId: 'other',
      method: 'station/subscribe',
      params: <String, dynamic>{'station_id': id},
    );
    expect((other['result'] as Map<String, dynamic>)['ok'], isFalse);
    expect(
      (other['result'] as Map<String, dynamic>)['error'],
      contains('不属于插件 other'),
    );

    // ②b 别的插件主动触发它 ⇒ 同样被拒（断言 2 只在建站方显式共享后才成立）
    final Map<String, dynamic> otherTrigger = await pluginRequest(
      bus,
      pluginId: 'other',
      method: 'station/trigger',
      params: <String, dynamic>{'station_id': id, 'payload': 'x'},
    );
    expect((otherTrigger['result'] as Map<String, dynamic>)['ok'], isFalse);
    expect(
      (otherTrigger['result'] as Map<String, dynamic>)['error'],
      contains('shared'),
      reason: '拒绝理由要指向正解：让建站方声明 shared',
    );

    // ②c 内置点位不可触发（它的触发时机由核心在固定接入点决定）
    expect(bus.stations.ensureBuiltinStations(), isNotEmpty);
    final Map<String, dynamic> builtinTrigger = await pluginRequest(
      bus,
      method: 'station/trigger',
      params: <String, dynamic>{
        'station_id': StationHubIds.broadcastToolPre,
        'topic': 'tool.pre',
      },
    );
    expect((builtinTrigger['result'] as Map<String, dynamic>)['ok'], isFalse);
    expect(
      (builtinTrigger['result'] as Map<String, dynamic>)['error'],
      contains('station/command'),
      reason: '要使用内置能力时正解是下命令，这里要把正解说出来',
    );

    // ③ 按 station_id 退订：幂等
    final Map<String, dynamic> unsub = await pluginRequest(
      bus,
      method: 'station/unsubscribe',
      params: <String, dynamic>{'station_id': id},
    );
    expect((unsub['result'] as Map<String, dynamic>)['removed'], 1);
    expect(bus.stations.station(id)!.subscribers, isEmpty);
  });

  // ── 跨插件调用自建站（shared + station/trigger）：断言 2 ────────────────
  //
  // 为什么要有这一组：自建站旧口径是「只能被自己的插件碰」（订阅都要校
  // plugin.{自己}. 前缀），所以下游只能由建站的插件自己接。现在由**建站方显式
  // 声明 shared** 把门推开：别人能订阅（成为加下游），也能触发（调用它）。

  test('自建站声明 shared ⇒ 别的插件可订阅，也可被 station/trigger 触发（断言 2）', () async {
    final PluginBus bus = await startBus(echoPluginsYaml());
    final Map<String, dynamic> created = await pluginRequest(
      bus,
      method: 'station/register',
      params: <String, dynamic>{
        'kind': 'broadcast',
        'name': 'fanout',
        'readme': selfReadme,
        'shared': true,
        'config': <String, dynamic>{'route': 'team'},
      },
    );
    final Map<String, dynamic> registered =
        created['result'] as Map<String, dynamic>;
    expect(registered['ok'], isTrue, reason: '${registered['error']}');
    final String id = registered['station_id'] as String;
    final StationInstance station = bus.stations.station(id)!;
    expect(station.shared, isTrue);
    expect(station.config, <String, dynamic>{'route': 'team'});

    // 断言 1：自建站**全局可见**——快照不按 team 过滤，左侧站点栏拿到的就是这一份
    expect(
      bus.stations.snapshot().any(
        (Map<String, dynamic> item) => item['station_id'] == id,
      ),
      isTrue,
    );

    // ① 别的插件订阅共享站：成功
    final Map<String, dynamic> subscribed = await pluginRequest(
      bus,
      pluginId: 'other',
      method: 'station/subscribe',
      params: <String, dynamic>{'station_id': id},
    );
    final Map<String, dynamic> sub =
        subscribed['result'] as Map<String, dynamic>;
    expect(sub['ok'], isTrue, reason: '${sub['error']}');
    expect(station.subscribers.single.pluginId, 'other');

    // ② 所有者触发自己的站 ⇒ 投给别人的订阅者，站点自定义配置随 meta 下发
    final Map<String, dynamic> fired = await pluginRequest(
      bus,
      method: 'station/trigger',
      params: <String, dynamic>{
        'station_id': id,
        'topic': 'fanout',
        'scope': <String, dynamic>{'mode_key': 'local'},
        'payload': <String, dynamic>{'text': 'hello'},
      },
    );
    final Map<String, dynamic> firedResult =
        fired['result'] as Map<String, dynamic>;
    expect(firedResult['ok'], isTrue, reason: '${firedResult['error']}');
    final Map<String, dynamic> detail =
        firedResult['result'] as Map<String, dynamic>;
    expect(detail['delivered'], 1, reason: '${detail['summary']}');
    final Map<String, dynamic> delivery =
        (detail['deliveries'] as List).single as Map<String, dynamic>;
    expect(delivery['plugin_id'], 'other');
    expect(delivery['ok'], isTrue, reason: '${delivery['error']}');
    final Map<String, dynamic> echoed =
        (delivery['payload'] as Map<String, dynamic>);
    expect(
      (echoed['meta'] as Map<String, dynamic>)['route'],
      'team',
      reason: '面板上配的站点参数必须能传到订阅者，否则“其他配置”就是摆设',
    );
    expect(
      (echoed['meta'] as Map<String, dynamic>)['triggered_by'],
      'sample',
      reason: '谁触发的要能让订阅者看到',
    );
    expect(echoed['echo'], isA<Map<String, dynamic>>(), reason: '载荷原样送到订阅者');

    // ③ 订阅方自己也能触发共享站（闸门只看声明，不看谁是所有者）
    final Map<String, dynamic> selfFired = await pluginRequest(
      bus,
      pluginId: 'other',
      method: 'station/trigger',
      params: <String, dynamic>{
        'station_id': id,
        'topic': 'fanout',
        'scope': <String, dynamic>{'mode_key': 'local'},
      },
    );
    expect(
      (selfFired['result'] as Map<String, dynamic>)['ok'],
      isTrue,
      reason: '${(selfFired['result'] as Map<String, dynamic>)['error']}',
    );

    // ③b 不带确定的 mode ⇒ 可读拒绝（空 mode 在订阅里是通配，在消息里定不了投递对象）
    final Map<String, dynamic> noMode = await pluginRequest(
      bus,
      method: 'station/trigger',
      params: <String, dynamic>{'station_id': id, 'topic': 'fanout'},
    );
    expect((noMode['result'] as Map<String, dynamic>)['ok'], isFalse);
    expect(
      (noMode['result'] as Map<String, dynamic>)['error'],
      contains('mode_key'),
      reason: '拒绝理由要指向可改的字段',
    );

    // ④ 缺 station_id ⇒ JSON-RPC 参数错（不静默吞掉）
    final Map<String, dynamic> noId = await pluginRequest(
      bus,
      method: 'station/trigger',
      params: <String, dynamic>{'topic': 'x'},
    );
    expect(noId['result'], isNull);
    expect(
      (noId['error'] as Map<String, dynamic>)['code'],
      PluginRpcErrorCode.invalidParams,
    );
  });

  test('shared 的 allowed_plugins ⇒ 只有名单内的插件能用（所有者不受限）', () async {
    final PluginBus bus = await startBus(echoPluginsYaml());
    final Map<String, dynamic> created = await pluginRequest(
      bus,
      method: 'station/register',
      params: <String, dynamic>{
        'kind': 'broadcast',
        'name': 'gated',
        'readme': selfReadme,
        'shared': true,
        'allowed_plugins': <String>['other'],
      },
    );
    final String id =
        (created['result'] as Map<String, dynamic>)['station_id'] as String;

    // ① 名单内的插件：能订能触发
    final Map<String, dynamic> sub = await pluginRequest(
      bus,
      pluginId: 'other',
      method: 'station/subscribe',
      params: <String, dynamic>{'station_id': id},
    );
    expect(
      (sub['result'] as Map<String, dynamic>)['ok'],
      isTrue,
      reason: '${(sub['result'] as Map<String, dynamic>)['error']}',
    );

    // ② 所有者不在名单里也永远能用：门是给别人的，不是防自己的
    final Map<String, dynamic> ownerFired = await pluginRequest(
      bus,
      method: 'station/trigger',
      params: <String, dynamic>{
        'station_id': id,
        'topic': 'gated',
        'scope': <String, dynamic>{'mode_key': 'local'},
      },
    );
    expect(
      (ownerFired['result'] as Map<String, dynamic>)['ok'],
      isTrue,
      reason: '${(ownerFired['result'] as Map<String, dynamic>)['error']}',
    );

    // ③ 换一个名单里没别人的站：同一把闸门，结论必须是拒绝
    final Map<String, dynamic> gated = await pluginRequest(
      bus,
      pluginId: 'other',
      method: 'station/register',
      params: <String, dynamic>{
        'kind': 'broadcast',
        'name': 'onlythem',
        'readme': selfReadme,
        'shared': true,
        'allowed_plugins': <String>['someone-else'],
      },
    );
    final String gatedId =
        (gated['result'] as Map<String, dynamic>)['station_id'] as String;
    final Map<String, dynamic> denied = await pluginRequest(
      bus,
      method: 'station/subscribe',
      params: <String, dynamic>{'station_id': gatedId},
    );
    expect((denied['result'] as Map<String, dynamic>)['ok'], isFalse);
    expect(
      (denied['result'] as Map<String, dynamic>)['error'],
      contains('白名单'),
      reason: '已共享但名单不含它：原因要说清是名单卡的',
    );
    // 触发同样被名单卡住（不能绕过订阅直接喊）
    final Map<String, dynamic> deniedFire = await pluginRequest(
      bus,
      method: 'station/trigger',
      params: <String, dynamic>{
        'station_id': gatedId,
        'topic': 'x',
        'scope': <String, dynamic>{'mode_key': 'local'},
      },
    );
    expect((deniedFire['result'] as Map<String, dynamic>)['ok'], isFalse);
    expect(
      (deniedFire['result'] as Map<String, dynamic>)['error'],
      contains('白名单'),
    );
  });

  test('站点所有者禁用订阅者 ⇒ 触发不再投递，原因写在 skipped（不静默）', () async {
    final PluginBus bus = await startBus(echoPluginsYaml());
    final Map<String, dynamic> created = await pluginRequest(
      bus,
      method: 'station/register',
      params: <String, dynamic>{
        'kind': 'broadcast',
        'name': 'fanout',
        'readme': selfReadme,
        'shared': true,
      },
    );
    final String id =
        (created['result'] as Map<String, dynamic>)['station_id'] as String;
    final Map<String, dynamic> sub = await pluginRequest(
      bus,
      pluginId: 'other',
      method: 'station/subscribe',
      params: <String, dynamic>{'station_id': id},
    );
    expect((sub['result'] as Map<String, dynamic>)['ok'], isTrue);
    final StationInstance station = bus.stations.station(id)!;
    final String key = station.subscribers.single.key;

    // ① 关掉：保留订阅（重启后不会被悄悄打开），但触发时不投
    expect(bus.stations.setSubscriberDisabled(id, key, true), isNull);
    expect(station.subscribers.single.disabled, isTrue);
    final Map<String, dynamic> fired = await pluginRequest(
      bus,
      method: 'station/trigger',
      params: <String, dynamic>{
        'station_id': id,
        'topic': 'fanout',
        'scope': <String, dynamic>{'mode_key': 'local'},
      },
    );
    final Map<String, dynamic> detail =
        ((fired['result'] as Map<String, dynamic>)['result'])
            as Map<String, dynamic>;
    expect(detail['delivered'], 0);
    expect(
      (detail['skipped'] as List).cast<String>(),
      containsAll(<String>['跳过 other：订阅者 other 已被本站所有者禁用']),
      reason: '${detail['summary']}：面板上关了什么必须在触发结果里看得见',
    );
    expect(station.counters['skipped_disabled'], 1);

    // ② 打开：立即恢复投递（改的是字段，不是重新订阅）
    expect(bus.stations.setSubscriberDisabled(id, key, false), isNull);
    final Map<String, dynamic> again = await pluginRequest(
      bus,
      method: 'station/trigger',
      params: <String, dynamic>{
        'station_id': id,
        'topic': 'fanout',
        'scope': <String, dynamic>{'mode_key': 'local'},
      },
    );
    final Map<String, dynamic> againDetail =
        ((again['result'] as Map<String, dynamic>)['result'])
            as Map<String, dynamic>;
    expect(againDetail['delivered'], 1, reason: '${againDetail['summary']}');

    // ③ 未知订阅键 ⇒ 可读错误（不假装成功）
    expect(
      bus.stations.setSubscriberDisabled(id, 'ghost|team-1', true),
      contains('订阅者不存在'),
    );
  });
}
