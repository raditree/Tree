// Q12 插件布局：槽位注册表测试（注册 / 更新 / 注销 / team 过滤 / 多插件共存）。
//
// 运行方式（项目根目录）：
//   flutter test test/plugin_ui_registry_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tree/ui/services/plugin_ui_registry.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// 构造一条槽位声明 JSON。
Map<String, dynamic> _slot(
  String key,
  String kind, {
  String title = '',
  int order = 0,
  Object? view,
}) =>
    <String, dynamic>{
      'slot_key': key,
      'slot': kind,
      'title': title,
      'order': order,
      'view': view ?? <String, dynamic>{'type': 'text', 'text': key},
    };

/// 构造一帧 manifest（合成帧，不依赖核心进程）。
Map<String, dynamic> _manifest(
  String pluginId, {
  String teamId = 't1',
  List<Map<String, dynamic>> slots = const <Map<String, dynamic>>[],
}) =>
    <String, dynamic>{
      'type': PluginUiFrameType.manifest,
      'data': <String, dynamic>{
        'plugin_id': pluginId,
        'team_id': teamId,
        'slots': slots,
      },
    };

/// 构造一帧 update。
Map<String, dynamic> _update(
  String slotKey, {
  String pluginId = 'demo.a',
  String teamId = 't1',
  Object? view,
}) =>
    <String, dynamic>{
      'type': PluginUiFrameType.update,
      'data': <String, dynamic>{
        'plugin_id': pluginId,
        'team_id': teamId,
        'slot_key': slotKey,
        'view': view,
      },
    };

/// 构造一帧 plugin_status（销毁）。
Map<String, dynamic> _destroyed(String pluginId, {String teamId = 't1'}) =>
    <String, dynamic>{
      'type': WsOutboundType.pluginStatus,
      'data': <String, dynamic>{
        'plugin_id': pluginId,
        'scope': <String, dynamic>{'team_id': teamId},
        'status': 'destroyed',
      },
    };

