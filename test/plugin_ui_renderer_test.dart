// Q12 插件布局：受限渲染器测试（六种控件 + 容器 + 未知控件占位 + 动作帧）。
//
// 运行方式（项目根目录）：
//   flutter test test/plugin_ui_renderer_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tree/ui/services/plugin_ui_registry.dart';
import 'package:tree/ui/widgets/plugin_ui_view.dart';
import 'package:tree_protocol/tree_protocol.dart';

/// 由视图 JSON 构造一个槽位（合成数据，不依赖核心进程）。
PluginUiSlot _makeSlot(
  Object? view, {
  String slotKey = 'demo.test.panel.1',
  String kind = PluginUiSlotKind.panel,
}) =>
    PluginUiSlot.tryParse(<String, dynamic>{
      'slot_key': slotKey,
      'slot': kind,
      'plugin_id': 'demo.test',
      'team_id': 't1',
      'title': '测试槽位',
      'view': view,
    })!;

/// 宿主：可滚动（避免长表单撑破测试视口），宽度固定便于 row 容器布局。
Widget _host(
  PluginUiSlot slot, {
  PluginUiRegistry? registry,
  double width = 420,
  String agentId = '',
  String sessionId = '',
}) =>
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: PluginUiViewRenderer(
                slot: slot,
                view: slot.view,
                registry: registry,
                agentId: agentId,
                sessionId: sessionId,
              ),
            ),
          ),
        ),
      ),
    );

/// 建一个已登记 [slot] 且可捕获动作帧的注册表。
(PluginUiRegistry, List<Map<String, dynamic>>) _registryWith(PluginUiSlot slot) {
  final PluginUiRegistry reg = PluginUiRegistry.forTesting()..setTeam('t1');
  reg.registerSlot(slot);
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  reg.actionSender = sent.add;
  return (reg, sent);
}

