/// 团队级运行模式 / 工作目录的**显示合成**（成员跟随团队 TOP，2026-10-03 用户断言）。
///
/// 为什么单独抽出来：这段口径有三条容易写错的规则，而输入只有"当前 agent 与团队 TOP
/// 各自的配置"两套，纯函数化之后可以逐条钉住（见 test/team_scope_view_test.dart）：
/// 1. **模式**：自己**显式**配了 SSH 就以自己那份为准（核心 `teamSshConfigFor` 同优先级：
///    手工配置优先），否则跟随团队 TOP；
/// 2. **工作目录**：**只有团队 TOP 那份算数**——成员自己的 `workspace_dir` 是核心写下的
///    镜像（见核心 `syncWorkspaceMirrors`），所以优先显示 TOP 的目录；TOP 未配置时退回
///    自己那份镜像。核心会把 TOP 的默认目录也镜像进来，成员页因此永远显示一个真实目录，
///    而不是让用户去"重新选择工作目录"；
/// 3. 团队 TOP 是 SSH 时，成员**无法**单独切回本地：核心没有"成员覆盖成 local"这个概念
///    （`teamSshConfigFor` 只会向上借 SSH，不会向下借本地）。界面必须如实拒绝。
class TeamScopeView {
  const TeamScopeView({
    required this.ssh,
    required this.workingDir,
    required this.sshConfig,
    required this.isMember,
    required this.teamHasSsh,
  });

  /// 按"自己那份 + 团队 TOP 那份"合成显示口径。
  factory TeamScopeView.combine({
    required bool isMember,
    required bool memberHasSsh,
    required bool teamHasSsh,
    required String memberDir,
    required String teamDir,
    required Map<String, dynamic> memberSshConfig,
    required Map<String, dynamic> teamSshConfig,
  }) => TeamScopeView(
    ssh: memberHasSsh || teamHasSsh,
    workingDir: teamDir.isNotEmpty ? teamDir : memberDir,
    sshConfig: memberSshConfig.isNotEmpty ? memberSshConfig : teamSshConfig,
    isMember: isMember,
    teamHasSsh: teamHasSsh,
  );

  /// 有效模式是否为 SSH（自己配了或跟随 TOP 配了）。
  final bool ssh;

  /// 显示用的工作目录（空 = 团队还没选目录）。
  final String workingDir;

  /// SSH 表单预填配置（自己优先，否则用 TOP 那份）。
  final Map<String, dynamic> sshConfig;

  /// 当前选中的是不是团队成员（非 TOP）。
  final bool isMember;

  /// 团队 TOP 是否配了 SSH。
  final bool teamHasSsh;

  /// 是否本地模式。
  bool get local => !ssh;

  /// 能否切回本地（见类文档第 3 条）。
  bool get canSwitchToLocal =>
      TeamScopeView.allowsLocalSwitch(isMember: isMember, teamHasSsh: teamHasSsh);

  /// 纯判据版本：团队 TOP 是 SSH 时，成员切不回本地。
  static bool allowsLocalSwitch({
    required bool isMember,
    required bool teamHasSsh,
  }) => !(isMember && teamHasSsh);
}