void main() {
  group('登记 / 更新 / 注销', () {
    test('manifest 登记四类槽位，按类型取用', () {
      final PluginUiRegistry reg = PluginUiRegistry.forTesting()..setTeam('t1');
      expect(
        reg.handleFrame(_manifest('demo.a', slots: <Map<String, dynamic>>[
          _slot('a.activity', PluginUiSlotKind.activity, title: '活动项'),
          _slot('a.panel', PluginUiSlotKind.panel, title: '面板'),
          _slot('a.status', PluginUiSlotKind.status),
          _slot('a.card', PluginUiSlotKind.card),
        ])),
        isTrue,
      );
      expect(reg.slotsOfKind(PluginUiSlotKind.activity).single.slotKey,
          'a.activity');
      expect(reg.slotsOfKind(PluginUiSlotKind.panel).single.title, '面板');
      expect(reg.slotsOfKind(PluginUiSlotKind.status), hasLength(1));
      expect(reg.slotsOfKind(PluginUiSlotKind.card), hasLength(1));
      expect(reg.allSlots, hasLength(4));
    });

    test('update 整块替换目标视图，其它槽位不受影响', () {
      final PluginUiRegistry reg = PluginUiRegistry.forTesting()..setTeam('t1');
      reg.handleFrame(_manifest('demo.a', slots: <Map<String, dynamic>>[
        _slot('a.panel', PluginUiSlotKind.panel),
        _slot('a.status', PluginUiSlotKind.status, view: <String, dynamic>{
          'type': 'text',
          'text': '原始',
        }),
      ]));
      final bool changed = reg.applyUpdate(PluginUiUpdate.fromFrame(_update(
        'a.panel',
        view: <String, dynamic>{'type': 'progress', 'value': 0.5},
      ))!);
      expect(changed, isTrue);
      expect(
        reg.slot('a.panel')!.view.nodes.single.type,
        PluginUiViewType.progress,
      );
      // 整块替换（不是 diff）：旧节点消失
      expect(reg.slot('a.panel')!.view.nodes.single.str('text'), '');
      // 其它槽位原样
      expect(reg.slot('a.status')!.view.nodes.single.str('text'), '原始');
    });

    test('update 的 view 为 null 时注销该槽位', () {
      final PluginUiRegistry reg = PluginUiRegistry.forTesting()..setTeam('t1');
      reg.handleFrame(_manifest('demo.a', slots: <Map<String, dynamic>>[
        _slot('a.status', PluginUiSlotKind.status),
      ]));
      expect(reg.handleFrame(_update('a.status', view: null)), isTrue);
      expect(reg.slot('a.status'), isNull);
      expect(reg.slotsOfKind(PluginUiSlotKind.status), isEmpty);
    });

    test('update 目标槽位不存在时忽略（不凭空新建）', () {
      final PluginUiRegistry reg = PluginUiRegistry.forTesting()..setTeam('t1');
      expect(
        reg.applyUpdate(PluginUiUpdate.fromFrame(_update('ghost'))!),
        isFalse,
      );
      expect(reg.allSlots, isEmpty);
    });

    test('plugin_status(destroyed) 注销该插件全部槽位', () {
      final PluginUiRegistry reg = PluginUiRegistry.forTesting()..setTeam('t1');
      reg.handleFrame(_manifest('demo.a', slots: <Map<String, dynamic>>[
        _slot('a.status', PluginUiSlotKind.status),
        _slot('a.card', PluginUiSlotKind.card),
      ]));
      reg.handleFrame(_manifest('demo.b', slots: <Map<String, dynamic>>[
        _slot('b.status', PluginUiSlotKind.status),
      ]));
      expect(reg.handleFrame(_destroyed('demo.a')), isTrue);
      // 只清 a，不动 b
      expect(reg.allSlots.map((PluginUiSlot s) => s.slotKey), <String>['b.status']);
      // 非 destroyed 的 plugin_status 与本注册表无关
      expect(
        reg.handleFrame(<String, dynamic>{
          'type': WsOutboundType.pluginStatus,
          'data': <String, dynamic>{'plugin_id': 'demo.b', 'status': 'disabled'},
        }),
        isFalse,
      );
      expect(reg.allSlots, hasLength(1));
    });

    test('manifest 是该插件在该 team 上的完整声明：未列出的旧槽位被注销', () {
      final PluginUiRegistry reg = PluginUiRegistry.forTesting()..setTeam('t1');
      reg.handleFrame(_manifest('demo.a', slots: <Map<String, dynamic>>[
        _slot('a.status', PluginUiSlotKind.status),
        _slot('a.card', PluginUiSlotKind.card),
      ]));
      // 同一插件在别的 team 的槽位不受牵连
      reg.handleFrame(_manifest('demo.a',
          teamId: 't2',
          slots: <Map<String, dynamic>>[
            _slot('a.status.t2', PluginUiSlotKind.status),
          ]));
      // 重新声明：只剩一个槽位
      reg.handleFrame(_manifest('demo.a', slots: <Map<String, dynamic>>[
        _slot('a.status', PluginUiSlotKind.status),
      ]));
      expect(
        reg.allSlots.map((PluginUiSlot s) => s.slotKey).toSet(),
        <String>{'a.status', 'a.status.t2'},
        reason: 'a.card 被注销；别的 team 的槽位不受牵连',
      );
    });

    test('与本注册表无关的帧返回 false（不吞别人的帧）', () {
      final PluginUiRegistry reg = PluginUiRegistry.forTesting();
      expect(
        reg.handleFrame(<String, dynamic>{'type': WsOutboundType.msgChunk}),
        isFalse,
      );
      // 畸形 manifest：类型匹配即消费，但载荷丢弃、不抛
      expect(
        reg.handleFrame(<String, dynamic>{
          'type': PluginUiFrameType.manifest,
          'data': 'not-a-map',
        }),
        isTrue,
      );
      expect(reg.allSlots, isEmpty);
    });
  });

  group('team 过滤（M9 1.2 隔离口径）', () {
    test('只呈现当前 team 的槽位，切回即恢复', () {
      final PluginUiRegistry reg = PluginUiRegistry.forTesting()..setTeam('t1');
      reg.handleFrame(_manifest('demo.a',
          teamId: 't1',
          slots: <Map<String, dynamic>>[
            _slot('a.status', PluginUiSlotKind.status, title: '甲队'),
          ]));
      reg.handleFrame(_manifest('demo.b',
          teamId: 't2',
          slots: <Map<String, dynamic>>[
            _slot('b.status', PluginUiSlotKind.status, title: '乙队'),
          ]));

      expect(
        reg.slotsOfKind(PluginUiSlotKind.status).map((PluginUiSlot s) => s.title),
        <String>['甲队'],
      );
      // 切 team：他人槽位不显示（数据保留）
      reg.setTeam('t2');
      expect(
        reg.slotsOfKind(PluginUiSlotKind.status).map((PluginUiSlot s) => s.title),
        <String>['乙队'],
      );
      expect(reg.slot('a.status'), isNull, reason: '不可见槽位取不到');
      expect(reg.slotRaw('a.status'), isNotNull, reason: '数据仍在，切回即恢复');
      reg.setTeam('t1');
      expect(reg.slotsOfKind(PluginUiSlotKind.status), hasLength(1));
    });

    test('未选 team 时只呈现 team_id 为空的全局槽位（限定 team 的仍隐藏）', () {
      final PluginUiRegistry reg = PluginUiRegistry.forTesting();
      reg.handleFrame(_manifest('demo.a',
          teamId: 't1',
          slots: <Map<String, dynamic>>[_slot('a.status', PluginUiSlotKind.status)]));
      expect(reg.slotsOfKind(PluginUiSlotKind.status), isEmpty);
      reg.handleFrame(_manifest('demo.g',
          teamId: '',
          slots: <Map<String, dynamic>>[_slot('g.status', PluginUiSlotKind.status)]));
      expect(reg.slotsOfKind(PluginUiSlotKind.status), hasLength(1));
    });

    // 真机回归：`plugins.yaml` 里 scope 为空的插件（示例插件默认如此）声明的面板
    // 归属 team 为空，而活动 agent 几乎总有 team 作用域（无 team_id 的 agent 也
    // 回退到自身 id，见 Agent.teamScopeId）。若把空 team_id 理解成"只在未选 team
    // 时呈现"，插件面板就**永远不呈现**——表现为"插件没给前端面板"。
    test('未限定团队的槽位在任何 team 下都呈现（agent 回退 id 作 team 作用域）', () {
      final PluginUiRegistry reg = PluginUiRegistry.forTesting()
        ..setTeam('agt_1790406811628_73afa9_44');
      reg.handleFrame(_manifest('sample',
          teamId: '',
          slots: <Map<String, dynamic>>[
            _slot('sample.activity.1', PluginUiSlotKind.activity, title: '示例插件'),
            _slot('sample.panel.1', PluginUiSlotKind.panel, title: '示例插件'),
          ]));

      expect(
        reg.slotsOfKind(PluginUiSlotKind.activity).map((PluginUiSlot s) => s.title),
        <String>['示例插件'],
        reason: '空 team_id = 不限定归属：不属于任何特定 team，故任何 team 下都呈现',
      );
      expect(reg.slotsOfKind(PluginUiSlotKind.panel), hasLength(1));
      expect(reg.slot('sample.panel.1'), isNotNull);

      // 切到别的 team 依旧呈现（全局槽位不随当前 team 变化）
      reg.setTeam('team-2');
      expect(reg.slotsOfKind(PluginUiSlotKind.panel), hasLength(1));

      // 而限定 team 的槽位仍受精确匹配约束（隔离不入不敷出）
      reg.handleFrame(_manifest('demo.t2',
          teamId: 't2',
          slots: <Map<String, dynamic>>[
            _slot('t2.panel', PluginUiSlotKind.panel, title: '乙队'),
          ]));
      expect(
        reg.slotsOfKind(PluginUiSlotKind.panel).map((PluginUiSlot s) => s.title),
        <String>['示例插件'],
        reason: '当前 team=team-2，限定 t2 的槽位必须隐藏',
      );
    });
  });

  group('多插件同槽位共存与排序', () {
    test('同类型槽位互不覆盖，按 order 升序（相同 order 按到达顺序）', () {
      final PluginUiRegistry reg = PluginUiRegistry.forTesting()..setTeam('t1');
      reg.handleFrame(_manifest('demo.b', slots: <Map<String, dynamic>>[
        _slot('b.status', PluginUiSlotKind.status, title: 'B', order: 20),
      ]));
      reg.handleFrame(_manifest('demo.a', slots: <Map<String, dynamic>>[
        _slot('a1.status', PluginUiSlotKind.status, title: 'A1', order: 10),
        _slot('a2.status', PluginUiSlotKind.status, title: 'A2', order: 20),
      ]));
      expect(
        reg.slotsOfKind(PluginUiSlotKind.status).map((PluginUiSlot s) => s.title),
        <String>['A1', 'B', 'A2'],
        reason: 'order 升序；order 相同按到达顺序（b 先于 a2 登记）',
      );
      expect(reg.allSlots, hasLength(3), reason: '多插件互不覆盖');
    });

    test('卡片槽位严格按到达顺序（order 不参与）', () {
      final PluginUiRegistry reg = PluginUiRegistry.forTesting()..setTeam('t1');
      reg.handleFrame(_manifest('demo.a', slots: <Map<String, dynamic>>[
        _slot('a.card.1', PluginUiSlotKind.card, title: '先到', order: 99),
      ]));
      reg.handleFrame(_manifest('demo.b', slots: <Map<String, dynamic>>[
        _slot('b.card.1', PluginUiSlotKind.card, title: '后到', order: 0),
      ]));
      expect(
        reg.slotsOfKind(PluginUiSlotKind.card).map((PluginUiSlot s) => s.title),
        <String>['先到', '后到'],
      );
    });
  });

  group('动作帧（plugin_ui_action）', () {
    test('dispatchAction 组装完整帧（槽位归属 + 上下文 + payload）', () {
      final PluginUiRegistry reg = PluginUiRegistry.forTesting()..setTeam('t1');
      reg.handleFrame(_manifest('demo.a', slots: <Map<String, dynamic>>[
        _slot('a.panel', PluginUiSlotKind.panel),
      ]));
      final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
      reg.actionSender = sent.add;

      final bool ok = reg.dispatchAction(
        slotKey: 'a.panel',
        actionId: 'save',
        payload: <String, dynamic>{'name': 'x'},
        agentId: 'agent_1',
        sessionId: 'session_default',
      );
      expect(ok, isTrue);
      expect(sent.single['type'], PluginUiFrameType.action);
      final PluginUiAction action = PluginUiAction.fromFrame(sent.single)!;
      expect(action.slotKey, 'a.panel');
      expect(action.actionId, 'save');
      expect(action.pluginId, 'demo.a');
      expect(action.teamId, 't1');
      expect(action.agentId, 'agent_1');
      expect(action.sessionId, 'session_default');
      expect(action.payload, <String, dynamic>{'name': 'x'});
    });

    test('未接发送通道 / 槽位不存在时返回 false 且不抛', () {
      final PluginUiRegistry reg = PluginUiRegistry.forTesting()..setTeam('t1');
      reg.handleFrame(_manifest('demo.a', slots: <Map<String, dynamic>>[
        _slot('a.panel', PluginUiSlotKind.panel),
      ]));
      expect(
        reg.dispatchAction(slotKey: 'a.panel', actionId: 'save'),
        isFalse,
        reason: '未接发送通道',
      );
      reg.actionSender = (Map<String, dynamic> frame) {};
      expect(
        reg.dispatchAction(slotKey: 'ghost', actionId: 'save'),
        isFalse,
        reason: '槽位不存在',
      );
    });
  });
}
