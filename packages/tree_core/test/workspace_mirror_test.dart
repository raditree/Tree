import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 团队共享工作目录的**镜像**（用户断言 2026-10-03）：
///
/// > TOP 删除后成员 agent 升级为 TOP **不可以**重新选择工作目录
/// >（意味着配置不能留空，根据 TOP 填写）。
///
/// 成员的 `workspace_dir` 是"团队 TOP 那份配置的派生副本"：运行期解析**不**看它
/// （工具一律用 teamWorkspaceFor 取归属者的目录，见 team_workspace.dart），它只保证
/// 两件事——界面能显示成员实际在用的目录；TOP 被外部删除、成员升为 TOP 时目录
/// **无损交接**（否则成员会悄悄落到 `workspaces/<member_id>`，用户看到"文件不见了"）。
void main() {
  String defaultDirFor(String agentId) => '/data/workspaces/$agentId';

  CoreAgent make({
    required String id,
    String dir = '',
    String teamId = '',
    String parent = '',
    int level = 0,
    int created = 1,
  }) => CoreAgent(
    id: id,
    name: id,
    createdAt: created,
    updatedAt: created,
    workspaceDir: dir,
    teamId: teamId,
    parentAgentId: parent,
    level: level,
  );

  test('自愈镜像：成员跟随 TOP 已配置的目录', () async {
    final MemoryStore store = MemoryStore();
    store.putAgent(make(id: 'top', dir: '/proj/qi'));
    store.putAgent(make(id: 'm1', teamId: 'top', parent: 'top', level: 1));
    final WorkspaceMirrorReport report = await syncWorkspaceMirrors(
      store,
      defaultDirFor: defaultDirFor,
    );
    expect(report.mirrored, <String, String>{'m1': '/proj/qi'});
    expect(store.agent('m1')!.workspaceDir, '/proj/qi');
  });

  test('TOP 未配置目录时镜像 TOP 的默认目录', () async {
    final MemoryStore store = MemoryStore();
    store.putAgent(make(id: 'top'));
    store.putAgent(make(id: 'm1', teamId: 'top', parent: 'top', level: 1));
    await syncWorkspaceMirrors(store, defaultDirFor: defaultDirFor);
    expect(store.agent('m1')!.workspaceDir, '/data/workspaces/top');
  });

  test('多级成员一路向上取团队 TOP 的目录', () async {
    final MemoryStore store = MemoryStore();
    store.putAgent(make(id: 'top', dir: '/proj/qi'));
    store.putAgent(make(id: 'mid', teamId: 'top', parent: 'top', level: 1));
    store.putAgent(make(id: 'leaf', teamId: 'top', parent: 'mid', level: 2));
    await syncWorkspaceMirrors(store, defaultDirFor: defaultDirFor);
    expect(store.agent('mid')!.workspaceDir, '/proj/qi');
    expect(store.agent('leaf')!.workspaceDir, '/proj/qi');
  });

  test('绝不改 TOP 自己的配置，且幂等', () async {
    final MemoryStore store = MemoryStore();
    store.putAgent(make(id: 'top', dir: '/proj/qi'));
    store.putAgent(
      make(id: 'm1', dir: '/stale', teamId: 'top', parent: 'top', level: 1),
    );
    final WorkspaceMirrorReport first = await syncWorkspaceMirrors(
      store,
      defaultDirFor: defaultDirFor,
    );
    expect(first.mirrored, hasLength(1));
    expect(
      store.agent('top')!.workspaceDir,
      '/proj/qi',
      reason: 'TOP 的目录是用户配置项，不在这条链上',
    );
    final WorkspaceMirrorReport second = await syncWorkspaceMirrors(
      store,
      defaultDirFor: defaultDirFor,
    );
    expect(second.isEmpty, isTrue, reason: '幂等：再跑一次不该有任何动作');
  });

  test('断言：TOP 被删后成员升为 TOP，目录从 TOP 继承且不退化成空', () async {
    final MemoryStore store = MemoryStore();
    store.putAgent(make(id: 'top', dir: '/proj/qi'));
    store.putAgent(make(id: 'm1', teamId: 'top', parent: 'top', level: 1));
    // 先镜像（等价于"成员创建时 / 上次启动时"写下的那份副本），
    // 再模拟"TOP 被外部删除"（手删 agents/<top>.yaml / 历史遗留数据）。
    await syncWorkspaceMirrors(store, defaultDirFor: defaultDirFor);
    store.deleteAgent('top');

    final TeamRepairReport repair = await repairTeamLinks(store);
    final CoreAgent promoted = store.agent('m1')!;
    expect(repair.repairs.single.action, TeamLinkRepair.promoted);
    expect(promoted.teamId, '');
    expect(promoted.parentAgentId, '');
    expect(promoted.level, 0);
    expect(
      promoted.workspaceDir,
      '/proj/qi',
      reason: '升为 TOP 后不许退回"未选择工作目录"：必须按原 TOP 的目录填好',
    );
  });

  test('断言（团队本来就没配置目录时同样成立）：升级后拿到原 TOP 的默认目录', () async {
    final MemoryStore store = MemoryStore();
    store.putAgent(make(id: 'top'));
    store.putAgent(make(id: 'm1', teamId: 'top', parent: 'top', level: 1));
    await syncWorkspaceMirrors(store, defaultDirFor: defaultDirFor);
    store.deleteAgent('top');
    await repairTeamLinks(store);
    // 路径里带的是**原 TOP 的 id**：这正是要点——升级前后工具跑的是同一个目录
    // （否则成员会掉进 workspaces/<member_id>，用户看到"文件不见了"）。
    expect(store.agent('m1')!.workspaceDir, '/data/workspaces/top');
  });

  test('建成员时就镜像（不依赖下次启动的自愈）', () {
    final MemoryStore store = MemoryStore();
    final CoreAgent top = store.createAgent(name: '队长');
    top.workspaceDir = '/proj/qi';
    store.putAgent(top);
    final TeamService teams = TeamService(
      store: store,
      defaultWorkspaceDir: defaultDirFor,
    );
    final Map<String, dynamic> result = teams.createMember(
      top.id,
      <String, dynamic>{'action': 'create_member', 'member_name': '成员甲'},
    );
    final CoreAgent member = store.agent(result['member_id'] as String)!;
    expect(member.workspaceDir, '/proj/qi');
  });
}
