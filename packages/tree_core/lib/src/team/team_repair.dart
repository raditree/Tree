import 'dart:io';

import 'package:path/path.dart' as p;

import '../store/tree_paths.dart';
import '../store/tree_store.dart';

/// 一次团队关系自愈动作（一条 = 一个 agent 的团队字段被改写）。
class TeamLinkRepair {
  const TeamLinkRepair({
    required this.agentId,
    required this.name,
    required this.action,
    required this.brokenParentId,
    required this.brokenTeamId,
    required this.newParentId,
    required this.newTeamId,
    required this.oldLevel,
    required this.newLevel,
    this.backupPath = '',
  });

  /// 上级被删：重挂到存活的团队 TOP（`team_id` 仍是活的）。
  static const String reparented = 'reparented';

  /// 团队 TOP 也没了：升为独立顶层 agent（`team_id`/`parent_agent_id` 清空、level 归 0）。
  static const String promoted = 'promoted';

  /// `team_id` 悬空但父链完好：按父链修正归属（不动 level）。
  static const String normalized = 'normalized';

  final String agentId;
  final String name;
  final String action;

  /// 改写前的悬空上级（空 = 本来就没有上级）。
  final String brokenParentId;

  /// 改写前的悬空团队 id（空 = 本来就没有团队）。
  final String brokenTeamId;

  final String newParentId;
  final String newTeamId;
  final int oldLevel;
  final int newLevel;

  /// `.bak.<n>` 备份路径（未写盘/未备份时为空）。
  final String backupPath;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'agent_id': agentId,
    'name': name,
    'action': action,
    'broken_parent_id': brokenParentId,
    'broken_team_id': brokenTeamId,
    'new_parent_id': newParentId,
    'new_team_id': newTeamId,
    'old_level': oldLevel,
    'new_level': newLevel,
    if (backupPath.isNotEmpty) 'backup': backupPath,
  };
}

/// 自愈结果（日志 / 自检 / 测试断言用）。
class TeamRepairReport {
  final List<TeamLinkRepair> repairs = <TeamLinkRepair>[];

  /// 被回填过 `team_member_count` 的 TOP id（含历史遗留的陈旧计数）。
  final List<String> memberCountSynced = <String>[];

  bool get isEmpty => repairs.isEmpty && memberCountSynced.isEmpty;
  int get changedCount => repairs.length;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'repaired': repairs.length,
    'repairs': repairs.map((TeamLinkRepair r) => r.toJson()).toList(),
    'member_count_synced': memberCountSynced,
  };
}

