import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/models/subagent_roster.dart';
import 'package:tree/ui/services/subagent_transcript.dart';

/// 临时员工的**过程分栏**（用户 2026-10-04：subagent 的输出不能跟主 agent 混杂；
/// 上下文长度统计也不能污染主 agent）。
void main() {
  ChatMessage msg(
    String id, {
    String subagentId = '',
    String subagentName = '',
    int level = 0,
    String kind = 'text',
    String content = '',
  }) =>
      ChatMessage(
        id: id,
        role: 'agent',
        content: content,
        timestamp: DateTime(2026, 10, 4, 9),
        kind: kind,
        subagentId: subagentId,
        subagentName: subagentName,
        subagentLevel: level,
      );

  setUp(SubagentTranscript.instance.clear);

  group(
    '落盘名册层（用户 2026-10-03：进入临时成员的入口不许随消息窗口抖动）',
    () {
      SubagentRosterEntry entry(
        String id, {
        String name = '',
        String parentId = '',
        int level = 1,
      }) => SubagentRosterEntry(
        id: id,
        name: name,
        parentId: parentId,
        level: level,
      );

      test('名册里的入口在过程消息被淘汰后仍在，且排在消息流观察到的前面', () {
        // 消息流里只观察到 sub_1（sub_2 的过程已经被窗口淘汰掉了）
        SubagentTranscript.instance.sync(<ChatMessage>[
          msg('s1', subagentId: 'sub_1', subagentName: '甲', level: 1),
        ]);
        expect(SubagentTranscript.instance.ids, <String>['sub_1']);
        SubagentTranscript.instance.setRoster(<SubagentRosterEntry>[
          entry('sub_1', name: '甲'),
          entry('sub_2', name: '乙', parentId: 'sub_1', level: 2),
        ]);
        expect(
          SubagentTranscript.instance.ids,
          <String>['sub_1', 'sub_2'],
          reason: '名册是权威来源：它的过程消息被淘汰了，入口也不能消失',
        );
        expect(SubagentTranscript.instance.of('sub_2'), isEmpty);
      });

      test('名字 / 谁召来的：名册优先（消息还没加载时也要对）', () {
        SubagentTranscript.instance.setRoster(<SubagentRosterEntry>[
          // level-1 的 parent_id 在**真实数据**里就是会话主人的 id（`CoreSubagent.parentId` /
          // `SubagentTag.parentId` = 召它的那个 agent）——用例照实写，不用空串（空串只会在
          // 老数据/坏数据里出现，那时按下面的口径如实退回"未知调用方"）。
          entry('sub_1', name: '甲', parentId: 'agt_1'),
          entry('sub_2', name: '乙', parentId: 'sub_1', level: 2),
        ]);
        expect(SubagentTranscript.instance.nameOf('sub_1'), '甲');
        expect(
          SubagentTranscript.instance.callerNameOf(
            'sub_2',
            ownerAgentId: 'agt_1',
            ownerName: '队长',
          ),
          '甲',
          reason: '上级临时员工的名字来自名册，不依赖它的过程消息',
        );
        expect(
          SubagentTranscript.instance.callerNameOf(
            'sub_1',
            ownerAgentId: 'agt_1',
            ownerName: '队长',
          ),
          '队长',
        );
        // 反面：名册里没有它（父既不在名册、也不在过程里）⇒ **如实退回空串**
        // （界面显示「（未知调用方）」），不许拿"会话主人"顶上——那是在编名字。
        expect(
          SubagentTranscript.instance.callerNameOf(
            'sub_3',
            ownerAgentId: 'agt_1',
            ownerName: '队长',
          ),
          isEmpty,
          reason: '父不在本会话的名册/过程里 ⇒ 退回空串（既有语义，不许编名字）',
        );
      });

      test('换会话 / 切 agent：名册层与消息层一起清（不跨会话保留）', () {
        SubagentTranscript.instance.setRoster(<SubagentRosterEntry>[
          entry('sub_1', name: '甲'),
        ]);
        SubagentTranscript.instance.sync(<ChatMessage>[
          msg('s1', subagentId: 'sub_1', subagentName: '甲', level: 1),
        ]);
        SubagentTranscript.instance.clear();
        expect(SubagentTranscript.instance.ids, isEmpty);
        expect(SubagentTranscript.instance.of('sub_1'), isEmpty);
        expect(SubagentTranscript.instance.nameOf('sub_1'), isEmpty);
      });

      test('setRoster 幂等：重复喂同一份名册，顺序不变', () {
        final List<SubagentRosterEntry> roster = <SubagentRosterEntry>[
          entry('sub_1', name: '甲'),
          entry('sub_2', name: '乙'),
        ];
        SubagentTranscript.instance.setRoster(roster);
        SubagentTranscript.instance.setRoster(roster);
        expect(SubagentTranscript.instance.ids, <String>['sub_1', 'sub_2']);
      });
    },
  );

  test('主消息流只留主 agent 自己的消息（临时员工的不进流）', () {
    final List<ChatMessage> all = <ChatMessage>[
      msg('m1', content: '主 agent 说'),
      msg('s1', subagentId: 'sub_1', subagentName: '甲', level: 1),
      msg('m2', content: '主 agent 又说'),
      msg('s2', subagentId: 'sub_2', subagentName: '乙', level: 1),
    ];
    expect(
      visibleStreamMessages(all).map((ChatMessage m) => m.id).toList(),
      <String>['m1', 'm2'],
    );
  });

  test('按 subagent_id 分组，组内保持到达顺序', () {
    SubagentTranscript.instance.sync(<ChatMessage>[
      msg('m1', content: '主 agent'),
      msg('s1', subagentId: 'sub_1', subagentName: '甲', level: 1),
      msg('s2', subagentId: 'sub_2', subagentName: '乙', level: 2),
      msg('s3', subagentId: 'sub_1', subagentName: '甲', level: 1),
    ]);
    expect(SubagentTranscript.instance.ids, <String>['sub_1', 'sub_2']);
    expect(
      SubagentTranscript.instance
          .of('sub_1')
          .map((ChatMessage m) => m.id)
          .toList(),
      <String>['s1', 's3'],
      reason: '同一个人后来的消息排在后头',
    );
    expect(SubagentTranscript.instance.of('sub_2'), hasLength(1));
    expect(SubagentTranscript.instance.of('sub_nope'), isEmpty);
  });

  test('sync 是幂等的；clear 清空；of() 返回不可改列表', () {
    final List<ChatMessage> all = <ChatMessage>[
      msg('s1', subagentId: 'sub_1', subagentName: '甲', level: 1),
    ];
    SubagentTranscript.instance.sync(all);
    SubagentTranscript.instance.sync(all);
    expect(SubagentTranscript.instance.ids, <String>['sub_1']);
    expect(SubagentTranscript.instance.of('sub_1'), hasLength(1));
    expect(
      () => SubagentTranscript.instance.of('sub_1').add(all.first),
      throwsUnsupportedError,
      reason: '外面只能读，不能改（改由 sync 统一重建）',
    );
    SubagentTranscript.instance.clear();
    expect(SubagentTranscript.instance.ids, isEmpty);
  });

  test('用量统计隔离的两处源钉（面板里不许把临时员工的数字算进主人）', () {
    final String panel = File('lib/ui/widgets/message_panel.dart')
        .readAsStringSync();
    expect(
      panel.contains('if (subagentId.isNotEmpty) return;'),
      isTrue,
      reason: '实时用量帧：带 subagent_id 的不记账',
    );
    expect(
      panel.contains('if (m.isSubagentMessage) continue;'),
      isTrue,
      reason: '历史恢复用量：跳过临时员工的消息',
    );
    expect(
      panel.contains('visible: (ChatMessage m) => !m.isSubagentMessage,'),
      isTrue,
      reason: '中栏只渲染主 agent 的消息（按槽位表过滤，临时员工的槽位零高度）',
    );
    expect(
      panel.contains('slots: _window.slots,'),
      isTrue,
      reason: '中栏渲染的是**窗口的槽位表**（滑到哪加载哪、限制缓存长度）',
    );
  });

  test('sync 是**合并**：被窗口淘汰的老过程不会从分栏里消失', () {
    // 窗口只热视口附近（用户 2026-10-04「限制缓存长度，仅缓存窗口附近的消息」），
    // 老消息会被淘汰出窗口；但"那次 subagent 工具调用的详情"里还得看得到它的过程。
    SubagentTranscript.instance.sync(<ChatMessage>[
      msg('s1', subagentId: 'sub_1', subagentName: '甲', level: 1),
      msg('s2', subagentId: 'sub_1', subagentName: '甲', level: 1),
    ]);
    // 窗口滑走、老消息被淘汰：这一批里已经没有 s1 了
    SubagentTranscript.instance.sync(<ChatMessage>[
      msg('s2', subagentId: 'sub_1', subagentName: '甲', level: 1),
      msg('s3', subagentId: 'sub_1', subagentName: '甲', level: 1),
    ]);
    expect(
      SubagentTranscript.instance
          .of('sub_1')
          .map((ChatMessage m) => m.id)
          .toList(),
      <String>['s1', 's2', 's3'],
      reason: '合并语义：老过程留着，新过程接在后头，同一 id 不重复',
    );
  });

  group(
    '落盘复查合并（用户 2026-10-11：「subagent 的工作数据不落盘，导致非常不稳定」——'
    '断言：跨会话不保留照旧，但临时员工的工作数据落盘、方便后期复查）',
    () {
      ChatMessage timed(String id, {String subagentId = 'sub_1', int minute = 0}) =>
          ChatMessage(
            id: id,
            role: 'agent',
            content: id,
            timestamp: DateTime(2026, 10, 11, 9, minute),
            subagentId: subagentId,
            subagentName: '甲',
            subagentLevel: 1,
          );

      test('窗口只有活的那一段时，复查把更早的落盘过程按时间序插回前面', () {
        SubagentTranscript.instance.sync(<ChatMessage>[
          timed('s2', minute: 2),
          timed('s3', minute: 3),
        ]);
        // 复查通路一次取全（同 id 的是另一份解析出来的对象）
        SubagentTranscript.instance.mergeTranscript('sub_1', <ChatMessage>[
          timed('s1', minute: 1),
          timed('s2', minute: 2),
          timed('s3', minute: 3),
        ]);
        expect(
          SubagentTranscript.instance
              .of('sub_1')
              .map((ChatMessage m) => m.id)
              .toList(),
          <String>['s1', 's2', 's3'],
          reason: '落盘的老过程补在前面，顺序按时间戳',
        );
      });

      test('同一 id 已在窗口里 = 保留活对象（流式原地长，不许被复查副本顶掉）', () {
        final ChatMessage live = timed('s2', minute: 2);
        SubagentTranscript.instance.sync(<ChatMessage>[live]);
        SubagentTranscript.instance.mergeTranscript('sub_1', <ChatMessage>[
          timed('s2', minute: 2),
          timed('s1', minute: 1),
        ]);
        final List<ChatMessage> merged = SubagentTranscript.instance.of('sub_1');
        expect(
          merged.map((ChatMessage m) => m.id).toList(),
          <String>['s1', 's2'],
        );
        expect(
          identical(merged.last, live),
          isTrue,
          reason: '去重按 id：已收的活对象优先（sync 的共享引用语义照旧）',
        );
      });

      test('复查批里混了别的 id 的消息：只收本员工的（错接线不许污染分栏）', () {
        SubagentTranscript.instance.mergeTranscript('sub_1', <ChatMessage>[
          timed('s1'),
          timed('x1', subagentId: 'sub_2'),
        ]);
        expect(
          SubagentTranscript.instance
              .of('sub_1')
              .map((ChatMessage m) => m.id)
              .toList(),
          <String>['s1'],
        );
        expect(SubagentTranscript.instance.of('sub_2'), isEmpty);
      });

      test('mergeTranscript 幂等：重复喂同一份复查结果，不重不漏', () {
        final List<ChatMessage> batch = <ChatMessage>[
          timed('s1', minute: 1),
          timed('s2', minute: 2),
        ];
        SubagentTranscript.instance.mergeTranscript('sub_1', batch);
        SubagentTranscript.instance.mergeTranscript('sub_1', batch);
        expect(SubagentTranscript.instance.of('sub_1'), hasLength(2));
        // 之后再 sync 同一批活消息也不会重复收（同一去重判据）
        SubagentTranscript.instance.sync(batch);
        expect(SubagentTranscript.instance.of('sub_1'), hasLength(2));
      });

      test('消息流从没加载过它时，复查先补数据、入口与名字跟着立起来', () {
        expect(SubagentTranscript.instance.ids, isEmpty);
        SubagentTranscript.instance.mergeTranscript('sub_1', <ChatMessage>[
          timed('s1'),
        ]);
        expect(SubagentTranscript.instance.ids, contains('sub_1'));
        expect(SubagentTranscript.instance.nameOf('sub_1'), '甲');
      });

      test('换会话 / 切 agent：复查补的数据与名册层、消息层一起清（跨会话不保留照旧）', () {
        SubagentTranscript.instance.mergeTranscript('sub_1', <ChatMessage>[
          timed('s1'),
        ]);
        SubagentTranscript.instance.clear();
        expect(SubagentTranscript.instance.ids, isEmpty);
        expect(SubagentTranscript.instance.of('sub_1'), isEmpty);
      });

      test('面板接线源钉：进临时员工视角走复查通路，拉取失败不清空分栏', () {
        final String panel = File('lib/ui/widgets/message_panel.dart')
            .readAsStringSync();
        expect(
          panel.contains('getSubagentTranscript'),
          isTrue,
          reason: '进入临时员工视角要拉一次落盘复查（不能依赖窗口恰好加载了什么）',
        );
        expect(
          panel.contains('mergeTranscript'),
          isTrue,
          reason: '复查结果合并进分栏（合并语义，不整表替换）',
        );
      });
    },
  );
}
