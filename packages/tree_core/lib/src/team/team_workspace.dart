import '../settings/ssh_config.dart';
import '../store/records.dart';

/// 团队工作目录口径（2026-10-02 用户定夺）：**成员与团队 TOP 共享同一个工作目录**，
/// 成员不再是"独立工作空间"。
///
/// 一句话规则：工作目录只有**团队所有者（TOP agent）**那一份，成员一律跟随它。
/// 为什么要一路向上找：成员可以挂在别的成员下面（level ≥ 2），而中间层没有自己的
/// 目录概念，最终都要落到 TOP 头上。查找带深度与 seen 去重（配置成环也不会死循环）。
///
/// 成员自己 yaml 里的 `workspace_dir` **不生效**：否则"和 leader 共享工作目录"就变成
/// 一条可被旧配置悄悄覆盖的软约定，而"成员各自 `workspaces/<member_id>`"正是
/// docs/known-issues.md #9 里成员文件与 leader 不在同一目录、用户看不到进度的成因。
///
/// 返回值分两段，因为不同调用点的"默认目录"口径不同（数据根 / 远端根 / 测试夹具）：
/// - [owner]：目录归属者（agent 本身是 TOP 时就是它自己）；
/// - [configuredDir]：归属者**显式配置**的 `workspace_dir`（空 ⇒ 调用方用
///   [owner] 的默认目录口径，例如 `<数据根>/workspaces/<owner.id>`）。
class TeamWorkspace {
  const TeamWorkspace({required this.owner, required this.configuredDir});

  /// 目录归属者（团队 TOP）。
  final CoreAgent owner;

  /// 归属者显式配置的 `workspace_dir`（已 trim；空串 = 未配置）。
  final String configuredDir;

}

/// 解析 [agent] 的**团队共享工作目录**（见 [TeamWorkspace]）。
///
/// [lookup] 按 id 取 agent（核心传 `store.agent`；测试可传自己的夹具）。
TeamWorkspace teamWorkspaceFor(
  CoreAgent agent,
  CoreAgent? Function(String agentId) lookup,
) {
  CoreAgent owner = agent;
  final Set<String> seen = <String>{agent.id};
  // 层级上限：配置里 max_level 默认 3，留足冗余；同时也是"成环"的硬保护。
  for (int depth = 0; depth < 32; depth++) {
    final String parentId = owner.parentAgentId.trim();
    if (parentId.isEmpty) break;
    final CoreAgent? parent = lookup(parentId);
    if (parent == null || !seen.add(parent.id)) {
      // 上级不存在（被删/跨库）或成环：以当前这一层为准，绝不无限向上。
      break;
    }
    owner = parent;
  }
  return TeamWorkspace(owner: owner, configuredDir: owner.workspaceDir.trim());
}

/// 成员的**有效 SSH 配置**：自己没有就跟随团队 TOP。
///
/// 与工作目录同一口径（见 [TeamWorkspace]）：成员不是"另一台机器上的独立 agent"——
/// leader 在远端跑，成员的工具就该在同一台远端主机、同一个根下跑。
/// 自己显式配了 ssh 的成员仍以自己那份为准（手工配置优先），因此这个函数对任何 agent 都安全：
/// TOP 自己的 owner 就是它自己 ⇒ 返回它原有的配置，行为与接线前一致。
SshConfig? teamSshConfigFor(
  CoreAgent agent,
  CoreAgent? Function(String agentId) lookup,
) {
  final SshConfig? own = agent.sshConfig;
  if (own != null) return own;
  return teamWorkspaceFor(agent, lookup).owner.sshConfig;
}
