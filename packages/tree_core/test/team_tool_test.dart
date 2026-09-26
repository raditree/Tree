import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// `team` 工具：声明条件、schema 边界与"不依赖工作空间"。
void main() {
  late MemoryStore store;
  late TeamService service;
  late CoreAgent top;

  setUp(() {
    store = MemoryStore();
    service = TeamService(store: store, settings: CoreSettings());
    top = store.createAgent(name: '队长');
  });

  test('只在接入团队服务时声明 team；未接入时不声明', () {
    expect(
      BuiltinTools.specs().map((ToolSpec s) => s.name),
      isNot(contains(TeamTool.name)),
    );
    expect(
      BuiltinTools.specs(withTeam: true).map((ToolSpec s) => s.name),
      contains(TeamTool.name),
    );
    expect(BuiltinTools.needsWorkspace(TeamTool.name), isFalse);
  });

  test('schema：action 必填且枚举 8 个；**没有 model 能力**（不出现 model_id）', () {
    final ToolSpec spec = TeamTool.spec();
    expect(spec.name, 'team');
    final Map<String, dynamic> parameters = spec.parameters;
    expect(parameters['required'], <String>['action']);
    final Map<String, dynamic> properties =
        parameters['properties'] as Map<String, dynamic>;
    expect(
      (properties['action'] as Map<String, dynamic>)['enum'],
      TeamService.actions,
    );
    expect(TeamService.actions, hasLength(8));
    expect(
      properties.containsKey('model_id'),
      isFalse,
      reason: 'team 工具无权分配模型，schema 里就不该出现 model_id',
    );
    expect(spec.description, contains('没有'));
    expect(spec.description, contains('模型'));
  });

  test('工具调用：工作空间不可用也能用；成功返回 JSON、失败带 error+hint', () async {
    final Directory temp = Directory.systemTemp.createTempSync(
      'tree_team_tool_',
    );
    addTearDown(() async {
      for (int i = 0; i < 5; i++) {
        try {
          if (temp.existsSync()) temp.deleteSync(recursive: true);
          return;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });
    final WorkspaceToolRunner runner = WorkspaceToolRunner(
      resolveWorkspaceDir: (String _) => temp.path,
      teamService: service,
    );
    final List<String> names = runner
        .specsFor(agentId: top.id, sessionId: TreeStore.defaultSessionId)
        .map((ToolSpec s) => s.name)
        .toList();
    expect(names, contains(TeamTool.name));

    final ToolOutcome created = await runner.run(
      ToolInvocation(
        id: 't1',
        name: TeamTool.name,
        arguments: <String, dynamic>{
          'action': 'create_member',
          'member_name': '成员甲',
        },
        agentId: top.id,
        sessionId: TreeStore.defaultSessionId,
      ),
    );
    expect(created.isError, isFalse);
    expect(created.content, contains('pending_model'));

    final ToolOutcome listed = await runner.run(
      ToolInvocation(
        id: 't2',
        name: TeamTool.name,
        arguments: <String, dynamic>{'action': 'list_members'},
        agentId: top.id,
        sessionId: TreeStore.defaultSessionId,
      ),
    );
    expect(listed.isError, isFalse);
    expect(listed.content, contains('成员甲'));
    expect(listed.content, contains('not_ready_count'));

    final ToolOutcome bad = await runner.run(
      ToolInvocation(
        id: 't3',
        name: TeamTool.name,
        arguments: <String, dynamic>{'action': 'nope'},
        agentId: top.id,
        sessionId: TreeStore.defaultSessionId,
      ),
    );
    expect(bad.isError, isTrue);
    expect(bad.content, contains('未知 action: nope'));
    expect(bad.content, contains('hint'));
    await runner.close();
  });

  test('团队工具与工作空间工具共存：read 仍要求工作空间', () async {
    final WorkspaceToolRunner runner = WorkspaceToolRunner(
      resolveWorkspaceDir: (String _) => '',
      teamService: service,
    );
    final ToolOutcome team = await runner.run(
      ToolInvocation(
        id: 't1',
        name: TeamTool.name,
        arguments: <String, dynamic>{'action': 'list_teams'},
        agentId: top.id,
        sessionId: TreeStore.defaultSessionId,
      ),
    );
    expect(team.isError, isFalse);
    final ToolOutcome read = await runner.run(
      ToolInvocation(
        id: 't2',
        name: BuiltinTools.read,
        arguments: <String, dynamic>{'file_path': 'a.txt'},
        agentId: top.id,
        sessionId: TreeStore.defaultSessionId,
      ),
    );
    expect(read.isError, isTrue);
    expect(read.content, contains('无法准备工作空间'));
    await runner.close();
  });
}