void main() {
  testWidgets('text：纯文本与样式', (WidgetTester tester) async {
    final PluginUiSlot slot = _makeSlot(<String, dynamic>{
      'type': 'text',
      'text': '普通文本',
      'style': 'title',
    });
    await tester.pumpWidget(_host(slot));
    expect(find.text('普通文本'), findsOneWidget);
  });

  testWidgets('text：markdown 渲染，图片只给占位（不联网）', (WidgetTester tester) async {
    final PluginUiSlot slot = _makeSlot(<String, dynamic>{
      'type': 'text',
      'format': 'markdown',
      'text': '**加粗**与[链接](https://example.com)'
          '\n\n![图](https://example.com/a.png)',
    });
    await tester.pumpWidget(_host(slot));
    expect(find.textContaining('加粗', findRichText: true), findsOneWidget);
    // 图片一律占位：不允许 webview/iframe，也不发起网络取图
    expect(find.textContaining('图片已禁用'), findsOneWidget);
  });

  testWidgets('list：标量项按文本、对象项递归渲染', (WidgetTester tester) async {
    final PluginUiSlot slot = _makeSlot(<String, dynamic>{
      'type': 'list',
      'ordered': true,
      'items': <dynamic>[
        '甲',
        <String, dynamic>{'type': 'text', 'text': '乙'},
      ],
    });
    await tester.pumpWidget(_host(slot));
    expect(find.text('甲'), findsOneWidget);
    expect(find.text('乙'), findsOneWidget);
    expect(find.text('1. '), findsOneWidget);
  });

  testWidgets('list：空列表显示 empty 文案', (WidgetTester tester) async {
    final PluginUiSlot slot = _makeSlot(<String, dynamic>{
      'type': 'list',
      'items': <dynamic>[],
      'empty': '还没有内容',
    });
    await tester.pumpWidget(_host(slot));
    expect(find.text('还没有内容'), findsOneWidget);
  });

  testWidgets('table：columns + rows 渲染为表格', (WidgetTester tester) async {
    final PluginUiSlot slot = _makeSlot(<String, dynamic>{
      'type': 'table',
      'caption': '统计',
      'columns': <dynamic>['列甲', '列乙'],
      'rows': <dynamic>[
        <dynamic>['1', '2'],
        <dynamic>['3'],
      ],
    });
    await tester.pumpWidget(_host(slot));
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('统计'), findsOneWidget);
    expect(find.text('列甲'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    // 行比表头短：缺的单元格按空串补齐，不崩
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('progress：label + detail + 进度条', (WidgetTester tester) async {
    final PluginUiSlot slot = _makeSlot(<String, dynamic>{
      'type': 'progress',
      'value': 0.42,
      'label': '同步中',
      'detail': '42%',
    });
    await tester.pumpWidget(_host(slot));
    expect(find.text('同步中'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    final LinearProgressIndicator bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(0.42, 0.0001));
  });

  testWidgets('progress：无 value 时是不确定进度', (WidgetTester tester) async {
    final PluginUiSlot slot = _makeSlot(<String, dynamic>{
      'type': 'progress',
      'label': '连接中',
    });
    await tester.pumpWidget(_host(slot));
    final LinearProgressIndicator bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, isNull);
  });

  testWidgets('actions：点击按钮发出 plugin_ui_action 帧（自带 payload）',
      (WidgetTester tester) async {
    final PluginUiSlot slot = _makeSlot(<String, dynamic>{
      'type': 'actions',
      'buttons': <dynamic>[
        <String, dynamic>{
          'action_id': 'refresh',
          'label': '刷新',
          'style': 'primary',
          'payload': <String, dynamic>{'mode': 'hard'},
        },
        <String, dynamic>{
          'action_id': 'remove',
          'label': '删除',
          'enabled': false,
        },
      ],
    });
    final (PluginUiRegistry reg, List<Map<String, dynamic>> sent) =
        _registryWith(slot);
    await tester.pumpWidget(
      _host(slot, registry: reg, agentId: 'agent_1', sessionId: 's1'),
    );

    await tester.tap(find.text('刷新'));
    await tester.pump();
    expect(sent, hasLength(1));
    final PluginUiAction action = PluginUiAction.fromFrame(sent.single)!;
    expect(action.slotKey, slot.slotKey);
    expect(action.actionId, 'refresh');
    expect(action.pluginId, 'demo.test');
    expect(action.teamId, 't1');
    expect(action.agentId, 'agent_1');
    expect(action.sessionId, 's1');
    expect(action.payload, <String, dynamic>{'mode': 'hard'});

    // 禁用按钮不派发
    await tester.tap(find.text('删除'));
    await tester.pump();
    expect(sent, hasLength(1));
  });

  testWidgets('form：字段值 + submit.payload 合并成提交 payload',
      (WidgetTester tester) async {
    final PluginUiSlot slot = _makeSlot(<String, dynamic>{
      'type': 'form',
      'fields': <dynamic>[
        <String, dynamic>{
          'key': 'name',
          'label': '名称',
          'kind': 'text',
          'value': '旧值',
        },
        <String, dynamic>{
          'key': 'count',
          'label': '数量',
          'kind': 'number',
          'value': '3',
        },
        <String, dynamic>{
          'key': 'enabled',
          'label': '启用',
          'kind': 'checkbox',
          'value': false,
        },
        <String, dynamic>{
          'key': 'level',
          'label': '级别',
          'kind': 'select',
          'options': <dynamic>['a', 'b'],
          'value': 'b',
        },
        <String, dynamic>{
          'key': 'note',
          'label': '备注',
          'kind': 'textarea',
          'placeholder': '补充说明',
        },
      ],
      'submit': <String, dynamic>{
        'action_id': 'save',
        'label': '保存',
        'payload': <String, dynamic>{'preset': 'x'},
      },
    });
    final (PluginUiRegistry reg, List<Map<String, dynamic>> sent) =
        _registryWith(slot);
    await tester.pumpWidget(_host(slot, registry: reg));

    expect(find.text('名称'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), '新名称');
    await tester.tap(find.byType(Checkbox));
    await tester.pump();

    await tester.tap(find.text('保存'));
    await tester.pump();

    expect(sent, hasLength(1));
    final PluginUiAction action = PluginUiAction.fromFrame(sent.single)!;
    expect(action.actionId, 'save');
    expect(action.payload['preset'], 'x', reason: 'submit.payload 先铺底');
    expect(action.payload['name'], '新名称');
    expect(action.payload['count'], 3, reason: 'number 字段解析为 num');
    expect(action.payload['enabled'], isTrue);
    expect(action.payload['level'], 'b', reason: 'select 初值');
    expect(action.payload['note'], '');
  });

  testWidgets('未知控件类型 → 可读占位（不崩）', (WidgetTester tester) async {
    final PluginUiSlot slot = _makeSlot(<String, dynamic>{
      'type': 'holo_deck',
      'x': 1,
    });
    await tester.pumpWidget(_host(slot));
    expect(find.text('不支持的控件（holo_deck）'), findsOneWidget);
  });

  testWidgets('容器 row / column：子节点按顺序渲染', (WidgetTester tester) async {
    final PluginUiSlot slot = _makeSlot(<String, dynamic>{
      'type': 'column',
      'children': <dynamic>[
        <String, dynamic>{'type': 'text', 'text': '上半'},
        <String, dynamic>{
          'type': 'row',
          'children': <dynamic>[
            <String, dynamic>{'type': 'text', 'text': '左'},
            <String, dynamic>{'type': 'text', 'text': '右'},
          ],
        },
      ],
    });
    await tester.pumpWidget(_host(slot));
    expect(find.text('上半'), findsOneWidget);
    expect(find.text('左'), findsOneWidget);
    expect(find.text('右'), findsOneWidget);
    // row 里左右并排：左在右的左边
    expect(
      tester.getTopLeft(find.text('左')).dx,
      lessThan(tester.getTopLeft(find.text('右')).dx),
    );
  });

  testWidgets('视图为节点数组：按顺序垂直堆叠', (WidgetTester tester) async {
    final PluginUiSlot slot = _makeSlot(<dynamic>[
      <String, dynamic>{'type': 'text', 'text': '第一块'},
      <String, dynamic>{'type': 'text', 'text': '第二块'},
    ]);
    await tester.pumpWidget(_host(slot));
    expect(
      tester.getTopLeft(find.text('第一块')).dy,
      lessThan(tester.getTopLeft(find.text('第二块')).dy),
    );
  });
}
