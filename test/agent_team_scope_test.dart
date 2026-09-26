import 'package:flutter_test/flutter_test.dart';
import 'package:tree/ui/models/agent.dart';

/// Agent 的团队作用域解析。
///
/// 为什么值得测：`/api/agents` 返回**全部** agent（含团队成员，核心 toApiJson 带
/// team_id），而插件槽位与站点都以**团队**为单位。若这里算错，选中团队成员时
/// 插件面板会被过滤成「站点（0）」——一个看起来像"功能没做"的显示 bug。
void main() {
  test('解析 team_id：成员非空、顶层为空', () {
    final Agent member = Agent.fromJson(<String, dynamic>{
      'id': 'agent_m',
      'name': '成员',
      'team_id': 'agent_top',
    });
    final Agent top = Agent.fromJson(<String, dynamic>{'id': 'agent_top', 'name': '顶层'});
    expect(member.teamId, 'agent_top');
    expect(top.teamId, '');
  });

  test('teamScopeId：成员回指团队，顶层用自身 id', () {
    final Agent member = Agent.fromJson(<String, dynamic>{'id': 'agent_m', 'team_id': 'agent_top'});
    final Agent top = Agent.fromJson(<String, dynamic>{'id': 'agent_top'});
    expect(member.teamScopeId, 'agent_top');
    expect(top.teamScopeId, 'agent_top');
  });

  test('兼容 camelCase 与缺失字段（旧核心）', () {
    final Agent camel = Agent.fromJson(<String, dynamic>{'id': 'a', 'teamId': 't'});
    final Agent none = Agent.fromJson(<String, dynamic>{'id': 'a'});
    expect(camel.teamScopeId, 't');
    expect(none.teamScopeId, 'a');
  });
}