import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tree/ui/models/agent.dart';
import 'package:tree/ui/pages/main_page.dart';

/// 左栏 Agent 列表的**成员口径**（2026-10-02 二改后的钉子）。
///
/// 旧判（同日一审）：成员**不**出现在左栏——列表只喂 `teamId` 为空的顶层 agent，
/// 成员的入口只有「选中 leader → 团队（teammates）」。
/// 新判（同日二改）：**允许出现**——点开成员就是它自己的会话，与顶层 agent 同一条通路。
/// **其余口径不变**：成员的工具根 / 提示词 / 文件面板仍解析到 leader 的工作目录与 SSH，
/// 插件作用域仍按 `teamScopeId` 回指团队（见 `lib/README.md` 不变量 6、`docs/team.md` §8）。
void main() {
  Agent agent(String id, {String teamId = ''}) => Agent(
    id: id,
    name: id,
    type: 'normal',
    lastMessage: '',
    teamId: teamId,
  );

  List<String> ids(List<Agent> agents) =>
      agents.map((Agent a) => a.id).toList();

  test('成员出现在列表里（旧判会把它滤掉）', () {
    expect(
      ids(railAgentsOf(<Agent>[
        agent('top'),
        agent('m1', teamId: 'top'),
        agent('m2', teamId: 'top'),
      ])),
      <String>['top', 'm1', 'm2'],
    );
  });

  test('顺序：顶层在前（保持接口顺序），成员紧跟各自的 TOP', () {
    expect(
      ids(railAgentsOf(<Agent>[
        agent('top_a'),
        agent('m_a1', teamId: 'top_a'),
        agent('top_b'),
        agent('m_b1', teamId: 'top_b'),
        agent('m_b2', teamId: 'top_b'),
      ])),
      <String>['top_a', 'm_a1', 'top_b', 'm_b1', 'm_b2'],
    );
  });

  test('多级成员（team_id 一律指向 TOP）跟着 TOP，一个都不掉', () {
    final List<String> rail = ids(
      railAgentsOf(<Agent>[
        agent('m_l2', teamId: 'top'),
        agent('top'),
        agent('m_l1', teamId: 'top'),
      ]),
    );
    expect(rail.first, 'top');
    expect(rail.toSet(), <String>{'top', 'm_l1', 'm_l2'});
  });

  test('找不到 TOP 的成员兜底列在末尾（绝不凭空消失）', () {
    expect(
      ids(railAgentsOf(<Agent>[
        agent('orphan', teamId: 'gone'),
        agent('top'),
        agent('m1', teamId: 'top'),
      ])),
      <String>['top', 'm1', 'orphan'],
    );
  });

  test('空列表 / 只有顶层：行为不变', () {
    expect(railAgentsOf(const <Agent>[]), isEmpty);
    expect(ids(railAgentsOf(<Agent>[agent('a'), agent('b')])), <String>['a', 'b']);
  });

  test('左栏两个入口（桌面三栏 / 移动端）都喂这份列表', () {
    // 数据源是纯函数，"接线"这一层只有源码能钉：两个 AgentList 都必须用 _railAgents，
    // 不能再出现只喂顶层 agent 的过滤（那正是旧判）。
    final String src = File('lib/ui/pages/main_page.dart').readAsStringSync();
    expect(RegExp(r'agents: _railAgents,').allMatches(src).length, 2, reason: '桌面 + 移动各一处');
    expect(src.contains('agents: _topAgents,'), isFalse, reason: '旧的\'只列顶层\'过滤不得残留');
  });
}
