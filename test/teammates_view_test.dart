import 'package:flutter_test/flutter_test.dart';
import 'package:tree/ui/services/teammates_view.dart';

/// 成员面板（「XX 的团队」窗口）的两条纯规则（用户断言 2026-10-03）：
///
/// 1. **名单里不能有自己**——成员「凌川」的面板里出现了「凌川」自己，
///    根卡片还写着「Level 0 · 团队负责人」；
/// 2. **根卡片如实**：成员要显示「Level N 成员 · 隶属「TOP」」，
///    拿不到核心的 `self` 描述符时用 `agent.teamId` 兜底（宁缺勿假）。
void main() {
  Map<String, dynamic> payload({
    Map<String, dynamic>? self,
    List<Map<String, dynamic>> members = const <Map<String, dynamic>>[],
  }) => <String, dynamic>{'members': members, 'self': ?self};

  group('根卡片：成员不许显示成 Level 0 团队负责人', () {
    test('TOP：Level 0 · 团队负责人', () {
      final TeammatesRoot root = teammatesRoot(
        payload: payload(self: <String, dynamic>{
          'name': '契门',
          'level': 0,
          'is_member': false,
          'top_agent_name': '',
        }),
        fallbackName: '契门',
        fallbackIsMember: false,
      );
      expect(root.isMember, isFalse);
      expect(root.subtitle, 'Level 0 · 团队负责人');
    });

    test('成员：Level 1 成员 · 隶属「契门」', () {
      final TeammatesRoot root = teammatesRoot(
        payload: payload(self: <String, dynamic>{
          'name': '凌川',
          'level': 1,
          'is_member': true,
          'top_agent_name': '契门',
        }),
        fallbackName: '凌川',
        fallbackIsMember: true,
      );
      expect(root.name, '凌川');
      expect(root.subtitle, 'Level 1 成员 · 隶属「契门」');
    });

    test('成员但没有 TOP 名：只写成员，不编隶属关系', () {
      final TeammatesRoot root = teammatesRoot(
        payload: payload(self: <String, dynamic>{
          'name': '凌川',
          'level': 2,
          'is_member': true,
        }),
        fallbackName: '凌川',
        fallbackIsMember: true,
      );
      expect(root.subtitle, 'Level 2 成员');
    });

    test('旧核心没有 self：用 agent.teamId 兜底，不说自己是团队负责人', () {
      final TeammatesRoot member = teammatesRoot(
        payload: <String, dynamic>{'members': <Map<String, dynamic>>[]},
        fallbackName: '凌川',
        fallbackIsMember: true,
      );
      expect(member.name, '凌川');
      expect(member.subtitle, '团队成员');
      final TeammatesRoot top = teammatesRoot(
        payload: null,
        fallbackName: '契门',
        fallbackIsMember: false,
      );
      expect(top.subtitle, 'Level 0 · 团队负责人');
    });
  });

  group('名单：滤掉自己', () {
    Map<String, dynamic> m(String id, String name) =>
        <String, dynamic>{'id': id, 'name': name, 'level': 1};

    test('自己出现在名单里也不显示（旧核心 / 中间态的兜底）', () {
      final List<Map<String, dynamic>> members = teammatesMembers(
        payload: payload(
          self: <String, dynamic>{'id': 'me', 'name': '凌川', 'is_member': true},
          members: <Map<String, dynamic>>[m('me', '凌川'), m('c1', '小工')],
        ),
        selfId: 'me',
      );
      expect(members.map((Map<String, dynamic> e) => e['id']), <String>['c1']);
    });

    test('没有 members / 没有 payload：空名单而不是抛异常', () {
      expect(teammatesMembers(payload: null, selfId: 'me'), isEmpty);
      expect(
        teammatesMembers(
          payload: <String, dynamic>{'self': <String, dynamic>{}},
          selfId: 'me',
        ),
        isEmpty,
      );
    });
  });
}
