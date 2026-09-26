import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// CoreServer 的站点接线（M9 Wave 3-I）：
/// 核心一启动就把执行站首命令集的**挂载位置**接上，并把运行期四元组的两个解析器
/// （team ← agent 归属、mode_key ← agent 工作空间模式）注入插件总线。
///
/// 这里跑的是**真实核心 + 真实工作空间 IO**（不注入假挂载），因此「暂无挂载位置」
/// 与「SSH 命令打到本地工作空间」这两类问题都能在这里被挡住。
void main() {
  late Directory temp;
  late String workspace;
  late MemoryStore store;
  late CoreAgent agent;
  late PluginBus bus;
  late CoreServer server;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('tree_station_wire_');
    workspace = p.join(temp.path, 'ws');
    Directory(workspace).createSync(recursive: true);
    store = MemoryStore();
    agent = store.createAgent(name: '甲', modelId: 'demo');
    agent.teamId = 'team-1';
    agent.workspaceDir = workspace;
    store.putAgent(agent);

    final File file = File('${temp.path}/config/plugins.yaml');
    file.createSync(recursive: true);
    file.writeAsStringSync('enabled: true\nplugins: []\n');
    bus = PluginBus(
      configFile: file.path,
      heartbeatInterval: const Duration(seconds: 30),
    );
    server = await CoreServer.start(
      store: store,
      pluginBus: bus,
      specIoFor: (String agentId) async =>
          agentId == agent.id ? LocalWorkspaceIO(workspace) : null,
      enableHeartbeat: false,
      streamChunkDelay: Duration.zero,
      engine: ScriptedAgent(chunkDelay: Duration.zero),
    );
  });

  tearDown(() async {
    await server.close();
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

  ExecuteStation station(String modeKey) => bus.stations.executeFor(
    StationScope(teamId: 'team-1', modeKey: modeKey),
  )!;

  test('核心启动即挂载八条命令（不再返回「暂无挂载位置」）', () {
    expect(
      station(StationModeKey.local)
          .mounts()
          .map((StationCommandMount m) => m.command)
          .toSet(),
      ExecuteStation.builtinCommands,
    );
  });

  test('运行期四元组：team 取 agent 归属、mode_key 取工作空间模式', () {
    final StationScope local = bus.runtimeScopeFor(
      agentId: agent.id,
      sessionId: 'ses_1',
    );
    expect(local.teamId, 'team-1', reason: 'team 从 agent 归属解析');
    expect(local.modeKey, StationModeKey.local);
    expect(local.agentId, agent.id);

    // 同一个 agent 配上 SSH 后：mode_key 变成 ssh（插件命令因此不会打到本地工作空间）
    agent.sshConfig = SshConfig(host: 'example.com', username: 'open');
    store.putAgent(agent);
    expect(
      bus.runtimeScopeFor(agentId: agent.id, sessionId: 'ses_1').modeKey,
      StationModeKey.ssh,
    );
  });

  test('端到端：fs.write / fs.read / fs.list 落在 agent 的工作空间里', () async {
    final ExecuteStation execute = station(StationModeKey.local);
    final StationScope scope = bus.runtimeScopeFor(
      agentId: agent.id,
      sessionId: 'ses_1',
    );

    final StationCommandResult write = await execute.execute(
      command: 'fs.write',
      scope: scope,
      arguments: <String, dynamic>{
        'agent_id': agent.id,
        'path': 'notes/a.txt',
        'content': '接线完成',
      },
    );
    expect(write.ok, isTrue, reason: write.error);
    expect(
      File(p.join(workspace, 'notes', 'a.txt')).readAsStringSync(),
      '接线完成',
    );

    final StationCommandResult read = await execute.execute(
      command: 'fs.read',
      scope: scope,
      arguments: <String, dynamic>{'agent_id': agent.id, 'path': 'notes/a.txt'},
    );
    expect(read.ok, isTrue, reason: read.error);
    expect((read.payload! as Map<String, dynamic>)['content'], '接线完成');

    final StationCommandResult list = await execute.execute(
      command: 'fs.list',
      scope: scope,
      arguments: <String, dynamic>{'agent_id': agent.id, 'path': 'notes'},
    );
    expect(list.ok, isTrue, reason: list.error);
    expect(
      ((list.payload! as Map<String, dynamic>)['entries'] as List<dynamic>),
      isNotEmpty,
    );
  });

  test('端到端：SSH 模式的命令不许打到本地工作空间（跨模式拒绝）', () async {
    final ExecuteStation ssh = station(StationModeKey.ssh);
    final StationCommandResult denied = await ssh.execute(
      command: 'fs.read',
      scope: StationScope(
        teamId: 'team-1',
        agentId: agent.id,
        sessionId: 'ses_1',
        modeKey: StationModeKey.ssh,
      ),
      arguments: <String, dynamic>{'agent_id': agent.id, 'path': 'notes/a.txt'},
    );
    expect(denied.ok, isFalse);
    expect(denied.error, contains('跨模式'));
  });

  test('端到端：agent.stop 走既有级联停止路径；未接线的服务显式报错', () async {
    final ExecuteStation execute = station(StationModeKey.local);
    final StationScope scope = bus.runtimeScopeFor(
      agentId: agent.id,
      sessionId: 'ses_1',
    );

    final StationCommandResult stop = await execute.execute(
      command: 'agent.stop',
      scope: scope,
      arguments: <String, dynamic>{'agent_id': agent.id},
    );
    expect(stop.ok, isTrue, reason: stop.error);
    final Map<String, dynamic> payload = stop.payload! as Map<String, dynamic>;
    expect(payload['cascade_ids'], <String>[agent.id]);
    expect(payload['any_running'], isFalse);
    expect(payload['reason'], contains('没有进行中的任务'));

    // compaction 没接：agent.compact 必须显式报错（不静默成功）
    final StationCommandResult compact = await execute.execute(
      command: 'agent.compact',
      scope: scope,
      arguments: <String, dynamic>{'agent_id': agent.id},
    );
    expect(compact.ok, isFalse);
    expect(compact.error, contains('压缩'));
  });
}
