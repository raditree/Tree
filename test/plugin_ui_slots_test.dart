// Q12 插件布局：四处接入点测试（活动栏 / 右栏 / 状态栏 / 消息流卡片）。
//
// 全部用**合成帧**驱动（plugin_ui_manifest / plugin_ui_update），不依赖核心进程。
// 运行方式（项目根目录）：
//   flutter test test/plugin_ui_slots_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree/ui/models/message.dart';
import 'package:tree/ui/services/plugin_ui_registry.dart';
import 'package:tree/ui/widgets/activity_bar_item.dart';
import 'package:tree/ui/widgets/file_panel.dart';
import 'package:tree/ui/widgets/message_list.dart';
import 'package:tree/ui/widgets/plugin_ui_slots.dart';
import 'package:tree_protocol/tree_protocol.dart';

void _noop() {}

/// 槽位声明 JSON（合成）。
Map<String, dynamic> _slot(
  String key,
  String kind, {
  String title = '',
  Object? view,
}) =>
    <String, dynamic>{
      'slot_key': key,
      'slot': kind,
      'title': title,
      'view': view ??
          <String, dynamic>{'type': 'text', 'text': '$key 的内容'},
    };

/// 把一条 manifest 合成帧喂给注册表（并断言被消费）。
void _feedManifest(
  PluginUiRegistry reg,
  String pluginId,
  String teamId,
  List<Map<String, dynamic>> slots,
) {
  final bool consumed = reg.handleFrame(<String, dynamic>{
    'type': PluginUiFrameType.manifest,
    'data': <String, dynamic>{
      'plugin_id': pluginId,
      'team_id': teamId,
      'slots': slots,
    },
  });
  expect(consumed, isTrue);
}

/// 把一条 update 合成帧喂给注册表。
void _feedUpdate(
  PluginUiRegistry reg,
  String pluginId,
  String teamId,
  String slotKey,
  Object? view,
) {
  reg.handleFrame(<String, dynamic>{
    'type': PluginUiFrameType.update,
    'data': <String, dynamic>{
      'plugin_id': pluginId,
      'team_id': teamId,
      'slot_key': slotKey,
      'view': view,
    },
  });
}

