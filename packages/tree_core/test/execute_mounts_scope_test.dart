import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';
import 'package:tree_local_exec/tree_local_exec.dart';

/// 「顶层 agent 自成一队」的口径回归（Q2）。
///
/// 站点体系按 (team, mode) 预建/取执行站时，顶层 agent（`team_id` 为空）用**它自己
/// 的 id** 当 team；挂载位置的归属解析必须同口径，否则针对顶层 agent 的执行站命令
/// 会被误判成"没有团队归属"而全部拒绝。
void main() {
  test('顶层 agent（team_id 为空）自成一队：执行站命令能落到它的工作空间', () async {
    final Directory temp = Directory.systemTemp.createTempSync(
      'tree_exec_top_',
    );
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final MemoryStore store = MemoryStore();
    final CoreAgent agent = store.createAgent(name: '顶层', modelId: 'demo');
    expect(agent.teamId, isEmpty, reason: '顶层 agent 的 team_id 就是空');

    final ExecuteStationMounts mounts = ExecuteStationMounts.forStore(
      store: store,
      ioFor: (String agentId) async => LocalWorkspaceIO(temp.path),
    );
    addTearDown(mounts.close);

    final ExecuteStation station = ExecuteStation(
      id: 'exec:${agent.id}:local',
      description: '测试执行站',
      scope: StationScope(teamId: agent.id, modeKey: StationModeKey.local),
    );
    expect(mounts.mountInto(station), isNull);

    final StationCommandResult result = await station.execute(
      command: 'fs.write',
      scope: StationScope(
        teamId: agent.id,
        agentId: agent.id,
        modeKey: StationModeKey.local,
      ),
      arguments: <String, dynamic>{
        'agent_id': agent.id,
        'path': 'top.txt',
        'content': 'ok',
      },
    );
    expect(result.ok, isTrue, reason: result.error);
    expect(File('${temp.path}/top.txt').readAsStringSync(), 'ok');
  });
}
