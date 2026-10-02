import 'package:flutter_test/flutter_test.dart';
import 'package:tree/ui/services/team_scope_view.dart';

/// 团队级模式/目录的显示合成（用户断言 2026-10-03）：
/// 成员**默认继承**团队 TOP 的工作模式与工作目录；TOP 被删后成员升为 TOP，
/// 不可以退回"重新选择工作目录"。
void main() {
  TeamScopeView combine({
    bool isMember = false,
    bool memberHasSsh = false,
    bool teamHasSsh = false,
    String memberDir = '',
    String teamDir = '',
    Map<String, dynamic> memberSsh = const <String, dynamic>{},
    Map<String, dynamic> teamSsh = const <String, dynamic>{},
  }) => TeamScopeView.combine(
    isMember: isMember,
    memberHasSsh: memberHasSsh,
    teamHasSsh: teamHasSsh,
    memberDir: memberDir,
    teamDir: teamDir,
    memberSshConfig: memberSsh,
    teamSshConfig: teamSsh,
  );

  test('成员跟随团队 TOP 的模式与目录', () {
    final TeamScopeView view = combine(
      isMember: true,
      teamHasSsh: true,
      teamDir: '/proj/qi',
      teamSsh: <String, dynamic>{'host': '10.0.0.1'},
    );
    expect(view.ssh, isTrue, reason: 'TOP 是 SSH，成员就是 SSH（工作模式默认继承）');
    expect(view.local, isFalse);
    expect(view.workingDir, '/proj/qi');
    expect(view.sshConfig['host'], '10.0.0.1');
  });

  test('成员自己的 SSH 配置优先（手工配置优先，与核心同口径）', () {
    final TeamScopeView view = combine(
      isMember: true,
      memberHasSsh: true,
      teamHasSsh: false,
      memberSsh: <String, dynamic>{'host': 'member-host'},
    );
    expect(view.ssh, isTrue);
    expect(view.sshConfig['host'], 'member-host');
  });

  test('目录只认团队 TOP 那份；TOP 未配置时退回成员自己的镜像', () {
    expect(combine(isMember: true, teamDir: '/top', memberDir: '/mirror').workingDir, '/top');
    expect(combine(isMember: true, teamDir: '', memberDir: '/mirror').workingDir, '/mirror');
    // 顶层 agent：自己就是那份配置
    expect(combine(isMember: false, memberDir: '/mine').workingDir, '/mine');
  });

  test('断言：团队 TOP 是 SSH 时成员切不回本地', () {
    expect(
      TeamScopeView.allowsLocalSwitch(isMember: true, teamHasSsh: true),
      isFalse,
      reason: '核心只会向上借 SSH，没有"成员覆盖成 local"的概念，界面不许假装切成功',
    );
    expect(TeamScopeView.allowsLocalSwitch(isMember: true, teamHasSsh: false), isTrue);
    expect(TeamScopeView.allowsLocalSwitch(isMember: false, teamHasSsh: true), isTrue);
    expect(
      combine(isMember: true, teamHasSsh: true).canSwitchToLocal,
      isFalse,
    );
  });
}
