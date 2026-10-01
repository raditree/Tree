// 会话改名帧（`session_renamed`）的纯逻辑单测。
//
// 背景（点位化，2026-10-01）：执行站命令 `session.rename` 让**插件**也能改会话标题。
// REST 改名路径是前端自己 setState，插件改名没有这条路径，核心因此下发
// `session_renamed` 帧；前端收到后要即时把标题换过来（否则要切走再切回才看得到）。
//
// 面板侧只做"取参 + setState"，该不该改、改成什么都在 `SessionRename` 里——所以这里
// 直接测纯函数，不必把 MessagePanel 整棵组件树搭起来。
//
// 运行方式（项目根目录）：
//   flutter test test/session_rename_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tree/ui/models/session.dart';
import 'package:tree/ui/services/session_rename.dart';

void main() {
  List<ChatSession> sessions() => <ChatSession>[
    ChatSession(sessionId: 'session_default', title: '默认会话', messageCount: 3),
    ChatSession(
      sessionId: 's_2',
      title: '旧标题',
      createdAt: 10,
      updatedAt: 20,
      selectedSpecIds: const <String>['spec_a'],
    ),
  ];

  group('会话改名帧的纯逻辑', () {
    test('命中当前 agent + 会话 ⇒ 只换那一条的标题，其余字段与顺序原样保留', () {
      final List<ChatSession>? next = SessionRename.apply(
        sessions(),
        currentAgentId: 'agt_1',
        agentId: 'agt_1',
        sessionId: 's_2',
        title: '新标题',
      );
      expect(next, isNotNull);
      expect(next!, hasLength(2));
      expect(next[0].sessionId, 'session_default');
      expect(next[1].title, '新标题');
      // 其余字段不受影响（copyWith 只换 title）
      expect(next[1].createdAt, 10);
      expect(next[1].updatedAt, 20);
      expect(next[1].selectedSpecIds, <String>['spec_a']);
    });

    test('不是当前 agent 的帧 ⇒ 不改（null，面板据此跳过 setState）', () {
      expect(
        SessionRename.apply(
          sessions(),
          currentAgentId: 'agt_1',
          agentId: 'agt_2',
          sessionId: 's_2',
          title: '新标题',
        ),
        isNull,
        reason: 'sessionId 只在 agent 内唯一，跨 agent 直接按 id 改会改错别人的会话',
      );
    });

    test('会话不在列表里 ⇒ 不改', () {
      expect(
        SessionRename.apply(
          sessions(),
          currentAgentId: 'agt_1',
          agentId: 'agt_1',
          sessionId: 's_unknown',
          title: '新标题',
        ),
        isNull,
      );
    });

    test('标题本来就一样 ⇒ 不改（避免为一次空改动重建整棵树）', () {
      expect(
        SessionRename.apply(
          sessions(),
          currentAgentId: 'agt_1',
          agentId: 'agt_1',
          sessionId: 's_2',
          title: '旧标题',
        ),
        isNull,
      );
    });

    test('畸形帧（缺 agent / 缺 session / 空标题）⇒ 一律不改', () {
      final List<ChatSession> list = sessions();
      for (final ({String agentId, String sessionId, String title}) bad
          in <({String agentId, String sessionId, String title})>[
        (agentId: '', sessionId: 's_2', title: '新标题'),
        (agentId: 'agt_1', sessionId: '', title: '新标题'),
        (agentId: 'agt_1', sessionId: 's_2', title: ''),
      ]) {
        expect(
          SessionRename.apply(
            list,
            currentAgentId: 'agt_1',
            agentId: bad.agentId,
            sessionId: bad.sessionId,
            title: bad.title,
          ),
          isNull,
          reason: '缺字段的帧按"不改动"处理（宁可不动，也不要把标题清空）',
        );
      }
    });

    test('载荷解析：兼容 {data: {...}} 与扁平两种帧形状，缺字段给空串', () {
      final ({String agentId, String sessionId, String title}) nested =
          SessionRename.parse(<String, dynamic>{
            'type': 'session_renamed',
            'data': <String, dynamic>{
              'agent_id': 'agt_1',
              'session_id': 's_2',
              'title': '新标题',
            },
          });
      expect(nested.agentId, 'agt_1');
      expect(nested.sessionId, 's_2');
      expect(nested.title, '新标题');

      final ({String agentId, String sessionId, String title}) flat =
          SessionRename.parse(<String, dynamic>{'session_id': 's_9'});
      expect(flat.agentId, '');
      expect(flat.sessionId, 's_9');
      expect(flat.title, '');
    });

    test('返回的是新列表（不改动入参，便于 setState 前后对比）', () {
      final List<ChatSession> list = sessions();
      final List<ChatSession>? next = SessionRename.apply(
        list,
        currentAgentId: 'agt_1',
        agentId: 'agt_1',
        sessionId: 's_2',
        title: '新标题',
      );
      expect(next, isNot(same(list)));
      expect(list[1].title, '旧标题', reason: '入参保持原样');
    });
  });
}
