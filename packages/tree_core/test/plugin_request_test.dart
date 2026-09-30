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

  /// 没声明 team 的插件：站点四元组不成立 ⇒ 执行站必须显式拒绝（不静默）。
  String noTeamPluginYaml() =>
      'enabled: true\n'
      'plugins:\n'
      '  - id: noteam\n'
      '    name: 无归属插件\n'
      '    command: "${slash(Platform.resolvedExecutable)}"\n'
      '    args: ["${slash(script)}", "--station-client"]\n';

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
      bus.stations
          .stationList()
          .whereType<ExecuteStation>()
          .map((ExecuteStation s) => s.scope.teamId)
          .toSet(),
      <String>{'team-1', 'team-2'},
      reason: '两个团队的执行站都按真实归属建出来了（同一个插件实例）',
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
    expect((response['result'] as Map<String, dynamic>)['ok'], isTrue);
    final Map<String, dynamic> frame = frames.singleWhere(
      (Map<String, dynamic> f) => f['type'] == PluginUiFrameType.update,
    );
    final Map<String, dynamic> data = frame['data'] as Map<String, dynamic>;
    expect(data['plugin_id'], 'sample');
    expect(data['team_id'], team, reason: '槽位帧一律带 team_id（1.2 隔离）');
    expect(data['slot_key'], 'sample.card.1');
    expect((data['view'] as Map<String, dynamic>)['text'], '插件卡片');
  });
}
