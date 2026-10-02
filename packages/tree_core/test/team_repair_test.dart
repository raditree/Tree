import 'dart:io';

import 'package:test/test.dart';
import 'package:tree_core/tree_core.dart';

/// 团队关系自愈（删 agent 留下的悬空 parent/team 指针）。
void main() {
  late Directory temp;
  late TreePaths paths;
  late FileTreeStore store;
  late TeamService teams;
  late CoreAgent top;
  late List<String> logs;

  Future<TeamRepairReport> repair() => repairTeamLinks(
    store,
    backup: (CoreAgent agent) => backupAgentFile(paths, agent.id),
    log: logs.add,
  );

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('team_repair');
    paths = TreePaths(temp.path);
    await paths.ensureLayout();
    store = FileTreeStore(paths);
    teams = TeamService(store: store, settings: CoreSettings());
    top = store.createAgent(
      name: '队长',
      modelId: '',
      maxLevel: 3,
      maxMembersPerLevel: 7,
    );
    logs = <String>[];
  });

  tearDown(() async {
    await store.flush();
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  String member(String name, String parent) =>
      teams.createMember(parent, <String, dynamic>{
        'action': 'create_member',
        'member_name': name,
      })['member_id'] as String;

  test('上级被删：重挂到 TOP + 子树层级平移 + 先备份后写盘', () async {
    final String leader = member('组长', top.id);
    final String kid = member('组员', leader);
    await store.flush();
    // 用户手删（或历史数据里已经这样了）：直接删掉中间层 leader
    expect(store.deleteAgent(leader), isTrue);
    await store.flush();
    final CoreAgent orphan = store.agent(kid)!;
    expect(orphan.parentAgentId, leader, reason: '删除前的悬空状态');
    expect(orphan.level, 2);
    expect(store.agent(top.id)!.teamMemberCount, 2, reason: '用户侧删除不回填（历史遗留）');

    final TeamRepairReport report = await repair();
    expect(report.changedCount, 1);
    final TeamLinkRepair fix = report.repairs.single;
    expect(fix.agentId, kid);
    expect(fix.action, TeamLinkRepair.reparented);
    expect(fix.brokenParentId, leader);
    expect(fix.newParentId, top.id);
    expect(fix.newTeamId, top.id);
    expect(fix.oldLevel, 2);
    expect(fix.newLevel, 1, reason: '重挂到 TOP ⇒ 层级回到 TOP+1');
    expect(fix.backupPath, endsWith('$kid.yaml.bak.1'));

    final CoreAgent fixed = store.agent(kid)!;
    expect(fixed.parentAgentId, top.id);
    expect(fixed.teamId, top.id);
    expect(fixed.level, 1);
    expect(store.members(top.id).map((CoreAgent a) => a.id), <String>[kid]);
    expect(store.agent(top.id)!.teamMemberCount, 1, reason: '计数按实际成员数回填');
    expect(report.memberCountSynced, <String>[top.id]);
    expect(logs.any((String l) => l.contains('reparented')), isTrue);

    // 磁盘上真的改了（新开一个 store 重新装载，不靠内存）
    final FileTreeStore reloaded = FileTreeStore(paths);
    expect(reloaded.agent(kid)!.parentAgentId, top.id);
    expect(reloaded.agent(kid)!.teamId, top.id);
    expect(reloaded.agent(kid)!.level, 1);
    await reloaded.flush();
  });

  test('TOP 也被删：最上层孤儿升为独立顶层 agent，子树跟着平移', () async {
    final String a = member('甲', top.id);
    final String b = member('乙', a);
    await store.flush();
    expect(store.deleteAgent(top.id), isTrue);
    await store.flush();

    final TeamRepairReport report = await repair();
    expect(report.changedCount, 2, reason: '根 + 它的下级都要改写');
    final CoreAgent promoted = store.agent(a)!;
    expect(promoted.teamId, '');
    expect(promoted.parentAgentId, '');
    expect(promoted.level, 0);
    final CoreAgent child = store.agent(b)!;
    expect(child.parentAgentId, a, reason: '父子关系保留');
    expect(child.teamId, a, reason: '归属挪到新顶层自己');
    expect(child.level, 1);
    expect(store.teams().map((CoreAgent x) => x.id), <String>[a]);
    expect(store.members(a).map((CoreAgent x) => x.id), <String>[b]);
  });

  test('team_id 悬空但父链完好：按父链修正归属，不动 level', () async {
    final String a = member('甲', top.id);
    final CoreAgent b = store.createAgent(name: '乙');
    b
      ..parentAgentId = a
      ..teamId = 'agt_ghost'
      ..level = 5;
    store.putAgent(b);
    await store.flush();

    final TeamRepairReport report = await repair();
    expect(report.changedCount, 1);
    expect(report.repairs.single.action, TeamLinkRepair.normalized);
    expect(store.agent(b.id)!.teamId, top.id, reason: '按父链解析到 TOP');
    expect(store.agent(b.id)!.level, 5, reason: '这条规则不动 level');
  });

  test('幂等：修完再跑一次没有任何动作，也不产生第二个备份', () async {
    final String leader = member('组长', top.id);
    final String kid = member('组员', leader);
    await store.flush();
    store.deleteAgent(leader);
    await store.flush();
    final TeamRepairReport first = await repair();
    expect(first.changedCount, 1);
    // 两条备份：被修的成员 + 计数回填过的 TOP（陈旧计数也顺手修正）
    final List<String> backups = <String>[
      for (final FileSystemEntity entity in Directory(paths.agentsDir).listSync())
        entity.path,
    ]..removeWhere((String p) => !p.contains('.bak.'));
    expect(backups, hasLength(2));

    final TeamRepairReport second = await repair();
    expect(second.isEmpty, isTrue);
    final List<String> backupsAfter = <String>[
      for (final FileSystemEntity entity in Directory(paths.agentsDir).listSync())
        entity.path,
    ]..removeWhere((String p) => !p.contains('.bak.'));
    expect(backupsAfter, hasLength(2), reason: '幂等：不该再多一个备份');
    expect(store.agent(kid)!.teamId, top.id);
  });

  test('backupAgentFile：序号递增、绝不覆盖旧备份', () async {
    final CoreAgent a = store.createAgent(name: '甲');
    await store.flush();
    final String first = await backupAgentFile(paths, a.id);
    final String second = await backupAgentFile(paths, a.id);
    expect(first, endsWith('.bak.1'));
    expect(second, endsWith('.bak.2'));
    expect(File(first).existsSync(), isTrue);
    expect(File(second).existsSync(), isTrue);
    expect(await backupAgentFile(paths, 'agt_missing'), '');
  });

  test('内存实现（没有盘）：只改内存、不碰文件也能修好', () async {
    final MemoryStore memory = MemoryStore();
    final CoreAgent t = memory.createAgent(name: '队长');
    final CoreAgent m = memory.createAgent(name: '成员')
      ..teamId = t.id
      ..parentAgentId = 'agt_ghost'
      ..level = 3;
    memory.putAgent(m);
    final TeamRepairReport report = await repairTeamLinks(memory);
    expect(report.changedCount, 1);
    expect(report.repairs.single.action, TeamLinkRepair.reparented);
    expect(memory.agent(m.id)!.parentAgentId, t.id);
    expect(memory.agent(m.id)!.level, 1);
  });

  test('健康的库：一个动作都不做', () async {
    member('甲', top.id);
    await store.flush();
    final TeamRepairReport report = await repair();
    expect(report.isEmpty, isTrue);
    expect(logs, isEmpty);
  });
}

