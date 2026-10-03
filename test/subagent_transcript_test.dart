import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tree/ui/models/message.dart';
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
}