/// 团队关系自愈：修复指向**不存在的 agent** 的 `parent_agent_id` / `team_id`。
///
/// 为什么需要它：用户直接 `DELETE /api/agents/{id}` 删掉一个中间层 leader 或整个 TOP 时，
/// 下级 agent 文件仍留着悬空的 `parent_agent_id`（删中间层）或悬空的 `team_id`（删 TOP）。
/// 实测后果：`directMembers` 够不着（广播不达）、`cascadeIds` 够不着（级联停止/删除失效）、
/// team 工具再也删不掉它们（`_subtree` 同样沿父链走），而它们**还会被寻址、还能干活**——
/// 也就是「删不掉也停不了的影子成员」。
///
/// 三条修复规则（顺序执行，全部只改必要的字段）：
/// 1. **上级被删**：`team_id` 仍能解析到存活 TOP ⇒ 重挂到 TOP，`level = TOP.level + 1`，
///    并把它整棵子树的 `team_id`/`level` 一起平移（层级是相对量，必须整体搬）；
/// 2. **团队也没了** ⇒ 最上层孤儿**升为独立顶层 agent**（`team_id`/`parent_agent_id` 清空、
///    `level = 0`），子树同样平移（`team_id` 指到新顶层自己的 id）；
/// 3. **`team_id` 悬空但父链完好**（手改 yaml 或历史数据）⇒ 按父链修正归属，不动 level。
///
/// 写盘口径（2026-10-02 定稿）：**修好就写盘**，但每个被改的 `agents/<id>.yaml` 先备份成
/// `.bak.<n>`（`n` 递增、绝不覆盖旧备份，与「重置系统提示词/Spec」同一约定）。为什么不是
/// 只改内存：磁盘才是权威（本项目口径是「yaml 人类可直接读、可手改」），只在内存修会让
/// 文件说 A、运行期是 B，而任何一次后续写入又会把内存值固化——不如一次说清、留好备份。
///
/// 幂等：修完再跑一次不会有任何动作（`report.isEmpty == true`）。
///
/// [backup] 传 null（内存实现 / 无盘场景）时只改内存不落盘。
Future<TeamRepairReport> repairTeamLinks(
  TreeStore store, {
  Future<String> Function(CoreAgent agent)? backup,
  void Function(String message)? log,
}) async {
  // `agents()` 会触发全量装载：必须先把所有 agent 读进内存再改，否则 `_loadAgent`
  // 的「磁盘是权威」逻辑会把改好的对象又用文件覆盖回去。
  final List<CoreAgent> agents = store.agents().toList();
  final Map<String, CoreAgent> byId = <String, CoreAgent>{
    for (final CoreAgent agent in agents) agent.id: agent,
  };
  final TeamRepairReport report = TeamRepairReport();
  if (agents.isEmpty) return report;

  // 父子索引（按**修复前**的拓扑建一次：修复只改字段，不改「谁是谁的子」）
  final Map<String, List<CoreAgent>> children = <String, List<CoreAgent>>{};
  for (final CoreAgent agent in agents) {
    final String parent = agent.parentAgentId.trim();
    if (parent.isEmpty) continue;
    children.putIfAbsent(parent, () => <CoreAgent>[]).add(agent);
  }

  /// agent 的团队归属：成员取 `team_id`，顶层就是它自己。
  String teamIdOf(CoreAgent agent) =>
      agent.teamId.trim().isEmpty ? agent.id : agent.teamId.trim();

  /// 沿 `team_id` 链解析到**存活的真实 TOP**；解析不通返回 null。
  CoreAgent? effectiveTop(CoreAgent agent) {
    final Set<String> seen = <String>{agent.id};
    String cursor = agent.teamId.trim();
    for (int depth = 0; depth < 32; depth++) {
      if (cursor.isEmpty) return null;
      final CoreAgent? next = byId[cursor];
      if (next == null || !seen.add(next.id)) return null;
      if (next.teamId.trim().isEmpty) return next;
      cursor = next.teamId.trim();
    }
    return null;
  }

  bool parentMissing(CoreAgent agent) {
    final String parent = agent.parentAgentId.trim();
    return parent.isNotEmpty && !byId.containsKey(parent);
  }

  bool teamMissing(CoreAgent agent) {
    final String teamId = agent.teamId.trim();
    return teamId.isNotEmpty && effectiveTop(agent) == null;
  }

  final Set<String> handled = <String>{};

  /// 把 [root] 的子树（按修复前拓扑）整体平移：`team_id` 跟随根，`level` 逐层 +1。
  void propagate(CoreAgent root, String action) {
    final String teamId = teamIdOf(root);
    final List<CoreAgent> cursor = <CoreAgent>[root];
    final Set<String> seen = <String>{root.id};
    for (int i = 0; i < cursor.length; i++) {
      final CoreAgent node = cursor[i];
      for (final CoreAgent child in children[node.id] ?? const <CoreAgent>[]) {
        if (!seen.add(child.id)) continue;
        final String oldTeam = child.teamId;
        final int oldLevel = child.level;
        child.teamId = teamId;
        child.level = node.level + 1;
        handled.add(child.id);
        cursor.add(child);
        if (oldTeam != child.teamId || oldLevel != child.level) {
          report.repairs.add(
            TeamLinkRepair(
              agentId: child.id,
              name: child.name,
              action: action,
              brokenParentId: child.parentAgentId,
              brokenTeamId: oldTeam,
              newParentId: node.id,
              newTeamId: child.teamId,
              oldLevel: oldLevel,
              newLevel: child.level,
            ),
          );
        }
      }
    }
  }

  // ── 1/2：上级（或整队）被删的「孤儿根」 ─────────────────────────────
  final List<CoreAgent> brokenRoots = agents
      .where((CoreAgent a) =>
          parentMissing(a) ||
          (a.parentAgentId.trim().isEmpty && teamMissing(a)))
      .toList()
    ..sort(
      (CoreAgent a, CoreAgent b) => a.createdAt == b.createdAt
          ? a.id.compareTo(b.id)
          : a.createdAt.compareTo(b.createdAt),
    );
  for (final CoreAgent root in brokenRoots) {
    if (handled.contains(root.id)) continue;
    final CoreAgent? top = effectiveTop(root);
    final String brokenParent = root.parentAgentId;
    final String brokenTeam = root.teamId;
    final int oldLevel = root.level;
    final String action;
    if (top != null) {
      action = TeamLinkRepair.reparented;
      root.parentAgentId = top.id;
      root.teamId = top.id;
      root.level = top.level + 1;
    } else {
      action = TeamLinkRepair.promoted;
      root.parentAgentId = '';
      root.teamId = '';
      root.level = 0;
    }
    handled.add(root.id);
    report.repairs.add(
      TeamLinkRepair(
        agentId: root.id,
        name: root.name,
        action: action,
        brokenParentId: brokenParent,
        brokenTeamId: brokenTeam,
        newParentId: root.parentAgentId,
        newTeamId: root.teamId,
        oldLevel: oldLevel,
        newLevel: root.level,
      ),
    );
    propagate(root, action);
  }

  // ── 3：`team_id` 悬空但父链完好（按父先于子的顺序修正） ─────────────
  int depthOf(CoreAgent agent) {
    final Set<String> seen = <String>{agent.id};
    CoreAgent cursor = agent;
    int depth = 0;
    for (int i = 0; i < 32; i++) {
      final String parentId = cursor.parentAgentId.trim();
      if (parentId.isEmpty) break;
      final CoreAgent? parent = byId[parentId];
      if (parent == null || !seen.add(parent.id)) break;
      cursor = parent;
      depth++;
    }
    return depth;
  }

  final List<CoreAgent> danglingTeams = agents
      .where((CoreAgent a) => !handled.contains(a.id) && teamMissing(a))
      .toList()
    ..sort((CoreAgent a, CoreAgent b) => depthOf(a).compareTo(depthOf(b)));
  for (final CoreAgent agent in danglingTeams) {
    if (handled.contains(agent.id)) continue;
    final String brokenTeam = agent.teamId;
    final CoreAgent? parent = byId[agent.parentAgentId.trim()];
    final String newTeam = parent == null ? '' : teamIdOf(parent);
    final int oldLevel = agent.level;
    final String brokenParent = agent.parentAgentId;
    agent.teamId = newTeam;
    if (parent == null && brokenParent.trim().isNotEmpty) {
      agent.parentAgentId = '';
      agent.level = 0;
    }
    handled.add(agent.id);
    report.repairs.add(
      TeamLinkRepair(
        agentId: agent.id,
        name: agent.name,
        action: parent == null
            ? TeamLinkRepair.promoted
            : TeamLinkRepair.normalized,
        brokenParentId: brokenParent,
        brokenTeamId: brokenTeam,
        newParentId: agent.parentAgentId,
        newTeamId: agent.teamId,
        oldLevel: oldLevel,
        newLevel: agent.level,
      ),
    );
  }

  if (handled.isEmpty) return report;

  // ── 写盘（先备份再写） + 计数回填 ──────────────────────────────────
  final Map<String, String> backups = <String, String>{};
  for (final TeamLinkRepair repair in report.repairs) {
    final CoreAgent? agent = store.agent(repair.agentId);
    if (agent == null) continue;
    if (backup != null) {
      final String path = await backup(agent);
      if (path.isNotEmpty) backups[agent.id] = path;
    }
    store.putAgent(agent);
  }
  // 计数回填：所有 TOP 按实际成员数核对（不累加），不一致才写（含历史遗留的陈旧值）。
  final Set<String> tops = <String>{
    for (final CoreAgent agent in store.agents())
      if (agent.teamId.trim().isEmpty) agent.id,
  };
  for (final String topId in tops) {
    final CoreAgent? top = store.agent(topId);
    if (top == null) continue;
    final int count = store.members(topId).length;
    if (top.teamMemberCount == count) continue;
    if (backup != null) {
      final String path = await backup(top);
      if (path.isNotEmpty) backups[top.id] = path;
    }
    top.teamMemberCount = count;
    store.putAgent(top);
    report.memberCountSynced.add(top.id);
  }
  await store.flush();
  if (backups.isNotEmpty) {
    final List<TeamLinkRepair> withBackup = <TeamLinkRepair>[
      for (final TeamLinkRepair r in report.repairs)
        if (backups.containsKey(r.agentId))
          TeamLinkRepair(
            agentId: r.agentId,
            name: r.name,
            action: r.action,
            brokenParentId: r.brokenParentId,
            brokenTeamId: r.brokenTeamId,
            newParentId: r.newParentId,
            newTeamId: r.newTeamId,
            oldLevel: r.oldLevel,
            newLevel: r.newLevel,
            backupPath: backups[r.agentId]!,
          ),
    ];
    report.repairs
      ..clear()
      ..addAll(withBackup);
  }
  for (final TeamLinkRepair repair in report.repairs) {
    log?.call(
      '团队关系自愈（${repair.action}）：${repair.name}(${repair.agentId}) '
      '上级[${repair.brokenParentId}]→[${repair.newParentId}] '
      '队伍[${repair.brokenTeamId}]→[${repair.newTeamId}] '
      'level ${repair.oldLevel}→${repair.newLevel}'
      '${repair.backupPath.isEmpty ? '' : '，备份 ${repair.backupPath}'}',
    );
  }
  for (final String topId in report.memberCountSynced) {
    log?.call('团队关系自愈：回填 $topId 的 team_member_count');
  }
  return report;
}

/// `agents/<agentId>.yaml` 的下一个 `.bak.<n>` 备份路径（n 递增、绝不覆盖旧备份）。
///
/// 与「重置系统提示词 / Spec」同一约定（见 `system_prompt_file.dart` 的备份序号逻辑）。
Future<String> backupAgentFile(TreePaths paths, String agentId) async {
  final File source = File(paths.agentFile(agentId));
  if (!source.existsSync()) return '';
  final String base = p.basename(source.path);
  final RegExp pattern = RegExp('^${RegExp.escape(base)}\\.bak\\.(\\d+)\$');
  int max = 0;
  final Directory dir = Directory(paths.agentsDir);
  if (dir.existsSync()) {
    for (final FileSystemEntity entity in dir.listSync()) {
      if (entity is! File) continue;
      final RegExpMatch? match = pattern.firstMatch(p.basename(entity.path));
      if (match == null) continue;
      final int value = int.tryParse(match.group(1) ?? '') ?? 0;
      if (value > max) max = value;
    }
  }
  final String target = '${source.path}.bak.${max + 1}';
  await source.copy(target);
  return target;
}