void main() {
  // ══ 接入点 1：左侧活动栏 ═══════════════════════════════════════════════

  group('左侧活动栏', () {
    Widget host(PluginUiRegistry reg, void Function(String) onSelect) =>
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 48,
              height: 300,
              child: Column(
                children: <Widget>[
                  // 既有内置项（插件项必须排在它之后，且用同一套观感）
                  ActivityBarItem(
                    icon: Icons.groups_outlined,
                    selectedIcon: Icons.groups,
                    tooltip: 'Agent 列表',
                    selected: true,
                    onTap: _noop,
                  ),
                  PluginActivityBarItems(
                    registry: reg,
                    selectedSlotKey: null,
                    onSelect: onSelect,
                  ),
                ],
              ),
            ),
          ),
        );

    testWidgets('插件项追加在内置项之后，点击回传槽位键', (WidgetTester tester) async {
      final PluginUiRegistry reg = PluginUiRegistry.forTesting()..setTeam('t1');
      _feedManifest(reg, 'demo.a', 't1', <Map<String, dynamic>>[
        _slot('a.activity.1', PluginUiSlotKind.activity, title: '演示活动项'),
      ]);
      final List<String> selected = <String>[];
      await tester.pumpWidget(host(reg, selected.add));

      expect(find.byTooltip('Agent 列表'), findsOneWidget);
      expect(find.byTooltip('演示活动项'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byTooltip('演示活动项')).dy,
        greaterThan(tester.getTopLeft(find.byTooltip('Agent 列表')).dy),
        reason: '插件项追加在主活动栏项之后',
      );

      await tester.tap(find.byTooltip('演示活动项'));
      expect(selected, <String>['a.activity.1']);
    });

    testWidgets('只显示当前 team 的插件项；切 team 后他人槽位不显示',
        (WidgetTester tester) async {
      final PluginUiRegistry reg = PluginUiRegistry.forTesting()..setTeam('t1');
      _feedManifest(reg, 'demo.a', 't1', <Map<String, dynamic>>[
        _slot('a.activity.1', PluginUiSlotKind.activity, title: '甲队项'),
      ]);
      _feedManifest(reg, 'demo.b', 't2', <Map<String, dynamic>>[
        _slot('b.activity.1', PluginUiSlotKind.activity, title: '乙队项'),
      ]);
      await tester.pumpWidget(host(reg, (_) {}));
      expect(find.byTooltip('甲队项'), findsOneWidget);
      expect(find.byTooltip('乙队项'), findsNothing);

      reg.setTeam('t2');
      await tester.pump();
      expect(find.byTooltip('甲队项'), findsNothing);
      expect(find.byTooltip('乙队项'), findsOneWidget);
    });

    testWidgets('插件卸载（plugin_status destroyed）后活动栏项消失',
        (WidgetTester tester) async {
      final PluginUiRegistry reg = PluginUiRegistry.forTesting()..setTeam('t1');
      _feedManifest(reg, 'demo.a', 't1', <Map<String, dynamic>>[
        _slot('a.activity.1', PluginUiSlotKind.activity, title: '演示活动项'),
      ]);
      await tester.pumpWidget(host(reg, (_) {}));
      expect(find.byTooltip('演示活动项'), findsOneWidget);

      reg.handleFrame(<String, dynamic>{
        'type': WsOutboundType.pluginStatus,
        'data': <String, dynamic>{
          'plugin_id': 'demo.a',
          'scope': <String, dynamic>{'team_id': 't1'},
          'status': 'destroyed',
        },
      });
      await tester.pump();
      expect(find.byTooltip('演示活动项'), findsNothing);
    });
  });

  // ══ 接入点 2：右栏 Tab ═════════════════════════════════════════════════

  group('右栏插件 Tab', () {
    Widget host(PluginUiRegistry reg) => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 760,
              height: 600,
              child: FilePanel(
                workspaceId: 'ws_test',
                teamId: 't1',
                sessionId: 'session_default',
                registry: reg,
              ),
            ),
          ),
        );

    testWidgets('插件 Tab 追加在既有 Tab 之后，切过去渲染槽位视图',
        (WidgetTester tester) async {
      final PluginUiRegistry reg = PluginUiRegistry.forTesting()..setTeam('t1');
      _feedManifest(reg, 'demo.a', 't1', <Map<String, dynamic>>[
        _slot(
          'a.panel.1',
          PluginUiSlotKind.panel,
          title: '演示面板',
          view: <String, dynamic>{'type': 'text', 'text': '面板内容'},
        ),
      ]);
      await tester.pumpWidget(host(reg));
      await tester.pump();

      // 既有四个 Tab 仍在
      expect(find.text('文件'), findsOneWidget);
      expect(find.text('MCP 配置'), findsOneWidget);
      expect(find.text('模型信息'), findsOneWidget);
      expect(find.text('问题回复'), findsOneWidget);
      // 插件 Tab 追加在最后
      expect(find.text('演示面板'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('演示面板')).dx,
        greaterThan(tester.getTopLeft(find.text('问题回复')).dx),
      );

      // 切到插件 Tab：内容为槽位视图
      await tester.tap(find.text('演示面板'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('面板内容'), findsOneWidget);

      // 整块替换：plugin_ui_update 后内容即时变化
      _feedUpdate(reg, 'demo.a', 't1', 'a.panel.1', <String, dynamic>{
        'type': 'text',
        'text': '更新后的内容',
      });
      await tester.pump();
      expect(find.text('更新后的内容'), findsOneWidget);
      expect(find.text('面板内容'), findsNothing);
    });

    testWidgets('别的 team 的插件 Tab 不出现', (WidgetTester tester) async {
      final PluginUiRegistry reg = PluginUiRegistry.forTesting()..setTeam('t1');
      _feedManifest(reg, 'demo.b', 't2', <Map<String, dynamic>>[
        _slot('b.panel.1', PluginUiSlotKind.panel, title: '乙队面板'),
      ]);
      await tester.pumpWidget(host(reg));
      await tester.pump();
      expect(find.text('乙队面板'), findsNothing);
      expect(find.text('问题回复'), findsOneWidget);
    });
  });

  // ══ 接入点 3：底部状态栏 ═══════════════════════════════════════════════

  group('底部状态栏', () {
    Widget host(PluginUiRegistry reg) => MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                const Expanded(child: SizedBox.shrink()),
                PluginStatusBar(registry: reg),
              ],
            ),
          ),
        );

    testWidgets('无状态项时整条不出现；有状态项时渲染并可更新/注销',
        (WidgetTester tester) async {
      final PluginUiRegistry reg = PluginUiRegistry.forTesting()..setTeam('t1');
      await tester.pumpWidget(host(reg));
      expect(
        tester.getSize(find.byType(PluginStatusBar)).height,
        0,
        reason: '没有插件状态项时状态栏不占高度',
      );

      _feedManifest(reg, 'demo.a', 't1', <Map<String, dynamic>>[
        _slot(
          'a.status.1',
          PluginUiSlotKind.status,
          title: '演示',
          view: <String, dynamic>{'type': 'text', 'text': '已连接'},
        ),
      ]);
      await tester.pump();
      expect(tester.getSize(find.byType(PluginStatusBar)).height, 24);
      expect(find.text('已连接'), findsOneWidget);

      _feedUpdate(reg, 'demo.a', 't1', 'a.status.1', <String, dynamic>{
        'type': 'text',
        'text': '已断开',
      });
      await tester.pump();
      expect(find.text('已断开'), findsOneWidget);
      expect(find.text('已连接'), findsNothing);

      // view: null ⇒ 注销槽位 ⇒ 状态栏重新消失
      _feedUpdate(reg, 'demo.a', 't1', 'a.status.1', null);
      await tester.pump();
      expect(tester.getSize(find.byType(PluginStatusBar)).height, 0);
    });

    testWidgets('切 team 后只显示当前 team 的状态项', (WidgetTester tester) async {
      final PluginUiRegistry reg = PluginUiRegistry.forTesting()..setTeam('t1');
      _feedManifest(reg, 'demo.a', 't1', <Map<String, dynamic>>[
        _slot('a.status.1', PluginUiSlotKind.status, view: <String, dynamic>{
          'type': 'text',
          'text': '甲队状态',
        }),
      ]);
      _feedManifest(reg, 'demo.b', 't2', <Map<String, dynamic>>[
        _slot('b.status.1', PluginUiSlotKind.status, view: <String, dynamic>{
          'type': 'text',
          'text': '乙队状态',
        }),
      ]);
      await tester.pumpWidget(host(reg));
      expect(find.text('甲队状态'), findsOneWidget);
      expect(find.text('乙队状态'), findsNothing);
      reg.setTeam('t2');
      await tester.pump();
      expect(find.text('甲队状态'), findsNothing);
      expect(find.text('乙队状态'), findsOneWidget);
    });
  });

  // ══ 接入点 4：消息流内联卡片 ═══════════════════════════════════════════

  group('消息流内联卡片', () {
    Widget host(PluginUiRegistry reg) => MaterialApp(
          home: Scaffold(
            body: MessageList(
              messages: <ChatMessage>[
                ChatMessage(
                  id: 'm1',
                  role: 'user',
                  content: '你好',
                  timestamp: DateTime.now(),
                ),
              ],
              revision: 1,
              trailingCards: <Widget>[PluginInlineCards(registry: reg)],
            ),
          ),
        );

    testWidgets('卡片渲染在最后一条消息之后，按到达顺序排列',
        (WidgetTester tester) async {
      final PluginUiRegistry reg = PluginUiRegistry.forTesting()..setTeam('t1');
      _feedManifest(reg, 'demo.a', 't1', <Map<String, dynamic>>[
        _slot(
          'a.card.1',
          PluginUiSlotKind.card,
          title: '先到卡片',
          view: <String, dynamic>{'type': 'text', 'text': '先到内容'},
        ),
      ]);
      _feedManifest(reg, 'demo.b', 't1', <Map<String, dynamic>>[
        _slot(
          'b.card.1',
          PluginUiSlotKind.card,
          title: '后到卡片',
          view: <String, dynamic>{'type': 'text', 'text': '后到内容'},
        ),
      ]);
      await tester.pumpWidget(host(reg));
      await tester.pump();

      expect(find.text('你好'), findsOneWidget);
      expect(find.text('先到内容'), findsOneWidget);
      expect(find.text('后到内容'), findsOneWidget);
      final double messageY = tester.getTopLeft(find.text('你好')).dy;
      expect(
        tester.getTopLeft(find.text('先到内容')).dy,
        greaterThan(messageY),
        reason: '卡片在消息之后',
      );
      expect(
        tester.getTopLeft(find.text('后到内容')).dy,
        greaterThan(tester.getTopLeft(find.text('先到内容')).dy),
        reason: '按到达顺序',
      );
    });

    testWidgets('卡片被注销后从消息流消失；别的 team 的卡片不显示',
        (WidgetTester tester) async {
      final PluginUiRegistry reg = PluginUiRegistry.forTesting()..setTeam('t1');
      _feedManifest(reg, 'demo.a', 't1', <Map<String, dynamic>>[
        _slot('a.card.1', PluginUiSlotKind.card, view: <String, dynamic>{
          'type': 'text',
          'text': '本队卡片',
        }),
      ]);
      _feedManifest(reg, 'demo.b', 't2', <Map<String, dynamic>>[
        _slot('b.card.1', PluginUiSlotKind.card, view: <String, dynamic>{
          'type': 'text',
          'text': '他队卡片',
        }),
      ]);
      await tester.pumpWidget(host(reg));
      await tester.pump();
      expect(find.text('本队卡片'), findsOneWidget);
      expect(find.text('他队卡片'), findsNothing);

      _feedUpdate(reg, 'demo.a', 't1', 'a.card.1', null);
      await tester.pump();
      expect(find.text('本队卡片'), findsNothing);
      expect(find.text('你好'), findsOneWidget, reason: '消息本身不受影响');
    });
  });
}
